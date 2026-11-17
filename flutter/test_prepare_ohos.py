import json
import re
import struct
import sys
import tempfile
import unittest
from pathlib import Path

FLUTTER_DIR = Path(__file__).resolve().parent
REPO_ROOT = FLUTTER_DIR.parent
if str(FLUTTER_DIR) not in sys.path:
    sys.path.insert(0, str(FLUTTER_DIR))

import prepare_ohos  # noqa: E402


class PrepareOhosTests(unittest.TestCase):
    def test_icon_copy_and_version_sync(self) -> None:
        icon_master = REPO_ROOT / "docs" / "images" / "app-icon-512.png"
        self.assertTrue(icon_master.exists(), f"Missing icon master: {icon_master}")

        with tempfile.TemporaryDirectory() as tmp:
            sandbox = Path(tmp) / "flutter"
            (sandbox / "ohos" / "AppScope").mkdir(parents=True)
            (sandbox / "ohos" / "entry").mkdir(parents=True)
            (sandbox / "ohos" / "AppScope" / "app.json5").write_bytes(
                (FLUTTER_DIR / "ohos" / "AppScope" / "app.json5").read_bytes()
            )
            (sandbox / "ohos" / "oh-package.json5").write_bytes(
                (FLUTTER_DIR / "ohos" / "oh-package.json5").read_bytes()
            )
            (sandbox / "ohos" / "entry" / "oh-package.json5").write_bytes(
                (FLUTTER_DIR / "ohos" / "entry" / "oh-package.json5").read_bytes()
            )

            # 1) Default version when harmonyos entry is absent in edition-versions.json
            (sandbox / "edition-versions.json").write_text(
                json.dumps({"windows": {"versionName": "0.5.24", "buildNumber": 74}}),
                encoding="utf-8",
            )
            rc = prepare_ohos.main(
                ["--project-root", str(sandbox), "--icon-source", str(icon_master)]
            )
            self.assertEqual(rc, 0)

            app_icon = sandbox / "ohos" / "AppScope" / "resources" / "base" / "media" / "app_icon.png"
            entry_icon = sandbox / "ohos" / "entry" / "src" / "main" / "resources" / "base" / "media" / "icon.png"
            for icon_path in (app_icon, entry_icon):
                self.assertTrue(icon_path.exists())
                raw = icon_path.read_bytes()
                self.assertEqual(raw[:8], b"\x89PNG\r\n\x1a\n")
                self.assertEqual(struct.unpack_from(">II", raw, 16), (512, 512))
                self.assertEqual(raw, icon_master.read_bytes())

            # Idempotent re-run returns False (no unnecessary rewrite)
            self.assertFalse(prepare_ohos._copy_bytes_idempotent(icon_master, app_icon))

            app_cfg = prepare_ohos.load_json5(sandbox / "ohos" / "AppScope" / "app.json5")["app"]
            self.assertEqual(app_cfg["versionName"], "0.1.0")
            self.assertEqual(app_cfg["versionCode"], 1000001)

            # 2) Explicit harmonyos entry in edition-versions.json
            (sandbox / "edition-versions.json").write_text(
                json.dumps(
                    {
                        "harmonyos": {
                            "versionName": "0.3.2",
                            "buildNumber": 12,
                        }
                    }
                ),
                encoding="utf-8",
            )
            prepare_ohos.sync_ohos_version(sandbox)
            app_cfg_updated = prepare_ohos.load_json5(sandbox / "ohos" / "AppScope" / "app.json5")["app"]
            self.assertEqual(app_cfg_updated["versionName"], "0.3.2")
            self.assertEqual(app_cfg_updated["versionCode"], 1000012)
            self.assertEqual(
                prepare_ohos.load_json5(sandbox / "ohos" / "oh-package.json5")["version"],
                "0.3.2",
            )

    def test_patch_and_restore_pubspec_roundtrip_is_byte_identical(self) -> None:
        icon_master = REPO_ROOT / "docs" / "images" / "app-icon-512.png"
        real_root_bytes = (FLUTTER_DIR / "pubspec.yaml").read_bytes()
        real_qjs_bytes = (FLUTTER_DIR / "packages" / "quickjs_engine" / "pubspec.yaml").read_bytes()
        real_lock_path = FLUTTER_DIR / "pubspec.lock"
        real_lock_bytes = real_lock_path.read_bytes() if real_lock_path.exists() else None

        with tempfile.TemporaryDirectory() as tmp:
            sandbox = Path(tmp) / "flutter"
            (sandbox / "packages" / "quickjs_engine").mkdir(parents=True)
            (sandbox / "ohos" / "AppScope").mkdir(parents=True)
            (sandbox / "pubspec.yaml").write_bytes(real_root_bytes)
            (sandbox / "packages" / "quickjs_engine" / "pubspec.yaml").write_bytes(real_qjs_bytes)
            if real_lock_bytes is not None:
                (sandbox / "pubspec.lock").write_bytes(real_lock_bytes)

            # Run --patch-pubspec twice to verify idempotent backup preservation
            for _ in range(2):
                rc = prepare_ohos.main(
                    [
                        "--project-root",
                        str(sandbox),
                        "--icon-source",
                        str(icon_master),
                        "--patch-pubspec",
                    ]
                )
                self.assertEqual(rc, 0)

            patched_root = (sandbox / "pubspec.yaml").read_text(encoding="utf-8")
            self.assertNotIn("media_kit_libs_video:", patched_root)
            self.assertNotIn("path_provider_foundation:", patched_root)
            self.assertIn("quickjs_engine:", patched_root)
            self.assertFalse((sandbox / "pubspec.lock").exists())

            patched_qjs = (
                sandbox / "packages" / "quickjs_engine" / "pubspec.yaml"
            ).read_text(encoding="utf-8")
            self.assertIn('sdk: ">=3.3.0 <4.0.0"', patched_qjs)
            self.assertIn('flutter: ">=3.22.0"', patched_qjs)

            # Restore and assert 100% byte-for-byte identity
            rc_restore = prepare_ohos.main(
                ["--project-root", str(sandbox), "--restore-pubspec"]
            )
            self.assertEqual(rc_restore, 0)
            self.assertEqual((sandbox / "pubspec.yaml").read_bytes(), real_root_bytes)
            self.assertEqual(
                (sandbox / "packages" / "quickjs_engine" / "pubspec.yaml").read_bytes(),
                real_qjs_bytes,
            )
            if real_lock_bytes is not None:
                self.assertEqual((sandbox / "pubspec.lock").read_bytes(), real_lock_bytes)

    def test_harmonyos_stage_model_json5_and_resources(self) -> None:
        ohos_dir = FLUTTER_DIR / "ohos"
        build_profile = prepare_ohos.load_json5(ohos_dir / "build-profile.json5")
        products = build_profile["app"]["products"]
        self.assertGreaterEqual(len(products), 1)
        default_product = products[0]
        self.assertEqual(default_product["compileSdkVersion"], "5.0.0(12)")
        self.assertEqual(default_product["compatibleSdkVersion"], "5.0.0(12)")
        self.assertEqual(default_product["targetSdkVersion"], "5.0.0(12)")
        module_names = [m["name"] for m in build_profile["modules"]]
        self.assertIn("entry", module_names)

        app_cfg = prepare_ohos.load_json5(ohos_dir / "AppScope" / "app.json5")["app"]
        self.assertEqual(app_cfg["bundleName"], "com.pilipala.marcomovie")
        self.assertEqual(app_cfg["vendor"], "Pilipala")

        entry_profile = prepare_ohos.load_json5(ohos_dir / "entry" / "build-profile.json5")
        native_opts = entry_profile["buildOption"]["externalNativeOptions"]
        self.assertEqual(native_opts["path"], "./src/main/cpp/CMakeLists.txt")
        self.assertEqual(set(native_opts["abiFilters"]), {"arm64-v8a", "x86_64"})

        module_cfg = prepare_ohos.load_json5(
            ohos_dir / "entry" / "src" / "main" / "module.json5"
        )["module"]
        self.assertEqual(
            set(module_cfg["deviceTypes"]),
            {"phone", "tablet", "2in1", "tv"},
        )
        abilities = {a["name"]: a for a in module_cfg["abilities"]}
        self.assertIn("EntryAbility", abilities)
        entry_ability = abilities["EntryAbility"]
        self.assertEqual(entry_ability["orientation"], "auto_rotation_restricted")
        self.assertEqual(
            set(entry_ability["supportWindowMode"]),
            {"fullscreen", "split", "floating"},
        )
        entities = {
            entity
            for skill in entry_ability["skills"]
            for entity in skill.get("entities", [])
        }
        actions = {
            action
            for skill in entry_ability["skills"]
            for action in skill.get("actions", [])
        }
        self.assertIn("entity.system.home", entities)
        self.assertIn("entity.system.leanback", entities)
        self.assertIn("action.system.home", actions)

        permissions = {p["name"] for p in module_cfg["requestPermissions"]}
        self.assertTrue(
            {
                "ohos.permission.INTERNET",
                "ohos.permission.GET_NETWORK_INFO",
                "ohos.permission.GET_WIFI_INFO",
                "ohos.permission.KEEP_BACKGROUND_RUNNING",
            }.issubset(permissions)
        )

        # Validate JSON resource files parse cleanly
        for rel in (
            "AppScope/resources/base/element/string.json",
            "entry/src/main/resources/base/element/string.json",
            "entry/src/main/resources/base/element/color.json",
            "entry/src/main/resources/base/profile/main_pages.json",
        ):
            parsed = json.loads((ohos_dir / rel).read_text(encoding="utf-8"))
            self.assertIsInstance(parsed, dict)

    def test_cmake_quickjs_native_sources_exist_on_disk(self) -> None:
        cmake_file = FLUTTER_DIR / "ohos" / "entry" / "src" / "main" / "cpp" / "CMakeLists.txt"
        self.assertTrue(cmake_file.exists())
        cmake_text = cmake_file.read_text(encoding="utf-8")

        self.assertIn("add_library(quickjs_c_bridge_plugin SHARED", cmake_text)
        self.assertIn("_GNU_SOURCE", cmake_text)
        self.assertIn("-fvisibility=default", cmake_text)
        for lib in ("pthread", "m", "dl"):
            self.assertIn(lib, cmake_text)

        dir_match = re.search(
            r'QJS_CXX_DIR\s+"?\$\{CMAKE_CURRENT_SOURCE_DIR\}/([^"\s\)]+)"?',
            cmake_text,
        )
        self.assertIsNotNone(dir_match, "QJS_CXX_DIR definition not found in CMakeLists.txt")
        qjs_cxx_dir = (cmake_file.parent / dir_match.group(1)).resolve()
        self.assertTrue(qjs_cxx_dir.is_dir(), f"Resolved QJS_CXX_DIR missing: {qjs_cxx_dir}")

        referenced_sources = re.findall(
            r'"\$\{QJS_CXX_DIR\}/([^"]+\.(?:c|cpp))"',
            cmake_text,
        )
        self.assertIn("libfastdev_quickjs_runtime.cpp", referenced_sources)
        self.assertIn("quickjs/quickjs.c", referenced_sources)
        self.assertTrue((qjs_cxx_dir / "quickjs").is_dir())
        for rel_src in referenced_sources:
            src_path = qjs_cxx_dir / rel_src
            self.assertTrue(src_path.is_file(), f"Missing CMake source on disk: {src_path}")

    def test_arkts_plugins_and_guardrail_compliance(self) -> None:
        ets_root = FLUTTER_DIR / "ohos" / "entry" / "src" / "main" / "ets"
        sys_plugin = (ets_root / "plugins" / "OhosSystemPlugin.ets").read_text(encoding="utf-8")
        av_plugin = (ets_root / "plugins" / "OhosAvPlayerPlugin.ets").read_text(encoding="utf-8")
        entry_ability = (ets_root / "entryability" / "EntryAbility.ets").read_text(encoding="utf-8")
        index_page = (ets_root / "pages" / "Index.ets").read_text(encoding="utf-8")
        dart_shim = (
            FLUTTER_DIR / "packages" / "ohos_platform_shims" / "lib" / "ohos_platform_shims.dart"
        ).read_text(encoding="utf-8")

        self.assertIn("com.pilipala.marcomovie/ohos_system", sys_plugin)
        self.assertIn("com.pilipala.marcomovie/ohos_system", dart_shim)
        expected_system_methods = (
            "getDeviceProfile",
            "getDirectories",
            "getPackageInfo",
            "prefsGetAll",
            "prefsSet",
            "prefsRemove",
            "prefsClear",
            "secureRead",
            "secureWrite",
            "secureDelete",
            "pickJsonFile",
            "saveTextFile",
            "openExternalUrl",
            "setKeepScreenOn",
            "setPreferredOrientation",
        )
        for method in expected_system_methods:
            self.assertIn(f"case '{method}':", sys_plugin)
            self.assertIn(f"'{method}'", dart_shim)
        self.assertIn("marco_movie_prefs", sys_plugin)
        self.assertIn("marco_movie_secure_fallback", sys_plugin)
        self.assertIn("DEVICE_FIRST_UNLOCKED", sys_plugin)

        self.assertIn("com.pilipala.marcomovie/ohos_avplayer", av_plugin)
        self.assertIn("com.pilipala.marcomovie/ohos_avplayer/events/", av_plugin)
        self.assertIn("com.pilipala.marcomovie/ohos_avplayer", dart_shim)
        expected_av_methods = (
            "create",
            "open",
            "play",
            "pause",
            "stop",
            "seek",
            "setRate",
            "setVolume",
            "getTracks",
            "selectTrack",
            "dispose",
        )
        for method in expected_av_methods:
            self.assertIn(f"case '{method}':", av_plugin)
            self.assertIn(f"'{method}'", dart_shim)

        for event_type in ("state", "position", "videoSize", "error"):
            self.assertIn(f"'type': '{event_type}'", av_plugin)
        self.assertIn("avPlayer.surfaceId = session.surfaceId", av_plugin)
        self.assertIn("createMediaSourceWithUrl", av_plugin)

        self.assertIn("extends FlutterAbility", entry_ability)
        self.assertIn("GeneratedPluginRegistrant.registerWith(flutterEngine)", entry_ability)
        self.assertIn("new OhosSystemPlugin", entry_ability)
        self.assertIn("new OhosAvPlayerPlugin", entry_ability)
        self.assertIn("FlutterPage({ viewId: this.viewId })", index_page)

        # Verify no forbidden directories or unexpected URLs inside flutter/ohos
        forbidden_dirs = {"build", "dist", "private", "tools", "classes", "lib", "__pycache__"}
        for path in (FLUTTER_DIR / "ohos").rglob("*"):
            rel_parts = set(path.relative_to(FLUTTER_DIR / "ohos").parts)
            self.assertTrue(
                rel_parts.isdisjoint(forbidden_dirs),
                f"Forbidden directory name in ohos tree: {path}",
            )
            if path.is_file() and path.suffix != ".png":
                text = path.read_text(encoding="utf-8")
                self.assertIsNone(
                    re.search(r"https?://", text),
                    f"Unexpected external URL in {path}",
                )


if __name__ == "__main__":
    unittest.main()
