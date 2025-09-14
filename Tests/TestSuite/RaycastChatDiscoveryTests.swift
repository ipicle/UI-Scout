// This integration test requires XCTest, AppKit, Raycast installed, and Accessibility permissions.
#if canImport(XCTest)
import XCTest
import UIScoutCore
#if canImport(AppKit)
import AppKit
#endif

@available(macOS 13.0, *)
final class RaycastChatDiscoveryTests: XCTestCase {
    func testRaycastChatElementsDiscovery() async throws {
        let raycastBundleId = "com.raycast.macos"

        // Ensure environment can operate
        let permissions = PermissionsManager().checkAllPermissions()
        guard permissions.canOperate else {
            throw XCTSkip("Skipping: missing permissions: \(permissions.needsPrompt.joined(separator: ", "))")
        }

        // Try to launch Raycast if available
        #if canImport(AppKit)
        if !Self.isAppRunning(bundleId: raycastBundleId) {
            guard Self.launchApp(bundleId: raycastBundleId) else {
                throw XCTSkip("Skipping: Raycast not installed or cannot be launched")
            }
            // Give it a moment to become active
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        #else
        throw XCTSkip("Skipping: AppKit unavailable in this environment")
        #endif

        // Initialize core components
        let axClient = AXClient()
        let elementFinder = ElementFinder(axClient: axClient)
        let snapshotManager = SnapshotManager(axClient: axClient)
        let scorer = ConfidenceScorer()
        let ocrManager = OCRManager()
        let store = try SignatureStore()
        let rateLimiter = RateLimiter()
        let stateMachineFactory = StateMachineFactory(
            scorer: scorer,
            snapshotManager: snapshotManager,
            axClient: axClient,
            ocrManager: ocrManager
        )
        let orchestrator = UIScoutOrchestrator(
            axClient: axClient,
            elementFinder: elementFinder,
            snapshotManager: snapshotManager,
            scorer: scorer,
            ocrManager: ocrManager,
            stateMachineFactory: stateMachineFactory,
            store: store,
            rateLimiter: rateLimiter
        )

        let policy = Policy(allowPeek: true, minConfidence: 0.6, maxPeekMs: 250)

        // Discover all four elements in parallel
        async let input = orchestrator.findElement(appBundleId: raycastBundleId, elementType: .input, policy: policy)
        async let send = orchestrator.findElement(appBundleId: raycastBundleId, elementType: .send, policy: policy)
        async let reply = orchestrator.findElement(appBundleId: raycastBundleId, elementType: .reply, policy: policy)
        async let session = orchestrator.findElement(appBundleId: raycastBundleId, elementType: .session, policy: policy)
        let results = await [("input", input), ("send", send), ("reply", reply), ("session", session)]

        // Report and assert
        for (kind, res) in results {
            print("Raycast discovery: \(kind) confidence=\(String(format: "%.2f", res.confidence)) role=\(res.elementSignature.role)")
            XCTAssertGreaterThanOrEqual(res.confidence, 0.6, "Low confidence for \(kind)")
        }
    }

    #if canImport(AppKit)
    private static func isAppRunning(bundleId: String) -> Bool {
        return NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleId }
    }

    private static func launchApp(bundleId: String) -> Bool {
        return NSWorkspace.shared.launchApplication(withBundleIdentifier: bundleId,
                                                    options: [.default],
                                                    additionalEventParamDescriptor: nil,
                                                    launchIdentifier: nil)
    }
    #endif
}
#endif
