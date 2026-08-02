/**
 * Environment access.
 *
 * Every secret is read through here so a missing one fails loudly at the top of
 * a request instead of surfacing as an unauthenticated call to a third party
 * halfway through a payment. Nothing in this directory ever falls back to a
 * default for a credential.
 */

/** Reads a required environment variable, throwing when it is absent or blank. */
export function requireEnv(name: string): string {
  const value = Deno.env.get(name);
  if (value === undefined || value.trim() === "") {
    throw new Error(
      `Missing required environment variable ${name}. ` +
        `Set it with: supabase secrets set ${name}=…`,
    );
  }
  return value;
}

/** Reads an optional environment variable, returning `undefined` when unset. */
export function optionalEnv(name: string): string | undefined {
  const value = Deno.env.get(name);
  return value === undefined || value.trim() === "" ? undefined : value;
}

/**
 * Reads an optional boolean flag. Accepts `1`, `true`, `yes` (case-insensitive)
 * as true; anything else — including absence — is false.
 */
export function envFlag(name: string): boolean {
  const value = optionalEnv(name)?.toLowerCase();
  return value === "1" || value === "true" || value === "yes";
}

/** Supabase injects these three into every function at deploy time. */
export const SUPABASE_URL = () => requireEnv("SUPABASE_URL");
export const SUPABASE_ANON_KEY = () => requireEnv("SUPABASE_ANON_KEY");
export const SUPABASE_SERVICE_ROLE_KEY = () => requireEnv("SUPABASE_SERVICE_ROLE_KEY");
