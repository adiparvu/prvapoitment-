# Localization

PRV Beauty ships in **English (en)**, **Dutch (nl)**, and **French (fr)** — the three
languages the product targets in Belgium, where a single salon routinely serves clients
in all three. This document is the contract for anyone adding or translating user-facing
text.

---

## 1. Where the strings live

Localized text lives in **String Catalogs** (`.xcstrings`). There is one catalog per
bundle, because `NSLocalizedString` lookup is always scoped to a bundle:

| Catalog | Bundle | Owns |
|---------|--------|------|
| `App/Resources/Localizable.xcstrings` | `Bundle.main` | The app shell and every feature module's user-facing text |
| `Sources/PRVDesignSystem/Resources/Localizable.xcstrings` | `Bundle.module` (PRVDesignSystem) | The design system's own built-in text |

### Why the feature strings sit in the app catalog

SwiftUI's `Text(_ key: LocalizedStringKey)` and Foundation's `String(localized:)` both
default to **`Bundle.main`**, *including when they are called from inside a Swift package
target*. A literal such as

```swift
// Sources/PRVBookingFeature/BookingConfirmationView.swift
Text("Add to Calendar")
```

therefore resolves against the **app** bundle, not `PRVBookingFeature`'s. The app catalog
is consequently the correct — and only — place those strings can be translated without
editing the feature modules.

That is deliberate for now: it lets the whole platform become trilingual without touching
262 Swift files. As modules adopt `bundle: .module` (§3) their strings migrate into
per-module catalogs; until then, keep them in the app catalog.

### File format

Each catalog is JSON:

```jsonc
{
  "sourceLanguage": "en",
  "strings": {
    "Confirm Booking": {
      "comment": "Booking flow primary CTA on the review step.",
      "extractionState": "manual",
      "localizations": {
        "en": { "stringUnit": { "state": "translated", "value": "Confirm Booking" } },
        "fr": { "stringUnit": { "state": "translated", "value": "Confirmer le rendez-vous" } },
        "nl": { "stringUnit": { "state": "translated", "value": "Afspraak bevestigen" } }
      }
    }
  },
  "version": "1.0"
}
```

Notes on the shape we use:

- The **key is the English source string**. Never invent symbolic keys — Xcode's catalog
  editor, the extractor, and the fallback path all assume key == source text.
- `"extractionState": "manual"` marks an entry as hand-authored. Many of our strings reach
  the UI as plain `String` arguments (`PRVEmptyState(title:message:)`,
  `AppointmentStatus.displayName`), which Xcode's extractor cannot see. Without `manual`,
  Xcode would flag them `stale` and offer to delete them. Entries that *are* extractable
  will be re-marked automatically once the call site adopts `String(localized:)`.
- `"state": "translated"` on every unit. Use `"needs_review"` for machine-assisted drafts
  and `"new"` for untranslated placeholders — **never ship either.**
- `comment` is the translator's only context. Write what the string *is* and where it
  appears, not what it says.
- Keys are sorted case-insensitively so diffs stay readable. Xcode preserves this.

### Plurals

Counted strings use `variations.plural`, not string concatenation:

```jsonc
"%lld treatments": {
  "localizations": {
    "nl": {
      "variations": {
        "plural": {
          "one":   { "stringUnit": { "state": "translated", "value": "%lld behandeling" } },
          "other": { "stringUnit": { "state": "translated", "value": "%lld behandelingen" } }
        }
      }
    }
  }
}
```

Call sites use `String(localized: "\(count) treatments")` — the catalog resolves the
category. Do **not** write `count == 1 ? "1 treatment" : "\(count) treatments"`; that is
correct only for English.

---

## 2. Build wiring

### Swift package targets

`Package.swift` already declares `defaultLocalization: "en"`, which is the prerequisite for
any localized resource in an SPM target. A target that carries a catalog additionally
needs its `Resources` directory processed:

```swift
resources: [.process("Resources")]
```

The `target(_:dependencies:hasResources:)` helper in `Package.swift` already emits exactly
that when `hasResources: true` is passed. **PRVDesignSystem must be switched to
`hasResources: true`** — see the integrator checklist in §7.

`.process` (not `.copy`) is required: it is what runs `XCStringsTool` over the catalog and
emits the per-language `.lproj/Localizable.strings` into the module bundle. `.copy` would
ship the raw JSON, which resolves to nothing at runtime.

### App target (XcodeGen)

`project.yml` already lists `App/Resources` under the app target's `sources`, so the
catalog is picked up and compiled with no further build-phase work.

Two project-level settings still matter:

- `options.developmentLanguage: en` — already set; this is the source language.
- The shipped languages must be **declared** on the bundle. XcodeGen derives
  `knownRegions` from localized resource folders (`en.lproj`, `nl.lproj`, …). String
  Catalogs have none, so add `CFBundleLocalizations` to the app target's Info.plist
  properties instead — it is the documented, always-honoured mechanism and is directly
  expressible in `project.yml`:

  ```yaml
  info:
    properties:
      CFBundleLocalizations: [en, nl, fr]
  ```

  Without it, iOS may not offer PRV Beauty in the per-app language picker even though the
  translations are in the binary.

- The `Info.plist` **usage descriptions** in `project.yml` (`NSFaceIDUsageDescription`,
  `NSLocationWhenInUseUsageDescription`, …) are user-facing prompts and are **not** covered
  by `Localizable.xcstrings`. They localize through a separate `InfoPlist.xcstrings`
  catalog. That file is not yet written; see §7.

---

## 3. How features should reference strings

### Inside a package target (`Sources/PRV*`)

Always pass the module bundle. Without it the lookup silently falls through to
`Bundle.main` and the module's own catalog is dead weight.

```swift
// Views
Text("See All", bundle: .module)
Label("Join the Waitlist", systemImage: "clock.badge", bundle: .module)
Button("Apply") { … }                     // ⚠️ no bundle parameter — see below

// Anything that must produce a String
let title = String(localized: "Fully booked", bundle: .module)

// Values that cross a concurrency boundary (Swift 6): LocalizedStringResource is Sendable
let prompt = LocalizedStringResource("Search", bundle: .atURL(Bundle.module.bundleURL))
```

`Button(_ titleKey:action:)` and friends take a `LocalizedStringKey` with **no** bundle
parameter. When a module needs its own bundle, build the label explicitly:

```swift
Button { … } label: { Text("Apply", bundle: .module) }
```

### Inside the app target (`App/Sources`)

`Bundle.main` is already correct, so the bundle argument is unnecessary:

```swift
Text("Sign In")
String(localized: "Settings")
```

### The three ways a string fails to localize

1. **`Text(someString)`** — passing a `String` variable selects the
   `Text(_ content: some StringProtocol)` overload, which performs **no** lookup. This is
   how every `displayName` currently reaches the screen:

   ```swift
   // Sources/PRVModels/Appointment.swift — returns a plain String, never localized
   public var displayName: String {
       switch self {
       case .pendingConfirmation: "Pending"
       …
   ```

   The fix is at the definition, not the call site:

   ```swift
   public var displayName: String {
       switch self {
       case .pendingConfirmation: String(localized: "Pending", bundle: .module)
       …
   ```

   The English text is unchanged, so the catalog keys already in this repo keep matching.

2. **String parameters on design-system components.** `PRVEmptyState(title:message:)`,
   `PRVSectionHeader(_:subtitle:actionTitle:)`, and `PRVSearchField(prompt:)` all take
   `String`. Callers must localize before passing:

   ```swift
   PRVEmptyState(
       systemImage: "calendar.badge.plus",
       title: String(localized: "Nothing on the books"),
       message: String(localized: "When you book a treatment it shows up here, with reminders so you never miss it.")
   )
   ```

   The longer-term fix is to widen those parameters to `LocalizedStringResource`.

3. **String interpolation into a literal.** `Text("\(count) treatments")` produces a
   `LocalizedStringKey` whose key is `"%lld treatments"` — which is why the plural entries
   in the catalog use that exact spelling. Interpolating a *variable* phrase
   (`Text("\(prefix) treatments")`) produces `"%@ treatments"` and is not translatable in
   any useful way. Never assemble sentences from fragments.

### Formatting is not translation

Dates, times, currency, distances, and percentages must go through `Date.FormatStyle`,
`Measurement`, and `Decimal.FormatStyle` with the current locale — not through the catalog.
`Money.formatted` (`.currency(code:)`) and `BookingFormatting.time` / `.shortDay`
(`.dateTime`) already do this. Belgium uses `12,50 €` in fr-BE and `€ 12,50` in nl-BE;
hard-coding either is a bug.

One formatter is **not** locale-aware yet: `BookingFormatting.duration` builds
`"1 h 30 min"` from hard-coded unit strings, and Dutch abbreviates hours as `u`, not `h`.
The correct fix is `Duration.UnitsFormatStyle`, which localizes with no catalog entry at
all:

```swift
Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
```

Until that lands, the catalog carries `%lld min`, `%lld h`, and `%1$lld h %2$lld min` so
the existing formatter can be localized in place.

---

## 4. Translation conventions

### Voice

| Language | Register | Rationale |
|----------|----------|-----------|
| en | Warm, direct, second person. Sentence case. | Matches the existing product copy. |
| nl | Informal **je/jij**, never **u**. | The Flemish beauty market is informal; `u` reads like a bank. |
| fr | Formal **vous**, never **tu**. | Belgian French service register; `tu` reads as over-familiar from a business. |

Apply this consistently — mixing registers inside one flow is the most visible
localization defect there is.

### Typography

- **French** requires a space before `? ! : ; %` and around `« »`. Written as a normal
  space in the catalog; the layout engine handles the rest.
  `Pourquoi annulez-vous ?` · `100 % va à votre artiste`
- **Apostrophes**: use the typographic apostrophe `’` (U+2019) in fr and nl, not `'`.
  `l’IA`, `d’annulation`, `diploma’s`.
- **Dutch compounds** are written closed: `annuleringsvoorwaarden`, `wachtlijstplaatsen`,
  `salonmedewerker`. Do not anglicize them into spaced pairs.
- **Em dashes** (`—`) in the English source are kept in both translations; they carry the
  brand's cadence.

### Beauty-industry glossary

Terms of art are not translated word for word. This table is binding:

| English | nl-BE | fr-BE |
|---------|-------|-------|
| appointment | afspraak | rendez-vous |
| booking (the act) | boeken | réserver |
| treatment / service | behandeling | soin |
| artist / professional | artiest | artiste |
| salon | salon | salon |
| hair salon | kapsalon | salon de coiffure |
| nail studio | nagelstudio | onglerie |
| lash / brow studio | wimper- / wenkbrauwstudio | studio de cils / sourcils |
| esthetics | schoonheidsverzorging | esthétique |
| waitlist | wachtlijst | liste d’attente |
| time slot | tijdslot | créneau |
| deposit / prepayment | voorschot | acompte |
| store credit | tegoed | avoir |
| gift card | cadeaubon | chèque-cadeau |
| invoice | factuur | facture |
| tip | fooi | pourboire |
| loyalty tier | niveau | niveau |
| review | beoordeling | avis |
| fully booked | volgeboekt / volzet | complet |

**Never translated** — brand and industry terms that Belgian clients use in English or
French regardless of interface language:

`PRV Beauty` · `Beauty Wallet` · `Beauty Assistant` · `Wallet` · `XP` · `Apple Pay` ·
`Bancontact` · `PayPal` · `Stripe` · `Face ID` · `balayage` · `gloss` · `brushing` ·
`Black` (the top loyalty tier, a name like Amex Black)

`balayage` in particular is a French word already naturalized into Dutch and English
salon menus — it stays `balayage` in all three catalogs, exactly as `PreviewData` spells it.

### Length

Dutch and French run **20–35 % longer** than English. Any string destined for a fixed-width
control (tab titles, chips, segmented controls, bottom-bar CTAs) must be checked at
`.accessibilityExtraExtraExtraLarge` in all three languages before merge. Per
`ARCHITECTURE.md` §9, Dynamic Type must never truncate — if a translation does not fit, the
fix is a shorter translation or a taller layout, never `minimumScaleFactor`.

---

## 5. Pseudolocalization

Pseudolocalization catches the two defects real translation reviews always miss: text that
was never routed through the catalog, and layouts that break under longer text. Run it
before you run a translator.

### The three levels

**Level 1 — find un-catalogued text (every PR that touches UI).**

```
-NSShowNonLocalizedStrings YES
```

Any string that has no catalog entry is rendered in `ALL CAPS`. Anything shouting at you on
screen is either a bug or a genuinely non-localizable token (a name, a price, a code).

**Level 2 — find truncation (any layout change).**

```
-NSDoubleLocalizedStrings YES
```

Every localized string is doubled. This overshoots the real nl/fr expansion (~35 %) on
purpose: a layout that survives doubling survives Belgium. Combine with the largest Dynamic
Type size and the smallest supported device.

**Level 3 — the real thing (before release).**

```
-AppleLanguages (nl)
-AppleLocale nl_BE
```
```
-AppleLanguages (fr)
-AppleLocale fr_BE
```

The locale matters as much as the language: `nl_BE` and `fr_BE` drive the comma decimal
separator, the `€` position, the 24-hour clock, and Monday-first weeks.

Set these in **Edit Scheme → Run → Arguments → Arguments Passed On Launch**, or use
**Edit Scheme → Run → Options → App Language**, which exposes Apple's built-in
*Double-Length Pseudolanguage*, *Accented Pseudolanguage*, *Bounded String Pseudolanguage*,
and *Right-to-Left Pseudolanguage* as one-click equivalents.

### Bracketed pseudolocale for CI screenshots

For automated screenshot diffing, a bracketed accented pseudolocale is more legible than
double-length because the boundaries of every string are visible. Generate it into a
**copy** of the catalog — never commit a pseudo-language into the shipping catalogs:

```bash
python3 - <<'PY'
import json, pathlib, re

SRC = pathlib.Path("App/Resources/Localizable.xcstrings")
DST = pathlib.Path("build/pseudo/Localizable.xcstrings")   # gitignored
ACCENT = str.maketrans("aeiouAEIOUcnsyCNSY", "áéíóúÁÉÍÓÚçñšýÇÑŠÝ")

# A full printf specifier: %@, %lld, %1$@, %2$lld, %.2f, %%. A bare "%" (as in
# "100% goes to your artist") deliberately does not match and is accented as text.
SPECIFIER = re.compile(
    r"%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:hh|h|ll|l|q|z|t|j|L)?[@dDuUxXoOfFeEgGcCsSpaA%]"
)

def pseudo(value: str) -> str:
    """Accents the prose, preserves every format specifier, pads 40% to expose truncation."""
    body, cursor = [], 0
    for match in SPECIFIER.finditer(value):
        body.append(value[cursor:match.start()].translate(ACCENT))
        body.append(match.group())
        cursor = match.end()
    body.append(value[cursor:].translate(ACCENT))
    text = "".join(body)
    return f"⟦{text}{'·' * max(2, len(text) * 2 // 5)}⟧"

catalog = json.loads(SRC.read_text(encoding="utf-8"))
for entry in catalog["strings"].values():
    en = entry["localizations"]["en"]
    if "stringUnit" in en:
        entry["localizations"]["en-XA"] = {
            "stringUnit": {"state": "translated", "value": pseudo(en["stringUnit"]["value"])}
        }
    else:
        entry["localizations"]["en-XA"] = {
            "variations": {"plural": {
                category: {"stringUnit": {"state": "translated",
                                          "value": pseudo(unit["stringUnit"]["value"])}}
                for category, unit in en["variations"]["plural"].items()
            }}
        }

DST.parent.mkdir(parents=True, exist_ok=True)
DST.write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(f"{DST}: {len(catalog['strings'])} keys pseudolocalized")
PY
```

Build with the generated catalog in place of the real one, run with
`-AppleLanguages (en-XA)`, and diff the screenshots. Three things are then visible at a
glance:

- **No brackets** around a string → it never went through the catalog.
- **A clipped `⟧`** → the layout truncates under realistic expansion.
- **A mangled `%@` or `%lld`** → the format specifier was corrupted; the call site is
  concatenating instead of interpolating.

---

## 6. Adding a language

1. **Decide the locale, not just the language.** `de` vs `de-AT`, `fr` vs `fr-CA`. PRV
   Beauty ships base languages (`nl`, `fr`) and lets the region drive formatting; only
   split when the *words* differ, not the number format.
2. **Add the language in Xcode's catalog editor** (`+` in the top-right of the
   `.xcstrings` view) for **both** catalogs. Xcode inserts empty `"state": "new"` units for
   every key.
3. **Add it to `CFBundleLocalizations`** in `project.yml`, then re-run `xcodegen generate`.
4. **Translate.** Give the translator the `comment` field and this document's glossary and
   voice table. Every unit must land on `"state": "translated"`.
5. **Check the plurals.** Categories differ per language — `nl` and `fr` use `one`/`other`,
   but Polish needs `one`/`few`/`many`/`other` and Arabic needs six. Xcode's editor shows
   exactly which categories the language requires; fill all of them.
6. **Run pseudolocalization level 3** with the new language and the matching locale, at the
   largest Dynamic Type size, on the smallest device.
7. **Check the salon-side language filter.** `SalonSearchQuery.languages` and the
   "Languages Spoken" filter carry BCP-47 codes; a new interface language should normally
   also appear there.
8. **Update this table:**

   | Language | Code | Status | Owner |
   |----------|------|--------|-------|
   | English | `en` | Source | Product |
   | Dutch (Belgium) | `nl` | Translated | Localization |
   | French (Belgium) | `fr` | Translated | Localization |

---

## 7. Adoption checklist

The catalogs are infrastructure; these are the changes that switch them on. None of them
belong to `App/Resources` or `Sources/PRVDesignSystem/Resources`, so they are listed here
rather than made.

**Build (required — nothing localizes without these):**

- [ ] `Package.swift`: change `target("PRVDesignSystem", dependencies: ["PRVFoundation"])`
      to `target("PRVDesignSystem", dependencies: ["PRVFoundation"], hasResources: true)`.
- [ ] `project.yml`: add `CFBundleLocalizations: [en, nl, fr]` to `PRVBeautyApp`'s
      `info.properties`.

**Code (per module, incremental — the app catalog works before any of this):**

- [ ] `PRVModels`: wrap every `displayName` / `title` / `shortTitle` switch arm in
      `String(localized:)` — `AppointmentStatus`, `LoyaltyTier`, `AppTab`, `UserRole`,
      `BusinessCategory`, `SalonAmenity`, `PaymentMethodKind`, `MembershipTier`,
      `SalonSearchQuery.Sort`, `SalonSearchQuery.AvailabilityWindow`. Every English value
      already has a catalog entry, so the keys match with no further edits.
      `PRVModels` will need `hasResources: true` and a catalog of its own if these should
      resolve from the module bundle rather than `Bundle.main`.
- [ ] `PRVDesignSystem`: pass `bundle: .module` at the component call sites listed in the
      design-system catalog's comments (`PRVSearchField`, `PRVQuantityStepper`,
      `PRVSectionHeader`, `PRVDateStrip`, `PRVTimeSlotPill`, `PRVProgressRing`,
      `PRVRatingStars`, `PRVToast`, `PRVStatTile`, `PRVPriceLabel`). Until then those
      strings resolve from `Bundle.main` and the module catalog is inert.
- [ ] Feature modules: replace `count == 1 ? "1 treatment" : "\(count) treatments"`-style
      branches with the plural keys (`%lld treatments`, `%lld guests`, `%lld visits`,
      `%lld points`, `%lld reviews`, `%lld unread notifications`).
- [ ] Widen `PRVEmptyState`, `PRVSectionHeader`, and `PRVSearchField` string parameters to
      `LocalizedStringResource` so callers cannot accidentally pass unlocalized text.
- [ ] `PRVBookingFeature`: move `BookingFormatting.duration` to
      `Duration.UnitsFormatStyle`, or route its unit strings through the `%lld min` /
      `%lld h` / `%1$lld h %2$lld min` keys. Dutch uses `u` for hours, so `"1 h 30 min"`
      is wrong in nl regardless of which route is taken.

**Known gaps:**

- **`InfoPlist.xcstrings` is not written.** The six usage-description prompts and
  `CFBundleDisplayName` in `project.yml` are still English-only. They need a separate
  `App/Resources/InfoPlist.xcstrings` keyed by Info.plist key
  (`NSFaceIDUsageDescription`, …), which is a different catalog format from this one.
- **Key collision on `"Review"`.** `BookingStep.shortTitle` uses it for the *review &
  pay* step; `AppointmentCard` uses it for *write a review*. A catalog key maps to exactly
  one translation, and it is currently translated as **write a review**
  (nl `Beoordelen`, fr `Évaluer`) because that call site — `Button("Review")` — is the one
  that actually performs a lookup today. When `BookingStep.shortTitle` adopts
  `String(localized:)` it must use a distinct source string (e.g. `"Summary"`), otherwise
  the booking progress bar will read "Évaluer".
- **Push notification payloads** are composed server-side in
  `Backend/supabase/functions/notify-fanout`. Localizing them needs `loc-key` / `loc-args`
  in the APNs payload plus matching entries here — the client catalog alone cannot do it.
- **Server-authored content** (salon names, service names, review text, assistant replies)
  is data, not UI text. It is never added to these catalogs; multi-language salon content
  belongs in the database, keyed by locale.

---

## 8. Coverage

The app catalog covers **440 keys** across: the tab bar and app shell; the welcome and
authentication screen including validation and every mapped `APIError`; onboarding; the
complete four-step booking flow (services, artist, time with slots and waitlist, review &
pay) plus recurrence, group booking, and the confirmation seal; the bookings list,
appointment detail, cancellation, and reschedule; checkout end to end (tips, deposits,
payment methods, gift cards, receipts, and every payment failure); the Beauty Wallet and
loyalty surfaces; Home and Discover including filters, sort orders, business categories,
and amenities; notifications; chat and the Beauty Assistant; the salon-side day book; and
the enumerated domain vocabulary — appointment statuses, loyalty tiers, payment methods,
and user roles.

The design-system catalog covers **41 keys**: the component-level empty states, `See All`,
`Search`, quantity and rating labels, slot and date-strip accessibility text, toast
affordances, stat-tile trends, price prefixes, and the loading announcements.

Both are hand-authored from the actual source. Every string in the **app** catalog is text
that appears in the app today — nothing was invented.

The **design-system** catalog additionally reserves a small accessibility vocabulary the
components do not yet emit: the loading announcements (`Loading`, `Loading content`,
`Content loaded`, `Loading failed`), the selection values (`Selected`, `Not selected`), the
stepper button labels (`Decrease`, `Increase`), the image fallbacks (`Photo`,
`Image unavailable`), and the generic empty-state title (`Nothing to show yet`). These
exist so that a component gaining a VoiceOver label needs no catalog change — pick the
reserved key rather than adding a synonym. They are listed here, not left as a TODO in
code.
