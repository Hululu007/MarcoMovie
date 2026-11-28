package com.thegrizzlylabs.sardineandroid;

import java.io.IOException;
import java.io.InputStream;
import java.util.List;

public interface Sardine {
    void setCredentials(String username, String password);

    List<DavResource> list(String url) throws IOException;

    InputStream get(String url) throws IOException;

    boolean exists(String url) throws IOException;
}
