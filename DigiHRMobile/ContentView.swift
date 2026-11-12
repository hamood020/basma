import SwiftUI
import WebKit
import CoreLocation

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
        case .entry: return "arrow.right.to.line"
        case .exit: return "arrow.left.from.line"
        }
    }
}

final class AppState: ObservableObject {
    @Published var selectedMode: PunchMode = .none
    @Published var webView: WKWebView?
}

struct MainTabView: View {
    @StateObject private var state = AppState()

    var body: some View {
        TabView {
            SystemPage(state: state)
                .tabItem {
                    Label("صفحة النظام", systemImage: "globe")
                }

            LocationTestPage()
                .tabItem {
                    Label("اختبار الموقع", systemImage: "location.circle")
                }
        }
        .environmentObject(state)
        .environment(\.layoutDirection, .rightToLeft)
        .tint(.blue)
    }
}

struct SystemPage: View {
    @ObservedObject var state: AppState
    @State private var isLoading = false
    @State private var pageError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("DigiHR")
                    .font(.title2.bold())
                Spacer()
                Button {
                    state.webView?.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.title3)
                        .padding(10)
                }
                .accessibilityLabel("تحديث الصفحة")
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            HStack(spacing: 12) {
                modeButton(.entry)
                modeButton(.exit)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 3)
            }

            if let pageError {
                Text(pageError)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(6)
            }

            DigiHRWebView(
                webView: $state.webView,
                selectedMode: state.selectedMode,
                isLoading: $isLoading
            )
        }
        .background(Color(uiColor: .systemBackground))
    }

    private func modeButton(_ mode: PunchMode) -> some View {
        Button {
            state.selectedMode = mode
            state.webView?.evaluateJavaScript(
                "window.digiHRMobileSetMode && window.digiHRMobileSetMode('\(mode.rawValue)');"
            )
            state.webView?.reload()
        } label: {
            Label(mode.title, systemImage: mode.symbol)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(state.selectedMode == mode ? Color.blue : Color.gray.opacity(0.15))
                .foregroundStyle(state.selectedMode == mode ? .white : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

struct DigiHRWebView: UIViewRepresentable {
    @Binding var webView: WKWebView?
    let selectedMode: PunchMode
    @Binding var isLoading: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(isLoading: $isLoading)
    }

    func makeUIView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        let source = Self.helperScript
        let script = WKUserScript(
            source: source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        controller.addUserScript(script)

        let config = WKWebViewConfiguration()
        config.userContentController = controller

        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        view.scrollView.contentInsetAdjustmentBehavior = .never

        DispatchQueue.main.async {
            webView = view
        }

        if let url = URL(string: "https://basma.ptlc.gov.om/") {
            view.load(URLRequest(url: url))
        }
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        let mode = selectedMode.rawValue
        let js = "window.digiHRMobileSetMode && window.digiHRMobileSetMode('\(mode)');"
        uiView.evaluateJavaScript(js, completionHandler: nil)
    }

    static let helperScript = """
    (function () {
      if (window.__digiHRMobileInstalled) return;
      window.__digiHRMobileInstalled = true;

      var mode = localStorage.getItem('digiHRMobileMode') || 'none';

      window.digiHRMobileSetMode = function (newMode) {
        if (newMode !== 'NP' && newMode !== 'IN' && newMode !== 'none') return;
        mode = newMode;
        try { localStorage.setItem('digiHRMobileMode', mode); } catch (e) {}
        window.dispatchEvent(new CustomEvent('digihr-mobile-mode', { detail: { mode: mode } }));
        window.digiHRMobileRefreshHint();
      };

      // مساعد واجهة فقط: لا يرسل طلب حضور، ولا يغيّر ردود الخادم أو الموقع.
      window.digiHRMobileRefreshHint = function () {
        var old = document.getElementById('__digihr_mobile_mode_hint');
        if (old) old.remove();
        if (mode === 'none') return;

        var hint = document.createElement('div');
        hint.id = '__digihr_mobile_mode_hint';
        hint.textContent = mode === 'NP'
          ? 'وضع الدخول محدد — أكمل إجراء الدخول من النظام'
          : 'وضع الخروج محدد — أكمل إجراء الخروج من النظام';
        hint.setAttribute('role', 'status');
        hint.style.cssText = [
          'position:sticky','top:0','z-index:2147483647',
          'padding:10px 12px','margin:6px','border-radius:10px',
          'background:#e8f1ff','color:#12345a',
          'font:600 14px -apple-system,BlinkMacSystemFont,sans-serif',
          'text-align:center','box-shadow:0 2px 8px rgba(0,0,0,.12)'
        ].join(';');
        if (document.body) document.body.insertBefore(hint, document.body.firstChild);
      };

      document.addEventListener('DOMContentLoaded', function () {
        window.digiHRMobileRefreshHint();
      });
      new MutationObserver(function () {
        if (document.body && mode !== 'none' &&
            !document.getElementById('__digihr_mobile_mode_hint')) {
          window.digiHRMobileRefreshHint();
        }
      }).observe(document.documentElement, { childList: true, subtree: true });
    })();
    """

    final class Coordinator: NSObject, WKNavigationDelegate {
        @Binding var isLoading: Bool
        init(isLoading: Binding<Bool>) { _isLoading = isLoading }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            isLoading = true
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoading = false
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            isLoading = false
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            isLoading = false
        }
    }
}

struct LocationTestPage: View {
    @StateObject private var locator = LocationManager()

    var body: some View {
        NavigationView {
            VStack(spacing: 18) {
                Image(systemName: "location.circle.fill")
                    .font(.system(size: 58))
                    .foregroundStyle(.blue)

                Text("اختبار الموقع الجغرافي")
                    .font(.title2.bold())

                Group {
                    infoRow("حالة الإذن", locator.permissionText)
                    infoRow("خط العرض", locator.latitudeText)
                    infoRow("خط الطول", locator.longitudeText)
                    infoRow("دقة الموقع", locator.accuracyText)
                    infoRow("آخر تحديث", locator.updatedText)
                }

                Button {
                    locator.requestLocation()
                } label: {
                    Label("اختبار / تحديث الموقع", systemImage: "location.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }

                if let error = locator.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("اختبار الموقع")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.medium).multilineTextAlignment(.trailing)
        }
        .padding(12)
        .background(Color.gray.opacity(0.09))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()

    @Published var permissionText = "لم يتم طلب الإذن"
    @Published var latitudeText = "—"
    @Published var longitudeText = "—"
    @Published var accuracyText = "—"
    @Published var updatedText = "—"
    @Published var errorMessage: String?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        updatePermission()
    }

    var permissionTextValue: String { permissionText }

    func requestLocation() {
        errorMessage = nil
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            errorMessage = "إذن الموقع مرفوض. فعّله من إعدادات iPhone."
        default:
            manager.requestLocation()
        }
    }

    private func updatePermission() {
        switch manager.authorizationStatus {
        case .notDetermined: permissionText = "لم يتم طلب الإذن"
        case .restricted: permissionText = "مقيّد"
        case .denied: permissionText = "مرفوض"
        case .authorizedWhenInUse: permissionText = "مسموح أثناء الاستخدام"
        case .authorizedAlways: permissionText = "مسموح دائمًا"
        @unknown default: permissionText = "غير معروف"
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        DispatchQueue.main.async {
            self.updatePermission()
            if manager.authorizationStatus == .authorizedWhenInUse ||
                manager.authorizationStatus == .authorizedAlways {
                manager.requestLocation()
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        DispatchQueue.main.async {
            self.latitudeText = String(format: "%.8f", location.coordinate.latitude)
            self.longitudeText = String(format: "%.8f", location.coordinate.longitude)
            self.accuracyText = String(format: "± %.1f متر", location.horizontalAccuracy)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "ar")
            formatter.dateStyle = .short
            formatter.timeStyle = .medium
            self.updatedText = formatter.string(from: location.timestamp)
            self.errorMessage = nil
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        DispatchQueue.main.async {
            self.errorMessage = error.localizedDescription
        }
    }
}
