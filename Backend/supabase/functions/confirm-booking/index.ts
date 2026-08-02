/**
 * confirm-booking
 *
 * The write path for `AppointmentRepository.book(_:)`. Accepts a
 * `BookingRequest` exactly as Swift encodes it (snake_case, ISO-8601 dates),
 * hands it to the `book_appointment` RPC, and returns an `Appointment` the
 * client can decode without a translation layer.
 *
 * The slot check is not done here. It is done inside the RPC, in the same
 * transaction as the insert, behind an advisory lock and an exclusion
 * constraint — a check performed in this function would be a check performed
 * before the write, which is exactly the race that double-books a chair.
 *
 * After the booking commits: the client is told it is confirmed, the salon is
 * told a booking came in, and both get a push. Those are best-effort — a push
 * that fails never rolls back a confirmed appointment.
 *
 * Request  BookingRequest (see PRVModels/Booking.swift)
 * Response Appointment (see PRVModels/Appointment.swift)
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
import { isSalonMember, requireUser } from "../_shared/auth.ts";
import { serviceClient, userClient } from "../_shared/supabase.ts";
import { fromCents, percentageOfCents, toCents } from "../_shared/money.ts";
import { appRoute, createAndFanOut, salonStaffUserIds } from "../_shared/notify.ts";

interface BookingItem {
  service_id?: string;
  professional_id?: string | null;
  add_on_ids?: string[];
}

interface BookingRequestBody {
  salon_id?: string;
  client_id?: string;
  items?: BookingItem[];
  slot?: { start?: string; end?: string; professional_id?: string | null };
  additional_client_ids?: string[];
  recurrence?: { frequency?: string; occurrences?: number | null } | null;
  notes?: string | null;
  prepayment_percent?: number | null;
  coupon_code?: string | null;
}

/** Mirrors the columns of `coupons` that decide what a code is worth. */
interface CouponRow {
  id: string;
  code: string;
  discount_kind: "percent" | "fixed";
  discount_percent: number | null;
  discount_amount: string | null;
  minimum_spend_amount: string | null;
}

/** A coupon that applies, priced against this order. */
interface AppliedCoupon {
  readonly id: string;
  readonly code: string;
  readonly discountCents: number;
}

interface AppointmentPayload {
  id: string;
  salon_id: string;
  salon_name: string;
  client_id: string;
  status: string;
  order_id: string | null;
  items: Array<{
    id: string;
    service_id: string;
    service_name: string;
    professional_name: string | null;
    start: string;
    duration_minutes: number;
    price: { amount: number; currency: string };
  }>;
}

Deno.serve(async (request) => {
  const preflight = handlePreflight(request);
  if (preflight) return preflight;

  try {
    requireMethod(request, "POST");
    const user = await requireUser(request);
    const body = await readJson<BookingRequestBody>(request);

    const salonId = requireUUID(body.salon_id, "salon_id");
    const clientId = requireUUID(body.client_id, "client_id");

    if (!Array.isArray(body.items) || body.items.length === 0) {
      throw HttpError.badRequest("`items` must contain at least one service.");
    }
    if (!body.slot?.start) {
      throw HttpError.badRequest("`slot.start` is required.");
    }
    if (Number.isNaN(Date.parse(body.slot.start))) {
      throw HttpError.badRequest("`slot.start` must be an ISO-8601 instant.");
    }
    for (const [index, item] of body.items.entries()) {
      requireUUID(item.service_id, `items[${index}].service_id`);
    }

    // Booking on someone else's behalf is a salon-staff action.
    if (clientId !== user.id && !(await isSalonMember(user, salonId))) {
      throw HttpError.forbidden("You can only book for yourself.");
    }

    // The RPC runs with the caller's JWT so it re-authorizes independently of
    // the check above — belt and braces, and it keeps the SQL usable directly.
    const asUser = userClient(request);
    const { data, error } = await asUser.rpc("book_appointment", { p_request: body });

    if (error) {
      throw fromPostgresError(error, "That booking could not be completed.");
    }
    if (!data) {
      throw HttpError.upstream("The booking service returned nothing.");
    }

    let appointment = data as AppointmentPayload;
    const admin = serviceClient();

    // A visit that needs money up front gets its order now, so the client can
    // go straight from "booked" into checkout without another round trip.
    const wantsPrepayment = typeof body.prepayment_percent === "number" &&
      body.prepayment_percent > 0;
    const isPending = appointment.status === "pending_confirmation";

    if (wantsPrepayment || isPending) {
      const orderId = await createOrderForAppointment(admin, appointment, body.coupon_code ?? null);
      if (orderId) {
        const { data: refreshed } = await admin.rpc("appointment_payload", {
          p_appointment_id: appointment.id,
        });
        if (refreshed) appointment = refreshed as AppointmentPayload;
      }
    }

    await announce(admin, appointment, user.id);

    return jsonResponse(request, appointment, 201);
  } catch (error) {
    return errorResponse(request, error);
  }
});

/**
 * Creates the payable order for a freshly booked appointment and links it back.
 * Returns the order id, or `null` when the order could not be created — a
 * failure here must not undo a confirmed booking, so it is logged and reported
 * rather than thrown.
 *
 * A coupon becomes money here, not a label: `orders.discount_amount` is what
 * `order_totals.total_amount` subtracts, so a code recorded only in
 * `discount_reason` would still bill the client the full price.
 */
async function createOrderForAppointment(
  admin: ReturnType<typeof serviceClient>,
  appointment: AppointmentPayload,
  couponCode: string | null,
): Promise<string | null> {
  if (appointment.order_id) return appointment.order_id;
  if (appointment.items.length === 0) return null;

  const currency = appointment.items[0].price.currency;
  const subtotalCents = appointment.items.reduce(
    (sum, item) => sum + toCents(item.price.amount),
    0,
  );

  const coupon = couponCode
    ? await resolveCoupon(admin, appointment.salon_id, couponCode, subtotalCents)
    : null;

  const { data: order, error: orderError } = await admin
    .from("orders")
    .insert({
      salon_id: appointment.salon_id,
      client_id: appointment.client_id,
      appointment_id: appointment.id,
      status: "awaiting_payment",
      currency,
      discount_amount: fromCents(coupon?.discountCents ?? 0),
      discount_reason: coupon ? `Coupon ${coupon.code}` : null,
    })
    .select("id")
    .single<{ id: string }>();

  if (orderError || !order) {
    console.error("Could not create order for appointment", orderError);
    return null;
  }

  const { error: linesError } = await admin.from("order_lines").insert(
    appointment.items.map((item, index) => ({
      order_id: order.id,
      kind: "service",
      title: item.service_name,
      quantity: 1,
      unit_price: item.price.amount,
      currency: item.price.currency,
      reference_id: item.service_id,
      position: index,
    })),
  );

  if (linesError) {
    console.error("Could not create order lines; rolling the order back", linesError);
    await admin.from("orders").delete().eq("id", order.id);
    return null;
  }

  if (coupon) await recordRedemption(admin, coupon, order.id, appointment.client_id, currency);

  const { error: linkError } = await admin
    .from("appointments")
    .update({ order_id: order.id })
    .eq("id", appointment.id);

  if (linkError) console.error("Could not link order to appointment", linkError);

  return order.id;
}

/**
 * Prices a coupon against the order subtotal, mirroring
 * `PRVPaymentsKit.PricingEngine.evaluate(coupon:subtotal:…)`: whole cents,
 * banker's rounding on a percentage, a fixed amount clamped to the subtotal,
 * and nothing at all below the minimum spend.
 *
 * `book_appointment` has already refused the booking if the code is unknown,
 * inactive, outside its window, or exhausted, so a miss here means the coupon
 * simply does not apply to this basket — the booking stands, at full price.
 */
async function resolveCoupon(
  admin: ReturnType<typeof serviceClient>,
  salonId: string,
  couponCode: string,
  subtotalCents: number,
): Promise<AppliedCoupon | null> {
  const wanted = couponCode.trim().toUpperCase();
  if (wanted.length === 0) return null;

  // `coupons` is unique on `(salon_id, upper(code))`, which PostgREST cannot
  // filter on directly, so the salon's active codes are matched here instead.
  const { data, error } = await admin
    .from("coupons")
    .select("id, code, discount_kind, discount_percent, discount_amount, minimum_spend_amount")
    .eq("salon_id", salonId)
    .eq("is_active", true);

  if (error) {
    console.error("Could not load coupons for salon", error);
    return null;
  }

  const coupon = (data ?? [])
    .map((row) => row as CouponRow)
    .find((row) => row.code.trim().toUpperCase() === wanted);
  if (!coupon) return null;

  const minimumSpendCents = toCents(coupon.minimum_spend_amount);
  if (minimumSpendCents > 0 && subtotalCents < minimumSpendCents) return null;

  const rawCents = coupon.discount_kind === "percent"
    ? percentageOfCents(subtotalCents, coupon.discount_percent ?? 0)
    : Math.max(toCents(coupon.discount_amount), 0);
  const discountCents = Math.min(rawCents, subtotalCents);

  if (discountCents <= 0) return null;
  return { id: coupon.id, code: wanted, discountCents };
}

/**
 * Writes the redemption row. `coupons.redemption_count` is maintained by a
 * trigger on this table, so an unrecorded redemption is an uncapped coupon —
 * and a discount with no audit trail. If the row cannot be written the discount
 * is withdrawn rather than left half-applied.
 */
async function recordRedemption(
  admin: ReturnType<typeof serviceClient>,
  coupon: AppliedCoupon,
  orderId: string,
  clientId: string,
  currency: string,
): Promise<void> {
  const { error } = await admin.from("coupon_redemptions").insert({
    coupon_id: coupon.id,
    user_id: clientId,
    order_id: orderId,
    amount: fromCents(coupon.discountCents),
    currency,
  });

  if (!error) return;

  console.error("Could not record coupon redemption; withdrawing the discount", error);
  const { error: revertError } = await admin
    .from("orders")
    .update({ discount_amount: fromCents(0), discount_reason: null })
    .eq("id", orderId);

  if (revertError) console.error("Could not withdraw the coupon discount", revertError);
}

/**
 * Tells the client and the salon. Deliberately non-fatal: the appointment is
 * already committed, and a notification outage is not a booking failure.
 */
async function announce(
  admin: ReturnType<typeof serviceClient>,
  appointment: AppointmentPayload,
  actorId: string,
): Promise<void> {
  const first = appointment.items[0];
  const when = first
    ? new Date(first.start).toLocaleString("en-GB", {
      weekday: "long",
      day: "numeric",
      month: "long",
      hour: "2-digit",
      minute: "2-digit",
      timeZone: "UTC",
    })
    : "your chosen time";

  const serviceSummary = appointment.items.map((item) => item.service_name).join(", ");
  const isPending = appointment.status === "pending_confirmation";

  try {
    await createAndFanOut(admin, {
      userIds: [appointment.client_id],
      kind: isPending ? "appointment_reminder" : "appointment_confirmed",
      title: isPending ? "Almost booked" : "Your appointment is confirmed",
      body: isPending
        ? `${serviceSummary} at ${appointment.salon_name} on ${when} — complete your deposit to secure it.`
        : `${serviceSummary} at ${appointment.salon_name} on ${when}.`,
      route: appRoute("appointment", appointment.id),
      collapseId: `appointment-${appointment.id}`,
      data: { appointment_id: appointment.id, salon_id: appointment.salon_id },
    });
  } catch (error) {
    console.error("Client notification failed", error);
  }

  try {
    const staff = (await salonStaffUserIds(admin, appointment.salon_id))
      .filter((id) => id !== actorId);

    if (staff.length > 0) {
      await createAndFanOut(admin, {
        userIds: staff,
        kind: "system",
        title: "New booking",
        body: `${serviceSummary} on ${when}${
          first?.professional_name ? ` with ${first.professional_name}` : ""
        }.`,
        route: appRoute("appointment", appointment.id),
        collapseId: `appointment-${appointment.id}`,
        data: { appointment_id: appointment.id, salon_id: appointment.salon_id },
      });
    }
  } catch (error) {
    console.error("Salon notification failed", error);
  }
}
