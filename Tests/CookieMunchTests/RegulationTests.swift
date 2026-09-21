import XCTest
@testable import CookieMunch

/// A native app's first question is not "what did they consent to" but "do I have to
/// ask at all". Getting that wrong in either direction is expensive: prompt a Texan
/// under GDPR rules and you have tanked your opt-in rate for nothing; skip the prompt
/// for a German and you are non-compliant.
final class RegulationTests: XCTestCase {

    func testEuropeIsGdprOptIn() {
        let reg = Regulation.resolve(region: "de")
        XCTAssertEqual(reg.regionClass, .eu)
        XCTAssertTrue(reg.gdprApplies)
        XCTAssertFalse(reg.ccpaApplies)
        XCTAssertEqual(reg.model, .optIn)
        XCTAssertEqual(reg.defaultState, .denied)
        XCTAssertEqual(reg.framework, .tcf)
    }

    func testUnitedKingdomCountsAsEurope() {
        XCTAssertEqual(Regulation.resolve(region: "gb").regionClass, .eu)
        XCTAssertEqual(Regulation.resolve(region: "uk").regionClass, .eu)
    }

    func testCaliforniaIsCcpaOptOut() {
        let reg = Regulation.resolve(region: "us-ca")
        XCTAssertEqual(reg.regionClass, .us)
        XCTAssertTrue(reg.ccpaApplies)
        XCTAssertEqual(reg.model, .optOut)
        XCTAssertEqual(reg.defaultState, .granted)
        XCTAssertEqual(reg.framework, .gpp)
    }

    func testBrazilIsLgpd() {
        let reg = Regulation.resolve(region: "br")
        XCTAssertTrue(reg.lgpdApplies)
        XCTAssertEqual(reg.model, .optIn)
    }

    func testRegionIsCaseInsensitiveAndTolerantOfSubdivisions() {
        XCTAssertEqual(Regulation.resolve(region: "FR").regionClass, .eu)
        XCTAssertEqual(Regulation.resolve(region: "US-NY").regionClass, .us)
    }

    /// The safest default. An unknown region is treated as opt-in, so a geo lookup
    /// that fails never silently downgrades someone's protections.
    func testUnknownRegionFallsBackToOptIn() {
        for region in ["", "unknown", "zz"] {
            let reg = Regulation.resolve(region: region)
            XCTAssertEqual(reg.model, .optIn, "region \(region)")
            XCTAssertEqual(reg.defaultState, .denied, "region \(region)")
        }
    }

    func testGpcForcesOptOutOnlyWhereCollectionWouldOtherwiseProceed() {
        XCTAssertTrue(Regulation.resolve(region: "us-ca", gpc: true).forcedOptOut)
        // Under GDPR nothing fires before consent, so there is nothing for GPC to stop.
        XCTAssertFalse(Regulation.resolve(region: "de", gpc: true).forcedOptOut)
    }

    func testDoNotTrackForcesOptOutAndCanBeDisabled() {
        XCTAssertTrue(Regulation.resolve(region: "us-tx", dnt: true).forcedOptOut)
        XCTAssertFalse(Regulation.resolve(region: "us-tx", dnt: true, honorDnt: false).forcedOptOut)
    }

    func testConsentRequiredIsFalseOnlyWhenTheySignalledAlready() {
        XCTAssertTrue(Regulation.resolve(region: "de").consentRequired)
        XCTAssertTrue(Regulation.resolve(region: "us-ca").consentRequired)
        XCTAssertFalse(Regulation.resolve(region: "us-ca", gpc: true).consentRequired)
    }

    // MARK: Decoding the server's answer

    /// The device's own locale says where the phone was SOLD, not where the person is
    /// standing. The server resolves from the request IP, so its answer wins.
    func testDecodesTheServerPayload() throws {
        let json = """
        {"region":"us-ca","class":"us",
         "regulations":{"gdprApplies":false,"ccpaApplies":true,"lgpdApplies":false},
         "model":"opt-out","defaultState":"granted","framework":"gpp",
         "forcedOptOut":true,"consentRequired":false}
        """.data(using: .utf8)!
        let reg = try JSONDecoder().decode(Regulation.self, from: json)
        XCTAssertEqual(reg.region, "us-ca")
        XCTAssertEqual(reg.regionClass, .us)
        XCTAssertTrue(reg.ccpaApplies)
        XCTAssertEqual(reg.model, .optOut)
        XCTAssertEqual(reg.framework, .gpp)
        XCTAssertTrue(reg.forcedOptOut)
        XCTAssertFalse(reg.consentRequired)
    }

    /// A server that grows a new region class must not crash an app built today.
    func testUnrecognisedClassDecodesAsOtherRatherThanThrowing() throws {
        let json = """
        {"region":"jp","class":"apac",
         "regulations":{"gdprApplies":false,"ccpaApplies":false,"lgpdApplies":false},
         "model":"opt-in","defaultState":"denied","framework":"none",
         "forcedOptOut":false,"consentRequired":true}
        """.data(using: .utf8)!
        let reg = try JSONDecoder().decode(Regulation.self, from: json)
        XCTAssertEqual(reg.regionClass, .other)
        XCTAssertEqual(reg.model, .optIn)
    }
}
