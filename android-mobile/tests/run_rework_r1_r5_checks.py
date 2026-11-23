"""Automated regression checks for Codex Rework Priority Blockers R1-R5."""

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
JAVA = str(JDK / ("java" + SUFFIX))
JAVAC = str(JDK / ("javac" + SUFFIX))


def run_r3_buffered_stop_harness(classes_dir: Path, work_dir: Path, base_cp: list[Path]) -> None:
    """Exercise the REAL compiled MobileInlinePlayer.onActivityStop against a buffering player double."""
    r3_dir = work_dir / "r3-buffering"
    r3_src = r3_dir / "src"
    r3_classes = r3_dir / "classes"
    r3_src.mkdir(parents=True, exist_ok=True)
    r3_classes.mkdir(parents=True, exist_ok=True)

    # Minimal Handler & buffering MoviePlayer double placed ahead of android.jar / compiled classes
    # to test the real production MobileInlinePlayer.onActivityStop(boolean) bytecode!
    handler_java = r3_src / "android/os/Handler.java"
    handler_java.parent.mkdir(parents=True, exist_ok=True)
    handler_java.write_text(
        """package android.os;
public class Handler {
    public int removedCallbacks;
    public void removeCallbacks(Runnable r) { removedCallbacks++; }
    public boolean post(Runnable r) { return true; }
    public boolean postDelayed(Runnable r, long delay) { return true; }
}
""",
        encoding="utf-8",
    )

    player_java = r3_src / "com/pilipala/marcomovie/MoviePlayer.java"
    player_java.parent.mkdir(parents=True, exist_ok=True)
    player_java.write_text(
        """package com.pilipala.marcomovie;
public class MoviePlayer {
    public boolean playWhenReady = true;
    public boolean buffering = true;
    public int pauseCalls;
    public int getCurrentPosition() { return 120_000; }
    public int getDuration() { return 2_400_000; }
    public boolean isPlaying() { return playWhenReady && !buffering; }
    public void pause() {
        pauseCalls++;
        playWhenReady = false;
    }
    public void start() {
        playWhenReady = true;
    }
}
""",
        encoding="utf-8",
    )

    test_java = r3_src / "com/pilipala/marcomovie/R3BufferedStopCheck.java"
    test_java.write_text(
        """package com.pilipala.marcomovie;
import java.lang.reflect.Field;
import sun.misc.Unsafe;

public final class R3BufferedStopCheck {
    private static void check(boolean cond, String label) {
        if (!cond) throw new AssertionError("FAIL: " + label);
        System.out.println("PASS " + label);
    }

    private static void put(Object target, String name, Object val) throws Exception {
        Field f = target.getClass().getDeclaredField(name);
        f.setAccessible(true);
        f.set(target, val);
    }

    private static boolean getBool(Object target, String name) throws Exception {
        Field f = target.getClass().getDeclaredField(name);
        f.setAccessible(true);
        return f.getBoolean(target);
    }

    private static MobileInlinePlayer newInline(Unsafe u, MoviePlayer player, boolean prepared)
            throws Exception {
        MobileInlinePlayer inline =
                (MobileInlinePlayer) u.allocateInstance(MobileInlinePlayer.class);
        MainActivity host = (MainActivity) u.allocateInstance(MainActivity.class);
        put(host, "ui", new android.os.Handler());
        host.privateMode = true;
        put(inline, "a", host);
        put(inline, "player", player);
        put(inline, "prepared", prepared);
        return inline;
    }

    public static void main(String[] args) throws Exception {
        Field uf = Unsafe.class.getDeclaredField("theUnsafe");
        uf.setAccessible(true);
        Unsafe u = (Unsafe) uf.get(null);

        // 1. Ready once -> buffering (isPlaying=false, playWhenReady=true) -> onActivityStop(false)
        //    -> buffer completes in background: MUST remain silent!
        MoviePlayer p1 = new MoviePlayer();
        MobileInlinePlayer inline1 = newInline(u, p1, true);
        check(!p1.isPlaying() && p1.playWhenReady, "R3 setup: buffering player has isPlaying=false, playWhenReady=true");
        inline1.onActivityStop(false);
        p1.buffering = false;
        check(
                p1.pauseCalls == 1 && !p1.playWhenReady && !p1.isPlaying() && getBool(inline1, "pausedForBackground"),
                "R3: onActivityStop(false) while buffering calls pause() and stays silent after buffer fills");

        // 2. Not yet prepared -> backgrounded with keepBgPlay=false: revokes intent too!
        MoviePlayer p2 = new MoviePlayer();
        MobileInlinePlayer inline2 = newInline(u, p2, false);
        inline2.onActivityStop(false);
        p2.buffering = false;
        check(
                p2.pauseCalls == 1 && !p2.isPlaying() && getBool(inline2, "pausedForBackground"),
                "R3: onActivityStop(false) before onPrepared still pauses player and sets pausedForBackground");

        // 3. Control A: Background play preference enabled -> keepBgPlay=true keeps playing after buffer fills!
        check(
                MobileInlinePlayer.shouldContinuePlaybackInBackground(false, false, true),
                "R3 control: backgroundPlayPref=true allows background playback");
        MoviePlayer p3 = new MoviePlayer();
        MobileInlinePlayer inline3 = newInline(u, p3, true);
        inline3.onActivityStop(true);
        p3.buffering = false;
        check(
                p3.pauseCalls == 0 && p3.playWhenReady && p3.isPlaying(),
                "R3 control: onActivityStop(true) with background play ON continues playing after buffer fills");

        // 4. Control B: Active Picture-in-Picture -> keepBgPlay=true keeps playing after buffer fills!
        check(
                MobileInlinePlayer.shouldContinuePlaybackInBackground(false, true, false),
                "R3 control: inPip=true allows playback when backgroundPlayPref=false");
        MoviePlayer p4 = new MoviePlayer();
        MobileInlinePlayer inline4 = newInline(u, p4, true);
        inline4.onActivityStop(true);
        p4.buffering = false;
        check(
                p4.pauseCalls == 0 && p4.playWhenReady && p4.isPlaying(),
                "R3 control: onActivityStop(true) in PiP continues playing after buffer fills");

        // 5. Direct pause() while buffering (e.g. surface destroyed) also revokes intent!
        MoviePlayer p5 = new MoviePlayer();
        MobileInlinePlayer inline5 = newInline(u, p5, true);
        inline5.pause();
        p5.buffering = false;
        check(
                p5.pauseCalls == 1 && !p5.isPlaying(),
                "R3: pause() while buffering revokes playWhenReady so buffer completion stays silent");
    }
}
""",
        encoding="utf-8",
    )

    compile_cp = os.pathsep.join(str(p) for p in [r3_classes, *base_cp])
    subprocess.run(
        [
            JAVAC,
            "-encoding",
            "UTF-8",
            "-cp",
            compile_cp,
            "-d",
            str(r3_classes),
            str(handler_java),
            str(player_java),
            str(test_java),
        ],
        check=True,
    )
    run_cp = os.pathsep.join(str(p) for p in [r3_classes, *base_cp])
    subprocess.run(
        [JAVA, "-Dfile.encoding=UTF-8", "-cp", run_cp, "com.pilipala.marcomovie.R3BufferedStopCheck"],
        cwd=ROOT,
        check=True,
        timeout=40,
    )


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="rework-r1-r5-") as tmp:
        work_dir = Path(tmp)
        classes_dir = work_dir / "classes"
        data_dir = work_dir / "data"
        halt_dir = work_dir / "r2-halt-state"
        data_dir.mkdir(parents=True, exist_ok=True)
        halt_dir.mkdir(parents=True, exist_ok=True)

        runtime_cp = compile_real_android_sources(
            classes_dir=classes_dir,
            work_dir=work_dir,
            test_sources=[ROOT / "android-mobile/tests/ReworkR1ToR5Checks.java"],
        )
        cp_str = os.pathsep.join(str(p) for p in runtime_cp)

        # 1. Run main R1, R2 (normal + failure + retry), R4 (latch MPV race), R5 (finite credits)
        subprocess.run(
            [
                JAVA,
                "-Dfile.encoding=UTF-8",
                "-cp",
                cp_str,
                "com.pilipala.marcomovie.ReworkR1ToR5Checks",
                str(data_dir),
                str(MOBILE_SRC),
            ],
            cwd=ROOT,
            check=True,
            timeout=60,
        )

        # 2. Run real Runtime.getRuntime().halt(0) child JVM + cold restart child JVM for R2a
        subprocess.run(
            [
                JAVA,
                "-Dfile.encoding=UTF-8",
                "-cp",
                cp_str,
                "com.pilipala.marcomovie.ReworkR1ToR5Checks",
                "--r2-halt",
                str(halt_dir),
            ],
            cwd=ROOT,
            check=True,
            timeout=40,
        )
        subprocess.run(
            [
                JAVA,
                "-Dfile.encoding=UTF-8",
                "-cp",
                cp_str,
                "com.pilipala.marcomovie.ReworkR1ToR5Checks",
                "--r2-cold",
                str(halt_dir),
            ],
            cwd=ROOT,
            check=True,
            timeout=40,
        )

        # 3. Run R3 real MobileInlinePlayer.onActivityStop buffering harness
        run_r3_buffered_stop_harness(classes_dir, work_dir, runtime_cp)

        print("ALL R1-R5 REGRESSION CHECKS PASSED")


if __name__ == "__main__":
    main()
