"""Deterministic JVM + real ffmpeg/ffprobe checks for Batch 3 (P1-P5)."""

from pathlib import Path
import json
import os
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from android_compile_support import SUFFIX, compile_real_android_sources, resolve_jdk_bin

ROOT = Path(__file__).resolve().parents[2]
MOBILE_SRC = ROOT / "android-mobile/src/main/java/com/pilipala/marcomovie"
JDK = resolve_jdk_bin()


def generate_ts_fixtures(media_dir: Path) -> bool:
    """Generate real MPEG-TS video-only, audio-only (440/880Hz tones), and muxed segments via ffmpeg."""
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        # Fallback synthetic MPEG-TS packets if ffmpeg is absent on another host
        for name in ("v0.ts", "v1.ts", "a0.ts", "a1.ts", "mux0.ts", "mux1.ts"):
            (media_dir / name).write_bytes(bytes([0x47, 0x40, 0x00, 0x10]) + b"\x00" * 184)
        return False

    cmds = [
        # Video-only segments (2s each)
        [ffmpeg, "-y", "-v", "error", "-f", "lavfi", "-i", "testsrc=duration=2:size=64x64:rate=15",
         "-c:v", "libx264", "-pix_fmt", "yuv420p", "-f", "mpegts", str(media_dir / "v0.ts")],
        [ffmpeg, "-y", "-v", "error", "-f", "lavfi", "-i", "testsrc2=duration=2:size=64x64:rate=15",
         "-c:v", "libx264", "-pix_fmt", "yuv420p", "-f", "mpegts", str(media_dir / "v1.ts")],
        # Audio-only segments (recognizable 440Hz & 880Hz sine tones, AAC in MPEG-TS)
        [ffmpeg, "-y", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=2",
         "-c:a", "aac", "-b:a", "64k", "-f", "mpegts", str(media_dir / "a0.ts")],
        [ffmpeg, "-y", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=880:duration=2",
         "-c:a", "aac", "-b:a", "64k", "-f", "mpegts", str(media_dir / "a1.ts")],
        # Embedded muxed audio+video segments
        [ffmpeg, "-y", "-v", "error", "-f", "lavfi", "-i", "testsrc=duration=2:size=64x64:rate=15",
         "-f", "lavfi", "-i", "sine=frequency=523:duration=2",
         "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "64k",
         "-shortest", "-f", "mpegts", str(media_dir / "mux0.ts")],
        [ffmpeg, "-y", "-v", "error", "-f", "lavfi", "-i", "testsrc2=duration=2:size=64x64:rate=15",
         "-f", "lavfi", "-i", "sine=frequency=659:duration=2",
         "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "64k",
         "-shortest", "-f", "mpegts", str(media_dir / "mux1.ts")],
    ]
    for cmd in cmds:
        subprocess.run(cmd, check=True)
    return True


def verify_offline_media_with_ffprobe(emb_path: Path, sep_master: Path) -> None:
    ffprobe = shutil.which("ffprobe")
    ffmpeg = shutil.which("ffmpeg")
    if not ffprobe or not ffmpeg:
        print("SKIP ffprobe offline decode check (ffprobe/ffmpeg not installed)")
        return

    for label, target in (("embedded-ts", emb_path), ("separated-hls-bundle", sep_master)):
        hls_opts = ["-allowed_extensions", "ALL"] if target.suffix.lower() == ".m3u8" else []
        probe = subprocess.run(
            [
                ffprobe,
                "-v",
                "error",
                *hls_opts,
                "-show_streams",
                "-of",
                "json",
                str(target),
            ],
            capture_output=True,
            text=True,
            check=True,
        )
        streams = json.loads(probe.stdout).get("streams", [])
        types = {s.get("codec_type") for s in streams}
        if "video" not in types or "audio" not in types:
            raise AssertionError(f"P2 ffprobe {label}: expected video+audio streams, got {types}")
        print(f"PASS P2 ffprobe ({label}): offline media has both video & audio streams ({sorted(types)})")

        # Verify offline seek (t=1.5s) decodes audio PCM frames cleanly with zero network!
        pcm = subprocess.run(
            [
                ffmpeg,
                "-v",
                "error",
                *hls_opts,
                "-ss",
                "1.5",
                "-i",
                str(target),
                "-t",
                "1.0",
                "-map",
                "0:a:0",
                "-f",
                "s16le",
                "-",
            ],
            capture_output=True,
            check=True,
        )
        if len(pcm.stdout) < 4096:
            raise AssertionError(f"P2 ffmpeg seek ({label}): decoded audio too small ({len(pcm.stdout)} B)")
        # Confirm audio is NOT digital silence (non-zero PCM samples -> audible tone preserved!)
        if not any(b != 0 for b in pcm.stdout):
            raise AssertionError(f"P2 ffmpeg seek ({label}): decoded audio is pure silence!")
        print(f"PASS P2 ffmpeg seek ({label}): offline seek t=1.5s decoded {len(pcm.stdout)} B non-silent PCM audio")


with tempfile.TemporaryDirectory(prefix="batch3-mobile-checks-") as tmp:
    work_dir = Path(tmp)
    media_dir = work_dir / "media"
    media_dir.mkdir(parents=True, exist_ok=True)
    classes_dir = work_dir / "classes"
    data_dir = work_dir / "data"
    data_dir.mkdir(parents=True, exist_ok=True)

    has_real_media = generate_ts_fixtures(media_dir)
    extra_stubs = {
        "android/os/Build.java": """package android.os;
public class Build {
    public static class VERSION {
        public static final int SDK_INT = 35;
    }
}
""",
        "android/os/Environment.java": """package android.os;
public final class Environment {
    public static final String DIRECTORY_MOVIES = "Movies";
}
""",
        "android/os/SystemClock.java": """package android.os;
public final class SystemClock {
    public static long elapsedRealtime() {
        return System.nanoTime() / 1_000_000L;
    }
}
""",
        "android/os/Bundle.java": """package android.os;
import java.util.HashMap;
import java.util.Map;
public class Bundle {
    private final Map<String, String> strings = new HashMap<>();
    public void putString(String k, String v) { strings.put(k, v); }
    public String getString(String k) { return strings.get(k); }
}
""",
        "android/content/pm/ApplicationInfo.java": """package android.content.pm;
import android.os.Bundle;
public class ApplicationInfo {
    public Bundle metaData = new Bundle();
    public int minSdkVersion = 23;
}
""",
        "android/content/pm/PackageInfo.java": """package android.content.pm;
public class PackageInfo {
    public String packageName = "com.pilipala.marcomovie";
    public int versionCode = 100;
    public String versionName = "0.7.0";
    public ApplicationInfo applicationInfo = new ApplicationInfo();
}
""",
        "android/content/pm/PackageManager.java": """package android.content.pm;
public class PackageManager {
    public static final int GET_META_DATA = 128;
    public static class NameNotFoundException extends Exception {}
    public PackageInfo getPackageInfo(String pkg, int flags) throws NameNotFoundException {
        PackageInfo p = new PackageInfo();
        p.packageName = pkg;
        p.applicationInfo.metaData.putString("com.pilipala.marcomovie.EDITION", "mobile");
        return p;
    }
    public ApplicationInfo getApplicationInfo(String pkg, int flags) throws NameNotFoundException {
        ApplicationInfo a = new ApplicationInfo();
        a.metaData.putString("com.pilipala.marcomovie.EDITION", "mobile");
        return a;
    }
}
""",
        "android/content/Context.java": """package android.content;
import android.content.pm.PackageManager;
import java.io.File;
public abstract class Context {
    public Context getApplicationContext() { return this; }
    public File getFilesDir() { return null; }
    public File getCacheDir() { return null; }
    public File getExternalFilesDir(String type) { return null; }
    public String getPackageName() { return "com.pilipala.marcomovie"; }
    public PackageManager getPackageManager() { return new PackageManager(); }
}
""",
        "android/content/ContextWrapper.java": """package android.content;
public class ContextWrapper extends Context {
    public ContextWrapper(Context base) {}
}
""",
    }
    runtime_cp = compile_real_android_sources(
        classes_dir=classes_dir,
        work_dir=work_dir,
        test_sources=[ROOT / "android-mobile/tests/Batch3MobileChecks.java"],
        extra_runtime_stubs=extra_stubs,
    )
    subprocess.run(
        [
            str(JDK / ("java" + SUFFIX)),
            "-Dfile.encoding=UTF-8",
            "-cp",
            os.pathsep.join(str(p) for p in runtime_cp),
            "com.pilipala.marcomovie.Batch3MobileChecks",
            str(media_dir),
            str(data_dir),
            str(MOBILE_SRC),
        ],
        cwd=ROOT,
        check=True,
    )
    if has_real_media:
        lines = (data_dir / "p2-outputs.txt").read_text(encoding="utf-8").strip().splitlines()
        verify_offline_media_with_ffprobe(Path(lines[0]), Path(lines[1]))
