package com.tencent.smtt.sdk;

/** Thin CookieManager shim backed by android.webkit.CookieManager. */
public class CookieManager {
    private static final CookieManager INSTANCE = new CookieManager();
    private final android.webkit.CookieManager delegate = android.webkit.CookieManager.getInstance();

    public static CookieManager getInstance() {
        return INSTANCE;
    }

    public void setAcceptCookie(boolean accept) {
        delegate.setAcceptCookie(accept);
    }

    public boolean acceptCookie() {
        return delegate.acceptCookie();
    }

    public void setAcceptThirdPartyCookies(WebView webview, boolean accept) {
        if (webview != null && android.os.Build.VERSION.SDK_INT >= 21) {
            delegate.setAcceptThirdPartyCookies(webview, accept);
        }
    }

    public void setCookie(String url, String value) {
        delegate.setCookie(url, value);
    }

    public String getCookie(String url) {
        return delegate.getCookie(url);
    }

    public void removeAllCookie() {
        if (android.os.Build.VERSION.SDK_INT >= 21) {
            delegate.removeAllCookies(null);
        } else {
            delegate.removeAllCookie();
        }
    }

    public void removeAllCookies(android.webkit.ValueCallback<Boolean> callback) {
        if (android.os.Build.VERSION.SDK_INT >= 21) {
            delegate.removeAllCookies(callback);
        } else if (callback != null) {
            delegate.removeAllCookie();
            callback.onReceiveValue(Boolean.TRUE);
        }
    }

    public void flush() {
        if (android.os.Build.VERSION.SDK_INT >= 21) {
            delegate.flush();
        }
    }
}
