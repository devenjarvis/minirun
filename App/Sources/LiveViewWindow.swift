import MiniRunKit
import SwiftUI
import WebKit

/// The Worker's live viewer in a window of its own, instead of a browser tab. It's the same page,
/// so it asks for the password the first time; the login cookie is kept after that.
struct LiveViewWindow: View {
    let menu: MenuStore

    var body: some View {
        Group {
            if let link = menu.snapshot.viewerURL, let url = URL(string: link) {
                WebView(url: url)
            } else {
                ContentUnavailableView("No Worker yet", systemImage: "play.slash",
                                       description: Text("Set up minirun first; the live view runs on your Worker."))
            }
        }
        .frame(minWidth: 320, minHeight: 480)
        .toolbar {
            ToolbarItem {
                Button { menu.copyPassword() } label: { Label("Copy password", systemImage: "key") }
                    .help("Copy the password the viewer asks for")
            }
            ToolbarItem {
                Button { menu.open(menu.snapshot.viewerURL) } label: { Label("Open in browser", systemImage: "safari") }
                    .disabled(menu.snapshot.viewerURL == nil)
            }
        }
    }
}

/// A WKWebView showing one URL. It reloads only when the URL changes, not on every poll.
struct WebView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // The default store keeps the viewer's login cookie between launches.
        configuration.websiteDataStore = .default()
        // The WebRTC stream is a muted <video autoplay> that starts without a click. That's
        // already macOS's default; set here so it stays that way.
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.load(URLRequest(url: url))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.loaded != url else { return }
        context.coordinator.loaded = url
        if view.url?.host != url.host { view.load(URLRequest(url: url)) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(loaded: url) }

    final class Coordinator {
        var loaded: URL
        init(loaded: URL) { self.loaded = loaded }
    }
}
