import Foundation
import Logging

public class ConfidenceStateMachine {
    private let scorer: ConfidenceScorer
    private let snapshotManager: SnapshotManager
    private let axClient: AXClient
    private let ocrManager: OCRManager
    private let logger = Logger(label: "ui-scout.state-machine")
    
    private var currentState: ElementState = .unknown
    private var stateHistory: [StateTransition] = []
    private let maxHistoryLength = 10
    
    public init(
        scorer: ConfidenceScorer,
        snapshotManager: SnapshotManager,
        axClient: AXClient,
        ocrManager: OCRManager
    ) {
        self.scorer = scorer
        self.snapshotManager = snapshotManager
        self.axClient = axClient
        self.ocrManager = ocrManager
    }
    
    // MARK: - State Machine States
    
    public enum ElementState {
        case unknown
        case highConfidence(ElementSignature, Evidence)
        case mediumConfidence(ElementSignature, Evidence)
        case lowConfidence(ElementSignature, Evidence)
        case ocrVerifying(ElementSignature, Evidence)
        case peeking(ElementSignature, Evidence)
        case failed(String)
        
        var signature: ElementSignature? {
            switch self {
            case .highConfidence(let sig, _), .mediumConfidence(let sig, _), 
                 .lowConfidence(let sig, _), .ocrVerifying(let sig, _), 
                 .peeking(let sig, _):
                return sig
            case .unknown, .failed:
                return nil
            }
        }
        
        var evidence: Evidence? {
            switch self {
            case .highConfidence(_, let ev), .mediumConfidence(_, let ev),
                 .lowConfidence(_, let ev), .ocrVerifying(_, let ev),
                 .peeking(_, let ev):
                return ev
            case .unknown, .failed:
                return nil
            }
        }
        
        var description: String {
            switch self {
            case .unknown: return "unknown"
            case .highConfidence: return "high-confidence"
            case .mediumConfidence: return "medium-confidence"
            case .lowConfidence: return "low-confidence"
            case .ocrVerifying: return "ocr-verifying"
            case .peeking: return "peeking"
            case .failed(let error): return "failed: \(error)"
            }
        }
    }
    
    public struct StateTransition {
        public let fromState: String
        public let toState: String
        public let reason: String
        public let timestamp: Date
        public let confidence: Double?
        
        public init(from: ElementState, to: ElementState, reason: String, confidence: Double? = nil) {
            self.fromState = from.description
            self.toState = to.description
            self.reason = reason
            self.timestamp = Date()
            self.confidence = confidence
        }
    }
    
    // MARK: - Main State Machine Logic
    
    public func processElement(
        signature: ElementSignature,
        policy: Policy,
        historicalEvidence: [Evidence] = []
    ) async -> ElementResult {
        logger.debug("Processing element \(signature.elementType) for \(signature.appBundleId)")
        
        // Start with observe phase
        let observeResult = await observePhase(signature: signature, policy: policy, historicalEvidence: historicalEvidence)
        
        switch observeResult.state {
        case .highConfidence(let sig, let evidence):
            return ElementResult(
                elementSignature: sig,
                confidence: evidence.confidence,
                evidence: evidence
            )
            
        case .mediumConfidence(let sig, let evidence):
            // Escalate to OCR phase
            let ocrResult = await ocrPhase(signature: sig, evidence: evidence, policy: policy)
            return ocrResult
            
        case .lowConfidence(let sig, let evidence):
            // Escalate to peek phase if allowed
            if policy.allowPeek {
                let peekResult = await peekPhase(signature: sig, evidence: evidence, policy: policy)
                return peekResult
            } else {
                return ElementResult(
                    elementSignature: sig,
                    confidence: evidence.confidence,
                    evidence: evidence,
                    needsPermissions: ["peek-disabled"]
                )
            }
            
        case .failed(let error):
            // Return failure with minimal signature
            return ElementResult(
                elementSignature: signature,
                confidence: 0.0,
                evidence: Evidence(
                    method: .passive,
                    heuristicScore: 0.0,
                    diffScore: 0.0,
                    confidence: 0.0
                ),
                needsPermissions: [error]
            )
            
        default:
            return ElementResult(
                elementSignature: signature,
                confidence: 0.0,
                evidence: Evidence(
                    method: .passive,
                    heuristicScore: 0.0,
                    diffScore: 0.0,
                    confidence: 0.0
                )
            )
        }
    }
    
    // MARK: - Observe Phase (Passive)
    
    private func observePhase(
        signature: ElementSignature,
        policy: Policy,
        historicalEvidence: [Evidence]
    ) async -> (state: ElementState, result: ElementResult?) {
        transitionTo(.unknown, reason: "Starting observe phase")
        
        // Create passive snapshot
        guard let snapshot = snapshotManager.createSnapshot(for: signature) else {
            let failedState = ElementState.failed("Cannot create snapshot")
            transitionTo(failedState, reason: "Snapshot creation failed")
            return (failedState, nil)
        }
        
        // Calculate confidence based on passive observation
        let confidence = scorer.calculateConfidence(
            signature: signature,
            heuristicScore: signature.stability,
            historicalEvidence: historicalEvidence,
            method: .passive
        )
        
        let evidence = Evidence(
            method: .passive,
            heuristicScore: signature.stability,
            diffScore: 0.0,
            confidence: confidence
        )
        
        // Determine next state based on confidence
        let nextState: ElementState
        
        if confidence >= 0.9 {
            nextState = .highConfidence(signature, evidence)
            transitionTo(nextState, reason: "High confidence from passive observation", confidence: confidence)
        } else if confidence >= 0.6 {
            nextState = .mediumConfidence(signature, evidence)
            transitionTo(nextState, reason: "Medium confidence, will try OCR", confidence: confidence)
        } else {
            nextState = .lowConfidence(signature, evidence)
            transitionTo(nextState, reason: "Low confidence, needs escalation", confidence: confidence)
        }
        
        return (nextState, nil)
    }
    
    // MARK: - OCR Phase
    
    @available(macOS 10.15, *)
    private func ocrPhase(
        signature: ElementSignature,
        evidence: Evidence,
        policy: Policy
    ) async -> ElementResult {
        transitionTo(.ocrVerifying(signature, evidence), reason: "Escalating to OCR verification")
        
        // Check if OCR is appropriate for this signature
        guard ocrManager.shouldUseOCR(for: signature, confidence: evidence.confidence, policy: policy) else {
            logger.debug("OCR not suitable, escalating to peek")
            if policy.allowPeek {
                return await peekPhase(signature: signature, evidence: evidence, policy: policy)
            } else {
                return ElementResult(
                    elementSignature: signature,
                    confidence: evidence.confidence,
                    evidence: evidence,
                    needsPermissions: ["screen-recording"]
                )
            }
        }
        
        // Create before snapshot
        guard let beforeSnapshot = snapshotManager.createSnapshot(for: signature) else {
            return await fallbackToPeek(signature: signature, evidence: evidence, policy: policy)
        }
        
        // Wait briefly for potential changes
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        
        // Create after snapshot
        guard let afterSnapshot = snapshotManager.createSnapshot(for: signature) else {
            return await fallbackToPeek(signature: signature, evidence: evidence, policy: policy)
        }
        
        // Perform OCR check
        let ocrResult = await ocrManager.performOCRCheck(
            appBundleId: signature.appBundleId,
            beforeSnapshot: beforeSnapshot,
            afterSnapshot: afterSnapshot
        )
        
        // Calculate new confidence with OCR evidence
        let snapshotDiff = snapshotManager.calculateDiff(before: beforeSnapshot, after: afterSnapshot)
        let newConfidence = scorer.calculateConfidence(
            signature: signature,
            heuristicScore: evidence.heuristicScore,
            diffEvidence: snapshotDiff,
            ocrEvidence: ocrResult,
            method: .ocr
        )
        
        let newEvidence = Evidence(
            method: .ocr,
            heuristicScore: evidence.heuristicScore,
            diffScore: snapshotDiff.confidence,
            ocrChange: ocrResult.changeDetected,
            confidence: newConfidence
        )
        
        let finalState: ElementState
        if newConfidence >= 0.8 {
            finalState = .highConfidence(signature, newEvidence)
            transitionTo(finalState, reason: "OCR confirmed high confidence", confidence: newConfidence)
        } else if newConfidence >= 0.6 {
            finalState = .mediumConfidence(signature, newEvidence)
            transitionTo(finalState, reason: "OCR provided medium confidence", confidence: newConfidence)
        } else {
            finalState = .lowConfidence(signature, newEvidence)
            transitionTo(finalState, reason: "OCR could not improve confidence", confidence: newConfidence)
            
            // Escalate to peek if still low confidence
            if policy.allowPeek {
                return await peekPhase(signature: signature, evidence: newEvidence, policy: policy)
            }
        }
        
        return ElementResult(
            elementSignature: signature,
            confidence: newConfidence,
            evidence: newEvidence
        )
    }
    
    // MARK: - Peek Phase (Active)
    
    private func peekPhase(
        signature: ElementSignature,
        evidence: Evidence,
        policy: Policy
    ) async -> ElementResult {
        transitionTo(.peeking(signature, evidence), reason: "Performing polite peek")
        
        // Implement polite peek: briefly activate app, get data, restore previous state
        let peekResult = await performPolitePeek(signature: signature, policy: policy)
        
        let newConfidence = scorer.calculateConfidence(
            signature: signature,
            heuristicScore: peekResult.heuristicScore,
            diffEvidence: peekResult.diff,
            method: .peek
        )
        
        let newEvidence = Evidence(
            method: .peek,
            heuristicScore: peekResult.heuristicScore,
            diffScore: peekResult.diff?.confidence ?? 0.0,
            confidence: newConfidence
        )
        
        let finalState: ElementState
        if newConfidence >= 0.7 {
            finalState = .highConfidence(signature, newEvidence)
            transitionTo(finalState, reason: "Peek provided sufficient confidence", confidence: newConfidence)
        } else {
            finalState = .failed("Could not achieve sufficient confidence after peek")
            transitionTo(finalState, reason: "All escalation methods exhausted", confidence: newConfidence)
        }
        
        return ElementResult(
            elementSignature: signature,
            confidence: newConfidence,
            evidence: newEvidence
        )
    }
    
    // MARK: - Polite Peek Implementation
    
    private struct PeekResult {
        let heuristicScore: Double
        let diff: SnapshotDiff?
        let updatedSignature: ElementSignature?
    }
    
    private func performPolitePeek(
        signature: ElementSignature,
        policy: Policy
    ) async -> PeekResult {
        // Store current active application
        let currentApp = NSWorkspace.shared.frontmostApplication
        
        // Activate target app
        let runningApps = NSWorkspace.shared.runningApplications
        guard let targetApp = runningApps.first(where: { $0.bundleIdentifier == signature.appBundleId }) else {
            return PeekResult(heuristicScore: 0.0, diff: nil, updatedSignature: nil)
        }
        
        // Brief activation
        targetApp.activate(options: .activateIgnoringOtherApps)
        
        // Small delay for UI to stabilize
        let peekDuration = min(policy.maxPeekMs, 100) // Cap at 100ms for politeness
        try? await Task.sleep(nanoseconds: UInt64(peekDuration * 1_000_000))
        
        // Capture data while active
        let beforeSnapshot = snapshotManager.createSnapshot(for: signature)
        
        // Brief wait for any dynamic content
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        
        let afterSnapshot = snapshotManager.createSnapshot(for: signature)
        
        // Restore previous app
        currentApp?.activate(options: .activateIgnoringOtherApps)
        
        // Calculate results
        var diff: SnapshotDiff?
        if let before = beforeSnapshot, let after = afterSnapshot {
            diff = snapshotManager.calculateDiff(before: before, after: after)
        }
        
        let heuristicScore = afterSnapshot != nil ? 0.8 : 0.2 // High score if we got data
        
        return PeekResult(
            heuristicScore: heuristicScore,
            diff: diff,
            updatedSignature: nil
        )
    }
    
    // MARK: - Fallback Methods
    
    @available(macOS 10.15, *)
    private func fallbackToPeek(
        signature: ElementSignature,
        evidence: Evidence,
        policy: Policy
    ) async -> ElementResult {
        if policy.allowPeek {
            return await peekPhase(signature: signature, evidence: evidence, policy: policy)
        } else {
            return ElementResult(
                elementSignature: signature,
                confidence: evidence.confidence,
                evidence: evidence,
                needsPermissions: ["peek-required"]
            )
        }
    }
    
    // MARK: - State Management
    
    private func transitionTo(_ newState: ElementState, reason: String, confidence: Double? = nil) {
        let transition = StateTransition(
            from: currentState,
            to: newState,
            reason: reason,
            confidence: confidence
        )
        
        logger.debug("State transition: \(currentState.description) → \(newState.description) (\(reason))")
        
        stateHistory.append(transition)
        if stateHistory.count > maxHistoryLength {
            stateHistory.removeFirst()
        }
        
        currentState = newState
    }
    
    // MARK: - Public Interface
    
    public var state: ElementState {
        return currentState
    }
    
    public var transitions: [StateTransition] {
        return Array(stateHistory)
    }
    
    public func reset() {
        currentState = .unknown
        stateHistory.removeAll()
    }
}

// MARK: - State Machine Factory

public class StateMachineFactory {
    private let scorer: ConfidenceScorer
    private let snapshotManager: SnapshotManager
    private let axClient: AXClient
    private let ocrManager: OCRManager
    
    public init(
        scorer: ConfidenceScorer,
        snapshotManager: SnapshotManager,
        axClient: AXClient,
        ocrManager: OCRManager
    ) {
        self.scorer = scorer
        self.snapshotManager = snapshotManager
        self.axClient = axClient
        self.ocrManager = ocrManager
    }
    
    public func createStateMachine() -> ConfidenceStateMachine {
        return ConfidenceStateMachine(
            scorer: scorer,
            snapshotManager: snapshotManager,
            axClient: axClient,
            ocrManager: ocrManager
        )
    }
}
