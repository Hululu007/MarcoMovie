"""Check failure categories (15) and TV audio decoder fallback/DRM rules without a device or prior APK build."""
from pathlib import Path
import os
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

from android_compile_support import SUFFIX, compile_real_android_sources, resolve_jdk_bin

JDK = resolve_jdk_bin()

with tempfile.TemporaryDirectory(prefix="tv-decoder-checks-") as tmp:
    work = Path(tmp)
    failure_out = work / "failure-classes"
    failure_out.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        [
            str(JDK / ("javac" + SUFFIX)),
            "-encoding",
            "UTF-8",
            "-source",
            "8",
            "-target",
            "8",
            "-Xlint:-options",
            "-d",
            str(failure_out),
            str(ROOT / "android-tv/src/main/java/com/pilipala/marcomovie/PlaybackFailure.java"),
            str(ROOT / "android-tv/tests/PlaybackFailureChecks.java"),
        ],
        check=True,
    )
    subprocess.run(
        [
            str(JDK / ("java" + SUFFIX)),
            "-Dfile.encoding=UTF-8",
            "-cp",
            str(failure_out),
            "com.pilipala.marcomovie.PlaybackFailureChecks",
        ],
        check=True,
    )

    # Always compile against real Android TV sources & dependency manifests so clean checkouts
    # without pre-existing android-tv/build/classes never silently skip audio fallback checks.
    runtime_cp = compile_real_android_sources(
        classes_dir=work / "audio-classes",
        work_dir=work / "audio-work",
        test_sources=[ROOT / "android-tv/tests/DecoderAudioFallbackChecks.java"],
    )
    subprocess.run(
        [
            str(JDK / ("java" + SUFFIX)),
            "-Dfile.encoding=UTF-8",
            "-cp",
            os.pathsep.join(str(p) for p in runtime_cp),
            "com.pilipala.marcomovie.DecoderAudioFallbackChecks",
        ],
        check=True,
    )
