package com.thegrizzlylabs.sardineandroid;

import java.util.Date;

public class DavResource {
    public String getName() {
        return "";
    }

    public String getPath() {
        return "";
    }

    public boolean isDirectory() {
        return false;
    }

    public Long getContentLength() {
        return 0L;
    }

    public Date getModified() {
        return new Date(0L);
    }
}
