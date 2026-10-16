// swift-tools-version: 6.0
import PackageDescription
import Foundation

// Choose targets while evaluating the manifest, before SwiftPM plans compilation.
let environment = ProcessInfo.processInfo.environment
let tier = environment["NOEMA_TEST_TIER"] ?? "extended"
let entityBridgeNative = environment["NOEMA_ENTITY_BRIDGE_NATIVE"] == "1"
let entityBridgePhase = environment["NOEMA_ENTITY_BRIDGE_PHASE"] ?? "4"
if entityBridgeNative {
    precondition(tier == "compile", "native entity bridge acceptance requires compile tier")
    precondition(["4", "5"].contains(entityBridgePhase), "entity bridge phase must be 4 or 5")
}
let domainTests = ["VaultCoreTests", "NativeAuthenticationTests", "ExternalAITests", "NoemaBrandTests"]
let functionalTests = domainTests + ["NoemaEditorTests"]
let requestedTests = (environment["NOEMA_TEST_TARGETS"] ?? "").split(separator: ",").map(String.init)
let specializedTests = [
    ("NOEMA_PERFORMANCE_TESTS", "NoemaPerformanceTests"),
    ("NOEMA_VISUAL_VALIDATION", "NoemaVisualValidationTests"),
    ("NOEMA_FIXTURE_VALIDATION", "NoemaFixtureValidationTests")
].filter { environment[$0.0] == "1" }.map { $0.1 }
let selectedTests: [String]
switch tier {
case "quick": selectedTests = domainTests
case "standard":
    precondition(!requestedTests.isEmpty, "standard requires NOEMA_TEST_TARGETS")
    precondition(requestedTests.allSatisfy { functionalTests.contains($0) }, "unknown functional test target")
    selectedTests = requestedTests
case "extended": selectedTests = functionalTests + specializedTests
case "specialized":
    precondition(!specializedTests.isEmpty, "specialized requires an explicit validation gate")
    selectedTests = specializedTests
case "compile": selectedTests = []
default: preconditionFailure("unknown NOEMA_TEST_TIER: \(tier)")
}
let needsApplication = tier == "compile" || selectedTests.contains { ["NoemaEditorTests", "NoemaVisualValidationTests", "NoemaPerformanceTests"].contains($0) }
let testDependencies: [String: [Target.Dependency]] = [
    "NativeAuthenticationTests": ["NativeAuthentication"],
    "ExternalAITests": ["ExternalAI", "VaultCore", "NativeAuthentication"],
    "VaultCoreTests": ["VaultCore", "NativeAuthentication"],
    "NoemaBrandTests": ["NoemaBrand"],
    "NoemaEditorTests": ["noema", "NativeAuthentication"],
    "NoemaPerformanceTests": ["noema", "VaultCore", "NoemaBrand", "NativeAuthentication"],
    "NoemaVisualValidationTests": ["noema", "VaultCore", "NoemaBrand", "NativeAuthentication"],
    "NoemaFixtureValidationTests": ["VaultCore"]
]

let coreTargets: [Target] = [
    .target(name: "NoemaBrand"),
    .target(name: "NativeAuthentication"),
    .target(name: "VaultCore", dependencies: [
        "NativeAuthentication",
        .product(name: "Markdown", package: "swift-markdown"),
        .product(name: "Yams", package: "Yams")
    ], linkerSettings: [.linkedLibrary("sqlite3")]),
    .target(name: "ExternalAI", dependencies: ["VaultCore", "NativeAuthentication"])
]
let applicationTargets: [Target] = needsApplication
    ? [.executableTarget(name: "noema", dependencies: ["VaultCore", "NoemaBrand", "ExternalAI"], resources: [.copy("MathResources")])] : []
let validationTargets: [Target] = selectedTests.map { name in
    Target.testTarget(name: name, dependencies: testDependencies[name]!)
}
let selectedProducts: [Product] = needsApplication
    ? [.executable(name: "noema", targets: ["noema"])] : []
let nativeBridgeTargets: [Target] = entityBridgeNative ? [
    .executableTarget(name: "NoemaEntityBridgeQA", dependencies: ["noema", "VaultCore", "NoemaBrand"],
        path: "validation/entity-bridge",
        swiftSettings: entityBridgePhase == "5" ? [.define("ENT05_SOURCE_LINKS")] : [],
        // SwiftPM imports executable modules but does not link their objects into
        // another executable. The QA script supplies app objects excluding NoemaApp.
        linkerSettings: environment["NOEMA_ENTITY_BRIDGE_OBJECTS"].map {
            [.unsafeFlags(["-Xlinker", "-filelist", "-Xlinker", $0])]
        } ?? [])
] : []
let nativeBridgeProducts: [Product] = entityBridgeNative ? [.executable(name: "NoemaEntityBridgeQA", targets: ["NoemaEntityBridgeQA"])] : []
let allTargets: [Target] = coreTargets + applicationTargets + validationTargets + nativeBridgeTargets

let package = Package(
    name: "noema",
    platforms: [.macOS("26.0")],
    products: selectedProducts + nativeBridgeProducts,
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.7.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.2")
    ],
    targets: allTargets
)
