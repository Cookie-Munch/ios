import Foundation

/// Carrying a decision made in the app into a `WKWebView`.
///
/// A hybrid app collects consent natively, then opens web content — a help centre, a
/// checkout, an article. That page runs the web embed, finds no stored decision, and
/// asks again. The person has now been asked twice for the same thing, and the answer
/// the web side keeps is the second one.
///
/// Two ways across, matching `@cookiemunch/core`'s `webview-bridge.ts` byte for byte so
/// a page cannot tell which platform seeded it:
///
/// ```swift
/// let js = CookieMunch.WebViewBridge.javaScript(for: state)
/// let script = WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: false)
/// webView.configuration.userContentController.addUserScript(script)
/// ```
///
/// Inject `.atDocumentStart`: the embed reads storage as it boots, so a script that
/// runs after the document is ready has already lost the race.
public enum WebViewBridge {
    /// Query parameter carrying a serialised decision.
    public static let queryParameter = "cm_consent"

    /// Cookie the web embed reads.
    static let cookieName = "CookieMunch"
    /// Cookiebot's name, for apps migrating from it.
    static let legacyCookieName = "CookieConsent"
    /// Twelve months, matching the embed's own default.
    public static let defaultMaxAge = 60 * 60 * 24 * 365

    /// The serialised, URL-encoded consent value the web side stores.
    static func serialize(_ state: ConsentState) -> String? {
        guard let data = try? JSONEncoder().encode(state),
              let json = String(data: data, encoding: .utf8) else { return nil }
        // Matches encodeURIComponent: everything outside the unreserved set is escaped.
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.!~*'()")
        return json.addingPercentEncoding(withAllowedCharacters: allowed)
    }

    /// Escape for embedding inside a single-quoted JavaScript string literal.
    static func jsString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
            // `</script` would close an inline tag if this were ever inlined.
            .replacingOccurrences(of: "<", with: "\\x3c")
    }

    /// A single JavaScript statement that seeds a web view with this decision.
    ///
    /// One line and expression-only on purpose: `evaluateJavaScript` takes a string, and
    /// a multi-line program is a common source of silent failures.
    public static func javaScript(
        for state: ConsentState,
        maxAge: Int = defaultMaxAge,
        alsoLegacyCookie: Bool = false
    ) -> String {
        guard let value = serialize(state) else { return "" }
        let attrs = ";path=/;max-age=\(maxAge);SameSite=Lax"
        func write(_ name: String) -> String {
            "document.cookie='\(jsString(name))='+'\(jsString(value))'+'\(jsString(attrs))';"
        }
        return alsoLegacyCookie ? write(cookieName) + write(legacyCookieName) : write(cookieName)
    }

    /// A URL parameter carrying this decision, for when script injection is unavailable.
    /// Append it to the URL you are about to load.
    public static func queryString(for state: ConsentState) -> String {
        guard let value = serialize(state) else { return "" }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.!~*'()")
        let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        return "\(queryParameter)=\(encoded)"
    }

    /// Append the decision to a URL, preserving any query it already has.
    public static func url(_ url: URL, carrying state: ConsentState) -> URL {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let value = serialize(state) else { return url }
        var items = parts.queryItems ?? []
        items.removeAll { $0.name == queryParameter }
        items.append(URLQueryItem(name: queryParameter, value: value))
        parts.queryItems = items
        return parts.url ?? url
    }
}
