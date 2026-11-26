// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ApplePIMTools",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "PIMConfig", targets: ["PIMConfig"]),
        .executable(name: "calendar-cli", targets: ["CalendarCLI"]),
        .executable(name: "reminder-cli", targets: ["ReminderCLI"]),
        .executable(name: "contacts-cli", targets: ["ContactsCLI"]),
        .executable(name: "mail-cli", targets: ["MailCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "PIMConfig",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/PIMConfig"
        ),
        .executableTarget(
            name: "CalendarCLI",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                "PIMConfig",
            ],
            path: "Sources/CalendarCLI"
        ),
        // Objective-C bridge to Apple's private ReminderKit, loaded at runtime with dlopen
        // (no link-time dependency on a private framework). Used only by opt-in
        // `reminder-cli --private` writes.
        .target(
            name: "ReminderKitShim",
            path: "Sources/ReminderKitShim",
            publicHeadersPath: "include",
            cSettings: [.unsafeFlags(["-fobjc-arc"])],
            linkerSettings: [.linkedFramework("Foundation")]
        ),
        .executableTarget(
            name: "ReminderCLI",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                "PIMConfig",
                "ReminderKitShim",
            ],
            path: "Sources/ReminderCLI"
        ),
        .executableTarget(
            name: "ContactsCLI",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                "PIMConfig",
            ],
            path: "Sources/ContactsCLI"
        ),
        .executableTarget(
            name: "MailCLI",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                "PIMConfig",
            ],
            path: "Sources/MailCLI"
        ),
        .testTarget(
            name: "PIMConfigTests",
            dependencies: ["PIMConfig"],
            path: "Tests/PIMConfigTests"
        ),
        .testTarget(
            name: "CalendarCLITests",
            dependencies: ["CalendarCLI"],
            path: "Tests/CalendarCLITests"
        ),
        .testTarget(
            name: "ReminderCLITests",
            dependencies: ["ReminderCLI", "ReminderKitShim"],
            path: "Tests/ReminderCLITests"
        ),
        .testTarget(
            name: "ContactsCLITests",
            dependencies: ["ContactsCLI"],
            path: "Tests/ContactsCLITests"
        ),
        .testTarget(
            name: "MailCLITests",
            dependencies: ["MailCLI"],
            path: "Tests/MailCLITests"
        ),
    ]
)
