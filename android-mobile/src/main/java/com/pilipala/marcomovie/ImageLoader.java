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
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.Future;
import java.util.concurrent.ThreadPoolExecutor;

/**
 * Bounded asynchronous poster/artwork loader, memory cache trimming, and background atmosphere
 * rendering extracted from {@link MainActivity}.
 */
final class ImageLoader {
    private static final class InFlightEntry {
        final int ticket;
        final java.util.List<ImageView> waiters = new java.util.ArrayList<>(2);

        InFlightEntry(int ticket, ImageView first) {
            this.ticket = ticket;
            if (first != null) this.waiters.add(first);
        }
    }

    private static final java.util.Map<String, InFlightEntry> IN_FLIGHT = new java.util.HashMap<>();
    private static final java.util.WeakHashMap<ImageView, Boolean> DETAIL_FLAGS =
            new java.util.WeakHashMap<>();
    private static final java.util.Map<String, String> HERO_HD_URL_CACHE =
            java.util.Collections.synchronizedMap(
                    new java.util.LinkedHashMap<String, String>(64, 0.75f, true) {
                        @Override
                        protected boolean removeEldestEntry(Map.Entry<String, String> eldest) {
                            return size() > 160;
                        }
                    });
    private static final String DOUBAN_BID = "M9kL2pQ7xR4";

    interface BitmapCallback {
        void onBitmap(Bitmap bitmap);
    }

    /** Pure-JVM quality gate: true 1080p/Retina vertical Hero poster must be >= 560x760 px. */
    static boolean isTrueHdPosterDimensions(int width, int height) {
        return width >= 560 && height >= 760;
    }

    /**
     * Loads a crisp full-bleed Hero poster at full viewport HD resolution (up to 1440x2160) and
     * automatically upgrades blurry CMS thumbnails (< 560x760) to official 1080p/2K theatrical
     * posters via TMDB (if configured), Douban {@code l_ratio_poster}, Bangumi {@code large}, or
     * Baidu Baike raw {@code bcebos.com}.
     */
    static void loadHeroHdPoster(
            final MainActivity a,
            final Cms.Video video,
            final ImageView image,
            final boolean isPrivateSite,
            final BitmapCallback onBitmapReady) {
        loadHeroHdPoster(a, video, image, isPrivateSite, false, onBitmapReady);
    }

    static void loadHeroHdPoster(
            final MainActivity a,
            final Cms.Video video,
            final ImageView image,
            final boolean isPrivateSite,
            final boolean allowSyncDiskHit,
            final BitmapCallback onBitmapReady) {
        if (a == null || video == null || image == null) return;
        final String rawAddress = normalizeArtworkAddress(video.poster);
        final String heroTag =
                "hero-hd|" + rawAddress + "|" + (video.title == null ? "" : video.title);
        image.setTag(heroTag);
        final int ticket = a.generation;
        final int targetW = Math.max(720, Math.min(960, (int) Math.round(a.windowWidth() * 0.68)));
        final int targetH = Math.max(1080, Math.round(targetW * 1.5f));
        final String heroCacheKey = "hero-hd|" + rawAddress + "|" + targetW + "x" + targetH;
        final String heroDiskKey =
                rawAddress + "|" + (video.title == null ? "" : video.title.trim());

        Bitmap memHit = a.images.get(heroCacheKey);
        if (memHit != null && !memHit.isRecycled()) {
            image.animate().cancel();
            image.setAlpha(1f);
            image.setImageBitmap(memHit);
            if (onBitmapReady != null) onBitmapReady.onBitmap(memHit);
            return;
        }

        // Instant synchronous disk-cache hydration for the lead Hero slide on cold start so
        // frame 1 displays the cached immersive poster immediately with zero blank gap.
        if (allowSyncDiskHit && !isPrivateSite && !a.privateMode) {
            byte[] diskBytes = readHeroDiskPosterBytes(a, heroDiskKey);
            if (diskBytes != null) {
                Bitmap diskBmp = decodeHeroBitmap(diskBytes, targetW, targetH);
                if (diskBmp != null && !diskBmp.isRecycled()) {
                    a.images.put(heroCacheKey, diskBmp);
                    image.animate().cancel();
                    image.setAlpha(1f);
                    image.setImageBitmap(diskBmp);
                    if (onBitmapReady != null) onBitmapReady.onBitmap(diskBmp);
                    if (isTrueHdPosterDimensions(diskBmp.getWidth(), diskBmp.getHeight())) {
                        return;
                    }
                }
            }
        }

        Future<?> request =
                RequestScope.submit(
                        a.artwork,
                        () -> {
                            if (ticket != a.generation || a.isFinishing()) return;
                            int currentPixels = 0;
                            boolean currentIsHd = false;
                            // 0. Fast async hero disk-cache hit (covers slides 1..4 on cold start)
                            if (!isPrivateSite && !a.privateMode) {
                                byte[] diskBytes = readHeroDiskPosterBytes(a, heroDiskKey);
                                if (diskBytes != null) {
                                    Bitmap diskBmp = decodeHeroBitmap(diskBytes, targetW, targetH);
                                    if (diskBmp != null) {
                                        if (ticket != a.generation
                                                || Thread.currentThread().isInterrupted()) {
                                            diskBmp.recycle();
                                            return;
                                        }
                                        currentPixels = diskBmp.getWidth() * diskBmp.getHeight();
                                        currentIsHd =
                                                isTrueHdPosterDimensions(
                                                        diskBmp.getWidth(), diskBmp.getHeight());
                                        a.images.put(heroCacheKey, diskBmp);
                                        deliverHeroBitmap(
                                                a, ticket, heroTag, image, diskBmp, onBitmapReady);
                                        if (currentIsHd) return;
                                    }
                                }
                            }
                            // 1. Fast first-pass decode of upgraded CMS poster URL
                            if (Cms.isHttp(rawAddress) || rawAddress.startsWith("catpaw://")) {
                                try {
                                    Cms.ImageRequest source = Cms.imageRequest(rawAddress);
                                    String resolvedUrl = Cms.normalizeHttp(source.url);
                                    if (resolvedUrl.startsWith("catpaw://")) {
                                        resolvedUrl =
                                                new com.pilipala.catpaw.CatPawHost(a)
                                                        .resolve(resolvedUrl);
                                    }
                                    String targetUrl = upgradePosterUrl(resolvedUrl, true);
                                    byte[] bytes =
                                            fetchPosterBytesWithFallback(
                                                    a, source, resolvedUrl, targetUrl, true);
                                    Bitmap bmp = decodeHeroBitmap(bytes, targetW, targetH);
                                    if (bmp != null) {
                                        if (ticket != a.generation
                                                || Thread.currentThread().isInterrupted()) {
                                            bmp.recycle();
                                            return;
                                        }
                                        currentPixels = bmp.getWidth() * bmp.getHeight();
                                        currentIsHd =
                                                isTrueHdPosterDimensions(
                                                        bmp.getWidth(), bmp.getHeight());
                                        a.images.put(heroCacheKey, bmp);
                                        if (!isPrivateSite && !a.privateMode) {
                                            writeHeroDiskPosterBytes(a, heroDiskKey, bytes);
                                        }
                                        deliverHeroBitmap(
                                                a, ticket, heroTag, image, bmp, onBitmapReady);
                                    }
                                } catch (Throwable ignored) {
                                }
                            }

                            // 2. If CMS thumbnail is blurry (< 560x760), resolve true HD artwork
                            if (!currentIsHd
                                    && !isPrivateSite
                                    && video.title != null
                                    && !video.title.trim().isEmpty()) {
                                try {
                                    RequestScope.current().check();
                                    String hdUrl = resolveTitleHdPosterUrl(a, video);
                                    if (hdUrl != null && !hdUrl.isEmpty()) {
                                        Cms.ImageRequest hdSrc = Cms.imageRequest(hdUrl);
                                        String hdUpgraded = upgradePosterUrl(hdSrc.url, true);
                                        byte[] hdBytes =
                                                fetchPosterBytesWithFallback(
                                                        a, hdSrc, hdSrc.url, hdUpgraded, true);
                                        Bitmap hdBmp = decodeHeroBitmap(hdBytes, targetW, targetH);
                                        if (hdBmp != null) {
                                            int hdPixels = hdBmp.getWidth() * hdBmp.getHeight();
                                            if (ticket != a.generation
                                                    || Thread.currentThread().isInterrupted()) {
                                                hdBmp.recycle();
                                                return;
                                            }
                                            if (currentPixels == 0
                                                    || (hdBmp.getWidth() >= 500
                                                            && hdPixels
                                                                    > Math.round(
                                                                            currentPixels
                                                                                    * 1.25))) {
                                                a.images.put(heroCacheKey, hdBmp);
                                                if (!a.privateMode) {
                                                    writeHeroDiskPosterBytes(
                                                            a, heroDiskKey, hdBytes);
                                                }
                                                deliverHeroBitmap(
                                                        a,
                                                        ticket,
                                                        heroTag,
                                                        image,
                                                        hdBmp,
                                                        onBitmapReady);
                                            } else {
                                                hdBmp.recycle();
                                            }
                                        }
                                    }
                                } catch (Throwable ignored) {
                                }
                            }
                        });
        for (java.util.Iterator<Future<?>> it = a.artworkRequests.iterator(); it.hasNext(); ) {
            if (it.next().isDone()) it.remove();
        }
        a.artworkRequests.add(request);
    }

    private static Bitmap decodeHeroBitmap(byte[] bytes, int targetW, int targetH) {
        if (bytes == null || bytes.length <= 128) return null;
        BitmapFactory.Options opts = new BitmapFactory.Options();
        opts.inJustDecodeBounds = true;
        BitmapFactory.decodeByteArray(bytes, 0, bytes.length, opts);
        if (opts.outWidth <= 0 || opts.outHeight <= 0) return null;
        int sample = 1;
        while ((opts.outWidth / (sample * 2)) >= targetW
                && (opts.outHeight / (sample * 2)) >= targetH) {
            sample *= 2;
        }
        long maxPixels = 1_600_000L;
        while ((long) Math.max(1, opts.outWidth / sample)
                        * (long) Math.max(1, opts.outHeight / sample)
                > maxPixels) {
            sample *= 2;
        }
        opts.inJustDecodeBounds = false;
        opts.inSampleSize = sample;
        opts.inPreferredConfig = Bitmap.Config.RGB_565;
        return BitmapFactory.decodeByteArray(bytes, 0, bytes.length, opts);
    }

    private static void deliverHeroBitmap(
            MainActivity a,
            int ticket,
            String heroTag,
            ImageView image,
            Bitmap bmp,
            BitmapCallback onBitmapReady) {
        a.ui.post(
                () -> {
                    if (ticket != a.generation || a.isFinishing()) return;
                    if (!heroTag.equals(image.getTag())) return;
                    boolean wasEmpty = image.getDrawable() == null;
                    image.setImageBitmap(bmp);
                    if (wasEmpty && !MobileMotion.isReduced(a)) {
                        image.animate().cancel();
                        image.setAlpha(0f);
                        image.animate()
                                .alpha(1f)
                                .setDuration(MotionTokens.DURATION_FAST_MS)
                                .setInterpolator(MotionTokens.createDecelerateInterpolator())
                                .start();
                    } else {
                        image.animate().cancel();
                        image.setAlpha(1f);
                    }
                    if (onBitmapReady != null) {
                        onBitmapReady.onBitmap(bmp);
                    }
                });
    }

    private static String resolveTitleHdPosterUrl(MainActivity a, Cms.Video video) {
        SeasonParser.SeasonMeta sm = SeasonParser.parseSeasonMeta(video.title);
        String cleanTitle = EpisodeNameCleaner.cleanSearchTitle(sm.baseTitle);
        if (cleanTitle == null || cleanTitle.trim().isEmpty()) return "";
        cleanTitle = cleanTitle.trim();
        String year = video.year == null ? "" : video.year.trim();
        String cacheKey = cleanTitle + "|" + year;
        String cached = HERO_HD_URL_CACHE.get(cacheKey);
        if (cached != null) return cached;

        String found = "";
        try {
            // 1. User-configured TMDB (highest reliability, clean official w780 vertical posters)
            if (TmdbService.isConfigured(a)) {
                found = queryTmdbHdPosterUrl(a, cleanTitle);
            }
            // 2. Douban Subject Suggest -> upgraded l_ratio_poster (zero API key, 1080p+ official)
            if (found.isEmpty()) {
                found = queryDoubanHdPosterUrl(cleanTitle, year);
            }
            // 3. Bangumi API -> images.large (official anime/drama HD key art)
            if (found.isEmpty()) {
                found = queryBangumiHdPosterUrl(cleanTitle);
            }
            // 4. Baidu Baike OpenAPI -> raw bcebos poster
            if (found.isEmpty()) {
                found = queryBaikeHdPosterUrl(cleanTitle);
            }
        } catch (Throwable ignored) {
        }
        HERO_HD_URL_CACHE.put(cacheKey, found);
        return found;
    }

    private static String fetchJsonText(String url, String referer, String cookie) {
        HttpURLConnection conn = null;
        try {
            conn = ProxyAddress.openHttpConnection(new URL(url));
            conn.setConnectTimeout(3500);
            conn.setReadTimeout(4500);
            conn.setRequestProperty("User-Agent", BROWSER_IMAGE_UA);
            conn.setRequestProperty("Accept", "application/json, text/plain, */*");
            if (referer != null && !referer.isEmpty()) {
                conn.setRequestProperty("Referer", referer);
            }
            if (cookie != null && !cookie.isEmpty()) {
                conn.setRequestProperty("Cookie", cookie);
            }
            RequestScope.attach(conn);
            if (conn.getResponseCode() != 200) return "";
            try (InputStream in = conn.getInputStream()) {
                ByteArrayOutputStream out = new ByteArrayOutputStream();
                byte[] buf = new byte[4096];
                int n;
                while ((n = in.read(buf)) != -1) {
                    RequestScope.current().check();
                    if (out.size() + n > 512 * 1024) break;
                    out.write(buf, 0, n);
                }
                return new String(out.toByteArray(), "UTF-8");
            }
        } catch (Throwable ignored) {
            return "";
        } finally {
            if (conn != null) {
                RequestScope.detach(conn);
                conn.disconnect();
            }
        }
    }

    private static String queryTmdbHdPosterUrl(MainActivity a, String cleanTitle) {
        try {
            String lang = a.mobilePrefs().getString(Prefs.TMDB_LANGUAGE, "zh-CN");
            String key = a.secretsPrefs().getString(Prefs.SECRET_TMDB_API_KEY, "").trim();
            if (key.isEmpty()) return "";
            String url =
                    TmdbService.apiBase(a)
                            + "/search/multi?language="
                            + lang
                            + "&query="
                            + java.net.URLEncoder.encode(cleanTitle, "UTF-8")
                            + (key.length() <= 64 ? "&api_key=" + key : "");
            HttpURLConnection conn = ProxyAddress.openHttpConnection(new URL(url));
            try {
                conn.setConnectTimeout(3500);
                conn.setReadTimeout(4500);
                conn.setRequestProperty("Accept", "application/json");
                if (key.length() > 64) {
                    conn.setRequestProperty("Authorization", "Bearer " + key);
                }
                RequestScope.attach(conn);
                if (conn.getResponseCode() != 200) return "";
                ByteArrayOutputStream out = new ByteArrayOutputStream();
                try (InputStream in = conn.getInputStream()) {
                    byte[] buf = new byte[4096];
                    int n;
                    while ((n = in.read(buf)) != -1) {
                        RequestScope.current().check();
                        if (out.size() + n > 512 * 1024) break;
                        out.write(buf, 0, n);
                    }
                }
                org.json.JSONObject obj =
                        new org.json.JSONObject(new String(out.toByteArray(), "UTF-8"));
                org.json.JSONArray results = obj.optJSONArray("results");
                if (results == null) return "";
                for (int i = 0; i < results.length(); i++) {
                    org.json.JSONObject item = results.optJSONObject(i);
                    if (item == null) continue;
                    String mt = item.optString("media_type", "");
                    if (!"movie".equals(mt) && !"tv".equals(mt)) continue;
                    String pPath = item.optString("poster_path", "");
                    if (!pPath.isEmpty() && !"null".equals(pPath)) {
                        return TmdbService.imageUrl(a, pPath, "w780");
                    }
                }
            } finally {
                RequestScope.detach(conn);
                conn.disconnect();
            }
        } catch (Throwable ignored) {
        }
        return "";
    }

    private static String queryDoubanHdPosterUrl(String cleanTitle, String year) {
        try {
            String url =
                    "https://movie.douban.com/j/subject_suggest?q="
                            + java.net.URLEncoder.encode(cleanTitle, "UTF-8");
            String body = fetchJsonText(url, "https://movie.douban.com/", "bid=" + DOUBAN_BID);
            if (body == null || !body.trim().startsWith("[")) return "";
            org.json.JSONArray arr = new org.json.JSONArray(body);
            String bestFallback = "";
            for (int i = 0; i < arr.length(); i++) {
                org.json.JSONObject it = arr.optJSONObject(i);
                if (it == null) continue;
                String type = it.optString("type", "");
                if ("celebrity".equalsIgnoreCase(type)) continue;
                String img = it.optString("img", "").trim();
                if (img.isEmpty()
                        || img.contains("/personage/")
                        || img.contains("/celebrity/")
                        || img.contains("movie_default")) {
                    continue;
                }
                String title = it.optString("title", "").trim();
                String itemYear = it.optString("year", "").trim();
                String upgraded = upgradePosterUrl(img, true);
                if (!year.isEmpty() && year.equals(itemYear) && title.contains(cleanTitle)) {
                    return upgraded;
                }
                if (bestFallback.isEmpty()
                        && (title.equalsIgnoreCase(cleanTitle)
                                || title.contains(cleanTitle)
                                || cleanTitle.contains(title))) {
                    bestFallback = upgraded;
                }
            }
            return bestFallback;
        } catch (Throwable ignored) {
            return "";
        }
    }

    private static String queryBangumiHdPosterUrl(String cleanTitle) {
        try {
            String url =
                    "https://api.bgm.tv/search/subject/"
                            + java.net.URLEncoder.encode(cleanTitle, "UTF-8")
                            + "?responseGroup=small&max_results=5";
            String body = fetchJsonText(url, "https://bgm.tv/", null);
            if (body == null || !body.trim().startsWith("{")) return "";
            org.json.JSONObject obj = new org.json.JSONObject(body);
            org.json.JSONArray list = obj.optJSONArray("list");
            if (list == null) return "";
            for (int i = 0; i < list.length(); i++) {
                org.json.JSONObject it = list.optJSONObject(i);
                if (it == null) continue;
                String nameCn = it.optString("name_cn", "").trim();
                String name = it.optString("name", "").trim();
                if (!nameCn.contains(cleanTitle)
                        && !cleanTitle.contains(nameCn)
                        && !name.contains(cleanTitle)) {
                    continue;
                }
                org.json.JSONObject images = it.optJSONObject("images");
                if (images == null) continue;
                String large = images.optString("large", "").trim();
                if (Cms.isHttp(large)
                        && !large.contains("/pic/crt/")
                        && !large.contains("/pic/user/")) {
                    return upgradePosterUrl(large, true);
                }
            }
        } catch (Throwable ignored) {
        }
        return "";
    }

    private static String queryBaikeHdPosterUrl(String cleanTitle) {
        try {
            String url =
                    "https://baike.baidu.com/api/openapi/BaikeLemmaCardApi?scope=103&format=json&appid=379020&bk_key="
                            + java.net.URLEncoder.encode(cleanTitle, "UTF-8");
            String body = fetchJsonText(url, "https://baike.baidu.com/", null);
            if (body == null || !body.trim().startsWith("{")) return "";
            org.json.JSONObject obj = new org.json.JSONObject(body);
            String img = obj.optString("image", "").trim();
            if (Cms.isHttp(img)) {
                return upgradePosterUrl(img, true);
            }
        } catch (Throwable ignored) {
        }
        return "";
    }

    private ImageLoader() {}

    static void cancel(MainActivity a) {
        synchronized (IN_FLIGHT) {
            IN_FLIGHT.clear();
        }
        for (Future<?> request : a.artworkRequests) request.cancel(true);
        a.artworkRequests.clear();
        ((ThreadPoolExecutor) a.artwork).purge();
    }

    static void trimMemory(MainActivity a, int level) {
        if (a.images == null) return;
        if (level >= ComponentCallbacks2.TRIM_MEMORY_BACKGROUND || level >= 15) {
            a.images.evictAll();
        } else if (level >= 10) {
            UiCompat.trimCache(a.images, a.images.maxSize() / 2);
        }
    }

    /**
     * Reloads any attached {@link ImageView} whose in-flight poster fetch was cancelled while
     * navigating to another screen (e.g. Home -> Detail -> Back to cached Home).
     */
    static void resumeMissingPosters(MainActivity a, View view) {
        if (a == null || view == null || a.isFinishing()) return;
        if (view instanceof ImageView) {
            ImageView iv = (ImageView) view;
            Object tag = iv.getTag();
            if (iv.getDrawable() == null && tag instanceof String) {
                String url = (String) tag;
                if (Cms.isHttp(url) || url.startsWith("catpaw://")) {
                    boolean detail;
                    synchronized (DETAIL_FLAGS) {
                        detail = Boolean.TRUE.equals(DETAIL_FLAGS.get(iv));
                    }
                    poster(a, url, iv, detail);
                }
            }
            return;
        }
        if (view instanceof android.view.ViewGroup) {
            android.view.ViewGroup group = (android.view.ViewGroup) view;
            for (int i = 0; i < group.getChildCount(); i++) {
                resumeMissingPosters(a, group.getChildAt(i));
            }
        }
    }

    /**
     * Detaches drawables from all {@link ImageView} nodes inside a detached/rebuilt view subtree so
     * uncached native {@link Bitmap} pixel buffers are eligible for immediate reclamation without
     * ever calling {@link Bitmap#recycle()} on potentially shared bitmaps.
     */
    static void detachImageViews(View view) {
        if (view == null) return;
        if (view instanceof ImageView) {
            ((ImageView) view).setImageDrawable(null);
            return;
        }
        if (view instanceof android.view.ViewGroup) {
            android.view.ViewGroup group = (android.view.ViewGroup) view;
            for (int i = 0; i < group.getChildCount(); i++) {
                detachImageViews(group.getChildAt(i));
            }
        }
    }

    /**
     * Memory-bounded loader for tiny decorative tiles (mood capsules, studio collages, 12-tile
     * mosaics) that decodes at compact bounds with {@code RGB_565} (~50–90 KB instead of 2+ MB).
     */
    static void posterCompact(
            MainActivity a, String address, ImageView image, int maxWidthPx, int maxHeightPx) {
        if (a == null || image == null) return;
        String normalized = normalizeArtworkAddress(address);
        Object previousTag = image.getTag();
        image.setTag(normalized);
        synchronized (DETAIL_FLAGS) {
            DETAIL_FLAGS.put(image, false);
        }
        if (!normalized.equals(previousTag)) {
            image.setImageDrawable(null);
        }
        if (!Cms.isHttp(normalized) && !normalized.startsWith("catpaw://")) return;
        final int w = Math.max(96, Math.min(240, maxWidthPx));
        final int h = Math.max(120, Math.min(320, maxHeightPx));
        final int ticket = a.generation;
        final boolean crop = image.getScaleType() == ImageView.ScaleType.CENTER_CROP;
        final String key = ImageDecodePolicy.cacheKey(normalized, w, h, crop, false);
        Bitmap immediate = a.images.get(key);
        if (immediate != null && !immediate.isRecycled()) {
            image.animate().cancel();
            image.setAlpha(1f);
            image.setImageBitmap(immediate);
            if (!a.isTvDevice()) com.pilipala.glass.GlassworkSurface.invalidateBackdrop(image);
            return;
        }
        startPosterLoadWithBounds(a, normalized, image, false, ticket, w, h);
    }

    static void poster(MainActivity a, String address, ImageView image, boolean detail) {
        String normalized = normalizeArtworkAddress(address);
        Object previousTag = image.getTag();
        image.setTag(normalized);
        synchronized (DETAIL_FLAGS) {
            DETAIL_FLAGS.put(image, detail);
        }
        if (!normalized.equals(previousTag)) {
            image.setImageDrawable(null);
        }
        if (!Cms.isHttp(normalized) && !normalized.startsWith("catpaw://")) return;
        address = normalized;
        final int ticket = a.generation;
        int initialW = ImageDecodePolicy.targetWidth(image.getWidth(), detail);
        int initialH = ImageDecodePolicy.targetHeight(image.getHeight(), detail);
        boolean initialCrop = image.getScaleType() == ImageView.ScaleType.CENTER_CROP;
        String initialKey =
                ImageDecodePolicy.cacheKey(address, initialW, initialH, initialCrop, detail);
        Bitmap immediate = a.images.get(initialKey);
        if (immediate != null && !immediate.isRecycled()) {
            image.animate().cancel();
            image.setAlpha(1f);
            image.setImageBitmap(immediate);
            if (!a.isTvDevice()) com.pilipala.glass.GlassworkSurface.invalidateBackdrop(image);
            return;
        }
        Bitmap preview = a.images.get(address);
        if (preview == null || preview.isRecycled()) {
            String gridKey =
                    ImageDecodePolicy.cacheKey(
                            address,
                            ImageDecodePolicy.targetWidth(0, false),
                            ImageDecodePolicy.targetHeight(0, false),
                            initialCrop,
                            false);
            preview = a.images.get(gridKey);
        }
        if ((preview == null || preview.isRecycled()) && !detail) {
            String detailKey =
                    ImageDecodePolicy.cacheKey(
                            address,
                            ImageDecodePolicy.targetWidth(0, true),
                            ImageDecodePolicy.targetHeight(0, true),
                            initialCrop,
                            true);
            preview = a.images.get(detailKey);
        }
        if (preview != null && !preview.isRecycled()) {
            image.animate().cancel();
            image.setAlpha(1f);
            image.setImageBitmap(preview);
            if (!a.isTvDevice()) com.pilipala.glass.GlassworkSurface.invalidateBackdrop(image);
            if (!detail || (preview.getWidth() >= initialW && preview.getHeight() >= initialH)) {
                return;
            }
        }
        startPosterLoad(a, address, image, detail, ticket);
    }

    private static void startPosterLoad(
            MainActivity a, String address, ImageView image, boolean detail, final int ticket) {
        if (ticket != a.generation || !address.equals(image.getTag())) return;
        final int width = ImageDecodePolicy.targetWidth(image.getWidth(), detail);
        final int height = ImageDecodePolicy.targetHeight(image.getHeight(), detail);
        startPosterLoadWithBounds(a, address, image, detail, ticket, width, height);
    }

    private static void startPosterLoadWithBounds(
            MainActivity a,
            String address,
            ImageView image,
            boolean detail,
            final int ticket,
            final int width,
            final int height) {
        if (ticket != a.generation || !address.equals(image.getTag())) return;
        final boolean crop = image.getScaleType() == ImageView.ScaleType.CENTER_CROP;
        final String key = ImageDecodePolicy.cacheKey(address, width, height, crop, detail);
        final String flightKey = ticket + "|" + key;
        Bitmap cached = a.images.get(key);
        if (cached != null && !cached.isRecycled()) {
            image.animate().cancel();
            image.setAlpha(1f);
            image.setImageBitmap(cached);
            if (!a.isTvDevice()) com.pilipala.glass.GlassworkSurface.invalidateBackdrop(image);
            return;
        }
        final InFlightEntry owned = new InFlightEntry(ticket, image);
        synchronized (IN_FLIGHT) {
            InFlightEntry existing = IN_FLIGHT.get(flightKey);
            if (existing != null && existing.ticket == ticket) {
                if (!existing.waiters.contains(image)) existing.waiters.add(image);
                return;
            }
            IN_FLIGHT.put(flightKey, owned);
        }
        Future<?> request =
                RequestScope.submit(
                        a.artwork,
                        () -> {
                            if (ticket != a.generation) {
                                synchronized (IN_FLIGHT) {
                                    if (IN_FLIGHT.get(flightKey) == owned)
                                        IN_FLIGHT.remove(flightKey);
                                }
                                return;
                            }
                            HttpURLConnection connection = null;
                            try {
                                Cms.ImageRequest source = Cms.imageRequest(address);
                                String resolvedUrl = Cms.normalizeHttp(source.url);
                                if (resolvedUrl.startsWith("catpaw://")) {
                                    resolvedUrl =
                                            new com.pilipala.catpaw.CatPawHost(a)
                                                    .resolve(resolvedUrl);
                                }
                                String targetUrl = upgradePosterUrl(resolvedUrl, detail);
                                byte[] bytes =
                                        fetchPosterBytesWithFallback(
                                                a, source, resolvedUrl, targetUrl, detail);
                                if (bytes == null || bytes.length == 0) return;
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
                                if (!detail) {
                                    options.inPreferredConfig = Bitmap.Config.RGB_565;
                                }
                                options.inJustDecodeBounds = false;
                                RequestScope.current().check();
                                Bitmap bitmap =
                                        BitmapFactory.decodeByteArray(
                                                bytes, 0, bytes.length, options);
                                if (bitmap != null) {
                                    if (ticket != a.generation
                                            || Thread.currentThread().isInterrupted()) {
                                        bitmap.recycle();
                                        return;
                                    }
                                    a.images.put(key, bitmap);
                                    final java.util.List<ImageView> targets;
                                    synchronized (IN_FLIGHT) {
                                        InFlightEntry removed =
                                                IN_FLIGHT.get(flightKey) == owned
                                                        ? IN_FLIGHT.remove(flightKey)
                                                        : null;
                                        targets =
                                                removed == null
                                                        ? java.util.Collections.singletonList(image)
                                                        : new java.util.ArrayList<>(
                                                                removed.waiters);
                                    }
                                    a.ui.post(
                                            () -> {
                                                if (ticket != a.generation || a.isFinishing())
                                                    return;
                                                boolean tv = a.isTvDevice();
                                                boolean reduced = tv || MobileMotion.isReduced(a);
                                                for (ImageView target : targets) {
                                                    if (target != null
                                                            && address.equals(target.getTag())) {
                                                        boolean wasEmpty =
                                                                target.getDrawable() == null;
                                                        target.setImageBitmap(bitmap);
                                                        if (!tv) {
                                                            if (wasEmpty && !reduced) {
                                                                target.animate().cancel();
                                                                target.setAlpha(0f);
                                                                target.animate()
                                                                        .alpha(1f)
                                                                        .setDuration(
                                                                                MotionTokens
                                                                                        .DURATION_FAST_MS)
                                                                        .setInterpolator(
                                                                                MotionTokens
                                                                                        .createDecelerateInterpolator())
                                                                        .start();
                                                            } else {
                                                                target.animate().cancel();
                                                                target.setAlpha(1f);
                                                            }
                                                            com.pilipala.glass.GlassworkSurface
                                                                    .invalidateBackdrop(target);
                                                        }
                                                    }
                                                }
                                            });
                                }
                            } catch (Throwable error) {
                                if (!(error instanceof java.io.InterruptedIOException)
                                        && !Thread.currentThread().isInterrupted()) {
                                    AppLog.w("ImageLoader", "poster load failed", error);
                                }
                            } finally {
                                synchronized (IN_FLIGHT) {
                                    if (IN_FLIGHT.get(flightKey) == owned)
                                        IN_FLIGHT.remove(flightKey);
                                }
                                if (connection != null) {
                                    RequestScope.detach(connection);
                                    connection.disconnect();
                                }
                            }
                        });
        for (java.util.Iterator<Future<?>> it = a.artworkRequests.iterator(); it.hasNext(); ) {
            if (it.next().isDone()) it.remove();
        }
        a.artworkRequests.add(request);
    }

    private static File heroDiskCacheFile(MainActivity a, String heroDiskKey) {
        try {
            File dir = new File(a.getCacheDir(), "hero_posters_v1");
            if (!dir.exists()) dir.mkdirs();
            java.security.MessageDigest md = java.security.MessageDigest.getInstance("SHA-256");
            byte[] d = md.digest(heroDiskKey.getBytes("UTF-8"));
            StringBuilder sb = new StringBuilder(32);
            for (int i = 0; i < 16; i++) {
                sb.append(String.format(java.util.Locale.ROOT, "%02x", d[i] & 255));
            }
            return new File(dir, sb.toString() + ".img");
        } catch (Exception e) {
            return null;
        }
    }

    private static byte[] readHeroDiskPosterBytes(MainActivity a, String heroDiskKey) {
        try {
            File f = heroDiskCacheFile(a, heroDiskKey);
            if (f == null || !f.isFile()) return null;
            long len = f.length();
            if (len <= 128 || len > 8 * 1024 * 1024) return null;
            if (System.currentTimeMillis() - f.lastModified() > 7L * 24 * 3600 * 1000L) {
                return null;
            }
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
            f.setLastModified(System.currentTimeMillis());
            return buf;
        } catch (Exception e) {
            return null;
        }
    }

    private static void writeHeroDiskPosterBytes(MainActivity a, String heroDiskKey, byte[] bytes) {
        if (a == null || a.privateMode || bytes == null || bytes.length <= 128) return;
        try {
            File f = heroDiskCacheFile(a, heroDiskKey);
            if (f == null) return;
            try (java.io.FileOutputStream out = new java.io.FileOutputStream(f)) {
                out.write(bytes);
            }
            File dir = f.getParentFile();
            if (dir != null && dir.isDirectory()) {
                File[] files = dir.listFiles();
                if (files != null && files.length > 18) {
                    java.util.Arrays.sort(
                            files, (x, y) -> Long.compare(x.lastModified(), y.lastModified()));
                    for (int i = 0; i < files.length - 16; i++) {
                        try {
                            files[i].delete();
                        } catch (Throwable ignored) {
                        }
                    }
                }
            }
        } catch (Exception ignored) {
        }
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

    private static byte[] readDiskCachedPoster(MainActivity a, String url) {
        try {
            File f = diskCacheFile(a, url);
            if (f == null || !f.isFile()) return null;
            long len = f.length();
            if (len <= 128 || len > 8 * 1024 * 1024) return null;
            if (System.currentTimeMillis() - f.lastModified() > 7L * 24 * 3600 * 1000L) {
                return null;
            }
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
        return trimmed;
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
        boolean hasCustomUa = source.headers.containsKey("User-Agent");
        String[] userAgents =
                hasCustomUa
                        ? new String[] {source.headers.get("User-Agent")}
                        : new String[] {BROWSER_IMAGE_UA, Cms.USER_AGENT};
        for (String candidate : candidates) {
            if (candidate == null || candidate.isEmpty() || !tried.add(candidate)) continue;
            byte[] cached = readDiskCachedPoster(a, candidate);
            if (cached != null) return cached;
            for (String ua : userAgents) {
                HttpURLConnection connection = null;
                try {
                    String currentUrl = candidate;
                    for (int hop = 0; hop < 4; hop++) {
                        if (connection != null) {
                            RequestScope.detach(connection);
                            connection.disconnect();
                        }
                        connection = ProxyAddress.openHttpConnection(new URL(currentUrl));
                        connection.setInstanceFollowRedirects(false);
                        for (Map.Entry<String, String> header : source.headers.entrySet())
                            connection.setRequestProperty(header.getKey(), header.getValue());
                        String fragment = new URL(currentUrl).getRef();
                        if (fragment != null && fragment.startsWith("mm-emby=")) {
                            com.pilipala.emby.EmbyLibrary library =
                                    com.pilipala.emby.EmbyAccounts.open(
                                            a, "emby://account/" + fragment.substring(8));
                            for (Map.Entry<String, String> h :
                                    library.imageHeaders(currentUrl).entrySet())
                                connection.setRequestProperty(h.getKey(), h.getValue());
                        }
                        applyArtworkHeaders(connection, currentUrl, source.headers);
                        connection.setConnectTimeout(4500);
                        connection.setReadTimeout(5500);
                        if (!hasCustomUa && ua != null) {
                            connection.setRequestProperty("User-Agent", ua);
                        }
                        RequestScope.attach(connection);
                        int code = connection.getResponseCode();
                        if (code >= 300 && code < 400 && code != 304) {
                            String loc = connection.getHeaderField("Location");
                            if (loc == null || loc.trim().isEmpty()) break;
                            currentUrl = new URL(new URL(currentUrl), loc.trim()).toString();
                            continue;
                        }
                        break;
                    }
                    if (connection == null) continue;
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
                        if (bytes.length > 128) {
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
        if (lastError != null) throw lastError;
        return null;
    }

    static String upgradePosterUrl(String rawUrl, boolean detail) {
        if (rawUrl == null || rawUrl.isEmpty()) return "";
        String url = rawUrl.trim();
        if (url.startsWith("//")) url = "https:" + url;
        if (url.contains("doubanio.com")) {
            url =
                    url.replaceAll(
                            "https?://(?:img[4-9]|qnmob\\d*-sign)\\.doubanio\\.com/",
                            "https://img3.doubanio.com/");
            int qIdx = url.indexOf('?');
            if (qIdx > 0 && url.substring(0, qIdx).matches("(?i).*\\.(?:jpg|jpeg|webp|png)$")) {
                url = url.substring(0, qIdx);
            }
            if (detail) {
                url =
                        url.replace("/s_ratio_poster/", "/l_ratio_poster/")
                                .replace("/m_ratio_poster/", "/l_ratio_poster/")
                                .replace("/view/photo/spic/", "/view/photo/lpic/")
                                .replace("/view/photo/mpic/", "/view/photo/lpic/")
                                .replace("/view/photo/sqxs/", "/view/photo/l/")
                                .replace("/view/photo/s/", "/view/photo/l/")
                                .replace("/view/photo/m/", "/view/photo/l/")
                                .replace("/view/subject/s/", "/view/subject/l/")
                                .replace("/view/subject/m/", "/view/subject/l/")
                                .replace("/view/photo/large/", "/view/photo/l_ratio_poster/");
                if (url.endsWith(".webp")) {
                    url = url.substring(0, url.length() - 5) + ".jpg";
                }
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
                if (url.startsWith("http://")) url = "https://" + url.substring(7);
                url =
                        url.replace("/pic/cover/c/", "/pic/cover/l/")
                                .replace("/pic/cover/m/", "/pic/cover/l/")
                                .replace("/pic/cover/s/", "/pic/cover/l/")
                                .replace("/pic/cover/g/", "/pic/cover/l/")
                                .replace("/r/400/", "/r/800/");
            }
            if (url.contains("hdslb.com") || url.contains("biliimg.com")) {
                if (url.startsWith("http://")) url = "https://" + url.substring(7);
                int at = url.indexOf('@');
                if (at > 0) url = url.substring(0, at);
            }
            if (url.contains("bcebos.com")) {
                int q = url.indexOf('?');
                if (q > 0) url = url.substring(0, q);
            } else {
                // Strip unsigned OSS / COS / Qiniu thumbnail resize directives for full-res origin
                int q = url.indexOf('?');
                if (q > 0) {
                    String lowerQ = url.substring(q + 1).toLowerCase(Locale.ROOT);
                    boolean resizeOnly =
                            (lowerQ.contains("x-oss-process=image/resize")
                                            || lowerQ.startsWith("imageview2/")
                                            || lowerQ.startsWith("imagemogr2/"))
                                    && !lowerQ.contains("signature")
                                    && !lowerQ.contains("sign=")
                                    && !lowerQ.contains("token=")
                                    && !lowerQ.contains("expires=")
                                    && !lowerQ.contains("ossaccesskeyid=");
                    if (resizeOnly) {
                        url = url.substring(0, q);
                    }
                }
            }
        }
        return url;
    }

    static void applyArtworkHeaders(
            HttpURLConnection connection, String url, Map<String, String> existing) {
        if (existing != null && existing.containsKey("Referer")) return;
        String lower = url.toLowerCase(Locale.ROOT);
        if (lower.contains("doubanio.com") || lower.contains("douban.com")) {
            connection.setRequestProperty("Referer", "https://movie.douban.com/");
            if (existing == null || !existing.containsKey("Cookie")) {
                connection.setRequestProperty("Cookie", "bid=" + DOUBAN_BID);
            }
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
        } else if (lower.contains("sinaimg.cn")) {
            connection.setRequestProperty("Referer", "https://weibo.com/");
        }
    }

    static View createAtmosphere(MainActivity a) {
        return new Atmosphere(a);
    }

    static final class Atmosphere extends View {
        final MainActivity a;
        final Paint paint = new Paint(3);
        Bitmap wallpaper;

        Atmosphere(Context c) {
            super(c);
            a = (MainActivity) c;
            reloadWallpaper();
        }

        void reloadWallpaper() {
            wallpaper = null;
            boolean showWallpaper =
                    a.isTvDevice()
                            ? HomeAmbient.effectiveBgMode(a) == Prefs.BG_MODE_WALLPAPER
                            : a.prefs.getBoolean(Prefs.WALLPAPER_ENABLED, false);
            if (showWallpaper) {
                File f = new File(a.getFilesDir(), "wallpaper.jpg");
                if (f.exists()) {
                    try {
                        BitmapFactory.Options bounds = new BitmapFactory.Options();
                        bounds.inJustDecodeBounds = true;
                        BitmapFactory.decodeFile(f.getAbsolutePath(), bounds);
                        if (bounds.outWidth > 0 && bounds.outHeight > 0) {
                            BitmapFactory.Options opts = new BitmapFactory.Options();
                            int sample = 1;
                            while ((bounds.outWidth / (sample * 2)) >= 1280
                                    && (bounds.outHeight / (sample * 2)) >= 720) {
                                sample *= 2;
                            }
                            opts.inSampleSize = sample;
                            opts.inPreferredConfig = Bitmap.Config.RGB_565;
                            wallpaper = BitmapFactory.decodeFile(f.getAbsolutePath(), opts);
                        }
                    } catch (Throwable ignored) {
                        wallpaper = null;
                    }
                }
            }
            invalidate();
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
            wallpaper = null;
        }
    }
}
