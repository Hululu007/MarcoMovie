"""Deterministic JVM checks for Batch 2 (D1-D4 data safety & isolation)."""

from pathlib import Path
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from android_compile_support import SUFFIX, compile_real_android_sources, resolve_jdk_bin

ROOT = Path(__file__).resolve().parents[2]
MOBILE_SRC = ROOT / "android-mobile/src/main/java/com/pilipala/marcomovie"
JDK = resolve_jdk_bin()

with tempfile.TemporaryDirectory(prefix="batch2-data-safety-") as tmp:
    work_dir = Path(tmp)
    classes_dir = work_dir / "classes"
    data_dir = work_dir / "data"
    data_dir.mkdir(parents=True, exist_ok=True)
    runtime_cp = compile_real_android_sources(
        classes_dir=classes_dir,
        work_dir=work_dir,
        test_sources=[ROOT / "android-mobile/tests/Batch2DataSafetyChecks.java"],
    )
    subprocess.run(
        [
            str(JDK / ("java" + SUFFIX)),
            "-Dfile.encoding=UTF-8",
            "-cp",
            os.pathsep.join(str(p) for p in runtime_cp),
            "com.pilipala.marcomovie.Batch2DataSafetyChecks",
            str(data_dir),
            str(MOBILE_SRC),
        ],
        cwd=ROOT,
        check=True,
    )
