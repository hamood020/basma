import Foundation
import Security
import LocalAuthentication
import WebKit

// MARK: - Saved Windows credential (iPhone Keychain, this device only)

struct WindowsCredential: Codable, Equatable {
    let user: String
    let password: String

    var isComplete: Bool { !user.isEmpty && !password.isEmpty }

    var urlCredential: URLCredential {
        URLCredential(user: user, password: password, persistence: .forSession)
    }
}

enum CredentialStore {
    private static let service = "om.gov.ptlc.digihrmobile.windows-auth"
    private static let account = "windows"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    static func save(_ credential: WindowsCredential) {
        guard let data = try? JSONEncoder().encode(credential) else { return }
        delete()
        var query = baseQuery
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load() -> WindowsCredential? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(WindowsCredential.self, from: data)
    }

    static func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

// MARK: - Face ID / passcode gate before the saved password is used

final class BiometricGate {
    private(set) var unlocked = false
    private var waiters: [(Bool) -> Void] = []

    func unlock(_ done: @escaping (Bool) -> Void) {
        if unlocked { done(true); return }
        waiters.append(done)
        guard waiters.count == 1 else { return }

        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            finish(true)
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication,
                               localizedReason: "استخدام كلمة مرور ويندوز المحفوظة لتسجيل الدخول") { ok, _ in
            DispatchQueue.main.async { self.finish(ok) }
        }
    }

    func markUnlocked() { unlocked = true }

    private func finish(_ ok: Bool) {
        if ok { unlocked = true }
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0(ok) }
    }
}

// MARK: - Script message proxy (avoids a retain cycle with WKUserContentController)

final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

// MARK: - Page script: reads what the user typed in the login form (so it can be used for the
// Windows challenge and offered for saving) and fills the form from the saved credential.

enum CredentialScript {
    static let source = """
    (function () {
      if (window.__digiHRCredsInstalled) return;
      window.__digiHRCredsInstalled = true;

      function fields() {
        var pass = document.querySelector('input[type="password"]');
        if (!pass) return null;
        var inputs = Array.prototype.slice.call(document.querySelectorAll('input'));
        var idx = inputs.indexOf(pass), user = null;
        for (var i = idx - 1; i >= 0; i--) {
          var t = (inputs[i].type || 'text').toLowerCase();
          if (t === 'text' || t === 'email') { user = inputs[i]; break; }
        }
        return { user: user, pass: pass };
      }

      function post(msg) {
        try { window.webkit.messageHandlers.digiHRCreds.postMessage(msg); } catch (e) {}
      }

      function capture() {
        var f = fields();
        if (!f) return;
        var u = f.user ? f.user.value : '';
        var p = f.pass.value;
        if (u || p) post({ user: u, pass: p });
      }

      document.addEventListener('click', function (e) {
        var el = e.target && e.target.closest ? e.target.closest('button, [type=submit], .btn') : null;
        if (el) capture();
      }, true);
      document.addEventListener('keydown', function (e) {
        if (e.key === 'Enter') capture();
      }, true);

      function setValue(el, v) {
        var setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
        setter.call(el, v);
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
      }

      window.digiHRFill = function (u, p) {
        var f = fields();
        if (!f) return false;
        if (f.user && !f.user.value && u) setValue(f.user, u);
        if (!f.pass.value && p) setValue(f.pass, p);
        return true;
      };

      var formShown = false;
      function check() {
        var visible = !!fields();
        if (visible && !formShown) post({ event: 'form' });
        formShown = visible;
      }
      new MutationObserver(check).observe(document.documentElement, { childList: true, subtree: true });
      check();
    })();
    """
}
