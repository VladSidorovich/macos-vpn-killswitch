// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "macos-vpn-killswitch",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "KillSwitchCore", targets: ["KillSwitchCore"]),
        .library(name: "KillSwitchClient", targets: ["KillSwitchClient"]),
        .executable(name: "KillSwitchBar", targets: ["KillSwitchBar"]),
        .executable(name: "ksctl", targets: ["ksctl"]),
        .executable(name: "killswitchd", targets: ["killswitchd"]),
    ],
    targets: [
        .target(name: "KillSwitchCore"),
        .target(name: "KillSwitchClient", dependencies: ["KillSwitchCore"]),
        .target(name: "KillSwitchDaemon", dependencies: ["KillSwitchCore"],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "ksctl", dependencies: ["KillSwitchCore", "KillSwitchClient"],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "KillSwitchBar", dependencies: ["KillSwitchCore", "KillSwitchClient"],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "killswitchd", dependencies: ["KillSwitchCore", "KillSwitchDaemon"],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        // Command Line Tools ship no XCTest/Testing modules, so tests are a plain executable.
        .executableTarget(name: "ksselftest", dependencies: ["KillSwitchCore", "KillSwitchClient", "KillSwitchDaemon"],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
