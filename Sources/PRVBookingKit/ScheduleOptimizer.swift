import Foundation
import PRVModels

/// Scores candidate slots by how good they are for the salon's calendar, and turns
/// the top of that ranking into the "recommended times" the booking flow surfaces.
///
/// The intuition is a salon manager's, not a search engine's:
///
/// - **Adjacency.** A slot that starts the moment another booking ends costs the
///   salon nothing. Credit decays linearly with the distance to the nearest
///   committed appointment and reaches zero at ``adjacencyHorizonMinutes``.
/// - **Edge anchoring.** A slot flush against opening or closing time is equally
///   tidy — it strands nothing behind it — and earns a smaller share of credit.
/// - **Fragmentation.** A slot that leaves a sliver too short to sell (anything
///   under ``minimumUsefulGapMinutes``) is penalised once per stranded side. Taking
///   11:00–12:00 in front of a 12:00 booking is excellent; taking 10:45–11:45 and
///   orphaning fifteen minutes is not.
/// - **Earliness.** A gentle tiebreak toward sooner, because clients want sooner.
///
/// Scores are normalised into `0...1` and written into `TimeSlot.optimizationScore`,
/// so downstream UI can render them without knowing any of this.
public struct ScheduleOptimizer: Sendable {
    /// Relative importance of each scoring signal.
    public struct Weights: Hashable, Sendable {
        /// Credit for sitting next to a committed appointment.
        public var adjacency: Double
        /// Credit for sitting flush against an opening-hours boundary.
        public var edgeAnchor: Double
        /// Credit for happening sooner within the requested range.
        public var earliness: Double
        /// Penalty for stranding an unsellable fragment.
        public var fragmentation: Double

        /// Creates a weight set.
        public init(
            adjacency: Double = 0.5,
            edgeAnchor: Double = 0.2,
            earliness: Double = 0.1,
            fragmentation: Double = 0.45
        ) {
            self.adjacency = max(0, adjacency)
            self.edgeAnchor = max(0, edgeAnchor)
            self.earliness = max(0, earliness)
            self.fragmentation = max(0, fragmentation)
        }

        /// The default balance used by the PRV booking flow.
        public static let balanced = Weights()

        /// Pure gap-filling: adjacency and fragmentation only, no time-of-day bias.
        public static let gapFillingOnly = Weights(adjacency: 0.7, edgeAnchor: 0.3, earliness: 0, fragmentation: 0.6)
    }

    /// The calendar used to resolve opening windows.
    public let calendar: Calendar
    /// Relative importance of each signal.
    public let weights: Weights
    /// Gaps shorter than this cannot realistically be sold, so creating one is penalised.
    public let minimumUsefulGapMinutes: Int
    /// Distance at which adjacency and edge credit decay to zero.
    public let adjacencyHorizonMinutes: Int

    /// Creates an optimizer.
    public init(
        calendar: Calendar = .prvBooking,
        weights: Weights = .balanced,
        minimumUsefulGapMinutes: Int = 30,
        adjacencyHorizonMinutes: Int = 120
    ) {
        self.calendar = calendar
        self.weights = weights
        self.minimumUsefulGapMinutes = max(0, minimumUsefulGapMinutes)
        self.adjacencyHorizonMinutes = max(1, adjacencyHorizonMinutes)
    }

    // MARK: Scoring

    /// Scores a single candidate in `0...1`. Convenience wrapper — prefer
    /// ``scoredCandidates(_:in:)`` when scoring a whole list, since this rebuilds
    /// the busy index on every call.
    public func score(_ candidate: SlotCandidate, in input: AvailabilityInput) -> Double {
        score(candidate, context: Context(input: input, calendar: calendar))
    }

    /// Returns every candidate with ``TimeSlot/optimizationScore`` filled in,
    /// ordered chronologically.
    public func scoredCandidates(_ candidates: [SlotCandidate], in input: AvailabilityInput) -> [SlotCandidate] {
        guard !candidates.isEmpty else { return [] }
        let context = Context(input: input, calendar: calendar)
        return candidates
            .map { $0.scored(score($0, context: context)) }
            .sorted { lhs, rhs in
                if lhs.slot.start != rhs.slot.start { return lhs.slot.start < rhs.slot.start }
                return (lhs.professionalID?.description ?? "") < (rhs.professionalID?.description ?? "")
            }
    }

    /// Returns every slot with its optimization score, ordered chronologically.
    public func scoredSlots(_ candidates: [SlotCandidate], in input: AvailabilityInput) -> [TimeSlot] {
        scoredCandidates(candidates, in: input).map(\.slot)
    }

    /// The best `topN` slots, highest score first.
    ///
    /// Ties break toward the earlier slot, then by professional identifier, so the
    /// ranking is total and reproducible.
    public func suggestedSlots(
        _ candidates: [SlotCandidate],
        in input: AvailabilityInput,
        topN: Int = 3
    ) -> [TimeSlot] {
        guard topN > 0 else { return [] }
        let scored = scoredCandidates(candidates, in: input)
        let ranked = scored.sorted { lhs, rhs in
            if lhs.slot.optimizationScore != rhs.slot.optimizationScore {
                return lhs.slot.optimizationScore > rhs.slot.optimizationScore
            }
            if lhs.slot.start != rhs.slot.start { return lhs.slot.start < rhs.slot.start }
            return (lhs.professionalID?.description ?? "") < (rhs.professionalID?.description ?? "")
        }
        return ranked.prefix(topN).map(\.slot)
    }

    /// End-to-end helper: generates availability and returns the recommended slots.
    ///
    /// This is what powers the "AI slot recommendation" row in the booking flow.
    public func recommendations(
        for input: AvailabilityInput,
        engine: AvailabilityEngine,
        topN: Int = 3
    ) -> [TimeSlot] {
        suggestedSlots(engine.candidates(for: input), in: input, topN: topN)
    }

    // MARK: Private

    /// Precomputed state shared across every candidate in one scoring pass.
    private struct Context {
        let busy: BusyIndex
        let openingHours: [OpeningHours]
        let rangeStart: Date
        let rangeSpan: TimeInterval

        init(input: AvailabilityInput, calendar: Calendar) {
            self.busy = BusyIndex(appointments: input.existingAppointments)
            self.openingHours = input.openingHours
            self.rangeStart = input.rangeStart
            self.rangeSpan = max(0, input.rangeEnd.timeIntervalSince(input.rangeStart))
        }
    }

    private func score(_ candidate: SlotCandidate, context: Context) -> Double {
        let block = candidate.occupancy
        let window = context.openingHours.window(containing: block, calendar: calendar)
            ?? dayWindow(containing: block)

        // Neighbours only count inside the same opening window: yesterday's last
        // appointment must not rob today's first slot of its edge-anchor credit.
        let previousEnd = context.busy
            .lastEnd(before: block.start, for: candidate.professionalID)
            .flatMap { $0 > window.start ? $0 : nil }
        let nextStart = context.busy
            .nextStart(after: block.end, for: candidate.professionalID)
            .flatMap { $0 < window.end ? $0 : nil }

        let gapBefore = calendar.minutes(from: previousEnd ?? window.start, to: block.start)
        let gapAfter = calendar.minutes(from: block.end, to: nextStart ?? window.end)

        var adjacency = 0.0
        var edge = 0.0
        if previousEnd != nil { adjacency = max(adjacency, decay(gapBefore)) } else { edge = max(edge, decay(gapBefore)) }
        if nextStart != nil { adjacency = max(adjacency, decay(gapAfter)) } else { edge = max(edge, decay(gapAfter)) }

        var strandedSides = 0
        if isStranded(gapBefore) { strandedSides += 1 }
        if isStranded(gapAfter) { strandedSides += 1 }
        let fragmentation = Double(strandedSides) / 2

        let earliness: Double
        if context.rangeSpan > 0 {
            let elapsed = candidate.slot.start.timeIntervalSince(context.rangeStart)
            earliness = clamped(1 - elapsed / context.rangeSpan)
        } else {
            earliness = 1
        }

        let positive = weights.adjacency + weights.edgeAnchor + weights.earliness
        let denominator = positive + weights.fragmentation
        guard denominator > 0 else { return 0 }

        let raw = weights.adjacency * adjacency
            + weights.edgeAnchor * edge
            + weights.earliness * earliness
            - weights.fragmentation * fragmentation

        // Map [-fragmentation, positive] onto [0, 1] without losing ordering.
        return clamped((raw + weights.fragmentation) / denominator)
    }

    private func decay(_ gapMinutes: Int) -> Double {
        guard gapMinutes > 0 else { return 1 }
        return max(0, 1 - Double(gapMinutes) / Double(adjacencyHorizonMinutes))
    }

    private func isStranded(_ gapMinutes: Int) -> Bool {
        gapMinutes > 0 && gapMinutes < minimumUsefulGapMinutes
    }

    private func clamped(_ value: Double) -> Double {
        min(1, max(0, value))
    }

    /// Fallback window when a block cannot be matched to an opening interval —
    /// only reachable for candidates that did not come from `AvailabilityEngine`.
    private func dayWindow(containing block: BookingInterval) -> BookingInterval {
        let start = calendar.startOfDay(for: block.start)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return BookingInterval(start: start, end: end)
    }
}
