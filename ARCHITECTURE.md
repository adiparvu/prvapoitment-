# PRV Beauty — Platform Architecture

PRV Beauty is the operating system for the beauty industry: one native Apple ecosystem
connecting clients, salons, freelancers, and enterprise beauty businesses.

This document is the **binding contract** for every module in the codebase. All code must
conform to it. When in doubt, choose the more scalable, maintainable, secure, performant,
and Apple-aligned option.

---

## 1. Technology baseline

| Concern            | Decision                                                       |
|--------------------|----------------------------------------------------------------|
| UI                 | SwiftUI only (no UIKit unless technically unavoidable)         |
| Language           | Swift 6, strict concurrency (`Sendable` everywhere)            |
| Minimum OS         | iOS 26 (Liquid Glass APIs), forward-compatible with iOS 27     |
| Architecture       | MV — Views + `@Observable` models/services (no VIPER/ViewModels-for-their-own-sake) |
| State              | `@Observable`, `@State`, `@Environment`; unidirectional data flow |
| Concurrency        | Swift Concurrency (`async/await`, actors); no GCD              |
| Persistence        | SwiftData (offline-first), CloudKit for personal-device sync   |
| Backend            | Supabase (PostgreSQL + RLS + Edge Functions), Stripe, APNs/Firebase |
| DI                 | `PRVDependencies` container injected via SwiftUI `Environment` |
| Design language    | Apple HIG, Liquid Glass (`glassEffect`, `GlassEffectContainer`), SF Symbols, SF Pro |
| Testing            | Swift Testing (`import Testing`) for unit tests; XCTest for UI tests |

## 2. Repository layout

```
PRVBeauty/
├── project.yml                  # XcodeGen manifest → generates PRVBeauty.xcodeproj
├── App/                         # App target (thin shell) + Widget extension
│   ├── Sources/                 # @main app, root scene, role-based root navigation
│   └── Widgets/                 # WidgetKit + Live Activities extension
├── Package.swift                # All modules live in one local SPM package
├── Sources/
│   ├── PRVFoundation/           # Utilities, logging, feature flags, environment
│   ├── PRVModels/               # Domain models + shared contracts (pure, Sendable)
│   ├── PRVDesignSystem/         # Liquid Glass tokens + component library
│   ├── PRVNetworking/           # API client, repository protocols, Supabase impls
│   ├── PRVPersistence/          # SwiftData stores, offline-first sync engine
│   ├── PRVBookingKit/           # Booking domain engine (slots, waitlist, optimization)
│   ├── PRVPaymentsKit/          # Pricing, prepayment benefits, refunds, splits
│   ├── PRVLoyaltyKit/           # XP, tiers, achievements, referrals
│   ├── PRVAuthFeature/          # Sign-in, passkeys, Face ID, onboarding, RBAC gates
│   ├── PRVHomeFeature/          # Client home
│   ├── PRVDiscoverFeature/      # AI search, filters, map
│   ├── PRVSalonProfileFeature/  # Salon + professional profiles, reviews
│   ├── PRVBookingFeature/       # Booking flow UI
│   ├── PRVPaymentsFeature/      # Checkout, Apple Pay, invoices
│   ├── PRVWalletFeature/        # Beauty Wallet, loyalty UI
│   ├── PRVMembershipsFeature/   # Memberships, packages, gift cards
│   ├── PRVChatFeature/          # Encrypted chat + AI Beauty Assistant
│   ├── PRVNotificationsFeature/ # Notification center, Live Activity models
│   ├── PRVDashboardFeature/     # Salon dashboard, analytics, reports
│   ├── PRVCRMFeature/           # Customer profiles, notes, consent forms
│   └── PRVOperationsFeature/    # Employees, inventory, marketing
├── Tests/                       # One test target per Kit + Models
├── Backend/
│   └── supabase/
│       ├── migrations/          # SQL schema + RLS policies
│       └── functions/           # TypeScript Edge Functions
└── docs/
```

## 3. Dependency rules (enforced by Package.swift)

```
PRVFoundation          ← no dependencies
PRVModels              ← PRVFoundation
PRVDesignSystem        ← PRVFoundation
PRVNetworking          ← PRVFoundation, PRVModels
PRVPersistence         ← PRVFoundation, PRVModels
PRV*Kit                ← PRVFoundation, PRVModels          (pure domain logic, no UI)
PRV*Feature            ← PRVDesignSystem, PRVModels, PRVNetworking (+ relevant Kits)
App target             ← all features
```

- **Features never import other features.** Cross-feature navigation goes through
  `AppRoute` / `AppRouter` (defined in `PRVModels/Navigation.swift`).
- **Kits contain zero SwiftUI.** They are deterministic, fully unit-testable engines.
- **Models are pure data**: `Codable`, `Hashable`, `Sendable`, `Identifiable` value types.

## 4. Shared contracts

### 4.1 Identifiers
Tagged IDs prevent mixing entity IDs: `PRVID<Salon>`, `PRVID<Appointment>`, etc.
(`Sources/PRVModels/Identifiers.swift`).

### 4.2 Dependency injection
`PRVDependencies` (in `PRVNetworking/Dependencies.swift`) aggregates every repository
protocol. It is injected once at app root:

```swift
@Environment(\.prvDependencies) private var deps
```

Features resolve repositories from it. Live implementations are Supabase-backed;
`InMemoryRepositories` power previews, tests, and offline demo mode.

### 4.3 Feature root views (exact public API each feature MUST expose)

| Module                  | Public root view(s)                                            |
|-------------------------|----------------------------------------------------------------|
| PRVAuthFeature          | `AuthRootView`, `OnboardingView`                               |
| PRVHomeFeature          | `HomeView`                                                     |
| PRVDiscoverFeature      | `DiscoverView`                                                 |
| PRVSalonProfileFeature  | `SalonProfileView(salonID:)`, `ProfessionalProfileView(professionalID:)` |
| PRVBookingFeature       | `BookingFlowView(context:)`, `AppointmentsListView`            |
| PRVPaymentsFeature      | `CheckoutView(order:)`                                         |
| PRVWalletFeature        | `WalletView`, `LoyaltyView`                                    |
| PRVMembershipsFeature   | `MembershipsView`, `PackagesView`, `GiftCardsView`             |
| PRVChatFeature          | `ChatListView`, `ConversationView(conversationID:)`, `BeautyAssistantView` |
| PRVNotificationsFeature | `NotificationCenterView`                                       |
| PRVDashboardFeature     | `SalonDashboardView`, `AnalyticsView`                          |
| PRVCRMFeature           | `CRMView`, `ClientDetailView(clientID:)`                       |
| PRVOperationsFeature    | `TeamView`, `InventoryView`, `MarketingView`                   |

All root views take dependencies from the environment — initializers stay minimal
(IDs/context only).

### 4.4 Design system usage (mandatory)

- Colors: `Color.prv.*` (semantic tokens) — never hard-coded hex in features.
- Typography: `.prvStyle(.title)`, `.prvStyle(.body)` etc.
- Spacing: `PRVSpacing.*` (4-pt grid). Corner radii: `PRVRadius.*` (large, continuous).
- Glass surfaces: `.prvGlassCard()`, `GlassEffectContainer`, `.glassEffect(...)`
  with `Reduce Transparency` fallbacks built into the components.
- Haptics: `PRVHaptics.tap()/success()/warning()` — never raw `UIImpactFeedbackGenerator`.
- Motion: `PRVMotion.spring` etc., all animation respects `accessibilityReduceMotion`.
- Accessibility: every interactive element has a label; Dynamic Type never truncates.

## 5. Roles & permissions

`UserRole` + `Permission` live in `PRVModels/User.swift`. UI gates use
`RoleGate(requires: .manageInventory) { ... }` from PRVAuthFeature or check
`session.can(.permission)`. Never branch on raw role names in feature code — always
check permissions.

## 6. Offline-first & sync

Repositories return cached data immediately and refresh in the background
(`AsyncStream`-based observation where live updates matter). `PRVPersistence.SyncEngine`
reconciles local mutations (queued as `SyncOperation`s) against Supabase with
last-write-wins + server-authoritative conflict resolution for bookings/payments.

## 7. Security

- Keychain-backed session tokens (`PRVAuthFeature.SessionStore`).
- Face ID / Touch ID / Passkeys for auth; app-lock option.
- Postgres Row Level Security for every table; clients only ever see rows they own.
- Payments never touch client code: Stripe PaymentSheet + Edge Function-created intents.
- Audit log entries for every privileged mutation.
- GDPR: export + erase flows; consent forms versioned in CRM.

## 8. Module ownership discipline (for contributors and codegen agents)

- Only create/edit files inside the module directory you own, plus its test target.
- Never redefine a type that belongs to PRVModels/PRVFoundation — import it.
- If a shared type seems missing, define a `private`/`internal` type in your module
  and flag it for promotion — do not edit shared files.
- Previews: use `PreviewData` from PRVModels and `InMemoryRepositories`.

## 9. Quality bar

Every screen must be worthy of an Apple Keynote demo: 120 fps-friendly (no heavy work
in `body`), layered glass depth, continuous corner curves, spring-based motion, full
Dark Mode + Dynamic Type + VoiceOver + Reduce Motion/Transparency support.
