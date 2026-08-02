import SwiftUI
import PRVDesignSystem
import PRVFoundation
import PRVModels

// MARK: - Goal display

extension PerformanceGoal.Metric {
    /// Full label used in accessibility copy.
    var displayName: String {
        switch self {
        case .revenue: "Revenue"
        case .appointments: "Appointments"
        case .retailSales: "Retail sales"
        case .rebookRate: "Rebook rate"
        case .reviewScore: "Review score"
        }
    }

    /// Short label that fits under a 56pt ring.
    var shortName: String {
        switch self {
        case .revenue: "Revenue"
        case .appointments: "Bookings"
        case .retailSales: "Retail"
        case .rebookRate: "Rebook"
        case .reviewScore: "Rating"
        }
    }

    /// SF Symbol shown inside the ring.
    var symbolName: String {
        switch self {
        case .revenue: "eurosign"
        case .appointments: "calendar"
        case .retailSales: "bag"
        case .rebookRate: "arrow.triangle.2.circlepath"
        case .reviewScore: "star"
        }
    }
}

extension PerformanceGoal {
    /// Completion as a 0…1 fraction, clamped for the ring.
    var fraction: Double {
        guard target > 0 else { return 0 }
        return min(1, max(0, (progress / target).doubleValue))
    }

    /// Whether the target has been reached or beaten.
    var isMet: Bool { target > 0 && progress >= target }

    /// `progress of target`, formatted for the metric, e.g. `€3.1k of €5k`.
    func summary(currency: Currency) -> String {
        "\(format(progress, currency: currency)) of \(format(target, currency: currency))"
    }

    private func format(_ value: Decimal, currency: Currency) -> String {
        switch metric {
        case .revenue, .retailSales:
            OperationsFormat.compactCurrency(Money(value, currency))
        case .appointments:
            OperationsFormat.decimal(value)
        case .rebookRate:
            "\(OperationsFormat.decimal(value))%"
        case .reviewScore:
            OperationsFormat.decimal(value, fractionDigits: 1)
        }
    }
}

// MARK: - Employee card

/// One person on the roster: avatar, role, a compensation chip that reveals
/// pay detail for owners, and a ring per performance goal.
struct EmployeeCard: View {
    let member: TeamMember
    let currency: Currency
    /// Whether pay figures may be revealed (`.managePayroll`).
    let canRevealPay: Bool
    /// Highlights the signed-in user's own row.
    let isCurrentUser: Bool
    /// Opens the public professional profile, when the person has one.
    let openProfile: (() -> Void)?

    @State private var isShowingPay = false

    var body: some View {
        PRVGlassCard {
            VStack(alignment: .leading, spacing: PRVSpacing.md) {
                identity
                compensation
                if isShowingPay && canRevealPay {
                    payDetail
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                goals
            }
        }
        .prvAnimation(PRVMotion.spring, value: isShowingPay)
    }

    // MARK: Identity

    private var identity: some View {
        HStack(spacing: PRVSpacing.md) {
            PRVAvatar(name: member.displayName, imageURL: member.photoURL, size: .large)

            VStack(alignment: .leading, spacing: PRVSpacing.xxs) {
                HStack(spacing: PRVSpacing.xxs) {
                    Text(member.displayName)
                        .prvStyle(.headline)
                        .lineLimit(1)
                    if isCurrentUser {
                        PRVBadge("You", tint: Color.prv.accent)
                    }
                }

                Text(member.title)
                    .prvStyle(.subheadline)
                    .lineLimit(1)

                Text("Joined \(OperationsFormat.date(member.employee.hiredAt))")
                    .prvStyle(.caption)
            }

            Spacer(minLength: 0)

            if let openProfile {
                Button {
                    PRVHaptics.tap()
                    openProfile()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.prv.textSecondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(member.displayName)'s profile")
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Compensation

    @ViewBuilder
    private var compensation: some View {
        if canRevealPay {
            PRVFlowLayout(spacing: PRVSpacing.xs) {
                PRVChip(
                    compensationLabel,
                    systemImage: member.employee.compensation.symbolName,
                    isSelected: isShowingPay
                ) {
                    isShowingPay.toggle()
                }
                .accessibilityLabel("\(compensationLabel). Pay details")
                .accessibilityHint(isShowingPay ? "Hides pay details" : "Shows pay details")

                PRVTag(
                    "\(member.vacationDaysRemaining) days off left",
                    systemImage: "beach.umbrella"
                )
            }
        } else {
            PRVFlowLayout(spacing: PRVSpacing.xs) {
                PRVTag(compensationLabel, systemImage: member.employee.compensation.symbolName)
                PRVTag(
                    "\(member.vacationDaysRemaining) days off left",
                    systemImage: "beach.umbrella"
                )
            }
        }
    }

    private var compensationLabel: String {
        let employee = member.employee
        switch employee.compensation {
        case .salary:
            return employee.monthlySalary.map { "\($0.formatted)/mo" } ?? "Salary"
        case .hourly:
            return employee.hourlyRate.map { "\($0.formatted)/h" } ?? "Hourly"
        case .commission:
            return "\(employee.commissionPercent)% commission"
        case .hybrid:
            let base = employee.monthlySalary.map { "\($0.formatted)/mo" } ?? "Base"
            return "\(base) + \(employee.commissionPercent)%"
        }
    }

    private var payDetail: some View {
        VStack(spacing: PRVSpacing.xs) {
            if let salary = member.employee.monthlySalary {
                OperationsDetailRow(label: "Monthly salary", value: salary.formatted, systemImage: "banknote")
            }
            if let hourly = member.employee.hourlyRate {
                OperationsDetailRow(label: "Hourly rate", value: hourly.formatted, systemImage: "clock")
            }
            OperationsDetailRow(
                label: "Commission",
                value: "\(member.employee.commissionPercent)% of services",
                systemImage: "percent"
            )
            OperationsDetailRow(
                label: "Model",
                value: member.employee.compensation.displayName,
                systemImage: member.employee.compensation.symbolName
            )
        }
        .padding(PRVSpacing.sm)
        .background(Color.prv.surface, in: PRVRadius.shape(PRVRadius.md))
    }

    // MARK: Goals

    @ViewBuilder
    private var goals: some View {
        if member.goals.isEmpty {
            OperationsFootnote(
                "No goals set for this period yet.",
                systemImage: "target"
            )
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: PRVSpacing.md) {
                    ForEach(member.goals) { goal in
                        GoalRing(goal: goal, currency: currency)
                    }
                }
                .padding(.vertical, PRVSpacing.xxs)
            }
            .scrollClipDisabled()
        }
    }
}

// MARK: - Goal ring

/// A single performance goal drawn as a progress ring with its metric glyph.
struct GoalRing: View {
    let goal: PerformanceGoal
    let currency: Currency

    var body: some View {
        VStack(spacing: PRVSpacing.xxs) {
            PRVProgressRing(
                progress: goal.fraction,
                lineWidth: 6,
                size: 56,
                tint: goal.isMet
                    ? AnyShapeStyle(Color.prv.success)
                    : AnyShapeStyle(Color.prv.accentGradient)
            ) {
                Image(systemName: goal.isMet ? "checkmark" : goal.metric.symbolName)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(goal.isMet ? Color.prv.success : Color.prv.textPrimary)
            }
            .accessibilityHidden(true)

            Text(goal.metric.shortName)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.prv.textSecondary)

            Text(OperationsFormat.percent(goal.fraction))
                .font(.caption2.weight(.bold))
                .foregroundStyle(goal.isMet ? Color.prv.success : Color.prv.textPrimary)
                .monospacedDigit()
        }
        .frame(width: 72)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(goal.metric.displayName): \(goal.summary(currency: currency)), \(OperationsFormat.percent(goal.fraction)) complete"
        )
    }
}

// MARK: - Vacation

/// One person's yearly time-off balance as a used/total meter.
struct VacationRow: View {
    let member: TeamMember

    var body: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: PRVSpacing.xs) {
                Text(member.displayName)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.prv.textPrimary)
                    .lineLimit(1)

                Spacer(minLength: PRVSpacing.xs)

                Text("\(member.employee.vacationDaysUsed) / \(member.employee.vacationDaysPerYear)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.prv.textPrimary)
                    .monospacedDigit()
            }

            OperationsMeter(fraction: member.vacationFraction, tint: meterTint)

            Text("\(member.vacationDaysRemaining) days remaining this year")
                .prvStyle(.caption)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(member.displayName) has used \(member.employee.vacationDaysUsed) of \(member.employee.vacationDaysPerYear) days off, \(member.vacationDaysRemaining) remaining."
        )
    }

    /// Warm amber once someone has burned through 85% of their allowance.
    private var meterTint: AnyShapeStyle {
        member.vacationFraction >= 0.85
            ? AnyShapeStyle(Color.prv.warning)
            : AnyShapeStyle(Color.prv.accentGradient)
    }
}

// MARK: - Previews

#Preview("Employee card") {
    ScrollView {
        VStack(spacing: PRVSpacing.md) {
            EmployeeCard(
                member: TeamMember(
                    employee: Employee(
                        salonID: PreviewData.salonLumiere.id,
                        professionalID: PreviewData.stylistAmelie.id,
                        role: .salonEmployee,
                        compensation: .hybrid,
                        monthlySalary: Money(2_400),
                        commissionPercent: 15,
                        vacationDaysUsed: 12
                    ),
                    professional: PreviewData.stylistAmelie,
                    goals: [
                        PerformanceGoal(
                            employeeID: Employee.ID(),
                            metric: .revenue,
                            target: 8_000,
                            progress: 6_150,
                            periodStart: .now,
                            periodEnd: .now.addingTimeInterval(86_400 * 30)
                        ),
                        PerformanceGoal(
                            employeeID: Employee.ID(),
                            metric: .retailSales,
                            target: 900,
                            progress: 940,
                            periodStart: .now,
                            periodEnd: .now.addingTimeInterval(86_400 * 30)
                        ),
                        PerformanceGoal(
                            employeeID: Employee.ID(),
                            metric: .rebookRate,
                            target: 70,
                            progress: 48,
                            periodStart: .now,
                            periodEnd: .now.addingTimeInterval(86_400 * 30)
                        ),
                    ]
                ),
                currency: .eur,
                canRevealPay: true,
                isCurrentUser: true,
                openProfile: {}
            )

            VacationRow(
                member: TeamMember(
                    employee: Employee(
                        salonID: PreviewData.salonLumiere.id,
                        professionalID: PreviewData.artistNoor.id,
                        vacationDaysPerYear: 20,
                        vacationDaysUsed: 18
                    ),
                    professional: PreviewData.artistNoor,
                    goals: []
                )
            )
            .prvGlassCard()
        }
        .padding(PRVSpacing.md)
    }
    .background(Color.prv.canvas)
}
