#!/usr/bin/env python3
"""Boot official Apple TV Simulator on macOS, run redesigned MarcoMovieTV.app, and capture screenshots."""
from __future__ import annotations

import argparse
import http.server
import json
import os
import plistlib
import subprocess
import threading
import time
from pathlib import Path
from urllib.parse import parse_qs, urlparse

ROOT = Path(__file__).resolve().parents[1]
POSTER_DIR = ROOT / "tvos" / "sim_demo_posters"
DEFAULT_BUNDLE_ID = "com.pilipala.marcoMovie.tv"


def make_handler(port: int):
    base = f"http://127.0.0.1:{port}"
    titles = [
        ("201", "远山回响", "p1.png", "2026", "自然纪实", "4K HDR · 共8集"),
        ("202", "海风沉默", "p2.png", "2026", "都市悬疑", "更新至24集"),
        ("203", "山海之间", "p3.png", "2025", "地理人文", "全8集"),
        ("204", "夜航都市", "p4.png", "2026", "科幻剧情", "4K 原画"),
        ("205", "星海回响", "p5.png", "2025", "太空探索", "杜比全景声"),
        ("206", "雪境来信", "p6.png", "2026", "治愈剧情", "高码率直连"),
        ("207", "雾港灯塔", "p2.png", "2025", "悬疑剧集", "全12集"),
        ("208", "群峰破晓", "p1.png", "2026", "户外纪录", "4K 原画"),
        ("209", "星际远航", "p5.png", "2025", "天文纪实", "HDR10+"),
        ("210", "寒山松雪", "p6.png", "2026", "自然电影", "60FPS"),
        ("211", "潮汐彼岸", "p3.png", "2025", "海洋生态", "4K REMUX"),
        ("212", "午夜电车", "p4.png", "2026", "都市故事", "超清原盘"),
    ]

    films = []
    for vid, name, pic, year, area, rem in titles:
        films.append(
            {
                "vod_id": vid,
                "vod_name": name,
                "vod_pic": f"{base}/poster/{pic}",
                "vod_year": year,
                "vod_area": area,
                "vod_remarks": rem,
                "vod_content": "穿过山谷与破晓晨雾，在静谧湖泊与群峰之间记录大地的呼吸。",
                "vod_play_from": "我的夸父4K$$$优汐4K云盘$$$CMS超清源",
                "vod_play_url": (
                    "#".join(f"第{i:02d}集$https://pan.quark.cn/s/demo{i:03d}" for i in range(1, 25))
                    + "$$$"
                    + "#".join(f"第{i:02d}集$https://drive.uc.cn/s/demo{i:03d}" for i in range(1, 13))
                    + "$$$"
                    + "#".join(f"第{i:02d}集${base}/v{i}.m3u8" for i in range(1, 9))
                ),
            }
        )

    class DemoHandler(http.server.BaseHTTPRequestHandler):
        def log_message(self, fmt: str, *args) -> None:
            pass

        def do_GET(self) -> None:
            parsed = urlparse(self.path)
            if parsed.path.startswith("/poster/"):
                fname = parsed.path.split("/poster/", 1)[1]
                fpath = POSTER_DIR / fname
                if fpath.is_file():
                    data = fpath.read_bytes()
                    self.send_response(200)
                    self.send_header("Content-Type", "image/png")
                    self.send_header("Content-Length", str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)
                    return
                self.send_error(404)
                return

            if parsed.path == "/config.json":
                cfg = {
                    "sites": [
                        {
                            "key": "demo_main",
                            "name": "家庭影院主源",
                            "type": 1,
                            "api": f"{base}/api/vod/main",
                            "searchable": 1,
                        },
                        {
                            "key": "demo_4k",
                            "name": "4K 云盘臻享源",
                            "type": 1,
                            "api": f"{base}/api/vod/4k",
                            "searchable": 1,
                        },
                    ],
                    "lives": [
                        {
                            "name": "家庭高清直播",
                            "type": 0,
                            "url": f"{base}/live.m3u",
                        }
                    ],
                }
                body = json.dumps(cfg, ensure_ascii=False).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "application/json; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return

            if parsed.path == "/live.m3u":
                m3u = (
                    "#EXTM3U\n"
                    '#EXTINF:-1 group-title="纪录频道",自然纪实 4K\n'
                    f"{base}/ch1.m3u8\n"
                    '#EXTINF:-1 group-title="纪录频道",山海地理 HD\n'
                    f"{base}/ch2.m3u8\n"
                    '#EXTINF:-1 group-title="纪录频道",极地探索 4K\n'
                    f"{base}/ch5.m3u8\n"
                    '#EXTINF:-1 group-title="影视频道",经典影院 4K\n'
                    f"{base}/ch3.m3u8\n"
                    '#EXTINF:-1 group-title="人文频道",海岸人文 HD\n'
                    f"{base}/ch4.m3u8\n"
                ).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "text/plain; charset=utf-8")
                self.send_header("Content-Length", str(len(m3u)))
                self.end_headers()
                self.wfile.write(m3u)
                return

            qs = parse_qs(parsed.query)
            ids_param = qs.get("ids", [""])[0]
            wd_param = qs.get("wd", [""])[0]
            result_list = films
            if ids_param:
                wanted = set(ids_param.split(","))
                matched = [f for f in films if f["vod_id"] in wanted]
                if matched:
                    result_list = matched
            elif wd_param:
                if parsed.path.endswith("/4k"):
                    result_list = films[5:10]
                else:
                    result_list = films[:5]
            payload = {
                "code": 1,
                "page": 1,
                "pagecount": 1,
                "class": [
                    {"type_id": 1, "type_name": "电影"},
                    {"type_id": 2, "type_name": "剧集"},
                    {"type_id": 3, "type_name": "纪录片"},
                    {"type_id": 4, "type_name": "动漫"},
                ],
                "list": result_list,
            }
            body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    return DemoHandler


def run(cmd: list[str], check: bool = True) -> subprocess.CompletedProcess:
    print("+", " ".join(cmd), flush=True)
    return subprocess.run(cmd, check=check, text=True, capture_output=True)


def find_or_create_appletv_sim() -> str:
    runtimes_json = json.loads(run(["xcrun", "simctl", "list", "runtimes", "-j"]).stdout)
    tv_runtimes = [
        r for r in runtimes_json.get("runtimes", [])
        if r.get("isAvailable") and ("tvOS" in r.get("name", "") or "tvOS" in r.get("identifier", ""))
    ]
    if not tv_runtimes:
        subprocess.run(["xcodebuild", "-downloadPlatform", "tvOS"], check=True)
        runtimes_json = json.loads(run(["xcrun", "simctl", "list", "runtimes", "-j"]).stdout)
        tv_runtimes = [
            r for r in runtimes_json.get("runtimes", [])
            if r.get("isAvailable") and ("tvOS" in r.get("name", "") or "tvOS" in r.get("identifier", ""))
        ]
    runtime_id = sorted(tv_runtimes, key=lambda r: r.get("version", ""))[-1]["identifier"]
    devtypes_json = json.loads(run(["xcrun", "simctl", "list", "devicetypes", "-j"]).stdout)
    tv_types = [
        d for d in devtypes_json.get("devicetypes", [])
        if "Apple-TV" in d.get("identifier", "") or "Apple TV" in d.get("name", "")
    ]
    preferred = [d for d in tv_types if "4K" in d.get("name", "")] or tv_types
    devtype_id = preferred[-1]["identifier"]
    udid = run(["xcrun", "simctl", "create", "MarcoAppleTV4K", devtype_id, runtime_id]).stdout.strip()
    return udid


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--out-dir", required=True)
    args = parser.parse_args()

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    info_plist = Path(args.app) / "Info.plist"
    bundle_id = plistlib.loads(info_plist.read_bytes()).get("CFBundleIdentifier", DEFAULT_BUNDLE_ID)

    httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), lambda *a, **kw: None)
    port = httpd.server_address[1]
    httpd.RequestHandlerClass = make_handler(port)
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    demo_url = f"http://127.0.0.1:{port}/config.json"

    udid = find_or_create_appletv_sim()
    run(["xcrun", "simctl", "boot", udid])
    run(["xcrun", "simctl", "bootstatus", udid, "-b"])
    time.sleep(6.0)
    run(["xcrun", "simctl", "install", udid, args.app])
    time.sleep(2.0)

    scenes = [
        ("01-appletv-discover.png", "discover", "aurora", "standard", 6.5),
        ("02-appletv-discover-twilight.png", "discover_twilight", "twilight", "standard", 6.0),
        ("03-appletv-detail.png", "detail", "aurora", "standard", 6.5),
        ("04-appletv-episodes.png", "episodes", "aurora", "standard", 7.5),
        ("05-appletv-netdisk-qr.png", "netdisk", "aurora", "standard", 6.0),
        ("06-appletv-live.png", "live", "ocean", "standard", 6.0),
        ("07-appletv-search.png", "search", "aurora", "standard", 7.0),
        ("08-appletv-library.png", "library", "aurora", "standard", 6.0),
        ("09-appletv-settings-appearance.png", "settings", "twilight", "standard", 6.0),
    ]

    for filename, scene, theme, intensity, wait_sec in scenes:
        run(["xcrun", "simctl", "terminate", udid, bundle_id], check=False)
        time.sleep(1.2)
        env = os.environ.copy()
        env["SIMCTL_CHILD_MARCO_SIM_DEMO_URL"] = demo_url
        env["SIMCTL_CHILD_MARCO_SIM_SCENE"] = scene
        env["SIMCTL_CHILD_MARCO_SIM_THEME"] = theme
        env["SIMCTL_CHILD_MARCO_SIM_INTENSITY"] = intensity
        for attempt in range(4):
            res = subprocess.run(
                ["xcrun", "simctl", "launch", udid, bundle_id],
                env=env,
                text=True,
                capture_output=True,
            )
            if res.returncode == 0:
                break
            time.sleep(3.0)
        else:
            raise RuntimeError(f"Failed to launch {bundle_id} for scene={scene}")
        time.sleep(wait_sec)
        target = out_dir / filename
        run(["xcrun", "simctl", "io", udid, "screenshot", str(target)])
        print(f"Captured {target} ({target.stat().st_size} bytes)", flush=True)

    run(["xcrun", "simctl", "shutdown", udid], check=False)
    httpd.shutdown()


if __name__ == "__main__":
    main()
