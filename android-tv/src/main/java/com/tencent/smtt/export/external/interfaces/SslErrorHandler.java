package com.tencent.smtt.export.external.interfaces;

public class SslErrorHandler {
    private final android.webkit.SslErrorHandler delegate;

    public SslErrorHandler(android.webkit.SslErrorHandler delegate) {
        this.delegate = delegate;
    }

    public void proceed() {
        if (delegate != null) delegate.proceed();
    }

    public void cancel() {
        if (delegate != null) delegate.cancel();
    }
}
