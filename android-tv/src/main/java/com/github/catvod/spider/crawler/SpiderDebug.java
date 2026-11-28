package com.github.catvod.spider.crawler;

/** Compatibility logging shim for plugin JARs referencing spider.crawler.SpiderDebug. */
public final class SpiderDebug {
    public static void log(String message) {
        com.github.catvod.crawler.SpiderDebug.log(message);
    }

    public static void log(Throwable error) {
        com.github.catvod.crawler.SpiderDebug.log(error);
    }

    public static void log(Exception error) {
        com.github.catvod.crawler.SpiderDebug.log(error);
    }
}
