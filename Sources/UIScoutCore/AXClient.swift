import Foundation
import ApplicationServices
import AppKit
import Logging

public class AXClient {
    private let logger = Logger(label: "ui-scout.ax-client")
    
    public init() {}
    
    // MARK: - Core AX Operations
    
    public func getElementsForApp(_ bundleId: String) throws -> [AXUIElement] {
        let runningApps = NSWorkspace.shared.runningApplications
        guard let app = runningApps.first(where: { $0.bundleIdentifier == bundleId }),
              let pid = app.processIdentifier as pid_t? else {
            throw UIScoutError.appNotFound(bundleId)
        }
        
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        
        guard result == .success, let windows = windowsRef as? [AXUIElement] else {
            throw UIScoutError.failedToGetWindows(result)
        }
        
        return windows
    }
    
    public func getAttribute<T>(_ element: AXUIElement, _ attribute: String, as type: T.Type) throws -> T? {
        var valueRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &valueRef)
        
        guard result == .success else {
            if result == .attributeUnsupported || result == .noValue {
                return nil
            }
            throw UIScoutError.failedToGetAttribute(attribute, result)
        }
        
        return valueRef as? T
    }
    
    public func setAttribute<T>(_ element: AXUIElement, _ attribute: String, value: T) throws {
        let result = AXUIElementSetAttributeValue(element, attribute as CFString, value as CFTypeRef)
        guard result == .success else {
            throw UIScoutError.failedToSetAttribute(attribute, result)
        }
    }
    
    // MARK: - Fast Attribute Fetching
    
    public struct MinimalAttributes {
        public let role: String?
        public let subrole: String?
        public let frame: CGRect
        public let value: String?
        public let childCount: Int
        public let isEnabled: Bool
        public let isFocused: Bool
        public let parent: AXUIElement?
        
        public init(
            role: String? = nil,
            subrole: String? = nil,
            frame: CGRect = .zero,
            value: String? = nil,
            childCount: Int = 0,
            isEnabled: Bool = true,
            isFocused: Bool = false,
            parent: AXUIElement? = nil
        ) {
            self.role = role
            self.subrole = subrole
            self.frame = frame
            self.value = value
            self.childCount = childCount
            self.isEnabled = isEnabled
            self.isFocused = isFocused
            self.parent = parent
        }
    }
    
    public func getMinimalAttributes(for element: AXUIElement) -> MinimalAttributes {
    let role = try? getAttribute(element, "AXRole", as: String.self) ?? "Unknown"
    let subrole = try? getAttribute(element, "AXSubrole", as: String.self)
        
        var frame = CGRect.zero
    if let frameValue = try? getAttribute(element, "AXFrame", as: AXValue.self) {
            AXValueGetValue(frameValue, .cgRect, &frame)
        }
        
    let value = try? getAttribute(element, "AXValue", as: String.self)
        
        var childCount = 0
    if let children = try? getAttribute(element, "AXChildren", as: [AXUIElement].self) {
            childCount = children.count
        }
        
    let isEnabled = (try? getAttribute(element, "AXEnabled", as: Bool.self)) ?? true
    let isFocused = (try? getAttribute(element, "AXFocused", as: Bool.self)) ?? false
    let parent = try? getAttribute(element, "AXParent", as: AXUIElement.self)
        
        return MinimalAttributes(
            role: role,
            subrole: subrole,
            frame: frame,
            value: value,
            childCount: childCount,
            isEnabled: isEnabled,
            isFocused: isFocused,
            parent: parent
        )
    }
    
    // MARK: - Text Aggregation (for reply areas)
    
    public func aggregateTextLength(from element: AXUIElement, maxLength: Int = 10000) -> Int {
        var totalLength = 0
        
        func traverseForText(_ element: AXUIElement) {
            if totalLength >= maxLength { return }
            
            let attrs = getMinimalAttributes(for: element)
            
            // If this is a text element, count its length
            if attrs.role == "AXStaticText" {
                if let text = attrs.value {
                    totalLength += text.count
                }
            }
            
            // Traverse children
            if let children = try? getAttribute(element, "AXChildren", as: [AXUIElement].self) {
                for child in children {
                    traverseForText(child)
                    if totalLength >= maxLength { break }
                }
            }
        }
        
        traverseForText(element)
        return min(totalLength, maxLength)
    }
    
    // MARK: - Element Path Generation
    
    public func generatePathHint(for element: AXUIElement) -> [String] {
        var path: [String] = []
        var current: AXUIElement? = element
        
        while let elem = current, path.count < 10 {
            let attrs = getMinimalAttributes(for: elem)
            let role = attrs.role ?? "Unknown"
            
            // Find sibling index if we have a parent
            var index = 0
            if let parent = attrs.parent,
               let siblings = try? getAttribute(parent, kAXChildrenAttribute, as: [AXUIElement].self) {
                for (idx, sibling) in siblings.enumerated() {
                    if CFEqual(sibling, elem) {
                        index = idx
                        break
                    }
                }
            }
            
            path.insert("\(role)[\(index)]", at: 0)
            current = attrs.parent
        }
        
        return path
    }
    
    // MARK: - Sibling Role Analysis
    
    public func getSiblingRoles(for element: AXUIElement) -> [String] {
      guard let parent = try? getAttribute(element, "AXParent", as: AXUIElement.self),
          let siblings = try? getAttribute(parent, "AXChildren", as: [AXUIElement].self) else {
            return []
        }
        
        return siblings.compactMap { sibling in
            try? getAttribute(sibling, kAXRoleAttribute, as: String.self)
        }
    }
    
    // MARK: - Element Focus and Interaction
    
    public func focusElement(_ element: AXUIElement) throws {
    let result = AXUIElementSetAttributeValue(element, "AXFocused" as CFString, kCFBooleanTrue)
        guard result == .success else {
            throw UIScoutError.failedToFocus(result)
        }
    }
    
    public func performAction(_ element: AXUIElement, action: String) throws {
        let result = AXUIElementPerformAction(element, action as CFString)
        guard result == .success else {
            throw UIScoutError.failedToPerformAction(action, result)
        }
    }
}

// MARK: - AX Error Types

// Use a distinct error type to avoid clashing with ApplicationServices.AXError
public enum UIScoutError: Error, LocalizedError {
    case appNotFound(String)
    case failedToGetWindows(ApplicationServices.AXError)
    case failedToGetAttribute(String, ApplicationServices.AXError)
    case failedToSetAttribute(String, ApplicationServices.AXError)
    case failedToFocus(ApplicationServices.AXError)
    case failedToPerformAction(String, ApplicationServices.AXError)
    case permissionDenied
    case failedToCreateObserver(ApplicationServices.AXError)
    case observerNotFound
    
    public var errorDescription: String? {
        switch self {
        case .appNotFound(let bundleId):
            return "Application not found: \(bundleId)"
        case .failedToGetWindows(let axError):
            return "Failed to get windows: \(axError)"
        case .failedToGetAttribute(let attr, let axError):
            return "Failed to get attribute \(attr): \(axError)"
        case .failedToSetAttribute(let attr, let axError):
            return "Failed to set attribute \(attr): \(axError)"
        case .failedToFocus(let axError):
            return "Failed to focus element: \(axError)"
        case .failedToPerformAction(let action, let axError):
            return "Failed to perform action \(action): \(axError)"
        case .permissionDenied:
            return "Accessibility permissions denied"
        case .failedToCreateObserver(let axError):
            return "Failed to create AX observer: \(axError)"
        case .observerNotFound:
            return "AX observer not found"
        }
    }
}

// MARK: - Extensions

// Provide readable description for the system AX error type
extension ApplicationServices.AXError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .success: return "success"
        case .failure: return "failure"
        case .illegalArgument: return "illegal argument"
        case .invalidUIElement: return "invalid UI element"
        case .invalidUIElementObserver: return "invalid observer"
        case .cannotComplete: return "cannot complete"
        case .attributeUnsupported: return "attribute unsupported"
        case .actionUnsupported: return "action unsupported"
        case .notificationUnsupported: return "notification unsupported"
        case .notImplemented: return "not implemented"
        case .notificationAlreadyRegistered: return "notification already registered"
        case .notificationNotRegistered: return "notification not registered"
        case .apiDisabled: return "API disabled"
        case .noValue: return "no value"
        case .parameterizedAttributeUnsupported: return "parameterized attribute unsupported"
        case .notEnoughPrecision: return "not enough precision"
        @unknown default: return "unknown error"
        }
    }
}
