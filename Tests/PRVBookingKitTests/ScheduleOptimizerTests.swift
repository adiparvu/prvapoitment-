import Foundation
import PRVBookingKit
import PRVModels
import Testing

@Suite("ScheduleOptimizer")
struct ScheduleOptimizerTests {
    /// A Monday with one committed 12:00–13:00 appointment for professional A.
    private func gapDay(granularity: Int) -> (AvailabilityEngine, AvailabilityInput) {
        let engine = Fixtures.engine(granularity: granularity)
        let input = Fixtures.availability(
            services: [Fixtures.plainCut],
            appointments: [
                Fixtures.appointment(start: Fixtures.mondayAt(12), minutes: 60, professionalID: Fixtures.proAID),
            ],
            professionals: [Fixtures.professional(id: Fixtures.proAID)],
            from: Fixtures.monday,
            to: Fixtures.mondayAt(18)
        )
        return (engine, input)
    }

    /// The score of the slot starting at `start`, or `-1` when no such slot exists —
    /// which fails any ordering assertion loudly rather than silently passing.
    private func score(
        at start: Date,
        optimizer: ScheduleOptimizer,
        engine: AvailabilityEngine,
        input: AvailabilityInput
    ) -> Double {
        optimizer
            .scoredSlots(engine.candidates(for: input), in: input)
            .first { $0.start == start }?
            .optimizationScore ?? -1
    }

    @Test("A slot that butts up against an existing booking outscores an isolated one")
    func adjacentSlotOutscoresIsolatedSlot() {
        let (engine, input) = gapDay(granularity: 60)
        let optimizer = ScheduleOptimizer(calendar: Fixtures.calendar)

        let adjacentBefore = score(at: Fixtures.mondayAt(11), optimizer: optimizer, engine: engine, input: input)
        let adjacentAfter = score(at: Fixtures.mondayAt(13), optimizer: optimizer, engine: engine, input: input)
        let isolated = score(at: Fixtures.mondayAt(15), optimizer: optimizer, engine: engine, input: input)

        #expect(adjacentBefore > isolated)
        #expect(adjacentAfter > isolated)
        #expect(isolated > 0)
    }

    @Test("A slot flush against closing time still earns edge-anchor credit")
    func edgeAnchoredSlotOutscoresMidAfternoon() {
        let (engine, input) = gapDay(granularity: 60)
        let optimizer = ScheduleOptimizer(calendar: Fixtures.calendar)

        let flushWithClosing = score(at: Fixtures.mondayAt(17), optimizer: optimizer, engine: engine, input: input)
        let midAfternoon = score(at: Fixtures.mondayAt(15), optimizer: optimizer, engine: engine, input: input)

        #expect(flushWithClosing > midAfternoon)
    }

    @Test("Stranding an unsellable fragment costs more than it gains in adjacency")
    func strandedFragmentIsPenalised() {
        let (engine, input) = gapDay(granularity: 15)
        let optimizer = ScheduleOptimizer(calendar: Fixtures.calendar)

        // 10:45–11:45 sits closer to the 12:00 booking but orphans 15 minutes;
        // 10:30–11:30 leaves a sellable 30-minute gap and must win.
        let strands = score(at: Fixtures.mondayAt(10, 45), optimizer: optimizer, engine: engine, input: input)
        let clean = score(at: Fixtures.mondayAt(10, 30), optimizer: optimizer, engine: engine, input: input)
        let perfectFill = score(at: Fixtures.mondayAt(11), optimizer: optimizer, engine: engine, input: input)

        #expect(clean > strands)
        #expect(perfectFill > strands)
        #expect(strands > 0)
    }

    @Test("A shorter minimum useful gap stops penalising the same fragment")
    func minimumUsefulGapIsConfigurable() {
        let (engine, input) = gapDay(granularity: 15)
        let strict = ScheduleOptimizer(calendar: Fixtures.calendar, minimumUsefulGapMinutes: 30)
        let relaxed = ScheduleOptimizer(calendar: Fixtures.calendar, minimumUsefulGapMinutes: 15)

        let strictScore = score(at: Fixtures.mondayAt(10, 45), optimizer: strict, engine: engine, input: input)
        let relaxedScore = score(at: Fixtures.mondayAt(10, 45), optimizer: relaxed, engine: engine, input: input)

        #expect(relaxedScore > strictScore)
    }

    @Test("Suggested slots rank the best gap-fillers first")
    func suggestedSlotsRankGapFillersFirst() {
        let (engine, input) = gapDay(granularity: 60)
        let optimizer = ScheduleOptimizer(calendar: Fixtures.calendar)
        let suggestions = optimizer.suggestedSlots(engine.candidates(for: input), in: input, topN: 2)

        #expect(suggestions.count == 2)
        #expect(suggestions.map(\.start) == [Fixtures.mondayAt(11), Fixtures.mondayAt(13)])
        #expect(suggestions[0].optimizationScore >= suggestions[1].optimizationScore)
    }

    @Test("Recommendations run availability and ranking end to end")
    func recommendationsRunEndToEnd() {
        let (engine, input) = gapDay(granularity: 60)
        let optimizer = ScheduleOptimizer(calendar: Fixtures.calendar)
        let recommended = optimizer.recommendations(for: input, engine: engine, topN: 3)

        #expect(recommended.count == 3)
        #expect(recommended.first?.start == Fixtures.mondayAt(11))
        #expect(recommended.allSatisfy { $0.professionalID == Fixtures.proAID })
    }

    @Test("Scores are normalised into 0...1 and written into the slot")
    func scoresAreNormalised() {
        let (engine, input) = gapDay(granularity: 15)
        let optimizer = ScheduleOptimizer(calendar: Fixtures.calendar)
        let slots = optimizer.scoredSlots(engine.candidates(for: input), in: input)

        #expect(!slots.isEmpty)
        #expect(slots.allSatisfy { $0.optimizationScore >= 0 && $0.optimizationScore <= 1 })
        #expect(slots.contains { $0.optimizationScore > 0 })
    }

    @Test("Scored slots stay in chronological order")
    func scoredSlotsStayChronological() {
        let (engine, input) = gapDay(granularity: 15)
        let optimizer = ScheduleOptimizer(calendar: Fixtures.calendar)
        let slots = optimizer.scoredSlots(engine.candidates(for: input), in: input)

        #expect(zip(slots, slots.dropFirst()).allSatisfy { $0.start <= $1.start })
    }

    @Test("Suggestions never exceed the requested count and tolerate empty input")
    func suggestionsRespectTopN() {
        let (engine, input) = gapDay(granularity: 60)
        let optimizer = ScheduleOptimizer(calendar: Fixtures.calendar)
        let candidates = engine.candidates(for: input)

        #expect(optimizer.suggestedSlots(candidates, in: input, topN: 100).count == candidates.count)
        #expect(optimizer.suggestedSlots(candidates, in: input, topN: 0).isEmpty)
        #expect(optimizer.suggestedSlots([], in: input, topN: 3).isEmpty)
        #expect(optimizer.scoredSlots([], in: input).isEmpty)
    }

    @Test("Gap-filling-only weights ignore time of day entirely")
    func gapFillingOnlyWeightsIgnoreTimeOfDay() {
        let (engine, input) = gapDay(granularity: 60)
        let optimizer = ScheduleOptimizer(calendar: Fixtures.calendar, weights: .gapFillingOnly)

        let beforeBooking = score(at: Fixtures.mondayAt(11), optimizer: optimizer, engine: engine, input: input)
        let afterBooking = score(at: Fixtures.mondayAt(13), optimizer: optimizer, engine: engine, input: input)

        // Both sit flush against the same booking, so without an earliness bias
        // they must score identically.
        #expect(beforeBooking == afterBooking)
    }

    @Test("Yesterday's last appointment does not steal today's opening-hours credit")
    func neighboursDoNotLeakAcrossDays() throws {
        let engine = Fixtures.engine(granularity: 60)
        let input = Fixtures.availability(
            services: [Fixtures.plainCut],
            appointments: [
                Fixtures.appointment(start: Fixtures.mondayAt(17), minutes: 60, professionalID: Fixtures.proAID),
            ],
            professionals: [Fixtures.professional(id: Fixtures.proAID)],
            from: Fixtures.tuesday,
            to: Fixtures.tuesdayAt(18)
        )
        let optimizer = ScheduleOptimizer(calendar: Fixtures.calendar)
        let slots = optimizer.scoredSlots(engine.candidates(for: input), in: input)
        let opening = try #require(slots.first { $0.start == Fixtures.tuesdayAt(9) })
        let midday = try #require(slots.first { $0.start == Fixtures.tuesdayAt(13) })

        #expect(opening.optimizationScore > midday.optimizationScore)
    }
}
