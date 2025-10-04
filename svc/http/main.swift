import Vapor
import Foundation
import UIScoutCore
import Logging
import ApplicationServices

// MARK: - HTTP Service Entry Point

@main
struct UIScoutService {
    static func main() async throws {
        var env = try Environment.detect()
        try LoggingSystem.bootstrap(from: &env)

    let app = try await Application.make(env)
    defer { Task { try? await app.asyncShutdown() } }

    try await configure(app)
    try await app.execute()
    }
}

// MARK: - Application Configuration

func configure(_ app: Application) async throws {
    // Initialize UIScout core components
    let bootstrap = UIScoutBootstrap()
    let permissionStatus = try await bootstrap.initialize()
    
    guard permissionStatus.canOperate else {
        app.logger.critical("Cannot start service: insufficient permissions")
        print("❌ UIScout Service cannot start - missing permissions:")
        print(permissionStatus.description)
        throw Abort(.internalServerError, reason: "Insufficient permissions")
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
    
    // Store orchestrator in application storage
    app.storage[UIScoutOrchestratorKey.self] = orchestrator
    
    // Configure routes
    try routes(app)
    
    // Configure server
    app.http.server.configuration.hostname = "127.0.0.1"
    app.http.server.configuration.port = 8080
    
    app.logger.info("UIScout Service starting on http://127.0.0.1:8080")
}

// MARK: - Storage Keys

private struct UIScoutOrchestratorKey: StorageKey {
    typealias Value = UIScoutOrchestrator
}

extension Application {
    var orchestrator: UIScoutOrchestrator {
        get {
            guard let orchestrator = self.storage[UIScoutOrchestratorKey.self] else {
                fatalError("UIScoutOrchestrator not configured")
            }
            return orchestrator
        }
        set {
            self.storage[UIScoutOrchestratorKey.self] = newValue
        }
    }
}

// MARK: - Routes

func routes(_ app: Application) throws {
    // Health check
    app.get("health") { req -> HealthResponse in
        HealthResponse(status: "ok", timestamp: Date().timeIntervalSince1970)
    }
    
    // API version 1
    let api = app.grouped("api", "v1")
    
    // Find element
    api.post("find") { req -> ElementResultResponse in
        let request = try req.content.decode(FindElementRequest.self)
        let orchestrator = req.application.orchestrator
        
        guard let elementType = ElementSignature.ElementType(rawValue: request.elementType) else {
            throw Abort(.badRequest, reason: "Invalid element type")
        }
        
        let policy = request.policy ?? Policy.default
        
        let result = await orchestrator.findElement(
            appBundleId: request.appBundleId,
            elementType: elementType,
            policy: policy
        )
        
        return ElementResultResponse(from: result)
    }
    
    // After-send diff
    api.post("after-send-diff") { req -> ElementResultResponse in
        let request = try req.content.decode(AfterSendDiffRequest.self)
        let orchestrator = req.application.orchestrator
        
        let policy = request.policy ?? Policy.default
        
        let result = await orchestrator.afterSendDiff(
            appBundleId: request.appBundleId,
            preSignature: request.preSignature,
            policy: policy
        )
        
        return ElementResultResponse(from: result)
    }
    
    // Observe element
    api.post("observe") { req -> Response in
        let request = try req.content.decode(ObserveElementRequest.self)
        let orchestrator = req.application.orchestrator
        
        // Start observation
        let eventStream = await orchestrator.observeElement(
            appBundleId: request.appBundleId,
            signature: request.signature,
            durationSeconds: request.durationSeconds,
            policy: request.policy ?? Policy.default
        )
        
        // Return streaming response
        let response = Response()
        response.headers.contentType = .init(type: "text", subType: "event-stream")
        response.headers.add(name: .cacheControl, value: "no-cache")
        response.headers.add(name: .connection, value: "keep-alive")
        
        // Stream events (server-sent events) using EventLoop scheduling
        response.body = .init(stream: { writer in
            let startTime = Date()
            let endTime = startTime.addingTimeInterval(TimeInterval(request.durationSeconds))
            var eventCount = 0
            
            func pump() {
                if Date() >= endTime {
                    let completionString = "{\"type\":\"complete\",\"total_events\":\(eventCount)}"
                    _ = writer.write(.buffer(.init(string: "data: \(completionString)\n\n")))
                    return
                }
                let events = eventStream.getRecentEvents(since: startTime)
                let newEvents = events.suffix(events.count - eventCount)
                for event in newEvents {
                    if let eventData = try? JSONEncoder().encode(ObservationEvent(from: event)),
                       let eventString = String(data: eventData, encoding: .utf8) {
                        _ = writer.write(.buffer(.init(string: "data: \(eventString)\n\n")))
                        eventCount += 1
                    }
                }
                _ = req.eventLoop.scheduleTask(in: .milliseconds(100)) { pump() }
            }
            pump()
        })
        
        return response
    }
    
    // Capture snapshot
    api.post("snapshot") { req -> SnapshotResponse in
        let request = try req.content.decode(SnapshotRequest.self)
        let orchestrator = req.application.orchestrator
        
        if let snapshot = orchestrator.captureSnapshot(
            appBundleId: request.appBundleId,
            signature: request.signature
        ) {
            return SnapshotResponse(snapshot: snapshot, success: true)
        } else {
            return SnapshotResponse(snapshot: nil, success: false, error: "Could not create snapshot")
        }
    }
    
    // Learn signature
    api.post("learn") { req -> LearnResponse in
        let request = try req.content.decode(LearnRequest.self)
        let orchestrator = req.application.orchestrator
        
        await orchestrator.learnSignature(
            signature: request.signature,
            pin: request.pin,
            decay: request.decay
        )
        
        let action = request.pin ? "pinned" : (request.decay ? "decayed" : "stored")
        return LearnResponse(
            success: true,
            action: action,
            signatureId: "\(request.signature.appBundleId)-\(request.signature.elementType.rawValue)"
        )
    }
    
    // Get status
    api.get("status") { req -> StatusResponse in
        let permissionsManager = PermissionsManager()
        let permissionStatus = permissionsManager.checkAllPermissions()
        let environment = permissionsManager.detectEnvironment()
        
        let store = try SignatureStore()
        let stats = await store.getStatistics()
        
        return StatusResponse(
            permissions: PermissionStatusResponse(from: permissionStatus),
            environment: EnvironmentResponse(from: environment),
            store: StoreStatsResponse(from: stats),
            canOperate: permissionStatus.canOperate
        )
    }
    
    // List signatures
    api.get("signatures") { req -> SignatureListResponse in
        let appBundleId = req.query[String.self, at: "app"]
        let elementTypeStr = req.query[String.self, at: "type"]
        
        var elementType: ElementSignature.ElementType?
        if let elementTypeStr = elementTypeStr {
            elementType = ElementSignature.ElementType(rawValue: elementTypeStr)
        }
        
        let store = try SignatureStore()
        let signatures = await store.getAllSignatures(
            appBundleId: appBundleId,
            elementType: elementType
        )
        
        return SignatureListResponse(signatures: signatures, count: signatures.count)
    }

    // Send message (AX-safe): set input value and press send button, then evaluate diff
    api.post("send") { req -> SendResponse in
        let request = try req.content.decode(SendRequest.self)
        let orchestrator = req.application.orchestrator

        let policy = request.policy ?? Policy.default

        // Discover elements in parallel
        async let inputR = orchestrator.findElement(appBundleId: request.appBundleId, elementType: .input, policy: policy)
        async let sendR  = orchestrator.findElement(appBundleId: request.appBundleId, elementType: .send,  policy: policy)
        async let replyR = orchestrator.findElement(appBundleId: request.appBundleId, elementType: .reply, policy: policy)
        let (inputRes, sendRes, replyRes) = await (inputR, sendR, replyR)

        // Resolve AX elements via signature.pathHint heuristics
        let ax = AXClient()
        var setValueOK = false
        var pressedSendOK = false
        var confirmedInputOK = false

        if let inputEl = resolveAXByPathHint(axClient: ax, signature: inputRes.elementSignature) ?? bfsFindRole(axClient: ax, bundleId: request.appBundleId, desiredRole: kAXTextFieldRole) ?? bfsFindRole(axClient: ax, bundleId: request.appBundleId, desiredRole: kAXTextAreaRole) {
            // Try to focus and set AXValue
            try? ax.focusElement(inputEl)
            try? ax.setAttribute(inputEl, kAXValueAttribute, value: request.text)
            setValueOK = true

            // Try pressing explicit send button, else confirm input
            if let sendEl = resolveAXByPathHint(axClient: ax, signature: sendRes.elementSignature) ?? bfsFindRole(axClient: ax, bundleId: request.appBundleId, desiredRole: kAXButtonRole) {
                try? ax.focusElement(sendEl)
                try? ax.performAction(sendEl, action: kAXPressAction)
                pressedSendOK = true
            } else {
                try? ax.performAction(inputEl, action: kAXConfirmAction)
                confirmedInputOK = true
            }
        }

        // Always try confirm after possible press
        if !pressedSendOK, let inputEl = resolveAXByPathHint(axClient: ax, signature: inputRes.elementSignature) ?? bfsFindRole(axClient: ax, bundleId: request.appBundleId, desiredRole: kAXTextFieldRole) {
            try? ax.performAction(inputEl, action: kAXConfirmAction)
            confirmedInputOK = confirmedInputOK || true
        }

        // Delay to allow UI refresh
        try? await Task.sleep(nanoseconds: 1_200_000_000)

        // Evaluate diff on reply (passive)
        var diffResult = await orchestrator.afterSendDiff(appBundleId: request.appBundleId, preSignature: replyRes.elementSignature, policy: policy)

        // Escalate to OCR if passive is weak
        if #available(macOS 10.15, *) {
            let snapMgr = SnapshotManager(axClient: ax)
            if let before = snapMgr.createSnapshot(for: replyRes.elementSignature) {
                try? await Task.sleep(nanoseconds: 400_000_000)
                if let after = snapMgr.createSnapshot(for: replyRes.elementSignature) {
                    let ocr = await OCRManager(disabled: false).performOCRCheck(appBundleId: request.appBundleId, beforeSnapshot: before, afterSnapshot: after)
                    if ocr.changeDetected {
                        let snapDiff = snapMgr.calculateDiff(before: before, after: after)
                        let conf = ConfidenceScorer().calculateConfidence(
                            signature: replyRes.elementSignature,
                            heuristicScore: replyRes.elementSignature.stability,
                            diffEvidence: snapDiff,
                            ocrEvidence: ocr,
                            method: .ocr
                        )
                        diffResult = ElementResult(
                            elementSignature: replyRes.elementSignature,
                            confidence: conf,
                            evidence: Evidence(method: .ocr, heuristicScore: replyRes.elementSignature.stability, diffScore: snapDiff.confidence, ocrChange: true, confidence: conf)
                        )
                    }
                }
            }
        }

        let elements: [String: ElementBrief] = [
            "input": ElementBrief(role: inputRes.elementSignature.role, confidence: inputRes.confidence),
            "send":  ElementBrief(role: sendRes.elementSignature.role,  confidence: sendRes.confidence),
            "reply": ElementBrief(role: replyRes.elementSignature.role, confidence: replyRes.confidence)
        ]

        let actions = SendActions(setValue: setValueOK, pressedSend: pressedSendOK, confirmedInput: confirmedInputOK)
        let diff = DiffBrief(confidence: diffResult.confidence, diffScore: diffResult.evidence.diffScore, ocrChange: diffResult.evidence.ocrChange)
        let success = (setValueOK && (pressedSendOK || confirmedInputOK)) && diff.confidence >= 0.5
        return SendResponse(elements: elements, actions: actions, diff: diff, success: success)
    }
    
    // Error handling
    app.middleware.use(ErrorMiddleware.default(environment: app.environment))
}

// MARK: - Request/Response Models

struct FindElementRequest: Content {
    let appBundleId: String
    let elementType: String
    let policy: Policy?
}

struct AfterSendDiffRequest: Content {
    let appBundleId: String
    let preSignature: ElementSignature
    let policy: Policy?
}

struct ObserveElementRequest: Content {
    let appBundleId: String
    let signature: ElementSignature
    let durationSeconds: Int
    let policy: Policy?
}

struct SnapshotRequest: Content {
    let appBundleId: String
    let signature: ElementSignature
}

struct LearnRequest: Content {
    let signature: ElementSignature
    let pin: Bool
    let decay: Bool
}

struct SendRequest: Content {
    let appBundleId: String
    let text: String
    let policy: Policy?
}

struct ElementResultResponse: Content {
    let elementSignature: ElementSignature
    let confidence: Double
    let evidence: Evidence
    let needsPermissions: [String]
    let success: Bool
    
    init(from result: ElementResult) {
        self.elementSignature = result.elementSignature
        self.confidence = result.confidence
        self.evidence = result.evidence
        self.needsPermissions = result.needsPermissions
        self.success = result.confidence > 0.5 // Basic success threshold
    }
}

struct SnapshotResponse: Content {
    let snapshot: ElementSnapshot?
    let success: Bool
    let error: String?
    
    init(snapshot: ElementSnapshot?, success: Bool, error: String? = nil) {
        self.snapshot = snapshot
        self.success = success
        self.error = error
    }
}

struct LearnResponse: Content {
    let success: Bool
    let action: String
    let signatureId: String
}

struct StatusResponse: Content {
    let permissions: PermissionStatusResponse
    let environment: EnvironmentResponse
    let store: StoreStatsResponse
    let canOperate: Bool
}

struct PermissionStatusResponse: Content {
    let accessibility: Bool
    let screenRecording: Bool
    let needsPrompt: [String]
    let canOperate: Bool
    
    init(from status: PermissionsManager.PermissionStatus) {
        self.accessibility = status.accessibility
        self.screenRecording = status.screenRecording
        self.needsPrompt = status.needsPrompt
        self.canOperate = status.canOperate
    }
}

struct EnvironmentResponse: Content {
    let isInTerminal: Bool
    let isInXcode: Bool
    let isSandboxed: Bool
    let bundleIdentifier: String
    let description: String
    
    init(from env: EnvironmentInfo) {
        self.isInTerminal = env.isInTerminal
        self.isInXcode = env.isInXcode
        self.isSandboxed = env.isSandboxed
        self.bundleIdentifier = env.bundleIdentifier
        self.description = env.description
    }
}

struct StoreStatsResponse: Content {
    let signatureCount: Int
    let evidenceCount: Int
    let averageStability: Double
    let pinnedSignatureCount: Int
    
    init(from stats: StoreStatistics) {
        self.signatureCount = stats.signatureCount
        self.evidenceCount = stats.evidenceCount
        self.averageStability = stats.averageStability
        self.pinnedSignatureCount = stats.pinnedSignatureCount
    }
}

struct SignatureListResponse: Content {
    let signatures: [ElementSignature]
    let count: Int
}

struct ObservationEvent: Content {
    let timestamp: Double
    let notification: String
    let appBundleId: String
    let type: String = "event"
    
    init(from event: AXNotificationEvent) {
        self.timestamp = event.timestamp.timeIntervalSince1970
        self.notification = event.notification
        self.appBundleId = event.appBundleId
    }
}

// MARK: - Content Conformance

extension ElementSignature: Content {}
extension ElementSnapshot: Content {}
extension Evidence: Content {}
extension Policy: Content {}

// MARK: - Additional Response Types

struct ErrorResponse: Content {
    let error: Bool = true
    let message: String
    let code: String?
    
    init(message: String, code: String? = nil) {
        self.message = message
        self.code = code
    }
}

// MARK: - Custom Error Handler

struct UIScoutErrorMiddleware: Middleware {
    func respond(to request: Request, chainingTo next: Responder) -> EventLoopFuture<Response> {
        return next.respond(to: request).flatMapError { error in
            let response: Response
            
            switch error {
            case let abort as AbortError:
                response = Response(status: abort.status)
                try? response.content.encode(ErrorResponse(
                    message: abort.reason,
                    code: abort.status.code.description
                ))
                
            default:
                response = Response(status: .internalServerError)
                try? response.content.encode(ErrorResponse(
                    message: "Internal server error",
                    code: "internal_error"
                ))
            }
            
            return request.eventLoop.makeSucceededFuture(response)
        }
    }
}

// MARK: - Simple Types

struct HealthResponse: Content {
    let status: String
    let timestamp: Double
}

// MARK: - Send Response Models

struct ElementBrief: Content {
    let role: String
    let confidence: Double
}

struct SendActions: Content {
    let setValue: Bool
    let pressedSend: Bool
    let confirmedInput: Bool
}

struct DiffBrief: Content {
    let confidence: Double
    let diffScore: Double
    let ocrChange: Bool
}

struct SendResponse: Content {
    let elements: [String: ElementBrief]
    let actions: SendActions
    let diff: DiffBrief
    let success: Bool
}

// MARK: - AX helpers (service scope)

private func resolveAXByPathHint(axClient: AXClient, signature: ElementSignature) -> AXUIElement? {
    guard let windows = try? axClient.getElementsForApp(signature.appBundleId) else { return nil }
    let windowStep = signature.pathHint.first(where: { $0.hasPrefix("AXWindow[") })
    var targetWindowIndex: Int? = nil
    if let step = windowStep,
       let lb = step.firstIndex(of: "["), let rb = step.firstIndex(of: "]"),
       let idx = Int(step[step.index(after: lb)..<rb]) {
        targetWindowIndex = idx
    }

    for (i, w) in windows.enumerated() {
        if let t = targetWindowIndex, t != i { continue }
        if let el = traverseByPathHint(axClient: axClient, root: w, pathHint: signature.pathHint) {
            return el
        }
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
