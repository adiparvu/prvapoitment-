/**
 * notify-fanout
 *
 * Creates notification rows and pushes them to every registered device.
 * Everything that notifies a user goes through here or through
 * `_shared/notify.ts`, so there is exactly one place where "who may notify
 * whom" is decided:
 *
 *   * anyone may notify themselves (the path the app uses to test its own
 *     push registration);
 *   * salon staff may notify their own clients and colleagues, scoped by
 *     `salon_id` and gated on `manageMarketing` for promotional sends;
 *   * platform admins may notify anyone.
 *
 * Delivery is best effort and reported honestly: the durable in-app rows are
 * written first, so a user never loses a notification because Apple was
 * unreachable.
 *
 * Request  { user_ids | user_id, kind, title, body, route?, data?, collapse_id?, silent?, salon_id? }
 * Response { notifications_created, pushes_attempted, pushes_delivered, tokens_pruned }
 */

import { handlePreflight } from "../_shared/cors.ts";
import {
  errorResponse,
  HttpError,
  jsonResponse,
  readJson,
  requireMethod,
  requireUUID,
} from "../_shared/errors.ts";
import { hasPermission, isSalonMember, requireUser } from "../_shared/auth.ts";
import { serviceClient } from "../_shared/supabase.ts";
import { createAndFanOut, type NotificationKind } from "../_shared/notify.ts";

const VALID_KINDS: ReadonlySet<string> = new Set([
  "appointment_reminder",
  "appointment_confirmed",
  "appointment_cancelled",
  "waitlist_slot_opened",
  "promotion",
  "review_request",
  "membership_renewal",
  "package_expiring",
  "price_change",
  "loyalty_reward",
  "chat_message",
  "system",
]);

/** Kinds that are marketing, and therefore need `manageMarketing`. */
const PROMOTIONAL_KINDS: ReadonlySet<string> = new Set(["promotion", "price_change"]);

/** One request may not blast the whole customer base; campaigns batch. */
const MAX_RECIPIENTS = 500;

interface RequestBody {
  user_id?: string;
  user_ids?: string[];
  kind?: string;
  title?: string;
  body?: string;
  route?: Record<string, unknown> | null;
  data?: Record<string, unknown>;
  collapse_id?: string;
  silent?: boolean;
  /** Required when notifying anyone other than yourself. */
  salon_id?: string;
}

Deno.serve(async (request) => {
  const preflight = handlePreflight(request);
  if (preflight) return preflight;

  try {
    requireMethod(request, "POST");
    const user = await requireUser(request);
    const body = await readJson<RequestBody>(request);

    const recipients = [
      ...new Set([
        ...(body.user_id ? [body.user_id] : []),
        ...(Array.isArray(body.user_ids) ? body.user_ids : []),
      ]),
    ];

    if (recipients.length === 0) {
      throw HttpError.badRequest("Provide `user_id` or a non-empty `user_ids`.");
    }
    if (recipients.length > MAX_RECIPIENTS) {
      throw HttpError.badRequest(
        `At most ${MAX_RECIPIENTS} recipients per request — send campaigns in batches.`,
      );
    }
    recipients.forEach((id, index) => requireUUID(id, `user_ids[${index}]`));

    const kind = body.kind ?? "system";
    if (!VALID_KINDS.has(kind)) {
      throw HttpError.badRequest(`\`kind\` must be one of: ${[...VALID_KINDS].join(", ")}.`);
    }

    const title = (body.title ?? "").trim();
    const message = (body.body ?? "").trim();
    if (title.length === 0) throw HttpError.badRequest("`title` is required.");
    if (title.length > 120) throw HttpError.badRequest("`title` must be 120 characters or fewer.");
    if (message.length > 1000) throw HttpError.badRequest("`body` must be 1000 characters or fewer.");

    const notifyingOthers = recipients.some((id) => id !== user.id);
    if (notifyingOthers) {
      await authorizeBroadcast(user, body, kind, recipients);
    }

    const result = await createAndFanOut(serviceClient(), {
      userIds: recipients,
      kind: kind as NotificationKind,
      title,
      body: message,
      route: body.route ?? null,
      data: body.data,
      collapseId: body.collapse_id,
      silent: body.silent === true,
    });

    return jsonResponse(request, {
      notifications_created: result.notificationsCreated,
      pushes_attempted: result.pushesAttempted,
      pushes_delivered: result.pushesDelivered,
      tokens_pruned: result.tokensPruned,
    });
  } catch (error) {
    return errorResponse(request, error);
  }
});

/**
 * Decides whether this caller may notify these people.
 *
 * A salon may reach its own clients and staff — established by an appointment,
 * a CRM record, or employment at the salon — and nothing beyond that. A
 * recipient outside that set fails the whole request rather than being silently
 * dropped, because a partial send is a confusing thing to debug.
 */
async function authorizeBroadcast(
  user: Awaited<ReturnType<typeof requireUser>>,
  body: RequestBody,
  kind: string,
  recipients: readonly string[],
): Promise<void> {
  if (["administrator", "super_admin", "developer"].includes(user.role)) return;

  const salonId = body.salon_id;
  if (!salonId) {
    throw HttpError.forbidden("`salon_id` is required when notifying other people.");
  }
  requireUUID(salonId, "salon_id");

  if (!(await isSalonMember(user, salonId))) {
    throw HttpError.forbidden("You do not work at that salon.");
  }

  if (PROMOTIONAL_KINDS.has(kind) && !(await hasPermission(user, "manageMarketing"))) {
    throw HttpError.forbidden("Promotional notifications require the `manageMarketing` permission.");
  }

  const others = recipients.filter((id) => id !== user.id);
  const reachable = await reachableFromSalon(salonId, others);
  const unreachable = others.filter((id) => !reachable.has(id));

  if (unreachable.length > 0) {
    throw HttpError.forbidden(
      `${unreachable.length} recipient(s) have no relationship with this salon.`,
    );
  }
}

/** The subset of `userIds` this salon has an established relationship with. */
async function reachableFromSalon(
  salonId: string,
  userIds: readonly string[],
): Promise<Set<string>> {
  if (userIds.length === 0) return new Set();

  const admin = serviceClient();
  const ids = [...userIds];

  const [appointments, clients, staff] = await Promise.all([
    admin.from("appointments").select("client_id").eq("salon_id", salonId).in("client_id", ids),
    admin.from("client_records").select("user_id").eq("salon_id", salonId).in("user_id", ids),
    admin.from("employees").select("user_id").eq("salon_id", salonId).in("user_id", ids),
  ]);

  const reachable = new Set<string>();
  for (const row of appointments.data ?? []) {
    reachable.add((row as { client_id: string }).client_id);
  }
  for (const row of clients.data ?? []) {
    const id = (row as { user_id: string | null }).user_id;
    if (id) reachable.add(id);
  }
  for (const row of staff.data ?? []) {
    const id = (row as { user_id: string | null }).user_id;
    if (id) reachable.add(id);
  }
  return reachable;
}
