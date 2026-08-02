/**
 * Money arithmetic, in whole minor units.
 *
 * `PRVPaymentsKit.MoneyMath` does every calculation in cents with banker's
 * rounding, and never lets a `Double` touch money. This module is the
 * server-side twin of that rule: amounts arrive from Postgres as
 * `numeric(12,2)` strings, are parsed digit-by-digit into integer cents, and
 * stay integers until they are formatted back out.
 *
 * That matters because the client and the server independently compute the
 * same cancellation fee. If one of them rounded half-up and the other half-even
 * they would disagree by a cent on exactly the amounts a customer notices.
 */

/** Parses a `numeric(12,2)` value into whole minor units, exactly. */
export function toCents(value: string | number | null | undefined): number {
  if (value === null || value === undefined) return 0;
  const text = typeof value === "number" ? value.toFixed(2) : value.trim();
  if (text.length === 0) return 0;

  const negative = text.startsWith("-");
  const unsigned = negative ? text.slice(1) : text;
  const [whole, fraction = ""] = unsigned.split(".");

  const wholeCents = Number.parseInt(whole === "" ? "0" : whole, 10) * 100;
  const fractionCents = Number.parseInt(`${fraction}00`.slice(0, 2), 10);

  if (!Number.isFinite(wholeCents) || !Number.isFinite(fractionCents)) {
    throw new Error(`Not a decimal amount: ${value}`);
  }

  const cents = wholeCents + fractionCents;
  return negative ? -cents : cents;
}

/** Formats whole minor units as a fixed-2 decimal string for Postgres. */
export function fromCents(cents: number): string {
  const negative = cents < 0;
  const absolute = Math.abs(Math.trunc(cents));
  const text = `${Math.floor(absolute / 100)}.${String(absolute % 100).padStart(2, "0")}`;
  return negative ? `-${text}` : text;
}

/** Whole minor units as a JavaScript number of major units, for JSON output. */
export function centsToNumber(cents: number): number {
  return Math.trunc(cents) / 100;
}

/**
 * Rounds half to even — the same rule `Decimal.rounded(scale:)` applies with
 * `.bankers` in PRVFoundation. Half-up would drift a cent away from the client
 * on every exact-half amount.
 */
export function bankersRound(value: number): number {
  const floor = Math.floor(value);
  const remainder = value - floor;

  if (Math.abs(remainder - 0.5) < 1e-9) {
    return floor % 2 === 0 ? floor : floor + 1;
  }
  return Math.round(value);
}

/**
 * `Money.percentage(_:)` in cents: applies a 0–100 percentage and
 * banker's-rounds the result to the cent.
 */
export function percentageOfCents(cents: number, percent: number): number {
  const clamped = Math.min(100, Math.max(0, percent));
  return bankersRound((cents * clamped) / 100);
}
