"""Validate real iOS deployment targets (14.0 for Xcode 16 compat, 15.0 for Xcode 26 Liquid Glass), then ad-hoc sign for sideloading."""
import os
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import sys


def _parse_min_ios(min_ios: str) -> tuple[tuple[int, int, int], int]:
    parts = [int(p) for p in min_ios.strip().split(".") if p.strip()]
    major = parts[0] if len(parts) > 0 else 14
    minor = parts[1] if len(parts) > 1 else 0
    patch = parts[2] if len(parts) > 2 else 0
    return (major, minor, patch), (major << 16) | (minor << 8) | patch


def strip_dsym_bundles(app_dir: Path) -> None:
    """Remove any accidental .dSYM bundles so ldid/TrollStore never sees MH_DSYM Mach-Os."""
    for dsym in sorted(app_dir.rglob('*.dSYM')):
        if dsym.is_dir() and not dsym.is_symlink():
            shutil.rmtree(dsym)


def validate_app(
    app_dir: Path,
    max_min_ios: str | None = None,
    expected_version: str | None = None,
    expected_build: str | None = None,
) -> None:
    """Reject dependencies compiled for a newer iOS. Rewriting minos hides dyld errors."""
    target_str = (max_min_ios or os.environ.get("MARCOMOVIE_IOS_MIN_TARGET") or "14.0").strip()
    max_tuple, max_packed = _parse_min_ios(target_str)
    app_plist = app_dir / 'Info.plist'
    if not app_plist.is_file():
        raise ValueError('Missing application Info.plist')
    app_metadata = plistlib.loads(app_plist.read_bytes())
    if expected_version:
        actual_ver = str(app_metadata.get('CFBundleShortVersionString') or '').strip()
        if actual_ver != expected_version.strip():
            raise ValueError(
                f'{app_plist}: CFBundleShortVersionString={actual_ver!r} != expected {expected_version!r}'
            )
    if expected_build:
        actual_build = str(app_metadata.get('CFBundleVersion') or '').strip()
        if actual_build != str(expected_build).strip():
            raise ValueError(
                f'{app_plist}: CFBundleVersion={actual_build!r} != expected {expected_build!r}'
            )
    binaries = 0
    for path in app_dir.rglob('*'):
        if path.is_symlink() or not path.is_file():
            continue
        if path.name == 'Info.plist':
            metadata = plistlib.loads(path.read_bytes())
            minimum = metadata.get('MinimumOSVersion')
            if minimum and tuple((list(map(int, minimum.split('.'))) + [0, 0])[:3]) > max_tuple:
                raise ValueError(f'{path}: requires iOS {minimum}')
        with path.open('rb') as stream:
            magic = stream.read(4)
        if magic in (bytes.fromhex('cafebabe'), bytes.fromhex('cafebabf')):
            subprocess.run(['lipo', '-thin', 'arm64', str(path), '-output', str(path)], check=True)
        elif magic != bytes.fromhex('cffaedfe'):
            continue
        data = path.read_bytes()
        if len(data) < 32 or data[:4] != bytes.fromhex('cffaedfe'):
            raise ValueError(f'{path}: truncated or unsupported Mach-O')
        binaries += 1
        cpu, _sub, filetype = struct.unpack_from('<III', data, 4)
        if cpu != 0x0100000c:
            raise ValueError(f'{path}: expected arm64 iOS device binary')
        if filetype not in (2, 6):
            raise ValueError(f'{path}: unsupported Mach-O filetype {filetype}')
        count, size = struct.unpack_from('<II', data, 16)
        if size > len(data) - 32 or count > size // 8:
            raise ValueError(f'{path}: invalid load-command bounds')
        pos = 32
        has_target = False
        for _ in range(count):
            cmd, length = struct.unpack_from('<II', data, pos)
            if length < 8 or pos + length > 32 + size:
                raise ValueError(f'{path}: invalid Mach-O')
            if cmd in (0x24, 0x2f, 0x30):
                raise ValueError(f'{path}: non-iOS device deployment target')
            if cmd in (0x32, 0x25):
                has_target = True
                if length < (24 if cmd == 0x32 else 16):
                    raise ValueError(f'{path}: truncated deployment command')
            if cmd == 0x32:
                platform, minimum = struct.unpack_from('<II', data, pos + 8)
                if platform != 2 or minimum > max_packed:
                    raise ValueError(f'{path}: incompatible platform {platform}, deployment target {minimum:#x}')
            if cmd == 0x25 and struct.unpack_from('<I', data, pos + 8)[0] > max_packed:
                raise ValueError(f'{path}: deployment target exceeds iOS {target_str}')
            pos += length
        if pos != 32 + size or not has_target:
            raise ValueError(f'{path}: missing deployment target or invalid command size')
    if binaries == 0:
        raise ValueError('No arm64 application binaries found')


def codesign_bundle(app_dir: Path) -> None:
    fw_dir = app_dir / "Frameworks"
    if fw_dir.exists():
        for item in sorted(fw_dir.iterdir()):
            if item.suffix in (".framework", ".dylib"):
                subprocess.run(
                    ["codesign", "--force", "--sign", "-", "--timestamp=none", str(item)],
                    check=True,
                )
    entitlements = app_dir.parent / "trollstore.entitlements"
    entitlements.write_bytes(
        plistlib.dumps(
            {
                "application-identifier": "TROLLSTORE.com.pilipala.marcoMovie",
                "com.apple.developer.team-identifier": "TROLLSTORE",
                "get-task-allow": True,
                "com.apple.developer.networking.multicast": True,
            },
            fmt=plistlib.FMT_XML,
        )
    )
    subprocess.run(
        [
            "codesign",
            "--force",
            "--sign",
            "-",
            "--timestamp=none",
            "--entitlements",
            str(entitlements),
            str(app_dir),
        ],
        check=True,
    )


def main() -> None:
    args = sys.argv[1:]
    max_min_ios = None
    expected_version = None
    expected_build = None
    filtered = []
    idx = 0
    while idx < len(args):
        if args[idx] == "--min-ios" and idx + 1 < len(args):
            max_min_ios = args[idx + 1]
            idx += 2
        elif args[idx] == "--expected-version" and idx + 1 < len(args):
            expected_version = args[idx + 1]
            idx += 2
        elif args[idx] == "--expected-build" and idx + 1 < len(args):
            expected_build = args[idx + 1]
            idx += 2
        else:
            filtered.append(args[idx])
            idx += 1
    app_dir = Path(filtered[0]).resolve()
    strip_dsym_bundles(app_dir)
    validate_app(
        app_dir,
        max_min_ios=max_min_ios,
        expected_version=expected_version,
        expected_build=expected_build,
    )
    codesign_bundle(app_dir)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app_dir)], check=True)


if __name__ == "__main__":
    main()
