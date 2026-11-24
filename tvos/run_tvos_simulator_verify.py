#!/usr/bin/env python3
# Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
"""Run real Apple TV (tvOS Simulator) build, hosted XCTest suite, cold-start smoke launch & screenshot capture."""

from __future__ import annotations

import argparse
import glob
import json
import os
from pathlib import Path
import platform
import re
import shutil
import struct
import subprocess
import sys
import time

TVOS_DIR = Path(__file__).resolve().parent
REPO_ROOT = TVOS_DIR.parent
BUNDLE_ID = "com.pilipala.marcoMovie.tv"
DIAG_DIR = Path.home() / "Library" / "Logs" / "DiagnosticReports"


def _run(
    cmd: list[str],
    *,
    env: dict[str, str] | None = None,
    check: bool = True,
    capture: bool = True,
) -> subprocess.CompletedProcess[str]:
    print(f"+ {' '.join(cmd)}", flush=True)
    return subprocess.run(
        cmd,
        cwd=REPO_ROOT,
        env=env,
        text=True,
        capture_output=capture,
        check=check,
    )


def _list_available_tvos_runtimes(env: dict[str, str]) -> list[dict]:
    proc = _run(["xcrun", "simctl", "list", "runtimes", "--json"], env=env, check=False)
    if proc.returncode != 0:
        return []
    try:
        payload = json.loads(proc.stdout)
    except Exception:
        return []
    runtimes = []
    for rt in payload.get("runtimes", []):
        ident = str(rt.get("identifier", ""))
        name = str(rt.get("name", ""))
        avail = bool(rt.get("isAvailable", False))
        if avail and ("tvOS" in ident or "tvOS" in name):
            runtimes.append(rt)
    # Sort newest version first
    runtimes.sort(
        key=lambda r: tuple(int(p) for p in re.findall(r"\d+", str(r.get("version", "0")))),
        reverse=True,
    )
    return runtimes


def _select_developer_dir_and_tvos_runtime() -> tuple[str, dict, str]:
    base_env = os.environ.copy()
    current_proc = _run(["xcode-select", "-p"], env=base_env, check=True)
    current_dev = current_proc.stdout.strip()

    candidates: list[str] = [current_dev]
    for app_path in sorted(glob.glob("/Applications/Xcode*.app"), reverse=True):
        dev = str(Path(app_path) / "Contents" / "Developer")
        if dev not in candidates and Path(dev).is_dir():
            candidates.append(dev)

    for dev in candidates:
        env = base_env.copy()
        env["DEVELOPER_DIR"] = dev
        ver = _run(["xcodebuild", "-version"], env=env, check=False).stdout.strip().replace("\n", " | ")
        runtimes = _list_available_tvos_runtimes(env)
        print(f"Probed {dev} ({ver}) -> {len(runtimes)} available tvOS runtime(s)", flush=True)
        if runtimes:
            return dev, runtimes[0], ver

    # No pre-installed tvOS Simulator runtime found: install via xcodebuild -downloadPlatform tvOS
    env = base_env.copy()
    env["DEVELOPER_DIR"] = current_dev
    ver = _run(["xcodebuild", "-version"], env=env, check=False).stdout.strip().replace("\n", " | ")
    print("No pre-installed tvOS Simulator runtime found; downloading official tvOS runtime...", flush=True)
    dl = _run(["xcodebuild", "-downloadPlatform", "tvOS"], env=env, check=False, capture=False)
    if dl.returncode != 0:
        raise RuntimeError(f"xcodebuild -downloadPlatform tvOS failed with exit code {dl.returncode}")

    runtimes = _list_available_tvos_runtimes(env)
    if not runtimes:
        raise RuntimeError("tvOS Simulator runtime still unavailable after xcodebuild -downloadPlatform tvOS")
    return current_dev, runtimes[0], ver


def _select_or_create_appletv_device(env: dict[str, str], runtime: dict) -> tuple[str, str]:
    rt_id = str(runtime["identifier"])
    proc = _run(["xcrun", "simctl", "list", "devices", "available", "--json"], env=env, check=True)
    devices_map = json.loads(proc.stdout).get("devices", {})
    rt_devices = devices_map.get(rt_id, [])

    def score_device(d: dict) -> tuple[int, str]:
        name = str(d.get("name", ""))
        if "Apple TV 4K" in name and "3rd" in name:
            return (0, name)
        if "Apple TV 4K" in name:
            return (1, name)
        if "Apple TV" in name:
            return (2, name)
        return (9, name)

    usable = [d for d in rt_devices if d.get("isAvailable", True) and "Apple TV" in str(d.get("name", ""))]
    if usable:
        usable.sort(key=score_device)
        chosen = usable[0]
        return str(chosen["udid"]), str(chosen["name"])

    dt_proc = _run(["xcrun", "simctl", "list", "devicetypes", "--json"], env=env, check=True)
    devicetypes = json.loads(dt_proc.stdout).get("devicetypes", [])
    tv_types = [dt for dt in devicetypes if "Apple-TV" in str(dt.get("identifier", ""))]
    if not tv_types:
        raise RuntimeError("No Apple TV simulator device types found")
    tv_types.sort(key=lambda dt: (0 if "4K" in str(dt.get("name", "")) else 1, str(dt.get("name", ""))))
    chosen_dt = tv_types[0]
    create_proc = _run(
        ["xcrun", "simctl", "create", "MarcoMovie-AppleTV", str(chosen_dt["identifier"]), rt_id],
        env=env,
        check=True,
    )
    udid = create_proc.stdout.strip()
    return udid, f"MarcoMovie-AppleTV ({chosen_dt['name']})"


def _snapshot_crash_reports() -> set[str]:
    if not DIAG_DIR.is_dir():
        return set()
    return {
        p.name
        for p in DIAG_DIR.iterdir()
        if p.is_file() and "MarcoMovieTV" in p.name
    }


def _png_info(path: Path) -> dict[str, object]:
    data = path.read_bytes()
    w = h = 0
    if len(data) >= 24 and data[:8] == b"\x89PNG\r\n\x1a\n":
        w, h = struct.unpack(">II", data[16:24])
    return {"file": path.name, "bytes": len(data), "width": w, "height": h}


def _parse_xcodebuild_test_summary(log_text: str) -> dict[str, object]:
    passed_cases = re.findall(r"Test Case '-\[([^\]]+)\]' passed \(([\d.]+) seconds\)", log_text)
    failed_cases = re.findall(r"Test Case '-\[([^\]]+)\]' failed \(([\d.]+) seconds\)", log_text)
    sim_cases = [c for c, _ in passed_cases if "TvOSSimulatorVerificationTests" in c]
    core_cases = [c for c, _ in passed_cases if "TvOSSimulatorVerificationTests" not in c]
    return {
        "total_passed": len(passed_cases),
        "total_failed": len(failed_cases),
        "core_tests_passed_on_tvos": len(core_cases),
        "simulator_ui_e2e_tests_passed": len(sim_cases),
        "failed_cases": [c for c, _ in failed_cases],
        "simulator_ui_e2e_case_names": sim_cases,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Verify MarcoMovieTV on real Apple TV Simulator.")
    parser.add_argument("--output-dir", default=str(TVOS_DIR / "sim-evidence"))
    args = parser.parse_args()

    out_dir = Path(args.output_dir).resolve()
    shots_dir = out_dir / "screenshots"
    derived_dir = out_dir / "DerivedDataSim"
    xcresult_path = out_dir / "MarcoMovieTV-Simulator.xcresult"
    test_log_path = out_dir / "xcodebuild-simulator-test.log"

    out_dir.mkdir(parents=True, exist_ok=True)
    shots_dir.mkdir(parents=True, exist_ok=True)
    if xcresult_path.exists():
        shutil.rmtree(xcresult_path)

    dev_dir, runtime, xcode_ver = _select_developer_dir_and_tvos_runtime()
    env = os.environ.copy()
    env["DEVELOPER_DIR"] = dev_dir

    udid, device_name = _select_or_create_appletv_device(env, runtime)
    print(f"Selected Apple TV Simulator: {device_name} ({udid}) on {runtime['name']}", flush=True)

    # Boot simulator and wait for full readiness
    _run(["xcrun", "simctl", "boot", udid], env=env, check=False)
    _run(["xcrun", "simctl", "bootstatus", udid, "-b"], env=env, check=True, capture=False)

    crash_before = _snapshot_crash_reports()

    # Phase 1: Build & run full App-hosted XCTest suite (MarcoTVCoreTests + TvOSSimulatorVerificationTests) on tvOS Simulator
    xcodebuild_cmd = [
        "xcodebuild",
        "test",
        "-project",
        str(TVOS_DIR / "RunnerProject" / "MarcoMovieTV.xcodeproj"),
        "-scheme",
        "MarcoMovieTV",
        "-sdk",
        "appletvsimulator",
        "-configuration",
        "Debug",
        "-destination",
        f"id={udid}",
        "-derivedDataPath",
        str(derived_dir),
        "-resultBundlePath",
        str(xcresult_path),
        "CODE_SIGNING_ALLOWED=YES",
        "CODE_SIGN_IDENTITY=-",
        "CODE_SIGNING_REQUIRED=NO",
        "ONLY_ACTIVE_ARCH=YES",
    ]
    print(f"+ {' '.join(xcodebuild_cmd)}", flush=True)
    log_lines: list[str] = []
    with subprocess.Popen(
        xcodebuild_cmd,
        cwd=REPO_ROOT,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    ) as proc:
        assert proc.stdout is not None
        for line in proc.stdout:
            sys.stdout.write(line)
            log_lines.append(line)
        test_rc = proc.wait()

    full_log = "".join(log_lines)
    test_log_path.write_text(full_log, encoding="utf-8")
    test_summary = _parse_xcodebuild_test_summary(full_log)

    # Pull screenshots rendered inside the hosted XCTest app container
    container_proc = _run(
        ["xcrun", "simctl", "get_app_container", udid, BUNDLE_ID, "data"],
        env=env,
        check=False,
    )
    if container_proc.returncode == 0:
        app_shots = Path(container_proc.stdout.strip()) / "Library" / "Caches" / "sim-screenshots"
        if app_shots.is_dir():
            for png in sorted(app_shots.glob("*.png")):
                shutil.copy2(png, shots_dir / png.name)

    # Phase 2: Clean cold-start install + launch smoke test + simctl framebuffer screenshot
    app_path = derived_dir / "Build" / "Products" / "Debug-appletvsimulator" / "MarcoMovieTV.app"
    cold_start_info: dict[str, object] = {"executed": False}
    if app_path.is_dir():
        _run(["xcrun", "simctl", "terminate", udid, BUNDLE_ID], env=env, check=False)
        _run(["xcrun", "simctl", "uninstall", udid, BUNDLE_ID], env=env, check=False)
        _run(["xcrun", "simctl", "install", udid, str(app_path)], env=env, check=True)
        launch_proc = _run(["xcrun", "simctl", "launch", udid, BUNDLE_ID], env=env, check=True)
        pid_match = re.search(r":\s*(\d+)", launch_proc.stdout)
        pid = int(pid_match.group(1)) if pid_match else 0
        time.sleep(5.0)
        alive = False
        if pid > 0:
            ps_proc = _run(["ps", "-p", str(pid), "-o", "pid=,comm="], env=env, check=False)
            alive = ps_proc.returncode == 0 and bool(ps_proc.stdout.strip())
        cold_shot = shots_dir / "01_cold_start_welcome.png"
        shot_proc = _run(["xcrun", "simctl", "io", udid, "screenshot", str(cold_shot)], env=env, check=False)
        _run(["xcrun", "simctl", "terminate", udid, BUNDLE_ID], env=env, check=False)
        cold_start_info = {
            "executed": True,
            "pid": pid,
            "stayed_alive_5s": alive,
            "simctl_screenshot_ok": shot_proc.returncode == 0 and cold_shot.is_file(),
        }

    crash_after = _snapshot_crash_reports()
    new_crashes = sorted(crash_after - crash_before)

    screenshots_meta = [_png_info(p) for p in sorted(shots_dir.glob("*.png"))]
    report = {
        "host_arch": platform.machine(),
        "macos_version": platform.mac_ver()[0],
        "developer_dir": dev_dir,
        "xcode_version": xcode_ver,
        "simulator_device": device_name,
        "simulator_udid": udid,
        "simulator_runtime": runtime.get("name"),
        "simulator_runtime_id": runtime.get("identifier"),
        "xcodebuild_test_returncode": test_rc,
        "test_summary": test_summary,
        "cold_start_smoke": cold_start_info,
        "new_crash_reports": new_crashes,
        "screenshots": screenshots_meta,
    }
    report_path = out_dir / "simulator-report.json"
    report_path.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print("\n=== tvOS Simulator Verification Report ===", flush=True)
    print(json.dumps(report, indent=2, ensure_ascii=False), flush=True)

    _run(["xcrun", "simctl", "shutdown", udid], env=env, check=False)

    if test_rc != 0:
        print(f"ERROR: xcodebuild test failed with code {test_rc}", file=sys.stderr)
        return test_rc
    if not cold_start_info.get("stayed_alive_5s"):
        print("ERROR: Clean cold-start smoke launch did not stay alive for 5s", file=sys.stderr)
        return 2
    if not cold_start_info.get("simctl_screenshot_ok"):
        print("ERROR: simctl cold-start screenshot failed", file=sys.stderr)
        return 3
    if new_crashes:
        print(f"ERROR: New crash reports detected: {new_crashes}", file=sys.stderr)
        return 4
    if test_summary["total_failed"] != 0 or test_summary["simulator_ui_e2e_tests_passed"] < 6:
        print("ERROR: Expected all simulator UI/E2E tests to pass", file=sys.stderr)
        return 5
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
