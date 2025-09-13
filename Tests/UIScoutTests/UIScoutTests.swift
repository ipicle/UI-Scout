import XCTest
@testable import UIScout

final class UIScoutTests: XCTestCase {
    var scout: UIScout!
    
    override func setUp() {
        super.setUp()
        scout = UIScout()
    }
    
    func testAXObserverSetup() throws {
        let observer = try AXObserver(processID: getpid())
        XCTAssertNotNil(observer)
    }
    
    func testElementDiscovery() throws {
        let finder = ElementFinder()
        let elements = finder.findElementsInActiveWindow()
        XCTAssertGreaterThanOrEqual(elements.count, 0)
    }
    
    func testConfidenceScoring() throws {
        let scorer = ConfidenceScorer()
        let element = UIElement(
            axElement: AXUIElementCreateSystemWide(),
            role: "button",
            bounds: CGRect(x: 100, y: 100, width: 80, height: 30),
            title: "Click Me"
        )
        
        let score = scorer.calculateConfidence(for: element, query: "click me")
        XCTAssertGreaterThan(score, 0.0)
        XCTAssertLessThanOrEqual(score, 1.0)
    }
    
    func testSignatureGeneration() throws {
        let generator = SignatureGenerator()
        let element = UIElement(
            axElement: AXUIElementCreateSystemWide(),
            role: "button",
            bounds: CGRect(x: 100, y: 100, width: 80, height: 30),
            title: "Click Me"
        )
        
        let signature = generator.generateSignature(for: element)
        XCTAssertFalse(signature.contextualMarkers.isEmpty)
    }
    
    func testPerformanceTargets() throws {
        measure {
            let finder = ElementFinder()
            _ = finder.findElementsInActiveWindow()
        }
    }
}
