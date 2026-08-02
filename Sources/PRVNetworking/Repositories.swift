import Foundation
import PRVModels

// Repository protocols are the single data contract between features and the
// backend. Live implementations are Supabase-backed with offline caching;
// `InMemoryBackend` powers previews, demo mode, and tests.

public protocol SalonRepository: Sendable {
    func searchSalons(_ query: SalonSearchQuery) async throws -> [Salon]
    func salon(id: Salon.ID) async throws -> Salon
    func trendingSalons() async throws -> [Salon]
    func nearbySalons(_ coordinate: GeoCoordinate?) async throws -> [Salon]
    func recentlyViewedSalons() async throws -> [Salon]
    func markViewed(salonID: Salon.ID) async
    func services(salonID: Salon.ID) async throws -> [SalonService]
    func service(id: SalonService.ID) async throws -> SalonService
    func professionals(salonID: Salon.ID) async throws -> [Professional]
    func professional(id: Professional.ID) async throws -> Professional
    func reviews(salonID: Salon.ID) async throws -> [Review]
    func submitReview(_ review: Review) async throws -> Review
    func toggleReviewLike(id: Review.ID) async throws -> Review
}

public protocol AppointmentRepository: Sendable {
    func appointments(clientID: User.ID) async throws -> [Appointment]
    func appointments(salonID: Salon.ID, on day: Date) async throws -> [Appointment]
    func appointment(id: Appointment.ID) async throws -> Appointment
    func availableSlots(_ request: AvailabilityRequest) async throws -> [TimeSlot]
    func book(_ request: BookingRequest) async throws -> Appointment
    func cancel(appointmentID: Appointment.ID, reason: String?) async throws -> Appointment
    func reschedule(appointmentID: Appointment.ID, to slot: TimeSlot) async throws -> Appointment
    func updateStatus(appointmentID: Appointment.ID, status: AppointmentStatus) async throws -> Appointment
    func joinWaitlist(_ entry: WaitlistEntry) async throws -> WaitlistEntry
    func waitlist(salonID: Salon.ID) async throws -> [WaitlistEntry]
}

public protocol PaymentRepository: Sendable {
    func savedMethods(userID: User.ID) async throws -> [SavedPaymentMethod]
    func orders(clientID: User.ID) async throws -> [Order]
    func order(id: Order.ID) async throws -> Order
    func createOrder(_ order: Order) async throws -> Order
    /// Charges `amount` against the order using the given method and returns
    /// the updated order. Payment intents are created server-side.
    func pay(orderID: Order.ID, method: PaymentMethodKind, amount: Money) async throws -> Order
    func refunds(orderID: Order.ID) async throws -> [Refund]
    func requestRefund(_ refund: Refund) async throws -> Refund
    func giftCards(userID: User.ID) async throws -> [GiftCard]
    func purchaseGiftCard(_ card: GiftCard) async throws -> GiftCard
    func redeemGiftCard(code: String) async throws -> GiftCard
    func walletTransactions(userID: User.ID) async throws -> [WalletTransaction]
    func invoices(userID: User.ID) async throws -> [Invoice]
    func storeCreditBalance(userID: User.ID) async throws -> Money
}

public protocol MembershipRepository: Sendable {
    func plans(salonID: Salon.ID?) async throws -> [MembershipPlan]
    func subscriptions(userID: User.ID) async throws -> [MembershipSubscription]
    func subscribe(planID: MembershipPlan.ID, userID: User.ID) async throws -> MembershipSubscription
    func cancelSubscription(id: MembershipSubscription.ID) async throws -> MembershipSubscription
    func packages(salonID: Salon.ID?) async throws -> [ServicePackage]
    func purchasePackage(packageID: ServicePackage.ID, userID: User.ID) async throws -> Order
}

public protocol LoyaltyRepository: Sendable {
    func profile(userID: User.ID) async throws -> LoyaltyProfile
    func allAchievements() async throws -> [Achievement]
    func challenges(userID: User.ID) async throws -> [LoyaltyChallenge]
    func claimDailyReward(userID: User.ID) async throws -> LoyaltyProfile
}

public protocol ChatRepository: Sendable {
    func conversations(userID: User.ID) async throws -> [Conversation]
    func messages(conversationID: Conversation.ID) async throws -> [ChatMessage]
    func send(_ message: ChatMessage) async throws -> ChatMessage
    func markRead(conversationID: Conversation.ID) async throws
    /// Streams live messages for a conversation (finishes when cancelled).
    func liveMessages(conversationID: Conversation.ID) -> AsyncStream<ChatMessage>
    /// Asks the AI Beauty Assistant for recommendations.
    func askAssistant(prompt: String, userID: User.ID) async throws -> AssistantRecommendation
    /// The user's dedicated assistant conversation (created on first use).
    func assistantConversation(userID: User.ID) async throws -> Conversation
}

public protocol NotificationRepository: Sendable {
    func notifications(userID: User.ID) async throws -> [PRVNotification]
    func markRead(id: PRVNotification.ID) async throws
    func markAllRead(userID: User.ID) async throws
    func registerDeviceToken(_ token: String, userID: User.ID) async throws
}

public protocol CRMRepository: Sendable {
    func clients(salonID: Salon.ID, searchText: String) async throws -> [ClientRecord]
    func client(id: ClientRecord.ID) async throws -> ClientRecord
    func upsertClient(_ record: ClientRecord) async throws -> ClientRecord
    func notes(clientRecordID: ClientRecord.ID) async throws -> [ClientNote]
    func addNote(_ note: ClientNote) async throws -> ClientNote
    func consentForms(clientRecordID: ClientRecord.ID) async throws -> [ConsentForm]
    func saveConsentForm(_ form: ConsentForm) async throws -> ConsentForm
}

public protocol TeamRepository: Sendable {
    func employees(salonID: Salon.ID) async throws -> [Employee]
    func shifts(salonID: Salon.ID, weekContaining: Date) async throws -> [Shift]
    func saveShift(_ shift: Shift) async throws -> Shift
    func deleteShift(id: Shift.ID) async throws
    func timeEntries(employeeID: Employee.ID) async throws -> [TimeEntry]
    func clockIn(employeeID: Employee.ID, location: GeoCoordinate?) async throws -> TimeEntry
    func clockOut(entryID: TimeEntry.ID, location: GeoCoordinate?) async throws -> TimeEntry
    func goals(employeeID: Employee.ID) async throws -> [PerformanceGoal]
}

public protocol InventoryRepository: Sendable {
    func products(salonID: Salon.ID) async throws -> [Product]
    func upsertProduct(_ product: Product) async throws -> Product
    func product(barcode: String, salonID: Salon.ID) async throws -> Product
    func suppliers() async throws -> [Supplier]
    func purchaseOrders(salonID: Salon.ID) async throws -> [PurchaseOrder]
    func upsertPurchaseOrder(_ order: PurchaseOrder) async throws -> PurchaseOrder
}

public protocol MarketingRepository: Sendable {
    func campaigns(salonID: Salon.ID) async throws -> [Campaign]
    func upsertCampaign(_ campaign: Campaign) async throws -> Campaign
    func coupons(salonID: Salon.ID) async throws -> [Coupon]
    func upsertCoupon(_ coupon: Coupon) async throws -> Coupon
    /// Validates a coupon code for a salon, throwing `APIError.notFound` when
    /// invalid, expired, or exhausted.
    func validateCoupon(code: String, salonID: Salon.ID) async throws -> Coupon
}

public protocol AnalyticsRepository: Sendable {
    func dashboard(salonID: Salon.ID, periodStart: Date, periodEnd: Date) async throws -> DashboardSnapshot
    /// Combined snapshot across all locations of an organization.
    func organizationDashboard(organizationID: Organization.ID, periodStart: Date, periodEnd: Date) async throws -> [DashboardSnapshot]
}

public protocol AuthService: Sendable {
    /// Restores a persisted session, if any.
    func restoreSession() async -> User?
    func signIn(email: String, password: String) async throws -> User
    func signInWithApple(identityToken: Data, fullName: String?) async throws -> User
    func signUp(email: String, password: String, firstName: String, lastName: String) async throws -> User
    func signOut() async
    func deleteAccount() async throws
}
