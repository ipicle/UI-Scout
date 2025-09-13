import Foundation
import Vision
import CoreGraphics
import AppKit
import Logging

@available(macOS 10.15, *)
public class OCRConfirmation {
    private let logger = Logger(label: "ui-scout.ocr")
    
    public init() {}
    
    // MARK: - OCR Change Detection
    
    public func confirmChange(
        appBundleId: String,
        beforeSnapshot: ElementSnapshot,
        afterSnapshot: ElementSnapshot,
        windowBounds: CGRect? = nil
    ) async -> OCRResult {
        do {
            let bounds = windowBounds ?? beforeSnapshot.frame
            
            // Capture before and after images
            guard let beforeImage = await captureScreenRegion(bounds),
                  let afterImage = await captureScreenRegion(bounds) else {
                return OCRResult(
                    changeDetected: false,
                    confidence: 0.0,
                    textDifferences: [],
                    error: "Failed to capture screen regions"
                )
            }
            
            // Extract text from both images
            let beforeText = await extractText(from: beforeImage)
            let afterText = await extractText(from: afterImage)
            
            // Compare text content
            let differences = calculateTextDifferences(before: beforeText, after: afterText)
            let changeDetected = !differences.isEmpty
            
            // Calculate confidence based on text changes and image differences
            let confidence = calculateOCRConfidence(
                beforeText: beforeText,
                afterText: afterText,
                differences: differences,
                snapshotDiff: SnapshotDiff(
                    replyChangeDetected: afterSnapshot.childCount > beforeSnapshot.childCount,
                    childCountDelta: afterSnapshot.childCount - beforeSnapshot.childCount,
                    textLengthDelta: afterSnapshot.textLength - beforeSnapshot.textLength,
                    confidence: 0.5
                )
            )
            
            return OCRResult(
                changeDetected: changeDetected,
                confidence: confidence,
                textDifferences: differences,
                beforeText: beforeText,
                afterText: afterText
            )
            
        } catch {
            logger.error("OCR confirmation failed: \(error)")
            return OCRResult(
                changeDetected: false,
                confidence: 0.0,
                textDifferences: [],
                error: error.localizedDescription
            )
        }
    }
    
    // MARK: - Quick OCR Check
    
    public func quickTextCheck(
        appBundleId: String,
        region: CGRect,
        expectedChanges: [String] = []
    ) async -> OCRResult {
        do {
            // Single capture and text extraction
            guard let image = await captureScreenRegion(region) else {
                return OCRResult(
                    changeDetected: false,
                    confidence: 0.0,
                    textDifferences: [],
                    error: "Failed to capture screen region"
                )
            }
            
            let extractedText = await extractText(from: image)
            
            // Check for expected changes if provided
            var changeDetected = false
            var confidence = 0.5
            
            if !expectedChanges.isEmpty {
                let foundExpectedChanges = expectedChanges.filter { expected in
                    extractedText.contains(expected)
                }
                
                changeDetected = !foundExpectedChanges.isEmpty
                confidence = Double(foundExpectedChanges.count) / Double(expectedChanges.count)
            } else {
                // Generic text content detection
                changeDetected = extractedText.count > 10 // Has substantial text
                confidence = min(Double(extractedText.count) / 100.0, 1.0)
            }
            
            return OCRResult(
                changeDetected: changeDetected,
                confidence: confidence,
                textDifferences: [],
                afterText: extractedText
            )
            
        } catch {
            logger.error("Quick OCR check failed: \(error)")
            return OCRResult(
                changeDetected: false,
                confidence: 0.0,
                textDifferences: [],
                error: error.localizedDescription
            )
        }
    }
    
    // MARK: - Screen Capture
    
    private func captureScreenRegion(_ bounds: CGRect) async -> CGImage? {
        // Ensure we're on the main thread for screen capture
        return await MainActor.run {
            guard let displayID = CGMainDisplayID() as CGDirectDisplayID? else {
                return nil
            }
            
            // Create a screenshot of the specified region
            let image = CGDisplayCreateImage(displayID, rect: bounds)
            return image
        }
    }
    
    // MARK: - Text Extraction
    
    private func extractText(from image: CGImage) async -> [String] {
        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error = error {
                    self.logger.error("Vision text recognition failed: \(error)")
                    continuation.resume(returning: [])
                    return
                }
                
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let recognizedStrings = observations.compactMap { observation in
                    observation.topCandidates(1).first?.string
                }
                
                continuation.resume(returning: recognizedStrings)
            }
            
            // Configure for better UI text recognition
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.customWords = [
                // Common UI text that might be missed
                "Send", "Reply", "Submit", "Post", "Enter",
                "Assistant", "User", "AI", "Bot", "Chat"
            ]
            
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            
            do {
                try handler.perform([request])
            } catch {
                self.logger.error("Failed to perform Vision request: \(error)")
                continuation.resume(returning: [])
            }
        }
    }
    
    // MARK: - Text Comparison
    
    private func calculateTextDifferences(
        before: [String],
        after: [String]
    ) -> [TextDifference] {
        var differences: [TextDifference] = []
        
        // Simple diff - find new text in after that wasn't in before
        let beforeSet = Set(before)
        let afterSet = Set(after)
        
        let addedText = afterSet.subtracting(beforeSet)
        let removedText = beforeSet.subtracting(afterSet)
        
        for added in addedText {
            differences.append(TextDifference(
                type: .addition,
                text: added,
                confidence: 0.8
            ))
        }
        
        for removed in removedText {
            differences.append(TextDifference(
                type: .removal,
                text: removed,
                confidence: 0.8
            ))
        }
        
        // Look for text length changes that indicate content updates
        let beforeLength = before.joined().count
        let afterLength = after.joined().count
        
        if abs(afterLength - beforeLength) > 20 {
            differences.append(TextDifference(
                type: .lengthChange,
                text: "Content length: \(beforeLength) → \(afterLength)",
                confidence: 0.6
            ))
        }
        
        return differences
    }
    
    private func calculateOCRConfidence(
        beforeText: [String],
        afterText: [String],
        differences: [TextDifference],
        snapshotDiff: SnapshotDiff
    ) -> Double {
        var confidence = 0.0
        
        // Base confidence from text extraction quality
        let totalTextLength = beforeText.joined().count + afterText.joined().count
        if totalTextLength > 0 {
            confidence += min(0.3, Double(totalTextLength) / 200.0)
        }
        
        // Confidence from detected differences
        if !differences.isEmpty {
            let avgDiffConfidence = differences.reduce(0.0) { $0 + $1.confidence } / Double(differences.count)
            confidence += avgDiffConfidence * 0.4
        }
        
        // Correlation with snapshot diff
        if snapshotDiff.replyChangeDetected && !differences.isEmpty {
            confidence += 0.3
        }
        
        // Penalty for very short or no text (may be unreliable)
        if totalTextLength < 10 {
            confidence *= 0.5
        }
        
        return min(confidence, 1.0)
    }
}

// MARK: - OCR Result Types

public struct OCRResult {
    public let changeDetected: Bool
    public let confidence: Double
    public let textDifferences: [TextDifference]
    public let beforeText: [String]?
    public let afterText: [String]?
    public let error: String?
    
    public init(
        changeDetected: Bool,
        confidence: Double,
        textDifferences: [TextDifference],
        beforeText: [String]? = nil,
        afterText: [String]? = nil,
        error: String? = nil
    ) {
        self.changeDetected = changeDetected
        self.confidence = confidence
        self.textDifferences = textDifferences
        self.beforeText = beforeText
        self.afterText = afterText
        self.error = error
    }
}

public struct TextDifference {
    public let type: DifferenceType
    public let text: String
    public let confidence: Double
    
    public enum DifferenceType {
        case addition
        case removal
        case lengthChange
        case modification
    }
    
    public init(type: DifferenceType, text: String, confidence: Double) {
        self.type = type
        self.text = text
        self.confidence = confidence
    }
}

// MARK: - OCR Manager

@available(macOS 10.15, *)
public class OCRManager {
    private let confirmation: OCRConfirmation
    private let logger = Logger(label: "ui-scout.ocr-manager")
    private var recentChecks: [String: Date] = [:]
    private let rateLimitInterval: TimeInterval = 1.0 // Minimum time between OCR checks
    
    public init() {
        self.confirmation = OCRConfirmation()
    }
    
    public func shouldUseOCR(
        for signature: ElementSignature,
        confidence: Double,
        policy: Policy
    ) -> Bool {
        // Don't use OCR if confidence is too high or too low
        guard confidence >= 0.3 && confidence < 0.9 else {
            return false
        }
        
        // Rate limiting
        let key = "\(signature.appBundleId)-\(signature.elementType.rawValue)"
        if let lastCheck = recentChecks[key],
           Date().timeIntervalSince(lastCheck) < rateLimitInterval {
            return false
        }
        
        // App-specific OCR suitability
        return isOCRSuitable(for: signature.appBundleId)
    }
    
    private func isOCRSuitable(for appBundleId: String) -> Bool {
        // OCR works better with native apps than web-based ones
        switch appBundleId {
        case "com.raycast.macos":
            return true
        case "com.microsoft.VSCode":
            return true
        case "com.apple.dt.Xcode":
            return true
        case "com.openai.chat":
            return false // Web-based, text likely not OCR-readable
        case "com.google.Chrome", "com.apple.Safari":
            return false // Web-based content
        default:
            return true // Default to allowing OCR
        }
    }
    
    public func performOCRCheck(
        appBundleId: String,
        beforeSnapshot: ElementSnapshot,
        afterSnapshot: ElementSnapshot
    ) async -> OCRResult {
        let key = "\(appBundleId)-\(beforeSnapshot.elementId)"
        recentChecks[key] = Date()
        
        return await confirmation.confirmChange(
            appBundleId: appBundleId,
            beforeSnapshot: beforeSnapshot,
            afterSnapshot: afterSnapshot
        )
    }
    
    public func clearRateLimit(for appBundleId: String, elementType: ElementSignature.ElementType) {
        let key = "\(appBundleId)-\(elementType.rawValue)"
        recentChecks.removeValue(forKey: key)
    }
}

// MARK: - Extensions

extension OCRResult: CustomStringConvertible {
    public var description: String {
        var desc = "OCR Result: change=\(changeDetected), confidence=\(String(format: "%.2f", confidence))"
        
        if let error = error {
            desc += ", error=\(error)"
        }
        
        if !textDifferences.isEmpty {
            desc += ", differences=\(textDifferences.count)"
        }
        
        return desc
    }
}

extension TextDifference: CustomStringConvertible {
    public var description: String {
        return "\(type): \(text) (confidence: \(String(format: "%.2f", confidence)))"
    }
}
