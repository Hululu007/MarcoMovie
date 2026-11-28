package com.tencent.smtt.sdk;

import android.content.Context;
import android.util.AttributeSet;

/** Thin WebView shim extending android.webkit.WebView for X5-referencing spider JARs. */
public class WebView extends android.webkit.WebView {
    private WebSettings settingsWrapper;

    public WebView(Context context) {
        super(context);
    }

    public WebView(Context context, AttributeSet attrs) {
        super(context, attrs);
    }

    public WebView(Context context, AttributeSet attrs, int defStyleAttr) {
        super(context, attrs, defStyleAttr);
    }

    public WebSettings getX5Settings() {
        if (settingsWrapper == null) {
            settingsWrapper = new WebSettings(super.getSettings());
        }
        return settingsWrapper;
    }

    public void setWebViewClient(final WebViewClient client) {
        if (client == null) {
            super.setWebViewClient(null);
            return;
        }
        super.setWebViewClient(
                new android.webkit.WebViewClient() {
                    @Override
                    public boolean shouldOverrideUrlLoading(
                            android.webkit.WebView view, String url) {
                        return client.shouldOverrideUrlLoading(WebView.this, url);
                    }

                    @Override
                    public void onPageFinished(android.webkit.WebView view, String url) {
                        client.onPageFinished(WebView.this, url);
                    }

                    @Override
                    public void onReceivedSslError(
                            android.webkit.WebView view,
                            android.webkit.SslErrorHandler handler,
                            android.net.http.SslError error) {
                        client.onReceivedSslError(
                                WebView.this,
                                new com.tencent.smtt.export.external.interfaces.SslErrorHandler(
                                        handler),
                                new com.tencent.smtt.export.external.interfaces.SslError(error));
                    }

                    @Override
                    public android.webkit.WebResourceResponse shouldInterceptRequest(
                            android.webkit.WebView view, String url) {
                        com.tencent.smtt.export.external.interfaces.WebResourceResponse r =
                                client.shouldInterceptRequest(WebView.this, url);
                        return r == null ? null : r.toNative();
                    }

                    @Override
                    public android.webkit.WebResourceResponse shouldInterceptRequest(
                            android.webkit.WebView view,
                            android.webkit.WebResourceRequest request) {
                        com.tencent.smtt.export.external.interfaces.WebResourceResponse r =
                                client.shouldInterceptRequest(
                                        WebView.this,
                                        new com.tencent.smtt.export.external.interfaces
                                                .WebResourceRequest(request));
                        return r != null
                                ? r.toNative()
                                : super.shouldInterceptRequest(view, request);
                    }
                });
    }

    public void setWebChromeClient(final WebChromeClient client) {
        if (client == null) {
            super.setWebChromeClient(null);
            return;
        }
        super.setWebChromeClient(
                new android.webkit.WebChromeClient() {
                    @Override
                    public void onProgressChanged(android.webkit.WebView view, int newProgress) {
                        client.onProgressChanged(WebView.this, newProgress);
                    }
                });
    }

    public void evaluateJavascript(String script, final ValueCallback<String> callback) {
        if (android.os.Build.VERSION.SDK_INT >= 19) {
            super.evaluateJavascript(
                    script,
                    callback == null ? null : value -> callback.onReceiveValue(value));
        }
    }
}
