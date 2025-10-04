import Foundation
import ArgumentParser
import UIScoutCore
import Logging
import ApplicationServices
import AppKit

@main
struct UIScoutCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uisct",
        abstract: "UIScout - Intelligent UI element discovery for macOS",
        version: "1.0.0",
        subcommands: [
            FindCommand.self,
            DiscoverChatCommand.self,
            ObserveCommand.self,
            AfterSendDiffCommand.self,
            SnapshotCommand.self,
            LearnCommand.self,
            SendMessageCommand.self,
            CopyChatCommand.self,
            CopyErrorLogsCommand.self,
            StatusCommand.self,
            SetupCommand.self
        ]
    )
    
    @Option(name: .shortAndLong, help: "Log level (trace, debug, info, warning, error)")
    var logLevel: String = "info"
    
    @Flag(name: .long, help: "Output results in JSON format")
    var json: Bool = false
    
    func validate() throws {
        let validLevels = ["trace", "debug", "info", "warning", "error"]
        guard validLevels.contains(logLevel.lowercased()) else {
            throw ValidationError("Invalid log level. Must be one of: \(validLevels.joined(separator: ", "))")
        }
    }
    
    mutating func run() async throws {
        // This will never be called since we have subcommands
    }
}

// MARK: - Menu Helpers

private func pressMenuItem(appBundleId: String, titleContains needle: String) -> (pressed: Bool, title: String?) {
    let ax = AXClient()
    do {
        let running = NSWorkspace.shared.runningApplications
        guard let app = running.first(where: { $0.bundleIdentifier == appBundleId }) else { return (false, nil) }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        // Try the main menu bar first
        if let menuBar: AXUIElement = try ax.getAttribute(appEl, kAXMenuBarAttribute, as: AXUIElement.self) {
            if let item = findMenuItemRecursively(ax: ax, root: menuBar, contains: needle) {
                try? ax.performAction(item, action: kAXPressAction)
                let title = (try? ax.getAttribute(item, kAXTitleAttribute, as: String.self)) ?? needle
                return (true, title)
            }
        }

        // Fallback: press in-window Actions menu (AXMenuButton/AXButton) and then pick menu item
        if let window = firstWindow(ax: ax, appEl: appEl, titleHint: "AI Chat") {
            if pressActionsAndSelect(ax: ax, appEl: appEl, root: window, pickTitleContains: needle) {
                return (true, needle)
            }
        }
    } catch {
        // ignore and fall through
    }
    return (false, nil)
}

private func findMenuItemRecursively(ax: AXClient, root: AXUIElement, contains needle: String) -> AXUIElement? {
    let lowerNeedle = needle.lowercased()
    if let title = try? ax.getAttribute(root, kAXTitleAttribute, as: String.self) {
        if title.lowercased().contains(lowerNeedle),
           let role = try? ax.getAttribute(root, kAXRoleAttribute, as: String.self), role == kAXMenuItemRole {
            return root
        }
    }
    if let children = try? ax.getAttribute(root, kAXChildrenAttribute, as: [AXUIElement].self) {
        for c in children {
            if let found = findMenuItemRecursively(ax: ax, root: c, contains: lowerNeedle) { return found }
        }
    }
    // Recurse through children only; many menu structures are nested via AXChildren
    return nil
}

private func readClipboardString() -> String {
    return NSPasteboard.general.string(forType: .string) ?? ""
}

// Find the first window, prefer one with a title hint
private func firstWindow(ax: AXClient, appEl: AXUIElement, titleHint: String?) -> AXUIElement? {
    if let windows: [AXUIElement] = try? ax.getAttribute(appEl, kAXWindowsAttribute, as: [AXUIElement].self) {
        if let hint = titleHint {
            for w in windows {
                if let t: String = try? ax.getAttribute(w, kAXTitleAttribute, as: String.self), t.contains(hint) { return w }
            }
        }
        return windows.first
    }
    return nil
}

// Press a likely actions menu button in the window, then choose a menu item by title
private func pressActionsAndSelect(ax: AXClient, appEl: AXUIElement, root: AXUIElement, pickTitleContains: String) -> Bool {
    // Candidates: AXMenuButton, or AXButton with title containing Actions/More/…
    let triggers = bfsCollect(ax: ax, root: root, maxDepth: 8) { el in
        let role = (try? ax.getAttribute(el, kAXRoleAttribute, as: String.self)) ?? ""
        let title = (try? ax.getAttribute(el, kAXTitleAttribute, as: String.self))?.lowercased() ?? ""
        if role == kAXMenuButtonRole { return true }
        if role == kAXButtonRole && (title.contains("actions") || title.contains("more") || title == "…" || title == "...") {
            return true
        }
        return false
    }
    for btn in triggers {
        try? ax.performAction(btn, action: kAXPressAction)
        // small delay to allow menu to appear
        usleep(200_000)
        if let item = findAnyMenuItem(ax: ax, appEl: appEl, contains: pickTitleContains) {
            try? ax.performAction(item, action: kAXPressAction)
            return true
        }
    }
    return false
}

// Search any visible AXMenu for a menu item containing the given text
private func findAnyMenuItem(ax: AXClient, appEl: AXUIElement, contains needle: String) -> AXUIElement? {
    let lower = needle.lowercased()
    // Search whole app tree shallowly for AXMenu nodes
    let candidates = bfsCollect(ax: ax, root: appEl, maxDepth: 5) { el in
        let role = (try? ax.getAttribute(el, kAXRoleAttribute, as: String.self)) ?? ""
        return role == kAXMenuRole
    }
    for menu in candidates {
        if let item = bfsFind(ax: ax, root: menu, maxDepth: 4) { el in
            let role = (try? ax.getAttribute(el, kAXRoleAttribute, as: String.self)) ?? ""
            if role != kAXMenuItemRole { return false }
            let t = ((try? ax.getAttribute(el, kAXTitleAttribute, as: String.self)) ?? "").lowercased()
            return t.contains(lower)
        } {
            return item
        }
    }
    // Fallback: many apps show a popover/panel with regular buttons; search for buttons by title
    if let button = bfsFind(ax: ax, root: appEl, maxDepth: 6, predicate: { el in
        let role = (try? ax.getAttribute(el, kAXRoleAttribute, as: String.self)) ?? ""
        if role != kAXButtonRole { return false }
        let t = ((try? ax.getAttribute(el, kAXTitleAttribute, as: String.self)) ?? "").lowercased()
        return t.contains(lower)
    }) {
        return button
    }
    return nil
}

// MARK: - Contextual Actions (near reply)

// Resolve an AX element from UIScout signature.pathHint within the correct window
private func resolveElementBySignature(axClient: AXClient, signature: ElementSignature) -> AXUIElement? {
    guard let windows = try? axClient.getElementsForApp(signature.appBundleId) else { return nil }
    // Try to respect window index from path hint if present
    let windowStep = signature.pathHint.first(where: { $0.hasPrefix("AXWindow[") })
    var targetWindowIndex: Int? = nil
    if let step = windowStep,
       let lb = step.firstIndex(of: "["), let rb = step.firstIndex(of: "]"),
       let idx = Int(step[step.index(after: lb)..<rb]) {
        targetWindowIndex = idx
    }
    for (i, window) in windows.enumerated() {
        if let t = targetWindowIndex, t != i { continue }
        if let el = traverseByPathHint(axClient: axClient, root: window, pathHint: signature.pathHint) { return el }
    }
    return nil
}

private func traverseByPathHint(axClient: AXClient, root: AXUIElement, pathHint: [String]) -> AXUIElement? {
    guard let windowPos = pathHint.firstIndex(where: { $0.hasPrefix("AXWindow[") }) else { return nil }
    var current: AXUIElement = root
    for step in pathHint.dropFirst(windowPos + 1) {
        guard let lb = step.firstIndex(of: "["), let rb = step.firstIndex(of: "]") else { return nil }
        let role = String(step[..<lb])
        guard let idx = Int(step[step.index(after: lb)..<rb]) else { return nil }
        guard let children = try? axClient.getAttribute(current, kAXChildrenAttribute, as: [AXUIElement].self) else { return nil }
        var count = 0
        var nextEl: AXUIElement?
        for child in children {
            let childRole = (try? axClient.getAttribute(child, kAXRoleAttribute, as: String.self)) ?? ""
            if childRole == role {
                if count == idx { nextEl = child; break }
                count += 1
            }
        }
        guard let next = nextEl else { return nil }
        current = next
    }
    return current
}

// From a starting element (e.g., reply), walk up a few parents and search siblings/children
// for an actions menu trigger (AXMenuButton or an AXButton titled Actions/More/…)
private func findActionsTrigger(ax: AXClient, start: AXUIElement, maxUp: Int = 4) -> AXUIElement? {
    var current: AXUIElement? = start
    for _ in 0..<maxUp {
        if let el = current {
            // Search siblings and their immediate children
            if let parent = try? ax.getAttribute(el, kAXParentAttribute, as: AXUIElement.self),
               let siblings = try? ax.getAttribute(parent, kAXChildrenAttribute, as: [AXUIElement].self) {
                for s in siblings {
                    if isActionsButton(ax: ax, el: s) { return s }
                    if let kids = try? ax.getAttribute(s, kAXChildrenAttribute, as: [AXUIElement].self) {
                        for k in kids { if isActionsButton(ax: ax, el: k) { return k } }
                    }
                }
                current = parent
                continue
            }
        }
        break
    }
    // Fallback: BFS around start
    return bfsFind(ax: ax, root: start, maxDepth: 6) { el in isActionsButton(ax: ax, el: el) }
}

private func isActionsButton(ax: AXClient, el: AXUIElement) -> Bool {
    let role = (try? ax.getAttribute(el, kAXRoleAttribute, as: String.self)) ?? ""
    if role == kAXMenuButtonRole { return true }
    if role == kAXButtonRole {
        let title = ((try? ax.getAttribute(el, kAXTitleAttribute, as: String.self)) ?? "").lowercased()
        if title.contains("actions") || title.contains("more") || title == "…" || title == "..." { return true }
    }
    return false
}

// Press the actions trigger and pick an item; returns clipboard contents if successful
private func invokeActionsAndCopy(ax: AXClient, appBundleId: String, reply: AXUIElement, pickTitleContains: String) -> (invoked: Bool, clipboard: String) {
    let appEl = AXUIElementCreateApplication((NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == appBundleId }?.processIdentifier) ?? 0)
    guard let trigger = findActionsTrigger(ax: ax, start: reply) else { return (false, "") }
    try? ax.performAction(trigger, action: kAXPressAction)
    usleep(250_000)
    if let menuItem = findAnyMenuItem(ax: ax, appEl: appEl, contains: pickTitleContains) {
        try? ax.performAction(menuItem, action: kAXPressAction)
        usleep(200_000)
        return (true, readClipboardString())
    }
    return (false, "")
}

// Generic BFS utilities
private func bfsFind(ax: AXClient, root: AXUIElement, maxDepth: Int, predicate: (AXUIElement) -> Bool) -> AXUIElement? {
    var q: [(AXUIElement, Int)] = [(root, 0)]
    while !q.isEmpty {
        let (el, d) = q.removeFirst()
        if predicate(el) { return el }
        if d >= maxDepth { continue }
        if let kids = try? ax.getAttribute(el, kAXChildrenAttribute, as: [AXUIElement].self) {
            for k in kids { q.append((k, d + 1)) }
        }
    }
    return nil
}

private func bfsCollect(ax: AXClient, root: AXUIElement, maxDepth: Int, predicate: (AXUIElement) -> Bool) -> [AXUIElement] {
    var out: [AXUIElement] = []
    var q: [(AXUIElement, Int)] = [(root, 0)]
    while !q.isEmpty {
        let (el, d) = q.removeFirst()
        if predicate(el) { out.append(el) }
        if d >= maxDepth { continue }
        if let kids = try? ax.getAttribute(el, kAXChildrenAttribute, as: [AXUIElement].self) {
            for k in kids { q.append((k, d + 1)) }
        }
    }
    return out
}

// MARK: - Copy Chat Command

struct CopyChatCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "copy-chat",
        abstract: "Invoke the app menu item to copy chat, then print clipboard contents"
    )

    @Option(name: .shortAndLong, help: "Application bundle identifier")
    var app: String

    @Flag(name: .long, help: "Output in JSON format")
    var json: Bool = false

    func run() async throws {
        LoggingSystem.bootstrap(StreamLogHandler.standardOutput)

        // First try menubar
        var (ok, title) = pressMenuItem(appBundleId: app, titleContains: "Copy Chat")
        var clip = readClipboardString()
        if !ok || clip.isEmpty {
            // Contextual: find reply, press actions, pick item
            let bootstrap = UIScoutBootstrap()
            let status = try await bootstrap.initialize()
            guard status.canOperate else { throw ExitCode(1) }

            let ax = AXClient()
            let finder = ElementFinder(axClient: ax)
            let snap = SnapshotManager(axClient: ax)
            let scorer = ConfidenceScorer()
            let ocr = OCRManager()
            let store = try SignatureStore()
            let rate = RateLimiter()
            let factory = StateMachineFactory(scorer: scorer, snapshotManager: snap, axClient: ax, ocrManager: ocr)
            let orch = UIScoutOrchestrator(axClient: ax, elementFinder: finder, snapshotManager: snap, scorer: scorer, ocrManager: ocr, stateMachineFactory: factory, store: store, rateLimiter: rate)
            let policy = Policy(allowPeek: true, minConfidence: 0.6)
            let replyRes = await orch.findElement(appBundleId: app, elementType: .reply, policy: policy)
            if let replyEl = resolveElementBySignature(axClient: ax, signature: replyRes.elementSignature) {
                let res = invokeActionsAndCopy(ax: ax, appBundleId: app, reply: replyEl, pickTitleContains: "Copy Chat")
                ok = res.invoked
                clip = res.clipboard.isEmpty ? clip : res.clipboard
                title = title ?? "Copy Chat"
            }
            orch.cleanup()
        }

        if json {
            printJSONAny(["invoked": ok, "title": title ?? "Copy Chat", "clipboard": clip])
        } else {
            print("📋 Copy Chat invoked=\(ok) title=\(title ?? "Copy Chat")")
            print(clip)
        }
    }
}

// MARK: - Copy Error Logs Command

struct CopyErrorLogsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "copy-error-logs",
        abstract: "Invoke the app menu item to copy error logs, then print clipboard contents"
    )

    @Option(name: .shortAndLong, help: "Application bundle identifier")
    var app: String

    @Flag(name: .long, help: "Output in JSON format")
    var json: Bool = false

    func run() async throws {
        LoggingSystem.bootstrap(StreamLogHandler.standardOutput)

        // First try menubar
        var (ok, title) = pressMenuItem(appBundleId: app, titleContains: "Copy Error Logs")
        var clip = readClipboardString()
        if !ok || clip.isEmpty {
            let bootstrap = UIScoutBootstrap()
            let status = try await bootstrap.initialize()
            guard status.canOperate else { throw ExitCode(1) }

            let ax = AXClient()
            let finder = ElementFinder(axClient: ax)
            let snap = SnapshotManager(axClient: ax)
            let scorer = ConfidenceScorer()
            let ocr = OCRManager()
            let store = try SignatureStore()
            let rate = RateLimiter()
            let factory = StateMachineFactory(scorer: scorer, snapshotManager: snap, axClient: ax, ocrManager: ocr)
            let orch = UIScoutOrchestrator(axClient: ax, elementFinder: finder, snapshotManager: snap, scorer: scorer, ocrManager: ocr, stateMachineFactory: factory, store: store, rateLimiter: rate)
            let policy = Policy(allowPeek: true, minConfidence: 0.6)
            let replyRes = await orch.findElement(appBundleId: app, elementType: .reply, policy: policy)
            if let replyEl = resolveElementBySignature(axClient: ax, signature: replyRes.elementSignature) {
                let res = invokeActionsAndCopy(ax: ax, appBundleId: app, reply: replyEl, pickTitleContains: "Copy Error Logs")
                ok = res.invoked
                clip = res.clipboard.isEmpty ? clip : res.clipboard
                title = title ?? "Copy Error Logs"
            }
            orch.cleanup()
        }

        if json {
            printJSONAny(["invoked": ok, "title": title ?? "Copy Error Logs", "clipboard": clip])
        } else {
            print("📋 Copy Error Logs invoked=\(ok) title=\(title ?? "Copy Error Logs")")
            print(clip)
        }
    }
}

// MARK: - Find Command

struct FindCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "find",
        abstract: "Find UI elements in applications"
    )
    
    @Option(name: .shortAndLong, help: "Application bundle identifier")
    var app: String
    
    @Option(name: .shortAndLong, help: "Element type (reply, input, session, send)")
    var type: String
    
    @Option(name: .long, help: "Minimum confidence threshold (0.0-1.0)")
    var minConfidence: Double = 0.8
    
    @Option(name: .long, help: "Maximum peek duration in milliseconds")
    var maxPeekMs: Int = 250
    
    @Flag(name: .long, help: "Allow polite peek if needed")
    var allowPeek: Bool = false
    
    @Flag(name: .long, help: "Output in JSON format")
    var json: Bool = false
    
    func validate() throws {
    let validTypes = ["reply", "input", "session", "send"]
        guard validTypes.contains(type.lowercased()) else {
            throw ValidationError("Invalid element type. Must be one of: \(validTypes.joined(separator: ", "))")
        }
        
        guard minConfidence >= 0.0 && minConfidence <= 1.0 else {
            throw ValidationError("Confidence threshold must be between 0.0 and 1.0")
        }
    }
    
    func run() async throws {
        LoggingSystem.bootstrap(StreamLogHandler.standardOutput)
        
        let bootstrap = UIScoutBootstrap()
        let permissionStatus = try await bootstrap.initialize()
        
        guard permissionStatus.canOperate else {
            if json {
                let error: [String: Any] = [
                    "error": "Insufficient permissions",
                    "needs": permissionStatus.needsPrompt
                ]
                printJSONAny(error)
            } else {
                print("❌ Cannot operate: missing permissions")
                print("Needs: \(permissionStatus.needsPrompt.joined(separator: ", "))")
            }
            throw ExitCode(1)
        }
        
        // Initialize core components
        let axClient = AXClient()
        let elementFinder = ElementFinder(axClient: axClient)
        let snapshotManager = SnapshotManager(axClient: axClient)
        let scorer = ConfidenceScorer()
        let ocrManager = OCRManager()
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
        
        // Parse element type
        guard let elementType = ElementSignature.ElementType(rawValue: type.lowercased()) else {
            throw ValidationError("Invalid element type")
        }
        
        // Create policy
        let policy = Policy(
            allowPeek: allowPeek,
            minConfidence: minConfidence,
            maxPeekMs: maxPeekMs
        )
        
        // Find element
        let result = await orchestrator.findElement(
            appBundleId: app,
            elementType: elementType,
            policy: policy
        )
        
        // Output result
        if json {
            printJSON(result)
        } else {
            printFindResult(result, app: app, elementType: elementType)
        }
        
        // Cleanup
        orchestrator.cleanup()
    }
    
    private func printFindResult(_ result: ElementResult, app: String, elementType: ElementSignature.ElementType) {
        print("🔍 UIScout Find Results")
        print("App: \(app)")
        print("Element Type: \(elementType.rawValue)")
        print("Confidence: \(String(format: "%.2f", result.confidence))")
        print("Method: \(result.evidence.method.rawValue)")
        
        if result.confidence >= minConfidence {
            print("✅ Element found successfully")
            print("Role: \(result.elementSignature.role)")
            print("Stability: \(String(format: "%.2f", result.elementSignature.stability))")
        } else {
            print("⚠️  Low confidence result")
            if !result.needsPermissions.isEmpty {
                print("Missing: \(result.needsPermissions.joined(separator: ", "))")
            }
        }
    }
}

// MARK: - Discover Chat Command

struct DiscoverChatCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "discover-chat",
        abstract: "Discover standard chat UI elements (input, send, reply, session)"
    )

    @Option(name: .shortAndLong, help: "Application bundle identifier")
    var app: String

    @Option(name: .long, help: "Minimum confidence threshold (0.0-1.0)")
    var minConfidence: Double = 0.6

    @Flag(name: .long, help: "Allow polite peek if needed")
    var allowPeek: Bool = false

    @Flag(name: .long, help: "Output in JSON format")
    var json: Bool = false

    func run() async throws {
        LoggingSystem.bootstrap(StreamLogHandler.standardOutput)

        let bootstrap = UIScoutBootstrap()
        let permissionStatus = try await bootstrap.initialize()
        guard permissionStatus.canOperate else { throw ExitCode(1) }

        // Initialize core components
        let axClient = AXClient()
        let elementFinder = ElementFinder(axClient: axClient)
        let snapshotManager = SnapshotManager(axClient: axClient)
        let scorer = ConfidenceScorer()
        let ocrManager = OCRManager()
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

        let policy = Policy(allowPeek: allowPeek, minConfidence: minConfidence)

        // Find all four elements
        async let input = orchestrator.findElement(appBundleId: app, elementType: .input, policy: policy)
        async let send = orchestrator.findElement(appBundleId: app, elementType: .send, policy: policy)
        async let reply = orchestrator.findElement(appBundleId: app, elementType: .reply, policy: policy)
        async let session = orchestrator.findElement(appBundleId: app, elementType: .session, policy: policy)
        let (inputR, sendR, replyR, sessionR) = await (input, send, reply, session)

        let results = [
            "input": inputR,
            "send": sendR,
            "reply": replyR,
            "session": sessionR
        ]

        if json {
            printJSON(results)
        } else {
            print("🔎 Chat UI Discovery for \(app)")
            for (key, res) in results {
                let ok = res.confidence >= minConfidence
                let status = ok ? "✅" : "⚠️"
                print("\(status) \(key): \(String(format: "%.2f", res.confidence)) role=\(res.elementSignature.role)")
            }
        }

        orchestrator.cleanup()
    }
}

// MARK: - Observe Command

struct ObserveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "observe",
        abstract: "Observe UI element changes over time"
    )
    
    @Option(name: .shortAndLong, help: "Application bundle identifier")
    var app: String
    
    @Option(name: .shortAndLong, help: "Element signature JSON file path")
    var signature: String
    
    @Option(name: .shortAndLong, help: "Duration to observe in seconds")
    var duration: Int = 10
    
    @Flag(name: .long, help: "Output events as they occur")
    var stream: Bool = false
    
    @Flag(name: .long, help: "Output in JSON format")
    var json: Bool = false
    
    func run() async throws {
        LoggingSystem.bootstrap(StreamLogHandler.standardOutput)
        
        // Load signature from file
        let signatureData = try Data(contentsOf: URL(fileURLWithPath: signature))
        let elementSignature = try JSONDecoder().decode(ElementSignature.self, from: signatureData)
        
        let bootstrap = UIScoutBootstrap()
        let permissionStatus = try await bootstrap.initialize()
        
        guard permissionStatus.canOperate else {
            throw ExitCode(1)
        }
        
        // Initialize components
        let axClient = AXClient()
        let snapshotManager = SnapshotManager(axClient: axClient)
        let scorer = ConfidenceScorer()
        let ocrManager = OCRManager()
        let store = try SignatureStore()
        let rateLimiter = RateLimiter()
        let elementFinder = ElementFinder(axClient: axClient)
        
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
        
        if !json {
            print("👀 Observing \(elementSignature.elementType.rawValue) in \(app) for \(duration)s...")
        }
        
        // Start observation
        let eventStream = await orchestrator.observeElement(
            appBundleId: app,
            signature: elementSignature,
            durationSeconds: duration
        )
        
        // Monitor events
        var eventCount = 0
        let startTime = Date()
        
        while Date().timeIntervalSince(startTime) < TimeInterval(duration) {
            let events = eventStream.getRecentEvents(since: startTime)
            let newEvents = events.suffix(events.count - eventCount)
            
            for event in newEvents {
                eventCount += 1
                
                if json {
                    let eventDict: [String: Any] = [
                        "timestamp": event.timestamp.timeIntervalSince1970,
                        "notification": event.notification,
                        "app": event.appBundleId
                    ]
                    printJSONAny(eventDict)
                } else if stream {
                    let timeString = DateFormatter().string(from: event.timestamp)
                    print("[\(timeString)] \(event.notification)")
                }
            }
            
            try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        }
        
        if !json {
            print("📊 Observed \(eventCount) events total")
        }
        
        orchestrator.cleanup()
    }
}

// MARK: - After Send Diff Command

struct AfterSendDiffCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "after-send-diff",
        abstract: "Check for changes after sending a message"
    )
    
    @Option(name: .shortAndLong, help: "Application bundle identifier")
    var app: String
    
    @Option(name: .long, help: "Pre-send signature JSON file path")
    var preSignature: String
    
    @Flag(name: .long, help: "Allow polite peek if needed")
    var allowPeek: Bool = false
    
    @Flag(name: .long, help: "Output in JSON format")
    var json: Bool = false
    
    func run() async throws {
        LoggingSystem.bootstrap(StreamLogHandler.standardOutput)
        
        // Load signature from file
        let signatureData = try Data(contentsOf: URL(fileURLWithPath: preSignature))
        let elementSignature = try JSONDecoder().decode(ElementSignature.self, from: signatureData)
        
        let bootstrap = UIScoutBootstrap()
        let permissionStatus = try await bootstrap.initialize()
        
        guard permissionStatus.canOperate else {
            throw ExitCode(1)
        }
        
        // Initialize components (same pattern as find command)
        let axClient = AXClient()
        let elementFinder = ElementFinder(axClient: axClient)
        let snapshotManager = SnapshotManager(axClient: axClient)
        let scorer = ConfidenceScorer()
        let ocrManager = OCRManager()
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
        
        let policy = Policy(allowPeek: allowPeek)
        
        let result = await orchestrator.afterSendDiff(
            appBundleId: app,
            preSignature: elementSignature,
            policy: policy
        )
        
        if json {
            printJSON(result)
        } else {
            print("🔄 After-Send Diff Results")
            print("App: \(app)")
            print("Method: \(result.evidence.method.rawValue)")
            print("Confidence: \(String(format: "%.2f", result.confidence))")
            
            if result.evidence.diffScore > 0.1 {
                print("✅ Changes detected")
            } else {
                print("⚠️  No clear changes detected")
            }
        }
        
        orchestrator.cleanup()
    }
}

// MARK: - Snapshot Command

struct SnapshotCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "snapshot",
        abstract: "Capture element snapshot for diagnostics"
    )
    
    @Option(name: .shortAndLong, help: "Application bundle identifier")
    var app: String
    
    @Option(name: .shortAndLong, help: "Element signature JSON file path")
    var signature: String
    
    @Flag(name: .long, help: "Output in JSON format")
    var json: Bool = false
    
    func run() async throws {
        LoggingSystem.bootstrap(StreamLogHandler.standardOutput)
        
        let signatureData = try Data(contentsOf: URL(fileURLWithPath: signature))
        let elementSignature = try JSONDecoder().decode(ElementSignature.self, from: signatureData)
        
        let bootstrap = UIScoutBootstrap()
        try await bootstrap.validateRuntime()
        
        let axClient = AXClient()
        let snapshotManager = SnapshotManager(axClient: axClient)
        
        if let snapshot = snapshotManager.createSnapshot(for: elementSignature) {
            if json {
                printJSON(snapshot)
            } else {
                print("📸 Element Snapshot")
                print("Role: \(snapshot.role)")
                print("Frame: \(snapshot.frame)")
                print("Children: \(snapshot.childCount)")
                print("Text Length: \(snapshot.textLength)")
                print("Value: \(snapshot.value ?? "nil")")
            }
        } else {
            if json {
                printJSON(["error": "Could not create snapshot"])
            } else {
                print("❌ Could not create snapshot")
            }
            throw ExitCode(1)
        }
    }
}

// MARK: - Learn Command

struct LearnCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "learn",
        abstract: "Manage signature learning and storage"
    )
    
    @Option(name: .shortAndLong, help: "Element signature JSON file path")
    var signature: String
    
    @Flag(name: .long, help: "Pin this signature (prevent decay)")
    var pin: Bool = false
    
    @Flag(name: .long, help: "Decay this signature (reduce stability)")
    var decay: Bool = false
    
    @Flag(name: .long, help: "Output in JSON format")
    var json: Bool = false
    
    func run() async throws {
        LoggingSystem.bootstrap(StreamLogHandler.standardOutput)
        
        let signatureData = try Data(contentsOf: URL(fileURLWithPath: signature))
        let elementSignature = try JSONDecoder().decode(ElementSignature.self, from: signatureData)
        
        let store = try SignatureStore()
        
        // Initialize minimal orchestrator for learn functionality
        let axClient = AXClient()
        let elementFinder = ElementFinder(axClient: axClient)
        let snapshotManager = SnapshotManager(axClient: axClient)
        let scorer = ConfidenceScorer()
        let ocrManager = OCRManager()
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
        
        await orchestrator.learnSignature(
            signature: elementSignature,
            pin: pin,
            decay: decay
        )
        
        if json {
            let result = [
                "action": pin ? "pinned" : (decay ? "decayed" : "stored"),
                "signature_id": "\(elementSignature.appBundleId)-\(elementSignature.elementType.rawValue)"
            ]
            printJSON(result)
        } else {
            let action = pin ? "📌 Pinned" : (decay ? "📉 Decayed" : "💾 Stored")
            print("\(action) signature for \(elementSignature.appBundleId)/\(elementSignature.elementType.rawValue)")
        }
    }
}

// MARK: - Send Message Command (AX-safe)

struct SendMessageCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "send",
        abstract: "Set chat input text via AX and press the send button (no raw keystrokes)"
    )

    @Option(name: .shortAndLong, help: "Application bundle identifier (e.g., com.raycast.macos)")
    var app: String

    @Option(name: .shortAndLong, help: "Message text to send")
    var text: String

    @Option(name: .long, help: "Minimum confidence threshold for element discovery")
    var minConfidence: Double = 0.6

    @Flag(name: .long, help: "Allow polite peek if needed")
    var allowPeek: Bool = true

    @Flag(name: .long, help: "Output in JSON format")
    var json: Bool = false

    func run() async throws {
        LoggingSystem.bootstrap(StreamLogHandler.standardOutput)

        // Permissions
        let bootstrap = UIScoutBootstrap()
        let permissionStatus = try await bootstrap.initialize()
        guard permissionStatus.canOperate else { throw ExitCode(1) }

        // Core components
        let axClient = AXClient()
        let elementFinder = ElementFinder(axClient: axClient)
        let snapshotManager = SnapshotManager(axClient: axClient)
        let scorer = ConfidenceScorer()
        let ocrManager = OCRManager()
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

        let policy = Policy(allowPeek: allowPeek, minConfidence: minConfidence)

        // Discover input, send, reply in parallel
        async let inputR = orchestrator.findElement(appBundleId: app, elementType: .input, policy: policy)
        async let sendR = orchestrator.findElement(appBundleId: app, elementType: .send, policy: policy)
        async let replyR = orchestrator.findElement(appBundleId: app, elementType: .reply, policy: policy)
        let (inputRes, sendRes, replyRes) = await (inputR, sendR, replyR)

        // Resolve AX elements using path hints (index-based where available)
        var inputEl = resolveAXByPathHint(axClient: axClient, signature: inputRes.elementSignature)
        var sendEl = resolveAXByPathHint(axClient: axClient, signature: sendRes.elementSignature)

        var setValueOK = false
        var pressedSendOK = false
        var confirmedInputOK = false

        if let el = inputEl {
            // Preferred: set AXValue on the input element
            do {
                // Attempt to focus first for better reliability
                try? axClient.focusElement(el)
                try axClient.setAttribute(el, kAXValueAttribute, value: text)
                setValueOK = true
            } catch {
                setValueOK = false
            }
        } else {
            // Fallback: try to locate a text field via BFS
            if let bfsInput = bfsFindRole(axClient: axClient, bundleId: app, desiredRole: kAXTextFieldRole) ?? bfsFindRole(axClient: axClient, bundleId: app, desiredRole: kAXTextAreaRole) {
                inputEl = bfsInput
                do {
                    try? axClient.focusElement(bfsInput)
                    try axClient.setAttribute(bfsInput, kAXValueAttribute, value: text)
                    setValueOK = true
                } catch {
                    setValueOK = false
                }
            }
        }

        if let el = sendEl {
            // Preferred: press the send button via AXPress
            do {
                try? axClient.focusElement(el)
                try axClient.performAction(el, action: kAXPressAction)
                pressedSendOK = true
            } catch {
                pressedSendOK = false
            }
        } else {
            // Fallback: try to locate any button in the active window and press it
            if let bfsButton = bfsFindRole(axClient: axClient, bundleId: app, desiredRole: kAXButtonRole) {
                sendEl = bfsButton
                do {
                    try? axClient.focusElement(bfsButton)
                    try axClient.performAction(bfsButton, action: kAXPressAction)
                    pressedSendOK = true
                } catch {
                    pressedSendOK = false
                }
            }
        }

        if !pressedSendOK, let inputEl {
            // Fallback: confirm on the input control
            do {
                try axClient.performAction(inputEl, action: kAXConfirmAction)
                confirmedInputOK = true
            } catch {
                confirmedInputOK = false
            }
        }

        // Always try to confirm once on input to avoid UI edge-cases
        if !pressedSendOK, let el = inputEl {
            try? axClient.performAction(el, action: kAXConfirmAction)
            confirmedInputOK = confirmedInputOK || true
        }

        // Delay briefly to allow UI to update
        try? await Task.sleep(nanoseconds: 1_200_000_000)

        // Enhanced diff: try passive diff, then force OCR if available
        var diffResult = await orchestrator.afterSendDiff(
            appBundleId: app,
            preSignature: replyRes.elementSignature,
            policy: policy
        )

        if #available(macOS 10.15, *) {
            // If passive diff is weak, attempt OCR confirmation regardless of stability
            let beforeSnap = SnapshotManager(axClient: axClient).createSnapshot(for: replyRes.elementSignature)
            try? await Task.sleep(nanoseconds: 400_000_000)
            let afterSnap = SnapshotManager(axClient: axClient).createSnapshot(for: replyRes.elementSignature)
            if let b = beforeSnap, let a = afterSnap {
                let ocr = await OCRManager(disabled: false).performOCRCheck(appBundleId: app, beforeSnapshot: b, afterSnapshot: a)
                if ocr.changeDetected {
                    let snapDiff = SnapshotManager(axClient: axClient).calculateDiff(before: b, after: a)
                    let newConf = ConfidenceScorer().calculateConfidence(
                        signature: replyRes.elementSignature,
                        heuristicScore: replyRes.elementSignature.stability,
                        diffEvidence: snapDiff,
                        ocrEvidence: ocr,
                        method: .ocr
                    )
                    diffResult = ElementResult(
                        elementSignature: replyRes.elementSignature,
                        confidence: newConf,
                        evidence: Evidence(method: .ocr, heuristicScore: replyRes.elementSignature.stability, diffScore: snapDiff.confidence, ocrChange: true, confidence: newConf)
                    )
                }
            }
        }

        if json {
            let out: [String: Any] = [
                "app": app,
                "elements": [
                    "input": ["confidence": inputRes.confidence, "role": inputRes.elementSignature.role],
                    "send": ["confidence": sendRes.confidence, "role": sendRes.elementSignature.role],
                    "reply": ["confidence": replyRes.confidence, "role": replyRes.elementSignature.role]
                ],
                "actions": [
                    "setValue": setValueOK,
                    "pressedSend": pressedSendOK,
                    "confirmedInput": confirmedInputOK
                ],
                "diff": [
                    "confidence": diffResult.confidence,
                    "diffScore": diffResult.evidence.diffScore,
                    "ocrChange": diffResult.evidence.ocrChange
                ],
                "success": (setValueOK && (pressedSendOK || confirmedInputOK)) && (diffResult.confidence >= 0.5)
            ]
            printJSONAny(out)
        } else {
            print("✉️  Send in \(app)")
            print("- input: conf=\(String(format: "%.2f", inputRes.confidence)) role=\(inputRes.elementSignature.role)")
            print("- send:  conf=\(String(format: "%.2f", sendRes.confidence)) role=\(sendRes.elementSignature.role)")
            print("- reply: conf=\(String(format: "%.2f", replyRes.confidence)) role=\(replyRes.elementSignature.role)")
            print("- actions: setValue=\(setValueOK) press=\(pressedSendOK) confirm=\(confirmedInputOK)")
            print("- diff:   conf=\(String(format: "%.2f", diffResult.confidence)) score=\(String(format: "%.2f", diffResult.evidence.diffScore)) ocr=\(diffResult.evidence.ocrChange)")
        }

        orchestrator.cleanup()
    }

    // Resolve AX element using signature.pathHint (e.g., ["AXApplication[0]","AXWindow[1]",...])
    private func resolveAXByPathHint(axClient: AXClient, signature: ElementSignature) -> AXUIElement? {
        guard let windows = try? axClient.getElementsForApp(signature.appBundleId) else { return nil }

        // Extract window index from pathHint if present
        let windowStep = signature.pathHint.first(where: { $0.hasPrefix("AXWindow[") })
        var targetWindowIndex: Int? = nil
        if let step = windowStep,
           let lb = step.firstIndex(of: "["), let rb = step.firstIndex(of: "]"),
           let idx = Int(step[step.index(after: lb)..<rb]) {
            targetWindowIndex = idx
        }

        for (i, window) in windows.enumerated() {
            if let targetIndex = targetWindowIndex, targetIndex != i { continue }
            if let element = traverseByPathHint(axClient: axClient, root: window, pathHint: signature.pathHint) {
                return element
            }
        }
        return nil
    }

    private func traverseByPathHint(axClient: AXClient, root: AXUIElement, pathHint: [String]) -> AXUIElement? {
        // Start at the window step in the path
        guard let windowPos = pathHint.firstIndex(where: { $0.hasPrefix("AXWindow[") }) else { return nil }
        var current: AXUIElement = root

        for step in pathHint.dropFirst(windowPos + 1) { // steps under window
            guard let lb = step.firstIndex(of: "["), let rb = step.firstIndex(of: "]") else { return nil }
            let role = String(step[..<lb])
            guard let idx = Int(step[step.index(after: lb)..<rb]) else { return nil }
            guard let children = try? axClient.getAttribute(current, kAXChildrenAttribute, as: [AXUIElement].self) else { return nil }
            // pick the idx-th child that matches role among all children with that role
            var count = 0
            var nextEl: AXUIElement?
            for child in children {
                let childRole = (try? axClient.getAttribute(child, kAXRoleAttribute, as: String.self)) ?? ""
                if childRole == role {
                    if count == idx { nextEl = child; break }
                    count += 1
                }
            }
            guard let next = nextEl else { return nil }
            current = next
        }
        return current
    }

    // Simple BFS to find an element with a desired AXRole in the app's frontmost window
    private func bfsFindRole(axClient: AXClient, bundleId: String, desiredRole: String, maxDepth: Int = 7) -> AXUIElement? {
        guard let windows = try? axClient.getElementsForApp(bundleId), let root = windows.first else { return nil }
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        while !queue.isEmpty {
            let (el, d) = queue.removeFirst()
            if d > maxDepth { continue }
            let role = (try? axClient.getAttribute(el, kAXRoleAttribute, as: String.self)) ?? ""
            if role == desiredRole { return el }
            if let children = try? axClient.getAttribute(el, kAXChildrenAttribute, as: [AXUIElement].self) {
                for c in children { queue.append((c, d + 1)) }
            }
        }
        return nil
    }
}

// MARK: - Status Command

struct StatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show UIScout system status and statistics"
    )
    
    @Flag(name: .long, help: "Output in JSON format")
    var json: Bool = false
    
    func run() async throws {
        LoggingSystem.bootstrap(StreamLogHandler.standardOutput)
        
        let permissionsManager = PermissionsManager()
        let permissionStatus = permissionsManager.checkAllPermissions()
        let environment = permissionsManager.detectEnvironment()
        
        let store = try SignatureStore()
        let stats = await store.getStatistics()
        
        if json {
            let status: [String: Any] = [
                "permissions": [
                    "accessibility": permissionStatus.accessibility,
                    "screen_recording": permissionStatus.screenRecording,
                    "can_operate": permissionStatus.canOperate
                ],
                "environment": [
                    "bundle_id": environment.bundleIdentifier,
                    "is_terminal": environment.isInTerminal,
                    "is_sandboxed": environment.isSandboxed
                ],
                "store": [
                    "signatures": stats.signatureCount,
                    "evidence_records": stats.evidenceCount,
                    "average_stability": stats.averageStability,
                    "pinned_signatures": stats.pinnedSignatureCount
                ]
            ]
            printJSONAny(status)
        } else {
            print("🎯 UIScout Status")
            print("\nPermissions:")
            print(permissionStatus.description)
            
            print("\nEnvironment:")
            print(environment.description)
            
            print("\nSignature Store:")
            print(stats.description)
            
            if permissionStatus.canOperate {
                print("\n✅ Ready to operate")
            } else {
                print("\n❌ Cannot operate - missing permissions")
            }
        }
    }
}

// MARK: - Setup Command

struct SetupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Interactive setup for UIScout permissions"
    )
    
    func run() async throws {
        LoggingSystem.bootstrap(StreamLogHandler.standardOutput)
        
        print("🚀 UIScout Setup")
        print("This will guide you through granting necessary permissions.\n")
        
        let bootstrap = UIScoutBootstrap()
        let finalStatus = try await bootstrap.initialize()
        
        print("\n" + finalStatus.description)
        
        if finalStatus.canOperate {
            print("\n🎉 Setup completed successfully!")
            print("You can now use UIScout to discover and interact with UI elements.")
        } else {
            print("\n⚠️  Setup incomplete")
            print("Some features may not work without all permissions.")
            throw ExitCode(1)
        }
    }
}

// MARK: - Helper Functions

private func printJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    
    do {
        let data = try encoder.encode(value)
        if let string = String(data: data, encoding: .utf8) {
            print(string)
        }
    } catch {
        print("Error encoding JSON: \(error)")
    }
}

// Helper for printing heterogenous dictionaries/arrays
private func printJSONAny(_ value: Any) {
    guard JSONSerialization.isValidJSONObject(value) else {
        print("Error: value is not a valid JSON object")
        return
    }
    do {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        if let string = String(data: data, encoding: .utf8) {
            print(string)
        }
    } catch {
        print("Error serializing JSON: \(error)")
    }
}

// MARK: - Extensions

// Codable conformances are already declared in UIScoutCore
