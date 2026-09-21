import XCTest
@testable import CookieMunch

/// Serves a canned `/config/:cbid` body, and records what was asked for.
actor StubConfigTransport: ConsentTransport {
    private let payload: Data?
    private(set) var gets: [URL] = []
    private(set) var getHeaders: [[String: String]] = []

    init(json: String?) {
        payload = json?.data(using: .utf8)
    }

    func post(_ url: URL, headers: [String: String], body: Data) async throws {}

    func get(_ url: URL, headers: [String: String]) async throws -> Data {
        gets.append(url)
        getHeaders.append(headers)
        guard let payload else { throw URLError(.notConnectedToInternet) }
        return payload
    }

    func requested() -> [URL] { gets }
    func headers() -> [[String: String]] { getHeaders }
}

@MainActor
final class ConsentRegulationTests: XCTestCase {

    private func makeClient(
        region: String,
        transport: ConsentTransport = MockTransport()
    ) -> CookieMunchConsent {
        CookieMunchConsent(
            cbid: "test-cbid",
            apiURL: "https://cmp.example.com/",
            storage: InMemoryConsentStorage(),
            transport: transport,
            region: region,
            now: { 1_700_000_000_000 },
            stamp: { "fixed-stamp" }
        )
    }

    // MARK: Offline resolution

    func testResolvesFromTheConfiguredRegionWithoutAnyNetworkCall() {
        XCTAssertTrue(makeClient(region: "de").applicableRegulation.gdprApplies)
        XCTAssertTrue(makeClient(region: "us-ca").applicableRegulation.ccpaApplies)
    }

    func testConsentIsRequiredBeforeTheUserHasAnswered() {
        XCTAssertTrue(makeClient(region: "de").isConsentRequired)
    }

    /// The single most useful property in the whole API: once they have answered, stop
    /// asking. An app that re-prompts on every cold start is the reason people install
    /// content blockers.
    func testConsentIsNotRequiredOnceTheUserHasAnswered() async {
        let client = makeClient(region: "de")
        await client.accept()
        XCTAssertFalse(client.isConsentRequired)
    }

    func testConsentIsNotRequiredWhenAnOptOutSignalAlreadyAnsweredForThem() {
        let client = makeClient(region: "us-ca")
        XCTAssertTrue(client.isConsentRequired)
        client.setGlobalPrivacyControl(true)
        XCTAssertFalse(client.isConsentRequired)
        XCTAssertTrue(client.applicableRegulation.forcedOptOut)
    }

    /// GPC is a refusal, not a regime change. Under GDPR nothing fires before consent,
    /// so the prompt is still owed.
    func testGlobalPrivacyControlDoesNotSuppressAGdprPrompt() {
        let client = makeClient(region: "de")
        client.setGlobalPrivacyControl(true)
        XCTAssertTrue(client.isConsentRequired)
    }

    // MARK: Server refinement

    func testRefreshAdoptsTheServerAnswerOverTheLocalGuess() async {
        // A German-locale phone, physically in California. Locale says GDPR; the
        // server, which sees the IP, says CCPA — and the server is right.
        let transport = StubConfigTransport(json: """
        {"cbid":"test-cbid","region":"us-ca","regulation":{
          "region":"us-ca","class":"us",
          "regulations":{"gdprApplies":false,"ccpaApplies":true,"lgpdApplies":false},
          "model":"opt-out","defaultState":"granted","framework":"gpp",
          "forcedOptOut":false,"consentRequired":true}}
        """)
        let client = makeClient(region: "de", transport: transport)
        XCTAssertTrue(client.applicableRegulation.gdprApplies)

        await client.refreshRegulation()

        XCTAssertTrue(client.applicableRegulation.ccpaApplies)
        XCTAssertFalse(client.applicableRegulation.gdprApplies)
        XCTAssertEqual(client.applicableRegulation.model, .optOut)
    }

    func testRefreshCallsTheConfigEndpointAndSendsTheRegionHeader() async {
        let transport = StubConfigTransport(json: """
        {"regulation":{"region":"fr","class":"eu",
          "regulations":{"gdprApplies":true,"ccpaApplies":false,"lgpdApplies":false},
          "model":"opt-in","defaultState":"denied","framework":"tcf",
          "forcedOptOut":false,"consentRequired":true}}
        """)
        let client = makeClient(region: "fr", transport: transport)
        await client.refreshRegulation()

        let urls = await transport.requested()
        XCTAssertEqual(urls.first?.absoluteString, "https://cmp.example.com/config/test-cbid")
        let headers = await transport.headers()
        XCTAssertEqual(headers.first?["X-CookieMunch-Region"], "fr")
    }

    /// Offline, or a server that has not been upgraded yet. Either way the app keeps
    /// the locally-resolved regime and carries on — a failed refresh must never leave
    /// the app without an answer to "do I prompt".
    func testRefreshFailureLeavesTheLocalRegulationIntact() async {
        let client = makeClient(region: "de", transport: StubConfigTransport(json: nil))
        await client.refreshRegulation()
        XCTAssertTrue(client.applicableRegulation.gdprApplies)
        XCTAssertTrue(client.isConsentRequired)
    }

    func testRefreshIgnoresAResponseWithNoRegulationBlock() async {
        let client = makeClient(region: "de", transport: StubConfigTransport(json: #"{"cbid":"test-cbid"}"#))
        await client.refreshRegulation()
        XCTAssertTrue(client.applicableRegulation.gdprApplies)
    }

    /// A transport written before this feature existed still compiles and still works
    /// for everything else — the refresh just declines rather than trapping.
    func testATransportWithoutGetSupportDoesNotCrashTheApp() async {
        let client = makeClient(region: "de", transport: MockTransport())
        await client.refreshRegulation()
        XCTAssertTrue(client.applicableRegulation.gdprApplies)
    }
}
