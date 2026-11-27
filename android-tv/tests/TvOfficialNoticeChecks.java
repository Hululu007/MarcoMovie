package com.pilipala.marcomovie;

import java.util.HashMap;
import java.util.Map;

/**
 * Pure-JVM acceptance checks for {@link TvOfficialNotice}:
 * - Shows once on fresh install AND once again after every versionCode upgrade
 * - Never touches Prefs.KEYS (46 backup keys)
 * - Verifies exact official website, group, and donation URLs & required anti-scam / voluntary copy.
 */
public final class TvOfficialNoticeChecks {
    private static int checks;

    private static void check(boolean ok, String label) {
        if (!ok) throw new AssertionError("FAIL: " + label);
        checks++;
        System.out.println("PASS " + label);
    }

    private static final class MemoryStore implements OnboardingScreen.Store {
        final Map<String, Integer> ints = new HashMap<>();
        final Map<String, Boolean> bools = new HashMap<>();

        @Override
        public int getInt(String key, int defaultValue) {
            Integer v = ints.get(key);
            return v == null ? defaultValue : v;
        }

        @Override
        public void putInt(String key, int value) {
            ints.put(key, value);
        }

        @Override
        public boolean getBoolean(String key, boolean defaultValue) {
            Boolean v = bools.get(key);
            return v == null ? defaultValue : v;
        }

        @Override
        public void putBoolean(String key, boolean value) {
            bools.put(key, value);
        }
    }

    public static void main(String[] args) {
        MemoryStore store = new MemoryStore();

        // 1. Fresh install on versionCode 100 shows once
        check(
                TvOfficialNotice.Controller.shouldShowOnLaunch(store, 100),
                "fresh install (versionCode=100) shows post-update official notice");

        // 2. Marking seen suppresses subsequent launches on same versionCode 100
        TvOfficialNotice.Controller.markSeen(store, 100);
        check(
                !TvOfficialNotice.Controller.shouldShowOnLaunch(store, 100),
                "same versionCode=100 does not re-show after markSeen");

        // 3. Upgrading to versionCode 101 triggers notice once again!
        check(
                TvOfficialNotice.Controller.shouldShowOnLaunch(store, 101),
                "upgrading to versionCode=101 shows post-update official notice again");
        TvOfficialNotice.Controller.markSeen(store, 101);
        check(
                !TvOfficialNotice.Controller.shouldShowOnLaunch(store, 101),
                "second launch on versionCode=101 stays silent");

        // 4. Legacy v1 user (boolean true, versionCode 0) upgrading to 100 sees the new notice once
        MemoryStore legacyStore = new MemoryStore();
        legacyStore.putBoolean(TvOfficialNotice.KEY_FIRST_LAUNCH_NOTICE_SEEN_V1, true);
        check(
                TvOfficialNotice.Controller.shouldShowOnLaunch(legacyStore, 100),
                "legacy v1 user upgrading to versionCode=100 sees post-update notice once");

        // 5. Invalid/zero versionCode safely returns false
        check(
                !TvOfficialNotice.Controller.shouldShowOnLaunch(store, 0),
                "invalid versionCode=0 never loops notice");

        // 6. Official URLs & sincere anti-scam / sole-channel / voluntary-donation copy
        check(
                "https://marcotv.wlj9919.top".equals(TvOfficialNotice.OFFICIAL_SITE_URL)
                        && "https://marcotv.wlj9919.top/movie/#group"
                                .equals(TvOfficialNotice.OFFICIAL_GROUP_URL)
                        && "https://marcotv.wlj9919.top/movie/#donate"
                                .equals(TvOfficialNotice.OFFICIAL_DONATE_URL),
                "official site, community group, and donation anchor URLs match live site");
        check(
                TvOfficialNotice.SECURITY_REMINDER.contains("免费")
                        && TvOfficialNotice.SECURITY_REMINDER.contains("唯一")
                        && TvOfficialNotice.SECURITY_REMINDER.contains(
                                TvOfficialNotice.OFFICIAL_SITE_DISPLAY)
                        && TvOfficialNotice.SECURITY_REMINDER.contains("退款"),
                "anti-scam notice highlights free software, refund warning, and sole official channel");
        check(
                TvOfficialNotice.NOTICE_DONATE_BODY.contains("免费")
                        && TvOfficialNotice.NOTICE_DONATE_BODY.contains("不捐赠")
                        && TvOfficialNotice.DONATE_SECTION_BODY.contains("自愿")
                        && TvOfficialNotice.DONATE_SECTION_BODY.contains("不捐赠"),
                "donation copy stays warm, voluntary, and explicitly guarantees zero feature lock");

        // 7. Backup key isolation: neither notice key is inside SettingsScreen.KEYS
        for (String k : SettingsScreen.KEYS) {
            check(
                    !TvOfficialNotice.KEY_NOTICE_SEEN_VERSION_CODE.equals(k)
                            && !TvOfficialNotice.KEY_FIRST_LAUNCH_NOTICE_SEEN_V1.equals(k),
                    "notice pref key not mixed into SettingsScreen.KEYS: " + k);
        }

        System.out.println("ALL PASS (" + checks + " TvOfficialNotice checks)");
    }
}
