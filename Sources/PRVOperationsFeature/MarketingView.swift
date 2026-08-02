import SwiftUI
import PRVDesignSystem
import PRVFoundation
import PRVModels
import PRVNetworking

/// The Marketing desk: what the salon is sending, what it earned, and what it
/// should probably send next.
///
/// **Campaigns** shows delivery and revenue for every campaign, a composer with
/// a live Lock Screen preview, and three locally computed suggestions drawn from
/// the salon's own analytics — a quiet-day promotion, a win-back when retention
/// slips, and the birthday automation — each of which prefills the composer.
///
/// **Coupons** creates and manages discount codes, with redemption progress and
/// a switch to pause one without losing its history.
///
/// Presented on its own, or embedded in ``TeamView``'s operations hub.
public struct MarketingView: View {
    @Environment(\.prvDependencies) private var deps
    @Environment(UserSession.self) private var session

    @State private var model = MarketingModel()

    /// `true` when hosted inside ``TeamView``, which owns the navigation title.
    private let isEmbedded: Bool

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: PRVSpacing.sm)]

    /// Creates the marketing desk. All dependencies come from the environment;
    /// the initializer stays empty by contract.
    public init() {
        self.isEmbedded = false
    }

    /// Creates the desk for embedding inside the operations hub.
    init(isEmbedded: Bool) {
        self.isEmbedded = isEmbedded
    }

    public var body: some View {
        @Bindable var model = model

        ScrollView {
            VStack(alignment: .leading, spacing: PRVSpacing.xl) {
                PRVSegmentedGlassControl(
                    selection: $model.tab,
                    options: MarketingTab.allCases,
                    title: \.title
                )
                .accessibilityLabel("Marketing view")

                switch model.phase {
                case .loading:
                    OperationsSkeleton(rows: 3, label: "Loading your campaigns")
                case .failed(let message):
                    failureState(message)
                case .loaded:
                    switch model.tab {
                    case .campaigns: campaignsTab
                    case .coupons: couponsTab
                    }
                }
            }
            .padding(.horizontal, PRVSpacing.lg)
            .padding(.top, isEmbedded ? 0 : PRVSpacing.md)
            .padding(.bottom, PRVSpacing.xxl)
        }
        .scrollIndicators(.hidden)
        .background(Color.prv.canvas)
        .operationsNavigationTitle("Marketing", isEmbedded: isEmbedded)
        .refreshable { await load() }
        .task(id: salonID.description) { await load() }
        .prvToast($model.toast)
        .prvAnimation(PRVMotion.gentle, value: model.phase)
        .prvAnimation(PRVMotion.morph, value: model.tab)
        .sheet(item: $model.campaignDraft) { draft in
            CampaignComposerSheet(
                draft: draft,
                salonName: model.salon?.name ?? "Your salon",
                coupons: model.coupons,
                isSaving: model.isSavingCampaign,
                save: { edited in
                    await model.saveCampaign(edited, salonID: salonID, using: deps)
                }
            )
        }
        .sheet(item: $model.couponDraft) { draft in
            CouponEditorSheet(
                draft: draft,
                salonName: model.salon?.name ?? "PRV",
                currency: model.currency,
                isSaving: model.isSavingCoupon,
                save: { edited in
                    await model.saveCoupon(edited, salonID: salonID, using: deps)
                }
            )
        }
    }

    // MARK: - Campaigns

    @ViewBuilder
    private var campaignsTab: some View {
        performanceTiles

        MarketingSuggestionsCard(
            suggestions: model.suggestions,
            errorMessage: model.insightsError,
            canCreate: canManage,
            create: { model.compose(from: $0) },
            retry: { reload() }
        )

        if canManage {
            Button {
                model.composeCampaign()
            } label: {
                Label("New Campaign", systemImage: "plus.circle.fill")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.prvPrimary)
            .accessibilityLabel("Compose a new campaign")
        } else {
            OperationsLockedNotice(
                title: "Campaigns are restricted",
                message: "Only team members with marketing permission can create or edit campaigns."
            )
        }

        if model.campaigns.isEmpty {
            PRVEmptyState(
                systemImage: "megaphone",
                title: "No campaigns yet",
                message: "Send your first push, email, or SMS and its delivery and revenue land here.",
                actionTitle: canManage ? "Compose One" : nil,
                action: composeAction
            )
        } else {
            OperationsBlock(
                "All Campaigns",
                subtitle: "\(model.campaigns.count) in this salon"
            ) {
                VStack(spacing: PRVSpacing.md) {
                    ForEach(model.sortedCampaigns) { campaign in
                        CampaignCard(
                            campaign: campaign,
                            coupon: model.coupon(campaign.couponID),
                            currency: model.currency,
                            canEdit: canManage,
                            edit: { model.edit(campaign) }
                        )
                    }
                }
            }
        }
    }

    private var performanceTiles: some View {
        LazyVGrid(columns: columns, spacing: PRVSpacing.sm) {
            PRVStatTile(label: "Messages sent", value: OperationsFormat.integer(model.totalSent))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(OperationsFormat.integer(model.totalSent)) messages sent")

            PRVStatTile(
                label: "Open rate",
                value: model.totalSent > 0 ? OperationsFormat.percent(model.openRate) : "—"
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                model.totalSent > 0
                    ? "Open rate \(OperationsFormat.percent(model.openRate))"
                    : "No messages sent yet"
            )

            PRVStatTile(label: "Bookings", value: OperationsFormat.integer(model.totalBookings))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(OperationsFormat.integer(model.totalBookings)) bookings attributed")

            PRVStatTile(
                label: "Attributed revenue",
                value: OperationsFormat.compactCurrency(model.attributedRevenue)
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Attributed revenue \(model.attributedRevenue.formatted)")
        }
    }

    // MARK: - Coupons

    @ViewBuilder
    private var couponsTab: some View {
        if canManage {
            Button {
                model.createCoupon()
            } label: {
                Label("New Coupon", systemImage: "ticket.fill")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.prvPrimary)
            .accessibilityLabel("Create a new coupon")
        } else {
            OperationsLockedNotice(
                title: "Coupons are restricted",
                message: "Only team members with marketing permission can create or change discount codes."
            )
        }

        if let couponsError = model.couponsError {
            OperationsErrorCard(message: couponsError) { reload() }
        } else if model.coupons.isEmpty {
            PRVEmptyState(
                systemImage: "ticket",
                title: "No coupons yet",
                message: "Create a discount code to attach to a campaign or hand out at the desk.",
                actionTitle: canManage ? "Create One" : nil,
                action: createCouponAction
            )
        } else {
            OperationsBlock(
                "Discount Codes",
                subtitle: "\(model.coupons.count(where: \.isActive)) active of \(model.coupons.count)"
            ) {
                VStack(spacing: PRVSpacing.md) {
                    ForEach(model.sortedCoupons) { coupon in
                        CouponRow(
                            coupon: coupon,
                            canManage: canManage,
                            isToggling: model.isToggling(coupon),
                            setActive: { isActive in
                                Task { await model.setActive(isActive, for: coupon, using: deps) }
                            },
                            edit: { model.edit(coupon) }
                        )
                        if coupon.id != model.sortedCoupons.last?.id {
                            Divider().overlay(Color.prv.separator.opacity(0.5))
                        }
                    }
                }
                .prvGlassCard()
            }
        }
    }

    // MARK: - States

    private func failureState(_ message: String) -> some View {
        PRVEmptyState(
            systemImage: "megaphone.fill",
            title: "Marketing unavailable",
            message: message,
            actionTitle: "Try Again"
        ) {
            reload()
        }
        .padding(.top, PRVSpacing.xxl)
    }

    // MARK: - Actions

    /// The salon in scope, falling back to the flagship fixture so previews and
    /// demo mode always have campaigns to work with.
    private var salonID: Salon.ID {
        session.activeSalonID ?? PreviewData.salonLumiere.id
    }

    private var canManage: Bool { session.can(.manageMarketing) }

    /// Empty-state call to action, offered only to people who may compose.
    private var composeAction: (() -> Void)? {
        guard canManage else { return nil }
        return { model.composeCampaign() }
    }

    /// Empty-state call to action for the coupons tab.
    private var createCouponAction: (() -> Void)? {
        guard canManage else { return nil }
        return { model.createCoupon() }
    }

    private func load() async {
        await model.load(salonID: salonID, using: deps)
    }

    private func reload() {
        PRVHaptics.tap()
        Task { await load() }
    }
}

// MARK: - Previews

#Preview("Marketing — Owner") {
    NavigationStack {
        MarketingView()
    }
    .environment(UserSession.previewOwner)
    .environment(AppRouter(selectedTab: .operations))
}

#Preview("Marketing — Dark") {
    NavigationStack {
        MarketingView()
    }
    .environment(UserSession.previewOwner)
    .environment(AppRouter(selectedTab: .operations))
    .preferredColorScheme(.dark)
}

#Preview("Marketing — Read only") {
    NavigationStack {
        MarketingView()
    }
    .environment(UserSession.previewSalonEmployee)
    .environment(AppRouter(selectedTab: .operations))
}
