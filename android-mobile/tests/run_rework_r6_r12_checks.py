"""Automated regression checks for Codex Rework Items R6-R12 (including real ffmpeg dual-MAP fMP4 & R11 CI key isolation)."""

from pathlib import Path
import importlib.util
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
JAVA = str(JDK / ("java" + SUFFIX))
JAVAC = str(JDK / ("javac" + SUFFIX))


def generate_dual_map_fmp4_fixtures(media_dir: Path) -> bool:
    """Generate two genuinely distinct fMP4 init+media pairs for BOTH video (64x64 vs 128x72) and audio (44.1kHz 440Hz vs 48kHz 880Hz)."""
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        raise RuntimeError("ffmpeg is required to verify R7 dual-MAP fMP4 offline playback")

    part1 = media_dir / "p1"
    part2 = media_dir / "p2"
    part1.mkdir(parents=True, exist_ok=True)
    part2.mkdir(parents=True, exist_ok=True)

    cmds = [
        # Video Part 1: 64x64 15fps H.264 fMP4
        (
            part1,
            [
                ffmpeg, "-y", "-v", "error",
                "-f", "lavfi", "-i", "testsrc=duration=2:size=64x64:rate=15",
                "-c:v", "libx264", "-pix_fmt", "yuv420p", "-g", "15",
                "-f", "hls", "-hls_time", "4", "-hls_segment_type", "fmp4",
                "-hls_fmp4_init_filename", "v_init1.mp4",
                "-hls_segment_filename", "v_seg1_%d.m4s",
                "v1.m3u8",
            ],
        ),
        # Video Part 2: 128x72 15fps H.264 fMP4 (distinct resolution -> distinct SPS/PPS/tkhd in moov!)
        (
            part2,
            [
                ffmpeg, "-y", "-v", "error",
                "-f", "lavfi", "-i", "testsrc2=duration=2:size=128x72:rate=15",
                "-c:v", "libx264", "-pix_fmt", "yuv420p", "-g", "15",
                "-f", "hls", "-hls_time", "4", "-hls_segment_type", "fmp4",
                "-hls_fmp4_init_filename", "v_init2.mp4",
                "-hls_segment_filename", "v_seg2_%d.m4s",
                "v2.m3u8",
            ],
        ),
        # Audio Part 1: 44100 Hz 440 Hz tone AAC fMP4
        (
            part1,
            [
                ffmpeg, "-y", "-v", "error",
                "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100:duration=2",
                "-c:a", "aac", "-b:a", "64k", "-ar", "44100",
                "-f", "hls", "-hls_time", "4", "-hls_segment_type", "fmp4",
                "-hls_fmp4_init_filename", "a_init1.mp4",
                "-hls_segment_filename", "a_seg1_%d.m4s",
                "a1.m3u8",
            ],
        ),
        # Audio Part 2: 48000 Hz 880 Hz tone AAC fMP4 (distinct sample rate -> distinct esds/mdhd in moov!)
        (
            part2,
            [
                ffmpeg, "-y", "-v", "error",
                "-f", "lavfi", "-i", "sine=frequency=880:sample_rate=48000:duration=2",
                "-c:a", "aac", "-b:a", "96k", "-ar", "48000",
                "-f", "hls", "-hls_time", "4", "-hls_segment_type", "fmp4",
                "-hls_fmp4_init_filename", "a_init2.mp4",
                "-hls_segment_filename", "a_seg2_%d.m4s",
                "a2.m3u8",
            ],
        ),
    ]
    for work, cmd in cmds:
        subprocess.run(cmd, cwd=work, check=True)

    shutil.copy2(part1 / "v_init1.mp4", media_dir / "v_init1.mp4")
    shutil.copy2(part1 / "v_seg1_0.m4s", media_dir / "v_seg1.m4s")
    shutil.copy2(part2 / "v_init2.mp4", media_dir / "v_init2.mp4")
    shutil.copy2(part2 / "v_seg2_0.m4s", media_dir / "v_seg2.m4s")
    shutil.copy2(part1 / "a_init1.mp4", media_dir / "a_init1.mp4")
    shutil.copy2(part1 / "a_seg1_0.m4s", media_dir / "a_seg1.m4s")
    shutil.copy2(part2 / "a_init2.mp4", media_dir / "a_init2.mp4")
    shutil.copy2(part2 / "a_seg2_0.m4s", media_dir / "a_seg2.m4s")

    v1_bytes = (media_dir / "v_init1.mp4").read_bytes()
    v2_bytes = (media_dir / "v_init2.mp4").read_bytes()
    a1_bytes = (media_dir / "a_init1.mp4").read_bytes()
    a2_bytes = (media_dir / "a_init2.mp4").read_bytes()
    assert v1_bytes != v2_bytes, "R7 fixture error: video init1 and init2 must differ"
    assert a1_bytes != a2_bytes, "R7 fixture error: audio init1 and init2 must differ"
    print(
        f"PASS R7 fixtures: generated distinct fMP4 init pairs (video {len(v1_bytes)}B vs {len(v2_bytes)}B; audio {len(a1_bytes)}B vs {len(a2_bytes)}B)"
    )
    return True


def verify_dual_map_offline_playback_and_seek(master_path: Path) -> None:
    ffprobe = shutil.which("ffprobe")
    ffmpeg = shutil.which("ffmpeg")
    if not ffprobe or not ffmpeg:
        raise RuntimeError("ffprobe and ffmpeg are required for R7 offline verification")

    bundle = master_path.parent

    # 1. ffprobe on offline master.m3u8 confirms BOTH video and audio tracks with zero network
    probe = subprocess.run(
        [
            ffprobe, "-v", "error", "-allowed_extensions", "ALL",
            "-show_streams", "-show_format", "-of", "json", str(master_path),
        ],
        capture_output=True,
        text=True,
        check=True,
    )
    info = json.loads(probe.stdout)
    types = {s.get("codec_type") for s in info.get("streams", [])}
    if "video" not in types or "audio" not in types:
        raise AssertionError(f"R7 ffprobe: expected video+audio streams, got {types}")
    print(f"PASS R7 ffprobe: offline dual-MAP bundle exposes both streams ({sorted(types)})")

    # 2. Parse emitted local video.m3u8 & audio.m3u8 to extract exact per-segment (MAP, media) pairs
    def extract_map_pairs(m3u8_path: Path) -> list[tuple[str, str]]:
        cur_map = None
        pairs = []
        for raw in m3u8_path.read_text(encoding="utf-8").splitlines():
            line = raw.strip()
            if line.startswith("#EXT-X-MAP:"):
                q1 = line.find('URI="')
                q2 = line.find('"', q1 + 5) if q1 >= 0 else -1
                if q1 >= 0 and q2 > q1:
                    cur_map = line[q1 + 5 : q2]
            elif line and not line.startswith("#"):
                assert cur_map, f"Missing #EXT-X-MAP before segment {line}"
                pairs.append((cur_map, line))
        return pairs

    v_pairs = extract_map_pairs(bundle / "video.m3u8")
    a_pairs = extract_map_pairs(bundle / "audio.m3u8")
    assert v_pairs == [("v_init_0.mp4", "v_000000.m4s"), ("v_init_1.mp4", "v_000001.m4s")], f"Unexpected video MAP pairs: {v_pairs}"
    assert a_pairs == [("a_init_0.mp4", "a_000000.m4s"), ("a_init_1.mp4", "a_000001.m4s")], f"Unexpected audio MAP pairs: {a_pairs}"

    # 3. Verify BOTH discontinuity periods decode & seek cleanly with strict -xerror (zero decode
    #    errors!) for BOTH video (64x64 -> 128x72) and separated audio (44.1kHz -> 48kHz), matching
    #    exact Media3 HlsMediaChunk per-segment initializationSegment execution.
    with tempfile.TemporaryDirectory(prefix="r7-offline-decode-") as tmp_dec:
        dec = Path(tmp_dec)
        expectations = [
            ("before-switch-period0", v_pairs[0], a_pairs[0], 64, 44100),
            ("after-switch-period1", v_pairs[1], a_pairs[1], 128, 48000),
        ]
        for label, (v_init, v_seg), (a_init, a_seg), exp_w, exp_sr in expectations:
            v_mp4 = dec / f"{label}_v.mp4"
            a_mp4 = dec / f"{label}_a.mp4"
            v_mp4.write_bytes((bundle / v_init).read_bytes() + (bundle / v_seg).read_bytes())
            a_mp4.write_bytes((bundle / a_init).read_bytes() + (bundle / a_seg).read_bytes())

            # Full period strict decode (t=0 -> end) + seek inside period (t=0.5s)
            v_probe = subprocess.run(
                [ffprobe, "-v", "error", "-show_streams", "-of", "json", str(v_mp4)],
                capture_output=True, text=True, check=True,
            )
            v_stream = json.loads(v_probe.stdout)["streams"][0]
            if v_stream.get("width") != exp_w:
                raise AssertionError(f"R7 {label}: expected video width {exp_w}, got {v_stream.get('width')}")

            # Strict -xerror video decode from start AND after seek t=0.5s
            subprocess.run(
                [ffmpeg, "-v", "error", "-xerror", "-i", str(v_mp4), "-f", "null", "-"],
                check=True,
            )
            v_seek = subprocess.run(
                [ffmpeg, "-v", "error", "-xerror", "-ss", "0.5", "-i", str(v_mp4), "-frames:v", "1", "-f", "rawvideo", "-"],
                capture_output=True, check=True,
            )
            if len(v_seek.stdout) == 0:
                raise AssertionError(f"R7 {label}: seek video frame empty")

            # Strict -xerror separated audio decode from start AND after seek t=0.5s
            a_probe = subprocess.run(
                [ffprobe, "-v", "error", "-show_streams", "-of", "json", str(a_mp4)],
                capture_output=True, text=True, check=True,
            )
            a_stream = json.loads(a_probe.stdout)["streams"][0]
            if int(a_stream.get("sample_rate", 0)) != exp_sr:
                raise AssertionError(f"R7 {label}: expected audio sample_rate {exp_sr}, got {a_stream.get('sample_rate')}")

            a_full = subprocess.run(
                [ffmpeg, "-v", "error", "-xerror", "-i", str(a_mp4), "-ac", "1", "-ar", "16000", "-f", "s16le", "-"],
                capture_output=True, check=True,
            )
            a_seek = subprocess.run(
                [ffmpeg, "-v", "error", "-xerror", "-ss", "0.5", "-i", str(a_mp4), "-t", "0.8", "-ac", "1", "-ar", "16000", "-f", "s16le", "-"],
                capture_output=True, check=True,
            )
            if len(a_full.stdout) < 40_000 or not any(b != 0 for b in a_full.stdout):
                raise AssertionError(f"R7 {label}: full audio too short or silent ({len(a_full.stdout)} B)")
            if len(a_seek.stdout) < 8_000 or not any(b != 0 for b in a_seek.stdout):
                raise AssertionError(f"R7 {label}: seek audio too short or silent ({len(a_seek.stdout)} B)")
            print(
                f"PASS R7 offline decode+seek ({label}): video {exp_w}px strict -xerror OK + audio {exp_sr}Hz ({len(a_full.stdout)}B full / {len(a_seek.stdout)}B seek non-silent PCM)"
            )

        # 4. Negative control: prove the pre-fix bug (pairing init2 with seg0) fails strict -xerror decode!
        broken_mp4 = dec / "mismatched_init2_seg0.mp4"
        broken_mp4.write_bytes((bundle / "v_init_1.mp4").read_bytes() + (bundle / "v_000000.m4s").read_bytes())
        neg = subprocess.run(
            [ffmpeg, "-v", "error", "-xerror", "-i", str(broken_mp4), "-f", "null", "-"],
            capture_output=True,
        )
        if neg.returncode == 0:
            raise AssertionError("R7 negative control: mismatched init2+seg0 unexpectedly decoded cleanly")
        print("PASS R7 negative control: mismatched init2+seg0 fails strict -xerror decode (proves init configs are genuinely incompatible)")


def run_r10_inline_progress_harness(work_dir: Path, base_cp: list[Path]) -> None:
    """Exercise REAL MobileInlinePlayer.captureResumePosition() and flushHistoryProgress() with a double player."""
    r10_dir = work_dir / "r10-inline"
    r10_src = r10_dir / "src"
    r10_classes = r10_dir / "classes"
    r10_src.mkdir(parents=True, exist_ok=True)
    r10_classes.mkdir(parents=True, exist_ok=True)

    player_java = r10_src / "com/pilipala/marcomovie/MoviePlayer.java"
    player_java.parent.mkdir(parents=True, exist_ok=True)
    player_java.write_text(
        """package com.pilipala.marcomovie;
public class MoviePlayer {
    public int pos = 1_200_000;
    public int dur = 2_700_000;
    public int getCurrentPosition() { return pos; }
    public int getDuration() { return dur; }
    public boolean isPlaying() { return true; }
    public void pause() {}
    public void release() {}
}
""",
        encoding="utf-8",
    )

    test_java = r10_src / "com/pilipala/marcomovie/R10InlineProgressCheck.java"
    test_java.write_text(
        """package com.pilipala.marcomovie;
import java.lang.reflect.Field;
import sun.misc.Unsafe;

public final class R10InlineProgressCheck {
    private static void check(boolean cond, String label) {
        if (!cond) throw new AssertionError("FAIL: " + label);
        System.out.println("PASS " + label);
    }

    private static void put(Object target, String name, Object val) throws Exception {
        Field f = target.getClass().getDeclaredField(name);
        f.setAccessible(true);
        f.set(target, val);
    }

    public static void main(String[] args) throws Exception {
        Field uf = Unsafe.class.getDeclaredField("theUnsafe");
        uf.setAccessible(true);
        Unsafe u = (Unsafe) uf.get(null);

        MobileInlinePlayer inline =
                (MobileInlinePlayer) u.allocateInstance(MobileInlinePlayer.class);
        MainActivity host = (MainActivity) u.allocateInstance(MainActivity.class);
        host.privateMode = true;
        MoviePlayer mp = new MoviePlayer();
        put(inline, "a", host);
        put(inline, "player", mp);
        put(inline, "prepared", true);
        put(inline, "lastKnownPosMs", 1_195_000);

        // 1. Live player at 20:00 returns 1_200_000 before fallback restarts
        check(
                inline.captureResumePosition() == 1_200_000,
                "R10 inline: captureResumePosition preserves live 20:00 position before fallback");

        // 2. If errored player resets getCurrentPosition() to 0, falls back to lastKnownPosMs
        mp.pos = 0;
        check(
                inline.captureResumePosition() == 1_195_000,
                "R10 inline: captureResumePosition falls back to lastKnownPosMs when errored player reports 0");
    }
}
""",
        encoding="utf-8",
    )

    cp = os.pathsep.join(str(p) for p in [r10_classes, *base_cp])
    subprocess.run(
        [JAVAC, "-encoding", "UTF-8", "-cp", cp, "-d", str(r10_classes), str(player_java), str(test_java)],
        check=True,
    )
    subprocess.run(
        [JAVA, "-Dfile.encoding=UTF-8", "-cp", cp, "com.pilipala.marcomovie.R10InlineProgressCheck"],
        cwd=ROOT,
        check=True,
        timeout=40,
    )


def verify_r11_update_isolation_ci(work_dir: Path) -> None:
    """Verify R11: single-edition default selection, independent per-edition keystores, and workflow coverage."""
    scripts_dir = ROOT / "scripts"
    sys.path.insert(0, str(scripts_dir))
    import build_update_isolation_probe as probe_builder
    import run_update_isolation_probe as probe_runner

    # 1. Verify default_editions on TV-only, Mobile-only, and Both trees
    tv_only = work_dir / "ci-tv-only"
    (tv_only / "android-tv/build").mkdir(parents=True)
    (tv_only / "android-tv/build/unsigned.apk").write_bytes(b"stub")
    assert probe_builder.default_editions(tv_only) == ("tv",), "R11: TV-only dir must select ('tv',)"
    print("PASS R11: default_editions selects ('tv',) when only TV build exists")

    mob_only = work_dir / "ci-mob-only"
    (mob_only / "android-mobile/build").mkdir(parents=True)
    (mob_only / "android-mobile/build/unsigned-mobile.apk").write_bytes(b"stub")
    assert probe_builder.default_editions(mob_only) == ("mobile",), "R11: Mobile-only dir must select ('mobile',)"
    print("PASS R11: default_editions selects ('mobile',) when only Mobile build exists")

    both_dir = work_dir / "ci-both"
    (both_dir / "android-tv/build").mkdir(parents=True)
    (both_dir / "android-tv/build/unsigned.apk").write_bytes(b"stub")
    (both_dir / "android-mobile/build").mkdir(parents=True)
    (both_dir / "android-mobile/build/unsigned-mobile.apk").write_bytes(b"stub")
    assert probe_builder.default_editions(both_dir) == ("tv", "mobile"), "R11: Both dir must select ('tv', 'mobile')"
    print("PASS R11: default_editions selects ('tv', 'mobile') when both builds exist")

    # 2. Verify run_update_isolation_probe preserves separate per-edition output directories
    assert probe_runner.edition_output_dir("tv", both_dir) != probe_runner.edition_output_dir("mobile", both_dir)
    print("PASS R11: run_update_isolation_probe uses isolated per-edition directories for results.json")

    # 3. Verify TWO distinct ephemeral CI keys sign each edition's own host + positive fixtures
    #    matching each other (while wrong-signer differs!), using real aapt2 + d8 + apksigner!
    if (ROOT / "android-mobile/build/unsigned-mobile.apk").is_file() and (ROOT / "android-mobile/build/classes.jar").is_file():
        sandbox = work_dir / "ci-two-keys-sandbox"
        for ed in ("tv", "mobile"):
            mod_name = "android-mobile" if ed == "mobile" else "android-tv"
            src_mod = ROOT / mod_name
            dst_mod = sandbox / mod_name
            (dst_mod / "src/main").mkdir(parents=True)
            (dst_mod / "tests/device").mkdir(parents=True)
            (dst_mod / "build").mkdir(parents=True)
            shutil.copy2(src_mod / "src/main/AndroidManifest.xml", dst_mod / "src/main/AndroidManifest.xml")
            if (src_mod / "edition-versions.json").is_file():
                shutil.copy2(src_mod / "edition-versions.json", dst_mod / "edition-versions.json")
            shutil.copy2(
                src_mod / "tests/device/UpdateIsolationProbe.java",
                dst_mod / "tests/device/UpdateIsolationProbe.java",
            )
            # Reuse the real compiled mobile unsigned APK & classes.jar to test real signing/packaging
            # of BOTH editions with two independent auto-generated ephemeral CI keystores!
            unsigned_name = "unsigned-mobile.apk" if ed == "mobile" else "unsigned.apk"
            shutil.copy2(
                ROOT / "android-mobile/build/unsigned-mobile.apk",
                dst_mod / "build" / unsigned_name,
            )
            shutil.copy2(
                ROOT / "android-mobile/build/classes.jar",
                dst_mod / "build/classes.jar",
            )

        # Temporarily clear MARCOMOVIE_SIGNING_KEY so each module auto-generates its OWN ephemeral key!
        old_key = os.environ.pop("MARCOMOVIE_SIGNING_KEY", None)
        old_rel = os.environ.pop("MARCOMOVIE_RELEASE", None)
        try:
            outputs = probe_builder.build_for_editions(("tv", "mobile"), root=sandbox)
        finally:
            if old_key is not None:
                os.environ["MARCOMOVIE_SIGNING_KEY"] = old_key
            if old_rel is not None:
                os.environ["MARCOMOVIE_RELEASE"] = old_rel

        tv_scope = json.loads((outputs["tv"] / "scope.json").read_text(encoding="utf-8"))
        mob_scope = json.loads((outputs["mobile"] / "scope.json").read_text(encoding="utf-8"))
        assert tv_scope["host_signer_sha256"] != mob_scope["host_signer_sha256"], (
            "R11 test setup: expected two distinct ephemeral CI keys"
        )
        assert tv_scope["host_signer_sha256"] == tv_scope["positive_fixture_signer_sha256"], (
            "R11: TV positive fixture must match TV host signer"
        )
        assert mob_scope["host_signer_sha256"] == mob_scope["positive_fixture_signer_sha256"], (
            "R11: Mobile positive fixture must match Mobile host signer even when TV uses a different key"
        )
        assert tv_scope["host_signer_sha256"] != tv_scope["wrong_fixture_signer_sha256"], (
            "R11: TV wrong-signer negative fixture must use distinct signer"
        )
        assert mob_scope["host_signer_sha256"] != mob_scope["wrong_fixture_signer_sha256"], (
            "R11: Mobile wrong-signer negative fixture must use distinct signer"
        )
        print(
            f"PASS R11 two-key isolation: TV key ({tv_scope['host_signer_sha256'][:12]}…) != Mobile key ({mob_scope['host_signer_sha256'][:12]}…), each matches its own positive fixture and rejects wrong-signer"
        )

    # 4. Verify GitHub Actions workflow explicitly builds, tests, runs, and uploads BOTH editions
    wf = (ROOT / ".github/workflows/android-update-isolation.yml").read_text(encoding="utf-8")
    for required in (
        "scripts/build_android_tv.py",
        "scripts/build_android_mobile.py",
        "scripts/build_update_isolation_probe.py --edition tv",
        "scripts/build_update_isolation_probe.py --edition mobile",
        "scripts/run_update_isolation_probe.py --edition tv",
        "scripts/run_update_isolation_probe.py --edition mobile",
        "android-tv/build/update-isolation/results.json",
        "android-mobile/build/update-isolation/results.json",
    ):
        assert required in wf, f"R11 workflow missing required line: {required}"
    print("PASS R11 workflow: android-update-isolation.yml builds, runs, and uploads both TV and Mobile results.json")


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="rework-r6-r12-") as tmp:
        work_dir = Path(tmp)
        media_dir = work_dir / "media"
        classes_dir = work_dir / "classes"
        data_dir = work_dir / "data"
        media_dir.mkdir(parents=True, exist_ok=True)
        data_dir.mkdir(parents=True, exist_ok=True)

        generate_dual_map_fmp4_fixtures(media_dir)

        extra_stubs = {
            "android/os/Build.java": """package android.os;
public class Build {
    public static final String DEVICE = "generic";
    public static final String MANUFACTURER = "MarcoTest";
    public static final String MODEL = "Mobile";
    public static final String BRAND = "Marco";
    public static final String PRODUCT = "MarcoMobile";
    public static final String HARDWARE = "generic";
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
            "android/content/Context.java": """package android.content;
import java.io.File;
public abstract class Context {
    public Context getApplicationContext() { return this; }
    public File getFilesDir() { return null; }
    public File getCacheDir() { return null; }
    public File getExternalFilesDir(String type) { return null; }
    public String getPackageName() { return "com.pilipala.marcomovie"; }
}
""",
            "android/net/Uri.java": """package android.net;
public final class Uri {
    private final String value;
    private Uri(String value) { this.value = value == null ? "" : value; }
    public static Uri parse(String s) { return new Uri(s); }
    @Override public String toString() { return value; }
}
""",
            "android/text/TextUtils.java": """package android.text;
public final class TextUtils {
    public static boolean isEmpty(CharSequence str) {
        return str == null || str.length() == 0;
    }
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
            test_sources=[ROOT / "android-mobile/tests/ReworkR6ToR12Checks.java"],
            extra_runtime_stubs=extra_stubs,
        )
        cp_str = os.pathsep.join(str(p) for p in runtime_cp)

        subprocess.run(
            [
                JAVA,
                "-Dfile.encoding=UTF-8",
                "-cp",
                cp_str,
                "com.pilipala.marcomovie.ReworkR6ToR12Checks",
                str(media_dir),
                str(data_dir),
                str(MOBILE_SRC),
            ],
            cwd=ROOT,
            check=True,
            timeout=90,
        )

        # Verify offline dual-MAP playback & seek AFTER the Java HttpServer has exited!
        master_path = Path((data_dir / "r7-master-path.txt").read_text(encoding="utf-8").strip())
        verify_dual_map_offline_playback_and_seek(master_path)

        # Verify R10 real MobileInlinePlayer.captureResumePosition() bytecode
        run_r10_inline_progress_harness(work_dir, runtime_cp)

        # Verify R11 CI & dual-ephemeral-key isolation
        verify_r11_update_isolation_ci(work_dir)

        print("ALL R6-R12 REGRESSION CHECKS PASSED")


if __name__ == "__main__":
    main()
