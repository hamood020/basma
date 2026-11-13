import SwiftUI
import WebKit
import CoreLocation
import UIKit

// MARK: - Theme

enum Theme {
    static let blue = Color(red: 0.16, green: 0.47, blue: 0.80)
    static let purple = Color(red: 0.40, green: 0.27, blue: 0.60)
    static let header = LinearGradient(
        colors: [blue, purple],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

// MARK: - Punch mode

enum PunchMode: String, CaseIterable, Identifiable {
    case none = "none"
    case entry = "NP"
    case exit = "IN"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "بدون تحديد"
        case .entry: return "دخول"
        case .exit: return "خروج"
        }
    }

    var symbol: String {
        switch self {
        case .none: return "circle"
        case .entry: return "arrow.down.right.circle.fill"
        case .exit: return "arrow.up.left.circle.fill"
        }
    }
}

final class AppState: ObservableObject {
    private static let key = "digiHRMobileMode"

    @Published private(set) var selectedMode: PunchMode

    init() {
        let saved = UserDefaults.standard.string(forKey: Self.key) ?? PunchMode.none.rawValue
        selectedMode = PunchMode(rawValue: saved) ?? .none
    }

    func setMode(_ mode: PunchMode) {
        selectedMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.key)
    }
}

// MARK: - Root

struct MainTabView: View {
    @StateObject private var state = AppState()

    var body: some View {
        TabView {
            SystemPage()
                .tabItem { Label("صفحة النظام", systemImage: "globe") }

            LocationTestPage()
                .tabItem { Label("اختبار الموقع", systemImage: "location.circle.fill") }
        }
        .environmentObject(state)
        .environment(\.layoutDirection, .rightToLeft)
        .tint(Theme.blue)
    }
}

// MARK: - Helpers

enum UIHelpers {
    static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.windows.first { $0.isKeyWindow }?.rootViewController
            ?? scene?.windows.first?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

// MARK: - Web store (one WKWebView kept alive for the whole app session)

final class WebStore: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    static let homeURL = URL(string: "https://basma.ptlc.gov.om/")!
    private static let authHostSuffix = "ptlc.gov.om"

    let webView: WKWebView

    @Published var progress: Double = 0
    @Published var isLoading = false
    @Published var canGoBack = false
    @Published var errorMessage: String?
    @Published var savedUsername: String? = CredentialStore.load()?.user
    // User text-size preference, applied on top of automatic fit-to-width.
    @Published var pageZoom: Double = {
        let saved = UserDefaults.standard.object(forKey: "digiHRScale") as? Double ?? 1.0
        return min(1.4, max(0.7, saved))
    }()

    private var currentMode: PunchMode = .none
    private var observers: [NSKeyValueObservation] = []
    private let refreshControl = UIRefreshControl()

    // Windows (NTLM / Negotiate) sign-in state
    private enum CredentialSource { case page, saved, prompt }
    private var pageCredential: WindowsCredential?
    private var lastSource: CredentialSource?
    private var credentialToOffer: WindowsCredential?
    private let gate = BiometricGate()
    private var promptWaiters: [(URLSession.AuthChallengeDisposition, URLCredential?) -> Void] = []

    override init() {
        let controller = WKUserContentController()
        controller.addUserScript(
            WKUserScript(source: Self.helperScript, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        controller.addUserScript(
            WKUserScript(source: CredentialScript.source, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        )
        controller.addUserScript(
            WKUserScript(source: Self.viewportScript, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
        )
        controller.addUserScript(
            WKUserScript(source: Self.fitScript, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        let config = WKWebViewConfiguration()
        config.userContentController = controller
        config.allowsInlineMediaPlayback = true
        config.websiteDataStore = .default()

        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        controller.add(WeakScriptHandler(self), name: "digiHRCreds")

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        webView.scrollView.backgroundColor = .systemBackground
        webView.scrollView.bounces = true
        webView.scrollView.alwaysBounceVertical = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never

        refreshControl.addTarget(self, action: #selector(pullToRefresh), for: .valueChanged)
        webView.scrollView.refreshControl = refreshControl

        observers = [
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
                DispatchQueue.main.async { self?.progress = view.estimatedProgress }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
                DispatchQueue.main.async {
                    self?.isLoading = view.isLoading
                    if !view.isLoading { self?.refreshControl.endRefreshing() }
                }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] view, _ in
                DispatchQueue.main.async { self?.canGoBack = view.canGoBack }
            },
            webView.observe(\.url, options: [.new]) { [weak self] view, _ in
                DispatchQueue.main.async { self?.urlChanged(view.url) }
            }
        ]

        webView.load(URLRequest(url: Self.homeURL))
    }

    @objc private func pullToRefresh() { reload() }

    func reload() {
        errorMessage = nil
        if webView.url == nil {
            webView.load(URLRequest(url: Self.homeURL))
        } else {
            webView.reload()
        }
    }

    func goHome() {
        errorMessage = nil
        webView.load(URLRequest(url: Self.homeURL))
    }

    func goBack() {
        if webView.canGoBack { webView.goBack() }
    }

    /// Stores the chosen UI mode inside the page (localStorage + event). It does not send any
    /// attendance request and does not modify server responses or location data.
    func apply(mode: PunchMode) {
        currentMode = mode
        webView.evaluateJavaScript(
            "window.digiHRMobileSetMode && window.digiHRMobileSetMode('\(mode.rawValue)');",
            completionHandler: nil
        )
    }

    // MARK: Windows authentication (IIS NTLM / Negotiate)

    func webView(_ webView: WKWebView,
                 didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        let windowsMethods = [
            NSURLAuthenticationMethodNTLM,
            NSURLAuthenticationMethodNegotiate,
            NSURLAuthenticationMethodHTTPBasic,
            NSURLAuthenticationMethodHTTPDigest
        ]
        guard windowsMethods.contains(space.authenticationMethod),
              space.host.hasSuffix(Self.authHostSuffix) else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        if challenge.previousFailureCount > 0 {
            // The last credential was rejected.
            if lastSource == .saved { forgetSavedCredential() }
            pageCredential = nil
            credentialToOffer = nil
            promptForCredentials(failed: true, completion: completionHandler)
            return
        }

        if let page = pageCredential, page.isComplete {
            lastSource = .page
            if page != CredentialStore.load() { credentialToOffer = page }
            completionHandler(.useCredential, page.urlCredential)
            return
        }

        if let saved = CredentialStore.load(), saved.isComplete {
            gate.unlock { [weak self] ok in
                guard let self else { completionHandler(.cancelAuthenticationChallenge, nil); return }
                if ok {
                    self.lastSource = .saved
                    completionHandler(.useCredential, saved.urlCredential)
                } else {
                    self.promptForCredentials(failed: false, completion: completionHandler)
                }
            }
            return
        }

        promptForCredentials(failed: false, completion: completionHandler)
    }

    private func promptForCredentials(failed: Bool,
                                      completion: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        promptWaiters.append(completion)
        guard promptWaiters.count == 1 else { return }   // a prompt is already on screen

        guard let top = UIHelpers.topViewController() else {
            finishPrompt(.cancelAuthenticationChallenge, nil)
            return
        }

        let alert = UIAlertController(
            title: "تسجيل الدخول بحساب ويندوز",
            message: failed
                ? "اسم المستخدم أو كلمة المرور غير صحيحة. حاول مرة أخرى."
                : "أدخل اسم مستخدم ويندوز وكلمة المرور (مثال: username أو DOMAIN\\username)",
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.placeholder = "اسم المستخدم"
            field.text = CredentialStore.load()?.user ?? self.pageCredential?.user
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.textContentType = .username
        }
        alert.addTextField { field in
            field.placeholder = "كلمة المرور"
            field.isSecureTextEntry = true
            field.textContentType = .password
        }

        let submit: (Bool) -> Void = { [weak self, weak alert] save in
            guard let self else { return }
            let user = alert?.textFields?[0].text?.trimmingCharacters(in: .whitespaces) ?? ""
            let password = alert?.textFields?[1].text ?? ""
            let credential = WindowsCredential(user: user, password: password)
            if save && credential.isComplete {
                CredentialStore.save(credential)
                self.savedUsername = credential.user
                self.gate.markUnlocked()
            }
            self.pageCredential = credential
            self.lastSource = save ? .saved : .prompt
            self.finishPrompt(.useCredential, credential.urlCredential)
        }

        alert.addAction(UIAlertAction(title: "إلغاء", style: .cancel) { [weak self] _ in
            self?.finishPrompt(.cancelAuthenticationChallenge, nil)
        })
        alert.addAction(UIAlertAction(title: "دخول", style: .default) { _ in submit(false) })
        alert.addAction(UIAlertAction(title: "دخول وحفظ كلمة المرور", style: .default) { _ in submit(true) })
        top.present(alert, animated: true)
    }

    private func finishPrompt(_ disposition: URLSession.AuthChallengeDisposition, _ credential: URLCredential?) {
        let waiters = promptWaiters
        promptWaiters.removeAll()
        waiters.forEach { $0(disposition, credential) }
    }

    /// After a successful Windows sign-in with what was typed in the page, offer to save it.
    private func urlChanged(_ url: URL?) {
        guard let offer = credentialToOffer, offer.isComplete,
              let path = url?.absoluteString, path.contains("web-app"),
              let top = UIHelpers.topViewController() else { return }
        credentialToOffer = nil

        let alert = UIAlertController(
            title: "حفظ كلمة المرور؟",
            message: "سيتم حفظ بيانات دخول ويندوز (\(offer.user)) في سلسلة مفاتيح iPhone، وتُستخدم بعد التحقق ببصمة الوجه.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "ليس الآن", style: .cancel))
        alert.addAction(UIAlertAction(title: "حفظ", style: .default) { [weak self] _ in
            CredentialStore.save(offer)
            self?.savedUsername = offer.user
            self?.gate.markUnlocked()
        })
        top.present(alert, animated: true)
    }

    func forgetSavedCredential() {
        CredentialStore.delete()
        savedUsername = nil
    }

    // Messages from the page script
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.request.url?.host?.hasSuffix(Self.authHostSuffix) ?? false,
              let body = message.body as? [String: Any] else { return }

        if body["event"] as? String == "form" {
            fillLoginFormFromSaved()
            return
        }
        let credential = WindowsCredential(
            user: (body["user"] as? String ?? "").trimmingCharacters(in: .whitespaces),
            password: body["pass"] as? String ?? ""
        )
        if credential.isComplete { pageCredential = credential }
    }

    private func fillLoginFormFromSaved() {
        guard let saved = CredentialStore.load(), saved.isComplete else { return }
        gate.unlock { [weak self] ok in
            guard ok, let self,
                  let data = try? JSONSerialization.data(withJSONObject: [saved.user, saved.password]),
                  let args = String(data: data, encoding: .utf8) else { return }
            self.webView.evaluateJavaScript(
                "(function(a){ window.digiHRFill && window.digiHRFill(a[0], a[1]); })(\(args));",
                completionHandler: nil
            )
        }
    }

    // MARK: Navigation delegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        errorMessage = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        apply(mode: currentMode)
        applyZoom()
        // The portal is a single-page app that renders after load; re-fit a few times.
        for delay in [0.3, 1.0, 2.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.webView.evaluateJavaScript("window.__digiHRFit && window.__digiHRFit();", completionHandler: nil)
            }
        }
    }

    // MARK: Page text size (applied on top of automatic fit-to-width)

    func stepZoom(_ delta: Double) {
        setZoom(((pageZoom * 100).rounded() / 100) + delta)
    }

    func setZoom(_ value: Double) {
        pageZoom = min(1.4, max(0.7, (value * 100).rounded() / 100))
        UserDefaults.standard.set(pageZoom, forKey: "digiHRScale")
        applyZoom()
    }

    private func applyZoom() {
        webView.evaluateJavaScript(
            "window.__digiHRApplyScale && window.__digiHRApplyScale(\(pageZoom));",
            completionHandler: nil
        )
    }

    static let viewportScript = """
    (function () {
      function fix() {
        var m = document.querySelector('meta[name=viewport]');
        if (!m) {
          m = document.createElement('meta');
          m.setAttribute('name', 'viewport');
          (document.head || document.documentElement).appendChild(m);
        }
        m.setAttribute('content',
          'width=device-width, initial-scale=1, minimum-scale=1, maximum-scale=6, user-scalable=yes');
      }
      fix();
      document.addEventListener('DOMContentLoaded', fix);
    })();
    """

    // Shrinks the whole page so its FULL width fits the screen — including fixed toolbars and
    // side rails that scrollWidth misses — so no button (e.g. the portal's menu icon) is cut off.
    // The user's chosen text size is applied on top. Re-runs on resize, rotation and DOM changes.
    static let fitScript = """
    (function () {
      if (window.__digiHRFitInstalled) return;
      window.__digiHRFitInstalled = true;
      window.__digiHRUserScale = 1;
      var raf = 0, lastRun = 0;

      function contentWidth(iw) {
        var el = document.documentElement, b = document.body;
        var w = Math.max(el.scrollWidth, b.scrollWidth, b.offsetWidth, iw);
        try {
          var nodes = b.getElementsByTagName('*');
          var n = Math.min(nodes.length, 5000);
          var sx = window.scrollX || 0;
          for (var i = 0; i < n; i++) {
            var e = nodes[i];
            var r = e.getBoundingClientRect();
            if (r.width <= 0 || r.height <= 0) continue;
            var cs = window.getComputedStyle(e);
            if (cs.visibility === 'hidden' || cs.display === 'none' || cs.opacity === '0') continue;
            var right = r.right + (cs.position === 'fixed' ? 0 : sx);
            if (right > w) w = right;
          }
        } catch (e) {}
        return w;
      }

      function fit() {
        try {
          var el = document.documentElement;
          if (!el || !document.body) return;
          lastRun = Date.now();
          el.style.setProperty('zoom', '1', 'important');
          var iw = window.innerWidth || el.clientWidth;
          var cw = contentWidth(iw);
          var f = (cw > iw + 1) ? (iw / cw) : 1;
          if (f < 0.4) f = 0.4;
          var z = f * (window.__digiHRUserScale || 1);
          el.style.setProperty('zoom', String(z), 'important');
          window.scrollTo(0, window.scrollY);
        } catch (e) {}
      }

      function schedule() {
        if (raf) return;
        var wait = Math.max(0, 400 - (Date.now() - lastRun));
        raf = 1;
        setTimeout(function () {
          raf = 0;
          requestAnimationFrame(fit);
        }, wait);
      }

      window.__digiHRFit = fit;
      window.__digiHRApplyScale = function (s) { window.__digiHRUserScale = s; fit(); };
      window.addEventListener('resize', schedule);
      window.addEventListener('orientationchange', function () { setTimeout(fit, 350); });
      document.addEventListener('DOMContentLoaded', function () {
        fit();
        try {
          new MutationObserver(schedule).observe(document.documentElement, { childList: true, subtree: true, attributes: true });
        } catch (e) {}
      });
    })();
    """

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handle(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handle(error)
    }

    private func handle(_ error: Error) {
        let nsError = error as NSError
        refreshControl.endRefreshing()
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        errorMessage = nsError.localizedDescription
    }

    // MARK: UI delegate

    /// Links with target="_blank" open in the same view.
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        guard let top = UIHelpers.topViewController() else { completionHandler(); return }
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "حسنًا", style: .default) { _ in completionHandler() })
        top.present(alert, animated: true)
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        guard let top = UIHelpers.topViewController() else { completionHandler(false); return }
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "إلغاء", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "موافق", style: .default) { _ in completionHandler(true) })
        top.present(alert, animated: true)
    }

    static let helperScript = """
    (function () {
      if (window.__digiHRMobileInstalled) return;
      window.__digiHRMobileInstalled = true;
      var mode = 'none';
      try { mode = localStorage.getItem('digiHRMobileMode') || 'none'; } catch (e) {}
      // UI helper only: stores the selected mode. Sends no attendance request,
      // and does not alter server responses or location.
      window.digiHRMobileSetMode = function (newMode) {
        if (newMode !== 'NP' && newMode !== 'IN' && newMode !== 'none') return;
        mode = newMode;
        try { localStorage.setItem('digiHRMobileMode', mode); } catch (e) {}
        window.dispatchEvent(new CustomEvent('digihr-mobile-mode', { detail: { mode: mode } }));
      };
      window.digiHRMobileGetMode = function () { return mode; };
    })();
    """
}

struct WebContainer: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

// MARK: - System page

struct SystemPage: View {
    @EnvironmentObject private var state: AppState
    @StateObject private var web = WebStore()
    @State private var showFontMenu = false
    @State private var showMoreMenu = false

    var body: some View {
        VStack(spacing: 0) {
            header
                .confirmationDialog("حجم الخط", isPresented: $showFontMenu, titleVisibility: .visible) {
                    Button("تصغير الخط") { web.stepZoom(-0.1) }
                    Button("تكبير الخط") { web.stepZoom(0.1) }
                    Button("الحجم الافتراضي") { web.setZoom(1.0) }
                    Button("إغلاق", role: .cancel) {}
                }
                .confirmationDialog("خيارات", isPresented: $showMoreMenu, titleVisibility: .visible) {
                    Button("الصفحة الرئيسية") { web.goHome() }
                    if let user = web.savedUsername {
                        Button("حذف كلمة المرور المحفوظة (\(user))", role: .destructive) {
                            web.forgetSavedCredential()
                        }
                    }
                    Button("إغلاق", role: .cancel) {}
                }

            ZStack(alignment: .top) {
                WebContainer(webView: web.webView)

                if web.isLoading && web.progress < 1 {
                    ProgressView(value: web.progress)
                        .progressViewStyle(.linear)
                        .tint(Theme.blue)
                        .frame(height: 3)
                }

                if let message = web.errorMessage {
                    errorView(message)
                }
            }
        }
        .onAppear { web.apply(mode: state.selectedMode) }
    }

    private var header: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "touchid")
                    .font(.title2)
                VStack(alignment: .leading, spacing: 0) {
                    Text("بصمة")
                        .font(.headline)
                    Text("DigiHR")
                        .font(.caption)
                        .opacity(0.8)
                }
                Spacer()
                headerButton("chevron.backward", label: "رجوع", enabled: web.canGoBack) { web.goBack() }
                headerButton("arrow.clockwise", label: "تحديث الصفحة") { web.reload() }
                headerButton("textformat.size", label: "حجم الخط") { showFontMenu = true }
                headerButton("ellipsis", label: "المزيد") { showMoreMenu = true }
            }

            HStack(spacing: 10) {
                modeButton(.entry)
                modeButton(.exit)
            }

            Text(statusText)
                .font(.caption)
                .opacity(0.9)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundColor(.white)
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 12)
        .background(Theme.header.ignoresSafeArea(edges: .top))
    }

    private var statusText: String {
        switch state.selectedMode {
        case .none: return "اختر وضع الدخول أو الخروج، ثم أكمل الإجراء من النظام"
        case .entry: return "وضع الدخول محدد — أكمل إجراء الدخول من صفحة النظام"
        case .exit: return "وضع الخروج محدد — أكمل إجراء الخروج من صفحة النظام"
        }
    }

    private func headerButton(_ symbol: String, label: String, enabled: Bool = true,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 36, height: 36)
                .background(Color.white.opacity(0.18))
                .clipShape(Circle())
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(label)
    }

    private func modeButton(_ mode: PunchMode) -> some View {
        let selected = state.selectedMode == mode
        return Button {
            let newMode: PunchMode = selected ? .none : mode
            state.setMode(newMode)
            web.apply(mode: newMode)
            web.reload()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: mode.symbol)
                Text(mode.title)
            }
            .font(.system(size: 16, weight: .bold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(selected ? Color.white : Color.white.opacity(0.18))
            .foregroundColor(selected ? Theme.purple : .white)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 44))
                .foregroundColor(.secondary)
            Text("تعذّر فتح صفحة النظام")
                .font(.headline)
            Text(message)
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button {
                web.reload()
            } label: {
                Label("إعادة المحاولة", systemImage: "arrow.clockwise")
                    .font(.headline)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Theme.blue)
                    .foregroundColor(.white)
                    .clipShape(Capsule())
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
    }
}

// MARK: - Google map (embedded, no API key needed)

struct GoogleMapView: UIViewRepresentable {
    let coordinate: CLLocationCoordinate2D

    final class Coordinator {
        var lastLoaded: CLLocation?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero)
        view.isOpaque = false
        view.backgroundColor = .secondarySystemBackground
        view.scrollView.isScrollEnabled = false
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        let target = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        if let last = context.coordinator.lastLoaded, last.distance(from: target) < 15 { return }
        context.coordinator.lastLoaded = target

        let q = String(format: "%.7f,%.7f", coordinate.latitude, coordinate.longitude)
        let html = """
        <!DOCTYPE html><html><head>
        <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
        <style>html,body{margin:0;padding:0;height:100%;background:#eef1f5}
        iframe{border:0;width:100%;height:100%;display:block}</style>
        </head><body>
        <iframe src="https://maps.google.com/maps?q=\(q)&z=17&hl=ar&output=embed" allowfullscreen loading="eager"></iframe>
        </body></html>
        """
        view.loadHTMLString(html, baseURL: URL(string: "https://maps.google.com"))
    }
}

// MARK: - Location page

struct LocationTestPage: View {
    @StateObject private var locator = LocationManager()
    @State private var copied = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    mapCard
                    detailsCard
                    actions
                    if let error = locator.errorMessage {
                        Text(error)
                            .font(.footnote)
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(16)
            }
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("اختبار الموقع")
            .navigationBarTitleDisplayMode(.inline)
        }
        .navigationViewStyle(.stack)
        .onAppear { locator.start() }
        .onDisappear { locator.stop() }
    }

    // Map

    private var mapCard: some View {
        ZStack(alignment: .topLeading) {
            if let coordinate = locator.coordinate {
                GoogleMapView(coordinate: coordinate)
            } else {
                VStack(spacing: 12) {
                    if locator.isDenied {
                        Image(systemName: "location.slash.fill")
                            .font(.system(size: 40))
                            .foregroundColor(.red)
                        Text("إذن الموقع غير مفعّل")
                            .font(.headline)
                    } else {
                        ProgressView()
                        Text("جاري تحديد موقعك…")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(uiColor: .secondarySystemBackground))
            }

            if let accuracy = locator.accuracy {
                HStack(spacing: 6) {
                    Circle().fill(accuracyColor(accuracy)).frame(width: 8, height: 8)
                    Text(String(format: "الدقة ± %.0f م", accuracy))
                        .font(.caption.bold())
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .padding(10)
            }
        }
        .frame(height: 340)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
    }

    // Details

    private var detailsCard: some View {
        VStack(spacing: 0) {
            row("checkmark.shield.fill", "حالة الإذن", locator.permissionText)
            Divider().padding(.leading, 48)
            row("arrow.up.and.down", "خط العرض", locator.coordinate.map { String(format: "%.7f", $0.latitude) } ?? "—")
            Divider().padding(.leading, 48)
            row("arrow.left.and.right", "خط الطول", locator.coordinate.map { String(format: "%.7f", $0.longitude) } ?? "—")
            Divider().padding(.leading, 48)
            row("scope", "دقة الموقع", locator.accuracy.map { String(format: "± %.1f متر", $0) } ?? "—",
                valueColor: locator.accuracy.map(accuracyColor))
            Divider().padding(.leading, 48)
            row("clock.fill", "آخر تحديث", locator.updatedText)
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func row(_ icon: String, _ title: String, _ value: String, valueColor: Color? = nil) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(Theme.blue)
                .frame(width: 24)
            Text(title)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
                .foregroundColor(valueColor ?? .primary)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // Actions

    private var actions: some View {
        VStack(spacing: 10) {
            if locator.isDenied {
                primaryButton("فتح إعدادات الموقع", icon: "gear") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            } else {
                primaryButton("فتح في خرائط جوجل", icon: "map.fill") {
                    if let coordinate = locator.coordinate { openInGoogleMaps(coordinate) }
                }
                .disabled(locator.coordinate == nil)
                .opacity(locator.coordinate == nil ? 0.5 : 1)
            }

            HStack(spacing: 10) {
                secondaryButton("تحديث الموقع", icon: "location.fill") { locator.refresh() }
                secondaryButton(copied ? "تم النسخ" : "نسخ الإحداثيات",
                                icon: copied ? "checkmark" : "doc.on.doc") {
                    guard let c = locator.coordinate else { return }
                    UIPasteboard.general.string = String(format: "%.7f,%.7f", c.latitude, c.longitude)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }
                .disabled(locator.coordinate == nil)
            }
        }
    }

    private func primaryButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Theme.header)
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func secondaryButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .foregroundColor(Theme.blue)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func accuracyColor(_ accuracy: Double) -> Color {
        if accuracy <= 20 { return .green }
        if accuracy <= 50 { return .orange }
        return .red
    }

    private func openInGoogleMaps(_ c: CLLocationCoordinate2D) {
        let q = String(format: "%.7f,%.7f", c.latitude, c.longitude)
        let web = URL(string: "https://www.google.com/maps/search/?api=1&query=\(q)")!
        guard let app = URL(string: "comgooglemaps://?q=\(q)&center=\(q)&zoom=17") else {
            UIApplication.shared.open(web)
            return
        }
        UIApplication.shared.open(app, options: [:]) { opened in
            if !opened { UIApplication.shared.open(web) }
        }
    }
}

// MARK: - Location manager (real device GPS only)

final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var active = false

    @Published var status: CLAuthorizationStatus = .notDetermined
    @Published var coordinate: CLLocationCoordinate2D?
    @Published var accuracy: Double?
    @Published var updated: Date?
    @Published var errorMessage: String?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 5
        status = manager.authorizationStatus
    }

    var isDenied: Bool { status == .denied || status == .restricted }

    var permissionText: String {
        switch status {
        case .notDetermined: return "لم يتم طلب الإذن"
        case .restricted: return "مقيّد"
        case .denied: return "مرفوض"
        case .authorizedWhenInUse: return "مسموح أثناء الاستخدام"
        case .authorizedAlways: return "مسموح دائمًا"
        @unknown default: return "غير معروف"
        }
    }

    var updatedText: String {
        guard let updated else { return "—" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ar")
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter.string(from: updated)
    }

    func start() {
        active = true
        errorMessage = nil
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            manager.startUpdatingLocation()
        default:
            break
        }
    }

    func stop() {
        active = false
        manager.stopUpdatingLocation()
    }

    func refresh() {
        errorMessage = nil
        if isDenied {
            errorMessage = "إذن الموقع مرفوض. فعّله من إعدادات iPhone."
            return
        }
        manager.stopUpdatingLocation()
        start()
        manager.requestLocation()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        DispatchQueue.main.async {
            self.status = manager.authorizationStatus
            if self.active && (self.status == .authorizedWhenInUse || self.status == .authorizedAlways) {
                manager.startUpdatingLocation()
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        DispatchQueue.main.async {
            self.coordinate = location.coordinate
            self.accuracy = location.horizontalAccuracy
            self.updated = location.timestamp
            self.errorMessage = nil
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if let clError = error as? CLError, clError.code == .locationUnknown { return }
        DispatchQueue.main.async {
            self.errorMessage = error.localizedDescription
        }
    }
}
