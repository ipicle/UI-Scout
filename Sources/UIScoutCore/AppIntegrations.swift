import Foundation
import Logging

// MARK: - App-Specific Integration Hints

public class AppIntegrations {
    private let logger = Logger(label: "ui-scout.integrations")
    
    public init() {}
    
    // MARK: - Integration Registry
    
    private static let knownApps: [String: AppIntegration] = [
        "com.raycast.macos": RaycastIntegration(),
        "com.microsoft.VSCode": VSCodeIntegration(),
        "com.openai.chat": ChatGPTIntegration(),
        "com.apple.dt.Xcode": XcodeIntegration(),
        "com.electron.replit": ElectronIntegration(appName: "Replit"),
        "com.figma.Desktop": ElectronIntegration(appName: "Figma"),
        "com.tinyspeck.slackmacgap": ElectronIntegration(appName: "Slack"),
        "com.hnc.Discord": ElectronIntegration(appName: "Discord")
    ]
    
    public func getIntegration(for appBundleId: String) -> AppIntegration? {
        // Direct lookup first
        if let integration = Self.knownApps[appBundleId] {
            logger.debug("Found specific integration for \(appBundleId)")
            return integration
        }
        
        // Pattern matching for common frameworks
        if appBundleId.contains("electron") {
            logger.debug("Using Electron integration for \(appBundleId)")
            return ElectronIntegration(appName: "Electron App")
        }
        
        // Web browsers
        if appBundleId.contains("chrome") || appBundleId.contains("safari") || appBundleId.contains("firefox") {
            logger.debug("Using Web Browser integration for \(appBundleId)")
            return WebBrowserIntegration()
        }
        
        // Default to generic native app integration
        logger.debug("Using default native app integration for \(appBundleId)")
        return NativeAppIntegration()
    }
    
    public func getAllKnownApps() -> [String] {
        return Array(Self.knownApps.keys)
    }
}

// MARK: - Base Integration Protocol

public protocol AppIntegration {
    var appName: String { get }
    var accessibilityQuality: AccessibilityQuality { get }
    var commonRoles: [String: ElementSignature.ElementType] { get }
    var behaviorHints: [BehaviorHint] { get }
    
    func getElementHints(for elementType: ElementSignature.ElementType) -> ElementHints
    func adjustConfidenceScore(_ baseScore: Double, for elementType: ElementSignature.ElementType) -> Double
    func getRecommendedPolicy() -> Policy
}

public enum AccessibilityQuality {
    case excellent  // Native macOS apps with full AX support
    case good      // Well-implemented native apps
    case fair      // Electron apps with decent AX
    case poor      // Web-based or minimal AX support
    case minimal   // Very limited or broken AX support
    
    var description: String {
        switch self {
        case .excellent: return "Excellent AX support"
        case .good: return "Good AX support"
        case .fair: return "Fair AX support"
        case .poor: return "Poor AX support"
        case .minimal: return "Minimal AX support"
        }
    }
    
    var confidenceModifier: Double {
        switch self {
        case .excellent: return 1.2
        case .good: return 1.1
        case .fair: return 1.0
        case .poor: return 0.8
        case .minimal: return 0.6
        }
    }
}

public struct ElementHints {
    public let preferredRoles: [String]
    public let avoidRoles: [String]
    public let requiredAttributes: [String]
    public let positionHints: [PositionHint]
    public let textPatterns: [String] // Regex patterns for identifying elements
    
    public init(
        preferredRoles: [String] = [],
        avoidRoles: [String] = [],
        requiredAttributes: [String] = [],
        positionHints: [PositionHint] = [],
        textPatterns: [String] = []
    ) {
        self.preferredRoles = preferredRoles
        self.avoidRoles = avoidRoles
        self.requiredAttributes = requiredAttributes
        self.positionHints = positionHints
        self.textPatterns = textPatterns
    }
}

public enum PositionHint {
    case bottom
    case top
    case left
    case right
    case center
    case nearButton(String) // Near button with specific title
    case inContainer(String) // Inside container with specific role
    
    var description: String {
        switch self {
        case .bottom: return "bottom of window"
        case .top: return "top of window"
        case .left: return "left side"
        case .right: return "right side"
        case .center: return "center area"
        case .nearButton(let title): return "near '\(title)' button"
        case .inContainer(let role): return "inside \(role)"
        }
    }
}

public struct BehaviorHint {
    public let action: String
    public let expectedOutcome: String
    public let confidence: Double
    
    public init(action: String, expectedOutcome: String, confidence: Double) {
        self.action = action
        self.expectedOutcome = expectedOutcome
        self.confidence = confidence
    }
}

// MARK: - Raycast Integration

public class RaycastIntegration: AppIntegration {
    public let appName = "Raycast"
    public let accessibilityQuality = AccessibilityQuality.good
    
    public let commonRoles: [String: ElementSignature.ElementType] = [
        kAXTextFieldRole: .input,
        kAXScrollAreaRole: .reply,
        kAXListRole: .session
    ]
    
    public let behaviorHints: [BehaviorHint] = [
        BehaviorHint(
            action: "send_message",
            expectedOutcome: "scroll_area_grows",
            confidence: 0.9
        ),
        BehaviorHint(
            action: "input_focus",
            expectedOutcome: "text_field_focused",
            confidence: 0.8
        )
    ]
    
    public func getElementHints(for elementType: ElementSignature.ElementType) -> ElementHints {
        switch elementType {
        case .input:
            return ElementHints(
                preferredRoles: [kAXTextFieldRole, kAXTextAreaRole],
                positionHints: [.bottom],
                textPatterns: [".*prompt.*", ".*ask.*", ".*search.*"]
            )
            
        case .reply:
            return ElementHints(
                preferredRoles: [kAXScrollAreaRole, kAXGroupRole],
                positionHints: [.center],
                requiredAttributes: [kAXChildrenAttribute]
            )
            
        case .session:
            return ElementHints(
                preferredRoles: [kAXListRole, kAXOutlineRole],
                positionHints: [.left, .right],
                textPatterns: [".*history.*", ".*recent.*"]
            )
        }
    }
    
    public func adjustConfidenceScore(_ baseScore: Double, for elementType: ElementSignature.ElementType) -> Double {
        var adjusted = baseScore * accessibilityQuality.confidenceModifier
        
        // Raycast-specific adjustments
        switch elementType {
        case .input:
            adjusted += 0.1 // Input fields are well-defined in Raycast
        case .reply:
            adjusted += 0.05 // Response areas are generally reliable
        case .session:
            adjusted -= 0.05 // Session management varies by use case
        }
        
        return min(adjusted, 1.0)
    }
    
    public func getRecommendedPolicy() -> Policy {
        return Policy(
            allowPeek: true,
            minConfidence: 0.7,
            maxPeekMs: 150,
            rateLimitPeekSeconds: 8
        )
    }
}

// MARK: - VS Code Integration

public class VSCodeIntegration: AppIntegration {
    public let appName = "Visual Studio Code"
    public let accessibilityQuality = AccessibilityQuality.fair
    
    public let commonRoles: [String: ElementSignature.ElementType] = [
        kAXTextAreaRole: .input,
        kAXGroupRole: .reply,
        kAXOutlineRole: .session
    ]
    
    public let behaviorHints: [BehaviorHint] = [
        BehaviorHint(
            action: "copilot_chat",
            expectedOutcome: "chat_panel_updates",
            confidence: 0.7
        )
    ]
    
    public func getElementHints(for elementType: ElementSignature.ElementType) -> ElementHints {
        switch elementType {
        case .input:
            return ElementHints(
                preferredRoles: [kAXTextAreaRole, kAXTextFieldRole],
                positionHints: [.bottom, .inContainer("AXGroup")],
                textPatterns: [".*chat.*", ".*copilot.*", ".*ask.*"]
            )
            
        case .reply:
            return ElementHints(
                preferredRoles: [kAXGroupRole, kAXScrollAreaRole],
                positionHints: [.center, .right],
                avoidRoles: [kAXToolbarRole, kAXMenuRole]
            )
            
        case .session:
            return ElementHints(
                preferredRoles: [kAXOutlineRole, kAXListRole],
                positionHints: [.left],
                textPatterns: [".*explorer.*", ".*files.*"]
            )
        }
    }
    
    public func adjustConfidenceScore(_ baseScore: Double, for elementType: ElementSignature.ElementType) -> Double {
        var adjusted = baseScore * accessibilityQuality.confidenceModifier
        
        // VS Code can be inconsistent with AX implementation
        switch elementType {
        case .input:
            adjusted += 0.05 // Text areas are usually well-marked
        case .reply:
            adjusted -= 0.1 // Chat responses can be tricky to identify
        case .session:
            adjusted += 0.1 // File explorer is generally reliable
        }
        
        return min(adjusted, 1.0)
    }
    
    public func getRecommendedPolicy() -> Policy {
        return Policy(
            allowPeek: true,
            minConfidence: 0.6,
            maxPeekMs: 200,
            rateLimitPeekSeconds: 12
        )
    }
}

// MARK: - ChatGPT/Web Integration

public class ChatGPTIntegration: AppIntegration {
    public let appName = "ChatGPT"
    public let accessibilityQuality = AccessibilityQuality.minimal
    
    public let commonRoles: [String: ElementSignature.ElementType] = [:] // Web-based, minimal AX
    
    public let behaviorHints: [BehaviorHint] = [
        BehaviorHint(
            action: "send_message",
            expectedOutcome: "page_content_changes",
            confidence: 0.4
        )
    ]
    
    public func getElementHints(for elementType: ElementSignature.ElementType) -> ElementHints {
        // Web-based apps have very limited accessibility support
        return ElementHints(
            preferredRoles: [kAXGroupRole, kAXUnknownRole],
            textPatterns: [".*chat.*", ".*message.*", ".*conversation.*"]
        )
    }
    
    public func adjustConfidenceScore(_ baseScore: Double, for elementType: ElementSignature.ElementType) -> Double {
        // Web apps generally have poor AX support
        return baseScore * accessibilityQuality.confidenceModifier
    }
    
    public func getRecommendedPolicy() -> Policy {
        return Policy(
            allowPeek: true,
            minConfidence: 0.4, // Lower threshold due to poor AX support
            maxPeekMs: 300,
            rateLimitPeekSeconds: 15
        )
    }
}

// MARK: - Xcode Integration

public class XcodeIntegration: AppIntegration {
    public let appName = "Xcode"
    public let accessibilityQuality = AccessibilityQuality.good
    
    public let commonRoles: [String: ElementSignature.ElementType] = [
        kAXTextViewRole: .input,
        kAXScrollAreaRole: .reply,
        kAXOutlineRole: .session
    ]
    
    public let behaviorHints: [BehaviorHint] = []
    
    public func getElementHints(for elementType: ElementSignature.ElementType) -> ElementHints {
        switch elementType {
        case .input:
            return ElementHints(
                preferredRoles: [kAXTextViewRole, kAXTextAreaRole],
                positionHints: [.center],
                textPatterns: [".*editor.*", ".*source.*"]
            )
            
        case .reply:
            return ElementHints(
                preferredRoles: [kAXScrollAreaRole, kAXTextViewRole],
                positionHints: [.center, .bottom]
            )
            
        case .session:
            return ElementHints(
                preferredRoles: [kAXOutlineRole, kAXBrowserRole],
                positionHints: [.left],
                textPatterns: [".*navigator.*", ".*project.*"]
            )
        }
    }
    
    public func adjustConfidenceScore(_ baseScore: Double, for elementType: ElementSignature.ElementType) -> Double {
        return baseScore * accessibilityQuality.confidenceModifier
    }
    
    public func getRecommendedPolicy() -> Policy {
        return Policy(
            allowPeek: true,
            minConfidence: 0.75,
            maxPeekMs: 100,
            rateLimitPeekSeconds: 10
        )
    }
}

// MARK: - Electron App Integration

public class ElectronIntegration: AppIntegration {
    public let appName: String
    public let accessibilityQuality = AccessibilityQuality.fair
    
    public let commonRoles: [String: ElementSignature.ElementType] = [
        kAXTextFieldRole: .input,
        kAXGroupRole: .reply,
        kAXListRole: .session
    ]
    
    public let behaviorHints: [BehaviorHint] = []
    
    public init(appName: String) {
        self.appName = appName
    }
    
    public func getElementHints(for elementType: ElementSignature.ElementType) -> ElementHints {
        // Electron apps have variable AX quality
        return ElementHints(
            preferredRoles: [kAXGroupRole, kAXUnknownRole],
            avoidRoles: [kAXWebAreaRole] // Web content often has poor AX
        )
    }
    
    public func adjustConfidenceScore(_ baseScore: Double, for elementType: ElementSignature.ElementType) -> Double {
        return baseScore * accessibilityQuality.confidenceModifier
    }
    
    public func getRecommendedPolicy() -> Policy {
        return Policy(
            allowPeek: true,
            minConfidence: 0.6,
            maxPeekMs: 250,
            rateLimitPeekSeconds: 15
        )
    }
}

// MARK: - Web Browser Integration

public class WebBrowserIntegration: AppIntegration {
    public let appName = "Web Browser"
    public let accessibilityQuality = AccessibilityQuality.poor
    
    public let commonRoles: [String: ElementSignature.ElementType] = [:]
    public let behaviorHints: [BehaviorHint] = []
    
    public func getElementHints(for elementType: ElementSignature.ElementType) -> ElementHints {
        return ElementHints(
            preferredRoles: [kAXWebAreaRole, kAXGroupRole],
            textPatterns: [".*input.*", ".*text.*", ".*chat.*"]
        )
    }
    
    public func adjustConfidenceScore(_ baseScore: Double, for elementType: ElementSignature.ElementType) -> Double {
        return baseScore * accessibilityQuality.confidenceModifier
    }
    
    public func getRecommendedPolicy() -> Policy {
        return Policy(
            allowPeek: true,
            minConfidence: 0.4,
            maxPeekMs: 400,
            rateLimitPeekSeconds: 20
        )
    }
}

// MARK: - Native App Integration (Default)

public class NativeAppIntegration: AppIntegration {
    public let appName = "Native macOS App"
    public let accessibilityQuality = AccessibilityQuality.good
    
    public let commonRoles: [String: ElementSignature.ElementType] = [
        kAXTextFieldRole: .input,
        kAXTextAreaRole: .input,
        kAXScrollAreaRole: .reply,
        kAXListRole: .session,
        kAXOutlineRole: .session
    ]
    
    public let behaviorHints: [BehaviorHint] = []
    
    public func getElementHints(for elementType: ElementSignature.ElementType) -> ElementHints {
        switch elementType {
        case .input:
            return ElementHints(
                preferredRoles: [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole],
                requiredAttributes: [kAXEnabledAttribute]
            )
            
        case .reply:
            return ElementHints(
                preferredRoles: [kAXScrollAreaRole, kAXTextViewRole, kAXGroupRole],
                avoidRoles: [kAXToolbarRole, kAXMenuRole]
            )
            
        case .session:
            return ElementHints(
                preferredRoles: [kAXOutlineRole, kAXListRole, kAXTableRole],
                requiredAttributes: [kAXChildrenAttribute]
            )
        }
    }
    
    public func adjustConfidenceScore(_ baseScore: Double, for elementType: ElementSignature.ElementType) -> Double {
        return baseScore * accessibilityQuality.confidenceModifier
    }
    
    public func getRecommendedPolicy() -> Policy {
        return Policy.default
    }
}

// MARK: - Integration Manager

public class IntegrationManager {
    private let appIntegrations = AppIntegrations()
    private let logger = Logger(label: "ui-scout.integration-manager")
    
    public init() {}
    
    public func enhanceElementFinding(
        for appBundleId: String,
        elementType: ElementSignature.ElementType,
        baseScore: Double
    ) -> Double {
        guard let integration = appIntegrations.getIntegration(for: appBundleId) else {
            return baseScore
        }
        
        let enhancedScore = integration.adjustConfidenceScore(baseScore, for: elementType)
        
        logger.debug("Enhanced score for \(appBundleId)/\(elementType): \(baseScore) → \(enhancedScore)")
        
        return enhancedScore
    }
    
    public func getRecommendedPolicy(for appBundleId: String) -> Policy {
        guard let integration = appIntegrations.getIntegration(for: appBundleId) else {
            return Policy.default
        }
        
        return integration.getRecommendedPolicy()
    }
    
    public func getElementHints(
        for appBundleId: String,
        elementType: ElementSignature.ElementType
    ) -> ElementHints {
        guard let integration = appIntegrations.getIntegration(for: appBundleId) else {
            return ElementHints()
        }
        
        return integration.getElementHints(for: elementType)
    }
    
    public func getAppInfo(for appBundleId: String) -> (name: String, quality: AccessibilityQuality)? {
        guard let integration = appIntegrations.getIntegration(for: appBundleId) else {
            return nil
        }
        
        return (integration.appName, integration.accessibilityQuality)
    }
    
    public func getSupportedApps() -> [(bundleId: String, name: String, quality: AccessibilityQuality)] {
        return appIntegrations.getAllKnownApps().compactMap { bundleId in
            guard let integration = appIntegrations.getIntegration(for: bundleId) else {
                return nil
            }
            return (bundleId, integration.appName, integration.accessibilityQuality)
        }
    }
}
