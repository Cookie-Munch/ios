import Foundation

/// How the current decision was made. Mirrors the web/RN SDK so records are uniform
/// across platforms: `implied` is the pre-interaction default; `explicit` once the user
/// has actually chosen.
public enum ConsentMethod: String, Codable, Sendable {
    case explicit
    case implied
}

/// The four standard consent categories. `necessary` is always granted.
public enum ConsentCategory: String, CaseIterable, Sendable {
    case necessary
    case preferences
    case statistics
    case marketing
}

/// The three user-controllable choices sent on the wire (matches the RN `MobileChoices`
/// and the `POST /api/v1/consent` `choices` object). `necessary` is implicit and never
/// part of this payload.
public struct Choices: Codable, Equatable, Sendable {
    public var preferences: Bool
    public var statistics: Bool
    public var marketing: Bool

    public init(preferences: Bool = false, statistics: Bool = false, marketing: Bool = false) {
        self.preferences = preferences
        self.statistics = statistics
        self.marketing = marketing
    }

    /// Everything opted in.
    public static let all = Choices(preferences: true, statistics: true, marketing: true)
    /// Everything opted out (necessary still applies).
    public static let none = Choices(preferences: false, statistics: false, marketing: false)

    public func granted(_ category: ConsentCategory) -> Bool {
        switch category {
        case .necessary:   return true
        case .preferences: return preferences
        case .statistics:  return statistics
        case .marketing:   return marketing
        }
    }
}

/// Full local consent state. `necessary` is always true and is never persisted or sent
/// (it's implied). Mirrors the RN `MobileConsentState`.
public struct ConsentState: Codable, Equatable, Sendable {
    public var preferences: Bool
    public var statistics: Bool
    public var marketing: Bool
    public var method: ConsentMethod
    public var stamp: String
    public var ver: Int
    public var utc: Int64
    public var region: String

    public init(
        preferences: Bool = false,
        statistics: Bool = false,
        marketing: Bool = false,
        method: ConsentMethod = .implied,
        stamp: String = UUID().uuidString,
        ver: Int = 1,
        utc: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        region: String = "unknown"
    ) {
        self.preferences = preferences
        self.statistics = statistics
        self.marketing = marketing
        self.method = method
        self.stamp = stamp
        self.ver = ver
        self.utc = utc
        self.region = region
    }

    /// Necessary cookies are always allowed.
    public var necessary: Bool { true }

    /// The wire-shaped choices for this state.
    public var choices: Choices {
        Choices(preferences: preferences, statistics: statistics, marketing: marketing)
    }

    /// True once the user has made an explicit decision (the banner can dismiss).
    public var hasResponse: Bool { method == .explicit }

    /// True if any non-necessary category is granted.
    public var consented: Bool { preferences || statistics || marketing }

    public func granted(_ category: ConsentCategory) -> Bool {
        category == .necessary ? true : choices.granted(category)
    }
}
