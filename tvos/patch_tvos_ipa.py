#!/usr/bin/env python3
# Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
"""Normalize tvOS 16.0 deployment targets, ad-hoc sign with TrollStore entitlements, and pack IPA."""

from __future__ import annotations

import argparse
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import sys
import zipfile

MH_MAGIC_64 = bytes.fromhex("cffaedfe")
FAT_MAGICS = (bytes.fromhex("cafebabe"), bytes.fromhex("cafebabf"))
CPU_TYPE_ARM64 = 0x0100000C
LC_VERSION_MIN_TVOS = 0x2F
LC_BUILD_VERSION = 0x32
PLATFORM_TVOS = 3
TVOS_16_0_VERSION = 0x00100000
DEFAULT_BUNDLE_ID = "com.pilipala.marcoMovie.tv"


def strip_dsym_bundles(app_dir: Path) -> None:
    """Remove accidental .dSYM directories so sideload signers never encounter MH_DSYM objects."""
    for dsym in sorted(app_dir.rglob("*.dSYM")):
        if dsym.is_dir() and not dsym.is_symlink():
            shutil.rmtree(dsym)


def _version_tuple(ver_str: str) -> tuple[int, int, int]:
    parts = [int(p) for p in ver_str.strip().split(".") if p.isdigit()]
    while len(parts) < 3:
        parts.append(0)
    return parts[0], parts[1], parts[2]


def patch_bundle_plists(app_dir: Path, target_version: str = "16.0") -> int:
    """Normalize MinimumOSVersion to 16.0 across all Info.plist files inside .app."""
    root_plist = app_dir / "Info.plist"
    if not root_plist.is_file():
        raise ValueError(f"Missing application Info.plist in {app_dir}")

    target_tuple = _version_tuple(target_version)
    patched_count = 0

    for path in sorted(app_dir.rglob("Info.plist")):
        if path.is_symlink() or not path.is_file():
            continue
        metadata = plistlib.loads(path.read_bytes())
        changed = False
        minimum = str(metadata.get("MinimumOSVersion") or "").strip()
        if not minimum or _version_tuple(minimum) > target_tuple:
            metadata["MinimumOSVersion"] = target_version
            changed = True
        if path == root_plist and metadata.get("UIDeviceFamily") != [3]:
            metadata["UIDeviceFamily"] = [3]
            changed = True
        if changed:
            path.write_bytes(plistlib.dumps(metadata, fmt=plistlib.FMT_XML, sort_keys=False))
            patched_count += 1

    return patched_count


def patch_macho_tvos_minos(binary_path: Path, target_minos: int = TVOS_16_0_VERSION) -> bool:
    """Validate arm64 tvOS Mach-O and clamp LC_BUILD_VERSION / LC_VERSION_MIN_TVOS minos to 16.0."""
    with binary_path.open("rb") as stream:
        magic = stream.read(4)

    if magic in FAT_MAGICS:
        lipo = shutil.which("lipo")
        if not lipo:
            raise ValueError(f"{binary_path}: universal Mach-O requires lipo to thin arm64 slice")
        subprocess.run([lipo, "-thin", "arm64", str(binary_path), "-output", str(binary_path)], check=True)
    elif magic != MH_MAGIC_64:
        return False

    data = bytearray(binary_path.read_bytes())
    if len(data) < 32 or bytes(data[:4]) != MH_MAGIC_64:
        raise ValueError(f"{binary_path}: truncated or unsupported Mach-O")

    cpu, _cpusub, filetype, ncmds, sizeofcmds, _flags, _reserved = struct.unpack_from("<IIIIIII", data, 4)
    if cpu != CPU_TYPE_ARM64:
        raise ValueError(f"{binary_path}: expected arm64 tvOS binary, got cpu={cpu:#x}")
    if filetype not in (2, 6, 8):
        raise ValueError(f"{binary_path}: unsupported Mach-O filetype {filetype}")
    if sizeofcmds > len(data) - 32 or ncmds > sizeofcmds // 8:
        raise ValueError(f"{binary_path}: invalid Mach-O load-command bounds")

    pos = 32
    saw_tvos_target = False
    modified = False

    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, pos)
        if cmdsize < 8 or pos + cmdsize > 32 + sizeofcmds:
            raise ValueError(f"{binary_path}: malformed Mach-O load command")

        if cmd == LC_BUILD_VERSION:
            if cmdsize < 24:
                raise ValueError(f"{binary_path}: truncated LC_BUILD_VERSION")
            platform, minos, _sdk, _ntools = struct.unpack_from("<IIII", data, pos + 8)
            if platform != PLATFORM_TVOS:
                raise ValueError(f"{binary_path}: expected PLATFORM_TVOS (3), got platform={platform}")
            saw_tvos_target = True
            if minos > target_minos:
                struct.pack_into("<I", data, pos + 12, target_minos)
                modified = True
        elif cmd == LC_VERSION_MIN_TVOS:
            if cmdsize < 16:
                raise ValueError(f"{binary_path}: truncated LC_VERSION_MIN_TVOS")
            minos, _sdk = struct.unpack_from("<II", data, pos + 8)
            saw_tvos_target = True
            if minos > target_minos:
                struct.pack_into("<I", data, pos + 8, target_minos)
                modified = True

        pos += cmdsize

    if pos != 32 + sizeofcmds or not saw_tvos_target:
        raise ValueError(f"{binary_path}: missing tvOS deployment load command")

    if modified:
        binary_path.write_bytes(bytes(data))
    return modified


def patch_app_binaries(app_dir: Path, target_minos: int = TVOS_16_0_VERSION) -> int:
    """Validate and clamp all Mach-O binaries inside an .app bundle."""
    total_binaries = 0
    for path in sorted(app_dir.rglob("*")):
        if path.is_symlink() or not path.is_file():
            continue
        with path.open("rb") as stream:
            magic = stream.read(4)
        if magic not in FAT_MAGICS and magic != MH_MAGIC_64:
            continue
        patch_macho_tvos_minos(path, target_minos=target_minos)
        total_binaries += 1

    if total_binaries == 0:
        raise ValueError(f"No arm64 tvOS binaries found inside {app_dir}")
    return total_binaries


def build_trollstore_entitlements(bundle_id: str = DEFAULT_BUNDLE_ID) -> dict[str, object]:
    return {
        "application-identifier": f"TROLLSTORE.{bundle_id}",
        "com.apple.developer.team-identifier": "TROLLSTORE",
        "get-task-allow": True,
    }


def codesign_bundle(app_dir: Path, bundle_id: str = DEFAULT_BUNDLE_ID) -> Path:
    entitlements_path = app_dir.parent / "trollstore.entitlements"
    entitlements_path.write_bytes(
        plistlib.dumps(build_trollstore_entitlements(bundle_id), fmt=plistlib.FMT_XML, sort_keys=False)
    )
    codesign = shutil.which("codesign")
    if not codesign:
        raise RuntimeError("codesign utility not found on PATH")

    fw_dir = app_dir / "Frameworks"
    if fw_dir.is_dir():
        for item in sorted(fw_dir.iterdir()):
            if item.suffix in (".framework", ".dylib"):
                subprocess.run(
                    [codesign, "--force", "--sign", "-", "--timestamp=none", str(item)],
                    check=True,
                )

    subprocess.run(
        [
            codesign,
            "--force",
            "--sign",
            "-",
            "--timestamp=none",
            "--entitlements",
            str(entitlements_path),
            str(app_dir),
        ],
        check=True,
    )
    subprocess.run([codesign, "--verify", "--deep", "--strict", str(app_dir)], check=True)
    return entitlements_path


def pack_ipa(app_dir: Path, ipa_path: Path) -> Path:
    """Package Payload/<App>.app into an .ipa archive with POSIX executable bits preserved."""
    ipa_path.parent.mkdir(parents=True, exist_ok=True)
    root_plist = plistlib.loads((app_dir / "Info.plist").read_bytes())
    main_exec = str(root_plist.get("CFBundleExecutable") or app_dir.stem)

    with zipfile.ZipFile(ipa_path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        for item in sorted(app_dir.rglob("*")):
            if item.is_symlink() or not item.is_file():
                continue
            rel = item.relative_to(app_dir).as_posix()
            arcname = f"Payload/{app_dir.name}/{rel}"
            zinfo = zipfile.ZipInfo(arcname)
            zinfo.compress_type = zipfile.ZIP_DEFLATED
            is_exec = item.name == main_exec or item.suffix == ".dylib"
            if not is_exec:
                with item.open("rb") as stream:
                    is_exec = stream.read(4) == MH_MAGIC_64
            mode = 0o100755 if is_exec else 0o100644
            zinfo.external_attr = mode << 16
            zf.writestr(zinfo, item.read_bytes())

    return ipa_path


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description="Patch, ad-hoc sign, and pack a tvOS 16.0 .app / .ipa")
    parser.add_argument("app_dir", type=Path, help="Path to MarcoMovieTV.app")
    parser.add_argument("--ipa", type=Path, default=None, help="Optional output .ipa path")
    parser.add_argument("--skip-codesign", action="store_true", help="Skip macOS codesign step")
    args = parser.parse_args(argv)

    app_dir = args.app_dir.resolve()
    strip_dsym_bundles(app_dir)
    patch_bundle_plists(app_dir, target_version="16.0")
    patch_app_binaries(app_dir, target_minos=TVOS_16_0_VERSION)

    root_meta = plistlib.loads((app_dir / "Info.plist").read_bytes())
    bundle_id = str(root_meta.get("CFBundleIdentifier") or DEFAULT_BUNDLE_ID)

    if not args.skip_codesign:
        codesign_bundle(app_dir, bundle_id=bundle_id)

    if args.ipa is not None:
        pack_ipa(app_dir, args.ipa.resolve())


if __name__ == "__main__":
    main()
