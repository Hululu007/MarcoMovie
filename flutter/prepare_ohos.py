#!/usr/bin/env python3
"""Prepare HarmonyOS NEXT (OpenHarmony) Stage-model assets, versions, and pubspec shims."""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
REPO_ROOT = ROOT.parent
DEFAULT_ICON_SOURCE = REPO_ROOT / "docs" / "images" / "app-icon-512.png"

DEFAULT_OHOS_VERSION_NAME = "0.1.0"
DEFAULT_OHOS_VERSION_CODE = 1000001

NON_OHOS_PACKAGES = {
    "media_kit_libs_video",
    "path_provider_foundation",
    "media_kit_libs_ios_video",
    "media_kit_libs_macos_video",
    "media_kit_libs_windows_video",
}

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


def _strip_json5_comments_and_trailing_commas(raw: str) -> str:
    """Convert a JSON5 configuration document into standard JSON for parsing."""
    out: list[str] = []
    i = 0
    n = len(raw)
    in_string = False
    quote_char = ""
    while i < n:
        ch = raw[i]
        if in_string:
            out.append(ch)
            if ch == "\\" and i + 1 < n:
                out.append(raw[i + 1])
                i += 2
                continue
            if ch == quote_char:
                in_string = False
            i += 1
            continue
        if ch in ('"', "'"):
            in_string = True
            quote_char = ch
            out.append(ch)
            i += 1
            continue
        if ch == "/" and i + 1 < n and raw[i + 1] == "/":
            i += 2
            while i < n and raw[i] not in ("\n", "\r"):
                i += 1
            continue
        if ch == "/" and i + 1 < n and raw[i + 1] == "*":
            i += 2
            while i + 1 < n and not (raw[i] == "*" and raw[i + 1] == "/"):
                i += 1
            i += 2
            continue
        out.append(ch)
        i += 1
    cleaned = "".join(out)
    cleaned = re.sub(r",(\s*[}\]])", r"\1", cleaned)
    return cleaned


def load_json5(path: Path) -> dict:
    text = path.read_text(encoding="utf-8")
    return json.loads(_strip_json5_comments_and_trailing_commas(text))


def _copy_bytes_idempotent(src: Path, dst: Path) -> bool:
    payload = src.read_bytes()
    if len(payload) < 24 or payload[:8] != PNG_SIGNATURE:
        raise ValueError(f"Invalid PNG icon source: {src}")
    dst.parent.mkdir(parents=True, exist_ok=True)
    if dst.exists() and dst.read_bytes() == payload:
        return False
    dst.write_bytes(payload)
    return True


def sync_ohos_icons(project_root: Path = ROOT, icon_source: Path | None = None) -> list[Path]:
    """Idempotently populate HarmonyOS AppScope and entry media icon PNGs."""
    source = icon_source or (project_root.parent / "docs" / "images" / "app-icon-512.png")
    if not source.exists():
        source = DEFAULT_ICON_SOURCE
    if not source.exists():
        raise FileNotFoundError(f"Missing app icon master: {source}")

    targets = [
        project_root / "ohos" / "AppScope" / "resources" / "base" / "media" / "app_icon.png",
        project_root / "ohos" / "entry" / "src" / "main" / "resources" / "base" / "media" / "icon.png",
    ]
    for target in targets:
        _copy_bytes_idempotent(source, target)
    return targets


def resolve_harmonyos_version(project_root: Path = ROOT) -> tuple[str, int]:
    """Read HarmonyOS versionName and versionCode from edition-versions.json with defaults."""
    editions_file = project_root / "edition-versions.json"
    if not editions_file.exists():
        return DEFAULT_OHOS_VERSION_NAME, DEFAULT_OHOS_VERSION_CODE

    data = json.loads(editions_file.read_text(encoding="utf-8"))
    harmony_cfg = data.get("harmonyos")
    if not isinstance(harmony_cfg, dict):
        return DEFAULT_OHOS_VERSION_NAME, DEFAULT_OHOS_VERSION_CODE

    version_name = str(harmony_cfg.get("versionName") or DEFAULT_OHOS_VERSION_NAME).strip()
    if not version_name:
        version_name = DEFAULT_OHOS_VERSION_NAME

    if harmony_cfg.get("versionCode") is not None:
        version_code = int(harmony_cfg["versionCode"])
    elif harmony_cfg.get("buildNumber") is not None:
        raw_build = int(harmony_cfg["buildNumber"])
        version_code = raw_build if raw_build >= 1000000 else (1000000 + raw_build)
    else:
        version_code = DEFAULT_OHOS_VERSION_CODE

    return version_name, version_code


def _write_text_idempotent(path: Path, content: str) -> bool:
    normalized = content if content.endswith("\n") else content + "\n"
    if path.exists():
        existing = path.read_text(encoding="utf-8")
        if existing == normalized:
            return False
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="\n") as handle:
        handle.write(normalized)
    return True


def sync_ohos_version(project_root: Path = ROOT) -> tuple[str, int]:
    """Synchronize ohos/AppScope/app.json5 and oh-package.json5 with edition-versions.json."""
    version_name, version_code = resolve_harmonyos_version(project_root)
    app_json5 = project_root / "ohos" / "AppScope" / "app.json5"
    if app_json5.exists():
        doc = load_json5(app_json5)
    else:
        doc = {
            "app": {
                "bundleName": "com.pilipala.marcomovie",
                "vendor": "Pilipala",
                "versionCode": version_code,
                "versionName": version_name,
                "icon": "$media:app_icon",
                "label": "$string:app_name",
            }
        }
    app_obj = doc.setdefault("app", {})
    app_obj["versionCode"] = version_code
    app_obj["versionName"] = version_name
    _write_text_idempotent(app_json5, json.dumps(doc, indent=2, ensure_ascii=False))

    for pkg_rel in ("ohos/oh-package.json5", "ohos/entry/oh-package.json5"):
        pkg_path = project_root / pkg_rel
        if pkg_path.exists():
            pkg_doc = load_json5(pkg_path)
            pkg_doc["version"] = version_name
            _write_text_idempotent(pkg_path, json.dumps(pkg_doc, indent=2, ensure_ascii=False))

    return version_name, version_code


def sync_flutter_har_if_available(project_root: Path = ROOT) -> Path | None:
    """Copy flutter.har from FLUTTER_ROOT engine cache into ohos/har/flutter.har when available."""
    flutter_root_env = os.environ.get("FLUTTER_ROOT", "").strip()
    if not flutter_root_env:
        return None
    sdk_root = Path(flutter_root_env)
    candidates = [
        sdk_root / "bin" / "cache" / "artifacts" / "engine" / "ohos-arm64-release" / "flutter.har",
        sdk_root / "bin" / "cache" / "artifacts" / "engine" / "ohos-arm64" / "flutter.har",
        sdk_root / "bin" / "cache" / "artifacts" / "engine" / "ohos-x64" / "flutter.har",
    ]
    target = project_root / "ohos" / "har" / "flutter.har"
    if target.exists():
        return target
    for candidate in candidates:
        if candidate.exists():
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(candidate, target)
            return target
    return None


def _remove_non_ohos_dependencies(pubspec_text: str) -> str:
    lines = pubspec_text.splitlines(keepends=True)
    out: list[str] = []
    skip_block = False
    dep_pattern = re.compile(r"^  ([A-Za-z0-9_]+)\s*:(.*)$")

    for line in lines:
        if skip_block:
            stripped = line.strip()
            indent = len(line) - len(line.lstrip(" "))
            if stripped == "" or stripped.startswith("#"):
                continue
            if indent >= 4:
                continue
            skip_block = False

        match = dep_pattern.match(line)
        if match:
            pkg_name = match.group(1)
            rest = match.group(2).split("#", 1)[0].strip()
            if pkg_name in NON_OHOS_PACKAGES:
                if rest == "":
                    skip_block = True
                continue
        out.append(line)

    return "".join(out)


def _relax_quickjs_pubspec(pubspec_text: str) -> str:
    lines = pubspec_text.splitlines(keepends=True)
    out: list[str] = []
    in_env = False
    saw_sdk = False
    saw_flutter = False
    line_ending = "\r\n" if "\r\n" in pubspec_text else "\n"

    for line in lines:
        top_section = re.match(r"^([A-Za-z0-9_]+)\s*:", line)
        if top_section:
            if in_env and saw_sdk and not saw_flutter:
                out.append(f'  flutter: ">=3.22.0"{line_ending}')
                saw_flutter = True
            in_env = top_section.group(1) == "environment"

        if in_env and re.match(r"^\s+sdk\s*:", line):
            out.append(f'  sdk: ">=3.3.0 <4.0.0"{line_ending}')
            saw_sdk = True
            continue
        if in_env and re.match(r"^\s+flutter\s*:", line):
            out.append(f'  flutter: ">=3.22.0"{line_ending}')
            saw_flutter = True
            continue
        if re.match(r"^\s+flutter_lints\s*:", line):
            out.append(f'  flutter_lints: ">=4.0.0 <6.0.0"{line_ending}')
            continue

        out.append(line)

    if in_env and saw_sdk and not saw_flutter:
        out.append(f'  flutter: ">=3.22.0"{line_ending}')

    return "".join(out)


def _backup_dir(project_root: Path) -> Path:
    return project_root / "ohos" / ".pubspec_backup"


def patch_pubspecs(project_root: Path = ROOT) -> None:
    """Back up and patch root and quickjs_engine pubspec.yaml files for OHOS Flutter."""
    backup_root = _backup_dir(project_root)
    backup_root.mkdir(parents=True, exist_ok=True)

    root_pubspec = project_root / "pubspec.yaml"
    qjs_pubspec = project_root / "packages" / "quickjs_engine" / "pubspec.yaml"
    root_lock = project_root / "pubspec.lock"

    root_backup = backup_root / "pubspec.yaml.bak"
    qjs_backup = backup_root / "quickjs_engine.pubspec.yaml.bak"
    lock_backup = backup_root / "pubspec.lock.bak"

    if not root_pubspec.exists():
        raise FileNotFoundError(f"Missing {root_pubspec}")
    if not qjs_pubspec.exists():
        raise FileNotFoundError(f"Missing {qjs_pubspec}")

    if not root_backup.exists():
        root_backup.write_bytes(root_pubspec.read_bytes())
    if not qjs_backup.exists():
        qjs_backup.write_bytes(qjs_pubspec.read_bytes())
    if root_lock.exists() and not lock_backup.exists():
        lock_backup.write_bytes(root_lock.read_bytes())

    original_root_text = root_backup.read_bytes().decode("utf-8")
    patched_root_text = _remove_non_ohos_dependencies(original_root_text)
    root_pubspec.write_bytes(patched_root_text.encode("utf-8"))

    original_qjs_text = qjs_backup.read_bytes().decode("utf-8")
    patched_qjs_text = _relax_quickjs_pubspec(original_qjs_text)
    qjs_pubspec.write_bytes(patched_qjs_text.encode("utf-8"))

    if root_lock.exists():
        root_lock.unlink()


def restore_pubspecs(project_root: Path = ROOT) -> bool:
    """Restore backed-up pubspec.yaml, quickjs_engine/pubspec.yaml, and pubspec.lock byte-for-byte."""
    backup_root = _backup_dir(project_root)
    if not backup_root.exists():
        return False

    root_pubspec = project_root / "pubspec.yaml"
    qjs_pubspec = project_root / "packages" / "quickjs_engine" / "pubspec.yaml"
    root_lock = project_root / "pubspec.lock"

    root_backup = backup_root / "pubspec.yaml.bak"
    qjs_backup = backup_root / "quickjs_engine.pubspec.yaml.bak"
    lock_backup = backup_root / "pubspec.lock.bak"

    restored_any = False
    if root_backup.exists():
        root_pubspec.parent.mkdir(parents=True, exist_ok=True)
        root_pubspec.write_bytes(root_backup.read_bytes())
        restored_any = True
    if qjs_backup.exists():
        qjs_pubspec.parent.mkdir(parents=True, exist_ok=True)
        qjs_pubspec.write_bytes(qjs_backup.read_bytes())
        restored_any = True
    if lock_backup.exists():
        root_lock.write_bytes(lock_backup.read_bytes())
        restored_any = True

    shutil.rmtree(backup_root, ignore_errors=True)
    return restored_any


def prepare_ohos(
    project_root: Path = ROOT,
    icon_source: Path | None = None,
    patch_pubspec: bool = False,
    restore_pubspec: bool = False,
) -> None:
    if restore_pubspec:
        restore_pubspecs(project_root)
        return

    sync_ohos_icons(project_root, icon_source=icon_source)
    sync_ohos_version(project_root)
    sync_flutter_har_if_available(project_root)
    if patch_pubspec:
        patch_pubspecs(project_root)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Prepare HarmonyOS NEXT Flutter shell.")
    parser.add_argument(
        "--project-root",
        type=Path,
        default=ROOT,
        help="Path to the flutter project directory.",
    )
    parser.add_argument(
        "--icon-source",
        type=Path,
        default=None,
        help="Optional override path to the 512x512 app icon PNG.",
    )
    group = parser.add_mutually_exclusive_group()
    group.add_argument(
        "--patch-pubspec",
        action="store_true",
        help="Back up and patch pubspec files for OpenHarmony Flutter pub resolution.",
    )
    group.add_argument(
        "--restore-pubspec",
        action="store_true",
        help="Restore backed-up pubspec files byte-for-byte.",
    )
    args = parser.parse_args(argv)
    prepare_ohos(
        project_root=args.project_root.resolve(),
        icon_source=args.icon_source.resolve() if args.icon_source else None,
        patch_pubspec=args.patch_pubspec,
        restore_pubspec=args.restore_pubspec,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
