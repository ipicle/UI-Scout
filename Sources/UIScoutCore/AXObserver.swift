import Foundation
import ApplicationServices
import AppKit
import Logging

public class AXEventObserver {
    private let logger = Logger(label: "ui-scout.ax-observer")
    private var observers: [String: ApplicationServices.AXObserver] = [:]
    private var callbacks: [String: [(String, AXUIElement) -> Void]] = [:]
    
    public init() {}
    
    // MARK: - Observer Management
    
    public func startObserving(
        appBundleId: String,
        element: AXUIElement,
        notifications: [String],
        callback: @escaping (String, AXUIElement) -> Void
    ) throws {
        let runningApps = NSWorkspace.shared.runningApplications
        guard let app = runningApps.first(where: { $0.bundleIdentifier == appBundleId }),
              let pid = app.processIdentifier as pid_t? else {
            throw UIScoutError.appNotFound(appBundleId)
        }
        
        let observerKey = "\(appBundleId)-\(pid)"
        
        // Create observer if it doesn't exist
        if observers[observerKey] == nil {
            var observer: ApplicationServices.AXObserver?
            let result = AXObserverCreate(pid, observerCallback, &observer)
            
            guard result == .success, let createdObserver = observer else {
                throw UIScoutError.failedToCreateObserver(result)
            }
            
            observers[observerKey] = createdObserver
            callbacks[observerKey] = []
            
            // Add observer to run loop
            CFRunLoopAddSource(
                CFRunLoopGetCurrent(),
                AXObserverGetRunLoopSource(createdObserver),
                .defaultMode
            )
        }
        
        guard let axObserver = observers[observerKey] else {
            throw UIScoutError.observerNotFound
        }
        
        // Add callback
        callbacks[observerKey]?.append(callback)
        
        // Register for notifications
    for notification in notifications {
            let result = AXObserverAddNotification(
                axObserver,
                element,
                notification as CFString,
                UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
            )
            
            if result != .success {
                logger.warning("Failed to register for notification \(notification): \(result)")
            }
        }
    }
    
    public func stopObserving(appBundleId: String, element: AXUIElement) {
        let runningApps = NSWorkspace.shared.runningApplications
        guard let app = runningApps.first(where: { $0.bundleIdentifier == appBundleId }),
              let pid = app.processIdentifier as pid_t? else {
            return
        }
        
        let observerKey = "\(appBundleId)-\(pid)"
        
        guard let observer = observers[observerKey] else { return }
        
        // Remove all notifications for this element
        let commonNotifications = [
            kAXValueChangedNotification,
            kAXUIElementDestroyedNotification,
            "AXChildrenChanged",
            kAXFocusedUIElementChangedNotification
        ]
        
        for notification in commonNotifications {
            AXObserverRemoveNotification(observer, element, notification as CFString)
        }
    }
    
    public func stopAllObserving(appBundleId: String) {
        let runningApps = NSWorkspace.shared.runningApplications
        guard let app = runningApps.first(where: { $0.bundleIdentifier == appBundleId }),
              let pid = app.processIdentifier as pid_t? else {
            return
        }
        
        let observerKey = "\(appBundleId)-\(pid)"
        
        if let observer = observers[observerKey] {
            CFRunLoopRemoveSource(
                CFRunLoopGetCurrent(),
                AXObserverGetRunLoopSource(observer),
                .defaultMode
            )
            
            observers.removeValue(forKey: observerKey)
            callbacks.removeValue(forKey: observerKey)
        }
    }
    
    // MARK: - Notification Handling
    
    func handleNotification(observer: ApplicationServices.AXObserver, element: AXUIElement, notification: String) {
        logger.debug("Received notification: \(notification)")
        
        // Find the observer key
        var observerKey: String?
        for (key, obs) in observers {
            if CFEqual(obs, observer) {
                observerKey = key
                break
            }
        }
        
        guard let key = observerKey,
              let callbackList = callbacks[key] else {
            return
        }
        
        // Call all registered callbacks
        for callback in callbackList {
            callback(notification, element)
        }
    }
    
    // MARK: - Convenience Methods
    
    public func observeValueChanges(
        appBundleId: String,
        element: AXUIElement,
        callback: @escaping (AXUIElement) -> Void
    ) throws {
        try startObserving(
            appBundleId: appBundleId,
            element: element,
            notifications: [kAXValueChangedNotification]
        ) { notification, element in
            if notification == kAXValueChangedNotification {
                callback(element)
            }
        }
    }
    
    public func observeChildrenChanges(
        appBundleId: String,
        element: AXUIElement,
        callback: @escaping (AXUIElement) -> Void
    ) throws {
        try startObserving(
            appBundleId: appBundleId,
            element: element,
            notifications: [String.axChildrenChanged]
        ) { notification, element in
            if notification == String.axChildrenChanged {
                callback(element)
            }
        }
    }
    
    public func observeFocusChanges(
        appBundleId: String,
        element: AXUIElement,
        callback: @escaping (AXUIElement) -> Void
    ) throws {
        try startObserving(
            appBundleId: appBundleId,
            element: element,
            notifications: [kAXFocusedUIElementChangedNotification]
        ) { notification, element in
            if notification == kAXFocusedUIElementChangedNotification {
                callback(element)
            }
        }
    }
}

// MARK: - Observer Callback

private func observerCallback(
    observer: ApplicationServices.AXObserver,
    element: AXUIElement,
    notificationName: CFString,
    contextData: UnsafeMutableRawPointer?
) {
    guard let contextData = contextData else { return }
    
    let axObserver = Unmanaged<AXEventObserver>.fromOpaque(contextData).takeUnretainedValue()
    let notification = notificationName as String
    
    axObserver.handleNotification(
        observer: observer,
        element: element,
        notification: notification
    )
}

// MARK: - Extended AX Error Types

// Error helpers now covered by UIScoutError

// MARK: - Notification Constants Extension

public extension String {
    // Common AX notifications
    static let axValueChanged = kAXValueChangedNotification
    static let axChildrenChanged = "AXChildrenChanged"
    static let axFocusedUIElementChanged = kAXFocusedUIElementChangedNotification
    static let axUIElementDestroyed = kAXUIElementDestroyedNotification
    static let axWindowCreated = kAXWindowCreatedNotification
    static let axWindowMoved = kAXWindowMovedNotification
    static let axWindowResized = kAXWindowResizedNotification
}

// MARK: - Observer Event Types

public struct AXNotificationEvent {
    public let notification: String
    public let element: AXUIElement
    public let timestamp: Date
    public let appBundleId: String
    
    public init(
        notification: String,
        element: AXUIElement,
        appBundleId: String,
        timestamp: Date = Date()
    ) {
        self.notification = notification
        self.element = element
        self.appBundleId = appBundleId
        self.timestamp = timestamp
    }
}

// MARK: - Event Stream

public class AXEventStream {
    private let observer: AXEventObserver
    private var isActive = false
    private var events: [AXNotificationEvent] = []
    private let maxEvents: Int
    
    public init(maxEvents: Int = 100) {
        self.observer = AXEventObserver()
        self.maxEvents = maxEvents
    }
    
    public func startStream(
        appBundleId: String,
        element: AXUIElement,
        notifications: [String]
    ) throws {
        guard !isActive else { return }
        
        isActive = true
        events.removeAll()
        
        try observer.startObserving(
            appBundleId: appBundleId,
            element: element,
            notifications: notifications
        ) { [weak self] notification, element in
            self?.addEvent(
                AXNotificationEvent(
                    notification: notification,
                    element: element,
                    appBundleId: appBundleId
                )
            )
        }
    }
    
    public func stopStream(appBundleId: String) {
        guard isActive else { return }
        
        observer.stopAllObserving(appBundleId: appBundleId)
        isActive = false
    }
    
    public func getRecentEvents(since: Date? = nil) -> [AXNotificationEvent] {
        if let since = since {
            return events.filter { $0.timestamp > since }
        }
        return Array(events)
    }
    
    private func addEvent(_ event: AXNotificationEvent) {
        events.append(event)
        if events.count > maxEvents {
            events.removeFirst(events.count - maxEvents)
        }
    }
}
