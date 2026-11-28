"""Automated regression checks for Codex Rework Priority Blockers R1-R5."""

from pathlib import Path
import os
import re
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
JAVAP = str(JDK / ("javap" + SUFFIX))


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
    public FoldableTabletopController foldableTabletop;
    public WatchHistory.Entry playingBookmark;
    public MobileEmbyLibrary.Reporter embyReporter;
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


def run_r4_reconnect_episode_switch_harness(work_dir: Path, base_cp: list[Path]) -> None:
    """Exercise REAL PlaybackController.playerPage onError(500ms IO retry) + onCompletion(450ms EOF retry) + changeEpisode(B) in BOTH return orders."""
    r4r_dir = work_dir / "r4-reconnect-r3"
    r4r_src = r4r_dir / "src"
    r4r_classes = r4r_dir / "classes"
    r4r_src.mkdir(parents=True, exist_ok=True)
    r4r_classes.mkdir(parents=True, exist_ok=True)

    stubs = {
        "android/content/Context.java": """package android.content;
public class Context {}
""",
        "android/content/ContextWrapper.java": """package android.content;
public class ContextWrapper extends Context {
    public ContextWrapper(Context base) {}
}
""",
        "android/app/Activity.java": """package android.app;
public class Activity extends android.content.Context {
    public boolean isFinishing() { return false; }
    public boolean isDestroyed() { return false; }
    public void setRequestedOrientation(int requestedOrientation) {}
    public android.view.Window getWindow() { return null; }
    public android.view.View getCurrentFocus() { return null; }
}
""",
        "android/view/View.java": """package android.view;
public class View {
    public static final int VISIBLE = 0;
    public static final int GONE = 8;
    public void setVisibility(int v) {}
    public ViewParent getParent() { return null; }
    public boolean requestFocus() { return true; }
    public void setFocusable(boolean b) {}
}
""",
        "android/view/ViewGroup.java": """package android.view;
public class ViewGroup extends View {
    public static class LayoutParams {
        public LayoutParams(int w, int h) {}
    }
    public void addView(View v, LayoutParams lp) {}
    public void removeView(View v) {}
}
""",
        "android/widget/FrameLayout.java": """package android.widget;
import android.view.*;
public class FrameLayout extends ViewGroup {
    public static class LayoutParams extends ViewGroup.LayoutParams {
        public LayoutParams(int w, int h) { super(w, h); }
    }
}
""",
        "android/widget/TextView.java": """package android.widget;
public class TextView extends android.view.View {
    public CharSequence lastText = "";
    public void setText(CharSequence s) { lastText = s; }
}
""",
        "android/os/Handler.java": """package android.os;
import java.util.*;
public class Handler {
    public final List<Runnable> delayed = new ArrayList<>();
    public final List<Long> delayedMs = new ArrayList<>();
    public final List<Runnable> immediate = new ArrayList<>();
    public void removeCallbacks(Runnable r) {}
    public boolean post(Runnable r) { immediate.add(r); return true; }
    public boolean postDelayed(Runnable r, long ms) {
        delayed.add(r);
        delayedMs.add(ms);
        return true;
    }
}
""",
        "com/pilipala/marcomovie/PluginDialogStyler.java": """package com.pilipala.marcomovie;
final class PluginDialogStyler {
    static void watch(MainActivity a) {}
}
""",
        "com/pilipala/marcomovie/PlaybackLoading.java": """package com.pilipala.marcomovie;
final class PlaybackLoading extends android.widget.FrameLayout {
    PlaybackLoading(MainActivity a) {}
    void start() {}
    void stop() {}
}
""",
        "com/pilipala/marcomovie/RequestScope.java": """package com.pilipala.marcomovie;
import java.util.concurrent.*;
final class RequestScope {
    static Future<?> submit(ExecutorService pool, Runnable task) {
        pool.execute(task);
        return new FutureTask<>(task, null);
    }
}
""",
        "com/pilipala/marcomovie/MoviePlayer.java": """package com.pilipala.marcomovie;
public class MoviePlayer {
    public int pos = 12_000;
    public int dur = 2_400_000;
    public int getCurrentPosition() { return pos; }
    public int getDuration() { return dur; }
    public void release() {}
    public static boolean isPrematureProgressiveEnd(boolean live, int pos, int dur) {
        return !live && dur > 60_000 && pos > 5_000 && pos < dur - 30_000;
    }
}
""",
        "com/pilipala/marcomovie/MainActivity.java": """package com.pilipala.marcomovie;
import android.content.SharedPreferences;
import android.widget.FrameLayout;
import android.widget.TextView;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicInteger;

public class MainActivity extends android.app.Activity {
    static final class Screen {
        final Runnable render;
        boolean player;
        Screen(Runnable render) { this.render = render; }
    }
    public final android.os.Handler ui = new android.os.Handler();
    public final List<Future<?>> pageRequests = new ArrayList<>();
    public final ArrayDeque<Screen> back = new ArrayDeque<>();
    public Screen current = new Screen(() -> {});
    public int generation = 37;
    public int fullscreenPlaybackSession = 100;
    public int playbackResolveSerial = 1;
    public boolean miniMode, changingMiniEpisode, prepared, playing, privateMode = true;
    public int resumeAt;
    public Cms.Line activeLine;
    public Cms.Episode activeEpisode;
    public MoviePlayer player;
    public WebResolver webResolver;
    public MagnetStream magnetStream;
    public PlaybackLoading playbackLoading;
    public android.view.View playbackLoadingFocus;
    public final FrameLayout root = new FrameLayout();
    public final TextView playStatus = new TextView();
    public final SeekGesture seekGesture = new SeekGesture();
    public Runnable seekPulse;
    public TvMarkerHost markerHost;
    public PlayerChrome playerChrome;
    public PlaybackControls playbackControls;
    public MobileInlinePlayer inlinePlayer;
    public TouchPlayerGesture touchPlayerGesture;
    public MobilePlayerOverlay mobilePlayerOverlay;
    public FoldableTabletopController foldableTabletop;
    public WatchHistory.Entry playingBookmark;
    public MobileEmbyLibrary.Reporter embyReporter;
    public Cms.Config config;
    public SharedPreferences prefs;
    public Cms.Episode openedEpisode;
    public final AtomicInteger openPlayerCount = new AtomicInteger();
    public final List<String> recordedHistoryEpisodes = new ArrayList<>();

    MainActivity() { current.player = true; }
    void toast(String s) {}
    void notice(String s) {}
    void clearLiveNumber() {}
    boolean isTvDevice() { return false; }
    void stopWeb() {}
    void stopMagnet() {}
    List<WatchHistory.Entry> watchHistory() { return Collections.emptyList(); }
    Future<?> trackPageRequest(Future<?> f) { return f; }
    void untrackPageRequest(Future<?> f) {}
    SourceEngine engine(Cms.Site s) {
        return new SourceEngine() {
            public boolean requiresExternalRuntime() { return false; }
            public String home() { return "{}"; }
            public String category(String id, int pg) { return "{}"; }
            public String detail(String id) { return "{}"; }
            public String search(String kw, int pg) { return "{}"; }
            public String player(String flag, String id) {
                return "{\\"url\\":\\"https://fixture.invalid/" + id + ".mp4\\"}";
            }
        };
    }
    void open(Screen s, boolean push) {
        if (s != null && s.render != null) {
            for (java.lang.reflect.Field f : s.render.getClass().getDeclaredFields()) {
                if (f.getType() == Cms.Episode.class) {
                    try {
                        f.setAccessible(true);
                        openedEpisode = (Cms.Episode) f.get(s.render);
                    } catch (ReflectiveOperationException e) {
                        throw new AssertionError(e);
                    }
                }
            }
        }
        // Simulate playerPage opening: increment generation + session and capture bookmark from activeEpisode!
        generation++;
        fullscreenPlaybackSession++;
        openPlayerCount.incrementAndGet();
        if (activeEpisode != null) {
            recordedHistoryEpisodes.add(activeEpisode.name);
        }
    }
}
""",
        "com/pilipala/marcomovie/R4ReconnectRound3Check.java": """package com.pilipala.marcomovie;

import java.lang.reflect.*;
import java.util.*;
import java.util.concurrent.*;

public final class R4ReconnectRound3Check {
    private static void check(boolean cond, String label) {
        if (!cond) throw new AssertionError("FAIL: " + label);
        System.out.println("PASS " + label);
    }

    private static void wireExecutor(final MainActivity a) throws Exception {
        Field f = PlaybackController.class.getDeclaredField("PLAYER_RESOLVE");
        f.setAccessible(true);
        // Replace only via custom pageRequests? Wait: PLAYER_RESOLVE is final; use direct invoke of
        // resolvePlayer with our stubbed RequestScope.submit capturing onto a.pageRequests?
        // Actually our stubbed RequestScope.submit calls pool.execute(task), so let's capture in RequestScope!
    }

    private static Method findRegisteredLambda(String propName) {
        String exactName = System.getProperty(propName, "").trim();
        if (exactName.isEmpty()) {
            throw new AssertionError("Missing required listener system property: " + propName);
        }
        for (Method m : PlaybackController.class.getDeclaredMethods()) {
            if (exactName.equals(m.getName())) {
                m.setAccessible(true);
                return m;
            }
        }
        throw new AssertionError("Registered listener lambda not found: " + exactName);
    }

    private static Object[] buildArgs(
            Method m, MainActivity a, MoviePlayer player, Cms.Site site, Cms.Video video, Cms.Episode ep, int what, int extra, boolean isError) {
        int g = a.generation;
        int s = a.fullscreenPlaybackSession;
        Class<?>[] params = m.getParameterTypes();
        Object[] values = new Object[params.length];
        int intCaptures = 0;
        for (int i = 0; i < params.length; i++) {
            Class<?> t = params[i];
            if (isError && i == params.length - 2) values[i] = what;
            else if (isError && i == params.length - 1) values[i] = extra;
            else if (t == int.class) values[i] = (intCaptures++ == 0 ? g : s);
            else if (t == MainActivity.class) values[i] = a;
            else if (t == MoviePlayer.class) values[i] = player;
            else if (t == Cms.Site.class) values[i] = site;
            else if (t == Cms.Video.class) values[i] = video;
            else if (t == Cms.Episode.class) values[i] = ep;
            else values[i] = null;
        }
        return values;
    }

    private static void runActivePositiveReconnect(boolean isEof) throws Exception {
        String kind = isEof ? "EOF-450ms" : "IO-500ms";
        long expectedDelay = isEof ? 450L : 500L;
        MainActivity a = new MainActivity();
        Cms.Episode epA = new Cms.Episode(); epA.name = "A"; epA.url = "id-A";
        Cms.Video video = new Cms.Video(); video.id = "v1"; video.title = "Film";
        Cms.Site site = new Cms.Site(); site.type = 3; site.key = "fixture";
        Cms.Line line = new Cms.Line(); line.name = "L1"; line.episodes.add(epA);
        a.activeLine = line;
        a.activeEpisode = epA;
        MoviePlayer player = a.player = new MoviePlayer();
        RequestScopeCapture.reset();

        Method listener = findRegisteredLambda(isEof ? "r4.completion.listener" : "r4.error.listener");
        listener.invoke(null, buildArgs(listener, a, player, site, video, epA, isEof ? 0 : 2001, 0, !isEof));
        check(
                a.ui.delayed.size() == 1 && a.ui.delayedMs.get(0) == expectedDelay,
                "R4 Round-4 Positive(" + kind + "): active A queued " + expectedDelay + "ms reconnect via registered listener");
        a.ui.delayed.get(0).run();
        check(
                RequestScopeCapture.tasks.size() == 1 && a.activeEpisode == epA,
                "R4 Round-4 Positive(" + kind + "): active A executed reconnect and requested A resolver");
        RequestScopeCapture.tasks.get(0).run();
        check(!a.ui.immediate.isEmpty(), "R4 Round-4 Positive(" + kind + "): A resolver posted UI openPlayer");
        a.ui.immediate.get(0).run();
        check(
                a.openPlayerCount.get() == 1
                        && a.activeEpisode == epA
                        && a.openedEpisode != null
                        && "https://fixture.invalid/id-A.mp4".equals(a.openedEpisode.url),
                "R4 Round-4 Positive(" + kind + "): active A reconnected and opened id-A.mp4 once");
    }

    private static void runIoReconnectScenario(boolean aRunsBeforeBResolves) throws Exception {
        String tag = aRunsBeforeBResolves ? "Order1(A-retry-before-B)" : "Order2(B-opens-before-A-retry)";
        MainActivity a = new MainActivity();
        Cms.Episode epA = new Cms.Episode(); epA.name = "A"; epA.url = "id-A";
        Cms.Episode epB = new Cms.Episode(); epB.name = "B"; epB.url = "id-B";
        Cms.Video video = new Cms.Video(); video.id = "v1"; video.title = "Film";
        Cms.Site site = new Cms.Site(); site.type = 3; site.key = "fixture";
        Cms.Line line = new Cms.Line(); line.name = "L1"; line.episodes.add(epA); line.episodes.add(epB);
        a.activeLine = line;
        a.activeEpisode = epA;
        MoviePlayer player = a.player = new MoviePlayer();

        Method onError = findRegisteredLambda("r4.error.listener");
        onError.invoke(null, buildArgs(onError, a, player, site, video, epA, 2001, 0, true));
        check(a.ui.delayed.size() == 1 && a.ui.delayedMs.get(0) == 500L, "R4 Round-3 " + tag + ": A queued 500ms IO retry");
        Runnable staleARetry = a.ui.delayed.get(0);

        // User switches in-place to async-resolved episode B!
        RequestScopeCapture.reset();
        PlaybackController.changeEpisode(a, site, video, line, epB, 5000);
        check(
                a.activeEpisode == epB
                        && a.fullscreenPlaybackSession == 101
                        && RequestScopeCapture.tasks.size() == 1,
                "R4 Round-3 " + tag + ": changeEpisode(B) bumped session and queued B resolver");

        if (aRunsBeforeBResolves) {
            // Order 1: A's 500ms retry fires WHILE B is still resolving!
            staleARetry.run();
            check(
                    a.activeEpisode == epB
                            && a.openPlayerCount.get() == 0
                            && RequestScopeCapture.tasks.size() == 1,
                    "R4 Round-3 " + tag + ": expired A retry rejected while B pending (activeEpisode stays B)");
            // Now let B's resolver finish and deliver on main thread
            RequestScopeCapture.tasks.get(0).run();
            check(!a.ui.immediate.isEmpty(), "R4 Round-3 " + tag + ": B resolver posted UI openPlayer");
            a.ui.immediate.get(0).run();
        } else {
            // Order 2: B resolves and opens FIRST, then expired A retry fires!
            RequestScopeCapture.tasks.get(0).run();
            check(!a.ui.immediate.isEmpty(), "R4 Round-3 " + tag + ": B resolver posted UI openPlayer");
            a.ui.immediate.get(0).run();
            check(
                    a.openPlayerCount.get() == 1
                            && a.activeEpisode == epB
                            && a.openedEpisode != null
                            && "https://fixture.invalid/id-B.mp4".equals(a.openedEpisode.url),
                    "R4 Round-3 " + tag + ": B opened cleanly before expired A retry");
            // Now expired A retry fires!
            staleARetry.run();
        }

        check(
                a.openPlayerCount.get() == 1
                        && a.activeEpisode == epB
                        && a.openedEpisode != null
                        && "https://fixture.invalid/id-B.mp4".equals(a.openedEpisode.url)
                        && a.recordedHistoryEpisodes.size() == 1
                        && "B".equals(a.recordedHistoryEpisodes.get(0)),
                "R4 Round-3 " + tag + ": URL, activeEpisode, and history/resume ALL point to B, and B started exactly once");
    }

    private static void runEofReconnectScenario(boolean aRunsBeforeBResolves) throws Exception {
        String tag = aRunsBeforeBResolves ? "EOF-Order1(A-before-B)" : "EOF-Order2(B-before-A)";
        MainActivity a = new MainActivity();
        Cms.Episode epA = new Cms.Episode(); epA.name = "A"; epA.url = "id-A";
        Cms.Episode epB = new Cms.Episode(); epB.name = "B"; epB.url = "id-B";
        Cms.Video video = new Cms.Video(); video.id = "v1"; video.title = "Film";
        Cms.Site site = new Cms.Site(); site.type = 3; site.key = "fixture";
        Cms.Line line = new Cms.Line(); line.name = "L1"; line.episodes.add(epA); line.episodes.add(epB);
        a.activeLine = line;
        a.activeEpisode = epA;
        MoviePlayer player = a.player = new MoviePlayer();

        Method onCompletion = findRegisteredLambda("r4.completion.listener");
        onCompletion.invoke(null, buildArgs(onCompletion, a, player, site, video, epA, 0, 0, false));
        check(a.ui.delayed.size() == 1 && a.ui.delayedMs.get(0) == 450L, "R4 Round-4 " + tag + ": A queued 450ms EOF reconnect");
        Runnable staleEof = a.ui.delayed.get(0);

        RequestScopeCapture.reset();
        PlaybackController.changeEpisode(a, site, video, line, epB, 5000);
        if (aRunsBeforeBResolves) {
            staleEof.run();
            check(
                    a.activeEpisode == epB && RequestScopeCapture.tasks.size() == 1,
                    "R4 Round-4 " + tag + ": expired A 450ms EOF reconnect rejected while B pending");
            RequestScopeCapture.tasks.get(0).run();
            a.ui.immediate.get(0).run();
        } else {
            RequestScopeCapture.tasks.get(0).run();
            a.ui.immediate.get(0).run();
            staleEof.run();
        }
        check(
                a.openPlayerCount.get() == 1
                        && a.activeEpisode == epB
                        && a.openedEpisode != null
                        && "https://fixture.invalid/id-B.mp4".equals(a.openedEpisode.url)
                        && a.recordedHistoryEpisodes.size() == 1
                        && "B".equals(a.recordedHistoryEpisodes.get(0)),
                "R4 Round-4 " + tag + ": URL, activeEpisode, and history/resume ALL point to B, and B started once");
    }

    public static void main(String[] args) throws Exception {
        runActivePositiveReconnect(false);
        runActivePositiveReconnect(true);
        runIoReconnectScenario(true);
        runIoReconnectScenario(false);
        runEofReconnectScenario(true);
        runEofReconnectScenario(false);
    }
}
""",
        "com/pilipala/marcomovie/RequestScopeCapture.java": """package com.pilipala.marcomovie;
import java.util.*;
final class RequestScopeCapture {
    static final List<Runnable> tasks = new ArrayList<>();
    static void reset() { tasks.clear(); }
}
""",
    }
    stubs["com/pilipala/marcomovie/RequestScope.java"] = """package com.pilipala.marcomovie;
import java.util.concurrent.*;
final class RequestScope {
    static Future<?> submit(ExecutorService pool, Runnable task) {
        RequestScopeCapture.tasks.add(task);
        return new FutureTask<>(task, null);
    }
}
"""

    src_files = []
    for rel, content in stubs.items():
        p = r4r_src / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(content, encoding="utf-8")
        src_files.append(str(p))

    def resolve_registered_player_listener(setter_name: str, required_body_call: str | None = None) -> str:
        """Inspect PlaybackController bytecode BootstrapMethods to bind the EXACT lambda passed to MoviePlayer.<setter_name>."""
        listing = subprocess.check_output(
            [
                JAVAP,
                "-J-Duser.language=en",
                "-v",
                "-p",
                "-c",
                "-classpath",
                str(base_cp[0]),
                "com.pilipala.marcomovie.PlaybackController",
            ],
            encoding="utf-8",
            errors="replace",
        )
        lines = listing.splitlines()
        bsm_targets: dict[int, str] = {}
        in_bsm = False
        cur_bsm: int | None = None
        for line in lines:
            if line.strip() == "BootstrapMethods:":
                in_bsm = True
                continue
            if in_bsm:
                m_idx = re.match(r"^\s+(\d+):\s+#\d+\s+REF_invokeStatic", line)
                if m_idx:
                    cur_bsm = int(m_idx.group(1))
                    continue
                if cur_bsm is not None:
                    m_ref = re.search(
                        r"REF_invokeStatic\s+com/pilipala/marcomovie/PlaybackController\.([^:\s]+):",
                        line,
                    )
                    if m_ref:
                        bsm_targets[cur_bsm] = m_ref.group(1)
        matched_lambdas: list[str] = []
        for i, line in enumerate(lines):
            if f"Method com/pilipala/marcomovie/MoviePlayer.{setter_name}:" in line:
                for back in range(1, 4):
                    if i - back >= 0:
                        m_ind = re.search(r"invokedynamic\s+#\d+,\s*0\s*//\s*InvokeDynamic\s+#(\d+):", lines[i - back])
                        if m_ind:
                            target = bsm_targets.get(int(m_ind.group(1)))
                            if target:
                                matched_lambdas.append(target)
                            break
        if len(matched_lambdas) != 1:
            raise AssertionError(
                f"Expected exactly 1 registered {setter_name} lambda in PlaybackController, got {matched_lambdas}"
            )
        chosen = matched_lambdas[0]
        if required_body_call:
            in_chosen = False
            saw_call = False
            for line in lines:
                if f" {chosen}(" in line and not line.startswith("        "):
                    in_chosen = True
                    continue
                if in_chosen:
                    if line.startswith("  private static ") or line.startswith("  static ") or line.startswith("  public "):
                        break
                    if required_body_call in line:
                        saw_call = True
                        break
            if not saw_call:
                raise AssertionError(
                    f"Resolved {setter_name} lambda {chosen} did not call expected {required_body_call}"
                )
        return chosen

    completion_lambda = resolve_registered_player_listener(
        "setOnCompletionListener", "MoviePlayer.isPrematureProgressiveEnd:"
    )
    error_lambda = resolve_registered_player_listener("setOnErrorListener")
    print(
        f"PASS R4 Round-4 bytecode binding: completion={completion_lambda}, error={error_lambda}",
        flush=True,
    )

    cp = os.pathsep.join(str(p) for p in [r4r_classes, *base_cp])
    subprocess.run(
        [JAVAC, "-encoding", "UTF-8", "-cp", cp, "-d", str(r4r_classes), *src_files],
        check=True,
    )
    subprocess.run(
        [
            JAVA,
            "-Dfile.encoding=UTF-8",
            f"-Dr4.completion.listener={completion_lambda}",
            f"-Dr4.error.listener={error_lambda}",
            "-cp",
            cp,
            "com.pilipala.marcomovie.R4ReconnectRound3Check",
        ],
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

        # 2b. Run Round-3 real Runtime.getRuntime().halt(35) child JVMs for R2 local SAF JSON
        #     shared-keys AND ~15.57 MiB quote-/backslash-/newline-heavy JS config!
        for mode in ("local", "large"):
            r3_halt_dir = work_dir / f"r2-r3-halt-{mode}"
            r3_halt_dir.mkdir(parents=True, exist_ok=True)
            # Pre-seed legacy config.json on disk for subscription A
            (r3_halt_dir / "config.json").write_text(
                '{"sites":[{"key":"first","name":"A first","type":1,"api":"https://catalog.invalid/A/first"},'
                '{"key":"second","name":"A second","type":1,"api":"https://catalog.invalid/A/second"}]}',
                encoding="utf-8",
            )
            halt_proc = subprocess.run(
                [
                    JAVA,
                    "-Xmx1g",
                    "-Dfile.encoding=UTF-8",
                    "-cp",
                    cp_str,
                    "com.pilipala.marcomovie.ReworkR1ToR5Checks",
                    "--r2-r3-halt",
                    str(r3_halt_dir),
                    mode,
                ],
                cwd=ROOT,
                timeout=60,
            )
            if halt_proc.returncode != 35:
                raise AssertionError(
                    f"R2 Round-3 child ({mode}) expected halt exit 35, got {halt_proc.returncode}"
                )
            subprocess.run(
                [
                    JAVA,
                    "-Xmx1g",
                    "-Dfile.encoding=UTF-8",
                    "-cp",
                    cp_str,
                    "com.pilipala.marcomovie.ReworkR1ToR5Checks",
                    "--r2-r3-cold",
                    str(r3_halt_dir),
                    mode,
                ],
                cwd=ROOT,
                check=True,
                timeout=60,
            )

        # 3. Run R3 real MobileInlinePlayer.onActivityStop buffering harness
        run_r3_buffered_stop_harness(classes_dir, work_dir, runtime_cp)

        # 4. Run R2 explicit-default & R4 fullscreen-return + rapid-play-B harness
        run_r2_explicit_default_and_r4_fullscreen_return_harness(work_dir, runtime_cp)

        # 5. Run R4 Round-3 weak-network reconnect vs episode switch B harness (both return orders + EOF)
        run_r4_reconnect_episode_switch_harness(work_dir, runtime_cp)

        print("ALL R1-R5 REGRESSION CHECKS PASSED")


if __name__ == "__main__":
    main()
