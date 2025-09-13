import Foundation
import ApplicationServices
import AVFoundation
import Logging

public class PermissionsManager {
    private let logger = Logger(label: "ui-scout.permissions")
    
    public struct PermissionStatus {
        public let accessibility: Bool
        public let screenRecording: Bool
        public let needsPrompt: [String]
        public let canOperate: Bool
        
        public init(accessibility: Bool, screenRecording: Bool, needsPrompt: [String] = []) {
            self.accessibility = accessibility
            self.screenRecording = screenRecording
            self.needsPrompt = needsPrompt
            self.canOperate = accessibility // Minimum requirement
        }
        
        public var description: String {
            var lines: [String] = []
            lines.append("Permission Status:")
            lines.append("  Accessibility: \(accessibility ? "✓" : "✗")")
            lines.append("  Screen Recording: \(screenRecording ? "✓" : "✗")")
            if !needsPrompt.isEmpty {
                lines.append("  Needs prompts for: \(needsPrompt.joined(separator: ", "))")
            }
            lines.append("  Can operate: \(canOperate ? "Yes" : "No")")
            return lines.joined(separator: "\n")
        }
    }
    
    public init() {}
    
    // MARK: - Permission Checking
    
    public func checkAllPermissions() -> PermissionStatus {
        let accessibilityGranted = checkAccessibilityPermission()
        let screenRecordingGranted = checkScreenRecordingPermission()
        
        var needsPrompt: [String] = []
        
        if !accessibilityGranted {
            needsPrompt.append("accessibility")
        }
        
        if !screenRecordingGranted {
            needsPrompt.append("screen-recording")
        }
        
        return PermissionStatus(
            accessibility: accessibilityGranted,
            screenRecording: screenRecordingGranted,
            needsPrompt: needsPrompt
        )
    }
    
    public func checkAccessibilityPermission() -> Bool {
        return AXIsProcessTrusted()
    }
    
    public func checkScreenRecordingPermission() -> Bool {
        // Screen recording permission is needed for OCR functionality
        // We check by attempting to capture a small screen region
        let displayID = CGMainDisplayID()
        
        // Try to capture a 1x1 pixel to test permission
        if let image = CGDisplayCreateImage(displayID, rect: CGRect(x: 0, y: 0, width: 1, height: 1)) {
            // If we can capture, we have permission
            return true
        } else {
            return false
        }
    }
    
    // MARK: - Permission Prompting
    
    public func promptForAccessibilityPermission() {
        logger.info("Prompting for accessibility permission")
        
        // This will show the system prompt if permission hasn't been granted
        let _ = AXIsProcessTrusted()
        
        // Additional guidance for the user
        showAccessibilityInstructions()
    }
    
    public func promptForScreenRecordingPermission() {
        logger.info("Prompting for screen recording permission")
        
        // Attempt a screen capture which will trigger the system prompt
        let displayID = CGMainDisplayID()
        let _ = CGDisplayCreateImage(displayID, rect: CGRect(x: 0, y: 0, width: 1, height: 1))
        
        showScreenRecordingInstructions()
    }
    
    private func showAccessibilityInstructions() {
        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Required"
        alert.informativeText = """
        UIScout needs Accessibility permission to interact with other applications.
        
        To grant permission:
        1. Open System Settings (or System Preferences)
        2. Go to Privacy & Security → Privacy → Accessibility
        3. Find and enable UIScout or your terminal application
        4. Restart UIScout if needed
        
        This permission allows UIScout to read UI elements and detect changes in applications.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openSystemSettings(anchor: "Privacy_Accessibility")
        }
    }
    
    private func showScreenRecordingInstructions() {
        let alert = NSAlert()
        alert.messageText = "Screen Recording Permission Recommended"
        alert.informativeText = """
        UIScout can use screen recording for advanced OCR verification features.
        
        To grant permission:
        1. Open System Settings (or System Preferences)
        2. Go to Privacy & Security → Privacy → Screen & System Audio Recording
        3. Find and enable UIScout or your terminal application
        
        This permission is optional but improves accuracy when detecting UI changes.
        You can still use UIScout without this permission.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Skip for Now")
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openSystemSettings(anchor: "Privacy_ScreenCapture")
        }
    }
    
    private func openSystemSettings(anchor: String) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
        NSWorkspace.shared.open(url)
    }
    
    // MARK: - Guided Setup
    
    public func performGuidedSetup() async -> PermissionStatus {
        logger.info("Starting guided permission setup")
        
        let initialStatus = checkAllPermissions()
        
        if initialStatus.canOperate {
            logger.info("All required permissions already granted")
            return initialStatus
        }
        
        // Step 1: Accessibility (required)
        if !initialStatus.accessibility {
            await promptForAccessibilityWithWait()
        }
        
        // Step 2: Screen Recording (optional)
        let updatedStatus = checkAllPermissions()
        if updatedStatus.accessibility && !updatedStatus.screenRecording {
            await promptForScreenRecordingWithWait()
        }
        
        let finalStatus = checkAllPermissions()
        
        if finalStatus.canOperate {
            logger.info("Setup completed successfully")
            showSetupCompleteMessage()
        } else {
            logger.warning("Setup incomplete - missing required permissions")
            showSetupIncompleteMessage()
        }
        
        return finalStatus
    }
    
    private func promptForAccessibilityWithWait() async {
        promptForAccessibilityPermission()
        
        // Wait for user to grant permission
        for attempt in 1...30 { // Wait up to 30 seconds
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
            if checkAccessibilityPermission() {
                logger.info("Accessibility permission granted after \(attempt) seconds")
                break
            }
        }
    }
    
    private func promptForScreenRecordingWithWait() async {
        promptForScreenRecordingPermission()
        
        // Wait briefly for user decision
        for attempt in 1...15 { // Wait up to 15 seconds
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
            if checkScreenRecordingPermission() {
                logger.info("Screen recording permission granted after \(attempt) seconds")
                break
            }
        }
    }
    
    private func showSetupCompleteMessage() {
        let alert = NSAlert()
        alert.messageText = "Setup Complete!"
        alert.informativeText = "UIScout now has all the permissions it needs to operate effectively."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
    
    private func showSetupIncompleteMessage() {
        let alert = NSAlert()
        alert.messageText = "Setup Incomplete"
        alert.informativeText = """
        UIScout is missing some required permissions. It may not work correctly.
        
        You can run the setup again later or manually grant permissions in System Settings.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
    
    // MARK: - Runtime Permission Checking
    
    public func requireAccessibilityPermission() throws {
        guard checkAccessibilityPermission() else {
            throw PermissionError.accessibilityRequired
        }
    }
    
    public func requireScreenRecordingPermission() throws {
        guard checkScreenRecordingPermission() else {
            throw PermissionError.screenRecordingRequired
        }
    }
    
    public func checkRequiredPermissions(for features: [UIScoutFeature]) throws {
        for feature in features {
            switch feature {
            case .elementDiscovery, .snapshotting, .observing:
                try requireAccessibilityPermission()
            case .ocrVerification:
                try requireScreenRecordingPermission()
            }
        }
    }
    
    // MARK: - Permission Recovery
    
    public func handlePermissionLoss() {
        logger.warning("Permission loss detected")
        
        let status = checkAllPermissions()
        
        if !status.accessibility {
            logger.error("Lost accessibility permission - UIScout cannot operate")
            showPermissionLossAlert(permission: "Accessibility")
        }
        
        if !status.screenRecording {
            logger.warning("Lost screen recording permission - OCR features disabled")
        }
    }
    
    private func showPermissionLossAlert(permission: String) {
        let alert = NSAlert()
        alert.messageText = "\(permission) Permission Lost"
        alert.informativeText = """
        UIScout has lost \(permission.lowercased()) permission and cannot operate.
        
        This may happen after system updates or security changes.
        Please re-grant permission in System Settings.
        """
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Quit UIScout")
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let anchor = permission == "Accessibility" ? "Privacy_Accessibility" : "Privacy_ScreenCapture"
            openSystemSettings(anchor: anchor)
        } else {
            exit(1)
        }
    }
    
    // MARK: - Environment Detection
    
    public func detectEnvironment() -> EnvironmentInfo {
        let isInTerminal = ProcessInfo.processInfo.environment["TERM"] != nil
        let isInXcode = ProcessInfo.processInfo.environment["__XCODE_BUILT_PRODUCTS_DIR_PATHS"] != nil
        let isSandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
        
        let bundleId = Bundle.main.bundleIdentifier ?? "unknown"
        
        return EnvironmentInfo(
            isInTerminal: isInTerminal,
            isInXcode: isInXcode,
            isSandboxed: isSandboxed,
            bundleIdentifier: bundleId
        )
    }
}

// MARK: - Supporting Types

public enum UIScoutFeature {
    case elementDiscovery
    case snapshotting
    case observing
    case ocrVerification
}

public enum PermissionError: Error, LocalizedError {
    case accessibilityRequired
    case screenRecordingRequired
    case permissionDenied(String)
    
    public var errorDescription: String? {
        switch self {
        case .accessibilityRequired:
            return "Accessibility permission is required for UIScout to operate"
        case .screenRecordingRequired:
            return "Screen recording permission is required for OCR features"
        case .permissionDenied(let permission):
            return "\(permission) permission was denied"
        }
    }
}

public struct EnvironmentInfo {
    public let isInTerminal: Bool
    public let isInXcode: Bool
    public let isSandboxed: Bool
    public let bundleIdentifier: String
    
    public var description: String {
        var components: [String] = []
        if isInTerminal { components.append("Terminal") }
        if isInXcode { components.append("Xcode") }
        if isSandboxed { components.append("Sandboxed") }
        
        let environment = components.isEmpty ? "Unknown" : components.joined(separator: ", ")
        return "Environment: \(environment) (Bundle: \(bundleIdentifier))"
    }
    
    public var recommendedSetupApproach: String {
        if isInTerminal {
            return "Grant permissions to your terminal application (Terminal.app, iTerm2, etc.)"
        } else if isInXcode {
            return "Grant permissions to Xcode for development builds"
        } else if isSandboxed {
            return "Sandboxed apps have limited permission capabilities"
        } else {
            return "Grant permissions to UIScout application"
        }
    }
}

// MARK: - Bootstrap Helper

public class UIScoutBootstrap {
    private let permissionsManager: PermissionsManager
    private let logger = Logger(label: "ui-scout.bootstrap")
    
    public init() {
        self.permissionsManager = PermissionsManager()
    }
    
    public func initialize() async throws -> PermissionStatus {
        logger.info("Initializing UIScout...")
        
        // Detect environment
        let environment = permissionsManager.detectEnvironment()
        logger.info(environment.description)
        logger.info("Recommended approach: \(environment.recommendedSetupApproach)")
        
        // Check current permissions
        let initialStatus = permissionsManager.checkAllPermissions()
        logger.info("Initial permission check:")
        logger.info(initialStatus.description)
        
        // If we don't have required permissions, start guided setup
        if !initialStatus.canOperate {
            logger.info("Starting guided setup...")
            
            if !environment.isInTerminal {
                // Show GUI setup for non-terminal environments
                return await permissionsManager.performGuidedSetup()
            } else {
                // Show CLI instructions for terminal environments
                showTerminalInstructions(environment: environment)
                
                // Wait for permissions to be granted
                return await waitForPermissions()
            }
        }
        
        logger.info("UIScout initialized successfully!")
        return initialStatus
    }
    
    private func showTerminalInstructions(environment: EnvironmentInfo) {
        print("""
        
        🔧 UIScout Setup Required
        
        UIScout needs Accessibility permission to operate.
        
        \(environment.recommendedSetupApproach)
        
        Steps:
        1. Open System Settings (or System Preferences)
        2. Go to Privacy & Security → Privacy → Accessibility
        3. Find your terminal app and enable it
        4. Return here and press Enter to continue
        
        For Screen Recording (optional OCR features):
        - Also enable your terminal in Screen & System Audio Recording
        
        """)
        
        print("Press Enter after granting permissions...")
        _ = readLine()
    }
    
    private func waitForPermissions() async -> PermissionStatus {
        for attempt in 1...60 { // Wait up to 60 seconds
            let status = permissionsManager.checkAllPermissions()
            
            if status.canOperate {
                print("✅ Permissions granted!")
                return status
            }
            
            if attempt % 5 == 0 {
                print("⏳ Still waiting for permissions... (\(attempt)s)")
            }
            
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
        }
        
        print("⚠️  Timeout waiting for permissions. Some features may not work.")
        return permissionsManager.checkAllPermissions()
    }
    
    public func validateRuntime() throws {
        try permissionsManager.requireAccessibilityPermission()
        logger.debug("Runtime validation passed")
    }
}
