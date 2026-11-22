// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Referee",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Referee", targets: ["Referee"]),
        .executable(name: "referee-cli", targets: ["referee-cli"]),
    ],
    targets: [
        .target(name: "RefereeCore"),
        .target(name: "TestSupport", dependencies: ["RefereeCore"]),
        .target(name: "PaperText", dependencies: ["RefereeCore"]),
        .target(name: "PDFBridge", dependencies: ["RefereeCore"]),
        .target(name: "CitationKit", dependencies: ["RefereeCore"]),
        .target(name: "LLMKit", dependencies: ["RefereeCore"]),
        .target(name: "CLIProviders", dependencies: ["RefereeCore"]),
        .target(name: "ReviewEngine", dependencies: ["RefereeCore"]),
        .target(name: "ScholarKit", dependencies: ["RefereeCore"]),
        .target(name: "Persistence", dependencies: ["RefereeCore"]),
        .target(name: "Composition", dependencies: ["RefereeCore", "TestSupport", "PaperText", "PDFBridge", "CitationKit", "LLMKit", "CLIProviders", "ReviewEngine", "ScholarKit", "Persistence"]),
        .target(name: "AppCore", dependencies: ["RefereeCore"]),
        .target(name: "RefereeUI", dependencies: ["RefereeCore", "AppCore", "PDFBridge", "TestSupport"]),
        .executableTarget(name: "Referee", dependencies: ["RefereeUI", "Composition"]),
        .executableTarget(name: "referee-cli", dependencies: ["RefereeCore", "Composition", "PDFBridge", "PaperText"]),

        .testTarget(name: "RefereeCoreTests", dependencies: ["RefereeCore", "TestSupport"]),
        .testTarget(name: "PaperTextTests", dependencies: ["PaperText", "TestSupport"]),
        .testTarget(name: "PDFBridgeTests", dependencies: ["PDFBridge", "TestSupport"]),
        .testTarget(name: "CitationKitTests", dependencies: ["CitationKit", "TestSupport"]),
        .testTarget(name: "LLMKitTests", dependencies: ["LLMKit", "TestSupport"]),
        .testTarget(name: "CLIProvidersTests", dependencies: ["CLIProviders", "TestSupport"]),
        .testTarget(name: "ReviewEngineTests", dependencies: ["ReviewEngine", "TestSupport"]),
        .testTarget(name: "ScholarKitTests", dependencies: ["ScholarKit", "TestSupport"]),
        .testTarget(name: "PersistenceTests", dependencies: ["Persistence", "TestSupport"]),
        .testTarget(name: "AppCoreTests", dependencies: ["AppCore", "TestSupport"]),
        .testTarget(name: "RefereeUITests", dependencies: ["RefereeUI", "TestSupport"]),
        .testTarget(name: "IntegrationTests", dependencies: ["Composition", "AppCore", "TestSupport"]),
    ],
    swiftLanguageModes: [.v5]
)
