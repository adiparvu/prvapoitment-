import Foundation
import Observation
import PRVDesignSystem
import PRVFoundation
import PRVModels
import PRVNetworking

/// Lifecycle of an availability query. Shared by the booking flow and the
/// reschedule sheet so both render slots the same way.
enum SlotsPhase: Equatable, Sendable {
    case idle
    case loading
    case loaded([TimeSlot])
    case failed(String)

    /// The slots to render, or an empty array while loading/failed.
    var slots: [TimeSlot] {
        if case .loaded(let slots) = self { return slots }
        return []
    }
}

/// Services grouped under one business category for the first step's menu.
struct BookingServiceGroup: Identifiable, Hashable, Sendable {
    var category: BusinessCategory
    var services: [SalonService]
    var id: String { category.rawValue }
}

/// Everything the confirmation screen needs after a successful booking.
struct BookingConfirmation: Hashable, Sendable {
    var appointment: Appointment
    var order: Order
    var salon: Salon
    /// What checkout will charge immediately (zero when paying at the salon).
    var amountDueNow: Money
    var professionalName: String?

    /// Start of the visit.
    var start: Date? { appointment.start }
    /// End of the visit, add-ons included.
    var end: Date? { appointment.end }

    /// Calendar event title, e.g. "Balayage & Gloss at Maison Lumière".
    var calendarTitle: String {
        let services = appointment.items.map(\.serviceName).joined(separator: " + ")
        return services.isEmpty ? salon.name : "\(services) at \(salon.name)"
    }

    /// Text shared through `ShareLink`.
    var shareText: String {
        guard let start else { return calendarTitle }
        var text = "\(calendarTitle) — \(BookingFormatting.dateAndTime(start))"
        if let professionalName {
            text += " with \(professionalName)"
        }
        return text
    }
}

/// Identifies one availability query. Bound to `.task(id:)` so changing the
/// day, the professional, or the service selection reloads slots exactly once.
struct SlotRequestKey: Hashable, Sendable {
    var salonID: Salon.ID
    var day: Date
    var professionalID: Professional.ID?
    var serviceIDs: [SalonService.ID]
}

/// Screen model backing ``BookingFlowView``.
///
/// Owns the entire four-step flow: the service selection with add-ons, the
/// professional choice, day/slot availability with waitlist, recurrence and
/// group options, prepayment and coupon pricing, and the final submission
/// (`book` → `createOrder`). All repository access is passed in per call so
/// the model stays free of environment plumbing and easy to drive in tests.
@Observable
@MainActor
final class BookingFlowModel {
    /// Lifecycle of the initial salon/services/team load.
    enum Phase: Equatable, Sendable {
        case loading
        case loaded
        case failed(String)
    }

    /// Where the client entered the flow from.
    let context: BookingContext

    // MARK: Loaded data

    private(set) var phase: Phase = .loading
    private(set) var salon: Salon?
    private(set) var services: [SalonService] = []
    private(set) var professionals: [Professional] = []

    // MARK: Flow state

    /// The visible step. Changing it drives the liquid morph transition.
    private(set) var step: BookingStep = .services
    /// The furthest step reached, so the progress bar can show completion.
    private(set) var furthestStep: BookingStep = .services

    // MARK: Selection

    private(set) var selectedServiceIDs: Set<SalonService.ID> = []
    private(set) var selectedAddOnIDs: [SalonService.ID: Set<ServiceAddOn.ID>] = [:]
    /// Chosen professional; `nil` means "any available".
    private(set) var professionalID: Professional.ID?
    /// Day being browsed for availability (normalized to start of day).
    var selectedDay: Date = Date.now.startOfDay()
    private(set) var selectedSlot: TimeSlot?
    private(set) var slotsPhase: SlotsPhase = .idle

    // MARK: Options

    var isRecurring = false
    var recurrenceFrequency: RecurrenceRule.Frequency = .every4Weeks
    var recurrenceOccurrences = 6
    /// When true the series runs until the client cancels it.
    var isRecurrenceOngoing = false
    var isGroupBooking = false
    /// Guests joining the client (the client themselves is always included).
    var guestCount = 1
    var notes = ""

    // MARK: Payment

    /// Chosen prepayment level; `nil` means pay at the salon.
    private(set) var prepaymentPercent: PrepaymentPolicy.Percent?
    var couponCode = ""
    private(set) var appliedCoupon: Coupon?
    private(set) var isValidatingCoupon = false

    // MARK: Submission

    private(set) var isSubmitting = false
    private(set) var confirmation: BookingConfirmation?

    // MARK: Transient UI

    var isWaitlistPresented = false
    var isJoiningWaitlist = false
    var toast: PRVToast?

    /// Creates the model for one booking entry point.
    init(context: BookingContext) {
        self.context = context
    }

    // MARK: - Loading

    /// Loads the salon, its menu, and its team concurrently, then applies the
    /// context's pre-selected services. Safe to call again to retry.
    func load(using deps: PRVDependencies) async {
        phase = .loading
        do {
            async let salonTask = deps.salons.salon(id: context.salonID)
            async let servicesTask = deps.salons.services(salonID: context.salonID)
            async let professionalsTask = deps.salons.professionals(salonID: context.salonID)

            let loadedSalon = try await salonTask
            let loadedServices = try await servicesTask.filter(\.isActive)
            let loadedProfessionals = try await professionalsTask

            salon = loadedSalon
            services = loadedServices
            professionals = loadedProfessionals

            if selectedServiceIDs.isEmpty {
                let available = Set(loadedServices.map(\.id))
                selectedServiceIDs = Set(context.serviceIDs.filter { available.contains($0) })
            }
            applyDefaultPrepayment(policy: loadedSalon.prepaymentPolicy)
            phase = .loaded
        } catch {
            PRVLog.booking.error("Booking flow load failed: \(String(describing: error), privacy: .public)")
            phase = .failed(BookingFormatting.friendlyError(error, subject: "This salon"))
        }
    }

    /// Pre-selects the smallest offered deposit when a chosen service demands
    /// prepayment; otherwise the client starts on "pay at the salon".
    private func applyDefaultPrepayment(policy: PrepaymentPolicy) {
        guard requiresPrepayment else { return }
        prepaymentPercent = policy.offeredPercents.min { $0.rawValue < $1.rawValue }
    }

    // MARK: - Step navigation

    /// Whether the current step's requirements are satisfied.
    var canAdvance: Bool {
        switch step {
        case .services: !selectedServiceIDs.isEmpty
        case .professional: true
        case .time: selectedSlot != nil
        case .review: !isSubmitting && salon != nil
        case .confirmation: false
        }
    }

    /// Label for the primary button of the current step.
    var primaryActionTitle: String {
        switch step {
        case .services: "Choose Your Artist"
        case .professional: "Pick a Time"
        case .time: "Review & Pay"
        case .review: isSubmitting ? "Confirming…" : "Confirm Booking"
        case .confirmation: "Done"
        }
    }

    /// Moves to the next step when the current one is complete.
    func advance() {
        guard canAdvance, let next = step.next, next != .confirmation else { return }
        move(to: next)
        PRVHaptics.impact()
    }

    /// Moves back one step. Returns `false` at the first step so the view can
    /// dismiss the flow instead.
    @discardableResult
    func retreat() -> Bool {
        guard step != .confirmation, let previous = step.previous else { return false }
        move(to: previous)
        PRVHaptics.tap()
        return true
    }

    /// Jumps to an already-visited step (progress-bar taps, "Edit" links).
    func jump(to target: BookingStep) {
        guard target != step, target <= furthestStep, target != .confirmation else { return }
        move(to: target)
        PRVHaptics.tap()
    }

    private func move(to target: BookingStep) {
        step = target
        if target > furthestStep { furthestStep = target }
    }

    // MARK: - Services

    /// The menu grouped by category, alphabetized for a stable read.
    var groupedServices: [BookingServiceGroup] {
        services
            .grouped { $0.category }
            .map { BookingServiceGroup(category: $0.key, services: $0.value.sorted(by: \.name)) }
            .sorted { $0.category.displayName < $1.category.displayName }
    }

    /// Whether the service is part of the booking.
    func isSelected(_ service: SalonService) -> Bool {
        selectedServiceIDs.contains(service.id)
    }

    /// Whether the add-on of a service is part of the booking.
    func isSelected(_ addOn: ServiceAddOn, of service: SalonService) -> Bool {
        selectedAddOnIDs[service.id, default: []].contains(addOn.id)
    }

    /// Adds or removes a service. Removing it also clears its add-ons.
    func toggleService(_ service: SalonService) {
        if selectedServiceIDs.remove(service.id) != nil {
            selectedAddOnIDs[service.id] = nil
            PRVHaptics.tap()
        } else {
            selectedServiceIDs.insert(service.id)
            PRVHaptics.impact()
        }
        selectionDidChange()
    }

    /// Toggles an add-on, selecting its parent service when needed so the
    /// running total always stays coherent.
    func toggleAddOn(_ addOn: ServiceAddOn, of service: SalonService) {
        var addOns = selectedAddOnIDs[service.id] ?? []
        if addOns.remove(addOn.id) == nil {
            addOns.insert(addOn.id)
            selectedServiceIDs.insert(service.id)
            PRVHaptics.impact()
        } else {
            PRVHaptics.tap()
        }
        selectedAddOnIDs[service.id] = addOns
        selectionDidChange()
    }

    /// Selected services in menu order.
    var selectedServices: [SalonService] {
        services.filter { selectedServiceIDs.contains($0.id) }
    }

    /// Selected add-ons of a service, in the service's own order.
    func selectedAddOns(of service: SalonService) -> [ServiceAddOn] {
        let ids = selectedAddOnIDs[service.id] ?? []
        return service.addOns.filter { ids.contains($0.id) }
    }

    /// The primary service — used for waitlist entries and copy.
    var primaryService: SalonService? { selectedServices.first }

    /// Total treatment time of the selection, add-ons included.
    var totalDurationMinutes: Int {
        selectedServices.reduce(0) { partial, service in
            let extra = selectedAddOns(of: service).reduce(0) { $0 + $1.extraMinutes }
            return partial + service.durationMinutes + extra
        }
    }

    /// Whether any selected service demands a deposit before booking.
    var requiresPrepayment: Bool {
        selectedServices.contains(where: \.requiresPrepayment)
    }

    /// Dropping or adding services invalidates the chosen professional and slot.
    private func selectionDidChange() {
        if let professionalID,
           let professional = professionals.first(where: { $0.id == professionalID }),
           !canPerformSelection(professional) {
            self.professionalID = nil
        }
        selectedSlot = nil
        slotsPhase = .idle
        if requiresPrepayment, prepaymentPercent == nil, let salon {
            applyDefaultPrepayment(policy: salon.prepaymentPolicy)
        }
    }

    // MARK: - Professionals

    /// Professionals who can perform every selected service. Falls back to the
    /// full team when the salon has not mapped services to its staff.
    var eligibleProfessionals: [Professional] {
        guard !selectedServiceIDs.isEmpty else { return professionals }
        let matching = professionals.filter { canPerformSelection($0) }
        return matching.isEmpty ? professionals : matching
    }

    /// Whether a professional performs all selected services.
    func canPerformSelection(_ professional: Professional) -> Bool {
        guard !professional.serviceIDs.isEmpty else { return false }
        return selectedServiceIDs.allSatisfy { professional.serviceIDs.contains($0) }
    }

    /// The chosen professional, or `nil` for "any available".
    var selectedProfessional: Professional? {
        professionalID.flatMap { id in professionals.first { $0.id == id } }
    }

    /// Chooses a professional (`nil` = any available) and invalidates the slot.
    func selectProfessional(_ professional: Professional?) {
        guard professionalID != professional?.id else { return }
        professionalID = professional?.id
        selectedSlot = nil
        slotsPhase = .idle
        PRVHaptics.impact()
    }

    // MARK: - Availability

    /// Identity of the current availability query.
    var slotRequestKey: SlotRequestKey {
        SlotRequestKey(
            salonID: context.salonID,
            day: selectedDay.startOfDay(),
            professionalID: professionalID,
            serviceIDs: selectedServices.map(\.id)
        )
    }

    /// Loads bookable slots for the selected day, professional, and services.
    func loadSlots(using deps: PRVDependencies) async {
        guard !selectedServiceIDs.isEmpty else {
            slotsPhase = .idle
            return
        }
        slotsPhase = .loading
        let dayStart = selectedDay.startOfDay()
        let request = AvailabilityRequest(
            salonID: context.salonID,
            serviceIDs: selectedServices.map(\.id),
            professionalID: professionalID,
            rangeStart: max(dayStart, .now),
            rangeEnd: dayStart.adding(days: 1).addingTimeInterval(-1)
        )
        do {
            let slots = try await deps.appointments.availableSlots(request)
                .filter { $0.start.isSameDay(as: dayStart) }
                .sorted { $0.start < $1.start }
            guard !Task.isCancelled else { return }
            slotsPhase = .loaded(slots)
            if let selectedSlot, !slots.contains(selectedSlot) {
                self.selectedSlot = nil
            }
        } catch {
            guard !Task.isCancelled else { return }
            PRVLog.booking.error("Availability load failed: \(String(describing: error), privacy: .public)")
            slotsPhase = .failed(BookingFormatting.friendlyError(error, subject: "Availability"))
        }
    }

    /// The three slots that fit the salon's calendar best. Hidden when the day
    /// is quiet enough that every time is already visible at a glance.
    var recommendedSlots: [TimeSlot] {
        let slots = slotsPhase.slots
        guard slots.count > 3 else { return [] }
        return slots.topRecommended()
    }

    /// Chooses a slot.
    func select(_ slot: TimeSlot) {
        selectedSlot = slot
    }

    /// Adds the client to the salon's waitlist for the selected day's window.
    /// Returns `true` when the entry was accepted, so the sheet can dismiss.
    func joinWaitlist(
        earliest: Date,
        latest: Date,
        clientID: User.ID,
        using deps: PRVDependencies
    ) async -> Bool {
        guard let service = primaryService else { return false }
        isJoiningWaitlist = true
        defer { isJoiningWaitlist = false }
        let entry = WaitlistEntry(
            salonID: context.salonID,
            clientID: clientID,
            serviceID: service.id,
            professionalID: professionalID,
            earliest: min(earliest, latest),
            latest: max(earliest, latest)
        )
        do {
            _ = try await deps.appointments.joinWaitlist(entry)
            toast = .success("You're on the waitlist — we'll ping you the moment a spot opens.")
            return true
        } catch {
            PRVLog.booking.error("Waitlist join failed: \(String(describing: error), privacy: .public)")
            toast = .error(BookingFormatting.friendlyError(error, subject: "The waitlist"))
            return false
        }
    }

    // MARK: - Pricing

    /// The salon's currency (euro until the salon loads).
    var currency: Currency { salon?.currency ?? .eur }

    /// Sum of the selected services and their add-ons.
    var servicesSubtotal: Money {
        selectedServices.reduce(Money.zero(currency)) { partial, service in
            let addOns = selectedAddOns(of: service)
                .reduce(Money.zero(currency)) { $0 + Money($1.price.amount, currency) }
            return partial + Money(service.price.amount, currency) + addOns
        }
    }

    /// Reduction granted by the applied coupon.
    var couponDiscount: Money {
        guard let appliedCoupon else { return .zero(currency) }
        return CouponPricing.discount(appliedCoupon, subtotal: servicesSubtotal)
    }

    /// The amount prepayment options are computed against.
    var prepaymentBase: Money { servicesSubtotal - couponDiscount }

    /// Prepayment levels offered for this order. The "pay at the salon" card
    /// is withheld when a selected service demands a deposit.
    var prepaymentOptions: [PrepaymentOption] {
        let policy = salon?.prepaymentPolicy ?? PrepaymentPolicy()
        let options = PrepaymentPricing.options(total: prepaymentBase, policy: policy)
        return requiresPrepayment ? options.filter { $0.percent != nil } : options
    }

    /// The currently chosen prepayment option.
    var selectedPrepaymentOption: PrepaymentOption? {
        prepaymentOptions.first { $0.percent == prepaymentPercent }
    }

    /// Chooses a prepayment level.
    func selectPrepayment(_ percent: PrepaymentPolicy.Percent?) {
        guard prepaymentPercent != percent else { return }
        prepaymentPercent = percent
        PRVHaptics.impact()
    }

    /// Reduction granted by prepaying in full.
    var prepaymentDiscount: Money { selectedPrepaymentOption?.discount ?? .zero(currency) }

    /// Every reduction applied to the order.
    var totalDiscount: Money { couponDiscount + prepaymentDiscount }

    /// What the visit costs after all reductions.
    var orderTotal: Money {
        let value = servicesSubtotal - totalDiscount
        return value.amount < 0 ? .zero(currency) : value
    }

    /// Charged immediately at checkout.
    var dueToday: Money { selectedPrepaymentOption?.amountDueNow ?? .zero(currency) }

    /// Settled in the salon on the day.
    var dueAtSalon: Money { selectedPrepaymentOption?.amountDueAtSalon ?? orderTotal }

    /// Human reason recorded on the order for its discount.
    var discountReason: String? {
        var parts: [String] = []
        if !couponDiscount.isZero, let code = appliedCoupon?.code {
            parts.append("Coupon \(code)")
        }
        if !prepaymentDiscount.isZero {
            parts.append("Full prepayment")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " + ")
    }

    // MARK: - Coupons

    /// Validates the typed coupon code against the salon.
    func applyCoupon(using deps: PRVDependencies) async {
        let code = couponCode.trimmed
        guard !code.isBlank else { return }
        isValidatingCoupon = true
        defer { isValidatingCoupon = false }
        do {
            let coupon = try await deps.marketing.validateCoupon(code: code, salonID: context.salonID)
            guard CouponPricing.meetsMinimumSpend(coupon, subtotal: servicesSubtotal) else {
                let minimum = coupon.minimumSpend?.formatted ?? ""
                toast = .warning("This code needs a minimum spend of \(minimum).")
                PRVHaptics.warning()
                return
            }
            appliedCoupon = coupon
            couponCode = coupon.code
            toast = .success("\(BookingFormatting.discount(coupon.discount)) applied")
        } catch {
            appliedCoupon = nil
            PRVLog.booking.info("Coupon rejected: \(code, privacy: .public)")
            toast = .warning("That code isn't valid for this salon.")
            PRVHaptics.warning()
        }
    }

    /// Removes the applied coupon.
    func removeCoupon() {
        appliedCoupon = nil
        couponCode = ""
        PRVHaptics.tap()
    }

    // MARK: - Recurrence & group

    /// The recurrence rule the booking will carry, if any.
    var recurrenceRule: RecurrenceRule? {
        guard isRecurring else { return nil }
        return RecurrenceRule(
            frequency: recurrenceFrequency,
            occurrences: isRecurrenceOngoing ? nil : max(2, recurrenceOccurrences)
        )
    }

    /// Mints one seat identifier per guest joining the client.
    ///
    /// - Note: Seats are placeholders until each guest claims their invitation;
    ///   a real invite flow resolves them to platform accounts server-side.
    func makeGuestSeatIDs() -> [User.ID] {
        guard isGroupBooking, guestCount > 0 else { return [] }
        return (0 ..< guestCount).map { _ in User.ID() }
    }

    // MARK: - Submission

    /// Books the appointment and creates its order.
    ///
    /// On success the model moves to the confirmation step and returns the new
    /// order's identifier so the view can present checkout.
    func confirm(clientID: User.ID, using deps: PRVDependencies) async -> Order.ID? {
        guard let salon, let slot = selectedSlot, !selectedServices.isEmpty else {
            toast = .warning("Pick a time before confirming.")
            return nil
        }
        guard !isSubmitting else { return nil }
        isSubmitting = true
        defer { isSubmitting = false }

        let request = BookingRequest(
            salonID: salon.id,
            clientID: clientID,
            items: selectedServices.map { service in
                BookingRequest.Item(
                    serviceID: service.id,
                    professionalID: professionalID,
                    addOnIDs: selectedAddOns(of: service).map(\.id)
                )
            },
            slot: slot,
            additionalClientIDs: makeGuestSeatIDs(),
            recurrence: recurrenceRule,
            notes: notes.trimmed.isBlank ? nil : notes.trimmed,
            prepaymentPercent: prepaymentPercent,
            couponCode: appliedCoupon?.code
        )

        do {
            let appointment = try await deps.appointments.book(request)
            let order = try await deps.payments.createOrder(makeOrder(for: appointment, salon: salon))
            confirmation = BookingConfirmation(
                appointment: appointment,
                order: order,
                salon: salon,
                amountDueNow: dueToday,
                professionalName: selectedProfessional?.displayName
            )
            move(to: .confirmation)
            PRVHaptics.success()
            return order.id
        } catch {
            PRVLog.booking.error("Booking failed: \(String(describing: error), privacy: .public)")
            toast = .error(BookingFormatting.friendlyError(error, subject: "This time slot"))
            PRVHaptics.error()
            return nil
        }
    }

    /// Builds the payable order for a freshly booked appointment: one line per
    /// service, one per add-on, with discounts and earned points applied.
    private func makeOrder(for appointment: Appointment, salon: Salon) -> Order {
        var lines: [OrderLine] = []
        for service in selectedServices {
            lines.append(OrderLine(
                kind: .service,
                title: service.name,
                unitPrice: Money(service.price.amount, currency),
                referenceID: service.id.rawValue
            ))
            for addOn in selectedAddOns(of: service) {
                lines.append(OrderLine(
                    kind: .service,
                    title: "\(service.name) · \(addOn.name)",
                    unitPrice: Money(addOn.price.amount, currency),
                    referenceID: addOn.id.rawValue
                ))
            }
        }
        return Order(
            salonID: salon.id,
            clientID: appointment.clientID,
            appointmentID: appointment.id,
            lines: lines,
            status: .awaitingPayment,
            discount: totalDiscount,
            discountReason: discountReason,
            amountPaid: .zero(currency),
            pointsEarned: PrepaymentPricing.points(
                for: orderTotal,
                percent: prepaymentPercent,
                policy: salon.prepaymentPolicy
            ),
            currency: currency
        )
    }
}
