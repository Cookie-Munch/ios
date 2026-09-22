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

    /// The copy to draw: the server's answer for this device's language when it has
    /// arrived, and the English fallback until then — a prompt that waits for the network
    /// is a prompt that does not ask.
    private var text: (title: String, body: String, accept: String, reject: String) {
        let copy = consent.copy?.banner
        return (
            copy?.title ?? "We value your privacy",
            copy?.body ?? "We use cookies and similar technologies to improve your experience. You decide what we use.",
            copy?.acceptAll ?? "Allow all",
            copy?.rejectAll ?? "Reject all"
        )
    }

    /// Right-to-left copy laid out left-to-right puts the buttons on the wrong side of a
    /// sentence the reader scans the other way.
    private var layoutDirection: LayoutDirection {
        consent.copy?.rtl == true ? .rightToLeft : .leftToRight
    }

    private var background: Color {
        #if os(tvOS) || os(watchOS)
        // Neither has systemBackground. The package declared both platforms but compiled
        // for neither until this branch existed.
        return Color(white: 0.12)
        #elseif canImport(UIKit)
        return Color(.systemBackground)
        #elseif canImport(AppKit)
        return Color(nsColor: .windowBackgroundColor)
        #else
        return Color.white
        #endif
    }

    public var body: some View {
        #if os(tvOS)
        if !consent.state.hasResponse {
            TVConsentCard(consent: consent, background: background, text: text)
                .environment(\.layoutDirection, layoutDirection)
        }
        #else
        phoneBody
        #endif
    }

    @ViewBuilder
    private var phoneBody: some View {
        if !consent.state.hasResponse {
            VStack(alignment: .leading, spacing: 12) {
                Text(text.title)
                    .font(.headline)
                Text(text.body)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                HStack(spacing: 8) {
                    Button(text.reject) { Task { await consent.decline() } }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(white: 0.8)))
                    Button(text.accept) { Task { await consent.accept() } }
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
            .environment(\.layoutDirection, layoutDirection)
            .accessibilityAddTraits(.isModal)
        }
    }
}

#if os(tvOS)
/// The consent prompt on a television.
///
/// A TV is read from across a room and driven by a remote that can only move focus and
/// press. So: a centred card, not a strip along the bottom; type sized for ten feet; and
/// buttons in the system style, because tvOS draws focus (lift, shadow, highlight) only
/// on buttons it styles itself — the phone banner's custom backgrounds hid which button
/// the remote was on. The two choices are the same size and weight, and focus starts on
/// the first in reading order rather than being steered toward "Allow all".
@available(tvOS 15, *)
struct TVConsentCard: View {
    @ObservedObject var consent: CookieMunchConsent
    let background: Color
    let text: (title: String, body: String, accept: String, reject: String)

    var body: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 28) {
                Text(text.title)
                    .font(.title2.weight(.semibold))
                Text(text.body)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 40) {
                    Button(text.reject) { Task { await consent.decline() } }
                    Button(text.accept) { Task { await consent.accept() } }
                }
                .focusSection()
            }
            .padding(60)
            .frame(maxWidth: 1100)
            .background(background)
            .cornerRadius(24)
        }
        .accessibilityAddTraits(.isModal)
    }
}
#endif
#endif
