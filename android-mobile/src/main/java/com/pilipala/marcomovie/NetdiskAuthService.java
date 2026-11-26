package com.pilipala.marcomovie;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.net.URLEncoder;
import java.nio.charset.Charset;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;
import org.json.JSONObject;

/**
 * Native QR authentication service for Quark, UC, Baidu, and Ali (Alipan) cloud drives.
 *
 * <p>Mirrors iOS 0.7.7 {@code lib/core/netdisk_service.dart} and {@code netdisk_session.dart}:
 *
 * <ul>
 *   <li>Local-only QR URL generation (never sends tokens to external QR image APIs).
 *   <li>One-use service ticket caching so transient network hiccups retry exchange cleanly.
 *   <li>Baidu 38s long-poll abort handle ({@link #abortBaiduLongPoll()}) for instant resume polling
 *       after returning from the netdisk app without invalidating the QR session or aborting an
 *       in-progress ticket exchange.
 *   <li>GBK-safe Base64 decoding for Ali {@code bizExt} payloads containing Chinese nicknames.
 *   <li>Injectable {@link Endpoints} for offline JVM tests against local mock HTTP servers.
 * </ul>
 */
final class NetdiskAuthService {
    static final String STATE_WAITING = "waiting";
    static final String STATE_SCANNED = "scanned";
    static final String STATE_CONFIRMED = "confirmed";
    static final String STATE_EXPIRED = "expired";
    static final String STATE_ERROR = "error";

    private static final String DESKTOP_UA =
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36";

    static final class Endpoints {
        String quarkUopBase = "https://uop.quark.cn";
        String quarkSuBase = "https://su.quark.cn";
        String quarkPanBase = "https://pan.quark.cn";
        String quarkDriveBase = "https://drive-pc.quark.cn";

        String ucOpenBase = "https://api.open.uc.cn";
        String ucSuBase = "https://su.uc.cn";
        String ucDriveBase = "https://drive.uc.cn";

        String baiduPassportBase = "https://passport.baidu.com";
        String baiduWappassBase = "https://wappass.baidu.com";
        String baiduPanBase = "https://pan.baidu.com";

        String aliPassportBase = "https://passport.aliyundrive.com";
        String aliAuthBase = "https://auth.aliyundrive.com";
    }

    static final class QrSession {
        final String driveKey;
        final String qrUrl;
        final String token; // Quark/UC token, Baidu sign, Ali ck
        final String extra; // Baidu gid, Ali t
        final long createdAtMs;
        final Map<String, String> cookies = new ConcurrentHashMap<>();
        final AtomicReference<String> cachedTicket = new AtomicReference<>("");
        final AtomicBoolean exchangingTicket = new AtomicBoolean(false);
        final AtomicReference<HttpURLConnection> activeLongPoll = new AtomicReference<>();

        QrSession(String driveKey, String qrUrl, String token, String extra) {
            this.driveKey = driveKey;
            this.qrUrl = qrUrl;
            this.token = token;
            this.extra = extra;
            this.createdAtMs = System.currentTimeMillis();
        }
    }

    static final class PollResult {
        final String state;
        final String credential;
        final String ownerId;
        final String message;

        PollResult(String state, String credential, String ownerId, String message) {
            this.state = state;
            this.credential = credential == null ? "" : credential;
            this.ownerId = ownerId == null ? "" : ownerId;
            this.message = message == null ? "" : message;
        }

        boolean isConfirmed() {
            return STATE_CONFIRMED.equals(state) && !credential.isEmpty();
        }
    }

    private final Endpoints endpoints;
    private final AtomicReference<QrSession> currentBaiduSession = new AtomicReference<>();

    NetdiskAuthService() {
        this(new Endpoints());
    }

    NetdiskAuthService(Endpoints endpoints) {
        this.endpoints = endpoints == null ? new Endpoints() : endpoints;
    }

    /** Returns native app deep-link candidates to open on the same Android device. */
    static List<String> buildSameDeviceDeepLinks(String driveKey, String qrUrl) {
        String key = NetdiskStore.normalizeDriveKey(driveKey);
        List<String> links = new ArrayList<>();
        String encoded = "";
        try {
            encoded = URLEncoder.encode(qrUrl == null ? "" : qrUrl, "UTF-8");
        } catch (Exception ignored) {
        }
        if (NetdiskStore.DRIVE_QUARK.equals(key)) {
            if (!encoded.isEmpty()) {
                links.add("qklink://open?url=" + encoded);
            }
            links.add("qklink://");
            links.add("qkcloudlink://");
        } else if (NetdiskStore.DRIVE_UC.equals(key)) {
            if (!encoded.isEmpty()) {
                links.add("uclink://open?url=" + encoded);
            }
            links.add("uclink://");
        } else if (NetdiskStore.DRIVE_BAIDU.equals(key)) {
            links.add("baiduboxapp://");
            links.add("bdnetdisk://");
        } else if (NetdiskStore.DRIVE_ALI.equals(key)) {
            links.add("smartdrive://");
            links.add("alipan://");
        }
        return Collections.unmodifiableList(links);
    }

    /**
     * Aborts an in-flight Baidu 38s unicast long-poll when the user returns from the Baidu app,
     * allowing an immediate 80ms retry without invalidating the session or aborting ticket exchange.
     */
    boolean abortBaiduLongPoll() {
        QrSession session = currentBaiduSession.get();
        if (session == null || session.exchangingTicket.get()) return false;
        HttpURLConnection conn = session.activeLongPoll.getAndSet(null);
        if (conn != null) {
            try {
                conn.disconnect();
            } catch (Throwable ignored) {
            }
            return true;
        }
        return false;
    }

    QrSession startQrSession(String rawDriveKey) throws IOException {
        String key = NetdiskStore.normalizeDriveKey(rawDriveKey);
        if (NetdiskStore.DRIVE_QUARK.equals(key)) return startQuarkQr();
        if (NetdiskStore.DRIVE_UC.equals(key)) return startUcQr();
        if (NetdiskStore.DRIVE_BAIDU.equals(key)) return startBaiduQr();
        if (NetdiskStore.DRIVE_ALI.equals(key)) return startAliQr();
        throw new IOException("不支持的网盘类型：" + rawDriveKey);
    }

    PollResult pollQrSession(QrSession session) {
        if (session == null) return new PollResult(STATE_ERROR, "", "", "扫码会话为空");
        try {
            if (NetdiskStore.DRIVE_QUARK.equals(session.driveKey)) return pollQuark(session);
            if (NetdiskStore.DRIVE_UC.equals(session.driveKey)) return pollUc(session);
            if (NetdiskStore.DRIVE_BAIDU.equals(session.driveKey)) return pollBaidu(session);
            if (NetdiskStore.DRIVE_ALI.equals(session.driveKey)) return pollAli(session);
            return new PollResult(STATE_ERROR, "", "", "不支持的网盘类型");
        } catch (IOException e) {
            return new PollResult(STATE_ERROR, "", "", e.getMessage());
        } catch (Throwable t) {
            return new PollResult(STATE_ERROR, "", "", t.getClass().getSimpleName());
        }
    }

    // ---- Quark ----

    private QrSession startQuarkQr() throws IOException {
        long now = System.currentTimeMillis();
        String url =
                endpoints.quarkUopBase
                        + "/cas/ajax/getTokenForQrcodeLogin?client_id=532&v=1.2&request_id="
                        + now;
        Map<String, String> headers = new LinkedHashMap<>();
        headers.put("User-Agent", DESKTOP_UA);
        headers.put("Origin", endpoints.quarkPanBase);
        headers.put("Referer", endpoints.quarkPanBase + "/");
        headers.put("Cache-Control", "no-cache");
        HttpResult res = httpGet(url, headers, 12_000, null);
        JSONObject json = parseJson(res.body);
        if (json.optInt("status", -1) != 2000000) {
            throw new IOException("获取夸克登录二维码失败（status=" + json.optInt("status", -1) + "）");
        }
        JSONObject data = json.optJSONObject("data");
        JSONObject members = data != null ? data.optJSONObject("members") : null;
        String token = members != null ? members.optString("token", "").trim() : "";
        if (token.isEmpty()) throw new IOException("夸克二维码 token 为空");
        String qrUrl =
                endpoints.quarkSuBase
                        + "/4_eMHBJ?uc_param_str=dsdnfrpfbivesscpgimibtbmnijblauputogpintnwktprchmt&token="
                        + urlEncode(token)
                        + "&client_id=532&ssb=weblogin&uc_biz_str=S%3Acustom%7COPT%3ASAREA%400%7COPT%3AIMMERSIVE%401%7COPT%3ABACK_BTN_STYLE%400";
        return new QrSession(NetdiskStore.DRIVE_QUARK, qrUrl, token, "");
    }

    private PollResult pollQuark(QrSession session) throws IOException {
        String st = session.cachedTicket.get();
        if (st == null || st.isEmpty()) {
            long now = System.currentTimeMillis();
            String url =
                    endpoints.quarkUopBase
                            + "/cas/ajax/getServiceTicketByQrcodeToken?client_id=532&v=1.2&token="
                            + urlEncode(session.token)
                            + "&request_id="
                            + now;
            Map<String, String> headers = new LinkedHashMap<>();
            headers.put("User-Agent", DESKTOP_UA);
            headers.put("Origin", endpoints.quarkPanBase);
            headers.put("Referer", endpoints.quarkPanBase + "/");
            HttpResult res = httpGet(url, headers, 12_000, null);
            JSONObject json = parseJson(res.body);
            int status = json.optInt("status", -1);
            if (status == 50004001) return new PollResult(STATE_WAITING, "", "", "等待夸克 App 扫码");
            if (status == 50004002) return new PollResult(STATE_EXPIRED, "", "", "二维码已过期，请刷新");
            if (status != 2000000) {
                return new PollResult(STATE_WAITING, "", "", "等待确认（" + status + "）");
            }
            JSONObject data = json.optJSONObject("data");
            JSONObject members = data != null ? data.optJSONObject("members") : null;
            st = members != null ? members.optString("service_ticket", "").trim() : "";
            if (st.isEmpty()) return new PollResult(STATE_WAITING, "", "", "等待确认");
            session.cachedTicket.set(st);
        }
        session.exchangingTicket.set(true);
        try {
            String infoUrl =
                    endpoints.quarkPanBase + "/account/info?st=" + urlEncode(st) + "&lw=scan";
            Map<String, String> headers = new LinkedHashMap<>();
            headers.put("User-Agent", DESKTOP_UA);
            headers.put("Referer", endpoints.quarkPanBase + "/");
            HttpResult infoRes = httpGet(infoUrl, headers, 15_000, session.cookies);
            String cookieHeader = formatCookieMap(session.cookies);
            if (!NetdiskStore.isCredentialUsable(NetdiskStore.DRIVE_QUARK, cookieHeader)) {
                // Fallback: mobileinfo endpoint returns __pus in JSON body
                String mobileUrl =
                        endpoints.quarkPanBase
                                + "/account/mobileinfo?pr=ucpro&fr=h5&st="
                                + urlEncode(st);
                HttpResult mRes = httpGet(mobileUrl, headers, 12_000, session.cookies);
                JSONObject mJson = parseJsonSafe(mRes.body);
                JSONObject mData = mJson != null ? mJson.optJSONObject("data") : null;
                String pus = mData != null ? mData.optString("__pus", "").trim() : "";
                if (!pus.isEmpty()) session.cookies.put("__pus", pus);
                cookieHeader = formatCookieMap(session.cookies);
            }
            if (!NetdiskStore.isCredentialUsable(NetdiskStore.DRIVE_QUARK, cookieHeader)) {
                throw new IOException("夸克登录未返回有效 Cookie");
            }
            // Validate session & absorb __puus / identity via member endpoint
            String memberUrl =
                    endpoints.quarkDriveBase
                            + "/1/clouddrive/member?pr=ucpro&fr=pc&uc_param_str=&fetch_subscribe=true&_ch=home&fetch_identity=true";
            Map<String, String> memberHeaders = new LinkedHashMap<>();
            memberHeaders.put("User-Agent", DESKTOP_UA);
            memberHeaders.put("Referer", endpoints.quarkPanBase + "/");
            memberHeaders.put("Cookie", cookieHeader);
            HttpResult memberRes = httpGet(memberUrl, memberHeaders, 12_000, session.cookies);
            String finalCookie = formatCookieMap(session.cookies);
            String ownerId = "";
            JSONObject infoJson = parseJsonSafe(infoRes.body);
            if (infoJson != null) {
                JSONObject d = infoJson.optJSONObject("data");
                String uid = d != null ? d.optString("uid", "").trim() : "";
                if (!uid.isEmpty()) ownerId = "quark:uid:" + uid;
            }
            if (ownerId.isEmpty()) {
                JSONObject mObj = parseJsonSafe(memberRes.body);
                JSONObject md = mObj != null ? mObj.optJSONObject("data") : null;
                String uid = md != null ? md.optString("member_id", "").trim() : "";
                if (!uid.isEmpty()) ownerId = "quark:uid:" + uid;
            }
            if (ownerId.isEmpty()) {
                ownerId = NetdiskStore.deriveCookieAccountId(NetdiskStore.DRIVE_QUARK, finalCookie);
            }
            return new PollResult(STATE_CONFIRMED, finalCookie, ownerId, "夸克网盘登录成功");
        } finally {
            session.exchangingTicket.set(false);
        }
    }

    // ---- UC ----

    private QrSession startUcQr() throws IOException {
        long now = System.currentTimeMillis();
        String url =
                endpoints.ucOpenBase
                        + "/cas/ajax/getTokenForQrcodeLogin?client_id=381&v=1.2&request_id="
                        + now;
        Map<String, String> headers = new LinkedHashMap<>();
        headers.put("User-Agent", DESKTOP_UA);
        headers.put("Origin", endpoints.ucDriveBase);
        headers.put("Referer", endpoints.ucDriveBase + "/");
        HttpResult res = httpGet(url, headers, 12_000, null);
        JSONObject json = parseJson(res.body);
        if (json.optInt("status", -1) != 2000000) {
            throw new IOException("获取 UC 网盘二维码失败（status=" + json.optInt("status", -1) + "）");
        }
        JSONObject data = json.optJSONObject("data");
        JSONObject members = data != null ? data.optJSONObject("members") : null;
        String token = members != null ? members.optString("token", "").trim() : "";
        if (token.isEmpty()) throw new IOException("UC 二维码 token 为空");
        String qrUrl =
                endpoints.ucSuBase
                        + "/1_n0ZCv?uc_param_str=dsdnfrpfbivesscpgimibtbmnijblauputogpintnwktprchmt&token="
                        + urlEncode(token)
                        + "&client_id=381&uc_biz_str=S%3Acustom%7CC%3Atitlebar_fix";
        return new QrSession(NetdiskStore.DRIVE_UC, qrUrl, token, "");
    }

    private PollResult pollUc(QrSession session) throws IOException {
        String st = session.cachedTicket.get();
        if (st == null || st.isEmpty()) {
            long now = System.currentTimeMillis();
            String url =
                    endpoints.ucOpenBase
                            + "/cas/ajax/getServiceTicketByQrcodeToken?client_id=381&v=1.2&token="
                            + urlEncode(session.token)
                            + "&request_id="
                            + now;
            Map<String, String> headers = new LinkedHashMap<>();
            headers.put("User-Agent", DESKTOP_UA);
            headers.put("Origin", endpoints.ucDriveBase);
            headers.put("Referer", endpoints.ucDriveBase + "/");
            HttpResult res = httpGet(url, headers, 12_000, null);
            JSONObject json = parseJson(res.body);
            int status = json.optInt("status", -1);
            if (status == 50004001) return new PollResult(STATE_WAITING, "", "", "等待 UC App 扫码");
            if (status == 50004002) return new PollResult(STATE_EXPIRED, "", "", "二维码已过期，请刷新");
            if (status != 2000000) return new PollResult(STATE_WAITING, "", "", "等待确认");
            JSONObject data = json.optJSONObject("data");
            JSONObject members = data != null ? data.optJSONObject("members") : null;
            st = members != null ? members.optString("service_ticket", "").trim() : "";
            if (st.isEmpty()) return new PollResult(STATE_WAITING, "", "", "等待确认");
            session.cachedTicket.set(st);
        }
        session.exchangingTicket.set(true);
        try {
            String url =
                    endpoints.ucDriveBase
                            + "/account/mobileinfo?pr=UCBrowser&fr=h5&st="
                            + urlEncode(st);
            Map<String, String> headers = new LinkedHashMap<>();
            headers.put("User-Agent", DESKTOP_UA);
            headers.put("Referer", endpoints.ucDriveBase + "/");
            HttpResult res = httpGet(url, headers, 15_000, session.cookies);
            JSONObject json = parseJsonSafe(res.body);
            JSONObject data = json != null ? json.optJSONObject("data") : null;
            String pus = data != null ? data.optString("__pus", "").trim() : "";
            if (!pus.isEmpty()) session.cookies.put("__pus", pus);
            String cookie = formatCookieMap(session.cookies);
            if (!NetdiskStore.isCredentialUsable(NetdiskStore.DRIVE_UC, cookie)) {
                throw new IOException("UC 登录未返回有效 __pus 凭据");
            }
            String uid = data != null ? data.optString("uid", "").trim() : "";
            String ownerId =
                    !uid.isEmpty()
                            ? ("uc:uid:" + uid)
                            : NetdiskStore.deriveCookieAccountId(NetdiskStore.DRIVE_UC, cookie);
            return new PollResult(STATE_CONFIRMED, cookie, ownerId, "UC 网盘登录成功");
        } finally {
            session.exchangingTicket.set(false);
        }
    }

    // ---- Baidu ----

    private QrSession startBaiduQr() throws IOException {
        long now = System.currentTimeMillis();
        String gid = UUID.randomUUID().toString().toUpperCase(Locale.ROOT);
        String cb = "tangram_guid_" + now;
        String url =
                endpoints.baiduPassportBase
                        + "/v2/api/getqrcode?lp=pc&qrloginfrom=pc&gid="
                        + urlEncode(gid)
                        + "&callback="
                        + cb
                        + "&apiver=v3&tt="
                        + now
                        + "&tpl=netdisk&logPage=traceId:pc_loginv5_"
                        + now
                        + ",logPage:loginv5&_="
                        + now;
        Map<String, String> headers = new LinkedHashMap<>();
        headers.put("User-Agent", DESKTOP_UA);
        headers.put("Referer", endpoints.baiduPanBase + "/");
        QrSession session = new QrSession(NetdiskStore.DRIVE_BAIDU, "", "", gid);
        HttpResult res = httpGet(url, headers, 12_000, session.cookies);
        JSONObject json = parseJsonpOrJson(res.body);
        String sign = json.optString("sign", "").trim();
        if (sign.isEmpty()) throw new IOException("获取百度网盘二维码失败");
        long serverSec = json.optLong("time", now / 1000L);
        String qrUrl =
                endpoints.baiduWappassBase
                        + "/wp/?qrlogin&t="
                        + serverSec
                        + "&error=0&sign="
                        + urlEncode(sign)
                        + "&cmd=login&lp=pc&adapter=3&qrloginfrom=pc";
        QrSession ready = new QrSession(NetdiskStore.DRIVE_BAIDU, qrUrl, sign, gid);
        ready.cookies.putAll(session.cookies);
        currentBaiduSession.set(ready);
        return ready;
    }

    private PollResult pollBaidu(QrSession session) throws IOException {
        currentBaiduSession.set(session);
        String ticket = session.cachedTicket.get();
        if (ticket == null || ticket.isEmpty()) {
            long now = System.currentTimeMillis();
            String cb = "tangram_guid_" + now;
            String url =
                    endpoints.baiduPassportBase
                            + "/channel/unicast?channel_id="
                            + urlEncode(session.token)
                            + "&gid="
                            + urlEncode(session.extra)
                            + "&tpl=netdisk&_sdkFrom=1&callback="
                            + cb
                            + "&apiver=v3&tt="
                            + now
                            + "&_="
                            + now;
            Map<String, String> headers = new LinkedHashMap<>();
            headers.put("User-Agent", DESKTOP_UA);
            headers.put("Referer", endpoints.baiduPanBase + "/");
            if (!session.cookies.isEmpty()) {
                headers.put("Cookie", formatCookieMap(session.cookies));
            }
            HttpResult res = httpGetAbortable(url, headers, 38_000, session.cookies, session);
            JSONObject json = parseJsonpOrJson(res.body);
            int errno = json.optInt("errno", -1);
            if (errno == 1) return new PollResult(STATE_WAITING, "", "", "等待百度网盘 App 扫码");
            if (errno != 0) return new PollResult(STATE_WAITING, "", "", "等待确认");
            String channelVRaw = json.optString("channel_v", "").trim();
            JSONObject channelV =
                    channelVRaw.startsWith("{")
                            ? parseJsonSafe(channelVRaw)
                            : json.optJSONObject("channel_v");
            if (channelV == null) return new PollResult(STATE_WAITING, "", "", "等待扫码");
            int st = channelV.optInt("status", -1);
            if (st == 1) return new PollResult(STATE_SCANNED, "", "", "已扫码，请在百度网盘 App 中确认登录");
            if (st == 2) return new PollResult(STATE_EXPIRED, "", "", "二维码已过期，请刷新");
            if (st != 0) return new PollResult(STATE_WAITING, "", "", "等待扫码");
            ticket = channelV.optString("v", "").trim();
            if (ticket.isEmpty()) return new PollResult(STATE_WAITING, "", "", "等待确认");
            session.cachedTicket.set(ticket);
        }

        session.exchangingTicket.set(true);
        try {
            long now = System.currentTimeMillis();
            String exchangeUrl =
                    endpoints.baiduPassportBase
                            + "/v3/login/main/qrbdusslogin?v="
                            + now
                            + "&bduss="
                            + urlEncode(ticket)
                            + "&u="
                            + urlEncode(endpoints.baiduPanBase + "/disk/home")
                            + "&loginVersion=v4&qrcode=1&tpl=netdisk&apiver=v3&tt="
                            + now;
            Map<String, String> headers = new LinkedHashMap<>();
            headers.put("User-Agent", DESKTOP_UA);
            headers.put("Referer", endpoints.baiduPanBase + "/");
            if (!session.cookies.isEmpty()) {
                headers.put("Cookie", formatCookieMap(session.cookies));
            }
            HttpResult exRes = httpGet(exchangeUrl, headers, 15_000, session.cookies);
            JSONObject exJson = parseJsonpOrJson(exRes.body);
            JSONObject data = exJson.optJSONObject("data");
            JSONObject sess = data != null ? data.optJSONObject("session") : null;
            if (sess != null) {
                putIfNonEmpty(session.cookies, "BDUSS", sess.optString("bduss", ""));
                putIfNonEmpty(session.cookies, "STOKEN", sess.optString("stoken", ""));
                putIfNonEmpty(session.cookies, "PTOKEN", sess.optString("ptoken", ""));
            }

            // Warmup & verify with user/info so raw one-use ticket is never mistakenly saved.
            String warmCookie = formatCookieMap(session.cookies);
            Map<String, String> panHeaders = new LinkedHashMap<>();
            panHeaders.put("User-Agent", DESKTOP_UA);
            panHeaders.put("Referer", endpoints.baiduPanBase + "/");
            panHeaders.put("Cookie", warmCookie);
            try {
                httpGet(endpoints.baiduPanBase + "/disk/home", panHeaders, 10_000, session.cookies);
            } catch (IOException ignored) {
            }
            panHeaders.put("Cookie", formatCookieMap(session.cookies));
            HttpResult verifyRes =
                    httpGet(
                            endpoints.baiduPanBase
                                    + "/rest/2.0/membership/user/info?method=query&clienttype=0&app_id=250528&web=1",
                            panHeaders,
                            12_000,
                            session.cookies);
            JSONObject verifyJson = parseJsonSafe(verifyRes.body);
            String finalBduss = NetdiskStore.cookieValueIgnoreCase(session.cookies, "BDUSS");
            if (finalBduss.isEmpty() || finalBduss.equals(ticket)) {
                throw new IOException("百度登录凭据未完成交换，请重试");
            }
            String ownerId = "";
            if (verifyJson != null) {
                int vErrno = verifyJson.optInt("errno", -1);
                long uk = verifyJson.optLong("uk", 0L);
                if (uk <= 0L) {
                    JSONObject uInfo = verifyJson.optJSONObject("user_info");
                    if (uInfo != null) uk = uInfo.optLong("uk", 0L);
                }
                if (vErrno != 0 && uk <= 0L) {
                    throw new IOException("百度账号状态校验未通过（errno=" + vErrno + "）");
                }
                if (uk > 0L) ownerId = "baidu:uk:" + uk;
            }
            String finalCookie = formatCookieMap(session.cookies);
            if (!NetdiskStore.isCredentialUsable(NetdiskStore.DRIVE_BAIDU, finalCookie)) {
                throw new IOException("百度网盘 Cookie 无效");
            }
            if (ownerId.isEmpty()) {
                ownerId = NetdiskStore.deriveCookieAccountId(NetdiskStore.DRIVE_BAIDU, finalCookie);
            }
            return new PollResult(STATE_CONFIRMED, finalCookie, ownerId, "百度网盘登录成功");
        } finally {
            session.exchangingTicket.set(false);
        }
    }

    // ---- Ali (Alipan) ----

    private QrSession startAliQr() throws IOException {
        long now = System.currentTimeMillis();
        String url =
                endpoints.aliPassportBase
                        + "/newlogin/qrcode/generate.do?appName=aliyun_drive&fromSite=52&appEntrance=web&_csrf_token=&isMobile=false&lang=zh_CN&returnUrl=&hsbegin="
                        + now;
        Map<String, String> headers = new LinkedHashMap<>();
        headers.put("User-Agent", DESKTOP_UA);
        HttpResult res = httpGet(url, headers, 12_000, null);
        JSONObject json = parseJson(res.body);
        JSONObject content = json.optJSONObject("content");
        JSONObject data = content != null ? content.optJSONObject("data") : null;
        if (data == null) throw new IOException("获取阿里云盘二维码失败");
        String codeContent = data.optString("codeContent", "").trim();
        String ck = data.optString("ck", "").trim();
        String t = String.valueOf(data.opt("t"));
        if (codeContent.isEmpty() || ck.isEmpty()) throw new IOException("阿里云盘二维码数据不完整");
        return new QrSession(NetdiskStore.DRIVE_ALI, codeContent, ck, t);
    }

    private PollResult pollAli(QrSession session) throws IOException {
        String url =
                endpoints.aliPassportBase
                        + "/newlogin/qrcode/query.do?appName=aliyun_drive&fromSite=52&_bx-v=2.2.3";
        String form =
                "ck="
                        + urlEncode(session.token)
                        + "&t="
                        + urlEncode(session.extra)
                        + "&appName=aliyun_drive&appEntrance=web&fromSite=52&isMobile=false&lang=zh_CN";
        Map<String, String> headers = new LinkedHashMap<>();
        headers.put("User-Agent", DESKTOP_UA);
        headers.put("Content-Type", "application/x-www-form-urlencoded; charset=UTF-8");
        HttpResult res = httpPostForm(url, headers, form, 12_000);
        JSONObject json = parseJson(res.body);
        JSONObject content = json.optJSONObject("content");
        JSONObject data = content != null ? content.optJSONObject("data") : null;
        if (data == null) return new PollResult(STATE_WAITING, "", "", "等待阿里云盘扫码");
        String status = data.optString("qrCodeStatus", "").trim().toUpperCase(Locale.ROOT);
        if ("NEW".equals(status) || status.isEmpty()) {
            return new PollResult(STATE_WAITING, "", "", "等待阿里云盘 App 扫码");
        }
        if ("SCANED".equals(status)) {
            return new PollResult(STATE_SCANNED, "", "", "已扫码，请在阿里云盘 App 中确认登录");
        }
        if ("EXPIRED".equals(status) || "CANCELED".equals(status)) {
            return new PollResult(STATE_EXPIRED, "", "", "二维码已过期，请刷新");
        }
        if (!"CONFIRMED".equals(status)) {
            return new PollResult(STATE_WAITING, "", "", "等待确认");
        }
        String bizExtB64 = data.optString("bizExt", "").trim();
        AliCredential parsed = parseAliBizExt(bizExtB64);
        if (parsed == null || parsed.refreshToken.isEmpty()) {
            throw new IOException("阿里云盘登录响应缺少 refreshToken");
        }
        String ownerId =
                !parsed.userId.isEmpty()
                        ? ("ali:uid:" + parsed.userId)
                        : NetdiskStore.deriveCookieAccountId(
                                NetdiskStore.DRIVE_ALI, "ali_token=" + parsed.refreshToken);
        return new PollResult(
                STATE_CONFIRMED, "ali_token=" + parsed.refreshToken, ownerId, "阿里云盘登录成功");
    }

    static final class AliCredential {
        final String refreshToken;
        final String userId;

        AliCredential(String refreshToken, String userId) {
            this.refreshToken = refreshToken;
            this.userId = userId;
        }
    }

    /**
     * Decodes Ali {@code bizExt} Base64 safely across UTF-8 and GBK encodings so GBK trail bytes
     * ({@code 0x5C}, {@code 0x22}) in Chinese {@code nickName} never corrupt JSON parsing.
     */
    static AliCredential parseAliBizExt(String base64) {
        if (base64 == null || base64.trim().isEmpty()) return null;
        byte[] raw = decodeBase64(base64.trim());
        if (raw == null || raw.length == 0) return null;
        String[] charsets = {"GBK", "UTF-8", "ISO-8859-1"};
        for (String csName : charsets) {
            try {
                if (!Charset.isSupported(csName)) continue;
                String decoded = new String(raw, Charset.forName(csName));
                JSONObject root = new JSONObject(decoded);
                JSONObject pds = root.optJSONObject("pds_login_result");
                if (pds == null) pds = root;
                String rt = pds.optString("refreshToken", "").trim();
                if (rt.isEmpty()) rt = pds.optString("refresh_token", "").trim();
                String uid = pds.optString("userId", "").trim();
                if (uid.isEmpty()) uid = pds.optString("user_id", "").trim();
                if (!rt.isEmpty()) return new AliCredential(rt, uid);
            } catch (Exception ignored) {
            }
        }
        // Regex fallback on ASCII-safe representation in case malformed nickname broke JSON string
        String ascii = new String(raw, StandardCharsets.ISO_8859_1);
        String rt = extractJsonStringValue(ascii, "refreshToken");
        if (rt.isEmpty()) rt = extractJsonStringValue(ascii, "refresh_token");
        String uid = extractJsonStringValue(ascii, "userId");
        if (uid.isEmpty()) uid = extractJsonStringValue(ascii, "user_id");
        if (!rt.isEmpty()) return new AliCredential(rt, uid);
        return null;
    }

    private static String extractJsonStringValue(String text, String key) {
        String marker = "\"" + key + "\"";
        int idx = text.indexOf(marker);
        if (idx < 0) return "";
        int colon = text.indexOf(':', idx + marker.length());
        if (colon < 0) return "";
        int q1 = text.indexOf('"', colon + 1);
        if (q1 < 0) return "";
        int q2 = text.indexOf('"', q1 + 1);
        if (q2 <= q1) return "";
        return text.substring(q1 + 1, q2).trim();
    }

    // ---- HTTP & JSON helpers ----

    private static final class HttpResult {
        final int code;
        final String body;

        HttpResult(int code, String body) {
            this.code = code;
            this.body = body;
        }
    }

    private static HttpResult httpGet(
            String urlStr,
            Map<String, String> headers,
            int timeoutMs,
            Map<String, String> cookieJar)
            throws IOException {
        return httpGetAbortable(urlStr, headers, timeoutMs, cookieJar, null);
    }

    private static HttpResult httpGetAbortable(
            String urlStr,
            Map<String, String> headers,
            int timeoutMs,
            Map<String, String> cookieJar,
            QrSession abortHolder)
            throws IOException {
        HttpURLConnection conn = ProxyAddress.openHttpConnection(new URL(urlStr));
        if (abortHolder != null) abortHolder.activeLongPoll.set(conn);
        try {
            conn.setRequestMethod("GET");
            conn.setInstanceFollowRedirects(false);
            conn.setConnectTimeout(Math.min(12_000, timeoutMs));
            conn.setReadTimeout(timeoutMs);
            if (headers != null) {
                for (Map.Entry<String, String> e : headers.entrySet()) {
                    conn.setRequestProperty(e.getKey(), e.getValue());
                }
            }
            int code = conn.getResponseCode();
            collectSetCookies(conn, cookieJar);
            InputStream stream = code >= 400 ? conn.getErrorStream() : conn.getInputStream();
            String body = stream != null ? readUtf8(stream, 2 * 1024 * 1024) : "";
            return new HttpResult(code, body);
        } finally {
            if (abortHolder != null) abortHolder.activeLongPoll.compareAndSet(conn, null);
            conn.disconnect();
        }
    }

    private static HttpResult httpPostForm(
            String urlStr, Map<String, String> headers, String formBody, int timeoutMs)
            throws IOException {
        HttpURLConnection conn = ProxyAddress.openHttpConnection(new URL(urlStr));
        try {
            conn.setRequestMethod("POST");
            conn.setDoOutput(true);
            conn.setInstanceFollowRedirects(false);
            conn.setConnectTimeout(timeoutMs);
            conn.setReadTimeout(timeoutMs);
            if (headers != null) {
                for (Map.Entry<String, String> e : headers.entrySet()) {
                    conn.setRequestProperty(e.getKey(), e.getValue());
                }
            }
            byte[] payload = formBody.getBytes(StandardCharsets.UTF_8);
            conn.setFixedLengthStreamingMode(payload.length);
            try (OutputStream out = conn.getOutputStream()) {
                out.write(payload);
            }
            int code = conn.getResponseCode();
            InputStream stream = code >= 400 ? conn.getErrorStream() : conn.getInputStream();
            String body = stream != null ? readUtf8(stream, 2 * 1024 * 1024) : "";
            return new HttpResult(code, body);
        } finally {
            conn.disconnect();
        }
    }

    static void collectSetCookies(HttpURLConnection conn, Map<String, String> jar) {
        if (conn == null || jar == null) return;
        Map<String, List<String>> hdrs = conn.getHeaderFields();
        if (hdrs == null) return;
        for (Map.Entry<String, List<String>> e : hdrs.entrySet()) {
            if (e.getKey() != null
                    && "Set-Cookie".equalsIgnoreCase(e.getKey())
                    && e.getValue() != null) {
                for (String raw : e.getValue()) {
                    if (raw == null) continue;
                    int semi = raw.indexOf(';');
                    String pair = semi >= 0 ? raw.substring(0, semi).trim() : raw.trim();
                    int eq = pair.indexOf('=');
                    if (eq > 0) {
                        String k = pair.substring(0, eq).trim();
                        String v = pair.substring(eq + 1).trim();
                        if (!k.isEmpty() && !v.isEmpty()) jar.put(k, v);
                    }
                }
            }
        }
    }

    static String formatCookieMap(Map<String, String> jar) {
        if (jar == null || jar.isEmpty()) return "";
        StringBuilder sb = new StringBuilder();
        for (Map.Entry<String, String> e : jar.entrySet()) {
            if (e.getKey() == null || e.getValue() == null || e.getValue().isEmpty()) continue;
            if (sb.length() > 0) sb.append("; ");
            sb.append(e.getKey()).append('=').append(e.getValue());
        }
        return sb.toString();
    }

    private static void putIfNonEmpty(Map<String, String> map, String key, String val) {
        if (val != null && !val.trim().isEmpty()) map.put(key, val.trim());
    }

    private static String readUtf8(InputStream in, int maxBytes) throws IOException {
        try (InputStream is = in) {
            ByteArrayOutputStream bos = new ByteArrayOutputStream();
            byte[] buf = new byte[8192];
            int total = 0;
            int n;
            while ((n = is.read(buf)) != -1) {
                total += n;
                if (total > maxBytes) throw new IOException("响应体超出大小限制");
                bos.write(buf, 0, n);
            }
            return new String(bos.toByteArray(), StandardCharsets.UTF_8);
        }
    }

    private static JSONObject parseJson(String body) throws IOException {
        try {
            return new JSONObject(body == null ? "" : body.trim());
        } catch (Exception e) {
            throw new IOException("响应不是有效 JSON");
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

    static JSONObject parseJsonpOrJson(String body) throws IOException {
        if (body == null) throw new IOException("空响应");
        String t = body.trim();
        if (t.startsWith("{")) return parseJson(t);
        int open = t.indexOf('(');
        int close = t.lastIndexOf(')');
        if (open >= 0 && close > open) {
            return parseJson(t.substring(open + 1, close));
        }
        throw new IOException("无法解析 JSONP 响应");
    }

    private static String urlEncode(String s) {
        try {
            return URLEncoder.encode(s == null ? "" : s, "UTF-8");
        } catch (Exception e) {
            return s == null ? "" : s;
        }
    }

    private static byte[] decodeBase64(String input) {
        String clean = input.replaceAll("\\s+", "");
        int len = clean.length();
        if (len == 0) return new byte[0];
        ByteArrayOutputStream out = new ByteArrayOutputStream((len * 3) / 4);
        int buf = 0;
        int bits = 0;
        for (int i = 0; i < len; i++) {
            char c = clean.charAt(i);
            if (c == '=') break;
            int v;
            if (c >= 'A' && c <= 'Z') v = c - 'A';
            else if (c >= 'a' && c <= 'z') v = c - 'a' + 26;
            else if (c >= '0' && c <= '9') v = c - '0' + 52;
            else if (c == '+' || c == '-') v = 62;
            else if (c == '/' || c == '_') v = 63;
            else continue;
            buf = (buf << 6) | v;
            bits += 6;
            if (bits >= 8) {
                bits -= 8;
                out.write((buf >> bits) & 0xff);
            }
        }
        return out.toByteArray();
    }
}
