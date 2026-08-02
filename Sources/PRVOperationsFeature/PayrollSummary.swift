import Foundation
import SwiftUI
import PRVDesignSystem
import PRVFoundation
import PRVModels

// MARK: - Estimate

/// One employee's modelled payout for the reporting period.
///
/// Deliberately an *estimate*: it combines contractual pay held on the
/// employment record with revenue attribution from the analytics snapshot. It
/// is a planning aid for owners, never a payslip — the UI says so out loud.
struct PayrollEstimate: Identifiable, Sendable {
    let employeeID: Employee.ID
    let name: String
    let model: Employee.CompensationModel
    /// Contractual pay for the period (salary, or rate × tracked hours).
    let base: Money
    /// How the base was derived, shown under the name.
    let baseCaption: String
    /// Revenue attributed to this person in the period.
    let attributedRevenue: Money
    let commissionPercent: Int
    /// Commission earned on ``attributedRevenue``.
    let commission: Money
    /// Hours read from closed and open time entries in the period.
    let trackedHours: TimeInterval

    var id: Employee.ID { employeeID }

    /// Base plus commission.
    var total: Money { base + commission }
}

// MARK: - Estimator

/// Builds the payroll table from employment records, tracked time, and the
/// analytics snapshot's revenue-by-employee breakdown.
///
/// All amounts are normalized to the salon's currency: employment records may
/// carry historical currencies, and a payroll table that mixes them would be
/// unreadable (and would trip `Money`'s same-currency arithmetic).
enum PayrollEstimator {
    static func estimates(
        members: [TeamMember],
        snapshot: DashboardSnapshot,
        timeEntries: [Employee.ID: [TimeEntry]],
        currency: Currency,
        period: DateInterval
    ) -> [PayrollEstimate] {
        members
            .map { member in
                estimate(
                    for: member,
                    snapshot: snapshot,
                    entries: timeEntries[member.id] ?? [],
                    currency: currency,
                    period: period
                )
            }
            .sorted { $0.total > $1.total }
    }

    private static func estimate(
        for member: TeamMember,
        snapshot: DashboardSnapshot,
        entries: [TimeEntry],
        currency: Currency,
        period: DateInterval
    ) -> PayrollEstimate {
        let employee = member.employee
        let revenue = Money(
            revenueAttributed(to: member.displayName, in: snapshot.revenueByEmployee),
            currency
        )
        let trackedSeconds = trackedTime(entries, in: period)
        let (base, caption) = basePay(
            for: employee,
            trackedSeconds: trackedSeconds,
            currency: currency
        )
        let commission = employee.commissionPercent > 0
            ? revenue.percentage(Decimal(employee.commissionPercent))
            : Money.zero(currency)

        return PayrollEstimate(
            employeeID: employee.id,
            name: member.displayName,
            model: employee.compensation,
            base: base,
            baseCaption: caption,
            attributedRevenue: revenue,
            commissionPercent: employee.commissionPercent,
            commission: commission,
            trackedHours: trackedSeconds
        )
    }

    /// Contractual pay for the period and the caption explaining it.
    private static func basePay(
        for employee: Employee,
        trackedSeconds: TimeInterval,
        currency: Currency
    ) -> (Money, String) {
        switch employee.compensation {
        case .salary, .hybrid:
            guard let salary = employee.monthlySalary else {
                return (.zero(currency), "No salary on file")
            }
            return (Money(salary.amount, currency), "Monthly salary")

        case .hourly:
            guard let rate = employee.hourlyRate else {
                return (.zero(currency), "No hourly rate on file")
            }
            let hours = Decimal(trackedSeconds / 3_600).rounded()
            let normalized = Money(rate.amount, currency)
            return (
                normalized * hours,
                "\(OperationsFormat.hours(trackedSeconds)) at \(normalized.formatted)/h"
            )

        case .commission:
            return (.zero(currency), "Commission only")
        }
    }

    /// Seconds logged inside the period; open entries count up to now.
    private static func trackedTime(_ entries: [TimeEntry], in period: DateInterval) -> TimeInterval {
        entries
            .filter { $0.clockIn >= period.start && $0.clockIn < period.end }
            .reduce(0) { $0 + $1.elapsed() }
    }

    /// Matches an employee to their slice of the revenue breakdown.
    ///
    /// Analytics labels are human names, so an exact diacritic-insensitive
    /// match comes first and a containment match second ("Amélie" vs
    /// "Amélie Dubois"). Unmatched people simply earn no commission.
    private static func revenueAttributed(to name: String, in metrics: [NamedMetric]) -> Decimal {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        if let exact = metrics.first(where: { $0.name.compare(name, options: options) == .orderedSame }) {
            return exact.value
        }
        if let partial = metrics.first(where: {
            $0.name.range(of: name, options: options) != nil
                || name.range(of: $0.name, options: options) != nil
        }) {
            return partial.value
        }
        return 0
    }
}

// MARK: - Compensation display

extension Employee.CompensationModel {
    /// Label used on the roster chip and in the payroll table.
    var displayName: String {
        switch self {
        case .salary: "Salary"
        case .hourly: "Hourly"
        case .commission: "Commission"
        case .hybrid: "Salary + commission"
        }
    }

    /// SF Symbol paired with the label.
    var symbolName: String {
        switch self {
        case .salary: "banknote"
        case .hourly: "clock"
        case .commission: "percent"
        case .hybrid: "chart.line.uptrend.xyaxis"
        }
    }
}

// MARK: - View

/// The payroll block: one row per team member, a period total, and an explicit
/// disclaimer. Only rendered when the session holds `.managePayroll`.
struct PayrollSummaryCard: View {
    let estimates: [PayrollEstimate]
    let total: Money
    let period: DateInterval
    let errorMessage: String?
    let retry: () -> Void

    var body: some View {
        OperationsBlock(
            "Payroll",
            subtitle: "Estimated for \(OperationsFormat.rangeTitle(period))"
        ) {
            if let errorMessage {
                OperationsErrorCard(message: errorMessage, retry: retry)
            } else if estimates.isEmpty {
                Text("Add pay details to an employment record to see an estimate here.")
                    .prvStyle(.footnote)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .prvGlassCard()
            } else {
                VStack(spacing: PRVSpacing.md) {
                    ForEach(estimates) { estimate in
                        PayrollRow(estimate: estimate)
                        if estimate.id != estimates.last?.id {
                            Divider().overlay(Color.prv.separator.opacity(0.5))
                        }
                    }

                    Divider().overlay(Color.prv.separator)

                    HStack {
                        Text("Estimated total")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.prv.textPrimary)
                        Spacer(minLength: PRVSpacing.xs)
                        Text(total.formatted)
                            .font(.system(.title3, design: .rounded, weight: .bold))
                            .foregroundStyle(Color.prv.textPrimary)
                            .monospacedDigit()
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Estimated payroll total \(total.formatted)")

                    OperationsFootnote(
                        "Estimate only. Base pay comes from each employment record; commission applies the record's percentage to attributed revenue for this period. Confirm with your accountant before paying.",
                        systemImage: "exclamationmark.circle"
                    )
                }
                .prvGlassCard()
            }
        }
    }
}

/// One line of the payroll table.
private struct PayrollRow: View {
    let estimate: PayrollEstimate

    var body: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: PRVSpacing.xs) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(estimate.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(Color.prv.textPrimary)
                        .lineLimit(1)
                    Text(estimate.baseCaption)
                        .prvStyle(.caption)
                }

                Spacer(minLength: PRVSpacing.xs)

                Text(estimate.total.formatted)
                    .font(.system(.body, design: .rounded, weight: .bold))
                    .foregroundStyle(Color.prv.textPrimary)
                    .monospacedDigit()
            }

            PRVFlowLayout(spacing: PRVSpacing.xxs) {
                PRVTag(estimate.model.displayName, systemImage: estimate.model.symbolName)
                PRVTag("Base \(estimate.base.formatted)", systemImage: "creditcard")
                if estimate.commissionPercent > 0 {
                    PRVTag(
                        "\(estimate.commissionPercent)% of \(estimate.attributedRevenue.formatted)",
                        systemImage: "percent",
                        tint: Color.prv.accent
                    )
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        var label = "\(estimate.name), \(estimate.model.displayName). "
        label += "Base \(estimate.base.formatted), \(estimate.baseCaption). "
        if estimate.commissionPercent > 0 {
            label += "Commission \(estimate.commission.formatted), "
            label += "\(estimate.commissionPercent) percent of \(estimate.attributedRevenue.formatted). "
        }
        label += "Estimated total \(estimate.total.formatted)."
        return label
    }
}
