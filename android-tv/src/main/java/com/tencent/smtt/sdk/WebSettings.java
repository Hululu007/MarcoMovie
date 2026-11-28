package com.tencent.smtt.sdk;

/** Thin wrapper delegating X5 WebSettings calls to android.webkit.WebSettings. */
public class WebSettings {
    public static final int LOAD_DEFAULT = android.webkit.WebSettings.LOAD_DEFAULT;
    public static final int LOAD_NO_CACHE = android.webkit.WebSettings.LOAD_NO_CACHE;

    private final android.webkit.WebSettings delegate;

    public WebSettings(android.webkit.WebSettings delegate) {
        this.delegate = delegate;
    }

    public void setJavaScriptEnabled(boolean flag) {
        delegate.setJavaScriptEnabled(flag);
    }

    public void setDomStorageEnabled(boolean flag) {
        delegate.setDomStorageEnabled(flag);
    }

    public void setUserAgentString(String ua) {
        delegate.setUserAgentString(ua);
    }

    public String getUserAgentString() {
        return delegate.getUserAgentString();
    }

    public void setUseWideViewPort(boolean use) {
        delegate.setUseWideViewPort(use);
    }

    public void setLoadWithOverviewMode(boolean overview) {
        delegate.setLoadWithOverviewMode(overview);
    }

    public void setCacheMode(int mode) {
        delegate.setCacheMode(mode);
    }

    public void setMixedContentMode(int mode) {
        if (android.os.Build.VERSION.SDK_INT >= 21) {
            delegate.setMixedContentMode(mode);
        }
    }

    public void setBlockNetworkImage(boolean flag) {
        delegate.setBlockNetworkImage(flag);
    }

    public void setLoadsImagesAutomatically(boolean flag) {
        delegate.setLoadsImagesAutomatically(flag);
    }
}
