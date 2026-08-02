/**
 * CORS.
 *
 * The iOS app is not a browser and sends no `Origin`, so these headers exist
 * for the web dashboard and for local tooling. The allow-list is read from
 * `ALLOWED_ORIGINS` (comma-separated); with nothing configured we echo `*`,
 * which is safe here because every function authenticates with a bearer token
 * rather than a cookie — there is no ambient authority for a hostile page to
 * ride on.
 */

import { optionalEnv } from "./env.ts";

const ALLOWED_HEADERS = [
  "authorization",
  "x-client-info",
  "apikey",
  "content-type",
  "x-prv-idempotency-key",
  "stripe-signature",
].join(", ");

function allowedOrigins(): string[] {
  return (optionalEnv("ALLOWED_ORIGINS") ?? "")
    .split(",")
    .map((value) => value.trim())
    .filter((value) => value.length > 0);
}

/** The CORS headers to attach to a response for `request`. */
export function corsHeaders(request: Request): Record<string, string> {
  const configured = allowedOrigins();
  const origin = request.headers.get("origin");

  let allowOrigin = "*";
  if (configured.length > 0) {
    allowOrigin = origin !== null && configured.includes(origin) ? origin : configured[0];
  }

  return {
    "access-control-allow-origin": allowOrigin,
    "access-control-allow-headers": ALLOWED_HEADERS,
    "access-control-allow-methods": "POST, OPTIONS",
    "access-control-max-age": "86400",
    ...(configured.length > 0 ? { vary: "Origin" } : {}),
  };
}

/**
 * Answers a CORS preflight. Returns `null` when the request is not a preflight,
 * so a handler can `const preflight = handlePreflight(req); if (preflight) return preflight;`.
 */
export function handlePreflight(request: Request): Response | null {
  if (request.method !== "OPTIONS") return null;
  return new Response(null, { status: 204, headers: corsHeaders(request) });
}
