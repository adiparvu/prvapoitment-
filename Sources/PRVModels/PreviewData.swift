import Foundation

/// Deterministic sample data for SwiftUI previews, demo mode, and tests.
/// IDs are stable string literals so cross-references keep working.
public enum PreviewData {
    // MARK: Users

    public static let client = User(
        id: User.ID("00000000-0000-0000-0000-000000000001"),
        role: .premiumClient,
        firstName: "Sofia",
        lastName: "Laurent",
        email: "sofia@example.com",
        phone: "+32 470 12 34 56"
    )

    public static let owner = User(
        id: User.ID("00000000-0000-0000-0000-000000000002"),
        role: .salonOwner,
        firstName: "Emma",
        lastName: "Verhoeven",
        email: "emma@maisonlumiere.be",
        salonIDs: [salonLumiere.id]
    )

    // MARK: Salons

    public static let salonLumiere = Salon(
        id: Salon.ID("00000000-0000-0000-0001-000000000001"),
        name: "Maison Lumière",
        tagline: "Luxury hair & beauty atelier",
        about: "An award-winning atelier in the heart of Antwerp blending Parisian technique with Belgian precision. Every visit begins with a personal consultation and ends with a look made to last.",
        categories: [.hairSalon, .makeupStudio],
        address: Address(
            street: "Schuttershofstraat 24",
            city: "Antwerp",
            postalCode: "2000",
            country: "BE",
            coordinate: GeoCoordinate(latitude: 51.2178, longitude: 4.4041)
        ),
        phone: "+32 3 123 45 67",
        amenities: [.luxury, .parking, .wheelchairAccess, .refreshments, .wifi],
        languages: ["en", "nl", "fr"],
        openingHours: (2...7).map {
            OpeningHours(weekday: $0, intervals: [.init(openMinutes: 540, closeMinutes: 1140)])
        } + [OpeningHours(weekday: 1, intervals: [])],
        rating: 4.9,
        reviewCount: 482,
        isVerified: true
    )

    public static let salonVelvet = Salon(
        id: Salon.ID("00000000-0000-0000-0001-000000000002"),
        name: "Velvet Nails Studio",
        tagline: "Nail artistry, elevated",
        about: "A boutique nail studio known for intricate nail art and flawless gel work.",
        categories: [.nailStudio, .lashStudio],
        address: Address(
            street: "Rue du Bailli 58",
            city: "Brussels",
            postalCode: "1050",
            country: "BE",
            coordinate: GeoCoordinate(latitude: 50.8265, longitude: 4.3595)
        ),
        amenities: [.premium, .petFriendly, .wifi],
        languages: ["en", "fr"],
        rating: 4.7,
        reviewCount: 231,
        isVerified: true
    )

    public static let salons: [Salon] = [salonLumiere, salonVelvet]

    // MARK: Professionals

    public static let stylistAmelie = Professional(
        id: Professional.ID("00000000-0000-0000-0002-000000000001"),
        salonID: salonLumiere.id,
        displayName: "Amélie Dubois",
        title: "Senior Colorist",
        biography: "Balayage specialist trained in Paris with 12 years behind the chair.",
        yearsOfExperience: 12,
        specialties: ["Balayage", "Color Correction", "Bridal"],
        languages: ["en", "fr"],
        rating: 4.95,
        reviewCount: 312,
        averageResponseMinutes: 18,
        serviceIDs: [serviceBalayage.id, serviceCutBlowDry.id]
    )

    public static let artistNoor = Professional(
        id: Professional.ID("00000000-0000-0000-0002-000000000002"),
        salonID: salonVelvet.id,
        displayName: "Noor El Amrani",
        title: "Nail Artist",
        biography: "Editorial nail artist featured in Vogue Belgium.",
        yearsOfExperience: 7,
        specialties: ["Nail Art", "Gel Extensions"],
        languages: ["en", "fr", "ar"],
        rating: 4.8,
        reviewCount: 148,
        averageResponseMinutes: 25,
        serviceIDs: [serviceGelManicure.id]
    )

    public static let professionals: [Professional] = [stylistAmelie, artistNoor]

    // MARK: Services

    public static let serviceBalayage = SalonService(
        id: SalonService.ID("00000000-0000-0000-0003-000000000001"),
        salonID: salonLumiere.id,
        name: "Balayage & Gloss",
        details: "Hand-painted dimension with a customized gloss finish. Includes consultation, treatment, and styling.",
        category: .hairSalon,
        price: Money(185),
        isStartingPrice: true,
        durationMinutes: 150,
        preparationMinutes: 10,
        cleanupMinutes: 15,
        requiresPrepayment: true,
        addOns: [
            ServiceAddOn(name: "Olaplex Treatment", price: Money(35), extraMinutes: 15),
            ServiceAddOn(name: "Luxury Scalp Massage", price: Money(25), extraMinutes: 15),
        ]
    )

    public static let serviceCutBlowDry = SalonService(
        id: SalonService.ID("00000000-0000-0000-0003-000000000002"),
        salonID: salonLumiere.id,
        name: "Cut & Blow-Dry",
        details: "Precision cut with consultation and signature blow-dry.",
        category: .hairSalon,
        price: Money(75),
        durationMinutes: 60,
        cleanupMinutes: 10
    )

    public static let serviceGelManicure = SalonService(
        id: SalonService.ID("00000000-0000-0000-0003-000000000003"),
        salonID: salonVelvet.id,
        name: "Gel Manicure",
        details: "Long-lasting gel color with cuticle care and hand massage.",
        category: .nailStudio,
        price: Money(55),
        durationMinutes: 75,
        cleanupMinutes: 10
    )

    public static let services: [SalonService] = [serviceBalayage, serviceCutBlowDry, serviceGelManicure]

    // MARK: Appointments

    public static let upcomingAppointment = Appointment(
        id: Appointment.ID("00000000-0000-0000-0004-000000000001"),
        salonID: salonLumiere.id,
        salonName: salonLumiere.name,
        clientID: client.id,
        items: [
            AppointmentItem(
                serviceID: serviceBalayage.id,
                serviceName: serviceBalayage.name,
                professionalID: stylistAmelie.id,
                professionalName: stylistAmelie.displayName,
                start: Date.now.addingTimeInterval(60 * 60 * 24 * 3),
                durationMinutes: 150,
                price: serviceBalayage.price
            ),
        ],
        status: .confirmed
    )

    // MARK: Loyalty

    public static let loyaltyProfile = LoyaltyProfile(
        userID: client.id,
        xp: 6_450,
        spendablePoints: 1_240,
        referralCode: "SOFIA-GLOW",
        currentStreakDays: 4
    )

    // MARK: Reviews

    public static let reviews: [Review] = [
        Review(
            salonID: salonLumiere.id,
            professionalID: stylistAmelie.id,
            authorID: client.id,
            authorName: "Sofia L.",
            rating: 5,
            text: "Amélie is a magician. The balayage looks completely natural and grew out beautifully.",
            verifiedAppointmentID: upcomingAppointment.id,
            likeCount: 24,
            ownerResponse: "Thank you Sofia — see you at your gloss refresh!"
        ),
        Review(
            salonID: salonLumiere.id,
            authorID: User.ID("00000000-0000-0000-0000-000000000009"),
            authorName: "Marie V.",
            rating: 4,
            text: "Beautiful salon, slightly long wait but worth it.",
            likeCount: 7
        ),
    ]

    // MARK: Membership

    public static let goldPlan = MembershipPlan(
        id: MembershipPlan.ID("00000000-0000-0000-0005-000000000001"),
        salonID: salonLumiere.id,
        tier: .gold,
        name: "Lumière Gold",
        details: "Monthly blow-dry, 15% off all color, priority booking, and a birthday ritual.",
        price: Money(89),
        cycle: .monthly,
        benefits: [
            MembershipBenefit(kind: .freeService, title: "1 Signature Blow-Dry / month", value: 1),
            MembershipBenefit(kind: .discountPercent, title: "15% off color services", value: 15),
            MembershipBenefit(kind: .priorityBooking, title: "Priority booking"),
            MembershipBenefit(kind: .birthdayGift, title: "Birthday ritual"),
        ]
    )

    public static let weddingPackage = ServicePackage(
        id: ServicePackage.ID("00000000-0000-0000-0006-000000000001"),
        salonID: salonLumiere.id,
        name: "Bridal Radiance",
        details: "Trial + wedding-day hair and makeup, with a glow facial the week before.",
        theme: .wedding,
        serviceIDs: [serviceBalayage.id, serviceCutBlowDry.id],
        regularPrice: Money(520),
        packagePrice: Money(440),
        validityDays: 180
    )
}
