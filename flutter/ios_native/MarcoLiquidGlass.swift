// MARK: - iOS 26 Native Liquid Glass Bridge (injected into AppDelegate.swift by prepare_platform.py)

private enum MarcoLiquidGlassSupport {
  private static var bridgeChannel: FlutterMethodChannel?
  static var brandLogoImage: UIImage?

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
    brandLogoImage = loadBrandLogoImage(registrar: registrar)

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
      case "showFilterSheet":
        guard let args = call.arguments as? [String: Any] else {
          result(nil)
          return
        }
        DispatchQueue.main.async {
          MarcoNativeFilterSheetController.present(args: args, completion: result)
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

  private static func loadBrandLogoImage(registrar: FlutterPluginRegistrar) -> UIImage? {
    let key = registrar.lookupKey(forAsset: "assets/logo_mark.png")
    let path = Bundle.main.path(forResource: key, ofType: nil)
      ?? Bundle.main.path(forResource: FlutterDartProject.lookupKey(forAsset: "assets/logo_mark.png"), ofType: nil)
    if let filePath = path, let raw = UIImage(contentsOfFile: filePath) {
      let target = CGSize(width: 28.0, height: 28.0)
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
    let symCfg = UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
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

  static func buildMenu(
    title: String = "",
    rawItems: [[String: Any]],
    onSelect: @escaping (String) -> Void
  ) -> UIMenu? {
    guard !rawItems.isEmpty else { return nil }
    var sections: [[UIMenuElement]] = []
    var currentSectionKey: Int?
    var currentBucket: [UIMenuElement] = []

    for item in rawItems {
      let id = (item["id"] as? String) ?? ""
      let label = (item["title"] as? String) ?? ""
      let subtitle = item["subtitle"] as? String
      let symbol = item["symbol"] as? String
      let checked = (item["checked"] as? Bool) ?? false
      let destructive = (item["destructive"] as? Bool) ?? false
      let sectionKey = (item["section"] as? NSNumber)?.intValue ?? 0

      if let prev = currentSectionKey, prev != sectionKey, !currentBucket.isEmpty {
        sections.append(currentBucket)
        currentBucket = []
      }
      currentSectionKey = sectionKey

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
      sections.append(currentBucket)
    }
    if sections.count <= 1 {
      return UIMenu(title: title, children: sections.first ?? [])
    }
    let inlineMenus = sections.map { UIMenu(title: "", options: .displayInline, children: $0) }
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

  static func present(args: [String: Any], completion: @escaping FlutterResult) {
    guard let host = MarcoLiquidGlassSupport.topPresenter() else {
      completion(nil)
      return
    }
    let vc = MarcoNativeFilterSheetController(args: args, completion: completion)
    let nav = UINavigationController(rootViewController: vc)
    nav.modalPresentationStyle = .pageSheet
    nav.overrideUserInterfaceStyle = .dark
    nav.presentationController?.delegate = vc
    if let sheet = nav.sheetPresentationController {
      sheet.detents = [.medium(), .large()]
      sheet.prefersGrabberVisible = true
      sheet.preferredCornerRadius = 28.0
      sheet.prefersScrollingExpandsWhenScrolledToEdge = true
    }
    host.present(nav, animated: true, completion: nil)
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
    finish(applied: false)
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

// MARK: - 1. Native iOS 26 Floating Liquid Glass Dock (Height-Aligned 4+1 & Scroll-Collapsed Logo Menu)

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
  let logoButton = UIButton(type: .system)

  var showSearchButton: Bool = true {
    didSet {
      updateVisibilityState()
      setNeedsLayout()
    }
  }
  private(set) var isCollapsed: Bool = false
  private var lastSearchIconHeight: CGFloat = 0.0

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
    configureSearchButton(diameter: 50.0)
    addSubview(searchButton)

    logoButton.overrideUserInterfaceStyle = .dark
    logoButton.accessibilityLabel = "快捷导航"
    logoButton.showsMenuAsPrimaryAction = true
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

  private func configureSearchButton(diameter: CGFloat) {
    let clamped = min(max(diameter, 44.0), 64.0)
    if abs(clamped - lastSearchIconHeight) < 0.8 && searchButton.configuration != nil {
      return
    }
    lastSearchIconHeight = clamped
    let symSize = max(16.0, min(21.0, clamped * 0.38))
    let symbolConfig = UIImage.SymbolConfiguration(pointSize: symSize, weight: .medium)
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

  private func configureLogoButton() {
    let logo = MarcoLiquidGlassSupport.brandLogoImage
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      var config = UIButton.Configuration.glass()
      config.image = logo
      config.baseForegroundColor = .white
      config.cornerStyle = .capsule
      config.contentInsets = .zero
      logoButton.configuration = config
      return
    }
    #endif
    var config = UIButton.Configuration.filled()
    config.image = logo
    config.baseForegroundColor = .white
    config.baseBackgroundColor = UIColor(white: 0.16, alpha: 0.85)
    config.cornerStyle = .capsule
    config.contentInsets = .zero
    logoButton.configuration = config
  }

  private func updateVisibilityState() {
    searchButton.isHidden = !showSearchButton && !isCollapsed
  }

  /// Measures the real visible Liquid Glass capsule platter inside `UITabBar`
  /// (in `tabBar`'s untransformed coordinate space) so the trailing circular
  /// search button matches its top, bottom, and height with 0.0pt error even
  /// during spring animations.
  private func measureTabBarLocalPlatterRect(expectedWidth: CGFloat, fallbackHeight: CGFloat) -> CGRect {
    var best: CGRect?
    func inspect(_ view: UIView, depth: Int) {
      guard depth <= 3 else { return }
      for sub in view.subviews {
        if sub.isHidden || sub.alpha < 0.01 { continue }
        let local = sub.convert(sub.bounds, to: tabBar)
        if local.width >= expectedWidth * 0.62 &&
           local.height >= 36.0 &&
           local.height <= bounds.height + 6.0 {
          if let existing = best {
            if local.height < existing.height && local.height >= 42.0 {
              best = local
            }
          } else {
            best = local
          }
        }
        inspect(sub, depth: depth + 1)
      }
    }
    inspect(tabBar, depth: 0)
    if let rect = best {
      return rect
    }
    return CGRect(x: 0, y: 0, width: expectedWidth, height: fallbackHeight)
  }

  func setCollapsed(_ collapsed: Bool, animated: Bool) {
    guard collapsed != isCollapsed else { return }
    isCollapsed = collapsed
    let targetCenterX = logoButton.center.x
    let tabShift = targetCenterX - tabBar.center.x
    let apply = {
      if collapsed {
        self.tabBar.alpha = 0.0
        self.tabBar.transform = CGAffineTransform(translationX: tabShift * 0.42, y: 0).scaledBy(x: 0.45, y: 0.45)
        self.searchButton.alpha = 0.0
        self.searchButton.transform = CGAffineTransform(scaleX: 0.45, y: 0.45)
        self.logoButton.alpha = 1.0
        self.logoButton.transform = .identity
      } else {
        self.tabBar.alpha = 1.0
        self.tabBar.transform = .identity
        self.searchButton.alpha = self.showSearchButton ? 1.0 : 0.0
        self.searchButton.transform = .identity
        self.logoButton.alpha = 0.0
        self.logoButton.transform = CGAffineTransform(scaleX: 0.55, y: 0.55)
      }
    }

    tabBar.isUserInteractionEnabled = !collapsed
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
    let logoSize: CGFloat = min(max(totalH - 14.0, 50.0), 54.0)

    // When collapsed into a narrow right-aligned container, keep logoButton anchored
    // at the trailing edge without corrupting tabBar geometry.
    if isCollapsed && totalW < 150.0 {
      logoButton.bounds = CGRect(x: 0, y: 0, width: logoSize, height: logoSize)
      logoButton.center = CGPoint(x: totalW - outerMargin - logoSize * 0.5, y: totalH * 0.5)
      bringSubviewToFront(logoButton)
      return
    }

    let maxRowWidth: CGFloat = min(totalW, 440.0)
    let rowX = (totalW - maxRowWidth) * 0.5

    // Ask UITabBar for its natural capsule height (avoid forcing an oversized frame
    // that causes standalone UITabBar to treat extra height as bottom safe area).
    let fittedTab = tabBar.sizeThatFits(CGSize(width: maxRowWidth, height: totalH))
    let naturalBarH = min(max(fittedTab.height, 48.0), min(totalH, 64.0))

    // Use bounds + center (never frame) so active collapsed transforms stay safe.
    let initialCircleSize = naturalBarH
    let circleCenterX = rowX + maxRowWidth - outerMargin - initialCircleSize * 0.5

    if showSearchButton {
      // Standalone iOS 26 UITabBar keeps ~14-16pt built-in horizontal inset on each side.
      // Extending tabBar slightly toward searchButton produces balanced 16pt outer margins
      // and a crisp ~10pt visual gap between the capsule and the circular search button.
      let tabX = rowX
      let tabW = max((circleCenterX - initialCircleSize * 0.5 + 6.0) - tabX, 180.0)
      tabBar.bounds = CGRect(x: 0, y: 0, width: tabW, height: naturalBarH)
      tabBar.center = CGPoint(x: tabX + tabW * 0.5, y: totalH * 0.5)
      tabBar.layoutIfNeeded()

      let localPlatter = measureTabBarLocalPlatterRect(expectedWidth: tabW, fallbackHeight: naturalBarH)
      let offsetInsideBar = localPlatter.midY - tabBar.bounds.midY
      if abs(offsetInsideBar) > 0.25 && abs(offsetInsideBar) < 16.0 {
        tabBar.center = CGPoint(x: tabBar.center.x, y: totalH * 0.5 - offsetInsideBar)
      }

      let exactCircleSize = min(max(localPlatter.height, 44.0), min(totalH, 64.0))
      configureSearchButton(diameter: exactCircleSize)
      let exactCircleCenterX = rowX + maxRowWidth - outerMargin - exactCircleSize * 0.5
      searchButton.bounds = CGRect(x: 0, y: 0, width: exactCircleSize, height: exactCircleSize)
      searchButton.center = CGPoint(x: exactCircleCenterX, y: totalH * 0.5)

      let effectiveLogoSize = min(max(exactCircleSize, 50.0), 56.0)
      logoButton.bounds = CGRect(x: 0, y: 0, width: effectiveLogoSize, height: effectiveLogoSize)
      logoButton.center = CGPoint(x: rowX + maxRowWidth - outerMargin - effectiveLogoSize * 0.5, y: totalH * 0.5)
    } else {
      let tabX = rowX
      let tabW = max(maxRowWidth, 180.0)
      tabBar.bounds = CGRect(x: 0, y: 0, width: tabW, height: naturalBarH)
      tabBar.center = CGPoint(x: tabX + tabW * 0.5, y: totalH * 0.5)
      tabBar.layoutIfNeeded()

      logoButton.bounds = CGRect(x: 0, y: 0, width: logoSize, height: logoSize)
      logoButton.center = CGPoint(x: rowX + maxRowWidth - outerMargin - logoSize * 0.5, y: totalH * 0.5)
    }

    bringSubviewToFront(searchButton)
    bringSubviewToFront(logoButton)
  }
}

private final class MarcoNativeDockPlatformView: NSObject, FlutterPlatformView, UITabBarDelegate {
  private let container: MarcoDockContainerView
  private let channel: FlutterMethodChannel
  private var tabItems: [UITabBarItem] = []
  private var rawItemDicts: [[String: Any]] = []
  private var currentSelectedIndex: Int = 0

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
      applyState(args, animated: false)
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
            self.selectTab(index: idx)
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
    } else {
      rebuildLogoMenu()
    }
    if let collapsed = args["collapsed"] as? Bool {
      container.setCollapsed(collapsed, animated: animated)
    }
    container.setNeedsLayout()
  }

  private func selectTab(index: Int) {
    guard index >= 0, index < tabItems.count else { return }
    currentSelectedIndex = index
    if container.tabBar.selectedItem !== tabItems[index] {
      container.tabBar.selectedItem = tabItems[index]
    }
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
        self.selectTab(index: idx)
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

    container.logoButton.menu = UIMenu(title: "", children: sections)
  }

  func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
    currentSelectedIndex = item.tag
    rebuildLogoMenu()
    channel.invokeMethod("onSelect", arguments: item.tag)
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
    symbolSize: CGFloat,
    menu: UIMenu?
  ) {
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      let glass = UIGlassEffect(style: .regular)
      glass.isInteractive = true
      glass.tintColor = tintColor
      effectView.effect = glass
    }
    #endif

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

    if let menu = menu {
      menuOverlayButton.menu = menu
      menuOverlayButton.isHidden = false
    } else {
      menuOverlayButton.menu = nil
      menuOverlayButton.isHidden = true
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
    let tintColor = MarcoLiquidGlassSupport.colorFromARGB(args["tintColor"])
    let a11yLabel = (args["accessibilityLabel"] as? String) ?? label
    let menuTitle = (args["menuTitle"] as? String) ?? ""
    let rawMenuItems = (args["menuItems"] as? [[String: Any]]) ?? []
    let menu = MarcoLiquidGlassSupport.buildMenu(title: menuTitle, rawItems: rawMenuItems) { [weak self] selectedId in
      self?.channel.invokeMethod("onMenuSelected", arguments: selectedId)
    }

    isCapsuleMode = (style == "capsule" && (!label.isEmpty || (trailingSymbol != nil && !trailingSymbol!.isEmpty)))
    circleButton.isHidden = isCapsuleMode
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
        symbolSize: symbolSize,
        menu: menu
      )
    } else {
      circleButton.accessibilityLabel = a11yLabel
      if let menu = menu {
        circleButton.menu = menu
        circleButton.showsMenuAsPrimaryAction = true
      } else {
        circleButton.menu = nil
        circleButton.showsMenuAsPrimaryAction = false
      }
      let symCfg = UIImage.SymbolConfiguration(pointSize: symbolSize, weight: .semibold)
      let image = symbol.flatMap { UIImage(systemName: $0, withConfiguration: symCfg) }
      #if compiler(>=6.2)
      if #available(iOS 26.0, *) {
        var config = (tintColor != nil) ? UIButton.Configuration.prominentGlass() : UIButton.Configuration.glass()
        config.image = image
        config.baseForegroundColor = fgColor
        if let tint = tintColor {
          config.baseBackgroundColor = tint
        }
        config.cornerStyle = .capsule
        config.contentInsets = .zero
        circleButton.configuration = config
        return
      }
      #endif
      var config = UIButton.Configuration.filled()
      config.image = image
      config.baseForegroundColor = fgColor
      config.baseBackgroundColor = tintColor ?? UIColor(white: 0.16, alpha: 0.85)
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

    hostView.frame = frame
    hostView.backgroundColor = .clear
    hostView.isOpaque = false
    hostView.clipsToBounds = false
    hostView.overrideUserInterfaceStyle = .dark

    control.overrideUserInterfaceStyle = .dark
    control.apportionsSegmentWidthsByContent = false
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
