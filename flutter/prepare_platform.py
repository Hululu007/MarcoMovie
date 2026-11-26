"""Bundle brand logo assets, and configure Apple/Windows native shells."""
from pathlib import Path
import json
import os
import re
import plistlib
import shutil
import struct
import subprocess
import sys
from urllib.parse import unquote, urlparse
ROOT = Path(__file__).resolve().parent
REPO_ROOT = ROOT.parent
IOS_LIQUID_GLASS_SWIFT_PATH = Path(__file__).resolve().parent / "ios_native" / "MarcoLiquidGlass.swift"
IOS_AVPLAYER_ENGINE_SWIFT_PATH = Path(__file__).resolve().parent / "ios_native" / "MarcoAvPlayerEngine.swift"
IOS_WEB_SNIFFER_JS_HOST_SWIFT_PATH = Path(__file__).resolve().parent / "ios_native" / "MarcoWebSnifferAndJsHost.swift"
_LOGO_MARK_CANDIDATES = (
    REPO_ROOT / "android-tv" / "src" / "main" / "res" / "drawable-nodpi" / "logo_mark.png",
    REPO_ROOT / "android-mobile" / "src" / "main" / "res" / "drawable-nodpi" / "logo_mark.png",
    REPO_ROOT / "android" / "src" / "main" / "res" / "drawable-nodpi" / "logo_mark.png",
    ROOT / "assets" / "logo_mark.png",
)
LOGO_MARK = next((p for p in _LOGO_MARK_CANDIDATES if p.is_file()), _LOGO_MARK_CANDIDATES[0])
OPAQUE_ICON = REPO_ROOT / "docs" / "images" / "app-icon-512.png"
MACOS_ICON_DIR = ROOT / "brand" / "macos"
IOS_ICON = ROOT / "brand" / "ios" / "1024.png"

IOS_NATIVE_CHANNEL_REGISTRAR_SWIFT = r'''

private enum MarcoNativeChannelRegistrar {
  private static weak var primaryFlutterController: FlutterViewController?
  private static var launchSceneObserversInstalled: Bool = false

  /// Ensures the root `UIWindow` and `FlutterViewController` surface are bound
  /// to the active `UIWindowScene`, sized to full scene bounds, and visible.
  /// Fixes iPadOS Home Screen cold launch where SpringBoard's icon-zoom
  /// transaction leaves an un-promoted legacy storyboard window black until a
  /// Dock activation triggers scene layout.
  static func reconcileLaunchWindowAndSurface(reason: String) {
    let delegateWin = UIApplication.shared.delegate?.window ?? nil
    let candidateWin = primaryFlutterController?.viewIfLoaded?.window ?? delegateWin
    if #available(iOS 13.0, *) {
      let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      let targetScene = scenes.first(where: { $0.activationState == .foregroundActive })
        ?? scenes.first(where: { $0.activationState == .foregroundInactive })
        ?? scenes.first
      if let win = candidateWin {
        if win.windowScene == nil, let scene = targetScene {
          win.windowScene = scene
        }
        if let sceneBounds = win.windowScene?.coordinateSpace.bounds,
           sceneBounds.width > 0,
           sceneBounds.height > 0,
           (win.bounds.width <= 0 || win.bounds.height <= 0 ||
            (win.bounds.width == 600 && win.bounds.height == 600 && sceneBounds != win.bounds)) {
          win.frame = sceneBounds
        }
        win.backgroundColor = .systemBackground
        if win.isHidden {
          win.isHidden = false
        }
        let hasSceneKeyWindow = win.windowScene?.windows.contains(where: { $0.isKeyWindow }) ?? win.isKeyWindow
        if !hasSceneKeyWindow {
          win.makeKeyAndVisible()
        }
      }
    } else if let win = candidateWin {
      if win.isHidden {
        win.isHidden = false
      }
      if !win.isKeyWindow {
        win.makeKeyAndVisible()
      }
    }
    if let fvc = primaryFlutterController ?? (candidateWin?.rootViewController as? FlutterViewController) {
      if let win = fvc.viewIfLoaded?.window, win.bounds.width > 0, win.bounds.height > 0, fvc.view.frame != win.bounds {
        fvc.view.frame = win.bounds
      }
      fvc.viewIfLoaded?.setNeedsLayout()
      fvc.viewIfLoaded?.layoutIfNeeded()
    }
    NSLog("[MarcoLaunch] stage=reconcile_window reason=%@ hasWindow=%@", reason, candidateWin != nil ? "true" : "false")
  }

  private static func installLaunchLifecycleObserversIfNeeded() {
    guard !launchSceneObserversInstalled else { return }
    launchSceneObserversInstalled = true
    let center = NotificationCenter.default
    _ = center.addObserver(
      forName: UIApplication.didBecomeActiveNotification,
      object: nil,
      queue: .main
    ) { _ in
      reconcileLaunchWindowAndSurface(reason: "app_did_become_active")
    }
    if #available(iOS 13.0, *) {
      _ = center.addObserver(
        forName: UIScene.willConnectNotification,
        object: nil,
        queue: .main
      ) { _ in
        reconcileLaunchWindowAndSurface(reason: "scene_will_connect")
      }
      _ = center.addObserver(
        forName: UIScene.didActivateNotification,
        object: nil,
        queue: .main
      ) { _ in
        reconcileLaunchWindowAndSurface(reason: "scene_did_activate")
      }
    }
  }

  private static func collectFlutterControllers(
    from root: UIViewController?,
    into out: inout [FlutterViewController]
  ) {
    guard let vc = root else { return }
    if let fvc = vc as? FlutterViewController, !out.contains(where: { $0 === fvc }) {
      out.append(fvc)
    }
    for child in vc.children {
      collectFlutterControllers(from: child, into: &out)
    }
    if let presented = vc.presentedViewController, !presented.isBeingDismissed {
      collectFlutterControllers(from: presented, into: &out)
    }
  }

  private static func windowFlutterControllers() -> [FlutterViewController] {
    var found: [FlutterViewController] = []
    if let activeRoot = MarcoLiquidGlassSupport.activeWindow()?.rootViewController {
      collectFlutterControllers(from: activeRoot, into: &found)
    }
    if #available(iOS 13.0, *) {
      for scene in UIApplication.shared.connectedScenes {
        guard let windowScene = scene as? UIWindowScene else { continue }
        for win in windowScene.windows {
          collectFlutterControllers(from: win.rootViewController, into: &found)
        }
      }
    }
    if let delegateWin = UIApplication.shared.delegate?.window ?? nil {
      collectFlutterControllers(from: delegateWin.rootViewController, into: &found)
    }
    return found
  }

  private static func activeFlutterControllers() -> [FlutterViewController] {
    var found = windowFlutterControllers()
    if let primary = primaryFlutterController,
       primary.engine.viewController === primary,
       !found.contains(where: { $0 === primary }) {
      found.append(primary)
    }
    return found
  }

  private static func controllerMatching(messenger: FlutterBinaryMessenger) -> FlutterViewController? {
    let target = messenger as AnyObject
    let mounted = windowFlutterControllers()
    if let attachedMounted = mounted.first(where: {
      ($0.binaryMessenger as AnyObject) === target && $0.engine.viewController === $0
    }) {
      return attachedMounted
    }
    if let engineOwner = mounted.first(where: { ($0.binaryMessenger as AnyObject) === target })?.engine.viewController,
       mounted.contains(where: { $0 === engineOwner }) {
      return engineOwner
    }
    if let primary = primaryFlutterController,
       (primary.binaryMessenger as AnyObject) === target,
       primary.engine.viewController === primary {
      return primary
    }
    return nil
  }

  private static func activeFlutterController() -> FlutterViewController? {
    let mounted = windowFlutterControllers()
    if let primary = primaryFlutterController,
       mounted.contains(where: { $0 === primary }),
       primary.engine.viewController === primary {
      return primary
    }
    if let attachedMarco = mounted.first(where: {
      $0 is MarcoFlutterViewController && $0.engine.viewController === $0
    }) {
      return attachedMarco
    }
    if let attached = mounted.first(where: { $0.engine.viewController === $0 }) {
      return attached
    }
    if let marco = mounted.first(where: { $0 is MarcoFlutterViewController }) {
      return marco
    }
    if let firstMounted = mounted.first {
      return firstMounted
    }
    if let primary = primaryFlutterController,
       primary.engine.viewController === primary {
      return primary
    }
    return nil
  }

  private static func preferredFlutterController(for messenger: FlutterBinaryMessenger) -> FlutterViewController? {
    return controllerMatching(messenger: messenger)
  }

  static func register(
    messenger: FlutterBinaryMessenger,
    pluginRegistry: FlutterPluginRegistry,
    controller: FlutterViewController? = nil
  ) {
    if let vc = controller {
      primaryFlutterController = vc
    } else if let matched = controllerMatching(messenger: messenger) {
      primaryFlutterController = matched
    }
    installLaunchLifecycleObserversIfNeeded()
    reconcileLaunchWindowAndSurface(reason: "channel_register")
    DispatchQueue.main.async {
      reconcileLaunchWindowAndSurface(reason: "channel_register_next_runloop")
    }
    NSLog("[MarcoLaunch] stage=native_channels_registered hasVC=%@", primaryFlutterController != nil ? "true" : "false")
    let wakelockChannel = FlutterMethodChannel(name: "marco_movie/wakelock", binaryMessenger: messenger)
    wakelockChannel.setMethodCallHandler { call, result in
      if call.method == "setEnabled", let enabled = call.arguments as? Bool {
        DispatchQueue.main.async {
          UIApplication.shared.isIdleTimerDisabled = enabled
          result(nil)
        }
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    let systemChromeChannel = FlutterMethodChannel(name: "marco_movie/system_chrome", binaryMessenger: messenger)
    systemChromeChannel.setMethodCallHandler { call, result in
      if call.method == "setImmersive" {
        var parsedImmersive: Bool?
        var forceRefresh = true
        if let immersive = call.arguments as? Bool {
          parsedImmersive = immersive
        } else if let args = call.arguments as? [String: Any], let immersive = args["immersive"] as? Bool {
          parsedImmersive = immersive
          forceRefresh = (args["force"] as? Bool) ?? true
        }
        guard let immersive = parsedImmersive else {
          result(FlutterMethodNotImplemented)
          return
        }
        DispatchQueue.main.async {
          let controllers = activeFlutterControllers()
          for controller in controllers {
            if let marcoVC = controller as? MarcoFlutterViewController {
              marcoVC.applyImmersiveMode(immersive, force: forceRefresh)
            } else {
              controller.setNeedsStatusBarAppearanceUpdate()
              if #available(iOS 11.0, *) {
                controller.setNeedsUpdateOfHomeIndicatorAutoHidden()
                controller.setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
              }
            }
          }
          result(nil)
        }
      } else if call.method == "requestOrientation", let mode = call.arguments as? String {
        DispatchQueue.main.async {
          for controller in activeFlutterControllers() {
            if let marcoVC = controller as? MarcoFlutterViewController {
              marcoVC.applyRequestedOrientation(mode)
            }
          }
          result(nil)
        }
      } else if call.method == "setOrientationMonitoring", let enabled = call.arguments as? Bool {
        DispatchQueue.main.async {
          let key = ObjectIdentifier(messenger as AnyObject)
          pruneOrientationBindings()
          if !enabled {
            if let binding = orientationBindings[key] {
              binding.desired = false
              binding.activeHost?.setPhysicalOrientationMonitoring(false, channel: systemChromeChannel)
              binding.activeHost = nil
            }
            if let marcoVC = preferredFlutterController(for: messenger) as? MarcoFlutterViewController {
              marcoVC.setPhysicalOrientationMonitoring(false, channel: systemChromeChannel)
            }
            result(nil)
            return
          }
          if let marcoVC = preferredFlutterController(for: messenger) as? MarcoFlutterViewController {
            let binding = orientationBindings[key] ?? OrientationMonitoringBinding(
              messenger: messenger as AnyObject,
              channel: systemChromeChannel
            )
            binding.channel = systemChromeChannel
            binding.desired = true
            if let prev = binding.activeHost, prev !== marcoVC {
              prev.setPhysicalOrientationMonitoring(false, channel: systemChromeChannel)
            }
            marcoVC.setPhysicalOrientationMonitoring(true, channel: systemChromeChannel)
            binding.activeHost = marcoVC
            orientationBindings[key] = binding
            result(nil)
          } else {
            if let binding = orientationBindings[key],
               let prev = binding.activeHost,
               prev.engine.viewController !== prev {
              prev.setPhysicalOrientationMonitoring(false, channel: systemChromeChannel)
              binding.activeHost = nil
            }
            result(
              FlutterError(
                code: "host_unavailable",
                message: "No attached FlutterViewController is available for this messenger",
                details: nil
              )
            )
          }
        }
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    let authChannel = FlutterMethodChannel(name: "marco_movie/netdisk_auth", binaryMessenger: messenger)
    authChannel.setMethodCallHandler { call, result in
      if call.method == "startWebAuth", let args = call.arguments as? [String: Any] {
        let drive = (args["drive"] as? String) ?? ""
        let urlStr = (args["url"] as? String) ?? ""
        let qrUrl = (args["qrUrl"] as? String) ?? ""
        DispatchQueue.main.async {
          guard let host = preferredFlutterController(for: messenger) else {
            result(nil)
            return
          }
          NetdiskWebAuthController.present(
            from: host,
            drive: drive,
            urlString: urlStr,
            qrUrlString: qrUrl,
            completion: result
          )
        }
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    MarcoWebSnifferAndJsHostRegistrar.register(messenger: messenger)

    if let avRegistrar = pluginRegistry.registrar(forPlugin: "MarcoAvPlayerPlugin") {
      MarcoAvPlayerEngine.register(with: avRegistrar, messenger: avRegistrar.messenger())
    }

    if let glassRegistrar = pluginRegistry.registrar(forPlugin: "MarcoLiquidGlassPlugin") {
      MarcoLiquidGlassSupport.register(with: glassRegistrar, messenger: glassRegistrar.messenger())
    }
  }

  private final class OrientationMonitoringBinding {
    weak var messenger: AnyObject?
    weak var channel: FlutterMethodChannel?
    weak var activeHost: MarcoFlutterViewController?
    var desired: Bool = false

    init(messenger: AnyObject, channel: FlutterMethodChannel) {
      self.messenger = messenger
      self.channel = channel
    }
  }

  private static var orientationBindings: [ObjectIdentifier: OrientationMonitoringBinding] = [:]

  private static func pruneOrientationBindings() {
    orientationBindings = orientationBindings.filter { $0.value.messenger != nil }
  }

  static func reconcileOrientationMonitoring(for controller: MarcoFlutterViewController) {
    pruneOrientationBindings()
    let messenger = controller.binaryMessenger
    let key = ObjectIdentifier(messenger as AnyObject)
    guard let binding = orientationBindings[key],
          binding.desired,
          let channel = binding.channel else {
      return
    }
    guard let activeTarget = preferredFlutterController(for: messenger) as? MarcoFlutterViewController,
          activeTarget === controller else {
      return
    }
    if let prev = binding.activeHost, prev !== controller {
      prev.setPhysicalOrientationMonitoring(false, channel: channel)
    }
    controller.setPhysicalOrientationMonitoring(true, channel: channel)
    binding.activeHost = controller
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
    guard var presenter = root else {
      completion(nil)
      return
    }
    while let presented = presenter.presentedViewController, !presented.isBeingDismissed {
      presenter = presented
    }
    let vc = NetdiskWebAuthController(drive: drive, urlString: urlString, qrUrlString: qrUrlString, completion: completion)
    let nav = UINavigationController(rootViewController: vc)
    nav.modalPresentationStyle = .pageSheet
    nav.presentationController?.delegate = vc
    nav.overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle
    presenter.present(nav, animated: true, completion: nil)
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle
    view.backgroundColor = MarcoLiquidGlassSupport.isEffectiveDark
      ? UIColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1.0)
      : UIColor.systemGroupedBackground
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

MACOS_WINDOW_CHANNEL_SNIPPET = r'''
    let macosWindowChannel = FlutterMethodChannel(name: "marco_movie/macos_window", binaryMessenger: flutterViewController.engine.binaryMessenger)
    macosWindowChannel.setMethodCallHandler { [weak self] call, result in
      DispatchQueue.main.async {
        guard let self = self else {
          result(nil)
          return
        }
        self.marcoHandleWindowMethodCall(call, result: result)
      }
    }'''

MACOS_WINDOW_EXTENSION_SWIFT = r'''
extension MainFlutterWindow {
  private static let marcoWindowFrameDefaultsKey = "marco_macos_window_frame_v1"
  private static let marcoMinWindowSize = NSSize(width: 720, height: 520)
  private static let marcoDefaultWindowSize = NSSize(width: 1280, height: 760)
  private static let marcoMinVisibleWidth: CGFloat = 180
  private static let marcoMinVisibleHeight: CGFloat = 80

  private static func marcoIsValidFrame(_ frame: NSRect) -> Bool {
    return frame.origin.x.isFinite
      && frame.origin.y.isFinite
      && frame.size.width.isFinite
      && frame.size.height.isFinite
      && frame.size.width >= marcoMinWindowSize.width
      && frame.size.height >= marcoMinWindowSize.height
      && frame.size.width <= 16384
      && frame.size.height <= 16384
      && frame.origin.x > -16000
      && frame.origin.y > -16000
      && frame.origin.x < 32768
      && frame.origin.y < 32768
  }

  private static func marcoCenteredFrame(in visibleFrame: NSRect, preferredSize: NSSize) -> NSRect {
    let safeW = visibleFrame.width > 0 ? visibleFrame.width : marcoDefaultWindowSize.width
    let safeH = visibleFrame.height > 0 ? visibleFrame.height : marcoDefaultWindowSize.height
    let minW = min(marcoMinWindowSize.width, safeW)
    let minH = min(marcoMinWindowSize.height, safeH)
    let targetW: CGFloat
    if preferredSize.width <= safeW {
      targetW = max(minW, preferredSize.width)
    } else {
      targetW = min(safeW, max(minW, safeW - 24))
    }
    let targetH: CGFloat
    if preferredSize.height <= safeH {
      targetH = max(minH, preferredSize.height)
    } else {
      targetH = min(safeH, max(minH, safeH - 24))
    }
    let x = visibleFrame.minX + (safeW - targetW) / 2.0
    let y = visibleFrame.minY + (safeH - targetH) / 2.0
    return NSRect(x: x.rounded(), y: y.rounded(), width: targetW.rounded(), height: targetH.rounded())
  }

  private static func marcoResolveFrame(
    saved: NSRect?,
    visibleFrames: [NSRect],
    primaryVisibleFrame: NSRect
  ) -> NSRect {
    let validFrames = visibleFrames.filter { $0.width > 0 && $0.height > 0 }
    let primary = (primaryVisibleFrame.width > 0 && primaryVisibleFrame.height > 0)
      ? primaryVisibleFrame
      : (validFrames.first ?? NSRect(x: 0, y: 0, width: 1440, height: 875))

    guard let candidate = saved, marcoIsValidFrame(candidate) else {
      return marcoCenteredFrame(in: primary, preferredSize: marcoDefaultWindowSize)
    }
    if validFrames.isEmpty {
      return candidate
    }

    var bestFrame: NSRect?
    var bestArea: CGFloat = -1
    var bestInter = NSRect.zero
    for frame in validFrames {
      let inter = candidate.intersection(frame)
      if inter.isNull || inter.width <= 0 || inter.height <= 0 { continue }
      let area = inter.width * inter.height
      if area > bestArea {
        bestArea = area
        bestFrame = frame
        bestInter = inter
      }
    }

    guard let target = bestFrame, bestInter.width >= 120, bestInter.height >= marcoMinVisibleHeight else {
      return marcoCenteredFrame(in: primary, preferredSize: candidate.size)
    }

    let minW = min(marcoMinWindowSize.width, target.width)
    let minH = min(marcoMinWindowSize.height, target.height)
    let clampedW = min(target.width, max(minW, candidate.width))
    let clampedH = min(target.height, max(minH, candidate.height))

    let minX = target.minX
    let maxX = max(target.minX, target.maxX - min(marcoMinVisibleWidth, clampedW))
    let clampedX = min(maxX, max(minX, candidate.minX))

    let minTopY = min(target.maxY, target.minY + min(marcoMinVisibleHeight, clampedH))
    let clampedTopY = min(target.maxY, max(minTopY, candidate.minY + clampedH))
    let clampedY = clampedTopY - clampedH

    return NSRect(
      x: clampedX.rounded(),
      y: clampedY.rounded(),
      width: clampedW.rounded(),
      height: clampedH.rounded()
    )
  }

  private static func marcoEncodeFrame(_ frame: NSRect) -> [String: Double] {
    return [
      "x": Double(frame.origin.x),
      "y": Double(frame.origin.y),
      "width": Double(frame.size.width),
      "height": Double(frame.size.height),
    ]
  }

  private static func marcoDecodeFrame(_ dict: [String: Any]?) -> NSRect? {
    guard let dict = dict,
          let x = (dict["x"] as? NSNumber)?.doubleValue,
          let y = (dict["y"] as? NSNumber)?.doubleValue,
          let w = (dict["width"] as? NSNumber)?.doubleValue,
          let h = (dict["height"] as? NSNumber)?.doubleValue else {
      return nil
    }
    let rect = NSRect(x: x, y: y, width: w, height: h)
    return marcoIsValidFrame(rect) ? rect : nil
  }

  private static func marcoLoadSavedFrame() -> NSRect? {
    let raw = UserDefaults.standard.dictionary(forKey: marcoWindowFrameDefaultsKey)
    return marcoDecodeFrame(raw)
  }

  func marcoRestoreInitialFrame() {
    let screens = NSScreen.screens
    let visibleFrames = screens.map { $0.visibleFrame }
    let primary = NSScreen.main?.visibleFrame
      ?? screens.first?.visibleFrame
      ?? NSRect(x: 0, y: 0, width: 1440, height: 875)
    let saved = Self.marcoLoadSavedFrame()
    let resolved = Self.marcoResolveFrame(
      saved: saved,
      visibleFrames: visibleFrames,
      primaryVisibleFrame: primary
    )
    self.marcoRestoredFromSaved = (saved != nil)
    self.marcoLastNormalFrame = (saved != nil) ? resolved : nil
    self.setFrame(resolved, display: true)
  }

  func marcoEnsureWindowChromeVisible() {
    self.titleVisibility = .hidden
    self.titlebarAppearsTransparent = true
    self.styleMask.insert(.fullSizeContentView)
    if !self.styleMask.contains(.fullScreen) {
      self.standardWindowButton(.closeButton)?.isHidden = false
      self.standardWindowButton(.miniaturizeButton)?.isHidden = false
      self.standardWindowButton(.zoomButton)?.isHidden = false
    }
  }

  func marcoClampVisibleIfNeeded() {
    guard !self.marcoInFullscreenTransition,
          !self.marcoIsMiniaturizing,
          !self.marcoIsClosing,
          !self.styleMask.contains(.fullScreen),
          !self.isMiniaturized else {
      return
    }
    let screens = NSScreen.screens
    guard !screens.isEmpty else { return }
    let visibleFrames = screens.map { $0.visibleFrame }
    let primary = NSScreen.main?.visibleFrame ?? screens[0].visibleFrame
    let current = self.frame
    let clamped = Self.marcoResolveFrame(
      saved: current,
      visibleFrames: visibleFrames,
      primaryVisibleFrame: primary
    )
    if abs(clamped.origin.x - current.origin.x) > 1
        || abs(clamped.origin.y - current.origin.y) > 1
        || abs(clamped.size.width - current.size.width) > 1
        || abs(clamped.size.height - current.size.height) > 1 {
      self.setFrame(clamped, display: true)
      self.marcoLastNormalFrame = clamped
    }
  }

  func marcoPersistNormalFrame(forceSynchronize: Bool = false) {
    guard !self.marcoInFullscreenTransition,
          !self.marcoIsMiniaturizing,
          !self.marcoIsClosing,
          !self.styleMask.contains(.fullScreen),
          !self.isMiniaturized,
          self.isVisible else {
      return
    }
    let current = self.frame
    guard Self.marcoIsValidFrame(current) else { return }
    self.marcoLastNormalFrame = current
    UserDefaults.standard.set(Self.marcoEncodeFrame(current), forKey: Self.marcoWindowFrameDefaultsKey)
    if forceSynchronize {
      UserDefaults.standard.synchronize()
    }
  }

  func marcoInstallWindowObservers() {
    guard self.marcoWindowObservers.isEmpty else { return }
    let nc = NotificationCenter.default
    let add: (Notification.Name, Any?, @escaping (MainFlutterWindow) -> Void) -> Void = { [weak self] name, obj, block in
      guard let self = self else { return }
      let token = nc.addObserver(forName: name, object: obj, queue: .main) { [weak self] _ in
        guard let strongSelf = self else { return }
        block(strongSelf)
      }
      self.marcoWindowObservers.append(token)
    }

    add(NSWindow.didMoveNotification, self) { win in
      win.marcoPersistNormalFrame()
    }
    add(NSWindow.didResizeNotification, self) { win in
      win.marcoPersistNormalFrame()
    }
    add(NSWindow.didEndLiveResizeNotification, self) { win in
      win.marcoPersistNormalFrame(forceSynchronize: true)
    }
    add(NSWindow.willEnterFullScreenNotification, self) { win in
      win.marcoPersistNormalFrame(forceSynchronize: true)
      win.marcoInFullscreenTransition = true
    }
    add(NSWindow.didEnterFullScreenNotification, self) { win in
      win.marcoInFullscreenTransition = false
    }
    add(NSWindow.willExitFullScreenNotification, self) { win in
      win.marcoInFullscreenTransition = true
    }
    add(NSWindow.didExitFullScreenNotification, self) { win in
      win.marcoInFullscreenTransition = false
      win.marcoEnsureWindowChromeVisible()
      win.marcoClampVisibleIfNeeded()
      win.marcoPersistNormalFrame(forceSynchronize: true)
    }
    add(NSWindow.willMiniaturizeNotification, self) { win in
      win.marcoPersistNormalFrame(forceSynchronize: true)
      win.marcoIsMiniaturizing = true
    }
    add(NSWindow.didDeminiaturizeNotification, self) { win in
      win.marcoIsMiniaturizing = false
      win.marcoEnsureWindowChromeVisible()
      win.marcoClampVisibleIfNeeded()
    }
    add(NSWindow.willCloseNotification, self) { win in
      win.marcoPersistNormalFrame(forceSynchronize: true)
      win.marcoIsClosing = true
    }
    add(NSApplication.willTerminateNotification, nil) { win in
      win.marcoPersistNormalFrame(forceSynchronize: true)
    }
    add(NSApplication.didChangeScreenParametersNotification, nil) { win in
      win.marcoClampVisibleIfNeeded()
      win.marcoEnsureWindowChromeVisible()
    }
  }

  func marcoHandleWindowMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getWindowBoundsState":
      var payload: [String: Any] = [
        "restoredFromSaved": self.marcoRestoredFromSaved,
        "isFullScreen": self.styleMask.contains(.fullScreen) || self.marcoInFullscreenTransition,
        "isMiniaturized": self.isMiniaturized || self.marcoIsMiniaturizing,
        "minWidth": Double(self.minSize.width),
        "minHeight": Double(self.minSize.height),
        "currentFrame": Self.marcoEncodeFrame(self.frame),
      ]
      if let saved = Self.marcoLoadSavedFrame() ?? (self.marcoRestoredFromSaved ? self.marcoLastNormalFrame : nil) {
        payload["savedFrame"] = Self.marcoEncodeFrame(saved)
      }
      result(payload)
    case "saveNormalBounds":
      self.marcoPersistNormalFrame(forceSynchronize: true)
      result(true)
    case "applyNormalBounds":
      guard !self.styleMask.contains(.fullScreen),
            !self.isMiniaturized,
            let dict = call.arguments as? [String: Any],
            let requested = Self.marcoDecodeFrame(dict) else {
        result(false)
        return
      }
      let screens = NSScreen.screens
      let visibleFrames = screens.map { $0.visibleFrame }
      let primary = NSScreen.main?.visibleFrame
        ?? screens.first?.visibleFrame
        ?? NSRect(x: 0, y: 0, width: 1440, height: 875)
      let resolved = Self.marcoResolveFrame(
        saved: requested,
        visibleFrames: visibleFrames,
        primaryVisibleFrame: primary
      )
      self.setFrame(resolved, display: true)
      self.marcoEnsureWindowChromeVisible()
      self.marcoLastNormalFrame = resolved
      UserDefaults.standard.set(Self.marcoEncodeFrame(resolved), forKey: Self.marcoWindowFrameDefaultsKey)
      result(true)
    case "setAppearance":
      let mode = (call.arguments as? String)?.lowercased() ?? "system"
      switch mode {
      case "light":
        self.appearance = NSAppearance(named: .aqua)
      case "dark":
        self.appearance = NSAppearance(named: .darkAqua)
      default:
        self.appearance = nil
      }
      self.marcoEnsureWindowChromeVisible()
      result(nil)
    case "revealInFinder":
      guard let args = call.arguments as? [String: Any],
            let path = args["path"] as? String,
            !path.isEmpty,
            FileManager.default.fileExists(atPath: path) else {
        result(false)
        return
      }
      NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
      result(true)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
'''

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

def _resolve_iconset_match(source_dir: Path, filename: str, w: int, h: int, contents_map: dict[str, str]) -> Path | None:
    if filename in contents_map:
        candidate = source_dir / contents_map[filename]
        if candidate.exists() and _png_dimensions(candidate) == (w, h):
            return candidate
    for name in (f"icon_{w}x{h}.png", f"icon_{w // 2}x{h // 2}@2x.png" if w % 2 == 0 and h % 2 == 0 else ""):
        if name:
            candidate = source_dir / name
            if candidate.exists() and _png_dimensions(candidate) == (w, h):
                return candidate
    return None

def _replace_xcassets_icons(appiconset_dir: Path, source: Path) -> None:
    if not appiconset_dir.exists() or not source.exists():
        return
    contents_map: dict[str, str] = {}
    contents_json = appiconset_dir / "Contents.json"
    if source.is_dir() and contents_json.exists():
        try:
            meta = json.loads(contents_json.read_text(encoding="utf-8"))
            for item in meta.get("images", []):
                fname = item.get("filename")
                size = item.get("size")
                scale = item.get("scale")
                if fname and size:
                    contents_map[fname] = f"icon_{size}@{scale}.png" if scale == "2x" else f"icon_{size}.png"
        except Exception:
            contents_map = {}
    fallback = (source / "icon_512x512@2x.png") if source.is_dir() else source
    sips = shutil.which("sips")
    for png_file in appiconset_dir.glob("*.png"):
        w, h = _png_dimensions(png_file)
        if source.is_dir():
            matched = _resolve_iconset_match(source, png_file.name, w, h, contents_map)
            if matched is not None:
                shutil.copy2(matched, png_file)
                continue
        if not fallback.exists():
            continue
        shutil.copy2(fallback, png_file)
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


def _install_ios_branded_launch_screen(ios_runner: Path, source_png: Path) -> None:
    """Populate LaunchImage.imageset with the transparent RGBA Marco Movie
    film-ribbon mark (`LOGO_MARK`, NEVER the opaque square `IOS_ICON`!) at
    76/152/228 px (76x76 pt) so iPhone & iPad cold launch renders the pure
    floating `M` mark with zero dark-gray square box."""
    launch_set = ios_runner / "Assets.xcassets" / "LaunchImage.imageset"
    if launch_set.exists() and source_png.exists():
        pil_image_mod = None
        try:
            from PIL import Image as _PilImage
            pil_image_mod = _PilImage
        except Exception:
            pil_image_mod = None
        sips = shutil.which("sips")
        for fname, px in (
            ("LaunchImage.png", 76),
            ("LaunchImage@2x.png", 152),
            ("LaunchImage@3x.png", 228),
        ):
            dest = launch_set / fname
            if pil_image_mod is not None:
                with pil_image_mod.open(source_png) as img:
                    rgba = img.convert("RGBA")
                    resample = getattr(
                        getattr(pil_image_mod, "Resampling", pil_image_mod),
                        "LANCZOS",
                    )
                    resized = rgba.resize((px, px), resample)
                    resized.save(dest, format="PNG")
            else:
                shutil.copy2(source_png, dest)
                if sips:
                    subprocess.run(
                        [sips, "-s", "format", "png", "-z", str(px), str(px), str(dest)],
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                        check=False,
                    )
        contents_json = launch_set / "Contents.json"
        contents_json.write_text(
            json.dumps(
                {
                    "images": [
                        {"idiom": "universal", "filename": "LaunchImage.png", "scale": "1x"},
                        {"idiom": "universal", "filename": "LaunchImage@2x.png", "scale": "2x"},
                        {"idiom": "universal", "filename": "LaunchImage@3x.png", "scale": "3x"},
                    ],
                    "info": {"version": 1, "author": "xcode"},
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )
    ios_launch_storyboard = ios_runner / "Base.lproj" / "LaunchScreen.storyboard"
    if ios_launch_storyboard.exists():
        lsb_text = ios_launch_storyboard.read_text(encoding="utf-8")
        patched_lsb = _patch_ios_storyboard_adaptive_bg(lsb_text)
        # Ensure centered LaunchImage renders cleanly at fixed 76x76 pt with
        # scaleAspectFit matching Flutter's `IosLaunchStageView` (`kIosLaunchMarkSize`).
        if 'image="LaunchImage"' in patched_lsb and 'contentMode="center"' in patched_lsb:
            patched_lsb = patched_lsb.replace(
                'contentMode="center"',
                'contentMode="scaleAspectFit"',
            )
        patched_lsb = re.sub(
            r'<image\s+name="LaunchImage"\s+width="[^"]+"\s+height="[^"]+"\s*/>',
            '<image name="LaunchImage" width="76" height="76"/>',
            patched_lsb,
        )
        if 'id="YRO-k0-Ey4"' in patched_lsb and 'id="marco-launch-w"' not in patched_lsb:
            patched_lsb = re.sub(
                r'(<imageView\b[^>]*\bid="YRO-k0-Ey4"[^>]*>)\s*(</imageView>)',
                r'\1\n'
                r'                                <constraints>\n'
                r'                                    <constraint firstAttribute="width" constant="76" id="marco-launch-w"/>\n'
                r'                                    <constraint firstAttribute="height" constant="76" id="marco-launch-h"/>\n'
                r'                                </constraints>\n'
                r'                            \2',
                patched_lsb,
                count=1,
            )
        if patched_lsb != lsb_text:
            ios_launch_storyboard.write_text(patched_lsb, encoding="utf-8")


def _patch_ios_storyboard_adaptive_bg(sb_text: str) -> str:
    """Replace hardcoded white storyboard backgrounds with iOS 13+ adaptive systemBackgroundColor."""
    updated = sb_text
    for white_tag in (
        '<color key="backgroundColor" red="1" green="1" blue="1" alpha="1" colorSpace="custom" customColorSpace="sRGB"/>',
        '<color key="backgroundColor" white="1" alpha="1" colorSpace="custom" customColorSpace="calibratedWhite"/>',
        '<color key="backgroundColor" white="1" alpha="1" colorSpace="custom" customColorSpace="genericGamma22GrayColorSpace"/>',
    ):
        if white_tag in updated:
            updated = updated.replace(
                white_tag,
                '<color key="backgroundColor" systemColor="systemBackgroundColor"/>',
            )
    if 'systemColor="systemBackgroundColor"' in updated and '<systemColor name="systemBackgroundColor">' not in updated:
        sys_color_block = (
            '        <systemColor name="systemBackgroundColor">\n'
            '            <color white="1" alpha="1" colorSpace="custom" customColorSpace="genericGamma22GrayColorSpace"/>\n'
            '        </systemColor>\n'
        )
        if "</resources>" in updated:
            updated = updated.replace("</resources>", sys_color_block + "    </resources>", 1)
        elif "</document>" in updated:
            updated = updated.replace(
                "</document>",
                "    <resources>\n" + sys_color_block + "    </resources>\n</document>",
                1,
            )
    return updated


IOS_FLUTTER_VIEW_CONTROLLER_SWIFT = r'''@objc(MarcoFlutterViewController)
final class MarcoFlutterViewController: FlutterViewController {
  var marcoImmersiveMode: Bool = false {
    didSet {
      guard oldValue != marcoImmersiveMode else { return }
      refreshSystemChromeAppearance()
    }
  }

  func applyImmersiveMode(_ immersive: Bool, force: Bool = false) {
    let changed = (marcoImmersiveMode != immersive)
    marcoImmersiveMode = immersive
    if force || !changed {
      refreshSystemChromeAppearance()
    }
  }

  private func refreshSystemChromeAppearance() {
    setNeedsStatusBarAppearanceUpdate()
    parent?.setNeedsStatusBarAppearanceUpdate()
    if #available(iOS 11.0, *) {
      setNeedsUpdateOfHomeIndicatorAutoHidden()
      setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
    }
  }

  var marcoPreferredInterfaceStyle: UIUserInterfaceStyle = .unspecified {
    didSet {
      setNeedsStatusBarAppearanceUpdate()
    }
  }

  private var orientationObserver: NSObjectProtocol?
  private var lifecycleObservers: [NSObjectProtocol] = []
  private weak var orientationChannel: FlutterMethodChannel?
  private var marcoOrientationMask: UIInterfaceOrientationMask?
  private var lastReportedGeometrySize: CGSize = .zero

  deinit {
    if let obs = orientationObserver {
      NotificationCenter.default.removeObserver(obs)
      UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }
    for obs in lifecycleObservers {
      NotificationCenter.default.removeObserver(obs)
    }
    lifecycleObservers.removeAll()
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    modalPresentationCapturesStatusBarAppearance = true
    if #available(iOS 13.0, *) {
      view.backgroundColor = .systemBackground
    }
    NSLog("[MarcoLaunch] stage=native_vc_view_did_load idiom=%ld bounds=%@", UIDevice.current.userInterfaceIdiom.rawValue, NSCoder.string(for: view.bounds))
    let center = NotificationCenter.default
    let becomeActiveObs = center.addObserver(
      forName: UIApplication.didBecomeActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.refreshSystemChromeAppearance()
    }
    lifecycleObservers.append(becomeActiveObs)
    if #available(iOS 13.0, *) {
      let sceneActiveObs = center.addObserver(
        forName: UIScene.didActivateNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        self?.refreshSystemChromeAppearance()
      }
      lifecycleObservers.append(sceneActiveObs)
    }
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    if #available(iOS 13.0, *) {
      view.window?.backgroundColor = .systemBackground
    }
    MarcoNativeChannelRegistrar.reconcileLaunchWindowAndSurface(reason: "vc_will_appear")
    refreshSystemChromeAppearance()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    NSLog("[MarcoLaunch] stage=native_vc_view_did_appear bounds=%@ safeArea=%@", NSCoder.string(for: view.bounds), NSCoder.string(for: view.safeAreaInsets))
    MarcoNativeChannelRegistrar.reconcileLaunchWindowAndSurface(reason: "vc_did_appear")
    refreshSystemChromeAppearance()
    MarcoNativeChannelRegistrar.reconcileOrientationMonitoring(for: self)
  }

  override func didMove(toParent parent: UIViewController?) {
    super.didMove(toParent: parent)
    if parent != nil {
      MarcoNativeChannelRegistrar.reconcileOrientationMonitoring(for: self)
    }
  }

  override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
    if UIDevice.current.userInterfaceIdiom == .pad {
      return super.supportedInterfaceOrientations
    }
    return marcoOrientationMask ?? super.supportedInterfaceOrientations
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    MarcoLiquidGlassSupport.bringRootChromeToFront()
    let sz = view.bounds.size
    if sz.width > 0, sz.height > 0, sz != lastReportedGeometrySize {
      lastReportedGeometrySize = sz
      MarcoLiquidGlassSupport.notifyWindowGeometryChanged(size: sz)
    }
  }

  override func viewWillTransition(
    to size: CGSize,
    with coordinator: UIViewControllerTransitionCoordinator
  ) {
    super.viewWillTransition(to: size, with: coordinator)
    lastReportedGeometrySize = size
    MarcoLiquidGlassSupport.notifyWindowGeometryChanged(size: size)
    coordinator.animate(alongsideTransition: { [weak self] _ in
      self?.refreshSystemChromeAppearance()
    }, completion: { [weak self] _ in
      self?.refreshSystemChromeAppearance()
    })
  }

  override func viewSafeAreaInsetsDidChange() {
    super.viewSafeAreaInsetsDidChange()
    if view.bounds.size.width > 0, view.bounds.size.height > 0 {
      lastReportedGeometrySize = view.bounds.size
      MarcoLiquidGlassSupport.notifyWindowGeometryChanged(size: view.bounds.size)
    }
    refreshSystemChromeAppearance()
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    refreshSystemChromeAppearance()
  }

  func setPhysicalOrientationMonitoring(_ enabled: Bool, channel: FlutterMethodChannel) {
    if enabled {
      orientationChannel = channel
      if orientationObserver != nil {
        return
      }
      UIDevice.current.beginGeneratingDeviceOrientationNotifications()
      orientationObserver = NotificationCenter.default.addObserver(
        forName: UIDevice.orientationDidChangeNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        guard let self = self else { return }
        let label: String?
        switch UIDevice.current.orientation {
        case .portrait:
          label = "portrait"
        case .landscapeLeft:
          label = "landscapeLeft"
        case .landscapeRight:
          label = "landscapeRight"
        default:
          label = nil
        }
        if let label = label {
          self.orientationChannel?.invokeMethod("physicalOrientationChanged", arguments: label)
        }
      }
      return
    }
    orientationChannel = nil
    if let obs = orientationObserver {
      NotificationCenter.default.removeObserver(obs)
      orientationObserver = nil
      UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }
  }

  func applyRequestedOrientation(_ mode: String) {
    // iPadOS multitasking (UIRequiresFullScreen = false) manages window geometry
    // through the system; forcing an orientation mask on iPad can stall UIKit.
    if UIDevice.current.userInterfaceIdiom == .pad {
      marcoOrientationMask = nil
      refreshSystemChromeAppearance()
      return
    }
    let mask: UIInterfaceOrientationMask
    let fallbackRaw: Int?
    switch mode {
    case "landscape":
      mask = .landscape
      marcoOrientationMask = .landscape
      fallbackRaw = UIInterfaceOrientation.landscapeRight.rawValue
    case "portrait":
      mask = .portrait
      marcoOrientationMask = .portrait
      fallbackRaw = UIInterfaceOrientation.portrait.rawValue
    default:
      mask = .allButUpsideDown
      marcoOrientationMask = nil
      fallbackRaw = nil
    }
    if #available(iOS 16.0, *) {
      setNeedsUpdateOfSupportedInterfaceOrientations()
      if let scene = view.window?.windowScene {
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
      }
    } else if let raw = fallbackRaw {
      UIDevice.current.setValue(raw, forKey: "orientation")
      UIViewController.attemptRotationToDeviceOrientation()
    }
  }

  override var preferredStatusBarStyle: UIStatusBarStyle {
    if marcoImmersiveMode {
      return .lightContent
    }
    switch marcoPreferredInterfaceStyle {
    case .light:
      return .darkContent
    case .dark:
      return .lightContent
    default:
      return traitCollection.userInterfaceStyle == .light ? .darkContent : .lightContent
    }
  }

  override var prefersStatusBarHidden: Bool {
    return marcoImmersiveMode || super.prefersStatusBarHidden
  }

  override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation {
    return .fade
  }

  override var prefersHomeIndicatorAutoHidden: Bool {
    return marcoImmersiveMode
  }

  override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge {
    // Do NOT include .bottom here: per UIKit, deferring .bottom disables
    // prefersHomeIndicatorAutoHidden so the iPad Home indicator never fades out.
    return marcoImmersiveMode ? [.top] : []
  }
}
'''


def _find_swift_brace_block_end(
    text: str,
    open_brace_idx: int,
    open_ch: str = "{",
    close_ch: str = "}",
) -> int:
    """Return index immediately after the matching closing delimiter for
    `open_ch` at `open_brace_idx`, skipping Swift comments and string literals
    (including multiline / raw)."""
    n = len(text)
    if open_brace_idx < 0 or open_brace_idx >= n or text[open_brace_idx] != open_ch:
        return -1
    depth = 0
    i = open_brace_idx
    while i < n:
        ch = text[i]
        # Single-line comment
        if ch == "/" and i + 1 < n and text[i + 1] == "/":
            nl = text.find("\n", i + 2)
            i = n if nl == -1 else nl + 1
            continue
        # Block comment (Swift supports nesting)
        if ch == "/" and i + 1 < n and text[i + 1] == "*":
            c_depth = 1
            i += 2
            while i < n and c_depth > 0:
                if text[i] == "/" and i + 1 < n and text[i + 1] == "*":
                    c_depth += 1
                    i += 2
                elif text[i] == "*" and i + 1 < n and text[i + 1] == "/":
                    c_depth -= 1
                    i += 2
                else:
                    i += 1
            continue
        # Raw multiline string #""" ... """#
        if ch == "#" and text.startswith('#"""', i):
            end_str = text.find('"""#', i + 4)
            i = n if end_str == -1 else end_str + 4
            continue
        # Multiline string """ ... """
        if text.startswith('"""', i):
            i += 3
            while i < n:
                if text[i] == "\\":
                    i += 2
                    continue
                if text.startswith('"""', i):
                    i += 3
                    break
                i += 1
            continue
        # Standard single-line string "..."
        if ch == '"':
            i += 1
            while i < n:
                if text[i] == "\\":
                    i += 2
                    continue
                if text[i] == '"':
                    i += 1
                    break
                i += 1
            continue
        if ch == open_ch:
            depth += 1
        elif ch == close_ch:
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return -1


def _upsert_swift_generated_block(
    text: str,
    marker_name: str,
    legacy_header_pattern: str,
    new_body: str,
) -> tuple[str, bool]:
    """Insert or upgrade a generator-owned Swift block in place while keeping
    surrounding developer-authored Swift code intact."""
    begin_marker = f"// MARCO_GENERATED_BEGIN: {marker_name}"
    end_marker = f"// MARCO_GENERATED_END: {marker_name}"
    marked = f"{begin_marker}\n{new_body.strip()}\n{end_marker}"

    begin_idx = text.find(begin_marker)
    if begin_idx != -1:
        end_idx = text.find(end_marker, begin_idx + len(begin_marker))
        if end_idx != -1:
            end_idx += len(end_marker)
            updated = text[:begin_idx] + marked + text[end_idx:]
            return updated, updated != text

    m = re.search(legacy_header_pattern, text, re.MULTILINE)
    if m:
        open_brace = text.find("{", m.start())
        block_end = _find_swift_brace_block_end(text, open_brace)
        if block_end != -1:
            updated = text[:m.start()] + marked + text[block_end:]
            return updated, updated != text

    updated = text.rstrip() + "\n\n" + marked + "\n"
    return updated, updated != text


def _ensure_ios_appdelegate_imports(ad_text: str) -> tuple[str, bool]:
    """Ensure required Apple framework imports exist in deterministic order
    right after `import UIKit`, regardless of whether an older Runner already
    had a subset of them."""
    if "import UIKit" not in ad_text:
        return ad_text, False
    updated = ad_text
    required = (
        "import AVFoundation",
        "import AVKit",
        "import MediaPlayer",
        "import SafariServices",
        "import WebKit",
    )
    # Remove any standalone generator-managed framework imports so they are
    # re-emitted in canonical order right after `import UIKit`.
    for imp in required:
        updated = re.sub(rf"(?m)^{re.escape(imp)}[ \t]*\n", "", updated)
    block = "import UIKit\n" + "\n".join(required)
    updated = re.sub(r"(?m)^import UIKit[ \t]*$", block, updated, count=1)
    return updated, updated != ad_text


def _upsert_swift_generated_section(
    text: str,
    marker_name: str,
    legacy_start_pattern: str,
    next_section_patterns: tuple[str, ...],
    new_body: str,
    *,
    retired_declarations: tuple[str, ...] = (),
) -> tuple[str, bool]:
    """Insert or upgrade a multi-declaration generator-owned Swift section.

    1. If `// MARCO_GENERATED_BEGIN/END: <marker_name>` exists, replace in place.
    2. For unmarked 0.7.6 output, replace only the declarations this section
       owns. A neighbouring declaration in AppDelegate.swift may be app code.
    3. Otherwise append as a marked block at the end of the file.
    """
    begin_marker = f"// MARCO_GENERATED_BEGIN: {marker_name}"
    end_marker = f"// MARCO_GENERATED_END: {marker_name}"
    marked = f"{begin_marker}\n{new_body.strip()}\n{end_marker}"

    begin_idx = text.find(begin_marker)
    if begin_idx != -1:
        end_idx = text.find(end_marker, begin_idx + len(begin_marker))
        if end_idx != -1:
            end_idx += len(end_marker)
            updated = text[:begin_idx] + marked + text[end_idx:]
            return updated, updated != text

    m = re.search(legacy_start_pattern, text, re.MULTILINE)
    if m:
        sec_end = len(text)
        for pattern in next_section_patterns:
            following_section = re.search(pattern, text[m.end():], re.MULTILINE)
            if following_section:
                sec_end = min(sec_end, m.end() + following_section.start())
        legacy = text[m.start():sec_end]
        declaration = re.compile(
            r"^(?:@(?:available|objc)\([^\n]*\)\n)*"
            r"(?:(?:private|fileprivate|public|internal|final) +)*"
            r"(?:class|enum|struct|protocol) +(?P<name>\w+)\b", re.MULTILINE,
        )
        owned = {match["name"] for match in declaration.finditer(new_body)}
        owned.update(retired_declarations)
        # Old sections bundled headers and MARK comments between declarations.
        # Remove generated comment-only gaps; preserve developer text verbatim.
        generated_comments = set(new_body.splitlines())
        preserved = []
        cursor = 0
        search_from = 0
        while match := declaration.search(legacy, search_from):
            close = _find_swift_brace_block_end(legacy, legacy.find("{", match.end()))
            if close == -1:
                raise ValueError(f"Cannot locate end of Swift declaration {match['name']}")
            if match["name"] in owned:
                gap = legacy[cursor:match.start()]
                if any(
                    line.strip() and not (line.startswith("//") and line in generated_comments)
                    for line in gap.splitlines()
                ):
                    preserved.append(gap)
                cursor = close
            search_from = close
        preserved.append(legacy[cursor:])
        prefix = text[:m.start()].rstrip()
        suffix = ("".join(preserved) + text[sec_end:]).lstrip("\n\r")
        if suffix:
            updated = prefix + "\n\n" + marked + "\n\n" + suffix
        else:
            updated = prefix + "\n\n" + marked + "\n"
        return updated, updated != text

    updated = text.rstrip() + "\n\n" + marked + "\n"
    return updated, updated != text


def _find_swift_clause_brace_open(text: str, start: int) -> int:
    """Finds the opening `{` of a Swift `else` / `else if ...` clause starting at
    `start`, skipping comments, string literals, and balanced `(...)`/`[...]`."""
    n = len(text)
    i = start
    paren = 0
    bracket = 0
    in_string = False
    in_line_comment = False
    block_comment_depth = 0
    while i < n:
        ch = text[i]
        nxt = text[i + 1] if i + 1 < n else ""
        if in_line_comment:
            if ch == "\n":
                in_line_comment = False
            i += 1
            continue
        if block_comment_depth > 0:
            if ch == "/" and nxt == "*":
                block_comment_depth += 1
                i += 2
            elif ch == "*" and nxt == "/":
                block_comment_depth -= 1
                i += 2
            else:
                i += 1
            continue
        if in_string:
            if ch == "\\":
                i += 2
                continue
            if ch == '"':
                in_string = False
            i += 1
            continue
        if ch == "/" and nxt == "/":
            in_line_comment = True
            i += 2
            continue
        if ch == "/" and nxt == "*":
            block_comment_depth = 1
            i += 2
            continue
        if ch == '"':
            in_string = True
            i += 1
            continue
        if ch == "(":
            paren += 1
        elif ch == ")" and paren > 0:
            paren -= 1
        elif ch == "[":
            bracket += 1
        elif ch == "]" and bracket > 0:
            bracket -= 1
        elif ch == "{" and paren == 0 and bracket == 0:
            return i
        i += 1
    return -1


def _skip_swift_ws_and_comments(text: str, pos: int) -> int:
    """Advances `pos` past Swift whitespace, `// ...` line comments, and
    nested `/* ... */` block comments."""
    n = len(text)
    i = pos
    while i < n:
        ch = text[i]
        if ch in " \t\r\n":
            i += 1
            continue
        nxt = text[i + 1] if i + 1 < n else ""
        if ch == "/" and nxt == "/":
            nl = text.find("\n", i + 2)
            i = n if nl == -1 else nl + 1
            continue
        if ch == "/" and nxt == "*":
            depth = 1
            i += 2
            while i < n and depth > 0:
                if i + 1 < n and text[i] == "/" and text[i + 1] == "*":
                    depth += 1
                    i += 2
                elif i + 1 < n and text[i] == "*" and text[i + 1] == "/":
                    depth -= 1
                    i += 2
                else:
                    i += 1
            continue
        break
    return i


def _find_swift_if_chain_end(text: str, if_block_end: int) -> tuple[int, bool]:
    """Extends `if_block_end` (immediately after the closing `}` of an `if` block)
    across any trailing Swift `else if ... { ... }` and `else { ... }` clauses,
    skipping intervening whitespace and Swift comments. Returns
    `(chain_end, has_else_chain)`."""
    cursor = if_block_end
    has_else = False
    while True:
        next_tok = _skip_swift_ws_and_comments(text, cursor)
        if not re.match(r"else\b", text[next_tok:]):
            break
        clause_open = _find_swift_clause_brace_open(text, next_tok + 4)
        if clause_open == -1:
            break
        clause_end = _find_swift_brace_block_end(text, clause_open, "{", "}")
        if clause_end == -1:
            break
        cursor = clause_end
        has_else = True
    return cursor, has_else


def _upsert_ios_appdelegate_registration(ad_text: str) -> tuple[str, bool]:
    """Inject or migrate the generator-owned registration block inside
    AppDelegate.swift (supporting both implicit engineBridge and legacy
    didFinishLaunchingWithOptions templates) without losing custom code."""
    begin_marker = "// MARCO_GENERATED_BEGIN: ios_registration"
    end_marker = "// MARCO_GENERATED_END: ios_registration"

    def _join_after_marker(prefix_with_marker: str, trailing: str) -> str:
        """Guarantees a `// MARCO_GENERATED_END: ...` line comment never merges
        with subsequent Swift tokens on the same line."""
        if not trailing or trailing.startswith("\n") or trailing.startswith("\r"):
            return prefix_with_marker + trailing
        return prefix_with_marker + "\n" + trailing

    def make_engine_block(indent: str) -> str:
        return (
            f"{indent}{begin_marker}\n"
            f"{indent}NSLog(\"[MarcoLaunch] stage=native_engine_plugin_register_start\")\n"
            f"{indent}GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)\n"
            f"{indent}MarcoNativeChannelRegistrar.register(\n"
            f"{indent}  messenger: engineBridge.applicationRegistrar.messenger(),\n"
            f"{indent}  pluginRegistry: engineBridge.pluginRegistry\n"
            f"{indent})\n"
            f"{indent}NSLog(\"[MarcoLaunch] stage=native_engine_plugin_register_done\")\n"
            f"{indent}{end_marker}"
        )

    def make_self_block(indent: str) -> str:
        return (
            f"{indent}{begin_marker}\n"
            f"{indent}NSLog(\"[MarcoLaunch] stage=native_did_finish_launching rootVC=%@\", String(describing: type(of: window?.rootViewController)))\n"
            f"{indent}if #available(iOS 13.0, *) {{\n"
            f"{indent}  window?.backgroundColor = .systemBackground\n"
            f"{indent}}}\n"
            f"{indent}GeneratedPluginRegistrant.register(with: self)\n"
            f"{indent}let marcoRootFlutterVC = window?.rootViewController as? FlutterViewController\n"
            f"{indent}if let messenger = marcoRootFlutterVC?.binaryMessenger\n"
            f"{indent}  ?? self.registrar(forPlugin: \"MarcoChannelBridge\")?.messenger() {{\n"
            f"{indent}  MarcoNativeChannelRegistrar.register(\n"
            f"{indent}    messenger: messenger,\n"
            f"{indent}    pluginRegistry: self,\n"
            f"{indent}    controller: marcoRootFlutterVC\n"
            f"{indent}  )\n"
            f"{indent}}}\n"
            f"{indent}NSLog(\"[MarcoLaunch] stage=native_plugins_registered\")\n"
            f"{indent}{end_marker}"
        )

    def make_engine_preamble(indent: str) -> str:
        return (
            f"{indent}// MARCO_GENERATED_BEGIN: ios_engine_plugin_preamble\n"
            f"{indent}NSLog(\"[MarcoLaunch] stage=native_engine_plugin_register_start\")\n"
            f"{indent}GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)\n"
            f"{indent}// MARCO_GENERATED_END: ios_engine_plugin_preamble"
        )

    def make_engine_registrar(indent: str) -> str:
        return (
            f"{indent}// MARCO_GENERATED_BEGIN: ios_engine_registrar\n"
            f"{indent}MarcoNativeChannelRegistrar.register(\n"
            f"{indent}  messenger: engineBridge.applicationRegistrar.messenger(),\n"
            f"{indent}  pluginRegistry: engineBridge.pluginRegistry\n"
            f"{indent})\n"
            f"{indent}NSLog(\"[MarcoLaunch] stage=native_engine_plugin_register_done\")\n"
            f"{indent}// MARCO_GENERATED_END: ios_engine_registrar"
        )

    def make_self_preamble(indent: str, *, include_root_vc: bool = True) -> str:
        root_vc_line = (
            f"{indent}let marcoRootFlutterVC = window?.rootViewController as? FlutterViewController\n"
            if include_root_vc
            else ""
        )
        return (
            f"{indent}// MARCO_GENERATED_BEGIN: ios_self_plugin_preamble\n"
            f"{indent}NSLog(\"[MarcoLaunch] stage=native_did_finish_launching rootVC=%@\", String(describing: type(of: window?.rootViewController)))\n"
            f"{indent}if #available(iOS 13.0, *) {{\n"
            f"{indent}  window?.backgroundColor = .systemBackground\n"
            f"{indent}}}\n"
            f"{indent}GeneratedPluginRegistrant.register(with: self)\n"
            f"{root_vc_line}"
            f"{indent}// MARCO_GENERATED_END: ios_self_plugin_preamble"
        )

    def make_self_registrar(
        indent: str,
        *,
        controller_expr: str | None = "marcoRootFlutterVC",
    ) -> str:
        if controller_expr:
            return (
                f"{indent}// MARCO_GENERATED_BEGIN: ios_self_registrar\n"
                f"{indent}MarcoNativeChannelRegistrar.register(\n"
                f"{indent}  messenger: messenger,\n"
                f"{indent}  pluginRegistry: self,\n"
                f"{indent}  controller: {controller_expr}\n"
                f"{indent})\n"
                f"{indent}// MARCO_GENERATED_END: ios_self_registrar"
            )
        return (
            f"{indent}// MARCO_GENERATED_BEGIN: ios_self_registrar\n"
            f"{indent}MarcoNativeChannelRegistrar.register(\n"
            f"{indent}  messenger: messenger,\n"
            f"{indent}  pluginRegistry: self\n"
            f"{indent})\n"
            f"{indent}// MARCO_GENERATED_END: ios_self_registrar"
        )

    def make_self_post_register(indent: str) -> str:
        return (
            f"{indent}// MARCO_GENERATED_BEGIN: ios_self_post_register\n"
            f"{indent}NSLog(\"[MarcoLaunch] stage=native_plugins_registered\")\n"
            f"{indent}// MARCO_GENERATED_END: ios_self_post_register"
        )

    def _strip_swift_comments(text: str) -> str:
        """Strips Swift `//` line comments and nested `/* ... */` block comments
        while preserving single-line and multi-line string literals and physical
        newlines (`\\n`) so line-oriented continuation analysis never truncates
        subsequent lines."""
        out: list[str] = []
        i = 0
        n = len(text)
        in_str = False
        in_multiline_str = False
        escaped = False
        block_depth = 0
        while i < n:
            ch = text[i]
            nxt = text[i + 1] if i + 1 < n else ""
            if block_depth > 0:
                if ch == "/" and nxt == "*":
                    block_depth += 1
                    i += 2
                    continue
                if ch == "*" and nxt == "/":
                    block_depth -= 1
                    if block_depth == 0:
                        out.append(" ")
                    i += 2
                    continue
                if ch == "\n":
                    out.append("\n")
                i += 1
                continue
            if in_multiline_str:
                out.append(ch)
                if escaped:
                    escaped = False
                elif ch == "\\":
                    escaped = True
                elif ch == '"' and text[i : i + 3] == '"""':
                    out.append('""')
                    in_multiline_str = False
                    i += 3
                    continue
                i += 1
                continue
            if in_str:
                out.append(ch)
                if escaped:
                    escaped = False
                elif ch == "\\":
                    escaped = True
                elif ch == '"':
                    in_str = False
                i += 1
                continue
            if ch == "/" and nxt == "/":
                i += 2
                while i < n and text[i] != "\n":
                    i += 1
                continue
            if ch == "/" and nxt == "*":
                block_depth = 1
                i += 2
                continue
            if ch == '"' and text[i : i + 3] == '"""':
                out.append('"""')
                in_multiline_str = True
                i += 3
                continue
            if ch == '"':
                out.append(ch)
                in_str = True
                i += 1
                continue
            out.append(ch)
            i += 1
        return "".join(out)

    def _strip_closed_inner_blocks(text: str) -> str:
        """Removes closed inner lexical scopes from `text` while preserving
        newlines and keeping enclosing unclosed blocks and `guard let` bindings
        intact.

        For a closed `{ ... }` preceded at the same expression depth by a
        block-scoped binding header (`if`, `while`, `for`, `catch`—never
        `guard ... else` or `#if`), wipes BOTH the header's temporary bindings
        and the block body so ended conditional bindings such as
        `if let receiver = ... as? FlutterViewController { ... }` cannot shadow
        an outer `let receiver: FlutterEngine?`."""
        chars = list(text)
        n = len(text)
        stack: list[tuple[int, int, int, int]] = []
        # Each frame: (open_brace_idx, wipe_start_idx, saved_paren_depth, saved_bracket_depth)
        pending_cond_start: int | None = None
        paren_depth = 0
        bracket_depth = 0
        in_str = False
        in_multiline_str = False
        escaped = False
        i = 0
        while i < n:
            ch = text[i]
            if in_multiline_str:
                if escaped:
                    escaped = False
                elif ch == "\\":
                    escaped = True
                elif ch == '"' and text[i : i + 3] == '"""':
                    in_multiline_str = False
                    i += 3
                    continue
                i += 1
                continue
            if in_str:
                if escaped:
                    escaped = False
                elif ch == "\\":
                    escaped = True
                elif ch == '"':
                    in_str = False
                i += 1
                continue
            if ch == '"' and text[i : i + 3] == '"""':
                in_multiline_str = True
                i += 3
                continue
            if ch == '"':
                in_str = True
                i += 1
                continue
            if ch == "(":
                paren_depth += 1
                i += 1
                continue
            if ch == ")":
                paren_depth = max(0, paren_depth - 1)
                i += 1
                continue
            if ch == "[":
                bracket_depth += 1
                i += 1
                continue
            if ch == "]":
                bracket_depth = max(0, bracket_depth - 1)
                i += 1
                continue
            if ch == ";" and paren_depth == 0 and bracket_depth == 0:
                pending_cond_start = None
                i += 1
                continue
            if ch == "{":
                if paren_depth == 0 and bracket_depth == 0 and pending_cond_start is not None:
                    stack.append((i, pending_cond_start, paren_depth, bracket_depth))
                    pending_cond_start = None
                else:
                    stack.append((i, i + 1, paren_depth, bracket_depth))
                i += 1
                continue
            if ch == "}":
                pending_cond_start = None
                if stack:
                    open_idx, wipe_start, saved_p, saved_b = stack.pop()
                    wipe_end = i + 1 if wipe_start < open_idx else i
                    for j in range(wipe_start, wipe_end):
                        if chars[j] != "\n":
                            chars[j] = " "
                    paren_depth = saved_p
                    bracket_depth = saved_b
                i += 1
                continue
            if (
                paren_depth == 0
                and bracket_depth == 0
                and (ch.isalpha() or ch == "_")
            ):
                start = i
                while i < n and (text[i].isalnum() or text[i] == "_"):
                    i += 1
                word = text[start:i]
                prev_ch = text[start - 1] if start > 0 else ""
                if prev_ch not in (".", "#"):
                    if word in ("if", "while", "for", "catch"):
                        if pending_cond_start is None:
                            pending_cond_start = start
                    elif word == "guard":
                        pending_cond_start = None
                continue
            i += 1
        return "".join(chars)

    def _strip_outer_parens_and_bang(expr: str) -> str:
        """Repeatedly strips matching outer `(...)` and trailing force-unwrap
        `!` (never touching member accesses such as `)?.engine`)."""
        cur = expr.strip()
        while cur:
            if cur.endswith("!") and not cur.endswith("!="):
                cur = cur[:-1].strip()
                continue
            if cur.startswith("(") and cur.endswith(")"):
                depth = 0
                in_str = False
                escaped = False
                closes_at_end = True
                for i, ch in enumerate(cur):
                    if in_str:
                        if escaped:
                            escaped = False
                        elif ch == "\\":
                            escaped = True
                        elif ch == '"':
                            in_str = False
                        continue
                    if ch == '"':
                        in_str = True
                    elif ch == "(":
                        depth += 1
                    elif ch == ")":
                        depth -= 1
                        if depth == 0 and i != len(cur) - 1:
                            closes_at_end = False
                            break
                if closes_at_end and depth == 0:
                    cur = cur[1:-1].strip()
                    continue
            break
        return cur

    def _trim_swift_decl_rhs(raw_rhs: str) -> str:
        """Extracts the single initializer expression from a Swift `let`/`var`
        line (stopping before top-level `else`, `;`, `,`, or an unclosed
        condition-body `{` while preserving balanced inline closures)."""
        cleaned = _strip_swift_comments(raw_rhs).strip()
        depth_p = depth_b = depth_c = 0
        in_str = False
        escaped = False
        unclosed_brace_stack: list[int] = []
        i = 0
        n = len(cleaned)
        while i < n:
            ch = cleaned[i]
            if in_str:
                if escaped:
                    escaped = False
                elif ch == "\\":
                    escaped = True
                elif ch == '"':
                    in_str = False
                i += 1
                continue
            if ch == '"':
                in_str = True
                i += 1
                continue
            if ch == "(":
                depth_p += 1
            elif ch == ")":
                depth_p = max(0, depth_p - 1)
            elif ch == "[":
                depth_b += 1
            elif ch == "]":
                depth_b = max(0, depth_b - 1)
            elif ch == "{":
                if depth_p == 0 and depth_b == 0 and depth_c == 0:
                    unclosed_brace_stack.append(i)
                depth_c += 1
            elif ch == "}":
                if depth_c > 0:
                    depth_c -= 1
                    if depth_p == 0 and depth_b == 0 and depth_c == 0 and unclosed_brace_stack:
                        unclosed_brace_stack.pop()
            elif depth_p == 0 and depth_b == 0 and depth_c == 0:
                if ch in (";", ","):
                    return cleaned[:i].strip()
                if cleaned[i : i + 4] == "else" and (
                    i == 0 or not (cleaned[i - 1].isalnum() or cleaned[i - 1] == "_")
                ) and (
                    i + 4 == n or not (cleaned[i + 4].isalnum() or cleaned[i + 4] == "_")
                ):
                    return cleaned[:i].strip()
            i += 1
        if unclosed_brace_stack:
            return cleaned[: unclosed_brace_stack[0]].strip()
        return cleaned

    def _extract_swift_closure_return_type(closure_body: str) -> str | None:
        """Extracts the explicit return type `R` from a Swift closure signature
        `[captures] params [throws] -> R in ...`, returning `None` if no
        top-level `-> R in` signature header is present."""
        depth_p = depth_b = depth_c = 0
        in_str = False
        escaped = False
        in_pos = -1
        i = 0
        n = len(closure_body)
        while i < n:
            ch = closure_body[i]
            if in_str:
                if escaped:
                    escaped = False
                elif ch == "\\":
                    escaped = True
                elif ch == '"':
                    in_str = False
                i += 1
                continue
            if ch == '"':
                in_str = True
                i += 1
                continue
            if ch == "(":
                depth_p += 1
            elif ch == ")":
                depth_p = max(0, depth_p - 1)
            elif ch == "[":
                depth_b += 1
            elif ch == "]":
                depth_b = max(0, depth_b - 1)
            elif ch == "{":
                depth_c += 1
            elif ch == "}":
                depth_c = max(0, depth_c - 1)
            elif depth_p == 0 and depth_b == 0 and depth_c == 0:
                if closure_body[i : i + 2] == "in" and (
                    i == 0 or not (closure_body[i - 1].isalnum() or closure_body[i - 1] == "_")
                ) and (
                    i + 2 == n or not (closure_body[i + 2].isalnum() or closure_body[i + 2] == "_")
                ):
                    in_pos = i
                    break
            i += 1
        if in_pos < 0:
            return None
        header = closure_body[:in_pos].strip()
        depth_p = depth_b = depth_c = 0
        in_str = False
        escaped = False
        arrow_pos = -1
        i = 0
        hn = len(header)
        while i < hn:
            ch = header[i]
            if in_str:
                if escaped:
                    escaped = False
                elif ch == "\\":
                    escaped = True
                elif ch == '"':
                    in_str = False
                i += 1
                continue
            if ch == '"':
                in_str = True
                i += 1
                continue
            if ch == "(":
                depth_p += 1
            elif ch == ")":
                depth_p = max(0, depth_p - 1)
            elif ch == "[":
                depth_b += 1
            elif ch == "]":
                depth_b = max(0, depth_b - 1)
            elif ch == "{":
                depth_c += 1
            elif ch == "}":
                depth_c = max(0, depth_c - 1)
            elif depth_p == 0 and depth_b == 0 and depth_c == 0:
                if header[i : i + 2] == "->":
                    arrow_pos = i
            i += 1
        if arrow_pos < 0:
            return None
        return header[arrow_pos + 2 :].strip()

    def _split_trailing_swift_optional_map(inner: str) -> tuple[str, str, str] | None:
        """If `inner` ends with a balanced trailing `.flatMap { ... }` or
        `.map { ... }` (including `?.` / `!.`), returns `(method, base_expr, closure_body)`.
        Returns `None` if there is anything after the closing `}`."""
        if not inner.endswith("}"):
            return None
        depth_c = 0
        in_str = False
        escaped = False
        open_brace = -1
        for i, ch in enumerate(inner):
            if in_str:
                if escaped:
                    escaped = False
                elif ch == "\\":
                    escaped = True
                elif ch == '"':
                    in_str = False
                continue
            if ch == '"':
                in_str = True
            elif ch == "{":
                if depth_c == 0:
                    open_brace = i
                depth_c += 1
            elif ch == "}":
                depth_c -= 1
                if depth_c < 0:
                    return None
                if depth_c == 0 and i != len(inner) - 1:
                    open_brace = -1
        if depth_c != 0 or open_brace < 0:
            return None
        prefix = inner[:open_brace].rstrip()
        m_map = re.search(r"(?:\?\.|!\.|\.)(flatMap|map)(?:\s*\(\s*\))?\s*$", prefix)
        if not m_map:
            return None
        base = prefix[: m_map.start()].rstrip()
        if not base:
            return None
        return m_map.group(1), base, inner[open_brace + 1 : -1]

    def _expr_has_final_flutter_vc_type(
        raw_expr: str,
        *,
        base_resolver=None,
        allow_closure_map: bool = False,
    ) -> bool:
        """Return True ONLY when the final/outermost type of `raw_expr` is
        `FlutterViewController` / `MarcoFlutterViewController` (never an
        intermediate cast followed by `.engine` or another member access)."""
        inner = _strip_outer_parens_and_bang(raw_expr)
        if not inner:
            return False

        # Case 1: Direct constructor call `(Flutter.)?(Marco)?FlutterViewController(...)`
        # whose closing `)` is the very last character (no trailing `.engine` etc.).
        m_init = re.match(
            r"^(?:Flutter\.)?(?:Marco)?FlutterViewController\s*\(",
            inner,
        )
        if m_init:
            depth = 0
            in_str = False
            escaped = False
            for i in range(m_init.end() - 1, len(inner)):
                ch = inner[i]
                if in_str:
                    if escaped:
                        escaped = False
                    elif ch == "\\":
                        escaped = True
                    elif ch == '"':
                        in_str = False
                    continue
                if ch == '"':
                    in_str = True
                elif ch == "(":
                    depth += 1
                elif ch == ")":
                    depth -= 1
                    if depth == 0:
                        return i == len(inner) - 1
            return False

        # Case 2: Trailing Optional `.flatMap { ... -> FlutterViewController? in ... }`
        # / `.map { ... -> FlutterViewController in ... }` on an already-captured
        # local binding (`allow_closure_map=True`, so closures are never re-evaluated
        # inline at the registration call site), where the closure's closing `}` is
        # the very last character, its explicit return type flattens to a single
        # optional `FlutterViewController?` (never double-optional `FlutterViewController??`
        # from `.map { ... -> FlutterViewController? in ... }`), AND the base
        # expression itself is proved to be a `FlutterViewController`.
        if allow_closure_map:
            split_map = _split_trailing_swift_optional_map(inner)
            if split_map is not None:
                map_method, base_expr, closure_body = split_map
                ret_type = _extract_swift_closure_return_type(closure_body)
                ret_pattern = (
                    r"(?:(?:Flutter\.)?(?:Marco)?FlutterViewController)[?!]?"
                    if map_method == "flatMap"
                    else r"(?:Flutter\.)?(?:Marco)?FlutterViewController"
                )
                if ret_type and re.fullmatch(ret_pattern, ret_type):
                    if _expr_has_final_flutter_vc_type(
                        base_expr,
                        base_resolver=base_resolver,
                        allow_closure_map=True,
                    ):
                        return True
                    base_ident = _strip_outer_parens_and_bang(base_expr)
                    if (
                        base_resolver is not None
                        and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", base_ident)
                        and base_resolver(base_ident)
                    ):
                        return True
                return False

        # Case 3: Top-level trailing cast `... as? (Flutter.)?(Marco)?FlutterViewController`
        # (or `as!`) at nesting depth 0, with no trailing member access and no
        # unparenthesized ternary `?` or coalescing `??` at depth 0.
        m_cast = re.search(
            r"\bas[?!]\s+(?:Flutter\.)?(?:Marco)?FlutterViewController\s*$",
            inner,
        )
        if not m_cast:
            return False
        prefix = inner[: m_cast.start()]
        depth_p = depth_b = depth_c = 0
        in_str = False
        escaped = False
        i = 0
        while i < len(prefix):
            ch = prefix[i]
            if in_str:
                if escaped:
                    escaped = False
                elif ch == "\\":
                    escaped = True
                elif ch == '"':
                    in_str = False
                i += 1
                continue
            if ch == '"':
                in_str = True
            elif ch == "(":
                depth_p += 1
            elif ch == ")":
                depth_p = max(0, depth_p - 1)
            elif ch == "[":
                depth_b += 1
            elif ch == "]":
                depth_b = max(0, depth_b - 1)
            elif ch == "{":
                depth_c += 1
            elif ch == "}":
                depth_c = max(0, depth_c - 1)
            elif depth_p == 0 and depth_b == 0 and depth_c == 0:
                if ch == "?" and prefix[i : i + 2] == "??":
                    return False
                if ch == "?" and prefix[i : i + 2] != "?." and not (
                    i >= 2 and prefix[i - 2 : i] == "as" and (i == 2 or not (prefix[i - 3].isalnum() or prefix[i - 3] == "_"))
                ):
                    return False
            i += 1
        return depth_p == 0 and depth_b == 0 and depth_c == 0

    # Swift expression continuation tokens that can legitimately continue a
    # preceding expression across a newline or SE-0308 postfix `#if` directive.
    # Notably excludes leading `(`, `{`, `[`: in Swift, a newline followed by
    # `(...)` starts an independent parenthesized statement (never a call).
    _SWIFT_EXPR_CONTINUATION_RE = re.compile(
        r"^(?:\?\.|!\.|\.|as(?:\b|[?!])|\?\?|\?|!(?=\s|$|\.)|:|&&|\|\||[+\-*/%&|^<>]=?)"
    )
    _SWIFT_INCOMPLETE_EXPR_END_RE = re.compile(
        r"(?:=|\?\.|!\.|\.|as(?:\b|[?!])|\?\?|\?|:|\(|\[|,|&&|\|\||->)\s*$"
    )

    def _swift_line_bracket_delta(line: str) -> int:
        delta = 0
        in_str = False
        esc = False
        for ch in line:
            if in_str:
                if esc:
                    esc = False
                elif ch == "\\":
                    esc = True
                elif ch == '"':
                    in_str = False
                continue
            if ch == '"':
                in_str = True
            elif ch in ("{", "(", "["):
                delta += 1
            elif ch in ("}", ")", "]"):
                delta -= 1
        return delta

    def _compute_needed_idents(target: str, text: str) -> set[str]:
        """Transitive closure of identifier names referenced in the RHS of
        declarations for `target` (used to prune unrelated closed `#if` blocks
        that cannot affect `target`'s static type)."""
        needed = {target}
        decls = list(
            re.finditer(
                r"\b(?:let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\b"
                r"(?:[ \t]*:[ \t]*[A-Za-z_][A-Za-z0-9_.]*[?!]?)?"
                r"(?:[ \t]*=[ \t]*([^\n]*))?",
                text,
            )
        )
        changed = True
        while changed:
            changed = False
            for m in decls:
                name = m.group(1)
                if name not in needed:
                    continue
                first_rhs = m.group(2)
                if first_rhs is None:
                    continue
                first_rhs_stripped = first_rhs.strip()
                rhs_parts = [first_rhs_stripped]
                open_depth = max(0, _swift_line_bracket_delta(first_rhs_stripped))
                prev_incomplete = (
                    not first_rhs_stripped
                    or bool(_SWIFT_INCOMPLETE_EXPR_END_RE.search(first_rhs_stripped))
                )
                for nxt in text[m.end() :].splitlines():
                    clean_nxt = nxt.strip()
                    if not clean_nxt or re.match(r"^#(?:if|elseif|else|endif)\b", clean_nxt):
                        continue
                    if (
                        open_depth > 0
                        or prev_incomplete
                        or _SWIFT_EXPR_CONTINUATION_RE.match(clean_nxt)
                    ):
                        rhs_parts.append(clean_nxt)
                        open_depth = max(0, open_depth + _swift_line_bracket_delta(clean_nxt))
                        prev_incomplete = bool(_SWIFT_INCOMPLETE_EXPR_END_RE.search(clean_nxt))
                        continue
                    break
                full_rhs = " ".join(p for p in rhs_parts if p)
                for ident in re.findall(r"\b[A-Za-z_][A-Za-z0-9_]*\b", full_rhs):
                    if ident not in needed:
                        needed.add(ident)
                        changed = True
        return needed

    def _lines_have_balanced_braces(arm_lines: list[str]) -> bool:
        depth = 0
        for ln in arm_lines:
            in_str = False
            esc = False
            for ch in ln:
                if in_str:
                    if esc:
                        esc = False
                    elif ch == "\\":
                        esc = True
                    elif ch == '"':
                        in_str = False
                    continue
                if ch == '"':
                    in_str = True
                elif ch == "{":
                    depth += 1
                elif ch == "}":
                    depth -= 1
                    if depth < 0:
                        return False
        return depth == 0

    def _parse_swift_if_cond(cond_expr: str) -> tuple[str, bool] | None:
        s = cond_expr.strip()
        neg = False
        while True:
            while s.startswith("(") and s.endswith(")") and _has_balanced_outer_parens(s):
                s = s[1:-1].strip()
            if s.startswith("!"):
                neg = not neg
                s = s[1:].strip()
                continue
            break
        if not s or "&&" in s or "||" in s:
            return None
        if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*(?:\([^()]*\))?", s):
            return s, (not neg)
        return None

    def _expand_swift_compile_branches(
        text: str,
        needed_idents: set[str] | None = None,
        max_branches: int = 16,
    ) -> list[str] | None:
        """Expands Swift compile-time `#if` / `#elseif` / `#else` / `#endif`
        blocks into every mutually feasible configuration branch so type checks
        only accept `controller: receiver` when EVERY reachable build
        configuration proves `receiver` is a `FlutterViewController`.

        Prunes closed `#if ... #endif` blocks whose arms have balanced braces
        and declare no identifier in `needed_idents` (e.g. unrelated `#if DEBUG`
        logging blocks), and tracks consistent truth assignments per atomic
        condition so repeated `#if DEBUG` / `#if !DEBUG` blocks never cause
        combinatorial 2^N blowup.

        Returns `None` if genuinely distinct combinatorial branching still
        exceeds `max_branches` (causing the caller to conservatively omit
        `controller:`)."""
        lines = text.splitlines()

        def _block_is_irrelevant(
            arms: list[tuple[str | None, list[str]]],
            *,
            attaches_to_needed: bool,
        ) -> bool:
            if not needed_idents:
                return False
            for _, arm_lines in arms:
                if not _lines_have_balanced_braces(arm_lines):
                    return False
                # Swift SE-0308 postfix `#if` expressions can alter the type of
                # the preceding statement without introducing a new `let`/`var`.
                # Only treat a postfix continuation arm as relevant when the
                # preceding statement actually defines a binding in `needed_idents`
                # (so unrelated postfix chains like `let launchLabel = "Marco"\n#if FLAG\n .appending(...)`
                # never consume branch budget).
                if attaches_to_needed:
                    expecting_arm_head = True
                    for arm_ln in arm_lines:
                        clean_arm_ln = arm_ln.strip()
                        if not clean_arm_ln:
                            continue
                        if re.match(r"^#(?:if|elseif|else|endif)\b", clean_arm_ln):
                            expecting_arm_head = True
                            continue
                        if expecting_arm_head:
                            if _SWIFT_EXPR_CONTINUATION_RE.match(clean_arm_ln):
                                return False
                            expecting_arm_head = False
                arm_text = "\n".join(arm_lines)
                if re.search(r"\btypealias\b", arm_text):
                    return False
                for m in re.finditer(r"\b(?:let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\b", arm_text):
                    if m.group(1) in needed_idents:
                        return False
                for m in re.finditer(r"\b(?:let|var)\s*\(([^=\n)]+)\)", arm_text):
                    for ident in re.findall(r"\b[A-Za-z_][A-Za-z0-9_]*\b", m.group(1)):
                        if ident in needed_idents:
                            return False
            return True

        def _advance_stmt_state(
            cur_decl: str | None,
            open_depth: int,
            prev_incomplete: bool,
            line: str,
        ) -> tuple[str | None, int, bool]:
            tok = line.strip()
            if not tok:
                return cur_decl, open_depth, prev_incomplete
            if cur_decl is None or (
                open_depth == 0
                and not prev_incomplete
                and not _SWIFT_EXPR_CONTINUATION_RE.match(tok)
            ):
                decls_on_line = re.findall(r"\b(?:let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\b", line)
                if decls_on_line:
                    cur_decl = decls_on_line[-1]
                    return (
                        cur_decl,
                        max(0, _swift_line_bracket_delta(line)),
                        bool(_SWIFT_INCOMPLETE_EXPR_END_RE.search(tok)),
                    )
                return None, 0, False
            next_depth = max(0, open_depth + _swift_line_bracket_delta(line))
            next_incomplete = bool(_SWIFT_INCOMPLETE_EXPR_END_RE.search(tok))
            return cur_decl, next_depth, next_incomplete

        def _expand_lines(
            seg_lines: list[str],
            init_states: list[tuple[list[str], dict[str, bool], str | None, int, bool]],
        ) -> list[tuple[list[str], dict[str, bool], str | None, int, bool]] | None:
            states = init_states
            seg_n = len(seg_lines)
            idx = 0
            while idx < seg_n:
                line = seg_lines[idx]
                tok = line.strip()
                if re.match(r"^#if\b", tok):
                    # Collect the `#if` block within `seg_lines`.
                    first_cond = tok[3:].strip()
                    arms: list[tuple[str | None, list[str]]] = []
                    cur_cond: str | None = first_cond
                    cur_lines: list[str] = []
                    idx += 1
                    depth = 0
                    closed = False
                    while idx < seg_n:
                        s_line = seg_lines[idx]
                        s_tok = s_line.strip()
                        if re.match(r"^#if\b", s_tok):
                            depth += 1
                            cur_lines.append(s_line)
                            idx += 1
                            continue
                        if re.match(r"^#endif\b", s_tok):
                            if depth == 0:
                                arms.append((cur_cond, cur_lines))
                                closed = True
                                idx += 1
                                break
                            depth -= 1
                            cur_lines.append(s_line)
                            idx += 1
                            continue
                        if depth == 0 and re.match(r"^#elseif\b", s_tok):
                            arms.append((cur_cond, cur_lines))
                            cur_cond = s_tok[7:].strip()
                            cur_lines = []
                            idx += 1
                            continue
                        if depth == 0 and re.match(r"^#else\b", s_tok):
                            arms.append((cur_cond, cur_lines))
                            cur_cond = None
                            cur_lines = []
                            idx += 1
                            continue
                        cur_lines.append(s_line)
                        idx += 1
                    if not closed:
                        arms.append((cur_cond, cur_lines))
                        # Unclosed `#if` enclosing the registration point:
                        # only the last (currently active) arm reaches EOF, and
                        # reaching it requires all preceding sibling arms to be false.
                        active_cond, active_lines = arms[-1]
                        next_states: list[tuple[list[str], dict[str, bool], str | None, int, bool]] = []
                        for prefix_lines, env, cur_decl, open_depth, prev_incomplete in states:
                            arm_env = dict(env)
                            feasible = True
                            for prior_cond, _ in arms[:-1]:
                                if prior_cond is None:
                                    continue
                                parsed_prior = _parse_swift_if_cond(prior_cond)
                                if parsed_prior is not None:
                                    p_atom, p_want = parsed_prior
                                    if p_atom in arm_env and arm_env[p_atom] == p_want:
                                        feasible = False
                                        break
                                    arm_env[p_atom] = not p_want
                            if not feasible:
                                continue
                            if active_cond is not None:
                                parsed = _parse_swift_if_cond(active_cond)
                                if parsed is not None:
                                    atom, want = parsed
                                    if atom in arm_env and arm_env[atom] != want:
                                        continue
                                    arm_env[atom] = want
                            sub = _expand_lines(
                                active_lines,
                                [(list(prefix_lines), arm_env, cur_decl, open_depth, prev_incomplete)],
                            )
                            if sub is None:
                                return None
                            next_states.extend(sub)
                            if len(next_states) > max_branches:
                                return None
                        states = next_states
                        continue

                    attaches_to_needed = bool(
                        needed_idents
                        and any(cur_decl in needed_idents for _, _, cur_decl, _, _ in states)
                    )
                    any_incomplete_needed_prev = False
                    if attaches_to_needed:
                        for p_lines, _, cur_decl, _, prev_incomplete in states:
                            if cur_decl not in (needed_idents or ()):
                                continue
                            if prev_incomplete:
                                any_incomplete_needed_prev = True
                                break
                            for prev_ln in reversed(p_lines):
                                s_prev = prev_ln.strip()
                                if s_prev:
                                    if _SWIFT_INCOMPLETE_EXPR_END_RE.search(s_prev):
                                        any_incomplete_needed_prev = True
                                    break
                            if any_incomplete_needed_prev:
                                break
                    if not any_incomplete_needed_prev and _block_is_irrelevant(
                        arms,
                        attaches_to_needed=attaches_to_needed,
                    ):
                        continue

                    has_else = any(cond is None for cond, _ in arms)
                    next_states = []
                    for prefix_lines, env, cur_decl, open_depth, prev_incomplete in states:
                        negated_env = dict(env)
                        guaranteed_taken = False
                        for arm_cond, arm_lines in arms:
                            if arm_cond is None:
                                sub = _expand_lines(
                                    arm_lines,
                                    [(list(prefix_lines), dict(negated_env), cur_decl, open_depth, prev_incomplete)],
                                )
                                if sub is None:
                                    return None
                                next_states.extend(sub)
                                guaranteed_taken = True
                                break
                            parsed = _parse_swift_if_cond(arm_cond)
                            if parsed is not None:
                                atom, want = parsed
                                if atom in negated_env:
                                    if negated_env[atom] != want:
                                        continue
                                    sub = _expand_lines(
                                        arm_lines,
                                        [(list(prefix_lines), dict(negated_env), cur_decl, open_depth, prev_incomplete)],
                                    )
                                    if sub is None:
                                        return None
                                    next_states.extend(sub)
                                    guaranteed_taken = True
                                    break
                                arm_env = dict(negated_env)
                                arm_env[atom] = want
                                sub = _expand_lines(
                                    arm_lines,
                                    [(list(prefix_lines), arm_env, cur_decl, open_depth, prev_incomplete)],
                                )
                                if sub is None:
                                    return None
                                next_states.extend(sub)
                                negated_env[atom] = not want
                            else:
                                sub = _expand_lines(
                                    arm_lines,
                                    [(list(prefix_lines), dict(negated_env), cur_decl, open_depth, prev_incomplete)],
                                )
                                if sub is None:
                                    return None
                                next_states.extend(sub)
                            if len(next_states) > max_branches:
                                return None
                        if not guaranteed_taken and not has_else:
                            next_states.append(
                                (list(prefix_lines), dict(negated_env), cur_decl, open_depth, prev_incomplete)
                            )
                        if len(next_states) > max_branches:
                            return None
                    states = next_states
                    continue

                updated_states: list[tuple[list[str], dict[str, bool], str | None, int, bool]] = []
                for prefix_lines, env, cur_decl, open_depth, prev_incomplete in states:
                    prefix_lines.append(line)
                    next_decl, next_depth, next_incomplete = _advance_stmt_state(
                        cur_decl,
                        open_depth,
                        prev_incomplete,
                        line,
                    )
                    updated_states.append((prefix_lines, env, next_decl, next_depth, next_incomplete))
                states = updated_states
                idx += 1
            return states

        expanded = _expand_lines(lines, [([], {}, None, 0, False)])
        if expanded is None:
            return None
        return ["\n".join(p_lines) for p_lines, _, _, _, _ in expanded]

    def _is_known_flutter_vc_in_linear_scope(
        stripped: str,
        linear_scope: str,
        _seen: frozenset[str] = frozenset(),
    ) -> bool:
        """Evaluates whether identifier `stripped` is positively proved to be a
        `FlutterViewController` in a single compile-configuration scope."""
        clean_scope = _strip_closed_inner_blocks(linear_scope)
        decl_matches = list(
            re.finditer(
                rf"\b(?:let|var)\s+{re.escape(stripped)}\b"
                r"(?:[ \t]*:[ \t]*(?P<type>[A-Za-z_][A-Za-z0-9_.]*[?!]?))?"
                r"(?:[ \t]*=[ \t]*(?P<rhs>[^\n]*))?",
                clean_scope,
            )
        )
        if not decl_matches:
            return False
        # Inspect the nearest binding shadowing `stripped` in scope. Because
        # `_strip_closed_inner_blocks` preserves exact character offsets, read
        # the RHS and its continuation lines from the un-wiped `linear_scope`
        # so closure return annotations like `.flatMap { child -> FlutterViewController? in ... }`
        # remain intact while closed inner-block shadow bindings are still ignored.
        last_decl = decl_matches[-1]
        ann_type = (last_decl.group("type") or "").strip()
        if ann_type:
            return bool(
                re.fullmatch(
                    r"(?:(?:Flutter\.)?(?:Marco)?FlutterViewController)[?!]?",
                    ann_type,
                )
            )
        if last_decl.start("rhs") < 0:
            return False
        raw_rhs = linear_scope[last_decl.start("rhs") : last_decl.end("rhs")].strip()
        tail_lines = linear_scope[last_decl.end() :].splitlines()
        rhs_parts = [raw_rhs] if raw_rhs else []
        open_depth = max(0, _swift_line_bracket_delta(raw_rhs))
        prev_incomplete = (
            not raw_rhs or bool(_SWIFT_INCOMPLETE_EXPR_END_RE.search(raw_rhs))
        )
        for next_line in tail_lines:
            clean_next = next_line.strip()
            if not clean_next:
                continue
            if (
                open_depth > 0
                or prev_incomplete
                or _SWIFT_EXPR_CONTINUATION_RE.match(clean_next)
            ):
                rhs_parts.append(clean_next)
                open_depth = max(0, open_depth + _swift_line_bracket_delta(clean_next))
                prev_incomplete = bool(_SWIFT_INCOMPLETE_EXPR_END_RE.search(clean_next))
                continue
            break
        rhs = _trim_swift_decl_rhs(" ".join(p for p in rhs_parts if p).strip())
        if not rhs:
            return False
        prior_scope = clean_scope[: last_decl.start()]
        if _expr_has_final_flutter_vc_type(
            rhs,
            base_resolver=lambda ident: _is_known_flutter_vc_expr(
                ident,
                prior_scope,
                _seen | {stripped},
            ),
            allow_closure_map=True,
        ):
            return True
        rhs_stripped = _strip_outer_parens_and_bang(rhs)
        if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", rhs_stripped):
            return _is_known_flutter_vc_expr(
                rhs_stripped,
                prior_scope,
                _seen | {stripped},
            )
        return False

    def _is_known_flutter_vc_expr(
        expr: str,
        scope_text: str,
        _seen: frozenset[str] = frozenset(),
    ) -> bool:
        """Return True ONLY when Swift syntax positively proves the FINAL type
        of `expr` is compatible with `FlutterViewController?` across ALL
        reachable compile-time `#if` / `#else` configurations (never a
        `FlutterEngine?` in Debug or Release, and never an unverified type)."""
        stripped = _strip_outer_parens_and_bang(expr)
        if stripped == "marcoRootFlutterVC":
            return True
        if _expr_has_final_flutter_vc_type(stripped):
            return True
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", stripped):
            return False
        if stripped in _seen or len(_seen) >= 4:
            return False
        comment_free = _strip_swift_comments(scope_text)
        needed = _compute_needed_idents(stripped, comment_free)
        branches = _expand_swift_compile_branches(comment_free, needed_idents=needed)
        if not branches:
            return False
        return all(
            _is_known_flutter_vc_in_linear_scope(stripped, branch, _seen)
            for branch in branches
        )

    def _detect_self_controller(
        header_or_span: str,
        user_scope_before_if: str,
    ) -> tuple[str | None, bool]:
        """Return `(controller_expr_or_none, uses_custom_messenger)` for a
        classic `if let messenger = ...?.binaryMessenger` block.

        Messenger handling and view-controller passing are strictly decoupled:
        - Any user-selected messenger receiver (child VC, FlutterEngine, etc.)
          is preserved verbatim (`uses_custom_messenger=True`).
        - `controller:` is passed ONLY when the full receiver expression's FINAL
          type is positively proved compatible with `FlutterViewController?`;
          otherwise `controller_expr=None` omits `controller:` so `register(...)`
          falls back to its existing optional `activeFlutterController()` lookup."""
        clean_header = _strip_swift_comments(header_or_span)
        m_src = re.search(
            r"if\s+let\s+messenger\s*=\s*(?P<expr>.+?)[?!]?\.binaryMessenger\b",
            clean_header,
            re.DOTALL,
        )
        if not m_src:
            return "marcoRootFlutterVC", False
        expr = " ".join(m_src.group("expr").strip().split())
        if expr in (
            "(window?.rootViewController as? FlutterViewController)",
            "marcoRootFlutterVC",
        ):
            return "marcoRootFlutterVC", False
        if expr == "rootFlutterVC":
            if re.search(r"\b(?:let|var)\s+rootFlutterVC\b", user_scope_before_if):
                ctrl = (
                    "rootFlutterVC"
                    if _is_known_flutter_vc_expr("rootFlutterVC", user_scope_before_if)
                    else None
                )
                return ctrl, True
            return "marcoRootFlutterVC", False
        ctrl = expr if _is_known_flutter_vc_expr(expr, user_scope_before_if) else None
        return ctrl, True

    def _strip_known_marco_snippets(snippet: str) -> str:
        """Removes ONLY exact Marco-generated launch logs, generator-owned
        rootFlutterVC binding, and the complete 3-line iOS 13 backgroundColor
        block while keeping all user-authored Swift statements—including nested
        multiline `if` / closure blocks and their closing braces—intact verbatim."""
        known_single_lines = {
            'NSLog("[MarcoLaunch] stage=native_engine_plugin_register_start")',
            'NSLog("[MarcoLaunch] stage=native_engine_plugin_register_done")',
            'NSLog("[MarcoLaunch] stage=native_plugins_registered")',
            'let marcoRootFlutterVC = window?.rootViewController as? FlutterViewController',
        }
        cleaned = re.sub(
            r'^[ \t]*if #available\(iOS 13\.0, \*\) \{\s*\n'
            r'[ \t]*window\?\.backgroundColor = \.systemBackground\s*\n'
            r'[ \t]*\}[ \t]*(?:\n|$)',
            '',
            snippet,
            flags=re.MULTILINE,
        )
        kept: list[str] = []
        for line in cleaned.splitlines():
            stripped = line.strip()
            if stripped in known_single_lines:
                continue
            if stripped.startswith('NSLog("[MarcoLaunch] stage=native_did_finish_launching'):
                continue
            kept.append(line)
        while kept and not kept[0].strip():
            kept.pop(0)
        while kept and not kept[-1].strip():
            kept.pop()
        return "\n".join(kept)

    # 1. Existing marked registration block(s) -> upgrade in place.
    marked_re = re.compile(
        r"^(?P<indent>[ \t]*)// MARCO_GENERATED_BEGIN: ios_registration\n"
        r"(?P<body>.*?)"
        r"^[ \t]*// MARCO_GENERATED_END: ios_registration",
        re.MULTILINE | re.DOTALL,
    )
    m_marked = marked_re.search(ad_text)
    if m_marked:
        indent = m_marked.group("indent")
        replacement = (
            make_engine_block(indent)
            if "engineBridge.pluginRegistry" in m_marked.group("body")
            else make_self_block(indent)
        )
        updated = _join_after_marker(
            ad_text[:m_marked.start()] + replacement,
            ad_text[m_marked.end():],
        )
        return updated, updated != ad_text

    # 1b. Existing split in-place markers (used when user-authored Swift sits
    #     between generator calls, inside `if let messenger`, or in a chained
    #     `else if` / `else`) -> upgrade each generator-owned span in place
    #     without touching user scope or ordering.
    preamble_begin_tag = "// MARCO_GENERATED_BEGIN: ios_self_plugin_preamble"
    preamble_end_tag = "// MARCO_GENERATED_END: ios_self_plugin_preamble"
    registrar_begin_tag = "// MARCO_GENERATED_BEGIN: ios_self_registrar"
    self_controller_expr = "marcoRootFlutterVC"
    self_uses_custom_controller = False
    preamble_begin_idx = ad_text.find(preamble_begin_tag)
    preamble_end_idx = ad_text.find(preamble_end_tag)
    if preamble_end_idx != -1:
        span_start = preamble_end_idx + len(preamble_end_tag)
        span_end = ad_text.find(registrar_begin_tag, span_start)
        if span_end != -1:
            between_markers = ad_text[span_start:span_end]
            func_start = (
                ad_text.rfind("func application(", 0, preamble_begin_idx)
                if preamble_begin_idx != -1
                else -1
            )
            user_before_preamble = (
                ad_text[func_start:preamble_begin_idx]
                if func_start != -1 and preamble_begin_idx != -1
                else ""
            )
            self_controller_expr, self_uses_custom_controller = _detect_self_controller(
                between_markers,
                user_before_preamble + "\n" + between_markers,
            )

    split_markers = (
        ("ios_engine_plugin_preamble", make_engine_preamble),
        ("ios_engine_registrar", make_engine_registrar),
        (
            "ios_self_plugin_preamble",
            lambda indent: make_self_preamble(
                indent, include_root_vc=not self_uses_custom_controller
            ),
        ),
        (
            "ios_self_registrar",
            lambda indent: make_self_registrar(
                indent, controller_expr=self_controller_expr
            ),
        ),
        ("ios_self_post_register", make_self_post_register),
    )
    if any(f"// MARCO_GENERATED_BEGIN: {tag}" in ad_text for tag, _ in split_markers):
        updated = ad_text
        for tag, builder in split_markers:
            tag_re = re.compile(
                rf"^(?P<indent>[ \t]*)// MARCO_GENERATED_BEGIN: {re.escape(tag)}\n"
                r".*?"
                rf"^[ \t]*// MARCO_GENERATED_END: {re.escape(tag)}",
                re.MULTILINE | re.DOTALL,
            )
            m_tag = tag_re.search(updated)
            if m_tag:
                updated = _join_after_marker(
                    updated[:m_tag.start()] + builder(m_tag.group("indent")),
                    updated[m_tag.end():],
                )
        # Upgrade an intermediate R3 split-marker `if let messenger = rootFlutterVC?.binaryMessenger`
        # ONLY within the span immediately between `ios_self_plugin_preamble` and
        # `ios_self_registrar` when `rootFlutterVC` was NOT user-declared.
        if not self_uses_custom_controller:
            preamble_end_idx = updated.find(preamble_end_tag)
            if preamble_end_idx != -1:
                span_start = preamble_end_idx + len(preamble_end_tag)
                span_end = updated.find(registrar_begin_tag, span_start)
                if span_end != -1:
                    between_markers = updated[span_start:span_end]
                    if (
                        "if let messenger = rootFlutterVC?.binaryMessenger" in between_markers
                        and not re.search(r"\b(?:let|var)\s+rootFlutterVC\b", between_markers)
                    ):
                        updated = (
                            updated[:span_start]
                            + between_markers.replace(
                                "if let messenger = rootFlutterVC?.binaryMessenger",
                                "if let messenger = marcoRootFlutterVC?.binaryMessenger",
                                1,
                            )
                            + updated[span_end:]
                        )
        return updated, updated != ad_text

    # 2. Legacy unmarked engineBridge registration block (0.7.6 or pre-marker candidate).
    #    When user-authored code sits between GeneratedPluginRegistrant and
    #    MarcoNativeChannelRegistrar (such as an early return or conditional),
    #    replace ONLY the generator-owned statements IN PLACE so execution order
    #    and scope are preserved verbatim.
    m_eng_gen = re.search(
        r"^(?P<indent>[ \t]*)"
        r"(?:NSLog\(\"\[MarcoLaunch\] stage=native_engine_plugin_register_start\"\)\s*\n[ \t]*)?"
        r"GeneratedPluginRegistrant\.register\(with:\s*engineBridge\.pluginRegistry\)",
        ad_text,
        re.MULTILINE,
    )
    if m_eng_gen:
        indent = m_eng_gen.group("indent")
        m_reg = re.search(
            r"^(?P<reg_indent>[ \t]*)MarcoNativeChannelRegistrar\.register\(",
            ad_text[m_eng_gen.end():],
            re.MULTILINE,
        )
        if m_reg:
            reg_start = m_eng_gen.end() + m_reg.start()
            reg_indent = m_reg.group("reg_indent")
            reg_paren = m_eng_gen.end() + m_reg.end() - 1
            call_end = _find_swift_brace_block_end(ad_text, reg_paren, "(", ")")
            if call_end != -1:
                between = ad_text[m_eng_gen.end():reg_start]
                custom_between = _strip_known_marco_snippets(between)
                tail_match = re.match(
                    r"[ \t]*\n[ \t]*NSLog\(\"\[MarcoLaunch\] stage=native_engine_plugin_register_done\"\)",
                    ad_text[call_end:],
                )
                block_end = call_end + (tail_match.end() if tail_match else 0)
                if not custom_between:
                    replacement = make_engine_block(indent)
                    updated = _join_after_marker(
                        ad_text[:m_eng_gen.start()] + replacement,
                        ad_text[block_end:],
                    )
                else:
                    updated = _join_after_marker(
                        ad_text[:m_eng_gen.start()]
                        + make_engine_preamble(indent)
                        + between
                        + make_engine_registrar(reg_indent),
                        ad_text[block_end:],
                    )
                return updated, updated != ad_text

    # 3. Legacy unmarked didFinishLaunchingWithOptions registration block (0.7.6 or pre-marker).
    #    When user-authored code sits between GeneratedPluginRegistrant and the
    #    messenger block, inside `if let messenger { ... }`, OR in a chained
    #    `else if` / `else` clause, replace ONLY the generator-owned statements
    #    IN PLACE so local declarations, guard scopes, else branches, and
    #    statement ordering relative to MarcoNativeChannelRegistrar stay intact.
    m_self_gen = re.search(
        r"^(?P<indent>[ \t]*)"
        r"(?:NSLog\(\"\[MarcoLaunch\] stage=native_did_finish_launching[^\n]*\)\s*\n[ \t]*)?"
        r"(?:if #available\(iOS 13\.0, \*\) \{\s*\n[ \t]*window\?\.backgroundColor = \.systemBackground\s*\n[ \t]*\}\s*\n[ \t]*)?"
        r"GeneratedPluginRegistrant\.register\(with:\s*self\)",
        ad_text,
        re.MULTILINE,
    )
    if m_self_gen:
        indent = m_self_gen.group("indent")
        search_tail = ad_text[m_self_gen.end():]
        m_if_msg = re.search(
            r"^(?P<if_indent>[ \t]*)if let messenger =[^\n{]*(?:\n[ \t]*[^\n{]*)*\{",
            search_tail,
            re.MULTILINE,
        )
        if m_if_msg:
            if_start = m_self_gen.end() + m_if_msg.start()
            if_indent = m_if_msg.group("if_indent")
            brace_open = m_self_gen.end() + m_if_msg.end() - 1
            if_end = _find_swift_brace_block_end(ad_text, brace_open, "{", "}")
            if if_end != -1 and "MarcoNativeChannelRegistrar.register(" in ad_text[brace_open:if_end]:
                chain_end, has_else_chain = _find_swift_if_chain_end(ad_text, if_end)
                between = ad_text[m_self_gen.end():if_start]
                custom_between = _strip_known_marco_snippets(between)
                inner_body = ad_text[brace_open + 1:if_end - 1]
                m_inner_reg = re.search(
                    r"^(?P<reg_indent>[ \t]*)MarcoNativeChannelRegistrar\.register\(",
                    inner_body,
                    re.MULTILINE,
                )
                custom_inside = ""
                inner_call_end = -1
                if m_inner_reg:
                    inner_call_end = _find_swift_brace_block_end(
                        inner_body, m_inner_reg.end() - 1, "(", ")"
                    )
                    if inner_call_end != -1:
                        stripped_inner = (
                            inner_body[:m_inner_reg.start()]
                            + inner_body[inner_call_end:]
                        )
                        custom_inside = _strip_known_marco_snippets(stripped_inner)
                tail_match = re.match(
                    r"[ \t]*\n[ \t]*NSLog\(\"\[MarcoLaunch\] stage=native_plugins_registered\"\)",
                    ad_text[chain_end:],
                )
                block_end = chain_end + (tail_match.end() if tail_match else 0)
                raw_header_text = ad_text[if_start:brace_open + 1]
                func_start = ad_text.rfind("func application(", 0, m_self_gen.start())
                user_before_gen = (
                    ad_text[func_start:m_self_gen.start()] if func_start != -1 else ""
                )
                ctrl_expr, uses_custom_ctrl = _detect_self_controller(
                    raw_header_text,
                    user_before_gen + "\n" + between,
                )
                if (
                    not custom_between
                    and not custom_inside
                    and not has_else_chain
                    and not uses_custom_ctrl
                ):
                    replacement = make_self_block(indent)
                    updated = _join_after_marker(
                        ad_text[:m_self_gen.start()] + replacement,
                        ad_text[block_end:],
                    )
                    return updated, updated != ad_text
                if m_inner_reg and inner_call_end != -1:
                    # Strip only a duplicate generator-owned `marcoRootFlutterVC` binding from
                    # `between`; never strip a user-authored `let rootFlutterVC = ...`.
                    cleaned_between = re.sub(
                        r"^[ \t]*let marcoRootFlutterVC = window\?\.rootViewController as\? FlutterViewController[ \t]*\n?",
                        "",
                        between,
                        flags=re.MULTILINE,
                    )
                    if uses_custom_ctrl:
                        header_text = raw_header_text
                    else:
                        header_text = (
                            raw_header_text
                            .replace(
                                "(window?.rootViewController as? FlutterViewController)?.binaryMessenger",
                                "marcoRootFlutterVC?.binaryMessenger",
                            )
                            .replace(
                                "rootFlutterVC?.binaryMessenger",
                                "marcoRootFlutterVC?.binaryMessenger",
                            )
                        )
                    reg_indent = m_inner_reg.group("reg_indent")
                    upgraded_inner = (
                        inner_body[:m_inner_reg.start()]
                        + make_self_registrar(reg_indent, controller_expr=ctrl_expr)
                        + inner_body[inner_call_end:]
                    )
                    else_chain = ad_text[if_end:chain_end]
                    updated = _join_after_marker(
                        ad_text[:m_self_gen.start()]
                        + make_self_preamble(indent, include_root_vc=not uses_custom_ctrl)
                        + cleaned_between
                        + header_text
                        + upgraded_inner
                        + "}"
                        + else_chain
                        + "\n"
                        + make_self_post_register(if_indent),
                        ad_text[block_end:],
                    )
                    return updated, updated != ad_text

    # Guard: if a custom MarcoNativeChannelRegistrar.register(...) call already
    # exists in an unrecognized shape, never fall through and duplicate it.
    if "MarcoNativeChannelRegistrar.register(" in ad_text:
        return ad_text, False

    # 4. Clean Flutter template (engineBridge or self).
    clean_engine_re = re.compile(
        r"^(?P<indent>[ \t]*)GeneratedPluginRegistrant\.register\(with:\s*engineBridge\.pluginRegistry\)",
        re.MULTILINE,
    )
    m_clean_engine = clean_engine_re.search(ad_text)
    if m_clean_engine:
        replacement = make_engine_block(m_clean_engine.group("indent"))
        updated = ad_text[:m_clean_engine.start()] + replacement + ad_text[m_clean_engine.end():]
        return updated, updated != ad_text

    clean_self_re = re.compile(
        r"^(?P<indent>[ \t]*)GeneratedPluginRegistrant\.register\(with:\s*self\)",
        re.MULTILINE,
    )
    m_clean_self = clean_self_re.search(ad_text)
    if m_clean_self:
        replacement = make_self_block(m_clean_self.group("indent"))
        updated = ad_text[:m_clean_self.start()] + replacement + ad_text[m_clean_self.end():]
        return updated, updated != ad_text

    return ad_text, False


def _upgrade_macos_media_kit_mpv_v073() -> None:
    """Upgrade pub-cached media_kit_libs_macos_video Makefile from v0.6.0 to v0.7.3 on macOS.

    media_kit_libs_macos_video 1.1.4 (latest on pub.dev) bundles libmpv-darwin-build v0.6.0,
    whose Avcodec.framework omits FFmpeg's pgssub decoder, preventing Blu-ray PGS subtitles
    from rendering on macOS. Official upstream v0.7.3 enables --enable-decoder=pgssub while
    retaining -mmacosx-version-min=10.9 and identical mpv 0.36.0 / FFmpeg 6.0 ABI.
    """
    if sys.platform != "darwin":
        return
    pkg_cfg = ROOT / ".dart_tool" / "package_config.json"
    if not pkg_cfg.is_file():
        return
    try:
        cfg = json.loads(pkg_cfg.read_text(encoding="utf-8"))
    except Exception:
        return
    target_ver = "v0.7.3"
    target_sha = "2e58ac66b0ea875239bf4db29b3ef2100a719df1d61fa1e780c38d651d4c9f27"
    for pkg in cfg.get("packages", []):
        if pkg.get("name") != "media_kit_libs_macos_video":
            continue
        root_uri = pkg.get("rootUri", "")
        if not root_uri:
            continue
        if root_uri.startswith("file://"):
            pkg_root = Path(unquote(urlparse(root_uri).path))
        else:
            pkg_root = (pkg_cfg.parent / root_uri).resolve()
        macos_dir = pkg_root / "macos"
        makefile = macos_dir / "Makefile"
        if not makefile.is_file():
            return
        src = makefile.read_text(encoding="utf-8")
        if f"MPV_XCFRAMEWORKS_VERSION={target_ver}" in src and target_sha in src:
            print(f"media_kit_libs_macos_video Makefile already at libmpv {target_ver}: {makefile}", flush=True)
            return
        updated = re.sub(
            r"^MPV_XCFRAMEWORKS_VERSION=.*$",
            f"MPV_XCFRAMEWORKS_VERSION={target_ver}",
            src,
            flags=re.MULTILINE,
        )
        updated = re.sub(
            r"^MPV_XCFRAMEWORKS_SHA256SUM=.*$",
            f"MPV_XCFRAMEWORKS_SHA256SUM={target_sha}",
            updated,
            flags=re.MULTILINE,
        )
        if updated != src:
            makefile.write_text(updated, encoding="utf-8")
            fw_dir = macos_dir / "Frameworks"
            if fw_dir.is_dir():
                for child in fw_dir.iterdir():
                    if child.name.endswith(".xcframework") or child.name == ".symlinks":
                        if child.is_dir() and not child.is_symlink():
                            shutil.rmtree(child)
                        else:
                            child.unlink(missing_ok=True)
            print(
                f"Upgraded media_kit_libs_macos_video Makefile to libmpv {target_ver} (pgssub enabled): {makefile}",
                flush=True,
            )
        return


def main() -> None:
    subprocess.run([sys.executable, str(REPO_ROOT / 'scripts/prepare_python_html.py'), '--check'], check=True)
    subprocess.run([sys.executable, str(REPO_ROOT / 'scripts/prepare_python_modules.py'), '--check'], check=True)
    src = ROOT / "src"
    if src.exists():
        raise RuntimeError(
            "flutter/src has been migrated to flutter/lib. "
            "Please delete flutter/src to prevent accidental divergence."
        )
    # Bundle user's brand logo into flutter/assets/logo_mark.png
    assets_dir = ROOT / "assets"
    assets_dir.mkdir(parents=True, exist_ok=True)
    shutil.copytree(REPO_ROOT / 'shared/catpaw', assets_dir / 'catpaw', dirs_exist_ok=True)
    python_host = REPO_ROOT / "shared/script-host/python-host"
    shutil.copytree(python_host, assets_dir / "python-host", dirs_exist_ok=True)
    (assets_dir / 'js-host').mkdir(parents=True, exist_ok=True)
    for name in ('module-interop.js', 'catvod.mjs', 'crypto-js.js', 'crypto.LICENSE'):
        shutil.copyfile(REPO_ROOT / 'shared/script-host/js-host' / name,
                        assets_dir / 'js-host' / name)
    if LOGO_MARK.exists():
        shutil.copy2(LOGO_MARK, assets_dir / "logo_mark.png")
    badge_rules = REPO_ROOT / "shared" / "ui-spec" / "badge-rules.json"
    if badge_rules.exists():
        ui_spec_dir = assets_dir / "ui-spec"
        ui_spec_dir.mkdir(parents=True, exist_ok=True)
        shutil.copy2(badge_rules, ui_spec_dir / "badge-rules.json")
    widget_test = ROOT / "test" / "widget_test.dart"
    if widget_test.exists():
        widget_test.unlink()
    # macOS entitlements, deployment target, app icon, and native dark full-size window
    macos_runner = ROOT / "macos" / "Runner"
    if macos_runner.exists():
        _replace_xcassets_icons(
            macos_runner / "Assets.xcassets" / "AppIcon.appiconset",
            MACOS_ICON_DIR if MACOS_ICON_DIR.exists() else (OPAQUE_ICON if OPAQUE_ICON.exists() else LOGO_MARK),
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
            # NSOpenPanel / NSSavePanel require user-selected file access under App Sandbox
            if "com.apple.security.files.user-selected.read-write" not in text:
                text = text.replace(
                    "</dict>",
                    "  <key>com.apple.security.files.user-selected.read-write</key>\n  <true/>\n</dict>",
                )
            # Release distributions must never carry the debug get-task-allow entitlement.
            if ent.name == "Release.entitlements":
                text = re.sub(
                    r"\s*<key>com\.apple\.security\.get-task-allow</key>\s*<(?:true|false)\s*/>\s*",
                    "\n",
                    text,
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
            if "private var marcoWindowObservers:" not in swift_text:
                anchor = (
                    "  private var playbackActivity: NSObjectProtocol?"
                    if "  private var playbackActivity: NSObjectProtocol?" in swift_text
                    else "class MainFlutterWindow: NSWindow {"
                )
                swift_text = swift_text.replace(
                    anchor,
                    anchor + "\n"
                    "  private var marcoWindowObservers: [NSObjectProtocol] = []\n"
                    "  private var marcoInFullscreenTransition = false\n"
                    "  private var marcoIsMiniaturizing = false\n"
                    "  private var marcoIsClosing = false\n"
                    "  private var marcoRestoredFromSaved = false\n"
                    "  private var marcoLastNormalFrame: NSRect?\n\n"
                    "  deinit {\n"
                    "    for observer in marcoWindowObservers {\n"
                    "      NotificationCenter.default.removeObserver(observer)\n"
                    "    }\n"
                    "    marcoWindowObservers.removeAll()\n"
                    "  }",
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
            if "marco_movie/macos_window" not in swift_text and "RegisterGeneratedPlugins(registry: flutterViewController)" in swift_text:
                swift_text = swift_text.replace(
                    "RegisterGeneratedPlugins(registry: flutterViewController)",
                    "RegisterGeneratedPlugins(registry: flutterViewController)"
                    + MACOS_WINDOW_CHANNEL_SNIPPET,
                    1,
                )
            if "marco_movie/web_sniffer" not in swift_text and "RegisterGeneratedPlugins(registry: flutterViewController)" in swift_text:
                swift_text = swift_text.replace(
                    "RegisterGeneratedPlugins(registry: flutterViewController)",
                    "RegisterGeneratedPlugins(registry: flutterViewController)"
                    + MACOS_WEB_SNIFFER_CHANNEL_SNIPPET,
                    1,
                )
            if "self.marcoRestoreInitialFrame()" not in swift_text:
                if "titlebarAppearsTransparent" in swift_text:
                    swift_text = re.sub(
                        r"self\.titleVisibility = \.hidden.*?super\.awakeFromNib\(\)",
                        "self.isRestorable = false\n"
                        "    self.titleVisibility = .hidden\n"
                        "    self.titlebarAppearsTransparent = true\n"
                        "    self.styleMask.insert(.fullSizeContentView)\n"
                        "    self.minSize = NSSize(width: 720, height: 520)\n"
                        "    self.marcoRestoreInitialFrame()\n"
                        "    super.awakeFromNib()\n"
                        "    self.marcoEnsureWindowChromeVisible()\n"
                        "    self.marcoInstallWindowObservers()",
                        swift_text,
                        count=1,
                        flags=re.DOTALL,
                    )
                else:
                    swift_text = swift_text.replace(
                        "super.awakeFromNib()",
                        "self.isRestorable = false\n"
                        "    self.titleVisibility = .hidden\n"
                        "    self.titlebarAppearsTransparent = true\n"
                        "    self.styleMask.insert(.fullSizeContentView)\n"
                        "    self.minSize = NSSize(width: 720, height: 520)\n"
                        "    self.marcoRestoreInitialFrame()\n"
                        "    super.awakeFromNib()\n"
                        "    self.marcoEnsureWindowChromeVisible()\n"
                        "    self.marcoInstallWindowObservers()",
                        1,
                    )
            if "private final class HeadlessMediaWebSniffer" not in swift_text:
                swift_text = swift_text.rstrip() + "\n" + APPLE_WEB_SNIFFER_SWIFT
            if "extension MainFlutterWindow {" not in swift_text:
                swift_text = swift_text.rstrip() + "\n" + MACOS_WINDOW_EXTENSION_SWIFT
            window_swift.write_text(swift_text, encoding="utf-8")
    macos_podfile = ROOT / "macos" / "Podfile"
    if macos_podfile.exists():
        text = macos_podfile.read_text(encoding="utf-8")
        text = re.sub(
            r"#?\s*platform\s+:osx\s*,\s*'[^']+'",
            "platform :osx, '11.0'",
            text,
        )
        mpv_upgrade_marker = "# MarcoMovie: upgrade media_kit macOS libmpv to v0.7.3 (enables FFmpeg pgssub Blu-ray PGS decoder)"
        if mpv_upgrade_marker not in text and "flutter_install_all_macos_pods" in text:
            mpv_upgrade_ruby = (
                f"  {mpv_upgrade_marker}\n"
                "  begin\n"
                "    require 'fileutils'\n"
                "    mk_macos_dir = File.expand_path('Flutter/ephemeral/.symlinks/plugins/media_kit_libs_macos_video/macos', __dir__)\n"
                "    mk_makefile = File.join(mk_macos_dir, 'Makefile')\n"
                "    if File.exist?(mk_makefile)\n"
                "      mk_src = File.read(mk_makefile)\n"
                "      target_ver = 'v0.7.3'\n"
                "      target_sha = '2e58ac66b0ea875239bf4db29b3ef2100a719df1d61fa1e780c38d651d4c9f27'\n"
                "      unless mk_src.include?(\"MPV_XCFRAMEWORKS_VERSION=#{target_ver}\")\n"
                "        mk_src = mk_src.sub(/^MPV_XCFRAMEWORKS_VERSION=.*$/, \"MPV_XCFRAMEWORKS_VERSION=#{target_ver}\")\n"
                "        mk_src = mk_src.sub(/^MPV_XCFRAMEWORKS_SHA256SUM=.*$/, \"MPV_XCFRAMEWORKS_SHA256SUM=#{target_sha}\")\n"
                "        File.write(mk_makefile, mk_src)\n"
                "        Dir.glob(File.join(mk_macos_dir, 'Frameworks', '*.xcframework')).each { |p| FileUtils.rm_rf(p) }\n"
                "        FileUtils.rm_rf(File.join(mk_macos_dir, 'Frameworks', '.symlinks'))\n"
                "        Pod::UI.puts(\"MarcoMovie: upgraded media_kit macOS libmpv to #{target_ver} (pgssub enabled)\")\n"
                "      end\n"
                "    end\n"
                "  rescue => e\n"
                "    Pod::UI.warn(\"MarcoMovie: skipped libmpv v0.7.3 upgrade: #{e}\")\n"
                "  end\n\n"
            )
            text = re.sub(
                r"(^\s*flutter_install_all_macos_pods\b)",
                lambda m: mpv_upgrade_ruby + m.group(1),
                text,
                count=1,
                flags=re.MULTILINE,
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
    _upgrade_macos_media_kit_mpv_v073()
    # iOS Info.plist, deployment target, and opaque AppIcon set
    ios_runner = ROOT / "ios" / "Runner"
    if ios_runner.exists():
        _replace_xcassets_icons(
            ios_runner / "Assets.xcassets" / "AppIcon.appiconset",
            IOS_ICON if IOS_ICON.exists() else (OPAQUE_ICON if OPAQUE_ICON.exists() else LOGO_MARK),
        )
        ios_plist = ios_runner / "Info.plist"
        if ios_plist.exists():
            info = plistlib.loads(ios_plist.read_bytes())
            info.update({
                'CFBundleDisplayName': 'Marco Movie',
                'CFBundleAllowMixedLocalizations': True,
                'UIStatusBarStyle': 'UIStatusBarStyleDefault',
                'UIViewControllerBasedStatusBarAppearance': True,
                # Unlock iPhone Duo dynamic fold/unfold resizing, Split View multitasking,
                # and free window sizing on iPadOS / iOS 27.1+.
                'UIRequiresFullScreen': False,
                'NSLocalNetworkUsageDescription': '用于发现局域网投屏电视（DLNA/AirPlay）及连接局域网 Emby 服务器与片源。',
                'NSBonjourServices': [
                    '_marcomovie-cast._tcp',
                    '_airplay._tcp',
                    '_raop._tcp',
                    '_lelink._tcp',
                    '_lebo._tcp',
                    '_googlecast._tcp',
                    '_dlna._tcp',
                    '_upnp._tcp',
                    '_http._tcp',
                ],
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
            bg_modes = list(info.get('UIBackgroundModes') or [])
            if 'audio' not in bg_modes:
                bg_modes.append('audio')
            info['UIBackgroundModes'] = bg_modes
            info.setdefault('UILaunchStoryboardName', 'LaunchScreen')
            info.setdefault('UISupportedInterfaceOrientations', [
                'UIInterfaceOrientationPortrait',
                'UIInterfaceOrientationLandscapeLeft',
                'UIInterfaceOrientationLandscapeRight',
            ])
            info.setdefault('UISupportedInterfaceOrientations~ipad', [
                'UIInterfaceOrientationPortrait',
                'UIInterfaceOrientationPortraitUpsideDown',
                'UIInterfaceOrientationLandscapeLeft',
                'UIInterfaceOrientationLandscapeRight',
            ])
            # Preserve Flutter 3.47+ generated UIScene manifests verbatim; only add a
            # scene manifest when SceneDelegate.swift is actually present in the runner.
            # Injecting FlutterSceneDelegate onto a classic Flutter 3.38 AppDelegate
            # runner breaks iOS 14 & iPad cold launch (window nil / black screen).
            if (ios_runner / 'SceneDelegate.swift').exists():
                info.setdefault('UIApplicationSceneManifest', {
                    'UIApplicationSupportsMultipleScenes': False,
                    'UISceneConfigurations': {
                        'UIWindowSceneSessionRoleApplication': [
                            {
                                'UISceneClassName': 'UIWindowScene',
                                'UISceneConfigurationName': 'flutter',
                                'UISceneDelegateClassName': '$(PRODUCT_MODULE_NAME).SceneDelegate',
                                'UISceneStoryboardFile': 'Main',
                            },
                        ],
                    },
                })
            info.setdefault('NSAppTransportSecurity', {})['NSAllowsArbitraryLoads'] = True
            ios_plist.write_bytes(plistlib.dumps(info, sort_keys=False))
        ios_storyboard = ios_runner / "Base.lproj" / "Main.storyboard"
        if ios_storyboard.exists():
            sb_text = ios_storyboard.read_text(encoding="utf-8")
            orig_sb = sb_text
            if 'customClass="FlutterViewController"' in sb_text:
                sb_text = sb_text.replace(
                    'customClass="FlutterViewController"',
                    'customClass="MarcoFlutterViewController" customModule="Runner" customModuleProvider="target"',
                )
            sb_text = _patch_ios_storyboard_adaptive_bg(sb_text)
            if sb_text != orig_sb:
                ios_storyboard.write_text(sb_text, encoding="utf-8")
        _install_ios_branded_launch_screen(
            ios_runner,
            LOGO_MARK if LOGO_MARK.exists() else (IOS_ICON if IOS_ICON.exists() else OPAQUE_ICON),
        )
        ios_app_delegate = ios_runner / "AppDelegate.swift"
        if ios_app_delegate.exists():
            ad_text = ios_app_delegate.read_text(encoding="utf-8")
            ad_changed = False
            ad_text, imports_changed = _ensure_ios_appdelegate_imports(ad_text)
            if imports_changed:
                ad_changed = True
            ad_text, reg_changed = _upsert_ios_appdelegate_registration(ad_text)
            if reg_changed:
                ad_changed = True
            ad_text, registrar_changed = _upsert_swift_generated_block(
                ad_text,
                "ios_channel_registrar",
                r"private\s+enum\s+MarcoNativeChannelRegistrar\s*\{",
                IOS_NATIVE_CHANNEL_REGISTRAR_SWIFT,
            )
            if registrar_changed:
                ad_changed = True
            ad_text, vc_changed = _upsert_swift_generated_block(
                ad_text,
                "ios_flutter_view_controller",
                r"(?:@objc\(MarcoFlutterViewController\)\s*\n[ \t]*)?final\s+class\s+MarcoFlutterViewController\s*:\s*FlutterViewController\s*\{",
                IOS_FLUTTER_VIEW_CONTROLLER_SWIFT,
            )
            if vc_changed:
                ad_changed = True
            ad_text, netdisk_changed = _upsert_swift_generated_section(
                ad_text,
                "ios_netdisk_auth",
                r"^(?:private\s+final\s+class\s+WeakScriptMessageHandler\b|final\s+class\s+NetdiskWebAuthController\b)",
                (
                    r"^// MARCO_GENERATED_BEGIN:",
                    r"^// MARK: - iOS WKWebView Rule Sniffer",
                    r"^private\s+enum\s+MarcoWebSnifferAndJsHostRegistrar\s*\{",
                ),
                IOS_NETDISK_AUTH_CONTROLLER_SWIFT,
            )
            if netdisk_changed:
                ad_changed = True
            if IOS_WEB_SNIFFER_JS_HOST_SWIFT_PATH.is_file():
                # Strip any legacy APPLE_WEB_SNIFFER_SWIFT block before upgrading sniffer & JS host.
                if "private enum MarcoWebSnifferAndJsHostRegistrar" not in ad_text:
                    legacy_sniffer_re = re.compile(
                        r"\n*private final class WeakSnifferScriptHandler:.*?private final class HeadlessMediaWebSniffer:.*?\n\}\s*",
                        re.DOTALL,
                    )
                    if legacy_sniffer_re.search(ad_text):
                        ad_text = legacy_sniffer_re.sub("\n", ad_text)
                        ad_changed = True
                ad_text, sniffer_changed = _upsert_swift_generated_section(
                    ad_text,
                    "ios_web_sniffer_js_host",
                    r"^(?:(?:// MARK: - iOS WKWebView Rule Sniffer[^\n]*\n)(?://[^\n]*\n)*\s*)?private\s+enum\s+MarcoWebSnifferAndJsHostRegistrar\s*\{",
                    (
                        r"^// MARCO_GENERATED_BEGIN:",
                        r"^// MARK: - iOS 14\+ Native Low-Power AVPlayer Engine",
                        r"^enum\s+MarcoAvPlayerEngine\s*\{",
                        r"^// MARK: - iOS 26 Native Liquid Glass Bridge",
                        r"^private\s+enum\s+MarcoLiquidGlassSupport\s*\{",
                    ),
                    IOS_WEB_SNIFFER_JS_HOST_SWIFT_PATH.read_text(encoding="utf-8"),
                )
                if sniffer_changed:
                    ad_changed = True
            if IOS_AVPLAYER_ENGINE_SWIFT_PATH.is_file():
                ad_text, av_changed = _upsert_swift_generated_section(
                    ad_text,
                    "ios_avplayer_engine",
                    r"^(?:(?:// MARK: - iOS 14\+ Native Low-Power AVPlayer Engine[^\n]*\n)(?://[^\n]*\n)*\s*)?enum\s+MarcoAvPlayerEngine\s*\{",
                    (
                        r"^// MARCO_GENERATED_BEGIN:",
                        r"^// MARK: - iOS 26 Native Liquid Glass Bridge",
                        r"^private\s+enum\s+MarcoLiquidGlassSupport\s*\{",
                    ),
                    IOS_AVPLAYER_ENGINE_SWIFT_PATH.read_text(encoding="utf-8"),
                )
                if av_changed:
                    ad_changed = True
            if IOS_LIQUID_GLASS_SWIFT_PATH.is_file():
                ad_text, lg_changed = _upsert_swift_generated_section(
                    ad_text,
                    "ios_liquid_glass",
                    r"^(?:(?:// MARK: - iOS 26 Native Liquid Glass Bridge[^\n]*\n)(?://[^\n]*\n)*\s*)?private\s+enum\s+MarcoLiquidGlassSupport\s*\{",
                    (r"^// MARCO_GENERATED_BEGIN:",),
                    IOS_LIQUID_GLASS_SWIFT_PATH.read_text(encoding="utf-8"),
                    retired_declarations=("MarcoWrapChipContainerView",),
                )
                if lg_changed:
                    ad_changed = True
            if ad_changed:
                ios_app_delegate.write_text(ad_text, encoding="utf-8")
    min_ios = os.environ.get("MARCOMOVIE_IOS_MIN_TARGET", "14.0").strip()
    if min_ios not in ("14.0", "15.0"):
        min_ios = "14.0"
    needs_ios14_linker_compat = min_ios == "14.0"

    ios_app_fw_plist = ROOT / "ios" / "Flutter" / "AppFrameworkInfo.plist"
    if ios_app_fw_plist.exists():
        text = ios_app_fw_plist.read_text(encoding="utf-8")
        text = re.sub(
            r"(<key>MinimumOSVersion</key>\s*<string>)[^<]+(</string>)",
            rf"\g<1>{min_ios}\g<2>",
            text,
        )
        ios_app_fw_plist.write_text(text, encoding="utf-8")
    for xcconfig_name in ("Release.xcconfig", "Debug.xcconfig", "Profile.xcconfig"):
        xcconfig = ROOT / "ios" / "Flutter" / xcconfig_name
        if xcconfig.exists():
            text = xcconfig.read_text(encoding="utf-8")
            text = re.sub(
                r"(?m)^IPHONEOS_DEPLOYMENT_TARGET\s*=.*$",
                f"IPHONEOS_DEPLOYMENT_TARGET = {min_ios}",
                text,
            )
            if f"IPHONEOS_DEPLOYMENT_TARGET = {min_ios}" not in text:
                text = text.rstrip() + f"\nIPHONEOS_DEPLOYMENT_TARGET = {min_ios}\n"
            if needs_ios14_linker_compat:
                if "-Wl,-no_fixup_chains" not in text:
                    text = text.rstrip() + "\nOTHER_LDFLAGS = $(inherited) -Wl,-no_fixup_chains\n"
                if "-fno-objc-msgsend-selector-stubs" not in text:
                    text = text.rstrip() + "\nOTHER_CFLAGS = $(inherited) -fno-objc-msgsend-selector-stubs\n"
            else:
                text = re.sub(
                    r"(?m)^OTHER_LDFLAGS\s*=\s*\$\(inherited\)\s+-Wl,-no_fixup_chains\s*$\n?",
                    "",
                    text,
                )
                text = re.sub(
                    r"(?m)^OTHER_CFLAGS\s*=\s*\$\(inherited\)\s+-fno-objc-msgsend-selector-stubs\s*$\n?",
                    "",
                    text,
                )
            xcconfig.write_text(text, encoding="utf-8")
    ios_pbx = ROOT / "ios" / "Runner.xcodeproj" / "project.pbxproj"
    if ios_pbx.exists():
        text = ios_pbx.read_text(encoding="utf-8")
        text = re.sub(
            r"IPHONEOS_DEPLOYMENT_TARGET\s*=\s*[0-9.]+;",
            f"IPHONEOS_DEPLOYMENT_TARGET = {min_ios};",
            text,
        )
        ios_pbx.write_text(text, encoding="utf-8")
    ios_podfile = ROOT / "ios" / "Podfile"
    if ios_podfile.exists():
        text = ios_podfile.read_text(encoding="utf-8")
        text = re.sub(
            r"#?\s*platform\s+:ios\s*,\s*'[^']+'",
            f"platform :ios, '{min_ios}'",
            text,
        )
        if f"Gem::Version.new('{min_ios}')" not in text and "flutter_additional_ios_build_settings(target)" in text:
            extra_flags = ""
            if needs_ios14_linker_compat:
                extra_flags = (
                    "      ldflags = Array(config.build_settings['OTHER_LDFLAGS'] || '$(inherited)')\n"
                    "      ldflags << '-Wl,-no_fixup_chains' unless ldflags.any? { |f| f.to_s.include?('no_fixup_chains') }\n"
                    "      config.build_settings['OTHER_LDFLAGS'] = ldflags\n"
                    "      cflags = Array(config.build_settings['OTHER_CFLAGS'] || '$(inherited)')\n"
                    "      cflags << '-fno-objc-msgsend-selector-stubs' unless cflags.any? { |f| f.to_s.include?('fno-objc-msgsend-selector-stubs') }\n"
                    "      config.build_settings['OTHER_CFLAGS'] = cflags\n"
                )
            text = text.replace(
                "flutter_additional_ios_build_settings(target)",
                "flutter_additional_ios_build_settings(target)\n"
                "    target.build_configurations.each do |config|\n"
                f"      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '{min_ios}' if Gem::Version.new(config.build_settings.fetch('IPHONEOS_DEPLOYMENT_TARGET', '0')) < Gem::Version.new('{min_ios}')\n"
                + extra_flags
                + "    end",
            )
        ios_podfile.write_text(text, encoding="utf-8")
    # Windows icon, working directory, immediate window show, and title
    win_runner = ROOT / "windows" / "runner"
    win_native_dir = ROOT / "windows_native"
    if win_runner.exists() and win_native_dir.exists():
        for fname in (
            "marco_webview2_plugin.h",
            "marco_webview2_plugin.cpp",
            "CMakeFragment.cmake",
        ):
            src_file = win_native_dir / fname
            if src_file.is_file():
                shutil.copy2(src_file, win_runner / fname)
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
    win_fw_h = win_runner / "flutter_window.h"
    if win_fw_h.exists():
        h_text = win_fw_h.read_text(encoding="utf-8")
        h_changed = False
        if "tray_channel_" not in h_text:
            if "<shellapi.h>" not in h_text:
                h_text = h_text.replace(
                    "#include <memory>",
                    "#include <flutter/method_channel.h>\n"
                    "#include <flutter/standard_method_codec.h>\n"
                    "#include <shellapi.h>\n\n"
                    "#include <memory>\n"
                    "#include <string>",
                    1,
                )
            h_text = h_text.replace(
                "  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;",
                "  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;\n"
                "  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> tray_channel_;\n"
                "  NOTIFYICONDATAW tray_data_{};\n"
                "  bool tray_icon_added_ = false;\n"
                "  UINT taskbar_created_msg_ = 0;\n"
                "  static constexpr UINT kTrayCallbackMsg = WM_APP + 101;\n"
                "  static constexpr UINT kTrayMenuRestoreId = 1001;\n"
                "  static constexpr UINT kTrayMenuQuitId = 1002;\n\n"
                "  bool AddTrayIcon(const std::wstring& tooltip);\n"
                "  void RemoveTrayIcon();\n"
                "  void RestoreFromTray();\n"
                "  void ShowTrayContextMenu(HWND hwnd);",
                1,
            )
            h_changed = True
        if h_changed:
            win_fw_h.write_text(h_text, encoding="utf-8")
    if win_fw_h.exists():
        h_text = win_fw_h.read_text(encoding="utf-8")
        h_changed = False
        if '#include "marco_webview2_plugin.h"' not in h_text and '#include "win32_window.h"' in h_text:
            h_text = h_text.replace(
                '#include "win32_window.h"',
                '#include "win32_window.h"\n#include "marco_webview2_plugin.h"',
                1,
            )
            h_changed = True
        if "webview2_plugin_" not in h_text and "flutter_controller_;" in h_text:
            h_text = h_text.replace(
                "  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;",
                "  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;\n"
                "  std::unique_ptr<marco::MarcoWebview2Plugin> webview2_plugin_;",
                1,
            )
            h_changed = True
        if h_changed:
            win_fw_h.write_text(h_text, encoding="utf-8")
    win_fw = win_runner / "flutter_window.cpp"
    if win_fw.exists():
        text = win_fw.read_text(encoding="utf-8")
        changed = False
        if '"resource.h"' not in text:
            text = text.replace(
                '#include "flutter_window.h"',
                '#include "flutter_window.h"\n#include "resource.h"',
                1,
            )
            changed = True
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
        if "marco_movie/windows_tray" not in text and "RegisterPlugins(flutter_controller_->engine());" in text:
            tray_setup = (
                "  taskbar_created_msg_ = ::RegisterWindowMessageW(L\"TaskbarCreated\");\n"
                "  tray_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(\n"
                "      flutter_controller_->engine()->messenger(), \"marco_movie/windows_tray\",\n"
                "      &flutter::StandardMethodCodec::GetInstance());\n"
                "  tray_channel_->SetMethodCallHandler(\n"
                "      [this](const flutter::MethodCall<flutter::EncodableValue>& call,\n"
                "             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {\n"
                "        if (call.method_name() == \"hideToTray\") {\n"
                "          std::wstring tip = L\"Marco Movie\";\n"
                "          if (const auto* map = std::get_if<flutter::EncodableMap>(call.arguments())) {\n"
                "            auto it = map->find(flutter::EncodableValue(\"tooltip\"));\n"
                "            if (it != map->end()) {\n"
                "              if (const auto* utf8 = std::get_if<std::string>(&it->second); utf8 && !utf8->empty()) {\n"
                "                int needed = ::MultiByteToWideChar(CP_UTF8, 0, utf8->c_str(), -1, nullptr, 0);\n"
                "                if (needed > 1) {\n"
                "                  std::wstring converted(static_cast<size_t>(needed - 1), L'\\0');\n"
                "                  ::MultiByteToWideChar(CP_UTF8, 0, utf8->c_str(), -1, converted.data(), needed);\n"
                "                  tip = converted;\n"
                "                }\n"
                "              }\n"
                "            }\n"
                "          }\n"
                "          bool ok = AddTrayIcon(tip);\n"
                "          if (ok && GetHandle()) {\n"
                "            ::ShowWindow(GetHandle(), SW_HIDE);\n"
                "          }\n"
                "          result->Success(flutter::EncodableValue(ok));\n"
                "        } else if (call.method_name() == \"showFromTray\") {\n"
                "          RestoreFromTray();\n"
                "          result->Success(flutter::EncodableValue(true));\n"
                "        } else if (call.method_name() == \"removeTray\") {\n"
                "          RemoveTrayIcon();\n"
                "          result->Success(flutter::EncodableValue(true));\n"
                "        } else {\n"
                "          result->NotImplemented();\n"
                "        }\n"
                "      });\n"
            )
            text = text.replace(
                "  SetChildContent(flutter_controller_->view()->GetNativeWindow());",
                tray_setup + "  SetChildContent(flutter_controller_->view()->GetNativeWindow());",
                1,
            )
            changed = True
        if "tray_channel_.reset();" not in text and "void FlutterWindow::OnDestroy()" in text:
            text = text.replace(
                "void FlutterWindow::OnDestroy() {",
                "void FlutterWindow::OnDestroy() {\n"
                "  RemoveTrayIcon();\n"
                "  tray_channel_.reset();",
                1,
            )
            changed = True
        if "case kTrayCallbackMsg:" not in text and "switch (message) {" in text:
            text = text.replace(
                "  switch (message) {",
                "  if (taskbar_created_msg_ != 0 && message == taskbar_created_msg_ && tray_icon_added_) {\n"
                "    ::Shell_NotifyIconW(NIM_ADD, &tray_data_);\n"
                "    return 0;\n"
                "  }\n\n"
                "  switch (message) {\n"
                "    case kTrayCallbackMsg: {\n"
                "      const UINT evt = LOWORD(lparam);\n"
                "      if (evt == WM_LBUTTONUP || evt == WM_LBUTTONDBLCLK) {\n"
                "        RestoreFromTray();\n"
                "        return 0;\n"
                "      }\n"
                "      if (evt == WM_RBUTTONUP || evt == WM_CONTEXTMENU) {\n"
                "        ShowTrayContextMenu(hwnd);\n"
                "        return 0;\n"
                "      }\n"
                "      return 0;\n"
                "    }",
                1,
            )
            changed = True
        if "bool FlutterWindow::AddTrayIcon(" not in text:
            text = (
                text.rstrip()
                + "\n\n"
                + "bool FlutterWindow::AddTrayIcon(const std::wstring& tooltip) {\n"
                + "  HWND hwnd = GetHandle();\n"
                + "  if (!hwnd) {\n"
                + "    return false;\n"
                + "  }\n"
                + "  if (tray_icon_added_) {\n"
                + "    wcsncpy_s(tray_data_.szTip,\n"
                + "              tooltip.empty() ? L\"Marco Movie\" : tooltip.c_str(), _TRUNCATE);\n"
                + "    ::Shell_NotifyIconW(NIM_MODIFY, &tray_data_);\n"
                + "    return true;\n"
                + "  }\n"
                + "  tray_data_ = {};\n"
                + "  tray_data_.cbSize = sizeof(NOTIFYICONDATAW);\n"
                + "  tray_data_.hWnd = hwnd;\n"
                + "  tray_data_.uID = 1;\n"
                + "  tray_data_.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;\n"
                + "  tray_data_.uCallbackMessage = kTrayCallbackMsg;\n"
                + "  tray_data_.hIcon = ::LoadIconW(::GetModuleHandleW(nullptr),\n"
                + "                                 MAKEINTRESOURCEW(IDI_APP_ICON));\n"
                + "  if (!tray_data_.hIcon) {\n"
                + "    tray_data_.hIcon = ::LoadIconW(nullptr, IDI_APPLICATION);\n"
                + "  }\n"
                + "  wcsncpy_s(tray_data_.szTip,\n"
                + "            tooltip.empty() ? L\"Marco Movie\" : tooltip.c_str(), _TRUNCATE);\n"
                + "  tray_icon_added_ = (::Shell_NotifyIconW(NIM_ADD, &tray_data_) == TRUE);\n"
                + "  return tray_icon_added_;\n"
                + "}\n\n"
                + "void FlutterWindow::RemoveTrayIcon() {\n"
                + "  if (tray_icon_added_) {\n"
                + "    ::Shell_NotifyIconW(NIM_DELETE, &tray_data_);\n"
                + "    tray_icon_added_ = false;\n"
                + "  }\n"
                + "}\n\n"
                + "void FlutterWindow::RestoreFromTray() {\n"
                + "  RemoveTrayIcon();\n"
                + "  HWND hwnd = GetHandle();\n"
                + "  if (hwnd) {\n"
                + "    ::ShowWindow(hwnd, SW_SHOW);\n"
                + "    if (::IsIconic(hwnd)) {\n"
                + "      ::ShowWindow(hwnd, SW_RESTORE);\n"
                + "    }\n"
                + "    ::SetForegroundWindow(hwnd);\n"
                + "  }\n"
                + "  if (tray_channel_) {\n"
                + "    tray_channel_->InvokeMethod(\"restore\", nullptr);\n"
                + "  }\n"
                + "}\n\n"
                + "void FlutterWindow::ShowTrayContextMenu(HWND hwnd) {\n"
                + "  HMENU menu = ::CreatePopupMenu();\n"
                + "  if (!menu) {\n"
                + "    return;\n"
                + "  }\n"
                + "  ::AppendMenuW(menu, MF_STRING, kTrayMenuRestoreId,\n"
                + "                L\"\\u663e\\u793a Marco Movie\");\n"
                + "  ::AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);\n"
                + "  ::AppendMenuW(menu, MF_STRING, kTrayMenuQuitId,\n"
                + "                L\"\\u9000\\u51fa Marco Movie\");\n"
                + "  ::SetMenuDefaultItem(menu, kTrayMenuRestoreId, FALSE);\n"
                + "  POINT pt{};\n"
                + "  ::GetCursorPos(&pt);\n"
                + "  ::SetForegroundWindow(hwnd);\n"
                + "  UINT cmd = static_cast<UINT>(::TrackPopupMenu(\n"
                + "      menu, TPM_RETURNCMD | TPM_RIGHTBUTTON | TPM_NONOTIFY,\n"
                + "      pt.x, pt.y, 0, hwnd, nullptr));\n"
                + "  ::PostMessageW(hwnd, WM_NULL, 0, 0);\n"
                + "  ::DestroyMenu(menu);\n"
                + "  if (cmd == kTrayMenuRestoreId) {\n"
                + "    RestoreFromTray();\n"
                + "  } else if (cmd == kTrayMenuQuitId) {\n"
                + "    RemoveTrayIcon();\n"
                + "    if (tray_channel_) {\n"
                + "      tray_channel_->InvokeMethod(\"quit\", nullptr);\n"
                + "    } else {\n"
                + "      ::PostMessageW(hwnd, WM_CLOSE, 0, 0);\n"
                + "    }\n"
                + "  }\n"
                + "}\n"
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
        if "webview2_plugin_ = " not in text and "RegisterPlugins(flutter_controller_->engine());" in text:
            text = text.replace(
                "RegisterPlugins(flutter_controller_->engine());",
                "RegisterPlugins(flutter_controller_->engine());\n"
                "  webview2_plugin_ = std::make_unique<marco::MarcoWebview2Plugin>(\n"
                "      flutter_controller_->engine()->messenger(), GetHandle());",
                1,
            )
            changed = True
        if "webview2_plugin_->Shutdown()" not in text and "void FlutterWindow::OnDestroy()" in text:
            text = text.replace(
                "void FlutterWindow::OnDestroy() {",
                "void FlutterWindow::OnDestroy() {\n"
                "  if (webview2_plugin_) {\n"
                "    webview2_plugin_->Shutdown();\n"
                "    webview2_plugin_.reset();\n"
                "  }",
                1,
            )
            changed = True
        if changed:
            win_fw.write_text(text, encoding="utf-8")
    win_runner_cmake = win_runner / "CMakeLists.txt"
    if win_runner_cmake.exists():
        cmake_text = win_runner_cmake.read_text(encoding="utf-8")
        cmake_changed = False
        if '"shell32.lib"' not in cmake_text and '"dwmapi.lib"' in cmake_text:
            cmake_text = cmake_text.replace(
                'target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")',
                'target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib" "shell32.lib")',
                1,
            )
            cmake_changed = True
        if "CMakeFragment.cmake" not in cmake_text and (win_runner / "CMakeFragment.cmake").is_file():
            cmake_text = cmake_text.rstrip() + "\n\ninclude(CMakeFragment.cmake)\n"
            cmake_changed = True
        if cmake_changed:
            win_runner_cmake.write_text(cmake_text, encoding="utf-8")

if __name__ == "__main__":
    main()
