import Foundation
import PRVFoundation
import PRVModels
import PRVNetworking
import Testing

/// `InMemoryBackend` is the reference implementation of every repository
/// protocol: previews, demo mode, and the UI tests all run against it, and the
/// Supabase-backed repositories are required to behave identically.
///
/// These tests therefore read as a **behavioural contract** rather than as
/// coverage of a fixture: every assertion here is one the live implementation
/// must also satisfy.
@Suite("Repository contract — InMemoryBackend")
struct InMemoryBackendContractTests {
    // MARK: - Search

    @Test("Search matches name, description, and category, case-insensitively")
    func searchMatchesFreeText() async throws {
        let backend = InMemoryBackend()

        let byName = try await backend.searchSalons(SalonSearchQuery(text: "velvet"))
        #expect(byName.map(\.id) == [PreviewData.salonVelvet.id])

        let byCategory = try await backend.searchSalons(SalonSearchQuery(text: "nail studio"))
        #expect(byCategory.contains { $0.id == PreviewData.salonVelvet.id })

        let empty = try await backend.searchSalons(SalonSearchQuery(text: "   "))
        #expect(empty.count == PreviewData.salons.count)

        let noMatch = try await backend.searchSalons(SalonSearchQuery(text: "zzzz"))
        #expect(noMatch.isEmpty)
    }

    @Test("Filters compose: amenities are a superset, categories and languages intersect")
    func searchFiltersCompose() async throws {
        let backend = InMemoryBackend()

        // Amenities must *all* be present — a salon offering only some is out.
        let luxuryAndParking = try await backend.searchSalons(
            SalonSearchQuery(amenities: [.luxury, .parking])
        )
        #expect(luxuryAndParking.map(\.id) == [PreviewData.salonLumiere.id])

        // Categories are an intersection — any one match qualifies.
        let nails = try await backend.searchSalons(SalonSearchQuery(categories: [.nailStudio]))
        #expect(nails.map(\.id) == [PreviewData.salonVelvet.id])

        let dutch = try await backend.searchSalons(SalonSearchQuery(languages: ["nl"]))
        #expect(dutch.map(\.id) == [PreviewData.salonLumiere.id])

        let highlyRated = try await backend.searchSalons(SalonSearchQuery(minRating: 4.8))
        #expect(highlyRated.map(\.id) == [PreviewData.salonLumiere.id])

        let verified = try await backend.searchSalons(SalonSearchQuery(verifiedOnly: true))
        #expect(verified.count == 2)

        let sorted = try await backend.searchSalons(SalonSearchQuery(sort: .rating))
        #expect(sorted.first?.id == PreviewData.salonLumiere.id)
    }

    @Test("Recently viewed is most-recent-first and never duplicates a salon")
    func recentlyViewedDeduplicates() async throws {
        let backend = InMemoryBackend()

        await backend.markViewed(salonID: PreviewData.salonVelvet.id)
        await backend.markViewed(salonID: PreviewData.salonLumiere.id)
        let firstPass = try await backend.recentlyViewedSalons()
        #expect(firstPass.map(\.id) == [PreviewData.salonLumiere.id, PreviewData.salonVelvet.id])

        await backend.markViewed(salonID: PreviewData.salonVelvet.id)
        let secondPass = try await backend.recentlyViewedSalons()
        #expect(secondPass.map(\.id) == [PreviewData.salonVelvet.id, PreviewData.salonLumiere.id])
    }

    @Test("Unknown identifiers throw notFound rather than returning a placeholder")
    func unknownIdentifiersThrowNotFound() async {
        let backend = InMemoryBackend()

        await #expect(throws: APIError.self) { _ = try await backend.salon(id: Salon.ID()) }
        await #expect(throws: APIError.self) { _ = try await backend.service(id: SalonService.ID()) }
        await #expect(throws: APIError.self) { _ = try await backend.professional(id: Professional.ID()) }
        await #expect(throws: APIError.self) { _ = try await backend.appointment(id: Appointment.ID()) }
        await #expect(throws: APIError.self) { _ = try await backend.order(id: Order.ID()) }

        let error = await apiError { _ = try await backend.salon(id: Salon.ID()) }
        #expect(error?.kind == .notFound)
    }

    @Test("Liking a review toggles both the flag and the count")
    func reviewLikeToggles() async throws {
        let backend = InMemoryBackend()
        let reviews = try await backend.reviews(salonID: PreviewData.salonLumiere.id)
        let review = try #require(reviews.first)
        let originalCount = review.likeCount

        let liked = try await backend.toggleReviewLike(id: review.id)
        #expect(liked.likedByMe)
        #expect(liked.likeCount == originalCount + 1)

        let unliked = try await backend.toggleReviewLike(id: review.id)
        #expect(!unliked.likedByMe)
        #expect(unliked.likeCount == originalCount)
    }

    // MARK: - Booking overlap

    @Test("A booked slot removes every overlapping slot from availability")
    func bookingRejectsOverlappingSlots() async throws {
        let backend = InMemoryBackend()
        let request = Self.availability()

        let before = try await backend.availableSlots(request)
        #expect(before.count > 3)

        let chosen = try #require(before.dropFirst(2).first)
        let appointment = try await backend.book(Self.booking(at: chosen))
        let start = try #require(appointment.start)
        let end = try #require(appointment.end)

        let after = try await backend.availableSlots(request)
        #expect(after.count < before.count)
        // The contract is not "one fewer slot" — it is that nothing overlapping
        // the booked window is offered again.
        #expect(!after.contains { $0.start < end && $0.end > start })
    }

    @Test("A booking with no artist assigned does not block a named artist's board")
    func unassignedBookingDoesNotBlockANamedArtist() async throws {
        let backend = InMemoryBackend()
        let anyArtist = Self.availability()

        let before = try await backend.availableSlots(anyArtist)
        let chosen = try #require(before.first)
        _ = try await backend.book(Self.booking(at: chosen))

        // Availability for a specific professional only collides with
        // appointments that professional is actually on.
        let named = Self.availability(professionalID: PreviewData.stylistAmelie.id)
        let afterForArtist = try await backend.availableSlots(named)

        #expect(afterForArtist.count == before.count)
        #expect(afterForArtist.contains { $0.start == chosen.start })
    }

    @Test("Booking builds one item per service, sequenced by occupancy time")
    func bookingSequencesItems() async throws {
        let backend = InMemoryBackend()
        let slots = try await backend.availableSlots(
            Self.availability(serviceIDs: [PreviewData.serviceCutBlowDry.id, PreviewData.serviceBalayage.id])
        )
        let chosen = try #require(slots.first)

        let appointment = try await backend.book(
            BookingRequest(
                salonID: PreviewData.salonLumiere.id,
                clientID: PreviewData.client.id,
                items: [
                    BookingRequest.Item(serviceID: PreviewData.serviceCutBlowDry.id),
                    BookingRequest.Item(serviceID: PreviewData.serviceBalayage.id),
                ],
                slot: chosen
            )
        )

        #expect(appointment.items.count == 2)
        #expect(appointment.status == .confirmed)
        #expect(appointment.items[0].start == chosen.start)
        // Cut & Blow-Dry occupies 60 + 10 minutes of chair time before the
        // next treatment can start.
        #expect(appointment.items[1].start == chosen.start.adding(minutes: 70))
        #expect(appointment.totalPrice == Money(75) + Money(185))
    }

    @Test("Booking an unknown service throws instead of inventing one")
    func bookingUnknownServiceThrows() async throws {
        let backend = InMemoryBackend()
        let slots = try await backend.availableSlots(Self.availability())
        let chosen = try #require(slots.first)

        let error = await apiError {
            _ = try await backend.book(
                BookingRequest(
                    salonID: PreviewData.salonLumiere.id,
                    clientID: PreviewData.client.id,
                    items: [BookingRequest.Item(serviceID: SalonService.ID())],
                    slot: chosen
                )
            )
        }
        #expect(error?.kind == .notFound)
    }

    @Test("A client's list includes the group bookings they were added to")
    func groupBookingsAppearForEveryParticipant() async throws {
        let backend = InMemoryBackend()
        let guest = User.ID()
        let slots = try await backend.availableSlots(Self.availability())
        let chosen = try #require(slots.first)

        _ = try await backend.book(
            BookingRequest(
                salonID: PreviewData.salonLumiere.id,
                clientID: PreviewData.client.id,
                items: [BookingRequest.Item(serviceID: PreviewData.serviceCutBlowDry.id)],
                slot: chosen,
                additionalClientIDs: [guest]
            )
        )

        let guestBookings = try await backend.appointments(clientID: guest)
        #expect(guestBookings.count == 1)
        #expect(guestBookings.first?.isGroupBooking == true)

        let clientBookings = try await backend.appointments(clientID: PreviewData.client.id)
        // Earliest first: the seeded appointment is three days out, the new one is sooner.
        #expect(clientBookings.count == 2)
        let starts = clientBookings.compactMap(\.start)
        #expect(starts == starts.sorted())
    }

    // MARK: - Cancellation and status

    @Test("Cancelling moves an appointment to cancelledByClient and stamps updatedAt")
    func cancellationTransitionsStatus() async throws {
        let backend = InMemoryBackend()
        let original = PreviewData.upcomingAppointment
        #expect(original.status == .confirmed)

        let cancelled = try await backend.cancel(
            appointmentID: original.id,
            reason: "Plans changed"
        )

        #expect(cancelled.status == .cancelledByClient)
        #expect(!cancelled.status.isActive)
        #expect(cancelled.updatedAt > original.updatedAt)
        #expect(cancelled.items == original.items)
    }

    @Test("A cancelled appointment stops blocking its slot")
    func cancellationFreesTheSlot() async throws {
        let backend = InMemoryBackend()
        let request = Self.availability()
        let before = try await backend.availableSlots(request)
        let chosen = try #require(before.dropFirst(2).first)

        let appointment = try await backend.book(Self.booking(at: chosen))
        let whileBooked = try await backend.availableSlots(request)
        #expect(whileBooked.count < before.count)

        _ = try await backend.cancel(appointmentID: appointment.id, reason: nil)

        let afterCancelling = try await backend.availableSlots(request)
        #expect(afterCancelling.count == before.count)
    }

    @Test("Status moves through the front-desk flow one step at a time")
    func statusAdvancesThroughTheFlow() async throws {
        let backend = InMemoryBackend()
        let id = PreviewData.upcomingAppointment.id

        for status: AppointmentStatus in [.checkedIn, .inProgress, .completed] {
            let updated = try await backend.updateStatus(appointmentID: id, status: status)
            #expect(updated.status == status)
        }

        let finished = try await backend.appointment(id: id)
        #expect(finished.status == .completed)
        #expect(!finished.status.isActive)

        await #expect(throws: APIError.self) {
            _ = try await backend.updateStatus(appointmentID: Appointment.ID(), status: .noShow)
        }
    }

    @Test("Rescheduling shifts every item by the same offset and re-confirms")
    func reschedulingShiftsEveryItem() async throws {
        let backend = InMemoryBackend()
        let original = try await backend.appointment(id: PreviewData.upcomingAppointment.id)
        let originalStart = try #require(original.start)
        let target = originalStart.adding(days: 2)

        let moved = try await backend.reschedule(
            appointmentID: original.id,
            to: TimeSlot(start: target, end: target.adding(minutes: 150))
        )

        #expect(moved.start == target)
        #expect(moved.status == .confirmed)
        #expect(moved.items.count == original.items.count)
        for (index, item) in moved.items.enumerated() {
            #expect(item.start == original.items[index].start.addingTimeInterval(target.timeIntervalSince(originalStart)))
        }
    }

    @Test("Waitlist entries are scoped to their salon")
    func waitlistIsScopedToItsSalon() async throws {
        let backend = InMemoryBackend()
        let entry = WaitlistEntry(
            salonID: PreviewData.salonLumiere.id,
            clientID: PreviewData.client.id,
            serviceID: PreviewData.serviceBalayage.id,
            earliest: Date.now,
            latest: Date.now.adding(days: 7)
        )

        _ = try await backend.joinWaitlist(entry)

        let lumiereWaitlist = try await backend.waitlist(salonID: PreviewData.salonLumiere.id)
        let velvetWaitlist = try await backend.waitlist(salonID: PreviewData.salonVelvet.id)
        #expect(lumiereWaitlist.count == 1)
        #expect(velvetWaitlist.isEmpty)
    }

    // MARK: - Wallet and money

    @Test("Paying an order in parts moves it through partiallyPaid to paid")
    func partialPaymentsAccumulate() async throws {
        let backend = InMemoryBackend()
        let order = Self.order()
        _ = try await backend.createOrder(order)

        let partial = try await backend.pay(
            orderID: order.id,
            method: .card,
            amount: Money(85)
        )
        #expect(partial.status == .partiallyPaid)
        #expect(partial.amountPaid == Money(85))
        #expect(partial.outstandingBalance == Money(100))
        let invoicesSoFar = try await backend.invoices(userID: PreviewData.client.id)
        #expect(invoicesSoFar.isEmpty)

        let settled = try await backend.pay(
            orderID: order.id,
            method: .applePay,
            amount: Money(100)
        )
        #expect(settled.status == .paid)
        #expect(settled.outstandingBalance.isZero)
        #expect(settled.paidAt != nil)
    }

    @Test("Every payment writes a debit to the wallet, newest first")
    func paymentsWriteWalletDebits() async throws {
        let backend = InMemoryBackend()
        let order = Self.order()
        _ = try await backend.createOrder(order)

        _ = try await backend.pay(orderID: order.id, method: .card, amount: Money(85))
        _ = try await backend.pay(orderID: order.id, method: .card, amount: Money(100))

        let transactions = try await backend.walletTransactions(userID: PreviewData.client.id)
        #expect(transactions.count == 2)
        #expect(transactions.allSatisfy { $0.kind == .payment })
        // Debits are negative: the wallet is a ledger, not a running total of
        // what was spent.
        #expect(transactions.allSatisfy { $0.amount.amount < 0 })
        #expect(transactions.map(\.amount).contains(Money(-85)))
        #expect(transactions.map(\.orderID).allSatisfy { $0 == order.id })

        let createdAt = transactions.map(\.createdAt)
        #expect(createdAt == createdAt.sorted(by: >))
    }

    @Test("Settling an order issues exactly one sequential invoice")
    func settlingIssuesAnInvoice() async throws {
        let backend = InMemoryBackend()
        let first = Self.order()
        let second = Self.order()
        _ = try await backend.createOrder(first)
        _ = try await backend.createOrder(second)

        _ = try await backend.pay(orderID: first.id, method: .applePay, amount: Money(185))
        _ = try await backend.pay(orderID: second.id, method: .applePay, amount: Money(185))

        let invoices = try await backend.invoices(userID: PreviewData.client.id)
        #expect(invoices.count == 2)
        #expect(invoices.map(\.number) == ["PRV-1001", "PRV-1002"])
        #expect(invoices.map(\.orderID) == [first.id, second.id])
    }

    @Test("Store credit counts only credit movements, never payments or refunds")
    func storeCreditIgnoresPayments() async throws {
        let backend = InMemoryBackend()
        let order = Self.order()
        _ = try await backend.createOrder(order)
        _ = try await backend.pay(orderID: order.id, method: .card, amount: Money(185))

        // A payment debit and a refund credit are both order movements, not
        // store credit — the balance must stay untouched by them.
        _ = try await backend.requestRefund(
            Refund(orderID: order.id, amount: Money(50), reason: .goodwill)
        )

        let balance = try await backend.storeCreditBalance(userID: PreviewData.client.id)
        #expect(balance == Money(0))
    }

    @Test("Refunds accumulate and flip the order to refunded once they cover it")
    func refundsAccumulate() async throws {
        let backend = InMemoryBackend()
        let order = Self.order()
        _ = try await backend.createOrder(order)
        _ = try await backend.pay(orderID: order.id, method: .card, amount: Money(185))

        _ = try await backend.requestRefund(
            Refund(orderID: order.id, amount: Money(85), reason: .cancellation)
        )
        let partiallyRefunded = try await backend.order(id: order.id)
        #expect(partiallyRefunded.status == .partiallyRefunded)

        _ = try await backend.requestRefund(
            Refund(orderID: order.id, amount: Money(100), reason: .cancellation, isAutomatic: true)
        )
        let fullyRefunded = try await backend.order(id: order.id)
        #expect(fullyRefunded.status == .refunded)

        let refunds = try await backend.refunds(orderID: order.id)
        #expect(refunds.count == 2)
        #expect(refunds.map(\.amount).contains(Money(85)))

        let credits = try await backend.walletTransactions(userID: PreviewData.client.id)
            .filter { $0.kind == .refund }
        #expect(credits.count == 2)
        #expect(credits.allSatisfy { $0.amount.amount > 0 })
    }

    @Test("Purchasing a package produces an order awaiting payment")
    func packagePurchaseCreatesAnOrder() async throws {
        let backend = InMemoryBackend()

        let order = try await backend.purchasePackage(
            packageID: PreviewData.weddingPackage.id,
            userID: PreviewData.client.id
        )

        #expect(order.status == .awaitingPayment)
        #expect(order.lines.count == 1)
        #expect(order.lines.first?.kind == .package)
        #expect(order.total == PreviewData.weddingPackage.packagePrice)
        let orders = try await backend.orders(clientID: PreviewData.client.id)
        #expect(orders.map(\.id) == [order.id])
    }

    // MARK: - Coupons

    @Test("A live coupon validates, case-insensitively, for its own salon")
    func couponValidates() async throws {
        let backend = InMemoryBackend()

        let coupon = try await backend.validateCoupon(
            code: "welcome10",
            salonID: PreviewData.salonLumiere.id
        )

        #expect(coupon.code == "WELCOME10")
        #expect(coupon.discount == .percent(10))
    }

    @Test("Coupons are rejected when unknown, foreign, inactive, expired, or exhausted")
    func couponRejectionRules() async throws {
        let backend = InMemoryBackend()
        let salonID = PreviewData.salonLumiere.id

        // Unknown code.
        var error = await apiError {
            _ = try await backend.validateCoupon(code: "NOPE", salonID: salonID)
        }
        #expect(error?.kind == .notFound)

        // Right code, wrong salon — coupons never leak across businesses.
        error = await apiError {
            _ = try await backend.validateCoupon(code: "WELCOME10", salonID: PreviewData.salonVelvet.id)
        }
        #expect(error?.kind == .notFound)

        // Switched off by the salon.
        _ = try await backend.upsertCoupon(
            Coupon(salonID: salonID, code: "PAUSED", discount: .percent(15), isActive: false)
        )
        error = await apiError {
            _ = try await backend.validateCoupon(code: "PAUSED", salonID: salonID)
        }
        #expect(error?.kind == .notFound)

        // Past its validity window.
        _ = try await backend.upsertCoupon(
            Coupon(
                salonID: salonID,
                code: "LASTYEAR",
                discount: .fixed(Money(20)),
                validUntil: Date.now.adding(days: -1)
            )
        )
        error = await apiError {
            _ = try await backend.validateCoupon(code: "LASTYEAR", salonID: salonID)
        }
        #expect(error?.kind == .notFound)

        // Fully redeemed.
        _ = try await backend.upsertCoupon(
            Coupon(
                salonID: salonID,
                code: "SOLDOUT",
                discount: .percent(25),
                maxRedemptions: 5,
                redemptionCount: 5
            )
        )
        error = await apiError {
            _ = try await backend.validateCoupon(code: "SOLDOUT", salonID: salonID)
        }
        #expect(error?.kind == .notFound)
    }

    @Test("A coupon with redemptions left still validates")
    func couponWithHeadroomValidates() async throws {
        let backend = InMemoryBackend()
        let salonID = PreviewData.salonLumiere.id

        _ = try await backend.upsertCoupon(
            Coupon(
                salonID: salonID,
                code: "SPRING",
                discount: .percent(20),
                maxRedemptions: 5,
                redemptionCount: 4,
                validUntil: Date.now.adding(days: 30)
            )
        )

        let coupon = try await backend.validateCoupon(code: "SPRING", salonID: salonID)
        #expect(coupon.redemptionCount == 4)
    }

    // MARK: - Loyalty and assistant

    @Test("The daily reward pays once per day and extends the streak")
    func dailyRewardIsIdempotentPerDay() async throws {
        let backend = InMemoryBackend()
        let userID = PreviewData.client.id
        let before = try await backend.profile(userID: userID)

        let claimed = try await backend.claimDailyReward(userID: userID)
        #expect(claimed.spendablePoints == before.spendablePoints + 25)
        #expect(claimed.xp == before.xp + 25)
        #expect(claimed.currentStreakDays == before.currentStreakDays + 1)
        #expect(claimed.lastDailyRewardAt != nil)

        let again = try await backend.claimDailyReward(userID: userID)
        #expect(again.spendablePoints == claimed.spendablePoints)
        #expect(again.currentStreakDays == claimed.currentStreakDays)

        await #expect(throws: APIError.self) {
            _ = try await backend.claimDailyReward(userID: User.ID())
        }
    }

    @Test("A first-time user gets a loyalty profile with a referral code")
    func loyaltyProfileIsCreatedOnDemand() async throws {
        let backend = InMemoryBackend()
        let newcomer = User.ID()

        let profile = try await backend.profile(userID: newcomer)

        #expect(profile.userID == newcomer)
        #expect(profile.xp == 0)
        #expect(profile.referralCode.hasPrefix("PRV-"))

        // Stable across calls — a second read must not mint a second profile.
        let reread = try await backend.profile(userID: newcomer)
        #expect(reread.id == profile.id)
    }

    @Test("The assistant conversation is created once and then reused")
    func assistantConversationIsStable() async throws {
        let backend = InMemoryBackend()

        let existing = try await backend.assistantConversation(userID: PreviewData.client.id)
        #expect(existing.kind == .assistant)
        let reread = try await backend.assistantConversation(userID: PreviewData.client.id)
        #expect(reread.id == existing.id)

        let newcomer = User.ID()
        let created = try await backend.assistantConversation(userID: newcomer)
        #expect(created.id != existing.id)
        #expect(created.participantIDs == [newcomer])
    }

    @Test("The assistant answers with intent-specific recommendations")
    func assistantRecommendationsFollowIntent() async throws {
        let backend = InMemoryBackend()
        let userID = PreviewData.client.id

        let bridal = try await backend.askAssistant(
            prompt: "I need hair and makeup for my wedding in June",
            userID: userID
        )
        #expect(bridal.packageIDs == [PreviewData.weddingPackage.id])
        #expect(bridal.serviceIDs.contains(PreviewData.serviceBalayage.id))

        let nails = try await backend.askAssistant(prompt: "My nails keep breaking", userID: userID)
        #expect(nails.serviceIDs == [PreviewData.serviceGelManicure.id])
        #expect(nails.salonIDs == [PreviewData.salonVelvet.id])

        let general = try await backend.askAssistant(prompt: "What should I book?", userID: userID)
        #expect(general.packageIDs.isEmpty)
        #expect(general.serviceIDs == [PreviewData.serviceBalayage.id])
    }

    @Test("Sending a message marks it delivered and updates its conversation preview")
    func sendingAMessageUpdatesTheConversation() async throws {
        let backend = InMemoryBackend()
        let conversations = try await backend.conversations(userID: PreviewData.client.id)
        let conversation = try #require(conversations.first { $0.kind == .clientSalon })

        let sent = try await backend.send(
            ChatMessage(
                conversationID: conversation.id,
                senderID: PreviewData.client.id,
                content: .text("Can I move to 15:00?")
            )
        )

        #expect(sent.deliveryState == .delivered)

        let afterSending = try await backend.conversations(userID: PreviewData.client.id)
        let refreshed = try #require(afterSending.first { $0.id == conversation.id })
        #expect(refreshed.lastMessagePreview == "Can I move to 15:00?")

        try await backend.markRead(conversationID: conversation.id)
        let afterReading = try await backend.conversations(userID: PreviewData.client.id)
        let read = try #require(afterReading.first { $0.id == conversation.id })
        #expect(read.unreadCount == 0)

        let thread = try await backend.messages(conversationID: conversation.id)
        #expect(thread.map(\.sentAt) == thread.map(\.sentAt).sorted())
    }

    // MARK: - Fixtures

    /// Availability for tomorrow only, so the seeded appointment three days out
    /// can never perturb a count.
    private static func availability(
        serviceIDs: [SalonService.ID] = [PreviewData.serviceCutBlowDry.id],
        professionalID: Professional.ID? = nil
    ) -> AvailabilityRequest {
        let tomorrow = Date.now.adding(days: 1).startOfDay()
        return AvailabilityRequest(
            salonID: PreviewData.salonLumiere.id,
            serviceIDs: serviceIDs,
            professionalID: professionalID,
            rangeStart: tomorrow,
            rangeEnd: tomorrow.adding(days: 1)
        )
    }

    /// A one-treatment booking at the given slot, with no artist assigned.
    private static func booking(at slot: TimeSlot) -> BookingRequest {
        BookingRequest(
            salonID: PreviewData.salonLumiere.id,
            clientID: PreviewData.client.id,
            items: [BookingRequest.Item(serviceID: PreviewData.serviceCutBlowDry.id)],
            slot: slot
        )
    }

    /// A €185 order for the demo client, awaiting payment.
    private static func order() -> Order {
        Order(
            salonID: PreviewData.salonLumiere.id,
            clientID: PreviewData.client.id,
            lines: [
                OrderLine(kind: .service, title: "Balayage & Gloss", unitPrice: Money(185)),
            ],
            status: .awaitingPayment
        )
    }
}
