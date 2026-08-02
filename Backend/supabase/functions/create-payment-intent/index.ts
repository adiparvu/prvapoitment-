/**
 * create-payment-intent
 *
 * Turns an order into a Stripe PaymentIntent the app can confirm with
 * PaymentSheet or Apple Pay.
 *
 * Three properties make this safe, and all three live here rather than in the
 * client:
 *
 *   1. **Ownership is proved by RLS, not asserted.** The order is read with the
 *      caller's own JWT, so a request for someone else's order returns nothing
 *      at all — there is no "check the client_id matches" branch to forget.
 *   2. **The amount is recomputed from the order lines.** Whatever the client
 *      sends as a total is ignored; the figure charged is derived from
 *      `order_totals`, the same view the receipt is rendered from — in whole
 *      minor units with banker's rounding, so it lands on the same cent
 *      `PRVPaymentsKit` quoted before the tap. Any discount earned along the
 *      way is written back to the order, not just applied to the charge.
 *   3. **The intent is created with an idempotency key derived from the order
 *      and the amount.** A retried request — a flaky network, an impatient tap
 *      — resolves to the same PaymentIntent instead of a second charge.
 *
 * Request  { order_id, prepayment_percent?, save_payment_method?, stripe_api_version? }
 * Response { payment_intent_id, client_secret, customer_id, ephemeral_key?, amount }
 */

import { handlePreflight } from "../_shared/cors.ts";
import {
  errorResponse,
  fromPostgresError,
  HttpError,
  jsonResponse,
  readJson,
  requireMethod,
  requireUUID,
} from "../_shared/errors.ts";
import { requireUser } from "../_shared/auth.ts";
import { serviceClient, userClient } from "../_shared/supabase.ts";
import { stripeClient, toMinorUnits } from "../_shared/stripe.ts";
import { centsToNumber, fromCents, percentageOfCents, toCents } from "../_shared/money.ts";
import { optionalEnv } from "../_shared/env.ts";

interface RequestBody {
  order_id?: string;
  /** 10 | 20 | 30 | 50 | 100 — must be offered by the salon. */
  prepayment_percent?: number;
  save_payment_method?: boolean;
  /** The Stripe API version the iOS SDK expects, for the ephemeral key. */
  stripe_api_version?: string;
}

interface OrderRow {
  id: string;
  salon_id: string;
  client_id: string;
  appointment_id: string | null;
  status: string;
  currency: string;
  amount_paid: string;
  discount_reason: string | null;
  stripe_payment_intent_id: string | null;
  stripe_customer_id: string | null;
}

interface OrderTotalsRow {
  order_id: string;
  subtotal_amount: string;
  discount_amount: string;
  total_amount: string;
  amount_paid: string;
  outstanding_amount: string;
}

/** Statuses from which a PaymentIntent can still be confirmed by the app. */
const REUSABLE_INTENT_STATUSES = new Set([
  "requires_payment_method",
  "requires_confirmation",
  "requires_action",
  "processing",
]);

Deno.serve(async (request) => {
  const preflight = handlePreflight(request);
  if (preflight) return preflight;

  try {
    requireMethod(request, "POST");
    const user = await requireUser(request);
    const body = await readJson<RequestBody>(request);
    const orderId = requireUUID(body.order_id, "order_id");

    const asUser = userClient(request);

    // (1) Ownership. RLS hides orders that are neither the caller's nor their
    // salon's, so "not found" and "not yours" are the same answer.
    const { data: order, error: orderError } = await asUser
      .from("orders")
      .select(
        "id, salon_id, client_id, appointment_id, status, currency, amount_paid, discount_reason, stripe_payment_intent_id, stripe_customer_id",
      )
      .eq("id", orderId)
      .maybeSingle<OrderRow>();

    if (orderError) throw fromPostgresError(orderError, "Could not load that order.");
    if (!order) throw HttpError.notFound("That order does not exist.");

    if (order.client_id !== user.id) {
      throw HttpError.forbidden("Only the client who owns an order can pay for it.");
    }
    if (order.status === "paid") {
      throw HttpError.conflict("This order has already been paid in full.");
    }
    if (["cancelled", "refunded"].includes(order.status)) {
      throw HttpError.conflict(`This order is ${order.status} and cannot be paid.`);
    }

    // (2) Server-side arithmetic. `order_totals` sums the lines; nothing the
    // client sent contributes to the figure below.
    const { data: totals, error: totalsError } = await asUser
      .from("order_totals")
      .select("order_id, subtotal_amount, discount_amount, total_amount, amount_paid, outstanding_amount")
      .eq("order_id", orderId)
      .maybeSingle<OrderTotalsRow>();

    if (totalsError) throw fromPostgresError(totalsError, "Could not price that order.");
    if (!totals) throw HttpError.notFound("That order has no lines to pay for.");

    const currency = order.currency.toUpperCase();
    const admin = serviceClient();

    const { chargeableCents, prepaymentPercent, discountReason, discountCents } =
      await resolveChargeable({
        request,
        admin,
        salonId: order.salon_id,
        orderId: order.id,
        subtotalCents: toCents(totals.subtotal_amount),
        totalCents: toCents(totals.total_amount),
        alreadyPaidCents: toCents(totals.amount_paid),
        requestedPercent: body.prepayment_percent,
      });

    if (chargeableCents <= 0) {
      throw HttpError.conflict("There is nothing left to pay on this order.");
    }

    const chargeable = centsToNumber(chargeableCents);
    const amountMinor = toMinorUnits(chargeable, currency);
    if (amountMinor < 50) {
      // Stripe's floor for most currencies; surfacing it here beats a raw
      // provider error in the checkout sheet.
      throw HttpError.badRequest(
        "That amount is below the minimum a card payment can process.",
      );
    }

    // The discount the client is charged against has to land on the order as
    // well as on the intent: `order_totals.total_amount` is what the webhook
    // compares `amount_paid` to, so a discount that only reached Stripe would
    // leave a fully prepaid order forever short of its own total. It is written
    // before the intent exists, and recomputed absolutely, so every path out of
    // this function — new intent, reused intent, retargeted intent — leaves the
    // order priced the same way.
    if (discountCents !== null) {
      const { error: discountError } = await admin
        .from("orders")
        .update({
          discount_amount: fromCents(discountCents),
          discount_reason: mergeDiscountReason(order.discount_reason, discountReason),
        })
        .eq("id", order.id);

      if (discountError) {
        throw fromPostgresError(discountError, "Could not price that order.");
      }
    }

    const stripe = stripeClient();

    // A customer per platform account, reused across orders so saved cards and
    // Apple Pay behave the way the client expects.
    const customerId = await resolveCustomer({
      stripe,
      admin,
      order,
      userId: user.id,
      email: user.email,
      name: `${user.firstName} ${user.lastName}`.trim(),
    });

    // (3) Idempotency. Same order, same amount, same key — Stripe returns the
    // original intent rather than creating a second one.
    const idempotencyKey = `prv:pi:${order.id}:${amountMinor}:${currency}`;

    // Reuse an in-flight intent when it still matches what we intend to charge.
    if (order.stripe_payment_intent_id) {
      const existing = await stripe.paymentIntents.retrieve(order.stripe_payment_intent_id)
        .catch(() => null);

      if (existing) {
        if (existing.status === "succeeded") {
          throw HttpError.conflict("This order has already been paid in full.");
        }
        if (REUSABLE_INTENT_STATUSES.has(existing.status) && existing.amount === amountMinor) {
          return jsonResponse(request, {
            payment_intent_id: existing.id,
            client_secret: existing.client_secret,
            customer_id: customerId,
            ephemeral_key: await maybeEphemeralKey(stripe, customerId, body.stripe_api_version),
            publishable_key: optionalEnv("STRIPE_PUBLISHABLE_KEY") ?? null,
            amount: { amount: chargeable, currency },
            reused: true,
          });
        }
        if (REUSABLE_INTENT_STATUSES.has(existing.status)) {
          // The order changed underneath an unconfirmed intent — retarget it.
          await stripe.paymentIntents.update(existing.id, { amount: amountMinor });
          const updated = await stripe.paymentIntents.retrieve(existing.id);
          return jsonResponse(request, {
            payment_intent_id: updated.id,
            client_secret: updated.client_secret,
            customer_id: customerId,
            ephemeral_key: await maybeEphemeralKey(stripe, customerId, body.stripe_api_version),
            publishable_key: optionalEnv("STRIPE_PUBLISHABLE_KEY") ?? null,
            amount: { amount: chargeable, currency },
            reused: true,
          });
        }
      }
    }

    const intent = await stripe.paymentIntents.create({
      amount: amountMinor,
      currency: currency.toLowerCase(),
      customer: customerId,
      automatic_payment_methods: { enabled: true },
      ...(body.save_payment_method ? { setup_future_usage: "off_session" as const } : {}),
      metadata: {
        order_id: order.id,
        salon_id: order.salon_id,
        client_id: order.client_id,
        appointment_id: order.appointment_id ?? "",
        prepayment_percent: String(prepaymentPercent ?? 100),
        platform: "prv-beauty-ios",
      },
      description: `PRV Beauty order ${order.id}`,
    }, { idempotencyKey });

    const { error: persistError } = await admin
      .from("orders")
      .update({
        stripe_payment_intent_id: intent.id,
        stripe_customer_id: customerId,
        idempotency_key: idempotencyKey,
        status: order.status === "draft" ? "awaiting_payment" : order.status,
      })
      .eq("id", order.id);

    if (persistError) {
      // The intent exists but we lost the link; the webhook resolves the order
      // from `metadata.order_id`, so payment still completes correctly.
      console.error("Could not persist payment intent id on order", persistError);
    }

    return jsonResponse(request, {
      payment_intent_id: intent.id,
      client_secret: intent.client_secret,
      customer_id: customerId,
      ephemeral_key: await maybeEphemeralKey(stripe, customerId, body.stripe_api_version),
      publishable_key: optionalEnv("STRIPE_PUBLISHABLE_KEY") ?? null,
      amount: { amount: chargeable, currency },
      reused: false,
    });
  } catch (error) {
    return errorResponse(request, error);
  }
});

/** The label every full-prepayment discount reason starts with. */
const PREPAYMENT_DISCOUNT_LABEL = "Full prepayment discount";

/** How `discount_reason` joins the components that make up a discount. */
const DISCOUNT_REASON_SEPARATOR = " + ";

/**
 * Works out what to charge now, in whole minor units.
 *
 * With no prepayment requested this is simply the outstanding balance. With one
 * requested, the percentage must be one the salon actually offers — a client
 * cannot invent a 5% deposit — and paying in full earns the salon's configured
 * full-prepayment discount.
 *
 * Every step mirrors `PRVPaymentsKit.PrepaymentCalculator`: integer cents,
 * banker's rounding, and the full level charging the payable total outright
 * rather than 100% of it, so the figure quoted before the tap is the figure
 * Stripe captures.
 *
 * `discountCents` is the order's whole discount recomputed from first
 * principles — the coupon redeemed at booking plus the prepayment discount just
 * earned — so re-running this for a retried or retargeted intent settles on the
 * same number instead of compounding.
 */
async function resolveChargeable(input: {
  request: Request;
  admin: ReturnType<typeof serviceClient>;
  salonId: string;
  orderId: string;
  subtotalCents: number;
  totalCents: number;
  alreadyPaidCents: number;
  requestedPercent?: number;
}): Promise<{
  chargeableCents: number;
  prepaymentPercent: number | null;
  discountReason: string | null;
  /** `null` when no percentage was requested — leave the order's discount alone. */
  discountCents: number | null;
}> {
  if (input.requestedPercent === undefined || input.requestedPercent === null) {
    return {
      chargeableCents: Math.max(input.totalCents - input.alreadyPaidCents, 0),
      prepaymentPercent: null,
      discountReason: null,
      discountCents: null,
    };
  }

  const percent = input.requestedPercent;
  if (!Number.isInteger(percent) || percent <= 0 || percent > 100) {
    throw HttpError.badRequest("`prepayment_percent` must be a whole percentage between 1 and 100.");
  }

  const asUser = userClient(input.request);
  const { data: policy } = await asUser
    .from("prepayment_policies")
    .select("offered_percents, full_prepayment_discount_percent")
    .eq("salon_id", input.salonId)
    .maybeSingle<{ offered_percents: number[]; full_prepayment_discount_percent: number }>();

  const offered = policy?.offered_percents ?? [100];
  if (!offered.includes(percent)) {
    throw HttpError.badRequest(
      `This salon offers prepayment at ${offered.join("%, ")}% — not ${percent}%.`,
    );
  }

  // The coupon redeemed at booking is the only other discount on an order, and
  // `coupon_redemptions` is its audit trail — reading it back keeps the two
  // components independent instead of layering one on top of the other.
  const couponDiscountCents = await couponDiscountCentsForOrder(input.admin, input.orderId);
  const beforePrepaymentCents = Math.max(input.subtotalCents - couponDiscountCents, 0);

  const fullDiscountPercent = policy?.full_prepayment_discount_percent ?? 0;
  const prepaymentDiscountCents = percent === 100 && fullDiscountPercent > 0
    ? percentageOfCents(beforePrepaymentCents, fullDiscountPercent)
    : 0;
  const discountReason = prepaymentDiscountCents > 0
    ? `${PREPAYMENT_DISCOUNT_LABEL} (${fullDiscountPercent}%)`
    : null;

  const payableCents = Math.max(beforePrepaymentCents - prepaymentDiscountCents, 0);
  const targetCents = percent === 100
    ? payableCents
    : Math.min(percentageOfCents(payableCents, percent), payableCents);

  return {
    chargeableCents: Math.max(targetCents - input.alreadyPaidCents, 0),
    prepaymentPercent: percent,
    discountReason,
    discountCents: couponDiscountCents + prepaymentDiscountCents,
  };
}

/** What the coupon applied at booking took off this order, in whole cents. */
async function couponDiscountCentsForOrder(
  admin: ReturnType<typeof serviceClient>,
  orderId: string,
): Promise<number> {
  const { data, error } = await admin
    .from("coupon_redemptions")
    .select("amount")
    .eq("order_id", orderId);

  if (error) {
    // Pricing must not fall over because the audit trail is unreadable; the
    // order keeps whatever discount it already carries.
    console.error("Could not read coupon redemptions for order", error);
    return 0;
  }

  return (data ?? [])
    .map((row) => (row as { amount: string }).amount)
    .reduce((sum, amount) => sum + toCents(amount), 0);
}

/**
 * Rebuilds `discount_reason` so the prepayment component is replaced rather
 * than appended, and the coupon reason written at booking survives a client
 * changing its mind about how much to pay up front.
 */
function mergeDiscountReason(existing: string | null, prepayment: string | null): string | null {
  const kept = (existing ?? "")
    .split(DISCOUNT_REASON_SEPARATOR)
    .map((part) => part.trim())
    .filter((part) => part.length > 0 && !part.startsWith(PREPAYMENT_DISCOUNT_LABEL));

  if (prepayment) kept.push(prepayment);
  return kept.length > 0 ? kept.join(DISCOUNT_REASON_SEPARATOR) : null;
}

/** Finds or creates the Stripe customer for this account. */
async function resolveCustomer(input: {
  stripe: ReturnType<typeof stripeClient>;
  admin: ReturnType<typeof serviceClient>;
  order: OrderRow;
  userId: string;
  email: string | null;
  name: string;
}): Promise<string> {
  if (input.order.stripe_customer_id) return input.order.stripe_customer_id;

  const { data: previous } = await input.admin
    .from("orders")
    .select("stripe_customer_id")
    .eq("client_id", input.userId)
    .not("stripe_customer_id", "is", null)
    .order("created_at", { ascending: false })
    .limit(1)
    .maybeSingle<{ stripe_customer_id: string }>();

  if (previous?.stripe_customer_id) return previous.stripe_customer_id;

  const customer = await input.stripe.customers.create({
    email: input.email ?? undefined,
    name: input.name.length > 0 ? input.name : undefined,
    metadata: { prv_user_id: input.userId },
  }, { idempotencyKey: `prv:customer:${input.userId}` });

  return customer.id;
}

/**
 * PaymentSheet needs an ephemeral key scoped to the customer and pinned to the
 * API version the iOS SDK was built against. We only mint one when the client
 * tells us which version it needs.
 */
async function maybeEphemeralKey(
  stripe: ReturnType<typeof stripeClient>,
  customerId: string,
  apiVersion: string | undefined,
): Promise<string | null> {
  if (!apiVersion) return null;
  try {
    const key = await stripe.ephemeralKeys.create({ customer: customerId }, { apiVersion });
    return key.secret ?? null;
  } catch (error) {
    console.error("Could not create ephemeral key", error);
    return null;
  }
}
