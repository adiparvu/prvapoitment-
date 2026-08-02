/**
 * JWT user resolution.
 *
 * The token is verified by Supabase Auth (`auth.getUser`), not decoded locally
 * — a function must never trust a `sub` claim it merely parsed. The resolved
 * identity is then joined to `profiles` so the caller's role and permissions
 * come from the database rather than from anything the client sent.
 */

import { serviceClient, bearerToken } from "./supabase.ts";
import { HttpError } from "./errors.ts";

/** The authenticated caller, as the platform knows them. */
export interface AuthenticatedUser {
  readonly id: string;
  readonly email: string | null;
  readonly role: string;
  readonly firstName: string;
  readonly lastName: string;
  /** The raw JWT, for forwarding to PostgREST on the caller's behalf. */
  readonly token: string;
}

/**
 * Verifies the request's bearer token and loads the caller's profile.
 *
 * @throws `HttpError` 401 when the token is missing, expired, or invalid.
 */
export async function requireUser(request: Request): Promise<AuthenticatedUser> {
  const token = bearerToken(request);
  const supabase = serviceClient();

  const { data, error } = await supabase.auth.getUser(token);
  if (error || !data?.user) {
    throw HttpError.unauthorized("Session expired or invalid. Sign in again.");
  }

  const { data: profile, error: profileError } = await supabase
    .from("profiles")
    .select("role, first_name, last_name, email")
    .eq("id", data.user.id)
    .maybeSingle();

  if (profileError) {
    throw HttpError.upstream("Could not load your profile.", profileError.message);
  }
  if (!profile) {
    throw HttpError.forbidden("This account has no profile yet.");
  }

  return {
    id: data.user.id,
    email: profile.email ?? data.user.email ?? null,
    role: profile.role as string,
    firstName: profile.first_name ?? "",
    lastName: profile.last_name ?? "",
    token,
  };
}

/**
 * True when the caller's role carries `permission`, resolved against the
 * `role_permissions` table that mirrors `UserRole.permissions` in Swift.
 */
export async function hasPermission(
  user: AuthenticatedUser,
  permission: string,
): Promise<boolean> {
  const supabase = serviceClient();
  const { data, error } = await supabase
    .from("role_permissions")
    .select("permission")
    .eq("role", user.role)
    .eq("permission", permission)
    .maybeSingle();

  if (error) {
    throw HttpError.upstream("Could not resolve permissions.", error.message);
  }
  return data !== null;
}

/** Throws 403 unless the caller's role carries `permission`. */
export async function requirePermission(
  user: AuthenticatedUser,
  permission: string,
): Promise<void> {
  if (!(await hasPermission(user, permission))) {
    throw HttpError.forbidden(`This action requires the \`${permission}\` permission.`);
  }
}

/**
 * True when the caller is staff at, or owner of, `salonId`.
 *
 * This deliberately does not call the `is_salon_member(uuid)` SQL helper: that
 * function resolves `auth.uid()`, which is NULL under the service role, so it
 * would answer for nobody. The three membership paths below are the same ones
 * the SQL helper walks, evaluated for an explicit user id.
 */
export async function isSalonMember(
  user: AuthenticatedUser,
  salonId: string,
): Promise<boolean> {
  if (["administrator", "super_admin", "developer"].includes(user.role)) {
    return true;
  }

  const supabase = serviceClient();

  const [{ data: employee }, { data: professional }, { data: salon }] = await Promise.all([
    supabase
      .from("employees")
      .select("id")
      .eq("salon_id", salonId)
      .eq("user_id", user.id)
      .is("terminated_at", null)
      .maybeSingle(),
    supabase
      .from("professionals")
      .select("id")
      .eq("salon_id", salonId)
      .eq("user_id", user.id)
      .eq("is_active", true)
      .maybeSingle(),
    supabase
      .from("salons")
      .select("organizations!inner(owner_id)")
      .eq("id", salonId)
      .eq("organizations.owner_id", user.id)
      .maybeSingle(),
  ]);

  return employee !== null || professional !== null || salon !== null;
}
