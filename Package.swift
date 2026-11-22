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
        .testTarget(name: "PaperTextTests", dependencies: ["PaperText", "RefereeCore", "TestSupport"]),
        .testTarget(name: "PDFBridgeTests", dependencies: ["PDFBridge", "RefereeCore", "TestSupport"]),
        .testTarget(name: "CitationKitTests", dependencies: ["CitationKit", "RefereeCore", "TestSupport"]),
        .testTarget(name: "LLMKitTests", dependencies: ["LLMKit", "RefereeCore", "TestSupport"]),
        .testTarget(name: "CLIProvidersTests", dependencies: ["CLIProviders", "RefereeCore", "TestSupport"]),
        .testTarget(name: "ReviewEngineTests", dependencies: ["ReviewEngine", "RefereeCore", "TestSupport"], exclude: ["Fixtures"]),
        .testTarget(name: "ScholarKitTests", dependencies: ["ScholarKit", "RefereeCore", "TestSupport"]),
        .testTarget(name: "PersistenceTests", dependencies: ["Persistence", "RefereeCore", "TestSupport"]),
        .testTarget(name: "AppCoreTests", dependencies: ["AppCore", "RefereeCore", "TestSupport"]),
        .testTarget(name: "RefereeUITests", dependencies: ["RefereeUI", "RefereeCore", "AppCore", "PDFBridge", "TestSupport"]),
        .testTarget(name: "IntegrationTests", dependencies: ["Composition", "RefereeCore", "AppCore", "TestSupport", "PaperText", "PDFBridge", "CitationKit", "LLMKit", "CLIProviders", "ReviewEngine", "ScholarKit", "Persistence"]),
    ],
    swiftLanguageModes: [.v5]
)
