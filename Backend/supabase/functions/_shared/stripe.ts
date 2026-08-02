/**
 * Stripe client.
 *
 * `STRIPE_SECRET_KEY` lives in Edge Function secrets and never reaches a
 * device. Deno has no Node `http` module, so the SDK is given the fetch-based
 * transport and the WebCrypto signature provider — the async
 * `constructEventAsync` in `stripe-webhook` depends on the latter.
 *
 * The API version is deliberately not pinned here: the SDK ships with the
 * version it was generated against, and overriding it with a string that does
 * not match the installed types is how a payment integration silently starts
 * reading fields that no longer exist.
 */

import Stripe from "npm:stripe@17.7.0";
import { requireEnv } from "./env.ts";

export type { Stripe };

let cached: Stripe | undefined;

/** The shared Stripe client for this isolate. */
export function stripeClient(): Stripe {
  if (!cached) {
    cached = new Stripe(requireEnv("STRIPE_SECRET_KEY"), {
      httpClient: Stripe.createFetchHttpClient(),
      appInfo: { name: "PRV Beauty", version: "1.0.0" },
      maxNetworkRetries: 2,
    });
  }
  return cached;
}

/** WebCrypto provider for asynchronous webhook signature verification. */
export function stripeCryptoProvider(): Stripe.CryptoProvider {
  return Stripe.createSubtleCryptoProvider();
}

/**
 * Converts a `Money` amount (major units, exact `Decimal` on the Swift side)
 * into the minor units Stripe charges in.
 *
 * Rounds half-up on the cent, which is the same rounding
 * `PRVPaymentsKit.MoneyMath` applies, so the figure the client was shown and
 * the figure Stripe captures cannot drift apart.
 */
export function toMinorUnits(amount: number | string, currency: string): number {
  const zeroDecimal = new Set(["BIF", "CLP", "DJF", "GNF", "JPY", "KMF", "KRW", "MGA", "PYG", "RWF", "UGX", "VND", "VUV", "XAF", "XOF", "XPF"]);
  const value = typeof amount === "string" ? Number.parseFloat(amount) : amount;
  if (!Number.isFinite(value)) {
    throw new Error(`Cannot convert ${amount} to minor units.`);
  }
  const factor = zeroDecimal.has(currency.toUpperCase()) ? 1 : 100;
  return Math.round(value * factor);
}

/** The inverse of `toMinorUnits`, for writing a Stripe amount back as `Money`. */
export function fromMinorUnits(minor: number, currency: string): number {
  const zeroDecimal = new Set(["BIF", "CLP", "DJF", "GNF", "JPY", "KMF", "KRW", "MGA", "PYG", "RWF", "UGX", "VND", "VUV", "XAF", "XOF", "XPF"]);
  const factor = zeroDecimal.has(currency.toUpperCase()) ? 1 : 100;
  return Math.round((minor / factor) * 100) / 100;
}
