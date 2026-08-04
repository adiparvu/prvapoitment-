/**
 * delete-account
 *
 * Erases the calling user's account — the GDPR right-to-erasure endpoint
 * behind `AuthService.deleteAccount()`.
 *
 * This is an Edge Function rather than an RPC because removing an
 * `auth.users` row needs the service role, which a client JWT can never hold.
 * The subject is always taken from the verified JWT and never from the request
 * body, so a caller can only ever erase themselves.
 *
 * Deleting the auth user cascades into `public.profiles` and onward through the
 * schema's foreign keys. Records a business is legally required to retain —
 * invoices and the orders they bill — are pseudonymized instead of removed:
 * `pseudonymize_client_records` clears the personal identifiers while the
 * financial history survives for accounting.
 *
 * Request  {}
 * Response { deleted: true, pseudonymized_records: number }
 */

import { handlePreflight } from "../_shared/cors.ts";
import {
  errorResponse,
  HttpError,
  jsonResponse,
  requireMethod,
} from "../_shared/errors.ts";
import { requireUser } from "../_shared/auth.ts";
import { serviceClient } from "../_shared/supabase.ts";

Deno.serve(async (request: Request) => {
  const preflight = handlePreflight(request);
  if (preflight) return preflight;

  try {
    requireMethod(request, "POST");
    const user = await requireUser(request);
    const admin = serviceClient();

    // Pseudonymize first: once the profile row is gone the client_id links are
    // severed, so retained records must be scrubbed while they still resolve.
    const { data: pseudonymized, error: pseudonymizeError } = await admin.rpc(
      "pseudonymize_client_records",
      { p_user_id: user.id },
    );
    if (pseudonymizeError) {
      throw new HttpError(
        500,
        "erasure_failed",
        `Could not pseudonymize retained records: ${pseudonymizeError.message}`,
      );
    }

    // Written before the actor disappears, so the trail survives the deletion.
    await admin.from("audit_log").insert({
      actor_id: user.id,
      action: "account.delete",
      entity: "auth.users",
      entity_id: user.id,
      detail: "Account erasure requested by the account holder.",
    });

    const { error: deleteError } = await admin.auth.admin.deleteUser(user.id);
    if (deleteError) {
      throw new HttpError(
        500,
        "erasure_failed",
        `Could not delete the account: ${deleteError.message}`,
      );
    }

    return jsonResponse(request, {
      deleted: true,
      pseudonymized_records: typeof pseudonymized === "number" ? pseudonymized : 0,
    });
  } catch (error) {
    return errorResponse(request, error);
  }
});
