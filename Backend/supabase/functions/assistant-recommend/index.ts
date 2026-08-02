/**
 * assistant-recommend
 *
 * The AI Beauty Assistant. Backs `ChatRepository.askAssistant(prompt:userID:)`
 * and returns an `AssistantRecommendation` the client decodes directly.
 *
 * Three things this function is responsible for, none of which can be done on
 * the device:
 *
 *   1. **The key stays here.** `ANTHROPIC_API_KEY` lives in Edge Function
 *      secrets. Shipping it in an app bundle would make it trivially
 *      extractable, and a leaked model key is someone else's bill.
 *   2. **The catalogue is the caller's catalogue.** Candidate salons, services,
 *      professionals, and packages are read with the caller's own JWT, so the
 *      model can only ever be shown — and can only ever recommend — rows that
 *      RLS already permits. Any id it invents is dropped before the response is
 *      returned: assistant output is a recommendation surface, never an
 *      authorization decision.
 *   3. **The JSON is enforced, not hoped for.** The system prompt fixes the
 *      schema, the response is parsed strictly, and a malformed reply gets one
 *      repair round-trip before the request fails honestly.
 *
 * Request  { prompt, salon_id?, conversation_id? }
 * Response AssistantRecommendation (see PRVModels/Chat.swift)
 */

import Anthropic from "npm:@anthropic-ai/sdk@^0.110.0";
import { handlePreflight } from "../_shared/cors.ts";
import {
  errorResponse,
  HttpError,
  jsonResponse,
  readJson,
  requireMethod,
} from "../_shared/errors.ts";
import { requireUser } from "../_shared/auth.ts";
import { serviceClient, userClient } from "../_shared/supabase.ts";
import { requireEnv } from "../_shared/env.ts";

/** The model is fixed here rather than taken from the request. */
const MODEL = "claude-sonnet-5";
const MAX_TOKENS = 2000;

interface RequestBody {
  prompt?: string;
  salon_id?: string | null;
  /** When present, the recommendation is also appended to that conversation. */
  conversation_id?: string | null;
}

interface CatalogueEntry {
  id: string;
  name: string;
  detail: string;
}

interface Catalogue {
  salons: CatalogueEntry[];
  services: CatalogueEntry[];
  professionals: CatalogueEntry[];
  packages: CatalogueEntry[];
}

/** The shape the model must produce — mirrors `AssistantRecommendation`. */
interface RecommendationDraft {
  headline?: unknown;
  rationale?: unknown;
  service_ids?: unknown;
  salon_ids?: unknown;
  professional_ids?: unknown;
  package_ids?: unknown;
  suggested_slots?: unknown;
  maintenance_advice?: unknown;
}

const SYSTEM_PROMPT = `You are the PRV Beauty Assistant, a beauty concierge for a booking platform.

You recommend treatments from a fixed catalogue that is supplied with every request. Obey these rules without exception:

1. Reply with a single JSON object and nothing else. No prose before it, no prose after it, no markdown fences, no explanation of the JSON.
2. The object has exactly these keys:
   {
     "headline": string,              // <= 60 characters, the one-line result
     "rationale": string,             // 1-3 sentences, warm and specific, no bullet points
     "service_ids": string[],         // ids copied verbatim from CATALOGUE.services
     "salon_ids": string[],           // ids copied verbatim from CATALOGUE.salons
     "professional_ids": string[],    // ids copied verbatim from CATALOGUE.professionals
     "package_ids": string[],         // ids copied verbatim from CATALOGUE.packages
     "maintenance_advice": string|null // e.g. "Refresh every 6 weeks", or null
   }
3. Every id you emit MUST appear verbatim in the catalogue supplied in the user message. Never invent, guess, abbreviate, or reformat an id. If nothing in the catalogue fits, return empty arrays and say so in the rationale.
4. Recommend at most 4 services, 3 salons, 3 professionals, and 2 packages. Fewer is better than padding.
5. Never quote prices, never promise availability, never claim a booking has been made. You suggest; the client books.
6. Never give medical, dermatological, or pharmaceutical advice. If the request is medical, say so plainly in the rationale and recommend a consultation instead.
7. Write in the client's language when their message is not in English.`;

Deno.serve(async (request) => {
  const preflight = handlePreflight(request);
  if (preflight) return preflight;

  try {
    requireMethod(request, "POST");
    const user = await requireUser(request);
    const body = await readJson<RequestBody>(request);

    const prompt = (body.prompt ?? "").trim();
    if (prompt.length === 0) {
      throw HttpError.badRequest("`prompt` is required.");
    }
    if (prompt.length > 2000) {
      throw HttpError.badRequest("`prompt` is too long — keep it under 2000 characters.");
    }

    const catalogue = await loadCatalogue(request, body.salon_id ?? null);
    if (catalogue.services.length === 0) {
      throw HttpError.notFound("There is nothing bookable to recommend yet.");
    }

    const anthropic = new Anthropic({ apiKey: requireEnv("ANTHROPIC_API_KEY") });
    const userMessage = buildUserMessage(prompt, catalogue);

    let raw = await ask(anthropic, [{ role: "user", content: userMessage }]);
    let draft = parseJsonObject(raw);

    if (!draft) {
      // One repair turn: hand the model its own output and ask for JSON only.
      raw = await ask(anthropic, [
        { role: "user", content: userMessage },
        { role: "assistant", content: raw.slice(0, 4000) },
        {
          role: "user",
          content:
            "That was not valid JSON. Reply again with the JSON object only — no prose, no markdown fences, no trailing commentary.",
        },
      ]);
      draft = parseJsonObject(raw);
    }

    if (!draft) {
      throw HttpError.upstream("The assistant could not produce a usable recommendation.");
    }

    const recommendation = sanitize(draft, catalogue);

    if (body.conversation_id) {
      await persist(user.id, body.conversation_id, recommendation);
    }

    return jsonResponse(request, recommendation);
  } catch (error) {
    return errorResponse(request, error);
  }
});

// -----------------------------------------------------------------------------
// Catalogue
// -----------------------------------------------------------------------------

/**
 * Reads the candidate set with the caller's JWT. Anything RLS hides from them
 * is never shown to the model, which is what keeps a recommendation from
 * leaking the existence of a row the caller cannot see.
 */
async function loadCatalogue(request: Request, salonId: string | null): Promise<Catalogue> {
  const asUser = userClient(request);

  const servicesQuery = asUser
    .from("services")
    .select("id, name, details, category, duration_minutes, price_amount, price_currency, salon_id")
    .eq("is_active", true)
    .limit(40);

  const salonsQuery = asUser
    .from("salons")
    .select("id, name, tagline, city, categories, rating")
    .eq("is_active", true)
    .order("rating", { ascending: false })
    .limit(12);

  const professionalsQuery = asUser
    .from("professionals")
    .select("id, display_name, title, specialties, rating, salon_id")
    .eq("is_active", true)
    .order("rating", { ascending: false })
    .limit(16);

  const packagesQuery = asUser
    .from("service_packages")
    .select("id, name, details, theme, salon_id")
    .eq("is_active", true)
    .limit(10);

  if (salonId) {
    servicesQuery.eq("salon_id", salonId);
    salonsQuery.eq("id", salonId);
    professionalsQuery.eq("salon_id", salonId);
    packagesQuery.eq("salon_id", salonId);
  }

  const [services, salons, professionals, packages] = await Promise.all([
    servicesQuery,
    salonsQuery,
    professionalsQuery,
    packagesQuery,
  ]);

  return {
    services: (services.data ?? []).map((row) => {
      const service = row as Record<string, unknown>;
      return {
        id: String(service.id),
        name: String(service.name),
        detail: [
          String(service.category ?? "").replace(/_/g, " "),
          `${service.duration_minutes} min`,
          String(service.details ?? "").slice(0, 160),
        ].filter((part) => part.length > 0).join(" · "),
      };
    }),
    salons: (salons.data ?? []).map((row) => {
      const salon = row as Record<string, unknown>;
      return {
        id: String(salon.id),
        name: String(salon.name),
        detail: [salon.tagline, salon.city, `${salon.rating}★`]
          .filter((part) => part !== null && part !== undefined && String(part).length > 0)
          .map(String)
          .join(" · "),
      };
    }),
    professionals: (professionals.data ?? []).map((row) => {
      const professional = row as Record<string, unknown>;
      const specialties = Array.isArray(professional.specialties)
        ? (professional.specialties as string[]).join(", ")
        : "";
      return {
        id: String(professional.id),
        name: String(professional.display_name),
        detail: [professional.title, specialties, `${professional.rating}★`]
          .filter((part) => part !== null && part !== undefined && String(part).length > 0)
          .map(String)
          .join(" · "),
      };
    }),
    packages: (packages.data ?? []).map((row) => {
      const servicePackage = row as Record<string, unknown>;
      return {
        id: String(servicePackage.id),
        name: String(servicePackage.name),
        detail: String(servicePackage.details ?? "").slice(0, 160),
      };
    }),
  };
}

function buildUserMessage(prompt: string, catalogue: Catalogue): string {
  const render = (entries: CatalogueEntry[]) =>
    entries.length === 0
      ? "  (none available)"
      : entries.map((entry) => `  - ${entry.id} | ${entry.name} | ${entry.detail}`).join("\n");

  return [
    "CATALOGUE",
    "salons:",
    render(catalogue.salons),
    "services:",
    render(catalogue.services),
    "professionals:",
    render(catalogue.professionals),
    "packages:",
    render(catalogue.packages),
    "",
    "CLIENT REQUEST",
    prompt,
  ].join("\n");
}

// -----------------------------------------------------------------------------
// Model call
// -----------------------------------------------------------------------------

async function ask(
  anthropic: Anthropic,
  messages: Array<{ role: "user" | "assistant"; content: string }>,
): Promise<string> {
  let response;
  try {
    response = await anthropic.messages.create({
      model: MODEL,
      max_tokens: MAX_TOKENS,
      system: SYSTEM_PROMPT,
      messages,
    });
  } catch (error) {
    console.error("Anthropic request failed", error);
    throw HttpError.upstream("The assistant is unavailable right now. Try again in a moment.");
  }

  if ((response.stop_reason as string | null) === "refusal") {
    throw new HttpError(
      422,
      "assistant_declined",
      "The assistant could not help with that request. Try describing the look you want instead.",
    );
  }

  // Adaptive thinking is on by default on this model, so the response can carry
  // thinking blocks ahead of the answer — take the text blocks only.
  const text = response.content
    .filter((block): block is Anthropic.TextBlock => block.type === "text")
    .map((block) => block.text)
    .join("\n")
    .trim();

  if (text.length === 0) {
    throw HttpError.upstream("The assistant returned an empty response.");
  }
  return text;
}

// -----------------------------------------------------------------------------
// Parsing, repair, and sanitizing
// -----------------------------------------------------------------------------

/**
 * Strict parse first; then the cheap structural repairs that cover almost every
 * real failure — a markdown fence, or a sentence wrapped around the object.
 * Anything beyond that goes back to the model rather than being guessed at.
 */
function parseJsonObject(raw: string): RecommendationDraft | null {
  const attempts: string[] = [raw];

  const fenced = raw.match(/```(?:json)?\s*([\s\S]*?)```/i);
  if (fenced?.[1]) attempts.push(fenced[1]);

  const firstBrace = raw.indexOf("{");
  const lastBrace = raw.lastIndexOf("}");
  if (firstBrace !== -1 && lastBrace > firstBrace) {
    attempts.push(raw.slice(firstBrace, lastBrace + 1));
  }

  for (const attempt of attempts) {
    try {
      const parsed = JSON.parse(attempt.trim());
      if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
        return parsed as RecommendationDraft;
      }
    } catch {
      // try the next shape
    }
  }
  return null;
}

/**
 * Coerces the draft into a valid `AssistantRecommendation`.
 *
 * Every id is intersected with the catalogue the caller was allowed to see, so
 * a hallucinated or out-of-scope id is dropped rather than returned. Free text
 * is trimmed to the lengths the UI is designed around.
 */
function sanitize(draft: RecommendationDraft, catalogue: Catalogue): Record<string, unknown> {
  const allow = (entries: CatalogueEntry[], value: unknown, limit: number): string[] => {
    const permitted = new Set(entries.map((entry) => entry.id));
    if (!Array.isArray(value)) return [];
    return [
      ...new Set(
        value
          .filter((item): item is string => typeof item === "string")
          .map((item) => item.trim())
          .filter((item) => permitted.has(item)),
      ),
    ].slice(0, limit);
  };

  const text = (value: unknown, fallback: string, limit: number): string => {
    const candidate = typeof value === "string" ? value.trim() : "";
    return (candidate.length > 0 ? candidate : fallback).slice(0, limit);
  };

  const maintenance = typeof draft.maintenance_advice === "string" &&
      draft.maintenance_advice.trim().length > 0
    ? draft.maintenance_advice.trim().slice(0, 240)
    : null;

  return {
    id: crypto.randomUUID(),
    headline: text(draft.headline, "A look worth booking", 80),
    rationale: text(
      draft.rationale,
      "Here are the treatments that best match what you described.",
      600,
    ),
    service_ids: allow(catalogue.services, draft.service_ids, 4),
    salon_ids: allow(catalogue.salons, draft.salon_ids, 3),
    professional_ids: allow(catalogue.professionals, draft.professional_ids, 3),
    package_ids: allow(catalogue.packages, draft.package_ids, 2),
    // Slots are produced by the availability engine against live calendars,
    // never by the model — a suggested time the salon cannot honour is worse
    // than no suggestion at all.
    suggested_slots: [],
    maintenance_advice: maintenance,
  };
}

/** Appends the recommendation to the caller's assistant conversation. */
async function persist(
  userId: string,
  conversationId: string,
  recommendation: Record<string, unknown>,
): Promise<void> {
  const admin = serviceClient();

  const { data: participant } = await admin
    .from("conversation_participants")
    .select("user_id")
    .eq("conversation_id", conversationId)
    .eq("user_id", userId)
    .maybeSingle();

  if (!participant) {
    console.warn("Skipping persistence: caller is not in that conversation.");
    return;
  }

  const { error } = await admin.from("messages").insert({
    conversation_id: conversationId,
    sender_id: null,
    is_from_assistant: true,
    content_kind: "recommendation",
    recommendation,
    delivery_state: "delivered",
  });

  if (error) console.error("Could not persist assistant recommendation", error);
}
