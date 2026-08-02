#!/usr/bin/env bash
# Builds and tests the platform-independent layer — PRVFoundation, PRVModels,
# and the PRVBookingKit / PRVPaymentsKit / PRVLoyaltyKit domain engines — on
# Linux, where no Apple SDK is available.
#
# Those targets are pure Foundation by design (ARCHITECTURE.md §3: kits contain
# zero SwiftUI), so the booking, pricing, and loyalty logic can be verified on a
# cheap Linux runner in seconds instead of waiting for a macOS simulator.
# The UI modules still need Xcode — see the `app` job in .github/workflows/ci.yml.
#
# Usage: Scripts/linux-domain-tests.sh [additional swift test arguments]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HARNESS="${ROOT}/.build-linux"

MODULES=(PRVFoundation PRVModels PRVBookingKit PRVPaymentsKit PRVLoyaltyKit PRVPersistence PRVNetworking)
TEST_MODULES=(PRVModelsTests PRVBookingKitTests PRVPaymentsKitTests PRVLoyaltyKitTests)

# The harness symlinks the real sources, so it can never drift from what ships.
rm -rf "${HARNESS}"
mkdir -p "${HARNESS}/Sources" "${HARNESS}/Tests"
for module in "${MODULES[@]}"; do
    ln -s "${ROOT}/Sources/${module}" "${HARNESS}/Sources/${module}"
done
for module in "${TEST_MODULES[@]}"; do
    ln -s "${ROOT}/Tests/${module}" "${HARNESS}/Tests/${module}"
done

# A manifest without the iOS platform pin or any SwiftUI target.
cat > "${HARNESS}/Package.swift" <<'MANIFEST'
// swift-tools-version: 6.0
import PackageDescription

let settings: [SwiftSetting] = [.swiftLanguageMode(.v6)]

let package = Package(
    name: "PRVDomain",
    targets: [
        .target(name: "PRVFoundation", swiftSettings: settings),
        .target(name: "PRVModels", dependencies: ["PRVFoundation"], swiftSettings: settings),
        .target(name: "PRVBookingKit", dependencies: ["PRVFoundation", "PRVModels"], swiftSettings: settings),
        .target(name: "PRVPaymentsKit", dependencies: ["PRVFoundation", "PRVModels"], swiftSettings: settings),
        .target(name: "PRVLoyaltyKit", dependencies: ["PRVFoundation", "PRVModels"], swiftSettings: settings),
        .target(name: "PRVPersistence", dependencies: ["PRVFoundation", "PRVModels"], swiftSettings: settings),
        // The repository contracts and the in-memory backend behind every
        // preview and the demo build are pure Foundation. Dependencies.swift
        // is excluded: its SwiftUI @Entry environment key needs an Apple SDK.
        .target(
            name: "PRVNetworking",
            dependencies: ["PRVFoundation", "PRVModels"],
            exclude: ["Dependencies.swift"],
            sources: ["APIClient.swift", "Repositories.swift", "InMemoryBackend.swift", "WireKeys.swift"],
            swiftSettings: settings
        ),
        .testTarget(name: "PRVModelsTests", dependencies: ["PRVModels"], swiftSettings: settings),
        .testTarget(name: "PRVBookingKitTests", dependencies: ["PRVBookingKit"], swiftSettings: settings),
        .testTarget(name: "PRVPaymentsKitTests", dependencies: ["PRVPaymentsKit"], swiftSettings: settings),
        .testTarget(name: "PRVLoyaltyKitTests", dependencies: ["PRVLoyaltyKit"], swiftSettings: settings),
    ]
)
MANIFEST

cd "${HARNESS}"
swift test "$@"
