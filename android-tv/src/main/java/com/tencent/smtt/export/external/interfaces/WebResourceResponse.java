package com.tencent.smtt.export.external.interfaces;

import java.io.InputStream;
import java.util.Map;

public class WebResourceResponse {
    private final android.webkit.WebResourceResponse delegate;

    public WebResourceResponse(String mimeType, String encoding, InputStream data) {
        this.delegate = new android.webkit.WebResourceResponse(mimeType, encoding, data);
    }

    public WebResourceResponse(
            String mimeType,
            String encoding,
            int statusCode,
            String reasonPhrase,
            Map<String, String> responseHeaders,
            InputStream data) {
        if (android.os.Build.VERSION.SDK_INT >= 21) {
            this.delegate =
                    new android.webkit.WebResourceResponse(
                            mimeType, encoding, statusCode, reasonPhrase, responseHeaders, data);
        } else {
            this.delegate = new android.webkit.WebResourceResponse(mimeType, encoding, data);
        }
    }

    public android.webkit.WebResourceResponse toNative() {
        return delegate;
    }
}
