/**
 * Push delivery — provider abstraction.
 *
 * Callers speak in `PushMessage`s and never in APNs or FCM vocabulary. Two
 * providers implement the transport:
 *
 *   * `APNsProvider` — HTTP/2 to Apple with a provider token (ES256 JWT signed
 *     from the `.p8` key). The token is cached for 50 minutes; Apple rejects
 *     tokens older than an hour and rate-limits regeneration.
 *   * `FCMProvider` — FCM HTTP v1, authenticated with a service-account
 *     assertion (RS256 JWT) exchanged for a short-lived OAuth access token.
 *
 * When a platform has no credentials configured, its provider degrades to a
 * logging no-op so local development and CI never depend on Apple or Google
 * being reachable. Every send reports `unregistered` for tokens the platform
 * has retired, and the caller prunes them.
 */

import { optionalEnv } from "./env.ts";

/** One notification, addressed to one device. */
export interface PushMessage {
  readonly token: string;
  readonly platform: "ios" | "android" | "web";
  readonly title: string;
  readonly body: string;
  /** Deep-link and metadata delivered alongside the alert. */
  readonly data?: Record<string, unknown>;
  readonly badge?: number;
  readonly threadId?: string;
  /** APNs collapse id / FCM collapse key — coalesces repeats on the device. */
  readonly collapseId?: string;
  readonly isSandbox?: boolean;
}

/** The outcome of a single delivery attempt. */
export interface PushResult {
  readonly token: string;
  readonly delivered: boolean;
  /** True when the platform says this token is dead and should be deleted. */
  readonly unregistered: boolean;
  readonly error?: string;
}

/** A transport capable of delivering to one or more platforms. */
export interface PushProvider {
  readonly name: string;
  readonly handles: ReadonlyArray<PushMessage["platform"]>;
  send(messages: readonly PushMessage[]): Promise<PushResult[]>;
}

// -----------------------------------------------------------------------------
// JWT signing
// -----------------------------------------------------------------------------

function base64UrlEncode(input: string | Uint8Array): string {
  const bytes = typeof input === "string" ? new TextEncoder().encode(input) : input;
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function pemToDer(pem: string): Uint8Array {
  const body = pem
    .replace(/-----BEGIN [^-]+-----/g, "")
    .replace(/-----END [^-]+-----/g, "")
    .replace(/\s+/g, "");
  const binary = atob(body);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

async function signJwt(
  header: Record<string, unknown>,
  claims: Record<string, unknown>,
  privateKeyPem: string,
  algorithm: "ES256" | "RS256",
): Promise<string> {
  const keyParams: EcKeyImportParams | RsaHashedImportParams = algorithm === "ES256"
    ? { name: "ECDSA", namedCurve: "P-256" }
    : { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" };

  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToDer(privateKeyPem).buffer as ArrayBuffer,
    keyParams,
    false,
    ["sign"],
  );

  const payload = `${base64UrlEncode(JSON.stringify(header))}.${base64UrlEncode(JSON.stringify(claims))}`;
  const signParams: EcdsaParams | AlgorithmIdentifier = algorithm === "ES256"
    ? { name: "ECDSA", hash: "SHA-256" }
    : { name: "RSASSA-PKCS1-v1_5" };

  const signature = await crypto.subtle.sign(
    signParams,
    key,
    new TextEncoder().encode(payload),
  );

  return `${payload}.${base64UrlEncode(new Uint8Array(signature))}`;
}

// -----------------------------------------------------------------------------
// APNs
// -----------------------------------------------------------------------------

const APNS_PRODUCTION_HOST = "https://api.push.apple.com";
const APNS_SANDBOX_HOST = "https://api.sandbox.push.apple.com";

interface APNsConfig {
  keyId: string;
  teamId: string;
  privateKey: string;
  topic: string;
  forceSandbox: boolean;
}

function apnsConfig(): APNsConfig | undefined {
  const keyId = optionalEnv("APNS_KEY_ID");
  const teamId = optionalEnv("APNS_TEAM_ID");
  // The .p8 is stored with literal \n so it survives `supabase secrets set`.
  const privateKey = optionalEnv("APNS_PRIVATE_KEY")?.replace(/\\n/g, "\n");
  const topic = optionalEnv("APNS_TOPIC");
  if (!keyId || !teamId || !privateKey || !topic) return undefined;
  return {
    keyId,
    teamId,
    privateKey,
    topic,
    forceSandbox: (optionalEnv("APNS_ENVIRONMENT") ?? "production") === "sandbox",
  };
}

let apnsToken: { value: string; issuedAt: number } | undefined;

async function apnsProviderToken(config: APNsConfig): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  // Apple rejects tokens older than 60 minutes and throttles regeneration
  // below 20 — 50 minutes sits comfortably between the two.
  if (apnsToken && now - apnsToken.issuedAt < 50 * 60) {
    return apnsToken.value;
  }
  const value = await signJwt(
    { alg: "ES256", kid: config.keyId },
    { iss: config.teamId, iat: now },
    config.privateKey,
    "ES256",
  );
  apnsToken = { value, issuedAt: now };
  return value;
}

/** Apple Push Notification service, HTTP/2 with a provider token. */
export class APNsProvider implements PushProvider {
  readonly name = "apns";
  readonly handles = ["ios"] as const;

  constructor(private readonly config: APNsConfig) {}

  async send(messages: readonly PushMessage[]): Promise<PushResult[]> {
    const token = await apnsProviderToken(this.config);

    return await Promise.all(messages.map(async (message) => {
      const host = message.isSandbox || this.config.forceSandbox
        ? APNS_SANDBOX_HOST
        : APNS_PRODUCTION_HOST;

      const payload = {
        aps: {
          alert: { title: message.title, body: message.body },
          sound: "default",
          "thread-id": message.threadId,
          badge: message.badge,
          "mutable-content": 1,
        },
        ...(message.data ?? {}),
      };

      try {
        const response = await fetch(`${host}/3/device/${message.token}`, {
          method: "POST",
          headers: {
            authorization: `bearer ${token}`,
            "apns-topic": this.config.topic,
            "apns-push-type": "alert",
            "apns-priority": "10",
            ...(message.collapseId ? { "apns-collapse-id": message.collapseId } : {}),
            "content-type": "application/json",
          },
          body: JSON.stringify(payload),
        });

        if (response.ok) {
          return { token: message.token, delivered: true, unregistered: false };
        }

        const detail = await response.text();
        // 410 Gone, and 400 with BadDeviceToken, both mean "stop sending here".
        const unregistered = response.status === 410 ||
          detail.includes("BadDeviceToken") ||
          detail.includes("Unregistered");

        return {
          token: message.token,
          delivered: false,
          unregistered,
          error: `APNs ${response.status}: ${detail.slice(0, 200)}`,
        };
      } catch (error) {
        return {
          token: message.token,
          delivered: false,
          unregistered: false,
          error: `APNs transport failure: ${String(error)}`,
        };
      }
    }));
  }
}

// -----------------------------------------------------------------------------
// FCM (HTTP v1)
// -----------------------------------------------------------------------------

interface FCMServiceAccount {
  project_id: string;
  client_email: string;
  private_key: string;
  token_uri?: string;
}

function fcmServiceAccount(): FCMServiceAccount | undefined {
  const raw = optionalEnv("FCM_SERVICE_ACCOUNT_JSON");
  if (!raw) return undefined;
  try {
    const parsed = JSON.parse(raw) as FCMServiceAccount;
    if (!parsed.project_id || !parsed.client_email || !parsed.private_key) return undefined;
    return { ...parsed, private_key: parsed.private_key.replace(/\\n/g, "\n") };
  } catch {
    console.error("FCM_SERVICE_ACCOUNT_JSON is not valid JSON; FCM delivery disabled.");
    return undefined;
  }
}

let fcmAccessToken: { value: string; expiresAt: number } | undefined;

async function fcmAccess(account: FCMServiceAccount): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (fcmAccessToken && fcmAccessToken.expiresAt - 60 > now) {
    return fcmAccessToken.value;
  }

  const tokenUri = account.token_uri ?? "https://oauth2.googleapis.com/token";
  const assertion = await signJwt(
    { alg: "RS256", typ: "JWT" },
    {
      iss: account.client_email,
      scope: "https://www.googleapis.com/auth/firebase.messaging",
      aud: tokenUri,
      iat: now,
      exp: now + 3600,
    },
    account.private_key,
    "RS256",
  );

  const response = await fetch(tokenUri, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion,
    }),
  });

  if (!response.ok) {
    throw new Error(`FCM token exchange failed: ${response.status}`);
  }

  const body = await response.json() as { access_token: string; expires_in: number };
  fcmAccessToken = { value: body.access_token, expiresAt: now + body.expires_in };
  return body.access_token;
}

/** Firebase Cloud Messaging, HTTP v1. */
export class FCMProvider implements PushProvider {
  readonly name = "fcm";
  readonly handles = ["android", "web"] as const;

  constructor(private readonly account: FCMServiceAccount) {}

  async send(messages: readonly PushMessage[]): Promise<PushResult[]> {
    let accessToken: string;
    try {
      accessToken = await fcmAccess(this.account);
    } catch (error) {
      return messages.map((message) => ({
        token: message.token,
        delivered: false,
        unregistered: false,
        error: String(error),
      }));
    }

    const endpoint =
      `https://fcm.googleapis.com/v1/projects/${this.account.project_id}/messages:send`;

    return await Promise.all(messages.map(async (message) => {
      // FCM data values must be strings.
      const data = Object.fromEntries(
        Object.entries(message.data ?? {}).map(([key, value]) => [
          key,
          typeof value === "string" ? value : JSON.stringify(value),
        ]),
      );

      try {
        const response = await fetch(endpoint, {
          method: "POST",
          headers: {
            authorization: `Bearer ${accessToken}`,
            "content-type": "application/json",
          },
          body: JSON.stringify({
            message: {
              token: message.token,
              notification: { title: message.title, body: message.body },
              data,
              android: {
                priority: "HIGH",
                ...(message.collapseId ? { collapse_key: message.collapseId } : {}),
              },
            },
          }),
        });

        if (response.ok) {
          return { token: message.token, delivered: true, unregistered: false };
        }

        const detail = await response.text();
        const unregistered = response.status === 404 ||
          detail.includes("UNREGISTERED") ||
          detail.includes("INVALID_ARGUMENT");

        return {
          token: message.token,
          delivered: false,
          unregistered,
          error: `FCM ${response.status}: ${detail.slice(0, 200)}`,
        };
      } catch (error) {
        return {
          token: message.token,
          delivered: false,
          unregistered: false,
          error: `FCM transport failure: ${String(error)}`,
        };
      }
    }));
  }
}

/**
 * Stand-in used when a platform has no credentials configured. It logs and
 * reports success, so local development exercises the same code path without
 * reaching Apple or Google.
 */
export class LoggingPushProvider implements PushProvider {
  readonly name = "logging";
  readonly handles = ["ios", "android", "web"] as const;

  send(messages: readonly PushMessage[]): Promise<PushResult[]> {
    for (const message of messages) {
      console.log(
        `[push:noop] ${message.platform} ${message.token.slice(0, 12)}… "${message.title}"`,
      );
    }
    return Promise.resolve(
      messages.map((message) => ({ token: message.token, delivered: true, unregistered: false })),
    );
  }
}

/** Resolves the configured providers, in the order they should be consulted. */
export function pushProviders(): PushProvider[] {
  const providers: PushProvider[] = [];
  const apns = apnsConfig();
  if (apns) providers.push(new APNsProvider(apns));
  const fcm = fcmServiceAccount();
  if (fcm) providers.push(new FCMProvider(fcm));
  if (providers.length === 0) providers.push(new LoggingPushProvider());
  return providers;
}

/**
 * Dispatches every message through the provider that handles its platform.
 * A platform with no configured provider falls back to the logging provider,
 * so an unconfigured Android build never fails an otherwise-successful booking.
 */
export async function dispatchPush(messages: readonly PushMessage[]): Promise<PushResult[]> {
  if (messages.length === 0) return [];

  const providers = pushProviders();
  const fallback = new LoggingPushProvider();
  const batches = new Map<PushProvider, PushMessage[]>();

  for (const message of messages) {
    const provider = providers.find((candidate) =>
      (candidate.handles as readonly string[]).includes(message.platform)
    ) ?? fallback;
    const batch = batches.get(provider) ?? [];
    batch.push(message);
    batches.set(provider, batch);
  }

  const results = await Promise.all(
    [...batches.entries()].map(([provider, batch]) => provider.send(batch)),
  );
  return results.flat();
}
