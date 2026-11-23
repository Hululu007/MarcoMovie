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


def run_r2_explicit_default_and_r4_fullscreen_return_harness(
    work_dir: Path, base_cp: list[Path]
) -> None:
    """Exercise REAL SourcePreferences.restoreDefault (R2 explicit default) & REAL PlaybackController.leavePlayback / releasePlayer / isFullscreenSessionActive (R4 offline return + rapid play B)."""
    r24_dir = work_dir / "r2-r4-round2"
    r24_src = r24_dir / "src"
    r24_classes = r24_dir / "classes"
    r24_src.mkdir(parents=True, exist_ok=True)
    r24_classes.mkdir(parents=True, exist_ok=True)

    handler_java = r24_src / "android/os/Handler.java"
    handler_java.parent.mkdir(parents=True, exist_ok=True)
    handler_java.write_text(
        """package android.os;
import java.util.ArrayList;
import java.util.List;
public class Handler {
    public final List<Runnable> posted = new ArrayList<>();
    public void removeCallbacks(Runnable r) {}
    public boolean post(Runnable r) {
        synchronized (posted) { posted.add(r); }
        return true;
    }
    public boolean postDelayed(Runnable r, long delay) { return post(r); }
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

    context_java = r24_src / "android/content/Context.java"
    context_java.parent.mkdir(parents=True, exist_ok=True)
    context_java.write_text(
        """package android.content;
public abstract class Context {}
""",
        encoding="utf-8",
    )

    activity_java = r24_src / "android/app/Activity.java"
    activity_java.parent.mkdir(parents=True, exist_ok=True)
    activity_java.write_text(
        """package android.app;
public class Activity extends android.content.Context {
    public boolean isFinishing() { return false; }
    public boolean isDestroyed() { return false; }
    public void setRequestedOrientation(int requestedOrientation) {}
    public android.view.Window getWindow() { return null; }
}
""",
        encoding="utf-8",
    )

    main_activity_java = r24_src / "com/pilipala/marcomovie/MainActivity.java"
    main_activity_java.parent.mkdir(parents=True, exist_ok=True)
    main_activity_java.write_text(
        """package com.pilipala.marcomovie;

import android.content.SharedPreferences;
import java.util.ArrayDeque;
import java.util.Deque;
import java.util.concurrent.atomic.AtomicInteger;

public class MainActivity extends android.app.Activity {
    static final class Screen {
        final Runnable render;
        boolean home;
        boolean player;
        Screen(Runnable render) { this.render = render; }
    }

    public boolean privateMode;
    public Runnable seekPulse;
    public boolean finishingFlag;
    public boolean destroyedFlag;
    public boolean tvFlag;
    public boolean playerLocked;
    public Runnable hideLockButton;
    public android.os.Handler ui = new android.os.Handler();
    public int usableWidth = 1080;
    public int usableHeight = 1920;
    public final ArrayDeque<Screen> back = new ArrayDeque<>();
    public Screen current;
    public int generation;
    public int fullscreenPlaybackSession;
    public MobileInlinePlayer inlinePlayer;
    public TvMarkerHost markerHost;
    public PlayerChrome playerChrome;
    public final SeekGesture seekGesture = new SeekGesture();
    public TouchPlayerGesture touchPlayerGesture;
    public MobilePlayerOverlay mobilePlayerOverlay;
    public WatchHistory.Entry playingBookmark;
    public com.pilipala.emby.EmbyLibrary.Reporter embyReporter;
    public boolean miniMode;
    public MiniDetails miniDetails;
    public PlaybackControls playbackControls;
    public boolean prepared;
    public boolean playing;
    public MoviePlayer player;
    public Cms.Config config;
    public SharedPreferences prefs;
    public final AtomicInteger renderReturnCalls = new AtomicInteger();

    @Override public boolean isFinishing() { return finishingFlag; }
    @Override public boolean isDestroyed() { return destroyedFlag; }
    boolean isTvDevice() { return tvFlag; }
    void applyMobileSystemBars(boolean fullscreen) {}
    @Override public void setRequestedOrientation(int requestedOrientation) {}
    void clearLiveNumber() {}
    @Override public android.view.Window getWindow() { return null; }
    void renderReturn(Screen s) {
        // Mirrors cached MobileRootShell.resume(): does NOT bump generation!
        renderReturnCalls.incrementAndGet();
    }
    void restore(Screen s) {}
    boolean available(Cms.Site site) { return site != null; }
}
""",
        encoding="utf-8",
    )

    test_java = r24_src / "com/pilipala/marcomovie/R2AndR4Round2Check.java"
    test_java.parent.mkdir(parents=True, exist_ok=True)
    test_java.write_text(
        """package com.pilipala.marcomovie;

import android.content.SharedPreferences;
import java.io.File;
import java.nio.file.Files;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;

public final class R2AndR4Round2Check {
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

    private static MainActivity newHost() {
        MainActivity host = new MainActivity();
        host.prefs = new MemPrefs();
        return host;
    }

    public static void main(String[] args) throws Exception {
        // -----------------------------------------------------------------
        // 1. R2 Explicit Default Site vs Follow-Last-Selection end-to-end
        // -----------------------------------------------------------------
        File dir = Files.createTempDirectory("r2-explicit-default-").toFile();
        String origin = "https://sub.example/cfg.json";
        String raw =
                "{\\"sites\\":["
                        + "{\\"key\\":\\"first\\",\\"name\\":\\"站点一\\",\\"type\\":1,\\"api\\":\\"https://sub.example/1\\"},"
                        + "{\\"key\\":\\"second\\",\\"name\\":\\"站点二\\",\\"type\\":1,\\"api\\":\\"https://sub.example/2\\"}"
                        + "]}";
        ConfigStore cs = new ConfigStore(dir);
        cs.writeVersioned(raw, new ConfigStore.PointerSnapshot(origin, "first"));

        // 1a. Follow-last-selection (PREFERRED_SITE empty): user switched to "second" -> cold boot keeps "second"
        MainActivity hFollow = newHost();
        hFollow.prefs.edit()
                .putString(Prefs.ORIGIN, origin)
                .putString(Prefs.SELECTED_SITE, "second")
                .putString(Prefs.PREFERRED_SITE, "")
                .apply();
        ConfigStore.RecoveredState recFollow =
                cs.loadRecoveredState(
                        hFollow.prefs.getString(Prefs.ORIGIN, null),
                        hFollow.prefs.getString(Prefs.SELECTED_SITE, null));
        hFollow.config = Cms.parseConfig(recFollow.raw, recFollow.origin);
        boolean followNeedsHeal =
                !java.util.Objects.equals(recFollow.origin, hFollow.prefs.getString(Prefs.ORIGIN, null))
                        || !java.util.Objects.equals(
                                recFollow.selectedSite, hFollow.prefs.getString(Prefs.SELECTED_SITE, null));
        SourcePreferences.restoreDefault(hFollow);
        check(
                !followNeedsHeal && "second".equals(hFollow.prefs.getString(Prefs.SELECTED_SITE, "")),
                "R2 Round-2 host: follow-last-selection keeps 'second' across cold restart with zero pref revert");

        // 1b. Explicit default site (PREFERRED_SITE = first): user temporarily switched to "second" -> cold boot restores "first"
        MainActivity hExplicit = newHost();
        Cms.Config parsedCfg = Cms.parseConfig(raw, origin);
        hExplicit.config = parsedCfg;
        hExplicit.prefs.edit()
                .putString(Prefs.ORIGIN, origin)
                .putString(Prefs.SELECTED_SITE, "second")
                .putString(Prefs.PREFERRED_SITE, SourcePreferences.identity(parsedCfg.sites.get(0)))
                .apply();
        ConfigStore.RecoveredState recExplicit =
                cs.loadRecoveredState(
                        hExplicit.prefs.getString(Prefs.ORIGIN, null),
                        hExplicit.prefs.getString(Prefs.SELECTED_SITE, null));
        hExplicit.config = Cms.parseConfig(recExplicit.raw, recExplicit.origin);
        SourcePreferences.restoreDefault(hExplicit);
        check(
                "first".equals(hExplicit.prefs.getString(Prefs.SELECTED_SITE, "")),
                "R2 Round-2 host: explicit PREFERRED_SITE='first' still restores 'first' on cold restart");

        // -----------------------------------------------------------------
        // 2. R4 Scenario A: Offline A delayed init -> Back to cached Library
        //    (aCreates == 0 && aStarts == 0)
        // -----------------------------------------------------------------
        ExecutorService initPool = Executors.newFixedThreadPool(2);
        try {
            MainActivity hostA = newHost();
            MainActivity.Screen libraryScreen = new MainActivity.Screen(() -> {});
            libraryScreen.home = true;
            MainActivity.Screen playerScreenA = new MainActivity.Screen(() -> {});
            playerScreenA.player = true;
            hostA.back.push(libraryScreen);
            hostA.current = playerScreenA;
            hostA.generation = 37;
            final int ticketA = hostA.generation;
            final int sessionA = ++hostA.fullscreenPlaybackSession;

            final CountDownLatch aInInit = new CountDownLatch(1);
            final CountDownLatch releaseA = new CountDownLatch(1);
            final CountDownLatch aPosted = new CountDownLatch(1);
            final AtomicInteger aCreates = new AtomicInteger();
            final AtomicInteger aStarts = new AtomicInteger();

            initPool.execute(() -> {
                aInInit.countDown();
                try { releaseA.await(5, TimeUnit.SECONDS); } catch (InterruptedException ignored) {}
                PlaybackController.commitPreparedLaunchOnMain(
                        hostA.ui::post,
                        () -> PlaybackController.isFullscreenSessionActive(hostA, ticketA, sessionA),
                        () -> {
                            aCreates.incrementAndGet();
                            aStarts.incrementAndGet();
                            return new Object();
                        },
                        null);
                aPosted.countDown();
            });
            check(aInInit.await(5, TimeUnit.SECONDS), "R4 Round-2 A: offline video A entered delayed PLAYER_INIT");

            // User exits fullscreen back to cached Library via real PlaybackController.leavePlayback!
            PlaybackController.leavePlayback(hostA);
            check(
                    hostA.current == libraryScreen
                            && hostA.renderReturnCalls.get() == 1
                            && hostA.generation != ticketA
                            && hostA.fullscreenPlaybackSession != sessionA
                            && !PlaybackController.isFullscreenSessionActive(hostA, ticketA, sessionA),
                    "R4 Round-2 A: leavePlayback returns to cached Library and revokes ticket + session");

            releaseA.countDown();
            check(aPosted.await(5, TimeUnit.SECONDS), "R4 Round-2 A: delayed task A posted to main queue");
            hostA.ui.drain();
            check(
                    aCreates.get() == 0 && aStarts.get() == 0,
                    "R4 Round-2 A (Back to Library): stale offline A has creates=0 and starts=0");

            // -----------------------------------------------------------------
            // 3. R4 Scenario B: Offline A delayed init -> Back -> Immediately play B
            //    (aCreates == 0, aStarts == 0, bCreates == 1, bStarts == 1, bReleases == 0)
            // -----------------------------------------------------------------
            MainActivity hostB = newHost();
            MainActivity.Screen libB = new MainActivity.Screen(() -> {});
            libB.home = true;
            MainActivity.Screen playA = new MainActivity.Screen(() -> {});
            playA.player = true;
            hostB.back.push(libB);
            hostB.current = playA;
            hostB.generation = 100;
            final int tA = hostB.generation;
            final int sA = ++hostB.fullscreenPlaybackSession;

            final CountDownLatch a2InInit = new CountDownLatch(1);
            final CountDownLatch releaseA2 = new CountDownLatch(1);
            final CountDownLatch a2Posted = new CountDownLatch(1);
            final CountDownLatch bPosted = new CountDownLatch(1);
            final AtomicInteger a2Creates = new AtomicInteger();
            final AtomicInteger a2Starts = new AtomicInteger();
            final AtomicInteger bCreates = new AtomicInteger();
            final AtomicInteger bStarts = new AtomicInteger();
            final AtomicInteger bReleases = new AtomicInteger();
            final AtomicBoolean bActive = new AtomicBoolean(false);

            initPool.execute(() -> {
                a2InInit.countDown();
                try { releaseA2.await(5, TimeUnit.SECONDS); } catch (InterruptedException ignored) {}
                PlaybackController.commitPreparedLaunchOnMain(
                        hostB.ui::post,
                        () -> PlaybackController.isFullscreenSessionActive(hostB, tA, sA),
                        () -> {
                            a2Creates.incrementAndGet();
                            if (bActive.get()) bReleases.incrementAndGet();
                            a2Starts.incrementAndGet();
                            return new Object();
                        },
                        null);
                a2Posted.countDown();
            });
            check(a2InInit.await(5, TimeUnit.SECONDS), "R4 Round-2 B: offline video A entered delayed PLAYER_INIT");

            // User exits A -> returns to Library -> immediately opens B!
            PlaybackController.leavePlayback(hostB);
            check(hostB.current == libB, "R4 Round-2 B: leavePlayback returned to Library before launching B");

            MainActivity.Screen playB = new MainActivity.Screen(() -> {});
            playB.player = true;
            hostB.back.push(libB);
            hostB.current = playB;
            hostB.generation++;
            final int tB = hostB.generation;
            final int sB = ++hostB.fullscreenPlaybackSession;

            initPool.execute(() -> {
                PlaybackController.commitPreparedLaunchOnMain(
                        hostB.ui::post,
                        () -> PlaybackController.isFullscreenSessionActive(hostB, tB, sB),
                        () -> {
                            bCreates.incrementAndGet();
                            bActive.set(true);
                            bStarts.incrementAndGet();
                            return new Object();
                        },
                        null);
                bPosted.countDown();
            });
            check(bPosted.await(5, TimeUnit.SECONDS), "R4 Round-2 B: video B posted main-thread launch");
            hostB.ui.drain();
            check(bCreates.get() == 1 && bStarts.get() == 1, "R4 Round-2 B: video B created and started normally");

            // Now delayed A arrives while B is actively playing in fullscreen!
            releaseA2.countDown();
            check(a2Posted.await(5, TimeUnit.SECONDS), "R4 Round-2 B: delayed A posted to main queue");
            hostB.ui.drain();
            check(
                    a2Creates.get() == 0
                            && a2Starts.get() == 0
                            && bCreates.get() == 1
                            && bStarts.get() == 1
                            && bReleases.get() == 0
                            && bActive.get(),
                    "R4 Round-2 B (Back then play B): A creates=0/starts=0, B plays uninterrupted (creates=1/starts=1/releases=0)");
        } finally {
            initPool.shutdownNow();
        }
    }
}
""",
        encoding="utf-8",
    )

    cp = os.pathsep.join(str(p) for p in [r24_classes, *base_cp])
    subprocess.run(
        [
            JAVAC,
            "-encoding",
            "UTF-8",
            "-cp",
            cp,
            "-d",
            str(r24_classes),
            str(handler_java),
            str(context_java),
            str(activity_java),
            str(main_activity_java),
            str(test_java),
        ],
        check=True,
    )
    subprocess.run(
        [JAVA, "-Dfile.encoding=UTF-8", "-cp", cp, "com.pilipala.marcomovie.R2AndR4Round2Check"],
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

        # 4. Run R2 explicit-default & R4 fullscreen-return + rapid-play-B harness
        run_r2_explicit_default_and_r4_fullscreen_return_harness(work_dir, runtime_cp)

        print("ALL R1-R5 REGRESSION CHECKS PASSED")


if __name__ == "__main__":
    main()
