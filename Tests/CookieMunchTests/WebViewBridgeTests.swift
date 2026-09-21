import XCTest
@testable import CookieMunch

/// The bridge must produce exactly what the web embed reads. If these drift from
/// `packages/core/src/webview-bridge.ts`, a hybrid app silently asks twice.
final class WebViewBridgeTests: XCTestCase {
    private let state = ConsentState(
        preferences: true,
        statistics: false,
        marketing: true,
        method: .explicit,
        stamp: "abc-123",
        ver: 1,
        utc: 1_700_000_000_000,
        region: "de"
    )

    func testJavaScriptWritesTheCookieTheEmbedReads() {
        let js = WebViewBridge.javaScript(for: state)
        XCTAssertTrue(js.contains("document.cookie"))
        XCTAssertTrue(js.contains("CookieMunch="))
        XCTAssertTrue(js.contains("path=/"))
    }

    func testJavaScriptIsASingleLine() {
        // evaluateJavaScript takes a string; a multi-line program fails quietly.
        XCTAssertFalse(WebViewBridge.javaScript(for: state).contains("\n"))
    }

    func testJavaScriptCarriesTheRealDecision() {
        let js = WebViewBridge.javaScript(for: state)
        let decoded = js.removingPercentEncoding ?? js
        XCTAssertTrue(decoded.contains("\"marketing\":true"))
        XCTAssertTrue(decoded.contains("\"statistics\":false"))
    }

    func testHonoursMaxAge() {
        XCTAssertTrue(WebViewBridge.javaScript(for: state, maxAge: 60).contains("max-age=60"))
    }

    func testLegacyCookieForMigratingApps() {
        let js = WebViewBridge.javaScript(for: state, alsoLegacyCookie: true)
        XCTAssertTrue(js.contains("CookieConsent="))
        XCTAssertTrue(js.contains("CookieMunch="))
    }

    /// The value goes inside a single-quoted literal; a quote in it would break out.
    func testEscapesValuesThatCouldBreakTheStatement() {
        let tricky = ConsentState(
            preferences: true, statistics: true, marketing: true, method: .explicit,
            stamp: "a'\";alert(1)//", ver: 1, utc: 1, region: "de"
        )
        let js = WebViewBridge.javaScript(for: tricky)
        XCTAssertFalse(js.contains("';alert(1)"))
    }

    func testQueryStringIsUrlSafe() {
        let qs = WebViewBridge.queryString(for: state)
        XCTAssertTrue(qs.hasPrefix("cm_consent="))
        XCTAssertFalse(qs.contains(" "))
        XCTAssertFalse(qs.contains("\""))
    }

    func testUrlAppendPreservesExistingQuery() {
        let out = WebViewBridge.url(URL(string: "https://x.test/p?a=1")!, carrying: state)
        let items = URLComponents(url: out, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertTrue(items.contains { $0.name == "a" && $0.value == "1" })
        XCTAssertTrue(items.contains { $0.name == "cm_consent" })
    }

    func testUrlAppendReplacesRatherThanDuplicating() {
        let once = WebViewBridge.url(URL(string: "https://x.test/p")!, carrying: state)
        let twice = WebViewBridge.url(once, carrying: state)
        let items = URLComponents(url: twice, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.filter { $0.name == "cm_consent" }.count, 1)
    }
}
