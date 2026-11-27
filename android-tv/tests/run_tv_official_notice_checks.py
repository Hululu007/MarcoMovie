#!/usr/bin/env python3
"""Runs pure-JVM TvOfficialNoticeChecks against real Android TV sources."""
import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TESTS = Path(__file__).resolve().parent
sys.path.insert(0, str(TESTS))
from android_compile_support import SUFFIX, compile_real_android_sources, resolve_jdk_bin


def main():
    with tempfile.TemporaryDirectory(prefix="tv-official-notice-") as td:
        work = Path(td)
        cp = compile_real_android_sources(
            work / "classes",
            work,
            [TESTS / "TvOfficialNoticeChecks.java"],
        )
        java = [
            str(resolve_jdk_bin() / ("java" + SUFFIX)),
            "-Dfile.encoding=UTF-8",
            "-cp",
            os.pathsep.join(map(str, cp)),
            "com.pilipala.marcomovie.TvOfficialNoticeChecks",
        ]
        subprocess.run(java, cwd=ROOT, check=True)


if __name__ == "__main__":
    main()
