package com.tencent.smtt.sdk;

import android.content.Context;

/** Minimal X5 QbSdk compatibility shim returning false so dual-path spiders use native WebKit. */
public final class QbSdk {
    public interface PreInitCallback {
        void onCoreInitFinished();

        void onViewInitFinished(boolean isX5Core);
    }

    public interface TbsListener {
        void onDownloadFinish(int i);

        void onInstallFinish(int i);

        void onDownloadProgress(int i);
    }

    public static void initX5Environment(Context context, PreInitCallback cb) {
        if (cb != null) {
            cb.onCoreInitFinished();
            cb.onViewInitFinished(false);
        }
    }

    public static boolean isTbsCoreInited() {
        return false;
    }

    public static void setCoreMinVersion(int version) {}

    public static void setDownloadWithoutWifi(boolean value) {}

    public static void setTbsListener(TbsListener listener) {}

    public static int getTbsVersion(Context context) {
        return 0;
    }

    public static void reset(Context context) {}
}
