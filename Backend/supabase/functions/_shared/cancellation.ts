/**
 * Cancellation fees and refund decisions — the server-side mirror of
 * `PRVBookingKit.CancellationEngine` and `PRVPaymentsKit.RefundEngine`.
 *
 * Both are pure: "now" is an input, never `Date.now()` read inside, so the same
 * request resolves the same way on the device, on the salon terminal, and here.
 * That is the whole point — the client quotes a figure before the user taps,
 * and this module has to reach the identical number, to the cent, or the app
 * has lied to someone about money.
 *
 * Arithmetic runs in whole minor units with banker's rounding (see `money.ts`),
 * matching `Money.percentage(_:)` and `MoneyMath.rounded(_:)`.
 */

import { centsToNumber, percentageOfCents } from "./money.ts";

/** Mirrors `CancellationEngine.Trigger`. */
export type Trigger = "client_cancellation" | "no_show" | "salon_cancellation";

/** Mirrors `CancellationAssessment.Outcome`. */
export type Outcome =
  | "within_free_window"
  | "late_cancellation"
  | "no_show"
  | "salon_initiated";

/** Mirrors `SalonPolicies`, narrowed to the fields cancellation depends on. */
export interface CancellationPolicies {
  readonly freeCancellationHours: number;
  readonly lateCancellationFeePercent: number;
  readonly noShowFeePercent: number;
}

/** Mirrors `CancellationAssessment`, in whole minor units. */
export interface CancellationAssessment {
  readonly outcome: Outcome;
  readonly feePercent: number;
  readonly feeCents: number;
  readonly refundDueCents: number;
  readonly isFree: boolean;
  /** Whole minutes to the start; negative once it has begun. */
  readonly minutesUntilStart: number;
}

/** Mirrors `RefundDecision.Outcome`. */
export type RefundOutcome = "nothing_to_refund" | "automatic" | "needs_approval";

/** Mirrors `RefundDecision`, in whole minor units. */
export interface RefundDecision {
  readonly outcome: RefundOutcome;
  readonly refundCents: number;
  readonly retainedCents: number;
  readonly explanation: string;
}

/** `RefundEngine.Policy.standard` — issued without a human up to €250. */
export const AUTOMATIC_REFUND_CEILING_CENTS = 25_000;

/**
 * Applies the salon's cancellation policy.
 *
 * Resolution order, matching `CancellationEngine.assess(...)`:
 *
 *   1. a salon-initiated cancellation is always free and fully refunded;
 *   2. a no-show charges `noShowFeePercent`;
 *   3. a client cancellation at or after the start is treated as a no-show —
 *      the chair was held and lost;
 *   4. a client cancellation at least `freeCancellationHours` before the start
 *      is free, and the boundary itself is inclusive: cancelling exactly 24
 *      hours before a 24-hour policy costs nothing;
 *   5. otherwise `lateCancellationFeePercent` applies.
 *
 * @param paidCents What the client has already paid, in minor units.
 */
export function assessCancellation(input: {
  policies: CancellationPolicies;
  appointmentStart: Date | string | null;
  now: Date;
  paidCents: number;
  trigger: Trigger;
}): CancellationAssessment {
  const start = input.appointmentStart === null
    ? null
    : input.appointmentStart instanceof Date
    ? input.appointmentStart
    : new Date(input.appointmentStart);

  // An appointment with no items has no start; treat it as already begun so a
  // missing span can never silently become a free cancellation.
  const secondsUntilStart = start ? (start.getTime() - input.now.getTime()) / 1000 : 0;
  const minutesUntilStart = Math.trunc(secondsUntilStart / 60);

  let outcome: Outcome;
  let requestedPercent: number;

  switch (input.trigger) {
    case "salon_cancellation":
      outcome = "salon_initiated";
      requestedPercent = 0;
      break;

    case "no_show":
      outcome = "no_show";
      requestedPercent = input.policies.noShowFeePercent;
      break;

    case "client_cancellation": {
      const freeWindowSeconds = Math.max(0, input.policies.freeCancellationHours) * 3600;
      if (secondsUntilStart <= 0) {
        outcome = "no_show";
        requestedPercent = input.policies.noShowFeePercent;
      } else if (secondsUntilStart >= freeWindowSeconds) {
        outcome = "within_free_window";
        requestedPercent = 0;
      } else {
        outcome = "late_cancellation";
        requestedPercent = input.policies.lateCancellationFeePercent;
      }
      break;
    }
  }

  const feePercent = Math.min(100, Math.max(0, requestedPercent));
  const chargeable = Math.max(input.paidCents, 0);
  const feeCents = Math.min(percentageOfCents(chargeable, feePercent), chargeable);

  return {
    outcome,
    feePercent,
    feeCents,
    refundDueCents: chargeable - feeCents,
    isFree: feePercent === 0,
    minutesUntilStart,
  };
}

/**
 * Decides the refund for a cancellation — `RefundEngine.decide(...)` with
 * `reason == .cancellation`, the only reason this path produces.
 *
 * The client gets back what they paid minus the fee, and anything above the
 * automatic ceiling waits for a manager however routine the cancellation was:
 * large money always gets a second pair of eyes.
 */
export function decideRefund(paidCents: number, feeCents: number): RefundDecision {
  const paid = Math.max(paidCents, 0);
  const fee = Math.min(Math.max(feeCents, 0), paid);
  const refundable = Math.max(paid - fee, 0);

  if (refundable === 0) {
    return {
      outcome: "nothing_to_refund",
      refundCents: 0,
      retainedCents: fee,
      explanation: paid === 0
        ? "Nothing was paid on this order."
        : "The retained fee covers everything paid — nothing to refund.",
    };
  }

  if (refundable > AUTOMATIC_REFUND_CEILING_CENTS) {
    return {
      outcome: "needs_approval",
      refundCents: refundable,
      retainedCents: fee,
      explanation:
        `Refunds above ${formatEuros(AUTOMATIC_REFUND_CEILING_CENTS)} are approved by a manager.`,
    };
  }

  return {
    outcome: "automatic",
    refundCents: refundable,
    retainedCents: fee,
    explanation: fee === 0
      ? "Cancelled inside the free window — refunded in full."
      : `Cancellation fee of ${formatEuros(fee)} retained under the salon's policy.`,
  };
}

/** The appointment status a trigger produces. */
export function cancelledStatus(trigger: Trigger): string {
  switch (trigger) {
    case "salon_cancellation":
      return "cancelled_by_salon";
    case "no_show":
      return "no_show";
    case "client_cancellation":
      return "cancelled_by_client";
  }
}

function formatEuros(cents: number): string {
  return `€${centsToNumber(cents).toFixed(2)}`;
}
