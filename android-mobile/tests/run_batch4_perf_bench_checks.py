"""Deterministic Batch 4 benchmarks & stress checks (#45, #65 audit, 10-min checkpointing, 200-poster scroll)."""

from pathlib import Path
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from android_compile_support import SUFFIX, compile_real_android_sources, resolve_jdk_bin

ROOT = Path(__file__).resolve().parents[2]
MOBILE_SRC = ROOT / "android-mobile/src/main/java/com/pilipala/marcomovie"
SHARED_GLASS = ROOT / "shared/java/com/pilipala/glass/GlassworkSurface.java"
JDK = resolve_jdk_bin()

with tempfile.TemporaryDirectory(prefix="batch4-perf-bench-") as tmp:
    work_dir = Path(tmp)
    classes_dir = work_dir / "classes"
    runtime_cp = compile_real_android_sources(
        classes_dir=classes_dir,
        work_dir=work_dir,
        test_sources=[ROOT / "android-mobile/tests/Batch4PerfBenchChecks.java"],
    )
    subprocess.run(
        [
            str(JDK / ("java" + SUFFIX)),
            "-Djava.awt.headless=true",
            "-Dfile.encoding=UTF-8",
            "-cp",
            os.pathsep.join(str(p) for p in runtime_cp),
            "com.pilipala.marcomovie.Batch4PerfBenchChecks",
            str(MOBILE_SRC),
            str(SHARED_GLASS),
        ],
        cwd=ROOT,
        check=True,
    )
