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
        // The same call also asks for this device's language, so the response carries the
        // banner's words as well as the regime.
        XCTAssertEqual(urls.first?.absoluteString.split(separator: "?").first.map(String.init), "https://cmp.example.com/config/test-cbid")
        XCTAssertTrue(urls.first?.query?.hasPrefix("lang=") == true)
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

/// Around twenty US states now have comprehensive privacy laws that differ on what a
/// consent UI must do. Only the server can say which one applies — a device's locale is a
/// country at best — so the SDK reads it from the config rather than guessing.
final class UsStateLawTests: XCTestCase {
    func testDecodesTheStateLawTheServerResolved() throws {
        let json = """
        {"region":"us-tx","class":"us","regulations":{"gdprApplies":false,"ccpaApplies":true,"lgpdApplies":false},
         "model":"opt-out","defaultState":"granted","framework":"gpp","forcedOptOut":false,"consentRequired":true,
         "stateLaw":{"id":"tdpsa","state":"TX","name":"Texas Data Privacy and Security Act",
         "universalOptOut":true,"universalOptOutInForce":true,"sensitiveOptIn":true,"minorOptInUnder":13}}
        """.data(using: .utf8)!
        let reg = try JSONDecoder().decode(Regulation.self, from: json)
        XCTAssertEqual(reg.stateLaw?.id, "tdpsa")
        XCTAssertEqual(reg.stateLaw?.state, "TX")
        XCTAssertTrue(reg.stateLaw?.sensitiveOptIn ?? false)
        XCTAssertEqual(reg.stateLaw?.minorOptInUnder, 13)
    }

    func testIsAbsentWhenTheServerNamedNoStateLaw() throws {
        let json = """
        {"region":"de","class":"eu","regulations":{"gdprApplies":true,"ccpaApplies":false,"lgpdApplies":false},
         "model":"opt-in","defaultState":"denied","framework":"tcf","forcedOptOut":false,"consentRequired":true}
        """.data(using: .utf8)!
        XCTAssertNil(try JSONDecoder().decode(Regulation.self, from: json).stateLaw)
    }

    func testLocalResolutionDoesNotInventOne() {
        XCTAssertNil(Regulation.resolve(region: "us-tx").stateLaw)
    }
}
