/**
 * cancel-appointment
 *
 * Cancels a booking and settles the money, applying exactly the rules the app
 * showed the client before they tapped.
 *
 * The fee calculation below is a line-for-line mirror of
 * `PRVBookingKit.CancellationEngine.assess(policies:appointmentStart:now:amountPaid:trigger:)`,
 * and the refund decision mirrors `PRVPaymentsKit.RefundEngine.decide(...)`.
 * Both are deterministic and take "now" as an input, which is what lets the
 * client quote a figure and the server charge the same figure to the cent —
 * including the banker's rounding, which is why the arithmetic here runs in
 * whole cents rather than on floats.
 *
 * Order of operations, chosen so no state can be lost to a partial failure:
 *
 *   1. assess     — pure arithmetic, no side effects
 *   2. refund     — Stripe first, because a refund we recorded but never issued
 *                   is worse than one we issued but must reconcile
 *   3. persist    — refund row, wallet credit, order status, appointment status
 *   4. audit      — always, whatever the outcome
 *   5. notify     — best effort
 *
 * Request  { appointment_id, reason?, trigger? }
 * Response { appointment, assessment, refund? }
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
import { stripeClient, toMinorUnits } from "../_shared/stripe.ts";
import { centsToNumber, fromCents, toCents } from "../_shared/money.ts";
import { appRoute, createAndFanOut, salonStaffUserIds } from "../_shared/notify.ts";
import {
  assessCancellation,
  cancelledStatus,
  decideRefund,
  type Trigger,
} from "../_shared/cancellation.ts";

interface RequestBody {
  appointment_id?: string;
  reason?: string | null;
  trigger?: Trigger;
}

interface AppointmentRow {
  id: string;
  salon_id: string;
  client_id: string;
  status: string;
  starts_at: string | null;
  order_id: string | null;
  salon_name: string;
  salons: {
    policy_free_cancellation_hours: number;
    policy_late_cancellation_percent: number;
    policy_no_show_percent: number;
  } | null;
}

interface OrderRow {
  id: string;
  amount_paid: string;
  currency: string;
  status: string;
  stripe_payment_intent_id: string | null;
}

const ACTIVE_STATUSES = new Set([
  "pending_confirmation",
  "confirmed",
  "checked_in",
  "in_progress",
]);

Deno.serve(async (request) => {
  const preflight = handlePreflight(request);
  if (preflight) return preflight;

  try {
    requireMethod(request, "POST");
    const user = await requireUser(request);
    const body = await readJson<RequestBody>(request);
    const appointmentId = requireUUID(body.appointment_id, "appointment_id");

    const asUser = userClient(request);
    const { data: appointment, error: loadError } = await asUser
      .from("appointments")
      .select(
        "id, salon_id, client_id, status, starts_at, order_id, salon_name, " +
          "salons!inner(policy_free_cancellation_hours, policy_late_cancellation_percent, policy_no_show_percent)",
      )
      .eq("id", appointmentId)
      .maybeSingle<AppointmentRow>();

    if (loadError) throw fromPostgresError(loadError, "Could not load that appointment.");
    if (!appointment) throw HttpError.notFound("That appointment does not exist.");

    if (!ACTIVE_STATUSES.has(appointment.status)) {
      throw HttpError.conflict(`This appointment is already ${appointment.status.replace(/_/g, " ")}.`);
    }

    const isClient = appointment.client_id === user.id;
    const isStaff = await isSalonMember(user, appointment.salon_id);
    if (!isClient && !isStaff) {
      throw HttpError.forbidden("You cannot cancel this appointment.");
    }

    // A client can only ever cancel as a client. Marking a no-show, or
    // cancelling on the salon's behalf, is a staff action.
    const trigger: Trigger = body.trigger ?? "client_cancellation";
    if (!isStaff && trigger !== "client_cancellation") {
      throw HttpError.forbidden("Only the salon can record a no-show or a salon cancellation.");
    }

    const admin = serviceClient();

    const order = appointment.order_id
      ? (await admin
        .from("orders")
        .select("id, amount_paid, currency, status, stripe_payment_intent_id")
        .eq("id", appointment.order_id)
        .maybeSingle<OrderRow>()).data
      : null;

    const paidCents = toCents(order?.amount_paid ?? "0");
    const currency = (order?.currency ?? "EUR").toUpperCase();

    const assessment = assessCancellation({
      policies: {
        freeCancellationHours: appointment.salons?.policy_free_cancellation_hours ?? 24,
        lateCancellationFeePercent: appointment.salons?.policy_late_cancellation_percent ?? 50,
        noShowFeePercent: appointment.salons?.policy_no_show_percent ?? 100,
      },
      appointmentStart: appointment.starts_at,
      now: new Date(),
      paidCents,
      trigger,
    });

    const decision = decideRefund(paidCents, assessment.feeCents);

    // (2) Money first. An issued-but-unrecorded refund reconciles; a
    // recorded-but-unissued one is a customer who never got paid back.
    let stripeRefundId: string | null = null;
    if (decision.outcome === "automatic" && order?.stripe_payment_intent_id) {
      try {
        const refund = await stripeClient().refunds.create({
          payment_intent: order.stripe_payment_intent_id,
          amount: toMinorUnits(centsToNumber(decision.refundCents), currency),
          reason: "requested_by_customer",
          metadata: {
            appointment_id: appointment.id,
            order_id: order.id,
            outcome: assessment.outcome,
            fee_percent: String(assessment.feePercent),
          },
        }, { idempotencyKey: `prv:refund:${appointment.id}:${decision.refundCents}` });
        stripeRefundId = refund.id;
      } catch (error) {
        // Fall through: the appointment still cancels and the refund is queued
        // for a human rather than silently dropped.
        console.error("Stripe refund failed; queueing for manual review", error);
      }
    }

    // (3) Persist.
    const newStatus = cancelledStatus(trigger);

    const { error: statusError } = await admin
      .from("appointments")
      .update({
        status: newStatus,
        cancelled_at: new Date().toISOString(),
        cancellation_reason: body.reason ?? null,
      })
      .eq("id", appointment.id);

    if (statusError) {
      throw fromPostgresError(statusError, "Could not cancel that appointment.");
    }

    let refundRecordId: string | null = null;
    if (decision.refundCents > 0 && order) {
      const { data: refundRow, error: refundError } = await admin
        .from("refunds")
        .insert({
          order_id: order.id,
          amount: fromCents(decision.refundCents),
          currency,
          reason: "cancellation",
          note: decision.explanation,
          is_automatic: decision.outcome === "automatic" && stripeRefundId !== null,
          stripe_refund_id: stripeRefundId,
          created_by: user.id,
        })
        .select("id")
        .single<{ id: string }>();

      if (refundError) {
        console.error("Could not record refund", refundError);
      } else {
        refundRecordId = refundRow.id;
      }

      if (stripeRefundId) {
        await admin.from("wallet_transactions").insert({
          user_id: appointment.client_id,
          kind: "refund",
          amount: fromCents(decision.refundCents),
          currency,
          title: `Refund — ${appointment.salon_name}`,
          order_id: order.id,
        });

        const remainingPaid = Math.max(paidCents - decision.refundCents, 0);
        await admin
          .from("orders")
          .update({
            amount_paid: fromCents(remainingPaid),
            status: remainingPaid === 0 ? "refunded" : "partially_refunded",
          })
          .eq("id", order.id);
      }
    } else if (order && paidCents === 0) {
      await admin.from("orders").update({ status: "cancelled" }).eq("id", order.id);
    }

    // (4) Audit — unconditional, including the no-money-moved case.
    await admin.from("audit_log").insert({
      actor_id: user.id,
      salon_id: appointment.salon_id,
      action: `appointment.${newStatus}`,
      operation: "update",
      entity: "appointments",
      entity_id: appointment.id,
      detail: decision.explanation,
      metadata: {
        trigger,
        outcome: assessment.outcome,
        fee_percent: assessment.feePercent,
        fee_amount: centsToNumber(assessment.feeCents),
        refund_amount: centsToNumber(decision.refundCents),
        refund_outcome: decision.outcome,
        stripe_refund_id: stripeRefundId,
        minutes_until_start: assessment.minutesUntilStart,
        reason: body.reason ?? null,
      },
    });

    // (5) Notify.
    await announce(admin, {
      appointment,
      actorId: user.id,
      cancelledByStaff: !isClient,
      explanation: decision.explanation,
      refundAmount: centsToNumber(decision.refundCents),
      currency,
    });

    const { data: payload } = await admin.rpc("appointment_payload", {
      p_appointment_id: appointment.id,
    });

    return jsonResponse(request, {
      appointment: payload,
      assessment: {
        outcome: assessment.outcome,
        fee_percent: assessment.feePercent,
        fee: { amount: centsToNumber(assessment.feeCents), currency },
        refund_due: { amount: centsToNumber(assessment.refundDueCents), currency },
        is_free: assessment.isFree,
        minutes_until_start: assessment.minutesUntilStart,
      },
      refund: decision.refundCents === 0 ? null : {
        id: refundRecordId,
        outcome: decision.outcome,
        amount: { amount: centsToNumber(decision.refundCents), currency },
        retained_fee: { amount: centsToNumber(decision.retainedCents), currency },
        explanation: decision.explanation,
        issued: stripeRefundId !== null,
        requires_approval: decision.outcome === "needs_approval",
      },
    });
  } catch (error) {
    return errorResponse(request, error);
  }
});

// -----------------------------------------------------------------------------

async function announce(
  admin: ReturnType<typeof serviceClient>,
  input: {
    appointment: AppointmentRow;
    actorId: string;
    cancelledByStaff: boolean;
    explanation: string;
    refundAmount: number;
    currency: string;
  },
): Promise<void> {
  const refundLine = input.refundAmount > 0
    ? ` A refund of €${input.refundAmount.toFixed(2)} is on its way.`
    : "";

  try {
    await createAndFanOut(admin, {
      userIds: [input.appointment.client_id],
      kind: "appointment_cancelled",
      title: input.cancelledByStaff ? "Your appointment was cancelled" : "Appointment cancelled",
      body: `${input.appointment.salon_name}: ${input.explanation}${refundLine}`,
      route: appRoute("appointment", input.appointment.id),
      collapseId: `appointment-${input.appointment.id}`,
      data: { appointment_id: input.appointment.id },
    });
  } catch (error) {
    console.error("Client cancellation notification failed", error);
  }

  try {
    const staff = (await salonStaffUserIds(admin, input.appointment.salon_id))
      .filter((id) => id !== input.actorId);
    if (staff.length > 0) {
      await createAndFanOut(admin, {
        userIds: staff,
        kind: "system",
        title: "Booking cancelled",
        body: input.explanation,
        route: appRoute("appointment", input.appointment.id),
        collapseId: `appointment-${input.appointment.id}`,
        data: { appointment_id: input.appointment.id },
      });
    }
  } catch (error) {
    console.error("Salon cancellation notification failed", error);
  }
}
