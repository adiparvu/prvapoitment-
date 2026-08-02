import Foundation
import PRVModels
import Testing

@Suite("Money")
struct MoneyTests {
    @Test("Addition and subtraction are exact and preserve the currency")
    func additionAndSubtractionAreExact() {
        #expect(Money(45) + Money(30) == Money(75))
        #expect(Money(45) - Money(60) == Money(-15))
        #expect((ModelFixtures.money("19.99") + ModelFixtures.money("0.01")).amount == Decimal(20))
        #expect((Money(45, .gbp) + Money(5, .gbp)).currency == .gbp)
    }

    @Test("Decimal arithmetic avoids the binary rounding errors Double would introduce")
    func decimalArithmeticIsExact() {
        // 0.1 + 0.2 == 0.3 exactly — the whole reason Money is Decimal-backed.
        let sum = ModelFixtures.money("0.10") + ModelFixtures.money("0.20")

        #expect(sum.amount == Decimal(string: "0.30"))
        #expect(sum == ModelFixtures.money("0.30"))
    }

    @Test("Multiplication scales the amount and rounds to currency precision")
    func multiplicationRoundsToCurrencyPrecision() {
        #expect(Money(45) * 3 == Money(135))
        #expect(ModelFixtures.money("19.99") * 3 == ModelFixtures.money("59.97"))
        #expect((Money(20) * 0).isZero)
    }

    @Test("Percentages are applied on the exact amount")
    func percentagesAreExact() {
        #expect(Money(200).percentage(50) == Money(100))
        #expect(Money(45).percentage(21) == ModelFixtures.money("9.45"))
        #expect(Money(185).percentage(0).isZero)
        #expect(Money(185).percentage(100) == Money(185))
    }

    @Test("Percentages round half to even, so fees never drift in the salon's favour")
    func percentagesUseBankersRounding() {
        // 0.50 × 25% = 0.125 — a tie, rounded down to the even cent.
        #expect(ModelFixtures.money("0.50").percentage(25) == ModelFixtures.money("0.12"))
        // 0.54 × 25% = 0.135 — a tie, rounded up to the even cent.
        #expect(ModelFixtures.money("0.54").percentage(25) == ModelFixtures.money("0.14"))
    }

    @Test("Money is Comparable and sorts by amount")
    func moneyIsComparable() {
        #expect(Money(45) < Money(50))
        #expect(Money(50) > Money(45))
        #expect(!(Money(45) < Money(45)))
        #expect(Money(45) <= Money(45))

        let prices = [Money(185), Money(55), Money(75)]
        #expect(prices.sorted() == [Money(55), Money(75), Money(185)])
        #expect(prices.max() == Money(185))
        #expect(prices.min() == Money(55))
    }

    @Test("Zero is currency-aware and reports itself as zero")
    func zeroIsCurrencyAware() {
        #expect(Money.zero().isZero)
        #expect(Money.zero(.usd).currency == .usd)
        #expect(Money.zero() == Money(0))
        #expect(!Money(-1).isZero)
    }

    @Test("Currency symbols cover every supported market")
    func currencySymbolsAreDefined() {
        #expect(Currency.eur.symbol == "€")
        #expect(Currency.usd.symbol == "$")
        #expect(Currency.gbp.symbol == "£")
        #expect(Currency.allCases.allSatisfy { !$0.symbol.isEmpty })
        #expect(Currency(rawValue: "EUR") == .eur)
    }

    @Test("Money round-trips through the wire format without losing cents")
    func moneyRoundTripsOnTheWire() throws {
        let original = ModelFixtures.money("185.50")
        let decoded = try PRVWireJSON.roundTrip(original)

        #expect(decoded == original)
        #expect(decoded.amount == Decimal(string: "185.50"))
        #expect(decoded.currency == .eur)
    }

    // MARK: - Zero is currency-agnostic

    // Nothing is nothing in every currency. Neutral zeros therefore adopt the
    // other operand's denomination, which is what keeps `reduce(.zero())`
    // seeds and defaulted zero fields from mixing currencies on a non-euro
    // order — the crash this behaviour was introduced to remove.

    @Test("A zero seed adopts the currency of what is added to it")
    func zeroSeedAdoptsTheOtherCurrency() {
        let sum = Money.zero() + Money(50, .usd)

        #expect(sum.amount == 50)
        #expect(sum.currency == .usd)
    }

    @Test("Subtracting a defaulted euro zero leaves the amount's own currency")
    func subtractingZeroKeepsTheReceiverCurrency() {
        let remaining = Money(120, .gbp) - Money.zero()

        #expect(remaining.amount == 120)
        #expect(remaining.currency == .gbp)
    }

    @Test("When both sides are zero the left operand's currency wins")
    func zeroMinusZeroKeepsTheLeftCurrency() {
        #expect((Money.zero(.usd) - Money.zero(.eur)).currency == .usd)
        #expect((Money.zero(.usd) + Money.zero(.eur)).currency == .usd)
    }

    @Test("Summing a foreign-currency collection from a zero seed stays in that currency")
    func reduceFromZeroSeedStaysForeign() {
        let amounts = [Money(10, .chf), Money(20, .chf), Money(5, .chf)]

        let total = amounts.reduce(Money.zero()) { $0 + $1 }

        #expect(total.amount == 35)
        #expect(total.currency == .chf)
    }

    @Test("Zero compares against any currency")
    func zeroComparesAcrossCurrencies() {
        #expect(Money.zero() < Money(1, .usd))
        #expect(Money(1, .usd) > Money.zero())
        #expect(!(Money.zero(.usd) < Money.zero(.eur)))
    }
}
