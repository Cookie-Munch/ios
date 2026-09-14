#if canImport(SwiftUI)
import SwiftUI

/// A SwiftUI consent banner wired to a `CookieMunchConsent` client. It is shown only
/// until the user has responded. Overlay it on your root view:
///
/// ```swift
/// @StateObject private var consent = CookieMunchConsent(cbid: "…", apiURL: "…")
/// // …
/// RootView()
///     .overlay(alignment: .bottom) { ConsentBannerView(consent: consent) }
///     .task { await consent.load() }
/// ```
@available(iOS 15, macOS 12, tvOS 15, watchOS 8, *)
public struct ConsentBannerView: View {
    @ObservedObject private var consent: CookieMunchConsent

    public init(consent: CookieMunchConsent) {
        self.consent = consent
    }

    private var background: Color {
        #if canImport(UIKit)
        return Color(.systemBackground)
        #elseif canImport(AppKit)
        return Color(nsColor: .windowBackgroundColor)
        #else
        return Color.white
        #endif
    }

    public var body: some View {
        if !consent.state.hasResponse {
            VStack(alignment: .leading, spacing: 12) {
                Text("We value your privacy")
                    .font(.headline)
                Text("We use cookies and similar technologies to improve your experience. You decide what we use.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                HStack(spacing: 8) {
                    Button("Reject all") { Task { await consent.decline() } }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(white: 0.8)))
                    Button("Allow all") { Task { await consent.accept() } }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color(red: 0.055, green: 0.43, blue: 0.36))
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
            }
            .padding(20)
            .background(background)
            .overlay(Rectangle().frame(height: 1).foregroundColor(Color(white: 0.88)), alignment: .top)
            .accessibilityAddTraits(.isModal)
        }
    }
}
#endif
