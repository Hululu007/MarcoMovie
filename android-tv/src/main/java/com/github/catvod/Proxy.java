package com.github.catvod;

/** Host Proxy ABI expected by ProGuarded CatVod spider reflection. */
public final class Proxy {
    private static volatile int port = 9978;

    private Proxy() {}

    public static void set(int p) {
        if (p > 0) port = p;
    }

    public static int getPort() {
        return port;
    }

    public static String getUrl() {
        return "http://127.0.0.1:" + port + "/proxy";
    }

    public static String getHostUrl() {
        return "http://127.0.0.1:" + port;
    }
}
