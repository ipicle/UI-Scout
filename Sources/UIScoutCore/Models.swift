import Foundation
import CryptoKit

// MARK: - Core Data Models

public struct ElementSignature: Codable, Hashable {
    public let appBundleId: String
    public let elementType: ElementType
    public let role: String
    public let subroles: [String]
    public let frameHash: String
    public let pathHint: [String]
    public let siblingRoles: [String]
    public let readOnly: Bool
    public let scrollable: Bool
    public let attrs: [String: AttributeValue?]
    public var stability: Double
    public var lastVerifiedAt: TimeInterval
    
    public enum ElementType: String, Codable, CaseIterable {
        case reply = "reply"
        case input = "input"
        case session = "session"
    }
    
    public enum AttributeValue: Codable, Hashable {
        case string(String)
        case int(Int)
        case bool(Bool)
        case null
        
        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
            } else if let boolValue = try? container.decode(Bool.self) {
                self = .bool(boolValue)
            } else if let intValue = try? container.decode(Int.self) {
                self = .int(intValue)
            } else if let stringValue = try? container.decode(String.self) {
                self = .string(stringValue)
            } else {
                self = .null
            }
        }
        
        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let value):
                try container.encode(value)
            case .int(let value):
                try container.encode(value)
            case .bool(let value):
                try container.encode(value)
            case .null:
                try container.encodeNil()
            }
        }
    }
    
    public init(
        appBundleId: String,
        elementType: ElementType,
        role: String,
        subroles: [String] = [],
        frameHash: String,
        pathHint: [String] = [],
        siblingRoles: [String] = [],
        readOnly: Bool = false,
        scrollable: Bool = false,
        attrs: [String: AttributeValue?] = [:],
        stability: Double = 0.0,
        lastVerifiedAt: TimeInterval = Date().timeIntervalSince1970
    ) {
        self.appBundleId = appBundleId
        self.elementType = elementType
        self.role = role
        self.subroles = subroles
        self.frameHash = frameHash
        self.pathHint = pathHint
        self.siblingRoles = siblingRoles
        self.readOnly = readOnly
        self.scrollable = scrollable
        self.attrs = attrs
        self.stability = stability
        self.lastVerifiedAt = lastVerifiedAt
    }
    
    public static func generateFrameHash(width: Int, height: Int, x: Int, y: Int) -> String {
        let frameString = "w\(width)-h\(height)-x\(x)-y\(y)"
        let hash = SHA1.hash(data: Data(frameString.utf8))
        return hash.compactMap { String(format: "%02x", $0) }.joined()[..<8].description + "@sha1"
    }
}

public struct Evidence: Codable {
    public let method: DetectionMethod
    public let heuristicScore: Double
    public let diffScore: Double
    public let ocrChange: Bool
    public let notifications: [String]
    public let confidence: Double
    public let timestamp: TimeInterval
    
    public enum DetectionMethod: String, Codable {
        case passive = "passive"
        case ocr = "ocr"
        case peek = "peek"
    }
    
    public init(
        method: DetectionMethod,
        heuristicScore: Double,
        diffScore: Double,
        ocrChange: Bool = false,
        notifications: [String] = [],
        confidence: Double,
        timestamp: TimeInterval = Date().timeIntervalSince1970
    ) {
        self.method = method
        self.heuristicScore = heuristicScore
        self.diffScore = diffScore
        self.ocrChange = ocrChange
        self.notifications = notifications
        self.confidence = confidence
        self.timestamp = timestamp
    }
}

public struct ElementResult: Codable {
    public let elementSignature: ElementSignature
    public let confidence: Double
    public let evidence: Evidence
    public let needsPermissions: [String]
    
    public init(
        elementSignature: ElementSignature,
        confidence: Double,
        evidence: Evidence,
        needsPermissions: [String] = []
    ) {
        self.elementSignature = elementSignature
        self.confidence = confidence
        self.evidence = evidence
        self.needsPermissions = needsPermissions
    }
}

public struct Policy: Codable {
    public let allowPeek: Bool
    public let minConfidence: Double
    public let maxPeekMs: Int
    public let rateLimitPeekSeconds: Int
    
    public static let `default` = Policy(
        allowPeek: true,
        minConfidence: 0.8,
        maxPeekMs: 250,
        rateLimitPeekSeconds: 10
    )
    
    public init(
        allowPeek: Bool = true,
        minConfidence: Double = 0.8,
        maxPeekMs: Int = 250,
        rateLimitPeekSeconds: Int = 10
    ) {
        self.allowPeek = allowPeek
        self.minConfidence = minConfidence
        self.maxPeekMs = maxPeekMs
        self.rateLimitPeekSeconds = rateLimitPeekSeconds
    }
}

// MARK: - Snapshot Models

public struct ElementSnapshot: Codable {
    public let elementId: String
    public let role: String
    public let frame: CGRect
    public let value: String?
    public let childCount: Int
    public let textLength: Int
    public let timestamp: TimeInterval
    
    public init(
        elementId: String,
        role: String,
        frame: CGRect,
        value: String? = nil,
        childCount: Int = 0,
        textLength: Int = 0,
        timestamp: TimeInterval = Date().timeIntervalSince1970
    ) {
        self.elementId = elementId
        self.role = role
        self.frame = frame
        self.value = value
        self.childCount = childCount
        self.textLength = textLength
        self.timestamp = timestamp
    }
}

public struct SnapshotDiff: Codable {
    public let replyChangeDetected: Bool
    public let childCountDelta: Int
    public let textLengthDelta: Int
    public let structuralChanges: [String]
    public let confidence: Double
    
    public init(
        replyChangeDetected: Bool,
        childCountDelta: Int = 0,
        textLengthDelta: Int = 0,
        structuralChanges: [String] = [],
        confidence: Double
    ) {
        self.replyChangeDetected = replyChangeDetected
        self.childCountDelta = childCountDelta
        self.textLengthDelta = textLengthDelta
        self.structuralChanges = structuralChanges
        self.confidence = confidence
    }
}
