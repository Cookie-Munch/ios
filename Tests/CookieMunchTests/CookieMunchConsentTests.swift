import XCTest
@testable import CookieMunch

/// Records every POST instead of hitting the network. Optionally fails, to prove the
/// client is offline-safe.
actor MockTransport: ConsentTransport {
    struct Request: Sendable {
        let url: URL
        let headers: [String: String]
        let body: Data
    }

    private(set) var requests: [Request] = []
    private var shouldThrow: Bool

    init(shouldThrow: Bool = false) {
        self.shouldThrow = shouldThrow
    }

    func post(_ url: URL, headers: [String: String], body: Data) async throws {
        requests.append(Request(url: url, headers: headers, body: body))
        if shouldThrow {
            throw URLError(.notConnectedToInternet)
        }
    }

    func count() -> Int { requests.count }
    func last() -> Request? { requests.last }
}

/// A storage spy that also lets us seed a persisted value for `load` tests.
actor SpyStorage: ConsentStorage {
    private var store: [String: String]
    private(set) var sets = 0

    init(seed: [String: String] = [:]) { self.store = seed }

    func getItem(_ key: String) async -> String? { store[key] }
    func setItem(_ key: String, _ value: String) async { store[key] = value; sets += 1 }
    func removeItem(_ key: String) async { store[key] = nil }

    func value(_ key: String) -> String? { store[key] }
    func setCount() -> Int { sets }
}

@MainActor
final class CookieMunchConsentTests: XCTestCase {

    private func makeClient(
        storage: ConsentStorage = InMemoryConsentStorage(),
        transport: ConsentTransport = MockTransport(),
        region: String = "EU"
    ) -> CookieMunchConsent {
        CookieMunchConsent(
            cbid: "test-cbid",
            apiURL: "https://cmp.example.com/",
            storage: storage,
            transport: transport,
            region: region,
            now: { 1_700_000_000_000 },
            stamp: { "fixed-stamp" }
        )
    }

    func testDefaultsToImplied() {
        let client = makeClient()
        XCTAssertEqual(client.state.method, .implied)
        XCTAssertFalse(client.state.hasResponse)
        XCTAssertTrue(client.state.necessary)
        XCTAssertFalse(client.state.consented)
        XCTAssertEqual(client.state.region, "EU")
        XCTAssertEqual(client.state.stamp, "fixed-stamp")
    }

    func testAcceptGrantsAllAndPostsOnce() async {
        let transport = MockTransport()
        let client = makeClient(transport: transport)

        let result = await client.accept()

        XCTAssertEqual(result.method, .explicit)
        XCTAssertTrue(result.preferences)
        XCTAssertTrue(result.statistics)
        XCTAssertTrue(result.marketing)
        XCTAssertTrue(client.hasResponse)

        let count = await transport.count()
        XCTAssertEqual(count, 1)

        let req = await transport.last()
        let unwrapped = try! XCTUnwrap(req)
        XCTAssertEqual(unwrapped.url.absoluteString, "https://cmp.example.com/api/v1/consent")
        XCTAssertEqual(unwrapped.headers["X-CookieMunch-Region"], "EU")
        XCTAssertEqual(unwrapped.headers["Content-Type"], "application/json")

        let json = try! JSONSerialization.jsonObject(with: unwrapped.body) as! [String: Any]
        XCTAssertEqual(json["cbid"] as? String, "test-cbid")
        XCTAssertEqual(json["stamp"] as? String, "fixed-stamp")
        XCTAssertEqual(json["method"] as? String, "explicit")
        XCTAssertEqual(json["ver"] as? Int, 1)
        XCTAssertEqual(json["url"] as? String, "app://test-cbid")
        let choices = json["choices"] as! [String: Any]
        XCTAssertEqual(choices["preferences"] as? Bool, true)
        XCTAssertEqual(choices["statistics"] as? Bool, true)
        XCTAssertEqual(choices["marketing"] as? Bool, true)
    }

    func testDeclineDeniesAll() async {
        let client = makeClient()
        let result = await client.decline()
        XCTAssertEqual(result.method, .explicit)
        XCTAssertFalse(result.preferences)
        XCTAssertFalse(result.statistics)
        XCTAssertFalse(result.marketing)
        XCTAssertTrue(result.necessary)
    }

    func testSetMergesIndividualCategories() async {
        let client = makeClient()
        _ = await client.set(statistics: true)
        XCTAssertFalse(client.state.preferences)
        XCTAssertTrue(client.state.statistics)
        XCTAssertFalse(client.state.marketing)
        XCTAssertEqual(client.state.method, .explicit)

        _ = await client.set(marketing: true)
        XCTAssertTrue(client.state.statistics) // preserved
        XCTAssertTrue(client.state.marketing)
    }

    func testSubmitCustomChoices() async {
        let client = makeClient()
        let result = await client.submit(Choices(preferences: true, statistics: false, marketing: true))
        XCTAssertTrue(result.preferences)
        XCTAssertFalse(result.statistics)
        XCTAssertTrue(result.marketing)
    }

    func testOfflineSafeNeverThrows() async {
        let transport = MockTransport(shouldThrow: true)
        let storage = SpyStorage()
        let client = makeClient(storage: storage, transport: transport)

        // Must not throw despite the transport failing.
        let result = await client.accept()
        XCTAssertTrue(result.consented)

        // The decision was still persisted locally.
        let sets = await storage.setCount()
        XCTAssertGreaterThanOrEqual(sets, 1)
        let stored = await storage.value("CookieMunch")
        XCTAssertNotNil(stored)
    }

    func testLoadRestoresPersistedState() async {
        let persisted = ConsentState(
            preferences: true, statistics: false, marketing: true,
            method: .explicit, stamp: "restored", ver: 1, utc: 42, region: "US"
        )
        let raw = String(data: try! JSONEncoder().encode(persisted), encoding: .utf8)!
        let storage = SpyStorage(seed: ["CookieMunch": raw])
        let client = makeClient(storage: storage)

        let result = await client.load()
        XCTAssertTrue(result.hasResponse)
        XCTAssertTrue(result.preferences)
        XCTAssertFalse(result.statistics)
        XCTAssertTrue(result.marketing)
        XCTAssertEqual(result.stamp, "restored")
        XCTAssertEqual(result.region, "US")
    }

    func testLoadWithCorruptDataKeepsDefault() async {
        let storage = SpyStorage(seed: ["CookieMunch": "not-json"])
        let client = makeClient(storage: storage)
        let result = await client.load()
        XCTAssertEqual(result.method, .implied)
        XCTAssertFalse(result.hasResponse)
    }

    func testGateRunsImmediatelyWhenAlreadyGranted() async {
        let client = makeClient()
        _ = await client.accept()

        var ran = 0
        client.gate(.marketing) { ran += 1 }
        XCTAssertEqual(ran, 1)
    }

    func testGateFiresOnceWhenGranted() async {
        let client = makeClient()

        var ran = 0
        client.gate(.statistics) { ran += 1 }
        XCTAssertEqual(ran, 0) // not granted yet

        _ = await client.accept()
        XCTAssertEqual(ran, 1) // fired on grant

        // Necessary is always granted.
        var necessaryRan = 0
        client.gate(.necessary) { necessaryRan += 1 }
        XCTAssertEqual(necessaryRan, 1)
    }

    func testGateNotFiredWhenCategoryDenied() async {
        let client = makeClient()
        var ran = 0
        client.gate(.marketing) { ran += 1 }
        _ = await client.decline()
        XCTAssertEqual(ran, 0)
    }

    func testOnChangeCallbackAndCancel() async {
        let client = makeClient()
        var received: [ConsentMethod] = []
        let cancel = client.onChange { state in received.append(state.method) }

        _ = await client.accept()
        XCTAssertEqual(received, [.explicit])

        cancel()
        _ = await client.decline()
        XCTAssertEqual(received, [.explicit]) // no further callbacks after cancel
    }

    func testInMemoryStorageRoundTrips() async {
        let storage = InMemoryConsentStorage()
        await storage.setItem("k", "v")
        let got = await storage.getItem("k")
        XCTAssertEqual(got, "v")
        await storage.removeItem("k")
        let gone = await storage.getItem("k")
        XCTAssertNil(gone)
    }
}
