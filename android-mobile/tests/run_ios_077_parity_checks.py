"""Deterministic JVM + local HTTP server checks for Android Mobile iOS 0.7.7 parity (Items 1-8, 9, 14)."""

from pathlib import Path
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from android_compile_support import SUFFIX, compile_real_android_sources, resolve_jdk_bin

ROOT = Path(__file__).resolve().parents[2]
JDK = resolve_jdk_bin()

EXTRA_STUBS = {
    "android/os/Build.java": """package android.os;
public class Build {
    public static class VERSION {
        public static final int SDK_INT = 35;
    }
}
""",
    "android/os/SystemClock.java": """package android.os;
public final class SystemClock {
    public static long elapsedRealtime() {
        return System.nanoTime() / 1_000_000L;
    }
    public static long uptimeMillis() {
        return System.nanoTime() / 1_000_000L;
    }
}
""",
    "android/util/Base64.java": """package android.util;
public final class Base64 {
    public static final int DEFAULT = 0;
    public static final int NO_WRAP = 2;
    public static byte[] decode(String str, int flags) {
        return java.util.Base64.getMimeDecoder().decode(str);
    }
    public static String encodeToString(byte[] input, int flags) {
        return java.util.Base64.getEncoder().encodeToString(input);
    }
}
""",
    "android/text/TextUtils.java": """package android.text;
public final class TextUtils {
    public static boolean isEmpty(CharSequence str) {
        return str == null || str.length() == 0;
    }
}
""",
    "android/net/Uri.java": """package android.net;
public final class Uri {
    private final String raw;
    private Uri(String raw) { this.raw = raw == null ? "" : raw; }
    public static Uri parse(String s) { return new Uri(s); }
    @Override public String toString() { return raw; }
}
""",
}

with tempfile.TemporaryDirectory(prefix="ios077-parity-checks-") as tmp:
    work_dir = Path(tmp)
    classes_dir = work_dir / "classes"
    data_dir = work_dir / "data"
    data_dir.mkdir(parents=True, exist_ok=True)
    runtime_cp = compile_real_android_sources(
        classes_dir=classes_dir,
        work_dir=work_dir,
        test_sources=[ROOT / "android-mobile/tests/MobileIos077ParityChecks.java"],
        extra_runtime_stubs=EXTRA_STUBS,
    )
    subprocess.run(
        [
            str(JDK / ("java" + SUFFIX)),
            "-Dfile.encoding=UTF-8",
            "-cp",
            os.pathsep.join(str(p) for p in runtime_cp),
            "com.pilipala.marcomovie.MobileIos077ParityChecks",
            str(data_dir),
        ],
        cwd=ROOT,
        check=True,
    )
