// Tests are limited to pure-model smoke checks and gated for environments without XCTest
#if canImport(XCTest)
import XCTest
@testable import UIScoutCore

final class UIScoutCoreSmokeTests: XCTestCase {
    func testConfidenceCategorization() {
        let scorer = ConfidenceScorer()
        XCTAssertEqual(scorer.categorizeConfidence(0.95), .high)
        XCTAssertEqual(scorer.categorizeConfidence(0.75), .medium)
        XCTAssertEqual(scorer.categorizeConfidence(0.3), .low)
    }
}
#endif
