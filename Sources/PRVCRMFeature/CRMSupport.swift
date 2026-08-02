import Foundation
import SwiftUI
import PRVDesignSystem
import PRVFoundation
import PRVModels
import PRVNetworking

// MARK: - Phase

/// Loading lifecycle of a CRM screen.
enum CRMPhase: Equatable, Sendable {
    case loading
    case loaded
    case failed(String)

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}

// MARK: - Copy

/// Warm, actionable failure copy for the client book.
enum CRMCopy {
    nonisolated static func friendlyMessage(for error: any Error) -> String {
        guard let apiError = error as? APIError else {
            return "Something went wrong. Pull to refresh to try again."
        }
        return switch apiError {
        case .offline, .network:
            "You appear to be offline. Client records will sync as soon as you reconnect."
        case .rateLimited:
            "The client book is catching up. Give it a moment and pull to refresh."
        case .unauthorized, .forbidden:
            "You don't have access to client records. Ask an owner to update your permissions."
        case .notFound:
            "We couldn't find that client. They may have been merged or removed."
        case .conflict, .server, .decoding:
            "We couldn't load the client book right now. Pull to refresh to try again."
        }
    }
}

// MARK: - Sorting

/// How the client list is ordered.
enum ClientSort: String, CaseIterable, Hashable, Sendable, Identifiable {
    case lastVisit
    case name
    case spend
    case visits

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lastVisit: "Last visit"
        case .name: "Name"
        case .spend: "Total spend"
        case .visits: "Visit count"
        }
    }

    var symbolName: String {
        switch self {
        case .lastVisit: "clock.arrow.circlepath"
        case .name: "textformat.abc"
        case .spend: "creditcard"
        case .visits: "number"
        }
    }

    /// Applies the ordering. Clients who have never visited sort last under
    /// `.lastVisit` rather than jumping to the top with a distant-past date.
    func apply(to clients: [ClientRecord]) -> [ClientRecord] {
        switch self {
        case .lastVisit:
            clients.sorted { lhs, rhs in
                switch (lhs.lastVisitAt, rhs.lastVisitAt) {
                case let (left?, right?): left > right
                case (nil, _?): false
                case (_?, nil): true
                case (nil, nil): lhs.fullName.localizedCaseInsensitiveCompare(rhs.fullName) == .orderedAscending
                }
            }
        case .name:
            clients.sorted {
                $0.fullName.localizedCaseInsensitiveCompare($1.fullName) == .orderedAscending
            }
        case .spend:
            clients.sorted { $0.totalSpend.amount > $1.totalSpend.amount }
        case .visits:
            clients.sorted { $0.totalVisits > $1.totalVisits }
        }
    }
}

// MARK: - Tiers

/// A client's standing with the salon, derived from spend and visit history.
/// Used for the list badge so the front desk recognizes regulars instantly.
enum ClientTier: Hashable, Sendable {
    case new
    case returning
    case vip

    static func tier(for record: ClientRecord) -> ClientTier {
        if record.totalSpend.amount >= 1_500 || record.totalVisits >= 20 { return .vip }
        if record.totalVisits >= 3 { return .returning }
        return .new
    }

    var title: String {
        switch self {
        case .new: "New"
        case .returning: "Regular"
        case .vip: "VIP"
        }
    }

    var tint: Color {
        switch self {
        case .new: Color.prv.accent
        case .returning: Color.prv.success
        case .vip: Color.prv.gold
        }
    }
}

// MARK: - Formatting

/// Shared CRM formatting.
enum CRMFormat {
    /// Relative last-visit copy, e.g. "2 weeks ago" or "Never visited".
    static func lastVisit(_ date: Date?) -> String {
        guard let date else { return "No visits yet" }
        return date.formatted(.relative(presentation: .named)).capitalizedFirstLetter
    }

    /// Absolute date for detail screens.
    static func day(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }

    /// Date and time for the visit history.
    static func dayTime(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    /// Birthday without a year, e.g. "14 March".
    static func birthday(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.wide))
    }
}

extension String {
    /// Uppercases the first character only, leaving the rest untouched.
    var capitalizedFirstLetter: String {
        guard let first else { return self }
        return String(first).uppercased() + dropFirst()
    }
}

// MARK: - Note kinds

extension ClientNote.Kind {
    /// Human label used in pickers and note headers.
    var title: String {
        switch self {
        case .general: "Note"
        case .colorFormula: "Colour formula"
        case .treatment: "Treatment"
        case .photo: "Photo"
        }
    }

    var symbolName: String {
        switch self {
        case .general: "text.alignleft"
        case .colorFormula: "paintpalette"
        case .treatment: "sparkles"
        case .photo: "photo"
        }
    }

    var tint: Color {
        switch self {
        case .general: Color.prv.textSecondary
        case .colorFormula: Color.prv.accent
        case .treatment: Color.prv.success
        case .photo: Color.prv.gold
        }
    }
}

// MARK: - Consent templates

/// A consent document the salon can capture a signature against.
///
/// The platform contract stores signed `ConsentForm`s but does not yet publish
/// a template catalogue, so the standard set lives here. Move it behind a
/// repository once the backend exposes versioned documents per salon.
struct ConsentTemplate: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let version: String
    let details: String

    static let standard: [ConsentTemplate] = [
        ConsentTemplate(
            id: "colour",
            title: "Colour Service Consent",
            version: "2.1",
            details: "Covers patch testing, expected results, and aftercare for colour services."
        ),
        ConsentTemplate(
            id: "patch-test",
            title: "Patch Test Declaration",
            version: "1.4",
            details: "Confirms a 48-hour patch test was offered and its outcome recorded."
        ),
        ConsentTemplate(
            id: "photography",
            title: "Photography & Marketing",
            version: "1.2",
            details: "Permission to photograph results and use them in salon marketing."
        ),
        ConsentTemplate(
            id: "gdpr",
            title: "Data Processing (GDPR)",
            version: "3.0",
            details: "How the salon stores, uses, and erases personal and treatment data."
        ),
    ]
}

// MARK: - Section chrome

/// A titled CRM section: header plus content, with consistent rhythm.
struct CRMSection<Content: View>: View {
    private let title: String
    private let subtitle: String?
    private let content: Content

    init(_ title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.sm) {
            PRVSectionHeader(title, subtitle: subtitle)
            content
        }
    }
}

/// Inline failure card with a retry, for sections that can fail alone.
struct CRMErrorCard: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: PRVSpacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.body)
                .foregroundStyle(Color.prv.warning)
                .accessibilityHidden(true)

            Text(message)
                .prvStyle(.footnote)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: PRVSpacing.xs)

            Button("Retry") {
                PRVHaptics.tap()
                retry()
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Color.prv.accent)
            .buttonStyle(.plain)
            .accessibilityLabel("Retry loading this section")
        }
        .prvGlassCard()
    }
}

// MARK: - Skeletons

/// Shimmering placeholder rows for the client list.
struct ClientListSkeleton: View {
    var body: some View {
        VStack(spacing: PRVSpacing.sm) {
            ForEach(0 ..< 6, id: \.self) { _ in
                HStack(spacing: PRVSpacing.sm) {
                    PRVSkeleton(width: 44, height: 44, radius: 22)
                    VStack(alignment: .leading, spacing: PRVSpacing.xxs) {
                        PRVSkeleton(width: 150, height: 15)
                        PRVSkeleton(width: 100, height: 11)
                    }
                    Spacer()
                    PRVSkeleton(width: 56, height: 20, radius: 10)
                }
                .prvGlassCard()
            }
        }
        .accessibilityLabel("Loading clients")
    }
}

/// Shimmering placeholder for the client detail screen.
struct ClientDetailSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.xl) {
            HStack(spacing: PRVSpacing.md) {
                PRVSkeleton(width: 64, height: 64, radius: 32)
                VStack(alignment: .leading, spacing: PRVSpacing.xxs) {
                    PRVSkeleton(width: 160, height: 20)
                    PRVSkeleton(width: 110, height: 12)
                }
                Spacer()
            }

            PRVSkeleton(height: 120, radius: PRVRadius.lg)
            PRVSkeleton(height: 88, radius: PRVRadius.lg)
            PRVSkeleton(height: 160, radius: PRVRadius.lg)
        }
        .accessibilityLabel("Loading client")
    }
}
