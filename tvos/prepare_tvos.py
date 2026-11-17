#!/usr/bin/env python3
# Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
"""Prepare Apple TV (tvOS 16.0+) vendor sources, brand assets, and Xcode project."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import struct
import sys
import zlib

TVOS_DIR = Path(__file__).resolve().parent
REPO_ROOT = TVOS_DIR.parent

QUICKJS_SRC_DIR = REPO_ROOT / "flutter" / "packages" / "quickjs_engine" / "native" / "cxx" / "quickjs"
CQUICKJS_DST_DIR = TVOS_DIR / "Sources" / "CQuickJS"
CQUICKJS_INCLUDE_DIR = CQUICKJS_DST_DIR / "include"

ANDROID_JS_HOST_DIR = REPO_ROOT / "android" / "src" / "main" / "assets" / "js-host"
FLUTTER_JS_HOST_DIR = REPO_ROOT / "flutter" / "assets" / "js-host"
SHARED_CATPAW_DIR = REPO_ROOT / "shared" / "catpaw"
TVOS_JS_HOST_DST_DIR = TVOS_DIR / "Sources" / "MarcoTVCore" / "Resources" / "js-host"

APP_ICON_512 = REPO_ROOT / "docs" / "images" / "app-icon-512.png"
LOGO_MARK_PNG = REPO_ROOT / "android" / "src" / "main" / "res" / "drawable-nodpi" / "logo_mark.png"

RUNNER_DIR = TVOS_DIR / "RunnerProject"
XCODEPROJ_DIR = RUNNER_DIR / "MarcoMovieTV.xcodeproj"
XCSCHEMES_DIR = XCODEPROJ_DIR / "xcshareddata" / "xcschemes"
ASSETS_DIR = RUNNER_DIR / "Assets.xcassets"

PORTABLE_QUICKJS_C_FILES = (
    "quickjs.c",
    "libregexp.c",
    "libunicode.c",
    "dtoa.c",
)

PUBLIC_QUICKJS_HEADERS = (
    "quickjs.h",
    "quickjs-libc.h",
)

BUNDLE_IDENTIFIER = "com.pilipala.marcoMovie.tv"
MINIMUM_TVOS_VERSION = "16.0"


# ==============================================================================
# Pure-Python PNG Decoder / Resizer / Encoder (Zero External Dependencies)
# ==============================================================================


def _paeth_predictor(a: int, b: int, c: int) -> int:
    p = a + b - c
    pa = abs(p - a)
    pb = abs(p - b)
    pc = abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    if pb <= pc:
        return b
    return c


def decode_png_rgba(path: Path) -> tuple[int, int, list[bytes]]:
    """Decode an 8-bit RGB (color_type=2) or RGBA (color_type=6) PNG into RGBA rows."""
    data = path.read_bytes()
    if len(data) < 33 or data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError(f"{path}: invalid PNG signature")

    pos = 8
    width = height = bit_depth = color_type = interlace = 0
    idat_chunks: list[bytes] = []
    while pos + 8 <= len(data):
        length, chunk_type = struct.unpack_from(">I4s", data, pos)
        chunk_data = data[pos + 8 : pos + 8 + length]
        pos += 12 + length
        if chunk_type == b"IHDR":
            width, height, bit_depth, color_type, _comp, _flt, interlace = struct.unpack(
                ">IIBBBBB", chunk_data[:13]
            )
        elif chunk_type == b"IDAT":
            idat_chunks.append(chunk_data)
        elif chunk_type == b"IEND":
            break

    if width <= 0 or height <= 0 or bit_depth != 8 or color_type not in (2, 6) or interlace != 0:
        raise ValueError(
            f"{path}: unsupported PNG format ({width}x{height}, depth={bit_depth}, color={color_type})"
        )

    bpp = 3 if color_type == 2 else 4
    stride = width * bpp
    raw = zlib.decompress(b"".join(idat_chunks))
    expected_len = height * (1 + stride)
    if len(raw) < expected_len:
        raise ValueError(f"{path}: truncated decompressed IDAT stream")

    prev_row = bytearray(stride)
    rgba_rows: list[bytes] = []
    offset = 0
    for _ in range(height):
        flt = raw[offset]
        scan = raw[offset + 1 : offset + 1 + stride]
        offset += 1 + stride
        recon = bytearray(stride)

        if flt == 0:
            recon[:] = scan
        elif flt == 1:  # Sub
            for i in range(stride):
                left = recon[i - bpp] if i >= bpp else 0
                recon[i] = (scan[i] + left) & 0xFF
        elif flt == 2:  # Up
            for i in range(stride):
                recon[i] = (scan[i] + prev_row[i]) & 0xFF
        elif flt == 3:  # Average
            for i in range(stride):
                left = recon[i - bpp] if i >= bpp else 0
                recon[i] = (scan[i] + ((left + prev_row[i]) >> 1)) & 0xFF
        elif flt == 4:  # Paeth
            for i in range(stride):
                left = recon[i - bpp] if i >= bpp else 0
                up = prev_row[i]
                up_left = prev_row[i - bpp] if i >= bpp else 0
                recon[i] = (scan[i] + _paeth_predictor(left, up, up_left)) & 0xFF
        else:
            raise ValueError(f"{path}: unsupported PNG filter {flt}")

        prev_row = recon
        if bpp == 4:
            rgba_rows.append(bytes(recon))
        else:
            row_rgba = bytearray(width * 4)
            row_rgba[0::4] = recon[0::3]
            row_rgba[1::4] = recon[1::3]
            row_rgba[2::4] = recon[2::3]
            row_rgba[3::4] = b"\xff" * width
            rgba_rows.append(bytes(row_rgba))

    return width, height, rgba_rows


def resize_rgba_nearest(
    src_w: int, src_h: int, src_rows: list[bytes], dst_w: int, dst_h: int
) -> list[bytes]:
    """Fast area/nearest RGBA resizer in pure Python."""
    x_map = [min(src_w - 1, (x * src_w) // dst_w) * 4 for x in range(dst_w)]
    out_rows: list[bytes] = []
    for y in range(dst_h):
        sy = min(src_h - 1, (y * src_h) // dst_h)
        srow = src_rows[sy]
        drow = bytearray(dst_w * 4)
        pos = 0
        for sx4 in x_map:
            drow[pos : pos + 4] = srow[sx4 : sx4 + 4]
            pos += 4
        out_rows.append(bytes(drow))
    return out_rows


def _png_chunk(chunk_type: bytes, payload: bytes) -> bytes:
    crc = zlib.crc32(chunk_type)
    crc = zlib.crc32(payload, crc) & 0xFFFFFFFF
    return struct.pack(">I", len(payload)) + chunk_type + payload + struct.pack(">I", crc)


def encode_png_from_scanlines(width: int, height: int, color_type: int, raw_scanlines: bytes) -> bytes:
    ihdr = struct.pack(">IIBBBBB", width, height, 8, color_type, 0, 0, 0)
    compressed = zlib.compress(raw_scanlines, level=6)
    return (
        b"\x89PNG\r\n\x1a\n"
        + _png_chunk(b"IHDR", ihdr)
        + _png_chunk(b"IDAT", compressed)
        + _png_chunk(b"IEND", b"")
    )


def render_centered_canvas_png(
    canvas_w: int,
    canvas_h: int,
    icon_w: int,
    icon_h: int,
    icon_rows_rgba: list[bytes],
    opaque_bg: tuple[int, int, int] | None,
) -> bytes:
    """Compose a centered RGBA icon onto either an opaque RGB gradient canvas or transparent RGBA canvas."""
    scaled_rows = resize_rgba_nearest(len(icon_rows_rgba[0]) // 4, len(icon_rows_rgba), icon_rows_rgba, icon_w, icon_h)
    ox = (canvas_w - icon_w) // 2
    oy = (canvas_h - icon_h) // 2

    scanlines = bytearray()
    if opaque_bg is not None:
        r0, g0, b0 = opaque_bg
        for y in range(canvas_h):
            # Subtle vertical studio gradient for living-room depth
            boost = (y * 14) // max(1, canvas_h)
            br = min(255, r0 + boost)
            bg = min(255, g0 + boost)
            bb = min(255, b0 + boost * 2)
            base_pixel = bytes((br, bg, bb))
            scanlines.append(0)  # Filter None
            if oy <= y < oy + icon_h:
                left = base_pixel * ox
                right = base_pixel * (canvas_w - ox - icon_w)
                srow = scaled_rows[y - oy]
                mid = bytearray(icon_w * 3)
                for ix in range(icon_w):
                    sr = srow[ix * 4]
                    sg = srow[ix * 4 + 1]
                    sb = srow[ix * 4 + 2]
                    sa = srow[ix * 4 + 3]
                    inv = 255 - sa
                    mid[ix * 3] = (sr * sa + br * inv) // 255
                    mid[ix * 3 + 1] = (sg * sa + bg * inv) // 255
                    mid[ix * 3 + 2] = (sb * sa + bb * inv) // 255
                scanlines.extend(left)
                scanlines.extend(mid)
                scanlines.extend(right)
            else:
                scanlines.extend(base_pixel * canvas_w)
        return encode_png_from_scanlines(canvas_w, canvas_h, 2, bytes(scanlines))

    empty_row = b"\x00" + (b"\x00\x00\x00\x00" * canvas_w)
    left_pad = b"\x00\x00\x00\x00" * ox
    right_pad = b"\x00\x00\x00\x00" * (canvas_w - ox - icon_w)
    for y in range(canvas_h):
        if oy <= y < oy + icon_h:
            scanlines.append(0)
            scanlines.extend(left_pad)
            scanlines.extend(scaled_rows[y - oy])
            scanlines.extend(right_pad)
        else:
            scanlines.extend(empty_row)
    return encode_png_from_scanlines(canvas_w, canvas_h, 6, bytes(scanlines))


def png_dimensions(path: Path) -> tuple[int, int]:
    data = path.read_bytes()
    if len(data) < 24 or data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError(f"{path}: invalid PNG file")
    return struct.unpack(">II", data[16:24])


# ==============================================================================
# Step 1 & 2: Sync QuickJS-NG C/H & JS Host Runtime Scripts
# ==============================================================================


def sync_quickjs_sources() -> list[Path]:
    if not QUICKJS_SRC_DIR.is_dir():
        raise FileNotFoundError(f"QuickJS source directory missing: {QUICKJS_SRC_DIR}")

    CQUICKJS_DST_DIR.mkdir(parents=True, exist_ok=True)
    CQUICKJS_INCLUDE_DIR.mkdir(parents=True, exist_ok=True)

    copied: list[Path] = []
    for c_name in PORTABLE_QUICKJS_C_FILES:
        src = QUICKJS_SRC_DIR / c_name
        dst = CQUICKJS_DST_DIR / c_name
        shutil.copy2(src, dst)
        copied.append(dst)

    for h_file in sorted(QUICKJS_SRC_DIR.glob("*.h")):
        dst = CQUICKJS_DST_DIR / h_file.name
        shutil.copy2(h_file, dst)
        copied.append(dst)

    for pub_h in PUBLIC_QUICKJS_HEADERS:
        src = QUICKJS_SRC_DIR / pub_h
        if src.exists():
            dst = CQUICKJS_INCLUDE_DIR / pub_h
            shutil.copy2(src, dst)
            copied.append(dst)

    return copied


def sync_js_host_assets() -> list[Path]:
    TVOS_JS_HOST_DST_DIR.mkdir(parents=True, exist_ok=True)
    js_src_base = FLUTTER_JS_HOST_DIR if (FLUTTER_JS_HOST_DIR / "crypto-js.js").exists() else ANDROID_JS_HOST_DIR

    copied: list[Path] = []
    for name in ("crypto-js.js", "catvod.mjs", "module-interop.js", "bootstrap.js", "crypto.LICENSE"):
        src = js_src_base / name
        if not src.exists():
            src = ANDROID_JS_HOST_DIR / name
        if src.exists():
            dst = TVOS_JS_HOST_DST_DIR / name
            shutil.copy2(src, dst)
            copied.append(dst)

    drpy_core = SHARED_CATPAW_DIR / "drpy-core.js"
    if drpy_core.exists():
        dst = TVOS_JS_HOST_DST_DIR / "drpy-core.js"
        shutil.copy2(drpy_core, dst)
        copied.append(dst)

    return copied


# ==============================================================================
# Step 3: Generate tvOS BrandAssets (400x240, 800x480, 1280x768, Top Shelf)
# ==============================================================================


def _write_json(path: Path, obj: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def generate_tvos_xcassets() -> None:
    _, _, opaque_rows = decode_png_rgba(APP_ICON_512)
    if LOGO_MARK_PNG.exists():
        _, _, front_rows = decode_png_rgba(LOGO_MARK_PNG)
    else:
        front_rows = opaque_rows

    _write_json(ASSETS_DIR / "Contents.json", {"info": {"author": "xcode", "version": 1}})

    brand_dir = ASSETS_DIR / "App Icon & Top Shelf Image.brandassets"
    _write_json(
        brand_dir / "Contents.json",
        {
            "assets": [
                {
                    "filename": "App Icon - App Store.imagestack",
                    "idiom": "tv",
                    "role": "primary-app-icon",
                    "size": "1280x768",
                },
                {
                    "filename": "App Icon.imagestack",
                    "idiom": "tv",
                    "role": "primary-app-icon",
                    "size": "400x240",
                },
                {
                    "filename": "Top Shelf Image Wide.imageset",
                    "idiom": "tv",
                    "role": "top-shelf-image-wide",
                    "size": "2320x720",
                },
                {
                    "filename": "Top Shelf Image.imageset",
                    "idiom": "tv",
                    "role": "top-shelf-image",
                    "size": "1920x720",
                },
            ],
            "info": {"author": "xcode", "version": 1},
        },
    )

    def build_imagestack(stack_dir: Path, w1x: int, h1x: int, include_2x: bool) -> None:
        _write_json(
            stack_dir / "Contents.json",
            {
                "info": {"author": "xcode", "version": 1},
                "layers": [
                    {"filename": "Front.imagestacklayer"},
                    {"filename": "Back.imagestacklayer"},
                ],
            },
        )
        for layer_name, is_back in (("Back", True), ("Front", False)):
            layer_dir = stack_dir / f"{layer_name}.imagestacklayer"
            _write_json(layer_dir / "Contents.json", {"info": {"author": "xcode", "version": 1}})
            imgset_dir = layer_dir / "Content.imageset"
            imgset_dir.mkdir(parents=True, exist_ok=True)
            images_meta = []

            scales = [(1, w1x, h1x)] + ([(2, w1x * 2, h1x * 2)] if include_2x else [])
            for scale, cw, ch in scales:
                fname = f"{layer_name.lower()}_{cw}x{ch}.png"
                icon_dim = int(ch * (0.68 if not is_back else 0.0))
                if is_back:
                    # Solid dark studio backdrop with subtle vignette
                    png_bytes = render_centered_canvas_png(
                        cw, ch, max(4, ch // 4), max(4, ch // 4), opaque_rows, opaque_bg=(13, 16, 25)
                    )
                else:
                    png_bytes = render_centered_canvas_png(
                        cw, ch, icon_dim, icon_dim, front_rows, opaque_bg=None
                    )
                (imgset_dir / fname).write_bytes(png_bytes)
                images_meta.append({"filename": fname, "idiom": "tv", "scale": f"{scale}x"})

            _write_json(
                imgset_dir / "Contents.json",
                {"images": images_meta, "info": {"author": "xcode", "version": 1}},
            )

    build_imagestack(brand_dir / "App Icon.imagestack", 400, 240, include_2x=True)
    build_imagestack(brand_dir / "App Icon - App Store.imagestack", 1280, 768, include_2x=False)

    # Top Shelf banners (1920x720 and 2320x720)
    for set_name, tw, th, slug in (
        ("Top Shelf Image.imageset", 1920, 720, "topshelf_1920x720.png"),
        ("Top Shelf Image Wide.imageset", 2320, 720, "topshelf_wide_2320x720.png"),
    ):
        tdir = brand_dir / set_name
        tdir.mkdir(parents=True, exist_ok=True)
        banner_bytes = render_centered_canvas_png(tw, th, 340, 340, opaque_rows, opaque_bg=(11, 14, 22))
        (tdir / slug).write_bytes(banner_bytes)
        _write_json(
            tdir / "Contents.json",
            {
                "images": [{"filename": slug, "idiom": "tv", "scale": "1x"}],
                "info": {"author": "xcode", "version": 1},
            },
        )


# ==============================================================================
# Step 4: Generate Info.plist, Shared Scheme & Deterministic project.pbxproj
# ==============================================================================


def _pbx_id(tag: str) -> str:
    return hashlib.sha1(f"marco-tvos::{tag}".encode("utf-8")).hexdigest()[:24].upper()


def generate_info_plist() -> Path:
    RUNNER_DIR.mkdir(parents=True, exist_ok=True)
    info = {
        "CFBundleDevelopmentRegion": "zh_CN",
        "CFBundleDisplayName": "Marco Movie",
        "CFBundleExecutable": "MarcoMovieTV",
        "CFBundleIdentifier": BUNDLE_IDENTIFIER,
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": "MarcoMovieTV",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "$(MARKETING_VERSION)",
        "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
        "LSRequiresIPhoneOS": True,
        "MinimumOSVersion": MINIMUM_TVOS_VERSION,
        "UIDeviceFamily": [3],
        "UIRequiredDeviceCapabilities": ["arm64"],
        "UIUserInterfaceStyle": "Dark",
        "TVTopShelfImage": {
            "TVTopShelfPrimaryImageWide": "Top Shelf Image Wide",
            "TVTopShelfPrimaryImage": "Top Shelf Image",
        },
        "NSLocalNetworkUsageDescription": "用于接收同一局域网手机扫码推送的配置、多端进度同步与本地流媒体头部代理。",
        "NSAppTransportSecurity": {
            "NSAllowsArbitraryLoads": True,
        },
    }
    plist_path = RUNNER_DIR / "Info.plist"
    plist_path.write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_XML, sort_keys=False))
    return plist_path


def generate_xcodeproj() -> Path:
    XCODEPROJ_DIR.mkdir(parents=True, exist_ok=True)
    XCSCHEMES_DIR.mkdir(parents=True, exist_ok=True)

    c_sources = sorted((TVOS_DIR / "Sources" / "CQuickJS").glob("*.c"))
    core_swift_sources = sorted((TVOS_DIR / "Sources" / "MarcoTVCore").rglob("*.swift"))
    app_swift_sources = sorted((TVOS_DIR / "Sources" / "MarcoMovieTV").rglob("*.swift"))

    objects: dict[str, dict] = {}

    def put(oid: str, payload: dict) -> str:
        objects[oid] = payload
        return oid

    def rel_to_runner(path: Path) -> str:
        # RunnerProject/ is directly inside tvos/
        rel = path.relative_to(TVOS_DIR).as_posix()
        return f"../{rel}"

    # File references & build files
    c_build_files: list[str] = []
    c_file_refs: list[str] = []
    for c_path in c_sources:
        rpath = rel_to_runner(c_path)
        fref = put(
            _pbx_id(f"fref:{rpath}"),
            {
                "isa": "PBXFileReference",
                "lastKnownFileType": "sourcecode.c.c",
                "name": c_path.name,
                "path": rpath,
                "sourceTree": "<group>",
            },
        )
        bfile = put(
            _pbx_id(f"bfile:cquickjs:{rpath}"),
            {"isa": "PBXBuildFile", "fileRef": fref},
        )
        c_file_refs.append(fref)
        c_build_files.append(bfile)

    core_build_files: list[str] = []
    core_file_refs: list[str] = []
    for s_path in core_swift_sources:
        rpath = rel_to_runner(s_path)
        fref = put(
            _pbx_id(f"fref:{rpath}"),
            {
                "isa": "PBXFileReference",
                "lastKnownFileType": "sourcecode.swift",
                "name": s_path.name,
                "path": rpath,
                "sourceTree": "<group>",
            },
        )
        bfile = put(
            _pbx_id(f"bfile:core:{rpath}"),
            {"isa": "PBXBuildFile", "fileRef": fref},
        )
        core_file_refs.append(fref)
        core_build_files.append(bfile)

    app_build_files: list[str] = []
    app_file_refs: list[str] = []
    for s_path in app_swift_sources:
        rpath = rel_to_runner(s_path)
        fref = put(
            _pbx_id(f"fref:{rpath}"),
            {
                "isa": "PBXFileReference",
                "lastKnownFileType": "sourcecode.swift",
                "name": s_path.name,
                "path": rpath,
                "sourceTree": "<group>",
            },
        )
        bfile = put(
            _pbx_id(f"bfile:app:{rpath}"),
            {"isa": "PBXBuildFile", "fileRef": fref},
        )
        app_file_refs.append(fref)
        app_build_files.append(bfile)

    # Resource & product file references
    assets_fref = put(
        _pbx_id("fref:Assets.xcassets"),
        {
            "isa": "PBXFileReference",
            "lastKnownFileType": "folder.assetcatalog",
            "path": "Assets.xcassets",
            "sourceTree": "<group>",
        },
    )
    jshost_fref = put(
        _pbx_id("fref:js-host"),
        {
            "isa": "PBXFileReference",
            "lastKnownFileType": "folder",
            "name": "js-host",
            "path": "../Sources/MarcoTVCore/Resources/js-host",
            "sourceTree": "<group>",
        },
    )
    info_fref = put(
        _pbx_id("fref:Info.plist"),
        {
            "isa": "PBXFileReference",
            "lastKnownFileType": "text.plist.xml",
            "path": "Info.plist",
            "sourceTree": "<group>",
        },
    )

    cquickjs_prod_ref = put(
        _pbx_id("prod:libCQuickJS.a"),
        {
            "isa": "PBXFileReference",
            "explicitFileType": "archive.ar",
            "includeInIndex": "0",
            "path": "libCQuickJS.a",
            "sourceTree": "BUILT_PRODUCTS_DIR",
        },
    )
    core_prod_ref = put(
        _pbx_id("prod:libMarcoTVCore.a"),
        {
            "isa": "PBXFileReference",
            "explicitFileType": "archive.ar",
            "includeInIndex": "0",
            "path": "libMarcoTVCore.a",
            "sourceTree": "BUILT_PRODUCTS_DIR",
        },
    )
    app_prod_ref = put(
        _pbx_id("prod:MarcoMovieTV.app"),
        {
            "isa": "PBXFileReference",
            "explicitFileType": "wrapper.application",
            "includeInIndex": "0",
            "path": "MarcoMovieTV.app",
            "sourceTree": "BUILT_PRODUCTS_DIR",
        },
    )

    assets_bfile = put(_pbx_id("bfile:Assets.xcassets"), {"isa": "PBXBuildFile", "fileRef": assets_fref})
    jshost_bfile = put(_pbx_id("bfile:js-host"), {"isa": "PBXBuildFile", "fileRef": jshost_fref})
    link_cquickjs_bfile = put(
        _pbx_id("bfile:link:libCQuickJS.a"), {"isa": "PBXBuildFile", "fileRef": cquickjs_prod_ref}
    )
    link_core_bfile = put(
        _pbx_id("bfile:link:libMarcoTVCore.a"), {"isa": "PBXBuildFile", "fileRef": core_prod_ref}
    )

    # Groups
    cquickjs_group = put(
        _pbx_id("grp:CQuickJS"),
        {"isa": "PBXGroup", "children": c_file_refs, "name": "CQuickJS", "sourceTree": "<group>"},
    )
    core_group = put(
        _pbx_id("grp:MarcoTVCore"),
        {"isa": "PBXGroup", "children": core_file_refs, "name": "MarcoTVCore", "sourceTree": "<group>"},
    )
    app_group = put(
        _pbx_id("grp:MarcoMovieTV"),
        {
            "isa": "PBXGroup",
            "children": app_file_refs + [assets_fref, jshost_fref, info_fref],
            "name": "MarcoMovieTV",
            "sourceTree": "<group>",
        },
    )
    products_group = put(
        _pbx_id("grp:Products"),
        {
            "isa": "PBXGroup",
            "children": [cquickjs_prod_ref, core_prod_ref, app_prod_ref],
            "name": "Products",
            "sourceTree": "<group>",
        },
    )
    main_group = put(
        _pbx_id("grp:Main"),
        {
            "isa": "PBXGroup",
            "children": [cquickjs_group, core_group, app_group, products_group],
            "sourceTree": "<group>",
        },
    )

    # Build phases
    c_sources_phase = put(
        _pbx_id("phase:sources:CQuickJS"),
        {
            "isa": "PBXSourcesBuildPhase",
            "buildActionMask": "2147483647",
            "files": c_build_files,
            "runOnlyForDeploymentPostprocessing": "0",
        },
    )
    core_sources_phase = put(
        _pbx_id("phase:sources:MarcoTVCore"),
        {
            "isa": "PBXSourcesBuildPhase",
            "buildActionMask": "2147483647",
            "files": core_build_files,
            "runOnlyForDeploymentPostprocessing": "0",
        },
    )
    app_sources_phase = put(
        _pbx_id("phase:sources:MarcoMovieTV"),
        {
            "isa": "PBXSourcesBuildPhase",
            "buildActionMask": "2147483647",
            "files": app_build_files,
            "runOnlyForDeploymentPostprocessing": "0",
        },
    )
    app_frameworks_phase = put(
        _pbx_id("phase:frameworks:MarcoMovieTV"),
        {
            "isa": "PBXFrameworksBuildPhase",
            "buildActionMask": "2147483647",
            "files": [link_core_bfile, link_cquickjs_bfile],
            "runOnlyForDeploymentPostprocessing": "0",
        },
    )
    app_resources_phase = put(
        _pbx_id("phase:resources:MarcoMovieTV"),
        {
            "isa": "PBXResourcesBuildPhase",
            "buildActionMask": "2147483647",
            "files": [assets_bfile, jshost_bfile],
            "runOnlyForDeploymentPostprocessing": "0",
        },
    )

    # Build configurations helper
    def make_config_list(tag: str, debug_settings: dict, release_settings: dict) -> str:
        dbg_id = put(
            _pbx_id(f"cfg:{tag}:Debug"),
            {"isa": "XCBuildConfiguration", "buildSettings": debug_settings, "name": "Debug"},
        )
        rel_id = put(
            _pbx_id(f"cfg:{tag}:Release"),
            {"isa": "XCBuildConfiguration", "buildSettings": release_settings, "name": "Release"},
        )
        return put(
            _pbx_id(f"cfglist:{tag}"),
            {
                "isa": "XCConfigurationList",
                "buildConfigurations": [dbg_id, rel_id],
                "defaultConfigurationIsVisible": "0",
                "defaultConfigurationName": "Release",
            },
        )

    proj_common = {
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "CLANG_ENABLE_MODULES": "YES",
        "CLANG_ENABLE_OBJC_ARC": "YES",
        "CURRENT_PROJECT_VERSION": "1",
        "GCC_C_LANGUAGE_STANDARD": "gnu11",
        "MARKETING_VERSION": "0.1.0",
        "SDKROOT": "appletvos",
        "SWIFT_VERSION": "5.0",
        "TARGETED_DEVICE_FAMILY": "3",
        "TVOS_DEPLOYMENT_TARGET": MINIMUM_TVOS_VERSION,
    }
    proj_cfg_list = make_config_list(
        "Project",
        {**proj_common, "SWIFT_OPTIMIZATION_LEVEL": "-Onone", "GCC_OPTIMIZATION_LEVEL": "0"},
        {**proj_common, "SWIFT_OPTIMIZATION_LEVEL": "-O", "SWIFT_COMPILATION_MODE": "wholemodule"},
    )

    cquickjs_common = {
        "PRODUCT_NAME": "CQuickJS",
        "SKIP_INSTALL": "YES",
        "HEADER_SEARCH_PATHS": [
            "$(SRCROOT)/../Sources/CQuickJS",
            "$(SRCROOT)/../Sources/CQuickJS/include",
        ],
        "WARNING_CFLAGS": [
            "-Wno-unused-function",
            "-Wno-unused-variable",
            "-Wno-unused-parameter",
            "-Wno-unused-but-set-variable",
            "-Wno-shorten-64-to-32",
        ],
    }
    cquickjs_cfg_list = make_config_list(
        "CQuickJS",
        {
            **cquickjs_common,
            "GCC_PREPROCESSOR_DEFINITIONS": ["_GNU_SOURCE=1", 'CONFIG_VERSION=\\"ng-0.14.0\\"'],
        },
        {
            **cquickjs_common,
            "GCC_PREPROCESSOR_DEFINITIONS": [
                "_GNU_SOURCE=1",
                'CONFIG_VERSION=\\"ng-0.14.0\\"',
                "NDEBUG=1",
            ],
        },
    )

    core_common = {
        "DEFINES_MODULE": "YES",
        "PRODUCT_MODULE_NAME": "MarcoTVCore",
        "PRODUCT_NAME": "MarcoTVCore",
        "SKIP_INSTALL": "YES",
        "HEADER_SEARCH_PATHS": ["$(SRCROOT)/../Sources/CQuickJS/include"],
        "SWIFT_INCLUDE_PATHS": ["$(SRCROOT)/../Sources/CQuickJS/include"],
    }
    core_cfg_list = make_config_list("MarcoTVCore", core_common, core_common)

    app_common = {
        "ASSETCATALOG_COMPILER_APPICON_NAME": "App Icon & Top Shelf Image",
        "CODE_SIGNING_ALLOWED": "NO",
        "CODE_SIGN_IDENTITY": "",
        "CODE_SIGN_STYLE": "Manual",
        "INFOPLIST_FILE": "Info.plist",
        "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks"],
        "LIBRARY_SEARCH_PATHS": ["$(inherited)", "$(BUILT_PRODUCTS_DIR)"],
        "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_IDENTIFIER,
        "PRODUCT_NAME": "MarcoMovieTV",
        "SWIFT_INCLUDE_PATHS": ["$(BUILT_PRODUCTS_DIR)", "$(SRCROOT)/../Sources/CQuickJS/include"],
    }
    app_cfg_list = make_config_list("MarcoMovieTV", app_common, app_common)

    # Targets & dependencies
    project_id = _pbx_id("project:MarcoMovieTV")
    cquickjs_target_id = _pbx_id("target:CQuickJS")
    core_target_id = _pbx_id("target:MarcoTVCore")
    app_target_id = _pbx_id("target:MarcoMovieTV")

    put(
        cquickjs_target_id,
        {
            "isa": "PBXNativeTarget",
            "buildConfigurationList": cquickjs_cfg_list,
            "buildPhases": [c_sources_phase],
            "buildRules": [],
            "dependencies": [],
            "name": "CQuickJS",
            "productName": "CQuickJS",
            "productReference": cquickjs_prod_ref,
            "productType": "com.apple.product-type.library.static",
        },
    )

    proxy_core_to_c = put(
        _pbx_id("proxy:core->cquickjs"),
        {
            "isa": "PBXContainerItemProxy",
            "containerPortal": project_id,
            "proxyType": "1",
            "remoteGlobalIDString": cquickjs_target_id,
            "remoteInfo": "CQuickJS",
        },
    )
    dep_core_to_c = put(
        _pbx_id("dep:core->cquickjs"),
        {"isa": "PBXTargetDependency", "target": cquickjs_target_id, "targetProxy": proxy_core_to_c},
    )

    put(
        core_target_id,
        {
            "isa": "PBXNativeTarget",
            "buildConfigurationList": core_cfg_list,
            "buildPhases": [core_sources_phase],
            "buildRules": [],
            "dependencies": [dep_core_to_c],
            "name": "MarcoTVCore",
            "productName": "MarcoTVCore",
            "productReference": core_prod_ref,
            "productType": "com.apple.product-type.library.static",
        },
    )

    proxy_app_to_c = put(
        _pbx_id("proxy:app->cquickjs"),
        {
            "isa": "PBXContainerItemProxy",
            "containerPortal": project_id,
            "proxyType": "1",
            "remoteGlobalIDString": cquickjs_target_id,
            "remoteInfo": "CQuickJS",
        },
    )
    dep_app_to_c = put(
        _pbx_id("dep:app->cquickjs"),
        {"isa": "PBXTargetDependency", "target": cquickjs_target_id, "targetProxy": proxy_app_to_c},
    )
    proxy_app_to_core = put(
        _pbx_id("proxy:app->core"),
        {
            "isa": "PBXContainerItemProxy",
            "containerPortal": project_id,
            "proxyType": "1",
            "remoteGlobalIDString": core_target_id,
            "remoteInfo": "MarcoTVCore",
        },
    )
    dep_app_to_core = put(
        _pbx_id("dep:app->core"),
        {"isa": "PBXTargetDependency", "target": core_target_id, "targetProxy": proxy_app_to_core},
    )

    put(
        app_target_id,
        {
            "isa": "PBXNativeTarget",
            "buildConfigurationList": app_cfg_list,
            "buildPhases": [app_sources_phase, app_frameworks_phase, app_resources_phase],
            "buildRules": [],
            "dependencies": [dep_app_to_c, dep_app_to_core],
            "name": "MarcoMovieTV",
            "productName": "MarcoMovieTV",
            "productReference": app_prod_ref,
            "productType": "com.apple.product-type.application",
        },
    )

    put(
        project_id,
        {
            "isa": "PBXProject",
            "attributes": {"LastSwiftUpdateCheck": "1500", "LastUpgradeCheck": "1500"},
            "buildConfigurationList": proj_cfg_list,
            "compatibilityVersion": "Xcode 14.0",
            "developmentRegion": "zh_CN",
            "hasScannedForEncodings": "0",
            "knownRegions": ["en", "zh_CN", "Base"],
            "mainGroup": main_group,
            "productRefGroup": products_group,
            "projectDirPath": "",
            "projectRoot": "",
            "targets": [cquickjs_target_id, core_target_id, app_target_id],
        },
    )

    pbx_root = {
        "archiveVersion": "1",
        "classes": {},
        "objectVersion": "56",
        "objects": objects,
        "rootObject": project_id,
    }
    pbxproj_path = XCODEPROJ_DIR / "project.pbxproj"
    pbxproj_path.write_bytes(plistlib.dumps(pbx_root, fmt=plistlib.FMT_XML, sort_keys=True))

    scheme_xml = f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1500" version="1.7">
   <BuildAction parallelizeBuildables="NO" buildImplicitDependencies="YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
            <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{cquickjs_target_id}" BuildableName="libCQuickJS.a" BlueprintName="CQuickJS" ReferencedContainer="container:MarcoMovieTV.xcodeproj"/>
         </BuildActionEntry>
         <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
            <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{core_target_id}" BuildableName="libMarcoTVCore.a" BlueprintName="MarcoTVCore" ReferencedContainer="container:MarcoMovieTV.xcodeproj"/>
         </BuildActionEntry>
         <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
            <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_target_id}" BuildableName="MarcoMovieTV.app" BlueprintName="MarcoMovieTV" ReferencedContainer="container:MarcoMovieTV.xcodeproj"/>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES">
      <BuildableProductRunnable runnableDebuggingMode="0">
         <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_target_id}" BuildableName="MarcoMovieTV.app" BlueprintName="MarcoMovieTV" ReferencedContainer="container:MarcoMovieTV.xcodeproj"/>
      </BuildableProductRunnable>
   </LaunchAction>
   <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
"""
    (XCSCHEMES_DIR / "MarcoMovieTV.xcscheme").write_text(scheme_xml, encoding="utf-8")
    return pbxproj_path


def prepare_all() -> dict[str, object]:
    copied_qjs = sync_quickjs_sources()
    copied_js = sync_js_host_assets()
    generate_tvos_xcassets()
    info_plist = generate_info_plist()
    pbxproj = generate_xcodeproj()
    return {
        "quickjs_files": len(copied_qjs),
        "js_host_files": len(copied_js),
        "info_plist": str(info_plist),
        "pbxproj": str(pbxproj),
    }


def main() -> None:
    summary = prepare_all()
    print(
        f"Prepared tvOS workspace: {summary['quickjs_files']} QuickJS files, "
        f"{summary['js_host_files']} JS host scripts, Xcode project -> {summary['pbxproj']}"
    )


if __name__ == "__main__":
    main()
