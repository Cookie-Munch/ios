import XCTest
@testable import CookieMunch

/// The banner's words come from the server, in the visitor's language, on the same call
/// that brings the regulatory regime — a phone cannot carry forty catalogues, and five SDKs
/// each carrying their own is five chances to disagree about one banner.
final class LocalizedCopyTests: XCTestCase {
    /// A transport that answers one canned config body and records what was asked for.
    private final class StubTransport: ConsentTransport, @unchecked Sendable {
        let body: String
        private(set) var lastURL: URL?
        private(set) var lastHeaders: [String: String] = [:]

        init(body: String) { self.body = body }

        func post(_ url: URL, headers: [String: String], body: Data) async throws {}

        func get(_ url: URL, headers: [String: String]) async throws -> Data {
            lastURL = url
            lastHeaders = headers
            return Data(body.utf8)
        }
    }

    private let json = """
    {
      "regulation": null,
      "copy": {
        "language": "ja",
        "rtl": false,
        "banner": { "title": "プライバシーを尊重します", "acceptAll": "すべて許可", "rejectAll": "すべて拒否" },
        "categories": { "marketing": { "label": "マーケティング", "description": "…" } },
        "reopen": "Cookie設定"
      }
    }
    """

    @MainActor
    func testAdoptsTheServersCopy() async {
        let transport = StubTransport(body: json)
        let consent = CookieMunchConsent(cbid: "cb-1", apiURL: "https://api.example", transport: transport)
        await consent.refreshRegulation()
        XCTAssertEqual(consent.copy?.banner.acceptAll, "すべて許可")
        XCTAssertEqual(consent.copy?.categories["marketing"]?.label, "マーケティング")
        XCTAssertEqual(consent.copy?.reopen, "Cookie設定")
    }

    @MainActor
    func testAsksForThisDevicesLanguage() async {
        let transport = StubTransport(body: json)
        let consent = CookieMunchConsent(cbid: "cb-1", apiURL: "https://api.example", transport: transport)
        await consent.refreshRegulation()
        XCTAssertTrue(transport.lastURL?.query?.contains("lang=") == true)
        XCTAssertNotNil(transport.lastHeaders["Accept-Language"])
    }

    /// Offline, the prompt still has to ask. Nil copy is the English fallback, not a blank banner.
    @MainActor
    func testKeepsWorkingWithoutTheServer() async {
        let consent = CookieMunchConsent(cbid: "cb-1", apiURL: "https://api.example")
        await consent.refreshRegulation()
        XCTAssertNil(consent.copy)
        XCTAssertTrue(consent.isConsentRequired)
    }
}
