package com.pilipala.marcomovie;

import android.content.Context;
import android.os.Environment;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * Bidirectional netdisk credential bridge between native {@link NetdiskStore} ("我的云盘") and
 * recognized subscription Config Center spiders / CatPaw runtime files.
 *
 * <p>Mirrors iOS 0.7.7 {@code lib/core/config_center_bridge.dart} {@code ConfigCenterBridge.syncAll}:
 *
 * <ul>
 *   <li>Scanning once in the player or "我的云盘" writes to app-private {@link NetdiskStore} and
 *       pushes credentials to all app-private spider/CatPaw config files (zero external storage
 *       permission required; best-effort mirrors to {@code /sdcard/TV} only if already writable).
 *   <li>Logging in via a subscription Config Center (or local/LAN config web page) syncs recognized
 *       credentials back into {@link NetdiskStore} so "我的云盘" & "我的文件" recognize them too.
 *   <li>Existing valid logged-in accounts are NEVER silently overwritten by stale external configs
 *       unless {@code overwriteExisting == true} (explicit user submission).
 * </ul>
 */
final class ConfigCenterBridge {
    static final class SyncReport {
        final int detectedCenters;
        final List<String> importedDrives = new ArrayList<>();
        final List<String> skippedExistingDrives = new ArrayList<>();
        final List<String> pushedFiles = new ArrayList<>();
        boolean importedOrder;
        boolean skippedExistingOrder;

        SyncReport(int detectedCenters) {
            this.detectedCenters = detectedCenters;
        }
    }

    private static volatile String lastPushedJson = "";

    private ConfigCenterBridge() {}

    static boolean isConfigCenterSite(Cms.Site site) {
        if (site == null) return false;
        if (AccountPanel.isLikelyConfigCenterSite(site)) return true;
        String api = site.api == null ? "" : site.api.toLowerCase(Locale.ROOT);
        String key = site.key == null ? "" : site.key.toLowerCase(Locale.ROOT);
        String name = site.name == null ? "" : site.name;
        return api.contains("/api/baseset")
                || api.contains("csp_config")
                || key.contains("csp_config")
                || name.contains("网盘配置")
                || name.contains("云盘配置");
    }

    static List<Cms.Site> detectConfigCenters(Cms.Config config) {
        List<Cms.Site> out = new ArrayList<>();
        if (config == null || config.sites == null) return out;
        for (Cms.Site site : config.sites) {
            if (isConfigCenterSite(site)) out.add(site);
        }
        return out;
    }

    static SyncReport syncAll(
            Context context,
            Cms.Config config,
            boolean pullFromExternal,
            boolean pushToExternal,
            boolean overwriteExisting) {
        if (context == null) return new SyncReport(0);
        Context app = context.getApplicationContext();
        NetdiskStore.KeyValueStore store = NetdiskStore.storeFor(app);
        List<File> writableDirs = collectRuntimeDirs(app, true);
        List<File> readableDirs = collectRuntimeDirs(app, false);
        return syncAll(
                store,
                readableDirs,
                writableDirs,
                config,
                pullFromExternal,
                pushToExternal,
                overwriteExisting);
    }

    /** Pure-JVM testable entrypoint for bidirectional Config Center sync & conflict protection. */
    static SyncReport syncAll(
            NetdiskStore.KeyValueStore store,
            List<File> readableDirs,
            List<File> writableDirs,
            Cms.Config config,
            boolean pullFromExternal,
            boolean pushToExternal,
            boolean overwriteExisting) {
        List<Cms.Site> centers = detectConfigCenters(config);
        SyncReport report = new SyncReport(centers.size());
        if (store == null) return report;

        if (pullFromExternal) {
            Map<String, String> discovered = new LinkedHashMap<>();
            List<String> discoveredOrder = null;

            // 1. Prefer fresher local plugin / CatPaw runtime files over static subscription ext.
            if (readableDirs != null) {
                for (File dir : readableDirs) {
                    if (dir == null || !dir.isDirectory()) continue;
                    Map<String, String> fromFiles = readCredentialsFromDirectory(dir);
                    for (Map.Entry<String, String> e : fromFiles.entrySet()) {
                        if ("order".equals(e.getKey())) {
                            if (discoveredOrder == null) {
                                discoveredOrder = NetdiskStore.parseOrder(e.getValue());
                            }
                        } else if (!discovered.containsKey(e.getKey())) {
                            discovered.put(e.getKey(), e.getValue());
                        }
                    }
                }
            }

            // 2. Fill remaining empty drives from recognized subscription Config Center site.ext.
            for (Cms.Site site : centers) {
                if (site == null || site.ext == null) continue;
                String extPayload = String.valueOf(site.ext).trim();
                if (extPayload.isEmpty()) continue;
                Map<String, String> fromExt = extractCredentialsFromPayload(extPayload);
                for (Map.Entry<String, String> e : fromExt.entrySet()) {
                    if ("order".equals(e.getKey())) {
                        if (discoveredOrder == null) {
                            discoveredOrder = NetdiskStore.parseOrder(e.getValue());
                        }
                    } else if (!discovered.containsKey(e.getKey())) {
                        discovered.put(e.getKey(), e.getValue());
                    }
                }
            }

            // 3. Apply conflict-protected import: never overwrite an existing valid account unless
            // overwriteExisting is explicitly requested.
            for (Map.Entry<String, String> e : discovered.entrySet()) {
                String drive = NetdiskStore.normalizeDriveKey(e.getKey());
                String val = e.getValue();
                if (drive.isEmpty() || !NetdiskStore.isCredentialUsable(drive, val)) continue;
                if (NetdiskStore.isLoggedIn(store, drive) && !overwriteExisting) {
                    report.skippedExistingDrives.add(drive);
                    continue;
                }
                if (NetdiskStore.setCredential(store, drive, val, "")) {
                    report.importedDrives.add(drive);
                }
            }

            if (discoveredOrder != null) {
                if (overwriteExisting || NetdiskStore.isDefaultOrder(store)) {
                    NetdiskStore.setOrder(store, discoveredOrder);
                    report.importedOrder = true;
                } else {
                    report.skippedExistingOrder = true;
                }
            }
        }

        if (pushToExternal && writableDirs != null && !writableDirs.isEmpty()) {
            pushCredentialsToDirectories(store, writableDirs, null, false, report);
        }

        return report;
    }

    /**
     * Pushes only the specified authorized drive(s) into external config files via field-level JSON
     * merge, preserving all other drives, unknown fields, and user-customized values.
     */
    static SyncReport pushAuthorizedDrives(
            Context context,
            Cms.Config config,
            java.util.Collection<String> drives,
            boolean updateOrder) {
        if (context == null) return new SyncReport(0);
        Context app = context.getApplicationContext();
        NetdiskStore.KeyValueStore store = NetdiskStore.storeFor(app);
        List<File> writableDirs = collectRuntimeDirs(app, true);
        SyncReport report = new SyncReport(detectConfigCenters(config).size());
        if (writableDirs != null && !writableDirs.isEmpty()) {
            java.util.Set<String> filter = new java.util.LinkedHashSet<>();
            if (drives != null) {
                for (String d : drives) {
                    String norm = NetdiskStore.normalizeDriveKey(d);
                    if (!norm.isEmpty()) filter.add(norm);
                }
            }
            pushCredentialsToDirectories(store, writableDirs, filter, updateOrder, report);
        }
        return report;
    }

    /**
     * Imports credentials explicitly submitted by the user (e.g. via local/LAN config web page or
     * manual config dialog). Only non-empty valid fields are written; omitted/blank fields NEVER
     * erase or overwrite already logged-in accounts.
     */
    static SyncReport applyUserSubmission(
            NetdiskStore.KeyValueStore store,
            List<File> writableDirs,
            Cms.Config config,
            Map<String, String> submittedDrives,
            String submittedOrder) {
        List<Cms.Site> centers = detectConfigCenters(config);
        SyncReport report = new SyncReport(centers.size());
        if (store == null) return report;

        java.util.Set<String> updatedDrives = new java.util.LinkedHashSet<>();
        if (submittedDrives != null) {
            for (Map.Entry<String, String> e : submittedDrives.entrySet()) {
                String drive = NetdiskStore.normalizeDriveKey(e.getKey());
                String val = e.getValue() == null ? "" : e.getValue().trim();
                if (drive.isEmpty() || val.isEmpty()) continue;
                if (!NetdiskStore.isCredentialUsable(drive, val)) continue;
                if (NetdiskStore.setCredential(store, drive, val, "")) {
                    report.importedDrives.add(drive);
                    updatedDrives.add(drive);
                }
            }
        }
        if (submittedOrder != null && !submittedOrder.trim().isEmpty()) {
            NetdiskStore.setOrder(store, NetdiskStore.parseOrder(submittedOrder));
            report.importedOrder = true;
        }
        if (writableDirs != null
                && !writableDirs.isEmpty()
                && (!updatedDrives.isEmpty() || report.importedOrder)) {
            pushCredentialsToDirectories(
                    store, writableDirs, updatedDrives, report.importedOrder, report);
        }
        return report;
    }

    /** Builds the canonical CatPaw / WEX Config Center JSON payload matching iOS 0.7.7. */
    static String buildPanConfigJson(NetdiskStore.KeyValueStore store) {
        return mergeIntoExistingPanConfigJson("", store, null, true);
    }

    /**
     * Merges only the specified authorized drive fields into an existing config JSON document,
     * preserving all other drives (e.g. 115, pikpak, tianyi), unknown top-level/nested keys, and
     * user-customized values.
     */
    static String mergeIntoExistingPanConfigJson(
            String existingJson,
            NetdiskStore.KeyValueStore store,
            java.util.Set<String> drivesToUpdate,
            boolean updateOrder) {
        try {
            JSONObject root;
            boolean hadExisting = false;
            String trimmed = existingJson == null ? "" : existingJson.trim();
            if (trimmed.startsWith("{")) {
                root = new JSONObject(trimmed);
                hadExisting = true;
            } else {
                root = new JSONObject();
            }

            JSONObject pan = root.optJSONObject("pan");
            if (pan == null) {
                pan = new JSONObject();
                root.put("pan", pan);
            }

            java.util.Set<String> effective =
                    collectEffectiveAuthorizedDrives(store, drivesToUpdate);
            for (String drive : effective) {
                String cred = NetdiskStore.getCredential(store, drive);
                if (!NetdiskStore.isCredentialUsable(drive, cred)) continue;
                JSONObject driveObj = pan.optJSONObject(drive);
                if (driveObj == null) {
                    driveObj = new JSONObject();
                    pan.put(drive, driveObj);
                }
                if (NetdiskStore.DRIVE_ALI.equals(drive)) {
                    String aliBare = NetdiskStore.extractAliRefreshToken(cred);
                    driveObj.put("token", aliBare);
                    driveObj.put("cookie", cred);
                    if (!aliBare.isEmpty()) root.put("ali_token", aliBare);
                } else {
                    driveObj.put("cookie", cred);
                    if (NetdiskStore.DRIVE_QUARK.equals(drive)) {
                        root.put("quark_cookie", cred);
                    } else if (NetdiskStore.DRIVE_UC.equals(drive)) {
                        root.put("uc_cookie", cred);
                    } else if (NetdiskStore.DRIVE_BAIDU.equals(drive)) {
                        root.put("baidu_cookie", cred);
                    }
                }
            }

            boolean shouldWriteOrder =
                    updateOrder
                            || (!hadExisting
                                    && !root.has("order")
                                    && !root.has("panOrder")
                                    && !NetdiskStore.isDefaultOrder(store));
            if (shouldWriteOrder) {
                List<String> order = NetdiskStore.getOrder(store);
                JSONArray orderArr = new JSONArray();
                StringBuilder orderCsv = new StringBuilder();
                for (int i = 0; i < order.size(); i++) {
                    orderArr.put(order.get(i));
                    if (i > 0) orderCsv.append(',');
                    orderCsv.append(order.get(i));
                }
                root.put("order", orderArr);
                root.put("panOrder", orderCsv.toString());
            }
            return root.toString();
        } catch (Exception e) {
            return existingJson != null && !existingJson.trim().isEmpty() ? existingJson : "{}";
        }
    }

    private static java.util.Set<String> collectEffectiveAuthorizedDrives(
            NetdiskStore.KeyValueStore store, java.util.Set<String> drivesFilter) {
        java.util.Set<String> out = new java.util.LinkedHashSet<>();
        if (store == null) return out;
        java.util.Collection<String> candidates =
                drivesFilter != null ? drivesFilter : NetdiskStore.DEFAULT_ORDER;
        for (String raw : candidates) {
            String drive = NetdiskStore.normalizeDriveKey(raw);
            if (!drive.isEmpty() && NetdiskStore.isLoggedIn(store, drive)) {
                out.add(drive);
            }
        }
        return out;
    }

    private static void pushCredentialsToDirectories(
            NetdiskStore.KeyValueStore store,
            List<File> dirs,
            java.util.Set<String> drivesFilter,
            boolean updateOrder,
            SyncReport report) {
        java.util.Set<String> effective = collectEffectiveAuthorizedDrives(store, drivesFilter);
        if (effective.isEmpty() && !updateOrder) {
            return;
        }
        List<String> order = NetdiskStore.getOrder(store);
        StringBuilder orderCsv = new StringBuilder();
        for (int i = 0; i < order.size(); i++) {
            if (i > 0) orderCsv.append(',');
            orderCsv.append(order.get(i));
        }
        String orderText = orderCsv.toString();
        String lastMerged = "";

        for (File dir : dirs) {
            if (dir == null) continue;
            try {
                if (!dir.exists() && !dir.mkdirs()) continue;
                if (!dir.isDirectory() || !dir.canWrite()) continue;
                for (String jsonName : new String[] {"wexfnwconfig.json", "config_center.json"}) {
                    File jsonFile = new File(dir, jsonName);
                    String existing = readSmallText(jsonFile);
                    // Preserve corrupted/non-JSON custom files rather than destroying them silently
                    if (!existing.isEmpty() && !existing.trim().startsWith("{")) continue;
                    String merged =
                            mergeIntoExistingPanConfigJson(existing, store, effective, updateOrder);
                    lastMerged = merged;
                    if (existing.isEmpty() || !existing.equals(merged)) {
                        writeAtomic(jsonFile, merged, report);
                    }
                }
                for (String drive : effective) {
                    String val = NetdiskStore.getCredential(store, drive);
                    if (!NetdiskStore.isCredentialUsable(drive, val)) continue;
                    if (NetdiskStore.DRIVE_QUARK.equals(drive)) {
                        writeCompatFileIfPresent(new File(dir, "quark_cookie.txt"), val, report);
                        writeCompatFileIfPresent(new File(dir, "quark.txt"), val, report);
                    } else if (NetdiskStore.DRIVE_UC.equals(drive)) {
                        writeCompatFileIfPresent(new File(dir, "uc_cookie.txt"), val, report);
                        writeCompatFileIfPresent(new File(dir, "uc.txt"), val, report);
                    } else if (NetdiskStore.DRIVE_BAIDU.equals(drive)) {
                        writeCompatFileIfPresent(new File(dir, "baidu_cookie.txt"), val, report);
                        writeCompatFileIfPresent(new File(dir, "baidu.txt"), val, report);
                    } else if (NetdiskStore.DRIVE_ALI.equals(drive)) {
                        String aliBare = NetdiskStore.extractAliRefreshToken(val);
                        writeCompatFileIfPresent(new File(dir, "ali_token.txt"), aliBare, report);
                        writeCompatFileIfPresent(new File(dir, "token.txt"), aliBare, report);
                    }
                }
                if (updateOrder && !orderText.isEmpty()) {
                    writeCompatFileIfPresent(new File(dir, "pan_order.txt"), orderText, report);
                }
            } catch (Throwable ignored) {
            }
        }
        if (!lastMerged.isEmpty()) {
            lastPushedJson = lastMerged;
        }
    }

    static String lastPushedPayload() {
        return lastPushedJson;
    }

    private static void writeCompatFileIfPresent(File file, String content, SyncReport report)
            throws IOException {
        if (content == null || content.trim().isEmpty()) {
            return;
        }
        writeAtomic(file, content, report);
    }

    private static void writeAtomic(File target, String content, SyncReport report)
            throws IOException {
        File parent = target.getParentFile();
        if (parent != null && !parent.exists()) parent.mkdirs();
        File tmp = new File(parent, target.getName() + ".tmp." + Thread.currentThread().getId());
        try (FileOutputStream fos = new FileOutputStream(tmp)) {
            fos.write(content.getBytes(StandardCharsets.UTF_8));
            fos.getFD().sync();
        } catch (IOException syncFallback) {
            // Some filesystems do not support fsync; write cleanly without failing.
            try (FileOutputStream fos = new FileOutputStream(tmp)) {
                fos.write(content.getBytes(StandardCharsets.UTF_8));
            }
        }
        if (!tmp.renameTo(target)) {
            if (target.exists()) target.delete();
            if (!tmp.renameTo(target)) {
                try (FileOutputStream fos = new FileOutputStream(target)) {
                    fos.write(content.getBytes(StandardCharsets.UTF_8));
                } finally {
                    tmp.delete();
                }
            }
        }
        if (report != null) report.pushedFiles.add(target.getAbsolutePath());
    }

    static List<File> collectRuntimeDirs(Context app, boolean forWrite) {
        List<File> out = new ArrayList<>();
        if (app == null) return out;
        try {
            File files = app.getFilesDir();
            if (files != null) {
                out.add(new File(files, "TV"));
                out.add(new File(files, "catpaw"));
                out.add(new File(new File(files, "catpaw"), "state"));
                if (!forWrite) out.add(files);
            }
            File extFiles = app.getExternalFilesDir(null);
            if (extFiles != null) {
                out.add(new File(extFiles, "TV"));
                if (!forWrite) out.add(extFiles);
            }
            File dbTv = app.getDatabasePath("tv");
            if (dbTv != null && dbTv.getParentFile() != null) {
                out.add(new File(dbTv.getParentFile(), "tv_config"));
            }
            if (!forWrite && app.getCacheDir() != null) {
                out.add(app.getCacheDir());
                out.add(new File(app.getCacheDir(), "TV"));
            }
            // Best-effort external /sdcard/TV ONLY when already granted & writable — NEVER prompts!
            if (CspEngine.hasGrantedAllFilesAccess()) {
                try {
                    File extRoot = Environment.getExternalStorageDirectory();
                    if (extRoot != null) {
                        File sharedTv = new File(extRoot, "TV");
                        if (!forWrite
                                || (sharedTv.exists() ? sharedTv.canWrite() : extRoot.canWrite())) {
                            out.add(sharedTv);
                        }
                    }
                } catch (Throwable ignored) {
                }
            }
        } catch (Throwable ignored) {
        }
        return out;
    }

    static Map<String, String> readCredentialsFromDirectory(File dir) {
        Map<String, String> out = new LinkedHashMap<>();
        if (dir == null || !dir.isDirectory()) return out;

        // JSON config files first (richest structured source)
        for (String name : new String[] {"wexfnwconfig.json", "config_center.json"}) {
            File f = new File(dir, name);
            String txt = readSmallText(f);
            if (!txt.isEmpty()) {
                Map<String, String> parsed = extractCredentialsFromPayload(txt);
                for (Map.Entry<String, String> e : parsed.entrySet()) {
                    if (!out.containsKey(e.getKey())) out.put(e.getKey(), e.getValue());
                }
            }
        }

        // Plaintext compat files
        readCompatDrive(
                dir,
                out,
                NetdiskStore.DRIVE_QUARK,
                "quark_cookie.txt",
                "quark.txt",
                ".quark",
                "quark_cookie");
        readCompatDrive(
                dir,
                out,
                NetdiskStore.DRIVE_UC,
                "uc_cookie.txt",
                "uc.txt",
                ".uc",
                "uc_cookie",
                "uc_token.txt");
        readCompatDrive(
                dir,
                out,
                NetdiskStore.DRIVE_BAIDU,
                "baidu_cookie.txt",
                "baidu.txt",
                ".baidu",
                "bd_cookie.txt");
        readCompatDrive(
                dir,
                out,
                NetdiskStore.DRIVE_ALI,
                "ali_token.txt",
                "ali.txt",
                ".ali",
                "aliyundrive.txt",
                "token.txt",
                "alipan.txt");

        if (!out.containsKey("order")) {
            String orderText = readSmallText(new File(dir, "pan_order.txt"));
            if (!orderText.isEmpty()) out.put("order", orderText);
        }
        return out;
    }

    private static void readCompatDrive(
            File dir, Map<String, String> out, String driveKey, String... names) {
        if (out.containsKey(driveKey)) return;
        for (String name : names) {
            String raw = readSmallText(new File(dir, name));
            if (NetdiskStore.isCredentialUsable(driveKey, raw)) {
                out.put(driveKey, NetdiskStore.normalizeCredential(driveKey, raw));
                return;
            }
        }
    }

    private static String readSmallText(File f) {
        if (f == null || !f.isFile() || f.length() <= 0 || f.length() > 256 * 1024) return "";
        try (FileInputStream fis = new FileInputStream(f)) {
            ByteArrayOutputStream bos = new ByteArrayOutputStream();
            byte[] buf = new byte[4096];
            int n;
            while ((n = fis.read(buf)) != -1) bos.write(buf, 0, n);
            return new String(bos.toByteArray(), StandardCharsets.UTF_8).trim();
        } catch (Throwable ignored) {
            return "";
        }
    }

    /**
     * Recursively extracts usable netdisk credentials and optional drive order from a JSON payload
     * (up to depth 4, matching iOS {@code ConfigCenterBridge.extractCredentialsFromPayload}).
     */
    static Map<String, String> extractCredentialsFromPayload(String rawPayload) {
        Map<String, String> out = new LinkedHashMap<>();
        if (rawPayload == null) return out;
        String trimmed = rawPayload.trim();
        if (!trimmed.startsWith("{")) return out;
        try {
            JSONObject obj = new JSONObject(trimmed);
            walkJsonObject(obj, 0, out);
        } catch (Exception ignored) {
        }
        return out;
    }

    private static void walkJsonObject(JSONObject obj, int depth, Map<String, String> out) {
        if (obj == null || depth > 4) return;
        Iterator<String> keys = obj.keys();
        while (keys.hasNext()) {
            String k = keys.next();
            if (k == null || obj.isNull(k)) continue;
            Object val = obj.opt(k);
            String lower = k.trim().toLowerCase(Locale.ROOT);

            if ("order".equals(lower)
                    || "panorder".equals(lower)
                    || "pan_order".equals(lower)
                    || "driveorder".equals(lower)
                    || "drive_order".equals(lower)) {
                if (!out.containsKey("order")) {
                    String orderCsv = extractOrderString(val);
                    if (!orderCsv.isEmpty()) out.put("order", orderCsv);
                }
                continue;
            }

            String drive = NetdiskStore.normalizeDriveKey(lower);
            if (!drive.isEmpty()) {
                String candidate = extractCredentialValue(drive, val);
                if (!candidate.isEmpty() && !out.containsKey(drive)) {
                    out.put(drive, NetdiskStore.normalizeCredential(drive, candidate));
                }
                continue;
            }

            if (val instanceof JSONObject
                    && ("pan".equals(lower)
                            || "pans".equals(lower)
                            || "drives".equals(lower)
                            || "netdisk".equals(lower)
                            || "accounts".equals(lower)
                            || "config".equals(lower)
                            || "data".equals(lower))) {
                walkJsonObject((JSONObject) val, depth + 1, out);
            }
        }
    }

    private static String extractCredentialValue(String driveKey, Object val) {
        if (val instanceof String) {
            String s = ((String) val).trim();
            return NetdiskStore.isCredentialUsable(driveKey, s) ? s : "";
        }
        if (val instanceof JSONObject) {
            JSONObject o = (JSONObject) val;
            for (String field :
                    new String[] {"cookie", "token", "refresh_token", "refreshToken", "value"}) {
                String s = o.optString(field, "").trim();
                if (NetdiskStore.isCredentialUsable(driveKey, s)) return s;
            }
        }
        return "";
    }

    private static String extractOrderString(Object val) {
        if (val instanceof String) return ((String) val).trim();
        if (val instanceof JSONArray) {
            JSONArray arr = (JSONArray) val;
            StringBuilder sb = new StringBuilder();
            for (int i = 0; i < arr.length(); i++) {
                String s = arr.optString(i, "").trim();
                if (!s.isEmpty()) {
                    if (sb.length() > 0) sb.append(',');
                    sb.append(s);
                }
            }
            return sb.toString();
        }
        return "";
    }

    static List<String> listNonEmptyDrives(Map<String, String> creds) {
        if (creds == null || creds.isEmpty()) return Collections.emptyList();
        List<String> list = new ArrayList<>();
        for (String d : NetdiskStore.DEFAULT_ORDER) {
            if (creds.containsKey(d)) list.add(d);
        }
        return list;
    }
}
