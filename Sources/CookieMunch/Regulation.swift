import Foundation

/// Which privacy regime applies to this person, and what that means for the app.
///
/// A native port of `packages/geo/src/index.ts` — the same table, so an iOS app, an
/// Android app and the web embed cannot disagree about someone's rights. Resolving
/// locally costs nothing and works offline, but see `CookieMunchConsent.refreshRegulation()`:
/// a device's locale says where the phone was sold, not where its owner is standing,
/// so the server's IP-derived answer is the authoritative one.
public struct Regulation: Codable, Equatable, Sendable {

    public enum RegionClass: String, Codable, Sendable {
        case eu, us, br, ca, other
    }

    /// Opt-in ("ask before anything fires") vs opt-out ("fire, but honour a refusal").
    public enum Model: String, Codable, Sendable {
        case optIn = "opt-in"
        case optOut = "opt-out"
    }

    public enum DefaultState: String, Codable, Sendable {
        case denied, granted
    }

    /// The signalling framework third parties on this page will read.
    public enum Framework: String, Codable, Sendable {
        case tcf, gpp, none
    }

    public struct Regulations: Codable, Equatable, Sendable {
        public let gdprApplies: Bool
        public let ccpaApplies: Bool
        public let lgpdApplies: Bool

        public init(gdprApplies: Bool, ccpaApplies: Bool, lgpdApplies: Bool) {
            self.gdprApplies = gdprApplies
            self.ccpaApplies = ccpaApplies
            self.lgpdApplies = lgpdApplies
        }
    }

    /// The region this was resolved from, as an ISO 3166-1 alpha-2 code, optionally
    /// with a subdivision (`"us-ca"`).
    public let region: String
    public let regionClass: RegionClass
    public let regulations: Regulations
    public let model: Model
    public let defaultState: DefaultState
    public let framework: Framework
    /// A browser/OS-level signal (GPC, DNT) already expressed a refusal for this person.
    public let forcedOptOut: Bool
    /// Whether a decision still has to be collected. See `CookieMunchConsent.isConsentRequired`,
    /// which also accounts for a decision this person already made in the app.
    public let consentRequired: Bool
    /// The US state law governing this person, when the server resolved one.
    ///
    /// Around twenty states now have comprehensive laws and they differ on what a consent
    /// UI must do. Only the server can say which applies — a device's locale gives a
    /// country at best, never a state — so this is nil when the regime was resolved on
    /// device, and populated from `/config/:cbid`.
    public let stateLaw: UsStateLaw?

    /// One US state privacy law, as the server resolved it.
    public struct UsStateLaw: Codable, Equatable, Sendable {
        /// Stable id, e.g. `"tdpsa"`.
        public let id: String
        /// Two-letter state code.
        public let state: String
        public let name: String
        /// The law requires honouring a universal opt-out signal.
        public let universalOptOut: Bool
        /// Sensitive data needs opt-in consent rather than an opt-out.
        public let sensitiveOptIn: Bool
        /// Opt-in required below this age for sale / targeted advertising; 0 = no rule.
        public let minorOptInUnder: Int

        private enum CodingKeys: String, CodingKey {
            case id, state, name, sensitiveOptIn, minorOptInUnder
            case universalOptOut, universalOptOutInForce
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            state = try c.decode(String.self, forKey: .state)
            name = (try? c.decode(String.self, forKey: .name)) ?? id
            // Prefer whether the duty is actually in force; fall back to whether the law
            // mandates it at all, for a server that predates the distinction.
            universalOptOut = (try? c.decode(Bool.self, forKey: .universalOptOutInForce))
                ?? (try? c.decode(Bool.self, forKey: .universalOptOut)) ?? false
            sensitiveOptIn = (try? c.decode(Bool.self, forKey: .sensitiveOptIn)) ?? false
            minorOptInUnder = (try? c.decode(Int.self, forKey: .minorOptInUnder)) ?? 0
        }

        /// Encoded back with the in-force spelling, so a round trip through the SDK
        /// keeps the meaning the server sent rather than the looser `universalOptOut`.
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(state, forKey: .state)
            try c.encode(name, forKey: .name)
            try c.encode(universalOptOut, forKey: .universalOptOutInForce)
            try c.encode(sensitiveOptIn, forKey: .sensitiveOptIn)
            try c.encode(minorOptInUnder, forKey: .minorOptInUnder)
        }

        public init(id: String, state: String, name: String, universalOptOut: Bool, sensitiveOptIn: Bool, minorOptInUnder: Int) {
            self.id = id
            self.state = state
            self.name = name
            self.universalOptOut = universalOptOut
            self.sensitiveOptIn = sensitiveOptIn
            self.minorOptInUnder = minorOptInUnder
        }
    }

    // Convenience accessors — `reg.gdprApplies` reads better than `reg.regulations.gdprApplies`
    // at the call site, which is almost always a single `if`.
    public var gdprApplies: Bool { regulations.gdprApplies }
    public var ccpaApplies: Bool { regulations.ccpaApplies }
    public var lgpdApplies: Bool { regulations.lgpdApplies }

    // MARK: Codable

    // `class` is a Swift keyword, so the wire name is mapped rather than inferred.
    private enum CodingKeys: String, CodingKey {
        case region, regulations, model, defaultState, framework, forcedOptOut, consentRequired, stateLaw
        case regionClass = "class"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        region = try c.decode(String.self, forKey: .region)
        regulations = try c.decode(Regulations.self, forKey: .regulations)
        forcedOptOut = try c.decode(Bool.self, forKey: .forcedOptOut)
        consentRequired = try c.decode(Bool.self, forKey: .consentRequired)
        // Decode the enums leniently. A server that learns about a new jurisdiction
        // tomorrow must not crash an app built today; an unknown value degrades to the
        // safest reading rather than throwing.
        regionClass = RegionClass(rawValue: try c.decode(String.self, forKey: .regionClass)) ?? .other
        model = Model(rawValue: try c.decode(String.self, forKey: .model)) ?? .optIn
        defaultState = DefaultState(rawValue: try c.decode(String.self, forKey: .defaultState)) ?? .denied
        framework = Framework(rawValue: try c.decode(String.self, forKey: .framework)) ?? .none
        stateLaw = try? c.decodeIfPresent(UsStateLaw.self, forKey: .stateLaw)
    }

    public init(
        region: String,
        regionClass: RegionClass,
        regulations: Regulations,
        model: Model,
        defaultState: DefaultState,
        framework: Framework,
        forcedOptOut: Bool,
        consentRequired: Bool,
        stateLaw: UsStateLaw? = nil
    ) {
        self.region = region
        self.regionClass = regionClass
        self.regulations = regulations
        self.model = model
        self.defaultState = defaultState
        self.framework = framework
        self.forcedOptOut = forcedOptOut
        self.consentRequired = consentRequired
        self.stateLaw = stateLaw
    }

    // MARK: Resolution

    // EU 27 + EEA + UK, lowercase ISO 3166-1 alpha-2.
    private static let euEeaUk: Set<String> = [
        "at", "be", "bg", "hr", "cy", "cz", "dk", "ee", "fi", "fr", "de", "gr", "hu", "ie",
        "it", "lv", "lt", "lu", "mt", "nl", "pl", "pt", "ro", "sk", "si", "es", "se",
        "is", "li", "no",
        "gb", "uk",
    ]

    public static func classify(region: String?) -> RegionClass {
        guard let region, !region.isEmpty else { return .other }
        let country = region.lowercased().split(separator: "-").first.map(String.init) ?? ""
        if euEeaUk.contains(country) { return .eu }
        if country == "us" { return .us }
        if country == "br" { return .br }
        if country == "ca" { return .ca }
        return .other
    }

    /// Resolve the regime for a region and the opt-out signals available on device.
    ///
    /// - Parameters:
    ///   - region: ISO 3166-1 alpha-2, optionally with a subdivision (`"us-ca"`).
    ///   - gpc: Global Privacy Control, if your app surfaces one.
    ///   - dnt: the legacy Do Not Track signal.
    ///   - honorDnt: treat `dnt` as a refusal. Default `true`.
    ///   - unknownModel: the regime for regions we don't recognise. Default `.optIn`,
    ///     which is the safe direction to be wrong in.
    public static func resolve(
        region: String?,
        gpc: Bool = false,
        dnt: Bool = false,
        honorDnt: Bool = true,
        unknownModel: Model = .optIn
    ) -> Regulation {
        let cls = classify(region: region)

        let regulations = Regulations(
            gdprApplies: cls == .eu,
            ccpaApplies: cls == .us,
            lgpdApplies: cls == .br
        )

        let model: Model
        let framework: Framework
        switch cls {
        case .us:
            model = .optOut
            framework = .gpp
        case .eu:
            model = .optIn
            framework = .tcf
        case .br, .ca:
            model = .optIn
            framework = .none
        case .other:
            model = unknownModel
            framework = .none
        }

        // GPC/DNT only matter where collection would otherwise proceed. Under an opt-in
        // regime nothing fires before consent anyway, so there is nothing to force.
        let forcedOptOut = model == .optOut && (gpc || (honorDnt && dnt))

        return Regulation(
            region: region ?? "",
            regionClass: cls,
            regulations: regulations,
            model: model,
            defaultState: model == .optIn ? .denied : .granted,
            framework: framework,
            forcedOptOut: forcedOptOut,
            consentRequired: !forcedOptOut
        )
    }
}
