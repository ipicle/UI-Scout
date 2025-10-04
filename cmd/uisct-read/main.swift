import Foundation
import ArgumentParser
import Logging
import UIScoutCore
import ApplicationServices
import AppKit

@main
struct UIScoutRead: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uisct-read",
        abstract: "Resolve chat elements and dump input/reply/session text"
    )

    @Option(name: .shortAndLong, help: "Application bundle identifier (e.g., com.raycast.macos)")
    var app: String

    @Flag(name: .long, help: "Output results in JSON format")
    var json: Bool = false

    func run() async throws {
        LoggingSystem.bootstrap { label in
            var h = StreamLogHandler.standardOutput(label: label)
            h.logLevel = .info
            return h
        }

        let bootstrap = UIScoutBootstrap()
        let status = try await bootstrap.initialize()
        guard status.canOperate else {
            throw ValidationError("Missing permissions: \(status.needsPrompt.joined(separator: ", "))")
        }

        let ax = AXClient()
        let finder = ElementFinder(axClient: ax)
        let snap = SnapshotManager(axClient: ax)
        let scorer = ConfidenceScorer()
        let ocr = OCRManager(disabled: true)
        let store = try SignatureStore()
        let rate = RateLimiter()
        let factory = StateMachineFactory(scorer: scorer, snapshotManager: snap, axClient: ax, ocrManager: ocr)
        let orch = UIScoutOrchestrator(axClient: ax, elementFinder: finder, snapshotManager: snap, scorer: scorer, ocrManager: ocr, stateMachineFactory: factory, store: store, rateLimiter: rate)

        let policy = Policy(allowPeek: false, minConfidence: 0.5)

        async let inputR = orch.findElement(appBundleId: app, elementType: .input, policy: policy)
        async let sendR = orch.findElement(appBundleId: app, elementType: .send, policy: policy)
        async let replyR = orch.findElement(appBundleId: app, elementType: .reply, policy: policy)
        async let sessionR = orch.findElement(appBundleId: app, elementType: .session, policy: policy)
        let (i, s, r, se) = await (inputR, sendR, replyR, sessionR)

        // Attempt to locate AX elements by traversing windows using signature hints
        func resolveAX(_ sig: ElementSignature?) -> AXUIElement? {
            guard let sig else { return nil }
            guard let windows = try? ax.getElementsForApp(sig.appBundleId) else { return nil }
            for w in windows {
                if let el = findByPathHint(root: w, hint: sig.pathHint) { return el }
            }
            return nil
        }

        func findByPathHint(root: AXUIElement, hint: [String]) -> AXUIElement? {
            // Fallback: simple DFS that matches role sequence roughly
            var target: AXUIElement? = root
            for step in hint {
                let role = step.split(separator: "[").first.map(String.init) ?? step
                guard let children = try? ax.getAttribute(target!, kAXChildrenAttribute, as: [AXUIElement].self) else { return nil }
                var found: AXUIElement?
                for c in children {
                    if ax.getMinimalAttributes(for: c).role == role { found = c; break }
                }
                target = found
                if target == nil { return nil }
            }
            return target
        }

        let inputEl = resolveAX(i.elementSignature)
        let replyEl = resolveAX(r.elementSignature)
        let sessionEl = resolveAX(se.elementSignature)

        let inputText = inputEl.flatMap { ax.extractText(from: $0, maxLength: 2048) } ?? ""
        var replyText = replyEl.flatMap { ax.extractText(from: $0, maxLength: 10000) } ?? ""
        let sessionItems = sessionEl.map { ax.extractListItems(from: $0, maxItems: 100) } ?? []

        // OCR fallback for reply if AX text is empty
        #if canImport(Vision)
        if replyText.isEmpty {
            if let replySnap = snap.createSnapshot(for: se.elementSignature) {
                if #available(macOS 10.15, *) {
                    let conf = OCRConfirmation()
                    let res = await conf.quickTextCheck(appBundleId: app, region: replySnap.frame)
                    if let lines = res.afterText, !lines.isEmpty {
                        replyText = lines.joined(separator: "\n")
                    }
                }
            }
        }
        #endif

        if json {
            let out: [String: Any] = [
                "app": app,
                "elements": [
                    "input": ["confidence": i.confidence, "text": inputText],
                    "reply": ["confidence": r.confidence, "text": replyText],
                    "session": ["confidence": se.confidence, "items": sessionItems]
                ]
            ]
            printJSONAny(out)
        } else {
            print("App: \(app)")
            print("- input conf=\(i.confidence)\n\(inputText)\n")
            print("- reply conf=\(r.confidence)\n\(replyText.prefix(1000))\n")
            print("- sessions conf=\(se.confidence)\n\(sessionItems.prefix(20).joined(separator: "\n"))\n")
        }
    }
}

private func printJSONAny(_ value: Any) {
    guard JSONSerialization.isValidJSONObject(value) else { print("{\"error\":true,\"message\":\"invalid json\"}"); return }
    let data = try! JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    print(String(data: data, encoding: .utf8)!)
}
