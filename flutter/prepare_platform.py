"""Sync flutter/src to flutter/lib, bundle brand logo assets, and configure Apple/Windows native shells."""
from pathlib import Path
import re
import plistlib
import shutil
import struct
import subprocess
import sys
ROOT = Path(__file__).resolve().parent
REPO_ROOT = ROOT.parent
LOGO_MARK = REPO_ROOT / "android" / "src" / "main" / "res" / "drawable-nodpi" / "logo_mark.png"
OPAQUE_ICON = REPO_ROOT / "docs" / "images" / "app-icon-512.png"

IOS_NETDISK_AUTH_CHANNEL_SNIPPET = r'''
      let authChannel = FlutterMethodChannel(name: "marco_movie/netdisk_auth", binaryMessenger: controller.binaryMessenger)
      authChannel.setMethodCallHandler { [weak controller] call, result in
        if call.method == "startWebAuth", let args = call.arguments as? [String: Any] {
          let drive = (args["drive"] as? String) ?? ""
          let urlStr = (args["url"] as? String) ?? ""
          let qrUrl = (args["qrUrl"] as? String) ?? ""
          DispatchQueue.main.async {
            NetdiskWebAuthController.present(
              from: controller,
              drive: drive,
              urlString: urlStr,
              qrUrlString: qrUrl,
              completion: result
            )
          }
        } else {
          result(FlutterMethodNotImplemented)
        }
      }'''

IOS_NETDISK_AUTH_CONTROLLER_SWIFT = r'''

private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
  weak var target: WKScriptMessageHandler?
  init(_ target: WKScriptMessageHandler) {
    self.target = target
  }
  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    target?.userContentController(userContentController, didReceive: message)
  }
}

final class NetdiskWebAuthController: UIViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, WKHTTPCookieStoreObserver, UIAdaptivePresentationControllerDelegate {
  private static let mobileSafariUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"
  private static let desktopSafariUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"

  private static let baiduAppJumpScript = #"""
  (function() {
    if (location.hostname !== 'wappass.baidu.com') return;
    if (window.__marcoBaiduAppJumpTried) return;
    var tries = 0;
    var timer = setInterval(function() {
      tries++;
      var btn = document.querySelector('.other-button');
      if (btn && btn.offsetParent !== null) {
        var txt = String(btn.innerText || btn.textContent || '');
        if (txt.indexOf('登录') !== -1 || txt.indexOf('授权') !== -1) {
          window.__marcoBaiduAppJumpTried = true;
          clearInterval(timer);
          setTimeout(function() { btn.click(); }, 120);
          return;
        }
      }
      if (tries >= 24) clearInterval(timer);
    }, 250);
  })();
  """#

  private static let aliHookScript = #"""
  (function() {
    var host = String(location.hostname || '').toLowerCase();
    if (!host.endsWith('aliyundrive.com') && !host.endsWith('alipan.com')) return;
    function post(payload) {
      try {
        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.marcoAuth) {
          window.webkit.messageHandlers.marcoAuth.postMessage(payload);
        }
      } catch (_) {}
    }
    function inspectObject(obj) {
      if (!obj) return;
      if (typeof obj === 'string') {
        var s = obj.trim();
        if (s.charCodeAt(0) === 123) {
          try { obj = JSON.parse(s); } catch (_) { return; }
        } else {
          return;
        }
      }
      if (typeof obj !== 'object') return;
      var rt = (obj.tokenInfo && (obj.tokenInfo.refresh_token || obj.tokenInfo.refreshToken))
        || obj.refresh_token || obj.refreshToken
        || (obj.pds_login_result && (obj.pds_login_result.refreshToken || obj.pds_login_result.refresh_token))
        || (obj.data && (obj.data.refresh_token || obj.data.refreshToken));
      if (typeof rt === 'string' && rt.length >= 16 && rt.indexOf('=') === -1) {
        post({ type: 'credential', credential: 'ali_token=' + rt });
        return;
      }
      var biz = obj.bizExt || (obj.data && obj.data.bizExt) || (obj.content && obj.content.data && obj.content.data.bizExt);
      if (typeof biz === 'string' && biz.length >= 16) {
        post({ type: 'bizExt', bizExt: biz });
      }
    }
    window.addEventListener('message', function(e) {
      try { inspectObject(e && e.data); } catch (_) {}
    }, true);
    try {
      var origSetItem = Storage.prototype.setItem;
      Storage.prototype.setItem = function(k, v) {
        try {
          if (k === 'token' && typeof v === 'string') inspectObject(v);
        } catch (_) {}
        return origSetItem.apply(this, arguments);
      };
    } catch (_) {}
    try {
      var origOpen = XMLHttpRequest.prototype.open;
      var origSend = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function(m, u) {
        this.__marcoUrl = String(u || '');
        return origOpen.apply(this, arguments);
      };
      XMLHttpRequest.prototype.send = function() {
        this.addEventListener('load', function() {
          try {
            var u = this.__marcoUrl || '';
            if (u.indexOf('token') !== -1 || u.indexOf('login') !== -1 || u.indexOf('oauth') !== -1) {
              inspectObject(this.responseText);
            }
          } catch (_) {}
        });
        return origSend.apply(this, arguments);
      };
    } catch (_) {}
    try {
      if (window.fetch) {
        var origFetch = window.fetch;
        window.fetch = function() {
          var first = arguments[0];
          var u = String(first && first.url ? first.url : first || '');
          return origFetch.apply(this, arguments).then(function(res) {
            try {
              if (u.indexOf('token') !== -1 || u.indexOf('login') !== -1 || u.indexOf('oauth') !== -1) {
                res.clone().text().then(inspectObject).catch(function() {});
              }
            } catch (_) {}
            return res;
          });
        };
      }
    } catch (_) {}
  })();
  """#

  private let driveKey: String
  private let initialUrlString: String
  private let qrUrlString: String
  private var completion: FlutterResult?
  private var completed = false
  private var panAuthTriggered = false
  private var webView: WKWebView!
  private var dataStore: WKWebsiteDataStore?
  private let hintLabel = UILabel()
  private var observers: [NSObjectProtocol] = []

  init(drive: String, urlString: String, qrUrlString: String, completion: @escaping FlutterResult) {
    self.driveKey = drive
    self.initialUrlString = urlString
    self.qrUrlString = qrUrlString
    self.completion = completion
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    if !completed {
      completed = true
      let callback = completion
      completion = nil
      DispatchQueue.main.async {
        callback?(nil)
      }
    }
  }

  static func present(from root: UIViewController?, drive: String, urlString: String, qrUrlString: String, completion: @escaping FlutterResult) {
    var presenter = root
    if presenter == nil {
      presenter = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap { $0.windows }
        .first(where: { $0.isKeyWindow })?.rootViewController
    }
    while let presented = presenter?.presentedViewController, !presented.isBeingDismissed {
      presenter = presented
    }
    guard let host = presenter else {
      completion(nil)
      return
    }
    let vc = NetdiskWebAuthController(drive: drive, urlString: urlString, qrUrlString: qrUrlString, completion: completion)
    let nav = UINavigationController(rootViewController: vc)
    nav.modalPresentationStyle = .pageSheet
    nav.presentationController?.delegate = vc
    nav.overrideUserInterfaceStyle = .dark
    host.present(nav, animated: true, completion: nil)
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    overrideUserInterfaceStyle = .dark
    view.backgroundColor = UIColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1.0)
    switch driveKey {
    case "baidu":
      navigationItem.title = "百度网盘登录授权"
    case "ali":
      navigationItem.title = "阿里云盘登录授权"
    case "quark":
      navigationItem.title = "夸克网盘登录授权"
    case "uc":
      navigationItem.title = "UC网盘登录授权"
    default:
      navigationItem.title = "网盘账号授权"
    }
    navigationItem.leftBarButtonItem = UIBarButtonItem(
      title: "关闭",
      style: .plain,
      target: self,
      action: #selector(closeTapped)
    )
    if driveKey == "ali" {
      navigationItem.rightBarButtonItem = UIBarButtonItem(
        title: "App扫码",
        style: .plain,
        target: self,
        action: #selector(openScanAppTapped)
      )
    }

    let config = WKWebViewConfiguration()
    let store = WKWebsiteDataStore.nonPersistent()
    self.dataStore = store
    config.websiteDataStore = store
    let contentController = WKUserContentController()
    contentController.add(WeakScriptMessageHandler(self), name: "marcoAuth")
    if driveKey == "ali" {
      contentController.addUserScript(
        WKUserScript(source: Self.aliHookScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
      )
    } else if driveKey == "baidu" {
      contentController.addUserScript(
        WKUserScript(source: Self.baiduAppJumpScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
      )
    }
    config.userContentController = contentController
    store.httpCookieStore.add(self)

    let banner = UIView()
    banner.translatesAutoresizingMaskIntoConstraints = false
    banner.backgroundColor = UIColor(red: 0.13, green: 0.14, blue: 0.18, alpha: 1.0)
    hintLabel.translatesAutoresizingMaskIntoConstraints = false
    hintLabel.font = UIFont.systemFont(ofSize: 12.5, weight: .medium)
    hintLabel.textColor = UIColor(white: 0.88, alpha: 1.0)
    hintLabel.numberOfLines = 2
    hintLabel.textAlignment = .center
    hintLabel.text = initialHintText()
    banner.addSubview(hintLabel)

    let wv = WKWebView(frame: .zero, configuration: config)
    wv.translatesAutoresizingMaskIntoConstraints = false
    wv.navigationDelegate = self
    wv.uiDelegate = self
    wv.allowsBackForwardNavigationGestures = true
    wv.customUserAgent = (driveKey == "baidu" || driveKey == "ali") ? Self.mobileSafariUA : Self.desktopSafariUA
    self.webView = wv

    view.addSubview(banner)
    view.addSubview(wv)
    let guide = view.safeAreaLayoutGuide
    NSLayoutConstraint.activate([
      banner.topAnchor.constraint(equalTo: guide.topAnchor),
      banner.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      banner.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      hintLabel.topAnchor.constraint(equalTo: banner.topAnchor, constant: 7),
      hintLabel.bottomAnchor.constraint(equalTo: banner.bottomAnchor, constant: -7),
      hintLabel.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: 12),
      hintLabel.trailingAnchor.constraint(equalTo: banner.trailingAnchor, constant: -12),
      wv.topAnchor.constraint(equalTo: banner.bottomAnchor),
      wv.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      wv.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      wv.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])

    let center = NotificationCenter.default
    for name in [UIApplication.didBecomeActiveNotification, UIApplication.willEnterForegroundNotification] {
      let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        self?.handleAppForegrounded()
      }
      observers.append(token)
    }

    if let targetUrl = URL(string: resolvedInitialUrl()) {
      wv.load(URLRequest(url: targetUrl))
    }
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    if isBeingDismissed || navigationController?.isBeingDismissed == true {
      finish(with: nil, dismissModal: false)
    }
  }

  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    finish(with: nil, dismissModal: false)
  }

  @objc private func closeTapped() {
    finish(with: nil, dismissModal: true)
  }

  @objc private func openScanAppTapped() {
    finish(with: ["type": "openScanApp"], dismissModal: true)
  }

  private func initialHintText() -> String {
    switch driveKey {
    case "baidu":
      for scheme in ["bdnetdisk://", "baiduyunipad://", "baiduyun://"] {
        if let u = URL(string: scheme), UIApplication.shared.canOpenURL(u) {
          return "正在唤起百度网盘 App，确认「授权登录」后返回即可自动完成登录"
        }
      }
      return "支持唤起百度 App 授权或直接在此页面登录，完成后自动同步"
    case "ali":
      return "支持本机免密 / 淘宝跳转 / 验证码登录，或点右上角用阿里云盘相册扫码"
    default:
      return "登录完成后将自动同步网盘状态并返回"
    }
  }

  private func resolvedInitialUrl() -> String {
    guard driveKey == "baidu" else { return initialUrlString }
    let candidates: [(scheme: String, authApp: String, appScheme: String)] = [
      ("bdnetdisk://", "netDisk", "bdnetdisk"),
      ("baiduyunipad://", "netDisk", "baiduyunipad"),
      ("baiduyun://", "netDisk", "baiduyun"),
      ("baiduboxapp://", "baidu", "baiduboxapp"),
    ]
    for item in candidates {
      if let probe = URL(string: item.scheme), UIApplication.shared.canOpenURL(probe) {
        let sep = initialUrlString.contains("?") ? "&" : "?"
        return "\(initialUrlString)\(sep)authApp=\(item.authApp)&appScheme=\(item.appScheme)"
      }
    }
    return initialUrlString
  }

  private func handleAppForegrounded() {
    guard !completed, let wv = webView else { return }
    if driveKey == "baidu" {
      wv.evaluateJavaScript(
        "try { document.dispatchEvent(new Event('visibilitychange')); window.dispatchEvent(new Event('focus')); window.dispatchEvent(new Event('pageshow')); } catch (_) {}",
        completionHandler: nil
      )
    }
    inspectCookies()
  }

  func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    guard let url = navigationAction.request.url else {
      decisionHandler(.allow)
      return
    }
    let scheme = (url.scheme ?? "").lowercased()
    if ["http", "https", "about", "data", "blob", "javascript"].contains(scheme) {
      decisionHandler(.allow)
      return
    }
    if scheme == "marcomovie" {
      handleAppForegrounded()
      decisionHandler(.cancel)
      return
    }
    var targetUrl = url
    let raw = url.absoluteString
    if raw.contains("com.baidu.passport/grantweb") {
      let patched = raw.replacingOccurrences(of: "browserScheme=&", with: "browserScheme=marcomovie%3A%2F%2Fauth&")
      let finalStr = patched.hasSuffix("browserScheme=") ? (patched + "marcomovie%3A%2F%2Fauth") : patched
      if let rewritten = URL(string: finalStr) {
        targetUrl = rewritten
      }
    }
    UIApplication.shared.open(targetUrl, options: [:], completionHandler: nil)
    decisionHandler(.cancel)
  }

  func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
    if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
      let scheme = (url.scheme ?? "").lowercased()
      if ["http", "https"].contains(scheme) {
        webView.load(navigationAction.request)
      } else {
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
      }
    }
    return nil
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    inspectCookies()
  }

  func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
    inspectCookies()
  }

  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    guard message.name == "marcoAuth", !completed else { return }
    guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
    if type == "credential", let cred = body["credential"] as? String, !cred.isEmpty {
      finish(with: ["type": "credential", "credential": cred], dismissModal: true)
    } else if type == "bizExt", let biz = body["bizExt"] as? String, !biz.isEmpty {
      finish(with: ["type": "bizExt", "bizExt": biz], dismissModal: true)
    }
  }

  private func inspectCookies() {
    guard !completed, let store = dataStore?.httpCookieStore else { return }
    store.getAllCookies { [weak self] cookies in
      guard let self = self, !self.completed else { return }
      let now = Date()
      let valid = cookies.filter { c in
        if c.value.isEmpty { return false }
        if let exp = c.expiresDate, exp <= now { return false }
        return true
      }
      switch self.driveKey {
      case "baidu":
        self.evaluateBaiduCookies(valid)
      case "quark":
        self.evaluateQuarkCookies(valid)
      case "uc":
        self.evaluateUcCookies(valid)
      default:
        break
      }
    }
  }

  private func evaluateBaiduCookies(_ valid: [HTTPCookie]) {
    var bduss = ""
    var panStoken = ""
    var rootStoken = ""
    var extra: [String: String] = [:]
    let allowedNames: Set<String> = ["BDUSS", "STOKEN", "PTOKEN", "BAIDUID", "PANPSC", "csrfToken"]
    for c in valid {
      guard allowedNames.contains(c.name) else { continue }
      let dom = c.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
      guard dom == "baidu.com" || dom == "pan.baidu.com" else { continue }
      if c.name == "BDUSS" {
        bduss = c.value
      } else if c.name == "STOKEN" {
        if dom == "pan.baidu.com" {
          panStoken = c.value
        } else {
          rootStoken = c.value
        }
      } else if dom == "pan.baidu.com" || extra[c.name] == nil {
        extra[c.name] = c.value
      }
    }
    guard !bduss.isEmpty else { return }
    let bestStoken = !panStoken.isEmpty ? panStoken : rootStoken
    if !panStoken.isEmpty {
      finishBaiduWith(bduss: bduss, stoken: bestStoken, extra: extra)
      return
    }
    if !panAuthTriggered {
      panAuthTriggered = true
      hintLabel.text = "已获取百度授权，正在同步网盘会话…"
      webView.customUserAgent = Self.desktopSafariUA
      if let authUrl = URL(string: "https://passport.baidu.com/v3/login/api/auth?return_type=3&tpl=netdisk&u=https%3A%2F%2Fpan.baidu.com%2Fdisk%2Fhome") {
        webView.load(URLRequest(url: authUrl))
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
        guard let self = self, !self.completed else { return }
        self.dataStore?.httpCookieStore.getAllCookies { [weak self] latest in
          guard let self = self, !self.completed else { return }
          let now = Date()
          var finalBduss = ""
          var finalStoken = ""
          var finalExtra: [String: String] = [:]
          for c in latest {
            if c.value.isEmpty { continue }
            if let exp = c.expiresDate, exp <= now { continue }
            let dom = c.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            guard dom == "baidu.com" || dom == "pan.baidu.com" else { continue }
            if c.name == "BDUSS" {
              finalBduss = c.value
            } else if c.name == "STOKEN" {
              if dom == "pan.baidu.com" || finalStoken.isEmpty {
                finalStoken = c.value
              }
            } else if ["PTOKEN", "BAIDUID", "PANPSC", "csrfToken"].contains(c.name) {
              if dom == "pan.baidu.com" || finalExtra[c.name] == nil {
                finalExtra[c.name] = c.value
              }
            }
          }
          if !finalBduss.isEmpty {
            self.finishBaiduWith(bduss: finalBduss, stoken: finalStoken, extra: finalExtra)
          }
        }
      }
    } else if webView.url?.host?.lowercased() == "pan.baidu.com" && !bestStoken.isEmpty {
      finishBaiduWith(bduss: bduss, stoken: bestStoken, extra: extra)
    }
  }

  private func finishBaiduWith(bduss: String, stoken: String, extra: [String: String]) {
    var parts: [String] = ["BDUSS=\(bduss)"]
    if !stoken.isEmpty {
      parts.append("STOKEN=\(stoken)")
    }
    for key in ["PTOKEN", "BAIDUID", "PANPSC", "csrfToken"] {
      if let v = extra[key], !v.isEmpty {
        parts.append("\(key)=\(v)")
      }
    }
    finish(with: ["type": "credential", "credential": parts.joined(separator: "; ")], dismissModal: true)
  }

  private func evaluateQuarkCookies(_ valid: [HTTPCookie]) {
    var map: [String: String] = [:]
    for c in valid {
      let dom = c.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
      if dom == "quark.cn" || dom.hasSuffix(".quark.cn") {
        map[c.name] = c.value
      }
    }
    guard let pus = map["__pus"], !pus.isEmpty, let puus = map["__puus"], !puus.isEmpty else { return }
    let header = map.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    finish(with: ["type": "credential", "credential": header], dismissModal: true)
  }

  private func evaluateUcCookies(_ valid: [HTTPCookie]) {
    var map: [String: String] = [:]
    for c in valid {
      let dom = c.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
      if dom == "uc.cn" || dom.hasSuffix(".uc.cn") {
        map[c.name] = c.value
      }
    }
    let pus = map["__pus"] ?? ""
    let puus = map["__puus"] ?? ""
    guard !pus.isEmpty || !puus.isEmpty else { return }
    let header = map.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    finish(with: ["type": "credential", "credential": header], dismissModal: true)
  }

  private func cleanupObservers() {
    let center = NotificationCenter.default
    for token in observers {
      center.removeObserver(token)
    }
    observers.removeAll()
    if let store = dataStore?.httpCookieStore {
      store.remove(self)
    }
    webView?.configuration.userContentController.removeScriptMessageHandler(forName: "marcoAuth")
    webView?.stopLoading()
  }

  private func finish(with value: Any?, dismissModal: Bool) {
    if !Thread.isMainThread {
      DispatchQueue.main.async { [weak self] in
        self?.finish(with: value, dismissModal: dismissModal)
      }
      return
    }
    guard !completed else { return }
    completed = true
    cleanupObservers()
    let callback = completion
    completion = nil
    let target = navigationController ?? self
    if dismissModal, target.presentingViewController != nil, !target.isBeingDismissed {
      target.dismiss(animated: true) {
        callback?(value)
      }
    } else {
      callback?(value)
    }
  }
}
'''

IOS_WEB_SNIFFER_CHANNEL_SNIPPET = r'''
      let snifferChannel = FlutterMethodChannel(name: "marco_movie/web_sniffer", binaryMessenger: controller.binaryMessenger)
      snifferChannel.setMethodCallHandler { call, result in
        if call.method == "sniffMedia", let args = call.arguments as? [String: Any] {
          let urlStr = (args["url"] as? String) ?? ""
          let rawHeaders = (args["headers"] as? [String: Any]) ?? [:]
          var headers: [String: String] = [:]
          for (k, v) in rawHeaders {
            headers[k] = String(describing: v)
          }
          let timeoutMs = (args["timeoutMs"] as? Int) ?? 12000
          HeadlessMediaWebSniffer.sniff(urlString: urlStr, headers: headers, timeoutMs: timeoutMs, completion: result)
        } else {
          result(FlutterMethodNotImplemented)
        }
      }'''

MACOS_WEB_SNIFFER_CHANNEL_SNIPPET = r'''
    let snifferChannel = FlutterMethodChannel(name: "marco_movie/web_sniffer", binaryMessenger: flutterViewController.engine.binaryMessenger)
    snifferChannel.setMethodCallHandler { call, result in
      if call.method == "sniffMedia", let args = call.arguments as? [String: Any] {
        let urlStr = (args["url"] as? String) ?? ""
        let rawHeaders = (args["headers"] as? [String: Any]) ?? [:]
        var headers: [String: String] = [:]
        for (k, v) in rawHeaders {
          headers[k] = String(describing: v)
        }
        let timeoutMs = (args["timeoutMs"] as? Int) ?? 12000
        HeadlessMediaWebSniffer.sniff(urlString: urlStr, headers: headers, timeoutMs: timeoutMs, completion: result)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }'''

APPLE_WEB_SNIFFER_SWIFT = r'''

private final class WeakSnifferScriptHandler: NSObject, WKScriptMessageHandler {
  weak var target: WKScriptMessageHandler?
  init(_ target: WKScriptMessageHandler) {
    self.target = target
  }
  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    target?.userContentController(userContentController, didReceive: message)
  }
}

private final class HeadlessMediaWebSniffer: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
  private static var activeSniffers: Set<HeadlessMediaWebSniffer> = []
  private static let desktopSafariUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

  private static let hookScript = #"""
  (function() {
    if (window.__marcoMediaSnifferInstalled) return;
    window.__marcoMediaSnifferInstalled = true;
    function looksMedia(raw) {
      if (!raw || typeof raw !== 'string') return false;
      var s = raw.trim();
      if (!s || s.indexOf('blob:') === 0 || s.indexOf('data:') === 0 || s.indexOf('javascript:') === 0) return false;
      var abs = s;
      try { abs = new URL(s, location.href).href; } catch (_) { return false; }
      if (abs.indexOf('http://') !== 0 && abs.indexOf('https://') !== 0 && abs.indexOf('rtmp://') !== 0 && abs.indexOf('rtsp://') !== 0) return false;
      var lower = abs.toLowerCase();
      if (/\.(?:js|mjs|css|png|jpe?g|gif|webp|svg|ico|woff2?|ttf|json|xml|vtt|srt|html?|php)(?:$|[?#])/.test(lower)) return false;
      return /\.(?:m3u8?|mp4|flv|mkv|mpd|webm|m4v|mov)(?:$|[?#])/.test(lower) || /[?&](?:type|format|mime)=[^&#]*(?:m3u8|mp4|flv|mpegurl|video)/.test(lower);
    }
    function report(raw) {
      try {
        if (!looksMedia(raw)) return;
        var abs = new URL(raw.trim(), location.href).href;
        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.marcoSniffer) {
          window.webkit.messageHandlers.marcoSniffer.postMessage({
            url: abs,
            pageUrl: String(location.href || '')
          });
        }
      } catch (_) {}
    }
    try {
      var origOpen = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function(m, u) {
        try { report(String(u || '')); } catch (_) {}
        return origOpen.apply(this, arguments);
      };
    } catch (_) {}
    try {
      if (window.fetch) {
        var origFetch = window.fetch;
        window.fetch = function() {
          try {
            var first = arguments[0];
            report(String(first && first.url ? first.url : first || ''));
          } catch (_) {}
          return origFetch.apply(this, arguments);
        };
      }
    } catch (_) {}
    try {
      var desc = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'src');
      if (desc && desc.set) {
        Object.defineProperty(HTMLMediaElement.prototype, 'src', {
          configurable: true,
          get: desc.get,
          set: function(v) {
            try { report(String(v || '')); } catch (_) {}
            return desc.set.call(this, v);
          }
        });
      }
    } catch (_) {}
    function scanDom() {
      try {
        var videos = document.querySelectorAll('video, source');
        for (var i = 0; i < videos.length; i++) {
          var el = videos[i];
          if (el.tagName === 'VIDEO') {
            try { el.muted = true; } catch (_) {}
            if (el.currentSrc) report(el.currentSrc);
          }
          if (el.src) report(el.src);
          var attr = el.getAttribute && el.getAttribute('src');
          if (attr) report(attr);
        }
      } catch (_) {}
    }
    setInterval(scanDom, 350);
    document.addEventListener('DOMContentLoaded', scanDom, true);
  })();
  """#

  private let targetUrl: URL
  private let headers: [String: String]
  private let timeoutMs: Int
  private var effectiveUa: String
  private var completion: FlutterResult?
  private var completed = false
  private var webView: WKWebView?
  private var dataStore: WKWebsiteDataStore?

  private init(targetUrl: URL, headers: [String: String], timeoutMs: Int, completion: @escaping FlutterResult) {
    self.targetUrl = targetUrl
    self.headers = headers
    self.timeoutMs = timeoutMs
    self.effectiveUa = Self.desktopSafariUA
    for (k, v) in headers {
      if k.lowercased() == "user-agent" && !v.trimmingCharacters(in: .whitespaces).isEmpty && !v.lowercased().hasPrefix("okhttp/") {
        self.effectiveUa = v
        break
      }
    }
    self.completion = completion
    super.init()
  }

  static func sniff(urlString: String, headers: [String: String], timeoutMs: Int, completion: @escaping FlutterResult) {
    DispatchQueue.main.async {
      guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
            let scheme = url.scheme?.lowercased(),
            (scheme == "http" || scheme == "https"),
            url.host != nil else {
        completion(nil)
        return
      }
      let instance = HeadlessMediaWebSniffer(targetUrl: url, headers: headers, timeoutMs: timeoutMs, completion: completion)
      activeSniffers.insert(instance)
      instance.start()
    }
  }

  private static func looksLikePlayableMedia(_ raw: String) -> Bool {
    let lower = raw.lowercased()
    if lower.range(of: #"\.(?:js|mjs|css|png|jpe?g|gif|webp|svg|ico|woff2?|ttf|json|xml|vtt|srt|html?|php)(?:$|[?#])"#, options: .regularExpression) != nil {
      return false
    }
    if lower.range(of: #"\.(?:m3u8?|mp4|flv|mkv|mpd|webm|m4v|mov)(?:$|[?#])"#, options: .regularExpression) != nil {
      return true
    }
    return lower.range(of: #"[?&](?:type|format|mime)=[^&#]*(?:m3u8|mp4|flv|mpegurl|video)"#, options: .regularExpression) != nil
  }

  private func start() {
    let config = WKWebViewConfiguration()
    let store = WKWebsiteDataStore.nonPersistent()
    self.dataStore = store
    config.websiteDataStore = store
    #if os(iOS)
    config.allowsInlineMediaPlayback = true
    config.mediaTypesRequiringUserActionForPlayback = .all
    #elseif os(macOS)
    config.mediaTypesRequiringUserActionForPlayback = .all
    #endif

    let contentController = WKUserContentController()
    contentController.add(WeakSnifferScriptHandler(self), name: "marcoSniffer")
    contentController.addUserScript(
      WKUserScript(source: Self.hookScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    )
    config.userContentController = contentController

    let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 720), configuration: config)
    wv.navigationDelegate = self
    wv.uiDelegate = self
    wv.customUserAgent = effectiveUa
    self.webView = wv

    var req = URLRequest(url: targetUrl, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12.0)
    for (k, v) in headers {
      if k.lowercased() == "user-agent" { continue }
      req.setValue(v, forHTTPHeaderField: k)
    }
    wv.load(req)

    let boundedMs = min(max(timeoutMs, 2000), 20000)
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(boundedMs)) { [weak self] in
      self?.finish(with: nil)
    }
  }

  func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    guard let url = navigationAction.request.url else {
      decisionHandler(.cancel)
      return
    }
    let scheme = (url.scheme ?? "").lowercased()
    if scheme == "rtmp" || scheme == "rtsp" {
      completeWithMedia(url: url, referer: webView.url?.absoluteString ?? targetUrl.absoluteString)
      decisionHandler(.cancel)
      return
    }
    guard ["http", "https", "about", "blob", "data"].contains(scheme) else {
      decisionHandler(.cancel)
      return
    }
    if (scheme == "http" || scheme == "https") && Self.looksLikePlayableMedia(url.absoluteString) {
      let ref = navigationAction.request.value(forHTTPHeaderField: "Referer") ?? webView.url?.absoluteString ?? targetUrl.absoluteString
      completeWithMedia(url: url, referer: ref)
      decisionHandler(.cancel)
      return
    }
    decisionHandler(.allow)
  }

  func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
    if let url = navigationResponse.response.url,
       let scheme = url.scheme?.lowercased(),
       (scheme == "http" || scheme == "https") {
      let mime = (navigationResponse.response.mimeType ?? "").lowercased()
      if mime.contains("mpegurl") || mime.hasPrefix("video/") || mime.contains("dash+xml") || Self.looksLikePlayableMedia(url.absoluteString) {
        completeWithMedia(url: url, referer: webView.url?.absoluteString ?? targetUrl.absoluteString)
        decisionHandler(.cancel)
        return
      }
    }
    decisionHandler(.allow)
  }

  func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
    return nil
  }

  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    guard message.name == "marcoSniffer", !completed else { return }
    guard let body = message.body as? [String: Any],
          let rawUrl = body["url"] as? String,
          let mediaUrl = URL(string: rawUrl),
          let scheme = mediaUrl.scheme?.lowercased(),
          ["http", "https", "rtmp", "rtsp"].contains(scheme),
          mediaUrl.host != nil,
          Self.looksLikePlayableMedia(mediaUrl.absoluteString) else {
      return
    }
    let pageUrl = (body["pageUrl"] as? String) ?? ""
    let referer = (pageUrl.hasPrefix("http://") || pageUrl.hasPrefix("https://"))
      ? pageUrl
      : (webView?.url?.absoluteString ?? targetUrl.absoluteString)
    completeWithMedia(url: mediaUrl, referer: referer)
  }

  private func completeWithMedia(url: URL, referer: String) {
    guard !completed else { return }
    let mediaHost = (url.host ?? "").lowercased()
    guard let store = dataStore?.httpCookieStore else {
      finish(with: [
        "url": url.absoluteString,
        "headers": ["Referer": referer, "User-Agent": effectiveUa]
      ])
      return
    }
    store.getAllCookies { [weak self] cookies in
      guard let self = self, !self.completed else { return }
      let now = Date()
      var cookiePairs: [String] = []
      for c in cookies {
        if c.value.isEmpty { continue }
        if let exp = c.expiresDate, exp <= now { continue }
        let rawDom = c.domain.lowercased()
        let cleanDom = rawDom.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let matched = rawDom.hasPrefix(".")
          ? (mediaHost == cleanDom || mediaHost.hasSuffix("." + cleanDom))
          : (mediaHost == cleanDom)
        if matched {
          cookiePairs.append("\(c.name)=\(c.value)")
        }
      }
      var outHeaders: [String: String] = [
        "Referer": referer,
        "User-Agent": self.effectiveUa
      ]
      if !cookiePairs.isEmpty {
        outHeaders["Cookie"] = cookiePairs.joined(separator: "; ")
      }
      self.finish(with: [
        "url": url.absoluteString,
        "headers": outHeaders
      ])
    }
  }

  private func finish(with payload: [String: Any]?) {
    if !Thread.isMainThread {
      DispatchQueue.main.async { [weak self] in
        self?.finish(with: payload)
      }
      return
    }
    guard !completed else { return }
    completed = true
    webView?.configuration.userContentController.removeScriptMessageHandler(forName: "marcoSniffer")
    webView?.stopLoading()
    webView?.navigationDelegate = nil
    webView?.uiDelegate = nil
    webView = nil
    dataStore = nil
    let callback = completion
    completion = nil
    Self.activeSniffers.remove(self)
    callback?(payload)
  }
}
'''

def _png_dimensions(path: Path) -> tuple[int, int]:
    data = path.read_bytes()
    if len(data) >= 24 and data[:8] == b"\x89PNG\r\n\x1a\n":
        w, h = struct.unpack(">II", data[16:24])
        if w > 0 and h > 0:
            return w, h
    return 1024, 1024

def _replace_xcassets_icons(appiconset_dir: Path, source_png: Path) -> None:
    if not appiconset_dir.exists() or not source_png.exists():
        return
    sips = shutil.which("sips")
    for png_file in appiconset_dir.glob("*.png"):
        w, h = _png_dimensions(png_file)
        shutil.copy2(source_png, png_file)
        if sips:
            subprocess.run(
                [sips, "-z", str(h), str(w), str(png_file)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )

def _write_windows_ico(ico_path: Path, source_png: Path) -> None:
    if not ico_path.parent.exists():
        return
    # Multi-resolution transparent assets prevent a gray square and poor shell scaling.
    frames = []
    for size in (16, 20, 24, 32, 40, 48, 64, 128, 256):
        png = ROOT / "brand" / "windows" / f"{size}.png"
        if _png_dimensions(png) != (size, size):
            raise ValueError("Invalid Windows icon frame")
        frames.append((size, png.read_bytes()))
    offset = 6 + 16 * len(frames)
    directory = bytearray(struct.pack("<HHH", 0, 1, len(frames)))
    payload = bytearray()
    for size, data in frames:
        directory.extend(struct.pack("<BBBBHHII", size % 256, size % 256, 0, 0, 1, 32, len(data), offset))
        payload.extend(data)
        offset += len(data)
    ico_path.write_bytes(directory + payload)


def main() -> None:
    subprocess.run([sys.executable, str(REPO_ROOT / 'scripts/prepare_python_html.py'), '--check'], check=True)
    subprocess.run([sys.executable, str(REPO_ROOT / 'scripts/prepare_python_modules.py'), '--check'], check=True)
    src = ROOT / "src"
    lib = ROOT / "lib"
    if src.exists():
        if lib.exists():
            for existing in list(lib.rglob("*.dart")):
                rel = existing.relative_to(lib)
                if not (src / rel).exists():
                    existing.unlink()
        shutil.copytree(src, lib, dirs_exist_ok=True)
    # Bundle user's brand logo into flutter/assets/logo_mark.png
    assets_dir = ROOT / "assets"
    assets_dir.mkdir(parents=True, exist_ok=True)
    shutil.copytree(REPO_ROOT / 'shared/catpaw', assets_dir / 'catpaw', dirs_exist_ok=True)
    python_host = REPO_ROOT / "android/src/main/assets/python-host"
    shutil.copytree(python_host, assets_dir / "python-host", dirs_exist_ok=True)
    (assets_dir / 'js-host').mkdir(parents=True, exist_ok=True)
    for name in ('module-interop.js', 'catvod.mjs', 'crypto-js.js', 'crypto.LICENSE'):
        shutil.copyfile(REPO_ROOT / 'android/src/main/assets/js-host' / name,
                        assets_dir / 'js-host' / name)
    if LOGO_MARK.exists():
        shutil.copy2(LOGO_MARK, assets_dir / "logo_mark.png")
    widget_test = ROOT / "test" / "widget_test.dart"
    if widget_test.exists():
        widget_test.unlink()
    # macOS entitlements, deployment target, app icon, and native dark full-size window
    macos_runner = ROOT / "macos" / "Runner"
    if macos_runner.exists():
        _replace_xcassets_icons(
            macos_runner / "Assets.xcassets" / "AppIcon.appiconset",
            LOGO_MARK if LOGO_MARK.exists() else OPAQUE_ICON,
        )
        for ent in macos_runner.glob("*.entitlements"):
            text = ent.read_text(encoding="utf-8")
            if "com.apple.security.network.server" not in text:
                text = text.replace(
                    "</dict>",
                    "  <key>com.apple.security.network.server</key>\n  <true/>\n</dict>",
                )
            if "com.apple.security.network.client" not in text:
                text = text.replace(
                    "</dict>",
                    "  <key>com.apple.security.network.client</key>\n  <true/>\n</dict>",
                )
            # Offline downloads are saved to ~/Downloads/Marco Movie
            if "com.apple.security.files.downloads.read-write" not in text:
                text = text.replace(
                    "</dict>",
                    "  <key>com.apple.security.files.downloads.read-write</key>\n  <true/>\n</dict>",
                )
            ent.write_text(text, encoding="utf-8")
        info_plist = macos_runner / "Info.plist"
        if info_plist.exists():
            text = info_plist.read_text(encoding="utf-8")
            text = text.replace("<string>marco_movie</string>", "<string>Marco Movie</string>")
            if "NSLocalNetworkUsageDescription" not in text:
                text = text.replace("</dict>\n</plist>",
                    "  <key>NSLocalNetworkUsageDescription</key>\n"
                    "  <string>连接你添加的局域网 Emby 服务器及片源。</string>\n</dict>\n</plist>")
            if "NSAppTransportSecurity" not in text:
                text = text.replace(
                    "</dict>",
                    "  <key>NSAppTransportSecurity</key>\n  <dict>\n    <key>NSAllowsArbitraryLoads</key>\n    <true/>\n  </dict>\n</dict>",
                    1,
                )
            info_plist.write_text(text, encoding="utf-8")
        window_swift = macos_runner / "MainFlutterWindow.swift"
        if window_swift.exists():
            swift_text = window_swift.read_text(encoding="utf-8")
            if "import WebKit" not in swift_text and "import FlutterMacOS" in swift_text:
                swift_text = swift_text.replace("import FlutterMacOS", "import FlutterMacOS\nimport WebKit", 1)
            if "playbackActivity" not in swift_text:
                swift_text = swift_text.replace(
                    "class MainFlutterWindow: NSWindow {",
                    "class MainFlutterWindow: NSWindow {\n"
                    "  private var playbackActivity: NSObjectProtocol?",
                    1,
                )
            if "marco_movie/wakelock" not in swift_text and "RegisterGeneratedPlugins(registry: flutterViewController)" in swift_text:
                swift_text = swift_text.replace(
                    "RegisterGeneratedPlugins(registry: flutterViewController)",
                    "RegisterGeneratedPlugins(registry: flutterViewController)\n"
                    "    let wakelockChannel = FlutterMethodChannel(name: \"marco_movie/wakelock\", binaryMessenger: flutterViewController.engine.binaryMessenger)\n"
                    "    wakelockChannel.setMethodCallHandler { [weak self] call, result in\n"
                    "      if call.method == \"setEnabled\", let enabled = call.arguments as? Bool {\n"
                    "        if enabled {\n"
                    "          if self?.playbackActivity == nil {\n"
                    "            self?.playbackActivity = ProcessInfo.processInfo.beginActivity(options: .idleDisplaySleepDisabled, reason: \"Marco Movie Video Playback\")\n"
                    "          }\n"
                    "        } else if let token = self?.playbackActivity {\n"
                    "          ProcessInfo.processInfo.endActivity(token)\n"
                    "          self?.playbackActivity = nil\n"
                    "        }\n"
                    "        result(nil)\n"
                    "      } else {\n"
                    "        result(FlutterMethodNotImplemented)\n"
                    "      }\n"
                    "    }",
                    1,
                )
            if "marco_movie/web_sniffer" not in swift_text and "RegisterGeneratedPlugins(registry: flutterViewController)" in swift_text:
                swift_text = swift_text.replace(
                    "RegisterGeneratedPlugins(registry: flutterViewController)",
                    "RegisterGeneratedPlugins(registry: flutterViewController)"
                    + MACOS_WEB_SNIFFER_CHANNEL_SNIPPET,
                    1,
                )
            if "private final class HeadlessMediaWebSniffer" not in swift_text:
                swift_text = swift_text.rstrip() + "\n" + APPLE_WEB_SNIFFER_SWIFT
            if "titlebarAppearsTransparent" not in swift_text:
                swift_text = swift_text.replace(
                    "super.awakeFromNib()",
                    "self.titleVisibility = .hidden\n"
                    "    self.titlebarAppearsTransparent = true\n"
                    "    self.styleMask.insert(.fullSizeContentView)\n"
                    "    self.appearance = NSAppearance(named: .darkAqua)\n"
                    "    self.minSize = NSSize(width: 900, height: 600)\n"
                    "    super.awakeFromNib()",
                )
            window_swift.write_text(swift_text, encoding="utf-8")
    macos_podfile = ROOT / "macos" / "Podfile"
    if macos_podfile.exists():
        text = macos_podfile.read_text(encoding="utf-8")
        text = re.sub(
            r"#?\s*platform\s+:osx\s*,\s*'[^']+'",
            "platform :osx, '11.0'",
            text,
        )
        macos_podfile.write_text(text, encoding="utf-8")
    macos_pbx = ROOT / "macos" / "Runner.xcodeproj" / "project.pbxproj"
    if macos_pbx.exists():
        text = macos_pbx.read_text(encoding="utf-8")
        text = re.sub(
            r"MACOSX_DEPLOYMENT_TARGET\s*=\s*10\.\d+;",
            "MACOSX_DEPLOYMENT_TARGET = 11.0;",
            text,
        )
        macos_pbx.write_text(text, encoding="utf-8")
    # iOS Info.plist, deployment target, and opaque AppIcon set
    ios_runner = ROOT / "ios" / "Runner"
    if ios_runner.exists():
        _replace_xcassets_icons(
            ios_runner / "Assets.xcassets" / "AppIcon.appiconset",
            OPAQUE_ICON if OPAQUE_ICON.exists() else LOGO_MARK,
        )
        ios_plist = ios_runner / "Info.plist"
        if ios_plist.exists():
            info = plistlib.loads(ios_plist.read_bytes())
            info.update({
                'CFBundleDisplayName': 'Marco Movie',
                'CFBundleAllowMixedLocalizations': True,
                'UIStatusBarStyle': 'UIStatusBarStyleLightContent',
                'UIViewControllerBasedStatusBarAppearance': False,
                'NSLocalNetworkUsageDescription': '连接你添加的局域网 Emby 服务器及片源。',
                'UIFileSharingEnabled': True,
                'LSSupportsOpeningDocumentsInPlace': True,
                'FlutterDeepLinkingEnabled': False,
                'LSApplicationQueriesSchemes': [
                    'apple-magnifier',
                    'qklink',
                    'qkcloudlink',
                    'quark',
                    'uclink',
                    'ucliteioslink',
                    'ucbrowser',
                    'bdnetdisk',
                    'baiduyun',
                    'baiduyunipad',
                    'baiduboxapp',
                    'smartdrive',
                    'alipan',
                    'aliyundrive',
                    'tbopen',
                    'taobao',
                ],
            })
            url_types = list(info.get('CFBundleURLTypes') or [])
            if not any('marcomovie' in (entry.get('CFBundleURLSchemes') or []) for entry in url_types if isinstance(entry, dict)):
                url_types.append({
                    'CFBundleTypeRole': 'Editor',
                    'CFBundleURLName': 'com.pilipala.marcoMovie',
                    'CFBundleURLSchemes': ['marcomovie'],
                })
            info['CFBundleURLTypes'] = url_types
            info.setdefault('NSAppTransportSecurity', {})['NSAllowsArbitraryLoads'] = True
            ios_plist.write_bytes(plistlib.dumps(info, sort_keys=False))
        ios_app_delegate = ios_runner / "AppDelegate.swift"
        if ios_app_delegate.exists():
            ad_text = ios_app_delegate.read_text(encoding="utf-8")
            ad_changed = False
            if "import WebKit" not in ad_text and "import UIKit" in ad_text:
                ad_text = ad_text.replace("import UIKit", "import UIKit\nimport WebKit", 1)
                ad_changed = True
            if "marco_movie/wakelock" not in ad_text and "GeneratedPluginRegistrant.register(with: self)" in ad_text:
                ad_text = ad_text.replace(
                    "GeneratedPluginRegistrant.register(with: self)",
                    "GeneratedPluginRegistrant.register(with: self)\n"
                    "    if let controller = window?.rootViewController as? FlutterViewController {\n"
                    "      let wakelockChannel = FlutterMethodChannel(name: \"marco_movie/wakelock\", binaryMessenger: controller.binaryMessenger)\n"
                    "      wakelockChannel.setMethodCallHandler { call, result in\n"
                    "        if call.method == \"setEnabled\", let enabled = call.arguments as? Bool {\n"
                    "          DispatchQueue.main.async {\n"
                    "            UIApplication.shared.isIdleTimerDisabled = enabled\n"
                    "            result(nil)\n"
                    "          }\n"
                    "        } else {\n"
                    "          result(FlutterMethodNotImplemented)\n"
                    "        }\n"
                    "      }\n"
                    "    }",
                    1,
                )
                ad_changed = True
            if "marco_movie/netdisk_auth" not in ad_text and "if let controller = window?.rootViewController as? FlutterViewController {" in ad_text:
                ad_text = ad_text.replace(
                    "    if let controller = window?.rootViewController as? FlutterViewController {",
                    "    if let controller = window?.rootViewController as? FlutterViewController {"
                    + IOS_NETDISK_AUTH_CHANNEL_SNIPPET,
                    1,
                )
                ad_text = ad_text.rstrip() + "\n" + IOS_NETDISK_AUTH_CONTROLLER_SWIFT
                ad_changed = True
            if "marco_movie/web_sniffer" not in ad_text and "if let controller = window?.rootViewController as? FlutterViewController {" in ad_text:
                ad_text = ad_text.replace(
                    "    if let controller = window?.rootViewController as? FlutterViewController {",
                    "    if let controller = window?.rootViewController as? FlutterViewController {"
                    + IOS_WEB_SNIFFER_CHANNEL_SNIPPET,
                    1,
                )
                ad_changed = True
            if "private final class HeadlessMediaWebSniffer" not in ad_text:
                ad_text = ad_text.rstrip() + "\n" + APPLE_WEB_SNIFFER_SWIFT
                ad_changed = True
            if ad_changed:
                ios_app_delegate.write_text(ad_text, encoding="utf-8")
    ios_app_fw_plist = ROOT / "ios" / "Flutter" / "AppFrameworkInfo.plist"
    if ios_app_fw_plist.exists():
        text = ios_app_fw_plist.read_text(encoding="utf-8")
        text = re.sub(
            r"(<key>MinimumOSVersion</key>\s*<string>)[^<]+(</string>)",
            r"\g<1>14.0\g<2>",
            text,
        )
        ios_app_fw_plist.write_text(text, encoding="utf-8")
    for xcconfig_name in ("Release.xcconfig", "Debug.xcconfig", "Profile.xcconfig"):
        xcconfig = ROOT / "ios" / "Flutter" / xcconfig_name
        if xcconfig.exists():
            text = xcconfig.read_text(encoding="utf-8")
            if "no_fixup_chains" not in text:
                text = (
                    text.rstrip()
                    + "\nIPHONEOS_DEPLOYMENT_TARGET = 14.0\n"
                    + "OTHER_LDFLAGS = $(inherited) -Wl,-no_fixup_chains\n"
                    + "OTHER_CFLAGS = $(inherited) -fno-objc-msgsend-selector-stubs\n"
                )
                xcconfig.write_text(text, encoding="utf-8")
    ios_pbx = ROOT / "ios" / "Runner.xcodeproj" / "project.pbxproj"
    if ios_pbx.exists():
        text = ios_pbx.read_text(encoding="utf-8")
        text = re.sub(
            r"IPHONEOS_DEPLOYMENT_TARGET\s*=\s*[0-9.]+;",
            "IPHONEOS_DEPLOYMENT_TARGET = 14.0;",
            text,
        )
        ios_pbx.write_text(text, encoding="utf-8")
    ios_podfile = ROOT / "ios" / "Podfile"
    if ios_podfile.exists():
        text = ios_podfile.read_text(encoding="utf-8")
        text = re.sub(
            r"#?\s*platform\s+:ios\s*,\s*'[^']+'",
            "platform :ios, '14.0'",
            text,
        )
        if "no_fixup_chains" not in text and "flutter_additional_ios_build_settings(target)" in text:
            text = text.replace(
                "flutter_additional_ios_build_settings(target)",
                "flutter_additional_ios_build_settings(target)\n"
                "    target.build_configurations.each do |config|\n"
                "      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '14.0' if Gem::Version.new(config.build_settings.fetch('IPHONEOS_DEPLOYMENT_TARGET', '0')) < Gem::Version.new('14.0')\n"
                "      config.build_settings['OTHER_LDFLAGS'] = (['$(inherited)'] + Array(config.build_settings['OTHER_LDFLAGS']) + ['-Wl,-no_fixup_chains']).uniq\n"
                "      config.build_settings['OTHER_CFLAGS'] = (['$(inherited)'] + Array(config.build_settings['OTHER_CFLAGS']) + ['-fno-objc-msgsend-selector-stubs']).uniq\n"
                "    end",
            )
        # Upgrade an already generated Podfile as well as a fresh runner. Keep
        # CocoaPods' explicit Flutter/NodeMobile framework link arguments.
        for key, flag in (("OTHER_LDFLAGS", "-Wl,-no_fixup_chains"),
                          ("OTHER_CFLAGS", "-fno-objc-msgsend-selector-stubs")):
            text = text.replace(
                f"config.build_settings['{key}'] = '$(inherited) {flag}'",
                f"config.build_settings['{key}'] = (['$(inherited)'] + Array(config.build_settings['{key}']) + ['{flag}']).uniq",
            )
        ios_podfile.write_text(text, encoding="utf-8")
    # Windows icon, working directory, immediate window show, and title
    win_runner = ROOT / "windows" / "runner"
    win_ico = win_runner / "resources" / "app_icon.ico"
    if win_ico.parent.exists():
        _write_windows_ico(
            win_ico,
            LOGO_MARK,
        )
    win_main = win_runner / "main.cpp"
    if win_main.exists():
        text = win_main.read_text(encoding="utf-8")
        text = text.replace('L"marco_movie"', 'L"Marco Movie"')
        if "SetCurrentDirectoryW" not in text and "wWinMain(" in text:
            init_hook = (
                "  wchar_t exe_path[MAX_PATH];\n"
                "  if (::GetModuleFileNameW(nullptr, exe_path, MAX_PATH) > 0) {\n"
                "    wchar_t* last_slash = wcsrchr(exe_path, L'\\\\');\n"
                "    if (last_slash) {\n"
                "      *last_slash = L'\\0';\n"
                "      ::SetCurrentDirectoryW(exe_path);\n"
                "    }\n"
                "  }\n"
            )
            text = text.replace(
                "  // Attach to console when present",
                init_hook + "  // Attach to console when present",
                1,
            )
        win_main.write_text(text, encoding="utf-8")
    win_fw = win_runner / "flutter_window.cpp"
    if win_fw.exists():
        text = win_fw.read_text(encoding="utf-8")
        changed = False
        if "marco_movie/wakelock" not in text and "RegisterPlugins(flutter_controller_->engine());" in text:
            if "<flutter/method_channel.h>" not in text:
                text = "#include <flutter/method_channel.h>\n#include <flutter/standard_method_codec.h>\n" + text
            text = text.replace(
                "RegisterPlugins(flutter_controller_->engine());",
                "RegisterPlugins(flutter_controller_->engine());\n"
                "  flutter::MethodChannel<flutter::EncodableValue> wakelock_channel(\n"
                "      flutter_controller_->engine()->messenger(), \"marco_movie/wakelock\",\n"
                "      &flutter::StandardMethodCodec::GetInstance());\n"
                "  wakelock_channel.SetMethodCallHandler(\n"
                "      [](const flutter::MethodCall<flutter::EncodableValue>& call,\n"
                "         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {\n"
                "        if (call.method_name() == \"setEnabled\") {\n"
                "          const auto* enabled = std::get_if<bool>(call.arguments());\n"
                "          ::SetThreadExecutionState((enabled && *enabled)\n"
                "              ? (ES_CONTINUOUS | ES_DISPLAY_REQUIRED | ES_SYSTEM_REQUIRED)\n"
                "              : ES_CONTINUOUS);\n"
                "          result->Success();\n"
                "        } else {\n"
                "          result->NotImplemented();\n"
                "        }\n"
                "      });",
                1,
            )
            changed = True
        if "this->Show();" in text and "// Immediate Show on Windows" not in text:
            text = text.replace(
                "SetChildContent(flutter_controller_->view()->GetNativeWindow());",
                "SetChildContent(flutter_controller_->view()->GetNativeWindow());\n"
                "  // Immediate Show on Windows so the window always appears right away\n"
                "  this->Show();",
                1,
            )
            changed = True
        if changed:
            win_fw.write_text(text, encoding="utf-8")

if __name__ == "__main__":
    main()
