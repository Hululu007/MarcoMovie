#!/usr/bin/env python3
"""
JVM verification of production ImageLoader.loadPosterBitmap / cancelScope / unbindBitmapTarget
for R17 P2 (search poster task cancellation, same-URL/same-spec coalescing, shared-scope survival,
scroll reuse unbinding, slow-return stale drop, and cancel-before-enqueue ordering).

Extracts the real production methods directly from android-tv/src/main/java/com/pilipala/marcomovie/ImageLoader.java
and compiles them with real RequestScope.java + ImageDecodePolicy.java against minimal Android/IO fakes.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

REPO = Path(__file__).resolve().parents[2]
SRC_DIR = REPO / "android-tv/src/main/java/com/pilipala/marcomovie"

FIXTURE_TEMPLATE = r'''package com.pilipala.marcomovie;

import java.lang.ref.WeakReference;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicInteger;

final class TvArtworkLoaderChecks {
    private static final int TAG_BIND_TOKEN = 0x5f494d42;
    private static final int TAG_SCOPE_TOKEN = 0x5f494d53;
    private static final int TAG_INFLIGHT_KEY = 0x5f494d4b;

    private static final AtomicInteger NEXT_BIND_TOKEN = new AtomicInteger(1);
    private static final AtomicInteger NEXT_SCOPE_TOKEN = new AtomicInteger(1);
    private static final Set<Integer> CANCELLED_SCOPES =
            Collections.newSetFromMap(new ConcurrentHashMap<Integer, Boolean>());

    static final List<String> fetched = new ArrayList<>();
    static final Map<String, Runnable> onFetchHooks = new HashMap<>();

    static class ImageView {
        Object tag;
        void setImageBitmap(Bitmap b) {}
        void setImageDrawable(Object d) {}
        Object getTag() { return tag; }
        Object getTag(int k) { return null; }
        void setTag(Object t) { tag = t; }
        void setTag(int k, Object v) {}
        boolean isAttachedToWindow() { return true; }
        Object getParent() { return this; }
    }

    static class Bitmap {
        enum Config { RGB_565 }
        final String label;
        boolean recycled;
        Bitmap(String label) { this.label = label; }
        boolean isRecycled() { return recycled; }
        void recycle() { recycled = true; }
    }

    static class BitmapFactory {
        static class Options {
            boolean inJustDecodeBounds;
            int outWidth = 320, outHeight = 480, inSampleSize;
            Bitmap.Config inPreferredConfig;
        }
        static Bitmap decodeByteArray(byte[] bytes, int off, int n, Options opt) {
            if (opt != null && opt.inJustDecodeBounds) return null;
            return new Bitmap(new String(bytes));
        }
    }

    static class Cms {
        static class ImageRequest { String url; }
        static boolean isHttp(String s) { return s != null && s.startsWith("https://"); }
        static String normalizeHttp(String s) { return s; }
        static ImageRequest imageRequest(String s) { ImageRequest r = new ImageRequest(); r.url = s; return r; }
    }

    static class Dispatcher {
        final List<Runnable> queue = new ArrayList<>();
        boolean defer = false;
        void post(Runnable r) {
            if (defer) queue.add(r);
            else r.run();
        }
        void flush() {
            List<Runnable> batch = new ArrayList<>(queue);
            queue.clear();
            for (Runnable r : batch) r.run();
        }
    }

    static class HeldExecutor extends ThreadPoolExecutor {
        final List<Runnable> pending = new ArrayList<>();
        HeldExecutor() {
            super(3, 3, 25, TimeUnit.SECONDS, new LinkedBlockingQueue<>());
        }
        @Override
        public void execute(Runnable r) {
            pending.add(r);
        }
        void drain() {
            List<Runnable> snap = new ArrayList<>(pending);
            pending.clear();
            for (Runnable r : snap) r.run();
        }
    }

    static class MainActivity {
        int generation = 1;
        HeldExecutor artwork = new HeldExecutor();
        List<Future<?>> artworkRequests = new ArrayList<>();
        Dispatcher ui = new Dispatcher();
        boolean isTvDevice() { return true; }
        boolean isFinishing() { return false; }
    }

    interface BitmapCallback { void onBitmap(Bitmap bitmap); }

    static String normalizeArtworkAddress(String s) { return s; }
    static boolean isLocalArtworkAddress(String s) { return false; }
    static Bitmap cachedPosterBitmap(MainActivity a, String s, int w, int h) { return null; }
    static String upgradePosterUrl(String s, boolean detail) { return s; }
    static byte[] readLocalArtworkBytes(MainActivity a, String s) { throw new AssertionError(); }
    static byte[] fetchPosterBytesWithFallback(MainActivity a, Cms.ImageRequest req, String url, String upgraded, boolean detail) {
        String name = url.substring(url.lastIndexOf('/') + 1);
        fetched.add(name);
        Runnable hook = onFetchHooks.remove(name);
        if (hook != null) hook.run();
        return name.getBytes();
    }
    static Bitmap downscaleTvCardPosterIfOversized(MainActivity a, Bitmap b, int w, int h) { return b; }
    static void putCachedBitmap(MainActivity a, String normalized, String key, Bitmap b) {}
    static boolean isTargetStillBound(ImageView target, String address, Waiter w) { return false; }

    /* PRODUCTION_METHODS */

    private static void resetState() {
        CANCELLED_SCOPES.clear();
        synchronized (IN_FLIGHT) {
            IN_FLIGHT.clear();
            OWNER_BIND_TOKENS.clear();
        }
        fetched.clear();
        onFetchHooks.clear();
    }

    private static void check(boolean cond, String msg) {
        if (!cond) throw new AssertionError("FAILED: " + msg);
    }

    private static String jsonArr(List<String> xs) {
        StringBuilder sb = new StringBuilder("[");
        for (int i = 0; i < xs.size(); i++) {
            if (i > 0) sb.append(",");
            sb.append("\"").append(xs.get(i).replace("\"", "\\\"")).append("\"");
        }
        return sb.append("]").toString();
    }

    public static void main(String[] args) {
        // 1. Cold cache + same-URL multi-card (6 cards same URL+spec -> 1 fetch, all 6 receive bitmap!)
        resetState();
        MainActivity a1 = new MainActivity();
        List<String> paints1 = new ArrayList<>();
        for (int i = 0; i < 6; i++) {
            final int idx = i;
            loadPosterBitmap(a1, "https://fixture.invalid/same", 320, 480, a1.generation, 10, new Object(),
                    b -> paints1.add("card" + idx + ":" + b.label));
        }
        check(a1.artwork.pending.size() == 1, "expected 1 coalesced job for 6 same-URL cards, got " + a1.artwork.pending.size());
        check(inFlightCount() == 1, "expected inFlightCount==1");
        a1.artwork.drain();
        check(fetched.equals(Collections.singletonList("same")), "expected 1 fetch for 6 same-URL cards, got " + fetched);
        check(paints1.size() == 6, "expected all 6 cards painted, got " + paints1.size());

        // 2. Rapid query change: 6 queued cards for old scope 1 -> cancelScope(a,1) -> new scope 2 runs FIRST with 0 old fetches!
        resetState();
        MainActivity a2 = new MainActivity();
        List<String> paints2 = new ArrayList<>();
        for (int i = 0; i < 6; i++) {
            loadPosterBitmap(a2, "https://fixture.invalid/old", 320, 480, a2.generation, 1, new Object(),
                    b -> paints2.add("old:" + b.label));
        }
        check(a2.artwork.pending.size() == 1, "expected 1 coalesced old task");
        Future<?> oldFuture = a2.artworkRequests.get(0);
        cancelScope(a2, 1);
        check(oldFuture.isCancelled(), "expected queued old task cancelled before start");
        check(inFlightCount() == 0, "expected inFlightCount==0 after cancelling exclusive scope");
        loadPosterBitmap(a2, "https://fixture.invalid/new", 320, 480, a2.generation, 2, new Object(),
                b -> paints2.add("new:" + b.label));
        a2.artwork.drain();
        check(fetched.equals(Collections.singletonList("new")), "old exclusive task must not fetch; got " + fetched);
        check(paints2.equals(Collections.singletonList("new:new")), "only new scope paints; got " + paints2);

        // 3. Shared URL across two scopes: scope 1 cancelled while scope 2 still subscribes -> task preserved & only scope 2 paints!
        resetState();
        MainActivity a3 = new MainActivity();
        List<String> paints3 = new ArrayList<>();
        loadPosterBitmap(a3, "https://fixture.invalid/shared", 320, 480, a3.generation, 1, new Object(),
                b -> paints3.add("s1:" + b.label));
        loadPosterBitmap(a3, "https://fixture.invalid/shared", 320, 480, a3.generation, 2, new Object(),
                b -> paints3.add("s2:" + b.label));
        check(a3.artwork.pending.size() == 1, "expected 1 shared task");
        Future<?> sharedFuture = a3.artworkRequests.get(0);
        cancelScope(a3, 1);
        check(!sharedFuture.isCancelled(), "shared task must NOT cancel while scope 2 still subscribes");
        check(inFlightCount() == 1, "shared task must stay in IN_FLIGHT");
        a3.artwork.drain();
        check(fetched.equals(Collections.singletonList("shared")), "shared task must fetch once; got " + fetched);
        check(paints3.equals(Collections.singletonList("s2:shared")), "only surviving scope 2 paints; got " + paints3);

        // 4. Scroll reuse (rebind before start): ownerA binds urlA, immediately rebounds to urlB -> exclusive urlA cancelled!
        resetState();
        MainActivity a4 = new MainActivity();
        List<String> paints4 = new ArrayList<>();
        Object holderViewA = new Object();
        loadPosterBitmap(a4, "https://fixture.invalid/scroll_old", 320, 480, a4.generation, 5, holderViewA,
                b -> paints4.add("scroll_old:" + b.label));
        Future<?> scrollOldFuture = a4.artworkRequests.get(0);
        loadPosterBitmap(a4, "https://fixture.invalid/scroll_new", 320, 480, a4.generation, 5, holderViewA,
                b -> paints4.add("scroll_new:" + b.label));
        check(scrollOldFuture.isCancelled(), "exclusive scroll_old must cancel when owner rebounds");
        a4.artwork.drain();
        check(fetched.equals(Collections.singletonList("scroll_new")), "only scroll_new fetches; got " + fetched);
        check(paints4.equals(Collections.singletonList("scroll_new:scroll_new")), "only scroll_new paints; got " + paints4);

        // 5. Slow-returning in-flight image after scroll recycle/rebind: stale UI callback dropped cleanly!
        resetState();
        MainActivity a5 = new MainActivity();
        List<String> paints5 = new ArrayList<>();
        Object holderViewB = new Object();
        Object survivorCard = new Object();
        loadPosterBitmap(a5, "https://fixture.invalid/slow_img", 320, 480, a5.generation, 6, holderViewB,
                b -> paints5.add("recycled_holder:" + b.label));
        loadPosterBitmap(a5, "https://fixture.invalid/slow_img", 320, 480, a5.generation, 6, survivorCard,
                b -> paints5.add("survivor_card:" + b.label));
        a5.ui.defer = true;
        onFetchHooks.put("slow_img", () -> unbindBitmapTarget(a5, holderViewB));
        a5.artwork.drain();
        a5.ui.flush();
        check(fetched.equals(Collections.singletonList("slow_img")), "slow_img fetched once; got " + fetched);
        check(paints5.equals(Collections.singletonList("survivor_card:slow_img")),
                "recycled holder callback must be dropped while survivor paints; got " + paints5);

        // 6. Cancel-before-enqueue AND distinct-spec separation (320x480 vs 640x960)!
        resetState();
        MainActivity a6 = new MainActivity();
        List<String> paints6 = new ArrayList<>();
        cancelScope(a6, 99);
        loadPosterBitmap(a6, "https://fixture.invalid/precancelled", 320, 480, a6.generation, 99, new Object(),
                b -> paints6.add("precancelled"));
        check(a6.artwork.pending.isEmpty() && inFlightCount() == 0, "cancel-before-enqueue must enqueue 0 jobs");
        loadPosterBitmap(a6, "https://fixture.invalid/multispec", 320, 480, a6.generation, 100, new Object(),
                b -> paints6.add("small:" + b.label));
        loadPosterBitmap(a6, "https://fixture.invalid/multispec", 640, 960, a6.generation, 100, new Object(),
                b -> paints6.add("large:" + b.label));
        check(a6.artwork.pending.size() == 2, "distinct specs must not collapse into 1 decode size");
        a6.artwork.drain();
        check(fetched.size() == 2 && paints6.size() == 2, "both specs fetched & painted");

        System.out.println("{"
                + "\"ok\":true,"
                + "\"scenarios\":6,"
                + "\"same_url_6cards_fetches\":1,"
                + "\"rapid_query_old_cancelled_before_start\":true,"
                + "\"rapid_query_fetches\":[\"new\"],"
                + "\"shared_scope_preserved\":true,"
                + "\"scroll_rebind_old_cancelled\":true,"
                + "\"slow_return_recycled_dropped\":true,"
                + "\"cancel_before_enqueue_jobs\":0,"
                + "\"distinct_spec_jobs\":2"
                + "}");
    }
}
'''


def extract_slice(src: str, start_marker: str, end_marker: str) -> str:
    s = src.index(start_marker)
    e = src.index(end_marker, s)
    return src[s:e].strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=None)
    args = parser.parse_args()

    loader_src = (SRC_DIR / "ImageLoader.java").read_text("utf-8")
    search_src = (SRC_DIR / "GlobalSearchScreen.java").read_text("utf-8")
    if "ImageLoader.unbindBitmapTarget(holder.posterArt)" not in search_src:
        raise SystemExit("GlobalSearchScreen must unbind recycled/rebound posterArt targets")
    if "ImageLoader.loadPosterBitmap(\n" not in search_src or "holder.posterArt," not in search_src:
        raise SystemExit("GlobalSearchScreen must pass scope & holder.posterArt to ImageLoader.loadPosterBitmap")

    pieces = [
        extract_slice(loader_src, "private static final class Waiter {", "private static final ConcurrentHashMap<String, String> LAST_CACHE_KEY_BY_URL"),
        extract_slice(loader_src, "static boolean isScopeCancelled(", "static void unbind("),
        extract_slice(loader_src, "static void unbindBitmapTarget(", "static void cancel(MainActivity a)"),
        extract_slice(loader_src, "static void loadPosterBitmap(", "static void poster(MainActivity a"),
    ]
    java_src = FIXTURE_TEMPLATE.replace("/* PRODUCTION_METHODS */", "\n\n".join(pieces))

    jdk = Path(os.environ.get("MARCOMOVIE_JDK", os.environ.get("JAVA_HOME", "")))
    exe = ".exe" if os.name == "nt" else ""
    javac = str(jdk / "bin" / f"javac{exe}") if jdk.is_dir() else "javac"
    java = str(jdk / "bin" / f"java{exe}") if jdk.is_dir() else "java"

    with tempfile.TemporaryDirectory(prefix="marco-r17-art-checks-") as td:
        folder = Path(td)
        (folder / "TvArtworkLoaderChecks.java").write_text(java_src, encoding="utf-8")
        shutil.copy2(SRC_DIR / "RequestScope.java", folder / "RequestScope.java")
        shutil.copy2(SRC_DIR / "ImageDecodePolicy.java", folder / "ImageDecodePolicy.java")
        cat = folder / "CatPawHost.java"
        cat.write_text("package com.pilipala.catpaw; public class CatPawHost { public CatPawHost(Object a){} public String resolve(String s){return s;} }", encoding="utf-8")
        glass = folder / "GlassworkSurface.java"
        glass.write_text("package com.pilipala.glass; public class GlassworkSurface { public static void invalidateBackdrop(Object v){} }", encoding="utf-8")
        subprocess.run(
            [javac, "-encoding", "UTF-8", "-d", str(folder),
             str(folder / "TvArtworkLoaderChecks.java"),
             str(folder / "RequestScope.java"),
             str(folder / "ImageDecodePolicy.java"),
             str(cat),
             str(glass)],
            check=True,
        )
        out_raw = subprocess.check_output(
            [java, "-cp", str(folder), "com.pilipala.marcomovie.TvArtworkLoaderChecks"],
            text=True, encoding="utf-8",
        ).strip()
    data = json.loads(out_raw)
    if not data.get("ok"):
        raise SystemExit(f"Artwork loader checks failed: {data}")
    if args.out is not None:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"ALL PASS (6 TV artwork loader cancellation & coalescing scenarios): {json.dumps(data)}")


if __name__ == "__main__":
    main()
