import XCTest
@testable import CookieMunch

/// Prints the bridge output for a fixed state so it can be diffed against the
/// TypeScript implementation. A page must not be able to tell which platform seeded it.
final class CrossPlatformFixture: XCTestCase {
    func testPrintFixture() {
        let state = ConsentState(
            preferences: true, statistics: false, marketing: true, method: .explicit,
            stamp: "abc-123", ver: 1, utc: 1_700_000_000_000, region: "de"
        )
        print("SWIFT_JS>>>" + WebViewBridge.javaScript(for: state) + "<<<")
        print("SWIFT_QS>>>" + WebViewBridge.queryString(for: state) + "<<<")
    }
}
