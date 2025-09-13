import Foundation
import ArgumentParser
import UIScoutCore
import Logging

@main
struct UIScoutCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uisct",
        abstract: "UIScout - Intelligent UI element discovery for macOS",
        version: "1.0.0",
        subcommands: [
            FindCommand.self,
            ObserveCommand.self,
            AfterSendDiffCommand.self,
            SnapshotCommand.self,
            LearnCommand.self,
            StatusCommand.self,
            SetupCommand.self
        ]
    )
    
    @Option(name: .shortAndLong, help: "Log level (trace, debug, info, warning, error)")
    var logLevel: String = "info"
    
    @Flag(name: .long, help: "Output results in JSON format")
    var json: Bool = false
    
    func validate() throws {
        let validLevels = ["trace", "debug", "info", "warning", "error"]
        guard validLevels.contains(logLevel.lowercased()) else {
            throw ValidationError("Invalid log level. Must be one of: \(validLevels.joined(separator: ", "))")
        }
    }
    
    mutating func run() async throws {
        // This will never be called since we have subcommands
    }
}

// MARK: - Find Command

struct FindCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "find",
        abstract: "Find UI elements in applications"
    )
    
    @Option(name: .shortAndLong, help: "Application bundle identifier")
    var app: String
    
    @Option(name: .shortAndLong, help: "Element type (reply, input, session)")
    var type: String
    
    @Option(name: .long, help: "Minimum confidence threshold (0.0-1.0)")
    var minConfidence: Double = 0.8
    
    @Option(name: .long, help: "Maximum peek duration in milliseconds")
    var maxPeekMs: Int = 250
    
    @Flag(name: .long, help: "Allow polite peek if needed")
    var allowPeek: Bool = false
    
    @Flag(name: .long, help: "Output in JSON format")
    var json: Bool = false
    
    func validate() throws {
        let validTypes = ["reply", "input", "session"]
        guard validTypes.contains(type.lowercased()) else {
            throw ValidationError("Invalid element type. Must be one of: \(validTypes.joined(separator: ", "))")
        }
        
        guard minConfidence >= 0.0 && minConfidence <= 1.0 else {
            throw ValidationError("Confidence threshold must be between 0.0 and 1.0")
        }
    }
    
    func run() async throws {
        LoggingSystem.bootstrap(StreamLogHandler.standardOutput)
        
        let bootstrap = UIScoutBootstrap()
        let permissionStatus = try await bootstrap.initialize()
        
        guard permissionStatus.canOperate else {
            if json {
                let error: [String: Any] = [
                    "error": "Insufficient permissions",
                    "needs": permissionStatus.needsPrompt
                ]
                printJSONAny(error)
            } else {
                print("❌ Cannot operate: missing permissions")
                print("Needs: \(permissionStatus.needsPrompt.joined(separator: ", "))")
            }
            throw ExitCode(1)
        }
        
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
        
        // Parse element type
        guard let elementType = ElementSignature.ElementType(rawValue: type.lowercased()) else {
            throw ValidationError("Invalid element type")
        }
        
        // Create policy
        let policy = Policy(
            allowPeek: allowPeek,
            minConfidence: minConfidence,
            maxPeekMs: maxPeekMs
        )
        
        // Find element
        let result = await orchestrator.findElement(
            appBundleId: app,
            elementType: elementType,
            policy: policy
        )
        
        // Output result
        if json {
            printJSON(result)
        } else {
            printFindResult(result, app: app, elementType: elementType)
        }
        
        // Cleanup
        orchestrator.cleanup()
    }
    
    private func printFindResult(_ result: ElementResult, app: String, elementType: ElementSignature.ElementType) {
        print("🔍 UIScout Find Results")
        print("App: \(app)")
        print("Element Type: \(elementType.rawValue)")
        print("Confidence: \(String(format: "%.2f", result.confidence))")
        print("Method: \(result.evidence.method.rawValue)")
        
        if result.confidence >= minConfidence {
            print("✅ Element found successfully")
            print("Role: \(result.elementSignature.role)")
            print("Stability: \(String(format: "%.2f", result.elementSignature.stability))")
        } else {
            print("⚠️  Low confidence result")
            if !result.needsPermissions.isEmpty {
                print("Missing: \(result.needsPermissions.joined(separator: ", "))")
            }
        }
    }
}

// MARK: - Observe Command

struct ObserveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "observe",
        abstract: "Observe UI element changes over time"
    )
    
    @Option(name: .shortAndLong, help: "Application bundle identifier")
    var app: String
    
    @Option(name: .shortAndLong, help: "Element signature JSON file path")
    var signature: String
    
    @Option(name: .shortAndLong, help: "Duration to observe in seconds")
    var duration: Int = 10
    
    @Flag(name: .long, help: "Output events as they occur")
    var stream: Bool = false
    
    @Flag(name: .long, help: "Output in JSON format")
    var json: Bool = false
    
    func run() async throws {
        LoggingSystem.bootstrap(StreamLogHandler.standardOutput)
        
        // Load signature from file
        let signatureData = try Data(contentsOf: URL(fileURLWithPath: signature))
        let elementSignature = try JSONDecoder().decode(ElementSignature.self, from: signatureData)
        
        let bootstrap = UIScoutBootstrap()
        let permissionStatus = try await bootstrap.initialize()
        
        guard permissionStatus.canOperate else {
            throw ExitCode(1)
        }
        
        // Initialize components
        let axClient = AXClient()
        let snapshotManager = SnapshotManager(axClient: axClient)
        let scorer = ConfidenceScorer()
        let ocrManager = OCRManager()
        let store = try SignatureStore()
        let rateLimiter = RateLimiter()
        let elementFinder = ElementFinder(axClient: axClient)
        
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
        
        if !json {
            print("👀 Observing \(elementSignature.elementType.rawValue) in \(app) for \(duration)s...")
        }
        
        // Start observation
        let eventStream = await orchestrator.observeElement(
            appBundleId: app,
            signature: elementSignature,
            durationSeconds: duration
        )
        
        // Monitor events
        var eventCount = 0
        let startTime = Date()
        
        while Date().timeIntervalSince(startTime) < TimeInterval(duration) {
            let events = eventStream.getRecentEvents(since: startTime)
            let newEvents = events.suffix(events.count - eventCount)
            
            for event in newEvents {
                eventCount += 1
                
                if json {
                    let eventDict: [String: Any] = [
                        "timestamp": event.timestamp.timeIntervalSince1970,
                        "notification": event.notification,
                        "app": event.appBundleId
                    ]
                    printJSONAny(eventDict)
                } else if stream {
                    let timeString = DateFormatter().string(from: event.timestamp)
                    print("[\(timeString)] \(event.notification)")
                }
            }
            
            try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        }
        
        if !json {
            print("📊 Observed \(eventCount) events total")
        }
        
        orchestrator.cleanup()
    }
}

// MARK: - After Send Diff Command

struct AfterSendDiffCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "after-send-diff",
        abstract: "Check for changes after sending a message"
    )
    
    @Option(name: .shortAndLong, help: "Application bundle identifier")
    var app: String
    
    @Option(name: .long, help: "Pre-send signature JSON file path")
    var preSignature: String
    
    @Flag(name: .long, help: "Allow polite peek if needed")
    var allowPeek: Bool = false
    
    @Flag(name: .long, help: "Output in JSON format")
    var json: Bool = false
    
    func run() async throws {
        LoggingSystem.bootstrap(StreamLogHandler.standardOutput)
        
        // Load signature from file
        let signatureData = try Data(contentsOf: URL(fileURLWithPath: preSignature))
        let elementSignature = try JSONDecoder().decode(ElementSignature.self, from: signatureData)
        
        let bootstrap = UIScoutBootstrap()
        let permissionStatus = try await bootstrap.initialize()
        
        guard permissionStatus.canOperate else {
            throw ExitCode(1)
        }
        
        // Initialize components (same pattern as find command)
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
        
        let policy = Policy(allowPeek: allowPeek)
        
        let result = await orchestrator.afterSendDiff(
            appBundleId: app,
            preSignature: elementSignature,
            policy: policy
        )
        
        if json {
            printJSON(result)
        } else {
            print("🔄 After-Send Diff Results")
            print("App: \(app)")
            print("Method: \(result.evidence.method.rawValue)")
            print("Confidence: \(String(format: "%.2f", result.confidence))")
            
            if result.evidence.diffScore > 0.1 {
                print("✅ Changes detected")
            } else {
                print("⚠️  No clear changes detected")
            }
        }
        
        orchestrator.cleanup()
    }
}

// MARK: - Snapshot Command

struct SnapshotCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "snapshot",
        abstract: "Capture element snapshot for diagnostics"
    )
    
    @Option(name: .shortAndLong, help: "Application bundle identifier")
    var app: String
    
    @Option(name: .shortAndLong, help: "Element signature JSON file path")
    var signature: String
    
    @Flag(name: .long, help: "Output in JSON format")
    var json: Bool = false
    
    func run() async throws {
        LoggingSystem.bootstrap(StreamLogHandler.standardOutput)
        
        let signatureData = try Data(contentsOf: URL(fileURLWithPath: signature))
        let elementSignature = try JSONDecoder().decode(ElementSignature.self, from: signatureData)
        
        let bootstrap = UIScoutBootstrap()
        try await bootstrap.validateRuntime()
        
        let axClient = AXClient()
        let snapshotManager = SnapshotManager(axClient: axClient)
        
        if let snapshot = snapshotManager.createSnapshot(for: elementSignature) {
            if json {
                printJSON(snapshot)
            } else {
                print("📸 Element Snapshot")
                print("Role: \(snapshot.role)")
                print("Frame: \(snapshot.frame)")
                print("Children: \(snapshot.childCount)")
                print("Text Length: \(snapshot.textLength)")
                print("Value: \(snapshot.value ?? "nil")")
            }
        } else {
            if json {
                printJSON(["error": "Could not create snapshot"])
            } else {
                print("❌ Could not create snapshot")
            }
            throw ExitCode(1)
        }
    }
}

// MARK: - Learn Command

struct LearnCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "learn",
        abstract: "Manage signature learning and storage"
    )
    
    @Option(name: .shortAndLong, help: "Element signature JSON file path")
    var signature: String
    
    @Flag(name: .long, help: "Pin this signature (prevent decay)")
    var pin: Bool = false
    
    @Flag(name: .long, help: "Decay this signature (reduce stability)")
    var decay: Bool = false
    
    @Flag(name: .long, help: "Output in JSON format")
    var json: Bool = false
    
    func run() async throws {
        LoggingSystem.bootstrap(StreamLogHandler.standardOutput)
        
        let signatureData = try Data(contentsOf: URL(fileURLWithPath: signature))
        let elementSignature = try JSONDecoder().decode(ElementSignature.self, from: signatureData)
        
        let store = try SignatureStore()
        
        // Initialize minimal orchestrator for learn functionality
        let axClient = AXClient()
        let elementFinder = ElementFinder(axClient: axClient)
        let snapshotManager = SnapshotManager(axClient: axClient)
        let scorer = ConfidenceScorer()
        let ocrManager = OCRManager()
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
        
        await orchestrator.learnSignature(
            signature: elementSignature,
            pin: pin,
            decay: decay
        )
        
        if json {
            let result = [
                "action": pin ? "pinned" : (decay ? "decayed" : "stored"),
                "signature_id": "\(elementSignature.appBundleId)-\(elementSignature.elementType.rawValue)"
            ]
            printJSON(result)
        } else {
            let action = pin ? "📌 Pinned" : (decay ? "📉 Decayed" : "💾 Stored")
            print("\(action) signature for \(elementSignature.appBundleId)/\(elementSignature.elementType.rawValue)")
        }
    }
}

// MARK: - Status Command

struct StatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show UIScout system status and statistics"
    )
    
    @Flag(name: .long, help: "Output in JSON format")
    var json: Bool = false
    
    func run() async throws {
        LoggingSystem.bootstrap(StreamLogHandler.standardOutput)
        
        let permissionsManager = PermissionsManager()
        let permissionStatus = permissionsManager.checkAllPermissions()
        let environment = permissionsManager.detectEnvironment()
        
        let store = try SignatureStore()
        let stats = await store.getStatistics()
        
        if json {
            let status: [String: Any] = [
                "permissions": [
                    "accessibility": permissionStatus.accessibility,
                    "screen_recording": permissionStatus.screenRecording,
                    "can_operate": permissionStatus.canOperate
                ],
                "environment": [
                    "bundle_id": environment.bundleIdentifier,
                    "is_terminal": environment.isInTerminal,
                    "is_sandboxed": environment.isSandboxed
                ],
                "store": [
                    "signatures": stats.signatureCount,
                    "evidence_records": stats.evidenceCount,
                    "average_stability": stats.averageStability,
                    "pinned_signatures": stats.pinnedSignatureCount
                ]
            ]
            printJSONAny(status)
        } else {
            print("🎯 UIScout Status")
            print("\nPermissions:")
            print(permissionStatus.description)
            
            print("\nEnvironment:")
            print(environment.description)
            
            print("\nSignature Store:")
            print(stats.description)
            
            if permissionStatus.canOperate {
                print("\n✅ Ready to operate")
            } else {
                print("\n❌ Cannot operate - missing permissions")
            }
        }
    }
}

// MARK: - Setup Command

struct SetupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Interactive setup for UIScout permissions"
    )
    
    func run() async throws {
        LoggingSystem.bootstrap(StreamLogHandler.standardOutput)
        
        print("🚀 UIScout Setup")
        print("This will guide you through granting necessary permissions.\n")
        
        let bootstrap = UIScoutBootstrap()
        let finalStatus = try await bootstrap.initialize()
        
        print("\n" + finalStatus.description)
        
        if finalStatus.canOperate {
            print("\n🎉 Setup completed successfully!")
            print("You can now use UIScout to discover and interact with UI elements.")
        } else {
            print("\n⚠️  Setup incomplete")
            print("Some features may not work without all permissions.")
            throw ExitCode(1)
        }
    }
}

// MARK: - Helper Functions

private func printJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    
    do {
        let data = try encoder.encode(value)
        if let string = String(data: data, encoding: .utf8) {
            print(string)
        }
    } catch {
        print("Error encoding JSON: \(error)")
    }
}

// Helper for printing heterogenous dictionaries/arrays
private func printJSONAny(_ value: Any) {
    guard JSONSerialization.isValidJSONObject(value) else {
        print("Error: value is not a valid JSON object")
        return
    }
    do {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        if let string = String(data: data, encoding: .utf8) {
            print(string)
        }
    } catch {
        print("Error serializing JSON: \(error)")
    }
}

// MARK: - Extensions

// Codable conformances are already declared in UIScoutCore
