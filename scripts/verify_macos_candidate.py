#!/usr/bin/env python3
"""Verify an unmodified unzipped macOS .app candidate in CI.

Checks:
1. Records SHA-256 digests of the main binary, Mpv.framework binary, and bundled node
   before and after all probes so the .app is provably untouched.
2. Compiles a tiny temporary C rpath harness (-Wl,-rpath,<app>/Contents/Frameworks)
   that dlopens the UNMODIFIED <app>/Contents/Frameworks/Mpv.framework/Versions/A/Mpv
   and exercises:
   - Authenticated local HTTP playback with custom User-Agent & X-Marco-Auth headers
   - Offline separate-audio HLS (H.264 video + separate AAC audio) playback & seek
   - Real macOS libmpv video-output properties on H.264+AAC vs audio-only AAC radio
3. Verifies upgrading a 4429808-style MainFlutterWindow.swift with prepare_platform.py
   twice (idempotent) and typechecks the upgraded Swift file with Apple's swiftc against
   the unzipped .app's FlutterMacOS.framework.
"""
from __future__ import annotations

import argparse
import hashlib
import http.server
import os
import shutil
import socketserver
import subprocess
import sys
import tempfile
import textwrap
import threading
from pathlib import Path

MPV_PROBE_C = r'''
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct mpv_handle mpv_handle;
typedef struct mpv_event {
  int event_id;
  int error;
  unsigned long long reply_userdata;
  void *data;
} mpv_event;

enum {
  MPV_EVENT_NONE = 0,
  MPV_EVENT_SHUTDOWN = 1,
  MPV_EVENT_END_FILE = 7,
  MPV_EVENT_FILE_LOADED = 8,
};

typedef unsigned long (*fn_api_version)(void);
typedef mpv_handle *(*fn_create)(void);
typedef int (*fn_set_option_string)(mpv_handle *, const char *, const char *);
typedef int (*fn_initialize)(mpv_handle *);
typedef int (*fn_command)(mpv_handle *, const char **);
typedef mpv_event *(*fn_wait_event)(mpv_handle *, double);
typedef char *(*fn_get_property_string)(mpv_handle *, const char *);
typedef int (*fn_set_property_string)(mpv_handle *, const char *, const char *);
typedef void (*fn_free)(void *);
typedef void (*fn_terminate_destroy)(mpv_handle *);

static char *prop_or_none(fn_get_property_string get_prop, fn_free mfree, mpv_handle *ctx, const char *name, char *buf, size_t len) {
  char *val = get_prop(ctx, name);
  if (!val) {
    snprintf(buf, len, "<null>");
    return buf;
  }
  snprintf(buf, len, "%s", val);
  mfree(val);
  return buf;
}

int main(int argc, char **argv) {
  if (argc < 4) {
    fprintf(stderr, "Usage: %s <mpv_lib> <mode:http|hls|audio> <uri> [header_line] [user_agent]\n", argv[0]);
    return 2;
  }
  const char *mpv_path = argv[1];
  const char *mode = argv[2];
  const char *uri = argv[3];
  const char *header_line = argc >= 5 ? argv[4] : "";
  const char *user_agent = argc >= 6 ? argv[5] : "";

  void *handle = dlopen(mpv_path, RTLD_NOW | RTLD_LOCAL);
  if (!handle) {
    fprintf(stderr, "dlopen failed: %s\n", dlerror());
    return 10;
  }

  fn_api_version api_version = (fn_api_version)dlsym(handle, "mpv_client_api_version");
  fn_create create = (fn_create)dlsym(handle, "mpv_create");
  fn_set_option_string set_opt = (fn_set_option_string)dlsym(handle, "mpv_set_option_string");
  fn_initialize init = (fn_initialize)dlsym(handle, "mpv_initialize");
  fn_command cmd = (fn_command)dlsym(handle, "mpv_command");
  fn_wait_event wait_event = (fn_wait_event)dlsym(handle, "mpv_wait_event");
  fn_get_property_string get_prop = (fn_get_property_string)dlsym(handle, "mpv_get_property_string");
  fn_set_property_string set_prop = (fn_set_property_string)dlsym(handle, "mpv_set_property_string");
  fn_free mfree = (fn_free)dlsym(handle, "mpv_free");
  fn_terminate_destroy destroy = (fn_terminate_destroy)dlsym(handle, "mpv_terminate_destroy");

  if (!api_version || !create || !set_opt || !init || !cmd || !wait_event || !get_prop || !set_prop || !mfree || !destroy) {
    fprintf(stderr, "missing mpv symbol\n");
    return 11;
  }

  unsigned long ver = api_version();
  printf("MPV_API_VERSION=%lu.%lu\n", ver >> 16, ver & 0xFFFF);

  mpv_handle *ctx = create();
  if (!ctx) {
    fprintf(stderr, "mpv_create failed\n");
    return 12;
  }

  set_opt(ctx, "vo", "null");
  set_opt(ctx, "ao", "null");
  set_opt(ctx, "terminal", "no");
  set_opt(ctx, "config", "no");
  set_opt(ctx, "ytdl", "no");
  set_opt(ctx, "demuxer-lavf-o", "protocol_whitelist=[file,http,https,tcp,tls,crypto,data]");
  if (header_line[0] != '\0') {
    set_opt(ctx, "http-header-fields", header_line);
  }
  if (user_agent[0] != '\0') {
    set_opt(ctx, "user-agent", user_agent);
  }
  if (init(ctx) < 0) {
    fprintf(stderr, "mpv_initialize failed\n");
    destroy(ctx);
    return 13;
  }

  const char *load_args[] = {"loadfile", uri, NULL};
  if (cmd(ctx, load_args) < 0) {
    fprintf(stderr, "loadfile failed\n");
    destroy(ctx);
    return 14;
  }

  int loaded = 0;
  for (int i = 0; i < 80; i++) {
    mpv_event *ev = wait_event(ctx, 0.1);
    if (!ev) continue;
    if (ev->event_id == MPV_EVENT_FILE_LOADED) {
      loaded = 1;
      break;
    }
    if (ev->event_id == MPV_EVENT_END_FILE && !loaded) {
      fprintf(stderr, "end-file before load (err=%d)\n", ev->error);
      destroy(ctx);
      return 15;
    }
  }
  if (!loaded) {
    fprintf(stderr, "timeout waiting for FILE_LOADED\n");
    destroy(ctx);
    return 16;
  }

  double pos = 0.0;
  char vid[64], aid[64], vw[64], vh[64], vo_cfg[64], out_dw[64], fps[64], arate[64];
  for (int i = 0; i < 40; i++) {
    usleep(100000);
    while (1) {
      mpv_event *ev = wait_event(ctx, 0.0);
      if (!ev || ev->event_id == MPV_EVENT_NONE) break;
    }
    char pos_buf[64];
    prop_or_none(get_prop, mfree, ctx, "time-pos", pos_buf, sizeof(pos_buf));
    pos = atof(pos_buf);
    prop_or_none(get_prop, mfree, ctx, "vid", vid, sizeof(vid));
    prop_or_none(get_prop, mfree, ctx, "aid", aid, sizeof(aid));
    prop_or_none(get_prop, mfree, ctx, "vo-configured", vo_cfg, sizeof(vo_cfg));
    if (pos >= 0.35 && (strcmp(mode, "audio") == 0 || strcmp(vo_cfg, "yes") == 0)) {
      break;
    }
  }

  prop_or_none(get_prop, mfree, ctx, "vid", vid, sizeof(vid));
  prop_or_none(get_prop, mfree, ctx, "aid", aid, sizeof(aid));
  prop_or_none(get_prop, mfree, ctx, "video-params/w", vw, sizeof(vw));
  prop_or_none(get_prop, mfree, ctx, "video-params/h", vh, sizeof(vh));
  prop_or_none(get_prop, mfree, ctx, "vo-configured", vo_cfg, sizeof(vo_cfg));
  prop_or_none(get_prop, mfree, ctx, "video-out-params/dw", out_dw, sizeof(out_dw));
  prop_or_none(get_prop, mfree, ctx, "estimated-vf-fps", fps, sizeof(fps));
  prop_or_none(get_prop, mfree, ctx, "audio-params/samplerate", arate, sizeof(arate));

  double seek_pos = pos;
  if (strcmp(mode, "hls") == 0) {
    const char *seek_args[] = {"seek", "1.4", "absolute", NULL};
    cmd(ctx, seek_args);
    for (int i = 0; i < 20; i++) {
      usleep(100000);
      char pos_buf[64];
      prop_or_none(get_prop, mfree, ctx, "time-pos", pos_buf, sizeof(pos_buf));
      seek_pos = atof(pos_buf);
      if (seek_pos >= 1.1) break;
    }
  }

  printf("MODE=%s POS=%.3f SEEK_POS=%.3f VID=%s AID=%s W=%s H=%s VO_CONFIGURED=%s OUT_DW=%s VF_FPS=%s AUDIO_RATE=%s\n",
         mode, pos, seek_pos, vid, aid, vw, vh, vo_cfg, out_dw, fps, arate);

  int rc = 0;
  if (pos < 0.2) {
    fprintf(stderr, "playback position did not advance: %.3f\n", pos);
    rc = 20;
  }
  if (strcmp(mode, "audio") == 0) {
    if (strcmp(vo_cfg, "yes") == 0 || strcmp(vw, "<null>") != 0 || strcmp(arate, "<null>") == 0) {
      fprintf(stderr, "audio-only expected no video output and active audio, got vo_cfg=%s vw=%s arate=%s aid=%s\n", vo_cfg, vw, arate, aid);
      rc = 21;
    }
  } else {
    if (strcmp(vw, "<null>") == 0 || strcmp(arate, "<null>") == 0) {
      fprintf(stderr, "%s expected active video and audio, got vw=%s arate=%s vid=%s aid=%s\n", mode, vw, arate, vid, aid);
      rc = 22;
    }
    if (strcmp(vo_cfg, "yes") != 0) {
      fprintf(stderr, "%s expected vo-configured=yes, got %s\n", mode, vo_cfg);
      rc = 23;
    }
    if (strcmp(mode, "hls") == 0 && seek_pos < 1.1) {
      fprintf(stderr, "hls seek did not reach >=1.1s: %.3f\n", seek_pos);
      rc = 24;
    }
  }

  destroy(ctx);
  dlclose(handle);
  return rc;
}
'''


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


def run_cmd(cmd: list[str], **kwargs) -> subprocess.CompletedProcess[str]:
    print("+", " ".join(str(c) for c in cmd), flush=True)
    return subprocess.run(cmd, check=True, text=True, **kwargs)


def find_mpv_binary(app_path: Path) -> Path:
    candidates = [
        app_path / "Contents/Frameworks/Mpv.framework/Versions/A/Mpv",
        app_path / "Contents/Frameworks/Mpv.framework/Mpv",
    ]
    for candidate in candidates:
        if candidate.exists():
            return candidate.resolve()
    raise FileNotFoundError(f"Mpv.framework binary not found under {app_path}")


def generate_samples(work: Path) -> tuple[Path, Path, Path]:
    av_mp4 = work / "auth_sample.mp4"
    run_cmd([
        "ffmpeg", "-y", "-v", "error",
        "-f", "lavfi", "-i", "color=c=0x1e88e5:s=320x180:r=25:d=2.4",
        "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=2.4",
        "-c:v", "libx264", "-pix_fmt", "yuv420p", "-g", "25", "-b:v", "220k",
        "-c:a", "aac", "-ar", "48000", "-ac", "2", "-b:a", "64k",
        "-movflags", "+faststart",
        str(av_mp4),
    ])

    hls_dir = work / "offline_hls"
    hls_dir.mkdir(parents=True, exist_ok=True)
    run_cmd([
        "ffmpeg", "-y", "-v", "error",
        "-f", "lavfi", "-i", "color=c=0xd32f2f:s=320x180:r=25:d=2.4",
        "-an",
        "-c:v", "libx264", "-pix_fmt", "yuv420p", "-g", "25", "-keyint_min", "25", "-sc_threshold", "0",
        "-hls_time", "1.0", "-hls_playlist_type", "vod",
        "-hls_segment_filename", str(hls_dir / "v_%03d.ts"),
        str(hls_dir / "video.m3u8"),
    ])
    run_cmd([
        "ffmpeg", "-y", "-v", "error",
        "-f", "lavfi", "-i", "sine=frequency=660:sample_rate=48000:duration=2.4",
        "-vn",
        "-c:a", "aac", "-ar", "48000", "-ac", "2", "-b:a", "64k",
        "-hls_time", "1.0", "-hls_playlist_type", "vod",
        "-hls_segment_filename", str(hls_dir / "a_%03d.ts"),
        str(hls_dir / "audio.m3u8"),
    ])
    master_m3u8 = hls_dir / "master.m3u8"
    master_m3u8.write_text(
        "#EXTM3U\n"
        "#EXT-X-VERSION:3\n"
        '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="Chinese",LANGUAGE="zh",DEFAULT=YES,AUTOSELECT=YES,URI="audio.m3u8"\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=450000,RESOLUTION=320x180,AUDIO="aud"\n'
        "video.m3u8\n",
        encoding="utf-8",
    )

    audio_only = work / "radio_only.m4a"
    run_cmd([
        "ffmpeg", "-y", "-v", "error",
        "-f", "lavfi", "-i", "sine=frequency=523:sample_rate=48000:duration=2.0",
        "-vn",
        "-c:a", "aac", "-ar", "48000", "-ac", "2", "-b:a", "64k",
        str(audio_only),
    ])
    return av_mp4, master_m3u8, audio_only


def verify_unmodified_mpv(app_path: Path, work: Path) -> None:
    mpv_bin = find_mpv_binary(app_path)
    frameworks_dir = app_path / "Contents/Frameworks"
    c_src = work / "mpv_probe.c"
    probe_bin = work / "mpv_probe"
    c_src.write_text(MPV_PROBE_C, encoding="utf-8")
    run_cmd([
        "clang", "-O2", str(c_src),
        f"-Wl,-rpath,{frameworks_dir}",
        "-o", str(probe_bin),
    ])

    av_mp4, master_m3u8, audio_only = generate_samples(work)
    mp4_bytes = av_mp4.read_bytes()
    seen_headers: list[tuple[str, str]] = []

    class AuthHandler(http.server.BaseHTTPRequestHandler):
        def do_GET(self) -> None:
            auth = self.headers.get("X-Marco-Auth", "")
            ua = self.headers.get("User-Agent", "")
            seen_headers.append((auth, ua))
            if auth != "secret-mac-check" or "MarcoMacVerify/0.6" not in ua:
                self.send_response(403)
                self.end_headers()
                return
            self.send_response(200)
            self.send_header("Content-Type", "video/mp4")
            self.send_header("Content-Length", str(len(mp4_bytes)))
            self.end_headers()
            self.wfile.write(mp4_bytes)

        def log_message(self, format: str, *args) -> None:
            return

    server = socketserver.TCPServer(("127.0.0.1", 0), AuthHandler)
    port = server.server_address[1]
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        print("=== Unmodified .app Mpv.framework: Authenticated HTTP Header Playback ===", flush=True)
        run_cmd([
            str(probe_bin), str(mpv_bin), "http",
            f"http://127.0.0.1:{port}/auth_sample.mp4",
            "X-Marco-Auth: secret-mac-check",
            "MarcoMacVerify/0.6",
        ])
        if not any(a == "secret-mac-check" and "MarcoMacVerify/0.6" in u for a, u in seen_headers):
            raise AssertionError(f"Expected custom headers not observed: {seen_headers}")
        print(f"Verified custom HTTP headers observed by origin server: {seen_headers[0]}", flush=True)
    finally:
        server.shutdown()
        server.server_close()

    print("=== Unmodified .app Mpv.framework: Offline Dual-Track HLS Playback & Seek ===", flush=True)
    run_cmd([str(probe_bin), str(mpv_bin), "hls", str(master_m3u8)])

    print("=== Unmodified .app Mpv.framework: Audio-Only Stream Playback ===", flush=True)
    run_cmd([str(probe_bin), str(mpv_bin), "audio", str(audio_only)])


def verify_legacy_runner_upgrade_swiftc(app_path: Path, flutter_dir: Path, work: Path) -> None:
    print("=== 4429808 Legacy Runner Double-Upgrade + Apple swiftc Typecheck ===", flush=True)
    sys.path.insert(0, str(flutter_dir))
    import prepare_platform  # type: ignore

    legacy_swift = textwrap.dedent("""\
        import Cocoa
        import FlutterMacOS
        import WebKit

        class MainFlutterWindow: NSWindow {
          private var playbackActivity: NSObjectProtocol?

          override func awakeFromNib() {
            let flutterViewController = FlutterViewController()
            let windowFrame = self.frame
            self.contentViewController = flutterViewController
            self.setFrame(windowFrame, display: true)

            RegisterGeneratedPlugins(registry: flutterViewController)
            let wakelockChannel = FlutterMethodChannel(name: "marco_movie/wakelock", binaryMessenger: flutterViewController.engine.binaryMessenger)
            wakelockChannel.setMethodCallHandler { [weak self] call, result in
              if call.method == "setEnabled", let enabled = call.arguments as? Bool {
                if enabled {
                  if self?.playbackActivity == nil {
                    self?.playbackActivity = ProcessInfo.processInfo.beginActivity(options: .idleDisplaySleepDisabled, reason: "Marco Movie Video Playback")
                  }
                } else if let token = self?.playbackActivity {
                  ProcessInfo.processInfo.endActivity(token)
                  self?.playbackActivity = nil
                }
                result(nil)
              } else {
                result(FlutterMethodNotImplemented)
              }
            }

            self.titleVisibility = .hidden
            self.titlebarAppearsTransparent = true
            self.styleMask.insert(.fullSizeContentView)
            self.appearance = NSAppearance(named: .darkAqua)
            self.minSize = NSSize(width: 900, height: 600)
            super.awakeFromNib()
          }
        }
    """)

    fake_root = work / "legacy_flutter_root"
    runner = fake_root / "macos" / "Runner"
    runner.mkdir(parents=True, exist_ok=True)
    (runner / "MainFlutterWindow.swift").write_text(legacy_swift, encoding="utf-8")
    (runner / "Release.entitlements").write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<plist version="1.0"><dict>\n'
        '  <key>com.apple.security.app-sandbox</key><true/>\n'
        '  <key>com.apple.security.get-task-allow</key><true/>\n'
        '</dict></plist>\n',
        encoding="utf-8",
    )
    (runner / "Info.plist").write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<plist version="1.0"><dict><key>CFBundleName</key><string>marco_movie</string></dict></plist>\n',
        encoding="utf-8",
    )

    old_root = prepare_platform.ROOT
    try:
        prepare_platform.ROOT = fake_root
        prepare_platform.main()
        first_pass = (runner / "MainFlutterWindow.swift").read_text(encoding="utf-8")
        prepare_platform.main()
        second_pass = (runner / "MainFlutterWindow.swift").read_text(encoding="utf-8")
    finally:
        prepare_platform.ROOT = old_root

    if first_pass != second_pass:
        raise AssertionError("Running prepare_platform.py twice on legacy Runner was not idempotent")

    for required in (
        "private var marcoWindowObservers: [NSObjectProtocol] = []",
        "private var marcoInFullscreenTransition = false",
        "private var marcoIsMiniaturizing = false",
        "private var marcoIsClosing = false",
        "private var marcoRestoredFromSaved = false",
        "private var marcoLastNormalFrame: NSRect?",
        "deinit {",
    ):
        count = second_pass.count(required)
        if count != 1:
            raise AssertionError(f"Expected {required!r} exactly once, found {count}")

    rel_ent = (runner / "Release.entitlements").read_text(encoding="utf-8")
    if "com.apple.security.get-task-allow" in rel_ent:
        raise AssertionError("Release.entitlements still contains com.apple.security.get-task-allow")

    stub_swift = work / "GeneratedPluginRegistrantStub.swift"
    stub_swift.write_text(
        "import FlutterMacOS\nfunc RegisterGeneratedPlugins(registry: FlutterPluginRegistry) {}\n",
        encoding="utf-8",
    )
    sdk_path = subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip()
    flutter_exe = shutil.which("flutter")
    flutter_root = Path(flutter_exe).resolve().parents[1] if flutter_exe else None
    fw_candidates = [
        flutter_dir / "macos/Flutter/ephemeral",
        flutter_dir / "build/macos/Build/Products/Release",
    ]
    if flutter_root is not None:
        fw_candidates.extend([
            flutter_root / "bin/cache/artifacts/engine/darwin-x64-release/FlutterMacOS.xcframework/macos-arm64_x86_64",
            flutter_root / "bin/cache/artifacts/engine/darwin-x64-release",
            flutter_root / "bin/cache/artifacts/engine/darwin-x64/FlutterMacOS.xcframework/macos-arm64_x86_64",
            flutter_root / "bin/cache/artifacts/engine/darwin-x64",
        ])
    fw_dirs: list[Path] = []
    for cand in fw_candidates:
        fw = cand / "FlutterMacOS.framework"
        if fw.exists() and (
            (fw / "Modules").exists()
            or (fw / "Versions/A/Modules").exists()
            or (fw / "Headers").exists()
            or (fw / "Versions/A/Headers").exists()
        ):
            fw_dirs.append(cand)
    if not fw_dirs:
        fw_dirs.append(app_path / "Contents/Frameworks")
    swift_cmd = ["swiftc", "-typecheck", "-sdk", sdk_path]
    for d in fw_dirs:
        swift_cmd.extend(["-F", str(d)])
    swift_cmd.extend([str(runner / "MainFlutterWindow.swift"), str(stub_swift)])
    run_cmd(swift_cmd)
    print("LEGACY_RUNNER_DOUBLE_UPGRADE_SWIFTC=PASS", flush=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--flutter-dir", type=Path, required=True)
    args = parser.parse_args()

    app_path = args.app.resolve()
    flutter_dir = args.flutter_dir.resolve()
    main_bin = next(p for p in (app_path / "Contents/MacOS").iterdir() if p.is_file() and os.access(p, os.X_OK))
    mpv_bin = find_mpv_binary(app_path)
    node_bin = app_path / "Contents/Frameworks/node/bin/node"

    before = {
        "main_bin": sha256_file(main_bin),
        "mpv_bin": sha256_file(mpv_bin),
        "node_bin": sha256_file(node_bin),
    }

    with tempfile.TemporaryDirectory(prefix="marco-unmodified-verify-") as tmp:
        work = Path(tmp)
        verify_unmodified_mpv(app_path, work)
        verify_legacy_runner_upgrade_swiftc(app_path, flutter_dir, work)

    after = {
        "main_bin": sha256_file(main_bin),
        "mpv_bin": sha256_file(mpv_bin),
        "node_bin": sha256_file(node_bin),
    }
    if before != after:
        raise AssertionError(f"Unmodified .app binaries changed during verification! before={before} after={after}")
    run_cmd(["codesign", "--verify", "--deep", "--strict", str(app_path)])
    print(
        f"UNMODIFIED_APP_INTEGRITY=PASS main={after['main_bin'][:12]} "
        f"mpv={after['mpv_bin'][:12]} node={after['node_bin'][:12]}",
        flush=True,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
