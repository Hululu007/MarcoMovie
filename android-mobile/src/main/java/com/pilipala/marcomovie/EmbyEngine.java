package com.pilipala.marcomovie;

import org.json.*;

final class EmbyEngine implements SourceEngine {
    private final MobileEmbyLibrary library;

    EmbyEngine(MainActivity activity, Cms.Site site) throws Exception {
        library = MobileEmbyAccounts.open(activity, site.api);
    }

    static void connect(MainActivity a) {
        MobileEmbyAccounts.connect(
                a,
                site -> {
                    SourceController.mergeOrSaveConfig(
                            a,
                            Cms.parseConfig(
                                    new JSONObject()
                                            .put("sites", new JSONArray().put(site))
                                            .toString(),
                                    ""),
                            "",
                            true);
                    openEmbySite(a, site);
                });
    }

    static void openManager(final MainActivity a) {
        if (a == null || a.isFinishing()) return;
        final java.util.List<JSONObject> saved = MobileEmbyAccounts.listSaved(a);
        if (saved.isEmpty()) {
            connect(a);
            return;
        }
        String[] labels = new String[saved.size() + 1];
        for (int i = 0; i < saved.size(); i++) {
            JSONObject s = saved.get(i);
            labels[i] = s.optString("name", "Emby") + "  (" + s.optString("base", "") + ")";
        }
        labels[saved.size()] = "＋ 添加新的 Emby 媒体库";
        new AppDialog.Builder(a)
                .setTitle("Emby 媒体库管理")
                .setItems(
                        labels,
                        (d, which) -> {
                            if (which == saved.size()) {
                                connect(a);
                            } else if (which >= 0 && which < saved.size()) {
                                showEmbyActions(a, saved.get(which));
                            }
                        })
                .setNegativeButton("关闭", null)
                .show();
    }

    private static void showEmbyActions(final MainActivity a, final JSONObject siteJson) {
        final String name = siteJson.optString("name", "Emby");
        final String api = siteJson.optString("api", "");
        new AppDialog.Builder(a)
                .setTitle(name)
                .setItems(
                        new String[] {"立即进入媒体库", "移除此 Emby 连接"},
                        (d, which) -> {
                            if (which == 0) {
                                openEmbySite(a, siteJson);
                            } else if (which == 1) {
                                MobileEmbyAccounts.remove(a, api);
                                if (a.config != null && a.config.sites != null) {
                                    for (java.util.Iterator<Cms.Site> it =
                                                    a.config.sites.iterator();
                                            it.hasNext(); ) {
                                        Cms.Site s = it.next();
                                        if (s != null && api.equals(s.api)) it.remove();
                                    }
                                }
                                a.closeEngines();
                                a.toast("已移除 " + name);
                                a.refresh();
                            }
                        })
                .setNegativeButton("返回", (d, w) -> openManager(a))
                .show();
    }

    private static void openEmbySite(MainActivity a, JSONObject siteJson) {
        if (a == null || siteJson == null) return;
        String api = siteJson.optString("api", "");
        Cms.Site target = findOrAttachEmbySite(a, siteJson);
        if (target != null) {
            final Cms.Site chosen = target;
            a.prefs.edit().putString(Prefs.SELECTED_SITE, chosen.key).apply();
            a.open(new MainActivity.Screen(() -> a.videos(chosen, "", chosen.name, 1, null)), true);
        }
    }

    private static Cms.Site findOrAttachEmbySite(MainActivity a, JSONObject siteJson) {
        String api = siteJson.optString("api", "");
        String key = siteJson.optString("key", "");
        if (a.config != null && a.config.sites != null) {
            for (Cms.Site s : a.config.sites) {
                if (s != null && (api.equals(s.api) || key.equals(s.key))) return s;
            }
        }
        Cms.Site s = new Cms.Site();
        s.key = key;
        s.name = siteJson.optString("name", "Emby");
        s.type = 1;
        s.api = api;
        s.searchable = true;
        s.group = "个人媒体库";
        if (a.config != null && a.config.sites != null) {
            a.config.sites.add(s);
        }
        return s;
    }

    /**
     * Re-attaches all persisted Emby & AList libraries into the active {@link Cms.Config} so
     * personal media libraries survive app restarts and remote subscription refreshes!
     */
    static void reattachSavedLibraries(MainActivity a, Cms.Config config) {
        if (a == null || config == null || config.sites == null) return;
        java.util.Set<String> existingApis = new java.util.HashSet<String>();
        for (Cms.Site s : config.sites) {
            if (s != null && s.api != null) existingApis.add(s.api);
        }
        try {
            for (JSONObject embySite : MobileEmbyAccounts.listSaved(a)) {
                String api = embySite.optString("api", "");
                if (api.isEmpty() || existingApis.contains(api)) continue;
                Cms.Site s = new Cms.Site();
                s.key = embySite.optString("key", "");
                s.name = embySite.optString("name", "Emby");
                s.type = 1;
                s.api = api;
                s.searchable = true;
                s.group = "个人媒体库";
                config.sites.add(s);
                existingApis.add(api);
            }
        } catch (Throwable ignored) {
        }
        try {
            for (AlistEngine.MountConfig mount : AlistAccounts.list(a)) {
                String api = mount.apiUri();
                if (api.isEmpty() || existingApis.contains(api)) continue;
                Cms.Site s = new Cms.Site();
                s.key = mount.siteKey();
                s.name = "AList · " + mount.name;
                s.type = 4;
                s.api = api;
                s.searchable = true;
                s.group = "个人媒体库";
                config.sites.add(s);
                existingApis.add(api);
            }
        } catch (Throwable ignored) {
        }
    }

    public String home() throws Exception {
        return library.home().toString();
    }

    public String homeVideos() throws Exception {
        return library.list("", "", 1).toString();
    }

    public String category(String id, int page) throws Exception {
        return library.list(id, "", page).toString();
    }

    public String search(String term, int page) throws Exception {
        return library.list("", term, page).toString();
    }

    public String detail(String id) throws Exception {
        return library.detail(id).toString();
    }

    public String player(String flag, String id) throws Exception {
        return library.resolve(id, false).toString();
    }

    public boolean requiresExternalRuntime() {
        return false;
    }
}
