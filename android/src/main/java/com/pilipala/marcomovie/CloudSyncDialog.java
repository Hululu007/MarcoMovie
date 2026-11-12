package com.pilipala.marcomovie;

import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.SharedPreferences;
import android.graphics.Color;
import android.graphics.Typeface;
import android.os.Handler;
import android.os.Looper;
import android.text.InputType;
import android.view.Gravity;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import java.io.File;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Date;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.lang.ref.WeakReference;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;

/**
 * UI dialog and background coordinator for multi-device WebDAV cloud sync and LAN peer-to-peer
 * bidirectional sync ({@code marco-movie-sync} v2: watch history, favorites, and optional public
 * subscriptions).
 */
final class CloudSyncDialog {
    private static final ExecutorService SYNC_EXEC =
            Executors.newSingleThreadExecutor(
                    r -> {
                        Thread t = new Thread(r, "marco-cloud-sync");
                        t.setDaemon(true);
                        return t;
                    });
    private static final Handler MAIN = new Handler(Looper.getMainLooper());
    private static final AtomicBoolean IN_FLIGHT = new AtomicBoolean(false);
    private static volatile long lastAutoPushMs = 0L;
    private static Runnable pendingAutoPush;
    private static WeakReference<MainActivity> pendingActivityRef;
    private static WeakReference<AppDialog> activeDialogRef;

    static void cancel() {
        if (pendingAutoPush != null) {
            MAIN.removeCallbacks(pendingAutoPush);
            pendingAutoPush = null;
        }
        pendingActivityRef = null;
        if (activeDialogRef != null) {
            AppDialog d = activeDialogRef.get();
            if (d != null) {
                try {
                    d.dismiss();
                } catch (Exception ignored) {
                }
            }
            activeDialogRef = null;
        }
    }

    private CloudSyncDialog() {}

    static boolean isConfigured(MainActivity a) {
        if (a == null || a.prefs == null) return false;
        String url = a.prefs.getString(Prefs.WEBDAV_URL, "").trim();
        return !url.isEmpty();
    }

    static boolean isAutoEnabled(MainActivity a) {
        return a != null && a.prefs != null && a.prefs.getBoolean(Prefs.WEBDAV_AUTO, true);
    }

    static boolean isSyncSubscriptionsEnabled(MainActivity a) {
        return a != null && a.prefs != null && a.prefs.getBoolean(Prefs.WEBDAV_SYNC_SUBS, true);
    }

    static String statusSummary(MainActivity a) {
        if (a == null || a.prefs == null) return "未配置";
        if (a.privateMode) return "隐私空间已隔离（不参与云同步）";
        if (!isConfigured(a)) return "支持坚果云 / Nextcloud / Alist / 群晖 WebDAV 与局域网互传";
        boolean auto = a.prefs.getBoolean(Prefs.WEBDAV_AUTO, true);
        boolean subs = a.prefs.getBoolean(Prefs.WEBDAV_SYNC_SUBS, true);
        long lastTs = a.prefs.getLong(Prefs.SYNC_LAST_TIME, 0L);
        String lastStatus = a.prefs.getString(Prefs.SYNC_LAST_STATUS, "");
        String mode = (auto ? "自动云同步" : "手动云同步") + (subs ? " · 含订阅源" : " · 仅进度收藏");
        if (lastTs > 0L) {
            String timeStr =
                    new SimpleDateFormat("MM-dd HH:mm", Locale.CHINA).format(new Date(lastTs));
            return mode
                    + " · 上次 "
                    + timeStr
                    + (lastStatus.isEmpty() ? "" : " (" + lastStatus + ")");
        }
        return mode + (lastStatus.isEmpty() ? "" : " · " + lastStatus);
    }

    /** Records a local watch-history deletion tombstone and schedules an auto-push. */
    static void onHistoryDeleted(MainActivity a, String itemKey) {
        if (a == null || a.privateMode || a.prefs == null || itemKey == null || itemKey.isEmpty())
            return;
        String next =
                CloudSync.Tombstones.recordHistoryDelete(
                        a.prefs.getString(Prefs.SYNC_TOMBSTONES, ""),
                        itemKey,
                        System.currentTimeMillis());
        a.prefs.edit().putString(Prefs.SYNC_TOMBSTONES, next).apply();
        scheduleAutoPush(a, true);
    }

    /** Records deletion tombstones for all cleared watch-history items and schedules auto-push. */
    static void onHistoryCleared(MainActivity a, List<WatchHistory.Entry> previousEntries) {
        if (a == null || a.privateMode || a.prefs == null) return;
        String next =
                CloudSync.Tombstones.recordHistoryClear(
                        a.prefs.getString(Prefs.SYNC_TOMBSTONES, ""),
                        previousEntries,
                        System.currentTimeMillis());
        a.prefs.edit().putString(Prefs.SYNC_TOMBSTONES, next).apply();
        scheduleAutoPush(a, true);
    }

    /** Records a local favorite addition/removal timestamp and schedules auto-push. */
    static void onFavoriteToggled(
            MainActivity a, String siteKey, String videoId, boolean nowFavorited) {
        if (a == null
                || a.privateMode
                || a.prefs == null
                || siteKey == null
                || videoId == null
                || siteKey.isEmpty()
                || videoId.isEmpty()) return;
        String itemKey = siteKey + "\n" + videoId;
        String next =
                CloudSync.Tombstones.recordFavoriteToggle(
                        a.prefs.getString(Prefs.SYNC_TOMBSTONES, ""),
                        itemKey,
                        nowFavorited,
                        System.currentTimeMillis());
        a.prefs.edit().putString(Prefs.SYNC_TOMBSTONES, next).apply();
        scheduleAutoPush(a, true);
    }

    /** Clears any prior deletion tombstone when a public subscription is imported or updated. */
    static void onSubscriptionSaved(MainActivity a, String origin, String raw) {
        if (a == null || a.privateMode || a.prefs == null) return;
        if (origin != null && origin.toLowerCase(Locale.ROOT).startsWith("file:")) return;
        try {
            String cleanUrl = origin != null && Cms.isHttp(origin.trim()) ? origin.trim() : "";
            String publicRaw = CloudSync.sanitizePublicRawConfig(raw);
            if (cleanUrl.isEmpty() && publicRaw.isEmpty()) return;
            String subId = ConfigLibrary.identity(cleanUrl, publicRaw);
            String next =
                    CloudSync.Tombstones.recordSubscriptionUpsert(
                            a.prefs.getString(Prefs.SYNC_TOMBSTONES, ""), subId);
            a.prefs.edit().putString(Prefs.SYNC_TOMBSTONES, next).apply();
            if (isSyncSubscriptionsEnabled(a)) {
                scheduleAutoPush(a, true);
            }
        } catch (Exception ignored) {
        }
    }

    /** Records a subscription deletion tombstone so deleted subscriptions do not resurrect. */
    static void onSubscriptionDeleted(MainActivity a, String subId) {
        if (a == null || a.privateMode || a.prefs == null || subId == null || subId.isEmpty())
            return;
        String next =
                CloudSync.Tombstones.recordSubscriptionDelete(
                        a.prefs.getString(Prefs.SYNC_TOMBSTONES, ""),
                        subId,
                        System.currentTimeMillis());
        a.prefs.edit().putString(Prefs.SYNC_TOMBSTONES, next).apply();
        if (isSyncSubscriptionsEnabled(a)) {
            scheduleAutoPush(a, true);
        }
    }

    /** Schedules a background WebDAV sync when automatic cloud sync is enabled. */
    static void scheduleAutoPush(final MainActivity a, boolean immediate) {
        if (a == null || a.isDestroyed() || a.isFinishing() || a.privateMode || a.prefs == null)
            return;
        if (!isConfigured(a) || !a.prefs.getBoolean(Prefs.WEBDAV_AUTO, true)) return;
        long now = System.currentTimeMillis();
        long delayMs;
        if (immediate) {
            delayMs = 2500L;
        } else {
            long minInterval = 300000L; // 5 minutes
            long elapsed = now - lastAutoPushMs;
            if (elapsed < minInterval) {
                delayMs = minInterval - elapsed;
            } else {
                delayMs = 3000L;
            }
        }
        if (pendingAutoPush != null) {
            MAIN.removeCallbacks(pendingAutoPush);
        }
        final WeakReference<MainActivity> weakAct = new WeakReference<>(a);
        pendingActivityRef = weakAct;
        pendingAutoPush =
                () -> {
                    pendingAutoPush = null;
                    pendingActivityRef = null;
                    MainActivity act = weakAct.get();
                    if (act != null
                            && !act.isFinishing()
                            && !act.isDestroyed()
                            && !act.privateMode) {
                        runWebdavSync(act, true, null);
                    }
                };
        MAIN.postDelayed(pendingAutoPush, delayMs);
    }

    /** Silently pulls and merges cloud state shortly after app launch. */
    static void pullOnStartup(final MainActivity a) {
        if (a == null || a.isDestroyed() || a.isFinishing() || a.privateMode || a.prefs == null)
            return;
        if (!isConfigured(a) || !a.prefs.getBoolean(Prefs.WEBDAV_AUTO, true)) return;
        final WeakReference<MainActivity> weakAct = new WeakReference<>(a);
        MAIN.postDelayed(
                () -> {
                    MainActivity act = weakAct.get();
                    if (act != null
                            && !act.isFinishing()
                            && !act.isDestroyed()
                            && !act.privateMode) {
                        runWebdavSync(
                                act,
                                true,
                                () -> {
                                    if (act.current != null
                                            && act.current.home
                                            && act.player == null) {
                                        act.refresh();
                                    }
                                });
                    }
                },
                1800L);
    }

    /** Collects non-private subscriptions from {@link ConfigLibrary} and active config. */
    static List<CloudSync.SubscriptionItem> collectPublicSubscriptions(MainActivity a) {
        List<CloudSync.SubscriptionItem> out = new ArrayList<>();
        if (a == null || a.privateMode || a.configStore == null) return out;
        try {
            ConfigLibrary library = new ConfigLibrary(a.configStore.directory);
            if (a.config != null
                    && a.config.raw != null
                    && !a.config.raw.isEmpty()
                    && (a.configOrigin == null
                            || !a.configOrigin.toLowerCase(Locale.ROOT).startsWith("file:"))) {
                try {
                    library.rememberIfAbsent(
                            a.config.raw,
                            a.configOrigin,
                            SourceController.configName(a.config),
                            a.prefs.getString(Prefs.SELECTED_SITE, ""));
                } catch (Exception ignored) {
                }
            }
            String activeId = "";
            if (a.config != null && a.config.raw != null && !a.config.raw.isEmpty()) {
                try {
                    activeId = ConfigLibrary.identity(a.configOrigin, a.config.raw);
                } catch (Exception ignored) {
                }
            }
            String currentSelectedSite = a.prefs.getString(Prefs.SELECTED_SITE, "");
            for (ConfigLibrary.Entry entry : library.entries()) {
                if (entry.origin != null
                        && entry.origin.toLowerCase(Locale.ROOT).startsWith("file:")) {
                    continue;
                }
                try {
                    String raw = library.raw(entry);
                    String sel =
                            entry.id.equals(activeId) && !currentSelectedSite.isEmpty()
                                    ? currentSelectedSite
                                    : entry.selected;
                    CloudSync.SubscriptionItem item =
                            CloudSync.SubscriptionItem.create(
                                    entry.name, entry.origin, raw, true, sel, entry.updated);
                    if (item != null) out.add(item);
                } catch (Exception ignored) {
                }
            }
        } catch (Exception ignored) {
        }
        return out;
    }

    /**
     * Persists merged subscriptions into {@link ConfigLibrary} (fetching remote HTTP configs if
     * only a URL was present) and updates {@code a.config} on the UI thread when needed.
     */
    private static boolean applyMergedSubscriptions(
            final MainActivity a,
            List<CloudSync.SubscriptionItem> mergedSubs,
            String tombstonesJson) {
        if (a == null || a.privateMode || a.configStore == null || mergedSubs == null) {
            return false;
        }
        ConfigLibrary library = new ConfigLibrary(a.configStore.directory);
        CloudSync.Tombstones tombs = CloudSync.Tombstones.read(tombstonesJson);
        Set<String> keepIds = new HashSet<>();
        CloudSync.SubscriptionItem firstValid = null;
        String firstValidRaw = null;

        for (CloudSync.SubscriptionItem sub : mergedSubs) {
            if (sub == null) continue;
            String raw = sub.rawContent == null ? "" : sub.rawContent.trim();
            String origin = sub.url == null ? "" : sub.url.trim();
            if (raw.isEmpty() && Cms.isHttp(origin)) {
                try {
                    raw = SourceController.fetchImport(a, origin);
                    origin = SourceController.importOrigin(origin);
                } catch (Exception ignored) {
                }
            }
            if (raw.isEmpty()) continue;
            try {
                Cms.Config parsed = Cms.parseConfig(raw, origin);
                String name =
                        sub.name == null
                                        || sub.name.isEmpty()
                                        || "我的订阅".equals(sub.name)
                                        || "备份订阅".equals(sub.name)
                                ? SourceController.configName(parsed)
                                : sub.name;
                ConfigLibrary.Entry saved =
                        library.remember(raw, origin, name, sub.selectedSiteKey, sub.updatedAt);
                keepIds.add(saved.id);
                if (firstValid == null && sub.enabled) {
                    firstValid = sub;
                    firstValidRaw = raw;
                }
            } catch (Exception ignored) {
            }
        }

        boolean removedActive = false;
        String activeId = "";
        if (a.config != null && a.config.raw != null && !a.config.raw.isEmpty()) {
            try {
                activeId = ConfigLibrary.identity(a.configOrigin, a.config.raw);
            } catch (Exception ignored) {
            }
        }
        try {
            for (ConfigLibrary.Entry existing : library.entries()) {
                if (existing.origin != null
                        && existing.origin.toLowerCase(Locale.ROOT).startsWith("file:")) {
                    continue;
                }
                if (!keepIds.contains(existing.id)
                        && tombs.get("sub:" + existing.id) >= existing.updated) {
                    library.remove(existing.id);
                    if (existing.id.equals(activeId)) {
                        removedActive = true;
                    }
                }
            }
        } catch (Exception ignored) {
        }

        final boolean needActivateNew =
                (a.config == null && firstValid != null && firstValidRaw != null) || removedActive;
        if (!needActivateNew) {
            return !keepIds.isEmpty();
        }

        String targetRaw = firstValidRaw;
        String targetOrigin = firstValid != null ? firstValid.url : "";
        String targetSelected = firstValid != null ? firstValid.selectedSiteKey : "";
        if (targetRaw == null) {
            try {
                List<ConfigLibrary.Entry> remaining = library.entries();
                if (!remaining.isEmpty()) {
                    ConfigLibrary.Entry fallback = remaining.get(0);
                    targetRaw = library.raw(fallback);
                    targetOrigin = fallback.origin;
                    targetSelected = fallback.selected;
                }
            } catch (Exception ignored) {
            }
        }

        final String finalRaw = targetRaw;
        final String finalOrigin = targetOrigin == null ? "" : targetOrigin;
        final String finalSelected = targetSelected == null ? "" : targetSelected;
        final boolean finalRemovedActive = removedActive;
        CountDownLatch uiLatch = new CountDownLatch(1);
        final AtomicReference<Throwable> uiError = new AtomicReference<>();
        a.ui.post(
                () -> {
                    try {
                        if (a.isFinishing() || a.isDestroyed() || a.privateMode) return;
                        if (finalRaw != null && !finalRaw.isEmpty()) {
                            Cms.Config parsed = Cms.parseConfig(finalRaw, finalOrigin);
                            a.configStore.write(parsed.raw);
                            SourcePicker.applyEdits(a, parsed, finalOrigin);
                            a.closeEngines();
                            a.config = parsed;
                            a.configOrigin = finalOrigin;
                            SharedPreferences.Editor ed =
                                    a.prefs.edit().putString(Prefs.ORIGIN, finalOrigin);
                            String pickSite = "";
                            for (Cms.Site s : parsed.sites) {
                                if (SourceController.available(a, s)) {
                                    if (pickSite.isEmpty()) pickSite = s.key;
                                    if (!finalSelected.isEmpty() && s.key.equals(finalSelected)) {
                                        pickSite = s.key;
                                        break;
                                    }
                                }
                            }
                            if (!pickSite.isEmpty()) ed.putString(Prefs.SELECTED_SITE, pickSite);
                            ed.apply();
                        } else if (finalRemovedActive) {
                            new File(a.getFilesDir(), "config.json").delete();
                            a.closeEngines();
                            a.config = null;
                            a.configOrigin = "";
                            a.prefs.edit().remove(Prefs.ORIGIN).remove(Prefs.SELECTED_SITE).apply();
                        }
                    } catch (Throwable t) {
                        uiError.set(t);
                    } finally {
                        uiLatch.countDown();
                    }
                });
        boolean completed = false;
        try {
            completed = uiLatch.await(15, TimeUnit.SECONDS);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new java.io.IOException("UI 主线程应用合并配置中断", e);
        }
        if (!completed) {
            throw new java.io.IOException("UI 主线程应用合并配置超时 (15s)");
        }
        if (uiError.get() != null) {
            throw new java.io.IOException(
                    "UI 主线程应用配置失败: " + uiError.get().getMessage(), uiError.get());
        }
        return true;
    }

    private static void runOnMainSync(MainActivity a, Runnable task) throws java.io.IOException {
        if (android.os.Looper.myLooper() == android.os.Looper.getMainLooper()) {
            task.run();
            return;
        }
        CountDownLatch latch = new CountDownLatch(1);
        final AtomicReference<Throwable> mainError = new AtomicReference<>();
        a.ui.post(
                () -> {
                    try {
                        task.run();
                    } catch (Throwable t) {
                        mainError.set(t);
                    } finally {
                        latch.countDown();
                    }
                });
        try {
            if (!latch.await(15, TimeUnit.SECONDS)) {
                throw new java.io.IOException("主线程同步超时 (15s)");
            }
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new java.io.IOException("主线程同步中断", e);
        }
        if (mainError.get() != null) {
            throw new java.io.IOException(
                    "主线程执行失败: " + mainError.get().getMessage(), mainError.get());
        }
    }

    private static CloudSync.MergeResult mergeAndPersistLocal(
            MainActivity a, String remoteJson, long now) throws Exception {
        final String[] snap = new String[3];
        final boolean[] syncSubsHolder = new boolean[1];
        runOnMainSync(
                a,
                () -> {
                    snap[0] = a.prefs.getString(Prefs.WATCH_HISTORY, "[]");
                    snap[1] = a.prefs.getString(Prefs.FAVORITES, "[]");
                    snap[2] = a.prefs.getString(Prefs.SYNC_TOMBSTONES, "");
                    syncSubsHolder[0] = isSyncSubscriptionsEnabled(a);
                });
        boolean syncSubs = syncSubsHolder[0];
        List<CloudSync.SubscriptionItem> localSubs =
                syncSubs ? collectPublicSubscriptions(a) : null;

        CloudSync.MergeResult res =
                CloudSync.merge(snap[0], snap[1], snap[2], localSubs, syncSubs, remoteJson, now);

        final boolean isHistCorrupt =
                WatchHistory.isCorrupted() || a.prefs.getBoolean("watch_history_corrupted", false);
        runOnMainSync(
                a,
                () -> {
                    SharedPreferences.Editor ed = a.prefs.edit();
                    if (!isHistCorrupt) {
                        ed.putString(Prefs.WATCH_HISTORY, res.historyJson);
                    }
                    ed.putString(Prefs.FAVORITES, res.favoritesJson)
                            .putString(Prefs.SYNC_TOMBSTONES, res.tombstonesJson)
                            .apply();
                });

        if (syncSubs && res.subscriptions != null) {
            applyMergedSubscriptions(a, res.subscriptions, res.tombstonesJson);
        }
        return res;
    }

    private static String exportCurrentPayload(MainActivity a, long now) throws Exception {
        final String[] snap = new String[3];
        final boolean[] syncSubsHolder = new boolean[1];
        runOnMainSync(
                a,
                () -> {
                    snap[0] = a.prefs.getString(Prefs.WATCH_HISTORY, "[]");
                    snap[1] = a.prefs.getString(Prefs.FAVORITES, "[]");
                    snap[2] = a.prefs.getString(Prefs.SYNC_TOMBSTONES, "");
                    syncSubsHolder[0] = isSyncSubscriptionsEnabled(a);
                });
        boolean syncSubs = syncSubsHolder[0];
        List<CloudSync.SubscriptionItem> localSubs =
                syncSubs ? collectPublicSubscriptions(a) : null;
        return CloudSync.exportPayload(snap[0], snap[1], snap[2], localSubs, syncSubs, now);
    }

    /** Sync handler mounted onto {@link ConfigTransferServer} for LAN peer-to-peer sync. */
    static ConfigTransferServer.SyncHandler lanSyncHandler(final MainActivity a) {
        return remotePayloadJson -> {
            if (a.privateMode) {
                throw new IllegalStateException("隐私空间不允许局域网同步");
            }
            long now = System.currentTimeMillis();
            if (remotePayloadJson == null) {
                return exportCurrentPayload(a, now);
            }
            CloudSync.MergeResult merged = mergeAndPersistLocal(a, remotePayloadJson, now);
            final String summary = formatCounts("局域网已合并", merged, isSyncSubscriptionsEnabled(a));
            a.ui.post(
                    () -> {
                        a.prefs
                                .edit()
                                .putLong(Prefs.SYNC_LAST_TIME, now)
                                .putString(Prefs.SYNC_LAST_STATUS, summary)
                                .apply();
                        if (!a.isFinishing()) {
                            a.toast(summary);
                            if (a.current != null && a.current.home && a.player == null) {
                                a.refresh();
                            }
                        }
                    });
            return merged.payloadJson;
        };
    }

    private static String formatCounts(
            String prefix, CloudSync.MergeResult r, boolean includeSubs) {
        String base = prefix + " · 历史 " + r.historyCount + " / 收藏 " + r.favoriteCount;
        return includeSubs ? base + " / 订阅 " + r.subscriptionCount : base;
    }

    static void runWebdavSync(
            final MainActivity a, final boolean silent, final Runnable onComplete) {
        if (a == null || a.isDestroyed() || a.isFinishing() || a.privateMode || a.prefs == null) {
            if (!silent && a != null && !a.isDestroyed() && !a.isFinishing() && a.privateMode) {
                a.toast("隐私空间数据不参与网络同步");
            }
            return;
        }
        final String url = a.prefs.getString(Prefs.WEBDAV_URL, "").trim();
        final String user = a.prefs.getString(Prefs.WEBDAV_USER, "").trim();
        final String pass = a.prefs.getString(Prefs.WEBDAV_PASS, "");
        final boolean syncSubs = isSyncSubscriptionsEnabled(a);
        if (url.isEmpty()) {
            if (!silent) a.toast("请先填写 WebDAV 服务器地址");
            return;
        }
        if (!IN_FLIGHT.compareAndSet(false, true)) {
            if (!silent) a.toast("正在同步中，请稍候…");
            return;
        }
        if (!silent) a.toast("正在与 WebDAV 云端双向同步…");

        final WeakReference<MainActivity> weakAct = new WeakReference<>(a);
        SYNC_EXEC.execute(
                () -> {
                    MainActivity act = weakAct.get();
                    if (act == null || act.isDestroyed() || act.isFinishing()) {
                        IN_FLIGHT.set(false);
                        return;
                    }
                    try {
                        final long now = System.currentTimeMillis();
                        final AtomicReference<CloudSync.MergeResult> resultRef =
                                new AtomicReference<>();
                        CloudSync.syncWebdav(
                                url,
                                user,
                                pass,
                                remoteJson -> {
                                    MainActivity cur = weakAct.get();
                                    if (cur == null || cur.isDestroyed() || cur.isFinishing()) {
                                        throw new java.io.IOException("页面已销毁，终止同步");
                                    }
                                    CloudSync.MergeResult res =
                                            mergeAndPersistLocal(cur, remoteJson, now);
                                    resultRef.set(res);
                                    return res;
                                });
                        lastAutoPushMs = System.currentTimeMillis();
                        final CloudSync.MergeResult r = resultRef.get();
                        final String okSummary = formatCounts("同步成功", r, syncSubs);
                        MainActivity currentAct = weakAct.get();
                        if (currentAct != null
                                && !currentAct.isDestroyed()
                                && !currentAct.isFinishing()) {
                            currentAct.ui.post(
                                    () -> {
                                        if (currentAct.isDestroyed() || currentAct.isFinishing()) {
                                            return;
                                        }
                                        currentAct
                                                .prefs
                                                .edit()
                                                .putLong(Prefs.SYNC_LAST_TIME, lastAutoPushMs)
                                                .putString(Prefs.SYNC_LAST_STATUS, okSummary)
                                                .apply();
                                        if (!silent && !currentAct.isFinishing()) {
                                            currentAct.toast("云同步完成（" + okSummary + "）");
                                        }
                                        if (onComplete != null && (r.changed || !silent)) {
                                            onComplete.run();
                                        }
                                    });
                        }
                    } catch (Exception e) {
                        AppLog.w("CloudSync", "WebDAV sync failed", e);
                        final String errMsg =
                                e.getMessage() == null
                                        ? e.getClass().getSimpleName()
                                        : e.getMessage();
                        MainActivity currentAct = weakAct.get();
                        if (currentAct != null
                                && !currentAct.isDestroyed()
                                && !currentAct.isFinishing()) {
                            currentAct.ui.post(
                                    () -> {
                                        if (currentAct.isDestroyed() || currentAct.isFinishing()) {
                                            return;
                                        }
                                        currentAct
                                                .prefs
                                                .edit()
                                                .putString(Prefs.SYNC_LAST_STATUS, "失败: " + errMsg)
                                                .apply();
                                        if (!silent && !currentAct.isFinishing()) {
                                            currentAct.notice("云同步未完成：" + errMsg);
                                        }
                                    });
                        }
                    } finally {
                        IN_FLIGHT.set(false);
                    }
                });
    }

    static void runLanPeerSync(
            final MainActivity a, final String peerInput, final Runnable onComplete) {
        if (a == null || a.privateMode) {
            if (a != null && a.privateMode) a.toast("隐私空间数据不参与局域网同步");
            return;
        }
        if (!IN_FLIGHT.compareAndSet(false, true)) {
            a.toast("正在同步中，请稍候…");
            return;
        }
        final boolean syncSubs = isSyncSubscriptionsEnabled(a);
        a.toast("正在连接局域网设备双向同步…");
        SYNC_EXEC.execute(
                () -> {
                    try {
                        final long now = System.currentTimeMillis();
                        final CloudSync.MergeResult r =
                                CloudSync.syncLanPeer(
                                        peerInput,
                                        new CloudSync.LanPeerCallback() {
                                            @Override
                                            public String exportLocalPayload() throws Exception {
                                                return exportCurrentPayload(a, now);
                                            }

                                            @Override
                                            public CloudSync.MergeResult applyMergedPayload(
                                                    String remoteMergedPayloadJson)
                                                    throws Exception {
                                                return mergeAndPersistLocal(
                                                        a, remoteMergedPayloadJson, now);
                                            }
                                        });
                        final String okSummary = formatCounts("局域网同步成功", r, syncSubs);
                        a.ui.post(
                                () -> {
                                    a.prefs
                                            .edit()
                                            .putLong(Prefs.SYNC_LAST_TIME, now)
                                            .putString(Prefs.SYNC_LAST_STATUS, okSummary)
                                            .apply();
                                    if (!a.isFinishing()) {
                                        a.toast(okSummary);
                                        if (onComplete != null) onComplete.run();
                                    }
                                });
                    } catch (Exception e) {
                        AppLog.w("CloudSync", "LAN sync failed", e);
                        final String errMsg =
                                e.getMessage() == null
                                        ? e.getClass().getSimpleName()
                                        : e.getMessage();
                        a.ui.post(
                                () -> {
                                    if (!a.isFinishing()) {
                                        a.notice("局域网同步未完成：" + errMsg);
                                    }
                                });
                    } finally {
                        IN_FLIGHT.set(false);
                    }
                });
    }

    /** Opens the Multi-Device Cloud & LAN Sync configuration dialog. */
    static void show(final MainActivity a, final Runnable onUpdated) {
        if (a.privateMode) {
            a.notice("隐私空间内的观看记录、收藏与订阅严格仅保存在本机，不会上传到 WebDAV 或通过局域网同步。");
            return;
        }

        LinearLayout panel = a.vertical();
        panel.setPadding(a.dp(6), a.dp(4), a.dp(6), a.dp(6));

        TextView intro =
                a.text(
                        "在手机、平板、电视、iPhone/iPad、Mac 与 Windows 电脑间自动同步观看进度、收藏与公开订阅源（兼容坚果云、Nextcloud、Alist、群晖等 WebDAV 及同局域网设备直连）。",
                        13,
                        MainActivity.MUTED);
        intro.setLineSpacing(a.dp(3), 1f);
        panel.addView(intro);
        a.gap(panel, 8);

        TextView statusBadge = a.text("状态：" + statusSummary(a), 12.5f, 0xff5ac8fa);
        statusBadge.setTypeface(null, Typeface.BOLD);
        panel.addView(statusBadge);
        a.gap(panel, 12);

        TextView secWebdav = a.text("一、WebDAV 自动云同步", 14, MainActivity.WHITE);
        secWebdav.setTypeface(null, Typeface.BOLD);
        panel.addView(secWebdav);
        a.gap(panel, 6);

        final EditText urlInput =
                styledInput(
                        a,
                        "WebDAV 目录或文件地址（如 https://dav.example/dav/MarcoMovie/）",
                        a.prefs.getString(Prefs.WEBDAV_URL, ""),
                        false);
        urlInput.setTag("cloud-sync-url");
        panel.addView(urlInput, new LinearLayout.LayoutParams(-1, -2));
        a.gap(panel, 8);

        final EditText userInput =
                styledInput(
                        a,
                        "WebDAV 账号 / 用户名（无认证可留空）",
                        a.prefs.getString(Prefs.WEBDAV_USER, ""),
                        false);
        userInput.setTag("cloud-sync-user");
        panel.addView(userInput, new LinearLayout.LayoutParams(-1, -2));
        a.gap(panel, 8);

        final EditText passInput =
                styledInput(
                        a, "WebDAV 密码 / 应用专用密码", a.prefs.getString(Prefs.WEBDAV_PASS, ""), true);
        passInput.setTag("cloud-sync-pass");
        panel.addView(passInput, new LinearLayout.LayoutParams(-1, -2));
        a.gap(panel, 8);

        final CheckBox autoCheck = new CheckBox(a);
        autoCheck.setText("开启后台自动云同步（启动自动拉取，播放进度、收藏与订阅变更自动推送）");
        autoCheck.setTextColor(MainActivity.WHITE);
        autoCheck.setTextSize(13);
        autoCheck.setChecked(a.prefs.getBoolean(Prefs.WEBDAV_AUTO, true));
        panel.addView(autoCheck, new LinearLayout.LayoutParams(-1, -2));

        final CheckBox subsCheck = new CheckBox(a);
        subsCheck.setTag("cloud-sync-subs-toggle");
        subsCheck.setText("同时同步我的订阅源配置（新设备一次同步即可拿到公开订阅源 + 进度 + 收藏，不含隐私空间）");
        subsCheck.setTextColor(MainActivity.WHITE);
        subsCheck.setTextSize(13);
        subsCheck.setChecked(a.prefs.getBoolean(Prefs.WEBDAV_SYNC_SUBS, true));
        subsCheck.setOnCheckedChangeListener(
                (btn, checked) ->
                        a.prefs.edit().putBoolean(Prefs.WEBDAV_SYNC_SUBS, checked).apply());
        panel.addView(subsCheck, new LinearLayout.LayoutParams(-1, -2));
        a.gap(panel, 10);

        final AppDialog[] holder = new AppDialog[1];

        Button syncNowBtn =
                a.button(
                        "保存并立即 WebDAV 云同步",
                        "cloud-sync-webdav-now",
                        () -> {
                            String u = urlInput.getText().toString().trim();
                            if (u.isEmpty()) {
                                a.toast("请先填写 WebDAV 地址");
                                return;
                            }
                            try {
                                CloudSync.resolveWebdavFileUrl(u);
                            } catch (Exception ex) {
                                a.toast(ex.getMessage());
                                return;
                            }
                            saveWebdavPrefs(
                                    a, urlInput, userInput, passInput, autoCheck, subsCheck);
                            if (holder[0] != null) holder[0].dismiss();
                            runWebdavSync(
                                    a,
                                    false,
                                    () -> {
                                        if (onUpdated != null) onUpdated.run();
                                        else a.refresh();
                                    });
                        });
        syncNowBtn.setBackground(a.bg(0xff0a84ff, 12));
        syncNowBtn.setTextColor(Color.WHITE);
        panel.addView(syncNowBtn, new LinearLayout.LayoutParams(-1, a.dp(44)));
        a.gap(panel, 8);

        LinearLayout subActions = a.row();
        Button saveOnlyBtn =
                a.navButton(
                        "仅保存配置",
                        "cloud-sync-save",
                        () -> {
                            saveWebdavPrefs(
                                    a, urlInput, userInput, passInput, autoCheck, subsCheck);
                            a.toast("已保存多端同步配置");
                            if (holder[0] != null) holder[0].dismiss();
                            if (onUpdated != null) onUpdated.run();
                        });
        subActions.addView(saveOnlyBtn, new LinearLayout.LayoutParams(0, a.dp(40), 1f));
        if (isConfigured(a)) {
            ViewSpacer.add(a, subActions, 8);
            Button clearCfgBtn =
                    a.navButton(
                            "清除云配置",
                            "cloud-sync-clear",
                            () -> {
                                a.prefs
                                        .edit()
                                        .remove(Prefs.WEBDAV_URL)
                                        .remove(Prefs.WEBDAV_USER)
                                        .remove(Prefs.WEBDAV_PASS)
                                        .remove(Prefs.SYNC_LAST_STATUS)
                                        .apply();
                                a.toast("已清除本机 WebDAV 云同步配置");
                                if (holder[0] != null) holder[0].dismiss();
                                if (onUpdated != null) onUpdated.run();
                            });
            subActions.addView(clearCfgBtn, new LinearLayout.LayoutParams(0, a.dp(40), 1f));
        }
        panel.addView(subActions, new LinearLayout.LayoutParams(-1, -2));

        a.gap(panel, 16);
        TextView secLan = a.text("二、局域网设备点对点双向同步（无需网盘账号）", 14, MainActivity.WHITE);
        secLan.setTypeface(null, Typeface.BOLD);
        panel.addView(secLan);
        a.gap(panel, 6);

        TextView lanHint =
                a.text(
                        "同一 Wi-Fi / 局域网下，一台设备打开「本机局域网接收码」，另一台设备点击「连接局域网其他设备」并输入该地址，即可一键双向合并观看进度、收藏与公开订阅源。",
                        12.5f,
                        MainActivity.MUTED);
        lanHint.setLineSpacing(a.dp(3), 1f);
        panel.addView(lanHint);
        a.gap(panel, 8);

        LinearLayout lanRow = a.vertical();
        Button openQrBtn =
                a.navButton(
                        "打开本机局域网接收码（二维码 5 分钟有效）",
                        "cloud-sync-lan-receive",
                        () -> {
                            saveToggleOnly(a, autoCheck, subsCheck);
                            if (holder[0] != null) holder[0].dismiss();
                            if (a.phoneConfig != null) a.phoneConfig.close();
                            a.phoneConfig = new PhoneConfigDialog(a);
                            a.phoneConfig.showLanSyncReceiver(
                                    onUpdated != null ? onUpdated : a::refresh);
                        });
        lanRow.addView(openQrBtn, new LinearLayout.LayoutParams(-1, a.dp(42)));
        a.gap(lanRow, 8);

        Button connectLanBtn =
                a.navButton(
                        "连接局域网其他设备并双向同步",
                        "cloud-sync-lan-connect",
                        () -> {
                            saveToggleOnly(a, autoCheck, subsCheck);
                            if (holder[0] != null) holder[0].dismiss();
                            showLanConnectDialog(a, onUpdated);
                        });
        lanRow.addView(connectLanBtn, new LinearLayout.LayoutParams(-1, a.dp(42)));
        panel.addView(lanRow, new LinearLayout.LayoutParams(-1, -2));

        ScrollView scroll = new TvScrollView(a);
        scroll.setVerticalScrollBarEnabled(false);
        scroll.addView(panel, new ScrollView.LayoutParams(-1, -2));

        int maxHeight = Math.max(a.dp(260), Math.round(a.windowHeight() * 0.72f));
        LinearLayout wrapper = a.vertical();
        wrapper.addView(scroll, new LinearLayout.LayoutParams(-1, maxHeight));

        AppDialog dialog =
                new AppDialog.Builder(a)
                        .setTitle("多端网络同步")
                        .setView(wrapper)
                        .setNegativeButton("关闭", null)
                        .create();
        holder[0] = dialog;
        activeDialogRef = new WeakReference<>(dialog);
        dialog.show();
        if (a.isTvDevice()) {
            a.ui.post(syncNowBtn::requestFocus);
        }
    }

    static void showLanConnectDialog(final MainActivity a, final Runnable onUpdated) {
        LinearLayout panel = a.vertical();
        panel.setPadding(a.dp(6), a.dp(6), a.dp(6), a.dp(4));

        TextView tip =
                a.text(
                        "在另一台设备打开「多端网络同步 → 本机局域网接收码」（或电视「手机扫码配置」），将该设备上显示的局域网地址输入或粘贴到下方：",
                        13,
                        MainActivity.MUTED);
        tip.setLineSpacing(a.dp(3), 1f);
        panel.addView(tip);
        a.gap(panel, 10);

        final EditText peerInput = styledInput(a, "http://…/configure/…", "", false);
        peerInput.setTag("lan-sync-peer-input");
        panel.addView(peerInput, new LinearLayout.LayoutParams(-1, -2));

        if (!a.isTvDevice()) {
            a.gap(panel, 8);
            TextView pasteBtn = a.text("从剪贴板粘贴对方局域网地址", 13, Color.WHITE);
            pasteBtn.setTypeface(null, Typeface.BOLD);
            pasteBtn.setGravity(Gravity.CENTER);
            pasteBtn.setPadding(a.dp(14), a.dp(10), a.dp(14), a.dp(10));
            pasteBtn.setBackground(a.bg(0xff1e2623, 999));
            MobileDetailScreen.bindTouchFeedback(pasteBtn);
            pasteBtn.setOnClickListener(
                    v -> {
                        ClipboardManager cm =
                                (ClipboardManager) a.getSystemService(Context.CLIPBOARD_SERVICE);
                        if (cm != null && cm.hasPrimaryClip()) {
                            ClipData clip = cm.getPrimaryClip();
                            if (clip != null
                                    && clip.getItemCount() > 0
                                    && clip.getItemAt(0).getText() != null) {
                                String txt = clip.getItemAt(0).getText().toString().trim();
                                peerInput.setText(txt);
                                peerInput.setSelection(txt.length());
                            }
                        }
                    });
            panel.addView(pasteBtn, new LinearLayout.LayoutParams(-1, -2));
        }

        AppDialog lanDialog =
                new AppDialog.Builder(a)
                        .setTitle("连接局域网其他设备")
                        .setView(panel)
                        .setNegativeButton("取消", null)
                        .setPositiveButton(
                                "立即双向同步",
                                (d, w) -> {
                                    String raw = peerInput.getText().toString().trim();
                                    if (raw.isEmpty()) {
                                        a.toast("请输入对方设备的局域网同步地址");
                                        return;
                                    }
                                    runLanPeerSync(
                                            a,
                                            raw,
                                            () -> {
                                                if (onUpdated != null) onUpdated.run();
                                                else a.refresh();
                                            });
                                })
                        .create();
        activeDialogRef = new WeakReference<>(lanDialog);
        lanDialog.show();
    }

    private static void saveToggleOnly(MainActivity a, CheckBox autoCheck, CheckBox subsCheck) {
        a.prefs
                .edit()
                .putBoolean(Prefs.WEBDAV_AUTO, autoCheck.isChecked())
                .putBoolean(Prefs.WEBDAV_SYNC_SUBS, subsCheck.isChecked())
                .apply();
    }

    private static void saveWebdavPrefs(
            MainActivity a,
            EditText urlInput,
            EditText userInput,
            EditText passInput,
            CheckBox autoCheck,
            CheckBox subsCheck) {
        a.prefs
                .edit()
                .putString(Prefs.WEBDAV_URL, urlInput.getText().toString().trim())
                .putString(Prefs.WEBDAV_USER, userInput.getText().toString().trim())
                .putString(Prefs.WEBDAV_PASS, passInput.getText().toString())
                .putBoolean(Prefs.WEBDAV_AUTO, autoCheck.isChecked())
                .putBoolean(Prefs.WEBDAV_SYNC_SUBS, subsCheck.isChecked())
                .apply();
    }

    private static EditText styledInput(
            MainActivity a, String hint, String value, boolean password) {
        EditText input = new EditText(a);
        input.setHint(hint);
        input.setHintTextColor(0xff6b7280);
        input.setTextColor(MainActivity.WHITE);
        input.setTextSize(13.5f);
        input.setSingleLine(true);
        if (password) {
            input.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD);
        } else {
            input.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI);
        }
        input.setPadding(a.dp(12), a.dp(10), a.dp(12), a.dp(10));
        input.setBackground(a.bg(0xff1e2428, 10));
        if (value != null && !value.isEmpty()) {
            input.setText(value);
            input.setSelection(value.length());
        }
        return input;
    }

    private static final class ViewSpacer {
        static void add(MainActivity a, LinearLayout row, int dpWidth) {
            android.view.View v = new android.view.View(a);
            row.addView(v, new LinearLayout.LayoutParams(a.dp(dpWidth), 1));
        }
    }
}
