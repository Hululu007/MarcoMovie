package com.pilipala.marcomovie;

import android.content.ComponentCallbacks2;
import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.RectF;
import android.view.View;
import android.widget.ImageView;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.lang.ref.WeakReference;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.Iterator;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.Future;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * Bounded asynchronous poster/artwork loader, memory cache trimming, and background atmosphere
 * rendering extracted from {@link MainActivity}.
 */
final class ImageLoader {
    private static final int TAG_BIND_TOKEN = 0x5f494d42; // "IMB"
    private static final int TAG_SCOPE_TOKEN = 0x5f494d53; // "IMS"
    private static final int TAG_INFLIGHT_KEY = 0x5f494d4b; // "IMK"

    private static final AtomicInteger NEXT_BIND_TOKEN = new AtomicInteger(1);
    private static final AtomicInteger NEXT_SCOPE_TOKEN = new AtomicInteger(1);
    private static final Set<Integer> CANCELLED_SCOPES =
            java.util.Collections.newSetFromMap(new ConcurrentHashMap<Integer, Boolean>());

    private static final class Waiter {
        final WeakReference<ImageView> viewRef;
        final Object ownerToken;
        final BitmapCallback callback;
        final int bindToken;
        final int scopeToken;
        final int ticket;

        Waiter(ImageView view, int bindToken, int scopeToken) {
            this.viewRef = new WeakReference<>(view);
            this.ownerToken = null;
            this.callback = null;
            this.bindToken = bindToken;
            this.scopeToken = scopeToken;
            this.ticket = 0;
        }

        Waiter(
                Object ownerToken,
                BitmapCallback callback,
                int bindToken,
                int scopeToken,
                int ticket) {
            this.viewRef = null;
            this.ownerToken = ownerToken;
            this.callback = callback;
            this.bindToken = bindToken;
            this.scopeToken = scopeToken;
            this.ticket = ticket;
        }

        boolean isDead() {
            return callback == null && (viewRef == null || viewRef.get() == null);
        }
    }

    private static final class InFlightEntry {
        final java.util.List<Waiter> waiters = new java.util.ArrayList<>(2);
        volatile Future<?> future;
    }

    private static final java.util.Map<String, InFlightEntry> IN_FLIGHT = new java.util.HashMap<>();
    private static final java.util.WeakHashMap<Object, Integer> OWNER_BIND_TOKENS =
            new java.util.WeakHashMap<>();
    private static final ConcurrentHashMap<String, String> LAST_CACHE_KEY_BY_URL =
            new ConcurrentHashMap<>();
    private static final java.util.concurrent.ExecutorService DISK_DECODE_POOL =
            createDiskDecodePool();

    private static java.util.concurrent.ExecutorService createDiskDecodePool() {
        java.util.concurrent.ThreadPoolExecutor pool =
                new java.util.concurrent.ThreadPoolExecutor(
                        2,
                        2,
                        20L,
                        java.util.concurrent.TimeUnit.SECONDS,
                        new java.util.concurrent.LinkedBlockingQueue<Runnable>(),
                        r -> {
                            Thread t = new Thread(r, "artwork-disk");
                            t.setDaemon(true);
                            return t;
                        });
        pool.allowCoreThreadTimeOut(true);
        return pool;
    }

    private static void putCachedBitmap(
            MainActivity a, String normalizedUrl, String key, Bitmap bitmap) {
        if (a == null || a.images == null || key == null || bitmap == null) return;
        a.images.put(key, bitmap);
        if (normalizedUrl != null && !normalizedUrl.isEmpty()) {
            if (LAST_CACHE_KEY_BY_URL.size() > 512) {
                LAST_CACHE_KEY_BY_URL.clear();
            }
            LAST_CACHE_KEY_BY_URL.put(normalizedUrl, key);
        }
    }

    private ImageLoader() {}

    static int newScope() {
        int token = NEXT_SCOPE_TOKEN.incrementAndGet();
        if (token <= 0) {
            NEXT_SCOPE_TOKEN.set(1);
            token = NEXT_SCOPE_TOKEN.incrementAndGet();
        }
        return token;
    }

    static boolean isScopeCancelled(int scopeToken) {
        return scopeToken != 0 && CANCELLED_SCOPES.contains(Integer.valueOf(scopeToken));
    }

    static int inFlightCount() {
        synchronized (IN_FLIGHT) {
            return IN_FLIGHT.size();
        }
    }

    static void unbind(ImageView image) {
        if (image == null) return;
        Object keyObj = image.getTag(TAG_INFLIGHT_KEY);
        image.setTag(null);
        image.setTag(TAG_BIND_TOKEN, null);
        image.setTag(TAG_SCOPE_TOKEN, null);
        image.setTag(TAG_INFLIGHT_KEY, null);
        try {
            image.setImageDrawable(null);
        } catch (Throwable ignored) {
        }
        if (keyObj instanceof String) {
            Future<?> cancelFuture = null;
            synchronized (IN_FLIGHT) {
                InFlightEntry entry = IN_FLIGHT.get(keyObj);
                if (entry != null) {
                    for (Iterator<Waiter> it = entry.waiters.iterator(); it.hasNext(); ) {
                        Waiter w = it.next();
                        if (w.isDead() || (w.viewRef != null && w.viewRef.get() == image)) {
                            it.remove();
                        }
                    }
                    if (entry.waiters.isEmpty()) {
                        IN_FLIGHT.remove(keyObj);
                        cancelFuture = entry.future;
                    }
                }
            }
            if (cancelFuture != null) cancelFuture.cancel(true);
        }
    }

    /**
     * Unsubscribes a reusable Canvas/callback target (such as a recycled search poster card) from
     * any queued or in-flight {@link #loadPosterBitmap} request, cancelling the underlying task if
     * it was the last active subscriber.
     */
    static void unbindBitmapTarget(Object ownerToken) {
        unbindBitmapTarget(null, ownerToken);
    }

    static void unbindBitmapTarget(MainActivity a, Object ownerToken) {
        if (ownerToken == null) return;
        java.util.List<Future<?>> toCancel = new java.util.ArrayList<>();
        synchronized (IN_FLIGHT) {
            OWNER_BIND_TOKENS.remove(ownerToken);
            for (Iterator<Map.Entry<String, InFlightEntry>> it = IN_FLIGHT.entrySet().iterator();
                    it.hasNext(); ) {
                InFlightEntry entry = it.next().getValue();
                for (Iterator<Waiter> wit = entry.waiters.iterator(); wit.hasNext(); ) {
                    Waiter w = wit.next();
                    if (w.isDead() || w.ownerToken == ownerToken) {
                        wit.remove();
                    }
                }
                if (entry.waiters.isEmpty()) {
                    if (entry.future != null) toCancel.add(entry.future);
                    it.remove();
                }
            }
        }
        for (Future<?> f : toCancel) f.cancel(true);
        if (a != null && !toCancel.isEmpty()) {
            for (Iterator<Future<?>> it = a.artworkRequests.iterator(); it.hasNext(); ) {
                Future<?> f = it.next();
                if (f.isDone() || f.isCancelled()) it.remove();
            }
            if (a.artwork instanceof ThreadPoolExecutor) {
                ((ThreadPoolExecutor) a.artwork).purge();
            }
        }
    }

    private static boolean hasActiveWaiters(
            String key, InFlightEntry owned, int currentGeneration) {
        synchronized (IN_FLIGHT) {
            if (IN_FLIGHT.get(key) != owned) return false;
            for (Iterator<Waiter> it = owned.waiters.iterator(); it.hasNext(); ) {
                Waiter w = it.next();
                if (w.isDead()
                        || isScopeCancelled(w.scopeToken)
                        || (w.ticket != 0 && w.ticket != currentGeneration)) {
                    it.remove();
                    continue;
                }
                if (w.callback != null && w.ownerToken != null) {
                    Integer curBind = OWNER_BIND_TOKENS.get(w.ownerToken);
                    if (curBind == null || curBind.intValue() != w.bindToken) {
                        it.remove();
                    }
                }
            }
            if (owned.waiters.isEmpty()) {
                IN_FLIGHT.remove(key);
                return false;
            }
            return true;
        }
    }

    private static boolean isBitmapWaiterStillValid(Waiter waiter, int currentGeneration) {
        if (waiter == null || waiter.callback == null) return false;
        if (isScopeCancelled(waiter.scopeToken)) return false;
        if (waiter.ticket != 0 && waiter.ticket != currentGeneration) return false;
        if (waiter.ownerToken != null) {
            synchronized (IN_FLIGHT) {
                Integer curBind = OWNER_BIND_TOKENS.get(waiter.ownerToken);
                if (curBind == null || curBind.intValue() != waiter.bindToken) return false;
            }
        }
        return true;
    }

    static void cancelScope(MainActivity a, int scopeToken) {
        if (scopeToken == 0) return;
        if (CANCELLED_SCOPES.size() > 128) CANCELLED_SCOPES.clear();
        CANCELLED_SCOPES.add(Integer.valueOf(scopeToken));
        java.util.List<Future<?>> toCancel = new java.util.ArrayList<>();
        synchronized (IN_FLIGHT) {
            for (Iterator<Map.Entry<String, InFlightEntry>> it = IN_FLIGHT.entrySet().iterator();
                    it.hasNext(); ) {
                InFlightEntry entry = it.next().getValue();
                for (Iterator<Waiter> wit = entry.waiters.iterator(); wit.hasNext(); ) {
                    Waiter w = wit.next();
                    if (w.isDead() || w.scopeToken == scopeToken) {
                        if (w.ownerToken != null) {
                            Integer curBind = OWNER_BIND_TOKENS.get(w.ownerToken);
                            if (curBind != null && curBind.intValue() == w.bindToken) {
                                OWNER_BIND_TOKENS.remove(w.ownerToken);
                            }
                        }
                        wit.remove();
                    }
                }
                if (entry.waiters.isEmpty()) {
                    if (entry.future != null) toCancel.add(entry.future);
                    it.remove();
                }
            }
        }
        for (Future<?> f : toCancel) f.cancel(true);
        if (a != null) {
            for (Iterator<Future<?>> it = a.artworkRequests.iterator(); it.hasNext(); ) {
                Future<?> f = it.next();
                if (f.isDone() || f.isCancelled()) it.remove();
            }
            if (a.artwork instanceof ThreadPoolExecutor) {
                ((ThreadPoolExecutor) a.artwork).purge();
            }
        }
    }

    static void cancel(MainActivity a) {
        synchronized (IN_FLIGHT) {
            IN_FLIGHT.clear();
            OWNER_BIND_TOKENS.clear();
        }
        for (Future<?> request : a.artworkRequests) request.cancel(true);
        a.artworkRequests.clear();
        if (a.artwork instanceof ThreadPoolExecutor) {
            ((ThreadPoolExecutor) a.artwork).purge();
        }
    }

    static void trimMemory(MainActivity a, int level) {
        if (a.images == null) return;
        if (level >= ComponentCallbacks2.TRIM_MEMORY_BACKGROUND || level >= 15) {
            a.images.evictAll();
            LAST_CACHE_KEY_BY_URL.clear();
        } else if (level >= 10) {
            UiCompat.trimCache(a.images, a.images.maxSize() / 2);
        }
    }

    static boolean isLocalArtworkAddress(String address) {
        if (address == null) return false;
        String lower = address.trim().toLowerCase(Locale.ROOT);
        return lower.startsWith("file://") || lower.startsWith("content://");
    }

    private static boolean isReasonablePosterReuse(
            MainActivity a, Bitmap bmp, int targetW, int targetH) {
        if (bmp == null || bmp.isRecycled()) return false;
        if (targetW <= 0 || targetH <= 0) return true;
        int bw = bmp.getWidth();
        int bh = bmp.getHeight();
        if (bw > targetW * 2 || bh > targetH * 2) return false;
        if (a != null
                && a.isTvDevice()
                && bmp.getConfig() == Bitmap.Config.ARGB_8888
                && (long) bw * (long) bh * 4L > (long) targetW * (long) targetH * 3L) {
            return false;
        }
        return true;
    }

    private static Bitmap downscaleTvCardPosterIfOversized(
            MainActivity a, Bitmap decoded, int targetW, int targetH) {
        if (a == null || !a.isTvDevice() || decoded == null || decoded.isRecycled()) return decoded;
        if (targetW <= 0 || targetH <= 0) return decoded;
        int bw = decoded.getWidth();
        int bh = decoded.getHeight();
        if (bw <= Math.round(targetW * 1.15f) && bh <= Math.round(targetH * 1.15f)) {
            return decoded;
        }
        float scale = Math.max((float) targetW / bw, (float) targetH / bh);
        if (scale >= 0.95f || scale <= 0f) return decoded;
        int outW = Math.max(1, Math.round(bw * scale));
        int outH = Math.max(1, Math.round(bh * scale));
        try {
            Bitmap scaled = Bitmap.createBitmap(outW, outH, Bitmap.Config.RGB_565);
            Canvas c = new Canvas(scaled);
            Paint p = new Paint(Paint.FILTER_BITMAP_FLAG);
            c.drawBitmap(decoded, null, new RectF(0f, 0f, outW, outH), p);
            decoded.recycle();
            return scaled;
        } catch (Throwable ignored) {
            return decoded;
        }
    }

    static Bitmap cachedPosterBitmap(
            MainActivity a, String address, int targetWidth, int targetHeight) {
        if (a == null || a.images == null || address == null || address.isEmpty()) return null;
        String normalized = normalizeArtworkAddress(address);
        if (!Cms.isHttp(normalized)
                && !normalized.startsWith("catpaw://")
                && !isLocalArtworkAddress(normalized)) {
            return null;
        }
        int w = ImageDecodePolicy.targetWidth(targetWidth, false);
        int h = ImageDecodePolicy.targetHeight(targetHeight, false);
        String key = ImageDecodePolicy.cacheKey(normalized, w, h, true, false);
        Bitmap bmp = a.images.get(key);
        if (bmp != null && !bmp.isRecycled()) return bmp;
        Bitmap fallback = a.images.get(normalized);
        if (isReasonablePosterReuse(a, fallback, w, h)) return fallback;
        int defW = ImageDecodePolicy.targetWidth(0, false);
        int defH = ImageDecodePolicy.targetHeight(0, false);
        if (defW != w || defH != h) {
            String defKey = ImageDecodePolicy.cacheKey(normalized, defW, defH, true, false);
            Bitmap defBmp = a.images.get(defKey);
            if (isReasonablePosterReuse(a, defBmp, w, h)) return defBmp;
        }
        String lastKey = LAST_CACHE_KEY_BY_URL.get(normalized);
        if (lastKey != null && !lastKey.equals(key)) {
            Bitmap reuse = a.images.get(lastKey);
            if (isReasonablePosterReuse(a, reuse, w, h)) return reuse;
        }
        return null;
    }

    /**
     * Decodes an already disk-cached or local poster into the in-memory {@link LruCache} on the
     * background artwork pool without initiating any network I/O, so opening History after
     * idle/cold start hits RAM immediately with zero layout or network wait.
     */
    static void preloadDiskCachedPoster(
            final MainActivity a, String address, int targetWidth, int targetHeight) {
        if (a == null || a.images == null || a.artwork == null || address == null) return;
        final String normalized = normalizeArtworkAddress(address);
        final boolean isLocal = isLocalArtworkAddress(normalized);
        if (!Cms.isHttp(normalized) && !isLocal) return;
        if (cachedPosterBitmap(a, normalized, targetWidth, targetHeight) != null) return;
        final int width = ImageDecodePolicy.targetWidth(targetWidth, false);
        final int height = ImageDecodePolicy.targetHeight(targetHeight, false);
        final String key = ImageDecodePolicy.cacheKey(normalized, width, height, true, false);
        final int expectedGen = a.generation;
        try {
            Future<?> req =
                    RequestScope.submit(
                            a.artwork,
                            () -> {
                                if (a.isFinishing()
                                        || a.images == null
                                        || a.generation != expectedGen) {
                                    return;
                                }
                                if (a.images.get(key) != null) return;
                                try {
                                    byte[] bytes;
                                    if (isLocal) {
                                        bytes = readLocalArtworkBytes(a, normalized);
                                    } else {
                                        Cms.ImageRequest source = Cms.imageRequest(normalized);
                                        String resolvedUrl = Cms.normalizeHttp(source.url);
                                        String targetUrl = upgradePosterUrl(resolvedUrl, false);
                                        bytes = readDiskCachedPoster(a, targetUrl);
                                        if (bytes == null && !resolvedUrl.equals(targetUrl)) {
                                            bytes = readDiskCachedPoster(a, resolvedUrl);
                                        }
                                    }
                                    if (bytes == null
                                            || bytes.length == 0
                                            || a.generation != expectedGen) {
                                        return;
                                    }
                                    BitmapFactory.Options options = new BitmapFactory.Options();
                                    options.inJustDecodeBounds = true;
                                    BitmapFactory.decodeByteArray(bytes, 0, bytes.length, options);
                                    if (options.outWidth <= 0 || options.outHeight <= 0) return;
                                    options.inSampleSize =
                                            ImageDecodePolicy.sample(
                                                    options.outWidth,
                                                    options.outHeight,
                                                    width,
                                                    height,
                                                    true,
                                                    false);
                                    if (a.isTvDevice()) {
                                        options.inPreferredConfig = Bitmap.Config.RGB_565;
                                    }
                                    options.inJustDecodeBounds = false;
                                    RequestScope.current().check();
                                    Bitmap bitmap =
                                            BitmapFactory.decodeByteArray(
                                                    bytes, 0, bytes.length, options);
                                    bitmap =
                                            downscaleTvCardPosterIfOversized(
                                                    a, bitmap, width, height);
                                    if (bitmap != null) {
                                        if (a.generation != expectedGen
                                                || Thread.currentThread().isInterrupted()) {
                                            bitmap.recycle();
                                            return;
                                        }
                                        putCachedBitmap(a, normalized, key, bitmap);
                                    }
                                } catch (Throwable ignored) {
                                }
                            });
            a.artworkRequests.add(req);
        } catch (Throwable ignored) {
        }
    }

    interface BitmapCallback {
        void onBitmap(Bitmap bitmap);
    }

    /**
     * Lightweight off-thread poster loader for custom Canvas views (such as {@code
     * CatalogScreen.TvHistoryCardView} and {@code GlobalSearchScreen.TvSearchPosterArtView}) using
     * exact pixel target dimensions, shared {@code IN_FLIGHT} same-URL/same-spec coalescing, and
     * search-scope + target-owner cancellation.
     */
    static void loadPosterBitmap(
            final MainActivity a,
            String address,
            int targetWidth,
            int targetHeight,
            final int ticket,
            final BitmapCallback callback) {
        loadPosterBitmap(a, address, targetWidth, targetHeight, ticket, 0, null, callback);
    }

    static void loadPosterBitmap(
            final MainActivity a,
            String address,
            int targetWidth,
            int targetHeight,
            final int ticket,
            final int scopeToken,
            final BitmapCallback callback) {
        loadPosterBitmap(a, address, targetWidth, targetHeight, ticket, scopeToken, null, callback);
    }

    static void loadPosterBitmap(
            final MainActivity a,
            String address,
            int targetWidth,
            int targetHeight,
            final int ticket,
            final int scopeToken,
            final Object ownerToken,
            final BitmapCallback callback) {
        if (ownerToken != null) {
            unbindBitmapTarget(a, ownerToken);
        }
        if (a == null || callback == null || address == null || address.isEmpty()) return;
        if (isScopeCancelled(scopeToken) || (ticket != 0 && ticket != a.generation)) return;
        final String normalized = normalizeArtworkAddress(address);
        String baseAddr = Cms.imageRequest(normalized).url;
        if (!Cms.isHttp(baseAddr)
                && !normalized.startsWith("catpaw://")
                && !isLocalArtworkAddress(normalized)) {
            return;
        }
        Bitmap immediate = cachedPosterBitmap(a, normalized, targetWidth, targetHeight);
        if (immediate != null) {
            callback.onBitmap(immediate);
            return;
        }
        final int width = ImageDecodePolicy.targetWidth(targetWidth, false);
        final int height = ImageDecodePolicy.targetHeight(targetHeight, false);
        final String key = ImageDecodePolicy.cacheKey(normalized, width, height, true, false);
        final int bindToken = NEXT_BIND_TOKEN.incrementAndGet();
        final Waiter selfWaiter = new Waiter(ownerToken, callback, bindToken, scopeToken, ticket);
        final InFlightEntry owned = new InFlightEntry();
        synchronized (IN_FLIGHT) {
            if (isScopeCancelled(scopeToken)) return;
            if (ownerToken != null) {
                OWNER_BIND_TOKENS.put(ownerToken, Integer.valueOf(bindToken));
            }
            InFlightEntry existing = IN_FLIGHT.get(key);
            if (existing != null) {
                for (Iterator<Waiter> it = existing.waiters.iterator(); it.hasNext(); ) {
                    Waiter w = it.next();
                    if (w.isDead()
                            || isScopeCancelled(w.scopeToken)
                            || (ownerToken != null && w.ownerToken == ownerToken)) {
                        it.remove();
                    }
                }
                if (!existing.waiters.isEmpty()) {
                    existing.waiters.add(selfWaiter);
                    return;
                }
                if (existing.future != null) existing.future.cancel(true);
                IN_FLIGHT.remove(key);
            }
            owned.waiters.add(selfWaiter);
            IN_FLIGHT.put(key, owned);
        }
        final boolean preferDiskPool =
                isLocalArtworkAddress(normalized) || hasFreshDiskCachedPoster(a, normalized, false);
        java.util.concurrent.ExecutorService targetPool =
                preferDiskPool ? DISK_DECODE_POOL : a.artwork;
        Future<?> request =
                RequestScope.submit(
                        targetPool,
                        () -> {
                            if (!hasActiveWaiters(key, owned, a.generation)) return;
                            try {
                                byte[] bytes;
                                if (isLocalArtworkAddress(normalized)) {
                                    bytes = readLocalArtworkBytes(a, normalized);
                                } else {
                                    Cms.ImageRequest source = Cms.imageRequest(normalized);
                                    String resolvedUrl = Cms.normalizeHttp(source.url);
                                    if (resolvedUrl.startsWith("catpaw://")) {
                                        resolvedUrl =
                                                new com.pilipala.catpaw.CatPawHost(a)
                                                        .resolve(resolvedUrl);
                                    }
                                    String targetUrl = upgradePosterUrl(resolvedUrl, false);
                                    bytes =
                                            fetchPosterBytesWithFallback(
                                                    a, source, resolvedUrl, targetUrl, false);
                                }
                                if (bytes == null || bytes.length == 0) return;
                                if (!hasActiveWaiters(key, owned, a.generation)) return;
                                BitmapFactory.Options options = new BitmapFactory.Options();
                                options.inJustDecodeBounds = true;
                                BitmapFactory.decodeByteArray(bytes, 0, bytes.length, options);
                                if (options.outWidth <= 0 || options.outHeight <= 0) return;
                                options.inSampleSize =
                                        ImageDecodePolicy.sample(
                                                options.outWidth,
                                                options.outHeight,
                                                width,
                                                height,
                                                true,
                                                false);
                                if (a.isTvDevice()) {
                                    options.inPreferredConfig = Bitmap.Config.RGB_565;
                                }
                                options.inJustDecodeBounds = false;
                                RequestScope.current().check();
                                Bitmap decoded =
                                        BitmapFactory.decodeByteArray(
                                                bytes, 0, bytes.length, options);
                                final Bitmap bitmap =
                                        downscaleTvCardPosterIfOversized(a, decoded, width, height);
                                if (bitmap == null) return;
                                if (Thread.currentThread().isInterrupted()
                                        || !hasActiveWaiters(key, owned, a.generation)) {
                                    bitmap.recycle();
                                    return;
                                }
                                putCachedBitmap(a, normalized, key, bitmap);
                                final java.util.List<Waiter> targets;
                                synchronized (IN_FLIGHT) {
                                    InFlightEntry removed =
                                            IN_FLIGHT.get(key) == owned
                                                    ? IN_FLIGHT.remove(key)
                                                    : null;
                                    targets =
                                            removed == null
                                                    ? java.util.Collections.<Waiter>emptyList()
                                                    : new java.util.ArrayList<>(removed.waiters);
                                }
                                if (targets.isEmpty()) return;
                                a.ui.post(
                                        () -> {
                                            if (a.isFinishing() || bitmap.isRecycled()) return;
                                            boolean tv = a.isTvDevice();
                                            for (Waiter waiter : targets) {
                                                if (waiter.callback != null) {
                                                    if (isBitmapWaiterStillValid(
                                                            waiter, a.generation)) {
                                                        waiter.callback.onBitmap(bitmap);
                                                    }
                                                } else if (waiter.viewRef != null) {
                                                    ImageView target = waiter.viewRef.get();
                                                    if (isTargetStillBound(
                                                            target, normalized, waiter)) {
                                                        target.setImageBitmap(bitmap);
                                                        if (!tv) {
                                                            com.pilipala.glass.GlassworkSurface
                                                                    .invalidateBackdrop(target);
                                                        }
                                                    }
                                                }
                                            }
                                        });
                            } catch (Throwable ignored) {
                            } finally {
                                synchronized (IN_FLIGHT) {
                                    if (IN_FLIGHT.get(key) == owned) IN_FLIGHT.remove(key);
                                }
                            }
                        });
        boolean cancelImmediately = false;
        synchronized (IN_FLIGHT) {
            owned.future = request;
            if (IN_FLIGHT.get(key) != owned || owned.waiters.isEmpty()) {
                cancelImmediately = true;
            }
        }
        if (cancelImmediately) {
            request.cancel(true);
            return;
        }
        for (Iterator<Future<?>> it = a.artworkRequests.iterator(); it.hasNext(); ) {
            Future<?> f = it.next();
            if (f.isDone() || f.isCancelled()) it.remove();
        }
        a.artworkRequests.add(request);
    }

    static void poster(MainActivity a, String address, ImageView image, boolean detail) {
        poster(a, address, image, detail, 0);
    }

    static void poster(
            MainActivity a, String address, ImageView image, boolean detail, int scopeToken) {
        if (a == null || image == null) return;
        String normalized = normalizeArtworkAddress(address);
        final int bindToken = NEXT_BIND_TOKEN.incrementAndGet();
        image.setTag(normalized);
        image.setTag(TAG_BIND_TOKEN, Integer.valueOf(bindToken));
        image.setTag(TAG_SCOPE_TOKEN, Integer.valueOf(scopeToken));
        image.setTag(TAG_INFLIGHT_KEY, null);
        if (isScopeCancelled(scopeToken)) return;
        String baseAddr = Cms.imageRequest(normalized).url;
        if (!Cms.isHttp(baseAddr)
                && !normalized.startsWith("catpaw://")
                && !isLocalArtworkAddress(normalized)) {
            image.setImageDrawable(null);
            return;
        }
        address = normalized;
        final int ticket = a.generation;
        int initialW = ImageDecodePolicy.targetWidth(image.getWidth(), detail);
        int initialH = ImageDecodePolicy.targetHeight(image.getHeight(), detail);
        boolean initialCrop = image.getScaleType() == ImageView.ScaleType.CENTER_CROP;
        String initialKey =
                ImageDecodePolicy.cacheKey(address, initialW, initialH, initialCrop, detail);
        Bitmap immediate = a.images.get(initialKey);
        if (immediate != null && !immediate.isRecycled()) {
            image.setImageBitmap(immediate);
            if (!a.isTvDevice()) com.pilipala.glass.GlassworkSurface.invalidateBackdrop(image);
            return;
        }
        Bitmap preview = a.images.get(address);
        if ((preview == null || preview.isRecycled()) && detail) {
            String gridKey =
                    ImageDecodePolicy.cacheKey(
                            address,
                            ImageDecodePolicy.targetWidth(0, false),
                            ImageDecodePolicy.targetHeight(0, false),
                            true,
                            false);
            preview = a.images.get(gridKey);
        }
        if (preview != null && !preview.isRecycled()) {
            image.setImageBitmap(preview);
            if (!a.isTvDevice()) com.pilipala.glass.GlassworkSurface.invalidateBackdrop(image);
            if (!detail || (preview.getWidth() >= initialW && preview.getHeight() >= initialH)) {
                return;
            }
        }
        startPosterLoad(a, address, image, detail, ticket, bindToken, scopeToken);
    }

    private static byte[] readLocalArtworkBytes(Context context, String uriStr) {
        if (context == null || uriStr == null || uriStr.isEmpty()) return null;
        InputStream in = null;
        try {
            android.net.Uri uri = android.net.Uri.parse(uriStr);
            if ("file".equalsIgnoreCase(uri.getScheme()) && uri.getPath() != null) {
                File f = new File(uri.getPath());
                if (!f.exists() || !f.canRead() || f.length() > 16 * 1024 * 1024) return null;
                in = new java.io.FileInputStream(f);
            } else {
                in = context.getContentResolver().openInputStream(uri);
            }
            if (in == null) return null;
            ByteArrayOutputStream bos = new ByteArrayOutputStream();
            byte[] buf = new byte[16 * 1024];
            int total = 0;
            int n;
            while ((n = in.read(buf)) > 0) {
                total += n;
                if (total > 16 * 1024 * 1024) return null;
                bos.write(buf, 0, n);
            }
            return bos.toByteArray();
        } catch (Throwable ignored) {
            return null;
        } finally {
            if (in != null) {
                try {
                    in.close();
                } catch (IOException ignored) {
                }
            }
        }
    }

    private static boolean isTargetStillBound(ImageView target, String address, Waiter waiter) {
        if (target == null || waiter == null) return false;
        if (isScopeCancelled(waiter.scopeToken)) return false;
        if (!address.equals(target.getTag())) return false;
        if (!Integer.valueOf(waiter.bindToken).equals(target.getTag(TAG_BIND_TOKEN))) return false;
        return target.isAttachedToWindow() || target.getParent() != null;
    }

    private static void startPosterLoad(
            MainActivity a,
            String address,
            ImageView image,
            boolean detail,
            final int ticket,
            final int bindToken,
            final int scopeToken) {
        if (ticket != a.generation
                || isScopeCancelled(scopeToken)
                || !address.equals(image.getTag())
                || !Integer.valueOf(bindToken).equals(image.getTag(TAG_BIND_TOKEN))) {
            return;
        }
        final int width = ImageDecodePolicy.targetWidth(image.getWidth(), detail);
        final int height = ImageDecodePolicy.targetHeight(image.getHeight(), detail);
        final boolean crop = image.getScaleType() == ImageView.ScaleType.CENTER_CROP;
        final String key = ImageDecodePolicy.cacheKey(address, width, height, crop, detail);
        Bitmap cached = a.images.get(key);
        if (cached != null && !cached.isRecycled()) {
            image.setImageBitmap(cached);
            if (!a.isTvDevice()) com.pilipala.glass.GlassworkSurface.invalidateBackdrop(image);
            return;
        }
        image.setTag(TAG_INFLIGHT_KEY, key);
        final Waiter selfWaiter = new Waiter(image, bindToken, scopeToken);
        final InFlightEntry owned = new InFlightEntry();
        synchronized (IN_FLIGHT) {
            InFlightEntry existing = IN_FLIGHT.get(key);
            if (existing != null) {
                for (Iterator<Waiter> it = existing.waiters.iterator(); it.hasNext(); ) {
                    Waiter w = it.next();
                    if (w.isDead()
                            || isScopeCancelled(w.scopeToken)
                            || (w.viewRef != null && w.viewRef.get() == image)) {
                        it.remove();
                    }
                }
                if (!existing.waiters.isEmpty()) {
                    existing.waiters.add(selfWaiter);
                    return;
                }
                if (existing.future != null) existing.future.cancel(true);
                IN_FLIGHT.remove(key);
            }
            owned.waiters.add(selfWaiter);
            IN_FLIGHT.put(key, owned);
        }
        final boolean preferDiskPool =
                isLocalArtworkAddress(address) || hasFreshDiskCachedPoster(a, address, detail);
        java.util.concurrent.ExecutorService targetPool =
                preferDiskPool ? DISK_DECODE_POOL : a.artwork;
        Future<?> request =
                RequestScope.submit(
                        targetPool,
                        () -> {
                            if (ticket != a.generation
                                    || !hasActiveWaiters(key, owned, a.generation)) {
                                synchronized (IN_FLIGHT) {
                                    if (IN_FLIGHT.get(key) == owned) IN_FLIGHT.remove(key);
                                }
                                return;
                            }
                            HttpURLConnection connection = null;
                            try {
                                byte[] bytes;
                                if (isLocalArtworkAddress(address)) {
                                    bytes = readLocalArtworkBytes(a, address);
                                } else {
                                    Cms.ImageRequest source = Cms.imageRequest(address);
                                    String resolvedUrl = Cms.normalizeHttp(source.url);
                                    if (resolvedUrl.startsWith("catpaw://")) {
                                        resolvedUrl =
                                                new com.pilipala.catpaw.CatPawHost(a)
                                                        .resolve(resolvedUrl);
                                    }
                                    String targetUrl = upgradePosterUrl(resolvedUrl, detail);
                                    bytes =
                                            fetchPosterBytesWithFallback(
                                                    a, source, resolvedUrl, targetUrl, detail);
                                }
                                if (bytes == null || bytes.length == 0) return;
                                if (ticket != a.generation
                                        || !hasActiveWaiters(key, owned, a.generation)) return;
                                BitmapFactory.Options options = new BitmapFactory.Options();
                                options.inJustDecodeBounds = true;
                                BitmapFactory.decodeByteArray(bytes, 0, bytes.length, options);
                                if (options.outWidth <= 0 || options.outHeight <= 0) return;
                                options.inSampleSize =
                                        ImageDecodePolicy.sample(
                                                options.outWidth,
                                                options.outHeight,
                                                width,
                                                height,
                                                crop,
                                                detail);
                                if (!detail && a.isTvDevice()) {
                                    options.inPreferredConfig = Bitmap.Config.RGB_565;
                                }
                                options.inJustDecodeBounds = false;
                                RequestScope.current().check();
                                Bitmap bitmap =
                                        BitmapFactory.decodeByteArray(
                                                bytes, 0, bytes.length, options);
                                if (bitmap != null) {
                                    if (ticket != a.generation
                                            || Thread.currentThread().isInterrupted()
                                            || !hasActiveWaiters(key, owned, a.generation)) {
                                        bitmap.recycle();
                                        return;
                                    }
                                    putCachedBitmap(a, address, key, bitmap);
                                    final java.util.List<Waiter> targets;
                                    synchronized (IN_FLIGHT) {
                                        InFlightEntry removed =
                                                IN_FLIGHT.get(key) == owned
                                                        ? IN_FLIGHT.remove(key)
                                                        : null;
                                        targets =
                                                removed == null
                                                        ? java.util.Collections.singletonList(
                                                                selfWaiter)
                                                        : new java.util.ArrayList<>(
                                                                removed.waiters);
                                    }
                                    if (targets.isEmpty()) return;
                                    a.ui.post(
                                            () -> {
                                                if (ticket != a.generation || a.isFinishing())
                                                    return;
                                                if (bitmap.isRecycled()) return;
                                                boolean tv = a.isTvDevice();
                                                for (Waiter waiter : targets) {
                                                    if (waiter.callback != null) {
                                                        if (isBitmapWaiterStillValid(
                                                                waiter, a.generation)) {
                                                            waiter.callback.onBitmap(bitmap);
                                                        }
                                                    } else if (waiter.viewRef != null) {
                                                        ImageView target = waiter.viewRef.get();
                                                        if (isTargetStillBound(
                                                                target, address, waiter)) {
                                                            target.setImageBitmap(bitmap);
                                                            if (!tv) {
                                                                com.pilipala.glass.GlassworkSurface
                                                                        .invalidateBackdrop(target);
                                                            }
                                                        }
                                                    }
                                                }
                                            });
                                }
                            } catch (Throwable ignored) {
                            } finally {
                                synchronized (IN_FLIGHT) {
                                    if (IN_FLIGHT.get(key) == owned) IN_FLIGHT.remove(key);
                                }
                                if (connection != null) {
                                    RequestScope.detach(connection);
                                    connection.disconnect();
                                }
                            }
                        });
        owned.future = request;
        for (Iterator<Future<?>> it = a.artworkRequests.iterator(); it.hasNext(); ) {
            if (it.next().isDone()) it.remove();
        }
        a.artworkRequests.add(request);
    }

    private static File diskCacheFile(MainActivity a, String url) {
        try {
            File dir = new File(a.getCacheDir(), "posters_v2");
            if (!dir.exists()) dir.mkdirs();
            java.security.MessageDigest md = java.security.MessageDigest.getInstance("SHA-256");
            byte[] d = md.digest(url.getBytes("UTF-8"));
            StringBuilder sb = new StringBuilder(32);
            for (int i = 0; i < 16; i++) {
                sb.append(String.format(java.util.Locale.ROOT, "%02x", d[i] & 255));
            }
            return new File(dir, sb.toString() + ".img");
        } catch (Exception e) {
            return null;
        }
    }

    static boolean hasFreshDiskCachedPoster(MainActivity a, String address, boolean detail) {
        if (a == null || address == null || address.isEmpty()) return false;
        try {
            Cms.ImageRequest source = Cms.imageRequest(address);
            String resolvedUrl = Cms.normalizeHttp(source.url);
            if (resolvedUrl == null
                    || resolvedUrl.isEmpty()
                    || resolvedUrl.startsWith("catpaw://")) {
                return false;
            }
            String targetUrl = upgradePosterUrl(resolvedUrl, detail);
            if (isDiskFileFresh(diskCacheFile(a, targetUrl))) return true;
            if (!targetUrl.equals(resolvedUrl) && isDiskFileFresh(diskCacheFile(a, resolvedUrl))) {
                return true;
            }
            if (detail) {
                String nonDetail = upgradePosterUrl(resolvedUrl, false);
                if (!nonDetail.equals(targetUrl)
                        && !nonDetail.equals(resolvedUrl)
                        && isDiskFileFresh(diskCacheFile(a, nonDetail))) {
                    return true;
                }
            }
        } catch (Throwable ignored) {
        }
        return false;
    }

    private static boolean isDiskFileFresh(File f) {
        if (f == null || !f.isFile()) return false;
        long len = f.length();
        if (len <= 128 || len > 8 * 1024 * 1024) return false;
        return System.currentTimeMillis() - f.lastModified() <= 7L * 24 * 3600 * 1000L;
    }

    static byte[] readDiskCachedPoster(MainActivity a, String url) {
        try {
            File f = diskCacheFile(a, url);
            if (!isDiskFileFresh(f)) return null;
            long len = f.length();
            byte[] buf = new byte[(int) len];
            try (java.io.FileInputStream in = new java.io.FileInputStream(f)) {
                int off = 0;
                while (off < buf.length) {
                    int r = in.read(buf, off, buf.length - off);
                    if (r < 0) break;
                    off += r;
                }
                if (off != buf.length) return null;
            }
            return buf;
        } catch (Exception e) {
            return null;
        }
    }

    private static void writeDiskCachedPoster(MainActivity a, String url, byte[] bytes) {
        try {
            File f = diskCacheFile(a, url);
            if (f == null) return;
            try (java.io.FileOutputStream out = new java.io.FileOutputStream(f)) {
                out.write(bytes);
            }
        } catch (Exception ignored) {
        }
    }

    static String normalizeArtworkAddress(String raw) {
        if (raw == null) return "";
        String trimmed = raw.trim();
        if (trimmed.startsWith("//")) return "https:" + trimmed;
        if (trimmed.startsWith("proxy://")
                || trimmed.startsWith("http://127.0.0.1:")
                || trimmed.startsWith("http://localhost:")) {
            Cms.ImageRequest req = Cms.imageRequest(trimmed);
            String rewritten = LocalProxy.rewrite(req.url);
            if (!rewritten.equals(req.url) && req.url.length() < trimmed.length()) {
                return rewritten + trimmed.substring(req.url.length());
            }
            return rewritten;
        }
        return trimmed;
    }

    private static String headerValueIgnoreCase(Map<String, String> headers, String target) {
        if (headers == null || target == null) return null;
        for (Map.Entry<String, String> e : headers.entrySet()) {
            if (e.getKey() != null && target.equalsIgnoreCase(e.getKey())) {
                return e.getValue();
            }
        }
        return null;
    }

    private static boolean hasHeaderIgnoreCase(Map<String, String> headers, String target) {
        String val = headerValueIgnoreCase(headers, target);
        return val != null && !val.trim().isEmpty();
    }

    private static boolean isDecodablePosterBytes(byte[] bytes) {
        if (bytes == null || bytes.length <= 128) return false;
        BitmapFactory.Options opts = new BitmapFactory.Options();
        opts.inJustDecodeBounds = true;
        BitmapFactory.decodeByteArray(bytes, 0, bytes.length, opts);
        return opts.outWidth > 0 && opts.outHeight > 0;
    }

    private static void deleteDiskCachedPosterQuietly(MainActivity a, String url) {
        try {
            File f = diskCacheFile(a, url);
            if (f != null && f.exists()) f.delete();
        } catch (Throwable ignored) {
        }
    }

    private static final String BROWSER_IMAGE_UA =
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36";

    private static byte[] fetchPosterBytesWithFallback(
            MainActivity a,
            Cms.ImageRequest source,
            String resolvedUrl,
            String targetUrl,
            boolean detail)
            throws Exception {
        String[] candidates =
                detail && !targetUrl.equals(resolvedUrl)
                        ? new String[] {
                            targetUrl, upgradePosterUrl(resolvedUrl, false), resolvedUrl
                        }
                        : new String[] {targetUrl, resolvedUrl};
        Exception lastError = null;
        java.util.HashSet<String> tried = new java.util.HashSet<>();
        String customUa = headerValueIgnoreCase(source.headers, "User-Agent");
        boolean hasCustomUa = customUa != null && !customUa.trim().isEmpty();
        boolean hasExplicitReferer = hasHeaderIgnoreCase(source.headers, "Referer");
        String[] userAgents =
                hasCustomUa
                        ? new String[] {customUa}
                        : new String[] {BROWSER_IMAGE_UA, Cms.USER_AGENT};
        for (String candidate : candidates) {
            if (candidate == null || candidate.isEmpty() || !tried.add(candidate)) continue;
            byte[] cached = readDiskCachedPoster(a, candidate);
            if (cached != null) {
                if (isDecodablePosterBytes(cached)) return cached;
                deleteDiskCachedPosterQuietly(a, candidate);
            }
            for (String ua : userAgents) {
                for (int refererMode = 0;
                        refererMode < (hasExplicitReferer ? 1 : 2);
                        refererMode++) {
                    HttpURLConnection connection = null;
                    try {
                        String currentUrl = candidate;
                        int lastCode = 0;
                        for (int hop = 0; hop < 4; hop++) {
                            if (connection != null) {
                                RequestScope.detach(connection);
                                connection.disconnect();
                            }
                            connection = ProxyAddress.openHttpConnection(new URL(currentUrl));
                            connection.setInstanceFollowRedirects(false);
                            Map<String, String> mergedHeaders =
                                    ProxyAddress.requestHeaders(currentUrl, source.headers);
                            for (Map.Entry<String, String> header : mergedHeaders.entrySet()) {
                                connection.setRequestProperty(header.getKey(), header.getValue());
                            }
                            connection.setRequestProperty(
                                    "Accept", "image/webp,image/png,image/jpeg,*/*;q=0.8");
                            String fragment = new URL(currentUrl).getRef();
                            if (fragment != null && fragment.startsWith("mm-emby=")) {
                                com.pilipala.emby.EmbyLibrary library =
                                        com.pilipala.emby.EmbyAccounts.open(
                                                a, "emby://account/" + fragment.substring(8));
                                for (Map.Entry<String, String> h :
                                        library.imageHeaders(currentUrl).entrySet())
                                    connection.setRequestProperty(h.getKey(), h.getValue());
                            }
                            if (refererMode == 0) {
                                applyArtworkHeaders(connection, currentUrl, mergedHeaders);
                            } else if (!hasExplicitReferer) {
                                URL u = new URL(currentUrl);
                                connection.setRequestProperty(
                                        "Referer", u.getProtocol() + "://" + u.getHost() + "/");
                            }
                            connection.setConnectTimeout(4500);
                            connection.setReadTimeout(5500);
                            if (!hasCustomUa && ua != null) {
                                connection.setRequestProperty("User-Agent", ua);
                            }
                            RequestScope.attach(connection);
                            lastCode = connection.getResponseCode();
                            if (lastCode >= 300 && lastCode < 400 && lastCode != 304) {
                                String loc = connection.getHeaderField("Location");
                                if (loc == null || loc.trim().isEmpty()) break;
                                currentUrl =
                                        Cms.normalizeHttp(
                                                new URL(new URL(currentUrl), loc.trim())
                                                        .toString());
                                continue;
                            }
                            break;
                        }
                        if (connection == null) continue;
                        if (lastCode == 403 && !hasExplicitReferer && refererMode == 0) {
                            continue;
                        }
                        if (lastCode < 200 || lastCode >= 300) {
                            lastError = new Cms.HttpStatusException(lastCode);
                            continue;
                        }
                        try (InputStream in = connection.getInputStream()) {
                            ByteArrayOutputStream out = new ByteArrayOutputStream();
                            byte[] buffer = new byte[8192];
                            int n;
                            while ((n = in.read(buffer)) != -1) {
                                RequestScope.current().check();
                                if (out.size() + n > (detail ? 8 : 3) * 1024 * 1024)
                                    throw new IOException("Poster too large");
                                out.write(buffer, 0, n);
                            }
                            byte[] bytes = out.toByteArray();
                            if (isDecodablePosterBytes(bytes)) {
                                writeDiskCachedPoster(a, candidate, bytes);
                                return bytes;
                            }
                        }
                    } catch (Exception e) {
                        lastError = e;
                    } finally {
                        if (connection != null) {
                            RequestScope.detach(connection);
                            connection.disconnect();
                        }
                    }
                }
            }
        }
        if (lastError != null) throw lastError;
        return null;
    }

    static String upgradePosterUrl(String rawUrl, boolean detail) {
        if (rawUrl == null || rawUrl.isEmpty()) return "";
        String url = rawUrl;
        if (url.contains("doubanio.com")) {
            boolean signedDouban = url.contains("qnmob") && url.contains("-sign.doubanio.com");
            if (!signedDouban) {
                url =
                        url.replaceAll(
                                "https?://img[4-8]\\.doubanio\\.com/",
                                "https://img1.doubanio.com/");
                int qIdx = url.indexOf('?');
                if (qIdx > 0 && url.substring(0, qIdx).endsWith(".jpg")) {
                    url = url.substring(0, qIdx);
                }
            }
            if (detail) {
                url =
                        url.replace("/s_ratio_poster/", "/l_ratio_poster/")
                                .replace("/m_ratio_poster/", "/l_ratio_poster/")
                                .replace("/view/photo/spic/", "/view/photo/lpic/")
                                .replace("/view/photo/mpic/", "/view/photo/lpic/")
                                .replace("/view/photo/s/", "/view/photo/l/")
                                .replace("/view/photo/m/", "/view/photo/l/")
                                .replace("/view/photo/large/", "/view/photo/l/");
            } else {
                url =
                        url.replace("/s_ratio_poster/", "/m_ratio_poster/")
                                .replace("/view/photo/spic/", "/view/photo/mpic/");
            }
        }
        if (url.contains("image.tmdb.org/t/p/")) {
            if (detail) {
                url =
                        url.replace("/t/p/w185/", "/t/p/w780/")
                                .replace("/t/p/w300/", "/t/p/w780/")
                                .replace("/t/p/w342/", "/t/p/w780/")
                                .replace("/t/p/w500/", "/t/p/w780/");
            } else {
                url =
                        url.replace("/t/p/w185/", "/t/p/w500/")
                                .replace("/t/p/w300/", "/t/p/w500/")
                                .replace("/t/p/w342/", "/t/p/w500/");
            }
        }
        if (detail) {
            if (url.contains("lain.bgm.tv") || url.contains("bgm.tv/pic/cover/")) {
                url =
                        url.replace("/pic/cover/c/", "/pic/cover/l/")
                                .replace("/pic/cover/m/", "/pic/cover/l/")
                                .replace("/pic/cover/s/", "/pic/cover/l/")
                                .replace("/r/400/", "/r/800/");
            }
            if (url.contains("hdslb.com") || url.contains("biliimg.com")) {
                int at = url.indexOf('@');
                if (at > 0) url = url.substring(0, at);
            }
            if (url.contains("bcebos.com")) {
                int q = url.indexOf('?');
                if (q > 0) url = url.substring(0, q);
            }
        }
        return url;
    }

    static void applyArtworkHeaders(
            HttpURLConnection connection, String url, Map<String, String> existing) {
        if (hasHeaderIgnoreCase(existing, "Referer")) return;
        String lower = url.toLowerCase(Locale.ROOT);
        if (lower.contains("doubanio.com") || lower.contains("douban.com")) {
            connection.setRequestProperty("Referer", "https://movie.douban.com/");
        } else if (lower.contains("hdslb.com")
                || lower.contains("biliimg.com")
                || lower.contains("bilibili.com")) {
            connection.setRequestProperty("Referer", "https://www.bilibili.com/");
        } else if (lower.contains("bcebos.com") || lower.contains("baidu.com")) {
            connection.setRequestProperty("Referer", "https://baike.baidu.com/");
        } else if (lower.contains("bgm.tv") || lower.contains("bangumi.tv")) {
            connection.setRequestProperty("Referer", "https://bgm.tv/");
        } else if (lower.contains("bing.net") || lower.contains("bing.com")) {
            connection.setRequestProperty("Referer", "https://cn.bing.com/");
        } else if (lower.contains("qpic.cn") || lower.contains("gtimg.cn")) {
            connection.setRequestProperty("Referer", "https://v.qq.com/");
        } else if (lower.contains("ykimg.com")
                || lower.contains("alicdn.com")
                || lower.contains("iqiyipic.com")
                || lower.contains("qiyipic.com")
                || lower.contains("mgtv.com")
                || lower.contains("hitv.com")) {
            try {
                String urlHost = connection.getURL() != null ? connection.getURL().getHost() : "";
                if (urlHost != null && !urlHost.trim().isEmpty()) {
                    connection.setRequestProperty("Referer", "https://" + urlHost + "/");
                }
            } catch (Exception ignored) {
            }
        } else if (lower.contains("sinaimg.cn")) {
            connection.setRequestProperty("Referer", "https://weibo.com/");
        }
    }

    static View createAtmosphere(MainActivity a) {
        return new Atmosphere(a);
    }

    static void clearWallpaperCache() {
        Atmosphere.clearCache();
    }

    static final class Atmosphere extends View {
        private static final Object WALLPAPER_LOCK = new Object();
        private static String cachedWallpaperKey = "";
        private static Bitmap cachedWallpaperBitmap;

        static void clearCache() {
            synchronized (WALLPAPER_LOCK) {
                cachedWallpaperKey = "";
                cachedWallpaperBitmap = null;
            }
        }

        final MainActivity a;
        final Paint paint = new Paint(3);
        Bitmap wallpaper;
        int decodeSerial;
        boolean detached;

        Atmosphere(Context c) {
            super(c);
            a = (MainActivity) c;
            reloadWallpaper();
        }

        private static Bitmap lookupCachedWallpaper(String key) {
            synchronized (WALLPAPER_LOCK) {
                if (key.equals(cachedWallpaperKey)
                        && cachedWallpaperBitmap != null
                        && !cachedWallpaperBitmap.isRecycled()) {
                    return cachedWallpaperBitmap;
                }
                return null;
            }
        }

        private static void storeCachedWallpaper(String key, Bitmap bmp) {
            synchronized (WALLPAPER_LOCK) {
                cachedWallpaperKey = key;
                cachedWallpaperBitmap = bmp;
            }
        }

        void reloadWallpaper() {
            final int serial = ++decodeSerial;
            boolean showWallpaper =
                    a.isTvDevice()
                            ? HomeAmbient.effectiveBgMode(a) == Prefs.BG_MODE_WALLPAPER
                            : a.prefs.getBoolean(Prefs.WALLPAPER_ENABLED, false);
            if (!showWallpaper) {
                wallpaper = null;
                invalidate();
                return;
            }
            final File f = new File(a.getFilesDir(), "wallpaper.jpg");
            if (!f.exists()) {
                wallpaper = null;
                clearCache();
                invalidate();
                return;
            }
            final int targetW = Math.max(640, Math.min(1920, a.windowWidth()));
            final int targetH = Math.max(360, Math.min(1080, a.windowHeight()));
            final String revKey =
                    f.getAbsolutePath()
                            + "|"
                            + f.lastModified()
                            + "|"
                            + f.length()
                            + "|"
                            + targetW
                            + "x"
                            + targetH;
            Bitmap cached = lookupCachedWallpaper(revKey);
            if (cached != null) {
                wallpaper = cached;
                invalidate();
                return;
            }
            wallpaper = null;
            invalidate();
            a.worker.execute(
                    () -> {
                        Bitmap decoded = null;
                        try {
                            BitmapFactory.Options bounds = new BitmapFactory.Options();
                            bounds.inJustDecodeBounds = true;
                            BitmapFactory.decodeFile(f.getAbsolutePath(), bounds);
                            if (bounds.outWidth > 0 && bounds.outHeight > 0) {
                                BitmapFactory.Options opts = new BitmapFactory.Options();
                                int sample = 1;
                                while ((bounds.outWidth / (sample * 2)) >= targetW
                                        && (bounds.outHeight / (sample * 2)) >= targetH) {
                                    sample *= 2;
                                }
                                opts.inSampleSize = sample;
                                opts.inPreferredConfig = Bitmap.Config.RGB_565;
                                decoded = BitmapFactory.decodeFile(f.getAbsolutePath(), opts);
                            }
                        } catch (Throwable ignored) {
                            decoded = null;
                        }
                        if (decoded != null && !decoded.isRecycled()) {
                            storeCachedWallpaper(revKey, decoded);
                        }
                        final Bitmap ready = decoded;
                        a.ui.post(
                                () -> {
                                    if (detached
                                            || serial != decodeSerial
                                            || a.isFinishing()
                                            || (ready != null && ready.isRecycled())) {
                                        return;
                                    }
                                    wallpaper = ready;
                                    invalidate();
                                });
                    });
        }

        @Override
        protected void onDraw(Canvas canvas) {
            canvas.drawColor(MainActivity.DARK);
            if (wallpaper != null && !wallpaper.isRecycled()) {
                float scale =
                        Math.max(
                                (float) getWidth() / wallpaper.getWidth(),
                                (float) getHeight() / wallpaper.getHeight());
                float w = wallpaper.getWidth() * scale, h = wallpaper.getHeight() * scale;
                canvas.drawBitmap(
                        wallpaper,
                        null,
                        new RectF(
                                (getWidth() - w) / 2,
                                (getHeight() - h) / 2,
                                (getWidth() + w) / 2,
                                (getHeight() + h) / 2),
                        paint);
                int dim = Prefs.clampWallpaperDim(a.prefs.getInt(Prefs.WALLPAPER_DIM, 60));
                canvas.drawColor(Color.argb(Math.round(255 * dim / 100f), 0, 0, 0));
            }
        }

        @Override
        protected void onDetachedFromWindow() {
            super.onDetachedFromWindow();
            detached = true;
            decodeSerial++;
            wallpaper = null;
        }
    }
}
