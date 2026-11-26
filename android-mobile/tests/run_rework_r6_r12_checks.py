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


def run_r10_init_fallback_harness(work_dir: Path, base_cp: list[Path]) -> None:
    """Exercise REAL PlaybackController.createPlayerWithPlan when MPV init throws, with AUTO_SWITCH_KERNEL OFF vs ON."""
    r10f_dir = work_dir / "r10-init-fallback"
    r10f_src = r10f_dir / "src"
    r10f_classes = r10f_dir / "classes"
    r10f_src.mkdir(parents=True, exist_ok=True)
    r10f_classes.mkdir(parents=True, exist_ok=True)

    activity_java = r10f_src / "android/app/Activity.java"
    activity_java.parent.mkdir(parents=True, exist_ok=True)
    activity_java.write_text(
        """package android.app;
public class Activity extends android.content.Context {}
""",
        encoding="utf-8",
    )

    main_java = r10f_src / "com/pilipala/marcomovie/MainActivity.java"
    main_java.parent.mkdir(parents=True, exist_ok=True)
    main_java.write_text(
        """package com.pilipala.marcomovie;
import android.content.SharedPreferences;
public class MainActivity extends android.app.Activity {
    public SharedPreferences mobilePrefsForTest;
    boolean isTvDevice() { return false; }
    SharedPreferences mobilePrefs() { return mobilePrefsForTest; }
}
""",
        encoding="utf-8",
    )

    movie_player_java = r10f_src / "com/pilipala/marcomovie/MoviePlayer.java"
    movie_player_java.write_text(
        """package com.pilipala.marcomovie;
import android.content.Context;
public class MoviePlayer {
    public static int backupCreations;
    public MoviePlayer(Context ctx) {
        if (getClass() == MoviePlayer.class) {
            backupCreations++;
        }
    }
    public MoviePlayer(Context ctx, int fallbackMode, boolean preferIjk) {
        if (getClass() == MoviePlayer.class) {
            backupCreations++;
        }
    }
    public static MoviePlayer createIjk(Context ctx) { return new MoviePlayer(ctx); }
}
""",
        encoding="utf-8",
    )

    mpv_player_java = r10f_src / "com/pilipala/marcomovie/MpvPlayer.java"
    mpv_player_java.write_text(
        """package com.pilipala.marcomovie;
import android.content.Context;
public class MpvPlayer extends MoviePlayer {
    public static int mpvAttempts;
    public MpvPlayer(Context ctx) {
        super(ctx);
        mpvAttempts++;
        throw new UnsatisfiedLinkError("mock libmpv init failure");
    }
}
""",
        encoding="utf-8",
    )

    test_java = r10f_src / "com/pilipala/marcomovie/R10InitFallbackCheck.java"
    test_java.write_text(
        """package com.pilipala.marcomovie;

import android.content.SharedPreferences;
import java.lang.reflect.Proxy;
import java.util.concurrent.atomic.AtomicBoolean;
import org.json.JSONObject;

public final class R10InitFallbackCheck {
    private static void check(boolean cond, String label) {
        if (!cond) throw new AssertionError("FAIL: " + label);
        System.out.println("PASS " + label);
    }

    private static SharedPreferences togglePrefs(final AtomicBoolean autoSwitch) {
        return (SharedPreferences)
                Proxy.newProxyInstance(
                        SharedPreferences.class.getClassLoader(),
                        new Class<?>[] {SharedPreferences.class},
                        (proxy, method, args) -> {
                            if ("getBoolean".equals(method.getName())
                                    && Prefs.AUTO_SWITCH_KERNEL.equals(args[0])) {
                                return autoSwitch.get();
                            }
                            if (method.getReturnType() == boolean.class) return Boolean.FALSE;
                            if (method.getReturnType() == int.class) return 0;
                            if (method.getReturnType() == long.class) return 0L;
                            if (method.getReturnType() == float.class) return 0f;
                            return null;
                        });
    }

    public static void main(String[] args) {
        final AtomicBoolean autoSwitch = new AtomicBoolean(false);
        MainActivity a = new MainActivity();
        a.mobilePrefsForTest = togglePrefs(autoSwitch);
        Cms.Episode ep = new Cms.Episode();
        ep.name = "E1";
        ep.url = "https://media.example/1.mp4";
        PlaybackController.EnginePlan mpvPlan =
                PlaybackController.planEngine(
                        PlaybackController.ENGINE_MPV, new JSONObject(), true);
        check(
                mpvPlan.engine == PlaybackController.ENGINE_MPV,
                "R10 Round-2 setup: planEngine selects MPV when user chose MPV");

        // 1. AUTO_SWITCH_KERNEL = false: MPV init throws -> MUST NOT create Media3 backup (0)
        //    and MUST surface MPV failure message!
        autoSwitch.set(false);
        MoviePlayer.backupCreations = 0;
        MpvPlayer.mpvAttempts = 0;
        MoviePlayer[] outOff = new MoviePlayer[1];
        Throwable caughtOff = null;
        try {
            PlaybackController.createPlayerWithPlan(a, ep, mpvPlan, outOff);
        } catch (Throwable err) {
            caughtOff = err;
        }
        String uiMsgOff = caughtOff == null ? "" : SourceController.message(caughtOff);
        check(
                caughtOff != null
                        && MpvPlayer.mpvAttempts == 1
                        && MoviePlayer.backupCreations == 0
                        && outOff[0] == null
                        && uiMsgOff.contains("MPV")
                        && uiMsgOff.contains("已关闭自动切核"),
                "R10 Round-2 (autoSwitch=false): MPV init error shows MPV failure and backup Media3 creations=0");

        // 2. AUTO_SWITCH_KERNEL = true: MPV init throws -> allows fallback to Media3 and exposes actual engine label!
        autoSwitch.set(true);
        MoviePlayer.backupCreations = 0;
        MpvPlayer.mpvAttempts = 0;
        MoviePlayer[] outOn = new MoviePlayer[1];
        PlaybackController.EnginePlan actualOn =
                PlaybackController.createPlayerWithPlan(a, ep, mpvPlan, outOn);
        check(
                MpvPlayer.mpvAttempts == 1
                        && MoviePlayer.backupCreations == 1
                        && outOn[0] != null
                        && outOn[0].getClass() == MoviePlayer.class
                        && actualOn.engine == PlaybackController.ENGINE_MEDIA3
                        && "Media3".equals(actualOn.engineLabel)
                        && actualOn.fallbackReason.contains("Media3"),
                "R10 Round-2 (autoSwitch=true): MPV init error falls back to Media3 (creations=1) and reports actual kernel Media3");
    }
}
""",
        encoding="utf-8",
    )

    cp = os.pathsep.join(str(p) for p in [r10f_classes, *base_cp])
    subprocess.run(
        [
            JAVAC,
            "-encoding",
            "UTF-8",
            "-cp",
            cp,
            "-d",
            str(r10f_classes),
            str(activity_java),
            str(main_java),
            str(movie_player_java),
            str(mpv_player_java),
            str(test_java),
        ],
        check=True,
    )
    subprocess.run(
        [JAVA, "-Dfile.encoding=UTF-8", "-cp", cp, "com.pilipala.marcomovie.R10InitFallbackCheck"],
        cwd=ROOT,
        check=True,
        timeout=40,
    )


def run_r9_same_name_import_harness(work_dir: Path, base_cp: list[Path]) -> None:
    """Exercise REAL SourceController.importLocalUri with concurrent same-named source.py imports + private-space switch."""
    r9_dir = work_dir / "r9-same-name-import"
    r9_src = r9_dir / "src"
    r9_classes = r9_dir / "classes"
    r9_src.mkdir(parents=True, exist_ok=True)
    r9_classes.mkdir(parents=True, exist_ok=True)

    handler_java = r9_src / "android/os/Handler.java"
    handler_java.parent.mkdir(parents=True, exist_ok=True)
    handler_java.write_text(
        """package android.os;
import java.util.ArrayList;
import java.util.List;
public class Handler {
    public final List<Runnable> posted = new ArrayList<>();
    public boolean post(Runnable r) {
        synchronized (posted) { posted.add(r); }
        return true;
    }
    public void drain() {
        List<Runnable> copy;
        synchronized (posted) {
            copy = new ArrayList<>(posted);
            posted.clear();
        }
        for (Runnable r : copy) r.run();
    }
}
""",
        encoding="utf-8",
    )

    resolver_java = r9_src / "android/content/ContentResolver.java"
    resolver_java.parent.mkdir(parents=True, exist_ok=True)
    resolver_java.write_text(
        """package android.content;
import android.database.Cursor;
import android.net.Uri;
import java.io.ByteArrayInputStream;
import java.io.InputStream;
import java.lang.reflect.Proxy;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.Map;

public class ContentResolver {
    public final Map<String, String> names = new HashMap<>();
    public final Map<String, String> bodies = new HashMap<>();

    public Cursor query(Uri uri, String[] projection, String selection, String[] selectionArgs, String sortOrder) {
        final String name = names.getOrDefault(uri.toString(), "source.py");
        return (Cursor) Proxy.newProxyInstance(
                Cursor.class.getClassLoader(),
                new Class<?>[] {Cursor.class},
                (proxy, method, args) -> {
                    String m = method.getName();
                    if ("moveToFirst".equals(m)) return Boolean.TRUE;
                    if ("getString".equals(m)) return name;
                    if ("close".equals(m)) return null;
                    return null;
                });
    }

    public InputStream openInputStream(Uri uri) {
        String body = bodies.getOrDefault(uri.toString(), "");
        return new ByteArrayInputStream(body.getBytes(StandardCharsets.UTF_8));
    }
}
""",
        encoding="utf-8",
    )

    activity_java = r9_src / "android/app/Activity.java"
    activity_java.parent.mkdir(parents=True, exist_ok=True)
    activity_java.write_text(
        """package android.app;
import android.content.ContentResolver;
import java.io.File;
public class Activity extends android.content.Context {
    public boolean isFinishing() { return false; }
    public boolean isDestroyed() { return false; }
    public ContentResolver getContentResolver() { return null; }
    @Override public File getFilesDir() { return null; }
}
""",
        encoding="utf-8",
    )

    main_activity_java = r9_src / "com/pilipala/marcomovie/MainActivity.java"
    main_activity_java.parent.mkdir(parents=True, exist_ok=True)
    main_activity_java.write_text(
        """package com.pilipala.marcomovie;

import android.content.ContentResolver;
import android.content.SharedPreferences;
import java.io.File;
import java.util.ArrayDeque;
import java.util.Deque;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;

public class MainActivity extends android.app.Activity {
    static final class Screen {
        final Runnable render;
        Screen(Runnable render) { this.render = render; }
    }

    public boolean privateMode, switchingPrivacy;
    public final AtomicLong configImportSeq = new AtomicLong();
    public android.os.Handler ui = new android.os.Handler();
    public ExecutorService worker;
    public File publicRoot;
    public ContentResolver resolver;
    public final AtomicInteger filesDirCalls = new AtomicInteger();
    public CountDownLatch pauseFirstInFilesDir;
    public CountDownLatch releaseFirstInFilesDir;
    public Cms.Config config;
    public String configOrigin = "";
    public ConfigStore configStore;
    public SharedPreferences prefs;
    public final ArrayDeque<Screen> back = new ArrayDeque<>();
    public Screen current;

    @Override public boolean isFinishing() { return false; }
    @Override public boolean isDestroyed() { return false; }
    boolean isTvDevice() { return false; }
    void toast(String msg) {}
    void refresh() {}
    void closeEngines() {}
    void home() {}
    void restore(Screen s) {}
    boolean available(Cms.Site site) { return true; }
    String message(Throwable e) { return e == null ? "" : String.valueOf(e.getMessage()); }
    @Override public ContentResolver getContentResolver() { return resolver; }
    @Override public File getFilesDir() {
        int call = filesDirCalls.incrementAndGet();
        if (call == 1 && pauseFirstInFilesDir != null && releaseFirstInFilesDir != null) {
            pauseFirstInFilesDir.countDown();
            try { releaseFirstInFilesDir.await(5, TimeUnit.SECONDS); } catch (InterruptedException ignored) {}
        }
        if (!privateMode) return publicRoot;
        File priv = new File(publicRoot, "private-space");
        priv.mkdirs();
        return priv;
    }
}
""",
        encoding="utf-8",
    )

    test_java = r9_src / "com/pilipala/marcomovie/R9SameNameImportCheck.java"
    test_java.parent.mkdir(parents=True, exist_ok=True)
    test_java.write_text(
        """package com.pilipala.marcomovie;

import android.content.ContentResolver;
import android.content.SharedPreferences;
import android.net.Uri;
import java.io.File;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

public final class R9SameNameImportCheck {
    private static void check(boolean cond, String label) {
        if (!cond) throw new AssertionError("FAIL: " + label);
        System.out.println("PASS " + label);
    }

    static final class MemPrefs implements SharedPreferences {
        final Map<String, Object> data = new HashMap<>();
        @Override public synchronized Map<String, ?> getAll() { return new HashMap<>(data); }
        @Override public synchronized String getString(String k, String d) {
            Object v = data.get(k); return v instanceof String ? (String) v : d;
        }
        @Override @SuppressWarnings("unchecked")
        public synchronized Set<String> getStringSet(String k, Set<String> d) {
            Object v = data.get(k); return v instanceof Set ? new HashSet<>((Set<String>) v) : d;
        }
        @Override public synchronized int getInt(String k, int d) {
            Object v = data.get(k); return v instanceof Integer ? (Integer) v : d;
        }
        @Override public synchronized long getLong(String k, long d) {
            Object v = data.get(k); return v instanceof Long ? (Long) v : d;
        }
        @Override public synchronized float getFloat(String k, float d) {
            Object v = data.get(k); return v instanceof Float ? (Float) v : d;
        }
        @Override public synchronized boolean getBoolean(String k, boolean d) {
            Object v = data.get(k); return v instanceof Boolean ? (Boolean) v : d;
        }
        @Override public synchronized boolean contains(String k) { return data.containsKey(k); }
        @Override public Editor edit() {
            return new Editor() {
                final Map<String, Object> u = new HashMap<>();
                final Set<String> rm = new HashSet<>();
                boolean clr;
                @Override public Editor putString(String k, String v) { u.put(k, v); rm.remove(k); return this; }
                @Override public Editor putStringSet(String k, Set<String> v) { u.put(k, v); rm.remove(k); return this; }
                @Override public Editor putInt(String k, int v) { u.put(k, v); rm.remove(k); return this; }
                @Override public Editor putLong(String k, long v) { u.put(k, v); rm.remove(k); return this; }
                @Override public Editor putFloat(String k, float v) { u.put(k, v); rm.remove(k); return this; }
                @Override public Editor putBoolean(String k, boolean v) { u.put(k, v); rm.remove(k); return this; }
                @Override public Editor remove(String k) { rm.add(k); u.remove(k); return this; }
                @Override public Editor clear() { clr = true; u.clear(); rm.clear(); return this; }
                @Override public boolean commit() { apply(); return true; }
                @Override public void apply() {
                    synchronized (MemPrefs.this) {
                        if (clr) data.clear();
                        for (String r : rm) data.remove(r);
                        for (Map.Entry<String, Object> e : u.entrySet()) {
                            if (e.getValue() == null) data.remove(e.getKey());
                            else data.put(e.getKey(), e.getValue());
                        }
                    }
                }
            };
        }
        @Override public void registerOnSharedPreferenceChangeListener(OnSharedPreferenceChangeListener l) {}
        @Override public void unregisterOnSharedPreferenceChangeListener(OnSharedPreferenceChangeListener l) {}
    }

    private static MainActivity newHost(File root, ExecutorService exec, ContentResolver cr) {
        MainActivity host = new MainActivity();
        host.publicRoot = root;
        host.resolver = cr;
        host.worker = exec;
        host.prefs = new MemPrefs();
        host.configStore = new ConfigStore(new File(root, "cfg"));
        return host;
    }

    private static String readApiFile(String apiUri) throws Exception {
        File f = new File(new URI(apiUri));
        return new String(Files.readAllBytes(f.toPath()), StandardCharsets.UTF_8);
    }

    private static void drainUntil(MainActivity host, java.util.concurrent.Callable<Boolean> cond)
            throws Exception {
        long deadline = System.currentTimeMillis() + 5000;
        while (System.currentTimeMillis() < deadline) {
            host.ui.drain();
            ConfigStore.WRITE_EXECUTOR.submit(() -> {}).get(5, TimeUnit.SECONDS);
            host.ui.drain();
            if (Boolean.TRUE.equals(cond.call())) return;
            Thread.sleep(10);
        }
        throw new AssertionError("Timed out waiting for async import condition");
    }

    public static void main(String[] args) throws Exception {
        // -----------------------------------------------------------------
        // 1. Concurrent same-named source.py from dirA & dirB:
        //    A stalls in getFilesDir, B completes first, A resumes last ->
        //    B's actual referenced file & cold-restarted config remain # current-B!
        // -----------------------------------------------------------------
        File root1 = Files.createTempDirectory("r9-concurrent-").toFile();
        ExecutorService exec1 = Executors.newFixedThreadPool(2);
        try {
            ContentResolver cr = new ContentResolver();
            Uri uriA = Uri.parse("content://docs/dirA/source.py");
            Uri uriB = Uri.parse("content://docs/dirB/source.py");
            cr.names.put(uriA.toString(), "source.py");
            cr.names.put(uriB.toString(), "source.py");
            cr.bodies.put(uriA.toString(), "# old-A\\nclass Spider:\\n    def homeContent(self, f): return {}\\n");
            cr.bodies.put(uriB.toString(), "# current-B\\nclass Spider:\\n    def homeContent(self, f): return {}\\n");

            MainActivity host = newHost(root1, exec1, cr);
            host.pauseFirstInFilesDir = new CountDownLatch(1);
            host.releaseFirstInFilesDir = new CountDownLatch(1);

            SourceController.importLocalUri(host, uriA, false);
            check(host.pauseFirstInFilesDir.await(5, TimeUnit.SECONDS), "R9 harness: A reached getFilesDir before B started");

            SourceController.importLocalUri(host, uriB, false);
            drainUntil(host, () -> host.config != null && !host.config.sites.isEmpty());
            String bApi = host.config.sites.get(0).api;
            check(
                    readApiFile(bApi).startsWith("# current-B"),
                    "R9 harness: B's referenced local source file starts with # current-B");

            // Now unblock stale A and let A finish completely!
            host.releaseFirstInFilesDir.countDown();
            exec1.shutdown();
            check(exec1.awaitTermination(5, TimeUnit.SECONDS), "R9 harness: stale A thread drained");
            host.ui.drain();
            ConfigStore.WRITE_EXECUTOR.submit(() -> {}).get(5, TimeUnit.SECONDS);
            host.ui.drain();

            // Simulate cold restart: reload config from ConfigStore and read the file referenced by site.api!
            ConfigStore.RecoveredState restarted =
                    new ConfigStore(new File(root1, "cfg"))
                            .loadRecoveredState(
                                    host.prefs.getString(Prefs.ORIGIN, null),
                                    host.prefs.getString(Prefs.SELECTED_SITE, null));
            Cms.Config restartedCfg = Cms.parseConfig(restarted.raw, restarted.origin);
            String restartedApi = restartedCfg.sites.get(0).api;
            String restartedContent = readApiFile(restartedApi);
            check(
                    bApi.equals(restartedApi)
                            && restartedContent.startsWith("# current-B")
                            && readApiFile(bApi).startsWith("# current-B"),
                    "R9 Round-2: after stale A completes, B's referenced file AND cold-restarted script remain # current-B");
        } finally {
            exec1.shutdownNow();
        }

        // -----------------------------------------------------------------
        // 2. Private-space switch during same-named source.py import:
        //    Public A stalls in getFilesDir -> switch to privateMode=true & import Private B ->
        //    Unblock Public A -> Public A cannot clobber Private B or leak into private space!
        // -----------------------------------------------------------------
        File root2 = Files.createTempDirectory("r9-privacy-").toFile();
        ExecutorService exec2 = Executors.newFixedThreadPool(2);
        try {
            ContentResolver cr2 = new ContentResolver();
            Uri pubA = Uri.parse("content://docs/public/source.py");
            Uri privB = Uri.parse("content://docs/private/source.py");
            cr2.names.put(pubA.toString(), "source.py");
            cr2.names.put(privB.toString(), "source.py");
            cr2.bodies.put(pubA.toString(), "# public-A\\nclass Spider:\\n    def homeContent(self, f): return {}\\n");
            cr2.bodies.put(privB.toString(), "# private-B\\nclass Spider:\\n    def homeContent(self, f): return {}\\n");

            MainActivity host2 = newHost(root2, exec2, cr2);
            host2.pauseFirstInFilesDir = new CountDownLatch(1);
            host2.releaseFirstInFilesDir = new CountDownLatch(1);

            host2.privateMode = false;
            SourceController.importLocalUri(host2, pubA, false);
            check(host2.pauseFirstInFilesDir.await(5, TimeUnit.SECONDS), "R9 privacy: public A stalled in getFilesDir");

            // Switch to private space with isolated private ConfigStore
            host2.privateMode = true;
            host2.configStore = new ConfigStore(new File(new File(root2, "private-space"), "cfg"));
            SourceController.importLocalUri(host2, privB, false);
            drainUntil(host2, () -> host2.config != null && !host2.config.sites.isEmpty());
            String privApi = host2.config.sites.get(0).api;
            check(
                    privApi.contains("local_spiders_private")
                            && readApiFile(privApi).startsWith("# private-B"),
                    "R9 privacy: private B lives in local_spiders_private with content # private-B");

            // Unblock stale public A!
            host2.releaseFirstInFilesDir.countDown();
            exec2.shutdown();
            check(exec2.awaitTermination(5, TimeUnit.SECONDS), "R9 privacy: stale public A drained");
            host2.ui.drain();
            ConfigStore.WRITE_EXECUTOR.submit(() -> {}).get(5, TimeUnit.SECONDS);
            host2.ui.drain();

            ConfigStore.RecoveredState privRestarted =
                    new ConfigStore(new File(new File(root2, "private-space"), "cfg"))
                            .loadRecoveredState(
                                    host2.prefs.getString(Prefs.ORIGIN, null),
                                    host2.prefs.getString(Prefs.SELECTED_SITE, null));
            Cms.Config privCfg = Cms.parseConfig(privRestarted.raw, privRestarted.origin);
            check(
                    privApi.equals(privCfg.sites.get(0).api)
                            && readApiFile(privApi).startsWith("# private-B"),
                    "R9 Round-2 privacy: stale public A never overwrote private B's file or config");
        } finally {
            exec2.shutdownNow();
        }

        // -----------------------------------------------------------------
        // 3. Round-3 R9: Updating the SAME SAF script URI twice (# revision-one -> # revision-two)
        //    MUST leave only 1 site (latest revision) with the SAME stable document key so
        //    SELECTED_SITE continues working; importing a DIFFERENT SAF URI with the same filename
        //    (dirB/source.py) produces 2 independent sites!
        // -----------------------------------------------------------------
        File root3 = Files.createTempDirectory("r9-same-doc-update-").toFile();
        ExecutorService exec3 = Executors.newSingleThreadExecutor();
        try {
            ContentResolver cr3 = new ContentResolver();
            Uri sameUri = Uri.parse("content://docs/dirA/source.py");
            Uri otherUri = Uri.parse("content://docs/dirB/source.py");
            cr3.names.put(sameUri.toString(), "source.py");
            cr3.names.put(otherUri.toString(), "source.py");

            MainActivity host3 = newHost(root3, exec3, cr3);

            // Revision 1 on dirA/source.py
            cr3.bodies.put(
                    sameUri.toString(),
                    "# revision-one\\nclass Spider:\\n    def homeContent(self, f): return {}\\n");
            SourceController.importLocalUri(host3, sameUri, false);
            exec3.submit(() -> {}).get(5, TimeUnit.SECONDS);
            drainUntil(host3, () -> host3.config != null && host3.config.sites.size() == 1);
            String rev1Key = host3.config.sites.get(0).key;
            String rev1Api = host3.config.sites.get(0).api;
            check(
                    rev1Key.equals(host3.prefs.getString(Prefs.SELECTED_SITE, ""))
                            && readApiFile(rev1Api).startsWith("# revision-one"),
                    "R9 Round-3: revision-one imported with stable key and selected");

            // Revision 2 on SAME URI dirA/source.py (only file body changed!)
            cr3.bodies.put(
                    sameUri.toString(),
                    "# revision-two\\nclass Spider:\\n    def homeContent(self, f): return {}\\n");
            SourceController.importLocalUri(host3, sameUri, false);
            exec3.submit(() -> {}).get(5, TimeUnit.SECONDS);
            drainUntil(
                    host3,
                    () ->
                            host3.config != null
                                    && !host3.config.sites.isEmpty()
                                    && !rev1Api.equals(host3.config.sites.get(0).api));
            check(
                    host3.config.sites.size() == 1
                            && rev1Key.equals(host3.config.sites.get(0).key)
                            && rev1Key.equals(host3.prefs.getString(Prefs.SELECTED_SITE, "")),
                    "R9 Round-3: re-importing same SAF URI keeps site count=1 with unchanged selected key");

            ConfigStore.RecoveredState coldSameDoc =
                    new ConfigStore(new File(root3, "cfg"))
                            .loadRecoveredState(
                                    host3.prefs.getString(Prefs.ORIGIN, null),
                                    host3.prefs.getString(Prefs.SELECTED_SITE, null),
                                    host3.prefs.getString(Prefs.ACTIVE_SUBSCRIPTION_ID, null));
            Cms.Config coldSameCfg = Cms.parseConfig(coldSameDoc.raw, coldSameDoc.origin);
            check(
                    coldSameCfg.sites.size() == 1
                            && rev1Key.equals(coldSameCfg.sites.get(0).key)
                            && rev1Key.equals(coldSameDoc.selectedSite)
                            && readApiFile(coldSameCfg.sites.get(0).api).startsWith("# revision-two"),
                    "R9 Round-3 cold restart: same SAF URI update leaves only revision-two and preserves selected site");

            // Importing a DIFFERENT SAF URI with the same filename dirB/source.py creates a 2nd independent site!
            cr3.bodies.put(
                    otherUri.toString(),
                    "# other-doc-B\\nclass Spider:\\n    def homeContent(self, f): return {}\\n");
            SourceController.importLocalUri(host3, otherUri, false);
            exec3.submit(() -> {}).get(5, TimeUnit.SECONDS);
            drainUntil(host3, () -> host3.config != null && host3.config.sites.size() == 2);
            check(
                    host3.config.sites.size() == 2
                            && readApiFile(host3.config.sites.get(0).api).startsWith("# revision-two")
                            && readApiFile(host3.config.sites.get(1).api).startsWith("# other-doc-B"),
                    "R9 Round-3 distinct URI: dirB/source.py stays isolated from dirA/source.py (2 independent sites)");
        } finally {
            exec3.shutdownNow();
        }

        // -----------------------------------------------------------------
        // 4. Round-5 R9 (headless fallback): Upgrading from 0.6.0 flat local_spiders/source.py
        //    with PREFERRED_SITE when NO interactive choice dialog can be shown MUST preserve
        //    old data (keep both sites, preserve original PREFERRED_SITE on # revision-one)
        //    rather than silently overwriting by filename. Interactive replace vs keep-both
        //    choices are verified separately in run_r9_legacy_choice_dialog_harness.
        //    An ambiguous non-flat legacy hashed script (no SAF URI) also never auto-merges.
        // -----------------------------------------------------------------
        File root4 = Files.createTempDirectory("r9-r5-legacy-headless-").toFile();
        ExecutorService exec4 = Executors.newSingleThreadExecutor();
        try {
            ContentResolver cr4 = new ContentResolver();
            Uri sameUri = Uri.parse("content://docs/dirA/source.py");
            Uri otherUri = Uri.parse("content://docs/dirB/source.py");
            cr4.names.put(sameUri.toString(), "source.py");
            cr4.names.put(otherUri.toString(), "source.py");

            MainActivity host4 = newHost(root4, exec4, cr4);
            // Seed authentic 0.6.0 flat local_spiders/source.py + legacy config.json (no bundle)
            File legacySpidersDir = new File(root4, "local_spiders");
            legacySpidersDir.mkdirs();
            File legacyFlatFile = new File(legacySpidersDir, "source.py");
            String rev1Body = "# revision-one\\nclass Spider:\\n    def homeContent(self, f): return {}\\n";
            Files.write(legacyFlatFile.toPath(), rev1Body.getBytes(StandardCharsets.UTF_8));
            String legacyFlatUri = Cms.fileUri(legacyFlatFile);
            Cms.Config legacyCfg = Cms.parseConfig(rev1Body, legacyFlatUri);
            String legacyKey = legacyCfg.sites.get(0).key;
            host4.configStore.write(legacyCfg.raw);
            host4.prefs
                    .edit()
                    .putString(Prefs.ORIGIN, "")
                    .putString(Prefs.SELECTED_SITE, legacyKey)
                    .putString(Prefs.PREFERRED_SITE, SourcePreferences.identity(legacyCfg.sites.get(0)))
                    .apply();
            // Simulate cold boot into 0.7.0 before importing another same-named document
            ConfigStore.RecoveredState preUpgrade =
                    host4.configStore.loadRecoveredState(
                            host4.prefs.getString(Prefs.ORIGIN, null),
                            host4.prefs.getString(Prefs.SELECTED_SITE, null),
                            host4.prefs.getString(Prefs.ACTIVE_SUBSCRIPTION_ID, null));
            host4.config = Cms.parseConfig(preUpgrade.raw, preUpgrade.origin);
            host4.configOrigin = preUpgrade.origin == null ? "" : preUpgrade.origin;
            host4.prefs.edit().putString(Prefs.ACTIVE_SUBSCRIPTION_ID, preUpgrade.subscriptionId).apply();
            SourcePreferences.restoreDefault(host4);

            // Headless import of dirB/source.py MUST preserve old 0.6.0 dirA & its PREFERRED_SITE!
            cr4.bodies.put(
                    otherUri.toString(),
                    "# other-doc-B\\nclass Spider:\\n    def homeContent(self, f): return {}\\n");
            SourceController.importLocalUri(host4, otherUri, false);
            exec4.submit(() -> {}).get(5, TimeUnit.SECONDS);
            drainUntil(
                    host4,
                    () ->
                            host4.config != null
                                    && host4.config.sites.size() == 2);
            ConfigStore.WRITE_EXECUTOR.submit(() -> {}).get(5, TimeUnit.SECONDS);
            host4.ui.drain();

            // Cold restart + SourcePreferences.restoreDefault MUST keep sites=2, original preferred!
            MainActivity coldHost4 = newHost(root4, exec4, cr4);
            for (String k :
                    new String[] {
                        Prefs.ORIGIN,
                        Prefs.SELECTED_SITE,
                        Prefs.PREFERRED_SITE,
                        Prefs.ACTIVE_SUBSCRIPTION_ID
                    }) {
                if (host4.prefs.contains(k)) {
                    coldHost4.prefs.edit().putString(k, host4.prefs.getString(k, "")).apply();
                }
            }
            ConfigStore.RecoveredState postUpgrade =
                    coldHost4.configStore.loadRecoveredState(
                            coldHost4.prefs.getString(Prefs.ORIGIN, null),
                            coldHost4.prefs.getString(Prefs.SELECTED_SITE, null),
                            coldHost4.prefs.getString(Prefs.ACTIVE_SUBSCRIPTION_ID, null));
            coldHost4.config = Cms.parseConfig(postUpgrade.raw, postUpgrade.origin);
            coldHost4.configOrigin = postUpgrade.origin == null ? "" : postUpgrade.origin;
            if (postUpgrade.selectedSite != null) {
                coldHost4.prefs.edit().putString(Prefs.SELECTED_SITE, postUpgrade.selectedSite).apply();
            }
            SourcePreferences.restoreDefault(coldHost4);
            check(
                    coldHost4.config.sites.size() == 2
                            && legacyKey.equals(coldHost4.config.sites.get(0).key)
                            && SourcePreferences.isPreferred(coldHost4, coldHost4.config.sites.get(0))
                            && !SourcePreferences.isPreferred(coldHost4, coldHost4.config.sites.get(1))
                            && legacyKey.equals(coldHost4.prefs.getString(Prefs.SELECTED_SITE, ""))
                            && readApiFile(coldHost4.config.sites.get(0).api)
                                    .startsWith("# revision-one")
                            && readApiFile(coldHost4.config.sites.get(1).api)
                                    .startsWith("# other-doc-B"),
                    "R9 Round-5 headless 0.6.0 guard: preserves old 0.6.0 flat site + PREFERRED_SITE and adds distinct document separately");

            // Ambiguous non-flat legacy hashed script (no SAF URI) MUST NOT silently merge by filename!
            File rootAmb = Files.createTempDirectory("r9-r4-ambiguous-legacy-").toFile();
            MainActivity hostAmb = newHost(rootAmb, exec4, cr4);
            File ambBucket = new File(new File(rootAmb, "local_spiders"), "deadbeef12345678");
            ambBucket.mkdirs();
            File ambFile = new File(ambBucket, "source.py");
            String ambBody = "# ambiguous-old\\nclass Spider:\\n    def homeContent(self, f): return {}\\n";
            Files.write(ambFile.toPath(), ambBody.getBytes(StandardCharsets.UTF_8));
            Cms.Config ambCfg = Cms.parseConfig(ambBody, Cms.fileUri(ambFile));
            hostAmb.configStore.write(ambCfg.raw);
            hostAmb.config = ambCfg;
            hostAmb.configOrigin = "";
            cr4.bodies.put(
                    otherUri.toString(),
                    "# distinct-new\\nclass Spider:\\n    def homeContent(self, f): return {}\\n");
            SourceController.importLocalUri(hostAmb, otherUri, false);
            exec4.submit(() -> {}).get(5, TimeUnit.SECONDS);
            drainUntil(hostAmb, () -> hostAmb.config != null && hostAmb.config.sites.size() == 2);
            check(
                    hostAmb.config.sites.size() == 2
                            && readApiFile(hostAmb.config.sites.get(0).api).startsWith("# ambiguous-old")
                            && readApiFile(hostAmb.config.sites.get(1).api).startsWith("# distinct-new"),
                    "R9 Round-4 ambiguity guard: non-flat legacy script without SAF URI is never silently merged by filename");
        } finally {
            exec4.shutdownNow();
        }

        // -----------------------------------------------------------------
        // 5. Round-4 R2: CloudSync subscription activation & removal MUST keep
        //    Prefs.ACTIVE_SUBSCRIPTION_ID aligned so manual site switch ("second")
        //    persists across cold restart for both tombstoned HTTP A -> HTTP B and
        //    fresh-device empty-origin local B!
        // -----------------------------------------------------------------
        for (int mode = 0; mode < 2; mode++) {
            boolean hasOld = (mode == 0);
            File syncRoot = Files.createTempDirectory("r2-r4-cloudsync-" + mode + "-").toFile();
            ExecutorService syncExec = Executors.newSingleThreadExecutor();
            try {
                MainActivity syncHost = newHost(syncRoot, syncExec, new ContentResolver());
                syncHost.prefs.edit().putBoolean(Prefs.WEBDAV_SYNC_SUBS, false).apply();
                String originA = "https://catalog.invalid/A/config.json";
                String originB = "https://catalog.invalid/B/config.json";
                String rawA =
                        "{\\\"sites\\\":[{\\\"key\\\":\\\"first\\\",\\\"name\\\":\\\"A first\\\",\\\"type\\\":1,\\\"api\\\":\\\"./first\\\"},{\\\"key\\\":\\\"second\\\",\\\"name\\\":\\\"A second\\\",\\\"type\\\":1,\\\"api\\\":\\\"./second\\\"}]}";
                String rawB =
                        "{\\\"sites\\\":[{\\\"key\\\":\\\"first\\\",\\\"name\\\":\\\"B first\\\",\\\"type\\\":1,\\\"api\\\":\\\"./first\\\"},{\\\"key\\\":\\\"second\\\",\\\"name\\\":\\\"B second\\\",\\\"type\\\":1,\\\"api\\\":\\\"./second\\\"}]}";
                String tombsJson = "{}";
                if (hasOld) {
                    SourceController.saveConfig(syncHost, Cms.parseConfig(rawA, originA), originA);
                    ConfigStore.WRITE_EXECUTOR.submit(() -> {}).get(5, TimeUnit.SECONDS);
                    syncHost.ui.drain();
                    String oldId = syncHost.prefs.getString(Prefs.ACTIVE_SUBSCRIPTION_ID, "");
                    tombsJson =
                            new org.json.JSONObject()
                                    .put("sub:" + oldId, System.currentTimeMillis() + 10000L)
                                    .toString();
                }
                CloudSync.SubscriptionItem itemB = new CloudSync.SubscriptionItem();
                itemB.rawContent = rawB;
                itemB.url = hasOld ? originB : "";
                itemB.name = "B";
                itemB.selectedSiteKey = "first";
                itemB.updatedAt = System.currentTimeMillis();
                java.lang.reflect.Method applyMerged =
                        CloudSyncDialog.class.getDeclaredMethod(
                                "applyMergedSubscriptions",
                                MainActivity.class,
                                java.util.List.class,
                                String.class);
                applyMerged.setAccessible(true);
                final String finalTombs = tombsJson;
                java.util.concurrent.Future<?> syncFuture =
                        syncExec.submit(
                                () ->
                                        applyMerged.invoke(
                                                null,
                                                syncHost,
                                                java.util.Collections.singletonList(itemB),
                                                finalTombs));
                long syncDeadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(10);
                while (!syncFuture.isDone() && System.nanoTime() < syncDeadline) {
                    syncHost.ui.drain();
                    Thread.sleep(10);
                }
                check(
                        Boolean.TRUE.equals(syncFuture.get(5, TimeUnit.SECONDS)),
                        "R2 Round-4 CloudSync(" + (hasOld ? "tombstone-HTTP" : "fresh-local") + "): activation succeeded");
                String expectedId = ConfigStore.subscriptionIdentity(syncHost.configOrigin, syncHost.config.raw);
                check(
                        expectedId.equals(syncHost.prefs.getString(Prefs.ACTIVE_SUBSCRIPTION_ID, "")),
                        "R2 Round-4 CloudSync(" + (hasOld ? "tombstone-HTTP" : "fresh-local") + "): ACTIVE_SUBSCRIPTION_ID updated to active B");
                // Manual site switch to "second" via real SourcePicker crash-guard helper
                java.lang.reflect.Method pickSite =
                        SourcePicker.class.getDeclaredMethod(
                                "commitSelectedSiteForCrashGuard", MainActivity.class, String.class);
                pickSite.setAccessible(true);
                pickSite.invoke(null, syncHost, "second");
                ConfigStore.RecoveredState coldSync =
                        new ConfigStore(new File(syncRoot, "cfg"))
                                .loadRecoveredState(
                                        syncHost.prefs.getString(Prefs.ORIGIN, null),
                                        syncHost.prefs.getString(Prefs.SELECTED_SITE, null),
                                        syncHost.prefs.getString(Prefs.ACTIVE_SUBSCRIPTION_ID, null));
                check(
                        "second".equals(coldSync.selectedSite)
                                && expectedId.equals(coldSync.subscriptionId),
                        "R2 Round-4 CloudSync(" + (hasOld ? "tombstone-HTTP" : "fresh-local") + "): cold restart preserves manual switch 'second'");

                // Deleting active subscription clears ACTIVE_SUBSCRIPTION_ID too!
                if (hasOld) {
                    String clearTombs =
                            new org.json.JSONObject()
                                    .put("sub:" + expectedId, System.currentTimeMillis() + 20000L)
                                    .toString();
                    java.util.concurrent.Future<?> clearFuture =
                            syncExec.submit(
                                    () ->
                                            applyMerged.invoke(
                                                    null,
                                                    syncHost,
                                                    java.util.Collections.emptyList(),
                                                    clearTombs));
                    long clearDeadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(10);
                    while (!clearFuture.isDone() && System.nanoTime() < clearDeadline) {
                        syncHost.ui.drain();
                        Thread.sleep(10);
                    }
                    clearFuture.get(5, TimeUnit.SECONDS);
                    check(
                            !syncHost.prefs.contains(Prefs.ACTIVE_SUBSCRIPTION_ID)
                                    && !syncHost.prefs.contains(Prefs.ORIGIN)
                                    && !syncHost.prefs.contains(Prefs.SELECTED_SITE),
                            "R2 Round-4 CloudSync: deleting last active subscription clears ORIGIN, SELECTED_SITE, and ACTIVE_SUBSCRIPTION_ID");
                }
            } finally {
                syncExec.shutdownNow();
            }
        }
    }
}
""",
        encoding="utf-8",
    )

    cp = os.pathsep.join(str(p) for p in [r9_classes, *base_cp])
    subprocess.run(
        [
            JAVAC,
            "-encoding",
            "UTF-8",
            "-cp",
            cp,
            "-d",
            str(r9_classes),
            str(handler_java),
            str(resolver_java),
            str(activity_java),
            str(main_activity_java),
            str(test_java),
        ],
        check=True,
    )
    subprocess.run(
        [JAVA, "-Dfile.encoding=UTF-8", "-cp", cp, "com.pilipala.marcomovie.R9SameNameImportCheck"],
        cwd=ROOT,
        check=True,
        timeout=40,
    )


def run_r9_legacy_choice_dialog_harness(work_dir: Path, base_cp: list[Path]) -> None:
    """Exercise REAL SourceController.importLocalUri interactive AppDialog choice for 0.6.0 flat & legacy hashed scripts."""
    r9d_dir = work_dir / "r9-legacy-choice-dialog"
    r9d_src = r9d_dir / "src"
    r9d_classes = r9d_dir / "classes"
    r9d_src.mkdir(parents=True, exist_ok=True)
    r9d_classes.mkdir(parents=True, exist_ok=True)

    window_java = r9d_src / "android/view/Window.java"
    window_java.parent.mkdir(parents=True, exist_ok=True)
    window_java.write_text("package android.view;\npublic class Window {}\n", encoding="utf-8")

    handler_java = r9d_src / "android/os/Handler.java"
    handler_java.parent.mkdir(parents=True, exist_ok=True)
    handler_java.write_text(
        """package android.os;
import java.util.ArrayList;
import java.util.List;
public class Handler {
    public final List<Runnable> posted = new ArrayList<>();
    public boolean post(Runnable r) {
        synchronized (posted) { posted.add(r); }
        return true;
    }
    public void drain() {
        List<Runnable> copy;
        synchronized (posted) {
            copy = new ArrayList<>(posted);
            posted.clear();
        }
        for (Runnable r : copy) r.run();
    }
}
""",
        encoding="utf-8",
    )

    resolver_java = r9d_src / "android/content/ContentResolver.java"
    resolver_java.parent.mkdir(parents=True, exist_ok=True)
    resolver_java.write_text(
        """package android.content;
import android.database.Cursor;
import android.net.Uri;
import java.io.ByteArrayInputStream;
import java.io.InputStream;
import java.lang.reflect.Proxy;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.Map;

public class ContentResolver {
    public final Map<String, String> names = new HashMap<>();
    public final Map<String, String> bodies = new HashMap<>();

    public Cursor query(Uri uri, String[] projection, String selection, String[] selectionArgs, String sortOrder) {
        final String name = names.getOrDefault(uri.toString(), "source.py");
        return (Cursor) Proxy.newProxyInstance(
                Cursor.class.getClassLoader(),
                new Class<?>[] {Cursor.class},
                (proxy, method, args) -> {
                    String m = method.getName();
                    if ("moveToFirst".equals(m)) return Boolean.TRUE;
                    if ("getString".equals(m)) return name;
                    if ("close".equals(m)) return null;
                    return null;
                });
    }

    public InputStream openInputStream(Uri uri) {
        String body = bodies.getOrDefault(uri.toString(), "");
        return new ByteArrayInputStream(body.getBytes(StandardCharsets.UTF_8));
    }
}
""",
        encoding="utf-8",
    )

    activity_java = r9d_src / "android/app/Activity.java"
    activity_java.parent.mkdir(parents=True, exist_ok=True)
    activity_java.write_text(
        """package android.app;
import android.content.ContentResolver;
import android.view.Window;
import java.io.File;
public class Activity extends android.content.Context {
    public Window getWindow() { return new Window(); }
    public boolean isFinishing() { return false; }
    public boolean isDestroyed() { return false; }
    public ContentResolver getContentResolver() { return null; }
    @Override public File getFilesDir() { return null; }
}
""",
        encoding="utf-8",
    )

    main_activity_java = r9d_src / "com/pilipala/marcomovie/MainActivity.java"
    main_activity_java.parent.mkdir(parents=True, exist_ok=True)
    main_activity_java.write_text(
        """package com.pilipala.marcomovie;

import android.content.ContentResolver;
import android.content.SharedPreferences;
import java.io.File;
import java.util.ArrayDeque;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.atomic.AtomicLong;

public class MainActivity extends android.app.Activity {
    static final class Screen {
        final Runnable render;
        Screen(Runnable render) { this.render = render; }
    }

    public boolean privateMode, switchingPrivacy;
    public final AtomicLong configImportSeq = new AtomicLong();
    public android.os.Handler ui = new android.os.Handler();
    public ExecutorService worker;
    public File publicRoot;
    public ContentResolver resolver;
    public Cms.Config config;
    public String configOrigin = "";
    public ConfigStore configStore;
    public SharedPreferences prefs;
    public final ArrayDeque<Screen> back = new ArrayDeque<>();
    public Screen current;

    @Override public boolean isFinishing() { return false; }
    @Override public boolean isDestroyed() { return false; }
    boolean isTvDevice() { return false; }
    void toast(String msg) {}
    void refresh() {}
    void closeEngines() {}
    void home() {}
    void restore(Screen s) {}
    boolean available(Cms.Site site) { return true; }
    String message(Throwable e) { return e == null ? "" : String.valueOf(e.getMessage()); }
    @Override public ContentResolver getContentResolver() { return resolver; }
    @Override public File getFilesDir() { return publicRoot; }
}
""",
        encoding="utf-8",
    )

    app_dialog_java = r9d_src / "com/pilipala/marcomovie/AppDialog.java"
    app_dialog_java.parent.mkdir(parents=True, exist_ok=True)
    app_dialog_java.write_text(
        """package com.pilipala.marcomovie;

import android.content.DialogInterface;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

final class AppDialog implements DialogInterface {
    static int showCount;
    static String lastTitle = "";
    static final List<String> lastItems = new ArrayList<>();
    static int nextPick = -1; // -1 = last option (keep both), 0 = first legacy replace

    static void reset(int pickMode) {
        showCount = 0;
        lastTitle = "";
        lastItems.clear();
        nextPick = pickMode;
    }

    @Override public void cancel() {}
    @Override public void dismiss() {}

    static final class Builder {
        String title = "";
        String[] items = new String[0];
        DialogInterface.OnClickListener listener;

        Builder(MainActivity a) {}
        Builder wrapChoices() { return this; }
        Builder setTitle(String value) { this.title = value == null ? "" : value; return this; }
        Builder setItems(String[] values, DialogInterface.OnClickListener action) {
            this.items = values == null ? new String[0] : values;
            this.listener = action;
            return this;
        }
        AppDialog show() {
            showCount++;
            lastTitle = title;
            lastItems.clear();
            lastItems.addAll(Arrays.asList(items));
            AppDialog d = new AppDialog();
            if (listener != null && items.length > 0) {
                int idx = nextPick < 0 ? (items.length - 1) : nextPick;
                listener.onClick(d, idx);
            }
            return d;
        }
    }
}
""",
        encoding="utf-8",
    )

    test_java = r9d_src / "com/pilipala/marcomovie/R9LegacyChoiceDialogCheck.java"
    test_java.parent.mkdir(parents=True, exist_ok=True)
    test_java.write_text(
        """package com.pilipala.marcomovie;

import android.content.ContentResolver;
import android.content.SharedPreferences;
import android.net.Uri;
import java.io.File;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

public final class R9LegacyChoiceDialogCheck {
    private static void check(boolean cond, String label) {
        if (!cond) throw new AssertionError("FAIL: " + label);
        System.out.println("PASS " + label);
    }

    static final class MemPrefs implements SharedPreferences {
        final Map<String, Object> data = new HashMap<>();
        @Override public synchronized Map<String, ?> getAll() { return new HashMap<>(data); }
        @Override public synchronized String getString(String k, String d) {
            Object v = data.get(k); return v instanceof String ? (String) v : d;
        }
        @Override @SuppressWarnings("unchecked")
        public synchronized Set<String> getStringSet(String k, Set<String> d) {
            Object v = data.get(k); return v instanceof Set ? new HashSet<>((Set<String>) v) : d;
        }
        @Override public synchronized int getInt(String k, int d) {
            Object v = data.get(k); return v instanceof Integer ? (Integer) v : d;
        }
        @Override public synchronized long getLong(String k, long d) {
            Object v = data.get(k); return v instanceof Long ? (Long) v : d;
        }
        @Override public synchronized float getFloat(String k, float d) {
            Object v = data.get(k); return v instanceof Float ? (Float) v : d;
        }
        @Override public synchronized boolean getBoolean(String k, boolean d) {
            Object v = data.get(k); return v instanceof Boolean ? (Boolean) v : d;
        }
        @Override public synchronized boolean contains(String k) { return data.containsKey(k); }
        @Override public Editor edit() {
            return new Editor() {
                final Map<String, Object> u = new HashMap<>();
                final Set<String> rm = new HashSet<>();
                boolean clr;
                @Override public Editor putString(String k, String v) { u.put(k, v); rm.remove(k); return this; }
                @Override public Editor putStringSet(String k, Set<String> v) { u.put(k, v); rm.remove(k); return this; }
                @Override public Editor putInt(String k, int v) { u.put(k, v); rm.remove(k); return this; }
                @Override public Editor putLong(String k, long v) { u.put(k, v); rm.remove(k); return this; }
                @Override public Editor putFloat(String k, float v) { u.put(k, v); rm.remove(k); return this; }
                @Override public Editor putBoolean(String k, boolean v) { u.put(k, v); rm.remove(k); return this; }
                @Override public Editor remove(String k) { rm.add(k); u.remove(k); return this; }
                @Override public Editor clear() { clr = true; u.clear(); rm.clear(); return this; }
                @Override public boolean commit() { apply(); return true; }
                @Override public void apply() {
                    synchronized (MemPrefs.this) {
                        if (clr) data.clear();
                        for (String r : rm) data.remove(r);
                        for (Map.Entry<String, Object> e : u.entrySet()) {
                            if (e.getValue() == null) data.remove(e.getKey());
                            else data.put(e.getKey(), e.getValue());
                        }
                    }
                }
            };
        }
        @Override public void registerOnSharedPreferenceChangeListener(OnSharedPreferenceChangeListener l) {}
        @Override public void unregisterOnSharedPreferenceChangeListener(OnSharedPreferenceChangeListener l) {}
    }

    private static MainActivity newHost(File root, ExecutorService exec, ContentResolver cr) {
        MainActivity host = new MainActivity();
        host.publicRoot = root;
        host.resolver = cr;
        host.worker = exec;
        host.prefs = new MemPrefs();
        host.configStore = new ConfigStore(new File(root, "cfg"));
        return host;
    }

    private static String readApiFile(String apiUri) throws Exception {
        return new String(Files.readAllBytes(new File(new URI(apiUri)).toPath()), StandardCharsets.UTF_8);
    }

    private static void flush(MainActivity host, ExecutorService exec) throws Exception {
        exec.submit(() -> {}).get(5, TimeUnit.SECONDS);
        host.ui.drain();
        ConfigStore.WRITE_EXECUTOR.submit(() -> {}).get(5, TimeUnit.SECONDS);
        host.ui.drain();
    }

    private static MainActivity coldRestart(File root, ExecutorService exec, ContentResolver cr, MainActivity prev)
            throws Exception {
        MainActivity cold = newHost(root, exec, cr);
        for (String k :
                new String[] {
                    Prefs.ORIGIN,
                    Prefs.SELECTED_SITE,
                    Prefs.PREFERRED_SITE,
                    Prefs.ACTIVE_SUBSCRIPTION_ID
                }) {
            if (prev.prefs.contains(k)) {
                cold.prefs.edit().putString(k, prev.prefs.getString(k, "")).apply();
            }
        }
        ConfigStore.RecoveredState rec =
                cold.configStore.loadRecoveredState(
                        cold.prefs.getString(Prefs.ORIGIN, null),
                        cold.prefs.getString(Prefs.SELECTED_SITE, null),
                        cold.prefs.getString(Prefs.ACTIVE_SUBSCRIPTION_ID, null));
        cold.config = Cms.parseConfig(rec.raw, rec.origin);
        cold.configOrigin = rec.origin == null ? "" : rec.origin;
        if (rec.selectedSite != null) {
            cold.prefs.edit().putString(Prefs.SELECTED_SITE, rec.selectedSite).apply();
        }
        if (rec.subscriptionId != null && !rec.subscriptionId.isEmpty()) {
            cold.prefs.edit().putString(Prefs.ACTIVE_SUBSCRIPTION_ID, rec.subscriptionId).apply();
        }
        SourcePreferences.restoreDefault(cold);
        return cold;
    }

    private static MainActivity seedLegacySite(
            File root, ExecutorService exec, ContentResolver cr, boolean flat060) throws Exception {
        MainActivity host = newHost(root, exec, cr);
        File targetDir =
                flat060
                        ? new File(root, "local_spiders")
                        : new File(new File(root, "local_spiders"), "deadbeef12345678");
        targetDir.mkdirs();
        File legacyFile = new File(targetDir, "source.py");
        String bodyA = "# revision-one\\nclass Spider:\\n    def homeContent(self, f): return {}\\n";
        Files.write(legacyFile.toPath(), bodyA.getBytes(StandardCharsets.UTF_8));
        Cms.Config legacyCfg = Cms.parseConfig(bodyA, Cms.fileUri(legacyFile));
        String legacyKey = legacyCfg.sites.get(0).key;
        host.configStore.write(legacyCfg.raw);
        host.prefs
                .edit()
                .putString(Prefs.ORIGIN, "")
                .putString(Prefs.SELECTED_SITE, legacyKey)
                .putString(Prefs.PREFERRED_SITE, SourcePreferences.identity(legacyCfg.sites.get(0)))
                .apply();
        return coldRestart(root, exec, cr, host);
    }

    public static void main(String[] args) throws Exception {
        ExecutorService exec = Executors.newSingleThreadExecutor();
        try {
            ContentResolver cr = new ContentResolver();
            Uri uriA = Uri.parse("content://docs/dirA/source.py");
            Uri uriB = Uri.parse("content://docs/dirB/source.py");
            cr.names.put(uriA.toString(), "source.py");
            cr.names.put(uriB.toString(), "source.py");
            cr.bodies.put(uriA.toString(), "# revision-two\\nclass Spider:\\n    def homeContent(self, f): return {}\\n");
            cr.bodies.put(uriB.toString(), "# other-doc-B\\nclass Spider:\\n    def homeContent(self, f): return {}\\n");

            for (boolean flat060 : new boolean[] {true, false}) {
                String tag = flat060 ? "0.6.0-flat" : "legacy-hashed";

                // 1. User chooses "保留旧片源并新增为独立片源" -> both sites preserved, old PREFERRED_SITE intact!
                File keepRoot = Files.createTempDirectory("r9-r5-choice-keep-" + tag + "-").toFile();
                MainActivity keepHost = seedLegacySite(keepRoot, exec, cr, flat060);
                String oldKey = keepHost.config.sites.get(0).key;
                AppDialog.reset(-1);
                SourceController.importLocalUri(keepHost, uriB, false);
                flush(keepHost, exec);
                MainActivity coldKeep = coldRestart(keepRoot, exec, cr, keepHost);
                check(
                        AppDialog.showCount == 1
                                && AppDialog.lastItems.size() == 2
                                && AppDialog.lastItems.get(0).startsWith("替换旧版同名片源：")
                                && "保留旧片源并新增为独立片源".equals(AppDialog.lastItems.get(1))
                                && coldKeep.config.sites.size() == 2
                                && oldKey.equals(coldKeep.config.sites.get(0).key)
                                && SourcePreferences.isPreferred(coldKeep, coldKeep.config.sites.get(0))
                                && !SourcePreferences.isPreferred(coldKeep, coldKeep.config.sites.get(1))
                                && oldKey.equals(coldKeep.prefs.getString(Prefs.SELECTED_SITE, ""))
                                && readApiFile(coldKeep.config.sites.get(0).api).startsWith("# revision-one")
                                && readApiFile(coldKeep.config.sites.get(1).api).startsWith("# other-doc-B"),
                        "R9 Round-5 interactive(" + tag + ", keep-both): shows choice dialog, keeps both docs, preserves original PREFERRED_SITE");

                // 2. User chooses "替换旧版同名片源..." -> 1->1 replacement & migrates PREFERRED_SITE!
                File repRoot = Files.createTempDirectory("r9-r5-choice-replace-" + tag + "-").toFile();
                MainActivity repHost = seedLegacySite(repRoot, exec, cr, flat060);
                AppDialog.reset(0);
                SourceController.importLocalUri(repHost, uriA, false);
                flush(repHost, exec);
                MainActivity coldRep = coldRestart(repRoot, exec, cr, repHost);
                check(
                        AppDialog.showCount == 1
                                && coldRep.config.sites.size() == 1
                                && coldRep.config.sites.get(0).key.startsWith("py_doc_")
                                && SourcePreferences.isPreferred(coldRep, coldRep.config.sites.get(0))
                                && coldRep.config.sites.get(0).key.equals(coldRep.prefs.getString(Prefs.SELECTED_SITE, ""))
                                && readApiFile(coldRep.config.sites.get(0).api).startsWith("# revision-two"),
                        "R9 Round-5 interactive(" + tag + ", replace): shows choice dialog, migrates 1->1 and preserves PREFERRED_SITE");

                // 3. Subsequent update of the ALREADY doc-scoped py_doc_* URI requires NO dialog (1->1)!
                cr.bodies.put(uriA.toString(), "# revision-three\\nclass Spider:\\n    def homeContent(self, f): return {}\\n");
                AppDialog.reset(-1);
                SourceController.importLocalUri(coldRep, uriA, false);
                flush(coldRep, exec);
                MainActivity coldDocUp = coldRestart(repRoot, exec, cr, coldRep);
                check(
                        AppDialog.showCount == 0
                                && coldDocUp.config.sites.size() == 1
                                && coldDocUp.config.sites.get(0).key.equals(coldRep.config.sites.get(0).key)
                                && SourcePreferences.isPreferred(coldDocUp, coldDocUp.config.sites.get(0))
                                && readApiFile(coldDocUp.config.sites.get(0).api).startsWith("# revision-three"),
                        "R9 Round-5 interactive(" + tag + ", doc-scoped update): updates 1->1 silently without dialog");
                cr.bodies.put(uriA.toString(), "# revision-two\\nclass Spider:\\n    def homeContent(self, f): return {}\\n");
            }
        } finally {
            exec.shutdownNow();
        }
    }
}
""",
        encoding="utf-8",
    )

    cp = os.pathsep.join(str(p) for p in [r9d_classes, *base_cp])
    subprocess.run(
        [
            JAVAC,
            "-encoding",
            "UTF-8",
            "-cp",
            cp,
            "-d",
            str(r9d_classes),
            str(window_java),
            str(handler_java),
            str(resolver_java),
            str(activity_java),
            str(main_activity_java),
            str(app_dialog_java),
            str(test_java),
        ],
        check=True,
    )
    subprocess.run(
        [JAVA, "-Dfile.encoding=UTF-8", "-cp", cp, "com.pilipala.marcomovie.R9LegacyChoiceDialogCheck"],
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

        # Verify R9 real SourceController.importLocalUri same-named source.py + privacy isolation
        run_r9_same_name_import_harness(work_dir, runtime_cp)

        # Verify R9 Round-5 interactive AppDialog choice for 0.6.0 flat & legacy hashed scripts
        run_r9_legacy_choice_dialog_harness(work_dir, runtime_cp)

        # Verify R10 real MobileInlinePlayer.captureResumePosition() bytecode
        run_r10_inline_progress_harness(work_dir, runtime_cp)

        # Verify R10 real PlaybackController.createPlayerWithPlan MPV init fallback vs AUTO_SWITCH_KERNEL
        run_r10_init_fallback_harness(work_dir, runtime_cp)

        # Verify R11 CI & dual-ephemeral-key isolation
        verify_r11_update_isolation_ci(work_dir)

        print("ALL R6-R12 REGRESSION CHECKS PASSED")


if __name__ == "__main__":
    main()
