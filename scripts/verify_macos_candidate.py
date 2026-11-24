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
import json
import os
import shutil
import socketserver
import struct
import subprocess
import sys
import tempfile
import textwrap
import threading
import zlib
from pathlib import Path

MPV_PROBE_C = r'''
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct mpv_handle mpv_handle;
typedef struct mpv_render_context mpv_render_context;
typedef struct mpv_event {
  int event_id;
  int error;
  unsigned long long reply_userdata;
  void *data;
} mpv_event;

typedef struct mpv_render_param {
  int type;
  void *data;
} mpv_render_param;

enum {
  MPV_EVENT_NONE = 0,
  MPV_EVENT_SHUTDOWN = 1,
  MPV_EVENT_END_FILE = 7,
  MPV_EVENT_FILE_LOADED = 8,
};

enum {
  MPV_RENDER_PARAM_INVALID = 0,
  MPV_RENDER_PARAM_API_TYPE = 1,
  MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME = 12,
  MPV_RENDER_PARAM_SW_SIZE = 17,
  MPV_RENDER_PARAM_SW_FORMAT = 18,
  MPV_RENDER_PARAM_SW_STRIDE = 19,
  MPV_RENDER_PARAM_SW_POINTER = 20,
  MPV_RENDER_UPDATE_FRAME = 1,
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
typedef int (*fn_render_context_create)(mpv_render_context **, mpv_handle *, mpv_render_param *);
typedef uint64_t (*fn_render_context_update)(mpv_render_context *);
typedef int (*fn_render_context_render)(mpv_render_context *, mpv_render_param *);
typedef void (*fn_render_context_free)(mpv_render_context *);

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
    fprintf(stderr, "Usage: %s <mpv_lib> <mode:http|hls|audio|subframe|meta> <uri> [arg4] [arg5] [arg6]\n", argv[0]);
    return 2;
  }
  const char *mpv_path = argv[1];
  const char *mode = argv[2];
  const char *uri = argv[3];
  const char *arg4 = argc >= 5 ? argv[4] : "";
  const char *arg5 = argc >= 6 ? argv[5] : "";
  const char *arg6 = argc >= 7 ? argv[6] : "";

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

  set_opt(ctx, "ao", "null");
  set_opt(ctx, "terminal", "no");
  set_opt(ctx, "config", "no");
  set_opt(ctx, "ytdl", "no");
  set_opt(ctx, "demuxer-lavf-o", "protocol_whitelist=[file,http,https,tcp,tls,crypto,data]");

  if (strcmp(mode, "subframe") == 0) {
    // arg4 = sid ("no", "1", "2", "3"), arg5 = sub-pos ("100", "88", "92"), arg6 = out_ppm_path
    const char *sid = arg4[0] ? arg4 : "no";
    const char *sub_pos = arg5[0] ? arg5 : "100";
    const char *out_ppm = arg6[0] ? arg6 : "frame.ppm";
    fn_render_context_create rc_create = (fn_render_context_create)dlsym(handle, "mpv_render_context_create");
    fn_render_context_update rc_update = (fn_render_context_update)dlsym(handle, "mpv_render_context_update");
    fn_render_context_render rc_render = (fn_render_context_render)dlsym(handle, "mpv_render_context_render");
    fn_render_context_free rc_free = (fn_render_context_free)dlsym(handle, "mpv_render_context_free");
    if (!rc_create || !rc_update || !rc_render || !rc_free) {
      fprintf(stderr, "missing mpv_render_context symbols\n");
      destroy(ctx);
      dlclose(handle);
      return 11;
    }

    set_opt(ctx, "vo", "libmpv");
    set_opt(ctx, "hwdec", "no");
    set_opt(ctx, "sid", sid);
    set_opt(ctx, "sub-ass", "yes");
    set_opt(ctx, "sub-ass-override", "yes");
    set_opt(ctx, "sub-visibility", strcmp(sid, "no") == 0 ? "no" : "yes");
    set_opt(ctx, "sub-pos", sub_pos);
    set_opt(ctx, "speed", "2");
    if (init(ctx) < 0) {
      fprintf(stderr, "mpv_initialize failed (subframe)\n");
      destroy(ctx);
      dlclose(handle);
      return 13;
    }

    mpv_render_context *rctx = NULL;
    char api_sw[] = "sw";
    mpv_render_param create_params[] = {
      {MPV_RENDER_PARAM_API_TYPE, api_sw},
      {MPV_RENDER_PARAM_INVALID, NULL},
    };
    int rc_err = rc_create(&rctx, ctx, create_params);
    if (rc_err < 0 || !rctx) {
      fprintf(stderr, "mpv_render_context_create(sw) failed: %d\n", rc_err);
      destroy(ctx);
      dlclose(handle);
      return 31;
    }

    const int width = 1280;
    const int height = 720;
    size_t stride = (size_t)width * 4;
    uint8_t *fb = (uint8_t *)calloc((size_t)height, stride);
    if (!fb) {
      rc_free(rctx);
      destroy(ctx);
      dlclose(handle);
      return 32;
    }
    int sw_size[2] = {width, height};
    char sw_fmt[] = "bgr0";
    int block_flag = 0;
    mpv_render_param render_params[] = {
      {MPV_RENDER_PARAM_SW_SIZE, sw_size},
      {MPV_RENDER_PARAM_SW_FORMAT, sw_fmt},
      {MPV_RENDER_PARAM_SW_STRIDE, &stride},
      {MPV_RENDER_PARAM_SW_POINTER, fb},
      {MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, &block_flag},
      {MPV_RENDER_PARAM_INVALID, NULL},
    };

    const char *load_args[] = {"loadfile", uri, NULL};
    if (cmd(ctx, load_args) < 0) {
      fprintf(stderr, "loadfile failed (subframe)\n");
      free(fb);
      rc_free(rctx);
      destroy(ctx);
      dlclose(handle);
      return 14;
    }

    int loaded = 0;
    int rendered = 0;
    double cur_pos = 0.0;
    for (int i = 0; i < 200; i++) {
      while (1) {
        mpv_event *ev = wait_event(ctx, 0.0);
        if (!ev || ev->event_id == MPV_EVENT_NONE) break;
        if (ev->event_id == MPV_EVENT_FILE_LOADED) {
          loaded = 1;
          // Explicitly re-apply requested sid & sub-pos once tracks are loaded
          set_prop(ctx, "sid", sid);
          set_prop(ctx, "sub-pos", sub_pos);
          set_prop(ctx, "sub-ass", "yes");
          set_prop(ctx, "sub-ass-override", "yes");
          set_prop(ctx, "sub-visibility", strcmp(sid, "no") == 0 ? "no" : "yes");
        }
      }
      uint64_t upd = rc_update(rctx);
      if (upd & MPV_RENDER_UPDATE_FRAME) {
        if (rc_render(rctx, render_params) == 0) {
          rendered++;
        }
      }
      if (loaded) {
        char pos_buf[64];
        prop_or_none(get_prop, mfree, ctx, "time-pos", pos_buf, sizeof(pos_buf));
        cur_pos = atof(pos_buf);
        if (cur_pos >= 1.75) {
          set_prop(ctx, "pause", "yes");
          if (cur_pos > 4.20) {
            const char *seek_args[] = {"seek", "2.0", "absolute+exact", NULL};
            cmd(ctx, seek_args);
          }
          for (int k = 0; k < 12; k++) {
            usleep(30000);
            while (1) {
              mpv_event *ev = wait_event(ctx, 0.0);
              if (!ev || ev->event_id == MPV_EVENT_NONE) break;
            }
            rc_update(rctx);
            if (rc_render(rctx, render_params) == 0) {
              rendered++;
            }
          }
          prop_or_none(get_prop, mfree, ctx, "time-pos", pos_buf, sizeof(pos_buf));
          cur_pos = atof(pos_buf);
          break;
        }
      }
      usleep(35000);
    }

    char applied_sid[64], applied_pos[64], applied_ass[64], applied_ov[64], track_list[2048];
    prop_or_none(get_prop, mfree, ctx, "sid", applied_sid, sizeof(applied_sid));
    prop_or_none(get_prop, mfree, ctx, "sub-pos", applied_pos, sizeof(applied_pos));
    prop_or_none(get_prop, mfree, ctx, "sub-ass", applied_ass, sizeof(applied_ass));
    prop_or_none(get_prop, mfree, ctx, "sub-ass-override", applied_ov, sizeof(applied_ov));
    prop_or_none(get_prop, mfree, ctx, "track-list", track_list, sizeof(track_list));
    printf("SUBFRAME_DONE=1 LOADED=%d RENDERED=%d POS=%.3f SID=%s SUB_POS=%s SUB_ASS=%s SUB_ASS_OVERRIDE=%s\n",
           loaded, rendered, cur_pos, applied_sid, applied_pos, applied_ass, applied_ov);
    printf("TRACK_LIST=%s\n", track_list);

    int write_ok = 0;
    if (loaded && rendered > 0) {
      FILE *fp = fopen(out_ppm, "wb");
      if (fp) {
        fprintf(fp, "P6\n%d %d\n255\n", width, height);
        uint8_t *row_rgb = (uint8_t *)malloc((size_t)width * 3);
        if (row_rgb) {
          for (int y = 0; y < height; y++) {
            const uint8_t *src = fb + (size_t)y * stride;
            for (int x = 0; x < width; x++) {
              row_rgb[x * 3 + 0] = src[x * 4 + 2]; // R
              row_rgb[x * 3 + 1] = src[x * 4 + 1]; // G
              row_rgb[x * 3 + 2] = src[x * 4 + 0]; // B
            }
            fwrite(row_rgb, 1, (size_t)width * 3, fp);
          }
          free(row_rgb);
          write_ok = 1;
        }
        fclose(fp);
      }
    }

    free(fb);
    rc_free(rctx);
    destroy(ctx);
    dlclose(handle);
    return write_ok ? 0 : 30;
  }

  set_opt(ctx, "vo", "null");
  if (strcmp(mode, "meta") == 0) {
    if (init(ctx) < 0) {
      fprintf(stderr, "mpv_initialize failed (meta)\n");
      destroy(ctx);
      return 13;
    }
    const char *load_args[] = {"loadfile", uri, NULL};
    if (cmd(ctx, load_args) < 0) {
      fprintf(stderr, "loadfile failed (meta)\n");
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
        destroy(ctx);
        dlclose(handle);
        return 15;
      }
    }
    char meta_buf[4096], title_buf[512];
    prop_or_none(get_prop, mfree, ctx, "metadata", meta_buf, sizeof(meta_buf));
    prop_or_none(get_prop, mfree, ctx, "media-title", title_buf, sizeof(title_buf));
    printf("META_LOADED=%d\nMEDIA_TITLE=%s\nMETADATA=%s\n", loaded, title_buf, meta_buf);
    destroy(ctx);
    dlclose(handle);
    return loaded ? 0 : 31;
  }

  if (arg4[0] != '\0') {
    set_opt(ctx, "http-header-fields", arg4);
  }
  if (arg5[0] != '\0') {
    set_opt(ctx, "user-agent", arg5);
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


def verify_unmodified_mpv(
    app_path: Path,
    work: Path,
    artifacts_dir: Path | None = None,
) -> None:
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

    verify_unmodified_mpv_subtitles_and_tags(probe_bin, mpv_bin, work, artifacts_dir)


_FONT_5X7: dict[str, tuple[str, ...]] = {
    "A": ("01110", "10001", "10001", "11111", "10001", "10001", "10001"),
    "B": ("11110", "10001", "10001", "11110", "10001", "10001", "11110"),
    "C": ("01110", "10001", "10000", "10000", "10000", "10001", "01110"),
    "D": ("11110", "10001", "10001", "10001", "10001", "10001", "11110"),
    "E": ("11111", "10000", "10000", "11110", "10000", "10000", "11111"),
    "F": ("11111", "10000", "10000", "11110", "10000", "10000", "10000"),
    "G": ("01110", "10001", "10000", "10111", "10001", "10001", "01110"),
    "H": ("10001", "10001", "10001", "11111", "10001", "10001", "10001"),
    "I": ("01110", "00100", "00100", "00100", "00100", "00100", "01110"),
    "L": ("10000", "10000", "10000", "10000", "10000", "10000", "11111"),
    "M": ("10001", "11011", "10101", "10101", "10001", "10001", "10001"),
    "N": ("10001", "11001", "10101", "10011", "10001", "10001", "10001"),
    "O": ("01110", "10001", "10001", "10001", "10001", "10001", "01110"),
    "P": ("11110", "10001", "10001", "11110", "10000", "10000", "10000"),
    "R": ("11110", "10001", "10001", "11110", "10100", "10010", "10001"),
    "S": ("01111", "10000", "10000", "01110", "00001", "00001", "11110"),
    "T": ("11111", "00100", "00100", "00100", "00100", "00100", "00100"),
    "U": ("10001", "10001", "10001", "10001", "10001", "10001", "01110"),
    "V": ("10001", "10001", "10001", "10001", "10001", "01010", "00100"),
    "X": ("10001", "10001", "01010", "00100", "01010", "10001", "10001"),
    "0": ("01110", "10001", "10011", "10101", "11001", "10001", "01110"),
    "1": ("00100", "01100", "00100", "00100", "00100", "00100", "01110"),
    "2": ("01110", "10001", "00001", "00110", "01000", "10000", "11111"),
    "7": ("11111", "00001", "00010", "00100", "01000", "01000", "01000"),
    "8": ("01110", "10001", "10001", "01110", "10001", "10001", "01110"),
    ":": ("00000", "00100", "00100", "00000", "00100", "00100", "00000"),
    "(": ("00010", "00100", "01000", "01000", "01000", "00100", "00010"),
    ")": ("01000", "00100", "00010", "00010", "00010", "00100", "01000"),
    " ": ("00000", "00000", "00000", "00000", "00000", "00000", "00000"),
}


def _pgs_segment(pts_90k: int, seg_type: int, payload: bytes) -> bytes:
    return b"PG" + struct.pack(">IIBH", pts_90k, 0, seg_type, len(payload)) + payload


def _pgs_rle_encode(rows: list[bytes]) -> bytes:
    out = bytearray()
    for row in rows:
        i = 0
        n = len(row)
        while i < n:
            color = row[i]
            j = i + 1
            while j < n and row[j] == color and (j - i) < 16383:
                j += 1
            run = j - i
            if color == 0:
                if run < 64:
                    out.extend((0, run))
                else:
                    out.extend((0, 0x40 | (run >> 8), run & 0xFF))
            else:
                if run == 1:
                    out.append(color)
                elif run < 64:
                    out.extend((0, 0x80 | run, color))
                else:
                    out.extend((0, 0xC0 | (run >> 8), run & 0xFF, color))
            i = j
        out.extend((0, 0))
    return bytes(out)


def build_pgs_sup(out_path: Path) -> None:
    """Synthesizes a spec-compliant 1280x720 two-line Blu-ray PGS (.sup) stream."""
    vid_w, vid_h = 1280, 720
    obj_w, obj_h = 840, 104
    obj_x, obj_y = (vid_w - obj_w) // 2, 592

    # Palette indices: 0=transparent, 1=dark box, 2=emerald border, 3=white text
    canvas = [bytearray([1] * obj_w) for _ in range(obj_h)]
    for y in range(obj_h):
        if y < 4 or y >= obj_h - 4:
            canvas[y] = bytearray([2] * obj_w)
        else:
            for x in range(4):
                canvas[y][x] = 2
                canvas[y][obj_w - 1 - x] = 2

    def draw_line(text: str, top_y: int, scale: int = 4) -> None:
        text = text.upper()
        char_w = 6 * scale
        total_w = len(text) * char_w - scale
        start_x = max(12, (obj_w - total_w) // 2)
        for idx, ch in enumerate(text):
            glyph = _FONT_5X7.get(ch, _FONT_5X7[" "])
            gx0 = start_x + idx * char_w
            for gy, row_bits in enumerate(glyph):
                for gx, bit in enumerate(row_bits):
                    if bit != "1":
                        continue
                    for sy in range(scale):
                        py = top_y + gy * scale + sy
                        if 0 <= py < obj_h:
                            for sx in range(scale):
                                px = gx0 + gx * scale + sx
                                if 0 <= px < obj_w:
                                    canvas[py][px] = 3

    draw_line("PGS BITMAP LINE 1 (1280X720)", 14, scale=4)
    draw_line("LINE 2: LIFTS ABOVE BOTTOM HUD", 58, scale=4)

    rle = _pgs_rle_encode([bytes(r) for r in canvas])

    # Display set 1: Epoch Start at t=0.40s (36000 ticks at 90kHz)
    pts_show = int(0.40 * 90000)
    pcs_show = struct.pack(
        ">HHBHBBBBHBBHH",
        vid_w, vid_h, 0x10,
        0, 0x80, 0, 0, 1,
        0, 0, 0, obj_x, obj_y,
    )
    wds_show = struct.pack(">BBHHHH", 1, 0, obj_x, obj_y, obj_w, obj_h)
    # BT.709-like YCrCbA entries
    pds_show = bytes([
        0, 0,
        0, 16, 128, 128, 0,     # 0: transparent
        1, 24, 128, 128, 220,   # 1: dark translucent plate
        2, 195, 55, 110, 255,   # 2: bright emerald green border
        3, 235, 128, 128, 255,  # 3: crisp white text
    ])
    ods_body = struct.pack(">HH", obj_w, obj_h) + rle
    ods_len = len(ods_body)
    ods_show = (
        struct.pack(">HBB", 0, 0, 0xC0)
        + bytes([(ods_len >> 16) & 0xFF, (ods_len >> 8) & 0xFF, ods_len & 0xFF])
        + ods_body
    )

    # Display set 2: Refresh Epoch Start at t=1.60s so seeking/playback around t=2.0s always hits a keyframe
    pts_show2 = int(1.60 * 90000)
    pcs_show2 = struct.pack(
        ">HHBHBBBBHBBHH",
        vid_w, vid_h, 0x10,
        1, 0x80, 0, 0, 1,
        0, 0, 0, obj_x, obj_y,
    )

    # Display set 3: Clear at t=4.60s
    pts_clear = int(4.60 * 90000)
    pcs_clear = struct.pack(">HHBHBBBB", vid_w, vid_h, 0x10, 2, 0x00, 0, 0, 0)

    data = b"".join([
        _pgs_segment(pts_show, 0x16, pcs_show),
        _pgs_segment(pts_show, 0x17, wds_show),
        _pgs_segment(pts_show, 0x14, pds_show),
        _pgs_segment(pts_show, 0x15, ods_show),
        _pgs_segment(pts_show, 0x80, b""),
        _pgs_segment(pts_show2, 0x16, pcs_show2),
        _pgs_segment(pts_show2, 0x17, wds_show),
        _pgs_segment(pts_show2, 0x14, pds_show),
        _pgs_segment(pts_show2, 0x15, ods_show),
        _pgs_segment(pts_show2, 0x80, b""),
        _pgs_segment(pts_clear, 0x16, pcs_clear),
        _pgs_segment(pts_clear, 0x80, b""),
    ])
    out_path.write_bytes(data)


def generate_subtitle_and_tag_samples(work: Path) -> tuple[Path, Path]:
    """Generates one multi-track MKV (SRT + ASS + Blu-ray PGS) and tagged clip-A.mkv."""
    srt_path = work / "sub_text.srt"
    srt_path.write_text(
        "1\n"
        "00:00:00,400 --> 00:00:04,600\n"
        "第一行可选文字字幕：底部控件出现时整体上移\n"
        "第二行双行字幕最下沿必须高于底部控件上沿\n",
        encoding="utf-8",
    )

    ass_path = work / "sub_styled.ass"
    ass_path.write_text(
        "[Script Info]\n"
        "ScriptType: v4.00+\n"
        "PlayResX: 1280\n"
        "PlayResY: 720\n"
        "ScaledBorderAndShadow: yes\n\n"
        "[V4+ Styles]\n"
        "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, "
        "Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, "
        "Alignment, MarginL, MarginR, MarginV, Encoding\n"
        "Style: Default,PingFang SC,40,&H0058EEFF,&H000000FF,&H00101010,&H80000000,-1,0,0,0,100,100,0,0,1,3,1,2,20,20,24,1\n"
        "Style: TopSign,PingFang SC,34,&H00FFE500,&H000000FF,&H00101010,&H80000000,-1,0,0,0,100,100,0,0,1,3,1,8,20,20,22,1\n\n"
        "[Events]\n"
        "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n"
        "Dialogue: 0,0:00:00.40,0:00:04.60,TopSign,,0,0,0,,{\\an8}ASS TOP SIGN (\\an8) - FIXED POSITION\n"
        "Dialogue: 0,0:00:00.40,0:00:04.60,Default,,0,0,0,,ASS LINE 1: TWO-LINE BOTTOM SUBTITLE\\NASS LINE 2: LIFTS STRICTLY ABOVE CONTROLS\n",
        encoding="utf-8",
    )

    pgs_path = work / "sub_pgs.sup"
    build_pgs_sup(pgs_path)

    sub_mkv = work / "subtitle_verify.mkv"
    run_cmd([
        "ffmpeg", "-y", "-v", "error",
        "-f", "lavfi", "-i", "color=c=0x122238:s=1280x720:r=10:d=5.0",
        "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=5.0",
        "-i", str(srt_path),
        "-i", str(ass_path),
        "-i", str(pgs_path),
        "-map", "0:v", "-map", "1:a", "-map", "2:s", "-map", "3:s", "-map", "4:s",
        "-c:v", "libx264", "-pix_fmt", "yuv420p", "-g", "10", "-b:v", "350k",
        "-c:a", "aac", "-ar", "48000", "-ac", "2", "-b:a", "64k",
        "-c:s:0", "subrip",
        "-c:s:1", "ass",
        "-c:s:2", "copy",
        "-metadata:s:s:0", "title=Optional Text SRT",
        "-metadata:s:s:1", "title=Styled ASS Top+Bottom",
        "-metadata:s:s:2", "title=Blu-ray PGS Bitmap",
        str(sub_mkv),
    ])

    clip_a_mkv = work / "clip-A.mkv"
    run_cmd([
        "ffmpeg", "-y", "-v", "error",
        "-f", "lavfi", "-i", "color=c=0x182838:s=320x180:r=10:d=1.5",
        "-f", "lavfi", "-i", "sine=frequency=520:sample_rate=48000:duration=1.5",
        "-c:v", "libx264", "-pix_fmt", "yuv420p", "-b:v", "120k",
        "-c:a", "aac", "-ar", "48000", "-ac", "2", "-b:a", "64k",
        "-metadata", "title=星际测试物语 S02E10 第二季高潮",
        "-metadata", "SEASON=2",
        "-metadata", "EPISODE=10",
        str(clip_a_mkv),
    ])
    return sub_mkv, clip_a_mkv


def decode_png_rgb(path: Path) -> tuple[int, int, bytes]:
    """Minimal pure-Python 8-bit RGB/RGBA PNG decoder (supports all 5 PNG filters)."""
    raw = path.read_bytes()
    if raw[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError(f"Not a PNG file: {path}")
    pos = 8
    width = height = bit_depth = color_type = 0
    idat = bytearray()
    while pos + 8 <= len(raw):
        length, ctype = struct.unpack(">I4s", raw[pos:pos + 8])
        cdata = raw[pos + 8:pos + 8 + length]
        pos += 12 + length
        if ctype == b"IHDR":
            width, height, bit_depth, color_type, _, _, interlace = struct.unpack(">IIBBBBB", cdata)
            if bit_depth != 8 or color_type not in (2, 6) or interlace != 0:
                raise ValueError(f"Unsupported PNG format: bd={bit_depth} ct={color_type} interlace={interlace}")
        elif ctype == b"IDAT":
            idat.extend(cdata)
        elif ctype == b"IEND":
            break
    bpp = 3 if color_type == 2 else 4
    stride = width * bpp
    decomp = zlib.decompress(bytes(idat))
    out = bytearray(width * height * 3)
    prev = bytearray(stride)
    idx = 0
    for y in range(height):
        flt = decomp[idx]
        idx += 1
        row = bytearray(decomp[idx:idx + stride])
        idx += stride
        if flt == 1:
            for i in range(bpp, stride):
                row[i] = (row[i] + row[i - bpp]) & 0xFF
        elif flt == 2:
            for i in range(stride):
                row[i] = (row[i] + prev[i]) & 0xFF
        elif flt == 3:
            for i in range(stride):
                left = row[i - bpp] if i >= bpp else 0
                row[i] = (row[i] + ((left + prev[i]) >> 1)) & 0xFF
        elif flt == 4:
            for i in range(stride):
                a = row[i - bpp] if i >= bpp else 0
                b = prev[i]
                c = prev[i - bpp] if i >= bpp else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                row[i] = (row[i] + pr) & 0xFF
        elif flt != 0:
            raise ValueError(f"Unsupported PNG filter {flt}")
        prev = row
        dst = y * width * 3
        if bpp == 3:
            out[dst:dst + width * 3] = row
        else:
            for x in range(width):
                out[dst + x * 3] = row[x * 4]
                out[dst + x * 3 + 1] = row[x * 4 + 1]
                out[dst + x * 3 + 2] = row[x * 4 + 2]
    return width, height, bytes(out)


def find_pixel_y_bounds(
    rgb: bytes,
    width: int,
    height: int,
    y_start: int,
    y_end: int,
    predicate,
) -> tuple[int | None, int | None, int]:
    y_min = None
    y_max = None
    count = 0
    for y in range(max(0, y_start), min(height, y_end)):
        row_off = y * width * 3
        row_hit = False
        for x in range(0, width, 2):
            off = row_off + x * 3
            if predicate(rgb[off], rgb[off + 1], rgb[off + 2]):
                count += 1
                row_hit = True
        if row_hit:
            if y_min is None:
                y_min = y
            y_max = y
    return y_min, y_max, count


def _png_chunk(tag: bytes, payload: bytes) -> bytes:
    return struct.pack(">I", len(payload)) + tag + payload + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF)


def ppm_to_png(ppm_path: Path, png_path: Path) -> tuple[int, int]:
    """Pure-Python P6 PPM -> standard 24-bit RGB PNG converter (zero encoder deps)."""
    data = ppm_path.read_bytes()
    if not data.startswith(b"P6"):
        raise ValueError(f"Not a binary P6 PPM file: {ppm_path}")
    idx = 2
    tokens: list[bytes] = []
    n = len(data)
    while len(tokens) < 3 and idx < n:
        while idx < n and data[idx] in b" \t\r\n":
            idx += 1
        if idx < n and data[idx] == ord("#"):
            while idx < n and data[idx] != ord("\n"):
                idx += 1
            continue
        start = idx
        while idx < n and data[idx] not in b" \t\r\n":
            idx += 1
        if idx > start:
            tokens.append(data[start:idx])
    if len(tokens) != 3:
        raise ValueError(f"Malformed PPM header in {ppm_path}")
    width, height, maxval = int(tokens[0]), int(tokens[1]), int(tokens[2])
    if maxval != 255:
        raise ValueError(f"Unsupported PPM maxval {maxval}")
    if idx < n and data[idx] in b" \t\r\n":
        idx += 1
    rgb = data[idx:idx + width * height * 3]
    if len(rgb) != width * height * 3:
        raise ValueError(f"Truncated PPM payload in {ppm_path}: got {len(rgb)} bytes, expected {width * height * 3}")
    stride = width * 3
    raw = bytearray()
    for y in range(height):
        raw.append(0)  # Filter type 0 (None)
        raw.extend(rgb[y * stride:(y + 1) * stride])
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    png_bytes = (
        b"\x89PNG\r\n\x1a\n"
        + _png_chunk(b"IHDR", ihdr)
        + _png_chunk(b"IDAT", zlib.compress(bytes(raw), level=6))
        + _png_chunk(b"IEND", b"")
    )
    png_path.parent.mkdir(parents=True, exist_ok=True)
    png_path.write_bytes(png_bytes)
    return width, height


def verify_unmodified_mpv_subtitles_and_tags(
    probe_bin: Path,
    mpv_bin: Path,
    work: Path,
    artifacts_dir: Path | None,
) -> None:
    print("=== Unmodified .app Mpv.framework: Same-MKV ASS (Top Sign + 2-Line Bottom) & PGS Lift + Container Tags ===", flush=True)
    sub_mkv, clip_a_mkv = generate_subtitle_and_tag_samples(work)

    # Verify container streams via ffprobe first
    probe_streams = run_cmd([
        "ffprobe", "-v", "error", "-show_entries", "stream=index,codec_type,codec_name",
        "-of", "json", str(sub_mkv),
    ], capture_output=True)
    stream_codecs = [s.get("codec_name") for s in json.loads(probe_streams.stdout).get("streams", [])]
    print(f"SUBTITLE_VERIFY_MKV_CODECS={stream_codecs}", flush=True)
    for req_codec in ("h264", "aac", "subrip", "ass", "hdmv_pgs_subtitle"):
        if req_codec not in stream_codecs:
            raise AssertionError(f"Expected codec {req_codec} in subtitle_verify.mkv, got {stream_codecs}")

    # Verify unmodified Mpv.framework reads clip-A.mkv container tags directly
    meta_proc = run_cmd(
        [str(probe_bin), str(mpv_bin), "meta", str(clip_a_mkv)],
        capture_output=True,
    )
    print(meta_proc.stdout.strip(), flush=True)
    if "S02E10" not in meta_proc.stdout:
        raise AssertionError(f"Expected S02E10 in clip-A.mkv Mpv.framework metadata output:\n{meta_proc.stdout}")
    print("UNMODIFIED_MPV_CONTAINER_TAG_S02E10=PASS", flush=True)

    # Render 7 frames at exact t=2.0s from the SAME subtitle_verify.mkv
    renders = [
        ("mpv_video_only.png", "no", "100"),
        ("mpv_ass_pos100.png", "2", "100"),
        ("mpv_ass_lifted_narrow.png", "2", "88"),
        ("mpv_ass_lifted_fullscreen.png", "2", "92"),
        ("mpv_pgs_pos100.png", "3", "100"),
        ("mpv_pgs_lifted_narrow.png", "3", "88"),
        ("mpv_pgs_lifted_fullscreen.png", "3", "92"),
    ]
    out_frames_dir = (artifacts_dir / "mpv_frames") if artifacts_dir is not None else (work / "mpv_frames")
    out_frames_dir.mkdir(parents=True, exist_ok=True)

    rendered_paths: dict[str, Path] = {}
    for filename, sid, sub_pos in renders:
        ppm_path = work / filename.replace(".png", ".ppm")
        proc = run_cmd([
            str(probe_bin), str(mpv_bin), "subframe", str(sub_mkv),
            sid, sub_pos, str(ppm_path),
        ], capture_output=True)
        print(proc.stdout.strip(), flush=True)
        if f"SID={sid} " not in proc.stdout:
            raise AssertionError(
                f"Mpv.framework failed to select expected subtitle track SID={sid} for {filename} "
                f"(possible missing decoder in Avcodec.framework):\n{proc.stdout}\n{proc.stderr}"
            )
        if not ppm_path.exists() or ppm_path.stat().st_size == 0:
            raise AssertionError(f"Mpv.framework SW render emitted no PPM for {filename} (sid={sid}, sub-pos={sub_pos})")
        dest = out_frames_dir / filename
        ppm_to_png(ppm_path, dest)
        rendered_paths[filename] = dest

    # Pixel-level geometric assertions on the REAL Mpv.framework rendered frames!
    is_cyan_top = lambda r, g, b: b > 160 and g > 140 and r < 110
    is_yellow_bottom = lambda r, g, b: r > 170 and g > 155 and b < 130
    is_pgs_bright = lambda r, g, b: (g > 150 and r < 140) or (r > 190 and g > 190 and b > 190)

    metrics: dict[str, object] = {"codecs": stream_codecs, "frames": {}}

    def measure_ass(name: str) -> dict[str, object]:
        w, h, rgb = decode_png_rgb(rendered_paths[name])
        top_min, top_max, top_cnt = find_pixel_y_bounds(rgb, w, h, 0, 220, is_cyan_top)
        bot_min, bot_max, bot_cnt = find_pixel_y_bounds(rgb, w, h, 360, h, is_yellow_bottom)
        res = {
            "width": w, "height": h,
            "top_sign_y_min": top_min, "top_sign_y_max": top_max, "top_sign_pixels": top_cnt,
            "bottom_sub_y_min": bot_min, "bottom_sub_y_max": bot_max, "bottom_sub_pixels": bot_cnt,
        }
        metrics["frames"][name] = res  # type: ignore[index]
        return res

    def measure_pgs(name: str) -> dict[str, object]:
        w, h, rgb = decode_png_rgb(rendered_paths[name])
        bot_min, bot_max, bot_cnt = find_pixel_y_bounds(rgb, w, h, 360, h, is_pgs_bright)
        res = {
            "width": w, "height": h,
            "pgs_y_min": bot_min, "pgs_y_max": bot_max, "pgs_pixels": bot_cnt,
        }
        metrics["frames"][name] = res  # type: ignore[index]
        return res

    ass_base = measure_ass("mpv_ass_pos100.png")
    ass_narrow = measure_ass("mpv_ass_lifted_narrow.png")
    ass_full = measure_ass("mpv_ass_lifted_fullscreen.png")
    pgs_base = measure_pgs("mpv_pgs_pos100.png")
    pgs_narrow = measure_pgs("mpv_pgs_lifted_narrow.png")
    pgs_full = measure_pgs("mpv_pgs_lifted_fullscreen.png")

    print("MPV_SUBTITLE_PIXEL_METRICS=" + json.dumps(metrics, ensure_ascii=False), flush=True)

    # 1. ASS top sign (\an8) MUST retain its exact original position!
    for label, sample in (("narrow", ass_narrow), ("fullscreen", ass_full)):
        if ass_base["top_sign_y_min"] is None or sample["top_sign_y_min"] is None:
            raise AssertionError(f"ASS top sign not detected in {label}: base={ass_base} sample={sample}")
        if (
            abs(int(sample["top_sign_y_min"]) - int(ass_base["top_sign_y_min"])) > 1
            or abs(int(sample["top_sign_y_max"]) - int(ass_base["top_sign_y_max"])) > 1
        ):
            raise AssertionError(f"ASS \\an8 top sign shifted in {label}! base={ass_base} sample={sample}")

    # 2. ASS bottom 2-line dialogue MUST lift strictly above bottom HUD controls top edge!
    if ass_base["bottom_sub_y_max"] is None or ass_narrow["bottom_sub_y_max"] is None or ass_full["bottom_sub_y_max"] is None:
        raise AssertionError(f"ASS bottom dialogue not detected: {ass_base}, {ass_narrow}, {ass_full}")
    if int(ass_narrow["bottom_sub_y_max"]) >= int(ass_base["bottom_sub_y_max"]) - 40:
        raise AssertionError(f"ASS bottom subtitle did not lift enough in narrow: base={ass_base} narrow={ass_narrow}")
    if int(ass_full["bottom_sub_y_max"]) >= int(ass_base["bottom_sub_y_max"]) - 25:
        raise AssertionError(f"ASS bottom subtitle did not lift enough in fullscreen: base={ass_base} full={ass_full}")

    # 3. Blu-ray PGS 2-line image subtitle MUST lift strictly above bottom HUD controls top edge!
    if pgs_base["pgs_y_max"] is None or pgs_narrow["pgs_y_max"] is None or pgs_full["pgs_y_max"] is None:
        raise AssertionError(f"PGS bitmap subtitle not detected: {pgs_base}, {pgs_narrow}, {pgs_full}")
    if int(pgs_narrow["pgs_y_max"]) >= int(pgs_base["pgs_y_max"]) - 40:
        raise AssertionError(f"PGS bitmap subtitle did not lift enough in narrow: base={pgs_base} narrow={pgs_narrow}")
    if int(pgs_full["pgs_y_max"]) >= int(pgs_base["pgs_y_max"]) - 25:
        raise AssertionError(f"PGS bitmap subtitle did not lift enough in fullscreen: base={pgs_base} full={pgs_full}")

    # Map video Y into 900x600 narrow & 1440x900 fullscreen screen coordinates to assert clearance above controls!
    # 900x600: letterboxTop=46.875, scale=506.25/720, bottomControlsTop~=510.8
    # 1440x900: letterboxTop=45.0, scale=810.0/720, bottomControlsTop~=808.5
    ass_narrow_screen_bottom = 46.875 + int(ass_narrow["bottom_sub_y_max"]) * (506.25 / 720.0)
    ass_full_screen_bottom = 45.0 + int(ass_full["bottom_sub_y_max"]) * (810.0 / 720.0)
    pgs_narrow_screen_bottom = 46.875 + int(pgs_narrow["pgs_y_max"]) * (506.25 / 720.0)
    pgs_full_screen_bottom = 45.0 + int(pgs_full["pgs_y_max"]) * (810.0 / 720.0)
    metrics["screenClearance"] = {
        "narrow_controls_top_y": 510.8,
        "fullscreen_controls_top_y": 808.5,
        "ass_narrow_screen_bottom_y": round(ass_narrow_screen_bottom, 2),
        "ass_fullscreen_screen_bottom_y": round(ass_full_screen_bottom, 2),
        "pgs_narrow_screen_bottom_y": round(pgs_narrow_screen_bottom, 2),
        "pgs_fullscreen_screen_bottom_y": round(pgs_full_screen_bottom, 2),
    }
    if ass_narrow_screen_bottom >= 510.0 or ass_full_screen_bottom >= 808.0:
        raise AssertionError(f"ASS bottom subtitle overlaps controls: {metrics['screenClearance']}")
    if pgs_narrow_screen_bottom >= 510.0 or pgs_full_screen_bottom >= 808.0:
        raise AssertionError(f"PGS bitmap subtitle overlaps controls: {metrics['screenClearance']}")

    if artifacts_dir is not None:
        artifacts_dir.mkdir(parents=True, exist_ok=True)
        (artifacts_dir / "mpv_subtitle_pixel_metrics.json").write_text(
            json.dumps(metrics, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
    print(
        f"UNMODIFIED_MPV_SUBTITLE_LIFT=PASS "
        f"ass_top_y={ass_base['top_sign_y_min']}..{ass_base['top_sign_y_max']} "
        f"ass_bot_narrow_screen_y={ass_narrow_screen_bottom:.1f}<510.8 "
        f"ass_bot_full_screen_y={ass_full_screen_bottom:.1f}<808.5 "
        f"pgs_narrow_screen_y={pgs_narrow_screen_bottom:.1f}<510.8 "
        f"pgs_full_screen_y={pgs_full_screen_bottom:.1f}<808.5",
        flush=True,
    )


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
    parser.add_argument("--app", type=Path, required=False)
    parser.add_argument("--flutter-dir", type=Path, required=False)
    parser.add_argument("--artifacts-dir", type=Path, default=None)
    parser.add_argument("--self-test-samples", action="store_true")
    args = parser.parse_args()

    if args.self_test_samples:
        with tempfile.TemporaryDirectory(prefix="marco-sub-selftest-") as tmp:
            work = Path(tmp)
            sub_mkv, clip_a_mkv = generate_subtitle_and_tag_samples(work)
            probe_streams = run_cmd([
                "ffprobe", "-v", "error", "-show_entries", "stream=index,codec_type,codec_name",
                "-of", "json", str(sub_mkv),
            ], capture_output=True)
            codecs = [s.get("codec_name") for s in json.loads(probe_streams.stdout).get("streams", [])]
            # Decode one PGS overlay frame via ffmpeg filter_complex to verify BD PGS is 100% valid!
            pgs_check_png = work / "pgs_decode_check.png"
            run_cmd([
                "ffmpeg", "-y", "-v", "error",
                "-i", str(sub_mkv),
                "-filter_complex", "[0:v][0:s:2]overlay",
                "-ss", "2.0", "-frames:v", "1",
                str(pgs_check_png),
            ])
            w, h, rgb = decode_png_rgb(pgs_check_png)
            # Also roundtrip-test our pure-Python PPM -> PNG encoder locally
            rt_ppm = work / "rt.ppm"
            rt_png = work / "rt.png"
            rt_ppm.write_bytes(f"P6\n{w} {h}\n255\n".encode("ascii") + rgb)
            ppm_to_png(rt_ppm, rt_png)
            w2, h2, rgb2 = decode_png_rgb(rt_png)
            if (w2, h2) != (w, h) or rgb2 != rgb:
                raise AssertionError(f"ppm_to_png roundtrip mismatch: {(w2, h2)} vs {(w, h)}")
            y_min, y_max, cnt = find_pixel_y_bounds(
                rgb, w, h, 360, h,
                lambda r, g, b: (g > 150 and r < 140) or (r > 190 and g > 190 and b > 190),
            )
            if y_min is None or cnt < 1000:
                raise AssertionError(f"Decoded PGS check frame missing pixels: y={y_min}..{y_max}, cnt={cnt}")
            probe_tags = run_cmd([
                "ffprobe", "-v", "error", "-show_entries", "format_tags",
                "-of", "json", str(clip_a_mkv),
            ], capture_output=True)
            if "S02E10" not in probe_tags.stdout:
                raise AssertionError(f"clip-A.mkv missing S02E10 tag: {probe_tags.stdout}")
            print(
                f"SELF_TEST_SAMPLES=PASS codecs={codecs} pgs_y={y_min}..{y_max} pgs_px={cnt}",
                flush=True,
            )
        return 0

    if args.app is None or args.flutter_dir is None:
        parser.error("--app and --flutter-dir are required unless --self-test-samples is specified")

    app_path = args.app.resolve()
    flutter_dir = args.flutter_dir.resolve()
    artifacts_dir = args.artifacts_dir.resolve() if args.artifacts_dir is not None else None
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
        verify_unmodified_mpv(app_path, work, artifacts_dir=artifacts_dir)
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
