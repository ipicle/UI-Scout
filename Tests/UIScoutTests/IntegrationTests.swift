// Integration tests require system permissions and a running UI; skip by default.
#if canImport(XCTest)
import XCTest
@testable import UIScoutCore

final class IntegrationTests: XCTestCase {
    func testPlaceholderIntegrationSkipped() throws {
        throw XCTSkip("UI integration tests are disabled in CI by default.")
    }
}
#endif
