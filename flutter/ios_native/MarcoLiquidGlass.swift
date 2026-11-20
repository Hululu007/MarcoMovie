// MARK: - iOS 26 Native Liquid Glass Bridge (injected into AppDelegate.swift by prepare_platform.py)

private enum MarcoLiquidGlassSupport {
  static var bridgeChannel: FlutterMethodChannel?
  static var brandLogoImage: UIImage?
  private static var accessibilityObservers: [NSObjectProtocol] = []

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
        ])
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
      let action = UIAction(
        title: label,
        subtitle: (subtitle?.isEmpty ?? true) ? nil : subtitle,
        image: image,
        attributes: attrs,
        state: checked ? .on : .off
      ) { _ in
        onSelect(id)
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
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let keyWindow = scenes
      .flatMap { $0.windows }
      .first(where: { $0.isKeyWindow }) ?? scenes.flatMap { $0.windows }.first
    var presenter = keyWindow?.rootViewController
    while let presented = presenter?.presentedViewController, !presented.isBeingDismissed {
      presenter = presented
    }
    return presenter
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
    alert.overrideUserInterfaceStyle = .dark
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
    sheet.overrideUserInterfaceStyle = .dark
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
  UIAdaptivePresentationControllerDelegate
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
  private let sections: [OptionSection]
  private let tableView = UITableView(frame: .zero, style: .insetGrouped)

  private var completion: FlutterResult?
  private var resolved = false
  private var dismissing = false
  private var navIdentity: ObjectIdentifier?

  private var isOpaqueMode: Bool {
    return forceOpaque || UIAccessibility.isReduceTransparencyEnabled
  }

  static func present(args: [String: Any], completion: @escaping FlutterResult) {
    guard let host = MarcoLiquidGlassSupport.topPresenter() else {
      completion(nil)
      return
    }
    let vc = MarcoNativeOptionSheetController(args: args, completion: completion)
    let nav = UINavigationController(rootViewController: vc)
    let navId = ObjectIdentifier(nav)
    vc.navIdentity = navId
    nav.modalPresentationStyle = .pageSheet
    nav.overrideUserInterfaceStyle = .dark
    nav.presentationController?.delegate = vc
    if let sheet = nav.sheetPresentationController {
      sheet.detents = [.medium(), .large()]
      sheet.prefersGrabberVisible = true
      sheet.preferredCornerRadius = 28.0
      sheet.prefersScrollingExpandsWhenScrolledToEdge = true
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

  init(args: [String: Any], completion: @escaping FlutterResult) {
    self.sheetTitle = (args["title"] as? String) ?? ""
    let rawSubtitle = (args["subtitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    self.sheetSubtitle = (rawSubtitle?.isEmpty ?? true) ? nil : rawSubtitle
    self.cancelTitle = (args["cancelTitle"] as? String) ?? "关闭"
    self.forceOpaque = (args["forceOpaque"] as? Bool) ?? false
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
    overrideUserInterfaceStyle = .dark
    let opaqueFallback = UIColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1.0)
    #if compiler(>=6.2)
    if #available(iOS 26.0, *), !isOpaqueMode {
      view.backgroundColor = .clear
    } else {
      view.backgroundColor = opaqueFallback
    }
    #else
    view.backgroundColor = opaqueFallback
    #endif

    navigationItem.title = sheetTitle
    if let subtitle = sheetSubtitle {
      navigationItem.prompt = subtitle
    }
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      title: cancelTitle,
      style: .done,
      target: self,
      action: #selector(closeTapped)
    )

    tableView.translatesAutoresizingMaskIntoConstraints = false
    tableView.overrideUserInterfaceStyle = .dark
    tableView.backgroundColor = .clear
    tableView.separatorColor = UIColor.white.withAlphaComponent(0.12)
    tableView.dataSource = self
    tableView.delegate = self
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "MarcoOptionCell")
    view.addSubview(tableView)

    NSLayoutConstraint.activate([
      tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
    ])
  }

  func numberOfSections(in tableView: UITableView) -> Int {
    return sections.count
  }

  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    return sections[section].items.count
  }

  func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
    let title = sections[section].title
    return title.isEmpty ? nil : title
  }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "MarcoOptionCell", for: indexPath)
    let item = sections[indexPath.section].items[indexPath.row]
    var cfg = cell.defaultContentConfiguration()
    cfg.text = item.title
    cfg.textProperties.color = item.destructive ? UIColor.systemRed : UIColor.white
    cfg.textProperties.font = UIFont.systemFont(
      ofSize: 15.0,
      weight: item.checked ? .semibold : .regular
    )
    if let sub = item.subtitle {
      cfg.secondaryText = sub
      cfg.secondaryTextProperties.color = UIColor.white.withAlphaComponent(0.66)
      cfg.secondaryTextProperties.font = UIFont.systemFont(ofSize: 12.5, weight: .regular)
    }
    if let symbol = item.symbol {
      let symCfg = UIImage.SymbolConfiguration(pointSize: 16.0, weight: .medium)
      cfg.image = UIImage(systemName: symbol, withConfiguration: symCfg)
      cfg.imageProperties.tintColor = item.destructive
        ? UIColor.systemRed
        : (item.checked ? UIColor.systemBlue : UIColor.white.withAlphaComponent(0.84))
    }
    cell.contentConfiguration = cfg
    cell.accessoryType = item.checked ? .checkmark : .none
    cell.tintColor = UIColor.systemBlue
    cell.backgroundColor = UIColor(white: 0.16, alpha: isOpaqueMode ? 0.96 : 0.72)
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

private final class MarcoWrapChipContainerView: UIView {
  var horizontalSpacing: CGFloat = 8.0
  var verticalSpacing: CGFloat = 8.0
  private var chipButtons: [UIButton] = []
  private var lastMeasuredWidth: CGFloat = 0.0
  private var calculatedHeight: CGFloat = 0.0

  func setButtons(_ buttons: [UIButton]) {
    for old in chipButtons {
      old.removeFromSuperview()
    }
    chipButtons = buttons
    for btn in buttons {
      addSubview(btn)
    }
    lastMeasuredWidth = 0.0
    setNeedsLayout()
    invalidateIntrinsicContentSize()
  }

  override var intrinsicContentSize: CGSize {
    return CGSize(width: UIView.noIntrinsicMetric, height: max(calculatedHeight, 34.0))
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let maxW = bounds.width
    guard maxW > 0 else { return }
    var x: CGFloat = 0.0
    var y: CGFloat = 0.0
    var rowH: CGFloat = 0.0

    for btn in chipButtons {
      let fit = btn.sizeThatFits(CGSize(width: maxW, height: 36.0))
      let w = min(max(fit.width, 52.0), maxW)
      let h = max(fit.height, 34.0)
      if x > 0 && x + w > maxW {
        x = 0.0
        y += rowH + verticalSpacing
        rowH = 0.0
      }
      btn.frame = CGRect(x: x, y: y, width: w, height: h)
      x += w + horizontalSpacing
      rowH = max(rowH, h)
    }

    let totalH = chipButtons.isEmpty ? 0.0 : (y + rowH)
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

  private var selectedCategoryId: String
  private var selectedGenreLabel: String
  private var selectedArea: String
  private var selectedYear: String

  private var categoryButtons: [UIButton] = []
  private var areaButtons: [UIButton] = []
  private var yearButtons: [UIButton] = []

  private let scrollView = UIScrollView()
  private let stackView = UIStackView()

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
    nav.overrideUserInterfaceStyle = .dark
    nav.presentationController?.delegate = vc
    if let sheet = nav.sheetPresentationController {
      sheet.detents = [.medium(), .large()]
      sheet.prefersGrabberVisible = true
      sheet.preferredCornerRadius = 28.0
      sheet.prefersScrollingExpandsWhenScrolledToEdge = true
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

  init(args: [String: Any], completion: @escaping FlutterResult) {
    self.sheetTitle = (args["title"] as? String) ?? "多维片库筛选"
    let rawCats = (args["categories"] as? [[String: Any]]) ?? []
    self.categories = rawCats.map {
      CategoryChoice(
        id: ($0["id"] as? String) ?? "",
        label: ($0["label"] as? String) ?? "",
        kind: ($0["kind"] as? String) ?? "all"
      )
    }
    self.areas = (args["areas"] as? [String]) ?? []
    self.years = (args["years"] as? [String]) ?? []
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
    overrideUserInterfaceStyle = .dark
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      view.backgroundColor = .clear
    } else {
      view.backgroundColor = UIColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1.0)
    }
    #else
    view.backgroundColor = UIColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1.0)
    #endif

    navigationItem.title = sheetTitle
    navigationItem.leftBarButtonItem = UIBarButtonItem(
      title: "重置",
      style: .plain,
      target: self,
      action: #selector(resetTapped)
    )
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      title: "完成",
      style: .done,
      target: self,
      action: #selector(doneTapped)
    )

    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.alwaysBounceVertical = true
    scrollView.showsVerticalScrollIndicator = false
    view.addSubview(scrollView)

    stackView.axis = .vertical
    stackView.spacing = 18.0
    stackView.alignment = .fill
    stackView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.addSubview(stackView)

    NSLayoutConstraint.activate([
      scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

      stackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 12.0),
      stackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -28.0),
      stackView.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 18.0),
      stackView.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -18.0),
    ])

    if !categories.isEmpty {
      categoryButtons = buildSection(
        title: "类别",
        labels: categories.map { $0.label },
        action: #selector(categoryTapped(_:))
      )
    }
    if !areas.isEmpty {
      areaButtons = buildSection(
        title: "地区",
        labels: areas,
        action: #selector(areaTapped(_:))
      )
    }
    if !years.isEmpty {
      yearButtons = buildSection(
        title: "年份",
        labels: years,
        action: #selector(yearTapped(_:))
      )
    }
    refreshSelectionStyles()
  }

  private func buildSection(title: String, labels: [String], action: Selector) -> [UIButton] {
    let header = UILabel()
    header.text = title
    header.font = UIFont.systemFont(ofSize: 13.5, weight: .semibold)
    header.textColor = UIColor.white.withAlphaComponent(0.72)

    let wrap = MarcoWrapChipContainerView()
    wrap.translatesAutoresizingMaskIntoConstraints = false

    var buttons: [UIButton] = []
    for (idx, label) in labels.enumerated() {
      let btn = UIButton(type: .system)
      btn.tag = idx
      btn.overrideUserInterfaceStyle = .dark
      btn.addTarget(self, action: action, for: .touchUpInside)
      applyChipStyle(btn, title: label, selected: false)
      buttons.append(btn)
    }
    wrap.setButtons(buttons)

    let sectionStack = UIStackView(arrangedSubviews: [header, wrap])
    sectionStack.axis = .vertical
    sectionStack.spacing = 10.0
    stackView.addArrangedSubview(sectionStack)
    return buttons
  }

  private func applyChipStyle(_ button: UIButton, title: String, selected: Bool) {
    var titleAttr = AttributedString(title)
    titleAttr.font = UIFont.systemFont(ofSize: 13.0, weight: selected ? .bold : .medium)
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      var cfg = selected ? UIButton.Configuration.prominentGlass() : UIButton.Configuration.glass()
      cfg.attributedTitle = titleAttr
      cfg.baseForegroundColor = selected ? .white : UIColor.white.withAlphaComponent(0.88)
      if selected {
        cfg.baseBackgroundColor = UIColor.systemBlue
      }
      cfg.cornerStyle = .capsule
      cfg.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 13, bottom: 7, trailing: 13)
      button.configuration = cfg
      return
    }
    #endif
    var cfg = UIButton.Configuration.filled()
    cfg.attributedTitle = titleAttr
    cfg.baseForegroundColor = selected ? .white : UIColor.white.withAlphaComponent(0.86)
    cfg.baseBackgroundColor = selected ? UIColor.systemBlue : UIColor(white: 0.22, alpha: 0.85)
    cfg.cornerStyle = .capsule
    cfg.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 13, bottom: 7, trailing: 13)
    button.configuration = cfg
  }

  private func refreshSelectionStyles() {
    for (idx, choice) in categories.enumerated() where idx < categoryButtons.count {
      let isSelected: Bool
      switch choice.kind {
      case "all":
        isSelected = selectedCategoryId.isEmpty && selectedGenreLabel.isEmpty
      case "cat":
        isSelected = selectedCategoryId == choice.id
      default:
        isSelected = selectedCategoryId.isEmpty && selectedGenreLabel == choice.label
      }
      applyChipStyle(categoryButtons[idx], title: choice.label, selected: isSelected)
    }
    for (idx, area) in areas.enumerated() where idx < areaButtons.count {
      let isSelected = (selectedArea.isEmpty && area == "全部") || selectedArea == area
      applyChipStyle(areaButtons[idx], title: area, selected: isSelected)
    }
    for (idx, yr) in years.enumerated() where idx < yearButtons.count {
      let isSelected = (selectedYear.isEmpty && yr == "全部") || selectedYear == yr
      applyChipStyle(yearButtons[idx], title: yr, selected: isSelected)
    }
    let hasAny = !selectedCategoryId.isEmpty || !selectedGenreLabel.isEmpty || !selectedArea.isEmpty || !selectedYear.isEmpty
    navigationItem.leftBarButtonItem?.isEnabled = hasAny
  }

  @objc private func categoryTapped(_ sender: UIButton) {
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
    refreshSelectionStyles()
  }

  @objc private func areaTapped(_ sender: UIButton) {
    let idx = sender.tag
    guard idx >= 0, idx < areas.count else { return }
    let val = areas[idx]
    selectedArea = (val == "全部") ? "" : val
    UISelectionFeedbackGenerator().selectionChanged()
    refreshSelectionStyles()
  }

  @objc private func yearTapped(_ sender: UIButton) {
    let idx = sender.tag
    guard idx >= 0, idx < years.count else { return }
    let val = years[idx]
    selectedYear = (val == "全部") ? "" : val
    UISelectionFeedbackGenerator().selectionChanged()
    refreshSelectionStyles()
  }

  @objc private func resetTapped() {
    selectedCategoryId = ""
    selectedGenreLabel = ""
    selectedArea = ""
    selectedYear = ""
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    refreshSelectionStyles()
  }

  @objc private func doneTapped() {
    finish(applied: true)
    dismiss(animated: true, completion: nil)
  }

  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    finish(applied: true)
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
    vc.overrideUserInterfaceStyle = .dark
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

  override func viewDidLoad() {
    super.viewDidLoad()
    overrideUserInterfaceStyle = .dark
    view.backgroundColor = .clear

    backdropControl.backgroundColor = UIColor.black.withAlphaComponent(0.58)
    backdropControl.translatesAutoresizingMaskIntoConstraints = false
    backdropControl.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
    view.addSubview(backdropControl)

    cardShadowView.backgroundColor = .clear
    cardShadowView.translatesAutoresizingMaskIntoConstraints = false
    cardShadowView.layer.shadowColor = UIColor.black.cgColor
    cardShadowView.layer.shadowOpacity = 0.45
    cardShadowView.layer.shadowRadius = 28.0
    cardShadowView.layer.shadowOffset = CGSize(width: 0, height: 14)
    view.addSubview(cardShadowView)

    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      let glass = UIGlassEffect(style: .regular)
      cardEffectView = UIVisualEffectView(effect: glass)
    } else {
      cardEffectView = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterialDark))
    }
    #else
    cardEffectView = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterialDark))
    #endif
    cardEffectView.overrideUserInterfaceStyle = .dark
    cardEffectView.translatesAutoresizingMaskIntoConstraints = false
    cardEffectView.layer.cornerRadius = 34.0
    cardEffectView.layer.cornerCurve = .continuous
    cardEffectView.clipsToBounds = true
    cardEffectView.layer.borderWidth = 0.65
    cardEffectView.layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor
    cardShadowView.addSubview(cardEffectView)

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
    titleLabel.textColor = .white
    titleLabel.textAlignment = .center
    titleLabel.numberOfLines = 1
    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(titleLabel)

    subtitleLabel.font = UIFont.systemFont(ofSize: 12.5, weight: .regular)
    subtitleLabel.textColor = UIColor.white.withAlphaComponent(0.74)
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

    // 3x4 Liquid Glass Keypad
    let isCompactHeight = UIScreen.main.bounds.height < 680.0
    let keySize: CGFloat = isCompactHeight ? 62.0 : 68.0
    let rowSpacing: CGFloat = isCompactHeight ? 10.0 : 12.0
    let colSpacing: CGFloat = isCompactHeight ? 16.0 : 20.0

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
    cardShadowView.transform = CGAffineTransform(scaleX: 0.90, y: 0.90)
    refreshUI(animatedDotIndex: nil)
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    becomeFirstResponder()
    guard !didAnimateIn else { return }
    didAnimateIn = true
    UIView.animate(
      withDuration: 0.30,
      delay: 0,
      usingSpringWithDamping: 0.84,
      initialSpringVelocity: 0.5,
      options: [.allowUserInteraction],
      animations: {
        self.backdropControl.alpha = 1.0
        self.cardShadowView.alpha = 1.0
        self.cardShadowView.transform = .identity
      },
      completion: nil
    )
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    badgeGradient.frame = badgeView.bounds
  }

  private func makeDigitButton(digit: String, size: CGFloat) -> UIButton {
    let btn = UIButton(type: .system)
    btn.translatesAutoresizingMaskIntoConstraints = false
    btn.overrideUserInterfaceStyle = .dark
    btn.tag = Int(digit) ?? 0
    btn.accessibilityLabel = digit
    var titleAttr = AttributedString(digit)
    titleAttr.font = UIFont.monospacedDigitSystemFont(ofSize: 28.0, weight: .medium)
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      var cfg = UIButton.Configuration.glass()
      cfg.attributedTitle = titleAttr
      cfg.baseForegroundColor = .white
      cfg.cornerStyle = .capsule
      cfg.contentInsets = .zero
      btn.configuration = cfg
    } else {
      var cfg = UIButton.Configuration.filled()
      cfg.attributedTitle = titleAttr
      cfg.baseForegroundColor = .white
      cfg.baseBackgroundColor = UIColor(white: 0.22, alpha: 0.85)
      cfg.cornerStyle = .capsule
      cfg.contentInsets = .zero
      btn.configuration = cfg
    }
    #else
    var cfg = UIButton.Configuration.filled()
    cfg.attributedTitle = titleAttr
    cfg.baseForegroundColor = .white
    cfg.baseBackgroundColor = UIColor(white: 0.22, alpha: 0.85)
    cfg.cornerStyle = .capsule
    cfg.contentInsets = .zero
    btn.configuration = cfg
    #endif
    btn.addTarget(self, action: #selector(digitTapped(_:)), for: .touchUpInside)
    NSLayoutConstraint.activate([
      btn.widthAnchor.constraint(equalToConstant: size),
      btn.heightAnchor.constraint(equalToConstant: size),
    ])
    return btn
  }

  private func configureCancelButton(size: CGFloat) {
    cancelButton.translatesAutoresizingMaskIntoConstraints = false
    cancelButton.overrideUserInterfaceStyle = .dark
    cancelButton.accessibilityLabel = "取消"
    var titleAttr = AttributedString("取消")
    titleAttr.font = UIFont.systemFont(ofSize: 16.0, weight: .semibold)
    var cfg = UIButton.Configuration.plain()
    cfg.attributedTitle = titleAttr
    cfg.baseForegroundColor = UIColor.white.withAlphaComponent(0.78)
    cfg.contentInsets = .zero
    cancelButton.configuration = cfg
    cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
    NSLayoutConstraint.activate([
      cancelButton.widthAnchor.constraint(equalToConstant: size),
      cancelButton.heightAnchor.constraint(equalToConstant: size),
    ])
  }

  private func configureBackspaceButton(size: CGFloat) {
    backspaceButton.translatesAutoresizingMaskIntoConstraints = false
    backspaceButton.overrideUserInterfaceStyle = .dark
    backspaceButton.accessibilityLabel = "删除"
    let symCfg = UIImage.SymbolConfiguration(pointSize: 22.0, weight: .medium)
    var cfg = UIButton.Configuration.plain()
    cfg.image = UIImage(systemName: "delete.left.fill", withConfiguration: symCfg)
    cfg.baseForegroundColor = UIColor.white.withAlphaComponent(0.84)
    cfg.contentInsets = .zero
    backspaceButton.configuration = cfg
    backspaceButton.addTarget(self, action: #selector(backspaceTapped), for: .touchUpInside)
    NSLayoutConstraint.activate([
      backspaceButton.widthAnchor.constraint(equalToConstant: size),
      backspaceButton.heightAnchor.constraint(equalToConstant: size),
    ])
  }

  private func refreshUI(animatedDotIndex: Int?) {
    titleLabel.text = (mode == "set" && confirming) ? confirmTitle : initialTitle
    let hasError = !(errorMessage?.isEmpty ?? true)
    if isBusy {
      subtitleLabel.text = loadingText
      subtitleLabel.textColor = UIColor.white.withAlphaComponent(0.92)
    } else if hasError {
      subtitleLabel.text = errorMessage
      subtitleLabel.textColor = UIColor.systemRed
    } else {
      subtitleLabel.text = (mode == "set" && confirming) ? confirmSubtitle : initialSubtitle
      subtitleLabel.textColor = UIColor.white.withAlphaComponent(0.72)
    }

    badgeIconView.isHidden = isBusy
    if isBusy {
      badgeSpinner.startAnimating()
    } else {
      badgeSpinner.stopAnimating()
    }

    let filledColor = hasError
      ? UIColor.systemRed
      : UIColor(red: 0.769, green: 0.710, blue: 0.992, alpha: 1.0)
    let filledBorder = hasError
      ? UIColor.systemRed
      : UIColor(red: 0.655, green: 0.545, blue: 0.980, alpha: 1.0)
    let emptyFill = UIColor.white.withAlphaComponent(0.12)
    let emptyBorder = UIColor.white.withAlphaComponent(0.32)

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
      if animatedDotIndex == idx {
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
    UIView.animate(
      withDuration: 0.18,
      delay: 0,
      options: [.curveEaseIn],
      animations: {
        self.backdropControl.alpha = 0.0
        self.cardShadowView.alpha = 0.0
        self.cardShadowView.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
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

/// Full-height (62pt) native iOS 26 Liquid Glass 4-tab capsule using `UIGlassEffect`
/// directly so it matches the 62pt trailing search circle and Apple's iOS 26
/// floating tab bar proportions (instead of standalone `UITabBar`'s 48pt cap).
private final class MarcoNativeLiquidTabCapsuleView: UIView {
  struct TabSpec {
    let label: String
    let symbol: String
    let selectedSymbol: String
  }

  private final class SlotView: UIView {
    let iconView = UIImageView()
    let titleLabel = UILabel()
    private let stack = UIStackView()

    override init(frame: CGRect) {
      super.init(frame: frame)
      isUserInteractionEnabled = false
      isAccessibilityElement = true
      accessibilityTraits = .button

      iconView.contentMode = .scaleAspectFit
      iconView.tintColor = .white

      titleLabel.font = UIFont.systemFont(ofSize: 10.5, weight: .medium)
      titleLabel.textAlignment = .center
      titleLabel.lineBreakMode = .byTruncatingTail
      titleLabel.textColor = UIColor.white.withAlphaComponent(0.84)

      stack.axis = .vertical
      stack.alignment = .center
      stack.spacing = 3.0
      stack.isUserInteractionEnabled = false
      stack.translatesAutoresizingMaskIntoConstraints = false
      stack.addArrangedSubview(iconView)
      stack.addArrangedSubview(titleLabel)
      addSubview(stack)

      NSLayoutConstraint.activate([
        stack.centerXAnchor.constraint(equalTo: centerXAnchor),
        stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 4.0),
        stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4.0),
      ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }
  }

  private let effectView: UIVisualEffectView
  private let selectionLensView = UIView()
  private let slotsStack = UIStackView()
  private var slotViews: [SlotView] = []
  private var specs: [TabSpec] = []
  private(set) var selectedIndex: Int = 0
  private var highlightedIndex: Int = 0
  private var isScrubbing: Bool = false
  private var scrubContinuousSlot: CGFloat?
  private let selectionFeedback = UISelectionFeedbackGenerator()

  var onSelect: ((Int) -> Void)?

  override init(frame: CGRect) {
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      let glass = UIGlassEffect(style: .regular)
      glass.isInteractive = true
      effectView = UIVisualEffectView(effect: glass)
    } else {
      effectView = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterialDark))
    }
    #else
    effectView = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterialDark))
    #endif
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false
    clipsToBounds = false
    isMultipleTouchEnabled = false
    isExclusiveTouch = true
    overrideUserInterfaceStyle = .dark

    effectView.overrideUserInterfaceStyle = .dark
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
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
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
    }
  }

  private func applySlotAppearances(activeIndex: Int) {
    let normalCfg = UIImage.SymbolConfiguration(pointSize: 20.5, weight: .medium)
    let selectedCfg = UIImage.SymbolConfiguration(pointSize: 20.5, weight: .semibold)
    for (idx, slot) in slotViews.enumerated() where idx < specs.count {
      let spec = specs[idx]
      let isSelected = idx == activeIndex
      let symName = isSelected ? spec.selectedSymbol : spec.symbol
      slot.iconView.image = UIImage(systemName: symName, withConfiguration: isSelected ? selectedCfg : normalCfg)
      slot.iconView.tintColor = isSelected ? .white : UIColor.white.withAlphaComponent(0.84)
      slot.titleLabel.textColor = isSelected ? .white : UIColor.white.withAlphaComponent(0.84)
      slot.titleLabel.font = UIFont.systemFont(ofSize: 10.5, weight: isSelected ? .semibold : .medium)
      slot.accessibilityTraits = isSelected ? [.button, .selected] : [.button]
    }
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
    let apply = {
      self.selectionLensView.bounds = metrics.bounds
      self.selectionLensView.center = metrics.center
      self.selectionLensView.transform = lifted
        ? CGAffineTransform(scaleX: 1.045, y: 1.045)
        : .identity
      self.selectionLensView.backgroundColor = UIColor.white.withAlphaComponent(lifted ? 0.22 : 0.16)
    }
    if animated {
      UIView.animate(
        withDuration: lifted ? 0.14 : 0.34,
        delay: 0,
        usingSpringWithDamping: lifted ? 0.85 : 0.78,
        initialSpringVelocity: 0.6,
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

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
    super.touchesBegan(touches, with: event)
    guard let touch = touches.first, !specs.isEmpty else { return }
    selectionFeedback.prepare()
    let pt = touch.location(in: self)
    let (idx, _) = indexForX(pt.x)
    isScrubbing = true
    highlightedIndex = idx
    scrubContinuousSlot = CGFloat(idx)
    applySlotAppearances(activeIndex: idx)
    positionLens(slotPosition: CGFloat(idx), animated: true, lifted: true)
  }

  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
    super.touchesMoved(touches, with: event)
    guard isScrubbing, let touch = touches.first, !specs.isEmpty else { return }
    let pt = touch.location(in: self)
    let (idx, continuous) = indexForX(pt.x)
    scrubContinuousSlot = continuous
    if idx != highlightedIndex {
      highlightedIndex = idx
      selectionFeedback.selectionChanged()
      applySlotAppearances(activeIndex: idx)
    }
    positionLens(slotPosition: continuous, animated: false, lifted: true)
  }

  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
    super.touchesEnded(touches, with: event)
    guard isScrubbing else { return }
    let target = highlightedIndex
    isScrubbing = false
    scrubContinuousSlot = nil
    let changed = target != selectedIndex
    selectedIndex = target
    applySlotAppearances(activeIndex: target)
    positionLens(slotPosition: CGFloat(target), animated: true, lifted: false)
    if changed {
      UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    onSelect?(target)
  }

  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
    super.touchesCancelled(touches, with: event)
    guard isScrubbing else { return }
    isScrubbing = false
    scrubContinuousSlot = nil
    highlightedIndex = selectedIndex
    applySlotAppearances(activeIndex: selectedIndex)
    positionLens(slotPosition: CGFloat(selectedIndex), animated: true, lifted: false)
  }
}

/// Genuine iOS 26 circular Liquid Glass control (`UIGlassEffect(style: .regular)`
/// with `isInteractive = true` and `cornerConfiguration = .capsule()`) hosting a
/// fixed-size centered `UIImageView` + optional transparent `UIMenu` overlay.
/// Avoids `UIButton.Configuration.glass()`'s iOS 26 frame-resize icon scale bounce
/// inside Flutter `UiKitView`.
private final class MarcoInteractiveCircleGlassControl: UIControl {
  private let effectView: UIVisualEffectView
  private let iconView = UIImageView()
  let menuOverlayButton = UIButton(type: .system)
  private var configuredTintARGB: UInt64?
  private var hasConfiguredEffect = false

  override init(frame: CGRect) {
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      let glass = UIGlassEffect(style: .regular)
      glass.isInteractive = true
      effectView = UIVisualEffectView(effect: glass)
    } else {
      effectView = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterialDark))
    }
    #else
    effectView = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterialDark))
    #endif
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false
    clipsToBounds = false
    overrideUserInterfaceStyle = .dark

    effectView.overrideUserInterfaceStyle = .dark
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

    iconView.contentMode = .scaleAspectFit
    iconView.tintColor = .white
    iconView.isUserInteractionEnabled = false
    iconView.translatesAutoresizingMaskIntoConstraints = false
    effectView.contentView.addSubview(iconView)

    menuOverlayButton.backgroundColor = .clear
    menuOverlayButton.overrideUserInterfaceStyle = .dark
    menuOverlayButton.showsMenuAsPrimaryAction = true
    menuOverlayButton.isHidden = true
    menuOverlayButton.translatesAutoresizingMaskIntoConstraints = false
    addSubview(menuOverlayButton)

    NSLayoutConstraint.activate([
      effectView.topAnchor.constraint(equalTo: topAnchor),
      effectView.bottomAnchor.constraint(equalTo: bottomAnchor),
      effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
      effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
      iconView.centerXAnchor.constraint(equalTo: effectView.contentView.centerXAnchor),
      iconView.centerYAnchor.constraint(equalTo: effectView.contentView.centerYAnchor),
      menuOverlayButton.topAnchor.constraint(equalTo: topAnchor),
      menuOverlayButton.bottomAnchor.constraint(equalTo: bottomAnchor),
      menuOverlayButton.leadingAnchor.constraint(equalTo: leadingAnchor),
      menuOverlayButton.trailingAnchor.constraint(equalTo: trailingAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
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

  override var isHighlighted: Bool {
    didSet {
      UIView.animate(
        withDuration: 0.14,
        delay: 0,
        options: [.allowUserInteraction, .beginFromCurrentState]
      ) {
        self.transform = self.isHighlighted
          ? CGAffineTransform(scaleX: 0.93, y: 0.93)
          : .identity
      }
    }
  }

  func configure(
    image: UIImage?,
    foregroundColor: UIColor,
    tintColor: UIColor?,
    tintARGB: UInt64?,
    menu: UIMenu?
  ) {
    MarcoLiquidGlassSupport.withoutAnimations {
      #if compiler(>=6.2)
      if #available(iOS 26.0, *) {
        if !self.hasConfiguredEffect || self.configuredTintARGB != tintARGB {
          self.hasConfiguredEffect = true
          self.configuredTintARGB = tintARGB
          let glass = UIGlassEffect(style: .regular)
          glass.isInteractive = true
          glass.tintColor = tintColor
          self.effectView.effect = glass
        }
      }
      #endif
      if MarcoLiquidGlassSupport.isNearWhite(foregroundColor) {
        self.iconView.image = image
        self.iconView.tintColor = foregroundColor
      } else {
        self.iconView.image = image?.withTintColor(foregroundColor, renderingMode: .alwaysOriginal)
        self.iconView.tintColor = foregroundColor
      }
      if let menu = menu {
        self.menuOverlayButton.menu = menu
        self.menuOverlayButton.isHidden = false
      } else {
        self.menuOverlayButton.menu = nil
        self.menuOverlayButton.isHidden = true
      }
    }
  }
}

private final class MarcoDockContainerView: UIView {
  let tabCapsule = MarcoNativeLiquidTabCapsuleView(frame: .zero)
  let searchButton = MarcoInteractiveCircleGlassControl(frame: .zero)
  let logoButton = MarcoInteractiveCircleGlassControl(frame: .zero)

  var showSearchButton: Bool = true {
    didSet {
      updateVisibilityState()
      setNeedsLayout()
    }
  }
  private(set) var isCollapsed: Bool = false

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false
    clipsToBounds = false
    insetsLayoutMarginsFromSafeArea = false
    overrideUserInterfaceStyle = .dark

    addSubview(tabCapsule)

    searchButton.accessibilityLabel = "搜索"
    configureSearchButton()
    addSubview(searchButton)

    logoButton.accessibilityLabel = "快捷导航"
    logoButton.menuOverlayButton.accessibilityLabel = "快捷导航"
    logoButton.alpha = 0.0
    logoButton.isUserInteractionEnabled = false
    logoButton.transform = CGAffineTransform(scaleX: 0.55, y: 0.55)
    configureLogoButton()
    addSubview(logoButton)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func configureSearchButton() {
    let symbolConfig = UIImage.SymbolConfiguration(pointSize: 22.0, weight: .medium)
    let icon = UIImage(systemName: "magnifyingglass", withConfiguration: symbolConfig)
    searchButton.configure(
      image: icon,
      foregroundColor: .white,
      tintColor: nil,
      tintARGB: nil,
      menu: nil
    )
  }

  private func configureLogoButton() {
    let logo = MarcoLiquidGlassSupport.brandLogoImage
    logoButton.configure(
      image: logo,
      foregroundColor: .white,
      tintColor: nil,
      tintARGB: nil,
      menu: nil
    )
  }

  private func updateVisibilityState() {
    searchButton.isHidden = !showSearchButton && !isCollapsed
  }

  func setCollapsed(_ collapsed: Bool, animated: Bool) {
    guard collapsed != isCollapsed else { return }
    isCollapsed = collapsed
    let targetCenterX = logoButton.center.x
    let tabShift = targetCenterX - tabCapsule.center.x
    let apply = {
      if collapsed {
        self.tabCapsule.alpha = 0.0
        self.tabCapsule.transform = CGAffineTransform(translationX: tabShift * 0.42, y: 0).scaledBy(x: 0.45, y: 0.45)
        self.searchButton.alpha = 0.0
        self.searchButton.transform = CGAffineTransform(scaleX: 0.45, y: 0.45)
        self.logoButton.alpha = 1.0
        self.logoButton.transform = .identity
      } else {
        self.tabCapsule.alpha = 1.0
        self.tabCapsule.transform = .identity
        self.searchButton.alpha = self.showSearchButton ? 1.0 : 0.0
        self.searchButton.transform = .identity
        self.logoButton.alpha = 0.0
        self.logoButton.transform = CGAffineTransform(scaleX: 0.55, y: 0.55)
      }
    }

    tabCapsule.isUserInteractionEnabled = !collapsed
    searchButton.isUserInteractionEnabled = !collapsed && showSearchButton
    logoButton.isUserInteractionEnabled = collapsed

    if animated {
      UIView.animate(
        withDuration: collapsed ? 0.28 : 0.38,
        delay: 0,
        usingSpringWithDamping: collapsed ? 0.86 : 0.78,
        initialSpringVelocity: 0.6,
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
    let totalW = bounds.width
    let totalH = bounds.height
    guard totalW > 0, totalH > 0 else { return }

    let outerMargin: CGFloat = 16.0
    let gap: CGFloat = 10.0
    // Match V1's full 62pt search button & Apple's iOS 26 floating tab bar height.
    let dockSize: CGFloat = min(62.0, totalH)

    // When collapsed into the narrow right-aligned container, keep logoButton anchored
    // at the trailing edge without disturbing tabCapsule's untransformed geometry.
    if isCollapsed && totalW < 150.0 {
      logoButton.bounds = CGRect(x: 0, y: 0, width: dockSize, height: dockSize)
      logoButton.center = CGPoint(x: totalW - outerMargin - dockSize * 0.5, y: totalH * 0.5)
      bringSubviewToFront(logoButton)
      return
    }

    let maxRowWidth: CGFloat = min(totalW, 440.0)
    let rowX = (totalW - maxRowWidth) * 0.5
    let centerY = totalH * 0.5

    // Use bounds + center (never frame) so active collapsed transforms stay safe.
    let rightCenterX = rowX + maxRowWidth - outerMargin - dockSize * 0.5
    logoButton.bounds = CGRect(x: 0, y: 0, width: dockSize, height: dockSize)
    logoButton.center = CGPoint(x: rightCenterX, y: centerY)

    if showSearchButton {
      searchButton.bounds = CGRect(x: 0, y: 0, width: dockSize, height: dockSize)
      searchButton.center = CGPoint(x: rightCenterX, y: centerY)

      let tabX = rowX + outerMargin
      let tabW = max((rightCenterX - dockSize * 0.5 - gap) - tabX, 180.0)
      tabCapsule.bounds = CGRect(x: 0, y: 0, width: tabW, height: dockSize)
      tabCapsule.center = CGPoint(x: tabX + tabW * 0.5, y: centerY)
    } else {
      let tabX = rowX + outerMargin
      let tabW = max(maxRowWidth - outerMargin * 2.0, 180.0)
      tabCapsule.bounds = CGRect(x: 0, y: 0, width: tabW, height: dockSize)
      tabCapsule.center = CGPoint(x: tabX + tabW * 0.5, y: centerY)
    }

    bringSubviewToFront(searchButton)
    bringSubviewToFront(logoButton)
  }
}

private final class MarcoNativeDockPlatformView: NSObject, FlutterPlatformView {
  private let container: MarcoDockContainerView
  private let channel: FlutterMethodChannel
  private var rawItemDicts: [[String: Any]] = []
  private var currentSelectedIndex: Int = 0

  init(
    frame: CGRect,
    viewId: Int64,
    arguments args: [String: Any]?,
    messenger: FlutterBinaryMessenger
  ) {
    let initialFrame = MarcoLiquidGlassSupport.resolvedInitialFrame(
      frame,
      args: args,
      defaultWidth: UIScreen.main.bounds.width,
      defaultHeight: 72.0
    )
    self.container = MarcoDockContainerView(frame: initialFrame)
    self.channel = FlutterMethodChannel(
      name: "marco_movie/ios26_dock_\(viewId)",
      binaryMessenger: messenger
    )
    super.init()

    container.tabCapsule.onSelect = { [weak self] idx in
      guard let self = self else { return }
      self.currentSelectedIndex = idx
      self.rebuildLogoMenu()
      self.channel.invokeMethod("onSelect", arguments: idx)
    }
    container.searchButton.addTarget(self, action: #selector(searchTapped), for: .touchUpInside)

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
            self.selectTab(index: idx, animated: true)
          }
          result(nil)
        case "setCollapsed":
          if let collapsed = call.arguments as? Bool {
            self.container.setCollapsed(collapsed, animated: true)
          }
          result(nil)
        case "setHidden":
          if let hidden = call.arguments as? Bool {
            UIView.animate(withDuration: 0.18) {
              self.container.alpha = hidden ? 0.0 : 1.0
            }
            self.container.isUserInteractionEnabled = !hidden
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
      container.alpha = hidden ? 0.0 : 1.0
      container.isUserInteractionEnabled = !hidden
    }
    if let rawItems = args["items"] as? [[String: Any]], !rawItems.isEmpty {
      rawItemDicts = rawItems
      let specs = rawItems.map { item -> MarcoNativeLiquidTabCapsuleView.TabSpec in
        let title = (item["label"] as? String) ?? ""
        let symbol = (item["symbol"] as? String) ?? "circle"
        let selectedSymbol = (item["selectedSymbol"] as? String) ?? symbol
        return MarcoNativeLiquidTabCapsuleView.TabSpec(
          label: title,
          symbol: symbol,
          selectedSymbol: selectedSymbol
        )
      }
      container.tabCapsule.setItems(specs)
    }
    if let selectedIndex = args["selectedIndex"] as? Int {
      selectTab(index: selectedIndex, animated: animated)
    } else {
      rebuildLogoMenu()
    }
    if let collapsed = args["collapsed"] as? Bool {
      container.setCollapsed(collapsed, animated: animated)
    }
    container.setNeedsLayout()
  }

  private func selectTab(index: Int, animated: Bool) {
    guard index >= 0, index < rawItemDicts.count else { return }
    currentSelectedIndex = index
    container.tabCapsule.setSelectedIndex(index, animated: animated)
    rebuildLogoMenu()
  }

  private func rebuildLogoMenu() {
    var sections: [UIMenuElement] = []

    if container.showSearchButton {
      let searchAction = UIAction(
        title: "搜索影片",
        image: UIImage(systemName: "magnifyingglass")
      ) { [weak self] _ in
        self?.searchTapped()
      }
      sections.append(UIMenu(title: "", options: .displayInline, children: [searchAction]))
    }

    var navActions: [UIAction] = []
    for (idx, item) in rawItemDicts.enumerated() {
      let title = (item["label"] as? String) ?? ""
      let isSelected = idx == currentSelectedIndex
      let symbol = isSelected
        ? ((item["selectedSymbol"] as? String) ?? (item["symbol"] as? String) ?? "circle")
        : ((item["symbol"] as? String) ?? "circle")
      let action = UIAction(
        title: title,
        image: UIImage(systemName: symbol),
        state: isSelected ? .on : .off
      ) { [weak self] _ in
        guard let self = self else { return }
        self.selectTab(index: idx, animated: true)
        self.channel.invokeMethod("onSelect", arguments: idx)
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
      self?.channel.invokeMethod("onScrollToTop", arguments: nil)
    }
    sections.append(UIMenu(title: "", options: .displayInline, children: [topAction]))

    container.logoButton.menuOverlayButton.menu = UIMenu(title: "", children: sections)
    container.logoButton.menuOverlayButton.isHidden = false
  }

  @objc private func searchTapped() {
    let generator = UIImpactFeedbackGenerator(style: .light)
    generator.impactOccurred()
    channel.invokeMethod("onSearch", arguments: nil)
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

private final class MarcoInteractiveCapsuleGlassControl: UIControl {
  private let effectView: UIVisualEffectView
  private let stack = UIStackView()
  private let leadingIcon = UIImageView()
  private let titleLabel = UILabel()
  private let trailingIcon = UIImageView()
  let menuOverlayButton = UIButton(type: .system)
  private var configuredTintARGB: UInt64?
  private var hasConfiguredEffect = false

  override init(frame: CGRect) {
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      let glass = UIGlassEffect(style: .regular)
      glass.isInteractive = true
      effectView = UIVisualEffectView(effect: glass)
    } else {
      effectView = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterialDark))
    }
    #else
    effectView = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterialDark))
    #endif
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false
    overrideUserInterfaceStyle = .dark

    effectView.overrideUserInterfaceStyle = .dark
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

    stack.axis = .horizontal
    stack.alignment = .center
    stack.spacing = 5.0
    stack.isUserInteractionEnabled = false
    stack.translatesAutoresizingMaskIntoConstraints = false
    effectView.contentView.addSubview(stack)

    leadingIcon.contentMode = .scaleAspectFit
    leadingIcon.tintColor = .white
    leadingIcon.setContentHuggingPriority(.required, for: .horizontal)
    leadingIcon.setContentCompressionResistancePriority(.required, for: .horizontal)

    titleLabel.font = UIFont.systemFont(ofSize: 13.0, weight: .semibold)
    titleLabel.textColor = .white
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.numberOfLines = 1
    titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    trailingIcon.contentMode = .scaleAspectFit
    trailingIcon.tintColor = UIColor.white.withAlphaComponent(0.82)
    trailingIcon.setContentHuggingPriority(.required, for: .horizontal)
    trailingIcon.setContentCompressionResistancePriority(.required, for: .horizontal)

    stack.addArrangedSubview(leadingIcon)
    stack.addArrangedSubview(titleLabel)
    stack.addArrangedSubview(trailingIcon)

    menuOverlayButton.backgroundColor = .clear
    menuOverlayButton.overrideUserInterfaceStyle = .dark
    menuOverlayButton.showsMenuAsPrimaryAction = true
    menuOverlayButton.isHidden = true
    menuOverlayButton.translatesAutoresizingMaskIntoConstraints = false
    addSubview(menuOverlayButton)

    NSLayoutConstraint.activate([
      effectView.topAnchor.constraint(equalTo: topAnchor),
      effectView.bottomAnchor.constraint(equalTo: bottomAnchor),
      effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
      effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.leadingAnchor.constraint(equalTo: effectView.contentView.leadingAnchor, constant: 12.0),
      stack.trailingAnchor.constraint(equalTo: effectView.contentView.trailingAnchor, constant: -11.0),
      stack.centerYAnchor.constraint(equalTo: effectView.contentView.centerYAnchor),
      menuOverlayButton.topAnchor.constraint(equalTo: topAnchor),
      menuOverlayButton.bottomAnchor.constraint(equalTo: bottomAnchor),
      menuOverlayButton.leadingAnchor.constraint(equalTo: leadingAnchor),
      menuOverlayButton.trailingAnchor.constraint(equalTo: trailingAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
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

  override var isHighlighted: Bool {
    didSet {
      UIView.animate(
        withDuration: 0.16,
        delay: 0,
        options: [.allowUserInteraction, .beginFromCurrentState]
      ) {
        self.transform = self.isHighlighted
          ? CGAffineTransform(scaleX: 0.95, y: 0.95)
          : .identity
      }
    }
  }

  func configure(
    label: String,
    symbol: String?,
    trailingSymbol: String?,
    foregroundColor: UIColor,
    tintColor: UIColor?,
    tintARGB: UInt64?,
    symbolSize: CGFloat,
    menu: UIMenu?
  ) {
    MarcoLiquidGlassSupport.withoutAnimations {
      #if compiler(>=6.2)
      if #available(iOS 26.0, *) {
        if !self.hasConfiguredEffect || self.configuredTintARGB != tintARGB {
          self.hasConfiguredEffect = true
          self.configuredTintARGB = tintARGB
          let glass = UIGlassEffect(style: .regular)
          glass.isInteractive = true
          glass.tintColor = tintColor
          self.effectView.effect = glass
        }
      }
      #endif

      self.titleLabel.text = label
      self.titleLabel.textColor = foregroundColor
      self.titleLabel.isHidden = label.isEmpty

      if let symbol = symbol, !symbol.isEmpty {
        let cfg = UIImage.SymbolConfiguration(pointSize: symbolSize, weight: .semibold)
        let raw = UIImage(systemName: symbol, withConfiguration: cfg)
        if MarcoLiquidGlassSupport.isNearWhite(foregroundColor) {
          self.leadingIcon.image = raw
        } else {
          self.leadingIcon.image = raw?.withTintColor(foregroundColor, renderingMode: .alwaysOriginal)
        }
        self.leadingIcon.tintColor = foregroundColor
        self.leadingIcon.isHidden = false
      } else {
        self.leadingIcon.isHidden = true
      }

      if let trailing = trailingSymbol, !trailing.isEmpty {
        let cfg = UIImage.SymbolConfiguration(pointSize: max(symbolSize - 3.0, 11.0), weight: .semibold)
        self.trailingIcon.image = UIImage(systemName: trailing, withConfiguration: cfg)
        self.trailingIcon.tintColor = foregroundColor.withAlphaComponent(0.82)
        self.trailingIcon.isHidden = false
      } else {
        self.trailingIcon.isHidden = true
      }

      if let menu = menu {
        self.menuOverlayButton.menu = menu
        self.menuOverlayButton.isHidden = false
      } else {
        self.menuOverlayButton.menu = nil
        self.menuOverlayButton.isHidden = true
      }
    }
  }
}

private final class MarcoNativeGlassButtonPlatformView: NSObject, FlutterPlatformView {
  private let hostView = UIView(frame: .zero)
  private let circleControl = MarcoInteractiveCircleGlassControl(frame: .zero)
  private let capsuleControl = MarcoInteractiveCapsuleGlassControl(frame: .zero)
  private let channel: FlutterMethodChannel
  private var isCapsuleMode = false

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
      self.hostView.overrideUserInterfaceStyle = .dark

      self.circleControl.translatesAutoresizingMaskIntoConstraints = false
      self.circleControl.addTarget(self, action: #selector(self.handleTap), for: .touchUpInside)
      self.hostView.addSubview(self.circleControl)

      self.capsuleControl.translatesAutoresizingMaskIntoConstraints = false
      self.capsuleControl.addTarget(self, action: #selector(self.handleTap), for: .touchUpInside)
      self.hostView.addSubview(self.capsuleControl)

      NSLayoutConstraint.activate([
        self.circleControl.topAnchor.constraint(equalTo: self.hostView.topAnchor),
        self.circleControl.bottomAnchor.constraint(equalTo: self.hostView.bottomAnchor),
        self.circleControl.leadingAnchor.constraint(equalTo: self.hostView.leadingAnchor),
        self.circleControl.trailingAnchor.constraint(equalTo: self.hostView.trailingAnchor),
        self.capsuleControl.topAnchor.constraint(equalTo: self.hostView.topAnchor),
        self.capsuleControl.bottomAnchor.constraint(equalTo: self.hostView.bottomAnchor),
        self.capsuleControl.leadingAnchor.constraint(equalTo: self.hostView.leadingAnchor),
        self.capsuleControl.trailingAnchor.constraint(equalTo: self.hostView.trailingAnchor),
      ])

      if let args = args {
        self.apply(args)
      }
      self.hostView.layoutIfNeeded()
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
    channel.setMethodCallHandler(nil)
  }

  func view() -> UIView {
    return hostView
  }

  private func apply(_ args: [String: Any]) {
    let style = (args["style"] as? String) ?? "circle"
    let symbol = args["symbol"] as? String
    let trailingSymbol = args["trailingSymbol"] as? String
    let label = (args["label"] as? String) ?? ""
    let symbolSize = CGFloat((args["symbolSize"] as? NSNumber)?.doubleValue ?? 17.0)
    let fgColor = MarcoLiquidGlassSupport.colorFromARGB(args["foregroundColor"]) ?? .white
    let tintARGB = (args["tintColor"] as? NSNumber)?.uint64Value
    let tintColor = MarcoLiquidGlassSupport.colorFromARGB(args["tintColor"])
    let a11yLabel = (args["accessibilityLabel"] as? String) ?? label
    let menuTitle = (args["menuTitle"] as? String) ?? ""
    let rawMenuItems = (args["menuItems"] as? [[String: Any]]) ?? []
    let menu = MarcoLiquidGlassSupport.buildMenu(title: menuTitle, rawItems: rawMenuItems) { [weak self] selectedId in
      self?.channel.invokeMethod("onMenuSelected", arguments: selectedId)
    }

    isCapsuleMode = (style == "capsule" && (!label.isEmpty || (trailingSymbol != nil && !trailingSymbol!.isEmpty)))
    circleControl.isHidden = isCapsuleMode
    capsuleControl.isHidden = !isCapsuleMode

    if isCapsuleMode {
      capsuleControl.accessibilityLabel = a11yLabel
      capsuleControl.menuOverlayButton.accessibilityLabel = a11yLabel
      capsuleControl.configure(
        label: label,
        symbol: symbol,
        trailingSymbol: trailingSymbol,
        foregroundColor: fgColor,
        tintColor: tintColor,
        tintARGB: tintARGB,
        symbolSize: symbolSize,
        menu: menu
      )
    } else {
      circleControl.accessibilityLabel = a11yLabel
      circleControl.menuOverlayButton.accessibilityLabel = a11yLabel
      let symCfg = UIImage.SymbolConfiguration(pointSize: symbolSize, weight: .semibold)
      let rawImage = symbol.flatMap { UIImage(systemName: $0, withConfiguration: symCfg) }
      circleControl.configure(
        image: rawImage,
        foregroundColor: fgColor,
        tintColor: tintColor,
        tintARGB: tintARGB,
        menu: menu
      )
    }
  }

  @objc private func handleTap() {
    let generator = UIImpactFeedbackGenerator(style: .light)
    generator.impactOccurred()
    channel.invokeMethod("onTap", arguments: nil)
  }
}

// MARK: - 3. Native iOS 26 Multi-Action Liquid Glass Pill (e.g. Detail Top-Right 3 Actions)

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

  override init(frame: CGRect) {
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      let glass = UIGlassEffect(style: .regular)
      glass.isInteractive = true
      effectView = UIVisualEffectView(effect: glass)
    } else {
      effectView = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterialDark))
    }
    #else
    effectView = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterialDark))
    #endif
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false
    clipsToBounds = false
    overrideUserInterfaceStyle = .dark

    effectView.overrideUserInterfaceStyle = .dark
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
    stack.spacing = 0
    stack.translatesAutoresizingMaskIntoConstraints = false
    effectView.contentView.addSubview(stack)

    NSLayoutConstraint.activate([
      effectView.topAnchor.constraint(equalTo: topAnchor),
      effectView.bottomAnchor.constraint(equalTo: bottomAnchor),
      effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
      effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.topAnchor.constraint(equalTo: effectView.contentView.topAnchor),
      stack.bottomAnchor.constraint(equalTo: effectView.contentView.bottomAnchor),
      stack.leadingAnchor.constraint(equalTo: effectView.contentView.leadingAnchor, constant: 6.0),
      stack.trailingAnchor.constraint(equalTo: effectView.contentView.trailingAnchor, constant: -6.0),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
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
    channel.setMethodCallHandler(nil)
  }

  func view() -> UIView {
    return hostView
  }

  private func apply(_ args: [String: Any]) {
    guard let items = args["items"] as? [[String: Any]] else { return }
    if buttons.count != items.count {
      for sub in hostView.stack.arrangedSubviews {
        hostView.stack.removeArrangedSubview(sub)
        sub.removeFromSuperview()
      }
      buttons.removeAll()
      for idx in 0..<items.count {
        if idx > 0 {
          let sep = UIView()
          sep.backgroundColor = UIColor.white.withAlphaComponent(0.24)
          sep.translatesAutoresizingMaskIntoConstraints = false
          NSLayoutConstraint.activate([
            sep.widthAnchor.constraint(equalToConstant: 0.6),
            sep.heightAnchor.constraint(equalToConstant: 18.0),
          ])
          hostView.stack.addArrangedSubview(sep)
        }
        let btn = UIButton(type: .system)
        btn.tag = idx
        btn.overrideUserInterfaceStyle = .dark
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.addTarget(self, action: #selector(itemTapped(_:)), for: .touchUpInside)
        NSLayoutConstraint.activate([
          btn.widthAnchor.constraint(equalToConstant: 38.0),
          btn.heightAnchor.constraint(equalToConstant: 38.0),
        ])
        hostView.stack.addArrangedSubview(btn)
        buttons.append(btn)
      }
    }

    let symCfg = UIImage.SymbolConfiguration(pointSize: 17.5, weight: .medium)
    for (idx, item) in items.enumerated() where idx < buttons.count {
      let btn = buttons[idx]
      let symbol = (item["symbol"] as? String) ?? "circle"
      let tint = MarcoLiquidGlassSupport.colorFromARGB(item["color"]) ?? .white
      let label = (item["accessibilityLabel"] as? String) ?? symbol
      btn.setImage(UIImage(systemName: symbol, withConfiguration: symCfg), for: .normal)
      btn.tintColor = tint
      btn.accessibilityLabel = label
    }
  }

  @objc private func itemTapped(_ sender: UIButton) {
    let generator = UIImpactFeedbackGenerator(style: .light)
    generator.impactOccurred()
    UIView.animate(withDuration: 0.10, animations: {
      sender.transform = CGAffineTransform(scaleX: 0.84, y: 0.84)
    }) { _ in
      UIView.animate(
        withDuration: 0.24,
        delay: 0,
        usingSpringWithDamping: 0.55,
        initialSpringVelocity: 0.8
      ) {
        sender.transform = .identity
      }
    }
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
  private let hostView = UIView(frame: .zero)
  private let control = UISegmentedControl(items: [])
  private let channel: FlutterMethodChannel
  private var currentSegments: [String] = []

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
      self.hostView.overrideUserInterfaceStyle = .dark

      self.control.overrideUserInterfaceStyle = .dark
      self.control.apportionsSegmentWidthsByContent = false
      self.control.translatesAutoresizingMaskIntoConstraints = false
      self.control.setTitleTextAttributes(
        [
          .foregroundColor: UIColor.white.withAlphaComponent(0.76),
          .font: UIFont.systemFont(ofSize: 13.0, weight: .semibold),
        ],
        for: .normal
      )
      self.control.setTitleTextAttributes(
        [
          .foregroundColor: UIColor.white,
          .font: UIFont.systemFont(ofSize: 13.0, weight: .semibold),
        ],
        for: .selected
      )
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
    channel.setMethodCallHandler(nil)
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
  private let hostView = UIView(frame: .zero)
  private let toggle = UISwitch(frame: .zero)
  private let channel: FlutterMethodChannel

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
      self.hostView.overrideUserInterfaceStyle = .dark

      self.toggle.overrideUserInterfaceStyle = .dark
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

private final class MarcoNativeSliderPlatformView: NSObject, FlutterPlatformView {
  private let hostView = UIView(frame: .zero)
  private let slider = UISlider(frame: .zero)
  private let channel: FlutterMethodChannel

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
      defaultHeight: 36.0
    )
    MarcoLiquidGlassSupport.withoutAnimations {
      self.hostView.frame = initialFrame
      self.hostView.backgroundColor = .clear
      self.hostView.isOpaque = false
      self.hostView.clipsToBounds = false
      self.hostView.overrideUserInterfaceStyle = .dark

      self.slider.overrideUserInterfaceStyle = .dark
      self.slider.minimumTrackTintColor = UIColor.systemBlue
      self.slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.22)
      self.slider.isContinuous = true
      self.slider.translatesAutoresizingMaskIntoConstraints = false
      self.slider.addTarget(self, action: #selector(self.valueChanged), for: .valueChanged)
      self.slider.addTarget(self, action: #selector(self.touchEnded), for: [.touchUpInside, .touchUpOutside, .touchCancel])
      self.hostView.addSubview(self.slider)

      NSLayoutConstraint.activate([
        self.slider.leadingAnchor.constraint(equalTo: self.hostView.leadingAnchor),
        self.slider.trailingAnchor.constraint(equalTo: self.hostView.trailingAnchor),
        self.slider.centerYAnchor.constraint(equalTo: self.hostView.centerYAnchor),
      ])

      if let args = args {
        self.apply(args)
      }
      self.hostView.layoutIfNeeded()
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

  @objc private func valueChanged() {
    channel.invokeMethod("onChanged", arguments: Double(slider.value))
  }

  @objc private func touchEnded() {
    channel.invokeMethod("onChangeEnd", arguments: Double(slider.value))
  }
}
