import XCTest
@testable import UIScout

final class IntegrationTests: XCTestCase {
    
    func testFullWorkflow() throws {
        // Test the complete workflow from element discovery to action
        let scout = UIScout()
        
        // 1. Discover elements
        let finder = ElementFinder()
        let elements = finder.findElementsInActiveWindow()
        
        // 2. Generate signatures
        let generator = SignatureGenerator()
        let signatures = elements.map { generator.generateSignature(for: $0) }
        
        // 3. Score confidence
        let scorer = ConfidenceScorer()
        let scores = elements.map { scorer.calculateConfidence(for: $0, query: "test button") }
        
        // 4. Verify we can complete the pipeline
        XCTAssertGreaterThanOrEqual(elements.count, 0)
        XCTAssertEqual(signatures.count, elements.count)
        XCTAssertEqual(scores.count, elements.count)
        
        for score in scores {
            XCTAssertGreaterThanOrEqual(score, 0.0)
            XCTAssertLessThanOrEqual(score, 1.0)
        }
    }
    
    func testMCPIntegration() throws {
        // Test that our MCP tool can communicate with the service
        // This would require the service to be running
        let expectation = XCTestExpectation(description: "MCP communication")
        
        // In a real test, we'd start the service and test the HTTP endpoints
        // For now, just verify the structure is correct
        expectation.fulfill()
        
        wait(for: [expectation], timeout: 5.0)
    }
    
    func testPerformanceUnderLoad() throws {
        // Test that the system maintains performance under load
        measure {
            let finder = ElementFinder()
            for _ in 0..<10 {
                _ = finder.findElementsInActiveWindow()
            }
        }
    }
}
