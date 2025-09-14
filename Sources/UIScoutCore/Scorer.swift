import Foundation
import Logging

public class ConfidenceScorer {
    private let logger = Logger(label: "ui-scout.confidence-scorer")
    
    // MARK: - Scoring Weights
    
    private struct ScoringWeights {
        let heuristicWeight: Double
        let diffWeight: Double
        let ocrWeight: Double
        let historyWeight: Double
        let stabilityWeight: Double
        
        static let `default` = ScoringWeights(
            heuristicWeight: 0.3,
            diffWeight: 0.3,
            ocrWeight: 0.2,
            historyWeight: 0.1,
            stabilityWeight: 0.1
        )
        
        static let ocrFocused = ScoringWeights(
            heuristicWeight: 0.2,
            diffWeight: 0.2,
            ocrWeight: 0.4,
            historyWeight: 0.1,
            stabilityWeight: 0.1
        )
    }
    
    public init() {}
    
    // MARK: - Primary Confidence Calculation
    
    public func calculateConfidence(
        signature: ElementSignature,
        heuristicScore: Double,
        diffEvidence: SnapshotDiff? = nil,
        ocrEvidence: OCRResult? = nil,
        historicalEvidence: [Evidence] = [],
        method: Evidence.DetectionMethod = .passive
    ) -> Double {
        let weights = selectWeights(for: method)
        var totalScore = 0.0
        var totalWeight = 0.0
        
        // Heuristic component
        totalScore += heuristicScore * weights.heuristicWeight
        totalWeight += weights.heuristicWeight
        
        // Diff evidence component
        if let diff = diffEvidence {
            let diffScore = scoreDiffEvidence(diff, for: signature.elementType)
            totalScore += diffScore * weights.diffWeight
            totalWeight += weights.diffWeight
        }
        
        // OCR evidence component
        if let ocr = ocrEvidence {
            let ocrScore = scoreOCREvidence(ocr)
            totalScore += ocrScore * weights.ocrWeight
            totalWeight += weights.ocrWeight
        }
        
        // Historical performance component
        if !historicalEvidence.isEmpty {
            let historyScore = scoreHistoricalEvidence(historicalEvidence)
            totalScore += historyScore * weights.historyWeight
            totalWeight += weights.historyWeight
        }
        
        // Signature stability component
        let stabilityScore = signature.stability
        totalScore += stabilityScore * weights.stabilityWeight
        totalWeight += weights.stabilityWeight
        
        // Normalize by actual weights used
        let rawConfidence = totalWeight > 0 ? totalScore / totalWeight : 0.0
        
        // Apply confidence modifiers
        return applyConfidenceModifiers(
            rawConfidence: rawConfidence,
            signature: signature,
            method: method
        )
    }
    
    // MARK: - Evidence Scoring
    
    private func scoreDiffEvidence(_ diff: SnapshotDiff, for elementType: ElementSignature.ElementType) -> Double {
        var score = diff.confidence
        
        // Element-type specific scoring
        switch elementType {
        case .reply:
            // Reply areas should show growth after messages
            if diff.replyChangeDetected {
                score += 0.3
            }
            
            if diff.childCountDelta > 0 {
                score += min(0.2, Double(diff.childCountDelta) * 0.1)
            }
            
            if diff.textLengthDelta > 50 {
                score += min(0.2, Double(diff.textLengthDelta) / 500.0)
            }
            
        case .input:
            // Input areas might clear or change value
            let hasValueChange = diff.structuralChanges.contains { $0.contains("value changed") }
            if hasValueChange {
                score += 0.4
            }
            
        case .session:
            // Session sidebars show list updates
            if abs(diff.childCountDelta) > 0 {
                score += 0.3
            }
        case .send:
            // Send button likely has no diff-based textual changes; keep diff component minimal
            score += 0.0
        }
        
        return min(score, 1.0)
    }
    
    private func scoreOCREvidence(_ ocr: OCRResult) -> Double {
        guard ocr.error == nil else { return 0.0 }
        
        var score = ocr.confidence
        
        // Boost score if we detected meaningful changes
        if ocr.changeDetected {
            score += 0.2
            
            // Additional boost for text additions (likely new content)
            let additions = ocr.textDifferences.filter { $0.type == .addition }
            if !additions.isEmpty {
                score += min(0.3, Double(additions.count) * 0.1)
            }
        }
        
        return min(score, 1.0)
    }
    
    private func scoreHistoricalEvidence(_ evidence: [Evidence]) -> Double {
        guard !evidence.isEmpty else { return 0.0 }
        
        let recentEvidence = evidence.suffix(5) // Last 5 checks
        let avgConfidence = recentEvidence.reduce(0.0) { $0 + $1.confidence } / Double(recentEvidence.count)
        
        // Bonus for consistent high confidence
        let highConfidenceCount = recentEvidence.filter { $0.confidence > 0.8 }.count
        let consistencyBonus = Double(highConfidenceCount) / Double(recentEvidence.count) * 0.2
        
        return min(avgConfidence + consistencyBonus, 1.0)
    }
    
    // MARK: - Confidence Modifiers
    
    private func applyConfidenceModifiers(
        rawConfidence: Double,
        signature: ElementSignature,
        method: Evidence.DetectionMethod
    ) -> Double {
        var confidence = rawConfidence
        
        // Time-based decay (older signatures are less reliable)
        let ageInHours = (Date().timeIntervalSince1970 - signature.lastVerifiedAt) / 3600
        if ageInHours > 24 {
            let decayFactor = max(0.5, 1.0 - (ageInHours - 24) / 168) // Decay over a week
            confidence *= decayFactor
        }
        
        // App-specific modifiers
        confidence = applyAppSpecificModifiers(
            confidence: confidence,
            appBundleId: signature.appBundleId,
            elementType: signature.elementType
        )
        
        // Method-specific adjustments
        switch method {
        case .peek:
            confidence += 0.1 // Peek provides more reliable data
        case .ocr:
            confidence *= 0.9 // OCR can be noisy
        case .passive:
            break // No adjustment
        }
        
        return max(0.0, min(confidence, 1.0))
    }
    
    private func applyAppSpecificModifiers(
        confidence: Double,
        appBundleId: String,
        elementType: ElementSignature.ElementType
    ) -> Double {
        var modifier = 1.0
        
        switch appBundleId {
        case "com.raycast.macos":
            // Raycast has good AX support
            modifier = 1.1
            
        case "com.microsoft.VSCode":
            // VS Code has decent AX support but can be inconsistent
            modifier = 0.95
            
        case "com.openai.chat":
            // Web-based apps have poor AX support
            modifier = 0.7
            
        case "com.google.Chrome", "com.apple.Safari":
            // Web browsers depend on web page AX implementation
            modifier = 0.8
            
        case "com.electron.*":
            // Electron apps have variable AX quality
            modifier = 0.85
            
        default:
            // Native Mac apps generally have better AX support
            modifier = 1.0
        }
        
        // Element-type specific modifiers
        switch elementType {
        case .reply:
            // Reply areas are generally more stable to detect
            modifier *= 1.05
            
        case .input:
            // Input areas are usually well-marked in AX
            modifier *= 1.1
            
        case .session:
            // Session sidebars can be harder to identify
            modifier *= 0.95
        case .send:
            // Send button is typically easy to identify
            modifier *= 1.05
        }
        
        return confidence * modifier
    }
    
    // MARK: - Weight Selection
    
    private func selectWeights(for method: Evidence.DetectionMethod) -> ScoringWeights {
        switch method {
        case .ocr:
            return .ocrFocused
        case .peek, .passive:
            return .default
        }
    }
    
    // MARK: - Confidence Categories
    
    public enum ConfidenceLevel {
        case high      // >= 0.9
        case medium    // 0.6 - 0.89
        case low       // < 0.6
        
        var description: String {
            switch self {
            case .high: return "high"
            case .medium: return "medium"
            case .low: return "low"
            }
        }
        
        var recommendedAction: String {
            switch self {
            case .high:
                return "Use cached signature with passive monitoring"
            case .medium:
                return "Consider OCR confirmation or escalate to peek"
            case .low:
                return "Perform polite peek or re-discover"
            }
        }
    }
    
    public func categorizeConfidence(_ confidence: Double) -> ConfidenceLevel {
        if confidence >= 0.9 {
            return .high
        } else if confidence >= 0.6 {
            return .medium
        } else {
            return .low
        }
    }
    
    // MARK: - Confidence Explanation
    
    public func explainConfidence(
        signature: ElementSignature,
        heuristicScore: Double,
        diffEvidence: SnapshotDiff? = nil,
        ocrEvidence: OCRResult? = nil,
        historicalEvidence: [Evidence] = [],
        finalConfidence: Double
    ) -> ConfidenceExplanation {
        var components: [String] = []
        let weights = ScoringWeights.default
        
        components.append("Heuristic: \(String(format: "%.2f", heuristicScore)) (weight: \(weights.heuristicWeight))")
        
        if let diff = diffEvidence {
            let diffScore = scoreDiffEvidence(diff, for: signature.elementType)
            components.append("Diff: \(String(format: "%.2f", diffScore)) (weight: \(weights.diffWeight))")
        }
        
        if let ocr = ocrEvidence {
            let ocrScore = scoreOCREvidence(ocr)
            components.append("OCR: \(String(format: "%.2f", ocrScore)) (weight: \(weights.ocrWeight))")
        }
        
        if !historicalEvidence.isEmpty {
            let historyScore = scoreHistoricalEvidence(historicalEvidence)
            components.append("History: \(String(format: "%.2f", historyScore)) (weight: \(weights.historyWeight))")
        }
        
        components.append("Stability: \(String(format: "%.2f", signature.stability)) (weight: \(weights.stabilityWeight))")
        
        let level = categorizeConfidence(finalConfidence)
        
        return ConfidenceExplanation(
            finalConfidence: finalConfidence,
            level: level,
            components: components,
            recommendedAction: level.recommendedAction
        )
    }
}

// MARK: - Confidence Explanation

public struct ConfidenceExplanation {
    public let finalConfidence: Double
    public let level: ConfidenceScorer.ConfidenceLevel
    public let components: [String]
    public let recommendedAction: String
    
    public var description: String {
        var desc = "Confidence: \(String(format: "%.2f", finalConfidence)) (\(level.description))\n"
        desc += "Components:\n"
        for component in components {
            desc += "  - \(component)\n"
        }
        desc += "Recommended action: \(recommendedAction)"
        return desc
    }
}

// MARK: - Confidence Tracker

public class ConfidenceTracker {
    private var confidenceHistory: [String: [(Double, Date)]] = [:]
    private let maxHistoryPerSignature = 20
    
    public func recordConfidence(_ confidence: Double, for signatureId: String) {
        if confidenceHistory[signatureId] == nil {
            confidenceHistory[signatureId] = []
        }
        
        confidenceHistory[signatureId]?.append((confidence, Date()))
        
        // Trim history
        if let count = confidenceHistory[signatureId]?.count, count > maxHistoryPerSignature {
            confidenceHistory[signatureId]?.removeFirst(count - maxHistoryPerSignature)
        }
    }
    
    public func getRecentConfidence(for signatureId: String, limit: Int = 5) -> [Double] {
        guard let history = confidenceHistory[signatureId] else { return [] }
        return Array(history.suffix(limit).map { $0.0 })
    }
    
    public func getConfidenceTrend(for signatureId: String) -> ConfidenceTrend {
        guard let history = confidenceHistory[signatureId], history.count >= 3 else {
            return .insufficient
        }
        
        let recent = Array(history.suffix(5))
        let firstHalf = Array(recent.prefix(recent.count / 2))
        let secondHalf = Array(recent.suffix(recent.count - recent.count / 2))
        
        let firstAvg = firstHalf.reduce(0.0) { $0 + $1.0 } / Double(firstHalf.count)
        let secondAvg = secondHalf.reduce(0.0) { $0 + $1.0 } / Double(secondHalf.count)
        
        let diff = secondAvg - firstAvg
        
        if diff > 0.1 {
            return .improving
        } else if diff < -0.1 {
            return .declining
        } else {
            return .stable
        }
    }
    
    public enum ConfidenceTrend {
        case improving
        case stable
        case declining
        case insufficient
        
        var description: String {
            switch self {
            case .improving: return "improving"
            case .stable: return "stable"
            case .declining: return "declining"
            case .insufficient: return "insufficient data"
            }
        }
    }
}
