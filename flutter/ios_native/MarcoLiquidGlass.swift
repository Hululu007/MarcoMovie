// MARK: - iOS 26 Native Liquid Glass Bridge (injected into AppDelegate.swift by prepare_platform.py)

private enum MarcoLiquidGlassSupport {
  private static var bridgeChannel: FlutterMethodChannel?

  static var isAvailable: Bool {
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      return true
    }
    #endif
    return false
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

  static func register(with registrar: FlutterPluginRegistrar, messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "marco_movie/ios_liquid_glass",
      binaryMessenger: messenger
    )
    bridgeChannel = channel
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "capabilities":
        result([
          "available": isAvailable,
          "majorVersion": majorOSVersion,
          "sdk26": builtWithSDK26,
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

    var resolved = false
    func finish(_ value: Any?) {
      guard !resolved else { return }
      resolved = true
      completion(value)
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

    host.present(alert, animated: true, completion: nil)
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
    func finish(_ value: Any?) {
      guard !resolved else { return }
      resolved = true
      if let box = activePopoverBoxes.removeValue(forKey: sheetKey) {
        box.invalidate()
      }
      completion(value)
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

    host.present(sheet, animated: true, completion: nil)
  }
}

// MARK: - 1. Native iOS 26 Floating Liquid Glass Dock (UITabBar + Detached Search Circle)

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

private final class MarcoDockContainerView: UIView {
  let tabBar = UITabBar(frame: .zero)
  let searchButton = UIButton(type: .system)
  var showSearchButton: Bool = true {
    didSet {
      searchButton.isHidden = !showSearchButton
      setNeedsLayout()
    }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false
    clipsToBounds = false
    insetsLayoutMarginsFromSafeArea = false
    overrideUserInterfaceStyle = .dark

    tabBar.overrideUserInterfaceStyle = .dark
    tabBar.isTranslucent = true
    tabBar.insetsLayoutMarginsFromSafeArea = false
    tabBar.preservesSuperviewLayoutMargins = false
    tabBar.tintColor = .white
    tabBar.unselectedItemTintColor = UIColor.white.withAlphaComponent(0.78)
    addSubview(tabBar)

    searchButton.overrideUserInterfaceStyle = .dark
    searchButton.accessibilityLabel = "搜索"
    configureSearchButton()
    addSubview(searchButton)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func configureSearchButton() {
    let symbolConfig = UIImage.SymbolConfiguration(pointSize: 21, weight: .medium)
    let icon = UIImage(systemName: "magnifyingglass", withConfiguration: symbolConfig)
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      var config = UIButton.Configuration.glass()
      config.image = icon
      config.baseForegroundColor = .white
      config.cornerStyle = .capsule
      config.contentInsets = .zero
      searchButton.configuration = config
      return
    }
    #endif
    var config = UIButton.Configuration.filled()
    config.image = icon
    config.baseForegroundColor = .white
    config.baseBackgroundColor = UIColor(white: 0.16, alpha: 0.85)
    config.cornerStyle = .capsule
    config.contentInsets = .zero
    searchButton.configuration = config
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let totalW = bounds.width
    let totalH = bounds.height
    guard totalW > 0, totalH > 0 else { return }

    let outerMargin: CGFloat = 14.0
    let maxRowWidth: CGFloat = min(totalW, 440.0)
    let rowX = (totalW - maxRowWidth) * 0.5
    let fittedTab = tabBar.sizeThatFits(CGSize(width: maxRowWidth, height: totalH))
    let barH = min(max(fittedTab.height, 60.0), totalH)
    let barY = (totalH - barH) * 0.5

    if showSearchButton {
      let circleSize = min(max(barH - 2.0, 56.0), 62.0)
      let circleX = rowX + maxRowWidth - outerMargin - circleSize
      let circleY = (totalH - circleSize) * 0.5
      searchButton.frame = CGRect(x: circleX, y: circleY, width: circleSize, height: circleSize)

      // Standalone iOS 26 UITabBar keeps an ~8-12pt internal inset around its
      // floating capsule, so giving it a small 4pt lead & 4pt trail aligns its
      // visible capsule flush with the 14pt screen margin and ~10pt gap to search.
      let tabX = rowX + 4.0
      let tabW = max(circleX - tabX - 2.0, 180.0)
      tabBar.frame = CGRect(x: tabX, y: barY, width: tabW, height: barH)
    } else {
      let tabX = rowX + 4.0
      let tabW = max(maxRowWidth - 8.0, 180.0)
      tabBar.frame = CGRect(x: tabX, y: barY, width: tabW, height: barH)
    }
  }
}

private final class MarcoNativeDockPlatformView: NSObject, FlutterPlatformView, UITabBarDelegate {
  private let container: MarcoDockContainerView
  private let channel: FlutterMethodChannel
  private var tabItems: [UITabBarItem] = []

  init(
    frame: CGRect,
    viewId: Int64,
    arguments args: [String: Any]?,
    messenger: FlutterBinaryMessenger
  ) {
    self.container = MarcoDockContainerView(frame: frame)
    self.channel = FlutterMethodChannel(
      name: "marco_movie/ios26_dock_\(viewId)",
      binaryMessenger: messenger
    )
    super.init()

    container.tabBar.delegate = self
    container.searchButton.addTarget(self, action: #selector(searchTapped), for: .touchUpInside)

    if let args = args {
      applyState(args)
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
            self.applyState(args)
          }
          result(nil)
        case "setSelectedIndex":
          if let idx = call.arguments as? Int {
            self.selectTab(index: idx)
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

  private func applyState(_ args: [String: Any]) {
    if let showSearch = args["showSearch"] as? Bool {
      container.showSearchButton = showSearch
    }
    if let hidden = args["hidden"] as? Bool {
      container.alpha = hidden ? 0.0 : 1.0
      container.isUserInteractionEnabled = !hidden
    }
    if let rawItems = args["items"] as? [[String: Any]], !rawItems.isEmpty {
      let symbolConfig = UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)
      var built: [UITabBarItem] = []
      for (idx, item) in rawItems.enumerated() {
        let title = (item["label"] as? String) ?? ""
        let symbol = (item["symbol"] as? String) ?? "circle"
        let selectedSymbol = (item["selectedSymbol"] as? String) ?? symbol
        let image = UIImage(systemName: symbol, withConfiguration: symbolConfig)
        let selectedImage = UIImage(systemName: selectedSymbol, withConfiguration: symbolConfig)
        let tabItem = UITabBarItem(title: title, image: image, selectedImage: selectedImage)
        tabItem.tag = idx
        built.append(tabItem)
      }
      tabItems = built
      container.tabBar.items = built
    }
    if let selectedIndex = args["selectedIndex"] as? Int {
      selectTab(index: selectedIndex)
    }
    container.setNeedsLayout()
  }

  private func selectTab(index: Int) {
    guard index >= 0, index < tabItems.count else { return }
    if container.tabBar.selectedItem !== tabItems[index] {
      container.tabBar.selectedItem = tabItems[index]
    }
  }

  func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
    channel.invokeMethod("onSelect", arguments: item.tag)
  }

  @objc private func searchTapped() {
    let generator = UIImpactFeedbackGenerator(style: .light)
    generator.impactOccurred()
    channel.invokeMethod("onSearch", arguments: nil)
  }
}

// MARK: - 2. Native iOS 26 Liquid Glass Button (Circle Icon or Capsule with Icon + Label + Chevron)

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

    NSLayoutConstraint.activate([
      effectView.topAnchor.constraint(equalTo: topAnchor),
      effectView.bottomAnchor.constraint(equalTo: bottomAnchor),
      effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
      effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.leadingAnchor.constraint(equalTo: effectView.contentView.leadingAnchor, constant: 12.0),
      stack.trailingAnchor.constraint(equalTo: effectView.contentView.trailingAnchor, constant: -11.0),
      stack.centerYAnchor.constraint(equalTo: effectView.contentView.centerYAnchor),
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
    symbolSize: CGFloat
  ) {
    titleLabel.text = label
    titleLabel.textColor = foregroundColor
    titleLabel.isHidden = label.isEmpty

    if let symbol = symbol, !symbol.isEmpty {
      let cfg = UIImage.SymbolConfiguration(pointSize: symbolSize, weight: .semibold)
      leadingIcon.image = UIImage(systemName: symbol, withConfiguration: cfg)
      leadingIcon.tintColor = foregroundColor
      leadingIcon.isHidden = false
    } else {
      leadingIcon.isHidden = true
    }

    if let trailing = trailingSymbol, !trailing.isEmpty {
      let cfg = UIImage.SymbolConfiguration(pointSize: max(symbolSize - 3.0, 11.0), weight: .semibold)
      trailingIcon.image = UIImage(systemName: trailing, withConfiguration: cfg)
      trailingIcon.tintColor = foregroundColor.withAlphaComponent(0.82)
      trailingIcon.isHidden = false
    } else {
      trailingIcon.isHidden = true
    }
  }
}

private final class MarcoNativeGlassButtonPlatformView: NSObject, FlutterPlatformView {
  private let hostView = UIView(frame: .zero)
  private let circleButton = UIButton(type: .system)
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

    hostView.frame = frame
    hostView.backgroundColor = .clear
    hostView.isOpaque = false
    hostView.clipsToBounds = false
    hostView.overrideUserInterfaceStyle = .dark

    circleButton.overrideUserInterfaceStyle = .dark
    circleButton.translatesAutoresizingMaskIntoConstraints = false
    circleButton.addTarget(self, action: #selector(handleTap), for: .touchUpInside)
    hostView.addSubview(circleButton)

    capsuleControl.translatesAutoresizingMaskIntoConstraints = false
    capsuleControl.addTarget(self, action: #selector(handleTap), for: .touchUpInside)
    hostView.addSubview(capsuleControl)

    NSLayoutConstraint.activate([
      circleButton.topAnchor.constraint(equalTo: hostView.topAnchor),
      circleButton.bottomAnchor.constraint(equalTo: hostView.bottomAnchor),
      circleButton.leadingAnchor.constraint(equalTo: hostView.leadingAnchor),
      circleButton.trailingAnchor.constraint(equalTo: hostView.trailingAnchor),
      capsuleControl.topAnchor.constraint(equalTo: hostView.topAnchor),
      capsuleControl.bottomAnchor.constraint(equalTo: hostView.bottomAnchor),
      capsuleControl.leadingAnchor.constraint(equalTo: hostView.leadingAnchor),
      capsuleControl.trailingAnchor.constraint(equalTo: hostView.trailingAnchor),
    ])

    if let args = args {
      apply(args)
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
    let a11yLabel = (args["accessibilityLabel"] as? String) ?? label

    isCapsuleMode = (style == "capsule" && (!label.isEmpty || (trailingSymbol != nil && !trailingSymbol!.isEmpty)))
    circleButton.isHidden = isCapsuleMode
    capsuleControl.isHidden = !isCapsuleMode

    if isCapsuleMode {
      capsuleControl.accessibilityLabel = a11yLabel
      capsuleControl.configure(
        label: label,
        symbol: symbol,
        trailingSymbol: trailingSymbol,
        foregroundColor: fgColor,
        symbolSize: symbolSize
      )
    } else {
      circleButton.accessibilityLabel = a11yLabel
      let symCfg = UIImage.SymbolConfiguration(pointSize: symbolSize, weight: .semibold)
      let image = symbol.flatMap { UIImage(systemName: $0, withConfiguration: symCfg) }
      #if compiler(>=6.2)
      if #available(iOS 26.0, *) {
        var config = UIButton.Configuration.glass()
        config.image = image
        config.baseForegroundColor = fgColor
        config.cornerStyle = .capsule
        config.contentInsets = .zero
        circleButton.configuration = config
        return
      }
      #endif
      var config = UIButton.Configuration.filled()
      config.image = image
      config.baseForegroundColor = fgColor
      config.baseBackgroundColor = UIColor(white: 0.16, alpha: 0.85)
      config.cornerStyle = .capsule
      config.contentInsets = .zero
      circleButton.configuration = config
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
    self.hostView = MarcoGlassPillHostView(frame: frame)
    self.channel = FlutterMethodChannel(
      name: "marco_movie/ios26_glass_pill_\(viewId)",
      binaryMessenger: messenger
    )
    super.init()

    if let args = args {
      apply(args)
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

// MARK: - 4. Native iOS 26 UISegmentedControl (Library Tabs with Liquid Glass Thumb)

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

    hostView.frame = frame
    hostView.backgroundColor = .clear
    hostView.isOpaque = false
    hostView.clipsToBounds = false
    hostView.overrideUserInterfaceStyle = .dark

    control.overrideUserInterfaceStyle = .dark
    control.translatesAutoresizingMaskIntoConstraints = false
    control.setTitleTextAttributes(
      [
        .foregroundColor: UIColor.white.withAlphaComponent(0.76),
        .font: UIFont.systemFont(ofSize: 13.0, weight: .semibold),
      ],
      for: .normal
    )
    control.setTitleTextAttributes(
      [
        .foregroundColor: UIColor.white,
        .font: UIFont.systemFont(ofSize: 13.0, weight: .semibold),
      ],
      for: .selected
    )
    control.addTarget(self, action: #selector(valueChanged), for: .valueChanged)
    hostView.addSubview(control)

    NSLayoutConstraint.activate([
      control.topAnchor.constraint(equalTo: hostView.topAnchor),
      control.bottomAnchor.constraint(equalTo: hostView.bottomAnchor),
      control.leadingAnchor.constraint(equalTo: hostView.leadingAnchor),
      control.trailingAnchor.constraint(equalTo: hostView.trailingAnchor),
    ])

    if let args = args {
      apply(args)
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
