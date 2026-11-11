"""Deployment guard regression tests; these do not replace a device launch test."""
import plistlib
import struct
import tempfile
import unittest
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
        return struct.pack('<8I', 0xfeedfacf, 0x100000c, 0, filetype, 1, 24, 0, 0) + struct.pack('<6I', 0x32, 24, platform, minimum, 0x120000, 0)

    def test_real_compatible_deployment_is_unchanged(self):
        blob = self.binary(0x0d0000)
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
            (runner / 'Info.plist').write_bytes(plistlib.dumps({'MinimumOSVersion': '14.0'}))
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
            swift = app_delegate.read_text(encoding='utf-8')
            self.assertEqual(swift.count('import WebKit'), 1)
            self.assertEqual(swift.count('marco_movie/wakelock'), 1)
            self.assertEqual(swift.count('marco_movie/netdisk_auth'), 1)
            self.assertEqual(swift.count('final class NetdiskWebAuthController'), 1)
            self.assertEqual(swift.count('{'), swift.count('}'))
            plist = plistlib.loads((runner / 'Info.plist').read_bytes())
            self.assertEqual(len([u for u in plist['CFBundleURLTypes'] if 'marcomovie' in u.get('CFBundleURLSchemes', [])]), 1)


if __name__ == '__main__':
    unittest.main()
