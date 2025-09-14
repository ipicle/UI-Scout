import Foundation
import ApplicationServices
import Logging

public class ElementFinder {
    private let axClient: AXClient
    private let logger = Logger(label: "ui-scout.element-finder")
    
    public init(axClient: AXClient) {
        self.axClient = axClient
    }
    
    // MARK: - Main Discovery Methods
    
    public func findCandidates(
        appBundleId: String, 
        elementType: ElementSignature.ElementType
    ) throws -> [ScoredCandidate] {
        let windows = try axClient.getElementsForApp(appBundleId)
        var candidates: [ScoredCandidate] = []
        
        for (index, window) in windows.enumerated() {
            let title = (try? axClient.getAttribute(window, kAXTitleAttribute, as: String.self)) ?? ""
            let windowCandidates = findCandidatesInWindow(
                window: window,
                windowIndex: index,
                windowTitle: title,
                elementType: elementType,
                appBundleId: appBundleId
            )
            candidates.append(contentsOf: windowCandidates)
        }
        
        return candidates.sorted { $0.score > $1.score }
    }
    
    private func findCandidatesInWindow(
        window: AXUIElement,
        windowIndex: Int,
        windowTitle: String,
        elementType: ElementSignature.ElementType,
        appBundleId: String
    ) -> [ScoredCandidate] {
        var candidates: [ScoredCandidate] = []
        
        func traverse(_ element: AXUIElement, depth: Int = 0) {
            if depth > 10 { return } // Prevent infinite recursion
            
            let attrs = axClient.getMinimalAttributes(for: element)
            let score = scoreElement(
                element: element,
                attrs: attrs,
                elementType: elementType,
                appBundleId: appBundleId
            )
            
            if score > 0.1 { // Only consider elements with some relevance
                candidates.append(ScoredCandidate(
                    element: element,
                    score: score,
                    elementType: elementType,
                    appBundleId: appBundleId,
                    windowIndex: windowIndex,
                    windowTitle: windowTitle
                ))
            }
            
            // Traverse children
            if let children = try? axClient.getAttribute(element, kAXChildrenAttribute, as: [AXUIElement].self) {
                for child in children {
                    traverse(child, depth: depth + 1)
                }
            }
        }
        
        traverse(window)
        return candidates
    }
    
    // MARK: - Element Scoring
    
    private func scoreElement(
        element: AXUIElement,
        attrs: AXClient.MinimalAttributes,
        elementType: ElementSignature.ElementType,
        appBundleId: String
    ) -> Double {
        switch elementType {
        case .reply:
            return scoreReplyCandidate(element: element, attrs: attrs, appBundleId: appBundleId)
        case .input:
            return scoreInputCandidate(element: element, attrs: attrs, appBundleId: appBundleId)
        case .session:
            return scoreSessionCandidate(element: element, attrs: attrs, appBundleId: appBundleId)
        case .send:
            return scoreSendCandidate(element: element, attrs: attrs, appBundleId: appBundleId)
        }
    }

    // MARK: - Send Button Scoring

    private func scoreSendCandidate(
        element: AXUIElement,
        attrs: AXClient.MinimalAttributes,
        appBundleId: String
    ) -> Double {
        var score = 0.0
        
        // Role must be a button
        if let role = attrs.role, role == kAXButtonRole {
            score += 0.4
        } else {
            return 0.0
        }
        
        // Title or label hints
        if let title = try? axClient.getAttribute(element, kAXTitleAttribute, as: String.self) {
            let lower = title.lowercased()
            if ["send","submit","reply","post","enter"].contains(where: { lower.contains($0) }) || title == "→" || title == "▶" {
                score += 0.3
            }
        }
        
        // Near an input field
        if isNearInputField(element) {
            score += 0.2
        }
        
        // Position: often bottom-right area
        let windowWidth = getWindowWidth(element)
        let windowHeight = getWindowHeight(element)
        if windowWidth > 0 && windowHeight > 0 {
            let rx = attrs.frame.maxX / windowWidth
            let ry = attrs.frame.maxY / windowHeight
            if rx > 0.6 && ry > 0.6 { // bottom-right quadrant
                score += 0.1
            }
        }
        
        return min(score, 1.0)
    }
    
    // MARK: - Reply Area Scoring
    
    private func scoreReplyCandidate(
        element: AXUIElement,
        attrs: AXClient.MinimalAttributes,
        appBundleId: String
    ) -> Double {
        var score = 0.0
        
        // Role scoring
        if let role = attrs.role {
            switch role {
            case kAXScrollAreaRole:
                score += 0.4
            case kAXGroupRole:
                score += 0.3
            case kAXTableRole, kAXListRole:
                score += 0.2
            default:
                break
            }
        }
        
        // Read-only preference
        if !attrs.isEnabled || (attrs.value == nil && attrs.childCount > 0) {
            score += 0.2
        }
        
        // Child content analysis
        let textLength = axClient.aggregateTextLength(from: element)
        if textLength > 100 {
            score += min(0.3, Double(textLength) / 1000.0)
        }
        
        // Scrollable content
        if isScrollable(element) {
            score += 0.2
        }
        
        // Position analysis (conversation areas are often in center/right)
        if attrs.frame.width > 200 && attrs.frame.height > 100 {
            score += 0.1
        }
        
        // Contains static text children (common in reply areas)
        if hasStaticTextChildren(element) {
            score += 0.2
        }
        
        // App-specific heuristics
        score += getAppSpecificReplyScore(element: element, appBundleId: appBundleId)
        
        return min(score, 1.0)
    }
    
    // MARK: - Input Area Scoring
    
    private func scoreInputCandidate(
        element: AXUIElement,
        attrs: AXClient.MinimalAttributes,
        appBundleId: String
    ) -> Double {
        var score = 0.0
        
        // Role scoring
        if let role = attrs.role {
            switch role {
            case kAXTextAreaRole:
                score += 0.5
            case kAXTextFieldRole:
                score += 0.4
            case kAXComboBoxRole:
                score += 0.2
            default:
                break
            }
        }
        
        // Must be enabled and focusable
        if !attrs.isEnabled {
            return 0.0
        }
        
        // Has insertion point capability
        if supportsInsertionPoint(element) {
            score += 0.3
        }
        
        // Near send button
        if isNearSendButton(element) {
            score += 0.3
        }
        
        // Position (input usually at bottom)
        let windowHeight = getWindowHeight(element)
        if windowHeight > 0 {
            let relativeY = attrs.frame.minY / windowHeight
            if relativeY > 0.7 { // Bottom area
                score += 0.2
            }
        }
        
        // Size constraints (not too small, not too large)
        if attrs.frame.height > 20 && attrs.frame.height < 200 {
            score += 0.1
        }
        
        // App-specific heuristics
        score += getAppSpecificInputScore(element: element, appBundleId: appBundleId)
        
        return min(score, 1.0)
    }
    
    // MARK: - Session Sidebar Scoring
    
    private func scoreSessionCandidate(
        element: AXUIElement,
        attrs: AXClient.MinimalAttributes,
        appBundleId: String
    ) -> Double {
        var score = 0.0
        
        // Role scoring
        if let role = attrs.role {
            switch role {
            case kAXOutlineRole:
                score += 0.5
            case kAXTableRole:
                score += 0.4
            case kAXListRole:
                score += 0.3
            case kAXScrollAreaRole:
                score += 0.2
            default:
                break
            }
        }
        
        // Position (sidebars are usually on left or right)
        let windowWidth = getWindowWidth(element)
        if windowWidth > 0 {
            let relativeX = attrs.frame.minX / windowWidth
            if relativeX < 0.3 || relativeX > 0.7 { // Side areas
                score += 0.3
            }
        }
        
        // Aspect ratio (taller than wide for sidebar)
        if attrs.frame.height > attrs.frame.width {
            score += 0.2
        }
        
        // Has selectable rows
        if supportsRowSelection(element) {
            score += 0.3
        }
        
        // In a split group
        if isInSplitGroup(element) {
            score += 0.2
        }
        
        // App-specific heuristics
        score += getAppSpecificSessionScore(element: element, appBundleId: appBundleId)
        
        return min(score, 1.0)
    }
    
    // MARK: - Helper Methods
    
    private func isScrollable(_ element: AXUIElement) -> Bool {
        if let role = try? axClient.getAttribute(element, kAXRoleAttribute, as: String.self) {
            return role == kAXScrollAreaRole
        }
        return false
    }
    
    private func hasStaticTextChildren(_ element: AXUIElement) -> Bool {
        guard let children = try? axClient.getAttribute(element, kAXChildrenAttribute, as: [AXUIElement].self) else {
            return false
        }
        
        for child in children.prefix(10) { // Check first 10 children for performance
            if let role = try? axClient.getAttribute(child, kAXRoleAttribute, as: String.self),
               role == kAXStaticTextRole {
                return true
            }
        }
        return false
    }
    
    private func supportsInsertionPoint(_ element: AXUIElement) -> Bool {
        return (try? axClient.getAttribute(element, kAXInsertionPointLineNumberAttribute, as: Int.self)) != nil
    }
    
    private func isNearSendButton(_ element: AXUIElement) -> Bool {
        // Look for nearby button elements with send-like labels
        guard let parent = try? axClient.getAttribute(element, kAXParentAttribute, as: AXUIElement.self),
              let siblings = try? axClient.getAttribute(parent, kAXChildrenAttribute, as: [AXUIElement].self) else {
            return false
        }
        
        let sendKeywords = ["send", "submit", "post", "reply", "enter", "→", "▶"]
        
        for sibling in siblings {
            if let role = try? axClient.getAttribute(sibling, kAXRoleAttribute, as: String.self),
               role == kAXButtonRole,
               let title = try? axClient.getAttribute(sibling, kAXTitleAttribute, as: String.self) {
                let lowerTitle = title.lowercased()
                if sendKeywords.contains(where: { lowerTitle.contains($0) }) {
                    return true
                }
            }
        }
        
        return false
    }

    private func isNearInputField(_ element: AXUIElement) -> Bool {
        // Look for nearby text input siblings
        guard let parent = try? axClient.getAttribute(element, kAXParentAttribute, as: AXUIElement.self),
              let siblings = try? axClient.getAttribute(parent, kAXChildrenAttribute, as: [AXUIElement].self) else {
            return false
        }
        for sibling in siblings {
            if let role = try? axClient.getAttribute(sibling, kAXRoleAttribute, as: String.self),
               role == kAXTextAreaRole || role == kAXTextFieldRole {
                return true
            }
        }
        return false
    }
    
    private func supportsRowSelection(_ element: AXUIElement) -> Bool {
        return (try? axClient.getAttribute(element, kAXSelectedRowsAttribute, as: [AXUIElement].self)) != nil
    }
    
    private func isInSplitGroup(_ element: AXUIElement) -> Bool {
        var current = element
        for _ in 0..<5 { // Check up to 5 levels up
            if let parent = try? axClient.getAttribute(current, kAXParentAttribute, as: AXUIElement.self) {
                if let role = try? axClient.getAttribute(parent, kAXRoleAttribute, as: String.self),
                   role == kAXSplitGroupRole {
                    return true
                }
                current = parent
            } else {
                break
            }
        }
        return false
    }
    
    private func getWindowHeight(_ element: AXUIElement) -> CGFloat {
        var current = element
        for _ in 0..<10 {
            if let role = try? axClient.getAttribute(current, kAXRoleAttribute, as: String.self),
               role == kAXWindowRole {
                let attrs = axClient.getMinimalAttributes(for: current)
                return attrs.frame.height
            }
            if let parent = try? axClient.getAttribute(current, kAXParentAttribute, as: AXUIElement.self) {
                current = parent
            } else {
                break
            }
        }
        return 0
    }
    
    private func getWindowWidth(_ element: AXUIElement) -> CGFloat {
        var current = element
        for _ in 0..<10 {
            if let role = try? axClient.getAttribute(current, kAXRoleAttribute, as: String.self),
               role == kAXWindowRole {
                let attrs = axClient.getMinimalAttributes(for: current)
                return attrs.frame.width
            }
            if let parent = try? axClient.getAttribute(current, kAXParentAttribute, as: AXUIElement.self) {
                current = parent
            } else {
                break
            }
        }
        return 0
    }
    
    // MARK: - App-Specific Heuristics
    
    private func getAppSpecificReplyScore(element: AXUIElement, appBundleId: String) -> Double {
        switch appBundleId {
        case "com.raycast.macos":
            return getRaycastReplyScore(element: element)
        case "com.microsoft.VSCode":
            return getVSCodeReplyScore(element: element)
        case "com.openai.chat":
            return getChatGPTReplyScore(element: element)
        default:
            return 0.0
        }
    }
    
    private func getAppSpecificInputScore(element: AXUIElement, appBundleId: String) -> Double {
        switch appBundleId {
        case "com.raycast.macos":
            return getRaycastInputScore(element: element)
        case "com.microsoft.VSCode":
            return getVSCodeInputScore(element: element)
        case "com.openai.chat":
            return getChatGPTInputScore(element: element)
        default:
            return 0.0
        }
    }
    
    private func getAppSpecificSessionScore(element: AXUIElement, appBundleId: String) -> Double {
        switch appBundleId {
        case "com.raycast.macos":
            return getRaycastSessionScore(element: element)
        case "com.microsoft.VSCode":
            return getVSCodeSessionScore(element: element)
        case "com.openai.chat":
            return getChatGPTSessionScore(element: element)
        default:
            return 0.0
        }
    }
    
    // MARK: - Raycast-specific heuristics
    
    private func getRaycastReplyScore(element: AXUIElement) -> Double {
        // Raycast AI responses are typically in scrollable groups
        let attrs = axClient.getMinimalAttributes(for: element)
        if attrs.role == kAXScrollAreaRole && attrs.childCount > 3 {
            return 0.3
        }
        return 0.0
    }
    
    private func getRaycastInputScore(element: AXUIElement) -> Double {
        // Raycast input is usually a text field at the bottom
        let attrs = axClient.getMinimalAttributes(for: element)
        if attrs.role == kAXTextFieldRole {
            let windowHeight = getWindowHeight(element)
            let relativeY = attrs.frame.minY / windowHeight
            if relativeY > 0.8 {
                return 0.3
            }
        }
        return 0.0
    }
    
    private func getRaycastSessionScore(element: AXUIElement) -> Double {
        // Raycast doesn't typically have session sidebars
        return 0.0
    }
    
    // MARK: - VS Code-specific heuristics
    
    private func getVSCodeReplyScore(element: AXUIElement) -> Double {
        // VS Code Copilot chat responses
        return 0.1 // Minimal boost for now
    }
    
    private func getVSCodeInputScore(element: AXUIElement) -> Double {
        // VS Code chat input
        return 0.1 // Minimal boost for now
    }
    
    private func getVSCodeSessionScore(element: AXUIElement) -> Double {
        // VS Code has sidebar panels
        return 0.1 // Minimal boost for now
    }
    
    // MARK: - ChatGPT-specific heuristics
    
    private func getChatGPTReplyScore(element: AXUIElement) -> Double {
        return 0.1 // Web-based, minimal AX support
    }
    
    private func getChatGPTInputScore(element: AXUIElement) -> Double {
        return 0.1 // Web-based, minimal AX support
    }
    
    private func getChatGPTSessionScore(element: AXUIElement) -> Double {
        return 0.1 // Web-based, minimal AX support
    }
}

// MARK: - Scored Candidate

public struct ScoredCandidate {
    public let element: AXUIElement
    public let score: Double
    public let elementType: ElementSignature.ElementType
    public let appBundleId: String
    public let windowIndex: Int
    public let windowTitle: String
    
    public init(
        element: AXUIElement,
        score: Double,
        elementType: ElementSignature.ElementType,
        appBundleId: String,
        windowIndex: Int,
        windowTitle: String
    ) {
        self.element = element
        self.score = score
        self.elementType = elementType
        self.appBundleId = appBundleId
        self.windowIndex = windowIndex
        self.windowTitle = windowTitle
    }
    
    public func toElementSignature(axClient: AXClient) -> ElementSignature {
        let attrs = axClient.getMinimalAttributes(for: element)
        let pathHint = axClient.generatePathHint(for: element)
        let siblingRoles = axClient.getSiblingRoles(for: element)
        
        let frameHash = ElementSignature.generateFrameHash(
            width: Int(attrs.frame.width),
            height: Int(attrs.frame.height),
            x: Int(attrs.frame.minX),
            y: Int(attrs.frame.minY)
        )
        
        var signatureAttrs: [String: ElementSignature.AttributeValue?] = [:]
        signatureAttrs["AXValue"] = attrs.value.map { .string($0) }
        signatureAttrs["AXChildrenCount"] = .int(attrs.childCount)
        signatureAttrs["AXWindowIndex"] = .int(windowIndex)
        if !windowTitle.isEmpty {
            signatureAttrs["AXWindowTitle"] = .string(windowTitle)
        }
        
        return ElementSignature(
            appBundleId: appBundleId,
            elementType: elementType,
            role: attrs.role ?? "Unknown",
            subroles: [attrs.subrole].compactMap { $0 },
            frameHash: frameHash,
            pathHint: pathHint,
            siblingRoles: siblingRoles,
            readOnly: !attrs.isEnabled,
            scrollable: attrs.role == kAXScrollAreaRole,
            attrs: signatureAttrs,
            stability: score, // Use initial score as stability baseline
            lastVerifiedAt: Date().timeIntervalSince1970
        )
    }
}
