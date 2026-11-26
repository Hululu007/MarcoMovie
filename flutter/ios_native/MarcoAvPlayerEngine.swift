// MARK: - iOS 14+ Native Low-Power AVPlayer Engine (PiP + AirPlay 2 + EDR/XDR + Thermal Telemetry)
// Injected into AppDelegate.swift by prepare_platform.py (requires `import AVFoundation` and `import AVKit`).
// System device volume bridge also requires `import MediaPlayer`.

enum MarcoAvPlayerEngine {
  static let methodChannelName = "marco_movie/ios_avplayer"
  static let eventChannelName = "marco_movie/ios_avplayer_events"
  static let platformViewType = "marco_movie/ios_avplayer_view"

  private static var sharedCoordinator: MarcoAvPlayerCoordinator?

  static func register(with registrar: FlutterPluginRegistrar, messenger: FlutterBinaryMessenger) {
    let coordinator = sharedCoordinator ?? MarcoAvPlayerCoordinator()
    sharedCoordinator = coordinator
    coordinator.attach(messenger: messenger)

    let factory = MarcoAvPlayerViewFactory(coordinator: coordinator)
    registrar.register(factory, withId: platformViewType)
  }

  static func activeWindowScene() -> UIWindowScene? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    return scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
  }

  static func activeKeyWindow() -> UIWindow? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let activeScene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
    if let win = activeScene?.windows.first(where: { $0.isKeyWindow }) {
      return win
    }
    if let anyKey = scenes.flatMap({ $0.windows }).first(where: { $0.isKeyWindow }) {
      return anyKey
    }
    return activeScene?.windows.first
      ?? scenes.flatMap({ $0.windows }).first
      ?? (UIApplication.shared.delegate?.window ?? nil)
  }

  static func topPresenter() -> UIViewController? {
    var vc = activeKeyWindow()?.rootViewController
    while let presented = vc?.presentedViewController, !presented.isBeingDismissed {
      vc = presented
    }
    return vc
  }

  static func thermalStateString(_ state: ProcessInfo.ThermalState) -> String {
    switch state {
    case .nominal:
      return "nominal"
    case .fair:
      return "fair"
    case .serious:
      return "serious"
    case .critical:
      return "critical"
    @unknown default:
      return "nominal"
    }
  }

  static func machineIdentifier() -> String {
    var systemInfo = utsname()
    uname(&systemInfo)
    let mirror = Mirror(reflecting: systemInfo.machine)
    let chars = mirror.children.compactMap { elem -> Character? in
      guard let value = elem.value as? Int8, value != 0 else { return nil }
      return Character(UnicodeScalar(UInt8(value)))
    }
    return String(chars)
  }

  static func potentialEdrHeadroom() -> Double {
    guard let screen = activeWindowScene()?.screen else { return 1.0 }
    if #available(iOS 16.0, *) {
      return Double(screen.potentialEDRHeadroom)
    }
    return screen.traitCollection.displayGamut == .P3 ? 1.25 : 1.0
  }

  static func thermalStateCode(_ state: ProcessInfo.ThermalState) -> Int {
    switch state {
    case .nominal:
      return 0
    case .fair:
      return 1
    case .serious:
      return 2
    case .critical:
      return 3
    @unknown default:
      return 0
    }
  }
}

private final class MarcoAvPlayerLayerContainerView: UIView {
  let playerLayer = AVPlayerLayer()

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .black
    isOpaque = true
    playerLayer.videoGravity = .resizeAspect
    playerLayer.needsDisplayOnBoundsChange = true
    layer.addSublayer(playerLayer)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    playerLayer.frame = bounds
    CATransaction.commit()
  }
}

private final class MarcoAvPlayerPlatformView: NSObject, FlutterPlatformView {
  private let container: MarcoAvPlayerLayerContainerView
  private weak var coordinator: MarcoAvPlayerCoordinator?

  init(frame: CGRect, coordinator: MarcoAvPlayerCoordinator) {
    self.container = MarcoAvPlayerLayerContainerView(frame: frame)
    self.coordinator = coordinator
    super.init()
    coordinator.bindPlayerLayer(container.playerLayer)
  }

  func view() -> UIView {
    return container
  }

  deinit {
    coordinator?.unbindPlayerLayer(container.playerLayer)
  }
}

private final class MarcoAvPlayerViewFactory: NSObject, FlutterPlatformViewFactory {
  private let coordinator: MarcoAvPlayerCoordinator

  init(coordinator: MarcoAvPlayerCoordinator) {
    self.coordinator = coordinator
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
    return MarcoAvPlayerPlatformView(frame: frame, coordinator: coordinator)
  }
}

private final class MarcoAvPlayerCoordinator: NSObject, FlutterStreamHandler, AVPictureInPictureControllerDelegate {
  private var methodChannel: FlutterMethodChannel?
  private var eventSink: FlutterEventSink?

  private var queuePlayer: AVQueuePlayer?
  private weak var visiblePlayerLayer: AVPlayerLayer?
  private var pipSourceLayer: AVPlayerLayer?
  private var pipController: AVPictureInPictureController?
  private var hiddenAirPlayPicker: AVRoutePickerView?
  private var hiddenVolumeView: MPVolumeView?

  private var audioSessionConfigured: Bool = false
  private var audioSessionActive: Bool = false
  private var autoPipEnabled: Bool = true
  private var pipStarting: Bool = false
  private var cancelPendingPipStart: Bool = false
  private var volumeConfirmWorkItem: DispatchWorkItem?
  private var pendingStartPositionMs: Int = 0
  private var currentSessionId: Int = 0
  private var activeMediaId: Int?
  private var mediaEventSeq: Int = 0
  private var currentUrlString: String = ""
  private var fallbackEmittedForCurrentItem: Bool = false
  private var requestedRate: Float = 1.0

  private var isPipActiveOrStarting: Bool {
    return pipStarting || (pipController?.isPictureInPictureActive == true)
  }

  private var timeObserverToken: Any?
  private var statusObservation: NSKeyValueObservation?
  private var likelyToKeepUpObservation: NSKeyValueObservation?
  private var bufferEmptyObservation: NSKeyValueObservation?
  private var presentationSizeObservation: NSKeyValueObservation?
  private var timeControlStatusObservation: NSKeyValueObservation?
  private var externalPlaybackObservation: NSKeyValueObservation?
  private var pipPossibleObservation: NSKeyValueObservation?
  private var systemVolumeObservation: NSKeyValueObservation?
  private var itemNotificationTokens: [NSObjectProtocol] = []
  private var notificationTokens: [NSObjectProtocol] = []

  override init() {
    super.init()
    installGlobalObservers()
  }

  deinit {
    cleanupPlaybackObservers()
    volumeConfirmWorkItem?.cancel()
    volumeConfirmWorkItem = nil
    systemVolumeObservation?.invalidate()
    systemVolumeObservation = nil
    detachHiddenVolumeView()
    for token in notificationTokens {
      NotificationCenter.default.removeObserver(token)
    }
    notificationTokens.removeAll()
  }

  func attach(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: MarcoAvPlayerEngine.methodChannelName,
      binaryMessenger: messenger
    )
    methodChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handleMethodCall(call, result: result)
    }

    let events = FlutterEventChannel(
      name: MarcoAvPlayerEngine.eventChannelName,
      binaryMessenger: messenger
    )
    events.setStreamHandler(self)
  }

  // MARK: - FlutterStreamHandler

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    self.eventSink = events
    emitTelemetrySnapshot()
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    self.eventSink = nil
    return nil
  }

  // MARK: - PlatformView Layer Binding

  func bindPlayerLayer(_ layer: AVPlayerLayer) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.visiblePlayerLayer = layer
      let player = self.ensurePlayer()
      layer.player = player
      if self.isPipActiveOrStarting {
        // Keep the starting or active PiP controller attached to pipSourceLayer
        // until PiP finishes starting/stopping or fails; delegate callbacks will
        // rebind visiblePlayerLayer cleanly without dropping start/failure events.
        self.emitPipState()
        return
      }
      if self.pipSourceLayer !== layer || self.pipController == nil {
        if let oldSource = self.pipSourceLayer, oldSource !== layer {
          oldSource.player = nil
        }
        self.configurePictureInPicture(for: layer)
      } else {
        self.emitPipState()
      }
    }
  }

  func unbindPlayerLayer(_ layer: AVPlayerLayer) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      if self.visiblePlayerLayer === layer {
        self.visiblePlayerLayer = nil
      }
      let isProtectedPipSource = self.isPipActiveOrStarting
        && self.pipSourceLayer === layer
      if isProtectedPipSource {
        // Retain pipSourceLayer and pipController strongly across both the
        // starting transition (startPictureInPicture -> didStart/failed) and
        // active PiP so rotation, Split View, or layout rebuilds never drop
        // delegate callbacks or cancel PiP silently.
        return
      }
      if self.visiblePlayerLayer !== layer {
        layer.player = nil
      }
      if self.pipSourceLayer === layer {
        self.teardownPictureInPicture(detachSourceLayer: false)
        if let currentVisible = self.visiblePlayerLayer {
          self.configurePictureInPicture(for: currentVisible)
        } else {
          self.emitPipState()
        }
      }
    }
  }

  private func ensurePlayer() -> AVQueuePlayer {
    if let existing = queuePlayer {
      return existing
    }
    let player = AVQueuePlayer()
    player.automaticallyWaitsToMinimizeStalling = true
    player.preventsDisplaySleepDuringVideoPlayback = true
    player.allowsExternalPlayback = true
    player.usesExternalPlaybackWhileExternalScreenIsActive = true
    player.actionAtItemEnd = .pause

    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      // iOS 26+ native EDR/XDR pipeline defaults are automatically preserved by AVPlayerLayer.
      player.allowsExternalPlayback = true
    }
    #endif

    externalPlaybackObservation = player.observe(\.isExternalPlaybackActive, options: [.new]) { [weak self] _, _ in
      DispatchQueue.main.async {
        self?.emitAirPlayState()
      }
    }
    timeControlStatusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
      let item = p.currentItem
      DispatchQueue.main.async {
        guard let self = self, let item = item, p.currentItem === item else { return }
        let playing = p.timeControlStatus == .playing
        let buffering = p.timeControlStatus == .waitingToPlayAtSpecifiedRate
        self.emitMediaEvent([
          "type": "playbackState",
          "playing": playing,
          "buffering": buffering,
          "rate": Double(p.rate),
          "positionMs": self.currentPositionMs(),
          "durationMs": self.currentDurationMs(),
        ])
      }
    }

    let interval = CMTime(seconds: 0.25, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
    timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
      self?.emitProgressTick()
    }

    queuePlayer = player
    return player
  }

  private func teardownPictureInPicture(detachSourceLayer: Bool) {
    pipPossibleObservation?.invalidate()
    pipPossibleObservation = nil
    pipController?.delegate = nil
    pipController = nil
    if detachSourceLayer, let source = pipSourceLayer, source !== visiblePlayerLayer {
      source.player = nil
    }
    pipSourceLayer = nil
  }

  private func configurePictureInPicture(for layer: AVPlayerLayer) {
    if isPipActiveOrStarting {
      emitPipState()
      return
    }
    teardownPictureInPicture(detachSourceLayer: true)

    guard AVPictureInPictureController.isPictureInPictureSupported() else {
      emitPipState()
      return
    }
    guard let controller = AVPictureInPictureController(playerLayer: layer) else {
      emitPipState()
      return
    }
    controller.delegate = self
    if #available(iOS 14.2, *) {
      controller.canStartPictureInPictureAutomaticallyFromInline = autoPipEnabled
    }
    pipSourceLayer = layer
    pipController = controller
    pipPossibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] _, _ in
      DispatchQueue.main.async {
        self?.emitPipState()
      }
    }
    emitPipState()
  }

  private func installGlobalObservers() {
    let center = NotificationCenter.default
    notificationTokens.append(
      center.addObserver(
        forName: ProcessInfo.thermalStateDidChangeNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        let state = ProcessInfo.processInfo.thermalState
        self?.emitEvent([
          "type": "thermalStateChanged",
          "thermalState": MarcoAvPlayerEngine.thermalStateString(state),
          "thermalStateCode": MarcoAvPlayerEngine.thermalStateCode(state),
        ])
      }
    )
    notificationTokens.append(
      center.addObserver(
        forName: AVAudioSession.routeChangeNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        guard let self = self else { return }
        self.emitAirPlayState()
        self.emitEvent([
          "type": "systemVolumeChanged",
          "volume": self.currentSystemVolume(),
        ])
      }
    )
    notificationTokens.append(
      center.addObserver(
        forName: AVAudioSession.interruptionNotification,
        object: nil,
        queue: .main
      ) { [weak self] notif in
        guard let rawType = notif.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
        if type == .began {
          self?.audioSessionActive = false
        }
      }
    )
    systemVolumeObservation = AVAudioSession.sharedInstance().observe(
      \.outputVolume,
      options: [.initial, .new]
    ) { [weak self] session, _ in
      let vol = Double(max(0.0, min(session.outputVolume, 1.0)))
      DispatchQueue.main.async {
        self?.emitEvent([
          "type": "systemVolumeChanged",
          "volume": vol,
        ])
      }
    }
  }

  // MARK: - Method Channel Handling

  private func handleMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "open":
      guard let args = call.arguments as? [String: Any],
            let urlStr = args["url"] as? String else {
        result(FlutterError(code: "INVALID_ARGS", message: "Missing url", details: nil))
        return
      }
      let rawHeaders = (args["headers"] as? [String: Any]) ?? [:]
      var headers: [String: String] = [:]
      for (k, v) in rawHeaders {
        let val = String(describing: v).trimmingCharacters(in: .whitespacesAndNewlines)
        if !k.isEmpty && !val.isEmpty {
          headers[k] = val
        }
      }
      let startPositionMs = (args["startPositionMs"] as? NSNumber)?.intValue ?? 0
      let autoPlay = (args["autoPlay"] as? Bool) ?? true
      let preferredBufferSec = (args["preferredForwardBufferDuration"] as? NSNumber)?.doubleValue ?? 24.0
      DispatchQueue.main.async { [weak self] in
        self?.openMedia(
          urlString: urlStr,
          mediaId: (args["mediaId"] as? NSNumber)?.intValue,
          headers: headers,
          startPositionMs: startPositionMs,
          autoPlay: autoPlay,
          preferredBufferSec: preferredBufferSec,
          result: result
        )
      }

    case "play":
      DispatchQueue.main.async { [weak self] in
        guard let self = self else { result(nil); return }
        self.configureAudioSession()
        let player = self.ensurePlayer()
        player.play()
        if self.requestedRate != 1.0 {
          player.rate = self.requestedRate
        }
        result(nil)
      }

    case "pause":
      DispatchQueue.main.async { [weak self] in
        self?.queuePlayer?.pause()
        result(nil)
      }

    case "seek":
      let posMs = (call.arguments as? NSNumber)?.intValue
        ?? ((call.arguments as? [String: Any])?["positionMs"] as? NSNumber)?.intValue
        ?? 0
      DispatchQueue.main.async { [weak self] in
        guard let self = self, let player = self.queuePlayer else {
          result(false)
          return
        }
        let seekMediaId = self.activeMediaId
        let clampedMs = max(0, posMs)
        let target = CMTime(value: CMTimeValue(clampedMs), timescale: 1000)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
          DispatchQueue.main.async {
            guard let self = self,
                  finished,
                  let mediaId = seekMediaId,
                  self.activeMediaId == mediaId else {
              result(false)
              return
            }
            self.mediaEventSeq += 1
            let seq = self.mediaEventSeq
            let landedMs = self.currentPositionMs()
            result([
              "finished": true,
              "mediaId": mediaId,
              "eventSeq": seq,
              "positionMs": (landedMs > 0 || clampedMs == 0) ? landedMs : clampedMs,
            ])
          }
        }
      }

    case "setRate":
      let rateVal = (call.arguments as? NSNumber)?.floatValue ?? 1.0
      DispatchQueue.main.async { [weak self] in
        guard let self = self else { result(nil); return }
        let clamped = max(0.25, min(rateVal, 4.0))
        self.requestedRate = clamped
        if let player = self.queuePlayer, player.timeControlStatus == .playing || player.rate > 0 {
          player.rate = clamped
        }
        result(nil)
      }

    case "setVolume":
      let vol = (call.arguments as? NSNumber)?.floatValue ?? 1.0
      DispatchQueue.main.async { [weak self] in
        self?.queuePlayer?.volume = max(0.0, min(vol, 1.0))
        result(nil)
      }

    case "getSystemVolume":
      DispatchQueue.main.async { [weak self] in
        result(self?.currentSystemVolume() ?? Double(AVAudioSession.sharedInstance().outputVolume))
      }

    case "setSystemVolume":
      let targetVol = (call.arguments as? NSNumber)?.doubleValue
        ?? ((call.arguments as? [String: Any])?["volume"] as? NSNumber)?.doubleValue
        ?? 0.5
      DispatchQueue.main.async { [weak self] in
        guard let self = self else {
          result(["applied": false, "volume": Double(AVAudioSession.sharedInstance().outputVolume)])
          return
        }
        result(self.setSystemVolume(targetVol))
      }

    case "detachSystemVolume":
      DispatchQueue.main.async { [weak self] in
        self?.detachHiddenVolumeView()
        result(nil)
      }

    case "setVideoGravity":
      let mode = (call.arguments as? String) ?? "resizeAspect"
      DispatchQueue.main.async { [weak self] in
        guard let layer = self?.visiblePlayerLayer else { result(nil); return }
        switch mode {
        case "resizeAspectFill", "cover":
          layer.videoGravity = .resizeAspectFill
        case "resize", "fill":
          layer.videoGravity = .resize
        default:
          layer.videoGravity = .resizeAspect
        }
        result(nil)
      }

    case "startPip":
      DispatchQueue.main.async { [weak self] in
        guard let self = self else { result(false); return }
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
          self.emitPipState()
          result(false)
          return
        }
        guard self.configureAudioSession(forceActivate: true) else {
          self.emitEvent([
            "type": "pipStateChanged",
            "active": false,
            "supported": true,
            "possible": self.pipController?.isPictureInPicturePossible ?? false,
            "phase": "failed",
            "error": "音频会话激活失败，暂无法开启画中画",
          ])
          result(false)
          return
        }
        if let visible = self.visiblePlayerLayer,
           (self.pipController == nil ||
            (self.pipSourceLayer !== visible && !self.isPipActiveOrStarting)) {
          self.configurePictureInPicture(for: visible)
        }
        guard let pip = self.pipController else {
          self.emitPipState()
          result(false)
          return
        }
        if pip.isPictureInPictureActive {
          self.pipStarting = false
          self.emitPipState(phase: "didStart")
          result(true)
          return
        }
        if self.pipStarting {
          result(true)
          return
        }
        guard pip.isPictureInPicturePossible else {
          self.emitEvent([
            "type": "pipStateChanged",
            "active": false,
            "supported": true,
            "possible": false,
            "phase": "notReady",
          ])
          result(false)
          return
        }
        self.cancelPendingPipStart = false
        self.pipStarting = true
        pip.startPictureInPicture()
        result(true)
      }

    case "stopPip":
      DispatchQueue.main.async { [weak self] in
        guard let self = self else { result(nil); return }
        if let pip = self.pipController, pip.isPictureInPictureActive {
          self.cancelPendingPipStart = false
          pip.stopPictureInPicture()
        } else if self.pipStarting {
          self.cancelPendingPipStart = true
        }
        result(nil)
      }

    case "setAutoPip":
      let enabled = (call.arguments as? Bool) ?? true
      DispatchQueue.main.async { [weak self] in
        self?.autoPipEnabled = enabled
        if #available(iOS 14.2, *) {
          self?.pipController?.canStartPictureInPictureAutomaticallyFromInline = enabled
        }
        result(nil)
      }

    case "presentAirPlayPicker":
      DispatchQueue.main.async { [weak self] in
        self?.presentAirPlayPicker()
        result(true)
      }

    case "getAudioTracks":
      DispatchQueue.main.async { [weak self] in
        result(self?.readMediaSelectionTracks(characteristic: .audible) ?? [])
      }

    case "setAudioTrack":
      let trackId = call.arguments as? String
      DispatchQueue.main.async { [weak self] in
        self?.selectMediaTrack(characteristic: .audible, trackId: trackId)
        result(nil)
      }

    case "getSubtitleTracks":
      DispatchQueue.main.async { [weak self] in
        result(self?.readMediaSelectionTracks(characteristic: .legible) ?? [])
      }

    case "setSubtitleTrack":
      let trackId = call.arguments as? String
      DispatchQueue.main.async { [weak self] in
        self?.selectMediaTrack(characteristic: .legible, trackId: trackId)
        result(nil)
      }

    case "getTelemetry":
      DispatchQueue.main.async { [weak self] in
        result(self?.buildTelemetryMap() ?? [:])
      }

    case "stop", "dispose":
      DispatchQueue.main.async { [weak self] in
        self?.stopPlayback()
        result(nil)
      }

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Playback Lifecycle & Auto-Fallback

  @discardableResult
  private func configureAudioSession(forceActivate: Bool = false) -> Bool {
    let session = AVAudioSession.sharedInstance()
    if !audioSessionConfigured || session.category != .playback || session.mode != .moviePlayback {
      do {
        // `.playback` supports AirPlay routing by default; Apple restricts `.allowAirPlay`
        // to `.playAndRecord` and rejects it on `.playback`.
        try session.setCategory(.playback, mode: .moviePlayback, options: [])
        audioSessionConfigured = true
      } catch {
        audioSessionConfigured = false
        NSLog("[MarcoAvPlayer] AVAudioSession.setCategory failed: %@", error.localizedDescription)
      }
    }
    if forceActivate || !audioSessionActive {
      do {
        try session.setActive(true)
        audioSessionActive = true
      } catch {
        audioSessionActive = false
        NSLog("[MarcoAvPlayer] AVAudioSession.setActive(true) failed: %@", error.localizedDescription)
        return false
      }
    }
    return audioSessionActive
  }

  private func openMedia(
    urlString: String,
    mediaId: Int?,
    headers: [String: String],
    startPositionMs: Int,
    autoPlay: Bool,
    preferredBufferSec: Double,
    result: @escaping FlutterResult
  ) {
    guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
      result(FlutterError(code: "INVALID_URL", message: "Invalid media URL", details: urlString))
      return
    }
    let scheme = (url.scheme ?? "").lowercased()
    if scheme != "http" && scheme != "https" && scheme != "file" {
      result(false)
      return
    }

    configureAudioSession()
    currentSessionId += 1
    let sessionId = currentSessionId
    activeMediaId = mediaId ?? sessionId
    currentUrlString = urlString
    pendingStartPositionMs = max(0, startPositionMs)
    fallbackEmittedForCurrentItem = false

    cleanupItemObservers()

    var assetOptions: [String: Any] = [
      AVURLAssetAllowsCellularAccessKey: true,
      AVURLAssetAllowsExpensiveNetworkAccessKey: true,
      AVURLAssetAllowsConstrainedNetworkAccessKey: true,
    ]
    if !headers.isEmpty {
      assetOptions["AVURLAssetHTTPHeaderFieldsKey"] = headers
    }

    let asset = AVURLAsset(url: url, options: assetOptions)
    let item = AVPlayerItem(asset: asset)
    item.preferredForwardBufferDuration = max(4.0, preferredBufferSec)
    item.canUseNetworkResourcesForLiveStreamingWhilePaused = true

    let player = ensurePlayer()
    if let layer = visiblePlayerLayer {
      if layer.player !== player {
        layer.player = player
      }
      if pipController == nil || (pipSourceLayer !== layer && !isPipActiveOrStarting) {
        configurePictureInPicture(for: layer)
      }
    }

    observePlayerItem(item, sessionId: sessionId)
    player.replaceCurrentItem(with: item)

    if autoPlay {
      player.play()
      if requestedRate != 1.0 {
        player.rate = requestedRate
      }
    } else {
      player.pause()
    }
    result(true)
  }

  private func observePlayerItem(_ item: AVPlayerItem, sessionId: Int) {
    statusObservation = item.observe(\.status, options: [.new]) { [weak self] observedItem, _ in
      DispatchQueue.main.async {
        guard let self = self, self.currentSessionId == sessionId else { return }
        switch observedItem.status {
        case .readyToPlay:
          if self.pendingStartPositionMs > 0 {
            let seekTarget = CMTime(value: CMTimeValue(self.pendingStartPositionMs), timescale: 1000)
            self.pendingStartPositionMs = 0
            self.queuePlayer?.seek(to: seekTarget, toleranceBefore: .zero, toleranceAfter: .zero)
          }
          self.inspectPlayabilityAndHdr(for: observedItem, sessionId: sessionId)
          self.emitMediaEvent([
            "type": "ready",
            "durationMs": self.currentDurationMs(),
            "positionMs": self.currentPositionMs(),
            "width": Int(observedItem.presentationSize.width),
            "height": Int(observedItem.presentationSize.height),
            "isHdr": self.isHdrItem(observedItem),
            "audioTracks": self.readMediaSelectionTracks(characteristic: .audible),
            "subtitleTracks": self.readMediaSelectionTracks(characteristic: .legible),
          ])
        case .failed:
          let message = observedItem.error?.localizedDescription ?? "AVPlayerItem status failed"
          self.triggerFallbackToMpv(reason: message)
        case .unknown:
          break
        @unknown default:
          break
        }
      }
    }

    presentationSizeObservation = item.observe(\.presentationSize, options: [.new]) { [weak self] observedItem, _ in
      DispatchQueue.main.async {
        guard let self = self, self.currentSessionId == sessionId else { return }
        let size = observedItem.presentationSize
        if size.width > 0 && size.height > 0 {
          self.emitMediaEvent([
            "type": "videoSize",
            "width": Int(size.width),
            "height": Int(size.height),
            "isHdr": self.isHdrItem(observedItem),
          ])
        }
      }
    }

    likelyToKeepUpObservation = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] observedItem, _ in
      DispatchQueue.main.async {
        guard let self = self, self.currentSessionId == sessionId else { return }
        self.emitMediaEvent([
          "type": "buffering",
          "buffering": !observedItem.isPlaybackLikelyToKeepUp,
        ])
      }
    }

    bufferEmptyObservation = item.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] observedItem, _ in
      DispatchQueue.main.async {
        guard let self = self, self.currentSessionId == sessionId else { return }
        if observedItem.isPlaybackBufferEmpty {
          self.emitMediaEvent([
            "type": "buffering",
            "buffering": true,
          ])
        }
      }
    }

    let center = NotificationCenter.default
    itemNotificationTokens.append(
      center.addObserver(
        forName: .AVPlayerItemDidPlayToEndTime,
        object: item,
        queue: .main
      ) { [weak self] _ in
        guard let self = self, self.currentSessionId == sessionId else { return }
        self.emitMediaEvent([
          "type": "completed",
          "positionMs": self.currentDurationMs(),
          "durationMs": self.currentDurationMs(),
        ])
      }
    )

    itemNotificationTokens.append(
      center.addObserver(
        forName: .AVPlayerItemFailedToPlayToEndTime,
        object: item,
        queue: .main
      ) { [weak self] notif in
        guard let self = self, self.currentSessionId == sessionId else { return }
        let err = notif.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
        self.triggerFallbackToMpv(reason: err?.localizedDescription ?? "Failed to play to end time")
      }
    )
  }

  private func inspectPlayabilityAndHdr(for item: AVPlayerItem, sessionId: Int) {
    let asset = item.asset
    asset.loadValuesAsynchronously(forKeys: ["playable", "tracks"]) { [weak self] in
      DispatchQueue.main.async {
        guard let self = self, self.currentSessionId == sessionId else { return }
        var err: NSError?
        if asset.statusOfValue(forKey: "playable", error: &err) == .loaded, !asset.isPlayable {
          self.triggerFallbackToMpv(reason: err?.localizedDescription ?? "Asset is not playable by AVPlayer")
          return
        }
        let audioTracks = asset.tracks(withMediaType: .audio)
        let hasDisabledAudio = !audioTracks.isEmpty && audioTracks.allSatisfy { !$0.isPlayable }
        if hasDisabledAudio {
          self.triggerFallbackToMpv(reason: "Audio track codec unsupported by AVPlayer")
        }
      }
    }
  }

  private func isHdrItem(_ item: AVPlayerItem) -> Bool {
    for track in item.asset.tracks(withMediaType: .video) {
      if track.hasMediaCharacteristic(.containsHDRVideo) {
        return true
      }
    }
    return false
  }

  private func triggerFallbackToMpv(reason: String) {
    guard !fallbackEmittedForCurrentItem, let mediaId = activeMediaId else { return }
    fallbackEmittedForCurrentItem = true
    let posMs = max(pendingStartPositionMs, currentPositionMs())
    queuePlayer?.pause()
    if eventSink != nil {
      emitMediaEvent([
        "type": "fallbackToMpv",
        "positionMs": posMs,
        "reason": reason,
      ])
    } else {
      methodChannel?.invokeMethod(
        "onFallbackToMpv",
        arguments: [
          "mediaId": mediaId,
          "positionMs": posMs,
          "reason": reason,
        ]
      )
    }
  }

  private func stopPlayback() {
    let wasStartingPip = pipStarting
    let wasActivePip = pipController?.isPictureInPictureActive == true
    pipStarting = false
    activeMediaId = nil
    currentSessionId += 1
    cleanupItemObservers()
    if let pip = pipController, wasActivePip {
      pip.stopPictureInPicture()
    } else if wasStartingPip {
      emitEvent([
        "type": "pipStateChanged",
        "active": false,
        "supported": AVPictureInPictureController.isPictureInPictureSupported(),
        "possible": false,
        "phase": "cancelled",
      ])
    }
    if #available(iOS 14.2, *) {
      pipController?.canStartPictureInPictureAutomaticallyFromInline = false
    }
    teardownPictureInPicture(detachSourceLayer: true)
    queuePlayer?.pause()
    queuePlayer?.removeAllItems()
    detachHiddenVolumeView()
    audioSessionActive = false
  }

  private func cleanupItemObservers() {
    statusObservation?.invalidate()
    statusObservation = nil
    likelyToKeepUpObservation?.invalidate()
    likelyToKeepUpObservation = nil
    bufferEmptyObservation?.invalidate()
    bufferEmptyObservation = nil
    presentationSizeObservation?.invalidate()
    presentationSizeObservation = nil
    let center = NotificationCenter.default
    for token in itemNotificationTokens {
      center.removeObserver(token)
    }
    itemNotificationTokens.removeAll()
  }

  private func cleanupPlaybackObservers() {
    cleanupItemObservers()
    timeControlStatusObservation?.invalidate()
    timeControlStatusObservation = nil
    externalPlaybackObservation?.invalidate()
    externalPlaybackObservation = nil
    pipPossibleObservation?.invalidate()
    pipPossibleObservation = nil
    if let token = timeObserverToken, let player = queuePlayer {
      player.removeTimeObserver(token)
    }
    timeObserverToken = nil
  }

  // MARK: - Media Selection Tracks

  private func readMediaSelectionTracks(characteristic: AVMediaCharacteristic) -> [[String: Any]] {
    guard let item = queuePlayer?.currentItem,
          let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: characteristic) else {
      return []
    }
    let selected = item.currentMediaSelection.selectedMediaOption(in: group)
    var out: [[String: Any]] = []
    for (idx, option) in group.options.enumerated() {
      let lang = option.locale?.identifier ?? option.extendedLanguageTag ?? ""
      out.append([
        "id": "\(idx)",
        "title": option.displayName,
        "language": lang,
        "selected": option == selected,
      ])
    }
    return out
  }

  private func selectMediaTrack(characteristic: AVMediaCharacteristic, trackId: String?) {
    guard let item = queuePlayer?.currentItem,
          let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: characteristic) else {
      return
    }
    if trackId == nil || trackId == "off" || trackId == "no" {
      if group.allowsEmptySelection {
        item.select(nil, in: group)
      }
      return
    }
    if let rawId = trackId, let idx = Int(rawId), idx >= 0 && idx < group.options.count {
      item.select(group.options[idx], in: group)
    }
  }

  // MARK: - Device System Volume (MPVolumeView + AVAudioSession)

  private func currentSystemVolume() -> Double {
    let session = AVAudioSession.sharedInstance()
    return Double(max(0.0, min(session.outputVolume, 1.0)))
  }

  private func findSlider(in view: UIView) -> UISlider? {
    for sub in view.subviews {
      if let slider = sub as? UISlider {
        return slider
      }
      if let nested = findSlider(in: sub) {
        return nested
      }
    }
    return nil
  }

  private func ensureHiddenVolumeSlider() -> UISlider? {
    let volumeView: MPVolumeView
    if let existing = hiddenVolumeView {
      volumeView = existing
    } else {
      let created = MPVolumeView(frame: CGRect(x: -2000.0, y: -2000.0, width: 1.0, height: 1.0))
      created.showsVolumeSlider = true
      created.alpha = 0.01
      created.isUserInteractionEnabled = false
      hiddenVolumeView = created
      volumeView = created
    }
    if volumeView.superview == nil, let window = MarcoAvPlayerEngine.activeKeyWindow() {
      window.addSubview(volumeView)
      volumeView.layoutIfNeeded()
    }
    return findSlider(in: volumeView)
  }

  private func setSystemVolume(_ volume: Double) -> [String: Any] {
    let clamped = max(0.0, min(volume, 1.0))
    let sessionReady = (audioSessionConfigured && audioSessionActive)
      ? true
      : configureAudioSession(forceActivate: true)
    guard sessionReady else {
      return [
        "applied": false,
        "volume": currentSystemVolume(),
        "reason": "audioSessionFailed",
      ]
    }
    guard let slider = ensureHiddenVolumeSlider() else {
      return [
        "applied": false,
        "volume": currentSystemVolume(),
        "reason": "sliderUnavailable",
      ]
    }
    let before = currentSystemVolume()
    slider.setValue(Float(clamped), animated: false)
    slider.sendActions(for: [.valueChanged, .touchUpInside])
    let observed = currentSystemVolume()
    let confirmedNow = abs(observed - before) > 0.001 || abs(observed - clamped) <= 0.02
    let reportedVolume = confirmedNow ? observed : clamped

    // MPVolumeView commits AVAudioSession.outputVolume asynchronously on the next
    // runloop cycle on real hardware; always schedule a post-commit readback so
    // Flutter's volume state and HUD converge to the true hardware volume.
    volumeConfirmWorkItem?.cancel()
    let confirmWork = DispatchWorkItem { [weak self] in
      guard let self = self else { return }
      self.emitEvent([
        "type": "systemVolumeChanged",
        "volume": self.currentSystemVolume(),
      ])
    }
    volumeConfirmWorkItem = confirmWork
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: confirmWork)

    return [
      "applied": true,
      "volume": reportedVolume,
      "observedVolume": observed,
      "requestedVolume": clamped,
    ]
  }

  private func detachHiddenVolumeView() {
    volumeConfirmWorkItem?.cancel()
    volumeConfirmWorkItem = nil
    let viewToRemove = hiddenVolumeView
    hiddenVolumeView = nil
    guard let view = viewToRemove else { return }
    if Thread.isMainThread {
      view.removeFromSuperview()
    } else {
      DispatchQueue.main.async {
        view.removeFromSuperview()
      }
    }
  }

  // MARK: - AirPlay 2

  private func presentAirPlayPicker() {
    guard let host = MarcoAvPlayerEngine.topPresenter() else { return }
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

  private func activeAirPlayRouteName() -> String? {
    let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
    for output in outputs where output.portType == .airPlay {
      return output.portName
    }
    return nil
  }

  private func emitAirPlayState() {
    let routeName = activeAirPlayRouteName()
    let active = (queuePlayer?.isExternalPlaybackActive ?? false) || routeName != nil
    emitEvent([
      "type": "airPlayStateChanged",
      "isAirPlayActive": active,
      "deviceName": routeName ?? "",
    ])
  }

  // MARK: - AVPictureInPictureControllerDelegate

  func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    pipStarting = true
    emitEvent([
      "type": "pipStateChanged",
      "active": false,
      "supported": AVPictureInPictureController.isPictureInPictureSupported(),
      "possible": pictureInPictureController.isPictureInPicturePossible,
      "phase": "willStart",
    ])
  }

  func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    pipStarting = false
    if cancelPendingPipStart {
      cancelPendingPipStart = false
      pictureInPictureController.stopPictureInPicture()
      emitEvent([
        "type": "pipStateChanged",
        "active": false,
        "supported": AVPictureInPictureController.isPictureInPictureSupported(),
        "possible": pictureInPictureController.isPictureInPicturePossible,
        "phase": "cancelled",
      ])
      return
    }
    emitPipState(phase: "didStart")
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    pipStarting = false
    cancelPendingPipStart = false
    let prevPossible = pictureInPictureController.isPictureInPicturePossible
    if pipSourceLayer !== visiblePlayerLayer {
      teardownPictureInPicture(detachSourceLayer: true)
      if let currentVisible = visiblePlayerLayer {
        configurePictureInPicture(for: currentVisible)
      }
    }
    emitEvent([
      "type": "pipStateChanged",
      "active": false,
      "supported": AVPictureInPictureController.isPictureInPictureSupported(),
      "possible": pipController?.isPictureInPicturePossible ?? prevPossible,
      "phase": "failed",
      "error": error.localizedDescription,
    ])
  }

  func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    pipStarting = false
    emitEvent([
      "type": "pipStateChanged",
      "active": false,
      "supported": AVPictureInPictureController.isPictureInPictureSupported(),
      "possible": pictureInPictureController.isPictureInPicturePossible,
      "phase": "willStop",
    ])
  }

  func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    pipStarting = false
    if pipSourceLayer !== visiblePlayerLayer {
      teardownPictureInPicture(detachSourceLayer: true)
      if let currentVisible = visiblePlayerLayer {
        configurePictureInPicture(for: currentVisible)
      }
    }
    emitPipState(phase: "didStop")
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
  ) {
    emitEvent(["type": "pipRestoreForeground"])
    methodChannel?.invokeMethod("onPipRestoreForeground", arguments: nil)
    completionHandler(true)
  }

  private func emitPipState(phase: String? = nil) {
    var payload: [String: Any] = [
      "type": "pipStateChanged",
      "active": pipController?.isPictureInPictureActive ?? false,
      "supported": AVPictureInPictureController.isPictureInPictureSupported(),
      "possible": pipController?.isPictureInPicturePossible ?? false,
    ]
    if let phase = phase {
      payload["phase"] = phase
    }
    emitEvent(payload)
  }

  // MARK: - Telemetry & Progress

  private func currentPositionMs() -> Int {
    guard let player = queuePlayer else { return 0 }
    let sec = CMTimeGetSeconds(player.currentTime())
    guard sec.isFinite && sec >= 0 else { return 0 }
    return Int((sec * 1000.0).rounded())
  }

  private func currentDurationMs() -> Int {
    guard let item = queuePlayer?.currentItem else { return 0 }
    let sec = CMTimeGetSeconds(item.duration)
    guard sec.isFinite && sec > 0 else { return 0 }
    return Int((sec * 1000.0).rounded())
  }

  private func currentBufferedMs() -> Int {
    guard let item = queuePlayer?.currentItem,
          let range = item.loadedTimeRanges.first?.timeRangeValue else {
      return 0
    }
    let endSec = CMTimeGetSeconds(CMTimeAdd(range.start, range.duration))
    guard endSec.isFinite && endSec > 0 else { return 0 }
    return Int((endSec * 1000.0).rounded())
  }

  private func emitProgressTick() {
    guard queuePlayer?.currentItem != nil else { return }
    emitMediaEvent([
      "type": "progress",
      "positionMs": currentPositionMs(),
      "durationMs": currentDurationMs(),
      "bufferedMs": currentBufferedMs(),
      "playing": queuePlayer?.timeControlStatus == .playing,
    ])
  }

  private func buildTelemetryMap() -> [String: Any] {
    let info = ProcessInfo.processInfo
    let routeName = activeAirPlayRouteName()
    let airPlayActive = (queuePlayer?.isExternalPlaybackActive ?? false) || routeName != nil
    let headroom = MarcoAvPlayerEngine.potentialEdrHeadroom()
    let supportsHdr = headroom > 1.05
    return [
      "thermalState": MarcoAvPlayerEngine.thermalStateString(info.thermalState),
      "thermalStateCode": MarcoAvPlayerEngine.thermalStateCode(info.thermalState),
      "physicalMemoryBytes": Int64(info.physicalMemory),
      "processorCount": info.processorCount,
      "machineIdentifier": MarcoAvPlayerEngine.machineIdentifier(),
      "supportsHdrDisplay": supportsHdr,
      "potentialEdrHeadroom": headroom,
      "osVersion": UIDevice.current.systemVersion,
      "isPad": UIDevice.current.userInterfaceIdiom == .pad,
      "lowPowerMode": info.isLowPowerModeEnabled,
      "isPipSupported": AVPictureInPictureController.isPictureInPictureSupported(),
      "isPipPossible": pipController?.isPictureInPicturePossible ?? false,
      "isPipActive": pipController?.isPictureInPictureActive ?? false,
      "systemVolume": currentSystemVolume(),
      "isAirPlayActive": airPlayActive,
      "airPlayDeviceName": routeName ?? "",
    ]
  }

  private func emitTelemetrySnapshot() {
    var payload = buildTelemetryMap()
    payload["type"] = "telemetry"
    emitEvent(payload)
  }

  private func emitMediaEvent(_ payload: [String: Any]) {
    let dispatch: () -> Void = { [weak self] in
      guard let self = self, let mediaId = self.activeMediaId else { return }
      self.mediaEventSeq += 1
      var event = payload
      event["mediaId"] = mediaId
      event["eventSeq"] = self.mediaEventSeq
      self.eventSink?(event)
    }
    if Thread.isMainThread {
      dispatch()
    } else {
      DispatchQueue.main.async(execute: dispatch)
    }
  }

  private func emitEvent(_ payload: [String: Any]) {
    if Thread.isMainThread {
      eventSink?(payload)
    } else {
      DispatchQueue.main.async { [weak self] in
        self?.eventSink?(payload)
      }
    }
  }
}
