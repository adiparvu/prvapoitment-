/**
 * Notification fan-out.
 *
 * One call writes the durable `notifications` rows the Notification Centre
 * reads and pushes the same content to every registered device. The two halves
 * are deliberately ordered: the row is committed first, so a push that fails to
 * deliver never loses the notification — the user still finds it in the app.
 *
 * Tokens the platform reports as retired are deleted here rather than left to
 * rot, which keeps later fan-outs from spending a request per dead device.
 */

import type { SupabaseClient } from "npm:@supabase/supabase-js@2.58.0";
import { dispatchPush, type PushMessage } from "./push.ts";

/** Mirrors `PRVNotification.Kind`. */
export type NotificationKind =
  | "appointment_reminder"
  | "appointment_confirmed"
  | "appointment_cancelled"
  | "waitlist_slot_opened"
  | "promotion"
  | "review_request"
  | "membership_renewal"
  | "package_expiring"
  | "price_change"
  | "loyalty_reward"
  | "chat_message"
  | "system";

/** What to tell a set of users. */
export interface NotificationRequest {
  readonly userIds: readonly string[];
  readonly kind: NotificationKind;
  readonly title: string;
  readonly body: string;
  /**
   * The encoded `AppRoute` the notification opens. Use `appRoute(…)` to build
   * it so the shape matches Swift's synthesized enum encoding.
   */
  readonly route?: Record<string, unknown> | null;
  /** Extra key/values delivered in the push payload only. */
  readonly data?: Record<string, unknown>;
  /** Coalesces repeats of the same subject on the device. */
  readonly collapseId?: string;
  /** Skip the push and only write the in-app row. */
  readonly silent?: boolean;
}

/** What happened. */
export interface FanOutResult {
  readonly notificationsCreated: number;
  readonly pushesAttempted: number;
  readonly pushesDelivered: number;
  readonly tokensPruned: number;
}

/**
 * Encodes an `AppRoute` case the way Swift's synthesized `Codable` does:
 * a single-key object whose value carries the associated values, positional
 * ones keyed `_0`, `_1`, … and labelled ones keyed by their label.
 *
 *     appRoute("appointment", "…uuid…")           // { appointment: { _0: "…" } }
 *     appRoute("memberships", { salonID: "…" })   // { memberships: { salonID: "…" } }
 *     appRoute("wallet")                          // { wallet: {} }
 */
export function appRoute(
  caseName: string,
  payload?: string | Record<string, unknown>,
): Record<string, unknown> {
  if (payload === undefined) return { [caseName]: {} };
  if (typeof payload === "string") return { [caseName]: { _0: payload } };
  return { [caseName]: payload };
}

interface DeviceTokenRow {
  user_id: string;
  token: string;
  platform: "ios" | "android" | "web";
  is_sandbox: boolean;
}

/**
 * Writes the notification rows and pushes them.
 *
 * Requires a service-role client: it writes rows for users other than the
 * caller (a salon notifying a client, a stock alert notifying staff), which no
 * client-side policy permits.
 */
export async function createAndFanOut(
  supabase: SupabaseClient,
  request: NotificationRequest,
): Promise<FanOutResult> {
  const userIds = [...new Set(request.userIds)].filter((id) => id.length > 0);
  if (userIds.length === 0) {
    return { notificationsCreated: 0, pushesAttempted: 0, pushesDelivered: 0, tokensPruned: 0 };
  }

  const { error: insertError } = await supabase.from("notifications").insert(
    userIds.map((userId) => ({
      user_id: userId,
      kind: request.kind,
      title: request.title,
      body: request.body,
      route: request.route ?? null,
    })),
  );

  if (insertError) {
    // A failed insert is a real failure: the user would never see this at all.
    throw new Error(`Could not create notifications: ${insertError.message}`);
  }

  if (request.silent) {
    return {
      notificationsCreated: userIds.length,
      pushesAttempted: 0,
      pushesDelivered: 0,
      tokensPruned: 0,
    };
  }

  const { data: tokens, error: tokenError } = await supabase
    .from("device_tokens")
    .select("user_id, token, platform, is_sandbox")
    .in("user_id", userIds);

  if (tokenError) {
    console.error("Could not read device tokens; in-app rows were still created.", tokenError);
    return {
      notificationsCreated: userIds.length,
      pushesAttempted: 0,
      pushesDelivered: 0,
      tokensPruned: 0,
    };
  }

  const rows = (tokens ?? []) as DeviceTokenRow[];
  if (rows.length === 0) {
    return {
      notificationsCreated: userIds.length,
      pushesAttempted: 0,
      pushesDelivered: 0,
      tokensPruned: 0,
    };
  }

  const messages: PushMessage[] = rows.map((row) => ({
    token: row.token,
    platform: row.platform,
    title: request.title,
    body: request.body,
    threadId: request.kind,
    collapseId: request.collapseId,
    isSandbox: row.is_sandbox,
    data: {
      kind: request.kind,
      ...(request.route ? { route: request.route } : {}),
      ...(request.data ?? {}),
    },
  }));

  const results = await dispatchPush(messages);

  const stale = results.filter((result) => result.unregistered).map((result) => result.token);
  if (stale.length > 0) {
    const { error: pruneError } = await supabase
      .from("device_tokens")
      .delete()
      .in("token", stale);
    if (pruneError) {
      console.error("Could not prune retired device tokens.", pruneError);
    }
  }

  for (const failure of results.filter((result) => !result.delivered && !result.unregistered)) {
    console.error(`Push failed for ${failure.token.slice(0, 12)}…: ${failure.error}`);
  }

  return {
    notificationsCreated: userIds.length,
    pushesAttempted: results.length,
    pushesDelivered: results.filter((result) => result.delivered).length,
    tokensPruned: stale.length,
  };
}

/**
 * The user ids of everyone who works at `salonId` and has an account — the
 * audience for "a booking just came in" and similar operational notices.
 */
export async function salonStaffUserIds(
  supabase: SupabaseClient,
  salonId: string,
): Promise<string[]> {
  const { data, error } = await supabase
    .from("employees")
    .select("user_id")
    .eq("salon_id", salonId)
    .is("terminated_at", null)
    .not("user_id", "is", null);

  if (error) {
    console.error("Could not resolve salon staff.", error);
    return [];
  }
  return (data ?? [])
    .map((row) => (row as { user_id: string | null }).user_id)
    .filter((id): id is string => id !== null);
}
