import Foundation
import Testing
import RefereeCore
import AppCore
import TestSupport
import Composition

/// The real graph of `LiveDependencies.make` on a temporary data folder of its own: no Keychain, and the mock
/// provider registered (`REFEREE_ENABLE_MOCK=1`). Nothing of the user's is read or written (plan.md section 3.5).
struct LiveGraph {
    let home: URL
    let dependencies: AppDependencies

    static func make(_ extra: [String: String] = [:], mock: Bool = true) async -> LiveGraph {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("referee-gate1-\(UUID().uuidString)", isDirectory: true)
        var environment = ["REFEREE_HOME": home.path, "REFEREE_NO_KEYCHAIN": "1"]
        if mock { environment["REFEREE_ENABLE_MOCK"] = "1" }
        for (key, value) in extra { environment[key] = value }
        return LiveGraph(home: home, dependencies: await LiveDependencies.make(environment: environment))
    }

    /// The default settings with the mock enabled and chosen for every task, saved through the graph's store.
    func mockSettings() async throws -> AppSettings {
        var settings = DefaultSettings.make()
        settings.providers["mock"] = ProviderSettings(enabled: true, model: "mock", inputMode: .auto)
        settings.defaults.review = ProviderRef(providerID: "mock", model: "mock")
        try await dependencies.settings.save(settings)
        return settings
    }

    func sessionFolder(_ sha256: String) -> URL {
        home.appendingPathComponent("sessions", isDirectory: true).appendingPathComponent(sha256, isDirectory: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: home)
    }
}

/// Lets the main actor run until the condition holds, for `seconds` at most. Returns whether it held.
@MainActor @discardableResult
func waitUntil(seconds: Double = 20, _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
    while !condition() {
        if ContinuousClock.now >= deadline { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}

/// The UTF-16 range of `needle` in `haystack`, which must occur exactly once.
func uniqueRange(of needle: String, in haystack: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> TextRange {
    let whole = haystack as NSString
    let found = whole.range(of: needle)
    try #require(found.location != NSNotFound, "\"\(needle)\" is not in the page string", sourceLocation: sourceLocation)
    let after = found.location + found.length
    let again = whole.range(of: needle, options: [], range: NSRange(location: after, length: whole.length - after))
    try #require(again.location == NSNotFound, "\"\(needle)\" occurs more than once", sourceLocation: sourceLocation)
    return TextRange(found)
}

/// The eight fixtures, by name (plan.md section 3.6).
enum Fixture {
    static let all = ["ay_nolinks", "s1_ruler", "ay_round_nolinks", "ay_links", "num_links", "num_twocol_links", "scanned", "ay_long"]
    static func url(_ name: String) -> URL { Fixtures.url("pdf/\(name).pdf") }
}

/// Runs a program to its end without blocking Swift's cooperative threads: the process, its two pipes and the
/// timeout live on threads of their own, and the caller is resumed once all is done. (Reading a pipe or waiting for a
/// process inside a task blocks a cooperative thread; with every test target running in parallel, the pool then has
/// no thread left to resume the waiting tests.)
enum Subprocess {
    struct Output: Sendable {
        var status: Int32
        var stdout: Data
        var stderr: Data
        var timedOut: Bool
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func set(_ value: Data) { lock.withLock { data = value } }
        var value: Data { lock.withLock { data } }
    }

    static func run(_ executable: URL, _ arguments: [String], directory: URL, environment: [String: String],
                    timeout: TimeInterval = 60) async throws -> Output {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Output, Error>) in
            let thread = Thread {
                do {
                    continuation.resume(returning: try runBlocking(executable, arguments, directory: directory, environment: environment,
                                                                   timeout: timeout))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            thread.start()
        }
    }

    private static func runBlocking(_ executable: URL, _ arguments: [String], directory: URL, environment: [String: String],
                                    timeout: TimeInterval) throws -> Output {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory                   // the child's directory; the test process keeps its own
        process.environment = environment
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let errors = Box()
        let errorsRead = DispatchSemaphore(value: 0)
        Thread {
            errors.set(err.fileHandleForReading.readDataToEndOfFile())
            errorsRead.signal()
        }.start()
        let expired = Box()
        let watchdog = DispatchWorkItem {
            if process.isRunning {
                expired.set(Data([1]))
                process.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let output = out.fileHandleForReading.readDataToEndOfFile()
        errorsRead.wait()
        process.waitUntilExit()
        watchdog.cancel()
        return Output(status: process.terminationStatus, stdout: output, stderr: errors.value, timedOut: !expired.value.isEmpty)
    }
}
