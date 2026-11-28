package com.tencent.smtt.export.external.interfaces;

public class SslError {
    private final android.net.http.SslError delegate;

    public SslError(android.net.http.SslError delegate) {
        this.delegate = delegate;
    }

    public String getUrl() {
        return delegate == null ? "" : delegate.getUrl();
    }
}
