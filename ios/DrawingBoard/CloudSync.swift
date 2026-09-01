import Foundation
import WebKit

/// Keeps the board the same on every device signed into the same Apple ID.
///
/// The page stores everything in localStorage under one namespace. A tiny script
/// reports every write to us; we mirror it into iCloud's key-value store, and
/// when iCloud tells us another device wrote something newer, we put it back
/// into localStorage here. Nothing goes anywhere except the person's own iCloud.
final class CloudSync: NSObject, WKScriptMessageHandler {

    static let namespace = "dbshare1."
    static let handlerName = "dbsync"

    /// For the sync X-ray: when iCloud last pushed changes to this device.
    static var lastExternal: Date?
    static var lastExternalKeys = 0

    /// Per-device things that should not travel, plus the background photo
    /// (a full-size photo is far bigger than iCloud key-value storage allows).
    private static let skipKeys: Set<String> = [
        "dbshare1.photo.v1", "dbshare1.installdismiss.v1", "dbshare1.feedback.v1",
    ]
    private static let maxValueBytes = 900_000

    private weak var webView: WKWebView?
    private let cloud = NSUbiquitousKeyValueStore.default
    private let local = UserDefaults.standard
    private(set) var pendingReload = false

    init(webView: WKWebView) {
        self.webView = webView
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(cloudChanged(_:)),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: cloud)
        cloud.synchronize()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: - Page side

    /// Injected at document start: report localStorage writes in our namespace.
    static let bridgeScript = """
    (function(){
      if (window.__dbSyncInstalled) return;
      window.__dbSyncInstalled = true;
      window.__dbSyncApplying = false;
      var NS = "dbshare1.";
      function post(op, key, value){
        if (window.__dbSyncApplying) return;
        try { window.webkit.messageHandlers.dbsync.postMessage({op: op, key: key, value: (value === undefined ? null : value)}); } catch (e) {}
      }
      var proto = Object.getPrototypeOf(window.localStorage);
      var origSet = proto.setItem, origRemove = proto.removeItem, origClear = proto.clear;
      proto.setItem = function(k, v){
        origSet.call(this, k, v);
        if (this === window.localStorage && typeof k === "string" && k.indexOf(NS) === 0) post("set", k, String(v));
      };
      proto.removeItem = function(k){
        origRemove.call(this, k);
        if (this === window.localStorage && typeof k === "string" && k.indexOf(NS) === 0) post("remove", k, null);
      };
      proto.clear = function(){
        var keys = [];
        if (this === window.localStorage) { for (var i = 0; i < this.length; i++) { var k = this.key(i); if (k && k.indexOf(NS) === 0) keys.push(k); } }
        origClear.call(this);
        keys.forEach(function(k){ post("remove", k, null); });
      };
    })();
    """

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let op = body["op"] as? String,
              let key = body["key"] as? String,
              key.hasPrefix(Self.namespace), !Self.skipKeys.contains(key) else { return }
        let now = Date().timeIntervalSince1970
        switch op {
        case "set":
            guard let value = body["value"] as? String, value.utf8.count <= Self.maxValueBytes else { return }
            cloud.set(value, forKey: key)
        case "remove":
            cloud.removeObject(forKey: key)
        default:
            return
        }
        cloud.set(now, forKey: "ts:" + key)
        local.set(now, forKey: "localts:" + key)
        cloud.synchronize()
    }

    // MARK: - Cloud side

    @objc private func cloudChanged(_ note: Notification) {
        let changed = (note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]) ?? []
        let keys = changed.filter { $0.hasPrefix(Self.namespace) }
        Self.lastExternal = Date()
        Self.lastExternalKeys = keys.count
        DispatchQueue.main.async { self.applyRemote(keys: keys, reloadIfIdle: true) }
    }

    /// Called once the page has loaded: push anything only we have, pull anything newer.
    func bootstrap() {
        guard let webView else { return }
        cloud.synchronize()
        let readAll = "(function(){var o={};for(var i=0;i<localStorage.length;i++){var k=localStorage.key(i);if(k&&k.indexOf('\(Self.namespace)')===0)o[k]=localStorage.getItem(k);}return JSON.stringify(o);})()"
        webView.evaluateJavaScript(readAll) { [weak self] result, _ in
            guard let self else { return }
            var localData: [String: String] = [:]
            if let text = result as? String, let data = text.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                localData = dict
            }
            let now = Date().timeIntervalSince1970
            // 1. Anything this device has that iCloud has never seen: send it up.
            for (key, value) in localData where !Self.skipKeys.contains(key) {
                if self.cloud.object(forKey: "ts:" + key) == nil, value.utf8.count <= Self.maxValueBytes {
                    self.cloud.set(value, forKey: key)
                    self.cloud.set(now, forKey: "ts:" + key)
                    self.local.set(now, forKey: "localts:" + key)
                }
            }
            self.cloud.synchronize()
            // 2. Anything iCloud has that is newer than ours: bring it down.
            let cloudKeys = self.cloud.dictionaryRepresentation.keys.filter { $0.hasPrefix(Self.namespace) }
            self.applyRemote(keys: Array(cloudKeys), reloadIfIdle: true)
        }
    }

    private func applyRemote(keys: [String], reloadIfIdle: Bool) {
        guard let webView else { return }
        var updates: [String: Any] = [:]
        for key in keys where !Self.skipKeys.contains(key) {
            let remoteTs = cloud.double(forKey: "ts:" + key)
            let localTs = local.double(forKey: "localts:" + key)
            guard remoteTs > localTs else { continue }
            updates[key] = cloud.string(forKey: key) ?? NSNull()
            local.set(remoteTs, forKey: "localts:" + key)
        }
        guard !updates.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: updates),
              let json = String(data: data, encoding: .utf8) else { return }
        let js = """
        (function(u){ window.__dbSyncApplying = true;
          try { for (var k in u) { try { if (u[k] === null) localStorage.removeItem(k); else localStorage.setItem(k, u[k]); } catch (e) {} } }
          finally { window.__dbSyncApplying = false; }
          var a = document.activeElement; var editing = !!(a && (a.tagName === 'INPUT' || a.tagName === 'TEXTAREA' || a.isContentEditable));
          return editing; })(\(json));
        """
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self else { return }
            let editing = (result as? Bool) ?? false
            if reloadIfIdle && !editing { webView.reload() } else { self.pendingReload = true }
        }
    }

    /// Call when the app comes back to the foreground.
    func becameActive() {
        cloud.synchronize()
        if pendingReload, let webView {
            pendingReload = false
            webView.reload()
        }
    }
}
