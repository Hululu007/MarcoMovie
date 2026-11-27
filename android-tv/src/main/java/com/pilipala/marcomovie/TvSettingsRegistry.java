package com.pilipala.marcomovie;

import java.util.Arrays;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * Pure-JVM routing, stable category IDs, legacy title/tag mapping, and focus-fallback policy for
 * the Android TV 6-category split-pane settings screen.
 *
 * <p>Migration registry (Old entry / stable ID -> Scope -> New Category -> Return target):
 *
 * <ul>
 *   <li>{@code settings-import} / {@code settings-source-manager} / {@code settings-refresh-subs} /
 *       {@code settings-live-import} / {@code settings-live-epg} / {@code
 *       setting-subscription_auto_update} / {@code settings-depots} (conditional) / {@code
 *       settings-accounts} / {@code settings-alist-mount} / {@code settings-storage-permission} /
 *       {@code setting-search_threads} / {@code setting-search_timeout} / {@code
 *       setting-native_python_enabled} / {@code setting-webview_js_fallback} / {@code
 *       setting-experimental_csp} / {@code setting-only_allow_https_plugins} / {@code
 *       settings-spider-gateway} (non-private) / {@code settings-live-udpxy} / {@code
 *       setting-live_high_quality} / {@code setting-live_merge_sources} -> Global -> {@code
 *       sources} (片源与直播) -> Parent row.
 *   <li>{@code setting-play_speed} / {@code setting-auto_next} / {@code setting-aspect} / {@code
 *       setting-video_skip_records} / {@code setting-player_skip_countdown} / {@code
 *       setting-repeat_mode} / {@code setting-audio_effect} / {@code setting-loudness_boost} /
 *       {@code setting-picture_effect} / {@code setting-player_engine} / {@code
 *       setting-decoder_mode} / {@code setting-video_output} / {@code setting-tunneled_playback} /
 *       {@code setting-hdr_tone_mapping} / {@code setting-anime4k_enabled} / {@code
 *       setting-hls_proxy_enabled} / {@code setting-hls_ad_strip} / {@code setting-media_cache_mb}
 *       / {@code setting-buffer_seconds} / {@code setting-software_audio} / {@code
 *       setting-prefer_aac} / {@code settings-decoders} -> Global playback defaults -> {@code
 *       playback} (播放) -> Parent row.
 *   <li>{@code setting-danmaku_default} / {@code setting-danmu-panel} / {@code
 *       setting-subtitle_size} / {@code setting-subtitle_style} / {@code
 *       setting-audio_track_preference} / {@code setting-danmu-display} / {@code
 *       setting-danmu-style} / {@code setting-danmu-filter} -> Global subtitle & danmu defaults ->
 *       {@code subtitle_danmu} (字幕与弹幕) -> Parent row / Player when opened from player.
 *   <li>{@code setting-tv_dock_position} / {@code setting-tv-nav-custom} / {@code
 *       settings-wallpaper} / {@code setting-tv_player_style} / {@code
 *       setting-tv_player_toolbar_order} / {@code setting-ui_scale_percent} / {@code
 *       setting-nav_scale_percent} / {@code setting-home_columns} / {@code
 *       setting-reduced_transparency} / {@code setting-startup_animation} / {@code setting-reduced}
 *       / {@code setting-tv_player_top_right_hud} / {@code setting-player_slim_progress} / {@code
 *       setting-player_start_spec_hud} -> Global UI & remote -> {@code appearance_remote} (外观与遥控)
 *       -> Parent row.
 *   <li>{@code settings-history} / {@code settings-cloud-sync} (non-private) / {@code
 *       settings-backup} / {@code settings-restore} / {@code settings-clear-images} / {@code
 *       settings-clear-history} / {@code settings-reset-history} / {@code settings-reset} -> User
 *       data & sync -> {@code data_sync} (数据与同步) -> Parent row (preserves Mine & Settings->History
 *       shortcuts).
 *   <li>{@code settings-update-action} / {@code settings-update-mode} / {@code settings-logs} /
 *       {@code settings-crash-feedback} (non-private) / {@code settings-update-full} / {@code
 *       settings-replay-onboarding} -> App update & diagnostics -> {@code updates_diag} (更新与诊断) ->
 *       Parent row / Actual caller.
 * </ul>
 */
final class TvSettingsRegistry {
    static final String CAT_SOURCES = "sources";
    static final String CAT_PLAYBACK = "playback";
    static final String CAT_SUBTITLE_DANMU = "subtitle_danmu";
    static final String CAT_APPEARANCE_REMOTE = "appearance_remote";
    static final String CAT_DATA_SYNC = "data_sync";
    static final String CAT_UPDATES_DIAG = "updates_diag";

    static final int IDX_SOURCES = 0;
    static final int IDX_PLAYBACK = 1;
    static final int IDX_SUBTITLE_DANMU = 2;
    static final int IDX_APPEARANCE_REMOTE = 3;
    static final int IDX_DATA_SYNC = 4;
    static final int IDX_UPDATES_DIAG = 5;
    static final int CATEGORY_COUNT = 6;

    static final class CategorySpec {
        final int index;
        final String id;
        final String title;
        final String navTag;
        final String subtitle;

        CategorySpec(int index, String id, String title, String navTag, String subtitle) {
            this.index = index;
            this.id = id;
            this.title = title;
            this.navTag = navTag;
            this.subtitle = subtitle;
        }
    }

    static final List<CategorySpec> CATEGORIES =
            Collections.unmodifiableList(
                    Arrays.asList(
                            new CategorySpec(
                                    IDX_SOURCES,
                                    CAT_SOURCES,
                                    "片源与直播",
                                    "settings-sources",
                                    "导入或管理订阅源、刷新片库与配置直播节目单；搜索并发与脚本引擎位于下方「高级」。"),
                            new CategorySpec(
                                    IDX_PLAYBACK,
                                    CAT_PLAYBACK,
                                    "播放",
                                    "settings-playback",
                                    "以下为全局默认播放参数（以后播放沿用）；播放中仍可随时调整。"),
                            new CategorySpec(
                                    IDX_SUBTITLE_DANMU,
                                    CAT_SUBTITLE_DANMU,
                                    "字幕与弹幕",
                                    "settings-subtitle-danmu",
                                    "片源自带弹幕可独立使用，无需配置自定义服务；样式与音轨偏好以后播放沿用。"),
                            new CategorySpec(
                                    IDX_APPEARANCE_REMOTE,
                                    CAT_APPEARANCE_REMOTE,
                                    "外观与遥控",
                                    "settings-appearance",
                                    "管理首页导航、柔光与壁纸、播放界面样式、工具栏按钮排序与界面显示。"),
                            new CategorySpec(
                                    IDX_DATA_SYNC,
                                    CAT_DATA_SYNC,
                                    "数据与同步",
                                    "settings-data-sync",
                                    "查看观看历史、多端同步与配置备份；清理缓存和恢复默认位于底部。"),
                            new CategorySpec(
                                    IDX_UPDATES_DIAG,
                                    CAT_UPDATES_DIAG,
                                    "更新与诊断",
                                    "settings-updates",
                                    "检查应用版本更新、运行日志与问题反馈（刷新片源请前往「片源与直播」）。")));

    private static final Map<String, String> LEGACY_TO_CATEGORY_ID;
    private static final Map<String, String> ROW_TAG_TO_CATEGORY_ID;

    static {
        Map<String, String> m = new HashMap<>();
        m.put(CAT_SOURCES, CAT_SOURCES);
        m.put("片源与直播", CAT_SOURCES);
        m.put("内容与连接", CAT_SOURCES);
        m.put("settings-content", CAT_SOURCES);
        m.put("settings-sources", CAT_SOURCES);

        m.put(CAT_PLAYBACK, CAT_PLAYBACK);
        m.put("播放", CAT_PLAYBACK);
        m.put("播放与字幕", CAT_PLAYBACK);
        m.put("解码组件", CAT_PLAYBACK);
        m.put("settings-playback", CAT_PLAYBACK);

        m.put(CAT_SUBTITLE_DANMU, CAT_SUBTITLE_DANMU);
        m.put("字幕与弹幕", CAT_SUBTITLE_DANMU);
        m.put("弹幕设置", CAT_SUBTITLE_DANMU);
        m.put("settings-subtitle-danmu", CAT_SUBTITLE_DANMU);

        m.put(CAT_APPEARANCE_REMOTE, CAT_APPEARANCE_REMOTE);
        m.put("外观与遥控", CAT_APPEARANCE_REMOTE);
        m.put("外观与壁纸", CAT_APPEARANCE_REMOTE);
        m.put("首页壁纸", CAT_APPEARANCE_REMOTE);
        m.put("settings-appearance", CAT_APPEARANCE_REMOTE);

        m.put(CAT_DATA_SYNC, CAT_DATA_SYNC);
        m.put("数据与同步", CAT_DATA_SYNC);
        m.put("数据与备份", CAT_DATA_SYNC);
        m.put("settings-backup-page", CAT_DATA_SYNC);
        m.put("settings-data-sync", CAT_DATA_SYNC);

        m.put(CAT_UPDATES_DIAG, CAT_UPDATES_DIAG);
        m.put("更新与诊断", CAT_UPDATES_DIAG);
        m.put("软件更新", CAT_UPDATES_DIAG);
        m.put("运行日志", CAT_UPDATES_DIAG);
        m.put("settings-updates", CAT_UPDATES_DIAG);
        LEGACY_TO_CATEGORY_ID = Collections.unmodifiableMap(m);

        Map<String, String> r = new HashMap<>();
        // Sources & Live
        for (String tag :
                new String[] {
                    "settings-import",
                    "settings-source-manager",
                    "settings-refresh-subs",
                    "settings-live-import",
                    "settings-live-epg",
                    "setting-" + Prefs.SUBSCRIPTION_AUTO_UPDATE,
                    "settings-depots",
                    "settings-accounts",
                    "settings-alist-mount",
                    "settings-storage-permission",
                    "setting-" + Prefs.SEARCH_THREADS,
                    "setting-" + Prefs.SEARCH_TIMEOUT,
                    "setting-" + Prefs.NATIVE_PYTHON_ENABLED,
                    "setting-" + Prefs.WEBVIEW_JS_FALLBACK,
                    "setting-" + Prefs.EXPERIMENTAL_CSP,
                    "setting-" + Prefs.ONLY_ALLOW_HTTPS_PLUGINS,
                    "settings-spider-gateway",
                    "settings-live-udpxy",
                    "setting-" + Prefs.LIVE_HIGH_QUALITY,
                    "setting-" + Prefs.LIVE_MERGE_SOURCES
                }) {
            r.put(tag, CAT_SOURCES);
        }
        // Playback
        for (String tag :
                new String[] {
                    "setting-" + Prefs.PLAY_SPEED,
                    "setting-" + Prefs.AUTO_NEXT,
                    "setting-" + Prefs.ASPECT,
                    "setting-" + Prefs.VIDEO_SKIP_RECORDS,
                    "setting-player_skip_countdown",
                    "setting-" + Prefs.REPEAT_MODE,
                    "setting-" + Prefs.AUDIO_EFFECT,
                    "setting-" + Prefs.LOUDNESS_BOOST,
                    "setting-" + Prefs.PICTURE_EFFECT,
                    "setting-" + Prefs.PLAYER_ENGINE,
                    "setting-" + Prefs.DECODER_MODE,
                    "setting-" + Prefs.VIDEO_OUTPUT,
                    "setting-" + Prefs.TUNNELED_PLAYBACK,
                    "setting-" + Prefs.HDR_TONE_MAPPING,
                    "setting-" + Prefs.ANIME4K_ENABLED,
                    "setting-" + Prefs.HLS_PROXY_ENABLED,
                    "setting-" + Prefs.HLS_AD_STRIP,
                    "setting-" + Prefs.MEDIA_CACHE_MB,
                    "setting-" + Prefs.BUFFER_SECONDS,
                    "setting-" + Prefs.SOFTWARE_AUDIO,
                    "setting-" + Prefs.PREFER_AAC,
                    "settings-decoders"
                }) {
            r.put(tag, CAT_PLAYBACK);
        }
        // Subtitle & Danmu
        for (String tag :
                new String[] {
                    "setting-" + Prefs.DANMAKU_DEFAULT,
                    "setting-danmu-panel",
                    "setting-" + Prefs.SUBTITLE_SIZE,
                    "setting-" + Prefs.SUBTITLE_STYLE,
                    "setting-" + Prefs.AUDIO_TRACK_PREFERENCE,
                    "setting-danmu-display",
                    "setting-danmu-style",
                    "setting-danmu-filter"
                }) {
            r.put(tag, CAT_SUBTITLE_DANMU);
        }
        // Appearance & Remote
        for (String tag :
                new String[] {
                    "setting-" + Prefs.TV_DOCK_POSITION,
                    "setting-tv-nav-custom",
                    "settings-wallpaper",
                    "setting-" + Prefs.TV_PLAYER_STYLE,
                    "setting-" + Prefs.TV_PLAYER_TOOLBAR_ORDER,
                    "setting-" + Prefs.UI_SCALE_PERCENT,
                    "setting-" + Prefs.NAV_SCALE_PERCENT,
                    "setting-" + Prefs.HOME_COLUMNS,
                    "setting-" + Prefs.REDUCED_TRANSPARENCY,
                    "setting-" + Prefs.STARTUP_ANIMATION,
                    "setting-" + Prefs.REDUCED,
                    "setting-" + Prefs.TV_PLAYER_TOP_RIGHT_HUD,
                    "setting-player_slim_progress",
                    "setting-player_start_spec_hud"
                }) {
            r.put(tag, CAT_APPEARANCE_REMOTE);
        }
        // Data & Sync
        for (String tag :
                new String[] {
                    "settings-history",
                    "settings-cloud-sync",
                    "settings-backup",
                    "settings-restore",
                    "settings-clear-images",
                    "settings-clear-history",
                    "settings-reset-history",
                    "settings-reset"
                }) {
            r.put(tag, CAT_DATA_SYNC);
        }
        // Updates & Diagnostics
        for (String tag :
                new String[] {
                    "settings-update-action",
                    "settings-update-mode",
                    "settings-logs",
                    "settings-crash-feedback",
                    TvOfficialNotice.SETTINGS_ROW_TAG,
                    TvOfficialNotice.DONATE_ROW_TAG,
                    "settings-update-full",
                    "settings-replay-onboarding"
                }) {
            r.put(tag, CAT_UPDATES_DIAG);
        }
        ROW_TAG_TO_CATEGORY_ID = Collections.unmodifiableMap(r);
    }

    private TvSettingsRegistry() {}

    static String resolveCategoryId(String idOrLegacyTitle) {
        if (idOrLegacyTitle == null) return CAT_SOURCES;
        String trimmed = idOrLegacyTitle.trim();
        String mapped = LEGACY_TO_CATEGORY_ID.get(trimmed);
        if (mapped != null) return mapped;
        String byRow = ROW_TAG_TO_CATEGORY_ID.get(trimmed);
        return byRow != null ? byRow : CAT_SOURCES;
    }

    static int resolveCategoryIndex(String idOrLegacyTitle) {
        String id = resolveCategoryId(idOrLegacyTitle);
        for (CategorySpec spec : CATEGORIES) {
            if (spec.id.equals(id)) return spec.index;
        }
        return IDX_SOURCES;
    }

    static CategorySpec specAt(int index) {
        if (index < 0 || index >= CATEGORIES.size()) return CATEGORIES.get(IDX_SOURCES);
        return CATEGORIES.get(index);
    }

    static String categoryIdForRowTag(String rowTag) {
        if (rowTag == null) return null;
        return ROW_TAG_TO_CATEGORY_ID.get(rowTag.trim());
    }

    /**
     * Resolves initial category when entering Settings from Home: first entry starts on {@link
     * #CAT_SOURCES}; subsequent visits restore the last visited category.
     */
    static String resolveInitialHomeEntryCategory(String savedLastCategoryId) {
        if (savedLastCategoryId == null || savedLastCategoryId.trim().isEmpty()) {
            return CAT_SOURCES;
        }
        return resolveCategoryId(savedLastCategoryId);
    }

    /**
     * Returns the Row-1 tag for {@link #CAT_SOURCES}: empty-config users land on {@code
     * settings-import}; users with configured sites land on {@code settings-source-manager}.
     */
    static String firstRowTagForSources(boolean hasConfiguredSites) {
        return hasConfiguredSites ? "settings-source-manager" : "settings-import";
    }

    /**
     * Resolves the target focus index within a category's visible focusable row list when moving
     * Right from the left rail or returning from a subpage, gracefully falling back to the nearest
     * visible row if the previously focused row disappeared (e.g. privacy/capability toggle).
     */
    static int resolveNearestVisibleRowIndex(
            List<String> visibleRowTags, String preferredTag, int preferredIndex) {
        if (visibleRowTags == null || visibleRowTags.isEmpty()) return -1;
        if (preferredTag != null && !preferredTag.isEmpty()) {
            int exact = visibleRowTags.indexOf(preferredTag);
            if (exact >= 0) return exact;
        }
        if (preferredIndex >= 0) {
            return Math.min(preferredIndex, visibleRowTags.size() - 1);
        }
        return 0;
    }
}
