import Foundation
#if canImport(Combine)
import Combine
#endif
#if canImport(AppTrackingTransparency)
import AppTrackingTransparency
#endif

/// CookieMunch iOS/macOS consent client — the framework-agnostic core of the SDK,
/// mirroring `packages/react-native/src/client.ts`.
///
/// - Standard `Choices` (necessary / preferences / statistics / marketing).
/// - `implied` default until the user chooses, then `explicit`.
/// - Pluggable `ConsentStorage` (in-memory, `UserDefaults`, or Keychain).
/// - `load` / `accept` / `decline` / `set` / `submit(custom)`.
/// - An `onChange` callback and — on Apple platforms — a Combine `@Published` state.
/// - Region-aware (sent as the `X-CookieMunch-Region` header).
/// - Offline-safe: the local decision is always persisted first and the API POST never
///   throws back into your code — a consent decision is never lost to a bad network.
/// - `gate(_:_:)` runs a closure once a category is granted — the native equivalent of
///   the web SDK's prior-blocking.
///
/// The client is `@MainActor` so it drops straight into SwiftUI as an `ObservableObject`.
@MainActor
public final class CookieMunchConsent: ObservableObject {

    // MARK: Published state

    /// The current consent state. On Apple platforms this is a Combine publisher (`$state`).
    @Published public private(set) var state: ConsentState

    // MARK: Configuration

    private let cbid: String
    private let apiURL: String
    private let storage: ConsentStorage
    private let transport: ConsentTransport
    private let storageKey: String
    private let region: String
    private let now: @Sendable () -> Int64
    private let stamp: @Sendable () -> String

    // MARK: Listeners & gates

    private var listeners: [UUID: (ConsentState) -> Void] = [:]
    private var pendingGates: [ConsentCategory: [() -> Void]] = [:]

    // MARK: Applicable regulation

    /// Set once the server has told us the regime for this person's real location.
    /// Until then `applicableRegulation` answers from the configured region.
    private var serverRegulation: Regulation?
    private var gpc = false
    private var dnt = false

    /// Who this device's decisions belong to, if the app has said. Deliberately NOT
    /// persisted with the decision: who is signed in is the app's business and can change
    /// between launches, so baking a stale account id into a restored record would
    /// attribute one person's consent to another.
    private var subjectId: String?

    /// - Parameters:
    ///   - cbid: your CookieMunch site id.
    ///   - apiURL: base URL of your CookieMunch API (e.g. `https://cmp.example.com`).
    ///   - storage: where the decision is persisted. Defaults to in-memory; use
    ///     `UserDefaultsConsentStorage()` or `KeychainConsentStorage()` in an app.
    ///   - transport: the network seam. Defaults to `URLSessionTransport()`.
    ///   - region: the user's region, sent as `X-CookieMunch-Region`.
    ///   - storageKey: the persistence key. Defaults to `"CookieMunch"`.
    public init(
        cbid: String,
        apiURL: String,
        storage: ConsentStorage = InMemoryConsentStorage(),
        transport: ConsentTransport = URLSessionTransport(),
        region: String = "unknown",
        storageKey: String = "CookieMunch",
        subjectId: String? = nil,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
        stamp: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.cbid = cbid
        self.apiURL = apiURL.hasSuffix("/") ? String(apiURL.dropLast()) : apiURL
        self.storage = storage
        self.transport = transport
        self.region = region
        self.storageKey = storageKey
        self.subjectId = (subjectId?.isEmpty ?? true) ? nil : subjectId
        self.now = now
        self.stamp = stamp
        self.state = ConsentState(stamp: stamp(), utc: now(), region: region)
    }

    // MARK: Queries

    /// The current state (equivalent to reading `state`).
    public func getState() -> ConsentState { state }

    /// Which privacy regime applies to this person: GDPR / CCPA / LGPD, opt-in vs
    /// opt-out, and which signalling framework third parties will read.
    ///
    /// Answers immediately and offline from the region this client was configured with.
    /// Call `refreshRegulation()` to replace that with the server's IP-derived answer —
    /// a device's locale tells you where the phone was sold, not where its owner is.
    public var applicableRegulation: Regulation {
        serverRegulation ?? Regulation.resolve(region: region, gpc: gpc, dnt: dnt)
    }

    /// Whether you still owe this person a consent prompt.
    ///
    /// False once they have made an explicit decision in the app, and false when an
    /// opt-out signal has already expressed a refusal on their behalf. Check this
    /// before presenting a banner: an app that re-prompts someone who already answered
    /// is both annoying and, under an opt-out regime, wrong.
    public var isConsentRequired: Bool {
        !state.hasResponse && applicableRegulation.consentRequired
    }

    /// Record a Global Privacy Control signal. Under an opt-out regime this counts as
    /// a refusal on this person's behalf, so no prompt is owed; under GDPR nothing
    /// fires before consent anyway, so the prompt still is.
    public func setGlobalPrivacyControl(_ enabled: Bool) {
        gpc = enabled
        serverRegulation = nil // the local resolver now has newer information than the server
    }

    /// Record a legacy Do Not Track signal. Treated exactly like GPC.
    public func setDoNotTrack(_ enabled: Bool) {
        dnt = enabled
        serverRegulation = nil
    }

    // MARK: Cross-surface identity

    /// The account id currently attached to this device's decisions, if any.
    public var currentSubjectId: String? { subjectId }

    /// Attach this device's decisions to a signed-in account, so one person's consent can
    /// be correlated across web, iOS, Android and desktop (`GET /v1/subjects/:id/consent`).
    ///
    /// Call it after sign-in rather than at construction: an app builds its consent client
    /// at launch, before anyone has signed in. Pass `nil` on sign-out — continuing to send
    /// the id would attribute the next person's decisions on a shared device to the
    /// account that just left.
    ///
    /// The id is opaque to us: stored and bound into the tamper-evident hash chain, never
    /// interpreted. It applies to decisions made from now on; it does not rewrite history.
    public func setSubjectId(_ id: String?) {
        subjectId = (id?.isEmpty ?? true) ? nil : id
    }

    /// Ask the server which regime applies, based on the IP it sees, and adopt the
    /// answer. Never throws: offline, or against a server too old to return a
    /// `regulation` block, the locally-resolved regime stays in place — a failed
    /// refresh must never leave the app with no answer to "do I prompt".
    public func refreshRegulation() async {
        guard let url = URL(string: "\(apiURL)/config/\(cbid)") else { return }
        do {
            let data = try await transport.get(url, headers: [
                "Accept": "application/json",
                "X-CookieMunch-Region": region,
            ])
            struct ConfigEnvelope: Decodable { let regulation: Regulation? }
            if let resolved = try JSONDecoder().decode(ConfigEnvelope.self, from: data).regulation {
                serverRegulation = resolved
            }
        } catch {
            // Offline, malformed, or a transport with no `get`. Keep the local answer.
        }
    }

    /// True once the user has made an explicit decision.
    public var hasResponse: Bool { state.hasResponse }

    /// True if the given category is currently granted.
    public func granted(_ category: ConsentCategory) -> Bool { state.granted(category) }

    // MARK: Lifecycle

    /// Restore any previously persisted decision. Call once at launch. Corrupt or absent
    /// data leaves the implied default in place. Fires ready gates and `onChange`.
    @discardableResult
    public func load() async -> ConsentState {
        if let raw = await storage.getItem(storageKey),
           let data = raw.data(using: .utf8),
           let restored = try? JSONDecoder().decode(ConsentState.self, from: data) {
            state = restored
        }
        runReadyGates()
        emit()
        return state
    }

    // MARK: Decisions

    /// Grant every category.
    @discardableResult
    public func accept() async -> ConsentState { await commit(.all) }

    /// Deny every non-necessary category.
    @discardableResult
    public func decline() async -> ConsentState { await commit(.none) }

    /// Set categories individually, merging into the current choices; unspecified
    /// categories keep their current value. Records an explicit decision.
    @discardableResult
    public func set(preferences: Bool? = nil, statistics: Bool? = nil, marketing: Bool? = nil) async -> ConsentState {
        var next = state.choices
        if let preferences { next.preferences = preferences }
        if let statistics { next.statistics = statistics }
        if let marketing { next.marketing = marketing }
        return await commit(next)
    }

    /// Submit a fully-specified custom set of choices. Records an explicit decision.
    @discardableResult
    public func submit(_ choices: Choices) async -> ConsentState { await commit(choices) }

    private func commit(_ choices: Choices) async -> ConsentState {
        var next = state
        next.preferences = choices.preferences
        next.statistics = choices.statistics
        next.marketing = choices.marketing
        next.method = .explicit
        next.utc = now()
        state = next

        await persist()
        runReadyGates()
        emit()
        requestTrackingIfMarketingGranted()
        await sync()
        return state
    }

    // MARK: Prior-blocking gate

    /// Run `fn` exactly once, as soon as `category` is (or becomes) granted — the native
    /// equivalent of the web SDK's prior-blocking. If the category is already granted the
    /// closure runs immediately; otherwise it is queued and fired the moment consent lands.
    public func gate(_ category: ConsentCategory, _ fn: @escaping () -> Void) {
        if state.granted(category) {
            fn()
        } else {
            pendingGates[category, default: []].append(fn)
        }
    }

    private func runReadyGates() {
        for category in ConsentCategory.allCases where state.granted(category) {
            guard let queued = pendingGates[category], !queued.isEmpty else { continue }
            pendingGates[category] = nil
            for fn in queued { fn() }
        }
    }

    // MARK: Change notifications

    /// Register a listener for state changes. Returns a cancel closure; call it (on the
    /// main actor) to unsubscribe. SwiftUI code can just observe `$state` instead.
    @discardableResult
    public func onChange(_ cb: @escaping (ConsentState) -> Void) -> @MainActor () -> Void {
        let id = UUID()
        listeners[id] = cb
        return { [weak self] in self?.listeners[id] = nil }
    }

    private func emit() {
        for cb in listeners.values {
            cb(state)
        }
    }

    // MARK: App Tracking Transparency

    /// Keep the ATT prompt consistent with the consent banner: only ask the OS for
    /// tracking permission once the user has granted the marketing category.
    public func requestTrackingIfMarketingGranted() {
        #if canImport(AppTrackingTransparency)
        guard state.marketing else { return }
        if #available(iOS 14, tvOS 14, macOS 11, *) {
            ATTrackingManager.requestTrackingAuthorization { _ in }
        }
        #endif
    }

    // MARK: Persistence & sync

    private func persist() async {
        guard let data = try? JSONEncoder().encode(state),
              let raw = String(data: data, encoding: .utf8) else { return }
        await storage.setItem(storageKey, raw)
    }

    private struct ConsentPayload: Encodable {
        let cbid: String
        let stamp: String
        let choices: Choices
        let method: String
        let ver: Int
        let utc: Int64
        let url: String
        // Omitted from the JSON entirely when nil, so a decision made while logged out is
        // byte-identical to one from a build that never had this field.
        let subjectId: String?
    }

    /// POST the decision to `POST /api/v1/consent`. Never throws: an offline device keeps
    /// the local decision and can retry on next launch.
    private func sync() async {
        guard let url = URL(string: "\(apiURL)/api/v1/consent") else { return }
        let payload = ConsentPayload(
            cbid: cbid,
            stamp: state.stamp,
            choices: state.choices,
            method: state.method.rawValue,
            ver: state.ver,
            utc: state.utc,
            url: "app://\(cbid)",
            subjectId: subjectId
        )
        guard let body = try? JSONEncoder().encode(payload) else { return }
        let headers = [
            "Content-Type": "application/json",
            "X-CookieMunch-Region": state.region
        ]
        do {
            try await transport.post(url, headers: headers, body: body)
        } catch {
            // Offline — the local persist already captured the decision; retry later.
        }
    }
}
