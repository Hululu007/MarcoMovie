"""Compile real Android TV search classes and run TvSearchAcceptanceChecks against search_acceptance_cases.json."""
import argparse
import os
import subprocess
import tempfile
from pathlib import Path

from android_compile_support import SUFFIX, compile_real_android_sources, resolve_jdk_bin

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_CASES = (
    ROOT / "dist/reviews/tv-rc-twelfth-recheck-2026-11-26/search_acceptance_cases.json"
)


def main() -> None:
    parser = argparse.ArgumentParser(description="Run Android TV exact/fuzzy search acceptance checks")
    parser.add_argument("--cases", default=str(DEFAULT_CASES), help="Path to search_acceptance_cases.json")
    parser.add_argument("--out", default="", help="Optional path to write JSON execution summary")
    args = parser.parse_args()

    with tempfile.TemporaryDirectory(prefix="tv-search-acceptance-") as tmp:
        work = Path(tmp)
        cp = compile_real_android_sources(
            classes_dir=work / "classes",
            work_dir=work,
            test_sources=[ROOT / "android-tv/tests/TvSearchAcceptanceChecks.java"],
        )
        cmd = [
            str(resolve_jdk_bin() / ("java" + SUFFIX)),
            "-Dfile.encoding=UTF-8",
            "-cp",
            os.pathsep.join(map(str, cp)),
            "com.pilipala.marcomovie.TvSearchAcceptanceChecks",
            str(ROOT),
            args.cases,
        ]
        if args.out:
            cmd.append(args.out)
        subprocess.run(cmd, check=True, cwd=ROOT)


if __name__ == "__main__":
    main()
