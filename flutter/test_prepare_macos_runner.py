"""Unit tests for prepare_platform.py macOS Runner generation."""
from pathlib import Path
import shutil
import tempfile
import unittest

import prepare_platform


SAMPLE_MAIN_FLUTTER_WINDOW = """import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
"""

SAMPLE_ENTITLEMENTS = """<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
  <key>com.apple.security.app-sandbox</key>
  <true/>
</dict>
</plist>
"""

SAMPLE_INFO_PLIST = """<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>marco_movie</string>
</dict>
</plist>
"""

SAMPLE_PODFILE = "# platform :osx, '10.14'\n"
SAMPLE_PBXPROJ = "MACOSX_DEPLOYMENT_TARGET = 10.14;\n"


class PrepareMacosRunnerTests(unittest.TestCase):
    def test_macos_runner_window_memory_and_idempotency(self):
        with tempfile.TemporaryDirectory(prefix="marco-macos-runner-") as tmp:
            fake_root = Path(tmp) / "flutter"
            runner = fake_root / "macos" / "Runner"
            runner.mkdir(parents=True)
            (fake_root / "macos" / "Podfile").write_text(SAMPLE_PODFILE, encoding="utf-8")
            pbx = fake_root / "macos" / "Runner.xcodeproj" / "project.pbxproj"
            pbx.parent.mkdir(parents=True)
            pbx.write_text(SAMPLE_PBXPROJ, encoding="utf-8")
            window_swift = runner / "MainFlutterWindow.swift"
            window_swift.write_text(SAMPLE_MAIN_FLUTTER_WINDOW, encoding="utf-8")
            (runner / "Release.entitlements").write_text(SAMPLE_ENTITLEMENTS, encoding="utf-8")
            (runner / "DebugProfile.entitlements").write_text(SAMPLE_ENTITLEMENTS, encoding="utf-8")
            (runner / "Info.plist").write_text(SAMPLE_INFO_PLIST, encoding="utf-8")

            orig_root = prepare_platform.ROOT
            try:
                prepare_platform.ROOT = fake_root
                prepare_platform.main()
                first_pass = window_swift.read_text(encoding="utf-8")
                prepare_platform.main()
                second_pass = window_swift.read_text(encoding="utf-8")
            finally:
                prepare_platform.ROOT = orig_root

            self.assertEqual(first_pass, second_pass, "prepare_platform.py must be idempotent")
            self.assertIn("NSSize(width: 720, height: 520)", first_pass)
            self.assertNotIn("NSSize(width: 900, height: 600)", first_pass)
            awake_block = first_pass.split("extension MainFlutterWindow {", 1)[0]
            self.assertNotIn(
                "self.appearance = NSAppearance(named: .darkAqua)",
                awake_block,
                "awakeFromNib must not hardcode darkAqua so Light Mode titlebars work",
            )
            self.assertIn("NSAppearance(named: .aqua)", first_pass)
            self.assertLess(
                first_pass.index("self.marcoRestoreInitialFrame()"),
                first_pass.index("super.awakeFromNib()"),
                "Saved normal bounds must be restored before first display",
            )
            for required in (
                'marco_movie/macos_window',
                'marco_macos_window_frame_v1',
                'self.isRestorable = false',
                'didMoveNotification',
                'didResizeNotification',
                'didEndLiveResizeNotification',
                'willEnterFullScreenNotification',
                'didExitFullScreenNotification',
                'willMiniaturizeNotification',
                'didDeminiaturizeNotification',
                'willCloseNotification',
                'willTerminateNotification',
                'didChangeScreenParametersNotification',
                'marcoEnsureWindowChromeVisible',
                'activateFileViewerSelecting',
                'setAppearance',
            ):
                self.assertIn(required, first_pass)

            ent = (runner / "Release.entitlements").read_text(encoding="utf-8")
            for key in (
                "com.apple.security.network.client",
                "com.apple.security.network.server",
                "com.apple.security.files.downloads.read-write",
                "com.apple.security.files.user-selected.read-write",
            ):
                self.assertIn(key, ent)
            self.assertIn("platform :osx, '11.0'", (fake_root / "macos" / "Podfile").read_text(encoding="utf-8"))
            self.assertIn("MACOSX_DEPLOYMENT_TARGET = 11.0;", pbx.read_text(encoding="utf-8"))
            self.assertTrue((fake_root / "assets" / "logo_mark.png").is_file())


if __name__ == "__main__":
    unittest.main()
