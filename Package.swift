// swift-tools-version: 6.0
// PRV Beauty — modular platform package.
// The app target (App/) consumes these libraries via project.yml (XcodeGen).

import PackageDescription

let strictConcurrency: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .swiftLanguageMode(.v6),
]

func target(
    _ name: String,
    dependencies: [Target.Dependency] = [],
    hasResources: Bool = false
) -> Target {
    .target(
        name: name,
        dependencies: dependencies,
        path: "Sources/\(name)",
        resources: hasResources ? [.process("Resources")] : [],
        swiftSettings: strictConcurrency
    )
}

func testTarget(_ name: String, dependencies: [Target.Dependency]) -> Target {
    .testTarget(
        name: name,
        dependencies: dependencies,
        path: "Tests/\(name)",
        swiftSettings: strictConcurrency
    )
}

let package = Package(
    name: "PRVBeauty",
    defaultLocalization: "en",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "PRVFoundation", targets: ["PRVFoundation"]),
        .library(name: "PRVModels", targets: ["PRVModels"]),
        .library(name: "PRVDesignSystem", targets: ["PRVDesignSystem"]),
        .library(name: "PRVNetworking", targets: ["PRVNetworking"]),
        .library(name: "PRVPersistence", targets: ["PRVPersistence"]),
        .library(name: "PRVBookingKit", targets: ["PRVBookingKit"]),
        .library(name: "PRVPaymentsKit", targets: ["PRVPaymentsKit"]),
        .library(name: "PRVLoyaltyKit", targets: ["PRVLoyaltyKit"]),
        .library(name: "PRVAuthFeature", targets: ["PRVAuthFeature"]),
        .library(name: "PRVHomeFeature", targets: ["PRVHomeFeature"]),
        .library(name: "PRVDiscoverFeature", targets: ["PRVDiscoverFeature"]),
        .library(name: "PRVSalonProfileFeature", targets: ["PRVSalonProfileFeature"]),
        .library(name: "PRVBookingFeature", targets: ["PRVBookingFeature"]),
        .library(name: "PRVPaymentsFeature", targets: ["PRVPaymentsFeature"]),
        .library(name: "PRVWalletFeature", targets: ["PRVWalletFeature"]),
        .library(name: "PRVMembershipsFeature", targets: ["PRVMembershipsFeature"]),
        .library(name: "PRVChatFeature", targets: ["PRVChatFeature"]),
        .library(name: "PRVNotificationsFeature", targets: ["PRVNotificationsFeature"]),
        .library(name: "PRVDashboardFeature", targets: ["PRVDashboardFeature"]),
        .library(name: "PRVCRMFeature", targets: ["PRVCRMFeature"]),
        .library(name: "PRVOperationsFeature", targets: ["PRVOperationsFeature"]),
    ],
    targets: [
        // ── Core ────────────────────────────────────────────────────────────
        target("PRVFoundation"),
        target("PRVModels", dependencies: ["PRVFoundation"]),
        target("PRVDesignSystem", dependencies: ["PRVFoundation"]),
        target("PRVNetworking", dependencies: ["PRVFoundation", "PRVModels"]),
        target("PRVPersistence", dependencies: ["PRVFoundation", "PRVModels"]),

        // ── Domain kits (no UI) ─────────────────────────────────────────────
        target("PRVBookingKit", dependencies: ["PRVFoundation", "PRVModels"]),
        target("PRVPaymentsKit", dependencies: ["PRVFoundation", "PRVModels"]),
        target("PRVLoyaltyKit", dependencies: ["PRVFoundation", "PRVModels"]),

        // ── Features ────────────────────────────────────────────────────────
        target("PRVAuthFeature", dependencies: [
            "PRVDesignSystem", "PRVModels", "PRVNetworking",
        ]),
        target("PRVHomeFeature", dependencies: [
            "PRVDesignSystem", "PRVModels", "PRVNetworking", "PRVLoyaltyKit",
        ]),
        target("PRVDiscoverFeature", dependencies: [
            "PRVDesignSystem", "PRVModels", "PRVNetworking",
        ]),
        target("PRVSalonProfileFeature", dependencies: [
            "PRVDesignSystem", "PRVModels", "PRVNetworking",
        ]),
        target("PRVBookingFeature", dependencies: [
            "PRVDesignSystem", "PRVModels", "PRVNetworking", "PRVBookingKit", "PRVPaymentsKit",
        ]),
        target("PRVPaymentsFeature", dependencies: [
            "PRVDesignSystem", "PRVModels", "PRVNetworking", "PRVPaymentsKit",
        ]),
        target("PRVWalletFeature", dependencies: [
            "PRVDesignSystem", "PRVModels", "PRVNetworking", "PRVPaymentsKit", "PRVLoyaltyKit",
        ]),
        target("PRVMembershipsFeature", dependencies: [
            "PRVDesignSystem", "PRVModels", "PRVNetworking", "PRVPaymentsKit",
        ]),
        target("PRVChatFeature", dependencies: [
            "PRVDesignSystem", "PRVModels", "PRVNetworking",
        ]),
        target("PRVNotificationsFeature", dependencies: [
            "PRVDesignSystem", "PRVModels", "PRVNetworking",
        ]),
        target("PRVDashboardFeature", dependencies: [
            "PRVDesignSystem", "PRVModels", "PRVNetworking",
        ]),
        target("PRVCRMFeature", dependencies: [
            "PRVDesignSystem", "PRVModels", "PRVNetworking",
        ]),
        target("PRVOperationsFeature", dependencies: [
            "PRVDesignSystem", "PRVModels", "PRVNetworking",
        ]),

        // ── Tests ───────────────────────────────────────────────────────────
        testTarget("PRVModelsTests", dependencies: ["PRVModels"]),
        testTarget("PRVBookingKitTests", dependencies: ["PRVBookingKit"]),
        testTarget("PRVPaymentsKitTests", dependencies: ["PRVPaymentsKit"]),
        testTarget("PRVLoyaltyKitTests", dependencies: ["PRVLoyaltyKit"]),
    ]
)
