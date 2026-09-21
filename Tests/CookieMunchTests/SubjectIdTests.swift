import XCTest
@testable import CookieMunch

/// Linking a decision to a signed-in account, so one person's consent correlates across
/// web, iOS, Android and desktop. The server has always accepted `subjectId` — it is
/// validated, stored and bound into the hash chain — but only the React Native client
/// ever sent it, and only as a constructor argument, which is close to useless: an app
/// builds its consent client at launch, before anyone has signed in.
@MainActor
final class SubjectIdTests: XCTestCase {

    private func makeClient(subjectId: String? = nil, transport: MockTransport) -> CookieMunchConsent {
        CookieMunchConsent(
            cbid: "test-cbid",
            apiURL: "https://cmp.example.com",
            storage: InMemoryConsentStorage(),
            transport: transport,
            region: "de",
            storageKey: "CookieMunch",
            subjectId: subjectId,
            now: { 1_700_000_000_000 },
            stamp: { "fixed-stamp" }
        )
    }

    /// The last synced body. Does its own awaiting: XCTAssert* takes an autoclosure, and
    /// `await` is not allowed inside one.
    private func lastBody(_ transport: MockTransport) async throws -> [String: Any] {
        let recorded = await transport.last()   // hoisted: XCTUnwrap takes an autoclosure
        let request = try XCTUnwrap(recorded)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
    }

    private func sentSubjectId(_ transport: MockTransport) async throws -> String? {
        try await lastBody(transport)["subjectId"] as? String
    }

    func testNoSubjectIdIsSentWhenNoneIsSet() async throws {
        let transport = MockTransport()
        await makeClient(transport: transport).accept()
        let sent = try await sentSubjectId(transport)
        XCTAssertNil(sent)
    }

    func testAnIdSetAfterSignInIsAttachedToLaterDecisions() async throws {
        let transport = MockTransport()
        let client = makeClient(transport: transport)

        await client.accept()
        let beforeSignIn = try await sentSubjectId(transport)
        XCTAssertNil(beforeSignIn)

        client.setSubjectId("account-42")
        await client.decline()
        let afterSignIn = try await sentSubjectId(transport)
        XCTAssertEqual(afterSignIn, "account-42")
    }

    func testTheConstructorOptionStillWorks() async throws {
        let transport = MockTransport()
        await makeClient(subjectId: "account-42", transport: transport).accept()
        let sent = try await sentSubjectId(transport)
        XCTAssertEqual(sent, "account-42")
    }

    func testSettingItOverridesTheConstructorValue() async throws {
        let transport = MockTransport()
        let client = makeClient(subjectId: "from-init", transport: transport)
        client.setSubjectId("after-sign-in")
        await client.accept()
        let sent = try await sentSubjectId(transport)
        XCTAssertEqual(sent, "after-sign-in")
    }

    /// Signing out must detach the id. Continuing to send it would attribute the next
    /// person's decisions on a shared device to the account that just left.
    func testClearingItStopsTheIdBeingSent() async throws {
        let transport = MockTransport()
        let client = makeClient(subjectId: "account-42", transport: transport)
        client.setSubjectId(nil)
        await client.accept()
        let sent = try await sentSubjectId(transport)
        XCTAssertNil(sent)
    }

    func testAnEmptyStringClearsItRatherThanSendingAnEmptyId() async throws {
        let transport = MockTransport()
        let client = makeClient(subjectId: "account-42", transport: transport)
        client.setSubjectId("")
        await client.accept()
        let sent = try await sentSubjectId(transport)
        XCTAssertNil(sent)
        XCTAssertNil(client.currentSubjectId)
    }

    func testItIsReadableBack() {
        let client = makeClient(transport: MockTransport())
        XCTAssertNil(client.currentSubjectId)
        client.setSubjectId("account-42")
        XCTAssertEqual(client.currentSubjectId, "account-42")
    }

    /// Who is signed in is the app's business and can change between launches, so a
    /// stale account id baked into a restored record would attribute one person's
    /// consent to another.
    func testItIsNotPersistedWithTheDecision() async throws {
        let storage = SpyStorage()
        let client = CookieMunchConsent(
            cbid: "test-cbid",
            apiURL: "https://cmp.example.com",
            storage: storage,
            transport: MockTransport(),
            region: "de",
            subjectId: "account-42",
            now: { 1_700_000_000_000 },
            stamp: { "fixed-stamp" }
        )
        await client.accept()
        let stored = await storage.value("CookieMunch")
        XCTAssertNotNil(stored)
        XCTAssertFalse(stored!.contains("account-42"))
    }
}
