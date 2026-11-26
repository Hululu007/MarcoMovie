package com.pilipala.marcomovie;

import android.content.Context;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.net.URLDecoder;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * Native 4-provider personal netdisk library client (Quark, UC, Baidu, Ali / Alipan).
 *
 * <p>Direct Java port of iOS 0.7.7 {@code lib/core/personal_netdisk_library.dart}:
 *
 * <ul>
 *   <li>Handles folder listing, pagination (page-indexed and Ali cursor-based), and playable stream
 *       resolution for all 4 personal drives.
 *   <li>Persists rotated Ali {@code refresh_token} automatically into {@link NetdiskStore}.
 *   <li>Encodes canonical credential-free {@code mmcloudlib://play?...&account=<accountId>} item
 *       IDs and enforces strict account isolation on {@link #resolveFile} and Favorites/WatchHistory
 *       opening so switching accounts NEVER opens a same-named file belonging to another account.
 *   <li>Distinguishes auth-expired failures ({@link PersonalCloudException#requiresReauth}) from
 *       transient errors so page-2 auth expiry preserves page-1 items and offers re-authorization.
 *   <li>Routes Quark/UC/Baidu authenticated streams through {@link CloudMediaProxy} with live
 *       {@link CloudMediaProxy.AccessGuard} account revocation.
 * </ul>
 */
final class PersonalNetdiskLibrary {
    static final String SCHEME_PLAY = "mmcloudlib://play";
    static final String SITE_PREFIX = "cloudlib_";

    private static final String QUARK_UA =
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) quark-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.4-b478491100 Safari/537.36 Channel/pckk_other_ch";
    private static final String UC_UA =
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) uc-cloud-drive/2.5.20 Chrome/100.0.4896.160 Safari/537.36";
    private static final String BAIDU_WEB_UA =
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36";
    private static final String BAIDU_MEDIA_UA = "netdisk;P2SP;2.2.91.136;android-android";
    private static final String ALI_CANARY = "client=Android,app=adrive,version=v4.1.4";

    private static final Set<String> VIDEO_EXTS = new HashSet<>();

    static {
        String[] exts = {
            "mp4", "mkv", "avi", "mov", "wmv", "flv", "webm", "ts", "m2ts", "mts", "m4v", "mpg",
            "mpeg", "rmvb", "rm", "vob", "3gp", "f4v", "iso", "m3u8"
        };
        Collections.addAll(VIDEO_EXTS, exts);
    }

    static final class Endpoints {
        String quarkDriveBase = "https://drive-pc.quark.cn";
        String quarkReferer = "https://pan.quark.cn/";

        String ucApiBase = "https://pc-api.uc.cn";
        String ucOrigin = "https://drive.uc.cn";

        String baiduPanBase = "https://pan.baidu.com";
        String baiduPcsBase = "https://d.pcs.baidu.com";

        String aliAuthBase = "https://auth.aliyundrive.com";
        String aliApiBase = "https://api.aliyundrive.com";
        String aliPdsBase = "https://bj29.api.aliyunpds.com";
        String aliReferer = "https://www.aliyundrive.com/";
    }

    static final class PersonalCloudException extends IOException {
        final String code;
        final boolean requiresReauth;

        PersonalCloudException(String code, String message, boolean requiresReauth) {
            super(message);
            this.code = code == null ? "error" : code;
            this.requiresReauth = requiresReauth;
        }
    }

    static final class CloudItem {
        final String provider;
        final String fid;
        final String name;
        final String path;
        final String driveId;
        final String accountId;
        final boolean directory;
        final long sizeBytes;
        final String thumbnailUrl;

        CloudItem(
                String provider,
                String fid,
                String name,
                String path,
                String driveId,
                String accountId,
                boolean directory,
                long sizeBytes,
                String thumbnailUrl) {
            this.provider = provider;
            this.fid = fid == null ? "" : fid;
            this.name = name == null ? "" : name;
            this.path = path == null ? "" : path;
            this.driveId = driveId == null ? "" : driveId;
            this.accountId = accountId == null ? "" : accountId;
            this.directory = directory;
            this.sizeBytes = Math.max(0L, sizeBytes);
            this.thumbnailUrl = thumbnailUrl == null ? "" : thumbnailUrl;
        }

        String canonicalPlayId() {
            return buildCanonicalPlayId(provider, accountId, driveId, fid, path, name);
        }

        Cms.Video toVideo() {
            Cms.Video v = new Cms.Video();
            v.id = canonicalPlayId();
            v.title = name;
            v.poster = thumbnailUrl;
            v.tag = directory ? "folder" : "cloud_file";
            v.remarks = directory ? "文件夹" : formatFileSize(sizeBytes);
            return v;
        }
    }

    static final class FolderPage {
        final String provider;
        final String folderId;
        final int page;
        final boolean hasMore;
        final String nextCursor;
        final String accountId;
        final String driveId;
        final List<CloudItem> items;

        FolderPage(
                String provider,
                String folderId,
                int page,
                boolean hasMore,
                String nextCursor,
                String accountId,
                String driveId,
                List<CloudItem> items) {
            this.provider = provider;
            this.folderId = folderId;
            this.page = page;
            this.hasMore = hasMore;
            this.nextCursor = nextCursor == null ? "" : nextCursor;
            this.accountId = accountId == null ? "" : accountId;
            this.driveId = driveId == null ? "" : driveId;
            this.items = items == null ? Collections.<CloudItem>emptyList() : items;
        }
    }

    static final class PlayVariant {
        final String name;
        final String url;
        final Map<String, String> headers;
        final boolean useProxy;

        PlayVariant(String name, String url, Map<String, String> headers, boolean useProxy) {
            this.name = name == null ? "原画" : name;
            this.url = url == null ? "" : url;
            this.headers =
                    headers == null
                            ? Collections.<String, String>emptyMap()
                            : new LinkedHashMap<>(headers);
            this.useProxy = useProxy;
        }
    }

    static final class ResolvedMedia {
        final String provider;
        final String accountId;
        final String fileName;
        final String playUrl;
        final Map<String, String> headers;
        final List<PlayVariant> variants;
        final CloudMediaProxy.Lease proxyLease;

        ResolvedMedia(
                String provider,
                String accountId,
                String fileName,
                String playUrl,
                Map<String, String> headers,
                List<PlayVariant> variants,
                CloudMediaProxy.Lease proxyLease) {
            this.provider = provider;
            this.accountId = accountId;
            this.fileName = fileName;
            this.playUrl = playUrl;
            this.headers = headers;
            this.variants = variants;
            this.proxyLease = proxyLease;
        }
    }

    private static final class AliSession {
        final String accessToken;
        final String driveId;
        final String userId;
        final String sourceRefreshToken;
        final long expiresAtMs;

        AliSession(
                String accessToken,
                String driveId,
                String userId,
                String sourceRefreshToken,
                long expiresAtMs) {
            this.accessToken = accessToken;
            this.driveId = driveId;
            this.userId = userId;
            this.sourceRefreshToken = sourceRefreshToken;
            this.expiresAtMs = expiresAtMs;
        }

        boolean isValidFor(String refreshToken) {
            return accessToken != null
                    && !accessToken.isEmpty()
                    && sourceRefreshToken.equals(refreshToken)
                    && System.currentTimeMillis() < expiresAtMs - 60_000L;
        }
    }

    private static final class UcRuntimeSession {
        String sourceCredential = "";
        final Map<String, String> cookies = new ConcurrentHashMap<>();
        String ownerId = "";
        boolean warmed;
    }

    private final NetdiskStore.KeyValueStore store;
    private final Endpoints endpoints;
    private final CloudMediaProxy customProxy;
    private final UcRuntimeSession ucSession = new UcRuntimeSession();
    private volatile AliSession aliSession;

    PersonalNetdiskLibrary(Context context) {
        this(NetdiskStore.storeFor(context), new Endpoints(), null);
    }

    PersonalNetdiskLibrary(
            NetdiskStore.KeyValueStore store, Endpoints endpoints, CloudMediaProxy proxy) {
        this.store = store == null ? new NetdiskStore.MemoryStore() : store;
        this.endpoints = endpoints == null ? new Endpoints() : endpoints;
        this.customProxy = proxy;
    }

    static String rootFolderId(String provider) {
        String p = NetdiskStore.normalizeDriveKey(provider);
        if (NetdiskStore.DRIVE_BAIDU.equals(p)) return "/";
        if (NetdiskStore.DRIVE_ALI.equals(p)) return "root";
        return "0";
    }

    static String siteKeyFor(String provider, String accountId) {
        String p = NetdiskStore.normalizeDriveKey(provider);
        String acct = accountId == null ? "" : accountId.trim();
        return SITE_PREFIX + NetdiskStore.sha256Hex("cloudlib|" + p + "|" + acct).substring(0, 16);
    }

    static boolean isPersonalCloudSiteKey(String siteKey) {
        return siteKey != null && siteKey.startsWith(SITE_PREFIX);
    }

    static boolean isPersonalCloudPlayId(String id) {
        return id != null && id.startsWith(SCHEME_PLAY);
    }

    static Cms.Site buildVirtualSite(String provider, String accountId) {
        String p = NetdiskStore.normalizeDriveKey(provider);
        Cms.Site site = new Cms.Site();
        site.key = siteKeyFor(p, accountId);
        site.name = NetdiskStore.displayName(p) + " · 我的文件";
        site.type = 3;
        site.api = "cloudlib://" + p + "/" + (accountId == null ? "" : accountId);
        site.searchable = false;
        site.group = "我的云盘";
        return site;
    }

    static String buildCanonicalPlayId(
            String provider,
            String accountId,
            String driveId,
            String fid,
            String path,
            String name) {
        StringBuilder sb = new StringBuilder(SCHEME_PLAY);
        sb.append("?provider=").append(urlEncode(NetdiskStore.normalizeDriveKey(provider)));
        sb.append("&account=").append(urlEncode(accountId == null ? "" : accountId));
        if (driveId != null && !driveId.isEmpty()) {
            sb.append("&drive=").append(urlEncode(driveId));
        }
        sb.append("&fid=").append(urlEncode(fid == null ? "" : fid));
        if (path != null && !path.isEmpty()) {
            sb.append("&path=").append(urlEncode(path));
        }
        sb.append("&name=").append(urlEncode(name == null ? "" : name));
        return sb.toString();
    }

    static CloudItem parseCanonicalPlayId(String playId) {
        if (!isPersonalCloudPlayId(playId)) return null;
        int q = playId.indexOf('?');
        if (q < 0) return null;
        Map<String, String> map = new LinkedHashMap<>();
        for (String pair : playId.substring(q + 1).split("&")) {
            if (pair.isEmpty()) continue;
            String[] kv = pair.split("=", 2);
            try {
                String k = URLDecoder.decode(kv[0], "UTF-8");
                String v = kv.length == 2 ? URLDecoder.decode(kv[1], "UTF-8") : "";
                map.put(k, v);
            } catch (Exception ignored) {
            }
        }
        String provider = NetdiskStore.normalizeDriveKey(map.get("provider"));
        String fid = map.get("fid");
        String path = map.get("path");
        if (provider.isEmpty()
                || ((fid == null || fid.isEmpty()) && (path == null || path.isEmpty()))) {
            return null;
        }
        return new CloudItem(
                provider,
                fid == null ? "" : fid,
                map.get("name") == null ? "" : map.get("name"),
                path == null ? "" : path,
                map.get("drive") == null ? "" : map.get("drive"),
                map.get("account") == null ? "" : map.get("account"),
                false,
                0L,
                "");
    }

    /**
     * Strictly verifies that the currently logged-in account for {@code provider} matches {@code
     * expectedAccountId}. Throws {@link PersonalCloudException} with code {@code account_mismatch}
     * if another account is logged in — guaranteeing old Favorites / WatchHistory NEVER open a
     * same-named file from a different account.
     */
    void assertAccountMatches(String provider, String expectedAccountId)
            throws PersonalCloudException {
        String p = NetdiskStore.normalizeDriveKey(provider);
        String cred = NetdiskStore.getCredential(store, p);
        if (cred.isEmpty()) {
            throw new PersonalCloudException(
                    "auth_required", NetdiskStore.displayName(p) + "未登录，请先授权登录", true);
        }
        if (expectedAccountId == null || expectedAccountId.trim().isEmpty()) {
            return;
        }
        String expected = expectedAccountId.trim();
        Set<String> activeAliases = NetdiskStore.getAccountAliases(store, p);
        if (activeAliases.contains(expected)) {
            return;
        }
        // If current login has not yet fetched server owner ID, check whether current active ID
        // belongs to a DIFFERENT explicit server owner.
        String currentId = NetdiskStore.getAccountId(store, p);
        if (isExplicitOwnerId(expected)
                && isExplicitOwnerId(currentId)
                && !expected.equals(currentId)) {
            throw new PersonalCloudException(
                    "account_mismatch",
                    "当前登录的"
                            + NetdiskStore.displayName(p)
                            + "账号与该收藏/记录所属账号不一致，已阻止打开他人或新账号同名文件。请切回原账号。",
                    true);
        }
        throw new PersonalCloudException(
                "account_mismatch",
                "当前登录的" + NetdiskStore.displayName(p) + "账号与原收藏所属账号不匹配，请使用原账号重新登录。",
                true);
    }

    private static boolean isExplicitOwnerId(String id) {
        if (id == null) return false;
        return id.startsWith("quark:uid:")
                || id.startsWith("uc:uid:")
                || id.startsWith("baidu:uk:")
                || id.startsWith("ali:uid:");
    }

    FolderPage listFolder(String rawProvider, String folderId, int page, String cursor)
            throws IOException {
        String provider = NetdiskStore.normalizeDriveKey(rawProvider);
        int safePage = Math.max(1, page);
        String safeFolder =
                (folderId == null || folderId.trim().isEmpty())
                        ? rootFolderId(provider)
                        : folderId.trim();
        if (NetdiskStore.DRIVE_QUARK.equals(provider)) return listQuark(safeFolder, safePage);
        if (NetdiskStore.DRIVE_UC.equals(provider)) return listUc(safeFolder, safePage);
        if (NetdiskStore.DRIVE_BAIDU.equals(provider)) return listBaidu(safeFolder, safePage);
        if (NetdiskStore.DRIVE_ALI.equals(provider)) return listAli(safeFolder, safePage, cursor);
        throw new PersonalCloudException("unsupported", "不支持的个人网盘：" + rawProvider, false);
    }

    ResolvedMedia resolveFile(CloudItem item) throws IOException {
        if (item == null) {
            throw new PersonalCloudException("invalid_item", "文件信息无效", false);
        }
        String provider = NetdiskStore.normalizeDriveKey(item.provider);
        String expectedAccount = item.accountId == null ? "" : item.accountId.trim();
        // Verify active account matches item owner BEFORE calling download APIs.
        // If the user re-logged into the SAME account with a rotated cookie and we don't yet have
        // the server owner ID cached locally, probe owner identity first for UC/Baidu/Ali/Quark.
        ensureOwnerIdentityIfNeeded(provider, expectedAccount);
        assertAccountMatches(provider, expectedAccount);

        if (NetdiskStore.DRIVE_QUARK.equals(provider)) return resolveQuark(item);
        if (NetdiskStore.DRIVE_UC.equals(provider)) return resolveUc(item);
        if (NetdiskStore.DRIVE_BAIDU.equals(provider)) return resolveBaidu(item);
        if (NetdiskStore.DRIVE_ALI.equals(provider)) return resolveAli(item);
        throw new PersonalCloudException("unsupported", "不支持的个人网盘：" + item.provider, false);
    }

    /**
     * When a user re-logs into the SAME account with a brand new cookie (e.g. after logout or
     * expiry), the cookie hash changes, so we probe the server owner ID (uid/uk/user_id) once on
     * demand before enforcing {@link #assertAccountMatches}. If the server confirms the same owner
     * ID, favorites stay seamlessly playable; if it's a DIFFERENT account, ownership mismatch is
     * enforced strictly!
     */
    private void ensureOwnerIdentityIfNeeded(String provider, String expectedAccount)
            throws IOException {
        if (expectedAccount == null || expectedAccount.isEmpty()) return;
        if (!NetdiskStore.isLoggedIn(store, provider)) return;
        if (NetdiskStore.getAccountAliases(store, provider).contains(expectedAccount)) return;
        if (!isExplicitOwnerId(expectedAccount)) return;

        if (NetdiskStore.DRIVE_UC.equals(provider)) {
            prepareUcSession(requireCredential(NetdiskStore.DRIVE_UC));
        } else if (NetdiskStore.DRIVE_ALI.equals(provider)) {
            requireAliSession(requireCredential(NetdiskStore.DRIVE_ALI));
        } else if (NetdiskStore.DRIVE_BAIDU.equals(provider)) {
            probeBaiduOwner(requireCredential(NetdiskStore.DRIVE_BAIDU));
        } else if (NetdiskStore.DRIVE_QUARK.equals(provider)) {
            probeQuarkOwner(requireCredential(NetdiskStore.DRIVE_QUARK));
        }
    }

    private String requireCredential(String provider) throws PersonalCloudException {
        String cred = NetdiskStore.getCredential(store, provider);
        if (cred.isEmpty()) {
            throw new PersonalCloudException(
                    "auth_required", NetdiskStore.displayName(provider) + "未登录，请先授权登录", true);
        }
        return cred;
    }

    // =========================================================================
    // 1. QUARK
    // =========================================================================

    private void probeQuarkOwner(String cookie) throws IOException {
        String url =
                endpoints.quarkDriveBase
                        + "/1/clouddrive/member?pr=ucpro&fr=pc&uc_param_str=&fetch_subscribe=true&_ch=home&fetch_identity=true";
        HttpRes res = httpRequest("GET", url, quarkHeaders(cookie), null, null);
        if (res.code == 401 || res.code == 403) {
            throw new PersonalCloudException("auth_expired", "夸克网盘登录已过期，请重新授权", true);
        }
        JSONObject obj = parseJsonSafe(res.body);
        if (obj != null) {
            if (obj.optInt("status", 200) == 401) {
                throw new PersonalCloudException("auth_expired", "夸克网盘登录已过期，请重新授权", true);
            }
            JSONObject data = obj.optJSONObject("data");
            String uid = data != null ? data.optString("member_id", "").trim() : "";
            if (uid.isEmpty() && data != null) uid = data.optString("uid", "").trim();
            if (!uid.isEmpty()) {
                NetdiskStore.recordVerifiedOwner(
                        store, NetdiskStore.DRIVE_QUARK, "quark:uid:" + uid, cookie);
            }
        }
    }

    private FolderPage listQuark(String folderId, int page) throws IOException {
        String cookie = requireCredential(NetdiskStore.DRIVE_QUARK);
        int pageSize = 50;
        String url =
                endpoints.quarkDriveBase
                        + "/1/clouddrive/file/sort?pr=ucpro&fr=pc&uc_param_str=&pdir_fid="
                        + urlEncode(folderId)
                        + "&_page="
                        + page
                        + "&_size="
                        + pageSize
                        + "&_fetch_total=1&_fetch_sub_dirs=0&_sort=file_type:asc,file_name:asc";
        HttpRes res = httpRequest("GET", url, quarkHeaders(cookie), null, null);
        JSONObject json = parseJsonOrThrow(res, "夸克网盘");
        if (res.code == 401 || json.optInt("status", 200) == 401) {
            throw new PersonalCloudException("auth_expired", "夸克网盘登录已过期，请重新授权", true);
        }
        if (res.code >= 400 || (json.has("status") && json.optInt("status", 200) != 200)) {
            throw new PersonalCloudException(
                    "list_failed",
                    "夸克目录读取失败：" + json.optString("message", "HTTP " + res.code),
                    false);
        }
        JSONObject data = json.optJSONObject("data");
        JSONArray list = data != null ? data.optJSONArray("list") : null;
        JSONObject meta = json.optJSONObject("metadata");
        int total = meta != null ? meta.optInt("_total", -1) : -1;
        String ownerUid = "";
        if (data != null) ownerUid = data.optString("owner_uid", "").trim();
        if (!ownerUid.isEmpty()) {
            NetdiskStore.recordVerifiedOwner(
                    store, NetdiskStore.DRIVE_QUARK, "quark:uid:" + ownerUid, cookie);
        }
        String accountId = NetdiskStore.getAccountId(store, NetdiskStore.DRIVE_QUARK);
        List<CloudItem> items = new ArrayList<>();
        if (list != null) {
            for (int i = 0; i < list.length(); i++) {
                JSONObject row = list.optJSONObject(i);
                if (row == null) continue;
                boolean isDir = row.optBoolean("dir", false) || row.optInt("file_type", 1) == 0;
                int cat = row.optInt("category", 0);
                String name = row.optString("file_name", "").trim();
                String fid = row.optString("fid", "").trim();
                if (fid.isEmpty() || name.isEmpty()) continue;
                if (!isDir && cat != 1 && !isVideoFileName(name)) continue;
                long size = row.optLong("size", 0L);
                String thumb = row.optString("big_thumbnail", row.optString("preview_url", ""));
                items.add(
                        new CloudItem(
                                NetdiskStore.DRIVE_QUARK,
                                fid,
                                name,
                                "",
                                "",
                                accountId,
                                isDir,
                                size,
                                thumb));
            }
        }
        boolean hasMore =
                total >= 0
                        ? (page * pageSize < total)
                        : (list != null && list.length() >= pageSize);
        return new FolderPage(
                NetdiskStore.DRIVE_QUARK, folderId, page, hasMore, "", accountId, "", items);
    }

    private ResolvedMedia resolveQuark(CloudItem item) throws IOException {
        String cookie = requireCredential(NetdiskStore.DRIVE_QUARK);
        Map<String, String> reqHeaders = quarkHeaders(cookie);
        reqHeaders.put("Content-Type", "application/json; charset=UTF-8");

        List<PlayVariant> variants = new ArrayList<>();
        Map<String, String> mediaHeaders = new LinkedHashMap<>();
        mediaHeaders.put("Cookie", cookie);
        mediaHeaders.put("User-Agent", QUARK_UA);
        mediaHeaders.put("Referer", endpoints.quarkReferer);

        // 1. Original download URL (原画)
        String dlUrl = endpoints.quarkDriveBase + "/1/clouddrive/file/download?pr=ucpro&fr=pc";
        JSONObject dlBody = new JSONObject();
        try {
            dlBody.put("fids", new JSONArray().put(item.fid));
        } catch (Exception ignored) {
        }
        HttpRes dlRes = httpRequest("POST", dlUrl, reqHeaders, dlBody.toString(), null);
        if (dlRes.code == 401) {
            throw new PersonalCloudException("auth_expired", "夸克网盘授权已过期，请重新登录", true);
        }
        JSONObject dlJson = parseJsonSafe(dlRes.body);
        if (dlJson != null && dlJson.optInt("status", 200) == 401) {
            throw new PersonalCloudException("auth_expired", "夸克网盘授权已过期，请重新登录", true);
        }
        if (dlJson != null) {
            JSONArray data = dlJson.optJSONArray("data");
            if (data != null && data.length() > 0) {
                JSONObject first = data.optJSONObject(0);
                String u = first != null ? first.optString("download_url", "").trim() : "";
                if (!u.isEmpty()) {
                    variants.add(new PlayVariant("原画", u, mediaHeaders, true));
                }
            }
        }

        // 2. Transcoded variants (/v2/play)
        String playApi = endpoints.quarkDriveBase + "/1/clouddrive/file/v2/play?pr=ucpro&fr=pc";
        JSONObject playBody = new JSONObject();
        try {
            playBody.put("fid", item.fid);
            playBody.put("resolutions", "normal,low,high,super,2k,4k");
            playBody.put("supports", "fmp4,m3u8");
        } catch (Exception ignored) {
        }
        try {
            HttpRes pRes = httpRequest("POST", playApi, reqHeaders, playBody.toString(), null);
            JSONObject pJson = parseJsonSafe(pRes.body);
            JSONObject pData = pJson != null ? pJson.optJSONObject("data") : null;
            JSONArray vList = pData != null ? pData.optJSONArray("video_list") : null;
            if (vList != null) {
                for (int i = 0; i < vList.length(); i++) {
                    JSONObject v = vList.optJSONObject(i);
                    JSONObject vi = v != null ? v.optJSONObject("video_info") : null;
                    String u = vi != null ? vi.optString("url", "").trim() : "";
                    String resLabel = v != null ? v.optString("resolution", "").trim() : "";
                    if (!u.isEmpty()) {
                        variants.add(
                                new PlayVariant(
                                        formatQuarkResLabel(resLabel), u, mediaHeaders, false));
                    }
                }
            }
        } catch (IOException ignored) {
        }

        if (variants.isEmpty()) {
            throw new PersonalCloudException("resolve_failed", "未能获取夸克网盘播放地址", false);
        }
        return wrapWithLease(NetdiskStore.DRIVE_QUARK, item, variants);
    }

    private static String formatQuarkResLabel(String res) {
        if ("4k".equalsIgnoreCase(res)) return "4K";
        if ("2k".equalsIgnoreCase(res)) return "2K";
        if ("super".equalsIgnoreCase(res)) return "超清 1080P";
        if ("high".equalsIgnoreCase(res)) return "高清 720P";
        if ("low".equalsIgnoreCase(res)) return "标清";
        return res == null || res.isEmpty() ? "流畅" : res.toUpperCase(Locale.ROOT);
    }

    private Map<String, String> quarkHeaders(String cookie) {
        Map<String, String> h = new LinkedHashMap<>();
        h.put("Cookie", cookie);
        h.put("User-Agent", QUARK_UA);
        h.put("Referer", endpoints.quarkReferer);
        h.put("Accept", "application/json");
        return h;
    }

    // =========================================================================
    // 2. UC
    // =========================================================================

    private synchronized void prepareUcSession(String credential) throws IOException {
        if (!credential.equals(ucSession.sourceCredential)) {
            ucSession.sourceCredential = credential;
            ucSession.cookies.clear();
            ucSession.ownerId = "";
            ucSession.warmed = false;
            Map<String, String> parsed = NetdiskStore.parseCookieMap(credential);
            // If __pus is present, strip stale __puus so /config refreshes it cleanly (iOS parity).
            boolean hasPus = !NetdiskStore.cookieValueIgnoreCase(parsed, "__pus").isEmpty();
            for (Map.Entry<String, String> e : parsed.entrySet()) {
                if (hasPus && "__puus".equalsIgnoreCase(e.getKey())) continue;
                ucSession.cookies.put(e.getKey(), e.getValue());
            }
        }
        if (ucSession.warmed) return;
        String url = endpoints.ucApiBase + "/1/clouddrive/config?pr=UCBrowser&fr=pc";
        HttpRes res = httpRequest("GET", url, ucHeaders(), null, ucSession.cookies);
        checkUcAuthError(res.code, parseJsonSafe(res.body));
        JSONObject obj = parseJsonSafe(res.body);
        if (obj != null) {
            JSONObject data = obj.optJSONObject("data");
            String uid = data != null ? data.optString("uid", "").trim() : "";
            if (uid.isEmpty() && data != null) uid = data.optString("member_id", "").trim();
            if (!uid.isEmpty()) {
                ucSession.ownerId = "uc:uid:" + uid;
                NetdiskStore.recordVerifiedOwner(
                        store, NetdiskStore.DRIVE_UC, ucSession.ownerId, credential);
            }
        }
        ucSession.warmed = true;
    }

    private Map<String, String> ucHeaders() {
        Map<String, String> h = new LinkedHashMap<>();
        h.put("Cookie", NetdiskAuthService.formatCookieMap(ucSession.cookies));
        h.put("User-Agent", UC_UA);
        h.put("Referer", endpoints.ucOrigin + "/");
        h.put("Origin", endpoints.ucOrigin);
        h.put("Accept", "application/json");
        return h;
    }

    private void checkUcAuthError(int httpCode, JSONObject json) throws PersonalCloudException {
        if (httpCode == 401 || httpCode == 403) {
            ucSession.warmed = false;
            throw new PersonalCloudException("auth_expired", "UC 网盘登录已过期，请重新授权", true);
        }
        if (json == null) return;
        int st = json.optInt("status", 200);
        int code = json.optInt("code", 0);
        String msg = json.optString("message", "");
        if (st == 401
                || st == 403
                || code == 31001
                || code == 40100
                || code == 41001
                || msg.contains("未登录")
                || msg.contains("登录失效")
                || msg.toLowerCase(Locale.ROOT).contains("token")) {
            ucSession.warmed = false;
            throw new PersonalCloudException("auth_expired", "UC 网盘授权已失效，请重新登录", true);
        }
    }

    private FolderPage listUc(String folderId, int page) throws IOException {
        String cred = requireCredential(NetdiskStore.DRIVE_UC);
        prepareUcSession(cred);
        int pageSize = 50;
        String url =
                endpoints.ucApiBase
                        + "/1/clouddrive/file/sort?pr=UCBrowser&fr=pc&pdir_fid="
                        + urlEncode(folderId)
                        + "&_page="
                        + page
                        + "&_size="
                        + pageSize
                        + "&_fetch_total=1&_fetch_sub_dirs=0&_sort=file_type:asc,file_name:asc";
        HttpRes res = httpRequest("GET", url, ucHeaders(), null, ucSession.cookies);
        JSONObject json = parseJsonOrThrow(res, "UC 网盘");
        checkUcAuthError(res.code, json);
        if (res.code >= 400 || (json.has("status") && json.optInt("status", 200) != 200)) {
            throw new PersonalCloudException(
                    "list_failed",
                    "UC 目录读取失败：" + json.optString("message", "HTTP " + res.code),
                    false);
        }
        JSONObject data = json.optJSONObject("data");
        JSONArray list = data != null ? data.optJSONArray("list") : null;
        JSONObject meta = json.optJSONObject("metadata");
        int total = meta != null ? meta.optInt("_total", -1) : -1;
        String accountId = NetdiskStore.getAccountId(store, NetdiskStore.DRIVE_UC);
        List<CloudItem> items = new ArrayList<>();
        if (list != null) {
            for (int i = 0; i < list.length(); i++) {
                JSONObject row = list.optJSONObject(i);
                if (row == null) continue;
                boolean isDir = row.optBoolean("dir", false) || row.optInt("file_type", 1) == 0;
                int cat = row.optInt("category", 0);
                String name = row.optString("file_name", "").trim();
                String fid = row.optString("fid", "").trim();
                if (fid.isEmpty() || name.isEmpty()) continue;
                if (!isDir && cat != 1 && !isVideoFileName(name)) continue;
                long size = row.optLong("size", 0L);
                String thumb = row.optString("big_thumbnail", row.optString("preview_url", ""));
                items.add(
                        new CloudItem(
                                NetdiskStore.DRIVE_UC,
                                fid,
                                name,
                                "",
                                "",
                                accountId,
                                isDir,
                                size,
                                thumb));
            }
        }
        boolean hasMore =
                total >= 0
                        ? (page * pageSize < total)
                        : (list != null && list.length() >= pageSize);
        return new FolderPage(
                NetdiskStore.DRIVE_UC, folderId, page, hasMore, "", accountId, "", items);
    }

    private ResolvedMedia resolveUc(CloudItem item) throws IOException {
        String cred = requireCredential(NetdiskStore.DRIVE_UC);
        prepareUcSession(cred);
        Map<String, String> reqHeaders = ucHeaders();
        reqHeaders.put("Content-Type", "application/json; charset=UTF-8");

        List<PlayVariant> variants = new ArrayList<>();
        Map<String, String> mediaHeaders = new LinkedHashMap<>();
        mediaHeaders.put("Cookie", NetdiskAuthService.formatCookieMap(ucSession.cookies));
        mediaHeaders.put("User-Agent", UC_UA);
        mediaHeaders.put("Referer", endpoints.ucOrigin + "/");

        String dlUrl = endpoints.ucApiBase + "/1/clouddrive/file/download?pr=UCBrowser&fr=pc";
        JSONObject dlBody = new JSONObject();
        try {
            dlBody.put("fids", new JSONArray().put(item.fid));
        } catch (Exception ignored) {
        }
        HttpRes dlRes =
                httpRequest("POST", dlUrl, reqHeaders, dlBody.toString(), ucSession.cookies);
        JSONObject dlJson = parseJsonSafe(dlRes.body);
        checkUcAuthError(dlRes.code, dlJson);
        mediaHeaders.put("Cookie", NetdiskAuthService.formatCookieMap(ucSession.cookies));
        if (dlJson != null) {
            JSONArray data = dlJson.optJSONArray("data");
            if (data != null && data.length() > 0) {
                JSONObject first = data.optJSONObject(0);
                String u = first != null ? first.optString("download_url", "").trim() : "";
                if (!u.isEmpty()) variants.add(new PlayVariant("原画", u, mediaHeaders, true));
            }
        }

        String playApi = endpoints.ucApiBase + "/1/clouddrive/file/v2/play?pr=UCBrowser&fr=pc";
        JSONObject playBody = new JSONObject();
        try {
            playBody.put("fid", item.fid);
            playBody.put("resolutions", "normal,low,high,super,2k,4k");
            playBody.put("supports", "fmp4,m3u8");
        } catch (Exception ignored) {
        }
        try {
            HttpRes pRes =
                    httpRequest(
                            "POST", playApi, reqHeaders, playBody.toString(), ucSession.cookies);
            JSONObject pJson = parseJsonSafe(pRes.body);
            JSONObject pData = pJson != null ? pJson.optJSONObject("data") : null;
            JSONArray vList = pData != null ? pData.optJSONArray("video_list") : null;
            if (vList != null) {
                for (int i = 0; i < vList.length(); i++) {
                    JSONObject v = vList.optJSONObject(i);
                    JSONObject vi = v != null ? v.optJSONObject("video_info") : null;
                    String u = vi != null ? vi.optString("url", "").trim() : "";
                    String resLabel = v != null ? v.optString("resolution", "").trim() : "";
                    if (!u.isEmpty()) {
                        variants.add(
                                new PlayVariant(
                                        formatQuarkResLabel(resLabel), u, mediaHeaders, false));
                    }
                }
            }
        } catch (IOException ignored) {
        }

        if (variants.isEmpty()) {
            throw new PersonalCloudException("resolve_failed", "未能获取 UC 网盘播放地址", false);
        }
        return wrapWithLease(NetdiskStore.DRIVE_UC, item, variants);
    }

    // =========================================================================
    // 3. BAIDU
    // =========================================================================

    private void probeBaiduOwner(String cookie) throws IOException {
        String url =
                endpoints.baiduPanBase
                        + "/rest/2.0/membership/user/info?method=query&clienttype=0&app_id=250528&web=1";
        HttpRes res = httpRequest("GET", url, baiduHeaders(cookie, BAIDU_WEB_UA), null, null);
        JSONObject json = parseJsonSafe(res.body);
        checkBaiduAuthError(res.code, json);
        if (json != null) {
            long uk = json.optLong("uk", 0L);
            if (uk <= 0L && json.optJSONObject("user_info") != null) {
                uk = json.optJSONObject("user_info").optLong("uk", 0L);
            }
            if (uk > 0L) {
                NetdiskStore.recordVerifiedOwner(
                        store, NetdiskStore.DRIVE_BAIDU, "baidu:uk:" + uk, cookie);
            }
        }
    }

    private void checkBaiduAuthError(int httpCode, JSONObject json) throws PersonalCloudException {
        if (httpCode == 401 || httpCode == 403) {
            throw new PersonalCloudException("auth_expired", "百度网盘登录已过期，请重新授权", true);
        }
        if (json == null) return;
        int errno = json.optInt("errno", 0);
        if (errno == -6 || errno == 110 || errno == 111 || errno == -3) {
            throw new PersonalCloudException(
                    "auth_expired", "百度网盘登录已失效（errno=" + errno + "），请重新授权", true);
        }
    }

    private Map<String, String> baiduHeaders(String cookie, String ua) {
        Map<String, String> h = new LinkedHashMap<>();
        h.put("Cookie", cookie);
        h.put("User-Agent", ua);
        h.put("Referer", endpoints.baiduPanBase + "/");
        return h;
    }

    private FolderPage listBaidu(String dirPath, int page) throws IOException {
        String cookie = requireCredential(NetdiskStore.DRIVE_BAIDU);
        int limit = 100;
        int start = (page - 1) * limit;
        String safeDir = dirPath.startsWith("/") ? dirPath : "/" + dirPath;
        String url =
                endpoints.baiduPanBase
                        + "/api/list?dir="
                        + urlEncode(safeDir)
                        + "&order=name&desc=0&start="
                        + start
                        + "&limit="
                        + limit
                        + "&web=1&showempty=0";
        HttpRes res = httpRequest("GET", url, baiduHeaders(cookie, BAIDU_WEB_UA), null, null);
        JSONObject json = parseJsonOrThrow(res, "百度网盘");
        checkBaiduAuthError(res.code, json);
        int errno = json.optInt("errno", 0);
        if (errno != 0) {
            throw new PersonalCloudException(
                    "list_failed", "百度网盘目录读取失败（errno=" + errno + "）", false);
        }
        long uk = json.optLong("uk", 0L);
        if (uk > 0L) {
            NetdiskStore.recordVerifiedOwner(
                    store, NetdiskStore.DRIVE_BAIDU, "baidu:uk:" + uk, cookie);
        }
        String accountId = NetdiskStore.getAccountId(store, NetdiskStore.DRIVE_BAIDU);
        JSONArray list = json.optJSONArray("list");
        List<CloudItem> items = new ArrayList<>();
        if (list != null) {
            for (int i = 0; i < list.length(); i++) {
                JSONObject row = list.optJSONObject(i);
                if (row == null) continue;
                boolean isDir = row.optInt("isdir", 0) == 1;
                int cat = row.optInt("category", 0);
                String name = row.optString("server_filename", "").trim();
                String path = row.optString("path", "").trim();
                String fsId = String.valueOf(row.optLong("fs_id", 0L));
                if ("0".equals(fsId)) fsId = row.optString("fs_id", "").trim();
                if (name.isEmpty() || path.isEmpty()) continue;
                if (!isDir && cat != 1 && !isVideoFileName(name)) continue;
                long size = row.optLong("size", 0L);
                String thumb = "";
                JSONObject thumbs = row.optJSONObject("thumbs");
                if (thumbs != null) {
                    thumb =
                            thumbs.optString(
                                    "url3", thumbs.optString("url2", thumbs.optString("url1", "")));
                }
                items.add(
                        new CloudItem(
                                NetdiskStore.DRIVE_BAIDU,
                                isDir ? path : fsId,
                                name,
                                path,
                                "",
                                accountId,
                                isDir,
                                size,
                                thumb));
            }
        }
        boolean hasMore =
                json.optInt("has_more", 0) == 1 || (list != null && list.length() >= limit);
        return new FolderPage(
                NetdiskStore.DRIVE_BAIDU, safeDir, page, hasMore, "", accountId, "", items);
    }

    private ResolvedMedia resolveBaidu(CloudItem item) throws IOException {
        String cookie = requireCredential(NetdiskStore.DRIVE_BAIDU);
        Map<String, String> mediaHeaders = baiduHeaders(cookie, BAIDU_MEDIA_UA);
        List<PlayVariant> variants = new ArrayList<>();

        // 1. filemetas dlink (原画)
        if (!item.fid.isEmpty() && item.fid.matches("\\d+")) {
            String metaUrl =
                    endpoints.baiduPanBase
                            + "/api/filemetas?dlink=1&fsids="
                            + urlEncode("[" + item.fid + "]");
            HttpRes mRes = httpRequest("GET", metaUrl, mediaHeaders, null, null);
            JSONObject mJson = parseJsonSafe(mRes.body);
            checkBaiduAuthError(mRes.code, mJson);
            JSONArray info = mJson != null ? mJson.optJSONArray("info") : null;
            if (info != null && info.length() > 0) {
                JSONObject first = info.optJSONObject(0);
                String dlink = first != null ? first.optString("dlink", "").trim() : "";
                if (!dlink.isEmpty()) {
                    variants.add(new PlayVariant("原画", dlink, mediaHeaders, true));
                }
            }
        }

        // 2. PCS locatedownload fallback
        if (variants.isEmpty() && !item.path.isEmpty()) {
            String pcsUrl =
                    endpoints.baiduPcsBase
                            + "/rest/2.0/pcs/file?method=locatedownload&app_id=250528&ver=4.0&path="
                            + urlEncode(item.path);
            try {
                HttpRes pRes = httpRequest("GET", pcsUrl, mediaHeaders, null, null);
                JSONObject pJson = parseJsonSafe(pRes.body);
                checkBaiduAuthError(pRes.code, pJson);
                JSONArray urls = pJson != null ? pJson.optJSONArray("urls") : null;
                if (urls != null && urls.length() > 0) {
                    JSONObject u0 = urls.optJSONObject(0);
                    String u = u0 != null ? u0.optString("url", "").trim() : "";
                    if (!u.isEmpty()) variants.add(new PlayVariant("原画", u, mediaHeaders, true));
                }
            } catch (PersonalCloudException reauth) {
                throw reauth;
            } catch (IOException ignored) {
            }
        }

        // 3. HLS streaming fallback (流畅转码)
        if (!item.path.isEmpty()) {
            String hlsUrl =
                    endpoints.baiduPanBase
                            + "/api/streaming?path="
                            + urlEncode(item.path)
                            + "&app_id=250528&clienttype=0&type=M3U8_AUTO_1080&vip=2";
            variants.add(new PlayVariant("流畅转码", hlsUrl, mediaHeaders, false));
        }

        if (variants.isEmpty()) {
            throw new PersonalCloudException("resolve_failed", "未能获取百度网盘播放地址", false);
        }
        return wrapWithLease(NetdiskStore.DRIVE_BAIDU, item, variants);
    }

    // =========================================================================
    // 4. ALI (ALIPAN)
    // =========================================================================

    private synchronized AliSession requireAliSession(String storedCred) throws IOException {
        String rt = NetdiskStore.extractAliRefreshToken(storedCred);
        if (rt.isEmpty()) {
            throw new PersonalCloudException("auth_required", "阿里云盘未登录，请先授权", true);
        }
        AliSession cur = aliSession;
        if (cur != null && cur.isValidFor(rt)) {
            return cur;
        }
        String tokenUrl = endpoints.aliAuthBase + "/v2/account/token";
        Map<String, String> headers = new LinkedHashMap<>();
        headers.put("Content-Type", "application/json; charset=UTF-8");
        headers.put("Referer", endpoints.aliReferer);
        headers.put("User-Agent", BAIDU_WEB_UA);
        JSONObject reqBody = new JSONObject();
        try {
            reqBody.put("refresh_token", rt);
            reqBody.put("grant_type", "refresh_token");
        } catch (Exception ignored) {
        }
        HttpRes res = httpRequest("POST", tokenUrl, headers, reqBody.toString(), null);
        JSONObject json = parseJsonSafe(res.body);
        if (res.code == 401
                || res.code == 400
                || (json != null
                        && (json.optString("code", "").toLowerCase(Locale.ROOT).contains("token")
                                || json.optString("code", "")
                                        .toLowerCase(Locale.ROOT)
                                        .contains("unauthorized")))) {
            aliSession = null;
            throw new PersonalCloudException("auth_expired", "阿里云盘授权已过期，请重新扫码登录", true);
        }
        if (json == null) {
            throw new PersonalCloudException("auth_failed", "阿里云盘 Token 刷新响应无效", false);
        }
        String accessToken = json.optString("access_token", "").trim();
        if (accessToken.isEmpty()) {
            aliSession = null;
            throw new PersonalCloudException("auth_expired", "阿里云盘未返回有效 access_token，请重新登录", true);
        }
        String newRt = json.optString("refresh_token", "").trim();
        String effectiveRt = !newRt.isEmpty() ? newRt : rt;
        String userId = json.optString("user_id", "").trim();
        String ownerId = !userId.isEmpty() ? ("ali:uid:" + userId) : "";
        String driveId = pickAliDriveId(json);
        long expiresIn = json.optLong("expires_in", 7200L);

        // Persist rotated refresh_token cleanly into NetdiskStore so future launches stay logged
        // in!
        if (!newRt.isEmpty() && !newRt.equals(rt)) {
            NetdiskStore.setCredential(
                    store, NetdiskStore.DRIVE_ALI, "ali_token=" + newRt, ownerId);
        } else if (!ownerId.isEmpty()) {
            NetdiskStore.recordVerifiedOwner(
                    store, NetdiskStore.DRIVE_ALI, ownerId, "ali_token=" + effectiveRt);
        }
        AliSession fresh =
                new AliSession(
                        accessToken,
                        driveId,
                        userId,
                        effectiveRt,
                        System.currentTimeMillis() + Math.max(300L, expiresIn) * 1000L);
        aliSession = fresh;
        return fresh;
    }

    private static String pickAliDriveId(JSONObject json) {
        String resourceDrive = json.optString("resource_drive_id", "").trim();
        if (!resourceDrive.isEmpty() && !"NO_ID".equalsIgnoreCase(resourceDrive)) {
            return resourceDrive;
        }
        String defDrive = json.optString("default_drive_id", "").trim();
        if (!defDrive.isEmpty()) return defDrive;
        return json.optString("backup_drive_id", "").trim();
    }

    private Map<String, String> aliHeaders(AliSession session) {
        Map<String, String> h = new LinkedHashMap<>();
        h.put("Authorization", "Bearer " + session.accessToken);
        h.put("Content-Type", "application/json; charset=UTF-8");
        h.put("Referer", endpoints.aliReferer);
        h.put("X-Canary", ALI_CANARY);
        h.put("x-device-id", NetdiskStore.sha256Hex("marco|" + session.userId).substring(0, 24));
        h.put("User-Agent", BAIDU_WEB_UA);
        return h;
    }

    private void checkAliAuthError(int httpCode, JSONObject json) throws PersonalCloudException {
        if (httpCode == 401) {
            aliSession = null;
            throw new PersonalCloudException("auth_expired", "阿里云盘登录已过期，请重新授权", true);
        }
        if (json == null) return;
        String code = json.optString("code", "").toLowerCase(Locale.ROOT);
        if (code.contains("token")
                || code.contains("unauthorized")
                || code.contains("accessdenied")) {
            aliSession = null;
            throw new PersonalCloudException("auth_expired", "阿里云盘授权已失效，请重新登录", true);
        }
    }

    private FolderPage listAli(String folderId, int page, String cursor) throws IOException {
        String cred = requireCredential(NetdiskStore.DRIVE_ALI);
        AliSession session = requireAliSession(cred);
        String targetFolder = folderId.isEmpty() ? "root" : folderId;

        // Support cursor directly OR indexed page stepping if cursor omitted for page > 1.
        String activeMarker = cursor == null ? "" : cursor.trim();
        int stepCount = (activeMarker.isEmpty() && page > 1) ? page : 1;
        JSONObject lastJson = null;
        for (int step = 0; step < stepCount; step++) {
            JSONObject body = new JSONObject();
            try {
                body.put("drive_id", session.driveId);
                body.put("parent_file_id", targetFolder);
                body.put("limit", 100);
                body.put("order_by", "name");
                body.put("order_direction", "ASC");
                if (!activeMarker.isEmpty()) body.put("marker", activeMarker);
            } catch (Exception ignored) {
            }
            HttpRes res =
                    httpRequest(
                            "POST",
                            endpoints.aliApiBase + "/adrive/v3/file/list",
                            aliHeaders(session),
                            body.toString(),
                            null);
            JSONObject json = parseJsonOrThrow(res, "阿里云盘");
            checkAliAuthError(res.code, json);
            if (res.code >= 400) {
                throw new PersonalCloudException(
                        "list_failed",
                        "阿里云盘目录读取失败：" + json.optString("message", "HTTP " + res.code),
                        false);
            }
            lastJson = json;
            activeMarker = json.optString("next_marker", "").trim();
            if (step + 1 < stepCount && activeMarker.isEmpty()) {
                // Reached end before requested page
                String accountId = NetdiskStore.getAccountId(store, NetdiskStore.DRIVE_ALI);
                return new FolderPage(
                        NetdiskStore.DRIVE_ALI,
                        targetFolder,
                        page,
                        false,
                        "",
                        accountId,
                        session.driveId,
                        Collections.<CloudItem>emptyList());
            }
        }

        String accountId = NetdiskStore.getAccountId(store, NetdiskStore.DRIVE_ALI);
        JSONArray arr = lastJson != null ? lastJson.optJSONArray("items") : null;
        List<CloudItem> items = new ArrayList<>();
        if (arr != null) {
            for (int i = 0; i < arr.length(); i++) {
                JSONObject row = arr.optJSONObject(i);
                if (row == null) continue;
                boolean isDir = "folder".equalsIgnoreCase(row.optString("type", ""));
                String cat = row.optString("category", "");
                String name = row.optString("name", "").trim();
                String fid = row.optString("file_id", "").trim();
                if (fid.isEmpty() || name.isEmpty()) continue;
                if (!isDir && !"video".equalsIgnoreCase(cat) && !isVideoFileName(name)) continue;
                long size = row.optLong("size", 0L);
                String thumb = row.optString("thumbnail", "");
                items.add(
                        new CloudItem(
                                NetdiskStore.DRIVE_ALI,
                                fid,
                                name,
                                "",
                                session.driveId,
                                accountId,
                                isDir,
                                size,
                                thumb));
            }
        }
        String nextMarker = lastJson != null ? lastJson.optString("next_marker", "").trim() : "";
        return new FolderPage(
                NetdiskStore.DRIVE_ALI,
                targetFolder,
                page,
                !nextMarker.isEmpty(),
                nextMarker,
                accountId,
                session.driveId,
                items);
    }

    private ResolvedMedia resolveAli(CloudItem item) throws IOException {
        String cred = requireCredential(NetdiskStore.DRIVE_ALI);
        AliSession session = requireAliSession(cred);
        String driveId =
                (item.driveId != null && !item.driveId.isEmpty()) ? item.driveId : session.driveId;
        Map<String, String> mediaHeaders = new LinkedHashMap<>();
        mediaHeaders.put("Referer", endpoints.aliReferer);
        mediaHeaders.put("User-Agent", BAIDU_WEB_UA);

        List<PlayVariant> variants = new ArrayList<>();

        // 1. Direct download URL (原画)
        JSONObject dlReq = new JSONObject();
        try {
            dlReq.put("drive_id", driveId);
            dlReq.put("file_id", item.fid);
            dlReq.put("expire_sec", 14400);
        } catch (Exception ignored) {
        }
        HttpRes dlRes =
                httpRequest(
                        "POST",
                        endpoints.aliPdsBase + "/v2/file/get_download_url",
                        aliHeaders(session),
                        dlReq.toString(),
                        null);
        JSONObject dlJson = parseJsonSafe(dlRes.body);
        checkAliAuthError(dlRes.code, dlJson);
        if (dlJson != null) {
            String u = dlJson.optString("url", "").trim();
            if (!u.isEmpty()) variants.add(new PlayVariant("原画", u, mediaHeaders, false));
        }

        // 2. Live transcoding variants (sorted by height desc)
        JSONObject previewReq = new JSONObject();
        try {
            previewReq.put("drive_id", driveId);
            previewReq.put("file_id", item.fid);
            previewReq.put("category", "live_transcoding");
            previewReq.put("get_subtitle_info", true);
            previewReq.put("url_expire_sec", 14400);
        } catch (Exception ignored) {
        }
        try {
            HttpRes pRes =
                    httpRequest(
                            "POST",
                            endpoints.aliApiBase + "/v2/file/get_video_preview_play_info",
                            aliHeaders(session),
                            previewReq.toString(),
                            null);
            JSONObject pJson = parseJsonSafe(pRes.body);
            checkAliAuthError(pRes.code, pJson);
            JSONObject playInfo =
                    pJson != null ? pJson.optJSONObject("video_preview_play_info") : null;
            JSONArray tasks =
                    playInfo != null ? playInfo.optJSONArray("live_transcoding_task_list") : null;
            if (tasks != null) {
                List<JSONObject> validTasks = new ArrayList<>();
                for (int i = 0; i < tasks.length(); i++) {
                    JSONObject t = tasks.optJSONObject(i);
                    if (t != null && !t.optString("url", "").trim().isEmpty()) {
                        validTasks.add(t);
                    }
                }
                Collections.sort(
                        validTasks,
                        new Comparator<JSONObject>() {
                            @Override
                            public int compare(JSONObject a, JSONObject b) {
                                return Integer.compare(
                                        b.optInt("template_height", 0),
                                        a.optInt("template_height", 0));
                            }
                        });
                for (JSONObject t : validTasks) {
                    String u = t.optString("url", "").trim();
                    int h = t.optInt("template_height", 0);
                    String id = t.optString("template_id", "");
                    String label = h > 0 ? (h + "P") : (id.isEmpty() ? "转码" : id);
                    variants.add(new PlayVariant(label, u, mediaHeaders, false));
                }
            }
        } catch (PersonalCloudException reauth) {
            throw reauth;
        } catch (IOException ignored) {
        }

        if (variants.isEmpty()) {
            throw new PersonalCloudException("resolve_failed", "未能获取阿里云盘播放地址", false);
        }
        return wrapWithLease(NetdiskStore.DRIVE_ALI, item, variants);
    }

    // =========================================================================
    // Lease Wrapping & Live Account Guard
    // =========================================================================

    private ResolvedMedia wrapWithLease(
            final String provider, CloudItem item, List<PlayVariant> variants) throws IOException {
        final String activeAccountId = NetdiskStore.getAccountId(store, provider);
        PlayVariant primary = variants.get(0);
        CloudMediaProxy.Lease lease = null;
        String effectiveUrl = primary.url;
        Map<String, String> effectiveHeaders = new LinkedHashMap<>(primary.headers);

        if (primary.useProxy) {
            CloudMediaProxy proxy = customProxy != null ? customProxy : CloudMediaProxy.shared();
            CloudMediaProxy.AccessGuard guard =
                    new CloudMediaProxy.AccessGuard() {
                        @Override
                        public boolean isCurrent() {
                            return NetdiskStore.isLoggedIn(store, provider)
                                    && NetdiskStore.getAccountAliases(store, provider)
                                            .contains(activeAccountId);
                        }
                    };
            lease = proxy.createLease(primary.url, primary.headers, guard);
            effectiveUrl = proxy.leaseUrl(lease);
            effectiveHeaders = Collections.emptyMap();
        }

        return new ResolvedMedia(
                provider,
                activeAccountId,
                item.name,
                effectiveUrl,
                effectiveHeaders,
                variants,
                lease);
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    static boolean isVideoFileName(String name) {
        if (name == null) return false;
        int dot = name.lastIndexOf('.');
        if (dot < 0 || dot >= name.length() - 1) return false;
        return VIDEO_EXTS.contains(name.substring(dot + 1).toLowerCase(Locale.ROOT));
    }

    static String formatFileSize(long bytes) {
        if (bytes <= 0L) return "";
        if (bytes >= 1024L * 1024L * 1024L) {
            return String.format(Locale.US, "%.2f GB", bytes / (1024.0 * 1024.0 * 1024.0));
        }
        if (bytes >= 1024L * 1024L) {
            return String.format(Locale.US, "%.1f MB", bytes / (1024.0 * 1024.0));
        }
        return (bytes / 1024L) + " KB";
    }

    private static final class HttpRes {
        final int code;
        final String body;

        HttpRes(int code, String body) {
            this.code = code;
            this.body = body;
        }
    }

    private static HttpRes httpRequest(
            String method,
            String urlStr,
            Map<String, String> headers,
            String jsonBody,
            Map<String, String> cookieJar)
            throws IOException {
        HttpURLConnection conn = ProxyAddress.openHttpConnection(new URL(urlStr));
        try {
            conn.setRequestMethod(method);
            conn.setInstanceFollowRedirects(false);
            conn.setConnectTimeout(15_000);
            conn.setReadTimeout(20_000);
            if (headers != null) {
                for (Map.Entry<String, String> e : headers.entrySet()) {
                    if (e.getKey() != null && e.getValue() != null) {
                        conn.setRequestProperty(e.getKey(), e.getValue());
                    }
                }
            }
            if (jsonBody != null && ("POST".equals(method) || "PUT".equals(method))) {
                byte[] payload = jsonBody.getBytes(StandardCharsets.UTF_8);
                conn.setDoOutput(true);
                conn.setFixedLengthStreamingMode(payload.length);
                try (OutputStream out = conn.getOutputStream()) {
                    out.write(payload);
                }
            }
            int code = conn.getResponseCode();
            NetdiskAuthService.collectSetCookies(conn, cookieJar);
            InputStream stream = code >= 400 ? conn.getErrorStream() : conn.getInputStream();
            String body = stream != null ? readUtf8(stream, 4 * 1024 * 1024) : "";
            return new HttpRes(code, body);
        } finally {
            conn.disconnect();
        }
    }

    private static String readUtf8(InputStream in, int maxBytes) throws IOException {
        try (InputStream s = in) {
            ByteArrayOutputStream bos = new ByteArrayOutputStream();
            byte[] buf = new byte[8192];
            int total = 0;
            int n;
            while ((n = s.read(buf)) != -1) {
                total += n;
                if (total > maxBytes) throw new IOException("响应过大");
                bos.write(buf, 0, n);
            }
            return new String(bos.toByteArray(), StandardCharsets.UTF_8);
        }
    }

    private static JSONObject parseJsonSafe(String body) {
        if (body == null || body.trim().isEmpty()) return null;
        try {
            return new JSONObject(body.trim());
        } catch (Exception ignored) {
            return null;
        }
    }

    private static JSONObject parseJsonOrThrow(HttpRes res, String providerLabel)
            throws PersonalCloudException {
        JSONObject obj = parseJsonSafe(res.body);
        if (obj != null) return obj;
        if (res.code == 401 || res.code == 403) {
            throw new PersonalCloudException("auth_expired", providerLabel + "登录已过期，请重新授权", true);
        }
        throw new PersonalCloudException(
                "bad_response", providerLabel + "返回了无效响应（HTTP " + res.code + "）", false);
    }

    private static String urlEncode(String s) {
        try {
            return URLEncoder.encode(s == null ? "" : s, "UTF-8");
        } catch (Exception e) {
            return s == null ? "" : s;
        }
    }
}
