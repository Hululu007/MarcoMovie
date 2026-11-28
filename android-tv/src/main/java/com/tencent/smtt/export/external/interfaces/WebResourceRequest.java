package com.tencent.smtt.export.external.interfaces;

import android.net.Uri;
import java.util.Collections;
import java.util.Map;

public class WebResourceRequest {
    private final android.webkit.WebResourceRequest delegate;

    public WebResourceRequest(android.webkit.WebResourceRequest delegate) {
        this.delegate = delegate;
    }

    public Uri getUrl() {
        return delegate == null ? null : delegate.getUrl();
    }

    public boolean isForMainFrame() {
        return delegate != null && delegate.isForMainFrame();
    }

    public String getMethod() {
        return delegate == null ? "GET" : delegate.getMethod();
    }

    public Map<String, String> getRequestHeaders() {
        return delegate == null ? Collections.emptyMap() : delegate.getRequestHeaders();
    }
}
