import Foundation
import PRVFoundation
import PRVModels
import PRVNetworking

// MARK: - Phase

/// Loading lifecycle shared by every screen in the chat module.
///
/// Screens render a shimmering skeleton while `.loading`, their content once
/// `.loaded` (which may still be empty), and an inline retry surface when
/// `.failed`.
enum ChatPhase: Equatable, Sendable {
    /// The first load is in flight.
    case loading
    /// Content is available — possibly an empty list.
    case loaded
    /// The first load failed, carrying human-readable copy.
    case failed(String)

    /// Whether a skeleton should be rendered.
    var isLoading: Bool { self == .loading }
}

// MARK: - Error copy

/// Maps transport errors onto warm, actionable copy. Chat never shows raw
/// error codes to a client who just wants to talk to their salon.
enum ChatErrorCopy {
    /// Copy for a failed read (conversation list, transcript, assistant).
    static func loadFailure(_ error: any Error) -> String {
        guard let apiError = error as? APIError else {
            return "Something went wrong. Pull to refresh to try again."
        }
        return switch apiError {
        case .offline, .network:
            "You appear to be offline. Check your connection and pull to refresh."
        case .rateLimited:
            "Too many requests. Give it a moment and pull to refresh."
        case .unauthorized, .forbidden:
            "Please sign in again to see your messages."
        case .notFound:
            "This conversation is no longer available."
        case .conflict, .server, .decoding:
            "We couldn't load your messages. Pull to refresh to try again."
        }
    }

    /// Copy for a message that failed to leave the device.
    static func sendFailure(_ error: any Error) -> String {
        guard let apiError = error as? APIError else {
            return "Message not sent. Tap it to try again."
        }
        return switch apiError {
        case .offline, .network:
            "You're offline. Tap the message to send it again."
        case .rateLimited:
            "You're sending very quickly. Wait a moment and try again."
        case .unauthorized, .forbidden:
            "Sign in again to send messages."
        case .notFound:
            "This conversation is no longer available."
        case .conflict, .server, .decoding:
            "Message not sent. Tap it to try again."
        }
    }

    /// Copy for a failed Beauty Assistant request.
    static func assistantFailure(_ error: any Error) -> String {
        guard let apiError = error as? APIError else {
            return "Your assistant couldn't answer just now. Try again."
        }
        return switch apiError {
        case .offline, .network:
            "Your assistant needs a connection to think. Try again once you're back online."
        case .rateLimited:
            "Your assistant is catching its breath. Try again in a moment."
        case .unauthorized, .forbidden:
            "Sign in again to talk to your assistant."
        case .notFound, .conflict, .server, .decoding:
            "Your assistant couldn't answer just now. Try again."
        }
    }
}

// MARK: - Formatting

/// Date, duration, and content formatting shared by the chat screens. All
/// output is localized through `FormatStyle`, never hand-assembled.
enum ChatFormat {
    /// Compact recency for conversation rows: a clock time today,
    /// "Yesterday", a weekday within the past week, otherwise a short date.
    static func recency(_ date: Date?, now: Date = .now, calendar: Calendar = .current) -> String {
        guard let date else { return "" }
        if calendar.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday"
        }
        if daysBetween(date, now, calendar: calendar) < 7 {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    /// Header shown above each day's run of messages.
    static func dayHeader(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let days = daysBetween(date, now, calendar: calendar)
        if days > 0, days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.wide))
    }

    /// Clock time shown beneath a run of messages.
    static func clockTime(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// Full, unambiguous date + time used for VoiceOver descriptions.
    static func spokenTimestamp(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    /// Day + time used inside appointment-request cards.
    static func appointmentMoment(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).day().month(.wide).hour().minute())
    }

    /// "0:42" style duration for a voice note.
    static func voiceDuration(seconds: Int) -> String {
        let clamped = max(0, seconds)
        return "\(clamped / 60):" + String(format: "%02d", clamped % 60)
    }

    /// Spoken duration for a voice note, e.g. "1 minute 5 seconds".
    static func spokenVoiceDuration(seconds: Int) -> String {
        let clamped = max(0, seconds)
        let minutes = clamped / 60
        let remainder = clamped % 60
        if minutes == 0 { return "\(remainder) seconds" }
        if remainder == 0 { return minutes == 1 ? "1 minute" : "\(minutes) minutes" }
        return "\(minutes) minute\(minutes == 1 ? "" : "s") \(remainder) seconds"
    }

    /// "2 h 30 min" style service duration.
    static func serviceDuration(minutes: Int) -> String {
        let clamped = max(0, minutes)
        let hours = clamped / 60
        let remainder = clamped % 60
        if hours == 0 { return "\(remainder) min" }
        if remainder == 0 { return "\(hours) h" }
        return "\(hours) h \(remainder) min"
    }

    /// One-line preview of any message content, used in conversation rows.
    static func preview(_ content: ChatMessage.Content) -> String {
        switch content {
        case .text(let text):
            text
        case .photo(_, let caption):
            nonBlank(caption) ?? "Photo"
        case .video(_, let caption):
            nonBlank(caption) ?? "Video"
        case .voice(_, let seconds):
            "Voice message · \(voiceDuration(seconds: seconds))"
        case .appointmentRequest:
            "Appointment request"
        case .recommendation(let recommendation):
            recommendation.headline
        }
    }

    /// Whole days between two dates, ignoring time of day.
    private static func daysBetween(_ earlier: Date, _ later: Date, calendar: Calendar) -> Int {
        calendar.dateComponents(
            [.day],
            from: earlier.startOfDay(in: calendar),
            to: later.startOfDay(in: calendar)
        ).day ?? 0
    }

    /// The string when it carries content, otherwise `nil`.
    private static func nonBlank(_ value: String?) -> String? {
        guard let value, !value.isBlank else { return nil }
        return value
    }
}

// MARK: - Transcript model

/// Header row introducing a day's messages.
struct ChatDayHeader: Identifiable, Hashable, Sendable {
    /// Start of the day being introduced.
    var date: Date

    var id: String { "\(date.timeIntervalSince1970)" }
}

/// A message plus the grouping flags the bubble needs to draw itself.
struct ChatTimelineMessage: Identifiable, Hashable, Sendable {
    /// The message being rendered.
    var message: ChatMessage
    /// First message of a same-author run — introduces the author.
    var isRunHead: Bool
    /// Last message of a same-author run — carries the tail corner, the
    /// timestamp, and the delivery state.
    var isRunTail: Bool

    var id: String { message.id.description }
}

/// One row of a conversation transcript.
enum ChatTimelineItem: Identifiable, Hashable, Sendable {
    case dayHeader(ChatDayHeader)
    case message(ChatTimelineMessage)

    var id: String {
        switch self {
        case .dayHeader(let header): "day-\(header.id)"
        case .message(let entry): "message-\(entry.id)"
        }
    }
}

/// Builds the rendered transcript from raw messages: day headers plus
/// same-author runs, exactly like Messages. Pure and `nonisolated`, so it can
/// be unit-tested and executed off the main actor.
enum ChatTimeline {
    /// Messages from one author within this window collapse into one run.
    static let runWindow: TimeInterval = 5 * 60

    /// Groups `messages` (any order) into an ordered list of transcript rows.
    static func build(from messages: [ChatMessage], calendar: Calendar = .current) -> [ChatTimelineItem] {
        let ordered = messages.sorted { $0.sentAt < $1.sentAt }
        var items: [ChatTimelineItem] = []
        items.reserveCapacity(ordered.count + 4)
        var previousDay: Date?

        for index in ordered.indices {
            let message = ordered[index]
            let day = calendar.startOfDay(for: message.sentAt)
            if previousDay != day {
                items.append(.dayHeader(ChatDayHeader(date: day)))
                previousDay = day
            }
            let previous = index > ordered.startIndex ? ordered[index - 1] : nil
            let next = index + 1 < ordered.endIndex ? ordered[index + 1] : nil
            items.append(.message(ChatTimelineMessage(
                message: message,
                isRunHead: !isSameRun(previous, message, calendar: calendar),
                isRunTail: !isSameRun(message, next, calendar: calendar)
            )))
        }
        return items
    }

    /// Whether `next` continues the visual run started by `current`.
    static func isSameRun(_ current: ChatMessage?, _ next: ChatMessage?, calendar: Calendar = .current) -> Bool {
        guard let current, let next else { return false }
        // Structured cards always stand alone — they are not chat bubbles.
        guard !isStructured(current), !isStructured(next) else { return false }
        guard authorKey(current) == authorKey(next) else { return false }
        guard calendar.isDate(current.sentAt, inSameDayAs: next.sentAt) else { return false }
        return next.sentAt.timeIntervalSince(current.sentAt) <= runWindow
    }

    /// Stable identity of a message's author.
    static func authorKey(_ message: ChatMessage) -> String {
        if message.isFromAssistant { return "assistant" }
        return message.senderID?.description ?? "system"
    }

    /// Whether the content renders as a standalone card rather than a bubble.
    static func isStructured(_ message: ChatMessage) -> Bool {
        switch message.content {
        case .appointmentRequest, .recommendation: true
        case .text, .photo, .video, .voice: false
        }
    }
}
