import SwiftUI
import PRVDesignSystem
import PRVFoundation
import PRVModels
import PRVNetworking
import PRVPaymentsKit

/// Checkout: the itemized order on glass, a tip selector that recomputes the
/// total as it is tapped, every way to pay (Apple Pay, vaulted cards, gift
/// cards, store credit), an optional deposit control for orders tied to an
/// upcoming visit, and the sealed receipt once the charge lands.
///
/// Card details never reach this screen. Apple Pay returns an encrypted token
/// and saved methods are Stripe vault references; the charge itself is created
/// server-side through `PaymentRepository.pay(orderID:method:amount:)`.
public struct CheckoutView: View {
    @Environment(\.prvDependencies) private var deps
    @Environment(AppRouter.self) private var router
    @Environment(UserSession.self) private var session

    @State private var model: CheckoutModel

    /// Creates checkout for one order. Everything else comes from the
    /// environment; the initializer takes only the identifier by contract.
    public init(order: Order.ID) {
        _model = State(initialValue: CheckoutModel(orderID: order))
    }

    public var body: some View {
        ZStack {
            if let receipt = model.paymentPhase.receipt {
                CheckoutSuccessView(
                    receipt: receipt,
                    salonName: model.salon?.name ?? "the salon",
                    onDone: close
                )
                .transition(.opacity)
            } else {
                checkoutContent
                    .transition(.opacity)
            }
        }
        .background(Color.prv.canvas)
        .navigationTitle(model.paymentPhase.receipt == nil ? "Checkout" : "Receipt")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .task { await model.load(for: session.currentUser, using: deps) }
        .sheet(isPresented: $model.isRedeemingGiftCard) {
            GiftCardRedeemSheet(model: model)
        }
        .overlay {
            if case .processing(let message) = model.paymentPhase {
                CheckoutProcessingOverlay(message: message, amount: model.amountBeforeCredits)
                    .transition(.opacity)
            }
        }
        .prvAnimation(PRVMotion.gentle, value: model.paymentPhase)
        .prvToast($model.toast)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if model.paymentPhase.receipt == nil {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    PRVHaptics.tap()
                    close()
                } label: {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.bold))
                }
                .disabled(model.paymentPhase.isProcessing)
                .accessibilityLabel("Close checkout")
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var checkoutContent: some View {
        switch model.phase {
        case .loading:
            loadingSkeleton
        case .failed(let message):
            failureState(message)
        case .loaded:
            if let order = model.order {
                loadedContent(order)
            } else {
                failureState("This order is no longer available.")
            }
        }
    }

    private func loadedContent(_ order: Order) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PRVSpacing.xl) {
                header(order)

                CheckoutLineItemsCard(
                    order: order,
                    vat: model.vat,
                    tip: model.tipAmount,
                    dueToday: model.amountBeforeCredits,
                    giftCardCredit: model.giftCardCredit,
                    storeCredit: model.storeCreditApplied,
                    chargedNow: model.amountDueOnMethod,
                    remaining: model.remainingAfterPayment
                )

                if model.canPayPartially {
                    CheckoutPartialPaymentControl(model: model)
                }

                CheckoutTipSelector(model: model)

                CheckoutPaymentMethodList(model: model)

                securityNote
            }
            .padding(.horizontal, PRVSpacing.md)
            .padding(.top, PRVSpacing.sm)
            .padding(.bottom, PRVSpacing.xxl)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .prvBottomBar { payBar }
    }

    // MARK: Header

    private func header(_ order: Order) -> some View {
        VStack(alignment: .leading, spacing: PRVSpacing.xxs) {
            HStack(spacing: PRVSpacing.xs) {
                Text(model.salon?.name ?? "Your order")
                    .prvStyle(.title)
                    .lineLimit(2)
                if order.status == .partiallyPaid {
                    PRVBadge("Deposit paid", tint: Color.prv.success)
                }
            }
            Text(order.appointmentID == nil
                 ? "Order \(order.createdAt.formatted(date: .abbreviated, time: .shortened))"
                 : "For your upcoming visit")
                .prvStyle(.subheadline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var securityNote: some View {
        HStack(alignment: .top, spacing: PRVSpacing.xs) {
            Image(systemName: "lock.shield.fill")
                .font(.footnote)
                .foregroundStyle(Color.prv.success)
                .accessibilityHidden(true)
            Text("Payments are processed by Stripe. Your card number is vaulted by Stripe and never touches this app.")
                .prvStyle(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, PRVSpacing.xs)
        .accessibilityElement(children: .combine)
    }

    // MARK: Bottom bar

    private var payBar: some View {
        VStack(spacing: PRVSpacing.sm) {
            if case .failed(let message) = model.paymentPhase {
                failureBanner(message)
            }

            HStack(spacing: PRVSpacing.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Due today").prvStyle(.caption)
                    PRVPriceLabel(model.amountBeforeCredits.formatted, emphasis: .prominent)
                }

                Spacer(minLength: PRVSpacing.xs)

                Button {
                    PRVHaptics.impact()
                    Task { await model.pay(using: deps) }
                } label: {
                    if model.paymentPhase.isProcessing {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Color.prv.textOnAccent)
                    } else {
                        Text(model.payButtonTitle)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
                .buttonStyle(.prvPrimary)
                .frame(maxWidth: 190)
                .disabled(!model.canPay)
                .accessibilityLabel(model.payButtonTitle)
                .accessibilityHint("Charges \(model.amountDueOnMethod.formatted) to \(model.selectedOption?.title ?? "your payment method")")
            }

            if !model.projectedCashback.isZero {
                Label(
                    "\(model.projectedCashback.formatted) cashback to your Beauty Wallet",
                    systemImage: "sparkles"
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.prv.success)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func failureBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: PRVSpacing.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(Color.prv.danger)
                .accessibilityHidden(true)
            Text(message)
                .font(.footnote)
                .foregroundStyle(Color.prv.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: PRVSpacing.xs)
            Button("Dismiss") { model.dismissPaymentFailure() }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.prv.accent)
                .buttonStyle(.plain)
        }
        .padding(PRVSpacing.sm)
        .background(Color.prv.danger.opacity(0.10), in: PRVRadius.shape(PRVRadius.sm))
        .accessibilityElement(children: .combine)
    }

    // MARK: States

    private var loadingSkeleton: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PRVSpacing.lg) {
                PRVSkeleton(width: 200, height: 26)
                PRVSkeleton(width: 140, height: 14)

                PRVGlassCard(radius: PRVRadius.xl, padding: PRVSpacing.lg) {
                    VStack(alignment: .leading, spacing: PRVSpacing.sm) {
                        ForEach(0..<4, id: \.self) { _ in
                            PRVSkeleton(height: 16)
                        }
                        PRVSkeleton(width: 160, height: 22)
                    }
                }

                PRVSkeleton(width: 170, height: 20)
                VStack(spacing: PRVSpacing.xs) {
                    ForEach(0..<3, id: \.self) { _ in
                        PRVSkeleton(height: 56, radius: PRVRadius.md)
                    }
                }
            }
            .padding(.horizontal, PRVSpacing.md)
            .padding(.top, PRVSpacing.sm)
        }
        .scrollIndicators(.hidden)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading your order")
    }

    private func failureState(_ message: String) -> some View {
        PRVEmptyState(
            systemImage: "creditcard.trianglebadge.exclamationmark",
            title: "We couldn't open checkout",
            message: message,
            actionTitle: "Try Again"
        ) {
            Task { await model.load(for: session.currentUser, using: deps) }
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: Navigation

    /// Leaves checkout by clearing the router's presented sheet.
    private func close() {
        router.presentedSheet = nil
    }
}

// MARK: - Previews

#Preview("Checkout — Light") {
    CheckoutPreviewHost(order: PaymentsPreview.openOrder)
        .environment(UserSession.previewClient)
        .environment(AppRouter())
}

#Preview("Checkout — Dark") {
    CheckoutPreviewHost(order: PaymentsPreview.openOrder)
        .environment(UserSession.previewClient)
        .environment(AppRouter())
        .preferredColorScheme(.dark)
}
