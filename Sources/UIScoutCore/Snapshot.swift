import Foundation
import ApplicationServices
import Logging

public class SnapshotManager {
    private let axClient: AXClient
    private let logger = Logger(label: "ui-scout.snapshot")
    
    public init(axClient: AXClient) {
        self.axClient = axClient
    }
    
    // MARK: - Snapshot Creation
    
    public func createSnapshot(for signature: ElementSignature) -> ElementSnapshot? {
        do {
            let windows = try axClient.getElementsForApp(signature.appBundleId)
            
            // Try to find the element using the signature
            for window in windows {
                if let element = findElementBySignature(window: window, signature: signature) {
                    return createSnapshotFromElement(element)
                }
            }
            
            logger.warning("Could not find element for signature in app \(signature.appBundleId)")
            return nil
            
        } catch {
            logger.error("Failed to create snapshot: \(error)")
            return nil
        }
    }
    
    public func createSnapshotFromElement(_ element: AXUIElement) -> ElementSnapshot {
        let attrs = axClient.getMinimalAttributes(for: element)
        let textLength = axClient.aggregateTextLength(from: element)
        
        return ElementSnapshot(
            elementId: generateElementId(element),
            role: attrs.role ?? "Unknown",
            frame: attrs.frame,
            value: attrs.value,
            childCount: attrs.childCount,
            textLength: textLength
        )
    }
    
    private func findElementBySignature(window: AXUIElement, signature: ElementSignature) -> AXUIElement? {
        func traverse(_ element: AXUIElement, depth: Int = 0) -> AXUIElement? {
            if depth > 15 { return nil }
            
            let attrs = axClient.getMinimalAttributes(for: element)
            
            // Check if this element matches the signature
            if matchesSignature(element: element, attrs: attrs, signature: signature) {
                return element
            }
            
            // Traverse children
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
    
    private func matchesSignature(
        element: AXUIElement,
        attrs: AXClient.MinimalAttributes,
        signature: ElementSignature
    ) -> Bool {
        // Role must match
        guard attrs.role == signature.role else { return false }
        
        // Frame size should be similar (allow for some variance)
        let frameHash = ElementSignature.generateFrameHash(
            width: Int(attrs.frame.width),
            height: Int(attrs.frame.height),
            x: Int(attrs.frame.minX),
            y: Int(attrs.frame.minY)
        )
        
        // For moved but not resized elements, check size similarity
        let sizeMatches = abs(attrs.frame.width - parseFrameWidth(signature.frameHash)) < 50 &&
                         abs(attrs.frame.height - parseFrameHeight(signature.frameHash)) < 50
        
        if frameHash == signature.frameHash || sizeMatches {
            return true
        }
        
        // Check path hint similarity
        let currentPath = axClient.generatePathHint(for: element)
        let pathSimilarity = calculatePathSimilarity(currentPath, signature.pathHint)
        
        return pathSimilarity > 0.7
    }
    
    // MARK: - Diff Calculation
    
    public func calculateDiff(
        before: ElementSnapshot,
        after: ElementSnapshot
    ) -> SnapshotDiff {
        let childCountDelta = after.childCount - before.childCount
        let textLengthDelta = after.textLength - before.textLength
        
        var structuralChanges: [String] = []
        var replyChangeDetected = false
        
        // Detect structural changes
        if childCountDelta != 0 {
            structuralChanges.append("childCount: \(before.childCount) → \(after.childCount)")
        }
        
        if textLengthDelta != 0 {
            structuralChanges.append("textLength: \(before.textLength) → \(after.textLength)")
        }
        
        if before.frame != after.frame {
            structuralChanges.append("frame moved/resized")
        }
        
        if before.value != after.value {
            structuralChanges.append("value changed")
        }
        
        // For reply areas, look for content additions
        if before.role.contains("ScrollArea") || before.role.contains("Group") {
            if childCountDelta > 0 || textLengthDelta > 50 {
                replyChangeDetected = true
            }
        }
        
        // Calculate confidence based on change magnitude
        var confidence = 0.5
        
        if replyChangeDetected {
            confidence += 0.3
        }
        
        if abs(childCountDelta) > 0 {
            confidence += min(0.2, Double(abs(childCountDelta)) * 0.1)
        }
        
        if abs(textLengthDelta) > 0 {
            confidence += min(0.2, Double(abs(textLengthDelta)) / 500.0)
        }
        
        return SnapshotDiff(
            replyChangeDetected: replyChangeDetected,
            childCountDelta: childCountDelta,
            textLengthDelta: textLengthDelta,
            structuralChanges: structuralChanges,
            confidence: min(confidence, 1.0)
        )
    }
    
    // MARK: - Passive Monitoring
    
    public func createPassiveSnapshot(
        for signature: ElementSignature,
        timeout: TimeInterval = 2.0
    ) -> ElementSnapshot? {
        // Try to create snapshot without focusing or activating the app
        return createSnapshot(for: signature)
    }
    
    // MARK: - Helper Methods
    
    private func generateElementId(_ element: AXUIElement) -> String {
        // Generate a stable ID based on element properties
        let pointer = Unmanaged.passUnretained(element).toOpaque()
        return "element-\(Int(bitPattern: pointer))"
    }
    
    private func calculatePathSimilarity(_ path1: [String], _ path2: [String]) -> Double {
        let maxLength = max(path1.count, path2.count)
        guard maxLength > 0 else { return 1.0 }
        
        let commonLength = min(path1.count, path2.count)
        var matches = 0
        
        for i in 0..<commonLength {
            if path1[i] == path2[i] {
                matches += 1
            }
        }
        
        return Double(matches) / Double(maxLength)
    }
    
    private func parseFrameWidth(_ frameHash: String) -> CGFloat {
        let components = frameHash.components(separatedBy: "-")
        for component in components {
            if component.hasPrefix("w"), let width = Int(String(component.dropFirst())) {
                return CGFloat(width)
            }
        }
        return 0
    }
    
    private func parseFrameHeight(_ frameHash: String) -> CGFloat {
        let components = frameHash.components(separatedBy: "-")
        for component in components {
            if component.hasPrefix("h"), let height = Int(String(component.dropFirst())) {
                return CGFloat(height)
            }
        }
        return 0
    }
}

// MARK: - Diff History Manager

public class DiffHistoryManager {
    private var history: [String: [SnapshotDiff]] = [:]
    private let maxHistoryPerSignature = 10
    
    public func addDiff(_ diff: SnapshotDiff, for signatureId: String) {
        if history[signatureId] == nil {
            history[signatureId] = []
        }
        
        history[signatureId]?.append(diff)
        
        // Trim history
        if let count = history[signatureId]?.count, count > maxHistoryPerSignature {
            history[signatureId]?.removeFirst(count - maxHistoryPerSignature)
        }
    }
    
    public func getRecentDiffs(for signatureId: String, limit: Int = 5) -> [SnapshotDiff] {
        guard let diffs = history[signatureId] else { return [] }
        return Array(diffs.suffix(limit))
    }
    
    public func getAverageConfidence(for signatureId: String) -> Double {
        guard let diffs = history[signatureId], !diffs.isEmpty else { return 0.0 }
        let sum = diffs.reduce(0.0) { $0 + $1.confidence }
        return sum / Double(diffs.count)
    }
    
    public func hasRecentActivity(for signatureId: String, within seconds: TimeInterval) -> Bool {
        guard let diffs = history[signatureId] else { return false }
        let cutoff = Date().timeIntervalSince1970 - seconds
        
        return diffs.contains { $0.timestamp > cutoff }
    }
    
    public func clearHistory(for signatureId: String) {
        history.removeValue(forKey: signatureId)
    }
}

// MARK: - Behavioral Pattern Detection

public class BehaviorAnalyzer {
    private let diffHistory: DiffHistoryManager
    
    public init(diffHistory: DiffHistoryManager) {
        self.diffHistory = diffHistory
    }
    
    public struct BehaviorPattern {
        public let patternType: PatternType
        public let confidence: Double
        public let evidence: [String]
        
        public enum PatternType {
            case replyGrowth      // Reply area grows after messages
            case inputClear       // Input clears after send
            case focusShift       // Focus moves after interaction
            case sessionUpdate    // Session list updates
        }
    }
    
    public func detectPattern(
        elementType: ElementSignature.ElementType,
        signatureId: String,
        recentDiffs: [SnapshotDiff]
    ) -> BehaviorPattern? {
        switch elementType {
        case .reply:
            return detectReplyPattern(diffs: recentDiffs)
        case .input:
            return detectInputPattern(diffs: recentDiffs)
        case .session:
            return detectSessionPattern(diffs: recentDiffs)
        }
    }
    
    private func detectReplyPattern(diffs: [SnapshotDiff]) -> BehaviorPattern? {
        let growthEvents = diffs.filter { 
            $0.replyChangeDetected && ($0.childCountDelta > 0 || $0.textLengthDelta > 0)
        }
        
        guard !growthEvents.isEmpty else { return nil }
        
        let avgConfidence = growthEvents.reduce(0.0) { $0 + $1.confidence } / Double(growthEvents.count)
        let evidence = growthEvents.map { "Growth: +\($0.childCountDelta) children, +\($0.textLengthDelta) chars" }
        
        return BehaviorPattern(
            patternType: .replyGrowth,
            confidence: avgConfidence,
            evidence: evidence
        )
    }
    
    private func detectInputPattern(diffs: [SnapshotDiff]) -> BehaviorPattern? {
        let clearEvents = diffs.filter { diff in
            diff.structuralChanges.contains { $0.contains("value changed") }
        }
        
        guard !clearEvents.isEmpty else { return nil }
        
        let avgConfidence = clearEvents.reduce(0.0) { $0 + $1.confidence } / Double(clearEvents.count)
        
        return BehaviorPattern(
            patternType: .inputClear,
            confidence: avgConfidence,
            evidence: ["Input value changes detected"]
        )
    }
    
    private func detectSessionPattern(diffs: [SnapshotDiff]) -> BehaviorPattern? {
        let updateEvents = diffs.filter { $0.childCountDelta != 0 }
        
        guard !updateEvents.isEmpty else { return nil }
        
        let avgConfidence = updateEvents.reduce(0.0) { $0 + $1.confidence } / Double(updateEvents.count)
        
        return BehaviorPattern(
            patternType: .sessionUpdate,
            confidence: avgConfidence,
            evidence: ["Session list changes detected"]
        )
    }
}
