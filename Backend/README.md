# PRV Beauty — Backend

The Supabase backend behind the iOS app: a PostgreSQL schema that mirrors
`Sources/PRVModels` one-to-one, Row Level Security on every table, and six Deno
Edge Functions for the work a device must not be trusted to do.

```
Backend/supabase/
├── config.toml                     # local stack + per-function JWT policy
├── migrations/
│   ├── 0001_schema.sql             # enums, tables, constraints, indexes
│   ├── 0002_rls.sql                # RLS, security-definer helpers, grants
│   ├── 0003_functions_triggers.sql # booking RPC, aggregates, loyalty, views
│   └── 0004_seed.sql               # role→permission matrix + demo fixtures
└── functions/
    ├── _shared/                    # clients, auth, CORS/errors, money, cancellation
    │                               # engines, notification fan-out, APNs/FCM providers
    ├── create-payment-intent/      # Stripe PaymentIntent, amount recomputed server-side
    ├── confirm-booking/            # book_appointment RPC + notification fan-out
    ├── cancel-appointment/         # cancellation fees, automatic refunds, audit
    ├── assistant-recommend/        # Claude-backed recommendations, key server-side
    ├── notify-fanout/              # notification rows + APNs/FCM dispatch
    └── stripe-webhook/             # the only place an order becomes paid
```

The app runs against an in-memory backend out of the box (`InMemoryBackend`), so
none of this is required to build, run, or demo the client. Point the app at a
real stack only when you want live data.

---

## 1. Local development

```bash
brew install supabase/tap/supabase   # or see supabase.com/docs/guides/cli

cd Backend
supabase start                       # Postgres, Auth, Storage, Realtime, Studio
supabase db reset                    # drops, re-applies 0001…0004, reseeds
supabase functions serve             # all six functions, hot-reloaded
```

`supabase start` prints the local URL and keys. Studio is at
<http://127.0.0.1:54323>; sent mail lands in Inbucket at
<http://127.0.0.1:54324>.

### Demo accounts

`0004_seed.sql` mirrors `PRVModels.PreviewData` — **the same UUIDs**, so the app
shows the same salons, services, and appointment whether it is running against
the in-memory backend or a freshly reset local database. Password for all three:
`prv-demo-password`.

| Account | Role | Sees |
|---|---|---|
| `sofia@example.com` | `premium_client` | Client experience: upcoming balayage, Gold membership, 6 450 XP |
| `emma@maisonlumiere.be` | `salon_owner` | Business experience for Maison Lumière |
| `marie@example.com` | `client` | A second client, for review and waitlist flows |

### Working on a migration

Migrations are append-only. To change the schema, add `0005_…sql`; never edit an
applied file. `supabase db reset` is the fast local loop; `supabase db diff -f
<name>` captures changes made through Studio.

```bash
supabase db reset                     # re-apply everything from scratch
supabase db lint                      # catches unqualified search_path, etc.
supabase test db                      # pgTAP, if/when tests are added
```

### Calling a function locally

```bash
# `supabase start` prints the anon key; sign in first to get a user token.
curl -i http://127.0.0.1:54321/functions/v1/confirm-booking \
  -H "Authorization: Bearer $USER_JWT" \
  -H "Content-Type: application/json" \
  -d '{
        "salon_id": "00000000-0000-0000-0001-000000000001",
        "client_id": "00000000-0000-0000-0000-000000000001",
        "items": [{ "service_id": "00000000-0000-0000-0003-000000000002" }],
        "slot": { "start": "2026-09-01T09:00:00Z", "end": "2026-09-01T10:00:00Z" }
      }'
```

Stripe webhooks locally:

```bash
stripe listen --forward-to http://127.0.0.1:54321/functions/v1/stripe-webhook
stripe trigger payment_intent.succeeded
```

---

## 2. Deploying

```bash
supabase link --project-ref <project-ref>
supabase db push                      # applies pending migrations
supabase functions deploy             # all functions
supabase functions deploy stripe-webhook   # or one at a time
```

`0004_seed.sql` is a migration, so it runs on `db push` too. Its first half —
the `role_permissions` matrix — **is** production data and must be applied. Its
second half is demo fixtures: strip that section before the first production
push, or keep it only in non-production projects.

Set the Stripe webhook endpoint to
`https://<project-ref>.supabase.co/functions/v1/stripe-webhook`, subscribed to
`payment_intent.succeeded`, `payment_intent.payment_failed`, and
`charge.refunded`.

---

## 3. Secrets

Set with `supabase secrets set KEY=value` (or in the dashboard). None of these
ever ship in the app bundle.

| Secret | Used by | Notes |
|---|---|---|
| `STRIPE_SECRET_KEY` | `create-payment-intent`, `cancel-appointment`, `stripe-webhook` | `sk_live_…` / `sk_test_…` |
| `STRIPE_WEBHOOK_SECRET` | `stripe-webhook` | `whsec_…`, per endpoint — staging and production differ |
| `STRIPE_PUBLISHABLE_KEY` | `create-payment-intent` | Optional; returned to the app so PaymentSheet needs no build-time config |
| `ANTHROPIC_API_KEY` | `assistant-recommend` | Server-side only. A key in an app bundle is a key on the internet. |
| `APNS_KEY_ID` | push | The `.p8` key id from the Apple Developer portal |
| `APNS_TEAM_ID` | push | Apple Developer team id |
| `APNS_PRIVATE_KEY` | push | Contents of the `.p8`, with newlines escaped as `\n` |
| `APNS_TOPIC` | push | The app's bundle id, e.g. `com.prvbeauty.app` |
| `APNS_ENVIRONMENT` | push | `production` (default) or `sandbox` |
| `FCM_SERVICE_ACCOUNT_JSON` | push | Whole service-account JSON, for the Android/web clients |
| `ALLOWED_ORIGINS` | all | Comma-separated CORS allow-list. Unset ⇒ `*`, which is safe here because every function authenticates with a bearer token rather than a cookie. |

`SUPABASE_URL`, `SUPABASE_ANON_KEY`, and `SUPABASE_SERVICE_ROLE_KEY` are
injected automatically — do not set them by hand.

Push credentials are optional. With none configured, `_shared/push.ts` falls
back to a logging provider, so local development and CI exercise the same code
path without depending on Apple or Google.

```bash
supabase secrets set \
  STRIPE_SECRET_KEY=sk_test_… \
  STRIPE_WEBHOOK_SECRET=whsec_… \
  ANTHROPIC_API_KEY=sk-ant-…

# The .p8 needs its newlines preserved:
supabase secrets set APNS_PRIVATE_KEY="$(awk '{printf "%s\\n", $0}' AuthKey_XXXXXXXX.p8)"
```

`.gitignore` blocks `*.p8`, `*.p12`, `*.mobileprovision`, and `.env` — nothing
above belongs in the repository.

---

## 4. Environments

`PRVFoundation.AppEnvironment` resolves `PRVEnvironment` from the app's
Info.plist and returns a base URL. Each maps to its own Supabase project — the
same schema, separate data, separate keys — fronted by a custom domain so the
app never has a project ref compiled into it.

| `AppEnvironment` | `supabaseURL` | Project | Stripe | Anthropic |
|---|---|---|---|---|
| `.development` | `https://dev.api.prvbeauty.com` | `prv-beauty-dev` | test keys | shared dev key |
| `.staging` | `https://staging.api.prvbeauty.com` | `prv-beauty-staging` | test keys | shared dev key |
| `.production` | `https://api.prvbeauty.com` | `prv-beauty-prod` | live keys | production key |

`AppEnvironment.current` defaults to `.production` when the key is missing or
malformed, so a misconfigured build can never point at development data. The
custom domain must cover both the REST path (`/rest/v1`) and the functions path
(`/functions/v1`); `URLSessionAPIClient` appends the path to the base URL, and
Edge Functions are reached at `<base>/functions/v1/<name>`.

Promote a change dev → staging → production with the same `supabase db push`
against each linked project. Never hand-edit a hosted schema: the migration
files are the definition.

---

## 5. Security model

The full statement is in [`docs/SECURITY.md`](../docs/SECURITY.md). What this
directory is responsible for:

**Deny by default.** RLS is enabled on every table in `0002_rls.sql`. Enabling
RLS without a policy denies the operation, so a table that appears there with
only a `SELECT` policy cannot be written by any client. Four access shapes:

- *Public read* — the marketing surface only: active salons, their services and
  professionals, approved reviews, membership plans, packages. `anon` sees what
  a search engine could see and nothing more.
- *Own rows* — clients read and write only rows keyed to `auth.uid()`.
- *Salon-scoped* — staff reach rows for a salon they work at, resolved by the
  security-definer helper `is_salon_member(uuid)`. Salon A can never read salon
  B's CRM, revenue, notes, or payroll.
- *Append-only* — `audit_log` has an `INSERT` policy and no `UPDATE`/`DELETE`
  policy, and those privileges are revoked. History cannot be rewritten.

**Permissions, not roles.** `role_permissions` is the server-side mirror of
`UserRole.permissions` in Swift. Policies check `has_permission('manageCRM')`,
never a role name. Client-side `RoleGate` is a UX affordance; a tampered client
gains nothing.

**Payments never touch the client.** Card data never reaches the app or this
database — `saved_payment_methods` stores a Stripe token and the last four
digits, nothing else. `create-payment-intent` proves ownership through RLS
(reading the order with the caller's own JWT), recomputes the amount from
`order_totals`, and creates the intent with an idempotency key derived from the
order and the amount, so a retried request can never double-charge. An order
becomes `paid` in exactly one place: `stripe-webhook`, after signature
verification.

**Booking is transactional.** `book_appointment(jsonb)` is the only supported
way to create an appointment, because it is the only path that takes the locks:
an advisory transaction lock per professional, `SELECT … FOR UPDATE` over
overlapping items, and — as the final arbiter — a gist exclusion constraint on
`appointment_items`. Two clients racing for the last 10:00 slot get one booking
and one `PRV09` conflict, never two bookings.

**The engines agree.** Cancellation fees and refund decisions are computed
identically on both sides: `cancel-appointment` mirrors
`PRVBookingKit.CancellationEngine` and `PRVPaymentsKit.RefundEngine`
branch for branch, down to banker's rounding in whole cents
(`_shared/money.ts`). The figure quoted in the app is the figure charged.

**AI output is a recommendation, never an authorization.**
`assistant-recommend` builds the model's candidate catalogue with the *caller's*
JWT, so RLS decides what the model can see; every id in the reply is then
intersected back against that catalogue, so a hallucinated or out-of-scope id is
dropped before the response is returned.

**Everything privileged is audited.** Refunds, cancellations, payment
settlement, and policy changes write an `audit_log` row with actor, action,
entity, and a JSON detail — insert-only, by policy and by privilege.

---

## 6. Conventions

- **snake_case everywhere.** Combined with `JSONDecoder.KeyDecodingStrategy
  .convertFromSnakeCase` in `PRVNetworking.JSONCoding`, a PostgREST row decodes
  into a domain type with no mapping layer. Enum labels match Swift `RawValue`s
  byte for byte. The one deliberate exception is the `permission` enum, whose
  labels are camelCase because `Permission` has no explicit raw values in Swift.
- **Money is `numeric(12,2)` + `char(3)`.** Never a float, on either side of the
  wire. `Money` decodes from `{ "amount": …, "currency": "EUR" }`.
- **Time is `timestamptz`.** The database is the clock; the client formats.
- **Totals are derived, not stored.** `order_totals` and `wallet_balances` are
  `security_invoker` views, so a view can never be used to sidestep a policy.
- **Migrations are append-only.** Add `000N_…sql`; never edit an applied file.
