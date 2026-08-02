import SwiftUI
import MapKit
import PRVModels
import PRVNetworking
import PRVDesignSystem

/// The About section: story, opening hours, amenities, languages,
/// certificates & awards, the address block with an embedded map and
/// directions hand-off, and the salon's booking policies.
struct AboutSectionView: View {
    let salon: Salon

    var body: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.lg) {
            if !salon.about.isEmpty {
                aboutCard
            }
            openingHoursCard
            if !salon.amenities.isEmpty {
                amenitiesCard
            }
            if !salon.languages.isEmpty {
                languagesCard
            }
            if !salon.certificates.isEmpty || !salon.awards.isEmpty {
                recognitionCard
            }
            locationCard
            policiesCard
        }
    }

    // MARK: - Story

    private var aboutCard: some View {
        PRVGlassCard {
            VStack(alignment: .leading, spacing: PRVSpacing.xs) {
                sectionTitle("About \(salon.name)")
                Text(salon.about)
                    .prvStyle(.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Opening hours

    /// Weekly hours computed from `OpeningHours` minute offsets, Monday
    /// first, with today's row highlighted.
    private var openingHoursCard: some View {
        let today = Calendar.current.component(.weekday, from: .now)

        return PRVGlassCard {
            VStack(alignment: .leading, spacing: PRVSpacing.xs) {
                sectionTitle("Opening Hours")

                if salon.openingHours.isEmpty {
                    Text("Hours not published yet.")
                        .prvStyle(.subheadline)
                } else {
                    ForEach(ProfileFormatting.orderedWeekdays, id: \.self) { weekday in
                        openingHoursRow(weekday: weekday, isToday: weekday == today)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func openingHoursRow(weekday: Int, isToday: Bool) -> some View {
        let hours = salon.openingHours.first { $0.weekday == weekday }
        let value = hoursText(for: hours)

        HStack(alignment: .firstTextBaseline) {
            Text(ProfileFormatting.weekdayName(weekday))
                .font(.subheadline.weight(isToday ? .semibold : .regular))
                .foregroundStyle(isToday ? Color.prv.accent : Color.prv.textPrimary)

            Spacer(minLength: PRVSpacing.md)

            Text(value)
                .font(.subheadline.weight(isToday ? .semibold : .regular))
                .monospacedDigit()
                .foregroundStyle(
                    hours?.isClosed ?? true
                        ? Color.prv.textSecondary
                        : (isToday ? Color.prv.accent : Color.prv.textPrimary)
                )
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(ProfileFormatting.weekdayName(weekday))\(isToday ? ", today" : ""): \(value)")
    }

    private func hoursText(for hours: OpeningHours?) -> String {
        guard let hours, !hours.isClosed else { return "Closed" }
        return hours.intervals
            .map { "\(ProfileFormatting.timeOfDay($0.openMinutes)) – \(ProfileFormatting.timeOfDay($0.closeMinutes))" }
            .joined(separator: ", ")
    }

    // MARK: - Amenities & languages

    private var amenitiesCard: some View {
        PRVGlassCard {
            VStack(alignment: .leading, spacing: PRVSpacing.sm) {
                sectionTitle("Amenities")
                PRVFlowLayout(spacing: PRVSpacing.xs) {
                    ForEach(salon.amenities, id: \.self) { amenity in
                        PRVTag(
                            amenity.displayName,
                            systemImage: amenity.symbolName,
                            tint: amenity == .luxury || amenity == .premium
                                ? Color.prv.gold
                                : Color.prv.textSecondary
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var languagesCard: some View {
        PRVGlassCard {
            VStack(alignment: .leading, spacing: PRVSpacing.sm) {
                sectionTitle("Languages Spoken")
                PRVFlowLayout(spacing: PRVSpacing.xs) {
                    ForEach(salon.languages, id: \.self) { code in
                        PRVTag(ProfileFormatting.languageName(code), systemImage: "globe")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Certificates & awards

    private var recognitionCard: some View {
        PRVGlassCard {
            VStack(alignment: .leading, spacing: PRVSpacing.xs) {
                sectionTitle("Certificates & Awards")

                ForEach(salon.certificates, id: \.self) { certificate in
                    recognitionRow(certificate, systemImage: "rosette")
                }
                ForEach(salon.awards, id: \.self) { award in
                    recognitionRow(award, systemImage: "trophy.fill", tint: Color.prv.gold)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func recognitionRow(
        _ title: String,
        systemImage: String,
        tint: Color = Color.prv.accent
    ) -> some View {
        HStack(spacing: PRVSpacing.sm) {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(tint)
                .frame(width: 24)
                .accessibilityHidden(true)
            Text(title)
                .prvStyle(.body)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Location

    private var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: salon.address.coordinate.latitude,
            longitude: salon.address.coordinate.longitude
        )
    }

    private var locationCard: some View {
        PRVGlassCard {
            VStack(alignment: .leading, spacing: PRVSpacing.sm) {
                sectionTitle("Find Us")

                Map(
                    initialPosition: .region(
                        MKCoordinateRegion(
                            center: coordinate,
                            span: MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008)
                        )
                    ),
                    interactionModes: []
                ) {
                    Marker(salon.name, coordinate: coordinate)
                        .tint(Color.prv.accent)
                }
                .frame(height: 160)
                .clipShape(PRVRadius.shape(PRVRadius.md))
                .accessibilityLabel("Map showing \(salon.name) at \(salon.address.oneLine)")

                VStack(alignment: .leading, spacing: 2) {
                    Text(salon.address.street)
                        .prvStyle(.body)
                    Text("\(salon.address.postalCode) \(salon.address.city), \(salon.address.country)")
                        .prvStyle(.subheadline)
                }

                Button {
                    PRVHaptics.impact()
                    openDirections()
                } label: {
                    Label("Get Directions", systemImage: "arrow.triangle.turn.up.right.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.prvGlass)
                .accessibilityHint("Opens Apple Maps with directions to the salon")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Hands the destination to Apple Maps in directions mode.
    private func openDirections() {
        let placemark = MKPlacemark(coordinate: coordinate)
        let item = MKMapItem(placemark: placemark)
        item.name = salon.name
        item.openInMaps(launchOptions: [
            MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDefault,
        ])
    }

    // MARK: - Policies

    private var policiesCard: some View {
        let policies = salon.policies

        return PRVGlassCard {
            VStack(alignment: .leading, spacing: PRVSpacing.sm) {
                sectionTitle("Booking Policies")

                policyRow(
                    systemImage: "calendar.badge.checkmark",
                    tint: Color.prv.success,
                    title: "Free cancellation",
                    value: "Up to \(policies.freeCancellationHours) h before your visit"
                )
                policyRow(
                    systemImage: "clock.badge.exclamationmark",
                    tint: Color.prv.warning,
                    title: "Late cancellation",
                    value: "\(policies.lateCancellationFeePercent)% of the booked services"
                )
                policyRow(
                    systemImage: "person.fill.xmark",
                    tint: Color.prv.danger,
                    title: "No-show fee",
                    value: "\(policies.noShowFeePercent)% of the booked services"
                )
                policyRow(
                    systemImage: "hourglass",
                    tint: Color.prv.accent,
                    title: "Grace period",
                    value: "\(policies.lateGraceMinutes) min before marked as no-show"
                )
                policyRow(
                    systemImage: "figure.and.child.holdinghands",
                    tint: Color.prv.accent,
                    title: "Children",
                    value: policies.childrenAllowed ? "Welcome" : "Not permitted"
                )

                if let notes = policies.notes, !notes.isEmpty {
                    Divider()
                    Text(notes)
                        .prvStyle(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func policyRow(
        systemImage: String,
        tint: Color,
        title: String,
        value: String
    ) -> some View {
        HStack(alignment: .top, spacing: PRVSpacing.sm) {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(tint)
                .frame(width: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.prv.textPrimary)
                Text(value)
                    .prvStyle(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Shared

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .prvStyle(.headline)
            .accessibilityAddTraits(.isHeader)
    }
}

#Preview("About Section") {
    ScrollView {
        AboutSectionView(
            salon: {
                var salon = PreviewData.salonLumiere
                salon.certificates = ["L'Oréal Professionnel Color Degree", "Olaplex Certified Atelier"]
                salon.awards = ["Best Luxury Salon Antwerp 2025"]
                salon.policies.notes = "Please arrive 5 minutes early so we can start with a relaxed consultation."
                return salon
            }()
        )
        .padding(PRVSpacing.md)
    }
    .background(Color.prv.canvas)
    .environment(UserSession.previewClient)
    .environment(AppRouter())
}
