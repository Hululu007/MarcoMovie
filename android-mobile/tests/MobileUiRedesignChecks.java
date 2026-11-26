package com.pilipala.marcomovie;

import com.pilipala.marcomovie.hud.SpeedLockCapsule;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;

/**
 * Dedicated verification suite for the Android Mobile global UI redesign covering:
 *  1. MobileTheme semantic Day/Night tokens, accent presets, Prefs.THEME_MODE bounds, and
 *     styles.xml / AndroidManifest.xml configuration contracts.
 *  2. MobileBottomSheet height policy and PluginDialogStyler anti-hijack exemption contracts.
 *  3. MobileFilterSheet pure-JVM multi-dimensional capsule helpers and VideoFilterDialog wiring.
 *  4. MobileSettingsIndex search coverage across all 7 sub-pages and icon/emoji hygiene.
 *  5. Player Touch HUD pure-JVM visibility/telemetry/order contracts and static hygiene.
 *  6. MobileMotion physics, reduced-motion policy, interruptible spring continuity, and 120fps
 *     spring frame-budget microbenchmark.
 *  7. UX first-principles state logic (reversible filters, progressive disclosure, clipboard
 *     import classification, dark-surface contrast lift).
 *  8. Static UX confirmation coverage, zero legacy emoji/color/interpolator hygiene, and
 *     reviewer P0/P1/P2 regression guards.
 */
public final class MobileUiRedesignChecks {
    private static int passed;

    private static void check(boolean cond, String label) {
        if (!cond) {
            throw new AssertionError("FAILED: " + label);
        }
        passed++;
        System.out.println("PASS " + label);
    }

    private static String readUtf8(Path root, String relativePath) throws Exception {
        return Files.readString(root.resolve(relativePath), StandardCharsets.UTF_8);
    }

    private static void test1_MobileThemeAndPrefs(Path root) throws Exception {
        check(
                MobileTheme.MODE_SYSTEM == 0
                        && MobileTheme.MODE_LIGHT == 1
                        && MobileTheme.MODE_DARK == 2,
                "Pillar 1: MobileTheme mode constants are SYSTEM=0, LIGHT=1, DARK=2");

        // Configuration.UI_MODE_NIGHT_NO = 0x10, UI_MODE_NIGHT_YES = 0x20
        final int uiNightYes = 0x20;
        final int uiNightNo = 0x10;
        check(
                MobileTheme.isDarkForConfig(uiNightYes, MobileTheme.MODE_SYSTEM),
                "Pillar 1: MODE_SYSTEM resolves dark when uiMode is NIGHT_YES");
        check(
                !MobileTheme.isDarkForConfig(uiNightNo, MobileTheme.MODE_SYSTEM),
                "Pillar 1: MODE_SYSTEM resolves light when uiMode is NIGHT_NO");
        check(
                MobileTheme.isDarkForConfig(uiNightYes | 0x01, MobileTheme.MODE_SYSTEM)
                        && !MobileTheme.isDarkForConfig(uiNightNo | 0x01, MobileTheme.MODE_SYSTEM)
                        && !MobileTheme.isDarkForConfig(0, MobileTheme.MODE_SYSTEM),
                "Pillar 1: MODE_SYSTEM masks UI_MODE_NIGHT_MASK cleanly with other config bits");
        check(
                !MobileTheme.isDarkForConfig(uiNightYes, MobileTheme.MODE_LIGHT)
                        && !MobileTheme.isDarkForConfig(uiNightNo, MobileTheme.MODE_LIGHT),
                "Pillar 1: MODE_LIGHT forces light regardless of system uiMode");
        check(
                MobileTheme.isDarkForConfig(uiNightNo, MobileTheme.MODE_DARK)
                        && MobileTheme.isDarkForConfig(uiNightYes, MobileTheme.MODE_DARK),
                "Pillar 1: MODE_DARK forces dark regardless of system uiMode");

        check(
                "跟随系统".equals(MobileTheme.themeModeLabel(MobileTheme.MODE_SYSTEM))
                        && "浅色日间".equals(MobileTheme.themeModeLabel(MobileTheme.MODE_LIGHT))
                        && "深色夜间".equals(MobileTheme.themeModeLabel(MobileTheme.MODE_DARK))
                        && "跟随系统".equals(MobileTheme.themeModeLabel(99)),
                "Pillar 1: MobileTheme.themeModeLabel maps all modes and invalid fallback");

        // Daylight Alabaster palette
        MobileTheme.Palette light = MobileTheme.forState(false, 0);
        check(
                !light.isDark
                        && light.bgCanvas == 0xFFF3F5F9
                        && light.bgCard == 0xFFFFFFFF
                        && light.bgSheet == 0xFFFFFFFF
                        && light.bgSubtle == 0xFFE7EBF2
                        && light.bgPressed == 0xFFDFE5EE
                        && light.textPrimary == 0xFF11141A
                        && light.textSecondary == 0xFF5C6472
                        && light.textTertiary == 0xFF8E96A5
                        && light.accent == 0xFF007AFF
                        && light.accentOnFill == 0xFFFFFFFF,
                "Pillar 1: Daylight Alabaster (light, preset 0) tokens match design spec");

        // Cinema Obsidian palette (zero #0b1311 swamp green)
        MobileTheme.Palette dark = MobileTheme.forState(true, 0);
        check(
                dark.isDark
                        && dark.bgCanvas == 0xFF0A0B0E
                        && dark.bgCard == 0xFF15171E
                        && dark.bgSheet == 0xFF161922
                        && dark.bgSubtle == 0xFF20232D
                        && dark.bgPressed == 0xFF282C38
                        && dark.textPrimary == 0xFFF3F5F9
                        && dark.textSecondary == 0xFF949BA8
                        && dark.textTertiary == 0xFF606775
                        && dark.accent == 0xFF007AFF
                        && dark.bgCanvas != 0xFF0B1311
                        && dark.bgCard != 0xFF0B1311,
                "Pillar 1: Cinema Obsidian (dark, preset 0) tokens match design spec with zero #0b1311");

        // All 8 accent presets (0..7)
        int[] expectedAccents = {
            0xFF007AFF,
            0xFFFF2D55,
            0xFF10B981,
            0xFF8B5CF6,
            0xFFF59E0B,
            0xFF64748B,
            0xFFF97316,
            0xFF14B8A6
        };
        check(
                MobileTheme.ACCENT_COLORS.length == 8 && MobileTheme.ACCENT_NAMES.length == 8,
                "Pillar 1: MobileTheme exposes all 8 accent presets");
        for (int i = 0; i < expectedAccents.length; i++) {
            int expected = expectedAccents[i];
            check(
                    Prefs.accentColorForPreset(i) == expected
                            && MobileTheme.ACCENT_COLORS[i] == expected
                            && MobileTheme.forState(false, i).accent == expected
                            && MobileTheme.forState(true, i).accent == expected
                            && !MobileTheme.accentName(i).isEmpty(),
                    "Pillar 1: accent preset " + i + " matches Prefs & MobileTheme palettes");
        }
        check(
                Prefs.accentColorForPreset(-1) == 0xFF007AFF
                        && Prefs.accentColorForPreset(99) == 0xFF007AFF
                        && MobileTheme.accentName(0).equals(MobileTheme.accentName(-1))
                        && MobileTheme.accentName(0).equals(MobileTheme.accentName(99)),
                "Pillar 1: out-of-range accent presets fall back to Classic Azure (0)");
        check(
                MobileTheme.withAlpha(0xFF007AFF, 0x33) == 0x33007AFF
                        && MobileTheme.withAlpha(0xFF007AFF, -5) == 0x00007AFF
                        && MobileTheme.withAlpha(0xFF007AFF, 999) == 0xFF007AFF,
                "Pillar 1: MobileTheme.withAlpha clamps alpha byte cleanly");
        check(
                MobileTheme.computeAccentOnFill(0xFFF59E0B) == 0xFF11141A
                        && MobileTheme.computeAccentOnFill(0xFF007AFF) == 0xFFFFFFFF,
                "Pillar 1: MobileTheme.computeAccentOnFill maintains high text contrast");

        // Prefs.THEME_MODE sanitization & Prefs.KEYS invariant
        check(
                Integer.valueOf(0).equals(Prefs.sanitizeMobileSetting(Prefs.THEME_MODE, 0))
                        && Integer.valueOf(1)
                                .equals(Prefs.sanitizeMobileSetting(Prefs.THEME_MODE, 1))
                        && Integer.valueOf(2)
                                .equals(Prefs.sanitizeMobileSetting(Prefs.THEME_MODE, 2)),
                "Pillar 1: Prefs.sanitizeMobileSetting accepts THEME_MODE 0, 1, 2");
        check(
                Prefs.sanitizeMobileSetting(Prefs.THEME_MODE, -1) == null
                        && Prefs.sanitizeMobileSetting(Prefs.THEME_MODE, 3) == null
                        && Prefs.sanitizeMobileSetting(Prefs.THEME_MODE, "0") == null
                        && Prefs.sanitizeMobileSetting(Prefs.THEME_MODE, Boolean.TRUE) == null
                        && Prefs.sanitizeMobileSetting(Prefs.THEME_MODE, null) == null,
                "Pillar 1: Prefs.sanitizeMobileSetting rejects -1, 3, \"0\", boolean, null for THEME_MODE");
        check(
                Prefs.KEYS.length == 46
                        && Arrays.asList(Prefs.MOBILE_KEYS).contains(Prefs.THEME_MODE),
                "Pillar 1: Prefs.KEYS remains strictly length 46 and THEME_MODE lives in MOBILE_KEYS");

        // Static contracts: MobileTheme, styles.xml, AndroidManifest.xml
        String themeSrc =
                readUtf8(
                        root,
                        "android-mobile/src/main/java/com/pilipala/marcomovie/MobileTheme.java");
        check(
                !themeSrc.toLowerCase(java.util.Locale.ROOT).contains("0b1311"),
                "Pillar 1 static: MobileTheme.java contains zero #0b1311 swamp green");

        String stylesXml = readUtf8(root, "android-mobile/src/main/res/values/styles.xml");
        check(
                !stylesXml.contains("android:windowFullscreen")
                        && stylesXml.contains("#0A0B0E")
                        && stylesXml.contains("#007AFF"),
                "Pillar 1 static: styles.xml removes windowFullscreen=true and sets #0A0B0E/#007AFF");

        String manifestXml = readUtf8(root, "android-mobile/src/main/AndroidManifest.xml");
        int activityIdx = manifestXml.indexOf("android:name=\".MainActivity\"");
        int activityEnd = activityIdx >= 0 ? manifestXml.indexOf('>', activityIdx) : -1;
        String activityTag =
                activityIdx >= 0 && activityEnd > activityIdx
                        ? manifestXml.substring(activityIdx, activityEnd)
                        : "";
        check(
                activityTag.contains("android:configChanges=") && activityTag.contains("uiMode"),
                "Pillar 1 static: AndroidManifest.xml MainActivity configChanges includes uiMode");
    }

    private static void test2_MobileBottomSheetAndAntiHijack(Path root) throws Exception {
        check(
                "mobile-drawer".equals(MobileBottomSheet.DRAWER_TAG),
                "Pillar 2: MobileBottomSheet.DRAWER_TAG equals \"mobile-drawer\"");
        check(
                PluginDialogStyler.isExemptTagForTest("mobile-drawer")
                        && PluginDialogStyler.isExemptTagForTest(MobileBottomSheet.DRAWER_TAG),
                "Pillar 2: PluginDialogStyler exempts \"mobile-drawer\" tag");
        check(
                !PluginDialogStyler.isExemptTagForTest("random-plugin")
                        && !PluginDialogStyler.isExemptTagForTest("")
                        && !PluginDialogStyler.isExemptTagForTest(null),
                "Pillar 2: PluginDialogStyler does not exempt unknown or null plugin tags");

        check(
                MobileBottomSheet.computeMaxSheetHeightPx(2400) == 1824
                        && MobileBottomSheet.computeMaxSheetHeightPx(1000) == 760
                        && MobileBottomSheet.computeMaxSheetHeightPx(0) == 0
                        && MobileBottomSheet.computeMaxSheetHeightPx(-200) == 0,
                "Pillar 2: MobileBottomSheet.computeMaxSheetHeightPx enforces 76% cap (2400 -> 1824)");

        String sheetSrc =
                readUtf8(
                        root,
                        "android-mobile/src/main/java/com/pilipala/marcomovie/MobileBottomSheet.java");
        check(
                sheetSrc.contains("decor.setTag(DRAWER_TAG);")
                        && sheetSrc.contains("backdrop.setTag(DRAWER_TAG);")
                        && sheetSrc.contains("sheet.setTag(DRAWER_TAG);"),
                "Pillar 2 static: MobileBottomSheet tags decorView, backdrop, and sheet with DRAWER_TAG");

        String widgetsSrc =
                readUtf8(
                        root,
                        "android-mobile/src/main/java/com/pilipala/marcomovie/UiWidgets.java");
        int pickerIdx = widgetsSrc.indexOf("static void showDrawerPicker(");
        String pickerBody =
                pickerIdx >= 0
                        ? widgetsSrc.substring(
                                pickerIdx, Math.min(widgetsSrc.length(), pickerIdx + 900))
                        : "";
        check(
                pickerBody.contains("MobileBottomSheet.showPicker("),
                "Pillar 2 static: UiWidgets.showDrawerPicker delegates mobile pickers to MobileBottomSheet.showPicker");
    }

    private static void test3_MobileFilterSheet(Path root) throws Exception {
        VideoFilters.Definition classDef =
                new VideoFilters.Definition("class", "class", "类型", true);
        classDef.choices.add(new VideoFilters.Choice("科幻", "sci-fi"));
        classDef.choices.add(new VideoFilters.Choice("动作", "action"));

        VideoFilters.Definition areaDef =
                new VideoFilters.Definition("area", "area", "国家 / 地区", true);
        areaDef.choices.add(new VideoFilters.Choice("中国大陆", "cn"));
        areaDef.choices.add(new VideoFilters.Choice("美国", "us"));

        VideoFilters.Definition yearDef = new VideoFilters.Definition("year", "year", "年份", true);
        yearDef.choices.add(new VideoFilters.Choice("2025", "2025"));

        VideoFilters.Definition sortDef = new VideoFilters.Definition("by", "by", "排序", true);
        sortDef.choices.add(new VideoFilters.Choice("按人气", "hits"));

        List<VideoFilters.Definition> defs = Arrays.asList(classDef, areaDef, yearDef, sortDef);
        Map<String, String> selections = new LinkedHashMap<>();

        check(
                MobileFilterSheet.countActiveSelections(defs, selections) == 0
                        && MobileFilterSheet.countActiveSelections(defs, null) == 0,
                "Pillar 3: countActiveSelections returns 0 for empty/null selections");

        check(
                MobileFilterSheet.applySelection(selections, "class", "sci-fi")
                        && "sci-fi".equals(selections.get("class"))
                        && MobileFilterSheet.countActiveSelections(defs, selections) == 1,
                "Pillar 3: applySelection adds new selection and increments count");

        check(
                !MobileFilterSheet.applySelection(selections, "class", "sci-fi"),
                "Pillar 3: applySelection returns false when selecting identical value");

        check(
                MobileFilterSheet.applySelection(selections, "class", "action")
                        && "action".equals(selections.get("class"))
                        && MobileFilterSheet.countActiveSelections(defs, selections) == 1,
                "Pillar 3: applySelection switches value in place");

        check(
                MobileFilterSheet.applySelection(selections, "class", "")
                        && !selections.containsKey("class")
                        && !MobileFilterSheet.applySelection(selections, "class", ""),
                "Pillar 3: applySelection with empty string removes key and is idempotent");

        check(
                !MobileFilterSheet.applySelection(null, "class", "action")
                        && !MobileFilterSheet.applySelection(selections, " ", "action"),
                "Pillar 3: applySelection ignores null map and blank dimension");

        // Multi-dimension count & subtitle formatting
        String idleRemoteSub = MobileFilterSheet.formatSubtitle(defs, selections);
        check(
                "点击下方胶囊即时筛选".equals(idleRemoteSub),
                "Pillar 3: formatSubtitle shows remote idle hint when 0 selections active");

        VideoFilters.Definition localOnly =
                new VideoFilters.Definition("year", "year", "年份", false);
        String idleLocalSub =
                MobileFilterSheet.formatSubtitle(Collections.singletonList(localOnly), selections);
        check(
                idleLocalSub.contains("按已加载影片资料筛选"),
                "Pillar 3: formatSubtitle shows local fallback hint for non-remote definitions");

        MobileFilterSheet.applySelection(selections, "class", "sci-fi");
        MobileFilterSheet.applySelection(selections, "area", "cn");
        String twoSub = MobileFilterSheet.formatSubtitle(defs, selections);
        check(
                "已选 2 项：科幻 · 中国大陆".equals(twoSub),
                "Pillar 3: formatSubtitle summarizes 2 active selections with choice labels");

        MobileFilterSheet.applySelection(selections, "year", "2025");
        MobileFilterSheet.applySelection(selections, "by", "hits");
        String fourSub = MobileFilterSheet.formatSubtitle(defs, selections);
        check(
                MobileFilterSheet.countActiveSelections(defs, selections) == 4
                        && fourSub.startsWith("已选 4 项：科幻 · 中国大陆 · 2025")
                        && fourSub.endsWith(" 等"),
                "Pillar 3: formatSubtitle truncates >3 active selections with trailing 等");

        // Reset selections
        check(
                MobileFilterSheet.resetSelections(selections)
                        && selections.isEmpty()
                        && !MobileFilterSheet.resetSelections(selections)
                        && !MobileFilterSheet.resetSelections(null),
                "Pillar 3: resetSelections clears map once and returns false when already empty");

        // Short dimension labels
        VideoFilters.Definition longClassDef =
                new VideoFilters.Definition("class", "class", "影视分类", true);
        check(
                "地区".equals(MobileFilterSheet.shortDimensionLabel(areaDef))
                        && "类型".equals(MobileFilterSheet.shortDimensionLabel(classDef))
                        && "类型".equals(MobileFilterSheet.shortDimensionLabel(longClassDef))
                        && "年份".equals(MobileFilterSheet.shortDimensionLabel(yearDef))
                        && "筛选".equals(MobileFilterSheet.shortDimensionLabel(null)),
                "Pillar 3: shortDimensionLabel produces compact row labels");

        // Static delegation check in VideoFilterDialog
        String filterDlgSrc =
                readUtf8(
                        root,
                        "android-mobile/src/main/java/com/pilipala/marcomovie/VideoFilterDialog.java");
        check(
                filterDlgSrc.contains("if (!a.isTvDevice())")
                        && filterDlgSrc.contains("MobileFilterSheet.show("),
                "Pillar 3 static: VideoFilterDialog delegates mobile !a.isTvDevice() to MobileFilterSheet.show(");
    }

    private static boolean hasHit(
            List<MobileSettingsIndex.Entry> hits, int expectedSubPage, String expectedKey) {
        for (MobileSettingsIndex.Entry e : hits) {
            if (e.subPage == expectedSubPage
                    && (expectedKey == null || expectedKey.equals(e.key))) {
                return true;
            }
        }
        return false;
    }

    private static void test4_SettingsCenterAndIconHygiene(Path root) throws Exception {
        Set<Integer> subPages = new HashSet<>();
        for (MobileSettingsIndex.Entry e : MobileSettingsIndex.all()) {
            subPages.add(e.subPage);
        }
        check(
                subPages.size() == 7
                        && subPages.contains(MobileSettingsIndex.SUB_SOURCES)
                        && subPages.contains(MobileSettingsIndex.SUB_APPEARANCE)
                        && subPages.contains(MobileSettingsIndex.SUB_PLAYBACK)
                        && subPages.contains(MobileSettingsIndex.SUB_SUBTITLE)
                        && subPages.contains(MobileSettingsIndex.SUB_SERVICES)
                        && subPages.contains(MobileSettingsIndex.SUB_SYNC)
                        && subPages.contains(MobileSettingsIndex.SUB_STORAGE),
                "Pillar 4: MobileSettingsIndex covers all 7 settings sub-pages");

        check(
                MobileSettingsIndex.search(null).isEmpty()
                        && MobileSettingsIndex.search("").isEmpty()
                        && MobileSettingsIndex.search("   ").isEmpty(),
                "Pillar 4: MobileSettingsIndex.search returns empty for null/blank query");

        check(
                hasHit(
                        MobileSettingsIndex.search("深色"),
                        MobileSettingsIndex.SUB_APPEARANCE,
                        "ms-theme-mode"),
                "Pillar 4: MobileSettingsIndex.search(\"深色\") matches theme mode");
        check(
                hasHit(
                        MobileSettingsIndex.search("浅色"),
                        MobileSettingsIndex.SUB_APPEARANCE,
                        "ms-theme-mode"),
                "Pillar 4: MobileSettingsIndex.search(\"浅色\") matches theme mode");
        check(
                hasHit(
                        MobileSettingsIndex.search("跟随系统"),
                        MobileSettingsIndex.SUB_APPEARANCE,
                        "ms-theme-mode"),
                "Pillar 4: MobileSettingsIndex.search(\"跟随系统\") matches theme mode");
        check(
                hasHit(
                        MobileSettingsIndex.search("强调色"),
                        MobileSettingsIndex.SUB_APPEARANCE,
                        "ms-accent"),
                "Pillar 4: MobileSettingsIndex.search(\"强调色\") matches accent preset");
        check(
                hasHit(
                        MobileSettingsIndex.search("MPV"),
                        MobileSettingsIndex.SUB_PLAYBACK,
                        "ms-player-engine"),
                "Pillar 4: MobileSettingsIndex.search(\"MPV\") matches player engine (case-insensitive)");
        check(
                hasHit(
                        MobileSettingsIndex.search("字幕"),
                        MobileSettingsIndex.SUB_SUBTITLE,
                        "ms-sub-adjust"),
                "Pillar 4: MobileSettingsIndex.search(\"字幕\") matches subtitle sub-page");
        check(
                hasHit(
                        MobileSettingsIndex.search("弹幕"),
                        MobileSettingsIndex.SUB_SUBTITLE,
                        "ms-danmaku-def"),
                "Pillar 4: MobileSettingsIndex.search(\"弹幕\") matches danmaku sub-page");
        check(
                hasHit(
                        MobileSettingsIndex.search("WebDAV"),
                        MobileSettingsIndex.SUB_SYNC,
                        "ms-cloud-sync"),
                "Pillar 4: MobileSettingsIndex.search(\"WebDAV\") matches cloud sync sub-page");
        check(
                hasHit(
                        MobileSettingsIndex.search("新手引导"),
                        MobileSettingsIndex.SUB_STORAGE,
                        "ms-replay-onboarding"),
                "Pillar 4: MobileSettingsIndex.search(\"新手引导\") matches replay onboarding in storage sub-page");
        check(
                hasHit(
                        MobileSettingsIndex.search("片源"),
                        MobileSettingsIndex.SUB_SOURCES,
                        "ms-switch-site"),
                "Pillar 4: MobileSettingsIndex.search(\"片源\") matches sources sub-page");

        // Static icon/emoji hygiene
        String settingsSrc =
                readUtf8(
                        root,
                        "android-mobile/src/main/java/com/pilipala/marcomovie/MobileSettingsScreen.java");
        String searchSrc =
                readUtf8(
                        root,
                        "android-mobile/src/main/java/com/pilipala/marcomovie/MobileSearchPage.java");
        String librarySrc =
                readUtf8(
                        root,
                        "android-mobile/src/main/java/com/pilipala/marcomovie/MobileLibraryPage.java");
        String shellSrc =
                readUtf8(
                        root,
                        "android-mobile/src/main/java/com/pilipala/marcomovie/MobileRootShell.java");

        check(
                !settingsSrc.contains("\uD83D\uDD0D") && !searchSrc.contains("\uD83D\uDD0D"),
                "Pillar 4 static: zero 🔍 emoji in MobileSettingsScreen.java & MobileSearchPage.java");
        check(
                !librarySrc.contains("\u2601"),
                "Pillar 4 static: zero ☁ emoji in MobileLibraryPage.java");
        check(
                !shellSrc.contains("\u2630"),
                "Pillar 4 static: zero ☰ symbol in MobileRootShell.java");
    }

    private static void test5_PlayerTouchHud(Path root) throws Exception {
        int fullMask =
                Prefs.HUD_CLOCK
                        | Prefs.HUD_BATTERY
                        | Prefs.HUD_NET_SPEED
                        | Prefs.HUD_RESOLUTION
                        | Prefs.HUD_FPS;

        // Idle corner HUD visibility (zero overlap with expanded Top Bar / lock screen)
        check(
                !MobilePlayerOverlay.shouldShowIdleCornerHud(true, fullMask, false),
                "Pillar 5: shouldShowIdleCornerHud is false when controlsVisible=true (zero Top Bar overlap)");
        check(
                !MobilePlayerOverlay.shouldShowIdleCornerHud(false, fullMask, true),
                "Pillar 5: shouldShowIdleCornerHud is false when locked=true");
        check(
                !MobilePlayerOverlay.shouldShowIdleCornerHud(false, 0, false),
                "Pillar 5: shouldShowIdleCornerHud is false when cornerMask=0");
        check(
                !MobilePlayerOverlay.shouldShowIdleCornerHud(false, Prefs.HUD_FPS, false),
                "Pillar 5: shouldShowIdleCornerHud ignores legacy synthetic HUD_FPS-only bit");
        check(
                MobilePlayerOverlay.shouldShowIdleCornerHud(false, fullMask, false)
                        && MobilePlayerOverlay.shouldShowIdleCornerHud(
                                false, Prefs.HUD_CLOCK, false),
                "Pillar 5: shouldShowIdleCornerHud is true when hidden, unlocked, and real telemetry bit set");

        // Telemetry status line formatting (zero fake 60fps or ⚡)
        String fullLine =
                MobilePlayerOverlay.formatCornerStatusLine(
                        fullMask, "2.4 MB/s", "1080P", 85, "21:30");
        check(
                "2.4 MB/s · 1080P · 85% · 21:30".equals(fullLine)
                        && !fullLine.contains("60fps")
                        && !fullLine.contains("\u26A1"),
                "Pillar 5: formatCornerStatusLine emits real telemetry without fake 60fps or ⚡");

        String filteredLine =
                MobilePlayerOverlay.formatCornerStatusLine(fullMask, "", "未知", 120, "08:05");
        check(
                "100% · 08:05".equals(filteredLine),
                "Pillar 5: formatCornerStatusLine skips blank/unknown fields and clamps battery to 100%");

        check(
                ""
                        .equals(
                                MobilePlayerOverlay.formatCornerStatusLine(
                                        Prefs.HUD_FPS, "1.0 MB/s", "4K", 90, "12:00")),
                "Pillar 5: formatCornerStatusLine emits empty string for HUD_FPS-only mask");

        // Net speed formatting across sub-KB, KB/s, MB/s, negative bounds
        check(
                "0 KB/s".equals(MobilePlayerOverlay.formatNetSpeed(-500L))
                        && "0 KB/s".equals(MobilePlayerOverlay.formatNetSpeed(0L))
                        && "0 KB/s".equals(MobilePlayerOverlay.formatNetSpeed(512L))
                        && "1 KB/s".equals(MobilePlayerOverlay.formatNetSpeed(1024L))
                        && "512 KB/s".equals(MobilePlayerOverlay.formatNetSpeed(512L * 1024L))
                        && "1.0 MB/s".equals(MobilePlayerOverlay.formatNetSpeed(1024L * 1024L))
                        && "2.5 MB/s".equals(MobilePlayerOverlay.formatNetSpeed(2621440L)),
                "Pillar 5: formatNetSpeed formats negative/sub-KB/KB/MB throughput accurately");

        // PlayerChrome mobile helpers
        check(
                PlayerChrome.shouldUseHorizontalMobileDock(false)
                        && !PlayerChrome.shouldUseHorizontalMobileDock(true),
                "Pillar 5: PlayerChrome.shouldUseHorizontalMobileDock is true for mobile and false for TV");
        check(
                PlayerChrome.shouldRenderMobileGradientScrims(false)
                        && !PlayerChrome.shouldRenderMobileGradientScrims(true),
                "Pillar 5: PlayerChrome.shouldRenderMobileGradientScrims is true for mobile and false for TV");
        check(
                "星际穿越".equals(PlayerChrome.formatMobileHeaderTitle("星际穿越", "正片", false))
                        && "星际穿越".equals(PlayerChrome.formatMobileHeaderTitle("星际穿越", "HD", false))
                        && "三体".equals(PlayerChrome.formatMobileHeaderTitle("三体", "三体", true))
                        && "三体".equals(PlayerChrome.formatMobileHeaderTitle("三体", "", false)),
                "Pillar 5: PlayerChrome.formatMobileHeaderTitle strips redundant generic single-episode labels");
        String multiTitle = PlayerChrome.formatMobileHeaderTitle("三体", "第01集", true);
        check(
                multiTitle.startsWith("三体 · ") && multiTitle.contains("1"),
                "Pillar 5: PlayerChrome.formatMobileHeaderTitle combines title and cleaned episode label");

        // PlaybackControls horizontal deck order
        List<String> vodOrder =
                PlaybackControls.resolveMobileHighFrequencyOrder(
                        Prefs.DEFAULT_PLAYER_BUTTON_ORDER, false);
        check(
                Arrays.asList("episodes", "lines", "speed", "subtitles", "decoder")
                        .equals(vodOrder),
                "Pillar 5: resolveMobileHighFrequencyOrder returns clean 5-pill VOD horizontal deck");

        List<String> liveOrder =
                PlaybackControls.resolveMobileHighFrequencyOrder(
                        Prefs.DEFAULT_PLAYER_BUTTON_ORDER, true);
        check(
                Arrays.asList("episodes", "lines", "decoder").equals(liveOrder),
                "Pillar 5: resolveMobileHighFrequencyOrder returns clean 3-pill Live horizontal deck");

        List<String> customOrder =
                PlaybackControls.resolveMobileHighFrequencyOrder(
                        "decoder,speed,online-sub,ai-sub,more,episodes", false);
        check(
                Arrays.asList("decoder", "speed", "episodes", "lines", "subtitles")
                        .equals(customOrder),
                "Pillar 5: resolveMobileHighFrequencyOrder honors user order and filters legacy right-strip overflow");

        // Static hygiene for player HUD files
        String overlaySrc =
                readUtf8(
                        root,
                        "android-mobile/src/main/java/com/pilipala/marcomovie/MobilePlayerOverlay.java");
        String chromeSrc =
                readUtf8(
                        root,
                        "android-mobile/src/main/java/com/pilipala/marcomovie/PlayerChrome.java");
        String inlineSrc =
                readUtf8(
                        root,
                        "android-mobile/src/main/java/com/pilipala/marcomovie/MobileInlinePlayer.java");

        check(
                !overlaySrc.contains("60fps")
                        && !overlaySrc.contains("\u26A1")
                        && !chromeSrc.contains("60fps")
                        && !chromeSrc.contains("\u26A1"),
                "Pillar 5 static: zero \"60fps\" and zero ⚡ in MobilePlayerOverlay.java & PlayerChrome.java");
        check(
                inlineSrc.contains("MobileIcons.")
                        && inlineSrc.contains("MobileTheme.of(")
                        && inlineSrc.contains("palette.accent")
                        && !inlineSrc.contains("60fps")
                        && !inlineSrc.contains("\u26A1"),
                "Pillar 5 static: MobileInlinePlayer uses MobileIcons/MobileTheme accent with clean telemetry");
    }

    private static double lumaOf(int argb) {
        int r = (argb >> 16) & 0xFF;
        int g = (argb >> 8) & 0xFF;
        int b = argb & 0xFF;
        return 0.299 * r + 0.587 * g + 0.114 * b;
    }

    private static void test6_MobileMotionPhysicsAndBenchmark() {
        // 1. Reduced-motion policy (app toggle OR system animator duration scale <= 0)
        check(
                MobileMotion.shouldReduceMotion(false, 0f)
                        && MobileMotion.shouldReduceMotion(false, -1f)
                        && MobileMotion.shouldReduceMotion(true, 1f)
                        && MobileMotion.shouldReduceMotion(true, 0f)
                        && !MobileMotion.shouldReduceMotion(false, 1f)
                        && !MobileMotion.shouldReduceMotion(false, 0.5f)
                        && !MobileMotion.shouldReduceMotion(false, Float.NaN),
                "Pillar 6: MobileMotion.shouldReduceMotion honors both app flag and system animator scale");

        // 2. Rubber-band overscroll resistance curve: monotonic, symmetric, strictly bounded
        float maxExt = 300f;
        float rb20 = MobileMotion.rubberBand(20f, maxExt);
        float rb100 = MobileMotion.rubberBand(100f, maxExt);
        float rb500 = MobileMotion.rubberBand(500f, maxExt);
        float rb2000 = MobileMotion.rubberBand(2000f, maxExt);
        float rb10000 = MobileMotion.rubberBand(10000f, maxExt);
        float rbHuge = MobileMotion.rubberBand(10_000_000f, maxExt);
        check(
                MobileMotion.rubberBand(0f, maxExt) == 0f
                        && MobileMotion.rubberBand(100f, 0f) == 0f
                        && MobileMotion.rubberBand(Float.NaN, maxExt) == 0f,
                "Pillar 6: MobileMotion.rubberBand returns 0 for zero/invalid inputs");
        check(
                0f < rb20
                        && rb20 < rb100
                        && rb100 < rb500
                        && rb500 < rb2000
                        && rb2000 < rb10000
                        && rb10000 < maxExt
                        && rbHuge < maxExt,
                "Pillar 6: MobileMotion.rubberBand is strictly monotonic and bounded < maxExtentPx even at 10000px+");
        check(
                Math.abs(
                                MobileMotion.rubberBand(-150f, maxExt)
                                        + MobileMotion.rubberBand(150f, maxExt))
                        < 1e-4f,
                "Pillar 6: MobileMotion.rubberBand is odd-symmetric for negative offsets");

        // 3. Sheet drag-to-dismiss release policy
        check(
                !MobileMotion.shouldDismissSheetOnRelease(0f, 2000f, 600f, 0.28f, 900f)
                        && !MobileMotion.shouldDismissSheetOnRelease(-20f, 2000f, 600f, 0.28f, 900f)
                        && !MobileMotion.shouldDismissSheetOnRelease(
                                Float.NaN, 2000f, 600f, 0.28f, 900f),
                "Pillar 6: shouldDismissSheetOnRelease never dismisses on zero/negative/NaN drag");
        check(
                MobileMotion.shouldDismissSheetOnRelease(168f, 0f, 600f, 0.28f, 900f)
                        && !MobileMotion.shouldDismissSheetOnRelease(160f, 0f, 600f, 0.28f, 900f),
                "Pillar 6: shouldDismissSheetOnRelease enforces distance fraction threshold");
        check(
                MobileMotion.shouldDismissSheetOnRelease(24f, 900f, 600f, 0.28f, 900f)
                        && !MobileMotion.shouldDismissSheetOnRelease(24f, 899f, 600f, 0.28f, 900f)
                        && MobileMotion.shouldDismissSheetOnRelease(10f, 950f, 0f, 0.28f, 900f)
                        && !MobileMotion.shouldDismissSheetOnRelease(10f, 100f, 0f, 0.28f, 900f),
                "Pillar 6: shouldDismissSheetOnRelease enforces fling velocity threshold and boundary conditions");

        // 4. Finite spring settle steps at 60Hz and 120Hz (< 0.55s)
        MotionTokens.SpringPreset[] presets = {
            MotionTokens.SPRING_PRESS_FEEDBACK,
            MotionTokens.SPRING_HUD_POPUP,
            MotionTokens.SPRING_PLAYER_TRANSITION
        };
        String[] presetNames = {
            "SPRING_PRESS_FEEDBACK", "SPRING_HUD_POPUP", "SPRING_PLAYER_TRANSITION"
        };
        float dt60 = 1f / 60f;
        float dt120 = 1f / 120f;
        for (int i = 0; i < presets.length; i++) {
            int steps60 = MobileMotion.measureSpringSettleSteps(presets[i], dt60, 0.002f);
            int steps120 = MobileMotion.measureSpringSettleSteps(presets[i], dt120, 0.002f);
            float sec60 = steps60 * dt60;
            float sec120 = steps120 * dt120;
            System.out.printf(
                    Locale.US,
                    "BENCHMARK Settle %-24s: 60Hz=%2d steps (%.3fs), 120Hz=%2d steps (%.3fs)%n",
                    presetNames[i],
                    steps60,
                    sec60,
                    steps120,
                    sec120);
            check(
                    steps60 > 0
                            && steps60 < 600
                            && sec60 < 0.55f
                            && steps120 > 0
                            && steps120 < 600
                            && sec120 < 0.55f,
                    "Pillar 6: "
                            + presetNames[i]
                            + " settles cleanly < 0.55s at both 60Hz and 120Hz");
        }

        // 5. Pure-JVM 100,000-step spring microbenchmark (120fps frame budget check)
        MotionTokens.SpringState benchUnder = new MotionTokens.SpringState(0f, 0f);
        MotionSpring benchCrit =
                new MotionSpring(
                        0f, MotionTokens.SPRING_PRESS_FEEDBACK.motionSpringFrequency, 0.001f);
        double sink = 0.0;
        // JIT warmup
        for (int i = 0; i < 20_000; i++) {
            float tgt = (i & 1) == 0 ? 1f : 0f;
            MotionTokens.stepUnderdampedSpring(
                    benchUnder, tgt, MotionTokens.SPRING_HUD_POPUP, dt120, 0.001f);
            benchCrit.target(tgt);
            benchCrit.step(dt120);
            sink += benchUnder.value + benchCrit.value;
        }

        final int iterations = 100_000;
        benchUnder.value = 0f;
        benchUnder.velocity = 0f;
        long t0 = System.nanoTime();
        for (int i = 0; i < iterations; i++) {
            float tgt = (i & 31) == 0 ? ((i & 32) == 0 ? 1f : 0f) : 1f;
            MotionTokens.stepUnderdampedSpring(
                    benchUnder, tgt, MotionTokens.SPRING_HUD_POPUP, dt120, 0.001f);
            sink += benchUnder.value;
        }
        long elapsedUnderNs = System.nanoTime() - t0;

        benchCrit.snap(0f);
        long t1 = System.nanoTime();
        for (int i = 0; i < iterations; i++) {
            float tgt = (i & 31) == 0 ? ((i & 32) == 0 ? 1f : 0f) : 1f;
            benchCrit.target(tgt);
            benchCrit.step(dt120);
            sink += benchCrit.value;
        }
        long elapsedCritNs = System.nanoTime() - t1;

        double underNsPerStep = elapsedUnderNs / (double) iterations;
        double critNsPerStep = elapsedCritNs / (double) iterations;
        double worstNsPerStep = Math.max(underNsPerStep, critNsPerStep);
        double frame20SpringsMs = (worstNsPerStep * 20.0) / 1_000_000.0;
        double budgetPct = (frame20SpringsMs / 8.3333) * 100.0;
        System.out.printf(
                Locale.US,
                "BENCHMARK SpringStep (100k steps): underdamped=%.1f ns/step, critical=%.1f ns/step, 20-spring 120fps frame=%.5f ms (%.3f%% of 8.33ms, sink=%.1f)%n",
                underNsPerStep,
                critNsPerStep,
                frame20SpringsMs,
                budgetPct,
                sink);
        check(
                frame20SpringsMs < 0.05,
                "Pillar 6 benchmark: 20 simultaneous springs stay strictly < 0.05ms per 120fps frame");

        // 6. MotionSpring interruptible mid-flight retarget continuity
        MotionSpring spring =
                new MotionSpring(
                        0f, MotionTokens.SPRING_PRESS_FEEDBACK.motionSpringFrequency, 0.002f);
        spring.target(100f);
        for (int i = 0; i < 6; i++) {
            spring.step(dt120);
        }
        float posBefore = spring.value;
        float velBefore = spring.velocity;
        check(
                posBefore > 5f && posBefore < 95f && velBefore > 0f,
                "Pillar 6: MotionSpring advances smoothly mid-flight with positive velocity");
        spring.target(0f);
        check(
                spring.value == posBefore && spring.velocity == velBefore,
                "Pillar 6: MotionSpring.target() mid-flight preserves exact position and velocity");
        spring.step(dt120);
        float posAfterOneStep = spring.value;
        float velAfterOneStep = spring.velocity;
        check(
                Math.abs(posAfterOneStep - posBefore) < 25f && velAfterOneStep < velBefore,
                "Pillar 6: MotionSpring reverses smoothly without positional teleportation");
        int settleCount = 0;
        while (spring.step(dt120) && settleCount < 300) {
            settleCount++;
        }
        check(
                spring.value == 0f && spring.velocity == 0f && settleCount < 300,
                "Pillar 6: MotionSpring converges cleanly to reversed target 0 with zero residual velocity");
    }

    private static void test7_UxFirstPrinciplesStateLogic() {
        // 1. MobileFilterSheet.toggleSelection vs applySelection & formatResetLabel
        Map<String, String> filterMap = new LinkedHashMap<>();
        check(
                MobileFilterSheet.toggleSelection(filterMap, "class", "sci-fi")
                        && "sci-fi".equals(filterMap.get("class")),
                "Pillar 7: MobileFilterSheet.toggleSelection selects new filter on first tap");
        check(
                MobileFilterSheet.toggleSelection(filterMap, "class", "sci-fi")
                        && !filterMap.containsKey("class"),
                "Pillar 7: MobileFilterSheet.toggleSelection deselects active choice on second tap");
        check(
                MobileFilterSheet.applySelection(filterMap, "class", "sci-fi")
                        && !MobileFilterSheet.applySelection(filterMap, "class", "sci-fi")
                        && "sci-fi".equals(filterMap.get("class")),
                "Pillar 7: MobileFilterSheet.applySelection still returns false on identical value");
        check(
                "".equals(MobileFilterSheet.formatResetLabel(0))
                        && "".equals(MobileFilterSheet.formatResetLabel(-2))
                        && "重置 (3)".equals(MobileFilterSheet.formatResetLabel(3)),
                "Pillar 7: MobileFilterSheet.formatResetLabel hides label at 0 and formats count > 0");

        // 2. MobileSearchPage.toggleSiteFilter
        check(
                "siteA".equals(MobileSearchPage.toggleSiteFilter("", "siteA"))
                        && "".equals(MobileSearchPage.toggleSiteFilter("siteA", "siteA"))
                        && "siteB".equals(MobileSearchPage.toggleSiteFilter("siteA", "siteB"))
                        && "".equals(MobileSearchPage.toggleSiteFilter("siteA", ""))
                        && "".equals(MobileSearchPage.toggleSiteFilter(null, null)),
                "Pillar 7: MobileSearchPage.toggleSiteFilter deselects active site on second tap");

        // 3. MobileDetailScreen.shouldShowMultiEpisodeTools
        check(
                !MobileDetailScreen.shouldShowMultiEpisodeTools(0)
                        && !MobileDetailScreen.shouldShowMultiEpisodeTools(1)
                        && !MobileDetailScreen.shouldShowMultiEpisodeTools(-1)
                        && MobileDetailScreen.shouldShowMultiEpisodeTools(2)
                        && MobileDetailScreen.shouldShowMultiEpisodeTools(36),
                "Pillar 7: MobileDetailScreen.shouldShowMultiEpisodeTools hides multi-ep chrome for <=1 ep");

        // 4. PlaybackControls.shouldShowEpisodeSteppers
        check(
                !PlaybackControls.shouldShowEpisodeSteppers(false, 0)
                        && !PlaybackControls.shouldShowEpisodeSteppers(false, 1)
                        && PlaybackControls.shouldShowEpisodeSteppers(false, 2)
                        && PlaybackControls.shouldShowEpisodeSteppers(true, 1)
                        && PlaybackControls.shouldShowEpisodeSteppers(true, 0),
                "Pillar 7: PlaybackControls.shouldShowEpisodeSteppers hides steppers on 1-ep VOD, keeps on multi-ep & live");

        // 5. MobileHomePage.resolvePosterColumns across phone / narrow / tablet & density 0/1/2
        check(
                MobileHomePage.resolvePosterColumns(360f, true, 0) == 4
                        && MobileHomePage.resolvePosterColumns(360f, true, 1) == 3
                        && MobileHomePage.resolvePosterColumns(360f, true, 2) == 2,
                "Pillar 7: MobileHomePage.resolvePosterColumns maps 360dp phone density 0/1/2 -> 4/3/2");
        check(
                MobileHomePage.resolvePosterColumns(280f, true, 0) == 3
                        && MobileHomePage.resolvePosterColumns(280f, true, 1) == 3
                        && MobileHomePage.resolvePosterColumns(280f, true, 2) == 2,
                "Pillar 7: MobileHomePage.resolvePosterColumns clamps narrow 280dp screen safely");
        check(
                MobileHomePage.resolvePosterColumns(720f, true, 0) == 6
                        && MobileHomePage.resolvePosterColumns(720f, true, 1) == 5
                        && MobileHomePage.resolvePosterColumns(720f, true, 2) == 4
                        && MobileHomePage.resolvePosterColumns(640f, false, 0) == 6
                        && MobileHomePage.resolvePosterColumns(640f, false, 1) == 5
                        && MobileHomePage.resolvePosterColumns(640f, false, 2) == 4,
                "Pillar 7: MobileHomePage.resolvePosterColumns maps tablet & landscape density 0/1/2 -> 6/5/4");

        // 6. MobileSettingsScreen.computeTransitionDirection & shouldAutoExpandAdvanced
        check(
                MobileSettingsScreen.computeTransitionDirection(0, 2) == 2
                        && MobileSettingsScreen.computeTransitionDirection(2, 0) == -2
                        && MobileSettingsScreen.computeTransitionDirection(2, 2) == 0
                        && MobileSettingsScreen.computeTransitionDirection(1, 5) == 2
                        && MobileSettingsScreen.computeTransitionDirection(5, 1) == -2,
                "Pillar 7: MobileSettingsScreen.computeTransitionDirection returns +2/-2/0 accurately");
        check(
                !MobileSettingsScreen.shouldAutoExpandAdvanced(false, false, null, "k1", "k2")
                        && MobileSettingsScreen.shouldAutoExpandAdvanced(true, false, null, "k1")
                        && MobileSettingsScreen.shouldAutoExpandAdvanced(false, true, null, "k1")
                        && MobileSettingsScreen.shouldAutoExpandAdvanced(
                                false, false, "k2", "k1", "k2")
                        && !MobileSettingsScreen.shouldAutoExpandAdvanced(
                                false, false, "other", "k1", "k2"),
                "Pillar 7: MobileSettingsScreen.shouldAutoExpandAdvanced honors user toggle, non-default, and search highlight");

        // 7. UiWidgets.classifyImportCandidate
        check(
                "网址配置".equals(UiWidgets.classifyImportCandidate("https://example.test/config.json"))
                        && "直播源链接"
                                .equals(
                                        UiWidgets.classifyImportCandidate(
                                                "https://example.test/tv.m3u8"))
                        && "压缩配置包"
                                .equals(
                                        UiWidgets.classifyImportCandidate(
                                                "https://example.test/pkg.zip"))
                        && "脚本源链接"
                                .equals(
                                        UiWidgets.classifyImportCandidate(
                                                "https://example.test/sp.py"))
                        && "直播源"
                                .equals(
                                        UiWidgets.classifyImportCandidate(
                                                "#EXTM3U\n#EXTINF:-1,CCTV1\nhttp://a.test/1.m3u8"))
                        && "本地规则"
                                .equals(
                                        UiWidgets.classifyImportCandidate(
                                                "clan://localhost/tvbox/config.json"))
                        && "JSON 配置"
                                .equals(
                                        UiWidgets.classifyImportCandidate(
                                                "{\"sites\":[{\"key\":\"demo\"}]}")),
                "Pillar 7: UiWidgets.classifyImportCandidate detects URL, JSON, M3U, ZIP, script, and clan:// sources");
        check(
                UiWidgets.classifyImportCandidate(null) == null
                        && UiWidgets.classifyImportCandidate("") == null
                        && UiWidgets.classifyImportCandidate("short") == null
                        && UiWidgets.classifyImportCandidate("just a normal chat sentence") == null
                        && UiWidgets.classifyImportCandidate("{\"hello\":\"world\"}") == null,
                "Pillar 7: UiWidgets.classifyImportCandidate rejects non-source clipboard text");

        // 8. SpeedLockCapsule.ensureDarkSurfaceContrast
        int liftedSlate = SpeedLockCapsule.ensureDarkSurfaceContrast(0xFF64748B);
        int liftedAzure = SpeedLockCapsule.ensureDarkSurfaceContrast(0xFF007AFF);
        int keptAmber = SpeedLockCapsule.ensureDarkSurfaceContrast(0xFFF59E0B);
        check(
                liftedSlate != 0xFF64748B
                        && lumaOf(liftedSlate) >= 165.0
                        && lumaOf(liftedAzure) >= 160.0
                        && keptAmber == 0xFFF59E0B,
                "Pillar 7: SpeedLockCapsule.ensureDarkSurfaceContrast lifts #64748B/#007AFF and preserves bright #F59E0B");
        for (int i = 0; i < MobileTheme.ACCENT_COLORS.length; i++) {
            int lifted = SpeedLockCapsule.ensureDarkSurfaceContrast(MobileTheme.ACCENT_COLORS[i]);
            check(
                    lumaOf(lifted) >= 160.0,
                    "Pillar 7: SpeedLockCapsule dark-surface contrast holds for accent preset "
                            + i);
        }
    }

    private static void test8_StaticUxHygieneAndReviewerGuards(Path root) throws Exception {
        String javaBase = "android-mobile/src/main/java/com/pilipala/marcomovie/";

        // 1. Unified MobileBottomSheet.showConfirm across all destructive-action surfaces
        String[] confirmFiles = {
            "MobileHomePage.java",
            "MobileLibraryPage.java",
            "MobileDownloads.java",
            "MobileSearchPage.java",
            "MobileSettingsScreen.java",
            "PlaybackControls.java"
        };
        for (String f : confirmFiles) {
            String src = readUtf8(root, javaBase + f);
            check(
                    src.contains("MobileBottomSheet.showConfirm("),
                    "Pillar 8 static: " + f + " uses unified MobileBottomSheet.showConfirm(");
        }

        // 2. Zero legacy emojis & zero "60fps" in redesigned mobile UI / HUD files
        String[] emojiCleanFiles = {
            "MobileDownloads.java",
            "hud/SpeedLockCapsule.java",
            "PlayerChrome.java",
            "MobilePlayerOverlay.java",
            "TouchPlayerGesture.java",
            "MobileRootShell.java",
            "MobileLibraryPage.java",
            "MobileSettingsScreen.java"
        };
        String[] forbiddenTokens = {
            "\uD83D\uDD12", // 🔒
            "\u23E9", // ⏩
            "\u2B07", // ⬇
            "\u25B6", // ▶
            "\u26A1", // ⚡
            "\uD83D\uDD0D", // 🔍
            "\u2601", // ☁
            "\u2630", // ☰
            "60fps"
        };
        for (String f : emojiCleanFiles) {
            String src = readUtf8(root, javaBase + f);
            boolean clean = true;
            for (String tok : forbiddenTokens) {
                if (src.contains(tok)) {
                    clean = false;
                    break;
                }
            }
            check(clean, "Pillar 8 static: zero legacy emojis or \"60fps\" in " + f);
        }

        // 3. Zero legacy emerald / dark-green / off-palette hardcoded colors
        String[] colorCleanFiles = {
            "MobileDownloads.java",
            "TouchPlayerGesture.java",
            "hud/SlimProgressBar.java",
            "hud/SpeedLockCapsule.java"
        };
        String[] forbiddenColors = {"#181922", "#252734", "0xdc181d1b", "0xff34d399"};
        for (String f : colorCleanFiles) {
            String lower = readUtf8(root, javaBase + f).toLowerCase(Locale.ROOT);
            boolean clean = true;
            for (String col : forbiddenColors) {
                if (lower.contains(col)) {
                    clean = false;
                    break;
                }
            }
            check(clean, "Pillar 8 static: zero legacy hardcoded palette colors in " + f);
        }

        // 4. Zero ad-hoc new DecelerateInterpolator / new LinearInterpolator
        String[] motionFiles = {
            "MobileBottomSheet.java",
            "MobileRootShell.java",
            "MobileSettingsScreen.java",
            "hud/SpeedLockCapsule.java",
            "hud/SlimProgressBar.java",
            "hud/StartSpecBanner.java"
        };
        for (String f : motionFiles) {
            String src = readUtf8(root, javaBase + f);
            check(
                    !src.contains("new DecelerateInterpolator")
                            && !src.contains("new LinearInterpolator"),
                    "Pillar 8 static: zero ad-hoc Decelerate/Linear interpolators in " + f);
        }

        // 5. Reviewer P0/P1 regression guards
        String sheetSrc = readUtf8(root, javaBase + "MobileBottomSheet.java");
        int hScrollIdx = sheetSrc.indexOf("hasScrollableHorizontalChild(");
        String hScrollBody =
                hScrollIdx >= 0
                        ? sheetSrc.substring(
                                hScrollIdx, Math.min(sheetSrc.length(), hScrollIdx + 600))
                        : "";
        check(
                hScrollBody.contains("MobileSectionGroup.SegmentedTrackView")
                        && hScrollBody.contains("AbsSeekBar"),
                "Pillar 8 reviewer guard: MobileBottomSheet.hasScrollableHorizontalChild protects SegmentedTrackView & AbsSeekBar");

        String shellSrc = readUtf8(root, javaBase + "MobileRootShell.java");
        int expandIdx = shellSrc.indexOf("void expandDock()");
        String expandBody =
                expandIdx >= 0
                        ? shellSrc.substring(
                                expandIdx, Math.min(shellSrc.length(), expandIdx + 600))
                        : "";
        check(
                expandBody.contains("driveDockSpringTo(0f)")
                        && !expandBody.contains("mainCapsule.getVisibility() != View.VISIBLE")
                        && shellSrc.contains("computeDockMorphAlphas(")
                        && shellSrc.contains("DockScrollTracker")
                        && shellSrc.contains("statusBarVeil"),
                "Pillar 8 reviewer guard: MobileRootShell uses single-spring zero-ghost dock morph, DockScrollTracker, and statusBarVeil");

        // Verify strictly non-overlapping two-phase dock morph alphas across [0, 1] (zero ghost!)
        boolean strictlyDisjoint = true;
        for (int i = 0; i <= 100; i++) {
            float p = i / 100f;
            float[] aPair = MobileRootShell.computeDockMorphAlphas(p);
            if (aPair[0] > 0f && aPair[1] > 0f) {
                strictlyDisjoint = false;
                break;
            }
        }
        float[] startPair = MobileRootShell.computeDockMorphAlphas(0f);
        float[] midPair = MobileRootShell.computeDockMorphAlphas(0.45f);
        float[] endPair = MobileRootShell.computeDockMorphAlphas(1f);
        check(
                strictlyDisjoint
                        && Math.abs(startPair[0] - 1f) < 1e-4f
                        && startPair[1] == 0f
                        && midPair[0] == 0f
                        && midPair[1] == 0f
                        && endPair[0] == 0f
                        && Math.abs(endPair[1] - 1f) < 1e-4f,
                "Pillar 8 device guard: computeDockMorphAlphas is strictly disjoint across [0, 1] (mathematically zero ghosting)");

        // Verify DockScrollTracker hysteresis, 120Hz accumulation, syncCollapsed (no lockout),
        // and cooldown
        MobileRootShell.DockScrollTracker tracker = new MobileRootShell.DockScrollTracker();
        long tMs = 1000L;
        check(
                tracker.onScroll(0, true, tMs, 120, 96, 60, 280)
                        == MobileRootShell.DockScrollTracker.ACTION_NONE,
                "Pillar 8 device guard: DockScrollTracker initializes cleanly at y=0");
        // Small 120Hz scroll steps below threshold do not jitter; crossing threshold collapses
        int act1 = tracker.onScroll(180, true, tMs + 8, 120, 96, 60, 280);
        int act2 = tracker.onScroll(310, true, tMs + 16, 120, 96, 60, 280);
        // Immediate reversal within cooldown is ignored; after cooldown upward scroll expands
        int cooldownUp = tracker.onScroll(180, true, tMs + 40, 120, 96, 60, 280);
        int validUp = tracker.onScroll(70, true, tMs + 200, 120, 96, 60, 280);
        // After programmatic expand sync, immediate downward scroll collapses cleanly without lock
        tracker.syncCollapsed(false, tMs + 210);
        tracker.onScroll(100, true, tMs + 220, 120, 96, 60, 280);
        int afterSyncDown = tracker.onScroll(320, false, tMs + 340, 120, 96, 60, 280);
        check(
                act1 == MobileRootShell.DockScrollTracker.ACTION_NONE
                        && act2 == MobileRootShell.DockScrollTracker.ACTION_COLLAPSE
                        && cooldownUp == MobileRootShell.DockScrollTracker.ACTION_NONE
                        && validUp == MobileRootShell.DockScrollTracker.ACTION_EXPAND
                        && afterSyncDown == MobileRootShell.DockScrollTracker.ACTION_COLLAPSE,
                "Pillar 8 device guard: DockScrollTracker enforces hysteresis, cooldown, and reliable scroll auto-collapse");

        // Verify MobileTheme.blend preserves alpha and blends RGB tonal surface
        int blended = MobileTheme.blend(0xF0000000, 0xFF007AFF, 0.5f);
        check(
                ((blended >>> 24) & 0xFF) == 0xF0
                        && ((blended >> 16) & 0xFF) == 0
                        && Math.abs(((blended >> 8) & 0xFF) - 61) <= 1
                        && Math.abs((blended & 0xFF) - 128) <= 1,
                "Pillar 8 device guard: MobileTheme.blend mixes tonal accent while preserving container alpha");

        // Verify Android 15/16 Edge-to-Edge immersive system bars & Home brand logo
        String mainSrc = readUtf8(root, javaBase + "MainActivity.java");
        String detailSrc = readUtf8(root, javaBase + "MobileDetailScreen.java");
        check(
                mainSrc.contains("w.setNavigationBarColor(Color.TRANSPARENT);")
                        && mainSrc.contains("w.setDecorFitsSystemWindows(false);")
                        && mainSrc.contains("w.setNavigationBarContrastEnforced(false);")
                        && mainSrc.contains("View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION")
                        && detailSrc.contains("a.applyMobileSystemBars(false, true);"),
                "Pillar 8 device guard: MainActivity enables true Android 15/16 Edge-to-Edge immersive bars & DetailScreen dark-hero light icons");

        String controlsSrc = readUtf8(root, javaBase + "PlaybackControls.java");
        check(
                controlsSrc.contains("getBoolean(Prefs.SUBTITLE_BILINGUAL, true)")
                        && !controlsSrc.contains("getBoolean(Prefs.SUBTITLE_BILINGUAL, false)"),
                "Pillar 8 reviewer guard: PlaybackControls SUBTITLE_BILINGUAL defaults to true");

        // 6. Real-device QA regression guards (Android 16 Xiaomi 14 Ultra hands-on fixes)
        check(
                MobileBottomSheet.computeRemainingScrollHeightPx(2432, 350, 369) == 2082
                        && MobileBottomSheet.computeRemainingScrollHeightPx(2432, 2300, 369) == 369
                        && MobileBottomSheet.computeRemainingScrollHeightPx(2432, 2400, 369) == 369,
                "Pillar 8 device guard: MobileBottomSheet.computeRemainingScrollHeightPx preserves full scroll height and floor");
        check(
                sheetSrc.contains("measureChildWithMargins(")
                        && !sheetSrc.contains("child.measure(childWSpec, childHSpec)"),
                "Pillar 8 device guard: MobileBottomSheet.MaxHeightLinearLayout uses measureChildWithMargins (never raw AT_MOST on View handle)");

        check(
                "正片 · 00:42 / 1:30:48"
                                .equals(
                                        MobileHomePage.formatCleanHistoryLabel(
                                                "[3.63GB] M- 4K.mkv · 00:42 / 1:30:48",
                                                "[3.63GB] M- 4K.mkv",
                                                "目不转睛",
                                                0,
                                                1))
                        && "第 5 集 · 12:04 / 45:00"
                                .equals(
                                        MobileHomePage.formatCleanHistoryLabel(
                                                "[2.88GB] DL-S01E05-2160p.mkv · 12:04 / 45:00",
                                                "[2.88GB] DL-S01E05-2160p.mkv",
                                                "大奉打更人",
                                                4,
                                                1))
                        && "[3.63GB] M- 4K.mkv · 00:42 / 1:30:48"
                                .equals(
                                        MobileHomePage.formatCleanHistoryLabel(
                                                "[3.63GB] M- 4K.mkv · 00:42 / 1:30:48",
                                                "[3.63GB] M- 4K.mkv",
                                                "目不转睛",
                                                0,
                                                0)),
                "Pillar 8 device guard: MobileHomePage.formatCleanHistoryLabel purifies raw netdisk filenames while keeping progress");

        String homeSrc = readUtf8(root, javaBase + "MobileHomePage.java");
        check(
                homeSrc.contains("HomeScreen.Snapshot initialSnap = a.homeData.get(site.key);")
                        && homeSrc.contains("categories.addAll(initialSnap.categories)")
                        && homeSrc.contains("R.drawable.logo_mark")
                        && homeSrc.contains("\"home-brand\"")
                        && homeSrc.contains("\"Marco Movie\"")
                        && homeSrc.contains("buildImmersiveHeroBillboard("),
                "Pillar 8 device guard: MobileHomePage renders iOS-style Marco Movie wordmark, immersive Hero billboard, and cached categories");
        check(
                MobileHomePage.computeImmersiveHeroHeightPx(3200, 1500, 1950) == 1792
                        && MobileHomePage.computeImmersiveHeroHeightPx(1600, 1200, 1950) == 1200
                        && MobileHomePage.computeImmersiveHeroHeightPx(5000, 1200, 1950) == 1950
                        && MobileHomePage.computeImmersiveHeroHeightPx(0, 1200, 1950) == 1200,
                "Pillar 8 device guard: MobileHomePage.computeImmersiveHeroHeightPx clamps ~56% full-bleed Hero height");
        check(
                ImageLoader.isTrueHdPosterDimensions(780, 1170)
                        && !ImageLoader.isTrueHdPosterDimensions(270, 400)
                        && !ImageLoader.isTrueHdPosterDimensions(559, 800)
                        && "https://img1.doubanio.com/view/photo/l_ratio_poster/public/p12345.jpg"
                                .equals(
                                        ImageLoader.upgradePosterUrl(
                                                "https://img1.doubanio.com/view/photo/large/public/p12345.webp?sign=abc",
                                                true))
                        && "https://cdn.example.test/p.jpg"
                                .equals(
                                        ImageLoader.upgradePosterUrl(
                                                "https://cdn.example.test/p.jpg?x-oss-process=image/resize,w_270",
                                                true)),
                "Pillar 8 device guard: ImageLoader HD gate and URL upgrader strip resize directives and promote Douban l_ratio_poster");
        int darkAtmo = MobileHomePage.resolveRexHeroAtmosphere(0xFFE8B949, true);
        int lightWarmAtmo = MobileHomePage.resolveRexHeroAtmosphere(0xFFE8B949, false);
        check(
                MobileHomePage.useLightInkForHeroAtmo(darkAtmo, true)
                        && !MobileHomePage.useLightInkForHeroAtmo(lightWarmAtmo, false)
                        && MobileHomePage.useLightInkForHeroAtmo(0xFF1A2233, false),
                "Pillar 8 device guard: RexHeroAtmosphere harmonizes dark/light poster tones and adaptive ink polarity");
        check(
                MobileHomePage.resolveHeroSwipeTargetPage(0, 5, -400f, -100f, 1440) == 1
                        && MobileHomePage.resolveHeroSwipeTargetPage(0, 5, -50f, -900f, 1440) == 1
                        && MobileHomePage.resolveHeroSwipeTargetPage(0, 5, -50f, -100f, 1440) == 0
                        && MobileHomePage.resolveHeroSwipeTargetPage(2, 5, 400f, 100f, 1440) == 1
                        && MobileHomePage.resolveHeroSwipeTargetPage(4, 5, -500f, -1200f, 1440)
                                == 4,
                "Pillar 8 device guard: HeroPagerView.resolveHeroSwipeTargetPage commits adjacent slide cleanly on drag or fling");
        check(
                homeSrc.contains("HeroPagerView")
                        && homeSrc.contains("HeroAtmosphereView")
                        && homeSrc.contains("HeroBottomDissolveView")
                        && homeSrc.contains("extractHeroLowerBandColor(")
                        && homeSrc.contains("MobileCuratedSection.renderInto(")
                        && homeSrc.contains("ImageLoader.loadHeroHdPoster(")
                        && homeSrc.contains("scrollContentHost")
                        && !homeSrc.contains("heroAndShelvesStage")
                        && homeSrc.contains("setDissolveRange(")
                        && homeSrc.contains("row.setGravity(Gravity.TOP);")
                        && homeSrc.contains("row.setBaselineAligned(false);")
                        && homeSrc.contains(
                                "t.setSingleLine(true);\n            t.setMaxLines(1);"),
                "Pillar 8 device guard: MobileHomePage uses zero-seam live-blended HeroBottomDissolveView, fixed 6-module MobileCuratedSection, tight gap, and aligned single-line cards");

        // Verify iOS-style Favorite Postcard Animation non-repeating picker, timeline & wiring
        boolean pickerNonRepeating = true;
        for (int prev = -1; prev < MobileFavoritePostcard.STYLE_COUNT; prev++) {
            for (int raw = -5; raw <= 12; raw++) {
                int next = MobileFavoritePostcard.pickNextStyle(prev, raw);
                if (next < 0 || next >= MobileFavoritePostcard.STYLE_COUNT || next == prev) {
                    pickerNonRepeating = false;
                    break;
                }
            }
        }
        check(
                pickerNonRepeating,
                "Pillar 8 device guard: MobileFavoritePostcard.pickNextStyle covers [0, 3] and never repeats previous style");

        MobileFavoritePostcard.TimelineState favFlash =
                MobileFavoritePostcard.computeTimelineState(0.035f, false);
        MobileFavoritePostcard.TimelineState favHold =
                MobileFavoritePostcard.computeTimelineState(0.20f, false);
        MobileFavoritePostcard.TimelineState favFly =
                MobileFavoritePostcard.computeTimelineState(0.40f, false);
        MobileFavoritePostcard.TimelineState favIsland =
                MobileFavoritePostcard.computeTimelineState(0.65f, false);
        MobileFavoritePostcard.TimelineState favDone =
                MobileFavoritePostcard.computeTimelineState(0.99f, false);
        MobileFavoritePostcard.TimelineState favReduced =
                MobileFavoritePostcard.computeTimelineState(0.50f, true);
        check(
                favFlash.flashOpacity > 0.80f
                        && !favFlash.showPostcard
                        && favHold.flashOpacity == 0f
                        && favHold.showPostcard
                        && favHold.cardOpacity == 1f
                        && favHold.flightProgress == 0f
                        && !favHold.showIsland
                        && favFly.showPostcard
                        && favFly.flightProgress > 0f
                        && favFly.cardTiltXDeg > 0f
                        && !favIsland.showPostcard
                        && favIsland.showIsland
                        && favIsland.islandExpand == 1f
                        && favIsland.arrivalTriggered
                        && !favDone.showPostcard
                        && !favDone.showIsland
                        && favReduced.flashOpacity == 0f
                        && !favReduced.showPostcard
                        && favReduced.showIsland
                        && favReduced.islandExpand == 1f,
                "Pillar 8 device guard: MobileFavoritePostcard.computeTimelineState executes flash -> develop -> 3D flight -> Dynamic Island & reduced-motion fallback");
        check(
                detailSrc.contains("MobileFavoritePostcard.show(")
                        && detailSrc.contains("MobileFavoritePostcard.dismissActive()")
                        && detailSrc.contains("MobileCuratedDiscovery.isCuratedSite(")
                        && !detailSrc.contains("TmdbService.enrichDetailAsync(")
                        && !detailSrc.contains("IMDb %.1f"),
                "Pillar 8 device guard: MobileDetailScreen launches collectible postcard, resolves curated items from user sources, and removes TMDB/IMDb badges");

        // Verify iOS-style zero-config Curated Discovery parser, fuzzy matching & TMDB/IMDb removal
        String sampleDouban =
                "{\"subject_collection_items\":[{"
                        + "\"id\":\"35678\",\"title\":\"漫长的季节\",\"year\":\"2023\","
                        + "\"pic\":{\"large\":\"https://img3.doubanio.com/view/photo/s_ratio_poster/public/p1.jpg\"},"
                        + "\"rating\":{\"value\":9.4},"
                        + "\"card_subtitle\":\"2023 / 中国大陆 / 剧情 悬疑 / 辛爽\","
                        + "\"actors\":[\"范伟\",\"秦昊\"]"
                        + "}]}";
        List<Cms.Video> parsedCurated =
                MobileCuratedDiscovery.parseDoubanDiscoveryJson(sampleDouban, "cn_hot");
        check(
                parsedCurated.size() == 1
                        && "curated:cn_hot:35678".equals(parsedCurated.get(0).id)
                        && "漫长的季节".equals(parsedCurated.get(0).title)
                        && "豆瓣 9.4".equals(parsedCurated.get(0).remarks)
                        && parsedCurated.get(0).poster.contains("/m_ratio_poster/")
                        && "中国大陆".equals(parsedCurated.get(0).area)
                        && MobileCuratedDiscovery.isCuratedSite(
                                MobileCuratedDiscovery.curatedSiteSentinel()),
                "Pillar 8 device guard: MobileCuratedDiscovery parses Douban charts cleanly without TMDB/IMDb keys");
        check(
                MobileCuratedDiscovery.titleMatchScore("庆余年 第二季", "庆余年2 [4K中字]") == 100
                        && MobileCuratedDiscovery.titleMatchScore("沙丘2", "沙丘2 2024") == 80
                        && MobileCuratedDiscovery.titleMatchScore("凡人修仙传", "凡人修仙传 动态漫") == 0,
                "Pillar 8 device guard: MobileCuratedDiscovery.titleMatchScore normalizes sequels/tags and rejects motion-comic mismatches");

        String settingsSrc = readUtf8(root, javaBase + "MobileSettingsScreen.java");
        String settingsIdxSrc = readUtf8(root, javaBase + "MobileSettingsIndex.java");
        int aiEnableIdx = settingsSrc.indexOf("\"ms-ai-enable\"");
        String aiEnableBlock =
                aiEnableIdx >= 0
                        ? settingsSrc.substring(
                                aiEnableIdx, Math.min(settingsSrc.length(), aiEnableIdx + 360))
                        : "";
        check(
                homeSrc.contains("renderCuratedDiscoveryHome(")
                        && !homeSrc.contains("TmdbService.isConfigured(")
                        && !shellSrc.contains("最近热门推荐首页")
                        && MobileCuratedDiscovery.MODULES.size() == 8
                        && detailSrc.contains("暂无数据 · 请添加订阅资源")
                        && !settingsSrc.contains("showTmdbConfigDialog")
                        && !settingsSrc.contains("ms-tmdb-cfg")
                        && !settingsSrc.contains("ms-mdblist-cfg")
                        && !settingsSrc.contains("ms-home-mode")
                        && !settingsIdxSrc.contains("ms-tmdb-cfg")
                        && !settingsIdxSrc.contains("ms-mdblist-cfg")
                        && !settingsIdxSrc.contains("ms-home-mode")
                        && !aiEnableBlock.contains("reloadPreservingScroll"),
                "Pillar 8 device guard: 8 curated modules fixed on Home (removed from source switcher/settings), no-source prompt clear, TMDB/IMDb removed, and ms-ai-enable zero-flash");

        String liveSrc = readUtf8(root, javaBase + "MobileLivePage.java");
        check(
                liveSrc.contains("MobileIcons.IC_SPARKLE")
                        && liveSrc.contains("replaceFirst(\"^✨\\\\s*\", \"\")")
                        && liveSrc.contains("\"live-import-btn\"")
                        && liveSrc.contains("SourceController.showLiveImportDialog(a)"),
                "Pillar 8 device guard: MobileLivePage strips ✨ emoji, renders vector IC_SPARKLE, and exposes top-right import live source button");

        String crashSrc = readUtf8(root, javaBase + "CrashReportDialog.java");
        check(
                crashSrc.contains("MobileTheme.of(a)") && crashSrc.contains("MobileIcons.IC_CHECK"),
                "Pillar 8 device guard: CrashReportDialog uses MobileTheme palette and vector checkmarks on mobile");

        // Verify iOS-parity Curated Collection Wall 3-style physics & convergence math
        check(
                Math.abs(MobileCuratedWallScreen.gravityFallWithBounce(0f)) < 1e-4f
                        && MobileCuratedWallScreen.gravityFallWithBounce(0.68f) > 0.99f
                        && MobileCuratedWallScreen.gravityFallWithBounce(0.77f) < 0.95f
                        && Math.abs(MobileCuratedWallScreen.gravityFallWithBounce(1f) - 1f) < 1e-4f,
                "Pillar 8 iOS motion guard: MobileCuratedWallScreen.gravityFallWithBounce accelerates, bounces, and settles at 1.0");

        int[] wallStyles = {
            MobileCuratedWallScreen.STYLE_GRAVITY_STACK,
            MobileCuratedWallScreen.STYLE_BLACK_HOLE_VORTEX,
            MobileCuratedWallScreen.STYLE_TETRIS_TUMBLE
        };
        boolean allWallStylesConverge = true;
        for (int st : wallStyles) {
            MobileCuratedWallScreen.PhysicsCardState mid =
                    MobileCuratedWallScreen.computePhysicsCardState(
                            st, 2, 12, 0.36f, 1080f, 2400f, 3f, 360f, 420f, 300f, 444f);
            MobileCuratedWallScreen.PhysicsCardState end =
                    MobileCuratedWallScreen.computePhysicsCardState(
                            st, 2, 12, 1.0f, 1080f, 2400f, 3f, 360f, 420f, 300f, 444f);
            boolean midDistinct =
                    Math.abs(mid.centerX - 510f) > 1f || Math.abs(mid.centerY - 642f) > 1f;
            boolean exactLanding =
                    Math.abs(end.centerX - 510f) < 0.05f
                            && Math.abs(end.centerY - 642f) < 0.05f
                            && Math.abs(end.width - 300f) < 0.05f
                            && Math.abs(end.height - 444f) < 0.05f
                            && Math.abs(end.angleRad) < 1e-4f
                            && Math.abs(end.opacity - 1f) < 1e-4f;
            if (!midDistinct || !exactLanding) {
                allWallStylesConverge = false;
                break;
            }
        }
        check(
                allWallStylesConverge,
                "Pillar 8 iOS motion guard: All 3 MobileCuratedWallScreen physics styles (GravityStack / BlackHoleVortex / TetrisTumble) animate dynamically and converge pixel-exactly onto target grid cells");

        // Verify iOS-parity shared-element Poster Expand & Shrink-Back-to-Origin math
        float sp0 = MobilePosterTransition.evaluateSpringProgress(0f, false);
        float spQuarter = MobilePosterTransition.evaluateSpringProgress(0.25f, false);
        float spHalf = MobilePosterTransition.evaluateSpringProgress(0.50f, false);
        float spOne = MobilePosterTransition.evaluateSpringProgress(1f, false);
        float spRevHalf = MobilePosterTransition.evaluateSpringProgress(0.50f, true);
        check(
                sp0 == 0f
                        && spQuarter > 0.55f
                        && spHalf > spQuarter
                        && spHalf < 1f
                        && spOne == 1f
                        && spRevHalf > 0.80f
                        && spRevHalf < 1f,
                "Pillar 8 iOS motion guard: MobilePosterTransition critically-damped spring is strictly monotonic with zero overshoot");

        MobilePosterTransition.MorphFrame mfStart =
                MobilePosterTransition.computeMorphFrame(
                        48f, 620f, 348f, 1064f, 1080f, 2400f, 36f, 0f, false, true, false);
        MobilePosterTransition.MorphFrame mfMid =
                MobilePosterTransition.computeMorphFrame(
                        48f, 620f, 348f, 1064f, 1080f, 2400f, 36f, 0.5f, false, true, false);
        MobilePosterTransition.MorphFrame mfEnd =
                MobilePosterTransition.computeMorphFrame(
                        48f, 620f, 348f, 1064f, 1080f, 2400f, 36f, 1f, false, true, false);
        MobilePosterTransition.MorphFrame mfRevLanding =
                MobilePosterTransition.computeMorphFrame(
                        48f, 620f, 348f, 1064f, 1080f, 2400f, 36f, 0.02f, false, true, true);
        check(
                mfStart.left == 48f
                        && mfStart.top == 620f
                        && mfStart.radiusPx == 36f
                        && !mfStart.hideSourceCard
                        && mfStart.detailOpacity == 0f
                        && mfMid.hideSourceCard
                        && mfMid.detailOpacity > 0.9f
                        && mfMid.backdropDim > 0.15f
                        && mfEnd.left == 0f
                        && mfEnd.top == 0f
                        && mfEnd.right == 1080f
                        && mfEnd.bottom == 2400f
                        && mfEnd.radiusPx == 0f
                        && mfEnd.detailOpacity == 1f
                        && !mfRevLanding.hideSourceCard
                        && mfRevLanding.edgeOpacity < 0.6f,
                "Pillar 8 iOS motion guard: MobilePosterTransition.computeMorphFrame interpolates bounds/radius/dim/detailOpacity and enforces 0.035 zero-ghosting hide threshold");

        String curatedSecSrc = readUtf8(root, javaBase + "MobileCuratedSection.java");
        String curatedWallSrc = readUtf8(root, javaBase + "MobileCuratedWallScreen.java");
        String mainNavSrc = readUtf8(root, javaBase + "MainActivity.java");
        String searchPageSrc = readUtf8(root, javaBase + "MobileSearchPage.java");
        String libPageSrc = readUtf8(root, javaBase + "MobileLibraryPage.java");
        check(
                curatedSecSrc.contains("MobileCuratedWallScreen.open(")
                        && curatedSecSrc.contains("STYLE_BLACK_HOLE_VORTEX")
                        && curatedSecSrc.contains("STYLE_TETRIS_TUMBLE")
                        && curatedSecSrc.contains("STYLE_GRAVITY_STACK")
                        && curatedWallSrc.contains("BlackHoleVortexView")
                        && curatedWallSrc.contains("MobilePosterTransition.openDetailFromCard(")
                        && homeSrc.contains("MobilePosterTransition.openDetailFromCard(")
                        && searchPageSrc.contains("MobilePosterTransition.openDetailFromCard(")
                        && libPageSrc.contains("MobilePosterTransition.openDetailFromCard(")
                        && mainNavSrc.contains("MobilePosterTransition.tryAnimatedBack(this)"),
                "Pillar 8 iOS motion guard: Full-screen Curated Collection Wall and shared-element poster expand/return transitions are wired across Home, Curated Wall, Search, Library, and MainActivity Back");

        // 7. 6-pillar craft upgrade guards (Dual Poster+Dock transition, Top source pill harmony,
        //    Episode locator & per-show ascending default, Linear Onboarding, Deep Settings UI,
        //    Dock long-press/slide quick actions)
        MobilePosterTransition.DualMorphFrame dmStart =
                MobilePosterTransition.computeDualMorphFrame(
                        48f, 520f, 348f, 964f, 36f, true, 60f, 2140f, 1020f, 2310f, 84f, 1080f,
                        2400f, 860f, 72f, 60f, 0f, false, true, false);
        MobilePosterTransition.DualMorphFrame dmMid =
                MobilePosterTransition.computeDualMorphFrame(
                        48f, 520f, 348f, 964f, 36f, true, 60f, 2140f, 1020f, 2310f, 84f, 1080f,
                        2400f, 860f, 72f, 60f, 0.5f, false, true, false);
        MobilePosterTransition.DualMorphFrame dmEnd =
                MobilePosterTransition.computeDualMorphFrame(
                        48f, 520f, 348f, 964f, 36f, true, 60f, 2140f, 1020f, 2310f, 84f, 1080f,
                        2400f, 860f, 72f, 60f, 1f, false, true, false);
        MobilePosterTransition.DualMorphFrame dmRevNear =
                MobilePosterTransition.computeDualMorphFrame(
                        48f, 520f, 348f, 964f, 36f, true, 60f, 2140f, 1020f, 2310f, 84f, 1080f,
                        2400f, 860f, 72f, 60f, 0.02f, false, true, true);
        MobilePosterTransition.DualMorphFrame dmNoDock =
                MobilePosterTransition.computeDualMorphFrame(
                        48f, 520f, 348f, 964f, 36f, false, 0f, 0f, 0f, 0f, 84f, 1080f, 2400f, 860f,
                        72f, 60f, 0.5f, false, true, false);
        check(
                dmStart.posterLeft == 48f
                        && dmStart.posterTop == 520f
                        && dmStart.sheetLeft == 60f
                        && dmStart.sheetTop == 2140f
                        && dmStart.sheetTopRadiusPx == 84f
                        && dmStart.sheetBottomRadiusPx == 84f
                        && !dmStart.hideSourceCard
                        && !dmStart.hideDock
                        && dmMid.hideSourceCard
                        && dmMid.hideDock
                        && dmMid.sheetTop < 2140f
                        && dmMid.sheetTop > 860f
                        && dmEnd.posterLeft == 0f
                        && dmEnd.posterRight == 1080f
                        && dmEnd.posterBottom >= 920f
                        && dmEnd.sheetLeft == 0f
                        && dmEnd.sheetTop == 860f
                        && dmEnd.sheetRight == 1080f
                        && dmEnd.sheetBottom == 2400f
                        && dmEnd.sheetTopRadiusPx == 72f
                        && dmEnd.sheetBottomRadiusPx == 0f
                        && dmEnd.sheetContentAlpha == 1f
                        && !dmRevNear.hideSourceCard
                        && !dmRevNear.hideDock
                        && !dmNoDock.hideDock,
                "Pillar 8 craft guard: MobilePosterTransition.computeDualMorphFrame synchronizes Poster->Hero and Dock->EpisodeSheet expansion & shrink-back");

        String posterTransSrc = readUtf8(root, javaBase + "MobilePosterTransition.java");
        check(
                posterTransSrc.contains("DualMorphStageView")
                        && posterTransSrc.contains("measureVisibleDockBounds(")
                        && detailSrc.contains("lowerBody.setTag(\"detail-lower-sheet\")")
                        && detailSrc.contains("a.glass(backBtn, 999)"),
                "Pillar 8 craft guard: DualMorphStageView & detail-lower-sheet wired cleanly while keeping glass backBtn contract");

        // Episode locator + per-video default-ascending sort + auto-locate remembered episode
        List<Cms.Episode> sampleEps = new java.util.ArrayList<>();
        for (int i = 1; i <= 5; i++) {
            Cms.Episode ep = new Cms.Episode();
            ep.name = "第0" + i + "集";
            ep.url = "u" + i;
            sampleEps.add(ep);
        }
        check(
                !MobileDetailScreen.defaultEpisodeDescending()
                        && MobileDetailScreen.resolveInitialEpisodeIndex(sampleEps, "第05集") == 4
                        && MobileDetailScreen.resolveInitialEpisodeIndex(sampleEps, "第01集") == 0
                        && MobileDetailScreen.resolveInitialEpisodeIndex(sampleEps, "") == 0
                        && MobileDetailScreen.resolveInitialEpisodeIndex(sampleEps, null) == 0
                        && MobileDetailScreen.resolveInitialEpisodeIndex(sampleEps, "不存在") == 0,
                "Pillar 8 craft guard: MobileDetailScreen defaults every show to ascending and resolves last-watched episode index accurately");
        check(
                !detailSrc.contains("Prefs.EPISODES_DESCENDING")
                        && detailSrc.contains("activeVideoDescending = defaultEpisodeDescending()")
                        && !settingsSrc.contains("\"ms-ep-desc\"")
                        && !settingsIdxSrc.contains("\"ms-ep-desc\""),
                "Pillar 8 craft guard: Episode sort is strictly per-show (zero global EPISODES_DESCENDING persistence)");

        // Dock long-press & long-press-slide quick actions across all 5 tabs
        boolean allDockTabsHaveActions = true;
        for (int tab = 0; tab <= 4; tab++) {
            List<MobileRootShell.DockQuickAction> acts = MobileRootShell.quickActionsForTab(tab);
            if (acts.size() < 2) {
                allDockTabsHaveActions = false;
                break;
            }
            Set<String> seenIds = new HashSet<>();
            for (MobileRootShell.DockQuickAction act : acts) {
                if (act.id == null
                        || act.id.isEmpty()
                        || act.label == null
                        || act.label.isEmpty()
                        || !seenIds.add(act.id)) {
                    allDockTabsHaveActions = false;
                    break;
                }
            }
        }
        float[] rowTops = new float[] {300f, 360f, 420f};
        float[] rowBots = new float[] {356f, 416f, 476f};
        check(
                allDockTabsHaveActions
                        && MobileRootShell.hitTestQuickAction(
                                        120f, 330f, 40f, 260f, rowTops, rowBots, 12f)
                                == 0
                        && MobileRootShell.hitTestQuickAction(
                                        120f, 390f, 40f, 260f, rowTops, rowBots, 12f)
                                == 1
                        && MobileRootShell.hitTestQuickAction(
                                        120f, 450f, 40f, 260f, rowTops, rowBots, 12f)
                                == 2
                        && MobileRootShell.hitTestQuickAction(
                                        10f, 390f, 40f, 260f, rowTops, rowBots, 12f)
                                == -1
                        && MobileRootShell.hitTestQuickAction(
                                        120f, 250f, 40f, 260f, rowTops, rowBots, 12f)
                                == -1,
                "Pillar 8 craft guard: MobileRootShell provides distinct long-press quick actions for all 5 Dock tabs with accurate slide hit-testing");
        check(
                shellSrc.contains("bindDockTabQuickGestures(")
                        && shellSrc.contains("DockQuickMenu"),
                "Pillar 8 craft guard: MobileRootShell wires DockQuickMenu long-press & slide gestures");

        // Redesigned minimalist interactive linear Onboarding
        check(
                OnboardingScreen.ACT_COUNT == 5
                        && OnboardingScreen.actEyebrows().length == 5
                        && OnboardingScreen.actTitles(false).length == 5
                        && OnboardingScreen.actTitles(true).length == 5
                        && OnboardingScreen.actSubtitles(false).length == 5,
                "Pillar 8 craft guard: OnboardingScreen exposes 5 minimalist linear-animated acts");
        String onboardSrc = readUtf8(root, javaBase + "OnboardingScreen.java");
        check(
                onboardSrc.contains("LinearPlaygroundView")
                        && onboardSrc.contains("0xFFF3F5F9")
                        && onboardSrc.contains("0xFF0A0B0E"),
                "Pillar 8 craft guard: OnboardingScreen renders interactive LinearPlaygroundView with Alabaster/Obsidian Day/Night tokens");

        // Deep Settings sub-pages & deep dialogs style consistency
        String updateSrc = readUtf8(root, javaBase + "UpdateScreen.java");
        String accountSrc = readUtf8(root, javaBase + "AccountPanel.java");
        String danmuSrc = readUtf8(root, javaBase + "DanmuSettingsPanel.java");
        String spiderGwSrc = readUtf8(root, javaBase + "SpiderGatewayDialog.java");
        String privacySrc = readUtf8(root, javaBase + "PrivacySpace.java");
        String cloudSyncSrc = readUtf8(root, javaBase + "CloudSyncDialog.java");
        check(
                updateSrc.contains("MobileTheme.of(a)")
                        && accountSrc.contains("MobileTheme.of(a)")
                        && danmuSrc.contains("MobileTheme.of(")
                        && spiderGwSrc.contains("MobileTheme.of(a)")
                        && privacySrc.contains("MobileTheme.of(a)")
                        && cloudSyncSrc.contains("MobileTheme.of(a)")
                        && !settingsSrc.contains("new AppDialog.Builder(")
                        && settingsSrc.contains("MobileBottomSheet.showHandle("),
                "Pillar 8 craft guard: All deep Settings sub-pages (UpdateScreen, AccountPanel) and deep panels (Danmu, SpiderGateway, CloudSync, Privacy, Settings dialogs) follow MobileTheme & MobileBottomSheet");

        // 1. Suppress duplicate center PlaybackLoading overlay while inline top player is active
        String playbackLoadingSrc = readUtf8(root, javaBase + "PlaybackLoading.java");
        String playbackCtrlSrc = readUtf8(root, javaBase + "PlaybackController.java");
        check(
                PlaybackLoading.shouldSuppressCenterOverlay(true)
                        && !PlaybackLoading.shouldSuppressCenterOverlay(false)
                        && playbackLoadingSrc.contains("shouldSuppressCenterOverlay(")
                        && playbackCtrlSrc.contains(
                                "a.inlinePlayer != null && !a.inlinePlayer.isClosed()"),
                "Pillar 8 polish guard: Center PlaybackLoading overlay is suppressed when top inline player is active");

        // 2. CrashReportStore ignores background cached LMK reclaims & ImageLoader bounds Native
        // Heap
        String imgLoaderSrc = readUtf8(root, javaBase + "ImageLoader.java");
        String curatedMemSrc = readUtf8(root, javaBase + "MobileCuratedSection.java");
        check(
                CrashReportStore.shouldRecordLowMemoryExit(100)
                        && CrashReportStore.shouldRecordLowMemoryExit(200)
                        && CrashReportStore.shouldRecordLowMemoryExit(230)
                        && !CrashReportStore.shouldRecordLowMemoryExit(400)
                        && !CrashReportStore.shouldRecordLowMemoryExit(500)
                        && !CrashReportStore.shouldRecordLowMemoryExit(0)
                        && imgLoaderSrc.contains("Bitmap.Config.RGB_565")
                        && imgLoaderSrc.contains("posterCompact(")
                        && imgLoaderSrc.contains("detachImageViews(")
                        && curatedMemSrc.contains("ImageLoader.posterCompact("),
                "Pillar 8 polish guard: Background cached LMK exits are filtered and poster thumbnails use RGB_565 + compact decode bounds");

        // 3. Playback Casting across inline player, fullscreen player, proxy unwrapping & mobile
        // sheet
        String hlsLocal =
                HlsStreamProxy.register("https://cdn.example.test/live/master.m3u8", null, false);
        String unwrappedCast = DlnaCastClient.resolveCastableMediaUrl(hlsLocal, "");
        String directCast =
                DlnaCastClient.resolveCastableMediaUrl("https://cdn.example.test/v.mp4", "");
        String fallbackCast =
                DlnaCastClient.resolveCastableMediaUrl(
                        "http://127.0.0.1:9999/unknown", "https://cdn.example.test/raw.m3u8");
        String dlnaSrc = readUtf8(root, javaBase + "DlnaCastClient.java");
        String inlineCastSrc = readUtf8(root, javaBase + "MobileInlinePlayer.java");
        String controlsCastSrc = readUtf8(root, javaBase + "PlaybackControls.java");
        check(
                "https://cdn.example.test/live/master.m3u8".equals(unwrappedCast)
                        && "https://cdn.example.test/v.mp4".equals(directCast)
                        && "https://cdn.example.test/raw.m3u8".equals(fallbackCast)
                        && DlnaCastClient.resolveCastableMediaUrl("http://127.0.0.1:9999/x", "")
                                .isEmpty()
                        && inlineCastSrc.contains("\"inline-cast\"")
                        && inlineCastSrc.contains("MobileIcons.IC_CAST")
                        && controlsCastSrc.contains("投屏到电视")
                        && dlnaSrc.contains("showMobileCastDevicePicker(")
                        && dlnaSrc.contains("MobileBottomSheet.show("),
                "Pillar 8 polish guard: Casting works from inline & fullscreen players with HLS proxy URL unwrapping and Day/Night MobileBottomSheet");

        // 4. Unused Startup Animation toggle removed from mobile Settings UI & index
        check(
                !settingsSrc.contains("\"ms-startup-anim\"")
                        && !settingsIdxSrc.contains("\"ms-startup-anim\""),
                "Pillar 8 polish guard: Unused Startup Animation setting is removed from MobileSettingsScreen and MobileSettingsIndex");

        // 5. Cold-start cached Immersive Hero snapshot + Hero disk poster cache
        Cms.Video hv1 = new Cms.Video();
        hv1.id = "v1";
        hv1.title = "A";
        hv1.poster = "https://img.example.test/a.jpg";
        Cms.Video hv1Same = new Cms.Video();
        hv1Same.id = "v1";
        hv1Same.title = "A";
        hv1Same.poster = "https://img.example.test/a.jpg";
        Cms.Video hv2 = new Cms.Video();
        hv2.id = "v2";
        hv2.title = "B";
        hv2.poster = "https://img.example.test/b.jpg";
        check(
                MobileHomePage.hasSameHeroLead(
                                java.util.Collections.singletonList(hv1),
                                java.util.Collections.singletonList(hv1Same))
                        && !MobileHomePage.hasSameHeroLead(
                                java.util.Collections.singletonList(hv1),
                                java.util.Collections.singletonList(hv2))
                        && homeSrc.contains("HomeScreen.readDiskSnapshot(")
                        && homeSrc.contains("HomeScreen.writeDiskSnapshot(")
                        && imgLoaderSrc.contains("hero_posters_v1"),
                "Pillar 8 polish guard: Home hydrates cold-start disk snapshot + Hero disk cache immediately and refreshes silently in background");

        // 6. Zero-bounce, zero-stair-step Dock & Cover Hero transition choreography
        check(
                Math.abs(MobilePosterTransition.interpolatePosterCropAnchorY(0f) - 0.50f) < 0.001f
                        && Math.abs(MobilePosterTransition.interpolatePosterCropAnchorY(1f) - 0.24f)
                                < 0.001f
                        && posterTransSrc.contains("resetPressScale(")
                        && posterTransSrc.contains("suppressTransitionContentView")
                        && !posterTransSrc.contains("lowerSheet.setVisibility(View.INVISIBLE)"),
                "Pillar 8 polish guard: MobilePosterTransition interpolates cover crop anchor smoothly, waits for OnPreDraw layout, and never mutates visibility in dispatchDraw");

        // 7. Non-nagging CrashReportStore reminder policy, confirmed-cached LMK purge, legacy LMK
        // preservation & per-ID prompted/dismissed persistence
        long nowMs = 1_800_000_000_000L;
        CrashReportStore.CrashReport unknownLmk = new CrashReportStore.CrashReport();
        unknownLmk.id = "exit_unknown_lmk";
        unknownLmk.timestampMs = nowMs - 10_000L;
        unknownLmk.kind = CrashReportStore.KIND_LOW_MEMORY;
        unknownLmk.summary = "内存不足 (OOM/LMK) (status=0)";
        unknownLmk.stackTrace =
                "ProcessExitReason: 3\nStatus/Signal: 0\nPSS(KB): 120000 / RSS(KB): 200000";

        CrashReportStore.CrashReport cachedLmk = new CrashReportStore.CrashReport();
        cachedLmk.id = "exit_cached_lmk";
        cachedLmk.timestampMs = nowMs - 15_000L;
        cachedLmk.kind = CrashReportStore.KIND_LOW_MEMORY;
        cachedLmk.summary = "内存不足 (OOM/LMK) (status=0)";
        cachedLmk.stackTrace = "ProcessExitReason: 3\nImportance: 400\nStatus/Signal: 0";

        CrashReportStore.CrashReport fgLmk = new CrashReportStore.CrashReport();
        fgLmk.id = "exit_fg_lmk";
        fgLmk.timestampMs = nowMs - 20_000L;
        fgLmk.kind = CrashReportStore.KIND_LOW_MEMORY;
        fgLmk.summary = "内存不足 (OOM/LMK) (status=0)";
        fgLmk.stackTrace = "ProcessExitReason: 3\nImportance: 100\nStatus/Signal: 0";

        CrashReportStore.CrashReport staleJava = new CrashReportStore.CrashReport();
        staleJava.id = "crash_stale";
        staleJava.timestampMs = nowMs - (CrashReportStore.PROMPT_MAX_AGE_MS + 60_000L);
        staleJava.kind = CrashReportStore.KIND_JAVA;
        staleJava.summary = "old crash";

        CrashReportStore.CrashReport freshJava = new CrashReportStore.CrashReport();
        freshJava.id = "crash_fresh";
        freshJava.timestampMs = nowMs - 5_000L;
        freshJava.kind = CrashReportStore.KIND_JAVA;
        freshJava.summary = "NullPointerException";

        check(
                !CrashReportStore.isConfirmedBackgroundLowMemoryReport(unknownLmk)
                        && CrashReportStore.isUnknownImportanceLowMemoryReport(unknownLmk)
                        && CrashReportStore.isConfirmedBackgroundLowMemoryReport(cachedLmk)
                        && !CrashReportStore.isConfirmedBackgroundLowMemoryReport(fgLmk)
                        && !CrashReportStore.isPromptEligible(unknownLmk, nowMs)
                        && !CrashReportStore.isPromptEligible(cachedLmk, nowMs)
                        && CrashReportStore.isPromptEligible(fgLmk, nowMs)
                        && !CrashReportStore.isPromptEligible(staleJava, nowMs)
                        && CrashReportStore.isPromptEligible(freshJava, nowMs),
                "Pillar 8 crash guard: Only confirmed cached LMK (>=400) is purged; unknown-importance legacy LMK suppresses auto-prompt while preserved in history");

        Path crashTmp = Files.createTempDirectory("mobile-crash-policy-");
        try {
            java.io.File crashDir = crashTmp.toFile();
            CrashReportStore.saveReport(crashDir, unknownLmk);
            CrashReportStore.saveReport(crashDir, cachedLmk);
            CrashReportStore.saveReport(crashDir, freshJava);
            CrashReportStore.saveReport(crashDir, staleJava);
            java.util.List<CrashReportStore.CrashReport> loaded =
                    CrashReportStore.loadReports(crashDir);
            java.util.List<CrashReportStore.CrashReport> promptable =
                    CrashReportStore.loadPromptableReports(crashDir, nowMs);
            boolean cachedOnlyPurged =
                    loaded.size() == 3
                            && promptable.size() == 1
                            && "crash_fresh".equals(promptable.get(0).id);

            CrashReportStore.markPrompted(crashDir, promptable);
            boolean promptedOnce =
                    CrashReportStore.loadPromptableReports(crashDir, nowMs).isEmpty();

            CrashReportStore.markDismissed(crashDir, promptable);
            java.util.List<CrashReportStore.CrashReport> afterDismissPromptable =
                    CrashReportStore.loadPromptableReports(crashDir, nowMs);
            java.util.List<CrashReportStore.CrashReport> afterDismissAll =
                    CrashReportStore.loadReports(crashDir);
            boolean dismissedStillInSettings =
                    afterDismissPromptable.isEmpty()
                            && afterDismissAll.size() == 3
                            && afterDismissAll.get(0).dismissed;
            check(
                    cachedOnlyPurged
                            && promptedOnce
                            && dismissedStillInSettings
                            && crashSrc.contains("loadPromptableReports(")
                            && crashSrc.contains("markPrompted(")
                            && crashSrc.contains("markDismissed(")
                            && crashSrc.contains("MobileBottomSheet.showHandle("),
                    "Pillar 8 crash guard: Per-ID prompted & dismissed flags persist silently without re-prompting while remaining viewable in Settings");
        } finally {
            CrashReportStore.clearAll(crashTmp.toFile());
            Files.deleteIfExists(crashTmp.resolve(CrashReportStore.DIR_NAME));
            Files.deleteIfExists(crashTmp);
        }

        // 8. Concurrent DoH Happy-Eyeballs racing, 2423 AES-CBC decode, & Mobile CPython linking
        java.util.List<java.net.InetAddress> rawDohIps =
                java.util.Arrays.asList(
                        java.net.InetAddress.getByAddress(
                                new byte[] {(byte) 185, (byte) 199, 109, (byte) 133}),
                        java.net.InetAddress.getByAddress(
                                new byte[] {(byte) 185, (byte) 199, 108, (byte) 133}),
                        java.net.InetAddress.getByAddress(
                                new byte[] {(byte) 185, (byte) 199, 109, (byte) 133}),
                        java.net.InetAddress.getByAddress(
                                new byte[] {(byte) 185, (byte) 199, 110, (byte) 133}),
                        java.net.InetAddress.getByAddress(
                                new byte[] {(byte) 185, (byte) 199, 111, (byte) 133}),
                        java.net.InetAddress.getByAddress(new byte[] {1, 2, 3, 4}));
        java.util.List<java.net.InetAddress> racedIps = Cms.selectDohRaceCandidates(rawDohIps, 4);
        String cmsSrc = readUtf8(root, javaBase + "Cms.java");
        check(
                racedIps.size() == 4
                        && "185.199.109.133".equals(racedIps.get(0).getHostAddress())
                        && "185.199.108.133".equals(racedIps.get(1).getHostAddress())
                        && "185.199.110.133".equals(racedIps.get(2).getHostAddress())
                        && "185.199.111.133".equals(racedIps.get(3).getHostAddress())
                        && cmsSrc.contains("raceDohAddresses(")
                        && !cmsSrc.contains("putIfAbsent(")
                        && Cms.utf8ByteLength("中文abc") == 9
                        && "{\"a\":1}".equals(Cms.withoutComments("{\"a\":1}"))
                        && "{\"a\":1}".equals(Cms.withoutComments("{\"a\":1,} // trailing").trim()),
                "Pillar 8 subscription guard: Cms races up to 4 deduplicated DoH IPs concurrently (API 23 safe, no putIfAbsent) and linear withoutComments works");

        // Verify synthetic 2423...2324... AES-128-CBC hex payload (extensionless subscription
        // format)
        String samplePlainJson =
                "{\"lives\":[{\"name\":\"CCTV\",\"type\":0,\"url\":\"https://live.example.test/a.m3u\"}],"
                        + "\"sites\":[{\"key\":\"db\",\"name\":\"豆瓣\",\"type\":3,\"api\":\"csp_Douban\","
                        + "\"jar\":\"https://cdn.example.test/a.jar\"},"
                        + "{\"key\":\"py1\",\"name\":\"Python站\",\"type\":3,\"api\":\"https://cdn.example.test/s.py\"}]}";
        javax.crypto.Cipher aesCipher = javax.crypto.Cipher.getInstance("AES/CBC/PKCS5Padding");
        aesCipher.init(
                javax.crypto.Cipher.ENCRYPT_MODE,
                new javax.crypto.spec.SecretKeySpec("djvrjbc000000000".getBytes("UTF-8"), "AES"),
                new javax.crypto.spec.IvParameterSpec("1795573087800000".getBytes("UTF-8")));
        byte[] encryptedBytes = aesCipher.doFinal(samplePlainJson.getBytes("UTF-8"));
        StringBuilder hexPayload = new StringBuilder();
        hexPayload.append("2423");
        for (byte b : "djvrjbc".getBytes("UTF-8")) {
            hexPayload.append(String.format(java.util.Locale.US, "%02x", b & 0xff));
        }
        hexPayload.append("2324");
        for (byte b : encryptedBytes) {
            hexPayload.append(String.format(java.util.Locale.US, "%02x", b & 0xff));
        }
        for (byte b : "1795573087800".getBytes("UTF-8")) {
            hexPayload.append(String.format(java.util.Locale.US, "%02x", b & 0xff));
        }
        String decodedDoc = Cms.document(hexPayload.toString().getBytes(StandardCharsets.UTF_8));
        Cms.Config decoded2423 =
                Cms.parseConfig(
                        decodedDoc,
                        "https://raw.githubusercontent.com/Jsnzkpg/Jsnzkpg/Jsnzkpg/Jsnzkpg");
        String buildMobilePy = readUtf8(root, "scripts/build_android_mobile.py");
        check(
                decoded2423.sites.size() == 2
                        && "https://cdn.example.test/a.jar".equals(decoded2423.sites.get(0).jar)
                        && NativePythonEngine.eligible(decoded2423.sites.get(1))
                        && "arm64-v8a"
                                .equals(
                                        NativePythonEngine.selectDynloadAbi(
                                                new String[] {"arm64-v8a", "armeabi-v7a"},
                                                true,
                                                true,
                                                true))
                        && "armeabi-v7a"
                                .equals(
                                        NativePythonEngine.selectDynloadAbi(
                                                new String[] {"arm64-v8a", "armeabi-v7a"},
                                                false,
                                                true,
                                                true))
                        && buildMobilePy.contains("build_mobile_python_runtime(")
                        && buildMobilePy.contains("verify_mobile_python_apk("),
                "Pillar 8 subscription guard: 2423 AES-CBC extensionless config decodes per-site JAR + Python sites, NativePythonEngine matches process bitness, and build_android_mobile builds & verifies bare libpython3.11.so link");
    }

    private static void test9_AuthorFirstLaunchNoticeAndContact(Path root) throws Exception {
        // 1. Canonical copy & official URL contract
        check(
                "PILIPALA来信".equals(MobileAuthorNotice.AUTHOR_SOCIAL_NAME)
                        && MobileAuthorNotice.SOCIAL_PLATFORMS.length == 5
                        && "小红书".equals(MobileAuthorNotice.SOCIAL_PLATFORMS[0])
                        && "B站".equals(MobileAuthorNotice.SOCIAL_PLATFORMS[1])
                        && "抖音".equals(MobileAuthorNotice.SOCIAL_PLATFORMS[2])
                        && "公众号".equals(MobileAuthorNotice.SOCIAL_PLATFORMS[3])
                        && "视频号".equals(MobileAuthorNotice.SOCIAL_PLATFORMS[4])
                        && "marcotv.wlj9919.top".equals(MobileAuthorNotice.OFFICIAL_SITE_DISPLAY)
                        && "https://marcotv.wlj9919.top"
                                .equals(MobileAuthorNotice.OFFICIAL_SITE_URL)
                        && "https://marcotv.wlj9919.top/movie/#donate"
                                .equals(MobileAuthorNotice.OFFICIAL_DONATE_URL)
                        && "https://pd.qq.com/s/N45e3aaawv?b=9"
                                .equals(MobileAuthorNotice.OFFICIAL_CHANNEL_URL)
                        && MobileAuthorNotice.OFFICIAL_DOWNLOAD_WARNING.contains("唯一")
                        && MobileAuthorNotice.OFFICIAL_DOWNLOAD_WARNING.contains("免费")
                        && MobileAuthorNotice.OFFICIAL_DOWNLOAD_WARNING.contains("谨防受骗")
                        && MobileAuthorNotice.OFFICIAL_DOWNLOAD_WARNING.contains("病毒"),
                "Pillar 9 author notice: canonical social handle, 5 platforms, official site/donate/channel URLs, and anti-scam warning match spec");

        // 2. Pure-JVM per-install & per-update Controller state machine
        final java.util.Map<String, Integer> mem = new java.util.HashMap<>();
        MobileAuthorNotice.Store store =
                new MobileAuthorNotice.Store() {
                    @Override
                    public int getInt(String key, int defaultValue) {
                        Integer v = mem.get(key);
                        return v != null ? v : defaultValue;
                    }

                    @Override
                    public void putInt(String key, int value) {
                        mem.put(key, value);
                    }
                };
        MobileAuthorNotice.Controller c1 = new MobileAuthorNotice.Controller(store, 103);
        check(
                c1.shouldShow(false, false)
                        && !c1.isUpgradeNotice()
                        && !c1.shouldShow(true, false)
                        && !c1.shouldShow(false, true),
                "Pillar 9 author notice: shows on fresh normal launch, suppressed in Privacy Space or when another blocking overlay is active");
        c1.markShown();
        check(
                !c1.shouldShow(false, false)
                        && store.getInt(MobileAuthorNotice.KEY_SEEN_VERSION, 0)
                                == MobileAuthorNotice.CURRENT_VERSION
                        && store.getInt(MobileAuthorNotice.KEY_SEEN_APP_VERSION_CODE, 0) == 103
                        && !new MobileAuthorNotice.Controller(store, 103).shouldShow(false, false),
                "Pillar 9 author notice: markShown persists versionCode and suppresses subsequent cold launches on same version");
        MobileAuthorNotice.Controller cUpgrade = new MobileAuthorNotice.Controller(store, 104);
        check(
                cUpgrade.shouldShow(false, false) && cUpgrade.isUpgradeNotice(),
                "Pillar 9 author notice: automatically re-shows once after every app versionCode upgrade");
        cUpgrade.markShown();
        check(
                !new MobileAuthorNotice.Controller(store, 104).shouldShow(false, false)
                        && store.getInt(MobileAuthorNotice.KEY_SEEN_APP_VERSION_CODE, 0) == 104,
                "Pillar 9 author notice: upgraded versionCode suppresses repeated launches until next update");

        // 3. Single-shot dismiss continuation guard
        final int[] count = {0};
        Runnable once = MobileAuthorNotice.singleShot(() -> count[0]++);
        once.run();
        once.run();
        once.run();
        check(
                count[0] == 1,
                "Pillar 9 author notice: singleShot continuation executes strictly once across Back/scrim/button dismiss");

        // 4. Strict official HTTPS URL whitelist
        check(
                MobileAuthorNotice.isTrustedOfficialUrl("https://marcotv.wlj9919.top")
                        && MobileAuthorNotice.isTrustedOfficialUrl(
                                "https://marcotv.wlj9919.top/movie/#donate")
                        && MobileAuthorNotice.isTrustedOfficialUrl(
                                "https://pd.qq.com/s/N45e3aaawv?b=9")
                        && !MobileAuthorNotice.isTrustedOfficialUrl("https://pd.qq.com/s/other")
                        && !MobileAuthorNotice.isTrustedOfficialUrl("http://marcotv.wlj9919.top")
                        && !MobileAuthorNotice.isTrustedOfficialUrl(
                                "https://marcotv.wlj9919.top.evil.test/")
                        && !MobileAuthorNotice.isTrustedOfficialUrl("https://evil.example/")
                        && !MobileAuthorNotice.isTrustedOfficialUrl(null)
                        && !MobileAuthorNotice.isTrustedOfficialUrl(""),
                "Pillar 9 author notice: isTrustedOfficialUrl permits only HTTPS marcotv.wlj9919.top paths and exact official Tencent channel");

        // 5. Settings search index coverage for all social platforms, channel, donate & site
        String[] socialQueries = {"PILIPALA来信", "小红书", "B站", "抖音", "公众号", "视频号", "反馈"};
        boolean allSocialHits = true;
        for (String q : socialQueries) {
            if (!hasHit(
                    MobileSettingsIndex.search(q),
                    MobileSettingsIndex.SUB_STORAGE,
                    "ms-author-social")) {
                allSocialHits = false;
            }
        }
        check(
                allSocialHits
                        && hasHit(
                                MobileSettingsIndex.search("交流频道"),
                                MobileSettingsIndex.SUB_STORAGE,
                                "ms-official-channel")
                        && hasHit(
                                MobileSettingsIndex.search("Marco交流区"),
                                MobileSettingsIndex.SUB_STORAGE,
                                "ms-official-channel")
                        && hasHit(
                                MobileSettingsIndex.search("捐赠"),
                                MobileSettingsIndex.SUB_STORAGE,
                                "ms-official-donate")
                        && hasHit(
                                MobileSettingsIndex.search("marcotv.wlj9919.top"),
                                MobileSettingsIndex.SUB_STORAGE,
                                "ms-official-site")
                        && Prefs.KEYS.length == 46,
                "Pillar 9 settings contact: search index resolves social handles, official channel, donation, and website while preserving Prefs.KEYS=46");

        // 6. Source wiring checks across MainActivity, CrashReportDialog, and MobileSettingsScreen
        String javaBase = "android-mobile/src/main/java/com/pilipala/marcomovie/";
        String mainSrc = readUtf8(root, javaBase + "MainActivity.java");
        String crashSrc = readUtf8(root, javaBase + "CrashReportDialog.java");
        String settingsSrc = readUtf8(root, javaBase + "MobileSettingsScreen.java");
        check(
                mainSrc.contains("MobileAuthorNotice.shouldShowFirstLaunch(")
                        && mainSrc.contains("MobileAuthorNotice.maybeShowFirstLaunch(")
                        && mainSrc.contains("MobileAuthorNotice.dismissActive()")
                        && crashSrc.contains("MobileAuthorNotice.isShowing()")
                        && settingsSrc.contains("\"ms-grp-contact\"")
                        && settingsSrc.contains("\"ms-author-social\"")
                        && settingsSrc.contains("\"ms-official-channel\"")
                        && settingsSrc.contains("\"ms-official-donate\"")
                        && settingsSrc.contains("\"ms-official-site\"")
                        && settingsSrc.contains("MobileAuthorNotice.showContactSheet("),
                "Pillar 9 wiring: MainActivity first-launch/destroy, CrashReportDialog guard, and MobileSettingsScreen contact/channel/donate entries are all connected");
    }

    public static void main(String[] args) throws Exception {
        Path root = args.length > 0 ? Paths.get(args[0]) : Paths.get(".");
        test1_MobileThemeAndPrefs(root);
        test2_MobileBottomSheetAndAntiHijack(root);
        test3_MobileFilterSheet(root);
        test4_SettingsCenterAndIconHygiene(root);
        test5_PlayerTouchHud(root);
        test6_MobileMotionPhysicsAndBenchmark();
        test7_UxFirstPrinciplesStateLogic();
        test8_StaticUxHygieneAndReviewerGuards(root);
        test9_AuthorFirstLaunchNoticeAndContact(root);
        System.out.println("MobileUiRedesignChecks OK (" + passed + " checks passed)");
    }
}
