/**
 * Supabase client factories.
 *
 * Two clients, two different trust levels — pick deliberately:
 *
 *   * `serviceClient()` bypasses Row Level Security. Use it only after the
 *     caller has been authorized explicitly, and only for work a client cannot
 *     be trusted to do (writing the wallet ledger, marking an order paid,
 *     reading another user's device tokens to send them a push).
 *
 *   * `userClient(request)` forwards the caller's JWT, so every query runs
 *     under their policies. Prefer it for reads: if RLS would hide a row from
 *     the caller, the function should not see it either. That is what makes
 *     "verify order ownership" free rather than a hand-written check that can
 *     drift from the policy.
 */

import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2.58.0";
import { SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY, SUPABASE_URL } from "./env.ts";
import { HttpError } from "./errors.ts";

const CLIENT_INFO = "prv-beauty-edge/1.0";

/** A privileged client that bypasses RLS. Never expose its key to a device. */
export function serviceClient(): SupabaseClient {
  return createClient(SUPABASE_URL(), SUPABASE_SERVICE_ROLE_KEY(), {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { "x-client-info": CLIENT_INFO } },
  });
}

/** Extracts the bearer token from the Authorization header. */
export function bearerToken(request: Request): string {
  const header = request.headers.get("Authorization") ?? request.headers.get("authorization");
  if (!header) {
    throw HttpError.unauthorized("Missing Authorization header.");
  }
  const [scheme, token] = header.split(" ");
  if (scheme?.toLowerCase() !== "bearer" || !token) {
    throw HttpError.unauthorized("Authorization header must be `Bearer <token>`.");
  }
  return token.trim();
}

/** A client scoped to the caller: every query is subject to their RLS policies. */
export function userClient(request: Request): SupabaseClient {
  const token = bearerToken(request);
  return createClient(SUPABASE_URL(), SUPABASE_ANON_KEY(), {
    auth: { persistSession: false, autoRefreshToken: false },
    global: {
      headers: {
        Authorization: `Bearer ${token}`,
        "x-client-info": CLIENT_INFO,
      },
    },
  });
}
