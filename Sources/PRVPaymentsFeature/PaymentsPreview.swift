import Foundation
import SwiftUI
import PRVDesignSystem
import PRVModels
import PRVNetworking
import PRVPaymentsKit

/// Deterministic fixtures for this module's previews.
///
/// Orders are not part of `PreviewData` (they are created by the booking
/// flow at runtime), so the payments previews build their own from the shared
/// salon, client, and service fixtures and seed them into a private in-memory
/// backend.
enum PaymentsPreview {
    /// Builds an exact amount from its decimal string — never a float literal.
    static func money(_ text: String) -> Money {
        Money(Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) ?? 0)
    }

    /// The priced order behind every payments preview: a balayage with an
    /// Olaplex add-on, prepaid in full at Maison Lumière's 10% incentive.
    static var pricedOrder: PricedOrder {
        PricingEngine().price(
            PricingRequest(
                items: [
                    PricingItem(
                        service: PreviewData.serviceBalayage,
                        addOns: [PreviewData.serviceBalayage.addOns[0]]
                    ),
                ],
                salonID: PreviewData.salonLumiere.id,
                prepayment: .full,
                prepaymentPolicy: PreviewData.salonLumiere.prepaymentPolicy,
                vatPercent: 21,
                currency: .eur
            )
        )
    }

    /// An order awaiting payment, tied to an upcoming visit so the deposit
    /// control appears.
    static var openOrder: Order {
        pricedOrder.makeOrder(
            salonID: PreviewData.salonLumiere.id,
            clientID: PreviewData.client.id,
            appointmentID: PreviewData.upcomingAppointment.id,
            status: .awaitingPayment
        )
    }

    /// The same order once it has been settled.
    static var paidOrder: Order {
        var order = openOrder
        order.status = .paid
        order.amountPaid = order.total
        order.paidAt = .now
        return order
    }
}

/// Hosts a checkout preview: seeds the order into a private in-memory backend
/// first, so `payments.order(id:)` resolves exactly as it does in the app.
struct CheckoutPreviewHost: View {
    /// The order to seed and settle.
    let order: Order

    @State private var dependencies = PRVDependencies.inMemory()
    @State private var isSeeded = false

    var body: some View {
        NavigationStack {
            Group {
                if isSeeded {
                    CheckoutView(order: order.id)
                } else {
                    ProgressView().controlSize(.large)
                }
            }
        }
        .task {
            _ = try? await dependencies.payments.createOrder(order)
            isSeeded = true
        }
        .environment(\.prvDependencies, dependencies)
    }
}
