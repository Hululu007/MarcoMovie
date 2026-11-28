package com.tencent.smtt.sdk;

import com.tencent.smtt.export.external.interfaces.SslError;
import com.tencent.smtt.export.external.interfaces.SslErrorHandler;
import com.tencent.smtt.export.external.interfaces.WebResourceRequest;
import com.tencent.smtt.export.external.interfaces.WebResourceResponse;

/** X5 WebViewClient compatibility base class for spider JAR subclasses. */
public class WebViewClient {
    public boolean shouldOverrideUrlLoading(WebView view, String url) {
        return false;
    }

    public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
        return shouldOverrideUrlLoading(
                view, request != null && request.getUrl() != null ? request.getUrl().toString() : "");
    }

    public void onPageFinished(WebView view, String url) {}

    public void onReceivedSslError(WebView view, SslErrorHandler handler, SslError error) {
        if (handler != null) handler.cancel();
    }

    public WebResourceResponse shouldInterceptRequest(WebView view, String url) {
        return null;
    }

    public WebResourceResponse shouldInterceptRequest(WebView view, WebResourceRequest request) {
        return shouldInterceptRequest(
                view, request != null && request.getUrl() != null ? request.getUrl().toString() : "");
    }
}
