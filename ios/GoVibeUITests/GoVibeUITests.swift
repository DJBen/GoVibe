import XCTest

final class GoVibeUITests: XCTestCase {
    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testMainScreenElementsExist() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.buttons["Auth"].waitForExistence(timeout: 5), "Auth button label missing. UI tree: \(app.debugDescription)")
        XCTAssertTrue(app.buttons["Connect Relay"].exists)
        XCTAssertTrue(app.buttons["Start Pair"].exists)
        XCTAssertTrue(app.buttons["Create Session"].exists)
        XCTAssertTrue(app.buttons["Send"].exists)
    }
}
