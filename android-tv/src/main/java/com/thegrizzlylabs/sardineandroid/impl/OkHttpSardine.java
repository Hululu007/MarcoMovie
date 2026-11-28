package com.thegrizzlylabs.sardineandroid.impl;

import com.thegrizzlylabs.sardineandroid.DavResource;
import com.thegrizzlylabs.sardineandroid.Sardine;
import java.io.IOException;
import java.io.InputStream;
import java.util.List;

/** Minimal Sardine stub preventing LinkageError/NoClassDefFoundError in spider JARs. */
public class OkHttpSardine implements Sardine {
    public OkHttpSardine() {}

    @Override
    public void setCredentials(String username, String password) {}

    @Override
    public List<DavResource> list(String url) throws IOException {
        throw new IOException("WebDAV 插件扩展暂不可用");
    }

    @Override
    public InputStream get(String url) throws IOException {
        throw new IOException("WebDAV 插件扩展暂不可用");
    }

    @Override
    public boolean exists(String url) throws IOException {
        return false;
    }
}
