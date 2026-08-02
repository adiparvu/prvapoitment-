# PRV Beauty

**The operating system for the beauty industry** — one native Apple ecosystem connecting
clients, salons, freelancers, and enterprise beauty businesses.

Built with SwiftUI for iOS 26+, designed in Apple's Liquid Glass language, and backed by
an enterprise Supabase + Stripe platform.

**21 modules · 260 Swift files · 61.5k lines · 293 unit tests · 208 SwiftUI previews ·
8.4k lines of SQL and Edge Functions**

---

## What's inside

| Layer | Contents |
|---|---|
| **Client app** | Home, AI-powered Discover, salon & professional profiles, multi-service booking with smart slot recommendations, waitlists, recurring & group bookings, checkout with Apple Pay, prepayment benefits, Beauty Wallet, loyalty (XP, tiers, streaks, challenges, referrals), memberships, packages, gift cards, encrypted chat, AI Beauty Assistant, notifications |
| **Business app** | Salon dashboard with revenue analytics & forecasting, appointment timeline, CRM with beauty profiles / color formulas / consent forms, team scheduling & clock-in with GPS validation, payroll & goals, inventory with barcode scanning & purchase orders, marketing campaigns & coupons with AI suggestions, multi-location comparison |
| **Domain kits** | `PRVBookingKit` (availability engine, schedule optimizer, cancellation rules, recurrence, waitlist matching), `PRVPaymentsKit` (pricing, VAT, prepayment quotes, refund rules, split payments), `PRVLoyaltyKit` (XP, tiers, streaks, referrals) — pure, deterministic, fully unit-tested |
| **Platform** | Design system (Liquid Glass tokens + component library), typed domain models, repository-based data layer with offline-first sync contracts, DI via SwiftUI Environment, feature flags, structured logging |
| **Widgets** | Next-appointment & loyalty widgets, booking Live Activity with Dynamic Island |
| **Backend** | Supabase PostgreSQL schema with row-level security, transactional booking RPC, Stripe payment-intent & webhook Edge Functions, AI assistant proxy (Claude API), notification fan-out |

## Requirements

- Xcode 26+ (iOS 26 SDK — Liquid Glass APIs)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- [Supabase CLI](https://supabase.com/docs/guides/cli) for the backend (optional for demo mode)

## Getting started

```bash
# 1. Generate the Xcode project
xcodegen generate

# 2. Open and run
open PRVBeauty.xcodeproj   # select the PRVBeauty scheme, ⌘R
```

The app launches in **demo mode** out of the box: every repository is backed by a fully
functional in-memory backend (`InMemoryBackend`) seeded with realistic data, so every
screen, flow, and preview works with zero configuration.

### Running the tests

```bash
# Domain logic — no Xcode or simulator needed, runs in seconds on Linux or macOS.
# Covers the models, booking/pricing/loyalty engines, repository contracts,
# and the in-memory backend.
Scripts/linux-domain-tests.sh

# Everything, including the UI modules:
xcodebuild test -scheme PRVBeauty -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

The domain layer is deliberately pure Foundation (see
[`ARCHITECTURE.md`](ARCHITECTURE.md) §3 — kits contain zero SwiftUI), which is what
lets the rules that move money and time be verified without an Apple SDK.

### Backend

```bash
cd Backend
supabase start          # local stack
supabase db reset       # applies migrations + seed
supabase functions serve
```

See [`Backend/README.md`](Backend/README.md) for deployment, secrets
(`STRIPE_SECRET_KEY`, `ANTHROPIC_API_KEY`, APNs keys), and the security model.

## Architecture

The codebase is a modular Swift Package consumed by a thin app target — see
[`ARCHITECTURE.md`](ARCHITECTURE.md) for the binding contract: module map, dependency
rules, design-system usage, role/permission model, offline-first sync, and security.

```
App (shell) ──▶ Feature modules ──▶ Domain kits ──▶ Models
                     │                                ▲
                     └──▶ DesignSystem, Networking ───┘
```

- **MV architecture** — SwiftUI views + `@Observable` models, Swift 6 strict concurrency
- **Features never import features** — cross-feature navigation via `AppRoute`/`AppRouter`
- **Permissions, not roles** — 15 user roles resolve to granular `Permission` sets
- **Offline-first** — repositories cache locally; mutations queue through the sync engine
- **Security** — Face ID app lock, passkeys, Keychain sessions, Postgres RLS on every
  table, server-side payment intents, audit logging, GDPR export/erase
  ([`docs/SECURITY.md`](docs/SECURITY.md))

## Demo personas

Demo builds cold-launch signed out, so the welcome screen, guest browsing, and both role
experiences are all reachable. Pick a persona with a launch argument (Xcode scheme →
Arguments, or `xcrun simctl launch`):

```
-PRVDemoPersona client    # premium client — client tab bar
-PRVDemoPersona owner     # salon owner — business tab bar
```

## Deep links

The `prvbeauty://` scheme is resolved against whichever tab set is on screen, so a link
lands correctly for client and business users alike:

```
prvbeauty://salon/<uuid>              prvbeauty://appointment/<uuid>
prvbeauty://booking/<uuid>?services=  prvbeauty://checkout/<uuid>
prvbeauty://assistant                 prvbeauty://wallet | loyalty | giftcards
```

## Design language

Apple HIG throughout: Liquid Glass surfaces with Reduce Transparency fallbacks, SF
Symbols, SF Pro typography with full Dynamic Type, spring-based motion honoring Reduce
Motion, haptics, Dark Mode, and VoiceOver labels on every interactive element.
