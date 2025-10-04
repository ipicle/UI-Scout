import Foundation
import ArgumentParser
import Logging
import UIScoutCore

@main
struct UIScoutTestflow: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uisct-testflow",
        abstract: "Run a discovery testflow for chat UIs (Raycast, etc.)"
    )

    @Option(name: .shortAndLong, help: "Application bundle identifier (e.g., com.raycast.macos)")
    var app: String

    @Flag(name: .long, help: "Output results in JSON format")
    var json: Bool = false

    @Option(name: .long, help: "Minimum confidence threshold (0.0-1.0)")
    var minConfidence: Double = 0.6

    @Flag(name: .customLong("no-ocr"), help: "Disable OCR checks (stabilizes runs if Screen Recording is unavailable)")
    var noOCR: Bool = false

    func run() async throws {
        // Lightweight logging bootstrap that avoids non-Sendable closure capture warnings
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardOutput(label: label)
            handler.logLevel = .info
            return handler
        }

        let bootstrap = UIScoutBootstrap()
        let permissionStatus = try await bootstrap.initialize()
        if !permissionStatus.canOperate {
            let msg = "Cannot operate: missing permissions: \(permissionStatus.needsPrompt.joined(separator: ", "))"
            if json { printJSONAny(["error": msg, "needs": permissionStatus.needsPrompt]) } else { print("❌ \(msg)") }
            throw ExitCode(1)
        }

        let axClient = AXClient()
        let elementFinder = ElementFinder(axClient: axClient)
        let snapshotManager = SnapshotManager(axClient: axClient)
        let scorer = ConfidenceScorer()
    let ocrManager = OCRManager(disabled: noOCR)
        let store = try SignatureStore()
        let rateLimiter = RateLimiter()

        let stateMachineFactory = StateMachineFactory(
            scorer: scorer,
            snapshotManager: snapshotManager,
            axClient: axClient,
            ocrManager: ocrManager
        )

        let orchestrator = UIScoutOrchestrator(
            axClient: axClient,
            elementFinder: elementFinder,
            snapshotManager: snapshotManager,
            scorer: scorer,
            ocrManager: ocrManager,
            stateMachineFactory: stateMachineFactory,
            store: store,
            rateLimiter: rateLimiter
        )

        let policy = Policy(allowPeek: true, minConfidence: minConfidence)

    // Run discovery in parallel
    if !json { print("[testflow] starting discovery (noOCR=\(noOCR))") }
    if !json { print("[testflow] finding input...") }
    async let input: ElementResult = orchestrator.findElement(appBundleId: app, elementType: ElementSignature.ElementType.input, policy: policy)
    if !json { print("[testflow] finding send...") }
    async let send: ElementResult = orchestrator.findElement(appBundleId: app, elementType: ElementSignature.ElementType.send, policy: policy)
    if !json { print("[testflow] finding reply...") }
    async let reply: ElementResult = orchestrator.findElement(appBundleId: app, elementType: ElementSignature.ElementType.reply, policy: policy)
    if !json { print("[testflow] finding session...") }
    async let session: ElementResult = orchestrator.findElement(appBundleId: app, elementType: ElementSignature.ElementType.session, policy: policy)
        if !json { print("[testflow] awaiting results...") }
        let (inputR, sendR, replyR, sessionR) = await (input, send, reply, session)

        if json {
            let out: [String: Any] = [
                "app": app,
                "results": [
                    "input": enc(inputR),
                    "send": enc(sendR),
                    "reply": enc(replyR),
                    "session": enc(sessionR)
                ]
            ]
            printJSONAny(out)
        } else {
            print("🔎 Testflow for \(app)")
            dumpResult("input", inputR)
            dumpResult("send", sendR)
            dumpResult("reply", replyR)
            dumpResult("session", sessionR)
        }

        // Exit code mirrors overall success
    let allOK = [inputR, sendR, replyR, sessionR].allSatisfy { (r: ElementResult) in r.confidence >= minConfidence }
        if !allOK { throw ExitCode(2) }
    }

    private func dumpResult(_ name: String, _ r: ElementResult) {
        print("\n• \(name): \(String(format: "%.2f", r.confidence))")
        print("  role=\(r.elementSignature.role)")
        print("  method=\(r.evidence.method.rawValue) heuristic=\(String(format: "%.2f", r.evidence.heuristicScore)) diff=\(String(format: "%.2f", r.evidence.diffScore)) ocr=\(r.evidence.ocrChange)")
    }

    private func enc<T: Encodable>(_ v: T) -> Any {
        do { return try JSONSerialization.jsonObject(with: JSONEncoder().encode(v)) } catch { return ["error": "encode_failed"] }
    }
}

// Helper for printing heterogenous output
private func printJSONAny(_ value: Any) {
    guard JSONSerialization.isValidJSONObject(value) else {
        print("Error: value is not a valid JSON object")
        return
    }
    do {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        if let string = String(data: data, encoding: .utf8) { print(string) }
    } catch { print("Error serializing JSON: \(error)") }
}