// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "noema",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "noema", targets: ["noema"])],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.7.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.2")
    ],
    targets: [
        .target(name: "NoemaBrand"),
        .target(name: "NativeAuthentication"),
        .target(name: "VaultCore", dependencies: [
            .product(name: "Markdown", package: "swift-markdown"),
            .product(name: "Yams", package: "Yams")
        ], linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "ExternalAI", dependencies: ["VaultCore", "NativeAuthentication"]),
        .executableTarget(name: "noema", dependencies: ["VaultCore", "NoemaBrand", "ExternalAI"]),
        .testTarget(name: "NativeAuthenticationTests", dependencies: ["NativeAuthentication"]),
        .testTarget(name: "ExternalAITests", dependencies: ["ExternalAI", "VaultCore", "NativeAuthentication"]),
        .testTarget(name: "VaultCoreTests", dependencies: ["VaultCore"]),
        .testTarget(name: "NoemaBrandTests", dependencies: ["NoemaBrand"]),
        .testTarget(name: "NoemaEditorTests", dependencies: ["noema"])
    ]
)
