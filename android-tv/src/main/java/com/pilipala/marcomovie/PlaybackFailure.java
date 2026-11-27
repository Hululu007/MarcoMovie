package com.pilipala.marcomovie;

/** User-facing categories contain no URLs, response bodies or account tokens. */
final class PlaybackFailure {
    static boolean decoderFallback(int code) {
        return code == 4001
                || code == 4002
                || code == 4003
                || code == 4004
                || code == 4005
                || code == 5001
                || code == 5002;
    }

    static boolean isTlsError(Throwable error) {
        int depth = 0;
        for (Throwable cur = error; cur != null && depth < 16; cur = cur.getCause(), depth++) {
            if (cur instanceof javax.net.ssl.SSLException
                    || cur instanceof java.security.cert.CertificateException
                    || cur instanceof java.security.cert.CertPathValidatorException) {
                return true;
            }
            String cls = cur.getClass().getName();
            if (cls != null
                    && (cls.contains("SSLHandshake")
                            || cls.contains("CertPathValidator")
                            || cls.contains("TrustAnchor"))) {
                return true;
            }
        }
        return false;
    }

    static String message(int code, int http) {
        return message(code, http, false);
    }

    static String message(int code, int http, boolean tlsError) {
        if (tlsError) return "HTTPS 安全证书或 TLS 握手失败（旧系统证书链可能不支持此源），请切换其他线路或检查电视系统时间。";
        if (http == 401 || http == 403) return "服务拒绝访问。可能是登录、权限或临时链接失效，请刷新线路或检查账号。";
        if (http == 404 || http == 410) return "播放链接已失效或内容不存在，请刷新线路。";
        if (code >= 2000 && code < 3000) return "媒体连接失败。请检查网络或刷新线路重试。";
        if (code >= 3000 && code < 4000) return "返回的数据无法识别为可播放媒体，请尝试其他线路。";
        if (code >= 4000 && code < 5000) return "当前设备与解码组件无法处理这段媒体。可尝试其他编码或较低清晰度的版本。";
        if (code >= 5000 && code < 6000) return "音频解码或输出失败。请尝试其他音轨或播放器。";
        if (code >= 6000 && code < 7000) return "内容授权不可用，请检查服务授权与设备支持。";
        return "播放失败，请刷新重试或选择其他线路。";
    }
}
