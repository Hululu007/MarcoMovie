package com.pilipala.marcomovie;

import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.LinearGradient;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.Shader;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.View;
import android.widget.FrameLayout;
import android.widget.HorizontalScrollView;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

/**
 * Native Android 1:1 port of iOS {@code CuratedDiscoverySection} ({@code
 * flutter/lib/ui/curated_discovery_section.dart}) delivering all 6 signature Marco Movie editorial
 * discovery modules fixed directly on the Home screen (always displayed regardless of whether the
 * user has added subscription sources):
 *
 * <ol>
 *   <li><b>光影风向标</b>: 16:9 widescreen cinema frame shelf
 *   <li><b>月度策划 · 藤蔓特辑</b>: Botanical vine-entwined editorial spotlight cards with 2-up mini
 *       frames
 *   <li><b>热播剧影榜</b>: 2:3 ranked vertical poster shelf with {@code 01..03} accent badges
 *   <li><b>灵感片单</b>: Fanned 3-poster mood capsules
 *   <li><b>影业档案室</b>: Disney · Pixar / MARVEL / DC studio cards with 3D-tilted 2×2 poster fans
 *   <li><b>口碑典藏馆</b>: 3-row staggered 12-poster collector mosaics
 * </ol>
 */
final class MobileCuratedSection {
    private static final String TAG_FIRST_TITLE = "curated-first-header-title";
    private static final String TAG_FIRST_CHEV = "curated-first-header-chev";

    private MobileCuratedSection() {}

    /** Renders all 6 editorial discovery modules inside {@code host}. */
    static void renderInto(
            final MainActivity a,
            final LinearLayout host,
            final boolean hasUserSources,
            final boolean firstUnderHero) {
        if (a == null || host == null) return;
        final MobileTheme.Palette p = MobileTheme.of(a);
        final Cms.Site curatedSite = MobileCuratedDiscovery.curatedSiteSentinel();

        MobileCuratedDiscovery.ModuleSpec trendingSpec =
                MobileCuratedDiscovery.moduleById(MobileCuratedDiscovery.ID_WEEKLY_TRENDING);
        MobileCuratedDiscovery.ModuleSpec cnHotSpec =
                MobileCuratedDiscovery.moduleById(MobileCuratedDiscovery.ID_CN_HOT);
        MobileCuratedDiscovery.ModuleSpec varietySpec =
                MobileCuratedDiscovery.moduleById(MobileCuratedDiscovery.ID_CN_VARIETY);
        MobileCuratedDiscovery.ModuleSpec doubanSpec =
                MobileCuratedDiscovery.moduleById(MobileCuratedDiscovery.ID_DOUBAN_TOP);
        MobileCuratedDiscovery.ModuleSpec rtSpec =
                MobileCuratedDiscovery.moduleById(MobileCuratedDiscovery.ID_ROTTEN_TOMATOES);
        MobileCuratedDiscovery.ModuleSpec disneySpec =
                MobileCuratedDiscovery.moduleById(MobileCuratedDiscovery.ID_DISNEY);
        MobileCuratedDiscovery.ModuleSpec marvelSpec =
                MobileCuratedDiscovery.moduleById(MobileCuratedDiscovery.ID_MARVEL);
        MobileCuratedDiscovery.ModuleSpec dcSpec =
                MobileCuratedDiscovery.moduleById(MobileCuratedDiscovery.ID_DC);

        List<Cms.Video> trendingItems = MobileCuratedDiscovery.peekModule(trendingSpec);
        List<Cms.Video> cnHotItems = MobileCuratedDiscovery.peekModule(cnHotSpec);
        List<Cms.Video> varietyItems = MobileCuratedDiscovery.peekModule(varietySpec);
        List<Cms.Video> doubanItems = MobileCuratedDiscovery.peekModule(doubanSpec);
        List<Cms.Video> rtItems = MobileCuratedDiscovery.peekModule(rtSpec);
        List<Cms.Video> disneyItems = MobileCuratedDiscovery.peekModule(disneySpec);
        List<Cms.Video> marvelItems = MobileCuratedDiscovery.peekModule(marvelSpec);
        List<Cms.Video> dcItems = MobileCuratedDiscovery.peekModule(dcSpec);

        String fp =
                buildCuratedRenderFingerprint(
                        p.isDark,
                        hasUserSources,
                        firstUnderHero,
                        trendingItems,
                        cnHotItems,
                        varietyItems,
                        doubanItems,
                        rtItems,
                        disneyItems,
                        marvelItems,
                        dcItems);
        if (host.getChildCount() > 0 && fp.equals(host.getTag())) {
            return;
        }
        host.setTag(fp);
        ImageLoader.detachImageViews(host);
        host.removeAllViews();

        // 1. 光影风向标 (16:9 Widescreen Cinema Frame Shelf)
        addWidescreenRadarShelf(
                a,
                host,
                curatedSite,
                "光影风向标",
                trendingSpec,
                trendingItems,
                firstUnderHero,
                hasUserSources);

        // 2. 月度策划 · 藤蔓特辑 (Botanical Vine Editorial Collection Cards)
        a.gap(host, 20);
        addSectionHeader(a, host, "月度策划", "藤蔓特辑", null, false);
        HorizontalScrollView edHsv = new HorizontalScrollView(a);
        edHsv.setHorizontalScrollBarEnabled(false);
        edHsv.setClipToPadding(false);
        edHsv.setPadding(a.dp(16), a.dp(2), a.dp(16), a.dp(4));
        LinearLayout edRow = a.row();
        edRow.setGravity(Gravity.TOP);
        edRow.setBaselineAligned(false);
        edHsv.addView(edRow);

        addEditorialCollectionCard(
                a,
                edRow,
                curatedSite,
                "当月欢笑 · 热门综艺",
                varietySpec,
                varietyItems,
                p.isDark ? 0xFF3E3A32 : 0xFF70685A,
                varietySpec.accentColor,
                hasUserSources,
                MobileCuratedWallScreen.STYLE_BLACK_HOLE_VORTEX);
        addEditorialCollectionCard(
                a,
                edRow,
                curatedSite,
                "当月热追 · 精选剧集",
                cnHotSpec,
                cnHotItems,
                p.isDark ? 0xFF21312F : 0xFF3A5451,
                cnHotSpec.accentColor,
                hasUserSources,
                MobileCuratedWallScreen.STYLE_TETRIS_TUMBLE);
        addEditorialCollectionCard(
                a,
                edRow,
                curatedSite,
                "高分必刷 · 影迷片单",
                doubanSpec,
                doubanItems,
                p.isDark ? 0xFF1D3125 : 0xFF31523E,
                doubanSpec.accentColor,
                hasUserSources,
                MobileCuratedWallScreen.STYLE_BLACK_HOLE_VORTEX);
        addEditorialCollectionCard(
                a,
                edRow,
                curatedSite,
                "口碑风向 · 全球严选",
                rtSpec,
                rtItems,
                p.isDark ? 0xFF372028 : 0xFF5D3542,
                rtSpec.accentColor,
                hasUserSources,
                MobileCuratedWallScreen.STYLE_TETRIS_TUMBLE);
        host.addView(edHsv, new LinearLayout.LayoutParams(-1, -2));

        // 3. 热播剧影榜 (Ranked 2:3 Vertical Poster Shelf)
        a.gap(host, 20);
        addRankedPortraitShelf(
                a, host, curatedSite, "热播剧影榜", cnHotSpec, cnHotItems, hasUserSources);

        // 4. 灵感片单 (Fanned 3-Poster Mood Capsules)
        a.gap(host, 20);
        addSectionHeader(a, host, "灵感片单", null, null, false);
        HorizontalScrollView moodHsv = new HorizontalScrollView(a);
        moodHsv.setHorizontalScrollBarEnabled(false);
        moodHsv.setClipToPadding(false);
        moodHsv.setPadding(a.dp(16), a.dp(2), a.dp(16), a.dp(4));
        LinearLayout moodRow = a.row();
        moodRow.setGravity(Gravity.CENTER_VERTICAL);
        moodHsv.addView(moodRow);

        addMoodCapsule(
                a,
                moodRow,
                curatedSite,
                "轻松解压",
                disneySpec,
                disneyItems,
                hasUserSources,
                MobileCuratedWallScreen.STYLE_TETRIS_TUMBLE);
        addMoodCapsule(
                a,
                moodRow,
                curatedSite,
                "高能热剧",
                cnHotSpec,
                cnHotItems,
                hasUserSources,
                MobileCuratedWallScreen.STYLE_BLACK_HOLE_VORTEX);
        addMoodCapsule(
                a,
                moodRow,
                curatedSite,
                "下饭综艺",
                varietySpec,
                varietyItems,
                hasUserSources,
                MobileCuratedWallScreen.STYLE_GRAVITY_STACK);
        addMoodCapsule(
                a,
                moodRow,
                curatedSite,
                "院线新片",
                trendingSpec,
                trendingItems,
                hasUserSources,
                MobileCuratedWallScreen.STYLE_BLACK_HOLE_VORTEX);
        addMoodCapsule(
                a,
                moodRow,
                curatedSite,
                "热血超英",
                marvelSpec,
                marvelItems,
                hasUserSources,
                MobileCuratedWallScreen.STYLE_TETRIS_TUMBLE);
        addMoodCapsule(
                a,
                moodRow,
                curatedSite,
                "暗黑悬疑",
                dcSpec,
                dcItems,
                hasUserSources,
                MobileCuratedWallScreen.STYLE_BLACK_HOLE_VORTEX);
        host.addView(moodHsv, new LinearLayout.LayoutParams(-1, -2));

        // 5. 影业档案室 (Studio Brand Cards with Tilted 2x2 Poster Collage)
        a.gap(host, 20);
        addSectionHeader(a, host, "影业档案室", hasUserSources ? "点播自动匹配片源" : "需添加片源播放", null, false);
        HorizontalScrollView studioHsv = new HorizontalScrollView(a);
        studioHsv.setHorizontalScrollBarEnabled(false);
        studioHsv.setClipToPadding(false);
        studioHsv.setPadding(a.dp(16), a.dp(2), a.dp(16), a.dp(4));
        LinearLayout studioRow = a.row();
        studioRow.setGravity(Gravity.TOP);
        studioRow.setBaselineAligned(false);
        studioHsv.addView(studioRow);

        addStudioFanCard(
                a,
                studioRow,
                curatedSite,
                0,
                disneySpec,
                disneyItems,
                hasUserSources,
                MobileCuratedWallScreen.STYLE_TETRIS_TUMBLE);
        addStudioFanCard(
                a,
                studioRow,
                curatedSite,
                1,
                marvelSpec,
                marvelItems,
                hasUserSources,
                MobileCuratedWallScreen.STYLE_BLACK_HOLE_VORTEX);
        addStudioFanCard(
                a,
                studioRow,
                curatedSite,
                2,
                dcSpec,
                dcItems,
                hasUserSources,
                MobileCuratedWallScreen.STYLE_TETRIS_TUMBLE);
        host.addView(studioHsv, new LinearLayout.LayoutParams(-1, -2));

        // 6. 口碑典藏馆 (3-Row Staggered Poster Mosaic Collector Cards)
        a.gap(host, 20);
        addSectionHeader(a, host, "口碑典藏馆", null, null, false);
        HorizontalScrollView mosaicHsv = new HorizontalScrollView(a);
        mosaicHsv.setHorizontalScrollBarEnabled(false);
        mosaicHsv.setClipToPadding(false);
        mosaicHsv.setPadding(a.dp(16), a.dp(2), a.dp(16), a.dp(4));
        LinearLayout mosaicRow = a.row();
        mosaicRow.setGravity(Gravity.TOP);
        mosaicRow.setBaselineAligned(false);
        mosaicHsv.addView(mosaicRow);

        addMosaicCard(
                a,
                mosaicRow,
                curatedSite,
                "高分殿堂",
                "影迷严选年度佳作",
                doubanItems,
                doubanSpec.accentColor,
                hasUserSources,
                MobileCuratedWallScreen.STYLE_TETRIS_TUMBLE);
        addMosaicCard(
                a,
                mosaicRow,
                curatedSite,
                "口碑新片",
                "全球影评新鲜直击",
                rtItems,
                rtSpec.accentColor,
                hasUserSources,
                MobileCuratedWallScreen.STYLE_BLACK_HOLE_VORTEX);
        List<Cms.Video> heroUniverse = new ArrayList<>();
        for (int i = 0; i < Math.min(6, marvelItems.size()); i++)
            heroUniverse.add(marvelItems.get(i));
        for (int i = 0; i < Math.min(6, dcItems.size()); i++) heroUniverse.add(dcItems.get(i));
        List<Cms.Video> heroUniverseAll = new ArrayList<>(marvelItems);
        heroUniverseAll.addAll(dcItems);
        addMosaicCard(
                a,
                mosaicRow,
                curatedSite,
                "英雄宇宙",
                "漫威 · DC 史诗巡礼",
                heroUniverse,
                marvelSpec.accentColor,
                hasUserSources,
                heroUniverseAll,
                MobileCuratedWallScreen.STYLE_BLACK_HOLE_VORTEX);
        host.addView(mosaicHsv, new LinearLayout.LayoutParams(-1, -2));
    }

    private static String buildCuratedRenderFingerprint(
            boolean isDark,
            boolean hasUserSources,
            boolean firstUnderHero,
            List<Cms.Video>... lists) {
        StringBuilder sb = new StringBuilder(128);
        sb.append(isDark ? 'D' : 'L')
                .append(hasUserSources ? 'S' : 'N')
                .append(firstUnderHero ? 'F' : 'B');
        for (List<Cms.Video> list : lists) {
            sb.append('|');
            if (list == null || list.isEmpty()) {
                sb.append('0');
                continue;
            }
            sb.append(list.size()).append(':');
            Cms.Video first = list.get(0);
            if (first != null) {
                sb.append(first.id == null ? "" : first.id)
                        .append(':')
                        .append(first.poster == null ? "" : first.poster.hashCode());
            }
        }
        return sb.toString();
    }

    /** Dynamically harmonizes the first curated header ink when sitting over the Hero aura. */
    static void applyFirstHeaderInk(
            View curatedHost, MobileTheme.Palette p, boolean overAtmo, boolean useLightInk) {
        if (curatedHost == null) return;
        View titleV = curatedHost.findViewWithTag(TAG_FIRST_TITLE);
        View chevV = curatedHost.findViewWithTag(TAG_FIRST_CHEV);
        int titleCol = overAtmo ? (useLightInk ? Color.WHITE : 0xFF141821) : p.textPrimary;
        int chevCol = overAtmo ? (useLightInk ? 0xC4FFFFFF : 0xA6141821) : p.textTertiary;
        if (titleV instanceof TextView) ((TextView) titleV).setTextColor(titleCol);
        if (chevV instanceof MobileIcons.IconView) ((MobileIcons.IconView) chevV).setTint(chevCol);
    }

    private static void addSectionHeader(
            MainActivity a,
            LinearLayout parent,
            String title,
            String badgeText,
            Runnable onChevronTap,
            boolean markAsFirstUnderHero) {
        MobileTheme.Palette p = MobileTheme.of(a);
        LinearLayout row = a.row();
        row.setGravity(Gravity.CENTER_VERTICAL);
        row.setPadding(a.dp(16), a.dp(4), a.dp(16), a.dp(10));

        TextView titleTv = a.text(title, 18f, p.textPrimary);
        titleTv.setTypeface(null, Typeface.BOLD);
        if (markAsFirstUnderHero) titleTv.setTag(TAG_FIRST_TITLE);
        row.addView(titleTv);

        if (badgeText != null && !badgeText.isEmpty()) {
            TextView badge = a.text(badgeText, 10.5f, p.accent);
            badge.setTypeface(null, Typeface.BOLD);
            badge.setSingleLine(true);
            badge.setEllipsize(TextUtils.TruncateAt.END);
            badge.setPadding(a.dp(8), a.dp(2.5f), a.dp(8), a.dp(2.5f));
            badge.setBackground(a.bg(MobileTheme.withAlpha(p.accent, 0x22), 999));
            LinearLayout.LayoutParams bLp = new LinearLayout.LayoutParams(-2, -2);
            bLp.leftMargin = a.dp(8);
            row.addView(badge, bLp);
        }

        row.addView(new View(a), new LinearLayout.LayoutParams(0, 1, 1f));

        if (onChevronTap != null) {
            FrameLayout chevWrap = new FrameLayout(a);
            chevWrap.setPadding(a.dp(6), a.dp(4), a.dp(2), a.dp(4));
            MobileIcons.IconView chev =
                    MobileIcons.create(a, MobileIcons.IC_CHEVRON_RIGHT, 15.5f, p.textTertiary);
            if (markAsFirstUnderHero) chev.setTag(TAG_FIRST_CHEV);
            chevWrap.addView(
                    chev, new FrameLayout.LayoutParams(a.dp(15.5f), a.dp(15.5f), Gravity.CENTER));
            MobileMotion.bindPress(chevWrap, 0.90f);
            chevWrap.setOnClickListener(v -> onChevronTap.run());
            row.addView(chevWrap);
        }
        parent.addView(row, new LinearLayout.LayoutParams(-1, -2));
    }

    // -------------------------------------------------------------------------
    // 1. 光影风向标 (16:9 Widescreen Cinema Frame Shelf)
    // -------------------------------------------------------------------------
    private static void addWidescreenRadarShelf(
            final MainActivity a,
            LinearLayout parent,
            final Cms.Site curatedSite,
            final String title,
            final MobileCuratedDiscovery.ModuleSpec spec,
            final List<Cms.Video> items,
            boolean firstUnderHero,
            final boolean hasUserSources) {
        if (items == null || items.isEmpty()) return;
        MobileTheme.Palette p = MobileTheme.of(a);
        addSectionHeader(
                a,
                parent,
                title,
                null,
                () ->
                        MobileCuratedWallScreen.open(
                                a,
                                curatedSite,
                                title,
                                spec.subtitle,
                                spec.accentColor,
                                items,
                                hasUserSources,
                                MobileCuratedWallScreen.STYLE_GRAVITY_STACK),
                firstUnderHero);

        HorizontalScrollView hsv = new HorizontalScrollView(a);
        hsv.setHorizontalScrollBarEnabled(false);
        hsv.setClipToPadding(false);
        hsv.setPadding(a.dp(16), 0, a.dp(16), a.dp(2));
        LinearLayout row = a.row();
        row.setGravity(Gravity.TOP);
        row.setBaselineAligned(false);
        hsv.addView(row);

        int cardW = a.dp(208);
        int imgH = a.dp(117);
        for (final Cms.Video v : items) {
            LinearLayout card = a.vertical();
            FrameLayout box = new FrameLayout(a);
            box.setClipToOutline(true);
            box.setBackground(MobileTheme.subtleBg(a, 14));
            if (!p.isDark) UiCompat.setElevation(box, a.dp(2f));

            ImageView img = new ImageView(a);
            img.setScaleType(ImageView.ScaleType.CENTER_CROP);
            String imgUrl = MobileCuratedDiscovery.backdropFor(v);
            if (!imgUrl.isEmpty()) a.poster(imgUrl, img);
            box.addView(img, new FrameLayout.LayoutParams(-1, -1));

            View scrim = new View(a);
            scrim.setBackground(
                    new GradientDrawable(
                            GradientDrawable.Orientation.TOP_BOTTOM,
                            new int[] {Color.TRANSPARENT, 0x16000000, 0x70000000}));
            box.addView(scrim, new FrameLayout.LayoutParams(-1, -1));

            String scoreTag = shortScoreTag(v);
            if (!scoreTag.isEmpty()) {
                TextView badge = a.text(scoreTag, 10f, 0xFFFFD86B);
                badge.setTypeface(null, Typeface.BOLD);
                badge.setPadding(a.dp(6), a.dp(2), a.dp(6), a.dp(2));
                badge.setBackground(a.bg(0xA80A0B0E, 6));
                FrameLayout.LayoutParams bLp =
                        new FrameLayout.LayoutParams(-2, -2, Gravity.TOP | Gravity.RIGHT);
                bLp.setMargins(a.dp(7), a.dp(7), a.dp(7), a.dp(7));
                box.addView(badge, bLp);
            }
            card.addView(box, new LinearLayout.LayoutParams(cardW, imgH));

            TextView t = a.text(v.title == null ? "" : v.title, 13.5f, p.textPrimary);
            t.setTypeface(null, Typeface.BOLD);
            t.setSingleLine(true);
            t.setEllipsize(TextUtils.TruncateAt.END);
            t.setPadding(a.dp(2), a.dp(7), a.dp(2), 0);
            card.addView(t, new LinearLayout.LayoutParams(cardW, -2));

            String sub = buildMetaSubtitle(v);
            if (!sub.isEmpty()) {
                TextView st = a.text(sub, 11f, p.textTertiary);
                st.setSingleLine(true);
                st.setEllipsize(TextUtils.TruncateAt.END);
                st.setPadding(a.dp(2), a.dp(1.5f), a.dp(2), 0);
                card.addView(st, new LinearLayout.LayoutParams(cardW, -2));
            }
            MobileMotion.bindPress(card, 0.97f);
            card.setOnClickListener(
                    view ->
                            MobilePosterTransition.openDetailFromCard(
                                    a, curatedSite, v, box, 14f, false));
            LinearLayout.LayoutParams cLp = new LinearLayout.LayoutParams(cardW, -2);
            cLp.rightMargin = a.dp(12);
            row.addView(card, cLp);
        }
        parent.addView(hsv, new LinearLayout.LayoutParams(-1, -2));
    }

    // -------------------------------------------------------------------------
    // 2. 月度策划 · 藤蔓特辑 (Botanical Vine Editorial Collection Card)
    // -------------------------------------------------------------------------
    private static void addEditorialCollectionCard(
            final MainActivity a,
            LinearLayout row,
            final Cms.Site curatedSite,
            final String title,
            final MobileCuratedDiscovery.ModuleSpec spec,
            final List<Cms.Video> items,
            int tintBase,
            final int accentColor,
            final boolean hasUserSources,
            final int entranceStyle) {
        if (items == null || items.isEmpty()) return;
        final Cms.Video heroItem = items.get(0);
        List<Cms.Video> subItems = new ArrayList<>();
        if (items.size() > 2) {
            subItems.add(items.get(1));
            subItems.add(items.get(2));
        } else {
            for (int i = 0; i < Math.min(2, items.size()); i++) subItems.add(items.get(i));
        }

        int cardW = a.dp(294);
        LinearLayout card = a.vertical();
        GradientDrawable bg = a.bg(tintBase, 22);
        bg.setStroke(MobileTheme.hairlinePx(a), 0x26FFFFFF);
        card.setBackground(bg);
        card.setClipToOutline(true);
        UiCompat.setElevation(card, a.dp(4f));
        MobileMotion.bindPress(card, 0.98f);
        card.setOnClickListener(
                v ->
                        MobileCuratedWallScreen.open(
                                a,
                                curatedSite,
                                title,
                                spec.subtitle,
                                accentColor,
                                items,
                                hasUserSources,
                                entranceStyle));

        // Top 168dp Spotlight Backdrop + Botanical Vine Canvas + Centered Title
        FrameLayout topStage = new FrameLayout(a);
        ImageView heroBg = new ImageView(a);
        heroBg.setScaleType(ImageView.ScaleType.CENTER_CROP);
        String heroUrl = MobileCuratedDiscovery.backdropFor(heroItem);
        if (!heroUrl.isEmpty()) a.poster(heroUrl, heroBg);
        topStage.addView(heroBg, new FrameLayout.LayoutParams(-1, -1));

        View grad = new View(a);
        grad.setBackground(
                new GradientDrawable(
                        GradientDrawable.Orientation.TOP_BOTTOM,
                        new int[] {
                            0x20000000,
                            MobileTheme.withAlpha(tintBase, 0x62),
                            MobileTheme.withAlpha(tintBase, 0xF5)
                        }));
        topStage.addView(grad, new FrameLayout.LayoutParams(-1, -1));

        // Botanical climbing vine overlay
        topStage.addView(
                new BotanicalVineOverlayView(a, accentColor), new FrameLayout.LayoutParams(-1, -1));

        // Top-right count pill ("共 N 部 >")
        LinearLayout countPill = a.row();
        countPill.setGravity(Gravity.CENTER_VERTICAL);
        countPill.setPadding(a.dp(8), a.dp(3.5f), a.dp(6), a.dp(3.5f));
        GradientDrawable cpBg = a.bg(0x6B000000, 999);
        cpBg.setStroke(MobileTheme.hairlinePx(a), 0x30FFFFFF);
        countPill.setBackground(cpBg);
        TextView cpTxt = a.text("共 " + items.size() + " 部", 10f, Color.WHITE);
        cpTxt.setTypeface(null, Typeface.BOLD);
        countPill.addView(cpTxt);
        MobileIcons.IconView cpChev =
                MobileIcons.create(a, MobileIcons.IC_CHEVRON_RIGHT, 10f, 0xB8FFFFFF);
        LinearLayout.LayoutParams ccLp = new LinearLayout.LayoutParams(a.dp(10), a.dp(10));
        ccLp.leftMargin = a.dp(2);
        countPill.addView(cpChev, ccLp);
        FrameLayout.LayoutParams cpLp =
                new FrameLayout.LayoutParams(-2, -2, Gravity.TOP | Gravity.RIGHT);
        cpLp.setMargins(a.dp(10), a.dp(10), a.dp(10), a.dp(10));
        topStage.addView(countPill, cpLp);

        // Bottom centered title + featured spotlight subtitle
        LinearLayout titleCol = a.vertical();
        titleCol.setGravity(Gravity.CENTER_HORIZONTAL);
        titleCol.setPadding(a.dp(14), 0, a.dp(14), a.dp(10));

        LinearLayout titleRow = a.row();
        titleRow.setGravity(Gravity.CENTER);
        titleRow.addView(
                new BotanicalFlourishView(a, false, accentColor),
                new LinearLayout.LayoutParams(a.dp(22), a.dp(22)));
        TextView titleTv = a.text(title, 16.5f, Color.WHITE);
        titleTv.setTypeface(null, Typeface.BOLD);
        titleTv.setSingleLine(true);
        titleTv.setEllipsize(TextUtils.TruncateAt.END);
        titleTv.setShadowLayer(a.dp(8), 0f, a.dp(2), 0x88000000);
        LinearLayout.LayoutParams tLp = new LinearLayout.LayoutParams(-2, -2);
        tLp.leftMargin = a.dp(6);
        tLp.rightMargin = a.dp(6);
        titleRow.addView(titleTv, tLp);
        titleRow.addView(
                new BotanicalFlourishView(a, true, accentColor),
                new LinearLayout.LayoutParams(a.dp(22), a.dp(22)));
        titleCol.addView(titleRow, new LinearLayout.LayoutParams(-1, -2));

        TextView heroSub = a.text(heroItem.title == null ? "" : heroItem.title, 11.5f, 0xC8FFFFFF);
        heroSub.setSingleLine(true);
        heroSub.setEllipsize(TextUtils.TruncateAt.END);
        heroSub.setPadding(0, a.dp(3), 0, 0);
        titleCol.addView(heroSub);

        topStage.addView(titleCol, new FrameLayout.LayoutParams(-1, -2, Gravity.BOTTOM));
        card.addView(topStage, new LinearLayout.LayoutParams(-1, a.dp(168)));

        // Bottom 2-up 16:9 mini-cards
        LinearLayout bottomRow = a.row();
        bottomRow.setGravity(Gravity.TOP);
        bottomRow.setBaselineAligned(false);
        bottomRow.setPadding(a.dp(12), a.dp(10), a.dp(12), a.dp(12));
        bottomRow.setBackgroundColor(MobileTheme.withAlpha(tintBase, 0xF0));
        for (int i = 0; i < subItems.size(); i++) {
            final Cms.Video subV = subItems.get(i);
            LinearLayout mini = a.vertical();
            FrameLayout miniBox = new FrameLayout(a);
            miniBox.setClipToOutline(true);
            miniBox.setBackground(a.bg(0x47000000, 11));
            ImageView miniImg = new ImageView(a);
            miniImg.setScaleType(ImageView.ScaleType.CENTER_CROP);
            String mUrl = MobileCuratedDiscovery.backdropFor(subV);
            if (!mUrl.isEmpty()) a.poster(mUrl, miniImg);
            miniBox.addView(miniImg, new FrameLayout.LayoutParams(-1, -1));
            mini.addView(miniBox, new LinearLayout.LayoutParams(-1, a.dp(74)));

            TextView mt = a.text(subV.title == null ? "" : subV.title, 12f, Color.WHITE);
            mt.setTypeface(null, Typeface.BOLD);
            mt.setSingleLine(true);
            mt.setEllipsize(TextUtils.TruncateAt.END);
            mt.setPadding(0, a.dp(6), 0, 0);
            mini.addView(mt, new LinearLayout.LayoutParams(-1, -2));

            String mSub = buildMetaSubtitle(subV);
            TextView ms = a.text(mSub.isEmpty() ? "精选推荐" : mSub, 10.5f, 0xA6FFFFFF);
            ms.setSingleLine(true);
            ms.setEllipsize(TextUtils.TruncateAt.END);
            mini.addView(ms, new LinearLayout.LayoutParams(-1, -2));

            MobileMotion.bindPress(mini, 0.96f);
            mini.setOnClickListener(
                    v ->
                            MobilePosterTransition.openDetailFromCard(
                                    a, curatedSite, subV, miniBox, 11f, false));
            LinearLayout.LayoutParams mLp = new LinearLayout.LayoutParams(0, -2, 1f);
            if (i > 0) mLp.leftMargin = a.dp(10);
            bottomRow.addView(mini, mLp);
        }
        card.addView(bottomRow, new LinearLayout.LayoutParams(-1, -2));

        LinearLayout.LayoutParams cardLp = new LinearLayout.LayoutParams(cardW, -2);
        cardLp.rightMargin = a.dp(14);
        row.addView(card, cardLp);
    }

    // -------------------------------------------------------------------------
    // 3. 热播剧影榜 (Ranked 2:3 Vertical Poster Shelf)
    // -------------------------------------------------------------------------
    private static void addRankedPortraitShelf(
            final MainActivity a,
            LinearLayout parent,
            final Cms.Site curatedSite,
            final String title,
            final MobileCuratedDiscovery.ModuleSpec spec,
            final List<Cms.Video> items,
            final boolean hasUserSources) {
        if (items == null || items.isEmpty()) return;
        MobileTheme.Palette p = MobileTheme.of(a);
        addSectionHeader(
                a,
                parent,
                title,
                null,
                () ->
                        MobileCuratedWallScreen.open(
                                a,
                                curatedSite,
                                title,
                                spec.subtitle,
                                spec.accentColor,
                                items,
                                hasUserSources,
                                MobileCuratedWallScreen.STYLE_GRAVITY_STACK),
                false);

        HorizontalScrollView hsv = new HorizontalScrollView(a);
        hsv.setHorizontalScrollBarEnabled(false);
        hsv.setClipToPadding(false);
        hsv.setPadding(a.dp(16), 0, a.dp(16), a.dp(2));
        LinearLayout row = a.row();
        row.setGravity(Gravity.TOP);
        row.setBaselineAligned(false);
        hsv.addView(row);

        int cardW = a.dp(112);
        int posterH = a.dp(166);
        for (int i = 0; i < items.size(); i++) {
            final Cms.Video v = items.get(i);
            final int rank = i + 1;
            LinearLayout card = a.vertical();

            FrameLayout box = new FrameLayout(a);
            box.setClipToOutline(true);
            box.setBackground(MobileTheme.subtleBg(a, 13));
            if (!p.isDark) UiCompat.setElevation(box, a.dp(2f));

            ImageView img = new ImageView(a);
            img.setScaleType(ImageView.ScaleType.CENTER_CROP);
            if (v.poster != null && !v.poster.isEmpty()) a.poster(v.poster, img);
            box.addView(img, new FrameLayout.LayoutParams(-1, -1));

            // Top-left rank badge (01..03 accent gradient, 04+ dark translucent)
            TextView rankTv = a.text(String.format(Locale.US, "%02d", rank), 9.5f, Color.WHITE);
            rankTv.setTypeface(null, Typeface.BOLD);
            rankTv.setPadding(a.dp(6), a.dp(2), a.dp(6), a.dp(2));
            if (rank <= 3) {
                GradientDrawable rBg =
                        new GradientDrawable(
                                GradientDrawable.Orientation.LEFT_RIGHT,
                                new int[] {
                                    MobileTheme.withAlpha(spec.accentColor, 0xEB),
                                    MobileTheme.withAlpha(spec.accentColor, 0xAD)
                                });
                rBg.setCornerRadius(a.dp(6));
                rankTv.setBackground(rBg);
            } else {
                rankTv.setBackground(a.bg(0xB80A0B0E, 6));
            }
            FrameLayout.LayoutParams rLp =
                    new FrameLayout.LayoutParams(-2, -2, Gravity.TOP | Gravity.LEFT);
            rLp.setMargins(a.dp(6), a.dp(6), a.dp(6), a.dp(6));
            box.addView(rankTv, rLp);

            // Top-right rating badge
            String scoreTag = shortScoreTag(v);
            if (!scoreTag.isEmpty()) {
                TextView sc = a.text(scoreTag, 9.5f, 0xFFFFD86B);
                sc.setTypeface(null, Typeface.BOLD);
                sc.setPadding(a.dp(5.5f), a.dp(2), a.dp(5.5f), a.dp(2));
                sc.setBackground(a.bg(0xAD0A0B0E, 6));
                FrameLayout.LayoutParams sLp =
                        new FrameLayout.LayoutParams(-2, -2, Gravity.TOP | Gravity.RIGHT);
                sLp.setMargins(a.dp(6), a.dp(6), a.dp(6), a.dp(6));
                box.addView(sc, sLp);
            }
            card.addView(box, new LinearLayout.LayoutParams(cardW, posterH));

            TextView t = a.text(v.title == null ? "" : v.title, 12.5f, p.textPrimary);
            t.setTypeface(null, Typeface.BOLD);
            t.setSingleLine(true);
            t.setEllipsize(TextUtils.TruncateAt.END);
            t.setPadding(a.dp(2), a.dp(6), a.dp(2), 0);
            card.addView(t, new LinearLayout.LayoutParams(cardW, -2));

            MobileMotion.bindPress(card, 0.97f);
            card.setOnClickListener(
                    view ->
                            MobilePosterTransition.openDetailFromCard(
                                    a, curatedSite, v, box, 13f, false));
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(cardW, -2);
            lp.rightMargin = a.dp(11);
            row.addView(card, lp);
        }
        parent.addView(hsv, new LinearLayout.LayoutParams(-1, -2));
    }

    // -------------------------------------------------------------------------
    // 4. 灵感片单 (Fanned 3-Poster Mood Capsule)
    // -------------------------------------------------------------------------
    private static void addMoodCapsule(
            final MainActivity a,
            LinearLayout row,
            final Cms.Site curatedSite,
            final String label,
            final MobileCuratedDiscovery.ModuleSpec spec,
            final List<Cms.Video> items,
            final boolean hasUserSources,
            final int entranceStyle) {
        MobileTheme.Palette p = MobileTheme.of(a);
        LinearLayout pill = a.row();
        pill.setGravity(Gravity.CENTER_VERTICAL);
        pill.setMinimumHeight(a.dp(56));
        pill.setPadding(a.dp(11), a.dp(6), a.dp(16), a.dp(6));
        GradientDrawable bg = a.bg(p.isDark ? 0xFF1C1F28 : p.bgCard, 16);
        bg.setStroke(MobileTheme.hairlinePx(a), p.isDark ? 0x1FFFFFFF : 0x10000000);
        pill.setBackground(bg);
        if (!p.isDark) UiCompat.setElevation(pill, a.dp(2f));

        FrameLayout stackBox = new FrameLayout(a);
        stackBox.setClipChildren(false);
        int count = Math.min(3, items == null ? 0 : items.size());
        for (int i = count - 1; i >= 0; i--) {
            Cms.Video v = items.get(i);
            FrameLayout mini = new FrameLayout(a);
            mini.setClipToOutline(true);
            GradientDrawable mb = a.bg(p.bgSubtle, 6);
            mb.setStroke(MobileTheme.hairlinePx(a), 0x48FFFFFF);
            mini.setBackground(mb);
            ImageView iv = new ImageView(a);
            iv.setScaleType(ImageView.ScaleType.CENTER_CROP);
            if (v.poster != null && !v.poster.isEmpty()) {
                ImageLoader.posterCompact(a, v.poster, iv, a.dp(48), a.dp(68));
            }
            mini.addView(iv, new FrameLayout.LayoutParams(-1, -1));
            FrameLayout.LayoutParams mLp =
                    new FrameLayout.LayoutParams(
                            a.dp(28), a.dp(40), Gravity.LEFT | Gravity.CENTER_VERTICAL);
            mLp.leftMargin = a.dp(i * 5.5f);
            mini.setRotation((i - 1) * 4f);
            stackBox.addView(mini, mLp);
        }
        LinearLayout.LayoutParams sbLp = new LinearLayout.LayoutParams(a.dp(44), a.dp(44));
        sbLp.rightMargin = a.dp(10);
        pill.addView(stackBox, sbLp);

        TextView lbl = a.text(label, 14f, p.textPrimary);
        lbl.setTypeface(null, Typeface.BOLD);
        lbl.setSingleLine(true);
        pill.addView(lbl);

        MobileMotion.bindPress(pill, 0.95f);
        pill.setOnClickListener(
                v ->
                        MobileCuratedWallScreen.open(
                                a,
                                curatedSite,
                                label,
                                spec.subtitle,
                                spec.accentColor,
                                items,
                                hasUserSources,
                                entranceStyle));
        LinearLayout.LayoutParams pLp = new LinearLayout.LayoutParams(-2, -2);
        pLp.rightMargin = a.dp(10);
        row.addView(pill, pLp);
    }

    // -------------------------------------------------------------------------
    // 5. 影业档案室 (Studio Brand Fan Card: Disney / MARVEL / DC)
    // -------------------------------------------------------------------------
    private static void addStudioFanCard(
            final MainActivity a,
            LinearLayout row,
            final Cms.Site curatedSite,
            int brandKind,
            final MobileCuratedDiscovery.ModuleSpec spec,
            final List<Cms.Video> items,
            final boolean hasUserSources,
            final int entranceStyle) {
        int cStart = brandKind == 0 ? 0xFF0E1B36 : (brandKind == 1 ? 0xFF221015 : 0xFF0D1729);
        int cEnd = brandKind == 0 ? 0xFF142A54 : (brandKind == 1 ? 0xFF3E131B : 0xFF102A56);

        FrameLayout card = new FrameLayout(a);
        card.setClipToOutline(true);
        GradientDrawable bg =
                new GradientDrawable(GradientDrawable.Orientation.TL_BR, new int[] {cStart, cEnd});
        bg.setCornerRadius(a.dp(18));
        bg.setStroke(MobileTheme.hairlinePx(a), 0x26FFFFFF);
        card.setBackground(bg);
        UiCompat.setElevation(card, a.dp(3f));

        // Right tilted 2x2 poster fan collage
        LinearLayout grid = a.vertical();
        grid.setRotation(13f);
        for (int r = 0; r < 2; r++) {
            LinearLayout rRow = a.row();
            for (int c = 0; c < 2; c++) {
                int idx = r * 2 + c;
                FrameLayout tile = new FrameLayout(a);
                tile.setClipToOutline(true);
                tile.setBackground(a.bg(0x16FFFFFF, 7));
                if (items != null && idx < items.size()) {
                    Cms.Video v = items.get(idx);
                    ImageView iv = new ImageView(a);
                    iv.setScaleType(ImageView.ScaleType.CENTER_CROP);
                    if (v.poster != null && !v.poster.isEmpty()) {
                        ImageLoader.posterCompact(a, v.poster, iv, a.dp(72), a.dp(96));
                    }
                    tile.addView(iv, new FrameLayout.LayoutParams(-1, -1));
                }
                LinearLayout.LayoutParams tLp = new LinearLayout.LayoutParams(a.dp(48), a.dp(62));
                tLp.setMargins(a.dp(3), a.dp(3), a.dp(3), a.dp(3));
                rRow.addView(tile, tLp);
            }
            grid.addView(rRow);
        }
        FrameLayout.LayoutParams gLp =
                new FrameLayout.LayoutParams(-2, -2, Gravity.RIGHT | Gravity.CENTER_VERTICAL);
        gLp.rightMargin = -a.dp(12);
        card.addView(grid, gLp);

        // Smooth left-to-right gradient mask so brand emblem pops crisply
        View mask = new View(a);
        mask.setBackground(
                new GradientDrawable(
                        GradientDrawable.Orientation.LEFT_RIGHT,
                        new int[] {
                            cStart,
                            MobileTheme.withAlpha(cStart, 0xEB),
                            MobileTheme.withAlpha(cEnd, 0x38)
                        }));
        card.addView(mask, new FrameLayout.LayoutParams(-1, -1));

        // Left studio brand emblem
        LinearLayout emblem = a.vertical();
        emblem.setGravity(Gravity.CENTER_VERTICAL);
        emblem.setPadding(a.dp(15), a.dp(10), a.dp(10), a.dp(10));
        if (brandKind == 0) {
            emblem.addView(new DisneyArcView(a), new LinearLayout.LayoutParams(a.dp(74), a.dp(14)));
            TextView dTitle = a.text("Disney+", 20f, Color.WHITE);
            dTitle.setTypeface(Typeface.SERIF, Typeface.BOLD_ITALIC);
            emblem.addView(dTitle);
            TextView dSub = a.text("PIXAR · 动画经典", 10f, 0xB8FFFFFF);
            dSub.setPadding(0, a.dp(2), 0, 0);
            emblem.addView(dSub);
        } else if (brandKind == 1) {
            TextView mBadge = a.text("MARVEL", 17f, Color.WHITE);
            mBadge.setTypeface(null, Typeface.BOLD);
            mBadge.setPadding(a.dp(8), a.dp(3), a.dp(8), a.dp(3));
            mBadge.setBackground(a.bg(0xFFE62429, 5));
            emblem.addView(mBadge, new LinearLayout.LayoutParams(-2, -2));
            TextView mSub = a.text("超级英雄宇宙", 10.5f, 0xC4FFFFFF);
            mSub.setPadding(0, a.dp(6), 0, 0);
            emblem.addView(mSub);
        } else {
            TextView dcBadge = a.text("DC", 18f, Color.WHITE);
            dcBadge.setTypeface(null, Typeface.BOLD);
            dcBadge.setGravity(Gravity.CENTER);
            GradientDrawable dcRing = a.bg(0xFF0476F2, 999);
            dcRing.setStroke(a.dp(1.5f), 0xCCFFFFFF);
            dcBadge.setBackground(dcRing);
            emblem.addView(dcBadge, new LinearLayout.LayoutParams(a.dp(40), a.dp(40)));
            TextView dcSub = a.text("哥谭暗黑史诗", 10.5f, 0xC4FFFFFF);
            dcSub.setPadding(0, a.dp(5), 0, 0);
            emblem.addView(dcSub);
        }
        card.addView(emblem, new FrameLayout.LayoutParams(a.dp(120), -1, Gravity.LEFT));

        MobileMotion.bindPress(card, 0.96f);
        card.setOnClickListener(
                v ->
                        MobileCuratedWallScreen.open(
                                a,
                                curatedSite,
                                spec.title,
                                spec.subtitle,
                                spec.accentColor,
                                items,
                                hasUserSources,
                                entranceStyle));
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(a.dp(218), a.dp(112));
        lp.rightMargin = a.dp(12);
        row.addView(card, lp);
    }

    // -------------------------------------------------------------------------
    // 6. 口碑典藏馆 (3-Row Staggered Poster Mosaic Collector Card)
    // -------------------------------------------------------------------------
    private static void addMosaicCard(
            MainActivity a,
            LinearLayout row,
            Cms.Site curatedSite,
            String title,
            String subtitle,
            List<Cms.Video> previewItems,
            int accentColor,
            boolean hasUserSources,
            int entranceStyle) {
        addMosaicCard(
                a,
                row,
                curatedSite,
                title,
                subtitle,
                previewItems,
                accentColor,
                hasUserSources,
                previewItems,
                entranceStyle);
    }

    private static void addMosaicCard(
            final MainActivity a,
            LinearLayout row,
            final Cms.Site curatedSite,
            final String title,
            final String subtitle,
            List<Cms.Video> previewItems,
            final int accentColor,
            final boolean hasUserSources,
            final List<Cms.Video> fullItems,
            final int entranceStyle) {
        FrameLayout card = new FrameLayout(a);
        card.setClipToOutline(true);
        GradientDrawable bg = a.bg(0xFF15171F, 22);
        bg.setStroke(MobileTheme.hairlinePx(a), 0x22FFFFFF);
        card.setBackground(bg);
        UiCompat.setElevation(card, a.dp(4f));

        // 3 staggered rows of 4 mini posters
        LinearLayout rowsCol = a.vertical();
        for (int r = 0; r < 3; r++) {
            LinearLayout mRow = a.row();
            mRow.setPadding(r % 2 == 1 ? a.dp(10) : 0, r == 0 ? 0 : a.dp(5), 0, 0);
            for (int c = 0; c < 4; c++) {
                FrameLayout tile = new FrameLayout(a);
                tile.setClipToOutline(true);
                tile.setBackground(a.bg(0xFF232630, 7));
                if (previewItems != null && !previewItems.isEmpty()) {
                    Cms.Video v = previewItems.get((r * 4 + c) % previewItems.size());
                    ImageView iv = new ImageView(a);
                    iv.setScaleType(ImageView.ScaleType.CENTER_CROP);
                    if (v.poster != null && !v.poster.isEmpty()) {
                        ImageLoader.posterCompact(a, v.poster, iv, a.dp(72), a.dp(96));
                    }
                    tile.addView(iv, new FrameLayout.LayoutParams(-1, -1));
                }
                LinearLayout.LayoutParams tLp = new LinearLayout.LayoutParams(0, -1, 1f);
                if (c > 0) tLp.leftMargin = a.dp(5);
                mRow.addView(tile, tLp);
            }
            rowsCol.addView(mRow, new LinearLayout.LayoutParams(-1, 0, 1f));
        }
        card.addView(rowsCol, new FrameLayout.LayoutParams(-1, -1));

        // Deep feathered bottom scrim cradling title & circular accent button
        View scrim = new View(a);
        scrim.setBackground(
                new GradientDrawable(
                        GradientDrawable.Orientation.TOP_BOTTOM,
                        new int[] {0x0D000000, 0x30000000, 0xE611131B, 0xFF101219}));
        card.addView(scrim, new FrameLayout.LayoutParams(-1, -1));

        LinearLayout footer = a.row();
        footer.setGravity(Gravity.BOTTOM);
        footer.setPadding(a.dp(15), 0, a.dp(15), a.dp(14));

        LinearLayout copy = a.vertical();
        TextView tTv = a.text(title, 19f, Color.WHITE);
        tTv.setTypeface(null, Typeface.BOLD);
        tTv.setSingleLine(true);
        tTv.setEllipsize(TextUtils.TruncateAt.END);
        copy.addView(tTv);

        TextView sTv = a.text(subtitle, 11.5f, 0xB0FFFFFF);
        sTv.setSingleLine(true);
        sTv.setEllipsize(TextUtils.TruncateAt.END);
        sTv.setPadding(0, a.dp(2), 0, 0);
        copy.addView(sTv);
        footer.addView(copy, new LinearLayout.LayoutParams(0, -2, 1f));

        FrameLayout circleChev = new FrameLayout(a);
        circleChev.setBackground(a.bg(MobileTheme.withAlpha(accentColor, 0xE0), 999));
        MobileIcons.IconView ic =
                MobileIcons.create(a, MobileIcons.IC_CHEVRON_RIGHT, 13f, Color.WHITE);
        circleChev.addView(ic, new FrameLayout.LayoutParams(a.dp(13), a.dp(13), Gravity.CENTER));
        LinearLayout.LayoutParams cLp = new LinearLayout.LayoutParams(a.dp(28), a.dp(28));
        cLp.leftMargin = a.dp(8);
        footer.addView(circleChev, cLp);

        card.addView(footer, new FrameLayout.LayoutParams(-1, -2, Gravity.BOTTOM));

        MobileMotion.bindPress(card, 0.96f);
        card.setOnClickListener(
                v ->
                        MobileCuratedWallScreen.open(
                                a,
                                curatedSite,
                                title,
                                subtitle,
                                accentColor,
                                fullItems,
                                hasUserSources,
                                entranceStyle));
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(a.dp(234), a.dp(264));
        lp.rightMargin = a.dp(14);
        row.addView(card, lp);
    }

    private static String shortScoreTag(Cms.Video v) {
        if (v == null || v.remarks == null) return "";
        String r = v.remarks.trim();
        if (r.startsWith("豆瓣 ")) return "豆 " + r.substring(3).trim();
        return r;
    }

    private static String buildMetaSubtitle(Cms.Video v) {
        if (v == null) return "";
        String genre = MobileCuratedDiscovery.genreFor(v);
        StringBuilder sb = new StringBuilder();
        if (v.year != null && !v.year.trim().isEmpty()) sb.append(v.year.trim());
        String tail = !genre.isEmpty() ? genre : (v.remarks != null ? v.remarks.trim() : "");
        if (!tail.isEmpty()) {
            if (sb.length() > 0) sb.append(" · ");
            sb.append(tail);
        }
        return sb.toString();
    }

    /** Custom-drawn sweeping corner vines across the top edge of 月度策划 cards. */
    private static final class BotanicalVineOverlayView extends View {
        private final Paint vinePaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint leafPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final MainActivity a;

        BotanicalVineOverlayView(MainActivity a, int accentColor) {
            super(a);
            this.a = a;
            vinePaint.setColor(
                    MobileTheme.withAlpha(
                            MobileTheme.blend(Color.WHITE, accentColor, 0.30f), 0x45));
            vinePaint.setStyle(Paint.Style.STROKE);
            vinePaint.setStrokeWidth(a.dp(1.25f));
            vinePaint.setStrokeCap(Paint.Cap.ROUND);
            leafPaint.setColor(0x3DFFFFFF);
            leafPaint.setStyle(Paint.Style.FILL);
        }

        @Override
        protected void onDraw(Canvas canvas) {
            Path p = new Path();
            p.moveTo(-a.dp(4), a.dp(24));
            p.cubicTo(a.dp(22), a.dp(10), a.dp(44), a.dp(34), a.dp(72), a.dp(14));
            p.quadTo(a.dp(88), a.dp(4), a.dp(104), a.dp(12));
            canvas.drawPath(p, vinePaint);

            float[][] leaves = {{26f, 17f, -24f}, {52f, 23f, 28f}, {78f, 12f, -34f}};
            for (float[] lf : leaves) {
                int s = canvas.save();
                canvas.translate(a.dp(lf[0]), a.dp(lf[1]));
                canvas.rotate(lf[2]);
                canvas.drawOval(-a.dp(4), -a.dp(1.7f), a.dp(4), a.dp(1.7f), leafPaint);
                canvas.restoreToCount(s);
            }
        }
    }

    /** Climbing botanical vine flourish flanking the centered 月度策划 card title. */
    private static final class BotanicalFlourishView extends View {
        private final boolean flip;
        private final Paint vinePaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint leafPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint budPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final MainActivity a;

        BotanicalFlourishView(MainActivity a, boolean flip, int accentColor) {
            super(a);
            this.a = a;
            this.flip = flip;
            vinePaint.setColor(
                    MobileTheme.withAlpha(
                            MobileTheme.blend(Color.WHITE, accentColor, 0.28f), 0xE0));
            vinePaint.setStyle(Paint.Style.STROKE);
            vinePaint.setStrokeWidth(a.dp(1.4f));
            vinePaint.setStrokeCap(Paint.Cap.ROUND);
            leafPaint.setColor(0xE6FFFFFF);
            budPaint.setColor(0xFFFFE7A3);
        }

        @Override
        protected void onDraw(Canvas canvas) {
            int w = getWidth(), h = getHeight();
            if (w <= 0 || h <= 0) return;
            int save = canvas.save();
            if (flip) {
                canvas.scale(-1f, 1f, w * 0.5f, h * 0.5f);
            }
            Path stem = new Path();
            stem.moveTo(w * 0.92f, h * 0.86f);
            stem.cubicTo(w * 0.56f, h * 0.92f, w * 0.26f, h * 0.62f, w * 0.34f, h * 0.34f);
            stem.cubicTo(w * 0.42f, h * 0.14f, w * 0.16f, h * 0.08f, w * 0.08f, h * 0.24f);
            canvas.drawPath(stem, vinePaint);

            float[][] leaves = {
                {0.32f, 0.40f, -42f, 1.0f},
                {0.46f, 0.58f, 26f, 0.9f},
                {0.68f, 0.80f, -20f, 0.85f},
                {0.24f, 0.20f, -62f, 0.75f}
            };
            for (float[] lf : leaves) {
                int ls = canvas.save();
                canvas.translate(w * lf[0], h * lf[1]);
                canvas.rotate(lf[2]);
                float sc = a.dp(lf[3]);
                Path lp = new Path();
                lp.moveTo(0f, 0f);
                lp.quadTo(3.2f * sc, -2.2f * sc, 6.2f * sc, 0f);
                lp.quadTo(3.2f * sc, 2.2f * sc, 0f, 0f);
                lp.close();
                canvas.drawPath(lp, leafPaint);
                canvas.restoreToCount(ls);
            }
            canvas.drawCircle(w * 0.12f, h * 0.28f, a.dp(1.6f), budPaint);
            canvas.restoreToCount(save);
        }
    }

    /** Disney shooting-star glowing arc rendered above the Disney+ studio emblem. */
    private static final class DisneyArcView extends View {
        private final Paint arcPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final MainActivity a;
        private int lastW = -1;

        DisneyArcView(MainActivity a) {
            super(a);
            this.a = a;
            arcPaint.setStyle(Paint.Style.STROKE);
            arcPaint.setStrokeWidth(a.dp(1.8f));
            arcPaint.setStrokeCap(Paint.Cap.ROUND);
        }

        @Override
        protected void onDraw(Canvas canvas) {
            int w = getWidth(), h = getHeight();
            if (w <= 0 || h <= 0) return;
            if (w != lastW) {
                lastW = w;
                arcPaint.setShader(
                        new LinearGradient(
                                0f,
                                0f,
                                w,
                                0f,
                                new int[] {0x3340C8FF, 0xFF7CE8FF, Color.WHITE},
                                null,
                                Shader.TileMode.CLAMP));
            }
            Path p = new Path();
            p.moveTo(a.dp(2), h);
            p.quadTo(w * 0.48f, -h * 0.35f, w - a.dp(2), h * 0.85f);
            canvas.drawPath(p, arcPaint);
        }
    }
}
