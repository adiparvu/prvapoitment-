# PRV Beauty — Security & Compliance Model

Security is a platform property, not a feature. This document is the reference for how
PRV Beauty protects accounts, payments, client records, and salon business data.

---

## 1. Authentication

| Mechanism | Where | Notes |
|---|---|---|
| Sign in with Apple | `PRVAuthFeature.AuthRootView` | Primary path; identity token verified server-side |
| Email + password | `PRVAuthFeature.AuthRootView` | Supabase Auth; passwords never stored or logged by the client |
| Passkeys (WebAuthn) | `PRVAuthFeature.PasskeySupport` | `ASAuthorizationPlatformPublicKeyCredential` registration + assertion |
| Face ID / Touch ID | `PRVAuthFeature.AppLock` | App-lock on foreground; `LocalAuthentication` with passcode fallback |

**Session storage.** Tokens live in the Keychain (`kSecClassGenericPassword`,
`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`) via `SessionStore`. They are never written
to `UserDefaults`, never logged, and never included in analytics payloads. Sign-out clears
the Keychain item and every cached read model.

**App-lock privacy shield.** When the app resigns active, a frosted glass overlay covers
the UI so client records and revenue figures never appear in the app switcher.

## 2. Authorization — permissions, not roles

Fifteen `UserRole` values resolve to sets of granular `Permission` values
(`PRVModels/User.swift`). Feature code **never branches on a role name** — it checks a
capability:

```swift
RoleGate(requires: .managePayroll) { PayrollSection() }   // UI gating
session.can(.manageInventory)                              // imperative checks
```

Roles are strictly nested where that makes sense (`salonOwner ⊇ salonManager ⊇
salonEmployee`), and `Tests/PRVModelsTests` asserts those supersets so a future edit
cannot silently widen or narrow a role.

Client-side gating is a UX affordance only. **Every permission is re-enforced server-side**
by row-level security; a tampered client gains nothing.

## 3. Data access — Postgres Row Level Security

RLS is enabled on every table with deny-by-default policies
(`Backend/supabase/migrations/0002_rls.sql`):

- **Clients** can read and mutate only rows keyed to their own `auth.uid()` — their
  appointments, orders, wallet transactions, messages, loyalty profile, reviews.
- **Salon staff** access rows scoped through the security-definer helper
  `is_salon_member(salon_id)`, which resolves the caller through `employees`/ownership.
  Staff of salon A can never read salon B's CRM, revenue, or client notes.
- **Public read** is limited to marketing-surface data: salons, services, professionals,
  approved reviews, membership plans, packages.
- **`audit_log`** is insert-only; no role may update or delete an entry.

## 4. Payments

- Card data **never touches the app or our database.** The client presents Apple Pay or a
  Stripe-hosted tokenization form; only the resulting payment-method token and last-four
  digits are persisted (`saved_payment_methods`).
- **Amounts are computed server-side.** The `create-payment-intent` Edge Function verifies
  order ownership with the caller's JWT, recomputes the total from the order rows, and
  ignores any amount supplied by the client — a tampered client cannot underpay.
- PaymentIntents are created with **idempotency keys**, so a retried request can never
  double-charge.
- The `stripe-webhook` function verifies the Stripe signature before mutating any order,
  then transitions the order to paid, credits wallet cashback, and awards loyalty XP.
- Refunds follow the deterministic rules in `PRVPaymentsKit.RefundEngine`; the same rules
  are mirrored in `cancel-appointment` so client and server always agree on what is owed.
- All money math uses `Decimal` with banker's rounding — never `Double`.

## 5. Messaging

Conversations are marked `isEncrypted` and carry a lock affordance in the UI. Message
media is stored in access-controlled buckets; signed URLs are short-lived. Chat content is
excluded from analytics and crash reports.

## 6. AI safety

The `ANTHROPIC_API_KEY` lives only in Edge Function secrets — never in the app bundle,
where it would be trivially extractable. The `assistant-recommend` function constrains the
model to strict JSON matching `AssistantRecommendation`, validates the response before
returning it, and passes through only IDs the caller is allowed to see. Assistant output
is treated as a recommendation surface, never as an authorization decision.

## 7. GDPR & client records

- **Consent forms** are versioned per client with a captured signature and `signedAt`
  timestamp (`ConsentForm`), so a salon can prove which version was agreed.
- **Sensitive beauty data** — allergies, skin/hair type, treatment notes, color formulas —
  is salon-scoped CRM data protected by `is_salon_member` policies.
- **Export**: `ClientDetailView` and account settings produce a portable JSON export of a
  data subject's records.
- **Erasure**: `AuthService.deleteAccount()` triggers server-side deletion; financial
  records legally required for accounting are retained in pseudonymized form with the
  personal identifiers stripped.
- **Data minimization**: analytics events carry no direct identifiers; logging uses
  `os.Logger` privacy annotations, with identifiers redacted by default and only
  non-identifying values marked `.public`.

## 8. Auditing & fraud

Every privileged mutation — refunds, payroll changes, permission changes, client-record
deletion, prepayment policy edits — writes an `AuditLogEntry` (actor, action, entity,
timestamp). Fraud detection sits behind the `fraudDetection` feature flag and evaluates
velocity signals (repeat refunds, mismatched geolocation on clock-in, gift-card redemption
patterns) server-side.

## 9. Transport & storage

- TLS 1.3 for all traffic; certificate validation is never relaxed.
- The API client retries only idempotent failures (429, 5xx) with exponential backoff, so
  a retry storm cannot become an accidental double-mutation.
- Offline mutations are queued as `SyncOperation`s and replayed in order; bookings and
  payments resolve **server-authoritative** so an offline client can never overwrite a
  confirmed slot.
- Local caches are cleared on sign-out and on account deletion.

## 10. Secrets

| Secret | Location |
|---|---|
| `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET` | Supabase Edge Function secrets |
| `ANTHROPIC_API_KEY` | Supabase Edge Function secrets |
| APNs auth key (`.p8`) | Supabase Edge Function secrets |
| Supabase anon/publishable key | App bundle (safe by design — RLS is the boundary) |

`.gitignore` blocks `*.p8`, `*.p12`, `*.mobileprovision`, and `.env` files from ever
entering version control.

## 11. Reporting a vulnerability

Email `security@prvbeauty.com`. Please do not open a public issue for security reports.
