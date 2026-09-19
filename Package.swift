// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Offload",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Offload", targets: ["Offload"]),
    ],
    targets: [
        // Вся логика без интерфейса: правила безопасности, перенос, бэкап, Docker.
        .target(name: "OffloadCore"),
        .executableTarget(name: "Offload", dependencies: ["OffloadCore"]),
        // XCTest и swift-testing есть только в Xcode, поэтому проверки — отдельная программа:
        // swift run OffloadChecks
        .executableTarget(name: "OffloadChecks", dependencies: ["OffloadCore"]),
    ],
    swiftLanguageModes: [.v5]
)
