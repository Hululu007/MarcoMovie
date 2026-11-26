// MARK: - iOS 26 Native Liquid Glass Bridge (injected into AppDelegate.swift by prepare_platform.py)

private enum MarcoLiquidGlassSupport {
  static var bridgeChannel: FlutterMethodChannel?
  static var brandLogoImage: UIImage?
  static var interfaceStyle: UIUserInterfaceStyle = .unspecified
  static var glassIntensity: CGFloat = 0.68
  static var isSceneActive: Bool = true
  static let appearanceChangedNotification = Notification.Name("MarcoLiquidGlassAppearanceChanged")
  static let glassIntensityChangedNotification = Notification.Name("MarcoLiquidGlassIntensityChanged")
  static let windowGeometryChangedNotification = Notification.Name("MarcoWindowGeometryChanged")
  static let sceneActivationChangedNotification = Notification.Name("MarcoSceneActivationChanged")
  private static var accessibilityObservers: [NSObjectProtocol] = []
  private static var hiddenAirPlayPicker: AVRoutePickerView?
  private static var activeMenuButtons: Set<ObjectIdentifier> = []

  /// Resolves the active UIWindow across UIScene / iPhone Duo fold-unfold / Split View
  /// without touching the deprecated `UIScreen.main` global.
  static func activeWindow(for view: UIView? = nil) -> UIWindow? {
    if let win = view?.window {
      return win
    }
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let activeScene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
    if let keyWin = activeScene?.windows.first(where: { $0.isKeyWindow }) {
      return keyWin
    }
    if let anyKey = scenes.flatMap({ $0.windows }).first(where: { $0.isKeyWindow }) {
      return anyKey
    }
    return activeScene?.windows.first
      ?? scenes.flatMap({ $0.windows }).first
      ?? (UIApplication.shared.delegate?.window ?? nil)
  }

  static func activeWindowBounds(for view: UIView? = nil) -> CGRect {
    if let win = activeWindow(for: view), win.bounds.width > 0, win.bounds.height > 0 {
      return win.bounds
    }
    if let v = view, v.bounds.width > 0, v.bounds.height > 0 {
      return v.bounds
    }
    return CGRect(x: 0.0, y: 0.0, width: 390.0, height: 844.0)
  }

  static func notifyWindowGeometryChanged(size: CGSize) {
    NotificationCenter.default.post(
      name: windowGeometryChangedNotification,
      object: nil,
      userInfo: ["width": size.width, "height": size.height]
    )
  }

  /// Keeps the root Liquid Glass Dock / Logo overlay above dynamically mounted
  /// Flutter `UiKitView`s inside `rootVC.view` while preserving `rootVC` in the
  /// responder chain so `logoButton.showsMenuAsPrimaryAction` presents natively.
  /// Strictly a no-op on iOS < 26 or before `configureRootTabChrome` succeeds so
  /// an unconfigured native overlay can never appear on iOS 14–25.
  static func bringRootChromeToFront() {
    guard isAvailable, let controller = MarcoIos27RootTabChromeController.existingInstance else {
      return
    }
    controller.bringToFrontIfNeeded()
  }

  static var isEffectiveDark: Bool {
    return isEffectiveDark(for: nil)
  }

  static func isEffectiveDark(for view: UIView?) -> Bool {
    switch interfaceStyle {
    case .dark:
      return true
    case .light:
      return false
    default:
      if let v = view, v.traitCollection.userInterfaceStyle != .unspecified {
        return v.traitCollection.userInterfaceStyle == .dark
      }
      if let win = activeWindow(), win.traitCollection.userInterfaceStyle != .unspecified {
        return win.traitCollection.userInterfaceStyle == .dark
      }
      return UITraitCollection.current.userInterfaceStyle == .dark
    }
  }

  static func adaptiveGlassForeground(for view: UIView?, forceDark: Bool = false) -> UIColor {
    let dark = forceDark || isEffectiveDark(for: view)
    return dark ? .white : UIColor(red: 0.08, green: 0.09, blue: 0.12, alpha: 0.94)
  }

  private static func restyleNativeViews(in view: UIView, style: UIUserInterfaceStyle) {
    if view.tag == 99001 {
      // Forced-dark media overlay subtree (Detail / Hero / Player): keep .dark intact.
      return
    }
    // Never mutate FlutterView / Metal surface layers during cold launch on iPadOS/iOS.
    let className = NSStringFromClass(type(of: view))
    if !className.contains("Flutter") && view.overrideUserInterfaceStyle != style {
      view.overrideUserInterfaceStyle = style
    }
    if let seg = view as? UISegmentedControl {
      let dark = isEffectiveDark(for: seg)
      seg.setTitleTextAttributes(
        [
          .foregroundColor: dark ? UIColor.white.withAlphaComponent(0.76) : UIColor.label.withAlphaComponent(0.74),
          .font: UIFont.systemFont(ofSize: 13.0, weight: .semibold),
        ],
        for: .normal
      )
      seg.setTitleTextAttributes(
        [
          .foregroundColor: dark ? UIColor.white : UIColor.label,
          .font: UIFont.systemFont(ofSize: 13.0, weight: .semibold),
        ],
        for: .selected
      )
    }
    for sub in view.subviews {
      restyleNativeViews(in: sub, style: style)
    }
  }

  static func applyWindowAppearance(_ mode: String) {
    let style: UIUserInterfaceStyle
    switch mode.lowercased() {
    case "light":
      style = .light
    case "dark":
      style = .dark
    default:
      style = .unspecified
    }
    interfaceStyle = style
    let winBg: UIColor = isEffectiveDark
      ? UIColor.black
      : UIColor(red: 0.914, green: 0.925, blue: 0.949, alpha: 1.0)
    var visitedWindows: [UIWindow] = []
    for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
      visitedWindows.append(contentsOf: scene.windows)
    }
    if visitedWindows.isEmpty, let legacyWin = UIApplication.shared.delegate?.window ?? nil {
      visitedWindows.append(legacyWin)
    }
    for win in visitedWindows {
      win.overrideUserInterfaceStyle = style
      win.backgroundColor = winBg
      restyleNativeViews(in: win, style: style)
      if let marcoVC = win.rootViewController as? MarcoFlutterViewController {
        marcoVC.marcoPreferredInterfaceStyle = style
      }
    }
    NotificationCenter.default.post(name: appearanceChangedNotification, object: nil)
  }

  static func applyGlassIntensity(_ value: Double) {
    // Native iOS 26 UIGlassEffect manages optical refraction & legibility natively;
    // avoid tinting or adding opaque milky backgrounds over UIGlassEffect views.
    glassIntensity = CGFloat(min(max(value, 0.0), 1.0))
  }

  static func presentNativeAirPlayPicker() {
    guard let host = topPresenter() else { return }
    let bounds = host.view.bounds
    let anchorFrame = CGRect(
      x: max(8.0, bounds.midX - 22.0),
      y: max(8.0, bounds.midY - 22.0),
      width: 44.0,
      height: 44.0
    )
    let picker = hiddenAirPlayPicker ?? AVRoutePickerView(frame: anchorFrame)
    hiddenAirPlayPicker = picker
    picker.frame = anchorFrame
    picker.prioritizesVideoDevices = true
    picker.alpha = 0.001
    picker.isUserInteractionEnabled = false
    if picker.superview !== host.view {
      picker.removeFromSuperview()
      host.view.addSubview(picker)
    }
    for sub in picker.subviews {
      if let btn = sub as? UIButton {
        btn.sendActions(for: .touchUpInside)
        return
      }
    }
  }

  static func triggerFavoriteDynamicIslandFeedback(phase: String) -> [String: Any] {
    let win = activeWindow()
    let winBounds = activeWindowBounds()
    let topInset = win?.safeAreaInsets.top ?? 0.0
    let screenW = winBounds.width
    let isPhone = UIDevice.current.userInterfaceIdiom == .phone
    // Guard against iPhone Duo unfolded inner display (669pt+) where there is no
    // centered Dynamic Island cutout.
    let hasIsland = isPhone && topInset >= 52.0 && screenW < 520.0
    if phase == "shutter" {
      let medium = UIImpactFeedbackGenerator(style: .medium)
      medium.prepare()
      medium.impactOccurred(intensity: 0.9)
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.065) {
        let light = UIImpactFeedbackGenerator(style: .light)
        light.impactOccurred(intensity: 0.65)
      }
    } else if phase == "arrive" {
      let notif = UINotificationFeedbackGenerator()
      notif.prepare()
      notif.notificationOccurred(.success)
    }
    let islandW: CGFloat = 126.0
    let islandH: CGFloat = 37.0
    let islandY: CGFloat = hasIsland ? 11.0 : max(topInset + 6.0, 12.0)
    return [
      "hasDynamicIsland": hasIsland,
      "islandX": Double((screenW - islandW) * 0.5),
      "islandTop": Double(islandY),
      "islandY": Double(islandY),
      "islandWidth": Double(islandW),
      "islandHeight": Double(islandH),
    ]
  }

  static var isAvailable: Bool {
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      return true
    }
    #endif
    return false
  }

  static var isReduceTransparencyEnabled: Bool {
    return UIAccessibility.isReduceTransparencyEnabled
  }

  static var isThermalThrottled: Bool {
    let state = ProcessInfo.processInfo.thermalState
    return state == .serious || state == .critical
  }

  static var majorOSVersion: Int {
    return ProcessInfo.processInfo.operatingSystemVersion.majorVersion
  }

  static var builtWithSDK26: Bool {
    #if compiler(>=6.2)
    return true
    #else
    return false
    #endif
  }

  static func animateSpring(
    duration: TimeInterval = 0.38,
    bounce: CGFloat = 0.16,
    animations: @escaping () -> Void,
    completion: (() -> Void)? = nil
  ) {
    if UIAccessibility.isReduceMotionEnabled {
      UIView.animate(withDuration: 0.14, delay: 0.0, options: [.beginFromCurrentState, .allowUserInteraction], animations: animations) { _ in
        completion?()
      }
      return
    }
    if #available(iOS 17.0, *) {
      let timing = UISpringTimingParameters(duration: duration, bounce: bounce)
      let animator = UIViewPropertyAnimator(duration: 0.0, timingParameters: timing)
      animator.isInterruptible = true
      animator.isUserInteractionEnabled = true
      animator.addAnimations(animations)
      if let completion = completion {
        animator.addCompletion { _ in completion() }
      }
      animator.startAnimation()
    } else {
      let damping = max(0.55, min(0.98, 1.0 - bounce))
      UIView.animate(
        withDuration: duration,
        delay: 0.0,
        usingSpringWithDamping: damping,
        initialSpringVelocity: 0.6,
        options: [.beginFromCurrentState, .allowUserInteraction],
        animations: animations
      ) { _ in
        completion?()
      }
    }
  }

  private static func updateSceneActivationState() {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let active = scenes.isEmpty || scenes.contains { $0.activationState == .foregroundActive }
    if isSceneActive != active {
      isSceneActive = active
      NotificationCenter.default.post(name: sceneActivationChangedNotification, object: nil)
      bridgeChannel?.invokeMethod("sceneActivationChanged", arguments: active)
    }
  }

  private static func installAccessibilityObservers() {
    let center = NotificationCenter.default
    for token in accessibilityObservers {
      center.removeObserver(token)
    }
    accessibilityObservers.removeAll()
    let notify: (Notification) -> Void = { _ in
      DispatchQueue.main.async {
        bridgeChannel?.invokeMethod(
          "reduceTransparencyChanged",
          arguments: isReduceTransparencyEnabled
        )
      }
    }
    accessibilityObservers.append(
      center.addObserver(
        forName: UIAccessibility.reduceTransparencyStatusDidChangeNotification,
        object: nil,
        queue: .main,
        using: notify
      )
    )
    accessibilityObservers.append(
      center.addObserver(
        forName: UIApplication.willEnterForegroundNotification,
        object: nil,
        queue: .main,
        using: notify
      )
    )
    accessibilityObservers.append(
      center.addObserver(
        forName: UIScene.didActivateNotification,
        object: nil,
        queue: .main
      ) { _ in
        isSceneActive = true
        NotificationCenter.default.post(name: sceneActivationChangedNotification, object: nil)
        bridgeChannel?.invokeMethod("sceneActivationChanged", arguments: true)
      }
    )
    accessibilityObservers.append(
      center.addObserver(
        forName: UIScene.willDeactivateNotification,
        object: nil,
        queue: .main
      ) { _ in
        DispatchQueue.main.async {
          updateSceneActivationState()
        }
      }
    )
    accessibilityObservers.append(
      center.addObserver(
        forName: ProcessInfo.thermalStateDidChangeNotification,
        object: nil,
        queue: .main
      ) { _ in
        bridgeChannel?.invokeMethod(
          "thermalStateChanged",
          arguments: isThermalThrottled
        )
      }
    )
  }

  static func showMenuAtRect(args: [String: Any], completion: @escaping FlutterResult) {
    guard let host = topPresenter(),
          let rawItems = args["items"] as? [[String: Any]],
          !rawItems.isEmpty else {
      completion(nil)
      return
    }
    let title = (args["title"] as? String) ?? ""
    let anchor = args["anchorRect"] as? [String: Any]
    let ax = CGFloat((anchor?["x"] as? NSNumber)?.doubleValue ?? Double(host.view.bounds.midX))
    let ay = CGFloat((anchor?["y"] as? NSNumber)?.doubleValue ?? Double(host.view.bounds.midY))
    let aw = max(CGFloat((anchor?["width"] as? NSNumber)?.doubleValue ?? 40.0), 4.0)
    let ah = max(CGFloat((anchor?["height"] as? NSNumber)?.doubleValue ?? 40.0), 4.0)

    if #available(iOS 17.4, *) {
      var resolved = false
      var pendingCompletion: FlutterResult? = completion
      let anchorBtn = MarcoEphemeralMenuAnchorButton(type: .system)
      let btnId = ObjectIdentifier(anchorBtn)
      activeMenuButtons.insert(btnId)

      func finish(_ selectedId: String?) {
        guard !resolved else { return }
        resolved = true
        activeMenuButtons.remove(btnId)
        anchorBtn.removeFromSuperview()
        let cb = pendingCompletion
        pendingCompletion = nil
        cb?(selectedId)
      }

      guard let menu = buildMenu(title: title, rawItems: rawItems, onSelect: { selectedId in
        finish(selectedId)
      }) else {
        finish(nil)
        return
      }

      anchorBtn.frame = CGRect(
        x: max(4.0, min(ax, host.view.bounds.width - aw - 4.0)),
        y: max(4.0, min(ay, host.view.bounds.height - ah - 4.0)),
        width: aw,
        height: ah
      )
      anchorBtn.backgroundColor = .clear
      anchorBtn.alpha = 0.02
      anchorBtn.overrideUserInterfaceStyle = interfaceStyle
      anchorBtn.menu = menu
      anchorBtn.showsMenuAsPrimaryAction = true
      anchorBtn.onMenuEnded = {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
          finish(nil)
        }
      }
      host.view.addSubview(anchorBtn)
      anchorBtn.performPrimaryAction()
      return
    }
    MarcoNativeOptionSheetController.present(args: args, completion: completion)
  }

  static func register(with registrar: FlutterPluginRegistrar, messenger: FlutterBinaryMessenger) {
    brandLogoImage = loadBrandLogoImage(registrar: registrar)

    let channel = FlutterMethodChannel(
      name: "marco_movie/ios_liquid_glass",
      binaryMessenger: messenger
    )
    bridgeChannel = channel
    installAccessibilityObservers()
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "capabilities":
        result([
          "available": isAvailable,
          "majorVersion": majorOSVersion,
          "sdk26": builtWithSDK26,
          "reduceTransparency": isReduceTransparencyEnabled,
          "sceneActive": isSceneActive,
          "thermalThrottled": isThermalThrottled,
        ])
      case "configureRootTabChrome":
        guard isAvailable,
              let args = call.arguments as? [String: Any],
              let items = args["items"] as? [[String: Any]],
              !items.isEmpty else {
          result(false)
          return
        }
        DispatchQueue.main.async {
          let ok = MarcoIos27RootTabChromeController.shared.configure(args: args)
          result(ok)
        }
      case "setRootTabSelectedIndex":
        guard isAvailable else {
          result(nil)
          return
        }
        DispatchQueue.main.async {
          guard let controller = MarcoIos27RootTabChromeController.existingInstance else {
            result(nil)
            return
          }
          if let dict = call.arguments as? [String: Any], let idx = dict["index"] as? Int {
            let animated = (dict["animated"] as? Bool) ?? true
            let epoch = (dict["epoch"] as? NSNumber)?.intValue
            controller.setSelectedIndex(idx, animated: animated, epoch: epoch)
          } else if let idx = call.arguments as? Int {
            controller.setSelectedIndex(idx, animated: true, epoch: nil)
          }
          result(nil)
        }
      case "setRootTabMinimized":
        guard isAvailable else {
          result(nil)
          return
        }
        DispatchQueue.main.async {
          guard let controller = MarcoIos27RootTabChromeController.existingInstance else {
            result(nil)
            return
          }
          if let dict = call.arguments as? [String: Any] {
            let epoch = (dict["epoch"] as? NSNumber)?.intValue
            if let progress = (dict["progress"] as? NSNumber)?.doubleValue {
              controller.updateScrollMinimizeProgress(CGFloat(progress), epoch: epoch)
            } else {
              let minimized = (dict["minimized"] as? Bool) ?? false
              let animated = (dict["animated"] as? Bool) ?? true
              controller.setMinimized(minimized, animated: animated, epoch: epoch)
            }
          } else if let minimized = call.arguments as? Bool {
            controller.setMinimized(minimized, animated: true, epoch: nil)
          }
          result(nil)
        }
      case "setRootTabVisible":
        guard isAvailable else {
          result(nil)
          return
        }
        DispatchQueue.main.async {
          guard let controller = MarcoIos27RootTabChromeController.existingInstance else {
            result(nil)
            return
          }
          if let dict = call.arguments as? [String: Any] {
            let visible = (dict["visible"] as? Bool) ?? true
            let animated = (dict["animated"] as? Bool) ?? true
            let epoch = (dict["epoch"] as? NSNumber)?.intValue
            controller.setRootDockVisible(visible, animated: animated, epoch: epoch)
          } else if let visible = call.arguments as? Bool {
            controller.setRootDockVisible(visible, animated: true, epoch: nil)
          }
          result(nil)
        }
      case "showMenuAtRect":
        guard let args = call.arguments as? [String: Any] else {
          result(nil)
          return
        }
        DispatchQueue.main.async {
          showMenuAtRect(args: args, completion: result)
        }
      case "showAlert":
        guard let args = call.arguments as? [String: Any] else {
          result(nil)
          return
        }
        DispatchQueue.main.async {
          MarcoNativeAlertPresenter.presentAlert(args: args, completion: result)
        }
      case "showActionSheet":
        guard let args = call.arguments as? [String: Any] else {
          result(nil)
          return
        }
        DispatchQueue.main.async {
          MarcoNativeAlertPresenter.presentActionSheet(args: args, completion: result)
        }
      case "showOptionSheet":
        guard let args = call.arguments as? [String: Any] else {
          result(nil)
          return
        }
        DispatchQueue.main.async {
          MarcoNativeOptionSheetController.present(args: args, completion: result)
        }
      case "showFilterSheet":
        guard let args = call.arguments as? [String: Any] else {
          result(nil)
          return
        }
        DispatchQueue.main.async {
          MarcoNativeFilterSheetController.present(args: args, completion: result)
        }
      case "showPrivacyPin":
        guard let args = call.arguments as? [String: Any] else {
          result(nil)
          return
        }
        DispatchQueue.main.async {
          MarcoNativePinSheetController.present(args: args, completion: result)
        }
      case "dismissActiveSheets":
        DispatchQueue.main.async {
          MarcoNativeSheetCoordinator.dismissAllActive()
          result(nil)
        }
      case "setAppearanceMode":
        let mode = (call.arguments as? String) ?? "system"
        DispatchQueue.main.async {
          applyWindowAppearance(mode)
          result(nil)
        }
      case "setGlassIntensity":
        let val = (call.arguments as? NSNumber)?.doubleValue ?? 0.68
        DispatchQueue.main.async {
          applyGlassIntensity(val)
          result(nil)
        }
      case "presentAirPlayPicker":
        DispatchQueue.main.async {
          presentNativeAirPlayPicker()
          result(true)
        }
      case "triggerFavoriteDynamicIslandFeedback":
        let phase = (call.arguments as? String) ?? "shutter"
        DispatchQueue.main.async {
          result(triggerFavoriteDynamicIslandFeedback(phase: phase))
        }
      case "discoverBonjourDevices":
        let args = (call.arguments as? [String: Any]) ?? [:]
        let types = (args["serviceTypes"] as? [String]) ?? [
          "_marcomovie-cast._tcp.",
          "_airplay._tcp.",
          "_raop._tcp.",
          "_lelink._tcp.",
          "_lebo._tcp.",
          "_googlecast._tcp.",
          "_dlna._tcp.",
          "_upnp._tcp.",
        ]
        let timeoutMs = (args["timeoutMs"] as? NSNumber)?.intValue ?? 2200
        DispatchQueue.main.async {
          MarcoBonjourScanner.scan(serviceTypes: types, timeoutMs: timeoutMs) { payload in
            result(payload)
          }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    registrar.register(
      MarcoNativeDockFactory(messenger: messenger),
      withId: "marco_movie/ios26_dock"
    )
    registrar.register(
      MarcoNativeGlassButtonFactory(messenger: messenger),
      withId: "marco_movie/ios26_glass_button"
    )
    registrar.register(
      MarcoNativeGlassPillFactory(messenger: messenger),
      withId: "marco_movie/ios26_glass_pill"
    )
    registrar.register(
      MarcoNativeSegmentedControlFactory(messenger: messenger),
      withId: "marco_movie/ios26_segmented_control"
    )
    registrar.register(
      MarcoNativeSwitchFactory(messenger: messenger),
      withId: "marco_movie/ios26_switch"
    )
    registrar.register(
      MarcoNativeSliderFactory(messenger: messenger),
      withId: "marco_movie/ios26_slider"
    )
  }

  private static func loadBrandLogoImage(registrar: FlutterPluginRegistrar) -> UIImage? {
    let key = registrar.lookupKey(forAsset: "assets/logo_mark.png")
    let path = Bundle.main.path(forResource: key, ofType: nil)
      ?? Bundle.main.path(forResource: FlutterDartProject.lookupKey(forAsset: "assets/logo_mark.png"), ofType: nil)
    if let filePath = path, let raw = UIImage(contentsOfFile: filePath) {
      let target = CGSize(width: 32.0, height: 32.0)
      let scale = min(target.width / max(raw.size.width, 1.0), target.height / max(raw.size.height, 1.0))
      let drawSize = CGSize(width: raw.size.width * scale, height: raw.size.height * scale)
      let drawOrigin = CGPoint(
        x: (target.width - drawSize.width) * 0.5,
        y: (target.height - drawSize.height) * 0.5
      )
      let renderer = UIGraphicsImageRenderer(size: target)
      let rendered = renderer.image { _ in
        raw.draw(in: CGRect(origin: drawOrigin, size: drawSize))
      }
      return rendered.withRenderingMode(.alwaysOriginal)
    }
    let symCfg = UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
    return UIImage(systemName: "film.stack.fill", withConfiguration: symCfg)
  }

  static func colorFromARGB(_ value: Any?) -> UIColor? {
    guard let num = value as? NSNumber else { return nil }
    let argb = num.uint64Value
    let a = CGFloat((argb >> 24) & 0xFF) / 255.0
    let r = CGFloat((argb >> 16) & 0xFF) / 255.0
    let g = CGFloat((argb >> 8) & 0xFF) / 255.0
    let b = CGFloat(argb & 0xFF) / 255.0
    return UIColor(red: r, green: g, blue: b, alpha: a)
  }

  static func isNearWhite(_ color: UIColor) -> Bool {
    var r: CGFloat = 1
    var g: CGFloat = 1
    var b: CGFloat = 1
    var a: CGFloat = 1
    if color.getRed(&r, green: &g, blue: &b, alpha: &a) {
      return r > 0.90 && g > 0.90 && b > 0.90
    }
    return true
  }

  static func isNearBlack(_ color: UIColor) -> Bool {
    var r: CGFloat = 0
    var g: CGFloat = 0
    var b: CGFloat = 0
    var a: CGFloat = 1
    if color.getRed(&r, green: &g, blue: &b, alpha: &a) {
      return r < 0.22 && g < 0.22 && b < 0.22
    }
    return false
  }

  static func withoutAnimations(_ block: () -> Void) {
    UIView.performWithoutAnimation {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      block()
      CATransaction.commit()
    }
  }

  static func resolvedInitialFrame(
    _ frame: CGRect,
    args: [String: Any]?,
    defaultWidth: CGFloat,
    defaultHeight: CGFloat
  ) -> CGRect {
    if frame.width >= 1.0 && frame.height >= 1.0 {
      return frame
    }
    let w = CGFloat((args?["initialWidth"] as? NSNumber)?.doubleValue ?? Double(defaultWidth))
    let h = CGFloat((args?["initialHeight"] as? NSNumber)?.doubleValue ?? Double(defaultHeight))
    return CGRect(x: frame.origin.x, y: frame.origin.y, width: max(w, 1.0), height: max(h, 1.0))
  }

  static func buildMenu(
    title: String = "",
    rawItems: [[String: Any]],
    onSelect: @escaping (String) -> Void
  ) -> UIMenu? {
    guard !rawItems.isEmpty else { return nil }
    var sections: [(title: String, elements: [UIMenuElement])] = []
    var currentSectionKey: Int?
    var currentSectionTitle: String = ""
    var currentBucket: [UIMenuElement] = []

    for item in rawItems {
      let id = (item["id"] as? String) ?? ""
      let label = (item["title"] as? String) ?? ""
      let subtitle = item["subtitle"] as? String
      let symbol = item["symbol"] as? String
      let checked = (item["checked"] as? Bool) ?? false
      let destructive = (item["destructive"] as? Bool) ?? false
      let sectionKey = (item["section"] as? NSNumber)?.intValue ?? 0
      let secTitle = (item["sectionTitle"] as? String) ?? ""

      if let prev = currentSectionKey, prev != sectionKey, !currentBucket.isEmpty {
        sections.append((title: currentSectionTitle, elements: currentBucket))
        currentBucket = []
        currentSectionTitle = ""
      }
      currentSectionKey = sectionKey
      if currentSectionTitle.isEmpty && !secTitle.isEmpty {
        currentSectionTitle = secTitle
      }

      let image = symbol.flatMap { UIImage(systemName: $0) }
      let attrs: UIMenuElement.Attributes = destructive ? [.destructive] : []
      let action: UIAction
      if #available(iOS 15.0, *) {
        action = UIAction(
          title: label,
          subtitle: (subtitle?.isEmpty ?? true) ? nil : subtitle,
          image: image,
          attributes: attrs,
          state: checked ? .on : .off
        ) { _ in
          onSelect(id)
        }
      } else {
        let combined = (subtitle?.isEmpty ?? true) ? label : "\(label) · \(subtitle!)"
        action = UIAction(
          title: combined,
          image: image,
          attributes: attrs,
          state: checked ? .on : .off
        ) { _ in
          onSelect(id)
        }
      }
      currentBucket.append(action)
    }
    if !currentBucket.isEmpty {
      sections.append((title: currentSectionTitle, elements: currentBucket))
    }
    if sections.count <= 1 && (sections.first?.title.isEmpty ?? true) {
      return UIMenu(title: title, children: sections.first?.elements ?? [])
    }
    let inlineMenus = sections.map { UIMenu(title: $0.title, options: .displayInline, children: $0.elements) }
    return UIMenu(title: title, children: inlineMenus)
  }

  static func topPresenter() -> UIViewController? {
    var presenter = activeWindow()?.rootViewController
    while let presented = presenter?.presentedViewController, !presented.isBeingDismissed {
      presenter = presented
    }
    return presenter
  }
}

private final class MarcoEphemeralMenuAnchorButton: UIButton {
  var onMenuEnded: (() -> Void)?

  override func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    willEndFor configuration: UIContextMenuConfiguration,
    animator: UIContextMenuInteractionAnimating?
  ) {
    super.contextMenuInteraction(interaction, willEndFor: configuration, animator: animator)
    if let animator = animator {
      animator.addCompletion { [weak self] in
        self?.onMenuEnded?()
      }
    } else {
      onMenuEnded?()
    }
  }
}

// MARK: - Single-Flight Native Sheet Coordinator & Deinit Sentinel

private final class _MarcoDeinitKeyToken: Sendable {}

private final class MarcoDeinitSentinel: NSObject {
  private static let keyToken = _MarcoDeinitKeyToken()
  private var onDeinit: (() -> Void)?

  init(onDeinit: @escaping () -> Void) {
    self.onDeinit = onDeinit
    super.init()
  }

  static func attach(to owner: AnyObject, onDeinit: @escaping () -> Void) -> MarcoDeinitSentinel {
    let sentinel = MarcoDeinitSentinel(onDeinit: onDeinit)
    let key = UnsafeRawPointer(Unmanaged.passUnretained(keyToken).toOpaque())
    objc_setAssociatedObject(owner, key, sentinel, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    return sentinel
  }

  func invalidate() {
    onDeinit = nil
  }

  deinit {
    let cb = onDeinit
    onDeinit = nil
    if let cb = cb {
      if Thread.isMainThread {
        cb()
      } else {
        DispatchQueue.main.async { cb() }
      }
    }
  }
}

private enum MarcoNativeSheetCoordinator {
  private static var isPresenting = false
  private static weak var activeController: UIViewController?
  private static var activeControllerId: ObjectIdentifier?
  private static var activeCancelHandler: (() -> Void)?

  static func tryBeginPresentation(
    host: UIViewController,
    controller: UIViewController,
    onCancel: @escaping () -> Void
  ) -> Bool {
    // Reclaim stale slot if a previously presented controller disappeared without firing its delegate.
    if let staleId = activeControllerId, !isPresenting {
      let staleGone = activeController == nil || activeController?.presentingViewController == nil
      if staleGone {
        let staleCancel = activeCancelHandler
        activeController = nil
        activeControllerId = nil
        activeCancelHandler = nil
        staleCancel?()
        _ = staleId
      }
    }
    if isPresenting || activeControllerId != nil {
      return false
    }
    if host.isBeingDismissed || host.isBeingPresented {
      return false
    }
    if let existing = host.presentedViewController, !existing.isBeingDismissed {
      return false
    }
    isPresenting = true
    activeController = controller
    activeControllerId = ObjectIdentifier(controller)
    activeCancelHandler = onCancel
    return true
  }

  static func isCurrent(identity: ObjectIdentifier) -> Bool {
    return activeControllerId == identity
  }

  static func didCompletePresentation(identity: ObjectIdentifier) {
    guard activeControllerId == identity else { return }
    isPresenting = false
    if activeController == nil || activeController?.presentingViewController == nil {
      let cancel = activeCancelHandler
      activeController = nil
      activeControllerId = nil
      activeCancelHandler = nil
      cancel?()
    }
  }

  static func didFinish(identity: ObjectIdentifier) {
    guard activeControllerId == identity else { return }
    isPresenting = false
    activeController = nil
    activeControllerId = nil
    activeCancelHandler = nil
  }

  static func dismissAllActive() {
    let vc = activeController
    let cancel = activeCancelHandler
    isPresenting = false
    activeController = nil
    activeControllerId = nil
    activeCancelHandler = nil
    if let presented = vc, presented.isBeingPresented,
       let coordinator = presented.transitionCoordinator {
      cancel?()
      coordinator.animate(alongsideTransition: nil) { _ in
        if presented.presentingViewController != nil && !presented.isBeingDismissed {
          presented.dismiss(animated: false, completion: nil)
        }
      }
    } else if let presented = vc, presented.presentingViewController != nil, !presented.isBeingDismissed {
      presented.dismiss(animated: false) {
        cancel?()
      }
    } else {
      cancel?()
    }
  }

  static func presentRespectingDismissTransition(
    host: UIViewController,
    controller: UIViewController,
    identity: ObjectIdentifier,
    onRejected: @escaping () -> Void
  ) {
    let performPresent: () -> Void = {
      guard isCurrent(identity: identity),
            host.presentedViewController == nil,
            !host.isBeingDismissed else {
        onRejected()
        return
      }
      host.present(controller, animated: true) {
        didCompletePresentation(identity: identity)
      }
    }
    if let existing = host.presentedViewController, existing.isBeingDismissed,
       let coordinator = existing.transitionCoordinator {
      coordinator.animate(alongsideTransition: nil) { _ in
        performPresent()
      }
    } else {
      performPresent()
    }
  }
}

// MARK: - Native UIAlertController Presenter (Alert & ActionSheet)

private final class MarcoPopoverDismissBox: NSObject, UIPopoverPresentationControllerDelegate {
  private var onDismiss: (() -> Void)?

  init(onDismiss: @escaping () -> Void) {
    self.onDismiss = onDismiss
    super.init()
  }

  func invalidate() {
    onDismiss = nil
  }

  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    let cb = onDismiss
    onDismiss = nil
    cb?()
  }
}

private enum MarcoNativeAlertPresenter {
  private static var activePopoverBoxes: [ObjectIdentifier: MarcoPopoverDismissBox] = [:]

  static func presentAlert(args: [String: Any], completion: @escaping FlutterResult) {
    guard let host = MarcoLiquidGlassSupport.topPresenter() else {
      completion(nil)
      return
    }
    let title = args["title"] as? String
    let message = args["message"] as? String
    let actionDicts = (args["actions"] as? [[String: Any]]) ?? []
    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    alert.overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle
    let alertKey = ObjectIdentifier(alert)

    var resolved = false
    var pendingCompletion: FlutterResult? = completion
    weak var weakSentinel: MarcoDeinitSentinel?
    func finish(_ value: Any?) {
      guard !resolved else { return }
      resolved = true
      weakSentinel?.invalidate()
      MarcoNativeSheetCoordinator.didFinish(identity: alertKey)
      let cb = pendingCompletion
      pendingCompletion = nil
      cb?(value)
    }

    guard MarcoNativeSheetCoordinator.tryBeginPresentation(
      host: host,
      controller: alert,
      onCancel: { finish(nil) }
    ) else {
      finish(nil)
      return
    }
    weakSentinel = MarcoDeinitSentinel.attach(to: alert) {
      finish(nil)
    }

    if actionDicts.isEmpty {
      alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in finish("ok") })
    } else {
      for dict in actionDicts {
        let id = (dict["id"] as? String) ?? ""
        let label = (dict["title"] as? String) ?? ""
        let styleStr = (dict["style"] as? String) ?? "default"
        let isDefault = (dict["isDefault"] as? Bool) ?? false
        let style: UIAlertAction.Style
        switch styleStr {
        case "cancel":
          style = .cancel
        case "destructive":
          style = .destructive
        default:
          style = .default
        }
        let action = UIAlertAction(title: label, style: style) { _ in
          finish(id)
        }
        alert.addAction(action)
        if isDefault && style != .cancel {
          alert.preferredAction = action
        }
      }
    }

    MarcoNativeSheetCoordinator.presentRespectingDismissTransition(
      host: host,
      controller: alert,
      identity: alertKey,
      onRejected: { finish(nil) }
    )
  }

  static func presentActionSheet(args: [String: Any], completion: @escaping FlutterResult) {
    guard let host = MarcoLiquidGlassSupport.topPresenter() else {
      completion(nil)
      return
    }
    let title = args["title"] as? String
    let message = args["message"] as? String
    let cancelTitle = args["cancelTitle"] as? String
    let actionDicts = (args["actions"] as? [[String: Any]]) ?? []
    let sheet = UIAlertController(title: title, message: message, preferredStyle: .actionSheet)
    sheet.overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle
    let sheetKey = ObjectIdentifier(sheet)

    var resolved = false
    var pendingCompletion: FlutterResult? = completion
    weak var weakSentinel: MarcoDeinitSentinel?
    func finish(_ value: Any?) {
      guard !resolved else { return }
      resolved = true
      weakSentinel?.invalidate()
      if let box = activePopoverBoxes.removeValue(forKey: sheetKey) {
        box.invalidate()
      }
      MarcoNativeSheetCoordinator.didFinish(identity: sheetKey)
      let cb = pendingCompletion
      pendingCompletion = nil
      cb?(value)
    }

    guard MarcoNativeSheetCoordinator.tryBeginPresentation(
      host: host,
      controller: sheet,
      onCancel: { finish(nil) }
    ) else {
      finish(nil)
      return
    }
    weakSentinel = MarcoDeinitSentinel.attach(to: sheet) {
      finish(nil)
    }

    for dict in actionDicts {
      let id = (dict["id"] as? String) ?? ""
      let label = (dict["title"] as? String) ?? ""
      let styleStr = (dict["style"] as? String) ?? "default"
      let style: UIAlertAction.Style = (styleStr == "destructive") ? .destructive : .default
      let action = UIAlertAction(title: label, style: style) { _ in
        finish(id)
      }
      sheet.addAction(action)
    }

    if let cancelLabel = cancelTitle, !cancelLabel.isEmpty {
      sheet.addAction(UIAlertAction(title: cancelLabel, style: .cancel) { _ in
        finish(nil)
      })
    }

    if let popover = sheet.popoverPresentationController {
      popover.sourceView = host.view
      popover.sourceRect = CGRect(
        x: host.view.bounds.midX,
        y: max(host.view.bounds.maxY - 96.0, host.view.bounds.midY),
        width: 1,
        height: 1
      )
      popover.permittedArrowDirections = []
      let dismissBox = MarcoPopoverDismissBox {
        finish(nil)
      }
      activePopoverBoxes[sheetKey] = dismissBox
      popover.delegate = dismissBox
    }

    MarcoNativeSheetCoordinator.presentRespectingDismissTransition(
      host: host,
      controller: sheet,
      identity: sheetKey,
      onRejected: { finish(nil) }
    )
  }
}

// MARK: - Native iOS 26 Liquid Glass Half-Sheet Option Picker (UISheetPresentationController)

private final class MarcoNativeOptionSheetController: UIViewController,
  UITableViewDataSource,
  UITableViewDelegate,
  UIAdaptivePresentationControllerDelegate,
  UIPopoverPresentationControllerDelegate
{
  private struct OptionItem {
    let id: String
    let title: String
    let subtitle: String?
    let symbol: String?
    let checked: Bool
    let destructive: Bool
  }

  private struct OptionSection {
    let title: String
    let items: [OptionItem]
  }

  private let sheetTitle: String
  private let sheetSubtitle: String?
  private let cancelTitle: String
  private let forceOpaque: Bool
  private let isPopoverPresentation: Bool
  private let forceDarkSurface: Bool
  private let sections: [OptionSection]
  private let tableView: UITableView
  private var compactHeaderView: UIView?
  private var compactHeaderLabel: UILabel?
  private var compactHeaderDivider: UIView?

  private var completion: FlutterResult?
  private var resolved = false
  private var dismissing = false
  private var navIdentity: ObjectIdentifier?

  private var isOpaqueMode: Bool {
    return forceOpaque || UIAccessibility.isReduceTransparencyEnabled
  }

  private var useDarkColors: Bool {
    return forceDarkSurface || MarcoLiquidGlassSupport.isEffectiveDark(for: isViewLoaded ? view : nil)
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
      let dark = useDarkColors
      tableView.separatorColor = dark
        ? UIColor.white.withAlphaComponent(0.10)
        : UIColor.black.withAlphaComponent(0.08)
      compactHeaderLabel?.textColor = dark
        ? UIColor.white.withAlphaComponent(0.92)
        : UIColor.label
      compactHeaderDivider?.backgroundColor = dark
        ? UIColor.white.withAlphaComponent(0.12)
        : UIColor.black.withAlphaComponent(0.08)
      tableView.reloadData()
    }
  }

  override func viewWillTransition(
    to size: CGSize,
    with coordinator: UIViewControllerTransitionCoordinator
  ) {
    super.viewWillTransition(to: size, with: coordinator)
    coordinator.animate(alongsideTransition: { [weak self] _ in
      guard let self = self else { return }
      if self.isPopoverPresentation, let nav = self.navigationController {
        let maxW = min(Double(size.width) - 24.0, 306.0)
        let maxH = min(Double(size.height) * 0.84, 380.0)
        nav.preferredContentSize = CGSize(
          width: max(236.0, min(Double(nav.preferredContentSize.width), maxW)),
          height: min(Double(nav.preferredContentSize.height), max(maxH, 160.0))
        )
      }
      self.view.setNeedsLayout()
      self.view.layoutIfNeeded()
    }, completion: nil)
  }

  func adaptivePresentationStyle(
    for controller: UIPresentationController,
    traitCollection: UITraitCollection
  ) -> UIModalPresentationStyle {
    return isPopoverPresentation ? .none : .automatic
  }

  static func present(args: [String: Any], completion: @escaping FlutterResult) {
    guard let host = MarcoLiquidGlassSupport.topPresenter() else {
      completion(nil)
      return
    }
    let anchorDict = args["anchorRect"] as? [String: Any]
    let vc = MarcoNativeOptionSheetController(
      args: args,
      isPopover: anchorDict != nil,
      completion: completion
    )
    let nav = UINavigationController(rootViewController: vc)
    let navId = ObjectIdentifier(nav)
    vc.navIdentity = navId
    let style: UIUserInterfaceStyle = vc.forceDarkSurface ? .dark : MarcoLiquidGlassSupport.interfaceStyle
    nav.overrideUserInterfaceStyle = style

    if let anchor = anchorDict,
       let ax = (anchor["x"] as? NSNumber)?.doubleValue,
       let ay = (anchor["y"] as? NSNumber)?.doubleValue,
       let aw = (anchor["width"] as? NSNumber)?.doubleValue,
       let ah = (anchor["height"] as? NSNumber)?.doubleValue {
      nav.modalPresentationStyle = .popover
      nav.setNavigationBarHidden(true, animated: false)
      let itemCount = vc.sections.reduce(0) { $0 + $1.items.count }
      let sectionHeaderCount = vc.sections.filter { !$0.title.isEmpty }.count
      let subtitleRows = vc.sections.flatMap { $0.items }.filter { $0.subtitle != nil }.count
      let headerH = vc.sheetTitle.isEmpty ? 6.0 : 34.0
      let rawHeight = headerH + Double(itemCount) * 36.0 + Double(subtitleRows) * 11.0 + Double(sectionHeaderCount) * 22.0 + 10.0
      let maxH = min(Double(host.view.bounds.height) * 0.84, 380.0)
      let maxW = min(Double(host.view.bounds.width) - 24.0, 306.0)
      nav.preferredContentSize = CGSize(
        width: max(240.0, maxW),
        height: min(max(rawHeight, 118.0), max(maxH, 160.0))
      )
      if let popover = nav.popoverPresentationController {
        popover.delegate = vc
        popover.sourceView = host.view
        popover.sourceRect = CGRect(
          x: max(4.0, min(CGFloat(ax), host.view.bounds.width - 8.0)),
          y: max(4.0, min(CGFloat(ay), host.view.bounds.height - 8.0)),
          width: max(CGFloat(aw), 1.0),
          height: max(CGFloat(ah), 1.0)
        )
        popover.permittedArrowDirections = [.up, .down, .left, .right]
        popover.canOverlapSourceViewRect = false
      }
    } else {
      nav.modalPresentationStyle = .pageSheet
      nav.presentationController?.delegate = vc
      if #available(iOS 15.0, *), let sheet = nav.sheetPresentationController {
        sheet.detents = [.medium(), .large()]
        sheet.prefersGrabberVisible = true
        sheet.preferredCornerRadius = 32.0
        sheet.prefersScrollingExpandsWhenScrolledToEdge = true
        sheet.prefersEdgeAttachedInCompactHeight = true
        sheet.widthFollowsPreferredContentSizeWhenEdgeAttached = true
      }
    }
    guard MarcoNativeSheetCoordinator.tryBeginPresentation(
      host: host,
      controller: nav,
      onCancel: { [weak vc] in vc?.finish(selectedId: nil) }
    ) else {
      vc.finish(selectedId: nil)
      return
    }
    MarcoNativeSheetCoordinator.presentRespectingDismissTransition(
      host: host,
      controller: nav,
      identity: navId,
      onRejected: { [weak vc] in vc?.finish(selectedId: nil) }
    )
  }

  init(args: [String: Any], isPopover: Bool = false, completion: @escaping FlutterResult) {
    self.sheetTitle = (args["title"] as? String) ?? ""
    let rawSubtitle = (args["subtitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    self.sheetSubtitle = (rawSubtitle?.isEmpty ?? true) ? nil : rawSubtitle
    self.cancelTitle = (args["cancelTitle"] as? String) ?? "关闭"
    self.forceOpaque = (args["forceOpaque"] as? Bool) ?? false
    self.isPopoverPresentation = isPopover
    self.forceDarkSurface = (args["forceDark"] as? Bool) ?? isPopover
    self.tableView = UITableView(frame: .zero, style: isPopover ? .plain : .insetGrouped)
    let rawItems = (args["items"] as? [[String: Any]]) ?? []
    var builtSections: [OptionSection] = []
    var currentKey: Int?
    var currentTitle = ""
    var bucket: [OptionItem] = []

    for raw in rawItems {
      let id = (raw["id"] as? String) ?? ""
      let title = (raw["title"] as? String) ?? ""
      let sub = (raw["subtitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
      let sym = (raw["symbol"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
      let checked = (raw["checked"] as? Bool) ?? false
      let destructive = (raw["destructive"] as? Bool) ?? false
      let secKey = (raw["section"] as? NSNumber)?.intValue ?? 0
      let secTitle = (raw["sectionTitle"] as? String) ?? ""

      if let prev = currentKey, prev != secKey, !bucket.isEmpty {
        builtSections.append(OptionSection(title: currentTitle, items: bucket))
        bucket = []
        currentTitle = ""
      }
      currentKey = secKey
      if currentTitle.isEmpty && !secTitle.isEmpty {
        currentTitle = secTitle
      }
      bucket.append(
        OptionItem(
          id: id,
          title: title,
          subtitle: (sub?.isEmpty ?? true) ? nil : sub,
          symbol: (sym?.isEmpty ?? true) ? nil : sym,
          checked: checked,
          destructive: destructive
        )
      )
    }
    if !bucket.isEmpty {
      builtSections.append(OptionSection(title: currentTitle, items: bucket))
    }
    self.sections = builtSections
    self.completion = completion
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
    guard !resolved else { return }
    resolved = true
    let cb = completion
    completion = nil
    let id = navIdentity
    if Thread.isMainThread {
      if let id = id { MarcoNativeSheetCoordinator.didFinish(identity: id) }
      cb?(nil)
    } else {
      DispatchQueue.main.async {
        if let id = id { MarcoNativeSheetCoordinator.didFinish(identity: id) }
        cb?(nil)
      }
    }
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    let dark = useDarkColors
    overrideUserInterfaceStyle = forceDarkSurface ? .dark : MarcoLiquidGlassSupport.interfaceStyle
    let opaqueFallback = dark
      ? UIColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1.0)
      : UIColor(red: 0.96, green: 0.96, blue: 0.98, alpha: 1.0)
    #if compiler(>=6.2)
    if #available(iOS 26.0, *), !isOpaqueMode {
      view.backgroundColor = .clear
    } else {
      view.backgroundColor = opaqueFallback
    }
    #else
    view.backgroundColor = isPopoverPresentation && !isOpaqueMode
      ? (dark ? UIColor(white: 0.12, alpha: 0.88) : UIColor(white: 0.98, alpha: 0.92))
      : opaqueFallback
    #endif

    navigationItem.title = sheetTitle
    if !isPopoverPresentation, let subtitle = sheetSubtitle {
      navigationItem.prompt = subtitle
    }
    if !isPopoverPresentation {
      navigationItem.rightBarButtonItem = UIBarButtonItem(
        title: cancelTitle,
        style: .done,
        target: self,
        action: #selector(closeTapped)
      )
    }

    tableView.translatesAutoresizingMaskIntoConstraints = false
    tableView.overrideUserInterfaceStyle = overrideUserInterfaceStyle
    tableView.backgroundColor = .clear
    tableView.separatorColor = dark
      ? UIColor.white.withAlphaComponent(isPopoverPresentation ? 0.10 : 0.12)
      : UIColor.black.withAlphaComponent(isPopoverPresentation ? 0.08 : 0.10)
    if isPopoverPresentation {
      tableView.separatorInset = UIEdgeInsets(top: 0, left: 36, bottom: 0, right: 12)
      tableView.rowHeight = UITableView.automaticDimension
      tableView.estimatedRowHeight = 36.0
      tableView.contentInset = UIEdgeInsets(top: 2, left: 0, bottom: 6, right: 0)
      tableView.tableFooterView = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 0.5))
      if #available(iOS 15.0, *) {
        tableView.sectionHeaderTopPadding = 4.0
      }
    }
    #if compiler(>=6.2)
    if #available(iOS 26.0, *), !isPopoverPresentation {
      tableView.cornerConfiguration = .corners(radius: .containerConcentric(minimum: 20.0))
    }
    #endif
    tableView.dataSource = self
    tableView.delegate = self
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "MarcoOptionCell")
    view.addSubview(tableView)

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleSceneActivationChanged),
      name: MarcoLiquidGlassSupport.sceneActivationChangedNotification,
      object: nil
    )

    if isPopoverPresentation && !sheetTitle.isEmpty {
      let header = UIView()
      header.translatesAutoresizingMaskIntoConstraints = false
      header.backgroundColor = .clear

      let titleLbl = UILabel()
      titleLbl.translatesAutoresizingMaskIntoConstraints = false
      titleLbl.text = sheetTitle
      titleLbl.font = UIFont.systemFont(ofSize: 13.0, weight: .semibold)
      titleLbl.textAlignment = .center
      titleLbl.textColor = dark ? UIColor.white.withAlphaComponent(0.92) : UIColor.label
      header.addSubview(titleLbl)

      let divider = UIView()
      divider.translatesAutoresizingMaskIntoConstraints = false
      divider.backgroundColor = dark
        ? UIColor.white.withAlphaComponent(0.12)
        : UIColor.black.withAlphaComponent(0.08)
      header.addSubview(divider)

      view.addSubview(header)
      compactHeaderView = header
      compactHeaderLabel = titleLbl
      compactHeaderDivider = divider

      NSLayoutConstraint.activate([
        header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
        header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
        header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        header.heightAnchor.constraint(equalToConstant: 32.0),

        titleLbl.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 12.0),
        titleLbl.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -12.0),
        titleLbl.centerYAnchor.constraint(equalTo: header.centerYAnchor),

        divider.leadingAnchor.constraint(equalTo: header.leadingAnchor),
        divider.trailingAnchor.constraint(equalTo: header.trailingAnchor),
        divider.bottomAnchor.constraint(equalTo: header.bottomAnchor),
        divider.heightAnchor.constraint(equalToConstant: 0.5),

        tableView.topAnchor.constraint(equalTo: header.bottomAnchor),
        tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
        tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      ])
    } else {
      NSLayoutConstraint.activate([
        tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
        tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
        tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      ])
    }
  }

  @objc private func handleSceneActivationChanged() {
    let active = MarcoLiquidGlassSupport.isSceneActive
    UIView.animate(withDuration: 0.18) {
      self.view.alpha = active ? 1.0 : 0.90
    }
  }

  func numberOfSections(in tableView: UITableView) -> Int {
    return sections.count
  }

  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    return sections[section].items.count
  }

  func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
    if isPopoverPresentation { return nil }
    let title = sections[section].title
    return title.isEmpty ? nil : title
  }

  func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
    if !isPopoverPresentation { return UITableView.automaticDimension }
    return sections[section].title.isEmpty ? 0.0 : 21.0
  }

  func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
    guard isPopoverPresentation else { return nil }
    let title = sections[section].title
    guard !title.isEmpty else { return nil }
    let dark = useDarkColors
    let container = UIView()
    container.backgroundColor = .clear
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.text = title
    label.font = UIFont.systemFont(ofSize: 10.5, weight: .semibold)
    label.textColor = dark
      ? UIColor.white.withAlphaComponent(0.50)
      : UIColor.secondaryLabel
    container.addSubview(label)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12.0),
      label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12.0),
      label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2.0),
    ])
    return container
  }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "MarcoOptionCell", for: indexPath)
    let item = sections[indexPath.section].items[indexPath.row]
    let dark = useDarkColors
    var cfg = cell.defaultContentConfiguration()
    cfg.text = item.title
    cfg.textProperties.numberOfLines = isPopoverPresentation ? 1 : 2
    cfg.textProperties.lineBreakMode = .byTruncatingTail
    cfg.textProperties.color = item.destructive
      ? UIColor.systemRed
      : (dark ? UIColor.white : UIColor.label)
    cfg.textProperties.font = UIFont.systemFont(
      ofSize: isPopoverPresentation ? 13.0 : 15.0,
      weight: item.checked ? .semibold : .medium
    )
    if let sub = item.subtitle {
      cfg.secondaryText = sub
      cfg.secondaryTextProperties.numberOfLines = 1
      cfg.secondaryTextProperties.lineBreakMode = .byTruncatingTail
      cfg.secondaryTextProperties.color = dark
        ? UIColor.white.withAlphaComponent(0.60)
        : UIColor.secondaryLabel
      cfg.secondaryTextProperties.font = UIFont.systemFont(
        ofSize: isPopoverPresentation ? 10.5 : 12.0,
        weight: .regular
      )
    }
    if isPopoverPresentation {
      cfg.directionalLayoutMargins = NSDirectionalEdgeInsets(
        top: 5.5,
        leading: 12.0,
        bottom: 5.5,
        trailing: 10.0
      )
      cfg.imageToTextPadding = 9.0
      cfg.textToSecondaryTextVerticalPadding = 1.5
    }
    if let symbol = item.symbol {
      let symCfg = UIImage.SymbolConfiguration(
        pointSize: isPopoverPresentation ? 13.5 : 15.5,
        weight: .medium
      )
      cfg.image = UIImage(systemName: symbol, withConfiguration: symCfg)
      cfg.imageProperties.tintColor = item.destructive
        ? UIColor.systemRed
        : (item.checked
            ? UIColor.systemBlue
            : (dark ? UIColor.white.withAlphaComponent(0.84) : UIColor.label))
    }
    cell.contentConfiguration = cfg
    cell.accessoryType = item.checked ? .checkmark : .none
    cell.tintColor = UIColor.systemBlue
    if isPopoverPresentation {
      cell.backgroundColor = .clear
    } else {
      let alpha: CGFloat = isOpaqueMode ? 0.96 : 0.72
      cell.backgroundColor = dark
        ? UIColor(white: 0.16, alpha: alpha)
        : UIColor(white: 1.0, alpha: isOpaqueMode ? 0.98 : 0.78)
    }
    return cell
  }

  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    guard !resolved, !dismissing else { return }
    dismissing = true
    let item = sections[indexPath.section].items[indexPath.row]
    UISelectionFeedbackGenerator().selectionChanged()
    if presentingViewController != nil {
      dismiss(animated: true) {
        self.finish(selectedId: item.id)
      }
    } else {
      finish(selectedId: item.id)
    }
  }

  @objc private func closeTapped() {
    guard !resolved, !dismissing else { return }
    dismissing = true
    if presentingViewController != nil {
      dismiss(animated: true) {
        self.finish(selectedId: nil)
      }
    } else {
      finish(selectedId: nil)
    }
  }

  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    finish(selectedId: nil)
  }

  private func finish(selectedId: String?) {
    guard !resolved else { return }
    resolved = true
    if let id = navIdentity {
      MarcoNativeSheetCoordinator.didFinish(identity: id)
    }
    let cb = completion
    completion = nil
    cb?(selectedId)
  }
}

// MARK: - Native iOS 26 Liquid Glass Filter Sheet (UISheetPresentationController)

private final class MarcoFilterOptionCellButton: UIControl {
  private let titleLbl = UILabel()
  private let checkIconView = UIImageView()
  private var checkWidthConstraint: NSLayoutConstraint?
  private var isDarkMode: Bool = true
  private var isOptionSelected: Bool = false

  override init(frame: CGRect) {
    super.init(frame: frame)
    layer.cornerRadius = 12.0
    layer.cornerCurve = .continuous
    layer.borderWidth = 0.6
    isAccessibilityElement = true

    titleLbl.translatesAutoresizingMaskIntoConstraints = false
    titleLbl.textAlignment = .left
    titleLbl.numberOfLines = 3
    titleLbl.lineBreakMode = .byWordWrapping
    titleLbl.adjustsFontForContentSizeCategory = true
    addSubview(titleLbl)

    checkIconView.translatesAutoresizingMaskIntoConstraints = false
    let cfg = UIImage.SymbolConfiguration(pointSize: 13.0, weight: .bold)
    checkIconView.image = UIImage(systemName: "checkmark", withConfiguration: cfg)
    checkIconView.tintColor = .white
    checkIconView.contentMode = .scaleAspectFit
    checkIconView.isHidden = true
    addSubview(checkIconView)

    let cw = checkIconView.widthAnchor.constraint(equalToConstant: 0.0)
    checkWidthConstraint = cw

    NSLayoutConstraint.activate([
      titleLbl.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12.0),
      titleLbl.topAnchor.constraint(equalTo: topAnchor, constant: 10.0),
      titleLbl.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10.0),
      titleLbl.trailingAnchor.constraint(equalTo: checkIconView.leadingAnchor, constant: -6.0),

      checkIconView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10.0),
      checkIconView.centerYAnchor.constraint(equalTo: centerYAnchor),
      checkIconView.heightAnchor.constraint(equalToConstant: 14.0),
      cw,
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var isHighlighted: Bool {
    didSet {
      UIView.animate(withDuration: 0.12) {
        self.alpha = self.isHighlighted ? 0.76 : 1.0
      }
    }
  }

  func configure(title: String, selected: Bool, dark: Bool) {
    isOptionSelected = selected
    isDarkMode = dark
    titleLbl.text = title
    let baseFont = UIFont.systemFont(ofSize: 13.5, weight: selected ? .bold : .medium)
    titleLbl.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: baseFont)
    titleLbl.textColor = selected
      ? .white
      : (dark ? UIColor.white.withAlphaComponent(0.92) : UIColor.label)
    backgroundColor = selected
      ? UIColor.systemBlue
      : (dark ? UIColor.white.withAlphaComponent(0.08) : UIColor.white)
    layer.borderColor = selected
      ? UIColor.systemBlue.cgColor
      : (dark ? UIColor.white.withAlphaComponent(0.10).cgColor : UIColor.black.withAlphaComponent(0.08).cgColor)
    layer.borderWidth = selected ? 1.0 : 0.6
    checkIconView.isHidden = !selected
    checkWidthConstraint?.constant = selected ? 15.0 : 0.0
    accessibilityLabel = title
    accessibilityTraits = selected ? [.button, .selected] : [.button]
  }

  func preferredHeight(forWidth width: CGFloat) -> CGFloat {
    let textW = max(24.0, width - 12.0 - 10.0 - 6.0 - 15.0)
    let measured = titleLbl.sizeThatFits(CGSize(width: textW, height: .greatestFiniteMagnitude))
    return max(44.0, ceil(measured.height) + 20.0)
  }
}

private final class MarcoFilterGridContainerView: UIView {
  var horizontalSpacing: CGFloat = 10.0
  var verticalSpacing: CGFloat = 10.0
  private var cells: [MarcoFilterOptionCellButton] = []
  private var lastMeasuredWidth: CGFloat = 0.0
  private var calculatedHeight: CGFloat = 44.0

  func setCells(_ newCells: [MarcoFilterOptionCellButton]) {
    for old in cells {
      old.removeFromSuperview()
    }
    cells = newCells
    for c in newCells {
      addSubview(c)
    }
    lastMeasuredWidth = 0.0
    setNeedsLayout()
    invalidateIntrinsicContentSize()
  }

  private func columnCount(forWidth maxW: CGFloat) -> Int {
    let scaled14 = UIFontMetrics(forTextStyle: .subheadline).scaledValue(for: 14.0)
    let textScale = max(1.0, scaled14 / 14.0)
    let effectiveWidth = maxW / textScale
    if maxW < 250.0 || effectiveWidth < 205.0 { return 1 }
    if maxW < 340.0 || effectiveWidth < 275.0 { return 2 }
    if effectiveWidth < 460.0 { return 3 }
    return 4
  }

  override var intrinsicContentSize: CGSize {
    return CGSize(width: UIView.noIntrinsicMetric, height: max(calculatedHeight, 44.0))
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let maxW = bounds.width
    guard maxW > 0 else { return }
    let cols = columnCount(forWidth: maxW)
    let cellW = floor((maxW - horizontalSpacing * CGFloat(cols - 1)) / CGFloat(cols))
    var y: CGFloat = 0.0
    var rowIndex = 0
    while rowIndex < cells.count {
      let endIndex = min(rowIndex + cols, cells.count)
      var rowH: CGFloat = 44.0
      for i in rowIndex..<endIndex {
        rowH = max(rowH, cells[i].preferredHeight(forWidth: cellW))
      }
      for i in rowIndex..<endIndex {
        let col = i - rowIndex
        let x = CGFloat(col) * (cellW + horizontalSpacing)
        cells[i].frame = CGRect(x: x, y: y, width: cellW, height: rowH)
      }
      y += rowH + verticalSpacing
      rowIndex = endIndex
    }

    let totalH = cells.isEmpty ? 0.0 : max(0.0, y - verticalSpacing)
    if abs(totalH - calculatedHeight) > 0.5 || abs(maxW - lastMeasuredWidth) > 0.5 {
      calculatedHeight = totalH
      lastMeasuredWidth = maxW
      invalidateIntrinsicContentSize()
    }
  }
}

private final class MarcoNativeFilterSheetController: UIViewController, UIAdaptivePresentationControllerDelegate {
  private struct CategoryChoice {
    let id: String
    let label: String
    let kind: String // "all" | "cat" | "genre"
  }

  private let sheetTitle: String
  private let categories: [CategoryChoice]
  private let areas: [String]
  private let years: [String]

  private var activeDimension: Int = 0
  private var selectedCategoryId: String
  private var selectedGenreLabel: String
  private var selectedArea: String
  private var selectedYear: String

  private let dimensionControl = UISegmentedControl(items: ["类别", "地区", "年份"])
  private let summaryContainer = UIView()
  private let summaryPrefixLabel = UILabel()
  private let summaryValueLabel = UILabel()
  private let topDivider = UIView()
  private let scrollView = UIScrollView()
  private let gridView = MarcoFilterGridContainerView()
  private let bottomDivider = UIView()
  private let bottomBar = UIView()
  private let resetButton = UIButton(type: .system)
  private let applyButton = UIButton(type: .system)

  private var completion: FlutterResult?
  private var resolved = false
  private var navIdentity: ObjectIdentifier?

  static func present(args: [String: Any], completion: @escaping FlutterResult) {
    guard let host = MarcoLiquidGlassSupport.topPresenter() else {
      completion(nil)
      return
    }
    let vc = MarcoNativeFilterSheetController(args: args, completion: completion)
    let nav = UINavigationController(rootViewController: vc)
    let navId = ObjectIdentifier(nav)
    vc.navIdentity = navId
    nav.modalPresentationStyle = .pageSheet
    nav.overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle
    nav.presentationController?.delegate = vc
    if #available(iOS 15.0, *), let sheet = nav.sheetPresentationController {
      sheet.detents = [.medium(), .large()]
      sheet.prefersGrabberVisible = true
      sheet.preferredCornerRadius = 32.0
      sheet.prefersScrollingExpandsWhenScrolledToEdge = true
      sheet.prefersEdgeAttachedInCompactHeight = true
      sheet.widthFollowsPreferredContentSizeWhenEdgeAttached = true
    }
    guard MarcoNativeSheetCoordinator.tryBeginPresentation(
      host: host,
      controller: nav,
      onCancel: { [weak vc] in vc?.finish(applied: false) }
    ) else {
      vc.finish(applied: false)
      return
    }
    MarcoNativeSheetCoordinator.presentRespectingDismissTransition(
      host: host,
      controller: nav,
      identity: navId,
      onRejected: { [weak vc] in vc?.finish(applied: false) }
    )
  }

  private static func cleanOptionLabel(_ raw: String) -> String {
    let filteredScalars = raw.unicodeScalars.filter { scalar in
      let v = scalar.value
      if v <= 0x1F || v == 0x7F || v == 0xAD || v == 0x2060 || v == 0xFEFF {
        return false
      }
      if (v >= 0x200B && v <= 0x200F) || (v >= 0x202A && v <= 0x202E) {
        return false
      }
      return true
    }
    let normalized = String(String.UnicodeScalarView(filteredScalars))
      .replacingOccurrences(of: "\u{3000}", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return "" }
    let hasMeaningfulChar = normalized.unicodeScalars.contains { scalar in
      CharacterSet.alphanumerics.contains(scalar)
        || (scalar.value >= 0x4E00 && scalar.value <= 0x9FFF)
        || (scalar.value >= 0x3400 && scalar.value <= 0x4DBF)
        || (scalar.value >= 0x3040 && scalar.value <= 0x30FF)
        || (scalar.value >= 0xAC00 && scalar.value <= 0xD7AF)
    }
    return hasMeaningfulChar ? normalized : ""
  }

  init(args: [String: Any], completion: @escaping FlutterResult) {
    let rawTitle = (args["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    self.sheetTitle = rawTitle.isEmpty ? "片库筛选" : rawTitle
    let rawCats = (args["categories"] as? [[String: Any]]) ?? []
    var sanitizedCats: [CategoryChoice] = []
    var seenAll = false
    var seenCatIds = Set<String>()
    var seenGenreLabels = Set<String>()
    for raw in rawCats {
      let kind = ((raw["kind"] as? String) ?? "all").trimmingCharacters(in: .whitespacesAndNewlines)
      let id = ((raw["id"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      let label = Self.cleanOptionLabel((raw["label"] as? String) ?? "")
      guard !label.isEmpty else { continue }
      switch kind {
      case "all":
        guard !seenAll else { continue }
        seenAll = true
        sanitizedCats.append(CategoryChoice(id: "", label: label, kind: "all"))
      case "cat":
        guard !id.isEmpty, label != "全部", seenCatIds.insert(id).inserted else { continue }
        sanitizedCats.append(CategoryChoice(id: id, label: label, kind: "cat"))
      default:
        guard label != "全部", seenGenreLabels.insert(label).inserted else { continue }
        sanitizedCats.append(CategoryChoice(id: id.isEmpty ? label : id, label: label, kind: "genre"))
      }
    }
    if sanitizedCats.isEmpty {
      sanitizedCats.append(CategoryChoice(id: "", label: "全部", kind: "all"))
    }
    self.categories = sanitizedCats

    var sanitizedAreas: [String] = []
    var seenAreas = Set<String>()
    for rawArea in (args["areas"] as? [String]) ?? [] {
      let cleaned = Self.cleanOptionLabel(rawArea)
      if !cleaned.isEmpty && seenAreas.insert(cleaned).inserted {
        sanitizedAreas.append(cleaned)
      }
    }
    self.areas = sanitizedAreas

    var sanitizedYears: [String] = []
    var seenYears = Set<String>()
    for rawYear in (args["years"] as? [String]) ?? [] {
      let cleaned = Self.cleanOptionLabel(rawYear)
      if !cleaned.isEmpty && seenYears.insert(cleaned).inserted {
        sanitizedYears.append(cleaned)
      }
    }
    self.years = sanitizedYears
    self.selectedCategoryId = (args["selectedCategoryId"] as? String) ?? ""
    self.selectedGenreLabel = (args["selectedGenreLabel"] as? String) ?? ""
    self.selectedArea = (args["selectedArea"] as? String) ?? ""
    self.selectedYear = (args["selectedYear"] as? String) ?? ""
    self.completion = completion
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
    guard !resolved else { return }
    resolved = true
    let cb = completion
    completion = nil
    let id = navIdentity
    if Thread.isMainThread {
      if let id = id { MarcoNativeSheetCoordinator.didFinish(identity: id) }
      cb?(nil)
    } else {
      DispatchQueue.main.async {
        if let id = id { MarcoNativeSheetCoordinator.didFinish(identity: id) }
        cb?(nil)
      }
    }
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle
    let dark = MarcoLiquidGlassSupport.isEffectiveDark
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      view.backgroundColor = .clear
    } else {
      view.backgroundColor = dark
        ? UIColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1.0)
        : UIColor.systemGroupedBackground
    }
    #else
    view.backgroundColor = dark
      ? UIColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1.0)
      : UIColor.systemGroupedBackground
    #endif

    // Top row: ONLY title ("片库筛选") + Close button ("×").
    navigationItem.title = sheetTitle
    navigationItem.leftBarButtonItem = nil
    let closeBtn = UIBarButtonItem(
      barButtonSystemItem: .close,
      target: self,
      action: #selector(closeTapped)
    )
    closeBtn.accessibilityLabel = "关闭"
    navigationItem.rightBarButtonItem = closeBtn

    dimensionControl.translatesAutoresizingMaskIntoConstraints = false
    dimensionControl.selectedSegmentIndex = activeDimension
    dimensionControl.addTarget(self, action: #selector(dimensionChanged(_:)), for: .valueChanged)
    view.addSubview(dimensionControl)

    summaryContainer.translatesAutoresizingMaskIntoConstraints = false
    summaryContainer.layer.cornerRadius = 10.0
    summaryContainer.layer.cornerCurve = .continuous
    view.addSubview(summaryContainer)

    summaryPrefixLabel.translatesAutoresizingMaskIntoConstraints = false
    summaryPrefixLabel.text = "已选："
    summaryPrefixLabel.font = UIFont.systemFont(ofSize: 12.5, weight: .semibold)
    summaryPrefixLabel.textColor = dark ? UIColor.white.withAlphaComponent(0.62) : UIColor.secondaryLabel
    summaryPrefixLabel.setContentHuggingPriority(.required, for: .horizontal)
    summaryPrefixLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
    summaryContainer.addSubview(summaryPrefixLabel)

    summaryValueLabel.translatesAutoresizingMaskIntoConstraints = false
    summaryValueLabel.font = UIFont.systemFont(ofSize: 13.0, weight: .semibold)
    summaryValueLabel.numberOfLines = 2
    summaryValueLabel.lineBreakMode = .byTruncatingTail
    summaryContainer.addSubview(summaryValueLabel)

    let hairlineColor = dark
      ? UIColor.white.withAlphaComponent(0.10)
      : UIColor.black.withAlphaComponent(0.08)
    topDivider.translatesAutoresizingMaskIntoConstraints = false
    topDivider.backgroundColor = hairlineColor
    view.addSubview(topDivider)

    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.alwaysBounceVertical = true
    scrollView.showsVerticalScrollIndicator = false
    view.addSubview(scrollView)

    gridView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.addSubview(gridView)

    bottomDivider.translatesAutoresizingMaskIntoConstraints = false
    bottomDivider.backgroundColor = hairlineColor
    view.addSubview(bottomDivider)

    bottomBar.translatesAutoresizingMaskIntoConstraints = false
    bottomBar.backgroundColor = .clear
    view.addSubview(bottomBar)

    resetButton.translatesAutoresizingMaskIntoConstraints = false
    resetButton.accessibilityLabel = "重置"
    resetButton.addTarget(self, action: #selector(resetTapped), for: .touchUpInside)
    bottomBar.addSubview(resetButton)

    applyButton.translatesAutoresizingMaskIntoConstraints = false
    applyButton.accessibilityLabel = "应用"
    applyButton.addTarget(self, action: #selector(applyTapped), for: .touchUpInside)
    bottomBar.addSubview(applyButton)

    styleBottomButtons()

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleSceneActivationChanged),
      name: MarcoLiquidGlassSupport.sceneActivationChangedNotification,
      object: nil
    )

    NSLayoutConstraint.activate([
      dimensionControl.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8.0),
      dimensionControl.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16.0),
      dimensionControl.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16.0),
      dimensionControl.heightAnchor.constraint(greaterThanOrEqualToConstant: 36.0),

      summaryContainer.topAnchor.constraint(equalTo: dimensionControl.bottomAnchor, constant: 10.0),
      summaryContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16.0),
      summaryContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16.0),

      summaryPrefixLabel.leadingAnchor.constraint(equalTo: summaryContainer.leadingAnchor, constant: 12.0),
      summaryPrefixLabel.topAnchor.constraint(equalTo: summaryContainer.topAnchor, constant: 8.0),
      summaryPrefixLabel.bottomAnchor.constraint(equalTo: summaryContainer.bottomAnchor, constant: -8.0),

      summaryValueLabel.leadingAnchor.constraint(equalTo: summaryPrefixLabel.trailingAnchor, constant: 2.0),
      summaryValueLabel.trailingAnchor.constraint(equalTo: summaryContainer.trailingAnchor, constant: -12.0),
      summaryValueLabel.centerYAnchor.constraint(equalTo: summaryPrefixLabel.centerYAnchor),

      topDivider.topAnchor.constraint(equalTo: summaryContainer.bottomAnchor, constant: 10.0),
      topDivider.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      topDivider.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      topDivider.heightAnchor.constraint(equalToConstant: 0.5),

      scrollView.topAnchor.constraint(equalTo: topDivider.bottomAnchor),
      scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: bottomDivider.topAnchor),

      gridView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 14.0),
      gridView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -18.0),
      gridView.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 16.0),
      gridView.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -16.0),

      bottomDivider.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      bottomDivider.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      bottomDivider.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),
      bottomDivider.heightAnchor.constraint(equalToConstant: 0.5),

      bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      bottomBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

      resetButton.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 16.0),
      resetButton.topAnchor.constraint(equalTo: bottomBar.topAnchor, constant: 12.0),
      resetButton.bottomAnchor.constraint(equalTo: bottomBar.bottomAnchor, constant: -12.0),
      resetButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 46.0),

      applyButton.leadingAnchor.constraint(equalTo: resetButton.trailingAnchor, constant: 12.0),
      applyButton.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -16.0),
      applyButton.topAnchor.constraint(equalTo: bottomBar.topAnchor, constant: 12.0),
      applyButton.bottomAnchor.constraint(equalTo: bottomBar.bottomAnchor, constant: -12.0),
      applyButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 46.0),
      applyButton.widthAnchor.constraint(equalTo: resetButton.widthAnchor, multiplier: 1.45),
    ])

    rebuildActiveDimensionGrid()
    refreshSummaryAndButtons()
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
      rebuildActiveDimensionGrid()
    }
  }

  override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
    super.viewWillTransition(to: size, with: coordinator)
    coordinator.animate(alongsideTransition: { _ in
      self.gridView.setNeedsLayout()
      self.gridView.layoutIfNeeded()
    })
  }

  private func styleBottomButtons() {
    let dark = MarcoLiquidGlassSupport.isEffectiveDark
    let hasAny = hasAnyDraftFilter
    if #available(iOS 15.0, *) {
      var resetCfg = UIButton.Configuration.filled()
      var resetTitle = AttributedString("重置")
      resetTitle.font = UIFont.systemFont(ofSize: 15.0, weight: .semibold)
      resetCfg.attributedTitle = resetTitle
      resetCfg.baseBackgroundColor = dark
        ? UIColor.white.withAlphaComponent(hasAny ? 0.14 : 0.06)
        : UIColor.black.withAlphaComponent(hasAny ? 0.08 : 0.03)
      resetCfg.baseForegroundColor = hasAny
        ? (dark ? .white : .label)
        : (dark ? UIColor.white.withAlphaComponent(0.32) : UIColor.tertiaryLabel)
      resetCfg.background.cornerRadius = 14.0
      resetButton.configuration = resetCfg

      var applyCfg = UIButton.Configuration.filled()
      var applyTitle = AttributedString("应用")
      applyTitle.font = UIFont.systemFont(ofSize: 15.0, weight: .bold)
      applyCfg.attributedTitle = applyTitle
      applyCfg.baseBackgroundColor = UIColor.systemBlue
      applyCfg.baseForegroundColor = .white
      applyCfg.background.cornerRadius = 14.0
      applyButton.configuration = applyCfg
    } else {
      resetButton.setTitle("重置", for: .normal)
      resetButton.titleLabel?.font = UIFont.systemFont(ofSize: 15.0, weight: .semibold)
      resetButton.layer.cornerRadius = 14.0
      applyButton.setTitle("应用", for: .normal)
      applyButton.titleLabel?.font = UIFont.systemFont(ofSize: 15.0, weight: .bold)
      applyButton.backgroundColor = UIColor.systemBlue
      applyButton.setTitleColor(.white, for: .normal)
      applyButton.layer.cornerRadius = 14.0
    }
    resetButton.isEnabled = hasAny
  }

  private var hasAnyDraftFilter: Bool {
    return !selectedCategoryId.isEmpty || !selectedGenreLabel.isEmpty || !selectedArea.isEmpty || !selectedYear.isEmpty
  }

  private func formattedSummary() -> String {
    var parts: [String] = []
    if !selectedCategoryId.isEmpty {
      if let matched = categories.first(where: { $0.kind == "cat" && $0.id == selectedCategoryId }) {
        parts.append(matched.label)
      } else {
        parts.append(selectedCategoryId)
      }
    } else if !selectedGenreLabel.isEmpty {
      parts.append(selectedGenreLabel)
    }
    if !selectedArea.isEmpty {
      parts.append(selectedArea)
    }
    if !selectedYear.isEmpty {
      parts.append(selectedYear)
    }
    return parts.isEmpty ? "全部" : parts.joined(separator: " · ")
  }

  private func refreshSummaryAndButtons() {
    let dark = MarcoLiquidGlassSupport.isEffectiveDark
    let hasAny = hasAnyDraftFilter
    let catActive = !selectedCategoryId.isEmpty || !selectedGenreLabel.isEmpty
    let areaActive = !selectedArea.isEmpty
    let yearActive = !selectedYear.isEmpty
    dimensionControl.setTitle(catActive ? "类别 •" : "类别", forSegmentAt: 0)
    dimensionControl.setTitle(areaActive ? "地区 •" : "地区", forSegmentAt: 1)
    dimensionControl.setTitle(yearActive ? "年份 •" : "年份", forSegmentAt: 2)
    summaryValueLabel.text = formattedSummary()
    summaryValueLabel.textColor = hasAny
      ? UIColor.systemBlue
      : (dark ? UIColor.white.withAlphaComponent(0.62) : UIColor.secondaryLabel)
    summaryContainer.backgroundColor = hasAny
      ? UIColor.systemBlue.withAlphaComponent(dark ? 0.16 : 0.09)
      : (dark ? UIColor.white.withAlphaComponent(0.05) : UIColor.black.withAlphaComponent(0.04))
    styleBottomButtons()
  }

  private func rebuildActiveDimensionGrid() {
    let dark = MarcoLiquidGlassSupport.isEffectiveDark
    var cells: [MarcoFilterOptionCellButton] = []
    switch activeDimension {
    case 0:
      for (idx, choice) in categories.enumerated() {
        let cell = MarcoFilterOptionCellButton()
        cell.tag = idx
        let isSelected: Bool
        switch choice.kind {
        case "all":
          isSelected = selectedCategoryId.isEmpty && selectedGenreLabel.isEmpty
        case "cat":
          isSelected = selectedCategoryId == choice.id
        default:
          isSelected = selectedCategoryId.isEmpty && selectedGenreLabel == choice.label
        }
        cell.configure(title: choice.label, selected: isSelected, dark: dark)
        cell.addTarget(self, action: #selector(categoryTapped(_:)), for: .touchUpInside)
        cells.append(cell)
      }
    case 1:
      for (idx, area) in areas.enumerated() {
        let cell = MarcoFilterOptionCellButton()
        cell.tag = idx
        let isSelected = (selectedArea.isEmpty && area == "全部") || selectedArea == area
        cell.configure(title: area, selected: isSelected, dark: dark)
        cell.addTarget(self, action: #selector(areaTapped(_:)), for: .touchUpInside)
        cells.append(cell)
      }
    default:
      for (idx, yr) in years.enumerated() {
        let cell = MarcoFilterOptionCellButton()
        cell.tag = idx
        let isSelected = (selectedYear.isEmpty && yr == "全部") || selectedYear == yr
        cell.configure(title: yr, selected: isSelected, dark: dark)
        cell.addTarget(self, action: #selector(yearTapped(_:)), for: .touchUpInside)
        cells.append(cell)
      }
    }
    gridView.setCells(cells)
  }

  @objc private func dimensionChanged(_ sender: UISegmentedControl) {
    activeDimension = sender.selectedSegmentIndex
    UISelectionFeedbackGenerator().selectionChanged()
    scrollView.setContentOffset(.zero, animated: false)
    rebuildActiveDimensionGrid()
  }

  @objc private func categoryTapped(_ sender: UIControl) {
    let idx = sender.tag
    guard idx >= 0, idx < categories.count else { return }
    let choice = categories[idx]
    switch choice.kind {
    case "all":
      selectedCategoryId = ""
      selectedGenreLabel = ""
    case "cat":
      selectedCategoryId = choice.id
      selectedGenreLabel = ""
    default:
      selectedCategoryId = ""
      selectedGenreLabel = choice.label
    }
    UISelectionFeedbackGenerator().selectionChanged()
    rebuildActiveDimensionGrid()
    refreshSummaryAndButtons()
  }

  @objc private func areaTapped(_ sender: UIControl) {
    let idx = sender.tag
    guard idx >= 0, idx < areas.count else { return }
    let val = areas[idx]
    selectedArea = (val == "全部") ? "" : val
    UISelectionFeedbackGenerator().selectionChanged()
    rebuildActiveDimensionGrid()
    refreshSummaryAndButtons()
  }

  @objc private func yearTapped(_ sender: UIControl) {
    let idx = sender.tag
    guard idx >= 0, idx < years.count else { return }
    let val = years[idx]
    selectedYear = (val == "全部") ? "" : val
    UISelectionFeedbackGenerator().selectionChanged()
    rebuildActiveDimensionGrid()
    refreshSummaryAndButtons()
  }

  @objc private func resetTapped() {
    selectedCategoryId = ""
    selectedGenreLabel = ""
    selectedArea = ""
    selectedYear = ""
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    rebuildActiveDimensionGrid()
    refreshSummaryAndButtons()
  }

  @objc private func handleSceneActivationChanged() {
    let active = MarcoLiquidGlassSupport.isSceneActive
    UIView.animate(withDuration: 0.18) {
      self.view.alpha = active ? 1.0 : 0.90
    }
  }

  @objc private func closeTapped() {
    finish(applied: false)
    dismiss(animated: true, completion: nil)
  }

  @objc private func applyTapped() {
    finish(applied: true)
    dismiss(animated: true, completion: nil)
  }

  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    finish(applied: false)
  }

  private func finish(applied: Bool) {
    guard !resolved else { return }
    resolved = true
    if let id = navIdentity {
      MarcoNativeSheetCoordinator.didFinish(identity: id)
    }
    let cb = completion
    completion = nil
    if !applied {
      cb?(nil)
      return
    }
    cb?([
      "categoryId": selectedCategoryId,
      "genreLabel": selectedGenreLabel,
      "area": selectedArea,
      "year": selectedYear,
    ])
  }
}

// MARK: - Native iOS 26 Centered Liquid Glass Privacy Passcode Modal

private final class MarcoNativePinSheetController: UIViewController {
  private let sessionId: String
  private let mode: String // "verify" | "set"
  private let initialTitle: String
  private let initialSubtitle: String
  private let confirmTitle: String
  private let confirmSubtitle: String
  private let pinLength: Int
  private let loadingText: String
  private let mismatchError: String

  private var firstPin: String = ""
  private var enteredPin: String = ""
  private var confirming: Bool = false
  private var isBusy: Bool = false
  private var errorMessage: String?

  private let backdropControl = UIControl()
  private let cardShadowView = UIView()
  private var cardEffectView: UIVisualEffectView!
  private let scrollView = UIScrollView()
  private let contentView = UIView()
  private let badgeView = UIView()
  private let badgeGradient = CAGradientLayer()
  private let badgeIconView = UIImageView()
  private let badgeSpinner = UIActivityIndicatorView(style: .medium)
  private let titleLabel = UILabel()
  private let subtitleLabel = UILabel()
  private let dotsStack = UIStackView()
  private var dotViews: [UIView] = []
  private let keypadStack = UIStackView()
  private var digitButtons: [UIButton] = []
  private let cancelButton = UIButton(type: .system)
  private let backspaceButton = UIButton(type: .system)

  private var completion: FlutterResult?
  private var resolved = false
  private var didAnimateIn = false
  private var resetWorkItem: DispatchWorkItem?

  static func present(args: [String: Any], completion: @escaping FlutterResult) {
    guard let host = MarcoLiquidGlassSupport.topPresenter() else {
      completion(nil)
      return
    }
    let vc = MarcoNativePinSheetController(args: args, completion: completion)
    vc.modalPresentationStyle = .overFullScreen
    vc.modalTransitionStyle = .crossDissolve
    vc.overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle
    host.present(vc, animated: false, completion: nil)
  }

  init(args: [String: Any], completion: @escaping FlutterResult) {
    self.sessionId = (args["sessionId"] as? String) ?? UUID().uuidString
    self.mode = (args["mode"] as? String) ?? "verify"
    self.initialTitle = (args["title"] as? String) ?? "解锁隐私空间"
    self.initialSubtitle = (args["subtitle"] as? String) ?? "输入设置的密码即可直接进入隐私分组模式"
    self.confirmTitle = (args["confirmTitle"] as? String) ?? "再次输入确认密码"
    self.confirmSubtitle = (args["confirmSubtitle"] as? String) ?? "请再次输入刚才设置的 4 位数字密码"
    let rawLen = (args["pinLength"] as? NSNumber)?.intValue ?? 4
    self.pinLength = max(4, min(rawLen, 8))
    self.loadingText = (args["loadingText"] as? String) ?? (self.mode == "set" ? "正在加密保存密码…" : "正在验证密码…")
    self.mismatchError = (args["mismatchError"] as? String) ?? "两次输入的密码不一致，请重新设置"
    self.completion = completion
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
    resetWorkItem?.cancel()
    finish(succeeded: false)
  }

  override var canBecomeFirstResponder: Bool {
    return true
  }

  override var keyCommands: [UIKeyCommand]? {
    var cmds: [UIKeyCommand] = []
    for d in 0...9 {
      cmds.append(UIKeyCommand(input: "\(d)", modifierFlags: [], action: #selector(handleDigitKeyCommand(_:))))
    }
    cmds.append(UIKeyCommand(input: "\u{8}", modifierFlags: [], action: #selector(backspaceTapped)))
    cmds.append(UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancelTapped)))
    return cmds
  }

  private var isDarkPin: Bool {
    return MarcoLiquidGlassSupport.isEffectiveDark(for: isViewLoaded ? view : nil)
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
      applyPinTheme()
      refreshUI(animatedDotIndex: nil)
    }
  }

  private func applyPinTheme() {
    let dark = isDarkPin
    let style = MarcoLiquidGlassSupport.interfaceStyle
    overrideUserInterfaceStyle = style
    cardEffectView.overrideUserInterfaceStyle = style
    backdropControl.backgroundColor = dark
      ? UIColor.black.withAlphaComponent(0.58)
      : UIColor.black.withAlphaComponent(0.32)
    cardShadowView.layer.shadowOpacity = dark ? 0.45 : 0.22
    cardEffectView.layer.borderColor = (dark
      ? UIColor.white.withAlphaComponent(0.18)
      : UIColor.black.withAlphaComponent(0.10)).cgColor
    titleLabel.textColor = dark ? .white : UIColor.label
    for btn in digitButtons {
      btn.overrideUserInterfaceStyle = style
      let fg = dark ? UIColor.white : UIColor.label
      let bg = dark ? UIColor(white: 0.22, alpha: 0.85) : UIColor.secondarySystemFill
      if #available(iOS 15.0, *) {
        if var cfg = btn.configuration {
          cfg.baseForegroundColor = fg
          if #unavailable(iOS 26.0) {
            cfg.baseBackgroundColor = bg
          }
          btn.configuration = cfg
        }
      } else {
        btn.setTitleColor(fg, for: .normal)
        btn.backgroundColor = bg
      }
    }
    cancelButton.overrideUserInterfaceStyle = style
    let cancelFg = dark ? UIColor.white.withAlphaComponent(0.78) : UIColor.secondaryLabel
    if #available(iOS 15.0, *) {
      if var cfg = cancelButton.configuration {
        cfg.baseForegroundColor = cancelFg
        cancelButton.configuration = cfg
      }
    } else {
      cancelButton.setTitleColor(cancelFg, for: .normal)
    }
    backspaceButton.overrideUserInterfaceStyle = style
    let backFg = dark ? UIColor.white.withAlphaComponent(0.84) : UIColor.label
    if #available(iOS 15.0, *) {
      if var cfg = backspaceButton.configuration {
        cfg.baseForegroundColor = backFg
        backspaceButton.configuration = cfg
      }
    } else {
      backspaceButton.tintColor = backFg
    }
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    let style = MarcoLiquidGlassSupport.interfaceStyle
    let dark = isDarkPin
    overrideUserInterfaceStyle = style
    view.backgroundColor = .clear

    backdropControl.backgroundColor = dark
      ? UIColor.black.withAlphaComponent(0.58)
      : UIColor.black.withAlphaComponent(0.32)
    backdropControl.translatesAutoresizingMaskIntoConstraints = false
    backdropControl.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
    view.addSubview(backdropControl)

    cardShadowView.backgroundColor = .clear
    cardShadowView.translatesAutoresizingMaskIntoConstraints = false
    cardShadowView.layer.shadowColor = UIColor.black.cgColor
    cardShadowView.layer.shadowOpacity = dark ? 0.45 : 0.22
    cardShadowView.layer.shadowRadius = 28.0
    cardShadowView.layer.shadowOffset = CGSize(width: 0, height: 14)
    view.addSubview(cardShadowView)

    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      let glass = UIGlassEffect(style: .regular)
      cardEffectView = UIVisualEffectView(effect: glass)
    } else {
      cardEffectView = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
    }
    #else
    cardEffectView = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
    #endif
    cardEffectView.overrideUserInterfaceStyle = style
    cardEffectView.translatesAutoresizingMaskIntoConstraints = false
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      cardEffectView.cornerConfiguration = .corners(radius: .containerConcentric(minimum: 26.0))
    } else {
      cardEffectView.layer.cornerRadius = 34.0
      cardEffectView.layer.cornerCurve = .continuous
      cardEffectView.clipsToBounds = true
    }
    #else
    cardEffectView.layer.cornerRadius = 34.0
    cardEffectView.layer.cornerCurve = .continuous
    cardEffectView.clipsToBounds = true
    #endif
    cardEffectView.layer.borderWidth = 0.65
    cardEffectView.layer.borderColor = (dark
      ? UIColor.white.withAlphaComponent(0.18)
      : UIColor.black.withAlphaComponent(0.10)).cgColor
    cardShadowView.addSubview(cardEffectView)

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handlePinSceneActivationChanged),
      name: MarcoLiquidGlassSupport.sceneActivationChangedNotification,
      object: nil
    )

    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.showsVerticalScrollIndicator = false
    scrollView.alwaysBounceVertical = false
    cardEffectView.contentView.addSubview(scrollView)

    contentView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.addSubview(contentView)

    // Shield badge
    badgeView.translatesAutoresizingMaskIntoConstraints = false
    badgeView.layer.cornerRadius = 25.0
    badgeView.layer.masksToBounds = false
    badgeView.layer.shadowColor = UIColor(red: 0.545, green: 0.361, blue: 0.965, alpha: 1.0).cgColor
    badgeView.layer.shadowOpacity = 0.45
    badgeView.layer.shadowRadius = 14.0
    badgeView.layer.shadowOffset = CGSize(width: 0, height: 4)

    badgeGradient.colors = [
      UIColor(red: 0.545, green: 0.361, blue: 0.965, alpha: 1.0).cgColor,
      UIColor(red: 0.310, green: 0.275, blue: 0.898, alpha: 1.0).cgColor,
    ]
    badgeGradient.startPoint = CGPoint(x: 0.0, y: 0.0)
    badgeGradient.endPoint = CGPoint(x: 1.0, y: 1.0)
    badgeGradient.cornerRadius = 25.0
    badgeView.layer.insertSublayer(badgeGradient, at: 0)

    let shieldCfg = UIImage.SymbolConfiguration(pointSize: 22.0, weight: .semibold)
    badgeIconView.image = UIImage(systemName: "lock.shield.fill", withConfiguration: shieldCfg)
    badgeIconView.tintColor = .white
    badgeIconView.contentMode = .scaleAspectFit
    badgeIconView.translatesAutoresizingMaskIntoConstraints = false
    badgeView.addSubview(badgeIconView)

    badgeSpinner.color = .white
    badgeSpinner.hidesWhenStopped = true
    badgeSpinner.translatesAutoresizingMaskIntoConstraints = false
    badgeView.addSubview(badgeSpinner)

    contentView.addSubview(badgeView)

    // Title & subtitle
    titleLabel.font = UIFont.systemFont(ofSize: 19.0, weight: .bold)
    titleLabel.textColor = dark ? .white : UIColor.label
    titleLabel.textAlignment = .center
    titleLabel.numberOfLines = 1
    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(titleLabel)

    subtitleLabel.font = UIFont.systemFont(ofSize: 12.5, weight: .regular)
    subtitleLabel.textColor = dark ? UIColor.white.withAlphaComponent(0.74) : UIColor.secondaryLabel
    subtitleLabel.textAlignment = .center
    subtitleLabel.numberOfLines = 2
    subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(subtitleLabel)

    // PIN dots
    dotsStack.axis = .horizontal
    dotsStack.alignment = .center
    dotsStack.spacing = pinLength > 6 ? 10.0 : 15.0
    dotsStack.translatesAutoresizingMaskIntoConstraints = false
    for _ in 0..<pinLength {
      let dot = UIView()
      dot.translatesAutoresizingMaskIntoConstraints = false
      dot.layer.cornerRadius = 7.0
      dot.layer.borderWidth = 1.2
      NSLayoutConstraint.activate([
        dot.widthAnchor.constraint(equalToConstant: 14.0),
        dot.heightAnchor.constraint(equalToConstant: 14.0),
      ])
      dotsStack.addArrangedSubview(dot)
      dotViews.append(dot)
    }
    contentView.addSubview(dotsStack)

    // 3x4 Liquid Glass Keypad — adapt smoothly to iPhone Duo 5.4" outer display (678pt),
    // inner/outer landscape, and narrow Split View panes (< 360pt) without UIScreen.main.
    let winBounds = MarcoLiquidGlassSupport.activeWindowBounds(for: view)
    let isCompactSize = winBounds.height < 690.0 || winBounds.width < 360.0
    let keySize: CGFloat = isCompactSize ? 60.0 : 68.0
    let rowSpacing: CGFloat = isCompactSize ? 10.0 : 12.0
    let colSpacing: CGFloat = isCompactSize ? 14.0 : 20.0

    keypadStack.axis = .vertical
    keypadStack.alignment = .center
    keypadStack.spacing = rowSpacing
    keypadStack.translatesAutoresizingMaskIntoConstraints = false

    let digitRows = [
      ["1", "2", "3"],
      ["4", "5", "6"],
      ["7", "8", "9"],
    ]
    for row in digitRows {
      let rowStack = UIStackView()
      rowStack.axis = .horizontal
      rowStack.alignment = .center
      rowStack.spacing = colSpacing
      for digit in row {
        let btn = makeDigitButton(digit: digit, size: keySize)
        digitButtons.append(btn)
        rowStack.addArrangedSubview(btn)
      }
      keypadStack.addArrangedSubview(rowStack)
    }

    // Bottom row: Cancel | 0 | Backspace
    let bottomRow = UIStackView()
    bottomRow.axis = .horizontal
    bottomRow.alignment = .center
    bottomRow.spacing = colSpacing

    configureCancelButton(size: keySize)
    let zeroBtn = makeDigitButton(digit: "0", size: keySize)
    digitButtons.append(zeroBtn)
    configureBackspaceButton(size: keySize)

    bottomRow.addArrangedSubview(cancelButton)
    bottomRow.addArrangedSubview(zeroBtn)
    bottomRow.addArrangedSubview(backspaceButton)
    keypadStack.addArrangedSubview(bottomRow)
    contentView.addSubview(keypadStack)

    let preferredCardWidth = cardShadowView.widthAnchor.constraint(equalToConstant: 332.0)
    preferredCardWidth.priority = UILayoutPriority(999)
    let fitScrollHeight = scrollView.heightAnchor.constraint(equalTo: contentView.heightAnchor)
    fitScrollHeight.priority = .defaultHigh

    NSLayoutConstraint.activate([
      backdropControl.topAnchor.constraint(equalTo: view.topAnchor),
      backdropControl.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      backdropControl.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      backdropControl.trailingAnchor.constraint(equalTo: view.trailingAnchor),

      cardShadowView.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
      cardShadowView.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
      preferredCardWidth,
      cardShadowView.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 18.0),
      cardShadowView.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -18.0),
      cardShadowView.heightAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.heightAnchor, constant: -32.0),

      cardEffectView.topAnchor.constraint(equalTo: cardShadowView.topAnchor),
      cardEffectView.bottomAnchor.constraint(equalTo: cardShadowView.bottomAnchor),
      cardEffectView.leadingAnchor.constraint(equalTo: cardShadowView.leadingAnchor),
      cardEffectView.trailingAnchor.constraint(equalTo: cardShadowView.trailingAnchor),

      scrollView.topAnchor.constraint(equalTo: cardEffectView.contentView.topAnchor),
      scrollView.bottomAnchor.constraint(equalTo: cardEffectView.contentView.bottomAnchor),
      scrollView.leadingAnchor.constraint(equalTo: cardEffectView.contentView.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: cardEffectView.contentView.trailingAnchor),
      fitScrollHeight,

      contentView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
      contentView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
      contentView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
      contentView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
      contentView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),

      badgeView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24.0),
      badgeView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
      badgeView.widthAnchor.constraint(equalToConstant: 50.0),
      badgeView.heightAnchor.constraint(equalToConstant: 50.0),

      badgeIconView.centerXAnchor.constraint(equalTo: badgeView.centerXAnchor),
      badgeIconView.centerYAnchor.constraint(equalTo: badgeView.centerYAnchor),
      badgeSpinner.centerXAnchor.constraint(equalTo: badgeView.centerXAnchor),
      badgeSpinner.centerYAnchor.constraint(equalTo: badgeView.centerYAnchor),

      titleLabel.topAnchor.constraint(equalTo: badgeView.bottomAnchor, constant: 12.0),
      titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 22.0),
      titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -22.0),

      subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 5.0),
      subtitleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24.0),
      subtitleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24.0),

      dotsStack.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 18.0),
      dotsStack.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),

      keypadStack.topAnchor.constraint(equalTo: dotsStack.bottomAnchor, constant: 22.0),
      keypadStack.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
      keypadStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -22.0),
    ])

    backdropControl.alpha = 0.0
    cardShadowView.alpha = 0.0
    cardShadowView.transform = UIAccessibility.isReduceMotionEnabled
      ? .identity
      : CGAffineTransform(scaleX: 0.90, y: 0.90)
    refreshUI(animatedDotIndex: nil)
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    becomeFirstResponder()
    guard !didAnimateIn else { return }
    didAnimateIn = true
    if UIAccessibility.isReduceMotionEnabled {
      UIView.animate(
        withDuration: 0.16,
        delay: 0,
        options: [.curveEaseOut],
        animations: {
          self.backdropControl.alpha = 1.0
          self.cardShadowView.alpha = 1.0
          self.cardShadowView.transform = .identity
        },
        completion: nil
      )
    } else {
      MarcoLiquidGlassSupport.animateSpring(duration: 0.36, bounce: 0.14) {
        self.backdropControl.alpha = 1.0
        self.cardShadowView.alpha = 1.0
        self.cardShadowView.transform = .identity
      }
    }
  }

  @objc private func handlePinSceneActivationChanged() {
    let active = MarcoLiquidGlassSupport.isSceneActive
    UIView.animate(withDuration: 0.18) {
      self.cardEffectView.alpha = active ? 1.0 : 0.90
    }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    badgeGradient.frame = badgeView.bounds
  }

  override func viewWillTransition(
    to size: CGSize,
    with coordinator: UIViewControllerTransitionCoordinator
  ) {
    super.viewWillTransition(to: size, with: coordinator)
    coordinator.animate(alongsideTransition: { [weak self] _ in
      self?.view.setNeedsLayout()
      self?.view.layoutIfNeeded()
    }, completion: nil)
  }

  private func makeDigitButton(digit: String, size: CGFloat) -> UIButton {
    let dark = isDarkPin
    let btn = UIButton(type: .system)
    btn.translatesAutoresizingMaskIntoConstraints = false
    btn.overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle
    btn.tag = Int(digit) ?? 0
    btn.accessibilityLabel = digit
    let font = UIFont.monospacedDigitSystemFont(ofSize: 28.0, weight: .medium)
    let fg: UIColor = dark ? .white : UIColor.label
    let bg: UIColor = dark ? UIColor(white: 0.22, alpha: 0.85) : UIColor.secondarySystemFill
    if #available(iOS 15.0, *) {
      var titleAttr = AttributedString(digit)
      titleAttr.font = font
      #if compiler(>=6.2)
      if #available(iOS 26.0, *) {
        var cfg = UIButton.Configuration.glass()
        cfg.attributedTitle = titleAttr
        cfg.baseForegroundColor = fg
        cfg.cornerStyle = .capsule
        cfg.contentInsets = .zero
        btn.configuration = cfg
        btn.cornerConfiguration = .capsule()
      } else {
        var cfg = UIButton.Configuration.filled()
        cfg.attributedTitle = titleAttr
        cfg.baseForegroundColor = fg
        cfg.baseBackgroundColor = bg
        cfg.cornerStyle = .capsule
        cfg.contentInsets = .zero
        btn.configuration = cfg
      }
      #else
      var cfg = UIButton.Configuration.filled()
      cfg.attributedTitle = titleAttr
      cfg.baseForegroundColor = fg
      cfg.baseBackgroundColor = bg
      cfg.cornerStyle = .capsule
      cfg.contentInsets = .zero
      btn.configuration = cfg
      #endif
    } else {
      btn.setTitle(digit, for: .normal)
      btn.titleLabel?.font = font
      btn.setTitleColor(fg, for: .normal)
      btn.backgroundColor = bg
      btn.layer.cornerRadius = size * 0.5
      btn.layer.masksToBounds = true
    }
    btn.addTarget(self, action: #selector(digitTapped(_:)), for: .touchUpInside)
    NSLayoutConstraint.activate([
      btn.widthAnchor.constraint(equalToConstant: size),
      btn.heightAnchor.constraint(equalToConstant: size),
    ])
    return btn
  }

  private func configureCancelButton(size: CGFloat) {
    let dark = isDarkPin
    cancelButton.translatesAutoresizingMaskIntoConstraints = false
    cancelButton.overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle
    cancelButton.accessibilityLabel = "取消"
    let font = UIFont.systemFont(ofSize: 16.0, weight: .semibold)
    let fg = dark ? UIColor.white.withAlphaComponent(0.78) : UIColor.secondaryLabel
    if #available(iOS 15.0, *) {
      var titleAttr = AttributedString("取消")
      titleAttr.font = font
      var cfg = UIButton.Configuration.plain()
      cfg.attributedTitle = titleAttr
      cfg.baseForegroundColor = fg
      cfg.contentInsets = .zero
      cancelButton.configuration = cfg
    } else {
      cancelButton.setTitle("取消", for: .normal)
      cancelButton.titleLabel?.font = font
      cancelButton.setTitleColor(fg, for: .normal)
    }
    cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
    NSLayoutConstraint.activate([
      cancelButton.widthAnchor.constraint(equalToConstant: size),
      cancelButton.heightAnchor.constraint(equalToConstant: size),
    ])
  }

  private func configureBackspaceButton(size: CGFloat) {
    let dark = isDarkPin
    backspaceButton.translatesAutoresizingMaskIntoConstraints = false
    backspaceButton.overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle
    backspaceButton.accessibilityLabel = "删除"
    let symCfg = UIImage.SymbolConfiguration(pointSize: 22.0, weight: .medium)
    let img = UIImage(systemName: "delete.left.fill", withConfiguration: symCfg)
    let fg = dark ? UIColor.white.withAlphaComponent(0.84) : UIColor.label
    if #available(iOS 15.0, *) {
      var cfg = UIButton.Configuration.plain()
      cfg.image = img
      cfg.baseForegroundColor = fg
      cfg.contentInsets = .zero
      backspaceButton.configuration = cfg
    } else {
      backspaceButton.setImage(img, for: .normal)
      backspaceButton.tintColor = fg
    }
    backspaceButton.addTarget(self, action: #selector(backspaceTapped), for: .touchUpInside)
    NSLayoutConstraint.activate([
      backspaceButton.widthAnchor.constraint(equalToConstant: size),
      backspaceButton.heightAnchor.constraint(equalToConstant: size),
    ])
  }

  private func refreshUI(animatedDotIndex: Int?) {
    let dark = isDarkPin
    titleLabel.text = (mode == "set" && confirming) ? confirmTitle : initialTitle
    titleLabel.textColor = dark ? .white : UIColor.label
    let hasError = !(errorMessage?.isEmpty ?? true)
    if isBusy {
      subtitleLabel.text = loadingText
      subtitleLabel.textColor = dark ? UIColor.white.withAlphaComponent(0.92) : UIColor.label
    } else if hasError {
      subtitleLabel.text = errorMessage
      subtitleLabel.textColor = UIColor.systemRed
    } else {
      subtitleLabel.text = (mode == "set" && confirming) ? confirmSubtitle : initialSubtitle
      subtitleLabel.textColor = dark ? UIColor.white.withAlphaComponent(0.72) : UIColor.secondaryLabel
    }

    badgeIconView.isHidden = isBusy
    if isBusy {
      badgeSpinner.startAnimating()
    } else {
      badgeSpinner.stopAnimating()
    }

    let filledColor = hasError
      ? UIColor.systemRed
      : (dark
          ? UIColor(red: 0.769, green: 0.710, blue: 0.992, alpha: 1.0)
          : UIColor(red: 0.486, green: 0.227, blue: 0.929, alpha: 1.0))
    let filledBorder = hasError
      ? UIColor.systemRed
      : (dark
          ? UIColor(red: 0.655, green: 0.545, blue: 0.980, alpha: 1.0)
          : UIColor(red: 0.427, green: 0.157, blue: 0.851, alpha: 1.0))
    let emptyFill = dark
      ? UIColor.white.withAlphaComponent(0.12)
      : UIColor.black.withAlphaComponent(0.06)
    let emptyBorder = dark
      ? UIColor.white.withAlphaComponent(0.32)
      : UIColor.black.withAlphaComponent(0.24)

    for (idx, dot) in dotViews.enumerated() {
      let filled = idx < enteredPin.count
      dot.backgroundColor = filled ? filledColor : emptyFill
      dot.layer.borderColor = (filled ? filledBorder : emptyBorder).cgColor
      if filled {
        dot.layer.shadowColor = (hasError ? UIColor.systemRed : UIColor(red: 0.545, green: 0.361, blue: 0.965, alpha: 1.0)).cgColor
        dot.layer.shadowOpacity = 0.65
        dot.layer.shadowRadius = 7.0
        dot.layer.shadowOffset = .zero
      } else {
        dot.layer.shadowOpacity = 0.0
      }
      if animatedDotIndex == idx && !UIAccessibility.isReduceMotionEnabled {
        dot.transform = CGAffineTransform(scaleX: 1.32, y: 1.32)
        UIView.animate(
          withDuration: 0.22,
          delay: 0,
          usingSpringWithDamping: 0.62,
          initialSpringVelocity: 0.7,
          options: [.allowUserInteraction],
          animations: { dot.transform = .identity },
          completion: nil
        )
      }
    }

    backspaceButton.alpha = (enteredPin.isEmpty || isBusy) ? 0.35 : 1.0
    backspaceButton.isEnabled = !enteredPin.isEmpty && !isBusy
    for btn in digitButtons {
      btn.isEnabled = !isBusy
    }
  }

  private func shakeDots() {
    if UIAccessibility.isReduceMotionEnabled {
      // Under Reduce Motion, omit horizontal shake while preserving immediate
      // error color/border styling, message text, and notification haptics.
      return
    }
    let anim = CAKeyframeAnimation(keyPath: "transform.translation.x")
    anim.timingFunction = CAMediaTimingFunction(name: .linear)
    anim.duration = 0.36
    anim.values = [-12.0, 12.0, -9.0, 9.0, -5.0, 5.0, 0.0]
    dotsStack.layer.add(anim, forKey: "marcoPinShake")
  }

  @objc private func handleDigitKeyCommand(_ cmd: UIKeyCommand) {
    guard let input = cmd.input else { return }
    appendDigit(input)
  }

  @objc private func digitTapped(_ sender: UIButton) {
    appendDigit("\(sender.tag)")
  }

  private func appendDigit(_ digit: String) {
    guard !isBusy, !resolved, enteredPin.count < pinLength else { return }
    resetWorkItem?.cancel()
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    errorMessage = nil
    enteredPin.append(digit)
    refreshUI(animatedDotIndex: enteredPin.count - 1)

    guard enteredPin.count == pinLength else { return }
    let completedPin = enteredPin

    if mode == "set" {
      if !confirming {
        isBusy = true
        let work = DispatchWorkItem { [weak self] in
          guard let self = self, !self.resolved else { return }
          self.isBusy = false
          self.firstPin = completedPin
          self.enteredPin = ""
          self.confirming = true
          UIView.transition(
            with: self.contentView,
            duration: 0.22,
            options: [.transitionCrossDissolve, .allowUserInteraction],
            animations: { self.refreshUI(animatedDotIndex: nil) },
            completion: nil
          )
        }
        resetWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: work)
        return
      }
      if completedPin != firstPin {
        triggerError(mismatchError, resetToFirstStep: true)
        return
      }
    }

    submitPinToFlutter(completedPin)
  }

  private func submitPinToFlutter(_ pin: String) {
    guard let channel = MarcoLiquidGlassSupport.bridgeChannel else {
      dismissAnimated(succeeded: false)
      return
    }
    isBusy = true
    errorMessage = nil
    refreshUI(animatedDotIndex: nil)

    channel.invokeMethod(
      "privacyPinCallback",
      arguments: [
        "sessionId": sessionId,
        "mode": mode,
        "pin": pin,
      ]
    ) { [weak self] response in
      DispatchQueue.main.async {
        guard let self = self, !self.resolved else { return }
        let dict = response as? [String: Any]
        let ok = (dict?["ok"] as? Bool) ?? false
        if ok {
          UINotificationFeedbackGenerator().notificationOccurred(.success)
          self.dismissAnimated(succeeded: true)
        } else {
          let errText = (dict?["error"] as? String) ?? "密码错误，请重新输入"
          self.triggerError(errText, resetToFirstStep: self.mode == "set")
        }
      }
    }
  }

  private func triggerError(_ message: String, resetToFirstStep: Bool) {
    UINotificationFeedbackGenerator().notificationOccurred(.error)
    isBusy = false
    errorMessage = message
    refreshUI(animatedDotIndex: nil)
    shakeDots()

    resetWorkItem?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self = self, !self.resolved else { return }
      self.enteredPin = ""
      if resetToFirstStep {
        self.firstPin = ""
        self.confirming = false
      }
      self.refreshUI(animatedDotIndex: nil)
    }
    resetWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.36, execute: work)
  }

  @objc private func backspaceTapped() {
    guard !isBusy, !enteredPin.isEmpty else { return }
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    errorMessage = nil
    enteredPin.removeLast()
    refreshUI(animatedDotIndex: nil)
  }

  @objc private func cancelTapped() {
    dismissAnimated(succeeded: false)
  }

  private func dismissAnimated(succeeded: Bool) {
    finish(succeeded: succeeded)
    let reduceMotion = UIAccessibility.isReduceMotionEnabled
    UIView.animate(
      withDuration: reduceMotion ? 0.14 : 0.18,
      delay: 0,
      options: [.curveEaseIn],
      animations: {
        self.backdropControl.alpha = 0.0
        self.cardShadowView.alpha = 0.0
        self.cardShadowView.transform = reduceMotion
          ? .identity
          : CGAffineTransform(scaleX: 0.92, y: 0.92)
      }
    ) { _ in
      self.dismiss(animated: false, completion: nil)
    }
  }

  private func finish(succeeded: Bool) {
    guard !resolved else { return }
    resolved = true
    let cb = completion
    completion = nil
    cb?(succeeded)
  }
}

// MARK: - 1. Native iOS 26 Floating Liquid Glass Dock (Full 62pt 4+1 & Scroll-Collapsed Logo Menu)

private final class MarcoNativeDockFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    return FlutterStandardMessageCodec.sharedInstance()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    return MarcoNativeDockPlatformView(
      frame: frame,
      viewId: viewId,
      arguments: args as? [String: Any],
      messenger: messenger
    )
  }
}

private final class MarcoTraitAwareHostView: UIView {
  var onTraitChanged: (() -> Void)?

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window != nil {
      MarcoLiquidGlassSupport.bringRootChromeToFront()
      DispatchQueue.main.async {
        MarcoLiquidGlassSupport.bringRootChromeToFront()
      }
    }
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
      onTraitChanged?()
    }
  }
}

/// Apple HIG native SF Symbols tab icon view for the floating Liquid Glass Dock.
///
/// Uses genuine Apple SF Symbols (`house`, `play.tv`, `rectangle.stack`,
/// `gearshape`, all available natively on iOS 14.0 through iOS 26+) at Apple's
/// exact tab-bar optical weight with monochrome tinting and native iOS 17+
/// `.bounce` SF Symbol effects.
private final class MarcoAnimatedTabIconView: UIView {
  enum Kind: String {
    case home
    case live
    case library
    case settings
    case fallback

    static func resolve(kind: String?, symbol: String, label: String) -> Kind {
      if let k = kind?.lowercased(), let parsed = Kind(rawValue: k) {
        return parsed
      }
      let sym = symbol.lowercased()
      if sym.contains("play.rectangle") || sym.contains("house") || label.contains("主页") {
        return .home
      }
      if sym.contains("radiowaves") || sym.contains("antenna") || sym.contains("tv") || label.contains("直播") {
        return .live
      }
      if sym.contains("square.stack") || sym.contains("rectangle.stack") || sym.contains("film") || sym.contains("bookmark") || label.contains("片库") {
        return .library
      }
      if sym.contains("gear") || sym.contains("slider") || label.contains("设置") {
        return .settings
      }
      return .fallback
    }

    func appleSymbolName(selected: Bool, fallback: String) -> String {
      switch self {
      case .home:
        return selected ? "house.fill" : "house"
      case .live:
        return selected ? "play.tv.fill" : "play.tv"
      case .library:
        return selected ? "rectangle.stack.fill" : "rectangle.stack"
      case .settings:
        return selected ? "gearshape.fill" : "gearshape"
      case .fallback:
        return fallback
      }
    }
  }

  private let symbolImageView = UIImageView()
  private var currentKind: Kind = .home
  private var isSelectedState: Bool = false
  private var isDarkState: Bool = true
  private var fallbackSymbol: String = "circle"

  override var intrinsicContentSize: CGSize {
    return CGSize(width: 24.0, height: 24.0)
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false
    isUserInteractionEnabled = false
    clipsToBounds = false

    symbolImageView.contentMode = .center
    symbolImageView.isUserInteractionEnabled = false
    symbolImageView.frame = CGRect(x: 0.0, y: 0.0, width: 24.0, height: 24.0)
    addSubview(symbolImageView)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    symbolImageView.frame = bounds
  }

  func configure(kind: Kind, selected: Bool, dark: Bool, fallbackSymbol: String) {
    self.currentKind = kind
    self.isSelectedState = selected
    self.isDarkState = dark
    self.fallbackSymbol = fallbackSymbol

    let activeTint: UIColor = dark
      ? UIColor(red: 0.039, green: 0.518, blue: 1.0, alpha: 1.0)
      : UIColor.systemBlue
    let inactiveTint: UIColor = dark
      ? UIColor.white.withAlphaComponent(0.76)
      : UIColor(white: 0.10, alpha: 0.82)

    let symbolName = kind.appleSymbolName(selected: selected, fallback: fallbackSymbol)
    let pointSize: CGFloat = kind == .live ? 19.0 : 20.0
    let cfg = UIImage.SymbolConfiguration(
      pointSize: pointSize,
      weight: selected ? .semibold : .medium,
      scale: .medium
    )
    let img = UIImage(systemName: symbolName, withConfiguration: cfg)
      ?? UIImage(systemName: fallbackSymbol, withConfiguration: cfg)
    symbolImageView.image = img?.withRenderingMode(.alwaysTemplate)
    symbolImageView.tintColor = selected ? activeTint : inactiveTint
  }

  /// Plays Apple's native SF Symbol effect (iOS 17+) or crisp spring bounce (iOS 14–16).
  func playSelectAnimation() {
    guard !UIAccessibility.isReduceMotionEnabled else { return }
    if #available(iOS 17.0, *) {
      symbolImageView.addSymbolEffect(.bounce.up.byLayer, options: .nonRepeating, animated: true)
      return
    }
    symbolImageView.layer.removeAllAnimations()
    let anim = CAKeyframeAnimation(keyPath: "transform.scale")
    anim.values = [0.88, 1.08, 0.98, 1.0]
    anim.keyTimes = [0, 0.42, 0.76, 1.0]
    anim.duration = 0.42
    anim.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
    symbolImageView.layer.add(anim, forKey: "marcoAppleSymbolBounce")
  }
}

/// Fallback capsule for iOS 15–25 (non-Liquid Glass OS versions).
/// On iOS 26+, `MarcoIos27DockChromeView` renders real `UITabBar` + `UIGlassContainerEffect`
/// + `UIButton(configuration: .glass())`.
private final class MarcoNativeLiquidTabCapsuleView: UIView, UIContextMenuInteractionDelegate {
  struct TabSpec {
    let label: String
    let symbol: String
    let selectedSymbol: String
    let kind: MarcoAnimatedTabIconView.Kind
    let menuItems: [[String: Any]]
  }

  private final class SlotView: UIView {
    let previewPillView = UIView()
    let iconView = MarcoAnimatedTabIconView()
    let titleLabel = UILabel()
    private let stack = UIStackView()

    override init(frame: CGRect) {
      super.init(frame: frame)
      isUserInteractionEnabled = false
      isAccessibilityElement = true
      accessibilityTraits = .button

      previewPillView.backgroundColor = .clear
      previewPillView.isOpaque = false
      previewPillView.isUserInteractionEnabled = false
      previewPillView.translatesAutoresizingMaskIntoConstraints = false
      addSubview(previewPillView)

      iconView.translatesAutoresizingMaskIntoConstraints = false

      titleLabel.font = UIFont.systemFont(ofSize: 10.5, weight: .medium)
      titleLabel.textAlignment = .center
      titleLabel.lineBreakMode = .byTruncatingTail
      titleLabel.textColor = UIColor.white.withAlphaComponent(0.72)

      stack.axis = .vertical
      stack.alignment = .center
      stack.spacing = 2.5
      stack.isUserInteractionEnabled = false
      stack.translatesAutoresizingMaskIntoConstraints = false
      stack.addArrangedSubview(iconView)
      stack.addArrangedSubview(titleLabel)
      previewPillView.addSubview(stack)

      NSLayoutConstraint.activate([
        previewPillView.topAnchor.constraint(equalTo: topAnchor),
        previewPillView.bottomAnchor.constraint(equalTo: bottomAnchor),
        previewPillView.leadingAnchor.constraint(equalTo: leadingAnchor),
        previewPillView.trailingAnchor.constraint(equalTo: trailingAnchor),

        iconView.widthAnchor.constraint(equalToConstant: 24.0),
        iconView.heightAnchor.constraint(equalToConstant: 24.0),
        stack.centerXAnchor.constraint(equalTo: previewPillView.centerXAnchor),
        stack.centerYAnchor.constraint(equalTo: previewPillView.centerYAnchor),
        stack.leadingAnchor.constraint(greaterThanOrEqualTo: previewPillView.leadingAnchor, constant: 4.0),
        stack.trailingAnchor.constraint(lessThanOrEqualTo: previewPillView.trailingAnchor, constant: -4.0),
      ])
    }

    func playSelectedMotion() {
      iconView.playSelectAnimation()
      guard !UIAccessibility.isReduceMotionEnabled else { return }
      titleLabel.transform = CGAffineTransform(translationX: 0, y: 1.6).scaledBy(x: 0.94, y: 0.94)
      UIView.animate(
        withDuration: 0.34,
        delay: 0.0,
        usingSpringWithDamping: 0.68,
        initialSpringVelocity: 0.8,
        options: [.beginFromCurrentState, .allowUserInteraction],
        animations: {
          self.titleLabel.transform = .identity
        },
        completion: nil
      )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }
  }

  private let effectView: UIVisualEffectView
  private let selectionLensView = UIView()
  private let slotsStack = UIStackView()
  private let scrubbingLensShadowView = UIView()
  private let scrubbingLensEffectView: UIVisualEffectView
  private var slotViews: [SlotView] = []
  private var specs: [TabSpec] = []
  private(set) var selectedIndex: Int = 0
  private var highlightedIndex: Int = 0
  private var isScrubbing: Bool = false
  private var scrubContinuousSlot: CGFloat?
  private var lastScrubX: CGFloat?
  private var lastScrubTimestamp: TimeInterval = 0
  private var scrubVelocityX: CGFloat = 0
  private let selectionFeedback = UISelectionFeedbackGenerator()
  private var contextMenuActive: Bool = false

  var onSelect: ((Int) -> Void)?
  var onTabMenuAction: ((Int, String) -> Void)?

  override init(frame: CGRect) {
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      let glass = UIGlassEffect(style: .regular)
      glass.isInteractive = true
      effectView = UIVisualEffectView(effect: glass)

      let lensGlass = UIGlassEffect(style: .clear)
      lensGlass.isInteractive = true
      scrubbingLensEffectView = UIVisualEffectView(effect: lensGlass)
    } else {
      effectView = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
      scrubbingLensEffectView = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
    }
    #else
    effectView = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
    scrubbingLensEffectView = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
    #endif
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false
    clipsToBounds = false
    isMultipleTouchEnabled = false
    isExclusiveTouch = true
    overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle

    effectView.overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle
    effectView.backgroundColor = .clear
    effectView.isUserInteractionEnabled = false
    effectView.translatesAutoresizingMaskIntoConstraints = false
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      effectView.cornerConfiguration = .capsule()
    } else {
      effectView.layer.cornerCurve = .continuous
      effectView.clipsToBounds = true
    }
    #else
    effectView.layer.cornerCurve = .continuous
    effectView.clipsToBounds = true
    #endif
    addSubview(effectView)

    selectionLensView.backgroundColor = UIColor.white.withAlphaComponent(0.16)
    selectionLensView.layer.cornerCurve = .continuous
    selectionLensView.layer.borderWidth = 0.5
    selectionLensView.layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor
    selectionLensView.isUserInteractionEnabled = false
    effectView.contentView.addSubview(selectionLensView)

    slotsStack.axis = .horizontal
    slotsStack.alignment = .fill
    slotsStack.distribution = .fillEqually
    slotsStack.spacing = 0.0
    slotsStack.isUserInteractionEnabled = false
    slotsStack.translatesAutoresizingMaskIntoConstraints = false
    effectView.contentView.addSubview(slotsStack)

    // Elevated native iOS 26 refractive Liquid Glass scrubbing bubble sitting
    // above the tab icons & outer capsule so holding and dragging physically
    // lifts and refracts the icons beneath the finger like system UITabBar.
    scrubbingLensShadowView.backgroundColor = .clear
    scrubbingLensShadowView.isOpaque = false
    scrubbingLensShadowView.clipsToBounds = false
    scrubbingLensShadowView.isUserInteractionEnabled = false
    scrubbingLensShadowView.alpha = 0.0
    scrubbingLensShadowView.layer.shadowColor = UIColor.black.cgColor
    scrubbingLensShadowView.layer.shadowOpacity = 0.18
    scrubbingLensShadowView.layer.shadowRadius = 14.0
    scrubbingLensShadowView.layer.shadowOffset = CGSize(width: 0, height: 5)
    addSubview(scrubbingLensShadowView)

    scrubbingLensEffectView.overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle
    scrubbingLensEffectView.backgroundColor = .clear
    scrubbingLensEffectView.isUserInteractionEnabled = false
    scrubbingLensEffectView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      scrubbingLensEffectView.cornerConfiguration = .capsule()
    } else {
      scrubbingLensEffectView.layer.cornerCurve = .continuous
      scrubbingLensEffectView.clipsToBounds = true
      scrubbingLensEffectView.layer.borderWidth = 0.85
    }
    #else
    scrubbingLensEffectView.layer.cornerCurve = .continuous
    scrubbingLensEffectView.clipsToBounds = true
    scrubbingLensEffectView.layer.borderWidth = 0.85
    #endif
    scrubbingLensShadowView.addSubview(scrubbingLensEffectView)

    NSLayoutConstraint.activate([
      effectView.topAnchor.constraint(equalTo: topAnchor),
      effectView.bottomAnchor.constraint(equalTo: bottomAnchor),
      effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
      effectView.trailingAnchor.constraint(equalTo: trailingAnchor),

      slotsStack.topAnchor.constraint(equalTo: effectView.contentView.topAnchor, constant: 4.0),
      slotsStack.bottomAnchor.constraint(equalTo: effectView.contentView.bottomAnchor, constant: -4.0),
      slotsStack.leadingAnchor.constraint(equalTo: effectView.contentView.leadingAnchor, constant: 4.0),
      slotsStack.trailingAnchor.constraint(equalTo: effectView.contentView.trailingAnchor, constant: -4.0),
    ])

    let contextMenu = UIContextMenuInteraction(delegate: self)
    addInteraction(contextMenu)
  }

  func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    configurationForMenuAtLocation location: CGPoint
  ) -> UIContextMenuConfiguration? {
    guard !specs.isEmpty, !isHidden, alpha > 0.5 else { return nil }
    let (idx, _) = indexForX(location.x)
    guard idx >= 0, idx < specs.count else { return nil }
    let rawItems = specs[idx].menuItems
    guard !rawItems.isEmpty else { return nil }
    contextMenuActive = true
    if isScrubbing {
      isScrubbing = false
      scrubCancelledByExit = false
      scrubContinuousSlot = nil
      lastScrubX = nil
      scrubVelocityX = 0
      highlightedIndex = selectedIndex
      scrubbingLensShadowView.layer.removeAllAnimations()
      applySlotAppearances(activeIndex: selectedIndex)
      positionLens(slotPosition: CGFloat(selectedIndex), animated: false, lifted: false)
    }
    return UIContextMenuConfiguration(identifier: NSNumber(value: idx), previewProvider: nil) { [weak self] _ in
      guard let self = self else { return nil }
      return MarcoLiquidGlassSupport.buildMenu(title: "", rawItems: rawItems) { [weak self] actionId in
        self?.onTabMenuAction?(idx, actionId)
      }
    }
  }

  private func targetedPreview(for configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
    guard let num = configuration.identifier as? NSNumber else { return nil }
    let idx = num.intValue
    guard idx >= 0, idx < slotViews.count else { return nil }
    let targetView = slotViews[idx].previewPillView
    guard targetView.window != nil,
          !isHidden,
          alpha > 0.05,
          targetView.bounds.width > 1.0,
          targetView.bounds.height > 1.0 else {
      return nil
    }
    let params = UIPreviewParameters()
    let pillPath = UIBezierPath(
      roundedRect: targetView.bounds,
      cornerRadius: targetView.bounds.height * 0.5
    )
    params.visiblePath = pillPath
    params.shadowPath = pillPath
    let dark = MarcoLiquidGlassSupport.isEffectiveDark(for: self)
    params.backgroundColor = dark
      ? UIColor(red: 0.17, green: 0.18, blue: 0.21, alpha: 0.94)
      : UIColor(white: 1.0, alpha: 0.95)
    return UITargetedPreview(view: targetView, parameters: params)
  }

  @available(iOS 16.0, *)
  func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    configuration: UIContextMenuConfiguration,
    highlightPreviewForItemWithIdentifier identifier: any NSCopying
  ) -> UITargetedPreview? {
    return targetedPreview(for: configuration)
  }

  @available(iOS 16.0, *)
  func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    configuration: UIContextMenuConfiguration,
    dismissalPreviewForItemWithIdentifier identifier: any NSCopying
  ) -> UITargetedPreview? {
    return targetedPreview(for: configuration)
  }

  func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    previewForHighlightingMenuWithConfiguration configuration: UIContextMenuConfiguration
  ) -> UITargetedPreview? {
    return targetedPreview(for: configuration)
  }

  func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    previewForDismissingMenuWithConfiguration configuration: UIContextMenuConfiguration
  ) -> UITargetedPreview? {
    return targetedPreview(for: configuration)
  }

  func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    willDisplayMenuFor configuration: UIContextMenuConfiguration,
    animator: UIContextMenuInteractionAnimating?
  ) {
    contextMenuActive = true
  }

  func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    willEndFor configuration: UIContextMenuConfiguration,
    animator: UIContextMenuInteractionAnimating?
  ) {
    let finish: () -> Void = { [weak self] in
      self?.contextMenuActive = false
    }
    if let animator = animator {
      animator.addCompletion(finish)
    } else {
      finish()
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
      refreshAppearance()
    }
  }

  func setItems(_ items: [TabSpec]) {
    specs = items
    for old in slotViews {
      slotsStack.removeArrangedSubview(old)
      old.removeFromSuperview()
    }
    slotViews.removeAll()
    for spec in items {
      let slot = SlotView()
      slot.titleLabel.text = spec.label
      slot.accessibilityLabel = spec.label
      slotsStack.addArrangedSubview(slot)
      slotViews.append(slot)
    }
    if selectedIndex >= items.count {
      selectedIndex = max(0, items.count - 1)
    }
    highlightedIndex = selectedIndex
    applySlotAppearances(activeIndex: selectedIndex)
    setNeedsLayout()
  }

  func setSelectedIndex(_ index: Int, animated: Bool) {
    guard index >= 0, index < specs.count else { return }
    let changed = selectedIndex != index
    selectedIndex = index
    if !isScrubbing {
      highlightedIndex = index
      applySlotAppearances(activeIndex: index)
      positionLens(slotPosition: CGFloat(index), animated: animated && changed, lifted: false)
      if animated && changed && index < slotViews.count {
        slotViews[index].playSelectedMotion()
      }
    }
  }

  private func applySlotAppearances(activeIndex: Int) {
    let dark = MarcoLiquidGlassSupport.isEffectiveDark(for: self)
    let activeLabelColor: UIColor = dark
      ? UIColor(red: 0.039, green: 0.518, blue: 1.0, alpha: 1.0)
      : UIColor.systemBlue
    let inactiveLabelColor: UIColor = dark
      ? UIColor.white.withAlphaComponent(0.76)
      : UIColor(white: 0.10, alpha: 0.82)
    selectionLensView.layer.borderColor = (dark
      ? UIColor.white.withAlphaComponent(0.14)
      : UIColor.black.withAlphaComponent(0.05)).cgColor
    scrubbingLensShadowView.layer.shadowOpacity = dark ? 0.34 : 0.16
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      // Native UIGlassEffect draws its own optical specular border.
    } else {
      scrubbingLensEffectView.layer.borderColor = (dark
        ? UIColor.white.withAlphaComponent(0.32)
        : UIColor.white.withAlphaComponent(0.75)).cgColor
    }
    #else
    scrubbingLensEffectView.layer.borderColor = (dark
      ? UIColor.white.withAlphaComponent(0.32)
      : UIColor.white.withAlphaComponent(0.75)).cgColor
    #endif
    for (idx, slot) in slotViews.enumerated() where idx < specs.count {
      let spec = specs[idx]
      let isSelected = idx == activeIndex
      let symName = isSelected ? spec.selectedSymbol : spec.symbol
      slot.iconView.configure(
        kind: spec.kind,
        selected: isSelected,
        dark: dark,
        fallbackSymbol: symName
      )
      slot.titleLabel.textColor = isSelected ? activeLabelColor : inactiveLabelColor
      slot.titleLabel.font = UIFont.systemFont(ofSize: 10.5, weight: isSelected ? .semibold : .medium)
      slot.accessibilityTraits = isSelected ? [.button, .selected] : [.button]
    }
  }

  func refreshAppearance() {
    overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle
    effectView.overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle
    scrubbingLensEffectView.overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle
    applySlotAppearances(activeIndex: isScrubbing ? highlightedIndex : selectedIndex)
    let slotPos = scrubContinuousSlot ?? CGFloat(selectedIndex)
    positionLens(slotPosition: slotPos, animated: false, lifted: isScrubbing)
  }

  private func lensMetrics(for slotPosition: CGFloat) -> (bounds: CGRect, center: CGPoint)? {
    let count = specs.count
    guard count > 0, bounds.width > 8.0, bounds.height > 8.0 else { return nil }
    let inset: CGFloat = 4.0
    let innerW = bounds.width - inset * 2.0
    let slotW = innerW / CGFloat(count)
    let lensH = bounds.height - inset * 2.0
    let clampedPos = max(0.0, min(slotPosition, CGFloat(count - 1)))
    let centerX = inset + slotW * (clampedPos + 0.5)
    let centerY = bounds.height * 0.5
    return (CGRect(x: 0, y: 0, width: slotW, height: lensH), CGPoint(x: centerX, y: centerY))
  }

  private func positionLens(slotPosition: CGFloat, animated: Bool, lifted: Bool) {
    guard let metrics = lensMetrics(for: slotPosition) else { return }
    selectionLensView.layer.cornerRadius = metrics.bounds.height * 0.5
    let liftedBounds = CGRect(
      x: 0,
      y: 0,
      width: metrics.bounds.width + 10.0,
      height: bounds.height + 6.0
    )
    let speedNorm = min(abs(scrubVelocityX) / 1400.0, 1.0)
    let stretchX: CGFloat = lifted ? (1.03 + speedNorm * 0.08) : 0.90
    let stretchY: CGFloat = lifted ? (1.04 - speedNorm * 0.03) : 0.88
    let apply = {
      self.selectionLensView.bounds = metrics.bounds
      self.selectionLensView.center = metrics.center
      self.selectionLensView.transform = .identity
      let dark = MarcoLiquidGlassSupport.isEffectiveDark(for: self)
      self.selectionLensView.backgroundColor = dark
        ? UIColor.white.withAlphaComponent(0.14)
        : UIColor.black.withAlphaComponent(0.065)
      self.selectionLensView.alpha = lifted ? 0.0 : 1.0

      self.scrubbingLensShadowView.bounds = liftedBounds
      self.scrubbingLensShadowView.center = metrics.center
      self.scrubbingLensShadowView.layer.shadowPath = UIBezierPath(
        roundedRect: liftedBounds,
        cornerRadius: liftedBounds.height * 0.5
      ).cgPath
      self.scrubbingLensEffectView.frame = liftedBounds
      #if compiler(>=6.2)
      if #available(iOS 26.0, *) {
        // Handled natively via cornerConfiguration = .capsule().
      } else {
        self.scrubbingLensEffectView.layer.cornerRadius = liftedBounds.height * 0.5
      }
      #else
      self.scrubbingLensEffectView.layer.cornerRadius = liftedBounds.height * 0.5
      #endif
      let reduceMotion = UIAccessibility.isReduceMotionEnabled
      self.scrubbingLensShadowView.transform = reduceMotion
        ? .identity
        : CGAffineTransform(scaleX: stretchX, y: stretchY)
      self.scrubbingLensShadowView.alpha = lifted ? 1.0 : 0.0
    }
    if animated && !UIAccessibility.isReduceMotionEnabled {
      UIView.animate(
        withDuration: lifted ? 0.20 : 0.34,
        delay: 0,
        usingSpringWithDamping: lifted ? 0.78 : 0.76,
        initialSpringVelocity: 0.7,
        options: [.beginFromCurrentState, .allowUserInteraction],
        animations: apply,
        completion: nil
      )
    } else {
      apply()
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      // Handled natively via cornerConfiguration = .capsule().
    } else {
      effectView.layer.cornerRadius = bounds.height * 0.5
    }
    #else
    effectView.layer.cornerRadius = bounds.height * 0.5
    #endif
    let slotPos = scrubContinuousSlot ?? CGFloat(selectedIndex)
    positionLens(slotPosition: slotPos, animated: false, lifted: isScrubbing)
  }

  private func indexForX(_ x: CGFloat) -> (discrete: Int, continuous: CGFloat) {
    let count = max(specs.count, 1)
    let inset: CGFloat = 4.0
    let innerW = max(bounds.width - inset * 2.0, 1.0)
    let slotW = innerW / CGFloat(count)
    let relative = x - inset
    let discrete = max(0, min(Int(floor(relative / slotW)), count - 1))
    let continuous = max(0.0, min((relative - slotW * 0.5) / slotW, CGFloat(count - 1)))
    return (discrete, continuous)
  }

  func setScrollCollapseProgress(_ rawProgress: CGFloat) {
    let p = max(0.0, min(rawProgress, 1.0))
    let count = max(slotViews.count, 1)
    let spanW = max(bounds.width, 1.0)
    for (idx, slot) in slotViews.enumerated() {
      // Stagger left-to-right so leftmost tabs roll rightward into the Search
      // circle first while rightmost tabs follow cleanly in linear lockstep.
      let frac = CGFloat(idx) / CGFloat(max(count - 1, 1))
      let slotP = max(0.0, min((p - frac * 0.18) / 0.82, 1.0))
      let pullX = (1.0 - frac * 0.45) * spanW * 0.24 * slotP
      let scale = max(0.32, 1.0 - 0.62 * slotP)
      slot.transform = CGAffineTransform(translationX: pullX, y: 0.0).scaledBy(x: scale, y: scale)
      slot.alpha = max(0.0, 1.0 - slotP * 1.15)
    }
    selectionLensView.alpha = isScrubbing ? 0.0 : max(0.0, 1.0 - p * 1.35)
  }

  private var scrubCancelledByExit: Bool = false

  private func isTouchInsideCommitZone(_ pt: CGPoint) -> Bool {
    return bounds.insetBy(dx: -24.0, dy: -28.0).contains(pt)
  }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
    // Intentionally do NOT call super.touchesBegan: forwarding up the responder
    // chain leaks Dock taps directly into FlutterView behind the overlay.
    guard let touch = touches.first, !specs.isEmpty else { return }
    contextMenuActive = false
    selectionFeedback.prepare()
    let pt = touch.location(in: self)
    let (idx, _) = indexForX(pt.x)
    let prevHighlighted = highlightedIndex
    isScrubbing = true
    scrubCancelledByExit = false
    highlightedIndex = idx
    scrubContinuousSlot = CGFloat(idx)
    lastScrubX = pt.x
    lastScrubTimestamp = touch.timestamp
    scrubVelocityX = 0
    applySlotAppearances(activeIndex: idx)
    positionLens(slotPosition: CGFloat(idx), animated: true, lifted: true)
    if idx != prevHighlighted && idx < slotViews.count {
      slotViews[idx].playSelectedMotion()
    }
  }

  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
    // Intentionally absorb scrubbing touches so underlying Flutter scrollables
    // and carousels never drag simultaneously with the Dock.
    guard isScrubbing, let touch = touches.first, !specs.isEmpty else { return }
    let pt = touch.location(in: self)
    if !isTouchInsideCommitZone(pt) {
      if !scrubCancelledByExit {
        scrubCancelledByExit = true
        scrubContinuousSlot = nil
        scrubVelocityX = 0
        highlightedIndex = selectedIndex
        applySlotAppearances(activeIndex: selectedIndex)
        positionLens(slotPosition: CGFloat(selectedIndex), animated: true, lifted: false)
      }
      return
    }
    scrubCancelledByExit = false
    if let prevX = lastScrubX {
      let dt = max(touch.timestamp - lastScrubTimestamp, 0.008)
      let instantV = (pt.x - prevX) / CGFloat(dt)
      scrubVelocityX = scrubVelocityX * 0.6 + instantV * 0.4
    }
    lastScrubX = pt.x
    lastScrubTimestamp = touch.timestamp
    let (idx, continuous) = indexForX(pt.x)
    scrubContinuousSlot = continuous
    if idx != highlightedIndex {
      highlightedIndex = idx
      selectionFeedback.selectionChanged()
      applySlotAppearances(activeIndex: idx)
      if idx < slotViews.count {
        slotViews[idx].playSelectedMotion()
      }
    }
    positionLens(slotPosition: continuous, animated: false, lifted: true)
  }

  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
    // Intentionally absorb touch release so underlying Flutter items never fire.
    guard isScrubbing else { return }
    let finalPt = touches.first?.location(in: self)
    let releasedOutside = scrubCancelledByExit
      || (finalPt != nil && !isTouchInsideCommitZone(finalPt!))
    if contextMenuActive || releasedOutside {
      isScrubbing = false
      scrubCancelledByExit = false
      scrubContinuousSlot = nil
      lastScrubX = nil
      scrubVelocityX = 0
      highlightedIndex = selectedIndex
      applySlotAppearances(activeIndex: selectedIndex)
      positionLens(slotPosition: CGFloat(selectedIndex), animated: true, lifted: false)
      return
    }
    let target = highlightedIndex
    isScrubbing = false
    scrubCancelledByExit = false
    scrubContinuousSlot = nil
    lastScrubX = nil
    scrubVelocityX = 0
    let changed = target != selectedIndex
    selectedIndex = target
    applySlotAppearances(activeIndex: target)
    positionLens(slotPosition: CGFloat(target), animated: true, lifted: false)
    if changed {
      UIImpactFeedbackGenerator(style: .light).impactOccurred()
    } else if target < slotViews.count {
      // Re-tapping the already-selected tab still gives a delightful micro-pop!
      slotViews[target].playSelectedMotion()
    }
    onSelect?(target)
  }

  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
    // Intentionally absorb cancellation without forwarding to FlutterView.
    guard isScrubbing else { return }
    isScrubbing = false
    scrubCancelledByExit = false
    scrubContinuousSlot = nil
    lastScrubX = nil
    scrubVelocityX = 0
    highlightedIndex = selectedIndex
    applySlotAppearances(activeIndex: selectedIndex)
    positionLens(slotPosition: CGFloat(selectedIndex), animated: true, lifted: false)
  }
}

private final class MarcoIos27PassthroughChromeView: UIView {
  weak var chromeView: UIView?
  weak var glassContainerView: UIVisualEffectView?

  override func didMoveToSuperview() {
    super.didMoveToSuperview()
    layer.zPosition = 1000.0
  }

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    guard !isHidden, alpha > 0.01, isUserInteractionEnabled else { return nil }
    guard let hit = super.hitTest(point, with: event) else { return nil }
    if hit === self || hit === chromeView || hit === glassContainerView || hit === glassContainerView?.contentView {
      return nil
    }
    return hit
  }
}

private final class MarcoIos27DockChromeView: UIView, UITabBarDelegate {
  private let isRootHost: Bool
  private let glassContainerView: UIVisualEffectView?
  private let fallbackContainerView = UIView()
  private let nativeTabBar = UITabBar(frame: .zero)
  private let legacyTabCapsule = MarcoNativeLiquidTabCapsuleView(frame: .zero)
  private let searchButton = UIButton(type: .system)
  private let logoButton = UIButton(type: .system)

  private var rawItemDicts: [[String: Any]] = []
  private var tabSpecs: [MarcoNativeLiquidTabCapsuleView.TabSpec] = []
  private(set) var selectedIndex: Int = 0
  private(set) var isMinimized: Bool = false
  private(set) var isChromeVisible: Bool = true
  private var minimizeProgress: CGFloat = 0.0
  private var morphDisplayLink: CADisplayLink?
  private var morphStartTime: CFTimeInterval = 0
  private var morphDuration: CFTimeInterval = 0.26
  private var morphFromProgress: CGFloat = 0.0
  private var morphToProgress: CGFloat = 0.0
  private var morphGeneration: Int = 0
  var showSearchButton: Bool = true {
    didSet {
      updateVisibilityState()
      setNeedsLayout()
    }
  }
  var adaptiveTopOnWide: Bool = true {
    didSet { setNeedsLayout() }
  }

  var onSelectTab: ((Int) -> Void)?
  var onSearchTapped: (() -> Void)?
  var onScrollToTopTapped: (() -> Void)?
  var onTabMenuAction: ((Int, String) -> Void)?

  private var usesNativeGlass26: Bool {
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      return !UIAccessibility.isReduceTransparencyEnabled
    }
    #endif
    return false
  }

  init(isRootHost: Bool, frame: CGRect = .zero) {
    self.isRootHost = isRootHost
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      let containerEffect = UIGlassContainerEffect()
      containerEffect.spacing = 10.0
      self.glassContainerView = UIVisualEffectView(effect: containerEffect)
    } else {
      self.glassContainerView = nil
    }
    #else
    self.glassContainerView = nil
    #endif
    super.init(frame: frame)

    backgroundColor = .clear
    isOpaque = false
    clipsToBounds = false
    insetsLayoutMarginsFromSafeArea = false
    overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle

    let contentParent: UIView
    if let glassContainer = glassContainerView {
      glassContainer.backgroundColor = .clear
      glassContainer.isOpaque = false
      glassContainer.clipsToBounds = false
      glassContainer.overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle
      addSubview(glassContainer)
      contentParent = glassContainer.contentView
    } else {
      fallbackContainerView.backgroundColor = .clear
      fallbackContainerView.isOpaque = false
      fallbackContainerView.clipsToBounds = false
      addSubview(fallbackContainerView)
      contentParent = fallbackContainerView
    }

    // Always mount the custom height-matched Liquid Glass tab capsule (which
    // uses native UIGlassEffect(style: .regular) + .capsule() + interactive
    // scrubbing lens on iOS 26+, and crisp blur material on iOS 14–25) so the
    // 4-tab capsule strictly matches the circular Search button's exact height
    // and displays our redesigned vector icons across every iOS & iPadOS version.
    contentParent.addSubview(legacyTabCapsule)

    legacyTabCapsule.onSelect = { [weak self] idx in
      guard let self = self else { return }
      self.selectedIndex = idx
      self.rebuildLogoMenu()
      self.onSelectTab?(idx)
    }
    legacyTabCapsule.onTabMenuAction = { [weak self] idx, actionId in
      self?.onTabMenuAction?(idx, actionId)
    }

    configureGlassCircleButton(
      searchButton,
      image: UIImage(
        systemName: "magnifyingglass",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 20.5, weight: .semibold)
      ),
      accessibilityLabel: "搜索"
    )
    searchButton.addTarget(self, action: #selector(handleSearchTap), for: .touchUpInside)
    searchButton.isExclusiveTouch = true
    contentParent.addSubview(searchButton)

    configureGlassCircleButton(
      logoButton,
      image: MarcoLiquidGlassSupport.brandLogoImage,
      accessibilityLabel: "快捷导航"
    )
    logoButton.showsMenuAsPrimaryAction = true
    logoButton.isExclusiveTouch = true
    logoButton.alpha = 0.0
    logoButton.isUserInteractionEnabled = false
    logoButton.transform = CGAffineTransform(rotationAngle: -.pi)
    contentParent.addSubview(logoButton)
    rebuildLogoMenu()

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleAppearanceChanged),
      name: MarcoLiquidGlassSupport.appearanceChangedNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleSceneActivationChanged),
      name: MarcoLiquidGlassSupport.sceneActivationChangedNotification,
      object: nil
    )
  }

  deinit {
    stopMorphAnimation()
    NotificationCenter.default.removeObserver(self)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  var containerViewForHitTest: UIVisualEffectView? {
    return glassContainerView
  }

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    guard !isHidden, alpha > 0.01, isUserInteractionEnabled else { return nil }
    guard let hit = super.hitTest(point, with: event) else { return nil }
    if hit === self || hit === fallbackContainerView || hit === glassContainerView || hit === glassContainerView?.contentView {
      return nil
    }
    return hit
  }

  // Secondary responder-chain firewall: once a touch hit-tests onto an active
  // Dock control (capsule or circular button), never let it propagate further
  // up to MarcoIos27PassthroughChromeView / FlutterView.
  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {}
  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {}
  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {}
  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {}

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
      handleAppearanceChanged()
    }
  }

  private func configureGlassCircleButton(
    _ button: UIButton,
    image: UIImage?,
    accessibilityLabel: String
  ) {
    let fg = MarcoLiquidGlassSupport.adaptiveGlassForeground(for: self)
    button.overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle
    button.accessibilityLabel = accessibilityLabel
    if #available(iOS 17.0, *) {
      button.isSymbolAnimationEnabled = true
    }
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      var cfg = UIButton.Configuration.glass()
      cfg.image = image
      cfg.baseForegroundColor = fg
      cfg.cornerStyle = .capsule
      cfg.contentInsets = .zero
      button.configuration = cfg
      button.cornerConfiguration = .capsule()
      return
    }
    #endif
    let dark = MarcoLiquidGlassSupport.isEffectiveDark(for: self)
    let bg = dark
      ? UIColor(white: 0.16, alpha: 0.88)
      : UIColor(white: 0.98, alpha: 0.92)
    if #available(iOS 15.0, *) {
      var cfg = UIButton.Configuration.filled()
      cfg.image = image
      cfg.baseForegroundColor = fg
      cfg.baseBackgroundColor = bg
      cfg.cornerStyle = .capsule
      cfg.contentInsets = .zero
      button.configuration = cfg
    } else {
      button.setImage(image, for: .normal)
      button.tintColor = fg
      button.backgroundColor = bg
      button.layer.cornerRadius = (button.bounds.height > 1.0 ? button.bounds.height : 62.0) * 0.5
      button.layer.masksToBounds = true
    }
  }

  @objc private func handleAppearanceChanged() {
    overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle
    glassContainerView?.overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle
    nativeTabBar.overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle
    legacyTabCapsule.refreshAppearance()
    configureGlassCircleButton(
      searchButton,
      image: UIImage(
        systemName: "magnifyingglass",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 20.5, weight: .semibold)
      ),
      accessibilityLabel: "搜索"
    )
    configureGlassCircleButton(
      logoButton,
      image: MarcoLiquidGlassSupport.brandLogoImage,
      accessibilityLabel: "快捷导航"
    )
    logoButton.showsMenuAsPrimaryAction = true
    rebuildLogoMenu()
  }

  @objc private func handleSceneActivationChanged() {
    let active = MarcoLiquidGlassSupport.isSceneActive
    let targetAlpha: CGFloat = isChromeVisible ? (active ? 1.0 : 0.86) : 0.0
    UIView.animate(withDuration: 0.18) {
      self.alpha = targetAlpha
    }
  }

  @objc private func handleSearchTap() {
    if #available(iOS 17.0, *) {
      searchButton.imageView?.addSymbolEffect(.bounce, options: .nonRepeating, animated: true)
    }
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    onSearchTapped?()
  }

  private func updateVisibilityState() {
    searchButton.isHidden = !showSearchButton && !isMinimized
  }

  func setItems(_ rawItems: [[String: Any]]) {
    guard !rawItems.isEmpty else { return }
    rawItemDicts = rawItems
    let specs = rawItems.map { item -> MarcoNativeLiquidTabCapsuleView.TabSpec in
      let title = (item["label"] as? String) ?? ""
      let symbol = (item["symbol"] as? String) ?? "circle"
      let selectedSymbol = (item["selectedSymbol"] as? String) ?? symbol
      let kind = MarcoAnimatedTabIconView.Kind.resolve(
        kind: item["kind"] as? String,
        symbol: symbol,
        label: title
      )
      let menuItems = (item["menuItems"] as? [[String: Any]]) ?? []
      return MarcoNativeLiquidTabCapsuleView.TabSpec(
        label: title,
        symbol: symbol,
        selectedSymbol: selectedSymbol,
        kind: kind,
        menuItems: menuItems
      )
    }
    tabSpecs = specs
    legacyTabCapsule.setItems(specs)

    var barItems: [UITabBarItem] = []
    for (idx, spec) in specs.enumerated() {
      let img = UIImage(systemName: spec.symbol)
      let selImg = UIImage(systemName: spec.selectedSymbol) ?? img
      let barItem = UITabBarItem(title: spec.label, image: img, selectedImage: selImg)
      barItem.tag = idx
      barItems.append(barItem)
    }
    nativeTabBar.setItems(barItems, animated: false)
    if selectedIndex >= 0, selectedIndex < barItems.count {
      nativeTabBar.selectedItem = barItems[selectedIndex]
    }
    rebuildLogoMenu()
    setNeedsLayout()
  }

  func setSelectedIndex(_ index: Int, animated: Bool) {
    guard index >= 0, index < max(tabSpecs.count, rawItemDicts.count) else { return }
    selectedIndex = index
    legacyTabCapsule.setSelectedIndex(index, animated: animated)
    if let barItems = nativeTabBar.items, index < barItems.count {
      nativeTabBar.selectedItem = barItems[index]
    }
    rebuildLogoMenu()
  }

  func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
    let idx = item.tag
    guard idx >= 0, idx < max(tabSpecs.count, rawItemDicts.count) else { return }
    selectedIndex = idx
    legacyTabCapsule.setSelectedIndex(idx, animated: true)
    rebuildLogoMenu()
    UISelectionFeedbackGenerator().selectionChanged()
    onSelectTab?(idx)
  }

  private func activeTabView() -> UIView {
    return legacyTabCapsule
  }

  private func stopMorphAnimation() {
    morphGeneration += 1
    morphDisplayLink?.invalidate()
    morphDisplayLink = nil
  }

  private func startMorphAnimation(to targetProgress: CGFloat, duration: CFTimeInterval = 0.26) {
    stopMorphAnimation()
    let clampedTarget = max(0.0, min(targetProgress, 1.0))
    if UIAccessibility.isReduceMotionEnabled || abs(minimizeProgress - clampedTarget) <= 0.004 {
      minimizeProgress = clampedTarget
      isMinimized = clampedTarget >= 0.5
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      applyScrollMorph(progress: clampedTarget)
      CATransaction.commit()
      return
    }
    morphFromProgress = minimizeProgress
    morphToProgress = clampedTarget
    morphDuration = max(0.12, duration)
    morphStartTime = CACurrentMediaTime()
    let link = CADisplayLink(target: self, selector: #selector(handleMorphDisplayLink(_:)))
    link.add(to: .main, forMode: .common)
    morphDisplayLink = link
  }

  @objc private func handleMorphDisplayLink(_ link: CADisplayLink) {
    let elapsed = CACurrentMediaTime() - morphStartTime
    let rawT = min(1.0, max(0.0, elapsed / morphDuration))
    // Cubic ease-out for crisp, smooth settling without overshoot on rotation.
    let inv = 1.0 - rawT
    let eased = CGFloat(1.0 - inv * inv * inv)
    let nextP = morphFromProgress + (morphToProgress - morphFromProgress) * eased
    minimizeProgress = nextP
    isMinimized = nextP >= 0.5
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    applyScrollMorph(progress: nextP)
    CATransaction.commit()
    if rawT >= 1.0 {
      minimizeProgress = morphToProgress
      isMinimized = morphToProgress >= 0.5
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      applyScrollMorph(progress: morphToProgress)
      CATransaction.commit()
      stopMorphAnimation()
    }
  }

  private func applyScrollMorph(progress rawProgress: CGFloat) {
    let p = max(0.0, min(rawProgress, 1.0))
    guard bounds.width > 1.0, logoButton.bounds.width > 1.0 else { return }
    let tabView = activeTabView()
    let settledCollapsed = p >= 0.995
    let settledExpanded = p <= 0.005
    let targetCenterX = logoButton.center.x
    let dx = targetCenterX - tabView.center.x
    let tabTx = dx * p
    let tabScaleX = max(0.08, 1.0 - 0.90 * p)
    let tabScaleY = max(0.28, 1.0 - 0.62 * p)
    let spinScale: CGFloat = (settledCollapsed || settledExpanded) ? 1.0 : (1.0 - 0.08 * sin(p * .pi))
    let searchAngle: CGFloat = settledExpanded ? 0.0 : p * .pi
    let logoAngle: CGFloat = settledCollapsed ? 0.0 : (p - 1.0) * .pi
    let searchAlpha: CGFloat = (showSearchButton && !settledCollapsed) ? max(0.0, min(1.0, (0.62 - p) / 0.28)) : 0.0
    let logoAlpha: CGFloat = settledCollapsed ? 1.0 : max(0.0, min(1.0, (p - 0.34) / 0.28))

    #if compiler(>=6.2)
    if #available(iOS 26.0, *), let glassEffect = glassContainerView?.effect as? UIGlassContainerEffect {
      glassEffect.spacing = max(0.0, 10.0 * (1.0 - p))
    }
    #endif

    legacyTabCapsule.setScrollCollapseProgress(p)
    tabView.isHidden = settledCollapsed
    tabView.alpha = settledCollapsed ? 0.0 : max(0.0, 1.0 - p * 1.15)
    tabView.transform = settledExpanded
      ? .identity
      : CGAffineTransform(translationX: tabTx, y: 0.0).scaledBy(x: tabScaleX, y: tabScaleY)

    searchButton.isHidden = !showSearchButton || settledCollapsed
    searchButton.alpha = searchAlpha
    searchButton.transform = settledExpanded
      ? .identity
      : CGAffineTransform(rotationAngle: searchAngle).scaledBy(x: spinScale, y: spinScale)

    logoButton.isHidden = settledExpanded
    logoButton.alpha = logoAlpha
    logoButton.transform = settledCollapsed
      ? .identity
      : CGAffineTransform(rotationAngle: logoAngle).scaledBy(x: spinScale, y: spinScale)

    tabView.isUserInteractionEnabled = !settledCollapsed && p < 0.35
    searchButton.isUserInteractionEnabled = !settledCollapsed && p < 0.5 && showSearchButton
    logoButton.isUserInteractionEnabled = settledCollapsed || p >= 0.5
  }

  func updateScrollMinimizeProgress(_ rawProgress: CGFloat) {
    stopMorphAnimation()
    let p = max(0.0, min(rawProgress, 1.0))
    minimizeProgress = p
    isMinimized = p >= 0.5
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    applyScrollMorph(progress: p)
    CATransaction.commit()
  }

  func setMinimized(_ minimized: Bool, animated: Bool) {
    let targetProgress: CGFloat = minimized ? 1.0 : 0.0
    isMinimized = minimized
    if animated {
      startMorphAnimation(to: targetProgress, duration: 0.26)
    } else {
      stopMorphAnimation()
      minimizeProgress = targetProgress
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      applyScrollMorph(progress: targetProgress)
      CATransaction.commit()
    }
  }

  func setRootDockVisible(_ visible: Bool, animated: Bool) {
    isChromeVisible = visible
    isUserInteractionEnabled = visible
    let isTopWide = isRootHost && adaptiveTopOnWide && (bounds.width > bounds.height && bounds.width >= 600.0)
    let hiddenOffsetY: CGFloat = isTopWide ? -96.0 : 120.0
    let targetTransform = visible ? CGAffineTransform.identity : CGAffineTransform(translationX: 0.0, y: hiddenOffsetY)
    let targetAlpha: CGFloat = visible ? (MarcoLiquidGlassSupport.isSceneActive ? 1.0 : 0.86) : 0.0

    let apply = {
      let host: UIView = self.glassContainerView ?? self.fallbackContainerView
      host.transform = targetTransform
      self.alpha = targetAlpha
    }
    if animated {
      MarcoLiquidGlassSupport.animateSpring(duration: 0.38, bounce: 0.16, animations: apply)
    } else {
      apply()
    }
  }

  private func rebuildLogoMenu() {
    var sections: [UIMenuElement] = []

    if showSearchButton {
      let searchAction = UIAction(
        title: "搜索影片",
        image: UIImage(systemName: "magnifyingglass")
      ) { [weak self] _ in
        self?.handleSearchTap()
      }
      sections.append(UIMenu(title: "", options: .displayInline, children: [searchAction]))
    }

    var navActions: [UIAction] = []
    for (idx, item) in rawItemDicts.enumerated() {
      let title = (item["label"] as? String) ?? ""
      let isSelected = idx == selectedIndex
      let symbol = isSelected
        ? ((item["selectedSymbol"] as? String) ?? (item["symbol"] as? String) ?? "circle")
        : ((item["symbol"] as? String) ?? "circle")
      let action = UIAction(
        title: title,
        image: UIImage(systemName: symbol),
        state: isSelected ? .on : .off
      ) { [weak self] _ in
        guard let self = self else { return }
        self.setSelectedIndex(idx, animated: true)
        self.onSelectTab?(idx)
      }
      navActions.append(action)
    }
    if !navActions.isEmpty {
      sections.append(UIMenu(title: "", options: .displayInline, children: navActions))
    }

    let topAction = UIAction(
      title: "回到顶部",
      image: UIImage(systemName: "arrow.up.to.line")
    ) { [weak self] _ in
      self?.onScrollToTopTapped?()
    }
    sections.append(UIMenu(title: "", options: .displayInline, children: [topAction]))

    logoButton.menu = UIMenu(title: "", children: sections)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let totalW = bounds.width
    let totalH = bounds.height
    guard totalW > 0, totalH > 0 else { return }

    let containerTarget: UIView = glassContainerView ?? fallbackContainerView
    let safeInsets = window?.safeAreaInsets ?? safeAreaInsets

    // Determine whether we are embedded inside a 76pt PlatformView slice or full-screen root host.
    let isEmbeddedSlice = !isRootHost || totalH <= 140.0
    let isWideTopLayout = !isEmbeddedSlice && adaptiveTopOnWide && (totalW > totalH && totalW >= 600.0)

    let chromeBounds: CGRect
    if isEmbeddedSlice {
      chromeBounds = bounds
    } else if isWideTopLayout {
      let barH: CGFloat = 54.0
      let topY = max(safeInsets.top, 10.0) + 6.0
      chromeBounds = CGRect(x: 0.0, y: topY, width: totalW, height: barH)
    } else {
      let barH: CGFloat = 72.0
      let bottomY = totalH - max(safeInsets.bottom, 8.0) - barH
      chromeBounds = CGRect(x: 0.0, y: max(0.0, bottomY), width: totalW, height: barH)
    }

    containerTarget.bounds = CGRect(x: 0.0, y: 0.0, width: chromeBounds.width, height: chromeBounds.height)
    containerTarget.center = CGPoint(x: chromeBounds.midX, y: chromeBounds.midY)

    let cw = chromeBounds.width
    let ch = chromeBounds.height
    let isCompactSplit = cw < 360.0
    let outerMargin: CGFloat = isCompactSplit ? 10.0 : 16.0
    let gap: CGFloat = isCompactSplit ? 8.0 : 10.0
    let dockSize: CGFloat = min(isWideTopLayout ? 52.0 : (cw < 340.0 ? 56.0 : 62.0), ch)

    let tabView = activeTabView()
    if isMinimized && cw < 150.0 {
      logoButton.bounds = CGRect(x: 0, y: 0, width: dockSize, height: dockSize)
      logoButton.center = CGPoint(x: cw - outerMargin - dockSize * 0.5, y: ch * 0.5)
      containerTarget.bringSubviewToFront(logoButton)
      return
    }

    let maxCap: CGFloat = isWideTopLayout ? 520.0 : (cw >= 600.0 ? 468.0 : 440.0)
    let maxRowWidth: CGFloat = min(cw, maxCap)
    let rowX = (cw - maxRowWidth) * 0.5
    let centerY = ch * 0.5

    let rightCenterX = rowX + maxRowWidth - outerMargin - dockSize * 0.5
    logoButton.bounds = CGRect(x: 0, y: 0, width: dockSize, height: dockSize)
    logoButton.center = CGPoint(x: rightCenterX, y: centerY)
    if #available(iOS 15.0, *) {
      // Capsule corner radius handled by UIButton.Configuration.
    } else {
      logoButton.layer.cornerRadius = dockSize * 0.5
      searchButton.layer.cornerRadius = dockSize * 0.5
    }

    if showSearchButton {
      searchButton.bounds = CGRect(x: 0, y: 0, width: dockSize, height: dockSize)
      searchButton.center = CGPoint(x: rightCenterX, y: centerY)

      let tabX = rowX + outerMargin
      let availTabW = (rightCenterX - dockSize * 0.5 - gap) - tabX
      let tabW = max(availTabW, min(180.0, max(availTabW, 132.0)))
      tabView.bounds = CGRect(x: 0, y: 0, width: tabW, height: dockSize)
      tabView.center = CGPoint(x: tabX + tabW * 0.5, y: centerY)
    } else {
      let tabX = rowX + outerMargin
      let availTabW = maxRowWidth - outerMargin * 2.0
      let tabW = max(availTabW, min(180.0, max(availTabW, 132.0)))
      tabView.bounds = CGRect(x: 0, y: 0, width: tabW, height: dockSize)
      tabView.center = CGPoint(x: tabX + tabW * 0.5, y: centerY)
    }

    let contentParent = glassContainerView?.contentView ?? fallbackContainerView
    contentParent.bringSubviewToFront(searchButton)
    contentParent.bringSubviewToFront(logoButton)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    applyScrollMorph(progress: minimizeProgress)
    CATransaction.commit()
  }
}

private final class MarcoIos27RootTabChromeController: NSObject {
  private static var _sharedInstance: MarcoIos27RootTabChromeController?
  static var existingInstance: MarcoIos27RootTabChromeController? {
    return _sharedInstance
  }
  static var shared: MarcoIos27RootTabChromeController {
    if let existing = _sharedInstance {
      return existing
    }
    let created = MarcoIos27RootTabChromeController()
    _sharedInstance = created
    return created
  }

  private let overlayView = MarcoIos27PassthroughChromeView(frame: .zero)
  private let chromeView = MarcoIos27DockChromeView(isRootHost: true, frame: .zero)
  private var observers: [NSObjectProtocol] = []
  private weak var attachedHostView: UIView?
  private var isConfigured: Bool = false
  private var latestEpoch: Int = 0

  private func acceptEpoch(_ epoch: Int?) -> Bool {
    guard let e = epoch else { return true }
    if e < latestEpoch {
      return false
    }
    latestEpoch = e
    return true
  }

  private override init() {
    super.init()
    overlayView.backgroundColor = .clear
    overlayView.isOpaque = false
    overlayView.clipsToBounds = false
    overlayView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    overlayView.chromeView = chromeView
    overlayView.glassContainerView = chromeView.containerViewForHitTest

    chromeView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    overlayView.addSubview(chromeView)

    chromeView.onSelectTab = { idx in
      MarcoLiquidGlassSupport.bridgeChannel?.invokeMethod("rootTabSelected", arguments: idx)
    }
    chromeView.onSearchTapped = {
      MarcoLiquidGlassSupport.bridgeChannel?.invokeMethod("rootTabSearchTapped", arguments: nil)
    }
    chromeView.onScrollToTopTapped = {
      MarcoLiquidGlassSupport.bridgeChannel?.invokeMethod("rootTabScrollToTop", arguments: nil)
    }
    chromeView.onTabMenuAction = { idx, actionId in
      MarcoLiquidGlassSupport.bridgeChannel?.invokeMethod(
        "rootTabMenuAction",
        arguments: ["tabIndex": idx, "actionId": actionId]
      )
    }

    observers.append(
      NotificationCenter.default.addObserver(
        forName: MarcoLiquidGlassSupport.windowGeometryChangedNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        self?.syncOverlayFrame()
      }
    )
  }

  deinit {
    for obs in observers {
      NotificationCenter.default.removeObserver(obs)
    }
  }

  private func attachToRootIfNeeded() {
    guard MarcoLiquidGlassSupport.isAvailable, isConfigured else { return }
    guard let window = MarcoLiquidGlassSupport.activeWindow(),
          let rootVC = window.rootViewController,
          let rootView = rootVC.view else {
      return
    }
    // Keep overlayView mounted inside rootVC.view so UIButton.showsMenuAsPrimaryAction
    // (`logoButton`'s native UIMenu) ALWAYS has rootVC in its responder chain
    // (`_viewControllerForAncestor != nil`). Pair with `layer.zPosition = 1000`
    // (strictly local to rootView.layer, so UIWindow-hosted UIMenus & sheets
    // stay above it) and `bringToFrontIfNeeded()` invoked from
    // `MarcoFlutterViewController.viewDidLayoutSubviews()` and every native
    // FlutterPlatformView's `didMoveToWindow()` so dynamically scrolling
    // UiKitViews (e.g. Filter button) never cover or intercept hits on the Dock/Logo.
    overlayView.layer.zPosition = 1000.0
    if attachedHostView !== rootView || overlayView.superview !== rootView {
      overlayView.removeFromSuperview()
      overlayView.frame = rootView.bounds
      chromeView.frame = overlayView.bounds
      rootView.addSubview(overlayView)
      attachedHostView = rootView
    } else if rootView.subviews.last !== overlayView {
      rootView.bringSubviewToFront(overlayView)
    }
  }

  func bringToFrontIfNeeded() {
    guard MarcoLiquidGlassSupport.isAvailable, isConfigured else { return }
    guard let rootView = attachedHostView ?? MarcoLiquidGlassSupport.activeWindow()?.rootViewController?.view else {
      return
    }
    guard overlayView.superview === rootView else { return }
    overlayView.layer.zPosition = 1000.0
    if rootView.subviews.last !== overlayView {
      rootView.bringSubviewToFront(overlayView)
    }
  }

  private func syncOverlayFrame() {
    guard MarcoLiquidGlassSupport.isAvailable, isConfigured else { return }
    guard let window = MarcoLiquidGlassSupport.activeWindow(),
          let rootView = attachedHostView ?? window.rootViewController?.view else {
      return
    }
    attachToRootIfNeeded()
    overlayView.frame = rootView.bounds
    chromeView.frame = overlayView.bounds
    chromeView.setNeedsLayout()
    bringToFrontIfNeeded()
  }

  @discardableResult
  func configure(args: [String: Any]) -> Bool {
    guard MarcoLiquidGlassSupport.isAvailable,
          let items = args["items"] as? [[String: Any]],
          !items.isEmpty else {
      return false
    }
    isConfigured = true
    if let epoch = (args["epoch"] as? NSNumber)?.intValue {
      latestEpoch = max(latestEpoch, epoch)
    }
    attachToRootIfNeeded()
    if let showSearch = args["showSearch"] as? Bool {
      chromeView.showSearchButton = showSearch
    }
    if let adaptiveTop = args["adaptiveTopOnWide"] as? Bool {
      chromeView.adaptiveTopOnWide = adaptiveTop
    }
    chromeView.setItems(items)
    if let selectedIndex = args["selectedIndex"] as? Int {
      chromeView.setSelectedIndex(selectedIndex, animated: false)
    }
    if let minimized = args["minimized"] as? Bool {
      chromeView.setMinimized(minimized, animated: false)
    }
    if let visible = args["visible"] as? Bool {
      chromeView.setRootDockVisible(visible, animated: false)
    }
    syncOverlayFrame()
    return true
  }

  func setSelectedIndex(_ index: Int, animated: Bool, epoch: Int? = nil) {
    guard MarcoLiquidGlassSupport.isAvailable, isConfigured, acceptEpoch(epoch) else { return }
    attachToRootIfNeeded()
    chromeView.setSelectedIndex(index, animated: animated)
  }

  func setMinimized(_ minimized: Bool, animated: Bool, epoch: Int? = nil) {
    guard MarcoLiquidGlassSupport.isAvailable, isConfigured, acceptEpoch(epoch) else { return }
    attachToRootIfNeeded()
    chromeView.setMinimized(minimized, animated: animated)
  }

  func updateScrollMinimizeProgress(_ progress: CGFloat, epoch: Int? = nil) {
    guard MarcoLiquidGlassSupport.isAvailable, isConfigured, acceptEpoch(epoch) else { return }
    attachToRootIfNeeded()
    chromeView.updateScrollMinimizeProgress(progress)
  }

  func setRootDockVisible(_ visible: Bool, animated: Bool, epoch: Int? = nil) {
    guard MarcoLiquidGlassSupport.isAvailable, isConfigured, acceptEpoch(epoch) else { return }
    attachToRootIfNeeded()
    chromeView.setRootDockVisible(visible, animated: animated)
  }
}

private final class MarcoNativeDockPlatformView: NSObject, FlutterPlatformView {
  private let container: MarcoIos27DockChromeView
  private let channel: FlutterMethodChannel

  init(
    frame: CGRect,
    viewId: Int64,
    arguments args: [String: Any]?,
    messenger: FlutterBinaryMessenger
  ) {
    let initialFrame = MarcoLiquidGlassSupport.resolvedInitialFrame(
      frame,
      args: args,
      defaultWidth: MarcoLiquidGlassSupport.activeWindowBounds().width,
      defaultHeight: 76.0
    )
    self.container = MarcoIos27DockChromeView(isRootHost: false, frame: initialFrame)
    self.channel = FlutterMethodChannel(
      name: "marco_movie/ios26_dock_\(viewId)",
      binaryMessenger: messenger
    )
    super.init()

    container.onSelectTab = { [weak self] idx in
      self?.channel.invokeMethod("onSelect", arguments: idx)
    }
    container.onSearchTapped = { [weak self] in
      self?.channel.invokeMethod("onSearch", arguments: nil)
    }
    container.onScrollToTopTapped = { [weak self] in
      self?.channel.invokeMethod("onScrollToTop", arguments: nil)
    }
    container.onTabMenuAction = { [weak self] idx, actionId in
      self?.channel.invokeMethod("onTabMenuAction", arguments: ["tabIndex": idx, "actionId": actionId])
    }

    if let args = args {
      MarcoLiquidGlassSupport.withoutAnimations {
        self.applyState(args, animated: false)
        self.container.layoutIfNeeded()
      }
    }

    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(nil)
        return
      }
      DispatchQueue.main.async {
        switch call.method {
        case "update":
          if let args = call.arguments as? [String: Any] {
            self.applyState(args, animated: true)
          }
          result(nil)
        case "setSelectedIndex":
          if let idx = call.arguments as? Int {
            self.container.setSelectedIndex(idx, animated: true)
          }
          result(nil)
        case "setCollapsed":
          if let collapsed = call.arguments as? Bool {
            self.container.setMinimized(collapsed, animated: true)
          }
          result(nil)
        case "setHidden":
          if let hidden = call.arguments as? Bool {
            self.container.setRootDockVisible(!hidden, animated: true)
          }
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }
  }

  deinit {
    channel.setMethodCallHandler(nil)
  }

  func view() -> UIView {
    return container
  }

  private func applyState(_ args: [String: Any], animated: Bool) {
    if let showSearch = args["showSearch"] as? Bool {
      container.showSearchButton = showSearch
    }
    if let hidden = args["hidden"] as? Bool {
      container.setRootDockVisible(!hidden, animated: animated)
    }
    if let rawItems = args["items"] as? [[String: Any]], !rawItems.isEmpty {
      container.setItems(rawItems)
    }
    if let selectedIndex = args["selectedIndex"] as? Int {
      container.setSelectedIndex(selectedIndex, animated: animated)
    }
    if let collapsed = args["collapsed"] as? Bool {
      container.setMinimized(collapsed, animated: animated)
    }
    container.setNeedsLayout()
  }
}

// MARK: - 2. Native iOS 26 Liquid Glass Button (Circle Icon or Capsule, Optional Native UIMenu)

private final class MarcoNativeGlassButtonFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    return FlutterStandardMessageCodec.sharedInstance()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    return MarcoNativeGlassButtonPlatformView(
      frame: frame,
      viewId: viewId,
      arguments: args as? [String: Any],
      messenger: messenger
    )
  }
}

private final class MarcoMinTouchButton: UIButton {
  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    let minSize: CGFloat = 44.0
    let dx = max(0.0, (minSize - bounds.width) * 0.5)
    let dy = max(0.0, (minSize - bounds.height) * 0.5)
    return bounds.insetBy(dx: -dx, dy: -dy).contains(point)
  }
}

private final class MarcoNativeGlassButtonControl: UIView {
  private let button = MarcoMinTouchButton(type: .system)
  private let fallbackBlurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
  private let trailingAccessoryView = UIImageView()
  private var sceneObserver: NSObjectProtocol?

  var onTap: (() -> Void)?

  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    let minSize: CGFloat = 44.0
    let dx = max(0.0, (minSize - bounds.width) * 0.5)
    let dy = max(0.0, (minSize - bounds.height) * 0.5)
    return bounds.insetBy(dx: -dx, dy: -dy).contains(point)
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false
    clipsToBounds = false
    overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle

    var useFallbackBackdrop = true
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      useFallbackBackdrop = false
    }
    #endif

    if useFallbackBackdrop {
      fallbackBlurView.overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle
      fallbackBlurView.isUserInteractionEnabled = false
      fallbackBlurView.layer.cornerCurve = .continuous
      fallbackBlurView.clipsToBounds = true
      fallbackBlurView.translatesAutoresizingMaskIntoConstraints = false
      addSubview(fallbackBlurView)
      NSLayoutConstraint.activate([
        fallbackBlurView.topAnchor.constraint(equalTo: topAnchor),
        fallbackBlurView.bottomAnchor.constraint(equalTo: bottomAnchor),
        fallbackBlurView.leadingAnchor.constraint(equalTo: leadingAnchor),
        fallbackBlurView.trailingAnchor.constraint(equalTo: trailingAnchor),
      ])
    }

    button.translatesAutoresizingMaskIntoConstraints = false
    button.overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle
    if #available(iOS 17.0, *) {
      button.isSymbolAnimationEnabled = true
    }
    button.addTarget(self, action: #selector(handleButtonTap), for: .touchUpInside)
    addSubview(button)

    trailingAccessoryView.contentMode = .scaleAspectFit
    trailingAccessoryView.isUserInteractionEnabled = false
    trailingAccessoryView.isHidden = true
    trailingAccessoryView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(trailingAccessoryView)

    NSLayoutConstraint.activate([
      button.topAnchor.constraint(equalTo: topAnchor),
      button.bottomAnchor.constraint(equalTo: bottomAnchor),
      button.leadingAnchor.constraint(equalTo: leadingAnchor),
      button.trailingAnchor.constraint(equalTo: trailingAnchor),
      trailingAccessoryView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10.0),
      trailingAccessoryView.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])

    sceneObserver = NotificationCenter.default.addObserver(
      forName: MarcoLiquidGlassSupport.sceneActivationChangedNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self = self else { return }
      UIView.animate(withDuration: 0.18) {
        self.alpha = MarcoLiquidGlassSupport.isSceneActive ? 1.0 : 0.88
      }
    }
  }

  deinit {
    if let obs = sceneObserver {
      NotificationCenter.default.removeObserver(obs)
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window != nil {
      MarcoLiquidGlassSupport.bringRootChromeToFront()
      DispatchQueue.main.async {
        MarcoLiquidGlassSupport.bringRootChromeToFront()
      }
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    if fallbackBlurView.superview != nil {
      fallbackBlurView.layer.cornerRadius = bounds.height * 0.5
    }
    MarcoLiquidGlassSupport.bringRootChromeToFront()
  }

  @objc private func handleButtonTap() {
    if #available(iOS 17.0, *) {
      button.imageView?.addSymbolEffect(.bounce, options: .nonRepeating, animated: true)
    }
    onTap?()
  }

  func configure(
    isCapsule: Bool,
    label: String,
    symbol: String?,
    trailingSymbol: String?,
    foregroundColor: UIColor,
    tintColor: UIColor?,
    prominent: Bool,
    symbolSize: CGFloat,
    menu: UIMenu?,
    menuAsPrimaryAction: Bool,
    accessibilityLabel: String,
    forceDark: Bool
  ) {
    MarcoLiquidGlassSupport.withoutAnimations {
      let targetStyle: UIUserInterfaceStyle = forceDark ? .dark : MarcoLiquidGlassSupport.interfaceStyle
      self.tag = forceDark ? 99001 : 0
      self.overrideUserInterfaceStyle = targetStyle
      self.button.overrideUserInterfaceStyle = targetStyle
      self.fallbackBlurView.overrideUserInterfaceStyle = targetStyle
      self.accessibilityLabel = accessibilityLabel
      self.button.accessibilityLabel = accessibilityLabel

      let symCfg = UIImage.SymbolConfiguration(pointSize: symbolSize, weight: .semibold)
      let leadingImg = symbol.flatMap { UIImage(systemName: $0, withConfiguration: symCfg) }
      let hasTrailing = isCapsule && !(trailingSymbol?.isEmpty ?? true)

      if hasTrailing, let trailing = trailingSymbol {
        let trailCfg = UIImage.SymbolConfiguration(pointSize: max(symbolSize - 3.0, 11.0), weight: .semibold)
        self.trailingAccessoryView.image = UIImage(systemName: trailing, withConfiguration: trailCfg)
        self.trailingAccessoryView.tintColor = foregroundColor.withAlphaComponent(0.82)
        self.trailingAccessoryView.isHidden = false
      } else {
        self.trailingAccessoryView.isHidden = true
      }

      let useProminent = prominent || tintColor != nil
      let singleLineLabel = label
        .replacingOccurrences(of: "\r", with: " ")
        .replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)

      if #available(iOS 15.0, *) {
        var titleAttr: AttributedString?
        if isCapsule && !singleLineLabel.isEmpty {
          var attr = AttributedString(singleLineLabel)
          attr.font = UIFont.systemFont(ofSize: 13.0, weight: .semibold)
          titleAttr = attr
        }

        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
          var cfg = useProminent ? UIButton.Configuration.prominentGlass() : UIButton.Configuration.glass()
          cfg.image = leadingImg
          cfg.attributedTitle = titleAttr
          cfg.titleLineBreakMode = .byTruncatingTail
          cfg.baseForegroundColor = foregroundColor
          if let tint = tintColor {
            cfg.baseBackgroundColor = tint
          } else if forceDark {
            cfg.baseBackgroundColor = UIColor(white: 0.10, alpha: 0.35)
          }
          cfg.imagePadding = isCapsule ? 4.5 : 0.0
          cfg.cornerStyle = .capsule
          cfg.contentInsets = isCapsule
            ? NSDirectionalEdgeInsets(top: 0.0, leading: 11.0, bottom: 0.0, trailing: hasTrailing ? 24.0 : 11.0)
            : .zero
          self.button.configuration = cfg
          self.button.cornerConfiguration = .capsule()
        } else {
          var cfg = useProminent ? UIButton.Configuration.filled() : UIButton.Configuration.plain()
          cfg.image = leadingImg
          cfg.attributedTitle = titleAttr
          cfg.titleLineBreakMode = .byTruncatingTail
          cfg.baseForegroundColor = foregroundColor
          if let tint = tintColor {
            cfg.baseBackgroundColor = tint
          }
          cfg.imagePadding = isCapsule ? 4.5 : 0.0
          cfg.cornerStyle = .capsule
          cfg.contentInsets = isCapsule
            ? NSDirectionalEdgeInsets(top: 0.0, leading: 11.0, bottom: 0.0, trailing: hasTrailing ? 24.0 : 11.0)
            : .zero
          self.button.configuration = cfg
        }
        #else
        var cfg = useProminent ? UIButton.Configuration.filled() : UIButton.Configuration.plain()
        cfg.image = leadingImg
        cfg.attributedTitle = titleAttr
        cfg.titleLineBreakMode = .byTruncatingTail
        cfg.baseForegroundColor = foregroundColor
        if let tint = tintColor {
          cfg.baseBackgroundColor = tint
        }
        cfg.imagePadding = isCapsule ? 4.5 : 0.0
        cfg.cornerStyle = .capsule
        cfg.contentInsets = isCapsule
          ? NSDirectionalEdgeInsets(top: 0.0, leading: 11.0, bottom: 0.0, trailing: hasTrailing ? 24.0 : 11.0)
          : .zero
        self.button.configuration = cfg
        #endif
        self.button.titleLabel?.numberOfLines = 1
        self.button.titleLabel?.lineBreakMode = .byTruncatingTail
        self.button.titleLabel?.allowsDefaultTighteningForTruncation = true
      } else {
        self.button.setImage(leadingImg, for: .normal)
        self.button.setTitle(isCapsule ? singleLineLabel : nil, for: .normal)
        self.button.titleLabel?.font = UIFont.systemFont(ofSize: 13.0, weight: .semibold)
        self.button.titleLabel?.numberOfLines = 1
        self.button.titleLabel?.lineBreakMode = .byTruncatingTail
        self.button.titleLabel?.allowsDefaultTighteningForTruncation = true
        self.button.tintColor = foregroundColor
        self.button.setTitleColor(foregroundColor, for: .normal)
        self.button.backgroundColor = useProminent ? (tintColor ?? UIColor.systemBlue) : .clear
        self.button.contentEdgeInsets = isCapsule
          ? UIEdgeInsets(top: 0.0, left: 11.0, bottom: 0.0, right: hasTrailing ? 24.0 : 11.0)
          : .zero
      }

      if let menu = menu {
        self.button.menu = menu
        self.button.showsMenuAsPrimaryAction = menuAsPrimaryAction
      } else {
        self.button.menu = nil
        self.button.showsMenuAsPrimaryAction = false
      }
    }
  }
}

private final class MarcoNativeGlassButtonPlatformView: NSObject, FlutterPlatformView {
  private let hostView = MarcoTraitAwareHostView(frame: .zero)
  private let glassButton = MarcoNativeGlassButtonControl(frame: .zero)
  private let channel: FlutterMethodChannel
  private var lastArgs: [String: Any] = [:]
  private var appearanceObserver: NSObjectProtocol?

  init(
    frame: CGRect,
    viewId: Int64,
    arguments args: [String: Any]?,
    messenger: FlutterBinaryMessenger
  ) {
    self.channel = FlutterMethodChannel(
      name: "marco_movie/ios26_glass_button_\(viewId)",
      binaryMessenger: messenger
    )
    super.init()

    let initialFrame = MarcoLiquidGlassSupport.resolvedInitialFrame(
      frame,
      args: args,
      defaultWidth: 40.0,
      defaultHeight: 40.0
    )
    MarcoLiquidGlassSupport.withoutAnimations {
      self.hostView.frame = initialFrame
      self.hostView.backgroundColor = .clear
      self.hostView.isOpaque = false
      self.hostView.clipsToBounds = false
      self.hostView.overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle

      self.glassButton.translatesAutoresizingMaskIntoConstraints = false
      self.glassButton.onTap = { [weak self] in
        self?.handleTap()
      }
      self.hostView.addSubview(self.glassButton)

      NSLayoutConstraint.activate([
        self.glassButton.topAnchor.constraint(equalTo: self.hostView.topAnchor),
        self.glassButton.bottomAnchor.constraint(equalTo: self.hostView.bottomAnchor),
        self.glassButton.leadingAnchor.constraint(equalTo: self.hostView.leadingAnchor),
        self.glassButton.trailingAnchor.constraint(equalTo: self.hostView.trailingAnchor),
      ])

      if let args = args {
        self.apply(args)
      }
      self.hostView.layoutIfNeeded()
    }

    self.hostView.onTraitChanged = { [weak self] in
      guard let self = self, !self.lastArgs.isEmpty else { return }
      self.apply(self.lastArgs)
    }
    appearanceObserver = NotificationCenter.default.addObserver(
      forName: MarcoLiquidGlassSupport.appearanceChangedNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self = self, !self.lastArgs.isEmpty else { return }
      self.apply(self.lastArgs)
    }

    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(nil)
        return
      }
      DispatchQueue.main.async {
        if call.method == "update", let args = call.arguments as? [String: Any] {
          self.apply(args)
          result(nil)
        } else {
          result(FlutterMethodNotImplemented)
        }
      }
    }
  }

  deinit {
    if let obs = appearanceObserver {
      NotificationCenter.default.removeObserver(obs)
    }
    channel.setMethodCallHandler(nil)
  }

  func view() -> UIView {
    return hostView
  }

  private func apply(_ args: [String: Any]) {
    lastArgs = args
    let style = (args["style"] as? String) ?? "circle"
    let symbol = args["symbol"] as? String
    let trailingSymbol = args["trailingSymbol"] as? String
    let label = (args["label"] as? String) ?? ""
    let symbolSize = CGFloat((args["symbolSize"] as? NSNumber)?.doubleValue ?? 17.0)
    let forceDark = (args["forceDark"] as? Bool) ?? false
    let prominent = (args["prominent"] as? Bool) ?? false
    let tintColor = MarcoLiquidGlassSupport.colorFromARGB(args["tintColor"])
    let explicitFg = MarcoLiquidGlassSupport.colorFromARGB(args["foregroundColor"])
    let effectiveDark = forceDark || MarcoLiquidGlassSupport.isEffectiveDark(for: hostView)
    let fgColor: UIColor
    if let explicit = explicitFg {
      if tintColor == nil && !effectiveDark && MarcoLiquidGlassSupport.isNearWhite(explicit) {
        fgColor = MarcoLiquidGlassSupport.adaptiveGlassForeground(for: hostView, forceDark: false)
      } else if tintColor == nil && effectiveDark && MarcoLiquidGlassSupport.isNearBlack(explicit) {
        fgColor = MarcoLiquidGlassSupport.adaptiveGlassForeground(for: hostView, forceDark: true)
      } else {
        fgColor = explicit
      }
    } else if tintColor != nil {
      fgColor = .white
    } else {
      fgColor = MarcoLiquidGlassSupport.adaptiveGlassForeground(for: hostView, forceDark: forceDark)
    }
    let targetStyle: UIUserInterfaceStyle = forceDark ? .dark : MarcoLiquidGlassSupport.interfaceStyle
    hostView.tag = forceDark ? 99001 : 0
    hostView.overrideUserInterfaceStyle = targetStyle

    let a11yLabel = (args["accessibilityLabel"] as? String) ?? label
    let menuTitle = (args["menuTitle"] as? String) ?? ""
    let rawMenuItems = (args["menuItems"] as? [[String: Any]]) ?? []
    let menuAsPrimaryAction = (args["menuAsPrimaryAction"] as? Bool) ?? true
    let menu = MarcoLiquidGlassSupport.buildMenu(title: menuTitle, rawItems: rawMenuItems) { [weak self] selectedId in
      self?.channel.invokeMethod("onMenuSelected", arguments: selectedId)
    }

    let isCapsuleMode = (style == "capsule" && (!label.isEmpty || (trailingSymbol != nil && !trailingSymbol!.isEmpty)))
    glassButton.configure(
      isCapsule: isCapsuleMode,
      label: label,
      symbol: symbol,
      trailingSymbol: trailingSymbol,
      foregroundColor: fgColor,
      tintColor: tintColor,
      prominent: prominent,
      symbolSize: symbolSize,
      menu: menu,
      menuAsPrimaryAction: menuAsPrimaryAction,
      accessibilityLabel: a11yLabel,
      forceDark: forceDark
    )
  }

  private func handleTap() {
    let generator = UIImpactFeedbackGenerator(style: .light)
    generator.impactOccurred()
    channel.invokeMethod("onTap", arguments: nil)
  }
}

// MARK: - 3. Native iOS 26/27 Multi-Action Liquid Glass Pill (UIGlassContainerEffect + UIButton.Configuration.glass())

private final class MarcoNativeGlassPillFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    return FlutterStandardMessageCodec.sharedInstance()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    return MarcoNativeGlassPillPlatformView(
      frame: frame,
      viewId: viewId,
      arguments: args as? [String: Any],
      messenger: messenger
    )
  }
}

private final class MarcoGlassPillHostView: UIView {
  let effectView: UIVisualEffectView
  let stack = UIStackView()
  var onTraitChanged: (() -> Void)?
  private var sceneObserver: NSObjectProtocol?

  override init(frame: CGRect) {
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      let containerEffect = UIGlassContainerEffect()
      containerEffect.spacing = 6.0
      effectView = UIVisualEffectView(effect: containerEffect)
    } else {
      effectView = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
    }
    #else
    effectView = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
    #endif
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false
    clipsToBounds = false
    overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle
    isExclusiveTouch = true
    isMultipleTouchEnabled = false

    effectView.overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle
    effectView.backgroundColor = .clear
    effectView.translatesAutoresizingMaskIntoConstraints = false
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      effectView.cornerConfiguration = .capsule()
    } else {
      effectView.layer.cornerCurve = .continuous
      effectView.clipsToBounds = true
    }
    #else
    effectView.layer.cornerCurve = .continuous
    effectView.clipsToBounds = true
    #endif
    addSubview(effectView)

    stack.axis = .horizontal
    stack.alignment = .center
    stack.distribution = .fill
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      stack.spacing = 4.0
    } else {
      stack.spacing = 0.0
    }
    #else
    stack.spacing = 0.0
    #endif
    stack.translatesAutoresizingMaskIntoConstraints = false
    effectView.contentView.addSubview(stack)

    NSLayoutConstraint.activate([
      effectView.topAnchor.constraint(equalTo: topAnchor),
      effectView.bottomAnchor.constraint(equalTo: bottomAnchor),
      effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
      effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.topAnchor.constraint(equalTo: effectView.contentView.topAnchor),
      stack.bottomAnchor.constraint(equalTo: effectView.contentView.bottomAnchor),
      stack.leadingAnchor.constraint(equalTo: effectView.contentView.leadingAnchor, constant: 4.0),
      stack.trailingAnchor.constraint(equalTo: effectView.contentView.trailingAnchor, constant: -4.0),
    ])

    sceneObserver = NotificationCenter.default.addObserver(
      forName: MarcoLiquidGlassSupport.sceneActivationChangedNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self = self else { return }
      UIView.animate(withDuration: 0.18) {
        self.alpha = MarcoLiquidGlassSupport.isSceneActive ? 1.0 : 0.88
      }
    }
  }

  deinit {
    if let obs = sceneObserver {
      NotificationCenter.default.removeObserver(obs)
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window != nil {
      MarcoLiquidGlassSupport.bringRootChromeToFront()
      DispatchQueue.main.async {
        MarcoLiquidGlassSupport.bringRootChromeToFront()
      }
    }
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
      onTraitChanged?()
    }
  }

  func configureAppearance(forceDark: Bool) {
    let targetStyle: UIUserInterfaceStyle = forceDark ? .dark : MarcoLiquidGlassSupport.interfaceStyle
    tag = forceDark ? 99001 : 0
    overrideUserInterfaceStyle = targetStyle
    effectView.overrideUserInterfaceStyle = targetStyle
    effectView.backgroundColor = .clear
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      return
    }
    #endif
    effectView.layer.cornerRadius = bounds.height * 0.5
  }
}

private final class MarcoNativeGlassPillPlatformView: NSObject, FlutterPlatformView {
  private let hostView: MarcoGlassPillHostView
  private let channel: FlutterMethodChannel
  private var buttons: [UIButton] = []
  private var separators: [UIView] = []
  private var lastArgs: [String: Any] = [:]
  private var appearanceObserver: NSObjectProtocol?

  init(
    frame: CGRect,
    viewId: Int64,
    arguments args: [String: Any]?,
    messenger: FlutterBinaryMessenger
  ) {
    let initialFrame = MarcoLiquidGlassSupport.resolvedInitialFrame(
      frame,
      args: args,
      defaultWidth: 128.0,
      defaultHeight: 40.0
    )
    self.hostView = MarcoGlassPillHostView(frame: initialFrame)
    self.channel = FlutterMethodChannel(
      name: "marco_movie/ios26_glass_pill_\(viewId)",
      binaryMessenger: messenger
    )
    super.init()

    if let args = args {
      MarcoLiquidGlassSupport.withoutAnimations {
        self.apply(args)
        self.hostView.layoutIfNeeded()
      }
    }

    self.hostView.onTraitChanged = { [weak self] in
      guard let self = self, !self.lastArgs.isEmpty else { return }
      self.apply(self.lastArgs)
    }
    appearanceObserver = NotificationCenter.default.addObserver(
      forName: MarcoLiquidGlassSupport.appearanceChangedNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self = self, !self.lastArgs.isEmpty else { return }
      self.apply(self.lastArgs)
    }

    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(nil)
        return
      }
      DispatchQueue.main.async {
        if call.method == "update", let args = call.arguments as? [String: Any] {
          self.apply(args)
          result(nil)
        } else {
          result(FlutterMethodNotImplemented)
        }
      }
    }
  }

  deinit {
    if let obs = appearanceObserver {
      NotificationCenter.default.removeObserver(obs)
    }
    channel.setMethodCallHandler(nil)
  }

  func view() -> UIView {
    return hostView
  }

  private func apply(_ args: [String: Any]) {
    lastArgs = args
    guard let items = args["items"] as? [[String: Any]] else { return }
    let forceDark = (args["forceDark"] as? Bool) ?? false
    hostView.configureAppearance(forceDark: forceDark)
    let dark = forceDark || MarcoLiquidGlassSupport.isEffectiveDark(for: hostView)
    let targetStyle: UIUserInterfaceStyle = forceDark ? .dark : MarcoLiquidGlassSupport.interfaceStyle
    let sepColor = dark ? UIColor.white.withAlphaComponent(0.24) : UIColor.black.withAlphaComponent(0.14)

    var useNativeGlass26 = false
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      useNativeGlass26 = true
    }
    #endif

    if buttons.count != items.count {
      for sub in hostView.stack.arrangedSubviews {
        hostView.stack.removeArrangedSubview(sub)
        sub.removeFromSuperview()
      }
      buttons.removeAll()
      separators.removeAll()
      for idx in 0..<items.count {
        if idx > 0 && !useNativeGlass26 {
          let sep = UIView()
          sep.backgroundColor = sepColor
          sep.translatesAutoresizingMaskIntoConstraints = false
          NSLayoutConstraint.activate([
            sep.widthAnchor.constraint(equalToConstant: 0.6),
            sep.heightAnchor.constraint(equalToConstant: 18.0),
          ])
          hostView.stack.addArrangedSubview(sep)
          separators.append(sep)
        }
        let btn = UIButton(type: .system)
        btn.tag = idx
        btn.overrideUserInterfaceStyle = targetStyle
        btn.translatesAutoresizingMaskIntoConstraints = false
        if #available(iOS 17.0, *) {
          btn.isSymbolAnimationEnabled = true
        }
        btn.addTarget(self, action: #selector(itemTapped(_:)), for: .touchUpInside)
        NSLayoutConstraint.activate([
          btn.widthAnchor.constraint(equalToConstant: 36.0),
          btn.heightAnchor.constraint(equalToConstant: 36.0),
        ])
        hostView.stack.addArrangedSubview(btn)
        buttons.append(btn)
      }
    }

    for sep in separators {
      sep.backgroundColor = sepColor
    }

    let defaultFg = MarcoLiquidGlassSupport.adaptiveGlassForeground(for: hostView, forceDark: forceDark)
    let symCfg = UIImage.SymbolConfiguration(pointSize: 17.5, weight: .medium)
    for (idx, item) in items.enumerated() where idx < buttons.count {
      let btn = buttons[idx]
      btn.overrideUserInterfaceStyle = targetStyle
      let symbol = (item["symbol"] as? String) ?? "circle"
      let explicitTint = MarcoLiquidGlassSupport.colorFromARGB(item["color"])
      let tint: UIColor
      if let c = explicitTint {
        if !dark && MarcoLiquidGlassSupport.isNearWhite(c) {
          tint = defaultFg
        } else if dark && MarcoLiquidGlassSupport.isNearBlack(c) {
          tint = defaultFg
        } else {
          tint = c
        }
      } else {
        tint = defaultFg
      }
      let label = (item["accessibilityLabel"] as? String) ?? symbol
      let img = UIImage(systemName: symbol, withConfiguration: symCfg)
      if #available(iOS 15.0, *) {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
          var cfg = UIButton.Configuration.glass()
          cfg.image = img
          cfg.baseForegroundColor = tint
          cfg.cornerStyle = .capsule
          cfg.contentInsets = .zero
          btn.configuration = cfg
          btn.cornerConfiguration = .capsule()
        } else {
          var cfg = UIButton.Configuration.plain()
          cfg.image = img
          cfg.baseForegroundColor = tint
          cfg.contentInsets = .zero
          btn.configuration = cfg
        }
        #else
        var cfg = UIButton.Configuration.plain()
        cfg.image = img
        cfg.baseForegroundColor = tint
        cfg.contentInsets = .zero
        btn.configuration = cfg
        #endif
      } else {
        btn.setImage(img, for: .normal)
        btn.tintColor = tint
      }
      btn.accessibilityLabel = label
    }
  }

  @objc private func itemTapped(_ sender: UIButton) {
    if #available(iOS 17.0, *) {
      sender.imageView?.addSymbolEffect(.bounce, options: .nonRepeating, animated: true)
    }
    let generator = UIImpactFeedbackGenerator(style: .light)
    generator.impactOccurred()
    channel.invokeMethod("onAction", arguments: sender.tag)
  }
}

// MARK: - 4. Native iOS 26 UISegmentedControl (Home Categories / Library / Netdisk)

private final class MarcoNativeSegmentedControlFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    return FlutterStandardMessageCodec.sharedInstance()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    return MarcoNativeSegmentedControlPlatformView(
      frame: frame,
      viewId: viewId,
      arguments: args as? [String: Any],
      messenger: messenger
    )
  }
}

private final class MarcoNativeSegmentedControlPlatformView: NSObject, FlutterPlatformView {
  private let hostView = MarcoTraitAwareHostView(frame: .zero)
  private let control = UISegmentedControl(items: [])
  private let channel: FlutterMethodChannel
  private var currentSegments: [String] = []
  private var appearanceObserver: NSObjectProtocol?

  init(
    frame: CGRect,
    viewId: Int64,
    arguments args: [String: Any]?,
    messenger: FlutterBinaryMessenger
  ) {
    self.channel = FlutterMethodChannel(
      name: "marco_movie/ios26_segmented_control_\(viewId)",
      binaryMessenger: messenger
    )
    super.init()

    let initialFrame = MarcoLiquidGlassSupport.resolvedInitialFrame(
      frame,
      args: args,
      defaultWidth: 280.0,
      defaultHeight: 36.0
    )
    MarcoLiquidGlassSupport.withoutAnimations {
      self.hostView.frame = initialFrame
      self.hostView.backgroundColor = .clear
      self.hostView.isOpaque = false
      self.hostView.clipsToBounds = false
      self.hostView.overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle

      self.control.overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle
      self.control.apportionsSegmentWidthsByContent = false
      self.control.translatesAutoresizingMaskIntoConstraints = false
      self.applySegmentTypography()
      self.control.addTarget(self, action: #selector(self.valueChanged), for: .valueChanged)
      self.hostView.addSubview(self.control)

      NSLayoutConstraint.activate([
        self.control.topAnchor.constraint(equalTo: self.hostView.topAnchor),
        self.control.bottomAnchor.constraint(equalTo: self.hostView.bottomAnchor),
        self.control.leadingAnchor.constraint(equalTo: self.hostView.leadingAnchor),
        self.control.trailingAnchor.constraint(equalTo: self.hostView.trailingAnchor),
      ])

      if let args = args {
        self.apply(args)
      }
      self.hostView.layoutIfNeeded()
    }

    self.hostView.onTraitChanged = { [weak self] in
      self?.refreshAppearance()
    }
    appearanceObserver = NotificationCenter.default.addObserver(
      forName: MarcoLiquidGlassSupport.appearanceChangedNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.refreshAppearance()
    }

    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(nil)
        return
      }
      DispatchQueue.main.async {
        switch call.method {
        case "update":
          if let args = call.arguments as? [String: Any] {
            self.apply(args)
          }
          result(nil)
        case "setSelectedIndex":
          if let idx = call.arguments as? Int,
             idx >= 0, idx < self.control.numberOfSegments,
             self.control.selectedSegmentIndex != idx {
            self.control.selectedSegmentIndex = idx
          }
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }
  }

  deinit {
    if let obs = appearanceObserver {
      NotificationCenter.default.removeObserver(obs)
    }
    channel.setMethodCallHandler(nil)
  }

  private func applySegmentTypography() {
    let segDark = MarcoLiquidGlassSupport.isEffectiveDark(for: hostView)
    control.setTitleTextAttributes(
      [
        .foregroundColor: segDark ? UIColor.white.withAlphaComponent(0.76) : UIColor.label.withAlphaComponent(0.74),
        .font: UIFont.systemFont(ofSize: 13.0, weight: .semibold),
      ],
      for: .normal
    )
    control.setTitleTextAttributes(
      [
        .foregroundColor: segDark ? UIColor.white : UIColor.label,
        .font: UIFont.systemFont(ofSize: 13.0, weight: .semibold),
      ],
      for: .selected
    )
  }

  private func refreshAppearance() {
    hostView.overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle
    control.overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle
    applySegmentTypography()
  }

  func view() -> UIView {
    return hostView
  }

  private func apply(_ args: [String: Any]) {
    if let segments = args["segments"] as? [String], segments != currentSegments {
      currentSegments = segments
      control.removeAllSegments()
      for (idx, title) in segments.enumerated() {
        control.insertSegment(withTitle: title, at: idx, animated: false)
      }
    }
    if let idx = args["selectedIndex"] as? Int,
       idx >= 0, idx < control.numberOfSegments,
       control.selectedSegmentIndex != idx {
      control.selectedSegmentIndex = idx
    }
  }

  @objc private func valueChanged() {
    let idx = control.selectedSegmentIndex
    if idx >= 0 {
      channel.invokeMethod("onChanged", arguments: idx)
    }
  }
}

// MARK: - 5. Native iOS 26 UISwitch (Liquid Glass Expanding Crystal Thumb)

private final class MarcoNativeSwitchFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    return FlutterStandardMessageCodec.sharedInstance()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    return MarcoNativeSwitchPlatformView(
      frame: frame,
      viewId: viewId,
      arguments: args as? [String: Any],
      messenger: messenger
    )
  }
}

private final class MarcoNativeSwitchPlatformView: NSObject, FlutterPlatformView {
  private let hostView = MarcoTraitAwareHostView(frame: .zero)
  private let toggle = UISwitch(frame: .zero)
  private let channel: FlutterMethodChannel
  private var appearanceObserver: NSObjectProtocol?

  init(
    frame: CGRect,
    viewId: Int64,
    arguments args: [String: Any]?,
    messenger: FlutterBinaryMessenger
  ) {
    self.channel = FlutterMethodChannel(
      name: "marco_movie/ios26_switch_\(viewId)",
      binaryMessenger: messenger
    )
    super.init()

    let initialFrame = MarcoLiquidGlassSupport.resolvedInitialFrame(
      frame,
      args: args,
      defaultWidth: 51.0,
      defaultHeight: 31.0
    )
    MarcoLiquidGlassSupport.withoutAnimations {
      self.hostView.frame = initialFrame
      self.hostView.backgroundColor = .clear
      self.hostView.isOpaque = false
      self.hostView.clipsToBounds = false
      self.hostView.overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle

      self.toggle.overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle
      self.toggle.onTintColor = UIColor.systemGreen
      self.toggle.translatesAutoresizingMaskIntoConstraints = false
      self.toggle.addTarget(self, action: #selector(self.valueChanged), for: .valueChanged)
      self.hostView.addSubview(self.toggle)

      NSLayoutConstraint.activate([
        self.toggle.centerXAnchor.constraint(equalTo: self.hostView.centerXAnchor),
        self.toggle.centerYAnchor.constraint(equalTo: self.hostView.centerYAnchor),
      ])

      if let args = args {
        self.apply(args, animated: false)
      }
      self.hostView.layoutIfNeeded()
    }

    self.hostView.onTraitChanged = { [weak self] in
      guard let self = self else { return }
      self.hostView.overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle
      self.toggle.overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle
    }
    appearanceObserver = NotificationCenter.default.addObserver(
      forName: MarcoLiquidGlassSupport.appearanceChangedNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self = self else { return }
      self.hostView.overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle
      self.toggle.overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle
    }

    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(nil)
        return
      }
      DispatchQueue.main.async {
        if call.method == "update", let args = call.arguments as? [String: Any] {
          self.apply(args, animated: true)
          result(nil)
        } else {
          result(FlutterMethodNotImplemented)
        }
      }
    }
  }

  deinit {
    if let obs = appearanceObserver {
      NotificationCenter.default.removeObserver(obs)
    }
    channel.setMethodCallHandler(nil)
  }

  func view() -> UIView {
    return hostView
  }

  private func apply(_ args: [String: Any], animated: Bool) {
    if let color = MarcoLiquidGlassSupport.colorFromARGB(args["onTintColor"]) {
      toggle.onTintColor = color
    }
    if let enabled = args["enabled"] as? Bool {
      toggle.isEnabled = enabled
    }
    if let a11y = args["accessibilityLabel"] as? String, !a11y.isEmpty {
      toggle.accessibilityLabel = a11y
    }
    if let val = args["value"] as? Bool, toggle.isOn != val {
      toggle.setOn(val, animated: animated)
    }
  }

  @objc private func valueChanged() {
    channel.invokeMethod("onChanged", arguments: toggle.isOn)
  }
}

// MARK: - 6. Native iOS 26 UISlider (Liquid Glass Magnifying Pill Thumb)

private final class MarcoNativeSliderFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    return FlutterStandardMessageCodec.sharedInstance()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    return MarcoNativeSliderPlatformView(
      frame: frame,
      viewId: viewId,
      arguments: args as? [String: Any],
      messenger: messenger
    )
  }
}

private final class MarcoHitExpandedSlider: UISlider {
  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    return bounds.insetBy(dx: -10.0, dy: -16.0).contains(point)
  }
}

private final class MarcoNativeSliderPlatformView: NSObject, FlutterPlatformView {
  private let hostView = MarcoTraitAwareHostView(frame: .zero)
  private let slider = MarcoHitExpandedSlider(frame: .zero)
  private let channel: FlutterMethodChannel
  private var appearanceObserver: NSObjectProtocol?

  init(
    frame: CGRect,
    viewId: Int64,
    arguments args: [String: Any]?,
    messenger: FlutterBinaryMessenger
  ) {
    self.channel = FlutterMethodChannel(
      name: "marco_movie/ios26_slider_\(viewId)",
      binaryMessenger: messenger
    )
    super.init()

    let initialFrame = MarcoLiquidGlassSupport.resolvedInitialFrame(
      frame,
      args: args,
      defaultWidth: 320.0,
      defaultHeight: 48.0
    )
    MarcoLiquidGlassSupport.withoutAnimations {
      self.hostView.frame = initialFrame
      self.hostView.backgroundColor = .clear
      self.hostView.isOpaque = false
      self.hostView.clipsToBounds = false
      self.hostView.overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle

      self.slider.overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle
      self.slider.minimumTrackTintColor = UIColor.systemBlue
      self.slider.maximumTrackTintColor = MarcoLiquidGlassSupport.isEffectiveDark(for: self.hostView)
        ? UIColor.white.withAlphaComponent(0.24)
        : UIColor.black.withAlphaComponent(0.14)
      self.slider.isContinuous = true
      self.slider.translatesAutoresizingMaskIntoConstraints = false
      self.slider.addTarget(self, action: #selector(self.valueChanged), for: .valueChanged)
      self.slider.addTarget(self, action: #selector(self.touchEnded), for: [.touchUpInside, .touchUpOutside, .touchCancel])
      let tap = UITapGestureRecognizer(target: self, action: #selector(self.trackTapped(_:)))
      tap.cancelsTouchesInView = false
      self.slider.addGestureRecognizer(tap)
      self.hostView.addSubview(self.slider)

      NSLayoutConstraint.activate([
        self.slider.leadingAnchor.constraint(equalTo: self.hostView.leadingAnchor),
        self.slider.trailingAnchor.constraint(equalTo: self.hostView.trailingAnchor),
        self.slider.centerYAnchor.constraint(equalTo: self.hostView.centerYAnchor),
        self.slider.heightAnchor.constraint(greaterThanOrEqualToConstant: 44.0),
      ])

      if let args = args {
        self.apply(args)
      }
      self.hostView.layoutIfNeeded()
    }

    let refreshSliderTheme: () -> Void = { [weak self] in
      guard let self = self else { return }
      self.hostView.overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle
      self.slider.overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle
      self.slider.maximumTrackTintColor = MarcoLiquidGlassSupport.isEffectiveDark(for: self.hostView)
        ? UIColor.white.withAlphaComponent(0.24)
        : UIColor.black.withAlphaComponent(0.14)
    }
    self.hostView.onTraitChanged = refreshSliderTheme
    appearanceObserver = NotificationCenter.default.addObserver(
      forName: MarcoLiquidGlassSupport.appearanceChangedNotification,
      object: nil,
      queue: .main
    ) { _ in
      refreshSliderTheme()
    }

    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(nil)
        return
      }
      DispatchQueue.main.async {
        if call.method == "update", let args = call.arguments as? [String: Any] {
          self.apply(args)
          result(nil)
        } else {
          result(FlutterMethodNotImplemented)
        }
      }
    }
  }

  deinit {
    if let obs = appearanceObserver {
      NotificationCenter.default.removeObserver(obs)
    }
    channel.setMethodCallHandler(nil)
  }

  func view() -> UIView {
    return hostView
  }

  private func apply(_ args: [String: Any]) {
    if let minVal = (args["min"] as? NSNumber)?.floatValue {
      slider.minimumValue = minVal
    }
    if let maxVal = (args["max"] as? NSNumber)?.floatValue {
      slider.maximumValue = maxVal
    }
    if let tint = MarcoLiquidGlassSupport.colorFromARGB(args["tintColor"]) {
      slider.minimumTrackTintColor = tint
    }
    if let a11y = args["accessibilityLabel"] as? String, !a11y.isEmpty {
      slider.accessibilityLabel = a11y
    }
    if !slider.isTracking, let val = (args["value"] as? NSNumber)?.floatValue {
      if abs(slider.value - val) > 0.0005 {
        slider.setValue(val, animated: false)
      }
    }
  }

  @objc private func trackTapped(_ gesture: UITapGestureRecognizer) {
    guard gesture.state == .ended else { return }
    let trackRect = slider.trackRect(forBounds: slider.bounds)
    guard trackRect.width > 1.0 else { return }
    let loc = gesture.location(in: slider)
    let ratio = min(max((loc.x - trackRect.minX) / trackRect.width, 0.0), 1.0)
    let newValue = slider.minimumValue + Float(ratio) * (slider.maximumValue - slider.minimumValue)
    slider.setValue(newValue, animated: true)
    UISelectionFeedbackGenerator().selectionChanged()
    channel.invokeMethod("onChanged", arguments: Double(newValue))
    channel.invokeMethod("onChangeEnd", arguments: Double(newValue))
  }

  @objc private func valueChanged() {
    channel.invokeMethod("onChanged", arguments: Double(slider.value))
  }

  @objc private func touchEnded() {
    channel.invokeMethod("onChangeEnd", arguments: Double(slider.value))
  }
}

private final class MarcoBonjourScanner: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
  private static var activeScanners: [MarcoBonjourScanner] = []

  private var browsers: [NetServiceBrowser] = []
  private var resolvingServices: [NetService] = []
  private var discoveredByKey: [String: [String: Any]] = [:]
  private var permissionDenied: Bool = false
  private var finished: Bool = false
  private var completion: (([String: Any]) -> Void)?

  static func scan(
    serviceTypes: [String],
    timeoutMs: Int,
    completion: @escaping ([String: Any]) -> Void
  ) {
    let scanner = MarcoBonjourScanner()
    activeScanners.append(scanner)
    scanner.start(serviceTypes: serviceTypes, timeoutMs: timeoutMs) { payload in
      activeScanners.removeAll { $0 === scanner }
      completion(payload)
    }
  }

  private func start(
    serviceTypes: [String],
    timeoutMs: Int,
    completion: @escaping ([String: Any]) -> Void
  ) {
    self.completion = completion
    let clampedMs = min(max(timeoutMs, 600), 6000)
    for rawType in serviceTypes {
      let trimmed = rawType.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { continue }
      let normalizedType = trimmed.hasSuffix(".") ? trimmed : "\(trimmed)."
      let browser = NetServiceBrowser()
      browser.delegate = self
      browser.schedule(in: .main, forMode: .common)
      browsers.append(browser)
      browser.searchForServices(ofType: normalizedType, inDomain: "local.")
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(clampedMs)) { [weak self] in
      self?.finish()
    }
  }

  private func finish() {
    guard !finished else { return }
    finished = true
    for browser in browsers {
      browser.stop()
      browser.delegate = nil
    }
    browsers.removeAll()
    for svc in resolvingServices {
      svc.stop()
      svc.delegate = nil
    }
    resolvingServices.removeAll()
    let cb = completion
    completion = nil
    cb?([
      "devices": Array(discoveredByKey.values),
      "permissionDenied": permissionDenied,
    ])
  }

  func netServiceBrowser(
    _ browser: NetServiceBrowser,
    didNotSearch errorDict: [String: NSNumber]
  ) {
    if let code = errorDict[NetService.errorCode]?.intValue, code == -72008 {
      permissionDenied = true
    }
  }

  func netServiceBrowser(
    _ browser: NetServiceBrowser,
    didFind service: NetService,
    moreComing: Bool
  ) {
    guard !finished else { return }
    service.delegate = self
    service.schedule(in: .main, forMode: .common)
    resolvingServices.append(service)
    service.resolve(withTimeout: 1.5)
  }

  func netServiceDidResolveAddress(_ sender: NetService) {
    guard !finished else { return }
    guard let addresses = sender.addresses, !addresses.isEmpty else { return }
    var resolvedHost: String?
    for data in addresses {
      if let ip = Self.ipv4Address(from: data) {
        if ip.hasPrefix("127.") || ip.hasPrefix("169.254.") { continue }
        resolvedHost = ip
        break
      }
    }
    guard let host = resolvedHost, !host.isEmpty else { return }
    let port = sender.port > 0 ? sender.port : 0
    var txtDict: [String: String] = [:]
    if let txtData = sender.txtRecordData() {
      let rawDict = NetService.dictionary(fromTXTRecord: txtData)
      for (k, v) in rawDict {
        if let str = String(data: v, encoding: .utf8), !str.isEmpty {
          txtDict[k] = str
        }
      }
    }
    let key = "\(sender.type)|\(host)|\(port)"
    discoveredByKey[key] = [
      "name": sender.name,
      "type": sender.type,
      "host": host,
      "port": port,
      "txt": txtDict,
    ]
  }

  func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
    if let code = errorDict[NetService.errorCode]?.intValue, code == -72008 {
      permissionDenied = true
    }
  }

  private static func ipv4Address(from addressData: Data) -> String? {
    return addressData.withUnsafeBytes { rawBuf -> String? in
      guard let base = rawBuf.baseAddress else { return nil }
      let sa = base.assumingMemoryBound(to: sockaddr.self)
      guard sa.pointee.sa_family == sa_family_t(AF_INET) else { return nil }
      let sin = base.assumingMemoryBound(to: sockaddr_in.self)
      var addr = sin.pointee.sin_addr
      var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
      guard inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil else {
        return nil
      }
      return String(cString: buf)
    }
  }
}
