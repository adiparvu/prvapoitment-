import SwiftUI
import PRVFoundation

/// A horizontally scrolling day selector for booking flows: weekday +
/// day-number cells, with the selected day filled by the brand gradient and
/// a dot marking today. The strip auto-scrolls to the current selection on
/// appearance.
///
/// The binding is normalized to the start of the selected day.
///
/// ```swift
/// PRVDateStrip(selection: $model.selectedDay, days: 21)
/// ```
public struct PRVDateStrip: View {
    @Binding private var selection: Date
    private let days: [Date]
    private let calendar: Calendar

    /// Creates a date strip.
    /// - Parameters:
    ///   - selection: Bound selected day (normalized to start-of-day on tap).
    ///   - startingFrom: First selectable day. Defaults to today.
    ///   - days: How many consecutive days to show. Defaults to 14.
    ///   - calendar: Calendar used for day math. Defaults to `.current`.
    public init(
        selection: Binding<Date>,
        startingFrom: Date = .now,
        days: Int = 14,
        calendar: Calendar = .current
    ) {
        self._selection = selection
        self.calendar = calendar
        let start = startingFrom.startOfDay(in: calendar)
        self.days = (0..<max(1, days)).map { start.adding(days: $0, calendar: calendar) }
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: PRVSpacing.xs) {
                    ForEach(days, id: \.self) { day in
                        dayCell(for: day)
                            .id(day)
                    }
                }
                .padding(.horizontal, PRVSpacing.md)
                .padding(.vertical, PRVSpacing.xxs)
            }
            .onAppear {
                if let selected = days.first(where: { $0.isSameDay(as: selection, calendar: calendar) }) {
                    proxy.scrollTo(selected, anchor: .center)
                }
            }
        }
        .prvAnimation(PRVMotion.quick, value: selection)
    }

    /// Built through `ContentBuilder` so the cell's per-day state reads as
    /// plain locals and the (deeply nested) label type-checks in isolation
    /// rather than as one expression inside `ForEach`.
    @ContentBuilder
    private func dayCell(for day: Date) -> some View {
        let isSelected = day.isSameDay(as: selection, calendar: calendar)
        let isToday = day.isSameDay(as: .now, calendar: calendar)

        Button {
            PRVHaptics.tap()
            selection = day
        } label: {
            VStack(spacing: PRVSpacing.xxs) {
                Text(day.formatted(.dateTime.weekday(.abbreviated)))
                    .font(.caption2.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(
                        isSelected
                            ? Color.prv.textOnAccent.opacity(0.85)
                            : Color.prv.textSecondary
                    )

                Text(day.formatted(.dateTime.day()))
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.prv.textOnAccent : Color.prv.textPrimary)

                Circle()
                    .fill(dotColor(isToday: isToday, isSelected: isSelected))
                    .frame(width: 4, height: 4)
            }
            .frame(width: 52, height: 70)
            .background {
                if isSelected {
                    PRVRadius.shape(PRVRadius.md)
                        .fill(Color.prv.accentGradient)
                } else {
                    PRVRadius.shape(PRVRadius.md)
                        .fill(Color.prv.surface)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
        .accessibilityHint(isToday ? "Today" : "")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// Today gets a marker dot; on the gradient it flips to the on-accent color.
    private func dotColor(isToday: Bool, isSelected: Bool) -> Color {
        guard isToday else { return .clear }
        return isSelected ? Color.prv.textOnAccent : Color.prv.accent
    }
}

#Preview("Date Strip — Light") {
    @Previewable @State var day = Date.now
    VStack(spacing: PRVSpacing.lg) {
        PRVDateStrip(selection: $day)
        Text(day.formatted(date: .complete, time: .omitted))
            .prvStyle(.footnote)
    }
    .padding(.vertical, PRVSpacing.lg)
    .background(Color.prv.canvas)
}

#Preview("Date Strip — Dark") {
    @Previewable @State var day = Date.now.addingTimeInterval(3 * 86_400)
    PRVDateStrip(selection: $day, days: 21)
        .padding(.vertical, PRVSpacing.lg)
        .background(Color.prv.canvas)
        .preferredColorScheme(.dark)
}
