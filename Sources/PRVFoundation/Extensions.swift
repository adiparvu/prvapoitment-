import Foundation

// MARK: - Date

extension Date {
    /// The start of the day in the given calendar (defaults to current).
    public func startOfDay(in calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: self)
    }

    public func adding(minutes: Int, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .minute, value: minutes, to: self) ?? self
    }

    public func adding(days: Int, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: days, to: self) ?? self
    }

    public func isSameDay(as other: Date, calendar: Calendar = .current) -> Bool {
        calendar.isDate(self, inSameDayAs: other)
    }
}

// MARK: - Collections

extension Sequence {
    /// Stable-sorts by a key path.
    public func sorted<T: Comparable>(by keyPath: KeyPath<Element, T>) -> [Element] {
        sorted { $0[keyPath: keyPath] < $1[keyPath: keyPath] }
    }

    public func grouped<Key: Hashable>(by key: (Element) -> Key) -> [Key: [Element]] {
        Dictionary(grouping: self, by: key)
    }
}

extension Array {
    /// Splits the array into chunks of at most `size` elements.
    public func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}

// MARK: - Decimal

extension Decimal {
    public var doubleValue: Double {
        (self as NSDecimalNumber).doubleValue
    }

    /// Banker's-rounding to the given scale (default: 2 for currency).
    public func rounded(scale: Int = 2) -> Decimal {
        var value = self
        var result = Decimal()
        NSDecimalRound(&result, &value, scale, .bankers)
        return result
    }
}

// MARK: - String

extension String {
    public var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isBlank: Bool {
        trimmed.isEmpty
    }
}
