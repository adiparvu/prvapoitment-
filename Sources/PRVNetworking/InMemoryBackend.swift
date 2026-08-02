import Foundation
import PRVFoundation
import PRVModels

/// A fully functional in-memory backend seeded with `PreviewData`.
/// Powers SwiftUI previews, demo mode, UI tests, and offline exploration.
public actor InMemoryBackend {
    var salons: [Salon]
    var services: [SalonService]
    var professionals: [Professional]
    var reviews: [Review]
    var appointments: [Appointment]
    var waitlist: [WaitlistEntry] = []
    var orders: [Order] = []
    var refunds: [Refund] = []
    var giftCards: [GiftCard] = []
    var walletTransactions: [WalletTransaction] = []
    var invoices: [Invoice] = []
    var savedMethods: [SavedPaymentMethod]
    var plans: [MembershipPlan]
    var subscriptions: [MembershipSubscription] = []
    var packages: [ServicePackage]
    var loyaltyProfiles: [LoyaltyProfile]
    var achievements: [Achievement]
    var challenges: [LoyaltyChallenge]
    var conversations: [Conversation]
    var messages: [ChatMessage]
    var notifications: [PRVNotification]
    var clientRecords: [ClientRecord]
    var clientNotes: [ClientNote] = []
    var consentForms: [ConsentForm] = []
    var employees: [Employee]
    var shifts: [Shift] = []
    var timeEntries: [TimeEntry] = []
    var goals: [PerformanceGoal] = []
    var products: [Product]
    var suppliers: [Supplier]
    var purchaseOrders: [PurchaseOrder] = []
    var campaigns: [Campaign] = []
    var coupons: [Coupon]
    var recentlyViewed: [Salon.ID] = []

    public init() {
        salons = PreviewData.salons
        services = PreviewData.services
        professionals = PreviewData.professionals
        reviews = PreviewData.reviews
        appointments = [PreviewData.upcomingAppointment]
        savedMethods = [
            SavedPaymentMethod(kind: .applePay, displayLabel: "Apple Pay", isDefault: true),
            SavedPaymentMethod(kind: .card, displayLabel: "Visa", lastFour: "4242", expiryMonth: 8, expiryYear: 2028),
        ]
        plans = [PreviewData.goldPlan]
        packages = [PreviewData.weddingPackage]
        loyaltyProfiles = [PreviewData.loyaltyProfile]
        achievements = [
            Achievement(title: "First Glow", details: "Complete your first appointment", symbolName: "sparkles", xpReward: 100, pointsReward: 50),
            Achievement(title: "Regular", details: "Complete 10 appointments", symbolName: "calendar.badge.checkmark", xpReward: 500, pointsReward: 250),
            Achievement(title: "Connoisseur", details: "Try 5 different service categories", symbolName: "crown.fill", xpReward: 750, pointsReward: 400),
        ]
        challenges = [
            LoyaltyChallenge(
                title: "Monthly Ritual",
                details: "Visit 3 times this month",
                symbolName: "flame.fill",
                targetCount: 3,
                progressCount: 1,
                pointsReward: 500,
                endsAt: Date.now.addingTimeInterval(60 * 60 * 24 * 21)
            ),
        ]
        let assistantConversation = Conversation(
            kind: .assistant,
            title: "Beauty Assistant",
            participantIDs: [PreviewData.client.id],
            lastMessagePreview: "I can plan your wedding look — tell me the date!",
            lastMessageAt: .now,
            unreadCount: 0
        )
        let salonConversation = Conversation(
            kind: .clientSalon,
            title: PreviewData.salonLumiere.name,
            participantIDs: [PreviewData.client.id],
            salonID: PreviewData.salonLumiere.id,
            lastMessagePreview: "See you Thursday at 14:00 ✨",
            lastMessageAt: Date.now.addingTimeInterval(-3_600),
            unreadCount: 1
        )
        conversations = [assistantConversation, salonConversation]
        messages = [
            ChatMessage(
                conversationID: salonConversation.id,
                senderID: PreviewData.owner.id,
                content: .text("See you Thursday at 14:00 ✨"),
                deliveryState: .delivered,
                sentAt: Date.now.addingTimeInterval(-3_600)
            ),
        ]
        notifications = [
            PRVNotification(
                userID: PreviewData.client.id,
                kind: .appointmentReminder,
                title: "Balayage & Gloss on Thursday",
                body: "Your appointment at Maison Lumière is in 3 days at 14:00.",
                route: .appointment(PreviewData.upcomingAppointment.id)
            ),
            PRVNotification(
                userID: PreviewData.client.id,
                kind: .loyaltyReward,
                title: "You reached Gold!",
                body: "Priority booking and exclusive offers are now unlocked.",
                route: .loyalty
            ),
        ]
        clientRecords = [
            ClientRecord(
                salonID: PreviewData.salonLumiere.id,
                userID: PreviewData.client.id,
                firstName: PreviewData.client.firstName,
                lastName: PreviewData.client.lastName,
                email: PreviewData.client.email,
                hairType: "Fine, color-treated",
                allergies: ["PPD"],
                preferences: ["Oat milk cappuccino", "Quiet appointments"],
                totalVisits: 14,
                totalSpend: Money(2_180),
                lastVisitAt: Date.now.addingTimeInterval(-60 * 60 * 24 * 20)
            ),
        ]
        employees = [
            Employee(
                salonID: PreviewData.salonLumiere.id,
                professionalID: PreviewData.stylistAmelie.id,
                role: .salonEmployee,
                compensation: .hybrid,
                monthlySalary: Money(2_400),
                commissionPercent: 15
            ),
        ]
        suppliers = [Supplier(name: "Beauty Supplies BV", email: "orders@beautysupplies.be")]
        products = [
            Product(
                salonID: PreviewData.salonLumiere.id,
                name: "No.4 Bond Maintenance Shampoo",
                brand: "Olaplex",
                retailPrice: Money(32),
                costPrice: Money(17),
                stockQuantity: 12
            ),
            Product(
                salonID: PreviewData.salonLumiere.id,
                name: "Élixir Ultime Oil",
                brand: "Kérastase",
                retailPrice: Money(48),
                costPrice: Money(26),
                stockQuantity: 3
            ),
        ]
        coupons = [
            Coupon(
                salonID: PreviewData.salonLumiere.id,
                code: "WELCOME10",
                discount: .percent(10),
                validUntil: Date.now.addingTimeInterval(60 * 60 * 24 * 90)
            ),
        ]
    }
}

// MARK: - SalonRepository

extension InMemoryBackend: SalonRepository {
    public func searchSalons(_ query: SalonSearchQuery) async throws -> [Salon] {
        var results = salons
        if !query.text.isBlank {
            let needle = query.text.lowercased()
            results = results.filter {
                $0.name.lowercased().contains(needle)
                    || $0.about.lowercased().contains(needle)
                    || $0.categories.contains { $0.displayName.lowercased().contains(needle) }
            }
        }
        if !query.categories.isEmpty {
            results = results.filter { !Set($0.categories).isDisjoint(with: query.categories) }
        }
        if !query.amenities.isEmpty {
            results = results.filter { Set($0.amenities).isSuperset(of: query.amenities) }
        }
        if !query.languages.isEmpty {
            results = results.filter { !Set($0.languages).isDisjoint(with: query.languages) }
        }
        if let minRating = query.minRating {
            results = results.filter { $0.rating >= minRating }
        }
        if query.verifiedOnly {
            results = results.filter(\.isVerified)
        }
        switch query.sort {
        case .rating: results.sort { $0.rating > $1.rating }
        case .recommended, .distance, .priceLowToHigh, .priceHighToLow: break
        }
        return results
    }

    public func salon(id: Salon.ID) async throws -> Salon {
        guard let salon = salons.first(where: { $0.id == id }) else { throw APIError.notFound }
        return salon
    }

    public func trendingSalons() async throws -> [Salon] {
        salons.sorted { $0.reviewCount > $1.reviewCount }
    }

    public func nearbySalons(_ coordinate: GeoCoordinate?) async throws -> [Salon] {
        salons
    }

    public func recentlyViewedSalons() async throws -> [Salon] {
        recentlyViewed.compactMap { id in salons.first { $0.id == id } }
    }

    public func markViewed(salonID: Salon.ID) async {
        recentlyViewed.removeAll { $0 == salonID }
        recentlyViewed.insert(salonID, at: 0)
        recentlyViewed = Array(recentlyViewed.prefix(10))
    }

    public func services(salonID: Salon.ID) async throws -> [SalonService] {
        services.filter { $0.salonID == salonID }
    }

    public func service(id: SalonService.ID) async throws -> SalonService {
        guard let service = services.first(where: { $0.id == id }) else { throw APIError.notFound }
        return service
    }

    public func professionals(salonID: Salon.ID) async throws -> [Professional] {
        professionals.filter { $0.salonID == salonID }
    }

    public func professional(id: Professional.ID) async throws -> Professional {
        guard let professional = professionals.first(where: { $0.id == id }) else { throw APIError.notFound }
        return professional
    }

    public func reviews(salonID: Salon.ID) async throws -> [Review] {
        reviews.filter { $0.salonID == salonID }.sorted { $0.createdAt > $1.createdAt }
    }

    public func submitReview(_ review: Review) async throws -> Review {
        reviews.append(review)
        return review
    }

    public func toggleReviewLike(id: Review.ID) async throws -> Review {
        guard let index = reviews.firstIndex(where: { $0.id == id }) else { throw APIError.notFound }
        reviews[index].likedByMe.toggle()
        reviews[index].likeCount += reviews[index].likedByMe ? 1 : -1
        return reviews[index]
    }
}

// MARK: - AppointmentRepository

extension InMemoryBackend: AppointmentRepository {
    public func appointments(clientID: User.ID) async throws -> [Appointment] {
        appointments
            .filter { $0.clientID == clientID || $0.additionalClientIDs.contains(clientID) }
            .sorted { ($0.start ?? .distantPast) < ($1.start ?? .distantPast) }
    }

    public func appointments(salonID: Salon.ID, on day: Date) async throws -> [Appointment] {
        appointments.filter { appointment in
            appointment.salonID == salonID && (appointment.start?.isSameDay(as: day) ?? false)
        }
    }

    public func appointment(id: Appointment.ID) async throws -> Appointment {
        guard let appointment = appointments.first(where: { $0.id == id }) else { throw APIError.notFound }
        return appointment
    }

    public func availableSlots(_ request: AvailabilityRequest) async throws -> [TimeSlot] {
        let requested = services.filter { request.serviceIDs.contains($0.id) }
        let totalMinutes = max(30, requested.reduce(0) { $0 + $1.totalOccupancyMinutes })
        let calendar = Calendar.current
        var slots: [TimeSlot] = []
        var day = request.rangeStart.startOfDay()
        while day <= request.rangeEnd, slots.count < 120 {
            for minute in stride(from: 9 * 60, through: 18 * 60 - totalMinutes, by: 45) {
                guard let start = calendar.date(byAdding: .minute, value: minute, to: day) else { continue }
                guard start > .now, start >= request.rangeStart, start <= request.rangeEnd else { continue }
                let end = start.adding(minutes: totalMinutes)
                let conflicts = appointments.contains { appointment in
                    guard appointment.status.isActive,
                          appointment.salonID == request.salonID,
                          let existingStart = appointment.start,
                          let existingEnd = appointment.end
                    else { return false }
                    if let wanted = request.professionalID,
                       !appointment.items.contains(where: { $0.professionalID == wanted }) {
                        return false
                    }
                    return start < existingEnd && end > existingStart
                }
                guard !conflicts else { continue }
                // Morning-adjacency scoring approximates the gap-filling optimizer.
                let score = 1.0 - abs(Double(minute) - 11 * 60) / (9 * 60)
                slots.append(TimeSlot(
                    start: start,
                    end: end,
                    professionalID: request.professionalID,
                    optimizationScore: score
                ))
            }
            day = day.adding(days: 1)
        }
        return slots
    }

    public func book(_ request: BookingRequest) async throws -> Appointment {
        let salon = try await salon(id: request.salonID)
        var cursor = request.slot.start
        var items: [AppointmentItem] = []
        for item in request.items {
            guard let service = services.first(where: { $0.id == item.serviceID }) else {
                throw APIError.notFound
            }
            let professional = professionals.first { $0.id == item.professionalID }
            let addOnMinutes = service.addOns
                .filter { item.addOnIDs.contains($0.id) }
                .reduce(0) { $0 + $1.extraMinutes }
            let addOnPrice = service.addOns
                .filter { item.addOnIDs.contains($0.id) }
                .reduce(Money.zero(service.price.currency)) { $0 + $1.price }
            items.append(AppointmentItem(
                serviceID: service.id,
                serviceName: service.name,
                professionalID: professional?.id,
                professionalName: professional?.displayName,
                start: cursor,
                durationMinutes: service.durationMinutes + addOnMinutes,
                price: service.price + addOnPrice
            ))
            cursor = cursor.adding(minutes: service.totalOccupancyMinutes + addOnMinutes)
        }
        let appointment = Appointment(
            salonID: salon.id,
            salonName: salon.name,
            clientID: request.clientID,
            additionalClientIDs: request.additionalClientIDs,
            items: items,
            status: .confirmed,
            recurrence: request.recurrence,
            clientNotes: request.notes
        )
        appointments.append(appointment)
        return appointment
    }

    public func cancel(appointmentID: Appointment.ID, reason: String?) async throws -> Appointment {
        try updateAppointment(id: appointmentID) { $0.status = .cancelledByClient }
    }

    public func reschedule(appointmentID: Appointment.ID, to slot: TimeSlot) async throws -> Appointment {
        try updateAppointment(id: appointmentID) { appointment in
            guard let firstStart = appointment.start else { return }
            let offset = slot.start.timeIntervalSince(firstStart)
            for index in appointment.items.indices {
                appointment.items[index].start.addTimeInterval(offset)
            }
            appointment.status = .confirmed
        }
    }

    public func updateStatus(appointmentID: Appointment.ID, status: AppointmentStatus) async throws -> Appointment {
        try updateAppointment(id: appointmentID) { $0.status = status }
    }

    public func joinWaitlist(_ entry: WaitlistEntry) async throws -> WaitlistEntry {
        waitlist.append(entry)
        return entry
    }

    public func waitlist(salonID: Salon.ID) async throws -> [WaitlistEntry] {
        waitlist.filter { $0.salonID == salonID }
    }

    private func updateAppointment(
        id: Appointment.ID,
        _ mutate: (inout Appointment) -> Void
    ) throws -> Appointment {
        guard let index = appointments.firstIndex(where: { $0.id == id }) else {
            throw APIError.notFound
        }
        mutate(&appointments[index])
        appointments[index].updatedAt = .now
        return appointments[index]
    }
}

// MARK: - PaymentRepository

extension InMemoryBackend: PaymentRepository {
    public func savedMethods(userID: User.ID) async throws -> [SavedPaymentMethod] {
        savedMethods
    }

    public func orders(clientID: User.ID) async throws -> [Order] {
        orders.filter { $0.clientID == clientID }.sorted { $0.createdAt > $1.createdAt }
    }

    public func order(id: Order.ID) async throws -> Order {
        guard let order = orders.first(where: { $0.id == id }) else { throw APIError.notFound }
        return order
    }

    public func createOrder(_ order: Order) async throws -> Order {
        orders.append(order)
        return order
    }

    public func pay(orderID: Order.ID, method: PaymentMethodKind, amount: Money) async throws -> Order {
        guard let index = orders.firstIndex(where: { $0.id == orderID }) else { throw APIError.notFound }
        orders[index].amountPaid = orders[index].amountPaid + amount
        orders[index].status = orders[index].outstandingBalance.isZero ? .paid : .partiallyPaid
        orders[index].paidAt = .now
        let order = orders[index]
        walletTransactions.append(WalletTransaction(
            userID: order.clientID,
            kind: .payment,
            amount: Money(-amount.amount, amount.currency),
            title: order.lines.first?.title ?? "Payment",
            orderID: order.id
        ))
        if order.status == .paid {
            invoices.append(Invoice(
                orderID: order.id,
                number: "PRV-\(invoices.count + 1_001)"
            ))
        }
        return order
    }

    public func refunds(orderID: Order.ID) async throws -> [Refund] {
        refunds.filter { $0.orderID == orderID }
    }

    public func requestRefund(_ refund: Refund) async throws -> Refund {
        refunds.append(refund)
        if let index = orders.firstIndex(where: { $0.id == refund.orderID }) {
            let totalRefunded = refunds
                .filter { $0.orderID == refund.orderID }
                .reduce(Money.zero(refund.amount.currency)) { $0 + $1.amount }
            orders[index].status = totalRefunded >= orders[index].amountPaid
                ? .refunded
                : .partiallyRefunded
        }
        walletTransactions.append(WalletTransaction(
            userID: PreviewData.client.id,
            kind: .refund,
            amount: refund.amount,
            title: "Refund",
            orderID: refund.orderID
        ))
        return refund
    }

    public func giftCards(userID: User.ID) async throws -> [GiftCard] {
        giftCards.filter { $0.purchaserID == userID }
    }

    public func purchaseGiftCard(_ card: GiftCard) async throws -> GiftCard {
        giftCards.append(card)
        return card
    }

    public func redeemGiftCard(code: String) async throws -> GiftCard {
        guard let card = giftCards.first(where: { $0.code == code }) else { throw APIError.notFound }
        return card
    }

    public func walletTransactions(userID: User.ID) async throws -> [WalletTransaction] {
        walletTransactions.filter { $0.userID == userID }.sorted { $0.createdAt > $1.createdAt }
    }

    public func invoices(userID: User.ID) async throws -> [Invoice] {
        invoices
    }

    public func storeCreditBalance(userID: User.ID) async throws -> Money {
        walletTransactions
            .filter { $0.userID == userID && ($0.kind == .cashback || $0.kind == .storeCreditTopUp || $0.kind == .storeCreditSpend) }
            .reduce(.zero()) { $0 + $1.amount }
    }
}

// MARK: - Membership / Loyalty

extension InMemoryBackend: MembershipRepository {
    public func plans(salonID: Salon.ID?) async throws -> [MembershipPlan] {
        salonID.map { id in plans.filter { $0.salonID == id } } ?? plans
    }

    public func subscriptions(userID: User.ID) async throws -> [MembershipSubscription] {
        subscriptions.filter { $0.userID == userID }
    }

    public func subscribe(planID: MembershipPlan.ID, userID: User.ID) async throws -> MembershipSubscription {
        guard let plan = plans.first(where: { $0.id == planID }) else { throw APIError.notFound }
        let subscription = MembershipSubscription(
            planID: planID,
            plan: plan,
            userID: userID,
            renewsAt: Date.now.addingTimeInterval(TimeInterval(plan.cycle.months) * 30 * 24 * 3_600)
        )
        subscriptions.append(subscription)
        return subscription
    }

    public func cancelSubscription(id: MembershipSubscription.ID) async throws -> MembershipSubscription {
        guard let index = subscriptions.firstIndex(where: { $0.id == id }) else { throw APIError.notFound }
        subscriptions[index].status = .cancelled
        subscriptions[index].cancelledAt = .now
        return subscriptions[index]
    }

    public func packages(salonID: Salon.ID?) async throws -> [ServicePackage] {
        salonID.map { id in packages.filter { $0.salonID == id } } ?? packages
    }

    public func purchasePackage(packageID: ServicePackage.ID, userID: User.ID) async throws -> Order {
        guard let package = packages.first(where: { $0.id == packageID }) else { throw APIError.notFound }
        let order = Order(
            salonID: package.salonID,
            clientID: userID,
            lines: [OrderLine(kind: .package, title: package.name, unitPrice: package.packagePrice)],
            status: .awaitingPayment
        )
        orders.append(order)
        return order
    }
}

extension InMemoryBackend: LoyaltyRepository {
    public func profile(userID: User.ID) async throws -> LoyaltyProfile {
        if let profile = loyaltyProfiles.first(where: { $0.userID == userID }) { return profile }
        let profile = LoyaltyProfile(userID: userID, referralCode: "PRV-\(userID.description.prefix(6))")
        loyaltyProfiles.append(profile)
        return profile
    }

    public func allAchievements() async throws -> [Achievement] {
        achievements
    }

    public func challenges(userID: User.ID) async throws -> [LoyaltyChallenge] {
        challenges
    }

    public func claimDailyReward(userID: User.ID) async throws -> LoyaltyProfile {
        guard let index = loyaltyProfiles.firstIndex(where: { $0.userID == userID }) else {
            throw APIError.notFound
        }
        let today = Date.now
        if let last = loyaltyProfiles[index].lastDailyRewardAt, last.isSameDay(as: today) {
            return loyaltyProfiles[index]
        }
        loyaltyProfiles[index].spendablePoints += 25
        loyaltyProfiles[index].xp += 25
        loyaltyProfiles[index].currentStreakDays += 1
        loyaltyProfiles[index].lastDailyRewardAt = today
        return loyaltyProfiles[index]
    }
}

// MARK: - Chat

extension InMemoryBackend: ChatRepository {
    public func conversations(userID: User.ID) async throws -> [Conversation] {
        conversations
            .filter { $0.participantIDs.contains(userID) }
            .sorted { ($0.lastMessageAt ?? .distantPast) > ($1.lastMessageAt ?? .distantPast) }
    }

    public func messages(conversationID: Conversation.ID) async throws -> [ChatMessage] {
        messages.filter { $0.conversationID == conversationID }.sorted { $0.sentAt < $1.sentAt }
    }

    public func send(_ message: ChatMessage) async throws -> ChatMessage {
        var delivered = message
        delivered.deliveryState = .delivered
        messages.append(delivered)
        if let index = conversations.firstIndex(where: { $0.id == message.conversationID }) {
            if case .text(let text) = message.content {
                conversations[index].lastMessagePreview = text
            }
            conversations[index].lastMessageAt = message.sentAt
        }
        return delivered
    }

    public func markRead(conversationID: Conversation.ID) async throws {
        if let index = conversations.firstIndex(where: { $0.id == conversationID }) {
            conversations[index].unreadCount = 0
        }
    }

    public nonisolated func liveMessages(conversationID: Conversation.ID) -> AsyncStream<ChatMessage> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    public func askAssistant(prompt: String, userID: User.ID) async throws -> AssistantRecommendation {
        let lowered = prompt.lowercased()
        if lowered.contains("wedding") || lowered.contains("bride") {
            return AssistantRecommendation(
                headline: "Your bridal countdown plan",
                rationale: "Two weeks out is perfect: a trial now, gloss and shape the week of, and the Bridal Radiance package covers your wedding-day look end to end.",
                serviceIDs: [PreviewData.serviceBalayage.id, PreviewData.serviceCutBlowDry.id],
                salonIDs: [PreviewData.salonLumiere.id],
                professionalIDs: [PreviewData.stylistAmelie.id],
                packageIDs: [PreviewData.weddingPackage.id],
                maintenanceAdvice: "Book a gloss refresh 5 days before the ceremony."
            )
        }
        if lowered.contains("nail") {
            return AssistantRecommendation(
                headline: "Stronger nails, beautiful finish",
                rationale: "A gel manicure with structured overlay protects brittle nails while they recover.",
                serviceIDs: [PreviewData.serviceGelManicure.id],
                salonIDs: [PreviewData.salonVelvet.id],
                professionalIDs: [PreviewData.artistNoor.id],
                maintenanceAdvice: "Refill every 3 weeks; add a keratin cure at home."
            )
        }
        return AssistantRecommendation(
            headline: "Here's what I'd book",
            rationale: "Based on your history, a balayage refresh with Amélie keeps your color dimensional into the season.",
            serviceIDs: [PreviewData.serviceBalayage.id],
            salonIDs: [PreviewData.salonLumiere.id],
            professionalIDs: [PreviewData.stylistAmelie.id]
        )
    }

    public func assistantConversation(userID: User.ID) async throws -> Conversation {
        if let existing = conversations.first(where: { $0.kind == .assistant && $0.participantIDs.contains(userID) }) {
            return existing
        }
        let conversation = Conversation(kind: .assistant, title: "Beauty Assistant", participantIDs: [userID])
        conversations.append(conversation)
        return conversation
    }
}

// MARK: - Notifications / CRM / Team / Inventory / Marketing / Analytics

extension InMemoryBackend: NotificationRepository {
    public func notifications(userID: User.ID) async throws -> [PRVNotification] {
        notifications.filter { $0.userID == userID }.sorted { $0.createdAt > $1.createdAt }
    }

    public func markRead(id: PRVNotification.ID) async throws {
        if let index = notifications.firstIndex(where: { $0.id == id }) {
            notifications[index].isRead = true
        }
    }

    public func markAllRead(userID: User.ID) async throws {
        for index in notifications.indices where notifications[index].userID == userID {
            notifications[index].isRead = true
        }
    }

    public func registerDeviceToken(_ token: String, userID: User.ID) async throws {}
}

extension InMemoryBackend: CRMRepository {
    public func clients(salonID: Salon.ID, searchText: String) async throws -> [ClientRecord] {
        var results = clientRecords.filter { $0.salonID == salonID }
        if !searchText.isBlank {
            let needle = searchText.lowercased()
            results = results.filter { $0.fullName.lowercased().contains(needle) }
        }
        return results.sorted { $0.lastName < $1.lastName }
    }

    public func client(id: ClientRecord.ID) async throws -> ClientRecord {
        guard let record = clientRecords.first(where: { $0.id == id }) else { throw APIError.notFound }
        return record
    }

    public func upsertClient(_ record: ClientRecord) async throws -> ClientRecord {
        if let index = clientRecords.firstIndex(where: { $0.id == record.id }) {
            clientRecords[index] = record
        } else {
            clientRecords.append(record)
        }
        return record
    }

    public func notes(clientRecordID: ClientRecord.ID) async throws -> [ClientNote] {
        clientNotes.filter { $0.clientRecordID == clientRecordID }.sorted { $0.createdAt > $1.createdAt }
    }

    public func addNote(_ note: ClientNote) async throws -> ClientNote {
        clientNotes.append(note)
        return note
    }

    public func consentForms(clientRecordID: ClientRecord.ID) async throws -> [ConsentForm] {
        consentForms.filter { $0.clientRecordID == clientRecordID }
    }

    public func saveConsentForm(_ form: ConsentForm) async throws -> ConsentForm {
        if let index = consentForms.firstIndex(where: { $0.id == form.id }) {
            consentForms[index] = form
        } else {
            consentForms.append(form)
        }
        return form
    }
}

extension InMemoryBackend: TeamRepository {
    public func employees(salonID: Salon.ID) async throws -> [Employee] {
        employees.filter { $0.salonID == salonID }
    }

    public func shifts(salonID: Salon.ID, weekContaining: Date) async throws -> [Shift] {
        shifts.filter { $0.salonID == salonID }
    }

    public func saveShift(_ shift: Shift) async throws -> Shift {
        if let index = shifts.firstIndex(where: { $0.id == shift.id }) {
            shifts[index] = shift
        } else {
            shifts.append(shift)
        }
        return shift
    }

    public func deleteShift(id: Shift.ID) async throws {
        shifts.removeAll { $0.id == id }
    }

    public func timeEntries(employeeID: Employee.ID) async throws -> [TimeEntry] {
        timeEntries.filter { $0.employeeID == employeeID }.sorted { $0.clockIn > $1.clockIn }
    }

    public func clockIn(employeeID: Employee.ID, location: GeoCoordinate?) async throws -> TimeEntry {
        let entry = TimeEntry(
            employeeID: employeeID,
            clockIn: .now,
            clockInLocation: location,
            gpsValidated: location != nil
        )
        timeEntries.append(entry)
        return entry
    }

    public func clockOut(entryID: TimeEntry.ID, location: GeoCoordinate?) async throws -> TimeEntry {
        guard let index = timeEntries.firstIndex(where: { $0.id == entryID }) else { throw APIError.notFound }
        timeEntries[index].clockOut = .now
        timeEntries[index].clockOutLocation = location
        return timeEntries[index]
    }

    public func goals(employeeID: Employee.ID) async throws -> [PerformanceGoal] {
        goals.filter { $0.employeeID == employeeID }
    }
}

extension InMemoryBackend: InventoryRepository {
    public func products(salonID: Salon.ID) async throws -> [Product] {
        products.filter { $0.salonID == salonID }
    }

    public func upsertProduct(_ product: Product) async throws -> Product {
        if let index = products.firstIndex(where: { $0.id == product.id }) {
            products[index] = product
        } else {
            products.append(product)
        }
        return product
    }

    public func product(barcode: String, salonID: Salon.ID) async throws -> Product {
        guard let product = products.first(where: { $0.barcode == barcode && $0.salonID == salonID }) else {
            throw APIError.notFound
        }
        return product
    }

    public func suppliers() async throws -> [Supplier] {
        suppliers
    }

    public func purchaseOrders(salonID: Salon.ID) async throws -> [PurchaseOrder] {
        purchaseOrders.filter { $0.salonID == salonID }
    }

    public func upsertPurchaseOrder(_ order: PurchaseOrder) async throws -> PurchaseOrder {
        if let index = purchaseOrders.firstIndex(where: { $0.id == order.id }) {
            purchaseOrders[index] = order
        } else {
            purchaseOrders.append(order)
        }
        return order
    }
}

extension InMemoryBackend: MarketingRepository {
    public func campaigns(salonID: Salon.ID) async throws -> [Campaign] {
        campaigns.filter { $0.salonID == salonID }
    }

    public func upsertCampaign(_ campaign: Campaign) async throws -> Campaign {
        if let index = campaigns.firstIndex(where: { $0.id == campaign.id }) {
            campaigns[index] = campaign
        } else {
            campaigns.append(campaign)
        }
        return campaign
    }

    public func coupons(salonID: Salon.ID) async throws -> [Coupon] {
        coupons.filter { $0.salonID == salonID }
    }

    public func upsertCoupon(_ coupon: Coupon) async throws -> Coupon {
        if let index = coupons.firstIndex(where: { $0.id == coupon.id }) {
            coupons[index] = coupon
        } else {
            coupons.append(coupon)
        }
        return coupon
    }

    public func validateCoupon(code: String, salonID: Salon.ID) async throws -> Coupon {
        guard let coupon = coupons.first(where: {
            $0.code.caseInsensitiveCompare(code) == .orderedSame && $0.salonID == salonID
        }), coupon.isActive,
        coupon.validUntil.map({ $0 > .now }) ?? true,
        coupon.maxRedemptions.map({ coupon.redemptionCount < $0 }) ?? true
        else { throw APIError.notFound }
        return coupon
    }
}

extension InMemoryBackend: AnalyticsRepository {
    public func dashboard(salonID: Salon.ID, periodStart: Date, periodEnd: Date) async throws -> DashboardSnapshot {
        let calendar = Calendar.current
        let dayCount = max(1, calendar.dateComponents([.day], from: periodStart, to: periodEnd).day ?? 1)
        // Deterministic demo series shaped like a healthy salon week.
        let weights: [Decimal] = [640, 720, 580, 810, 940, 1_260, 380]
        let series: [MetricPoint] = (0 ..< min(dayCount, 30)).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: periodStart) else { return nil }
            let weekday = calendar.component(.weekday, from: date)
            return MetricPoint(date: date, value: weights[(weekday - 1) % weights.count])
        }
        let revenue = series.reduce(Decimal(0)) { $0 + $1.value }
        return DashboardSnapshot(
            salonID: salonID,
            periodStart: periodStart,
            periodEnd: periodEnd,
            revenue: Money(revenue),
            revenueForecast: Money((revenue * 112 / 100).rounded()),
            appointmentCount: series.count * 9,
            completedCount: series.count * 8,
            cancellationRate: 0.06,
            occupancyRate: 0.78,
            newClientCount: 14,
            returningClientCount: 96,
            retentionRate: 0.83,
            averageTicket: Money(86),
            productsSold: 41,
            membershipsSold: 6,
            revenueSeries: series,
            revenueByService: [
                NamedMetric(name: "Balayage & Gloss", value: revenue * 46 / 100),
                NamedMetric(name: "Cut & Blow-Dry", value: revenue * 31 / 100),
                NamedMetric(name: "Retail", value: revenue * 23 / 100),
            ],
            revenueByEmployee: [
                NamedMetric(name: "Amélie Dubois", value: revenue * 62 / 100),
                NamedMetric(name: "Guest Artists", value: revenue * 38 / 100),
            ]
        )
    }

    public func organizationDashboard(
        organizationID: Organization.ID,
        periodStart: Date,
        periodEnd: Date
    ) async throws -> [DashboardSnapshot] {
        var snapshots: [DashboardSnapshot] = []
        for salon in salons {
            snapshots.append(try await dashboard(salonID: salon.id, periodStart: periodStart, periodEnd: periodEnd))
        }
        return snapshots
    }
}

// MARK: - Auth

extension InMemoryBackend: AuthService {
    public func restoreSession() async -> User? {
        PreviewData.client
    }

    public func signIn(email: String, password: String) async throws -> User {
        PreviewData.client
    }

    public func signInWithApple(identityToken: Data, fullName: String?) async throws -> User {
        PreviewData.client
    }

    public func signUp(email: String, password: String, firstName: String, lastName: String) async throws -> User {
        User(role: .client, firstName: firstName, lastName: lastName, email: email)
    }

    public func signOut() async {}

    public func deleteAccount() async throws {}
}
