"""Deployment guard regression tests; these do not replace a device launch test."""
import plistlib
import re
import struct
import tempfile
import unittest
import xml.etree.ElementTree as ET
from unittest.mock import patch
import prepare_platform
from pathlib import Path
from patch_ios_ipa import validate_app


class DeploymentChecks(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.app = Path(self.folder.name)
        (self.app / 'Info.plist').write_bytes(plistlib.dumps({'MinimumOSVersion': '14.0'}))

    def binary(self, minimum, platform=2, filetype=2):
        return struct.pack('<8I', 0xfeedfacf, 0x100000c, 0, filetype, 1, 24, 0, 0) + struct.pack('<6I', 0x32, 24, platform, minimum, 0x1a0000, 0)

    def test_real_compatible_deployment_is_unchanged(self):
        for minos in (0x0d0000, 0x0e0000):
            blob = self.binary(minos)
            (self.app / 'Runner').write_bytes(blob)
            validate_app(self.app)
            self.assertEqual((self.app / 'Runner').read_bytes(), blob)

    def test_dsym_or_object_macho_rejected(self):
        for bad_type in (1, 10):
            (self.app / 'Runner').write_bytes(self.binary(0x0e0000, filetype=bad_type))
            with self.assertRaises(ValueError):
                validate_app(self.app)

    def test_new_engine_is_rejected_instead_of_forging_minimum(self):
        blob = self.binary(0x0f0000)
        (self.app / 'Runner').write_bytes(blob)
        with self.assertRaises(ValueError):
            validate_app(self.app)
        self.assertEqual((self.app / 'Runner').read_bytes(), blob)
        # Xcode 26 Liquid Glass build explicitly validates against iOS 15.0 floor.
        (self.app / 'Info.plist').write_bytes(plistlib.dumps({'MinimumOSVersion': '15.0'}))
        validate_app(self.app, max_min_ios='15.0')
        blob16 = self.binary(0x100000)
        (self.app / 'Runner').write_bytes(blob16)
        with self.assertRaises(ValueError):
            validate_app(self.app, max_min_ios='15.0')

    def test_simulator_binary_rejected(self):
        (self.app / 'Runner').write_bytes(self.binary(0x0e0000, 7))
        with self.assertRaises(ValueError):
            validate_app(self.app)

    def test_truncated_binary_rejected(self):
        (self.app / 'Runner').write_bytes(self.binary(0x0e0000)[:-4])
        with self.assertRaises(ValueError):
            validate_app(self.app)

    def test_empty_bundle_rejected(self):
        with self.assertRaises(ValueError):
            validate_app(self.app)

    def test_platform_settings_are_written_at_plist_root(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            runner = root / 'ios/Runner'
            runner.mkdir(parents=True)
            plist = runner / 'Info.plist'
            nested = {'UIApplicationSceneManifest': {'UIApplicationSupportsMultipleScenes': True}}
            plist.write_bytes(plistlib.dumps(nested))
            with patch.object(prepare_platform, 'ROOT', root):
                prepare_platform.main()
            result = plistlib.loads(plist.read_bytes())
            self.assertIn('NSLocalNetworkUsageDescription', result)
            self.assertTrue(result['NSAppTransportSecurity']['NSAllowsArbitraryLoads'])
            self.assertEqual(result['UIApplicationSceneManifest'], nested['UIApplicationSceneManifest'])
            self.assertIs(result['FlutterDeepLinkingEnabled'], False)
            for scheme in ('qklink', 'qkcloudlink', 'uclink', 'ucliteioslink', 'bdnetdisk', 'baiduyunipad', 'baiduboxapp', 'smartdrive', 'alipan', 'tbopen'):
                self.assertIn(scheme, result['LSApplicationQueriesSchemes'])
            url_types = result['CFBundleURLTypes']
            self.assertEqual(len([u for u in url_types if 'marcomovie' in u.get('CFBundleURLSchemes', [])]), 1)

    def test_ios_app_delegate_injects_wakelock_and_netdisk_auth_idempotently(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            runner = root / 'ios/Runner'
            runner.mkdir(parents=True)
            flutter_ios = root / 'ios/Flutter'
            flutter_ios.mkdir(parents=True)
            (flutter_ios / 'AppFrameworkInfo.plist').write_bytes(plistlib.dumps({'MinimumOSVersion': '14.0'}))
            (flutter_ios / 'Release.xcconfig').write_text('IPHONEOS_DEPLOYMENT_TARGET = 13.0\n', encoding='utf-8')
            xcodeproj = root / 'ios/Runner.xcodeproj'
            xcodeproj.mkdir(parents=True)
            (xcodeproj / 'project.pbxproj').write_text('IPHONEOS_DEPLOYMENT_TARGET = 13.0;\n', encoding='utf-8')
            (runner / 'Info.plist').write_bytes(plistlib.dumps({
                'MinimumOSVersion': '15.0',
                'UIBackgroundModes': ['fetch'],
            }))
            app_delegate = runner / 'AppDelegate.swift'
            app_delegate.write_text(
                'import Flutter\n'
                'import UIKit\n\n'
                '@main\n'
                '@objc class AppDelegate: FlutterAppDelegate {\n'
                '  override func application(\n'
                '    _ application: UIApplication,\n'
                '    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?\n'
                '  ) -> Bool {\n'
                '    GeneratedPluginRegistrant.register(with: self)\n'
                '    return super.application(application, didFinishLaunchingWithOptions: launchOptions)\n'
                '  }\n'
                '}\n',
                encoding='utf-8',
            )
            with patch.object(prepare_platform, 'ROOT', root):
                prepare_platform.main()
                prepare_platform.main()
                prepare_platform.main()
            swift = app_delegate.read_text(encoding='utf-8')
            self.assertEqual(swift.count('import WebKit'), 1)
            self.assertEqual(len(re.findall(r'(?m)^import AVKit$', swift)), 1)
            self.assertEqual(len(re.findall(r'(?m)^import AVFoundation$', swift)), 1)
            self.assertEqual(len(re.findall(r'(?m)^import MediaPlayer$', swift)), 1)
            self.assertEqual(swift.count('marco_movie/wakelock'), 1)
            self.assertEqual(swift.count('marco_movie/netdisk_auth'), 1)
            self.assertEqual(swift.count('"marco_movie/web_sniffer"'), 1)
            self.assertEqual(swift.count('"marco_movie/webview_js"'), 1)
            self.assertEqual(swift.count('MarcoLiquidGlassPlugin'), 1)
            self.assertEqual(swift.count('MarcoAvPlayerPlugin'), 1)
            self.assertEqual(swift.count('enum MarcoAvPlayerEngine'), 1)
            self.assertEqual(swift.count('"marco_movie/ios_avplayer"'), 1)
            self.assertEqual(swift.count('"marco_movie/ios_avplayer_view"'), 1)
            self.assertEqual(swift.count('private enum MarcoWebSnifferAndJsHostRegistrar'), 1)
            self.assertEqual(swift.count('private final class MarcoOffscreenWebJsHost'), 1)
            self.assertIn('AVPictureInPictureController', swift)
            self.assertIn('canStartPictureInPictureAutomaticallyFromInline', swift)
            self.assertIn('WKContentRuleList', swift)
            self.assertIn('WKScriptMessageHandlerWithReply', swift)
            self.assertEqual(swift.count('private enum MarcoLiquidGlassSupport'), 1)
            self.assertEqual(swift.count('"marco_movie/ios26_dock"'), 1)
            self.assertEqual(swift.count('"marco_movie/ios26_glass_button"'), 1)
            self.assertEqual(swift.count('"marco_movie/ios26_glass_pill"'), 1)
            self.assertEqual(swift.count('"marco_movie/ios26_segmented_control"'), 1)
            self.assertEqual(swift.count('"marco_movie/ios26_switch"'), 1)
            self.assertEqual(swift.count('"marco_movie/ios26_slider"'), 1)
            self.assertEqual(swift.count('final class MarcoNativeSwitchFactory'), 1)
            self.assertEqual(swift.count('final class MarcoNativeSliderFactory'), 1)
            self.assertEqual(swift.count('final class MarcoIos27RootTabChromeController'), 1)
            self.assertEqual(swift.count('final class MarcoIos27PassthroughChromeView'), 1)
            self.assertEqual(swift.count('final class MarcoIos27DockChromeView'), 1)
            self.assertEqual(swift.count('final class MarcoNativeGlassButtonControl'), 1)
            self.assertEqual(swift.count('static func withoutAnimations'), 1)
            self.assertEqual(swift.count('final class MarcoNativeFilterSheetController'), 1)
            self.assertEqual(swift.count('case "showFilterSheet":'), 1)
            self.assertEqual(swift.count('final class MarcoNativePinSheetController'), 1)
            self.assertEqual(swift.count('case "showPrivacyPin":'), 1)
            self.assertEqual(swift.count('case "configureRootTabChrome":'), 1)
            self.assertEqual(swift.count('case "setRootTabSelectedIndex":'), 1)
            self.assertEqual(swift.count('case "setRootTabMinimized":'), 1)
            self.assertEqual(swift.count('case "setRootTabVisible":'), 1)
            self.assertEqual(swift.count('case "showMenuAtRect":'), 1)
            self.assertEqual(swift.count('final class MarcoNativeLiquidTabCapsuleView'), 1)
            self.assertEqual(swift.count('final class MarcoAnimatedTabIconView'), 1)
            self.assertIn('UITabBarDelegate', swift)
            self.assertIn('UITabBarItem(', swift)
            self.assertIn('UIGlassContainerEffect()', swift)
            self.assertIn('UIButton.Configuration.glass()', swift)
            self.assertIn('UIButton.Configuration.prominentGlass()', swift)
            self.assertIn('cornerConfiguration = .capsule()', swift)
            self.assertIn('containerConcentric(', swift)
            self.assertIn('UISpringTimingParameters(duration: duration, bounce: bounce)', swift)
            self.assertIn('animateSpring(duration: 0.38, bounce: 0.16', swift)
            self.assertIn('addSymbolEffect(.bounce', swift)
            self.assertIn('UIScene.didActivateNotification', swift)
            self.assertIn('UIScene.willDeactivateNotification', swift)
            self.assertIn('final class MarcoTraitAwareHostView', swift)
            self.assertIn('static func adaptiveGlassForeground', swift)
            self.assertIn('static func isNearBlack', swift)
            self.assertNotIn('scaleX: 0.93', swift)
            self.assertNotIn('scaleX: 0.95', swift)
            self.assertNotIn('MarcoInteractiveCircleGlassControl', swift)
            self.assertNotIn('updateNativeGlassIntensity', swift)
            self.assertNotIn('UIScreen.main.bounds', swift)
            self.assertNotIn('UIScreen.main.scale', swift)
            self.assertEqual(
                [line for line in swift.splitlines() if not line.lstrip().startswith('//') and 'UIScreen.main' in line],
                [],
            )
            self.assertIn('static func activeWindowBounds', swift)
            self.assertEqual(swift.count('final class NetdiskWebAuthController'), 1)
            self.assertEqual(swift.count('private final class HeadlessMediaWebSniffer'), 1)
            self.assertEqual(swift.count('case "discoverBonjourDevices":'), 1)
            self.assertEqual(swift.count('private final class MarcoBonjourScanner'), 1)
            self.assertEqual(swift.count('{'), swift.count('}'))
            self.assertNotIn('@available(iOS 15.0, *)\nenum MarcoAvPlayerEngine', swift)
            self.assertIn('if #available(iOS 14.2, *)', swift)
            # Compact high-density popover & height-aligned dock / iPad portrait dock checks.
            self.assertIn('setNavigationBarHidden(true, animated: false)', swift)
            self.assertIn('return legacyTabCapsule', swift)
            self.assertIn('totalW > totalH && totalW >= 600.0', swift)
            plist = plistlib.loads((runner / 'Info.plist').read_bytes())
            self.assertIs(plist['UIRequiresFullScreen'], False)
            # Classic Flutter 3.38 AppDelegate runner without SceneDelegate.swift must NOT inject FlutterSceneDelegate
            self.assertNotIn('UIApplicationSceneManifest', plist)
            self.assertIn('audio', plist['UIBackgroundModes'])
            self.assertIn('fetch', plist['UIBackgroundModes'])
            self.assertEqual(plist['UIBackgroundModes'].count('audio'), 1)
            self.assertEqual(len([u for u in plist['CFBundleURLTypes'] if 'marcomovie' in u.get('CFBundleURLSchemes', [])]), 1)
            for svc in ('_marcomovie-cast._tcp', '_airplay._tcp', '_lelink._tcp', '_googlecast._tcp', '_dlna._tcp', '_upnp._tcp'):
                self.assertIn(svc, plist['NSBonjourServices'])
            app_fw_plist = plistlib.loads((flutter_ios / 'AppFrameworkInfo.plist').read_bytes())
            self.assertEqual(app_fw_plist['MinimumOSVersion'], '14.0')
            release_xc = (flutter_ios / 'Release.xcconfig').read_text(encoding='utf-8')
            self.assertIn('IPHONEOS_DEPLOYMENT_TARGET = 14.0', release_xc)
            self.assertIn('-Wl,-no_fixup_chains', release_xc)
            self.assertIn('-fno-objc-msgsend-selector-stubs', release_xc)
            self.assertIn('IPHONEOS_DEPLOYMENT_TARGET = 14.0;', (xcodeproj / 'project.pbxproj').read_text(encoding='utf-8'))

    def test_ios_uiscene_implicit_engine_template_for_iphone_duo_idempotently(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            runner = root / 'ios/Runner'
            runner.mkdir(parents=True)
            (runner / 'Info.plist').write_bytes(plistlib.dumps({'MinimumOSVersion': '15.0'}))
            (runner / 'SceneDelegate.swift').write_text(
                'import Flutter\nimport UIKit\n\nclass SceneDelegate: FlutterSceneDelegate {}\n',
                encoding='utf-8',
            )
            app_delegate = runner / 'AppDelegate.swift'
            app_delegate.write_text(
                'import Flutter\n'
                'import UIKit\n\n'
                '@main\n'
                '@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {\n'
                '  override func application(\n'
                '    _ application: UIApplication,\n'
                '    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?\n'
                '  ) -> Bool {\n'
                '    return super.application(application, didFinishLaunchingWithOptions: launchOptions)\n'
                '  }\n\n'
                '  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {\n'
                '    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)\n'
                '  }\n'
                '}\n',
                encoding='utf-8',
            )
            with patch.object(prepare_platform, 'ROOT', root):
                prepare_platform.main()
                prepare_platform.main()
            swift = app_delegate.read_text(encoding='utf-8')
            self.assertEqual(swift.count('MarcoNativeChannelRegistrar.register('), 1)
            self.assertIn('engineBridge.applicationRegistrar.messenger()', swift)
            self.assertEqual(swift.count('marco_movie/wakelock'), 1)
            self.assertEqual(swift.count('marco_movie/system_chrome'), 1)
            self.assertEqual(swift.count('marco_movie/netdisk_auth'), 1)
            self.assertEqual(swift.count('"marco_movie/web_sniffer"'), 1)
            self.assertEqual(swift.count('"marco_movie/webview_js"'), 1)
            self.assertEqual(swift.count('"marco_movie/ios_avplayer"'), 1)
            self.assertEqual(swift.count('MarcoLiquidGlassPlugin'), 1)
            self.assertEqual(swift.count('MarcoAvPlayerPlugin'), 1)
            self.assertIn('override func viewWillTransition(', swift)
            self.assertIn('override func viewSafeAreaInsetsDidChange()', swift)
            self.assertNotIn('UIScreen.main.bounds', swift)
            self.assertEqual(swift.count('{'), swift.count('}'))
            plist = plistlib.loads((runner / 'Info.plist').read_bytes())
            self.assertIs(plist['UIRequiresFullScreen'], False)
            self.assertEqual(plist['UILaunchStoryboardName'], 'LaunchScreen')
            scene_cfgs = plist['UIApplicationSceneManifest']['UISceneConfigurations']['UIWindowSceneSessionRoleApplication']
            self.assertEqual(scene_cfgs[0]['UISceneDelegateClassName'], '$(PRODUCT_MODULE_NAME).SceneDelegate')
            self.assertIn('UIInterfaceOrientationLandscapeLeft', plist['UISupportedInterfaceOrientations'])
            self.assertIn('UIInterfaceOrientationPortraitUpsideDown', plist['UISupportedInterfaceOrientations~ipad'])

    def test_trollstore_entitlements_include_multicast_for_dlna(self):
        import patch_ios_ipa
        src = Path(patch_ios_ipa.__file__).read_text(encoding='utf-8')
        self.assertIn('"com.apple.developer.networking.multicast": True', src)

    def test_macos_main_window_injects_wakelock_and_web_sniffer_idempotently(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            runner = root / 'macos/Runner'
            runner.mkdir(parents=True)
            window_swift = runner / 'MainFlutterWindow.swift'
            window_swift.write_text(
                'import Cocoa\n'
                'import FlutterMacOS\n\n'
                'class MainFlutterWindow: NSWindow {\n'
                '  override func awakeFromNib() {\n'
                '    let flutterViewController = FlutterViewController()\n'
                '    let windowFrame = self.frame\n'
                '    self.contentViewController = flutterViewController\n'
                '    self.setFrame(windowFrame, display: true)\n'
                '    RegisterGeneratedPlugins(registry: flutterViewController)\n'
                '    super.awakeFromNib()\n'
                '  }\n'
                '}\n',
                encoding='utf-8',
            )
            with patch.object(prepare_platform, 'ROOT', root):
                prepare_platform.main()
                prepare_platform.main()
            swift = window_swift.read_text(encoding='utf-8')
            self.assertEqual(swift.count('import WebKit'), 1)
            self.assertEqual(swift.count('marco_movie/wakelock'), 1)
            self.assertEqual(swift.count('marco_movie/web_sniffer'), 1)
            self.assertEqual(swift.count('private final class HeadlessMediaWebSniffer'), 1)
            self.assertEqual(swift.count('{'), swift.count('}'))

    def test_ios_round2_native_dock_and_capsule_and_hardware_telemetry_guards(self):
        liquid_src = (
            Path(__file__).resolve().parent / 'ios_native' / 'MarcoLiquidGlass.swift'
        ).read_text(encoding='utf-8')
        av_src = (
            Path(__file__).resolve().parent / 'ios_native' / 'MarcoAvPlayerEngine.swift'
        ).read_text(encoding='utf-8')

        # 1. Brace balance sanity
        self.assertEqual(liquid_src.count('{'), liquid_src.count('}'))
        self.assertEqual(av_src.count('{'), av_src.count('}'))

        # 2. Native tab capsule must NOT call super.touchesBegan/Moved/Ended/Cancelled
        #    (otherwise Dock taps & scrubs leak straight into FlutterView).
        capsule_start = liquid_src.index('final class MarcoNativeLiquidTabCapsuleView')
        capsule_end = liquid_src.index('final class MarcoIos27PassthroughChromeView')
        capsule_block = liquid_src[capsule_start:capsule_end]
        self.assertNotIn('super.touchesBegan(', capsule_block)
        self.assertNotIn('super.touchesMoved(', capsule_block)
        self.assertNotIn('super.touchesEnded(', capsule_block)
        self.assertNotIn('super.touchesCancelled(', capsule_block)
        self.assertIn('func setScrollCollapseProgress(', capsule_block)

        # 3. Single-line enforcement on native glass capsule buttons
        self.assertIn('cfg.titleLineBreakMode = .byTruncatingTail', liquid_src)
        self.assertIn('self.button.titleLabel?.numberOfLines = 1', liquid_src)

        # 4. Linear Search->Logo rotation + 4-tab roll-in morph
        self.assertIn('private func applyScrollMorph(', liquid_src)
        self.assertIn('CGAffineTransform(rotationAngle: searchAngle)', liquid_src)
        self.assertIn('CGAffineTransform(rotationAngle: logoAngle)', liquid_src)
        self.assertIn('CATransaction.setDisableActions(true)', liquid_src)

        # 5. Hardware telemetry fields in MarcoAvPlayerEngine (without UIScreen.main)
        self.assertIn('static func machineIdentifier() -> String', av_src)
        self.assertIn('"machineIdentifier":', av_src)
        self.assertIn('"processorCount":', av_src)
        self.assertIn('"supportsHdrDisplay":', av_src)
        self.assertNotIn('UIScreen.main', av_src)

        # 6. Root Dock / Logo overlay stays inside rootVC.view (so UIButton
        #    showsMenuAsPrimaryAction always has rootVC in its responder chain)
        #    while layer.zPosition = 1000 + bringRootChromeToFront() keep it
        #    above all dynamically mounted Flutter UiKitViews (e.g. Filter).
        self.assertIn('rootView.addSubview(overlayView)', liquid_src)
        self.assertIn('overlayView.layer.zPosition = 1000.0', liquid_src)
        self.assertIn('static func bringRootChromeToFront()', liquid_src)
        self.assertEqual(liquid_src.count('override func didMoveToWindow()'), 3)
        prepare_src = (
            Path(__file__).resolve().parent / 'prepare_platform.py'
        ).read_text(encoding='utf-8')
        self.assertIn('MarcoLiquidGlassSupport.bringRootChromeToFront()', prepare_src)

        # 7. Native Apple SF Symbols monochrome tab icons (no cartoonish multi-layer shapes)
        self.assertIn('return selected ? "house.fill" : "house"', liquid_src)
        self.assertIn('return selected ? "play.tv.fill" : "play.tv"', liquid_src)
        self.assertIn('return selected ? "rectangle.stack.fill" : "rectangle.stack"', liquid_src)
        self.assertIn('return selected ? "gearshape.fill" : "gearshape"', liquid_src)
        self.assertNotIn('liveBeaconRed', liquid_src)

        # 8. iOS 14-25 regression guard: bringRootChromeToFront must never lazily
        #    instantiate MarcoIos27RootTabChromeController or mount an unconfigured
        #    ghost dock overlay when isAvailable == false.
        self.assertNotIn(
            'static let shared = MarcoIos27RootTabChromeController()',
            liquid_src,
        )
        self.assertIn(
            'guard isAvailable, let controller = MarcoIos27RootTabChromeController.existingInstance else',
            liquid_src,
        )
        self.assertIn('private var isConfigured: Bool = false', liquid_src)
        # All 7 dock controller lifecycle/state methods guard against legacy OS
        # (`isAvailable`) and unconfigured state (`isConfigured`), and the 4
        # stateful mutators additionally reject stale/out-of-order bridge epochs
        # (`acceptEpoch`).
        ctrl_start = liquid_src.index(
            'private final class MarcoIos27RootTabChromeController: NSObject'
        )
        ctrl_end = liquid_src.index(
            'private final class MarcoNativeDockPlatformView: NSObject'
        )
        ctrl_block = liquid_src[ctrl_start:ctrl_end]
        self.assertIn('private func acceptEpoch(_ epoch: Int?) -> Bool', ctrl_block)
        self.assertEqual(
            ctrl_block.count('guard MarcoLiquidGlassSupport.isAvailable, isConfigured else'),
            3,
        )
        self.assertEqual(
            ctrl_block.count(
                'guard MarcoLiquidGlassSupport.isAvailable, isConfigured, acceptEpoch(epoch) else'
            ),
            4,
        )
        for method_sig in (
            'private func attachToRootIfNeeded()',
            'func bringToFrontIfNeeded()',
            'private func syncOverlayFrame()',
        ):
            idx = ctrl_block.find(method_sig)
            self.assertNotEqual(idx, -1, f'Missing dock lifecycle method: {method_sig}')
            snippet = ctrl_block[idx : idx + 180]
            self.assertIn('MarcoLiquidGlassSupport.isAvailable', snippet)
            self.assertIn('isConfigured', snippet)
        for method_sig in (
            'func setSelectedIndex(',
            'func setMinimized(',
            'func updateScrollMinimizeProgress(',
            'func setRootDockVisible(',
        ):
            idx = ctrl_block.find(method_sig)
            self.assertNotEqual(idx, -1, f'Missing dock mutator method: {method_sig}')
            snippet = ctrl_block[idx : idx + 240]
            self.assertIn('MarcoLiquidGlassSupport.isAvailable', snippet)
            self.assertIn('isConfigured', snippet)
            self.assertIn('acceptEpoch(epoch)', snippet)
        # Circle buttons on iOS 14 must scale cornerRadius to dockSize instead of hardcoding 31.0.
        self.assertNotIn('button.layer.cornerRadius = 31.0', liquid_src)
        self.assertIn('logoButton.layer.cornerRadius = dockSize * 0.5', liquid_src)
        self.assertIn('searchButton.layer.cornerRadius = dockSize * 0.5', liquid_src)
        # .unspecified trait style must resolve via == .dark rather than != .light.
        self.assertIn('v.traitCollection.userInterfaceStyle == .dark', liquid_src)
        self.assertIn('win.traitCollection.userInterfaceStyle == .dark', liquid_src)

    def test_ios_dock_context_menu_per_tab_preview_filter_sanitization_and_thermal_hook(self):
        liquid_src = (
            Path(__file__).resolve().parent / 'ios_native' / 'MarcoLiquidGlass.swift'
        ).read_text(encoding='utf-8')

        # 1. Dock long-press menu (0.7.9): the pressed tab never lifts / floats.
        #    iOS 17.4+ presents the tab UIMenu from an invisible ephemeral anchor
        #    button over the pressed slot via a plain long-press recognizer (no
        #    context-menu preview); iOS 15-17.3 keeps UIContextMenuInteraction
        #    but every preview targets an invisible 2pt clear dot.
        capsule_start = liquid_src.index('final class MarcoNativeLiquidTabCapsuleView')
        capsule_end = liquid_src.index('final class MarcoIos27PassthroughChromeView')
        capsule_block = liquid_src[capsule_start:capsule_end]
        self.assertNotIn('previewPillView', capsule_block)
        self.assertNotIn('UITargetedPreview(view: targetView', capsule_block)
        self.assertNotIn('params.shadowPath = pillPath', capsule_block)
        self.assertIn('if #available(iOS 17.4, *) {\n      // No UIContextMenuInteraction on iOS 17.4+', capsule_block)
        self.assertIn('UILongPressGestureRecognizer(', capsule_block)
        self.assertIn('action: #selector(handleTabMenuLongPress(_:))', capsule_block)
        self.assertIn('longPress.minimumPressDuration = 0.4', capsule_block)
        self.assertIn('longPress.cancelsTouchesInView = true', capsule_block)
        self.assertIn('@available(iOS 17.4, *)\n  private func presentTabMenuAnchored(at idx: Int)', capsule_block)
        self.assertIn('let anchorBtn = MarcoEphemeralMenuAnchorButton(type: .system)', capsule_block)
        self.assertIn('anchorBtn.alpha = 0.02', capsule_block)
        self.assertIn('anchorBtn.showsMenuAsPrimaryAction = true', capsule_block)
        self.assertIn('anchorBtn.performPrimaryAction()', capsule_block)
        self.assertIn('UIImpactFeedbackGenerator(style: .medium).impactOccurred()', capsule_block)
        self.assertIn('self?.onTabMenuAction?(idx, actionId)', capsule_block)
        self.assertIn('private func tearDownTabMenuAnchor()', capsule_block)
        self.assertIn('if let hit = hit, hit is MarcoEphemeralMenuAnchorButton {', capsule_block)
        self.assertIn('override func gestureRecognizerShouldBegin(', capsule_block)
        self.assertIn('override func willMove(toWindow newWindow: UIWindow?)', capsule_block)
        # Stale anchors are torn down on the next touch so taps never wedge.
        touches_began = capsule_block[capsule_block.index('override func touchesBegan('):]
        self.assertIn('tearDownTabMenuAnchor()', touches_began[:600])
        # Legacy (< 17.4) previews are invisible: clear 2pt dot, no shadow.
        self.assertIn('private func invisibleTabMenuPreview(for configuration: UIContextMenuConfiguration)', capsule_block)
        self.assertIn('params.backgroundColor = .clear', capsule_block)
        self.assertIn('params.shadowPath = UIBezierPath()', capsule_block)
        self.assertIn('UITargetedPreview(view: dot, parameters: params)', capsule_block)
        self.assertIn('highlightPreviewForItemWithIdentifier', capsule_block)
        self.assertIn('dismissalPreviewForItemWithIdentifier', capsule_block)
        self.assertIn('previewForHighlightingMenuWithConfiguration', capsule_block)
        self.assertIn('previewForDismissingMenuWithConfiguration', capsule_block)
        self.assertEqual(capsule_block.count('UIContextMenuInteraction(delegate: self)'), 1)
        self.assertIn('scrubbingLensShadowView.layer.removeAllAnimations()', capsule_block)
        # Root chrome forwards menu selections over the same channel call.
        self.assertIn('"rootTabMenuAction",\n        arguments: ["tabIndex": idx, "actionId": actionId]', liquid_src)

        # 1b. Dart: menu-triggered tab switches route through the canonical
        #     selection path so the Dock highlight follows the landed page.
        shell_src = (
            Path(__file__).resolve().parent / 'lib' / 'ui' / 'adaptive_shell.dart'
        ).read_text(encoding='utf-8')
        menu_start = shell_src.index('void _handleDockTabMenuAction(int tabIndex, String actionId)')
        menu_block = shell_src[menu_start : menu_start + 1600]
        self.assertIn('_handleRootNativeTabSelected(ownerTab);', menu_block)
        self.assertNotIn('_selectedTabIndexNotifier.value =', menu_block)
        self.assertIn("'top' || 'search' || 'switch_source' || 'refresh_home' => 0,", shell_src)
        owner_start = shell_src.index('static int? _dockMenuActionOwnerTab(String actionId)')
        owner_block = shell_src[owner_start : owner_start + 700]
        self.assertIn("'add_library'", owner_block)
        self.assertIn("'netdisk_accounts'", owner_block)
        self.assertIn("'ai_assistant' =>", owner_block)

        # 2. Native filter sheet rejects empty/invisible/empty-id/duplicate options.
        filter_start = liquid_src.index('final class MarcoNativeFilterSheetController')
        filter_block = liquid_src[filter_start : filter_start + 5500]
        self.assertIn('private static func cleanOptionLabel(', filter_block)
        self.assertIn('guard !id.isEmpty, label != "全部", seenCatIds.insert(id).inserted else { continue }', filter_block)

        # 3. Thermal pressure bridge for iPad Pro 2020 / iPadOS 15.4 & hot devices.
        self.assertIn('static var isThermalThrottled: Bool', liquid_src)
        self.assertIn('ProcessInfo.thermalStateDidChangeNotification', liquid_src)
        self.assertIn('"thermalStateChanged"', liquid_src)
        self.assertIn('"thermalThrottled": isThermalThrottled', liquid_src)
        self.assertEqual(liquid_src.count('{'), liquid_src.count('}'))

    def test_ios_storyboards_and_controller_use_adaptive_system_background(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            runner = root / 'ios/Runner'
            lproj = runner / 'Base.lproj'
            lproj.mkdir(parents=True)
            (runner / 'Info.plist').write_bytes(plistlib.dumps({'MinimumOSVersion': '14.0'}))
            main_sb = lproj / 'Main.storyboard'
            main_sb.write_text(
                '<?xml version="1.0" encoding="UTF-8" standalone="no"?>\n'
                '<document type="com.apple.InterfaceBuilder3.CocoaTouch.Storyboard.XIB" version="3.0" toolsVersion="10117" targetRuntime="iOS.CocoaTouch" initialViewController="BYZ-38-t0r">\n'
                '    <scenes>\n'
                '        <scene sceneID="tne-QT-ifu">\n'
                '            <objects>\n'
                '                <viewController id="BYZ-38-t0r" customClass="FlutterViewController" sceneMemberID="viewController">\n'
                '                    <view key="view" contentMode="scaleToFill" id="8bC-Xf-vdC">\n'
                '                        <color key="backgroundColor" white="1" alpha="1" colorSpace="custom" customColorSpace="calibratedWhite"/>\n'
                '                    </view>\n'
                '                </viewController>\n'
                '            </objects>\n'
                '        </scene>\n'
                '    </scenes>\n'
                '</document>\n',
                encoding='utf-8',
            )
            launch_sb = lproj / 'LaunchScreen.storyboard'
            launch_sb.write_text(
                '<?xml version="1.0" encoding="UTF-8" standalone="no"?>\n'
                '<document type="com.apple.InterfaceBuilder3.CocoaTouch.Storyboard.XIB" version="3.0" toolsVersion="12121" targetRuntime="iOS.CocoaTouch" launchScreen="YES" initialViewController="01J-lp-oVM">\n'
                '    <scenes>\n'
                '        <scene sceneID="EHf-IW-A2E">\n'
                '            <objects>\n'
                '                <viewController id="01J-lp-oVM" sceneMemberID="viewController">\n'
                '                    <view key="view" contentMode="scaleToFill" id="Ze5-6b-2t3">\n'
                '                        <color key="backgroundColor" red="1" green="1" blue="1" alpha="1" colorSpace="custom" customColorSpace="sRGB"/>\n'
                '                    </view>\n'
                '                </viewController>\n'
                '            </objects>\n'
                '        </scene>\n'
                '    </scenes>\n'
                '    <resources>\n'
                '        <image name="LaunchImage" width="168" height="185"/>\n'
                '    </resources>\n'
                '</document>\n',
                encoding='utf-8',
            )
            app_delegate = runner / 'AppDelegate.swift'
            app_delegate.write_text(
                'import Flutter\nimport UIKit\n\n'
                '@main\n@objc class AppDelegate: FlutterAppDelegate {\n'
                '  override func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {\n'
                '    GeneratedPluginRegistrant.register(with: self)\n'
                '    return super.application(application, didFinishLaunchingWithOptions: launchOptions)\n'
                '  }\n'
                '}\n',
                encoding='utf-8',
            )
            with patch.object(prepare_platform, 'ROOT', root):
                prepare_platform.main()
                prepare_platform.main()
            main_text = main_sb.read_text(encoding='utf-8')
            launch_text = launch_sb.read_text(encoding='utf-8')
            # Both storyboards remain valid XML and switch to adaptive systemBackgroundColor idempotently.
            ET.fromstring(main_text)
            ET.fromstring(launch_text)
            self.assertIn('customClass="MarcoFlutterViewController"', main_text)
            self.assertEqual(main_text.count('systemColor="systemBackgroundColor"'), 1)
            self.assertEqual(main_text.count('<systemColor name="systemBackgroundColor">'), 1)
            self.assertEqual(launch_text.count('systemColor="systemBackgroundColor"'), 1)
            self.assertEqual(launch_text.count('<systemColor name="systemBackgroundColor">'), 1)
            swift = app_delegate.read_text(encoding='utf-8')
            self.assertIn('view.backgroundColor = .systemBackground', swift)
            self.assertIn('window?.backgroundColor = .systemBackground', swift)

    def test_ios_prepare_platform_migrates_legacy_076_runner_and_is_idempotent(self):
        expected_shared_markers = (
            'stage=native_vc_view_did_appear',
            'func applyImmersiveMode(',
            'return marcoImmersiveMode ? [.top] : []',
            'private func acceptEpoch(_ epoch: Int?) -> Bool',
        )
        expected_variant_marker = {
            'self': 'stage=native_did_finish_launching',
            'engineBridge': 'stage=native_engine_plugin_register_start',
        }
        custom_helper = '  private func customDeveloperHook() -> String { return "keep-me" }\n'
        custom_between = 'private enum CustomBetweenDecl { static let v = 7 }'
        custom_tail = 'private enum CustomTailDecl { static let v = 9 }'
        stale_tail = (
            'private final class WeakScriptMessageHandler: NSObject {}\n'
            'final class NetdiskWebAuthController: UIViewController {}\n\n'
            '// MARK: - iOS WKWebView Rule Sniffer, WKContentRuleList Ad Blocker & Offscreen Async JS Host\n'
            'private enum MarcoWebSnifferAndJsHostRegistrar { static let legacy = true }\n\n'
            '// MARK: - iOS 14+ Native Low-Power AVPlayer Engine (PiP + AirPlay 2 + EDR/XDR + Thermal Telemetry)\n'
            'enum MarcoAvPlayerEngine { static let legacy = true }\n\n'
            '// MARK: - iOS 26 Native Liquid Glass Bridge (injected into AppDelegate.swift by prepare_platform.py)\n'
            'private enum MarcoLiquidGlassSupport { static let legacy = true }\n'
        )
        templates = {
            'self': (
                'import Flutter\nimport UIKit\n\n'
                '@main\n@objc class AppDelegate: FlutterAppDelegate {\n'
                f'{custom_helper}'
                '  override func application(\n'
                '    _ application: UIApplication,\n'
                '    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?\n'
                '  ) -> Bool {\n'
                '    GeneratedPluginRegistrant.register(with: self)\n'
                '    return super.application(application, didFinishLaunchingWithOptions: launchOptions)\n'
                '  }\n'
                '}\n'
            ),
            'engineBridge': (
                'import Flutter\nimport UIKit\n\n'
                '@main\n@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {\n'
                f'{custom_helper}'
                '  override func application(\n'
                '    _ application: UIApplication,\n'
                '    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?\n'
                '  ) -> Bool {\n'
                '    return super.application(application, didFinishLaunchingWithOptions: launchOptions)\n'
                '  }\n\n'
                '  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {\n'
                '    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)\n'
                '  }\n'
                '}\n'
            ),
        }
        legacy_076_templates = {
            'self': (
                'import Flutter\nimport UIKit\nimport AVFoundation\nimport WebKit\n\n'
                '@main\n@objc class AppDelegate: FlutterAppDelegate {\n'
                f'{custom_helper}'
                '  override func application(\n'
                '    _ application: UIApplication,\n'
                '    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?\n'
                '  ) -> Bool {\n'
                '    if #available(iOS 13.0, *) {\n'
                '      window?.backgroundColor = .systemBackground\n'
                '    }\n'
                '    GeneratedPluginRegistrant.register(with: self)\n'
                '    if let messenger = (window?.rootViewController as? FlutterViewController)?.binaryMessenger\n'
                '      ?? self.registrar(forPlugin: "MarcoChannelBridge")?.messenger() {\n'
                '      MarcoNativeChannelRegistrar.register(messenger: messenger, pluginRegistry: self)\n'
                '    }\n'
                '    return super.application(application, didFinishLaunchingWithOptions: launchOptions)\n'
                '  }\n'
                '}\n\n'
                'private enum MarcoNativeChannelRegistrar {\n'
                '  static func register(messenger: FlutterBinaryMessenger, pluginRegistry: FlutterPluginRegistry) {\n'
                '    let _ = (messenger, pluginRegistry)\n'
                '  }\n'
                '}\n\n'
                '@objc(MarcoFlutterViewController)\n'
                'final class MarcoFlutterViewController: FlutterViewController {\n'
                '  var marcoImmersiveMode: Bool = false\n'
                '  override var prefersHomeIndicatorAutoHidden: Bool {\n'
                '    return marcoImmersiveMode\n'
                '  }\n'
                '  override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge {\n'
                '    return marcoImmersiveMode ? [.top, .bottom] : []\n'
                '  }\n'
                '}\n\n'
                f'{stale_tail}'
            ),
            'engineBridge': (
                'import Flutter\nimport UIKit\nimport AVFoundation\nimport WebKit\n\n'
                '@main\n@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {\n'
                f'{custom_helper}'
                '  override func application(\n'
                '    _ application: UIApplication,\n'
                '    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?\n'
                '  ) -> Bool {\n'
                '    return super.application(application, didFinishLaunchingWithOptions: launchOptions)\n'
                '  }\n\n'
                '  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {\n'
                '    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)\n'
                '    MarcoNativeChannelRegistrar.register(\n'
                '      messenger: engineBridge.applicationRegistrar.messenger(),\n'
                '      pluginRegistry: engineBridge.pluginRegistry\n'
                '    )\n'
                '  }\n'
                '}\n\n'
                'private enum MarcoNativeChannelRegistrar {\n'
                '  static func register(messenger: FlutterBinaryMessenger, pluginRegistry: FlutterPluginRegistry) {\n'
                '    let _ = (messenger, pluginRegistry)\n'
                '  }\n'
                '}\n\n'
                '@objc(MarcoFlutterViewController)\n'
                'final class MarcoFlutterViewController: FlutterViewController {\n'
                '  var marcoImmersiveMode: Bool = false\n'
                '  override var prefersHomeIndicatorAutoHidden: Bool {\n'
                '    return marcoImmersiveMode\n'
                '  }\n'
                '  override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge {\n'
                '    return marcoImmersiveMode ? [.top, .bottom] : []\n'
                '  }\n'
                '}\n\n'
                f'{stale_tail}'
            ),
        }

        def run_prepare(initial_swift: str, times: int) -> str:
            with tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                runner = root / 'ios/Runner'
                runner.mkdir(parents=True)
                (runner / 'Info.plist').write_bytes(plistlib.dumps({'MinimumOSVersion': '14.0'}))
                app_delegate = runner / 'AppDelegate.swift'
                app_delegate.write_text(initial_swift, encoding='utf-8')
                with patch.object(prepare_platform, 'ROOT', root):
                    for _ in range(times):
                        prepare_platform.main()
                return app_delegate.read_text(encoding='utf-8')

        for variant in ('self', 'engineBridge'):
            clean_once = run_prepare(templates[variant], 1)
            clean_twice = run_prepare(templates[variant], 2)
            upgraded_once = run_prepare(legacy_076_templates[variant], 1)
            upgraded_twice = run_prepare(legacy_076_templates[variant], 2)

            self.assertEqual(clean_once, clean_twice, f'Clean run not idempotent ({variant})')
            self.assertEqual(upgraded_once, upgraded_twice, f'Upgrade run not idempotent ({variant})')
            self.assertEqual(clean_twice, upgraded_twice, f'Upgrade diverged from clean ({variant})')
            for marker in (*expected_shared_markers, expected_variant_marker[variant]):
                self.assertIn(marker, upgraded_twice, f'Missing {marker} in {variant}')
            self.assertNotIn('static let legacy = true', upgraded_twice)
            self.assertIn(custom_helper.strip(), upgraded_twice)
            self.assertEqual(upgraded_twice.count('final class MarcoFlutterViewController:'), 1)
            self.assertEqual(upgraded_twice.count('private enum MarcoNativeChannelRegistrar'), 1)
            self.assertNotIn('[.top, .bottom]', upgraded_twice)
            self.assertEqual(upgraded_twice.count('{'), upgraded_twice.count('}'))

            # Developer declarations placed between generated sections or at EOF must survive upgrades.
            with_between = legacy_076_templates[variant].replace(
                '// MARK: - iOS 14+ Native Low-Power AVPlayer Engine',
                f'{custom_between}\n\n// MARK: - iOS 14+ Native Low-Power AVPlayer Engine',
                1,
            )
            with_tail = legacy_076_templates[variant].rstrip() + f'\n\n{custom_tail}\n'
            migrated_between = run_prepare(with_between, 2)
            migrated_tail = run_prepare(with_tail, 2)
            self.assertEqual(migrated_between.count(custom_between), 1)
            self.assertEqual(migrated_tail.count(custom_tail), 1)

            # Custom registration statements—including multiline nested `if` blocks with
            # their own closing `}`—after GeneratedPluginRegistrant or inside the classic
            # messenger block must survive upgrades with balanced AppDelegate braces and
            # without duplicating MarcoNativeChannelRegistrar.register(...).
            user_log = 'NSLog("User app metrics ready")'
            nested_if = (
                'if ProcessInfo.processInfo.isLowPowerModeEnabled {\n'
                '      NSLog("User low-power startup")\n'
                '    }'
            )
            if variant == 'self':
                after_plugin = legacy_076_templates[variant].replace(
                    'GeneratedPluginRegistrant.register(with: self)\n',
                    f'GeneratedPluginRegistrant.register(with: self)\n    {user_log}\n',
                    1,
                )
                inside_if = legacy_076_templates[variant].replace(
                    '      MarcoNativeChannelRegistrar.register(',
                    f'      {user_log}\n      MarcoNativeChannelRegistrar.register(',
                    1,
                )
                nested_after_plugin = legacy_076_templates[variant].replace(
                    'GeneratedPluginRegistrant.register(with: self)\n',
                    f'GeneratedPluginRegistrant.register(with: self)\n    {nested_if}\n',
                    1,
                )
                nested_inside_if = legacy_076_templates[variant].replace(
                    '      MarcoNativeChannelRegistrar.register(',
                    '      if ProcessInfo.processInfo.isLowPowerModeEnabled {\n'
                    '        NSLog("User low-power startup")\n'
                    '      }\n'
                    '      MarcoNativeChannelRegistrar.register(',
                    1,
                )
                for label, src, expected_needle in (
                    ('after-plugin', after_plugin, user_log),
                    ('inside-if', inside_if, user_log),
                    ('nested-after-plugin', nested_after_plugin, 'NSLog("User low-power startup")'),
                    ('nested-inside-if', nested_inside_if, 'NSLog("User low-power startup")'),
                ):
                    up1 = run_prepare(src, 1)
                    up2 = run_prepare(src, 2)
                    self.assertEqual(up1, up2, f'Custom registration not idempotent ({variant}:{label})')
                    self.assertEqual(
                        up2.count('MarcoNativeChannelRegistrar.register('),
                        1,
                        f'Duplicated native registrar ({variant}:{label})',
                    )
                    self.assertEqual(
                        up2.count(expected_needle),
                        1,
                        f'Lost custom user statement ({variant}:{label})',
                    )
                    app_open = up2.find('{', up2.find('class AppDelegate:'))
                    self.assertNotEqual(
                        prepare_platform._find_swift_brace_block_end(up2, app_open, '{', '}'),
                        -1,
                        f'Unbalanced AppDelegate braces ({variant}:{label})',
                    )
                    self.assertEqual(up2.count('{'), up2.count('}'))
            else:
                after_plugin = legacy_076_templates[variant].replace(
                    'GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)\n',
                    f'GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)\n    {user_log}\n',
                    1,
                )
                nested_after_plugin = legacy_076_templates[variant].replace(
                    'GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)\n',
                    f'GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)\n    {nested_if}\n',
                    1,
                )
                for label, src, expected_needle in (
                    ('after-plugin', after_plugin, user_log),
                    ('nested-after-plugin', nested_after_plugin, 'NSLog("User low-power startup")'),
                ):
                    up1 = run_prepare(src, 1)
                    up2 = run_prepare(src, 2)
                    self.assertEqual(up1, up2, f'Custom registration not idempotent ({variant}:{label})')
                    self.assertEqual(up2.count('MarcoNativeChannelRegistrar.register('), 1)
                    self.assertEqual(up2.count(expected_needle), 1)
                    app_open = up2.find('{', up2.find('class AppDelegate:'))
                    self.assertNotEqual(
                        prepare_platform._find_swift_brace_block_end(up2, app_open, '{', '}'),
                        -1,
                        f'Unbalanced AppDelegate braces ({variant}:{label})',
                    )
                    self.assertEqual(up2.count('{'), up2.count('}'))

        # R3 P1-2: Preserve local variable scope & exact statement ordering in both
        # classic (`if let messenger` with scoped `let phaseName`) and `engineBridge`
        # (early `return` before `MarcoNativeChannelRegistrar.register`) shapes.
        scoped_classic = legacy_076_templates['self'].replace(
            '      MarcoNativeChannelRegistrar.register(messenger: messenger, pluginRegistry: self)\n'
            '    }\n'
            '    return super.application(application, didFinishLaunchingWithOptions: launchOptions)',
            '      let phaseName = "channel.ready"\n'
            '      NSLog("%@", phaseName)\n'
            '      MarcoNativeChannelRegistrar.register(messenger: messenger, pluginRegistry: self)\n'
            '    }\n'
            '    let phaseName = "application.ready"\n'
            '    NSLog("%@", phaseName)\n'
            '    return super.application(application, didFinishLaunchingWithOptions: launchOptions)',
            1,
        )
        classic_up1 = run_prepare(scoped_classic, 1)
        classic_up2 = run_prepare(scoped_classic, 2)
        self.assertEqual(classic_up1, classic_up2)
        self.assertEqual(classic_up2.count('MarcoNativeChannelRegistrar.register('), 1)
        if_idx = classic_up2.find('if let messenger =')
        if_open = classic_up2.find('{', if_idx)
        if_close = prepare_platform._find_swift_brace_block_end(classic_up2, if_open, '{', '}')
        self.assertNotEqual(if_close, -1)
        if_body = classic_up2[if_open:if_close]
        self.assertIn('let phaseName = "channel.ready"', if_body)
        self.assertLess(
            if_body.find('let phaseName = "channel.ready"'),
            if_body.find('MarcoNativeChannelRegistrar.register('),
        )
        self.assertIn('let phaseName = "application.ready"', classic_up2[if_close:])
        self.assertNotIn('let phaseName = "channel.ready"', classic_up2[if_close:])

        ordered_engine = legacy_076_templates['engineBridge'].replace(
            'GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)\n',
            'GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)\n'
            '    if ProcessInfo.processInfo.isLowPowerModeEnabled { return }\n',
            1,
        )
        eng_up1 = run_prepare(ordered_engine, 1)
        eng_up2 = run_prepare(ordered_engine, 2)
        self.assertEqual(eng_up1, eng_up2)
        self.assertEqual(eng_up2.count('MarcoNativeChannelRegistrar.register('), 1)
        self.assertLess(
            eng_up2.find('if ProcessInfo.processInfo.isLowPowerModeEnabled { return }'),
            eng_up2.find('MarcoNativeChannelRegistrar.register('),
        )

        # R4 P1-2: Preserve chained `else` / `else if` clauses attached directly to
        # `if let messenger { ... }` (never swallowing `else {` into a line comment),
        # and avoid colliding with user-authored method-scope `let rootFlutterVC`.
        else_only_classic = legacy_076_templates['self'].replace(
            '      MarcoNativeChannelRegistrar.register(messenger: messenger, pluginRegistry: self)\n'
            '    }\n',
            '      MarcoNativeChannelRegistrar.register(messenger: messenger, pluginRegistry: self)\n'
            '    } else if ProcessInfo.processInfo.isLowPowerModeEnabled {\n'
            '      NSLog("custom: low power fallback")\n'
            '    } else {\n'
            '      NSLog("custom: messenger unavailable")\n'
            '    }\n',
            1,
        )
        else_with_body_classic = else_only_classic.replace(
            '      MarcoNativeChannelRegistrar.register(',
            '      NSLog("custom: messenger ready")\n      MarcoNativeChannelRegistrar.register(',
            1,
        )
        for label, src in (
            ('else-only', else_only_classic),
            ('else-with-body', else_with_body_classic),
        ):
            e1 = run_prepare(src, 1)
            e2 = run_prepare(src, 2)
            self.assertEqual(e1, e2, f'Else-chain upgrade not idempotent ({label})')
            self.assertEqual(e2.count('MarcoNativeChannelRegistrar.register('), 1)
            self.assertIn('} else if ProcessInfo.processInfo.isLowPowerModeEnabled {', e2)
            self.assertIn('} else {\n      NSLog("custom: messenger unavailable")\n    }', e2)
            self.assertNotIn('MARCO_GENERATED_END: ios_registration else', e2)
            self.assertNotIn('MARCO_GENERATED_END: ios_self_post_register else', e2)
            self.assertLess(
                e2.find('NSLog("custom: messenger unavailable")'),
                e2.find('stage=native_plugins_registered'),
            )
            self.assertEqual(e2.count('{'), e2.count('}'))

        for pos_label, src in (
            (
                'after-messenger',
                legacy_076_templates['self'].replace(
                    '    return super.application',
                    '    let rootFlutterVC = window?.rootViewController as? FlutterViewController\n'
                    '    rootFlutterVC?.view.accessibilityIdentifier = "root-player-view"\n'
                    '    return super.application',
                    1,
                ),
            ),
            (
                'before-messenger',
                legacy_076_templates['self'].replace(
                    '    GeneratedPluginRegistrant.register(with: self)\n',
                    '    GeneratedPluginRegistrant.register(with: self)\n'
                    '    let rootFlutterVC = window?.rootViewController as? FlutterViewController\n'
                    '    rootFlutterVC?.view.accessibilityIdentifier = "root-player-view"\n',
                    1,
                ),
            ),
        ):
            r1 = run_prepare(src, 1)
            r2 = run_prepare(src, 2)
            self.assertEqual(r1, r2, f'rootFlutterVC upgrade not idempotent ({pos_label})')
            self.assertEqual(
                len(re.findall(r'^[ \t]*let rootFlutterVC\s*=', r2, re.MULTILINE)),
                1,
                f'Expected exactly 1 user rootFlutterVC declaration ({pos_label})',
            )
            self.assertIn('rootFlutterVC?.view.accessibilityIdentifier = "root-player-view"', r2)
            self.assertEqual(r2.count('{'), r2.count('}'))

        # R5 P1-3: Comments between `}` and `else` must not break the `if / else`
        # chain, and independent user methods using `rootFlutterVC` must remain
        # verbatim across repeat upgrades with split markers.
        comment_else_classic = legacy_076_templates['self'].replace(
            '      MarcoNativeChannelRegistrar.register(messenger: messenger, pluginRegistry: self)\n'
            '    }\n',
            '      MarcoNativeChannelRegistrar.register(messenger: messenger, pluginRegistry: self)\n'
            '    } // Keep normal launch available before the engine attaches.\n'
            '    /* block note */ else {\n'
            '      NSLog("channel not ready")\n'
            '    }\n',
            1,
        )
        ce1 = run_prepare(comment_else_classic, 1)
        ce2 = run_prepare(comment_else_classic, 2)
        self.assertEqual(ce1, ce2)
        if_open = ce2.find('{', ce2.find('if let messenger'))
        if_close = prepare_platform._find_swift_brace_block_end(ce2, if_open, '{', '}')
        else_idx = ce2.find('else {\n      NSLog("channel not ready")', if_close)
        self.assertNotEqual(else_idx, -1)
        gap_lines = [
            line.strip()
            for line in ce2[if_close:else_idx].splitlines()
            if line.strip() and not line.strip().startswith('//') and not line.strip().startswith('/*')
        ]
        self.assertEqual(gap_lines, [])
        self.assertLess(else_idx, ce2.find('stage=native_plugins_registered'))

        analytics_helper = (
            '  private func notifyAnalytics() {\n'
            '    let rootFlutterVC = window?.rootViewController as? FlutterViewController\n'
            '    if let messenger = rootFlutterVC?.binaryMessenger {\n'
            '      let channel = FlutterMethodChannel(name: "analytics", binaryMessenger: messenger)\n'
            '      channel.invokeMethod("ready", arguments: nil)\n'
            '    }\n'
            '  }\n\n'
        )
        helper_scoped_classic = legacy_076_templates['self'].replace(
            '  override func application(',
            analytics_helper + '  override func application(',
            1,
        ).replace(
            '      MarcoNativeChannelRegistrar.register(',
            '      NSLog("app: messenger ready")\n      MarcoNativeChannelRegistrar.register(',
            1,
        )
        hs1 = run_prepare(helper_scoped_classic, 1)
        hs2 = run_prepare(helper_scoped_classic, 2)
        self.assertEqual(hs1, hs2)
        h_start = hs2.index('private func notifyAnalytics()')
        h_body = hs2[h_start : prepare_platform._find_swift_brace_block_end(hs2, hs2.index('{', h_start), '{', '}')]
        self.assertIn('if let messenger = rootFlutterVC?.binaryMessenger', h_body)
        self.assertNotIn('marcoRootFlutterVC', h_body)

        # R6 P1-2: Classic Runner using a Flutter child of a UIKit container
        # (both `embeddedController` and user-declared `rootFlutterVC`) must
        # preserve the selected child messenger source AND pass that child as
        # `controller:` without emitting an unused `marcoRootFlutterVC` binding,
        # identically across repeat runs.
        for child_var in ('embeddedController', 'rootFlutterVC'):
            embedded_classic = legacy_076_templates['self'].replace(
                '    if let messenger = (window?.rootViewController as? FlutterViewController)?.binaryMessenger\n'
                '      ?? self.registrar(forPlugin: "MarcoChannelBridge")?.messenger() {',
                '    let navigation = window?.rootViewController as? UINavigationController\n'
                f'    let {child_var} = navigation?.topViewController as? FlutterViewController\n'
                f'    if let messenger = {child_var}?.binaryMessenger {{',
                1,
            )
            em1 = run_prepare(embedded_classic, 1)
            em2 = run_prepare(embedded_classic, 2)
            self.assertEqual(em1, em2, f'Embedded child upgrade not idempotent ({child_var})')
            app_start = em2.index('class AppDelegate')
            app_body = em2[
                app_start : prepare_platform._find_swift_brace_block_end(
                    em2, em2.index('{', app_start), '{', '}'
                )
            ]
            self.assertIn(f'if let messenger = {child_var}?.binaryMessenger {{', app_body)
            self.assertIn(f'controller: {child_var}', app_body)
            self.assertNotIn('marcoRootFlutterVC', app_body)
            self.assertEqual(app_body.count('MarcoNativeChannelRegistrar.register('), 1)
            self.assertEqual(em2.count('{'), em2.count('}'))

        # R7 P1-2: Decouple messenger source from controller argument so a
        # FlutterEngine messenger (`activeEngine?.binaryMessenger`) is preserved
        # verbatim and NEVER passed to `controller: FlutterViewController?`,
        # while a proved FlutterViewController child continues to be passed.
        for msg_source, expect_ctrl in (
            ('embeddedController', 'controller: embeddedController'),
            ('activeEngine', None),
        ):
            engine_classic = legacy_076_templates['self'].replace(
                '    if let messenger = (window?.rootViewController as? FlutterViewController)?.binaryMessenger\n'
                '      ?? self.registrar(forPlugin: "MarcoChannelBridge")?.messenger() {',
                '    let navigation = window?.rootViewController as? UINavigationController\n'
                '    let embeddedController = navigation?.topViewController as? FlutterViewController\n'
                '    let activeEngine: FlutterEngine? = embeddedController?.engine\n'
                f'    if let messenger = {msg_source}?.binaryMessenger {{',
                1,
            )
            eng1 = run_prepare(engine_classic, 1)
            eng2 = run_prepare(engine_classic, 2)
            self.assertEqual(eng1, eng2, f'Engine messenger upgrade not idempotent ({msg_source})')
            app_start = eng2.index('class AppDelegate')
            app_body = eng2[
                app_start : prepare_platform._find_swift_brace_block_end(
                    eng2, eng2.index('{', app_start), '{', '}'
                )
            ]
            self.assertIn(f'if let messenger = {msg_source}?.binaryMessenger {{', app_body)
            self.assertNotIn('controller: activeEngine', app_body)
            self.assertNotIn('marcoRootFlutterVC', app_body)
            if expect_ctrl is not None:
                self.assertIn(expect_ctrl, app_body)
            else:
                self.assertNotIn('controller:', app_body)
            self.assertEqual(app_body.count('MarcoNativeChannelRegistrar.register('), 1)
            self.assertEqual(eng2.count('{'), eng2.count('}'))

        # R8 P1-1: Verify the FINAL/outermost type of the full receiver expression
        # (never matching an intermediate `as? FlutterViewController` cast when
        # chained with `.engine` in inferred locals, multiline chains, constructor
        # chains, or inline `if let messenger = (... as? FlutterViewController)?.engine?.binaryMessenger`).
        r8_receiver_cases = (
            (
                'inferred-vc',
                '    let navigation = window?.rootViewController as? UINavigationController\n'
                '    let receiver = (navigation?.topViewController as? FlutterViewController)\n'
                '    if let messenger = receiver?.binaryMessenger {',
                'if let messenger = receiver?.binaryMessenger {',
                'controller: receiver',
            ),
            (
                'annotated-engine',
                '    let navigation = window?.rootViewController as? UINavigationController\n'
                '    let receiver: FlutterEngine? = (navigation?.topViewController as? FlutterViewController)?.engine\n'
                '    if let messenger = receiver?.binaryMessenger {',
                'if let messenger = receiver?.binaryMessenger {',
                None,
            ),
            (
                'inferred-engine',
                '    let navigation = window?.rootViewController as? UINavigationController\n'
                '    let receiver = (navigation?.topViewController as? FlutterViewController)?.engine\n'
                '    if let messenger = receiver?.binaryMessenger {',
                'if let messenger = receiver?.binaryMessenger {',
                None,
            ),
            (
                'multiline-engine',
                '    let navigation = window?.rootViewController as? UINavigationController\n'
                '    let receiver = (navigation?.topViewController as? FlutterViewController)\n'
                '      ?.engine\n'
                '    if let messenger = receiver?.binaryMessenger {',
                'if let messenger = receiver?.binaryMessenger {',
                None,
            ),
            (
                'inline-engine',
                '    let navigation = window?.rootViewController as? UINavigationController\n'
                '    if let messenger = (navigation?.topViewController as? FlutterViewController)?.engine?.binaryMessenger {',
                'if let messenger = (navigation?.topViewController as? FlutterViewController)?.engine?.binaryMessenger {',
                None,
            ),
            (
                'ctor-engine',
                '    let receiver = FlutterViewController(project: nil, nibName: nil, bundle: nil).engine\n'
                '    if let messenger = receiver?.binaryMessenger {',
                'if let messenger = receiver?.binaryMessenger {',
                None,
            ),
        )
        for case_name, replacement_snippet, expected_messenger_line, expected_ctrl in r8_receiver_cases:
            src = legacy_076_templates['self'].replace(
                '    if let messenger = (window?.rootViewController as? FlutterViewController)?.binaryMessenger\n'
                '      ?? self.registrar(forPlugin: "MarcoChannelBridge")?.messenger() {',
                replacement_snippet,
                1,
            )
            r8_up1 = run_prepare(src, 1)
            r8_up2 = run_prepare(src, 2)
            self.assertEqual(r8_up1, r8_up2, f'R8 receiver upgrade not idempotent ({case_name})')
            app_start = r8_up2.index('class AppDelegate')
            app_body = r8_up2[
                app_start : prepare_platform._find_swift_brace_block_end(
                    r8_up2, r8_up2.index('{', app_start), '{', '}'
                )
            ]
            self.assertIn(expected_messenger_line, app_body, f'Messenger line lost ({case_name})')
            self.assertNotIn('marcoRootFlutterVC', app_body, f'Unexpected marcoRootFlutterVC ({case_name})')
            if expected_ctrl is not None:
                self.assertIn(expected_ctrl, app_body, f'Expected {expected_ctrl} ({case_name})')
            else:
                self.assertNotIn('controller:', app_body, f'Unexpected controller: arg ({case_name})')
            self.assertEqual(app_body.count('MarcoNativeChannelRegistrar.register('), 1)
            self.assertEqual(r8_up2.count('{'), r8_up2.count('}'))

        # R9 P1-1: Strip Swift comments per physical line (and ignore closed
        # inner-scope shadow declarations) so a trailing `//` comment on the
        # cast line followed by `.flatMap { child -> FlutterEngine? in child.engine }`
        # never drops the continuation chain and mis-emits `controller: receiver`.
        r9_commented_cases = (
            (
                'child-control',
                '    let navigation = window?.rootViewController as? UINavigationController\n'
                '    let receiver = (navigation?.topViewController as? FlutterViewController)\n'
                '    if let messenger = receiver?.binaryMessenger {',
                'controller: receiver',
            ),
            (
                'engine-no-comment',
                '    let navigation = window?.rootViewController as? UINavigationController\n'
                '    let receiver = (navigation?.topViewController as? FlutterViewController)\n'
                '        .flatMap { child -> FlutterEngine? in child.engine }\n'
                '    if let messenger = receiver?.binaryMessenger {',
                None,
            ),
            (
                'engine-line-comment',
                '    let navigation = window?.rootViewController as? UINavigationController\n'
                '    let receiver = (navigation?.topViewController as? FlutterViewController) // Use the visible Flutter child.\n'
                '        .flatMap { child -> FlutterEngine? in child.engine }\n'
                '    if let messenger = receiver?.binaryMessenger {',
                None,
            ),
            (
                'engine-type-control',
                '    let navigation = window?.rootViewController as? UINavigationController\n'
                '    let receiver: FlutterEngine? = (navigation?.topViewController as? FlutterViewController) // Use the visible Flutter child.\n'
                '        .flatMap { child -> FlutterEngine? in child.engine }\n'
                '    if let messenger = receiver?.binaryMessenger {',
                None,
            ),
            (
                'dead-inner-shadow',
                '    let navigation = window?.rootViewController as? UINavigationController\n'
                '    let receiver: FlutterEngine? = (navigation?.topViewController as? FlutterViewController)?.engine\n'
                '    if ProcessInfo.processInfo.isLowPowerModeEnabled {\n'
                '      let receiver = navigation?.topViewController as? FlutterViewController\n'
                '      NSLog("%@", String(describing: receiver))\n'
                '    }\n'
                '    if let messenger = receiver?.binaryMessenger {',
                None,
            ),
        )
        for case_name, replacement_snippet, expected_ctrl in r9_commented_cases:
            src = legacy_076_templates['self'].replace(
                '    if let messenger = (window?.rootViewController as? FlutterViewController)?.binaryMessenger\n'
                '      ?? self.registrar(forPlugin: "MarcoChannelBridge")?.messenger() {',
                replacement_snippet,
                1,
            )
            r9_up1 = run_prepare(src, 1)
            r9_up2 = run_prepare(src, 2)
            self.assertEqual(r9_up1, r9_up2, f'R9 commented chain not idempotent ({case_name})')
            app_start = r9_up2.index('class AppDelegate')
            app_body = r9_up2[
                app_start : prepare_platform._find_swift_brace_block_end(
                    r9_up2, r9_up2.index('{', app_start), '{', '}'
                )
            ]
            self.assertIn('if let messenger = receiver?.binaryMessenger {', app_body)
            self.assertNotIn('marcoRootFlutterVC', app_body)
            if expected_ctrl is not None:
                self.assertIn(expected_ctrl, app_body, f'Expected {expected_ctrl} ({case_name})')
            else:
                self.assertNotIn('controller:', app_body, f'Unexpected controller: arg ({case_name})')
            self.assertEqual(app_body.count('MarcoNativeChannelRegistrar.register('), 1)
            self.assertEqual(r9_up2.count('{'), r9_up2.count('}'))

        # R10 P1: Ended conditional/loop bindings (`if let receiver = ... { ... }`,
        # `else if let receiver`, `while let receiver`) must be scoped strictly to
        # their closed block and never shadow an outer `let receiver: FlutterEngine?`,
        # while active `guard let receiver = ... else { return false }` and genuine
        # `FlutterViewController` bindings remain recognized.
        outer_engine = '    let receiver: FlutterEngine? = (navigation?.topViewController as? FlutterViewController)?.engine\n'
        r10_scope_cases = (
            (
                'engine-alone',
                '    let navigation = window?.rootViewController as? UINavigationController\n'
                + outer_engine
                + '    if let messenger = receiver?.binaryMessenger {',
                None,
            ),
            (
                'if-sibling-name',
                '    let navigation = window?.rootViewController as? UINavigationController\n'
                + outer_engine
                + '    if let visibleChild = navigation?.topViewController as? FlutterViewController {\n'
                '      NSLog("%@", visibleChild.description)\n'
                '    }\n'
                '    if let messenger = receiver?.binaryMessenger {',
                None,
            ),
            (
                'if-same-name',
                '    let navigation = window?.rootViewController as? UINavigationController\n'
                + outer_engine
                + '    if let receiver = navigation?.topViewController as? FlutterViewController {\n'
                '      NSLog("%@", receiver.description)\n'
                '    }\n'
                '    if let messenger = receiver?.binaryMessenger {',
                None,
            ),
            (
                'else-if-same-name',
                '    let navigation = window?.rootViewController as? UINavigationController\n'
                + outer_engine
                + '    if ProcessInfo.processInfo.isLowPowerModeEnabled {\n'
                '      NSLog("low power")\n'
                '    } else if let receiver = navigation?.topViewController as? FlutterViewController {\n'
                '      NSLog("%@", receiver.description)\n'
                '    }\n'
                '    if let messenger = receiver?.binaryMessenger {',
                None,
            ),
            (
                'if-actual-vc',
                '    let navigation = window?.rootViewController as? UINavigationController\n'
                '    let receiver = (navigation?.topViewController as? FlutterViewController)\n'
                '    if let visibleChild = navigation?.topViewController as? FlutterViewController {\n'
                '      NSLog("%@", visibleChild.description)\n'
                '    }\n'
                '    if let messenger = receiver?.binaryMessenger {',
                'controller: receiver',
            ),
            (
                'guard-actual-vc',
                '    let navigation = window?.rootViewController as? UINavigationController\n'
                '    guard let receiver = navigation?.topViewController as? FlutterViewController else {\n'
                '      return super.application(application, didFinishLaunchingWithOptions: launchOptions)\n'
                '    }\n'
                '    if let messenger = receiver?.binaryMessenger {',
                'controller: receiver',
            ),
        )
        for case_name, replacement_snippet, expected_ctrl in r10_scope_cases:
            src = legacy_076_templates['self'].replace(
                '    if let messenger = (window?.rootViewController as? FlutterViewController)?.binaryMessenger\n'
                '      ?? self.registrar(forPlugin: "MarcoChannelBridge")?.messenger() {',
                replacement_snippet,
                1,
            )
            r10_up1 = run_prepare(src, 1)
            r10_up2 = run_prepare(src, 2)
            self.assertEqual(r10_up1, r10_up2, f'R10 scope upgrade not idempotent ({case_name})')
            app_start = r10_up2.index('class AppDelegate')
            app_body = r10_up2[
                app_start : prepare_platform._find_swift_brace_block_end(
                    r10_up2, r10_up2.index('{', app_start), '{', '}'
                )
            ]
            self.assertIn('if let messenger = receiver?.binaryMessenger {', app_body)
            self.assertNotIn('marcoRootFlutterVC', app_body)
            if expected_ctrl is not None:
                self.assertIn(expected_ctrl, app_body, f'Expected {expected_ctrl} ({case_name})')
            else:
                self.assertNotIn('controller:', app_body, f'Unexpected controller: arg ({case_name})')
            self.assertEqual(app_body.count('MarcoNativeChannelRegistrar.register('), 1)
            self.assertEqual(r10_up2.count('{'), r10_up2.count('}'))

        # R11 P1: Build-configuration conditional bindings (`#if / #elseif / #else / #endif`)
        # must pass `controller: receiver` ONLY when EVERY reachable compile configuration
        # proves `receiver` is a `FlutterViewController?` (never emitting `controller: receiver`
        # when either Debug or Release binds `receiver: FlutterEngine?`).
        vc_decl = '    let receiver: FlutterViewController? = navigation?.topViewController as? FlutterViewController\n'
        eng_decl = '    let receiver: FlutterEngine? = (navigation?.topViewController as? FlutterViewController)?.engine\n'
        r11_build_cfg_cases = (
            (
                'engine-control',
                '    let navigation = window?.rootViewController as? UINavigationController\n'
                '    #if !DEBUG\n'
                + eng_decl
                + '    #else\n'
                + eng_decl
                + '    #endif\n'
                '    if let messenger = receiver?.binaryMessenger {',
                None,
            ),
            (
                'vc-control',
                '    let navigation = window?.rootViewController as? UINavigationController\n'
                '    #if !DEBUG\n'
                + vc_decl
                + '    #else\n'
                + vc_decl
                + '    #endif\n'
                '    if let messenger = receiver?.binaryMessenger {',
                'controller: receiver',
            ),
            (
                'release-engine',
                '    let navigation = window?.rootViewController as? UINavigationController\n'
                '    #if !DEBUG\n'
                + eng_decl
                + '    #else\n'
                + vc_decl
                + '    #endif\n'
                '    if let messenger = receiver?.binaryMessenger {',
                None,
            ),
            (
                'debug-engine',
                '    let navigation = window?.rootViewController as? UINavigationController\n'
                '    #if DEBUG\n'
                + eng_decl
                + '    #else\n'
                + vc_decl
                + '    #endif\n'
                '    if let messenger = receiver?.binaryMessenger {',
                None,
            ),
            (
                'if-without-else-engine',
                '    let navigation = window?.rootViewController as? UINavigationController\n'
                + eng_decl
                + '    #if DEBUG\n'
                + vc_decl
                + '    #endif\n'
                '    if let messenger = receiver?.binaryMessenger {',
                None,
            ),
            (
                'nested-if-mixed',
                '    let navigation = window?.rootViewController as? UINavigationController\n'
                '    #if !DEBUG\n'
                + vc_decl
                + '    #elseif targetEnvironment(simulator)\n'
                + eng_decl
                + '    #else\n'
                + vc_decl
                + '    #endif\n'
                '    if let messenger = receiver?.binaryMessenger {',
                None,
            ),
        )
        for case_name, replacement_snippet, expected_ctrl in r11_build_cfg_cases:
            src = legacy_076_templates['self'].replace(
                '    if let messenger = (window?.rootViewController as? FlutterViewController)?.binaryMessenger\n'
                '      ?? self.registrar(forPlugin: "MarcoChannelBridge")?.messenger() {',
                replacement_snippet,
                1,
            )
            r11_up1 = run_prepare(src, 1)
            r11_up2 = run_prepare(src, 2)
            self.assertEqual(r11_up1, r11_up2, f'R11 build-config upgrade not idempotent ({case_name})')
            app_start = r11_up2.index('class AppDelegate')
            app_body = r11_up2[
                app_start : prepare_platform._find_swift_brace_block_end(
                    r11_up2, r11_up2.index('{', app_start), '{', '}'
                )
            ]
            self.assertIn('if let messenger = receiver?.binaryMessenger {', app_body)
            self.assertNotIn('marcoRootFlutterVC', app_body)
            if expected_ctrl is not None:
                self.assertIn(expected_ctrl, app_body, f'Expected {expected_ctrl} ({case_name})')
            else:
                self.assertNotIn('controller:', app_body, f'Unexpected controller: arg ({case_name})')
            self.assertEqual(app_body.count('MarcoNativeChannelRegistrar.register('), 1)
            self.assertEqual(r11_up2.count('{'), r11_up2.count('}'))

        # R12 P2-4: Unrelated `#if DEBUG` / distinct-flag blocks (even 5-10+ blocks
        # with unrelated locals) must NOT cause branch-limit blowup or drop
        # `controller: receiver` for an unconditionally typed FlutterViewController,
        # while still preserving type safety for FlutterEngine receivers and mixed
        # Debug/Release build configs.
        split_vc = '    let receiver: FlutterViewController? = split?.viewControllers.last as? FlutterViewController\n'
        split_eng = '    let receiver: FlutterEngine? = (split?.viewControllers.last as? FlutterViewController)?.engine\n'
        five_debug_logs = ''.join(
            f'    #if DEBUG\n    NSLog("launch: {i}")\n    #endif\n' for i in range(5)
        )
        ten_distinct_flag_blocks = ''.join(
            f'    #if MARCO_DIAG_{i}\n    let diagTag{i} = "diag-{i}"\n    NSLog("%@", diagTag{i})\n    #endif\n'
            for i in range(10)
        )
        r12_explicit_child_cases = (
            (
                'vc-zero',
                '    let split = window?.rootViewController as? UISplitViewController\n'
                + split_vc
                + '    if let messenger = receiver?.binaryMessenger {',
                'controller: receiver',
            ),
            (
                'vc-five-debug-logs',
                five_debug_logs
                + '    let split = window?.rootViewController as? UISplitViewController\n'
                + split_vc
                + '    if let messenger = receiver?.binaryMessenger {',
                'controller: receiver',
            ),
            (
                'vc-ten-distinct-flags-with-locals',
                ten_distinct_flag_blocks
                + '    let split = window?.rootViewController as? UISplitViewController\n'
                + split_vc
                + '    if let messenger = receiver?.binaryMessenger {',
                'controller: receiver',
            ),
            (
                'vc-complementary-if-endif',
                '    let split = window?.rootViewController as? UISplitViewController\n'
                '    #if DEBUG\n'
                + split_vc
                + '    #endif\n'
                '    #if !DEBUG\n'
                + split_vc
                + '    #endif\n'
                '    if let messenger = receiver?.binaryMessenger {',
                'controller: receiver',
            ),
            (
                'engine-five-debug-logs',
                five_debug_logs
                + '    let split = window?.rootViewController as? UISplitViewController\n'
                + split_eng
                + '    if let messenger = receiver?.binaryMessenger {',
                None,
            ),
        )
        for case_name, replacement_snippet, expected_ctrl in r12_explicit_child_cases:
            src = legacy_076_templates['self'].replace(
                '    if let messenger = (window?.rootViewController as? FlutterViewController)?.binaryMessenger\n'
                '      ?? self.registrar(forPlugin: "MarcoChannelBridge")?.messenger() {',
                replacement_snippet,
                1,
            )
            r12_up1 = run_prepare(src, 1)
            r12_up2 = run_prepare(src, 2)
            self.assertEqual(r12_up1, r12_up2, f'R12 explicit child upgrade not idempotent ({case_name})')
            app_start = r12_up2.index('class AppDelegate')
            app_body = r12_up2[
                app_start : prepare_platform._find_swift_brace_block_end(
                    r12_up2, r12_up2.index('{', app_start), '{', '}'
                )
            ]
            self.assertIn('if let messenger = receiver?.binaryMessenger {', app_body)
            self.assertNotIn('marcoRootFlutterVC', app_body)
            if expected_ctrl is not None:
                self.assertIn(expected_ctrl, app_body, f'Expected {expected_ctrl} ({case_name})')
            else:
                self.assertNotIn('controller:', app_body, f'Unexpected controller: arg ({case_name})')
            self.assertEqual(app_body.count('MarcoNativeChannelRegistrar.register('), 1)
            self.assertEqual(r12_up2.count('{'), r12_up2.count('}'))

        # R13 P1: Swift SE-0308 postfix `#if` expressions (e.g. `#if DEBUG` /
        # `#if !DEBUG` wrapping `.flatMap { child -> FlutterEngine? in child.engine }`)
        # can change the inferred type of the preceding `let receiver = ...`
        # without introducing a new declaration and must NEVER be pruned, while
        # unrelated `#if DEBUG` log blocks (including chained logger calls) still
        # preserve explicit `controller: receiver` bindings.
        nav_vc = '(navigation?.topViewController as? FlutterViewController)'
        engine_postfix = '\n        .flatMap { child -> FlutterEngine? in child.engine }'
        five_chained_logs = ''.join(
            f'    #if DEBUG\n    NSLog(\n      "launch: {i}"\n    )\n    #endif\n'
            for i in range(5)
        )
        r13_postfix_cases = (
            (
                'child-control',
                '    let navigation = window?.rootViewController as? UINavigationController\n'
                f'    let receiver = {nav_vc}\n'
                '    if let messenger = receiver?.binaryMessenger {',
                'controller: receiver',
            ),
            (
                'engine-control',
                '    let navigation = window?.rootViewController as? UINavigationController\n'
                f'    let receiver = {nav_vc}{engine_postfix}\n'
                '    if let messenger = receiver?.binaryMessenger {',
                None,
            ),
            (
                'debug-postfix',
                '    let navigation = window?.rootViewController as? UINavigationController\n'
                f'    let receiver = {nav_vc}\n'
                '#if DEBUG'
                f'{engine_postfix}\n'
                '#endif\n'
                '    if let messenger = receiver?.binaryMessenger {',
                None,
            ),
            (
                'release-postfix',
                '    let navigation = window?.rootViewController as? UINavigationController\n'
                f'    let receiver = {nav_vc}\n'
                '#if !DEBUG'
                f'{engine_postfix}\n'
                '#endif\n'
                '    if let messenger = receiver?.binaryMessenger {',
                None,
            ),
            (
                'debug-postfix-after-five-logs',
                five_debug_logs
                + '    let navigation = window?.rootViewController as? UINavigationController\n'
                f'    let receiver = {nav_vc}\n'
                '#if DEBUG'
                f'{engine_postfix}\n'
                '#endif\n'
                '    if let messenger = receiver?.binaryMessenger {',
                None,
            ),
            (
                'nested-debug-postfix',
                '    let navigation = window?.rootViewController as? UINavigationController\n'
                f'    let receiver = {nav_vc}\n'
                '#if DEBUG\n'
                '#if os(iOS)'
                f'{engine_postfix}\n'
                '#endif\n'
                '#endif\n'
                '    if let messenger = receiver?.binaryMessenger {',
                None,
            ),
            (
                'vc-after-five-multiline-logs',
                five_chained_logs
                + '    let navigation = window?.rootViewController as? UINavigationController\n'
                f'    let receiver = {nav_vc}\n'
                '    if let messenger = receiver?.binaryMessenger {',
                'controller: receiver',
            ),
        )
        for case_name, replacement_snippet, expected_ctrl in r13_postfix_cases:
            src = legacy_076_templates['self'].replace(
                '    if let messenger = (window?.rootViewController as? FlutterViewController)?.binaryMessenger\n'
                '      ?? self.registrar(forPlugin: "MarcoChannelBridge")?.messenger() {',
                replacement_snippet,
                1,
            )
            r13_up1 = run_prepare(src, 1)
            r13_up2 = run_prepare(src, 2)
            self.assertEqual(r13_up1, r13_up2, f'R13 postfix upgrade not idempotent ({case_name})')
            app_start = r13_up2.index('class AppDelegate')
            app_body = r13_up2[
                app_start : prepare_platform._find_swift_brace_block_end(
                    r13_up2, r13_up2.index('{', app_start), '{', '}'
                )
            ]
            self.assertIn('if let messenger = receiver?.binaryMessenger {', app_body)
            self.assertNotIn('marcoRootFlutterVC', app_body)
            if expected_ctrl is not None:
                self.assertIn(expected_ctrl, app_body, f'Expected {expected_ctrl} ({case_name})')
            else:
                self.assertNotIn('controller:', app_body, f'Unexpected controller: arg ({case_name})')
            self.assertEqual(app_body.count('MarcoNativeChannelRegistrar.register('), 1)
            self.assertEqual(r13_up2.count('{'), r13_up2.count('}'))

        # R14 P2: Independent parenthesized statements (bare or inside `#if DEBUG`),
        # unrelated multi-flag postfix chains on earlier statements (`launchLabel`),
        # and conditional `.flatMap` chains returning `FlutterViewController?` must
        # preserve `controller: receiver`, while `FlutterEngine?` chains stay
        # type-safe, and `MarcoNativeChannelRegistrar` resolves controller identity
        # via `messenger` (`controllerMatching` / `preferredFlutterController`).
        split_detail = '    let receiver = split?.viewControllers.last as? FlutterViewController\n'
        split_engine = '    let receiver = (split?.viewControllers.last as? FlutterViewController)?.engine\n'
        left_nav_stmt = '    (split?.viewControllers.first as? UINavigationController)?.setNavigationBarHidden(false, animated: false)\n'
        vc_flatmap = '\n        .flatMap { child -> FlutterViewController? in child.presentedViewController as? FlutterViewController ?? child }'

        def _make_launch_label(flag_names: tuple[str, ...]) -> str:
            parts = ['    let launchLabel = "Marco"']
            for flg in flag_names:
                parts.extend([f'#if {flg}', f'        .appending(" {flg}")', '#endif'])
            parts.append('    NSLog("%@", launchLabel)')
            return '\n'.join(parts) + '\n'

        five_flags = ('DEBUG', 'STAGING', 'BETA_FEATURES', 'INTERNAL_QA', 'TESTFLIGHT')
        r14_cases = (
            (
                'independent-parenthesized-with-ifdef',
                '    let split = window?.rootViewController as? UISplitViewController\n'
                + split_detail
                + '#if DEBUG\n'
                + left_nav_stmt
                + '#endif\n'
                '    if let messenger = receiver?.binaryMessenger {',
                'controller: receiver',
            ),
            (
                'independent-parenthesized-without-ifdef',
                '    let split = window?.rootViewController as? UISplitViewController\n'
                + split_detail
                + left_nav_stmt
                + '    if let messenger = receiver?.binaryMessenger {',
                'controller: receiver',
            ),
            (
                'five-unrelated-postfix-flags',
                _make_launch_label(five_flags)
                + '    let split = window?.rootViewController as? UISplitViewController\n'
                + split_detail
                + '    if let messenger = receiver?.binaryMessenger {',
                'controller: receiver',
            ),
            (
                'engine-with-unrelated-flags-and-nav',
                _make_launch_label(five_flags)
                + '    let split = window?.rootViewController as? UISplitViewController\n'
                + split_engine
                + '#if DEBUG\n'
                + left_nav_stmt
                + '#endif\n'
                '    if let messenger = receiver?.binaryMessenger {',
                None,
            ),
            (
                'selected-child-flatmap-vc',
                '    let split = window?.rootViewController as? UISplitViewController\n'
                '    let receiver = (split?.viewControllers.last as? FlutterViewController)\n'
                '#if DEBUG'
                + vc_flatmap + '\n'
                '#endif\n'
                '    if let messenger = receiver?.binaryMessenger {',
                'controller: receiver',
            ),
            (
                'nested-selected-child-flatmap-vc',
                '    let split = window?.rootViewController as? UISplitViewController\n'
                '    let receiver = (split?.viewControllers.last as? FlutterViewController)\n'
                '#if DEBUG\n'
                '#if os(iOS)'
                + vc_flatmap + '\n'
                '#endif\n'
                '#endif\n'
                '    if let messenger = receiver?.binaryMessenger {',
                'controller: receiver',
            ),
            (
                'nested-engine-flatmap',
                '    let split = window?.rootViewController as? UISplitViewController\n'
                '    let receiver = (split?.viewControllers.last as? FlutterViewController)\n'
                '#if DEBUG\n'
                '#if os(iOS)'
                + engine_postfix + '\n'
                '#endif\n'
                '#endif\n'
                '    if let messenger = receiver?.binaryMessenger {',
                None,
            ),
            (
                'combined-all-three-r14-patterns',
                _make_launch_label(five_flags)
                + '    let split = window?.rootViewController as? UISplitViewController\n'
                '    let receiver = (split?.viewControllers.last as? FlutterViewController)\n'
                '#if DEBUG'
                + vc_flatmap + '\n'
                '#endif\n'
                '#if DEBUG\n'
                + left_nav_stmt
                + '#endif\n'
                '    if let messenger = receiver?.binaryMessenger {',
                'controller: receiver',
            ),
        )
        for case_name, replacement_snippet, expected_ctrl in r14_cases:
            src = legacy_076_templates['self'].replace(
                '    if let messenger = (window?.rootViewController as? FlutterViewController)?.binaryMessenger\n'
                '      ?? self.registrar(forPlugin: "MarcoChannelBridge")?.messenger() {',
                replacement_snippet,
                1,
            )
            r14_up1 = run_prepare(src, 1)
            r14_up2 = run_prepare(src, 2)
            self.assertEqual(r14_up1, r14_up2, f'R14 upgrade not idempotent ({case_name})')
            app_start = r14_up2.index('class AppDelegate')
            app_body = r14_up2[
                app_start : prepare_platform._find_swift_brace_block_end(
                    r14_up2, r14_up2.index('{', app_start), '{', '}'
                )
            ]
            self.assertIn('if let messenger = receiver?.binaryMessenger {', app_body)
            self.assertNotIn('marcoRootFlutterVC', app_body)
            if expected_ctrl is not None:
                self.assertIn(expected_ctrl, app_body, f'Expected {expected_ctrl} ({case_name})')
            else:
                self.assertNotIn('controller:', app_body, f'Unexpected controller: arg ({case_name})')
            self.assertEqual(app_body.count('MarcoNativeChannelRegistrar.register('), 1)
            self.assertEqual(r14_up2.count('{'), r14_up2.count('}'))
            # Runtime registrar identity contract: prefers mounted window controller
            # currently attached to `messenger`'s engine (`engine.viewController === $0`),
            # excluding detached retained controllers after same-engine handoff.
            self.assertIn('windowFlutterControllers() -> [FlutterViewController]', r14_up2)
            self.assertIn('controllerMatching(messenger: FlutterBinaryMessenger)', r14_up2)
            self.assertIn('$0.engine.viewController === $0', r14_up2)
            self.assertIn('preferredFlutterController(for messenger: FlutterBinaryMessenger)', r14_up2)
            self.assertIn('preferredFlutterController(for: messenger) as? MarcoFlutterViewController', r14_up2)
            self.assertIn('guard let host = preferredFlutterController(for: messenger) else {', r14_up2)
            self.assertIn('from: host,', r14_up2)

        # R15 P1 & P2: Wrapped assignment across newline (`let receiver =\n  ...`)
        # with `#if DEBUG` / `#if !DEBUG` engine postfix MUST omit `controller:`,
        # wrapped direct controller and `.map { -> FlutterViewController }` MUST
        # retain `controller: receiver`, double-optional `.map { -> FlutterViewController? }`
        # MUST omit `controller:`, and same-engine reattach from retained A -> B
        # selects active mounted B while preserving distinct-engine split-view routing.
        child_expr = '(split?.viewControllers.last as? FlutterViewController)'
        r15_cases = (
            (
                'r15-direct',
                '    let split = window?.rootViewController as? UISplitViewController\n'
                f'    let receiver = {child_expr}\n'
                '    if let messenger = receiver?.binaryMessenger {',
                'controller: receiver',
            ),
            (
                'r15-unwrapped-engine',
                '    let split = window?.rootViewController as? UISplitViewController\n'
                f'    let receiver = {child_expr}\n'
                '#if DEBUG'
                + engine_postfix + '\n'
                '#endif\n'
                '    if let messenger = receiver?.binaryMessenger {',
                None,
            ),
            (
                'r15-wrapped-engine',
                '    let split = window?.rootViewController as? UISplitViewController\n'
                '    let receiver =\n'
                f'        {child_expr}\n'
                '#if DEBUG'
                + engine_postfix + '\n'
                '#endif\n'
                '    if let messenger = receiver?.binaryMessenger {',
                None,
            ),
            (
                'r15-wrapped-release-engine',
                '    let split = window?.rootViewController as? UISplitViewController\n'
                '    let receiver =\n'
                f'        {child_expr}\n'
                '#if !DEBUG'
                + engine_postfix + '\n'
                '#endif\n'
                '    if let messenger = receiver?.binaryMessenger {',
                None,
            ),
            (
                'r15-wrapped-direct',
                '    let split = window?.rootViewController as? UISplitViewController\n'
                '    let receiver =\n'
                f'        {child_expr}\n'
                '    if let messenger = receiver?.binaryMessenger {',
                'controller: receiver',
            ),
            (
                'r15-unwrapped-map',
                '    let split = window?.rootViewController as? UISplitViewController\n'
                f'    let receiver = {child_expr}\n'
                '        .map { child -> FlutterViewController in child }\n'
                '    if let messenger = receiver?.binaryMessenger {',
                'controller: receiver',
            ),
            (
                'r15-map-explicit-flatten',
                '    let split = window?.rootViewController as? UISplitViewController\n'
                f'    let maybeChild = {child_expr}\n'
                '        .map { child -> FlutterViewController? in child }\n'
                '    let receiver: FlutterViewController? = maybeChild ?? nil\n'
                '    if let messenger = receiver?.binaryMessenger {',
                'controller: receiver',
            ),
            (
                'r15-double-optional-map-omits',
                '    let split = window?.rootViewController as? UISplitViewController\n'
                f'    let receiver = {child_expr}\n'
                '        .map { child -> FlutterViewController? in child }\n'
                '    if let messenger = receiver?.binaryMessenger {',
                None,
            ),
        )
        for case_name, replacement_snippet, expected_ctrl in r15_cases:
            src = legacy_076_templates['self'].replace(
                '    if let messenger = (window?.rootViewController as? FlutterViewController)?.binaryMessenger\n'
                '      ?? self.registrar(forPlugin: "MarcoChannelBridge")?.messenger() {',
                replacement_snippet,
                1,
            )
            r15_up1 = run_prepare(src, 1)
            r15_up2 = run_prepare(src, 2)
            self.assertEqual(r15_up1, r15_up2, f'R15 upgrade not idempotent ({case_name})')
            app_start = r15_up2.index('class AppDelegate')
            app_body = r15_up2[
                app_start : prepare_platform._find_swift_brace_block_end(
                    r15_up2, r15_up2.index('{', app_start), '{', '}'
                )
            ]
            self.assertIn('if let messenger = receiver?.binaryMessenger {', app_body)
            self.assertNotIn('marcoRootFlutterVC', app_body)
            if expected_ctrl is not None:
                self.assertIn(expected_ctrl, app_body, f'Expected {expected_ctrl} ({case_name})')
            else:
                self.assertNotIn('controller:', app_body, f'Unexpected controller: arg ({case_name})')
            self.assertEqual(app_body.count('MarcoNativeChannelRegistrar.register('), 1)
            self.assertEqual(r15_up2.count('{'), r15_up2.count('}'))

        # R15 P2: Registrar runtime selection invariants (reattach same engine A -> B
        # when A is still retained, plus dual-column independent engines B & C).
        registrar_src = prepare_platform.IOS_NATIVE_CHANNEL_REGISTRAR_SWIFT
        wf_idx = registrar_src.index('private static func windowFlutterControllers()')
        af_idx = registrar_src.index('private static func activeFlutterControllers()')
        cm_idx = registrar_src.index('private static func controllerMatching(messenger: FlutterBinaryMessenger)')
        self.assertLess(wf_idx, af_idx)
        self.assertLess(af_idx, cm_idx)
        active_fn_src = registrar_src[af_idx:cm_idx]
        # activeFlutterControllers must start from windowFlutterControllers() rather than
        # unconditionally prepending cached primaryFlutterController ahead of mounted VCs.
        self.assertIn('var found = windowFlutterControllers()', active_fn_src)
        self.assertIn('primary.engine.viewController === primary', active_fn_src)
        match_fn_src = registrar_src[cm_idx : registrar_src.index('private static func activeFlutterController()')]
        self.assertIn('let mounted = windowFlutterControllers()', match_fn_src)
        self.assertIn('($0.binaryMessenger as AnyObject) === target && $0.engine.viewController === $0', match_fn_src)
        self.assertIn('primary.engine.viewController === primary', match_fn_src)
        # R16 P2: Never match detached old controller (`mountedMatch`) or fall back
        # across unrelated engines during handoff gap (`preferredFlutterController`),
        # and never fall back to `activeWindow()?.rootViewController` inside
        # `NetdiskWebAuthController.present`.
        self.assertNotIn('mountedMatch', match_fn_src)
        pref_idx = registrar_src.index('private static func preferredFlutterController(for messenger: FlutterBinaryMessenger)')
        pref_fn_src = registrar_src[pref_idx : registrar_src.index('static func register(', pref_idx)]
        self.assertIn('return controllerMatching(messenger: messenger)', pref_fn_src)
        self.assertNotIn('activeFlutterController()', pref_fn_src)
        self.assertIn('code: "host_unavailable"', registrar_src)
        self.assertIn('guard let host = preferredFlutterController(for: messenger) else {', registrar_src)
        auth_src = prepare_platform.IOS_NETDISK_AUTH_CONTROLLER_SWIFT
        present_idx = auth_src.index('static func present(from root: UIViewController?')
        present_fn_src = auth_src[present_idx : auth_src.index('override func viewDidLoad()', present_idx)]
        self.assertIn('guard var presenter = root else {', present_fn_src)
        self.assertNotIn('activeWindow()?.rootViewController', present_fn_src)

        # R18 P2: Orientation monitoring follows the active host VC for the same
        # messenger (A -> B handoff) while staying idempotent and balanced on
        # the same healthy host A and strictly isolated across engines.
        self.assertIn('private final class OrientationMonitoringBinding', registrar_src)
        self.assertIn('static func reconcileOrientationMonitoring(for controller: MarcoFlutterViewController)', registrar_src)
        self.assertIn('guard let activeTarget = preferredFlutterController(for: messenger) as? MarcoFlutterViewController', registrar_src)
        self.assertIn('activeTarget === controller', registrar_src)
        fvc_src = prepare_platform.IOS_FLUTTER_VIEW_CONTROLLER_SWIFT
        self.assertIn('MarcoNativeChannelRegistrar.reconcileOrientationMonitoring(for: self)', fvc_src)
        mon_idx = fvc_src.index('func setPhysicalOrientationMonitoring(')
        mon_src = fvc_src[mon_idx : fvc_src.index('func applyRequestedOrientation(', mon_idx)]
        self.assertIn('if orientationObserver != nil {\n        return', mon_src)
        self.assertIn('if let obs = orientationObserver {\n      NotificationCenter.default.removeObserver(obs)\n      orientationObserver = nil\n      UIDevice.current.endGeneratingDeviceOrientationNotifications()', mon_src)

    def test_ios_native_avplayer_and_liquid_glass_review_invariants(self) -> None:
        flutter_dir = Path(__file__).resolve().parent
        av_swift = (flutter_dir / 'ios_native/MarcoAvPlayerEngine.swift').read_text(encoding='utf-8')
        lg_swift = (flutter_dir / 'ios_native/MarcoLiquidGlass.swift').read_text(encoding='utf-8')

        # 1. Audio session must not pass .allowAirPlay with .playback, and tracks activation state.
        self.assertNotIn('options: [.allowAirPlay]', av_swift)
        self.assertIn('session.setCategory(.playback, mode: .moviePlayback, options: [])', av_swift)
        self.assertIn('audioSessionConfigured', av_swift)
        self.assertIn('audioSessionActive', av_swift)

        # 2. System volume write checks audio session activation, distinguishes missing UISlider,
        #    schedules post-commit outputVolume readback, and re-emits volume on route change.
        self.assertIn('"applied": false', av_swift)
        self.assertIn('"applied": true', av_swift)
        self.assertIn('"reason": "audioSessionFailed"', av_swift)
        self.assertIn('"reason": "sliderUnavailable"', av_swift)
        self.assertIn('volumeConfirmWorkItem', av_swift)
        route_idx = av_swift.find('AVAudioSession.routeChangeNotification')
        self.assertNotEqual(route_idx, -1)
        self.assertIn('"type": "systemVolumeChanged"', av_swift[route_idx : route_idx + 420])

        # 3. PiP layer lifecycle protects pipSourceLayer across BOTH starting and active states,
        #    rebinds visiblePlayerLayer on didStop and failedToStart, and emits cancelled on stop.
        self.assertIn('private weak var visiblePlayerLayer: AVPlayerLayer?', av_swift)
        self.assertIn('private var pipSourceLayer: AVPlayerLayer?', av_swift)
        self.assertIn('private var pipStarting: Bool = false', av_swift)
        self.assertIn('private var cancelPendingPipStart: Bool = false', av_swift)
        self.assertIn('private var isPipActiveOrStarting: Bool', av_swift)
        self.assertIn('if cancelPendingPipStart {', av_swift)
        self.assertIn('if pipSourceLayer !== visiblePlayerLayer {', av_swift)
        self.assertIn('"phase": "willStart"', av_swift)
        self.assertIn('emitPipState(phase: "didStart")', av_swift)
        self.assertIn('"phase": "cancelled"', av_swift)
        fail_idx = av_swift.find('failedToStartPictureInPictureWithError')
        self.assertNotEqual(fail_idx, -1)
        self.assertIn('if pipSourceLayer !== visiblePlayerLayer {', av_swift[fail_idx : fail_idx + 450])

        # 4. Native AVPlayer monotonic eventSeq ordering across clock samples and seek completions.
        self.assertIn('private var mediaEventSeq: Int = 0', av_swift)
        self.assertIn('event["eventSeq"] = self.mediaEventSeq', av_swift)
        self.assertIn('"eventSeq": seq', av_swift)

        # 5. Native Liquid Glass Dock cancel-on-vertical-exit & Reduce Motion guards (including PIN dialog).
        self.assertIn('isTouchInsideCommitZone', lg_swift)
        self.assertIn('scrubCancelledByExit', lg_swift)
        self.assertIn('if UIAccessibility.isReduceMotionEnabled {', lg_swift)
        self.assertIn('if animated && !UIAccessibility.isReduceMotionEnabled {', lg_swift)
        pin_dismiss_idx = lg_swift.find('private func dismissAnimated(succeeded: Bool)')
        self.assertNotEqual(pin_dismiss_idx, -1)
        self.assertIn('UIAccessibility.isReduceMotionEnabled', lg_swift[pin_dismiss_idx : pin_dismiss_idx + 420])
        pin_appear_idx = lg_swift.find('cardShadowView.transform = UIAccessibility.isReduceMotionEnabled')
        self.assertNotEqual(pin_appear_idx, -1)


if __name__ == '__main__':
    unittest.main()
