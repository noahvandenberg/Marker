import AppKit
import WebKit

/// Opt-in stderr tracing for the rendering pipeline (MARKER_RENDER_DEBUG=1).
enum MarkerLog {
    static let enabled = ProcessInfo.processInfo.environment["MARKER_RENDER_DEBUG"] == "1"

    static func render(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        FileHandle.standardError.write(Data(("[render] " + message() + "\n").utf8))
    }
}

extension Notification.Name {
    /// Posted when a diagram or equation finishes rasterizing.
    static let markerRenderDidFinish = Notification.Name("MarkerRenderDidFinish")
}

enum RenderKind: String, Hashable {
    case math
    case mermaid
}

struct RenderRequest: Hashable {
    var kind: RenderKind
    var source: String
    /// Display (centered, larger) vs inline math.
    var display: Bool
    var fontSize: CGFloat
    var maxWidth: CGFloat
    var isDark: Bool
    var colorHex: String
    var backgroundHex: String

    /// Widths are bucketed so a window resize doesn't invalidate every diagram.
    func normalized() -> RenderRequest {
        var copy = self
        copy.maxWidth = (maxWidth / 40).rounded(.down) * 40
        return copy
    }
}

enum RenderState {
    case ready(NSImage)
    case pending
    case failed(String)
}

/// Rasterizes LaTeX and Mermaid using a single offscreen WKWebView.
///
/// The editing surface stays pure TextKit; this exists only to turn source text
/// into an `NSImage` that a layout fragment can draw. Results are cached, so a
/// document that is merely being scrolled or edited elsewhere never re-renders.
@MainActor
final class RenderService: NSObject {

    static let shared = RenderService()

    private var webView: WKWebView?
    private var hostWindow: NSWindow?
    private var isLoaded = false

    private var cache: [RenderRequest: NSImage] = [:]
    /// Insertion order, so the cache can be trimmed without unbounded growth.
    private var cacheOrder: [RenderRequest] = []
    private let cacheLimit = 160
    private var failures: [RenderRequest: String] = [:]
    private var queued: [RenderRequest] = []
    private var inFlight: RenderRequest?

    /// Rendered at 2× and tagged down to points, so diagrams stay sharp.
    private let renderScale: CGFloat = 2

    private override init() {
        super.init()
    }

    private func log(_ message: @autoclosure () -> String) {
        MarkerLog.render(message())
    }

    /// Whether the vendored renderer assets are present in the bundle.
    static var isAvailable: Bool { harnessURL != nil }

    private static var harnessURL: URL? {
        Bundle.main.url(forResource: "render", withExtension: "html", subdirectory: "Web")
            ?? Bundle.main.url(forResource: "render", withExtension: "html")
    }

    // MARK: - Public API

    /// Returns a cached image, or starts a render and reports `.pending`.
    func state(for request: RenderRequest) -> RenderState {
        let key = request.normalized()
        if let image = cache[key] { return .ready(image) }
        if let error = failures[key] { return .failed(error) }
        log("miss w=\(key.maxWidth) fs=\(key.fontSize) disp=\(key.display) "
            + "dark=\(key.isDark) fg=\(key.colorHex) bg=\(key.backgroundHex) "
            + "src=\(key.source.prefix(18))")
        enqueue(key)
        return .pending
    }

    func clearCache() {
        cache.removeAll()
        cacheOrder.removeAll()
        failures.removeAll()
    }

    // MARK: - Queue

    private func enqueue(_ request: RenderRequest) {
        guard RenderService.isAvailable else {
            failures[request] = "Renderer assets are missing from the app bundle."
            return
        }
        guard inFlight != request, !queued.contains(request) else { return }
        log("enqueue \(request.kind.rawValue) \(request.source.prefix(30))")
        queued.append(request)
        pump()
    }

    private func pump() {
        guard inFlight == nil, !queued.isEmpty else { return }
        guard let webView = ensureWebView() else { log("no web view"); return }
        guard isLoaded else { log("waiting for harness load"); return }

        let request = queued.removeFirst()
        inFlight = request
        run(request, in: webView)
    }

    private func finish(_ request: RenderRequest, image: NSImage?, error: String?) {
        log("finish \(request.kind.rawValue): \(error ?? "ok \(image?.size ?? .zero)")")
        if let image {
            if cache[request] == nil { cacheOrder.append(request) }
            cache[request] = image
            while cacheOrder.count > cacheLimit {
                cache.removeValue(forKey: cacheOrder.removeFirst())
            }
        }
        if let error { failures[request] = error }
        inFlight = nil
        NotificationCenter.default.post(name: .markerRenderDidFinish, object: nil)
        pump()
    }

    // MARK: - Web view

    private func ensureWebView() -> WKWebView? {
        if let webView { return webView }
        guard let harness = RenderService.harnessURL else { return nil }

        let configuration = WKWebViewConfiguration()
        configuration.suppressesIncrementalRendering = true
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 1200),
                             configuration: configuration)
        view.navigationDelegate = self
        view.pageZoom = renderScale

        // WebKit only lays out reliably inside a window; park one off-screen.
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1200, height: 1200),
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        window.contentView = view
        window.orderBack(nil)
        window.isReleasedWhenClosed = false

        webView = view
        hostWindow = window
        view.loadFileURL(harness, allowingReadAccessTo: harness.deletingLastPathComponent())
        return view
    }

    // MARK: - One render

    private func run(_ request: RenderRequest, in webView: WKWebView) {
        let payload: [String: Any] = [
            "kind": request.kind.rawValue,
            "source": request.source,
            "display": request.display,
            "fontSize": Double(request.fontSize),
            "maxWidth": Double(request.maxWidth),
            "dark": request.isDark,
            "color": request.colorHex,
            "background": request.backgroundHex,
        ]

        // Give the page room to lay out before it is measured.
        webView.frame = NSRect(x: 0, y: 0,
                               width: max(400, request.maxWidth) * renderScale,
                               height: 4000)

        webView.callAsyncJavaScript("return await window.markerRender(payload);",
                                    arguments: ["payload": payload],
                                    in: nil,
                                    in: .page) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.finish(request, image: nil, error: error.localizedDescription)
            case .success(let value):
                guard let dictionary = value as? [String: Any],
                      dictionary["ok"] as? Bool == true,
                      let width = (dictionary["width"] as? NSNumber)?.doubleValue,
                      let height = (dictionary["height"] as? NSNumber)?.doubleValue else {
                    let message = (value as? [String: Any])?["error"] as? String
                    self.finish(request, image: nil, error: message ?? "Could not render")
                    return
                }
                self.snapshot(request, in: webView, cssSize: CGSize(width: width, height: height))
            }
        }
    }

    private func snapshot(_ request: RenderRequest, in webView: WKWebView, cssSize: CGSize) {
        // Measurements come back in CSS pixels; the view is zoomed by renderScale.
        let deviceSize = CGSize(width: ceil(cssSize.width * renderScale),
                                height: ceil(cssSize.height * renderScale))
        webView.frame = NSRect(origin: .zero, size: deviceSize)

        let configuration = WKSnapshotConfiguration()
        configuration.rect = NSRect(origin: .zero, size: deviceSize)
        configuration.snapshotWidth = NSNumber(value: Double(deviceSize.width))
        configuration.afterScreenUpdates = true

        // One runloop turn so the resize takes effect before the snapshot.
        DispatchQueue.main.async {
            webView.takeSnapshot(with: configuration) { [weak self] image, error in
                guard let self else { return }
                guard let image, let cgImage = image.cgImage(forProposedRect: nil,
                                                             context: nil,
                                                             hints: nil) else {
                    self.finish(request, image: nil,
                                error: error?.localizedDescription ?? "Snapshot failed")
                    return
                }
                // Retag the bitmap at point size so it draws crisply on Retina.
                let representation = NSBitmapImageRep(cgImage: cgImage)
                let scaled = NSImage(size: cssSize)
                representation.size = cssSize
                scaled.addRepresentation(representation)
                self.finish(request, image: scaled, error: nil)
            }
        }
    }
}

// MARK: - WKNavigationDelegate

extension RenderService: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            self.log("harness loaded")
            self.isLoaded = true
            self.pump()
        }
    }

    nonisolated func webView(_ webView: WKWebView,
                             didFail navigation: WKNavigation!,
                             withError error: Error) {
        Task { @MainActor in
            self.log("harness failed: \(error.localizedDescription)")
            self.isLoaded = false
        }
    }

    /// The harness is local and must stay that way — no network, ever.
    @MainActor
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        decisionHandler(url?.isFileURL == true ? .allow : .cancel)
    }
}

// MARK: - Color helper

extension NSColor {
    /// `#rrggbb` in sRGB, for handing colors to the render harness.
    var cssHex: String {
        guard let rgb = usingColorSpace(.sRGB) else { return "#000000" }
        let r = Int((rgb.redComponent * 255).rounded())
        let g = Int((rgb.greenComponent * 255).rounded())
        let b = Int((rgb.blueComponent * 255).rounded())
        return String(format: "#%02x%02x%02x", r, g, b)
    }
}
