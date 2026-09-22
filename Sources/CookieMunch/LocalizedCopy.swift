import Foundation

/// The banner's words in the visitor's language, resolved by the server.
///
/// Forty languages will not fit in an app binary, and five native SDKs each shipping their
/// own catalogue is five chances to disagree about what one banner says. So the platform
/// resolves the copy the same way it resolves the regulatory regime — once, server-side —
/// and this is that answer. It is nil until `refreshRegulation()` has run; the views fall
/// back to their English strings, so an app that has never reached the network still asks.
public struct LocalizedCopy: Codable, Equatable, Sendable {
    public struct Banner: Codable, Equatable, Sendable {
        public var title: String?
        public var body: String?
        public var acceptAll: String?
        public var rejectAll: String?
        public var save: String?
        public var customize: String?
        public var doNotSell: String?
        public var policyText: String?
    }

    public struct CategoryText: Codable, Equatable, Sendable {
        public var label: String
        public var description: String
    }

    /// The language actually used, which may be the site's default rather than the one asked for.
    public let language: String
    /// Written right to left. A view mirrors its layout rather than merely its text.
    public let rtl: Bool
    public let banner: Banner
    /// Keyed by category id: necessary, preferences, statistics, marketing.
    public let categories: [String: CategoryText]
    /// The label on the affordance that reopens the prompt.
    public let reopen: String
}

public extension LocalizedCopy {
    /// The language tag to ask the server for: what this device actually reads in.
    static var preferredLanguage: String {
        Locale.preferredLanguages.first ?? "en"
    }
}
