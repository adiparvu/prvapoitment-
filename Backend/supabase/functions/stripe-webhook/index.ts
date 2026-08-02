/**
 * stripe-webhook
 *
 * The only place an order becomes paid.
 *
 * The client is never trusted to report a successful payment — it can be
 * killed mid-flight, it can lie, and its "success" screen is cosmetic. Stripe
 * tells us, over a signed request, and this function is what moves the money
 * into our own ledger.
 *
 * Three invariants:
 *
 *   1. **Signature first.** The raw body is verified against
 *      `STRIPE_WEBHOOK_SECRET` with `constructEventAsync` before a single field
 *      is read. An unverified payload is discarded with 400 — a forged
 *      "payment succeeded" must never reach the database.
 *   2. **Idempotent by state, not by luck.** Stripe retries, and delivers at
 *      least once. `payment_intent.succeeded` is a no-op once the order is
 *      `paid`; refunds are keyed on the unique `refunds.stripe_refund_id`
 *      index, so a replay conflicts instead of double-crediting.
 *   3. **Always answer 2xx once verified.** A 5xx makes Stripe retry, which for
 *      a genuine bug turns one failure into a storm. Handler errors are logged
 *      and acknowledged; the reconciliation job picks up the difference.
 *
 * This function runs with `verify_jwt = false` (see config.toml) because Stripe
 * has no Supabase session. The Stripe signature is the authentication.
 */

import type { SupabaseClient } from "npm:@supabase/supabase-js@2.58.0";
import { serviceClient } from "../_shared/supabase.ts";
import { fromMinorUnits, stripeClient, stripeCryptoProvider, type Stripe } from "../_shared/stripe.ts";
import { requireEnv } from "../_shared/env.ts";
import { centsToNumber, fromCents, percentageOfCents, toCents } from "../_shared/money.ts";
import { appRoute, createAndFanOut } from "../_shared/notify.ts";

interface OrderRow {
  id: string;
  salon_id: string;
  client_id: string;
  appointment_id: string | null;
  status: string;
  currency: string;
  amount_paid: string;
  points_earned: number;
  stripe_payment_intent_id: string | null;
}

Deno.serve(async (request) => {
  if (request.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }

  const signature = request.headers.get("stripe-signature");
  if (!signature) {
    return new Response("Missing stripe-signature header", { status: 400 });
  }

  // The raw bytes matter: any re-serialization breaks the signature.
  const payload = await request.text();

  let event: Stripe.Event;
  try {
    event = await stripeClient().webhooks.constructEventAsync(
      payload,
      signature,
      requireEnv("STRIPE_WEBHOOK_SECRET"),
      undefined,
      stripeCryptoProvider(),
    );
  } catch (error) {
    console.error("Stripe signature verification failed", error);
    return new Response("Invalid signature", { status: 400 });
  }

  const admin = serviceClient();

  try {
    switch (event.type) {
      case "payment_intent.succeeded":
        await handlePaymentSucceeded(admin, event.data.object as Stripe.PaymentIntent);
        break;

      case "payment_intent.payment_failed":
        await handlePaymentFailed(admin, event.data.object as Stripe.PaymentIntent);
        break;

      case "charge.refunded":
        await handleChargeRefunded(admin, event.data.object as Stripe.Charge);
        break;

      default:
        // Acknowledged and ignored — subscribing to more event types than we
        // handle is normal, and 2xx keeps Stripe from retrying them forever.
        break;
    }
  } catch (error) {
    // Verified but unhandled: log loudly, acknowledge anyway. A retry storm on
    // top of a bug helps nobody, and every state change here is recoverable
    // from Stripe's own records.
    console.error(`Handler failed for ${event.type} (${event.id})`, error);
  }

  return new Response(JSON.stringify({ received: true, event: event.type }), {
    status: 200,
    headers: { "content-type": "application/json" },
  });
});

// -----------------------------------------------------------------------------
// payment_intent.succeeded
// -----------------------------------------------------------------------------

/**
 * Marks the order paid, credits Beauty Wallet cashback, awards loyalty XP, and
 * confirms the appointment the order was holding.
 *
 * Every step is derived from Stripe's own numbers (`amount_received`), never
 * from anything the client sent.
 */
async function handlePaymentSucceeded(
  admin: SupabaseClient,
  intent: Stripe.PaymentIntent,
): Promise<void> {
  const order = await resolveOrder(admin, intent);
  if (!order) {
    console.error(`No order for payment intent ${intent.id}`);
    return;
  }

  // Idempotency: a replayed success on a settled order changes nothing.
  if (order.status === "paid") {
    console.log(`Order ${order.id} already paid; ignoring replay of ${intent.id}.`);
    return;
  }

  const currency = order.currency.toUpperCase();
  const receivedCents = Math.round(
    fromMinorUnits(intent.amount_received, currency) * 100,
  );
  const alreadyPaidCents = toCents(order.amount_paid);
  const paidCents = alreadyPaidCents + receivedCents;

  const { data: totals } = await admin
    .from("order_totals")
    .select("total_amount")
    .eq("order_id", order.id)
    .maybeSingle<{ total_amount: string }>();

  const totalCents = toCents(totals?.total_amount ?? "0");
  const settled = totalCents > 0 && paidCents >= totalCents;

  const { data: policy } = await admin
    .from("prepayment_policies")
    .select("cashback_percent, reward_points_multiplier")
    .eq("salon_id", order.salon_id)
    .maybeSingle<{ cashback_percent: number; reward_points_multiplier: number }>();

  // Prepaying in full is what earns the multiplier, exactly as the booking
  // flow promised when the client chose it.
  const prepaidInFull = intent.metadata?.prepayment_percent === "100";
  const multiplier = prepaidInFull ? (policy?.reward_points_multiplier ?? 1) : 1;
  const wholeMajorUnits = Math.floor(receivedCents / 100);
  const xpAwarded = wholeMajorUnits;
  const pointsAwarded = wholeMajorUnits * multiplier;

  const { error: orderError } = await admin
    .from("orders")
    .update({
      amount_paid: fromCents(paidCents),
      status: settled ? "paid" : "partially_paid",
      paid_at: settled ? new Date().toISOString() : null,
      points_earned: order.points_earned + pointsAwarded,
      stripe_payment_intent_id: intent.id,
    })
    .eq("id", order.id);

  if (orderError) {
    throw new Error(`Could not settle order ${order.id}: ${orderError.message}`);
  }

  await admin.from("wallet_transactions").insert({
    user_id: order.client_id,
    kind: "payment",
    // Negative: money left the client.
    amount: fromCents(-receivedCents),
    currency,
    title: `Payment — order ${order.id.slice(0, 8)}`,
    order_id: order.id,
  });

  const cashbackCents = percentageOfCents(receivedCents, policy?.cashback_percent ?? 0);
  if (cashbackCents > 0) {
    await admin.from("wallet_transactions").insert({
      user_id: order.client_id,
      kind: "cashback",
      amount: fromCents(cashbackCents),
      currency,
      title: `Beauty Wallet cashback (${policy?.cashback_percent}%)`,
      order_id: order.id,
    });
  }

  if (xpAwarded > 0 || pointsAwarded > 0) {
    const { error: loyaltyError } = await admin.rpc("award_loyalty_xp", {
      p_user: order.client_id,
      p_xp: xpAwarded,
      p_points: pointsAwarded,
    });
    if (loyaltyError) console.error("Could not award loyalty XP", loyaltyError);
  }

  // A prepayment-gated booking becomes real the moment the deposit lands.
  if (settled && order.appointment_id) {
    const { data: appointment } = await admin
      .from("appointments")
      .select("id, status, salon_name")
      .eq("id", order.appointment_id)
      .maybeSingle<{ id: string; status: string; salon_name: string }>();

    if (appointment?.status === "pending_confirmation") {
      await admin
        .from("appointments")
        .update({ status: "confirmed" })
        .eq("id", appointment.id);
    }
  }

  await admin.from("audit_log").insert({
    actor_id: null,
    salon_id: order.salon_id,
    action: "order.paid",
    operation: "update",
    entity: "orders",
    entity_id: order.id,
    detail: `Stripe payment ${intent.id} received.`,
    metadata: {
      stripe_payment_intent_id: intent.id,
      amount: centsToNumber(receivedCents),
      currency,
      cashback: centsToNumber(cashbackCents),
      xp_awarded: xpAwarded,
      points_awarded: pointsAwarded,
      settled,
    },
  });

  try {
    await createAndFanOut(admin, {
      userIds: [order.client_id],
      kind: settled ? "appointment_confirmed" : "system",
      title: settled ? "Payment received" : "Deposit received",
      body: settled
        ? `Thank you — €${centsToNumber(receivedCents).toFixed(2)} paid.${
          cashbackCents > 0 ? ` €${centsToNumber(cashbackCents).toFixed(2)} cashback added to your wallet.` : ""
        }`
        : `€${centsToNumber(receivedCents).toFixed(2)} received. The balance is due at your visit.`,
      route: order.appointment_id
        ? appRoute("appointment", order.appointment_id)
        : appRoute("wallet"),
      collapseId: `order-${order.id}`,
      data: { order_id: order.id },
    });
  } catch (error) {
    console.error("Payment notification failed", error);
  }
}

// -----------------------------------------------------------------------------
// payment_intent.payment_failed
// -----------------------------------------------------------------------------

async function handlePaymentFailed(
  admin: SupabaseClient,
  intent: Stripe.PaymentIntent,
): Promise<void> {
  const order = await resolveOrder(admin, intent);
  if (!order || order.status === "paid") return;

  await admin.from("orders").update({ status: "failed" }).eq("id", order.id);

  try {
    await createAndFanOut(admin, {
      userIds: [order.client_id],
      kind: "system",
      title: "Payment did not go through",
      body: intent.last_payment_error?.message ??
        "Your card was declined. Try another payment method to keep your slot.",
      route: appRoute("checkout", order.id),
      collapseId: `order-${order.id}`,
      data: { order_id: order.id },
    });
  } catch (error) {
    console.error("Payment-failure notification failed", error);
  }
}

// -----------------------------------------------------------------------------
// charge.refunded
// -----------------------------------------------------------------------------

/**
 * Records refunds issued anywhere — this function, the Stripe dashboard, or a
 * dispute — and puts the money back on the client's wallet.
 *
 * Refunds are listed from the API rather than read off the charge, because the
 * embedded `refunds` list is not expanded on webhook payloads. Each one is
 * inserted against the unique `stripe_refund_id` index: a replay conflicts and
 * is skipped instead of crediting twice.
 */
async function handleChargeRefunded(
  admin: SupabaseClient,
  charge: Stripe.Charge,
): Promise<void> {
  const paymentIntentId = typeof charge.payment_intent === "string"
    ? charge.payment_intent
    : charge.payment_intent?.id;

  if (!paymentIntentId) {
    console.error(`Charge ${charge.id} has no payment intent; cannot resolve an order.`);
    return;
  }

  const { data: order } = await admin
    .from("orders")
    .select(
      "id, salon_id, client_id, appointment_id, status, currency, amount_paid, points_earned, stripe_payment_intent_id",
    )
    .eq("stripe_payment_intent_id", paymentIntentId)
    .maybeSingle<OrderRow>();

  if (!order) {
    console.error(`No order for refunded charge ${charge.id}`);
    return;
  }

  const currency = order.currency.toUpperCase();
  const refunds = await stripeClient().refunds.list({ charge: charge.id, limit: 100 });

  let newlyRecordedCents = 0;

  for (const refund of refunds.data) {
    if (refund.status !== "succeeded") continue;

    const amountCents = Math.round(fromMinorUnits(refund.amount, currency) * 100);

    const { error } = await admin.from("refunds").insert({
      order_id: order.id,
      amount: fromCents(amountCents),
      currency,
      reason: mapRefundReason(refund.reason),
      note: "Recorded from Stripe webhook.",
      is_automatic: true,
      stripe_refund_id: refund.id,
    });

    if (error) {
      // 23505 = we already recorded this one. Anything else is worth seeing.
      if (error.code !== "23505") {
        console.error(`Could not record refund ${refund.id}`, error);
      }
      continue;
    }

    newlyRecordedCents += amountCents;

    await admin.from("wallet_transactions").insert({
      user_id: order.client_id,
      kind: "refund",
      amount: fromCents(amountCents),
      currency,
      title: `Refund — order ${order.id.slice(0, 8)}`,
      order_id: order.id,
    });
  }

  // Stripe's totals are authoritative for what is left paid on the charge.
  const capturedCents = Math.round(fromMinorUnits(charge.amount_captured, currency) * 100);
  const refundedCents = Math.round(fromMinorUnits(charge.amount_refunded, currency) * 100);
  const remainingCents = Math.max(capturedCents - refundedCents, 0);

  await admin
    .from("orders")
    .update({
      amount_paid: fromCents(remainingCents),
      status: remainingCents === 0 ? "refunded" : "partially_refunded",
    })
    .eq("id", order.id);

  await admin.from("audit_log").insert({
    actor_id: null,
    salon_id: order.salon_id,
    action: remainingCents === 0 ? "order.refunded" : "order.partially_refunded",
    operation: "update",
    entity: "orders",
    entity_id: order.id,
    detail: `Stripe charge ${charge.id} refunded.`,
    metadata: {
      stripe_charge_id: charge.id,
      refunded_total: centsToNumber(refundedCents),
      newly_recorded: centsToNumber(newlyRecordedCents),
      currency,
    },
  });

  if (newlyRecordedCents > 0) {
    try {
      await createAndFanOut(admin, {
        userIds: [order.client_id],
        kind: "system",
        title: "Refund issued",
        body: `€${centsToNumber(newlyRecordedCents).toFixed(2)} is on its way back to your original payment method.`,
        route: appRoute("wallet"),
        collapseId: `order-${order.id}`,
        data: { order_id: order.id },
      });
    } catch (error) {
      console.error("Refund notification failed", error);
    }
  }
}

// -----------------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------------

/**
 * Finds the order behind a PaymentIntent. `metadata.order_id` is set when we
 * create the intent; the stored intent id is the fallback for intents created
 * elsewhere (a Stripe dashboard charge, a legacy flow).
 */
async function resolveOrder(
  admin: SupabaseClient,
  intent: Stripe.PaymentIntent,
): Promise<OrderRow | null> {
  const columns =
    "id, salon_id, client_id, appointment_id, status, currency, amount_paid, points_earned, stripe_payment_intent_id";

  const orderId = intent.metadata?.order_id;
  if (orderId) {
    const { data } = await admin
      .from("orders")
      .select(columns)
      .eq("id", orderId)
      .maybeSingle<OrderRow>();
    if (data) return data;
  }

  const { data } = await admin
    .from("orders")
    .select(columns)
    .eq("stripe_payment_intent_id", intent.id)
    .maybeSingle<OrderRow>();

  return data ?? null;
}

/** Maps Stripe's refund reason onto `Refund.Reason`. */
function mapRefundReason(reason: Stripe.Refund["reason"]): string {
  switch (reason) {
    case "duplicate":
      return "duplicate";
    case "fraudulent":
      return "fraud";
    case "requested_by_customer":
      return "cancellation";
    default:
      return "goodwill";
  }
}
