/**
 * Error and response helpers.
 *
 * Two rules hold across every function:
 *
 *   1. The client sees a stable `{ error: { code, message } }` envelope that
 *      `PRVNetworking.APIError` can map onto — never a stack trace, never a
 *      provider's raw error body.
 *   2. Anything that could carry a secret (a Stripe error, a Postgres detail, a
 *      provider response) is logged server-side and replaced with a safe
 *      summary before it leaves the function.
 */

import { corsHeaders } from "./cors.ts";

/** An error that carries the HTTP status and machine code to return. */
export class HttpError extends Error {
  readonly status: number;
  readonly code: string;
  readonly details?: unknown;

  constructor(status: number, code: string, message: string, details?: unknown) {
    super(message);
    this.name = "HttpError";
    this.status = status;
    this.code = code;
    this.details = details;
  }

  static badRequest(message: string, details?: unknown): HttpError {
    return new HttpError(400, "bad_request", message, details);
  }

  static unauthorized(message = "Authentication required."): HttpError {
    return new HttpError(401, "unauthorized", message);
  }

  static forbidden(message = "You do not have access to this resource."): HttpError {
    return new HttpError(403, "forbidden", message);
  }

  static notFound(message = "Not found."): HttpError {
    return new HttpError(404, "not_found", message);
  }

  static conflict(message: string, details?: unknown): HttpError {
    return new HttpError(409, "conflict", message, details);
  }

  static upstream(message: string, details?: unknown): HttpError {
    return new HttpError(502, "upstream_error", message, details);
  }
}

/** Serializes `body` as JSON with CORS headers attached. */
export function jsonResponse(
  request: Request,
  body: unknown,
  status = 200,
  extraHeaders: Record<string, string> = {},
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      ...corsHeaders(request),
      ...extraHeaders,
    },
  });
}

/**
 * The SQLSTATEs raised by `book_appointment` and friends in
 * migrations/0003_functions_triggers.sql, mapped to HTTP.
 */
const POSTGRES_STATUS: Record<string, { status: number; code: string }> = {
  PRV01: { status: 403, code: "forbidden" },
  PRV04: { status: 404, code: "not_found" },
  PRV09: { status: 409, code: "slot_conflict" },
  "23505": { status: 409, code: "conflict" }, // unique_violation
  "23514": { status: 400, code: "constraint_violation" }, // check_violation
  "23P01": { status: 409, code: "slot_conflict" }, // exclusion_violation
  "42501": { status: 403, code: "forbidden" }, // insufficient_privilege (RLS)
};

/** A PostgREST / supabase-js error shape, narrowed structurally. */
export interface PostgresErrorLike {
  code?: string | null;
  message?: string | null;
  details?: string | null;
  hint?: string | null;
}

/** Converts a Postgres/PostgREST error into an `HttpError`. */
export function fromPostgresError(error: PostgresErrorLike, fallback: string): HttpError {
  const mapped = error.code ? POSTGRES_STATUS[error.code] : undefined;
  const message = error.message?.replace(/^[a-z_]+: /i, "") ?? fallback;

  if (mapped) {
    return new HttpError(
      mapped.status,
      mapped.code,
      message,
      error.hint ?? undefined,
    );
  }
  return new HttpError(500, "database_error", fallback);
}

/** Renders any thrown value as the standard error envelope. */
export function errorResponse(request: Request, error: unknown): Response {
  if (error instanceof HttpError) {
    if (error.status >= 500) {
      console.error(`[${error.code}] ${error.message}`, error.details ?? "");
    }
    return jsonResponse(
      request,
      {
        error: {
          code: error.code,
          message: error.message,
          ...(error.details === undefined ? {} : { details: error.details }),
        },
      },
      error.status,
    );
  }

  // Anything unrecognized is a bug: log it in full, tell the client nothing.
  console.error("Unhandled error", error);
  return jsonResponse(
    request,
    { error: { code: "internal_error", message: "Something went wrong on our side." } },
    500,
  );
}

/** Parses and validates a JSON request body. */
export async function readJson<T>(request: Request): Promise<T> {
  const contentType = request.headers.get("content-type") ?? "";
  if (!contentType.includes("application/json")) {
    throw HttpError.badRequest("Expected a JSON request body.");
  }
  try {
    return (await request.json()) as T;
  } catch {
    throw HttpError.badRequest("Request body is not valid JSON.");
  }
}

/** Rejects anything other than the expected method. */
export function requireMethod(request: Request, method: "POST" | "GET"): void {
  if (request.method !== method) {
    throw new HttpError(405, "method_not_allowed", `Use ${method} for this endpoint.`);
  }
}

/** Narrow a value to a non-empty UUID string, or throw. */
export function requireUUID(value: unknown, field: string): string {
  const pattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  if (typeof value !== "string" || !pattern.test(value)) {
    throw HttpError.badRequest(`\`${field}\` must be a UUID.`);
  }
  return value;
}
