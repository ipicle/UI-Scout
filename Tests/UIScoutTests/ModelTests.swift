#if canImport(XCTest)
import XCTest
@testable import UIScoutCore

final class ElementSignatureTests: XCTestCase {
    
    func testElementSignatureCreation() {
        let signature = ElementSignature(
            appBundleId: "com.test.app",
            elementType: .reply,
            role: "AXScrollArea",
            frameHash: "w100-h200-x0-y0@sha1"
        )
        
        XCTAssertEqual(signature.appBundleId, "com.test.app")
        XCTAssertEqual(signature.elementType, .reply)
        XCTAssertEqual(signature.role, "AXScrollArea")
        XCTAssertEqual(signature.frameHash, "w100-h200-x0-y0@sha1")
        XCTAssertEqual(signature.stability, 0.0)
    }
    
    func testFrameHashGeneration() {
        let hash1 = ElementSignature.generateFrameHash(width: 100, height: 200, x: 0, y: 0)
        let hash2 = ElementSignature.generateFrameHash(width: 100, height: 200, x: 0, y: 0)
        let hash3 = ElementSignature.generateFrameHash(width: 101, height: 200, x: 0, y: 0)
        
        XCTAssertEqual(hash1, hash2, "Same dimensions should produce same hash")
        XCTAssertNotEqual(hash1, hash3, "Different dimensions should produce different hashes")
        XCTAssertTrue(hash1.hasSuffix("@sha1"), "Hash should have SHA1 suffix")
    }
    
    func testElementSignatureCodable() throws {
        let original = ElementSignature(
            appBundleId: "com.test.app",
            elementType: .input,
            role: "AXTextField",
            subroles: ["AXSecure"],
            frameHash: "w100-h50-x10-y20@sha1",
            pathHint: ["Window[0]", "Group[1]", "TextField[0]"],
            siblingRoles: ["AXButton", "AXLabel"],
            readOnly: false,
            scrollable: false,
            attrs: ["AXValue": .string("test"), "AXEnabled": .bool(true)],
            stability: 0.85,
            lastVerifiedAt: 1699999999
        )
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ElementSignature.self, from: data)
        
        XCTAssertEqual(decoded.appBundleId, original.appBundleId)
        XCTAssertEqual(decoded.elementType, original.elementType)
        XCTAssertEqual(decoded.role, original.role)
        XCTAssertEqual(decoded.subroles, original.subroles)
        XCTAssertEqual(decoded.frameHash, original.frameHash)
        XCTAssertEqual(decoded.pathHint, original.pathHint)
        XCTAssertEqual(decoded.siblingRoles, original.siblingRoles)
        XCTAssertEqual(decoded.readOnly, original.readOnly)
        XCTAssertEqual(decoded.scrollable, original.scrollable)
        XCTAssertEqual(decoded.stability, original.stability, accuracy: 0.001)
        XCTAssertEqual(decoded.lastVerifiedAt, original.lastVerifiedAt, accuracy: 0.001)
    }
    
    func testAttributeValueCodable() throws {
        let values: [ElementSignature.AttributeValue?] = [
            .string("test"),
            .int(42),
            .bool(true),
            .null,
            nil
        ]
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(values)
        
        let decoder = JSONDecoder()
        let decoded = try decoder.decode([ElementSignature.AttributeValue?].self, from: data)
        
        XCTAssertEqual(decoded.count, values.count)
        
        // Check specific values
        if case .string(let str) = decoded[0] {
            XCTAssertEqual(str, "test")
        } else {
            XCTFail("Expected string value")
        }
        
        if case .int(let num) = decoded[1] {
            XCTAssertEqual(num, 42)
        } else {
            XCTFail("Expected int value")
        }
        
        if case .bool(let flag) = decoded[2] {
            XCTAssertTrue(flag)
        } else {
            XCTFail("Expected bool value")
        }
        
        if case .null = decoded[3] {
            // Correct
        } else {
            XCTFail("Expected null value")
        }
        
        XCTAssertNil(decoded[4])
    }
}

final class EvidenceTests: XCTestCase {
    
    func testEvidenceCreation() {
        let evidence = Evidence(
            method: .passive,
            heuristicScore: 0.8,
            diffScore: 0.2,
            ocrChange: false,
            notifications: ["AXValueChanged"],
            confidence: 0.75
        )
        
        XCTAssertEqual(evidence.method, .passive)
        XCTAssertEqual(evidence.heuristicScore, 0.8, accuracy: 0.001)
        XCTAssertEqual(evidence.diffScore, 0.2, accuracy: 0.001)
        XCTAssertFalse(evidence.ocrChange)
        XCTAssertEqual(evidence.notifications, ["AXValueChanged"])
        XCTAssertEqual(evidence.confidence, 0.75, accuracy: 0.001)
    }
    
    func testEvidenceCodable() throws {
        let original = Evidence(
            method: .ocr,
            heuristicScore: 0.6,
            diffScore: 0.4,
            ocrChange: true,
            notifications: ["AXChildrenChanged", "AXValueChanged"],
            confidence: 0.9,
            timestamp: 1699999999
        )
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Evidence.self, from: data)
        
        XCTAssertEqual(decoded.method, original.method)
        XCTAssertEqual(decoded.heuristicScore, original.heuristicScore, accuracy: 0.001)
        XCTAssertEqual(decoded.diffScore, original.diffScore, accuracy: 0.001)
        XCTAssertEqual(decoded.ocrChange, original.ocrChange)
        XCTAssertEqual(decoded.notifications, original.notifications)
        XCTAssertEqual(decoded.confidence, original.confidence, accuracy: 0.001)
        XCTAssertEqual(decoded.timestamp, original.timestamp, accuracy: 0.001)
    }
}

final class PolicyTests: XCTestCase {
    
    func testDefaultPolicy() {
        let policy = Policy.default
        
        XCTAssertTrue(policy.allowPeek)
        XCTAssertEqual(policy.minConfidence, 0.8, accuracy: 0.001)
        XCTAssertEqual(policy.maxPeekMs, 250)
        XCTAssertEqual(policy.rateLimitPeekSeconds, 10)
    }
    
    func testCustomPolicy() {
        let policy = Policy(
            allowPeek: false,
            minConfidence: 0.9,
            maxPeekMs: 100,
            rateLimitPeekSeconds: 5
        )
        
        XCTAssertFalse(policy.allowPeek)
        XCTAssertEqual(policy.minConfidence, 0.9, accuracy: 0.001)
        XCTAssertEqual(policy.maxPeekMs, 100)
        XCTAssertEqual(policy.rateLimitPeekSeconds, 5)
    }
    
    func testPolicyCodable() throws {
        let original = Policy(
            allowPeek: true,
            minConfidence: 0.7,
            maxPeekMs: 300,
            rateLimitPeekSeconds: 15
        )
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Policy.self, from: data)
        
        XCTAssertEqual(decoded.allowPeek, original.allowPeek)
        XCTAssertEqual(decoded.minConfidence, original.minConfidence, accuracy: 0.001)
        XCTAssertEqual(decoded.maxPeekMs, original.maxPeekMs)
        XCTAssertEqual(decoded.rateLimitPeekSeconds, original.rateLimitPeekSeconds)
    }
}

final class ElementSnapshotTests: XCTestCase {
    
    func testElementSnapshotCreation() {
        let snapshot = ElementSnapshot(
            elementId: "test-element-123",
            role: "AXScrollArea",
            frame: CGRect(x: 10, y: 20, width: 300, height: 400),
            value: "Test content",
            childCount: 5,
            textLength: 150
        )
        
        XCTAssertEqual(snapshot.elementId, "test-element-123")
        XCTAssertEqual(snapshot.role, "AXScrollArea")
        XCTAssertEqual(snapshot.frame, CGRect(x: 10, y: 20, width: 300, height: 400))
        XCTAssertEqual(snapshot.value, "Test content")
        XCTAssertEqual(snapshot.childCount, 5)
        XCTAssertEqual(snapshot.textLength, 150)
    }
    
    func testElementSnapshotCodable() throws {
        let original = ElementSnapshot(
            elementId: "test-123",
            role: "AXTextField",
            frame: CGRect(x: 0, y: 0, width: 200, height: 30),
            value: nil,
            childCount: 0,
            textLength: 0,
            timestamp: 1699999999
        )
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ElementSnapshot.self, from: data)
        
        XCTAssertEqual(decoded.elementId, original.elementId)
        XCTAssertEqual(decoded.role, original.role)
        XCTAssertEqual(decoded.frame, original.frame)
        XCTAssertEqual(decoded.value, original.value)
        XCTAssertEqual(decoded.childCount, original.childCount)
        XCTAssertEqual(decoded.textLength, original.textLength)
        XCTAssertEqual(decoded.timestamp, original.timestamp, accuracy: 0.001)
    }
}

final class SnapshotDiffTests: XCTestCase {
    
    func testSnapshotDiffCreation() {
        let diff = SnapshotDiff(
            replyChangeDetected: true,
            childCountDelta: 2,
            textLengthDelta: 150,
            structuralChanges: ["childCount: 3 → 5", "textLength: 100 → 250"],
            confidence: 0.85
        )
        
        XCTAssertTrue(diff.replyChangeDetected)
        XCTAssertEqual(diff.childCountDelta, 2)
        XCTAssertEqual(diff.textLengthDelta, 150)
        XCTAssertEqual(diff.structuralChanges.count, 2)
        XCTAssertEqual(diff.confidence, 0.85, accuracy: 0.001)
    }
    
    func testSnapshotDiffCodable() throws {
        let original = SnapshotDiff(
            replyChangeDetected: false,
            childCountDelta: 0,
            textLengthDelta: -50,
            structuralChanges: ["value changed"],
            confidence: 0.6
        )
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(SnapshotDiff.self, from: data)
        
        XCTAssertEqual(decoded.replyChangeDetected, original.replyChangeDetected)
        XCTAssertEqual(decoded.childCountDelta, original.childCountDelta)
        XCTAssertEqual(decoded.textLengthDelta, original.textLengthDelta)
        XCTAssertEqual(decoded.structuralChanges, original.structuralChanges)
        XCTAssertEqual(decoded.confidence, original.confidence, accuracy: 0.001)
    }
}

final class ElementResultTests: XCTestCase {
    
    func testElementResultCreation() {
        let signature = ElementSignature(
            appBundleId: "com.test.app",
            elementType: .reply,
            role: "AXScrollArea",
            frameHash: "test-hash"
        )
        
        let evidence = Evidence(
            method: .passive,
            heuristicScore: 0.8,
            diffScore: 0.2,
            confidence: 0.75
        )
        
        let result = ElementResult(
            elementSignature: signature,
            confidence: 0.75,
            evidence: evidence,
            needsPermissions: ["accessibility"]
        )
        
        XCTAssertEqual(result.confidence, 0.75, accuracy: 0.001)
        XCTAssertEqual(result.elementSignature.appBundleId, "com.test.app")
        XCTAssertEqual(result.evidence.method, .passive)
        XCTAssertEqual(result.needsPermissions, ["accessibility"])
    }
    
    func testElementResultCodable() throws {
        let signature = ElementSignature(
            appBundleId: "com.raycast.macos",
            elementType: .input,
            role: "AXTextField",
            frameHash: "w400-h30-x100-y500@sha1",
            stability: 0.9
        )
        
        let evidence = Evidence(
            method: .peek,
            heuristicScore: 0.7,
            diffScore: 0.3,
            ocrChange: false,
            confidence: 0.85
        )
        
        let original = ElementResult(
            elementSignature: signature,
            confidence: 0.85,
            evidence: evidence,
            needsPermissions: []
        )
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ElementResult.self, from: data)
        
        XCTAssertEqual(decoded.confidence, original.confidence, accuracy: 0.001)
        XCTAssertEqual(decoded.elementSignature.appBundleId, original.elementSignature.appBundleId)
        XCTAssertEqual(decoded.elementSignature.elementType, original.elementSignature.elementType)
        XCTAssertEqual(decoded.evidence.method, original.evidence.method)
        XCTAssertEqual(decoded.needsPermissions, original.needsPermissions)
    }
}

#endif
