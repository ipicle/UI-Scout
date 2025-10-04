import Foundation
import ApplicationServices
import AppKit
import Logging

public class UIScoutOrchestrator {
    private let axClient: AXClient
    private let elementFinder: ElementFinder
    private let snapshotManager: SnapshotManager
    private let scorer: ConfidenceScorer
    private let ocrManager: OCRManager
    private let stateMachineFactory: StateMachineFactory
    private let store: SignatureStore
    private let rateLimiter: RateLimiter
    private let logger = Logger(label: "ui-scout.orchestrator")
    
    private var activeObservers: [String: AXEventObserver] = [:]
    private var lastPeekTimes: [String: Date] = [:]
    
    public init(
        axClient: AXClient,
        elementFinder: ElementFinder,
        snapshotManager: SnapshotManager,
        scorer: ConfidenceScorer,
        ocrManager: OCRManager,
        stateMachineFactory: StateMachineFactory,
        store: SignatureStore,
        rateLimiter: RateLimiter
    ) {
        self.axClient = axClient
        self.elementFinder = elementFinder
        self.snapshotManager = snapshotManager
        self.scorer = scorer
        self.ocrManager = ocrManager
        self.stateMachineFactory = stateMachineFactory
        self.store = store
        self.rateLimiter = rateLimiter
    }
    
    // MARK: - Primary API Methods
    
    public func findElement(
        appBundleId: String,
        elementType: ElementSignature.ElementType,
        policy: Policy = .default
    ) async -> ElementResult {
        logger.info("Finding \(elementType) element for \(appBundleId)")
        
        // Check rate limiting
        let rateLimitKey = "\(appBundleId)-\(elementType.rawValue)"
        if !rateLimiter.allowRequest(key: rateLimitKey) {
            logger.warning("Rate limited request for \(rateLimitKey)")
            return createRateLimitedResult(appBundleId: appBundleId, elementType: elementType)
        }
        
        // Try cached signature first
        if let cachedSignature = await store.getBestSignature(
            appBundleId: appBundleId,
            elementType: elementType
        ) {
            logger.debug("Found cached signature with stability \(cachedSignature.stability)")
            
            // Check if cached signature meets confidence threshold
            let historicalEvidence = await store.getRecentEvidence(for: cachedSignature, limit: 5)
            
            let stateMachine = stateMachineFactory.createStateMachine()
            let result = await stateMachine.processElement(
                signature: cachedSignature,
                policy: policy,
                historicalEvidence: historicalEvidence
            )
            
            // Update signature stability based on result
            await updateSignatureStability(signature: cachedSignature, confidence: result.confidence)
            
            if result.confidence >= policy.minConfidence {
                logger.info("Cached signature sufficient: confidence \(result.confidence)")
                return result
            } else {
                logger.debug("Cached signature insufficient, will rediscover")
            }
        }
        
        // Perform fresh discovery
        logger.debug("Performing fresh discovery")
        return await performDiscovery(
            appBundleId: appBundleId,
            elementType: elementType,
            policy: policy
        )
    }
    
    public func afterSendDiff(
        appBundleId: String,
        preSignature: ElementSignature,
        policy: Policy = .default
    ) async -> ElementResult {
        logger.info("Checking after-send diff for \(appBundleId)")
        
        let rateLimitKey = "\(appBundleId)-after-send"
        if !rateLimiter.allowRequest(key: rateLimitKey) {
            return createRateLimitedResult(appBundleId: appBundleId, elementType: preSignature.elementType)
        }
        
        // Try passive diff first
        if let passiveResult = await tryPassiveDiff(signature: preSignature, policy: policy) {
            logger.debug("Passive diff successful")
            await store.recordEvidence(passiveResult.evidence, for: preSignature)
            return passiveResult
        }
        
        // Try OCR confirmation if available
        if #available(macOS 10.15, *) {
            if let ocrResult = await tryOCRDiff(signature: preSignature, policy: policy) {
                logger.debug("OCR diff successful")
                await store.recordEvidence(ocrResult.evidence, for: preSignature)
                return ocrResult
            }
        }
        
        // Fall back to polite peek if allowed
        if policy.allowPeek && canPerformPeek(appBundleId: appBundleId, policy: policy) {
            logger.debug("Performing polite peek for after-send diff")
            let result = await performPeekDiff(signature: preSignature, policy: policy)
            await store.recordEvidence(result.evidence, for: preSignature)
            return result
        }
        
        // Return failure if no method worked
        return ElementResult(
            elementSignature: preSignature,
            confidence: 0.0,
            evidence: Evidence(
                method: .passive,
                heuristicScore: 0.0,
                diffScore: 0.0,
                confidence: 0.0
            ),
            needsPermissions: policy.allowPeek ? [] : ["peek-required"]
        )
    }
    
    public func observeElement(
        appBundleId: String,
        signature: ElementSignature,
        durationSeconds: Int,
        policy: Policy = .default
    ) async -> AXEventStream {
        logger.info("Starting observation of \(signature.elementType) for \(durationSeconds)s")
        
        let eventStream = AXEventStream(maxEvents: 50)
        let observerKey = "\(appBundleId)-\(signature.elementType.rawValue)"
        
        // Find the actual element
        do {
            let windows = try axClient.getElementsForApp(appBundleId)
            for window in windows {
                if let element = findElementBySignature(window: window, signature: signature) {
                    try await eventStream.startStream(
                        appBundleId: appBundleId,
                        element: element,
                        notifications: [
                            kAXValueChangedNotification,
                            String.axChildrenChanged,
                            kAXFocusedUIElementChangedNotification
                        ]
                    )
                    break
                }
            }
            
            // Stop observation after duration
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(durationSeconds)) {
                eventStream.stopStream(appBundleId: appBundleId)
            }
            
        } catch {
            logger.error("Failed to start observation: \(error)")
        }
        
        return eventStream
    }
    
    public func captureSnapshot(
        appBundleId: String,
        signature: ElementSignature
    ) -> ElementSnapshot? {
        return snapshotManager.createSnapshot(for: signature)
    }

    @MainActor
    public func writeText(
        appBundleId: String,
        signature: ElementSignature,
        text: String
    ) async -> Bool {
        do {
            let windows = try axClient.getElementsForApp(appBundleId)
            for window in windows {
                if let element = findElementBySignature(window: window, signature: signature) {
                    try axClient.focusElement(element)
                    try axClient.setAttribute(element, kAXValueAttribute, value: text as CFString)
                    logger.info("Wrote text to \(signature.elementType.rawValue) for \(appBundleId)")
                    return true
                }
            }
            logger.warning("Could not resolve element for writeText: \(signature.elementType.rawValue)")
        } catch {
            logger.error("writeText failed: \(error.localizedDescription)")
        }
        return false
    }
    
    public func learnSignature(
        signature: ElementSignature,
        pin: Bool = false,
        decay: Bool = false
    ) async {
        if pin {
            await store.pinSignature(signature)
            logger.info("Pinned signature for \(signature.appBundleId)/\(signature.elementType)")
        } else if decay {
            await store.decaySignature(signature)
            logger.info("Decayed signature for \(signature.appBundleId)/\(signature.elementType)")
        } else {
            await store.storeSignature(signature)
            logger.info("Stored signature for \(signature.appBundleId)/\(signature.elementType)")
        }
    }
    
    // MARK: - Discovery Implementation
    
    private func performDiscovery(
        appBundleId: String,
        elementType: ElementSignature.ElementType,
        policy: Policy
    ) async -> ElementResult {
        do {
            // Find candidates using heuristics
            let candidates = try elementFinder.findCandidates(
                appBundleId: appBundleId,
                elementType: elementType
            )
            
            guard !candidates.isEmpty else {
                logger.warning("No candidates found for \(elementType)")
                return createFailureResult(
                    appBundleId: appBundleId,
                    elementType: elementType,
                    reason: "No candidates found"
                )
            }
            
            logger.debug("Found \(candidates.count) candidates, best score: \(candidates[0].score)")
            
            // Take the best candidate
            let bestCandidate = candidates[0]
            
            // Convert to signature
            let signature = bestCandidate.toElementSignature(axClient: axClient)
            
            // Process through state machine
            let stateMachine = stateMachineFactory.createStateMachine()
            let result = await stateMachine.processElement(
                signature: signature,
                policy: policy,
                historicalEvidence: []
            )
            
            // Store the discovered signature
            await store.storeSignature(signature)
            await store.recordEvidence(result.evidence, for: signature)
            
            return result
            
        } catch {
            logger.error("Discovery failed: \(error)")
            return createFailureResult(
                appBundleId: appBundleId,
                elementType: elementType,
                reason: error.localizedDescription
            )
        }
    }
    
    // MARK: - Diff Strategies
    
    private func tryPassiveDiff(
        signature: ElementSignature,
        policy: Policy
    ) async -> ElementResult? {
        guard let beforeSnapshot = snapshotManager.createSnapshot(for: signature) else {
            return nil
        }
        
        // Wait briefly for changes
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
        
        guard let afterSnapshot = snapshotManager.createSnapshot(for: signature) else {
            return nil
        }
        
        let diff = snapshotManager.calculateDiff(before: beforeSnapshot, after: afterSnapshot)
        
        // Check if we detected meaningful changes
        if diff.replyChangeDetected || diff.confidence > 0.6 {
            let confidence = scorer.calculateConfidence(
                signature: signature,
                heuristicScore: signature.stability,
                diffEvidence: diff,
                method: .passive
            )
            
            let evidence = Evidence(
                method: .passive,
                heuristicScore: signature.stability,
                diffScore: diff.confidence,
                confidence: confidence
            )
            
            return ElementResult(
                elementSignature: signature,
                confidence: confidence,
                evidence: evidence
            )
        }
        
        return nil
    }
    
    @available(macOS 10.15, *)
    private func tryOCRDiff(
        signature: ElementSignature,
        policy: Policy
    ) async -> ElementResult? {
        guard ocrManager.shouldUseOCR(
            for: signature,
            confidence: signature.stability,
            policy: policy
        ) else {
            return nil
        }
        
        guard let beforeSnapshot = snapshotManager.createSnapshot(for: signature) else {
            return nil
        }
        
        // Brief wait
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        
        guard let afterSnapshot = snapshotManager.createSnapshot(for: signature) else {
            return nil
        }
        
        let ocrResult = await ocrManager.performOCRCheck(
            appBundleId: signature.appBundleId,
            beforeSnapshot: beforeSnapshot,
            afterSnapshot: afterSnapshot
        )
        
        if ocrResult.changeDetected {
            let diff = snapshotManager.calculateDiff(before: beforeSnapshot, after: afterSnapshot)
            let confidence = scorer.calculateConfidence(
                signature: signature,
                heuristicScore: signature.stability,
                diffEvidence: diff,
                ocrEvidence: ocrResult,
                method: .ocr
            )
            
            let evidence = Evidence(
                method: .ocr,
                heuristicScore: signature.stability,
                diffScore: diff.confidence,
                ocrChange: true,
                confidence: confidence
            )
            
            return ElementResult(
                elementSignature: signature,
                confidence: confidence,
                evidence: evidence
            )
        }
        
        return nil
    }
    
    private func performPeekDiff(
        signature: ElementSignature,
        policy: Policy
    ) async -> ElementResult {
        // Record peek time for rate limiting
        lastPeekTimes[signature.appBundleId] = Date()
        
        let stateMachine = stateMachineFactory.createStateMachine()
        return await stateMachine.processElement(
            signature: signature,
            policy: policy,
            historicalEvidence: []
        )
    }
    
    // MARK: - Helper Methods
    
    private func canPerformPeek(appBundleId: String, policy: Policy) -> Bool {
        if let lastPeek = lastPeekTimes[appBundleId] {
            let timeSinceLastPeek = Date().timeIntervalSince(lastPeek)
            return timeSinceLastPeek >= TimeInterval(policy.rateLimitPeekSeconds)
        }
        return true
    }
    
    private func findElementBySignature(
        window: AXUIElement,
        signature: ElementSignature
    ) -> AXUIElement? {
        // Simple signature matching - in a real implementation,
        // this would use more sophisticated matching logic
        func traverse(_ element: AXUIElement, depth: Int = 0) -> AXUIElement? {
            if depth > 10 { return nil }
            
            let attrs = axClient.getMinimalAttributes(for: element)
            
            // Basic role matching
            if attrs.role == signature.role {
                return element
            }
            
            // Check children
            if let children = try? axClient.getAttribute(element, kAXChildrenAttribute, as: [AXUIElement].self) {
                for child in children {
                    if let found = traverse(child, depth: depth + 1) {
                        return found
                    }
                }
            }
            
            return nil
        }
        
        return traverse(window)
    }
    
    private func updateSignatureStability(
        signature: ElementSignature,
        confidence: Double
    ) async {
        // Simple EWMA update
        let alpha = 0.3 // Learning rate
        let newStability = alpha * confidence + (1 - alpha) * signature.stability
        
        var updatedSignature = signature
        updatedSignature.stability = newStability
        updatedSignature.lastVerifiedAt = Date().timeIntervalSince1970
        
        await store.updateSignature(updatedSignature)
    }
    
    private func createRateLimitedResult(
        appBundleId: String,
        elementType: ElementSignature.ElementType
    ) -> ElementResult {
        let signature = ElementSignature(
            appBundleId: appBundleId,
            elementType: elementType,
            role: "Unknown",
            frameHash: "rate-limited"
        )
        
        return ElementResult(
            elementSignature: signature,
            confidence: 0.0,
            evidence: Evidence(
                method: .passive,
                heuristicScore: 0.0,
                diffScore: 0.0,
                confidence: 0.0
            ),
            needsPermissions: ["rate-limited"]
        )
    }
    
    private func createFailureResult(
        appBundleId: String,
        elementType: ElementSignature.ElementType,
        reason: String
    ) -> ElementResult {
        let signature = ElementSignature(
            appBundleId: appBundleId,
            elementType: elementType,
            role: "Unknown",
            frameHash: "failed"
        )
        
        return ElementResult(
            elementSignature: signature,
            confidence: 0.0,
            evidence: Evidence(
                method: .passive,
                heuristicScore: 0.0,
                diffScore: 0.0,
                confidence: 0.0
            ),
            needsPermissions: [reason]
        )
    }
    
    // MARK: - Cleanup
    
    public func cleanup() {
        for (appBundleId, observer) in activeObservers {
            observer.stopAllObserving(appBundleId: appBundleId)
        }
        activeObservers.removeAll()
    }
}

// MARK: - Rate Limiter

public class RateLimiter {
    private var requestTimes: [String: [Date]] = [:]
    private let maxRequestsPerWindow: Int
    private let windowDuration: TimeInterval
    private let queue = DispatchQueue(label: "rate-limiter")
    
    public init(maxRequestsPerWindow: Int = 10, windowDuration: TimeInterval = 60.0) {
        self.maxRequestsPerWindow = maxRequestsPerWindow
        self.windowDuration = windowDuration
    }
    
    public func allowRequest(key: String) -> Bool {
        return queue.sync {
            let now = Date()
            let cutoff = now.addingTimeInterval(-windowDuration)
            
            // Clean old requests
            if var times = requestTimes[key] {
                times = times.filter { $0 > cutoff }
                requestTimes[key] = times
                
                // Check if we can add a new request
                if times.count < maxRequestsPerWindow {
                    requestTimes[key]?.append(now)
                    return true
                } else {
                    return false
                }
            } else {
                // First request for this key
                requestTimes[key] = [now]
                return true
            }
        }
    }
    
    public func resetKey(_ key: String) {
        queue.async(flags: .barrier) {
            self.requestTimes.removeValue(forKey: key)
        }
    }
    
    public func getRequestCount(for key: String) -> Int {
        return queue.sync {
            let now = Date()
            let cutoff = now.addingTimeInterval(-windowDuration)
            
            if let times = requestTimes[key] {
                return times.filter { $0 > cutoff }.count
            }
            return 0
        }
    }
}
