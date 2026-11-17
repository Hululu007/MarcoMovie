#!/usr/bin/env python3
# Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
"""End-to-end verification suite for tvOS workspace preparation, Swift structure, and IPA patching."""

from __future__ import annotations

from pathlib import Path
import plistlib
import struct
import sys
import tempfile
import unittest
import zipfile

TVOS_DIR = Path(__file__).resolve().parent
if str(TVOS_DIR) not in sys.path:
    sys.path.insert(0, str(TVOS_DIR))

import patch_tvos_ipa  # noqa: E402
import prepare_tvos  # noqa: E402


def _strip_swift_strings_and_comments(source: str) -> str:
    """Strip Swift line/block comments and string literals (including #\"...\"# and \"\"\"...\"\"\") for delimiter checks."""
    n = len(source)
    i = 0
    out: list[str] = []
    while i < n:
        ch = source[i]
        # Line comment //
        if ch == "/" and i + 1 < n and source[i + 1] == "/":
            i += 2
            while i < n and source[i] != "\n":
                i += 1
            continue
        # Block comment /* ... */
        if ch == "/" and i + 1 < n and source[i + 1] == "*":
            i += 2
            while i + 1 < n and not (source[i] == "*" and source[i + 1] == "/"):
                i += 1
            i += 2
            continue
        # Extended raw string #"..."# or #"""..."""#
        if ch == "#":
            j = i
            while j < n and source[j] == "#":
                j += 1
            hashes = j - i
            if j < n and source[j] == '"':
                if source[j : j + 3] == '"""':
                    end_pat = '"""' + ("#" * hashes)
                    end_idx = source.find(end_pat, j + 3)
                    i = (end_idx + len(end_pat)) if end_idx >= 0 else n
                    out.append(" ")
                    continue
                end_pat = '"' + ("#" * hashes)
                end_idx = source.find(end_pat, j + 1)
                i = (end_idx + len(end_pat)) if end_idx >= 0 else n
                out.append(" ")
                continue
        # Multiline string """..."""
        if source[i : i + 3] == '"""':
            i += 3
            while i < n:
                if source[i] == "\\":
                    i += 2
                    continue
                if source[i : i + 3] == '"""':
                    i += 3
                    break
                i += 1
            out.append(" ")
            continue
        # Standard string "..."
        if ch == '"':
            i += 1
            while i < n:
                if source[i] == "\\":
                    i += 2
                    continue
                if source[i] == '"':
                    i += 1
                    break
                i += 1
            out.append(" ")
            continue
        out.append(ch)
        i += 1
    return "".join(out)


class TvOSWorkspaceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.summary = prepare_tvos.prepare_all()

    def test_quickjs_and_js_host_synced(self) -> None:
        cquickjs_dir = TVOS_DIR / "Sources" / "CQuickJS"
        for c_name in ("cquickjs_anchor.c", "quickjs.c", "libregexp.c", "libunicode.c", "dtoa.c"):
            self.assertTrue((cquickjs_dir / c_name).is_file(), f"Missing {c_name}")
        # quickjs-libc.c uses fork/exec and must NOT be compiled into the tvOS sandbox library
        self.assertFalse((cquickjs_dir / "quickjs-libc.c").exists())

        include_dir = cquickjs_dir / "include"
        for h_name in ("CQuickJS.h", "module.modulemap", "quickjs.h", "quickjs-libc.h"):
            self.assertTrue((include_dir / h_name).is_file(), f"Missing include/{h_name}")

        js_host_dir = TVOS_DIR / "Sources" / "MarcoTVCore" / "Resources" / "js-host"
        for script_name in ("crypto-js.js", "catvod.mjs", "module-interop.js", "drpy-core.js"):
            self.assertTrue((js_host_dir / script_name).is_file(), f"Missing js-host/{script_name}")

    def test_tvos_layered_icons_and_top_shelf_dimensions(self) -> None:
        brand = (
            TVOS_DIR
            / "RunnerProject"
            / "Assets.xcassets"
            / "App Icon & Top Shelf Image.brandassets"
        )
        expected_pngs = {
            brand / "App Icon.imagestack" / "Back.imagestacklayer" / "Content.imageset" / "back_400x240.png": (400, 240),
            brand / "App Icon.imagestack" / "Back.imagestacklayer" / "Content.imageset" / "back_800x480.png": (800, 480),
            brand / "App Icon.imagestack" / "Front.imagestacklayer" / "Content.imageset" / "front_400x240.png": (400, 240),
            brand / "App Icon.imagestack" / "Front.imagestacklayer" / "Content.imageset" / "front_800x480.png": (800, 480),
            brand / "App Icon - App Store.imagestack" / "Back.imagestacklayer" / "Content.imageset" / "back_1280x768.png": (1280, 768),
            brand / "App Icon - App Store.imagestack" / "Front.imagestacklayer" / "Content.imageset" / "front_1280x768.png": (1280, 768),
            brand / "Top Shelf Image.imageset" / "topshelf_1920x720.png": (1920, 720),
            brand / "Top Shelf Image Wide.imageset" / "topshelf_wide_2320x720.png": (2320, 720),
        }
        for png_path, expected_wh in expected_pngs.items():
            self.assertTrue(png_path.is_file(), f"Missing generated PNG: {png_path}")
            self.assertEqual(prepare_tvos.png_dimensions(png_path), expected_wh)

    def test_public_content_guardrail_compliance(self) -> None:
        import re
        import subprocess

        repo_root = TVOS_DIR.parent
        guard_script = repo_root / "scripts" / "check_public_content.py"
        ns: dict[str, object] = {}
        guard_lines = guard_script.read_text(encoding="utf-8").splitlines()[:20]
        exec("\n".join(guard_lines), {"__file__": str(guard_script)}, ns)
        excluded = set(ns["EXCLUDED"])  # type: ignore[arg-type]
        allowed_hosts = set(ns["ALLOWED_HOSTS"])  # type: ignore[arg-type]

        proc_status = subprocess.run(
            ["git", "status", "--porcelain", "-uall", "tvos"],
            cwd=repo_root,
            capture_output=True,
            text=True,
            check=True,
        )
        proc_tracked = subprocess.run(
            ["git", "ls-files", "tvos"],
            cwd=repo_root,
            capture_output=True,
            text=True,
            check=True,
        )
        rel_candidates = {
            line[3:].strip()
            for line in proc_status.stdout.splitlines()
            if line.strip() and not line.startswith("D ")
        } | {line.strip() for line in proc_tracked.stdout.splitlines() if line.strip()}
        tracked_or_unignored = [
            repo_root / rel for rel in sorted(rel_candidates) if (repo_root / rel).is_file()
        ]
        self.assertGreaterEqual(len(tracked_or_unignored), 30)

        url_re = re.compile(r'https?://([^/\s"\'<>\\)`\u3000-\u303f\uff00-\uffef]+)')
        secret_patterns = [
            r"gh[pousr]_[A-Za-z0-9]{25,}",
            r"github_pat_[A-Za-z0-9_]{30,}",
            r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----",
            r"[A-Za-z]:[/\\](?:Users|TV)[/\\]",
            r"192\.168\.\d+\.\d+",
        ]

        for p in tracked_or_unignored:
            rel = p.relative_to(repo_root)
            self.assertFalse(
                any(part in excluded for part in rel.parts),
                f"{rel}: contains excluded directory name",
            )
            self.assertNotIn(
                p.suffix,
                {".apk", ".aab", ".p12", ".jks", ".keystore", ".rar", ".zip", ".bin", ".mp4", ".ipa"},
                f"{rel}: excluded binary extension",
            )
            if p.suffix == ".png":
                continue
            text = p.read_bytes().decode("utf-8")
            for pat in secret_patterns:
                self.assertIsNone(re.search(pat, text), f"{rel}: matched private pattern {pat}")
            for m in url_re.finditer(text):
                authority = m.group(1)
                if re.fullmatch(r"\$(?:[A-Za-z_][A-Za-z0-9_]*|\{[A-Za-z_][A-Za-z0-9_.]*\})", authority):
                    continue
                host = authority.split(":")[0].lower().rstrip(".,;")
                if host not in allowed_hosts and not host.endswith((".test", ".example", ".invalid")):
                    self.fail(f"{rel}: unlisted network host {host!r} in {m.group(0)!r}")

    def test_info_plist_and_pbxproj_xml_valid_and_complete(self) -> None:
        info_path = TVOS_DIR / "RunnerProject" / "Info.plist"
        info = plistlib.loads(info_path.read_bytes())
        self.assertEqual(info["CFBundleIdentifier"], "com.pilipala.marcoMovie.tv")
        self.assertEqual(info["MinimumOSVersion"], "16.0")
        self.assertEqual(info["UIDeviceFamily"], [3])
        self.assertTrue(info["NSAppTransportSecurity"]["NSAllowsArbitraryLoads"])

        pbx_path = TVOS_DIR / "RunnerProject" / "MarcoMovieTV.xcodeproj" / "project.pbxproj"
        pbx = plistlib.loads(pbx_path.read_bytes())
        self.assertEqual(pbx["objectVersion"], "56")
        objects = pbx["objects"]

        referenced_paths = {
            obj.get("path")
            for obj in objects.values()
            if isinstance(obj, dict) and obj.get("isa") == "PBXFileReference"
        }

        core_swift = sorted((TVOS_DIR / "Sources" / "MarcoTVCore").rglob("*.swift"))
        app_swift = sorted((TVOS_DIR / "Sources" / "MarcoMovieTV").rglob("*.swift"))
        self.assertGreaterEqual(len(core_swift), 14)
        self.assertGreaterEqual(len(app_swift), 11)

        for required_rel in (
            "../Sources/MarcoTVCore/Network/NetdiskService.swift",
            "../Sources/MarcoTVCore/Network/NetdiskRangeProxyServer.swift",
            "../Sources/MarcoTVCore/Network/NetdiskShareResolver.swift",
            "../Sources/MarcoMovieTV/NetdiskAccountSheetView.swift",
        ):
            self.assertIn(required_rel, referenced_paths, f"Phase 2 file missing from project.pbxproj: {required_rel}")

        for swift_file in core_swift + app_swift:
            rel_path = f"../{swift_file.relative_to(TVOS_DIR).as_posix()}"
            self.assertIn(rel_path, referenced_paths, f"{rel_path} missing from project.pbxproj")

        for c_file in sorted((TVOS_DIR / "Sources" / "CQuickJS").glob("*.c")):
            rel_path = f"../{c_file.relative_to(TVOS_DIR).as_posix()}"
            self.assertIn(rel_path, referenced_paths, f"{rel_path} missing from project.pbxproj")

    def test_swift_files_have_balanced_delimiters_and_imports(self) -> None:
        swift_files = sorted(TVOS_DIR.rglob("*.swift"))
        self.assertGreaterEqual(len(swift_files), 28)

        pairs = {"{": "}", "(": ")", "[": "]"}
        closing = set(pairs.values())

        for sf in swift_files:
            text = sf.read_text(encoding="utf-8")
            if sf.name != "Package.swift":
                self.assertRegex(text, r"(?m)^import\s+\w+", f"{sf.name} has no import statement")
            stripped = _strip_swift_strings_and_comments(text)
            stack: list[str] = []
            for ch in stripped:
                if ch in pairs:
                    stack.append(pairs[ch])
                elif ch in closing:
                    self.assertTrue(stack, f"Unexpected '{ch}' in {sf}")
                    expected = stack.pop()
                    self.assertEqual(ch, expected, f"Mismatched '{ch}' (expected '{expected}') in {sf}")
            self.assertEqual(stack, [], f"Unclosed delimiters {stack} in {sf}")

    def test_tvos16_availability_guards_and_phase2_tests(self) -> None:
        import re

        for ui_file in sorted((TVOS_DIR / "Sources" / "MarcoMovieTV").rglob("*.swift")):
            lines = ui_file.read_text(encoding="utf-8").splitlines()
            for idx, line in enumerate(lines):
                if re.search(r"\bMenu\s*\(", line):
                    prev_window = "\n".join(lines[max(0, idx - 3) : idx + 1])
                    self.assertIn(
                        "#available(tvOS 17.0",
                        prev_window,
                        f"{ui_file.name}:{idx + 1}: Menu(...) must be guarded by #available(tvOS 17.0, *)",
                    )
                self.assertIsNone(
                    re.search(r"\.onChange\s*\(\s*of:[^)]+\)\s*\{\s*\w+\s*,\s*\w+\s+in", line),
                    f"{ui_file.name}:{idx + 1}: 2-arg onChange requires tvOS 17.0",
                )

        phase2_test = TVOS_DIR / "Tests" / "MarcoTVCoreTests" / "NetdiskAndRangeProxyTests.swift"
        self.assertTrue(phase2_test.is_file(), "Missing NetdiskAndRangeProxyTests.swift")
        test_text = phase2_test.read_text(encoding="utf-8")
        for token in (
            "testHeaderPolicyRedirectIsolationAndIdentityEncoding",
            "testRangeProxyHeadMultiChunkStreaming416AndSeekPreemption",
            "testNetdiskQrStateMachineAndShareResolver",
            "testKeychainNetdiskCrudBackupIsolationAndLanPush",
        ):
            self.assertIn(token, test_text)

    def test_patch_tvos_ipa_macho_and_plist_and_packaging(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            app_dir = tmp_path / "MarcoMovieTV.app"
            app_dir.mkdir(parents=True)
            dsym_dir = app_dir / "MarcoMovieTV.app.dSYM"
            dsym_dir.mkdir()
            (dsym_dir / "dummy").write_text("strip me", encoding="utf-8")

            # Write Info.plist with newer MinimumOSVersion 17.4 and wrong UIDeviceFamily
            (app_dir / "Info.plist").write_bytes(
                plistlib.dumps(
                    {
                        "CFBundleExecutable": "MarcoMovieTV",
                        "CFBundleIdentifier": "com.pilipala.marcoMovie.tv",
                        "MinimumOSVersion": "17.4",
                        "UIDeviceFamily": [1, 2],
                    },
                    fmt=plistlib.FMT_XML,
                )
            )

            # Construct synthetic 64-bit arm64 Mach-O with LC_BUILD_VERSION (cmd=0x32, platform=3, minos=17.4)
            lc_build = struct.pack(
                "<IIIIII",
                patch_tvos_ipa.LC_BUILD_VERSION,
                24,
                patch_tvos_ipa.PLATFORM_TVOS,
                0x00110400,  # tvOS 17.4.0 -> should be clamped to 16.0.0 (0x00100000)
                0x00110400,  # sdk 17.4.0
                0,
            )
            mach_header = struct.pack(
                "<IIIIIIII",
                0xFEEDFACF,  # MH_MAGIC_64 (little-endian cffaedfe)
                patch_tvos_ipa.CPU_TYPE_ARM64,
                0,
                2,  # MH_EXECUTE
                1,  # ncmds
                len(lc_build),
                0,
                0,
            )
            bin_path = app_dir / "MarcoMovieTV"
            bin_path.write_bytes(mach_header + lc_build + b"\x00" * 64)

            ipa_out = tmp_path / "MarcoMovieTV.ipa"
            patch_tvos_ipa.main([str(app_dir), "--skip-codesign", "--ipa", str(ipa_out)])

            self.assertFalse(dsym_dir.exists(), ".dSYM directory must be stripped")
            patched_plist = plistlib.loads((app_dir / "Info.plist").read_bytes())
            self.assertEqual(patched_plist["MinimumOSVersion"], "16.0")
            self.assertEqual(patched_plist["UIDeviceFamily"], [3])

            patched_bin = bin_path.read_bytes()
            _platform, patched_minos = struct.unpack_from("<II", patched_bin, 32 + 8)
            self.assertEqual(patched_minos, patch_tvos_ipa.TVOS_16_0_VERSION)

            self.assertTrue(ipa_out.is_file())
            with zipfile.ZipFile(ipa_out, "r") as zf:
                names = set(zf.namelist())
                self.assertIn("Payload/MarcoMovieTV.app/MarcoMovieTV", names)
                self.assertIn("Payload/MarcoMovieTV.app/Info.plist", names)
                exec_info = zf.getinfo("Payload/MarcoMovieTV.app/MarcoMovieTV")
                self.assertEqual((exec_info.external_attr >> 16) & 0o777, 0o755)


if __name__ == "__main__":
    unittest.main()
