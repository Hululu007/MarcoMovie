package com.pilipala.marcomovie.lite;

import javax.net.ssl.*;
import java.io.IOException;
import java.util.Arrays;

public final class LiteTlsChecks {
    static final class LegacySocket extends SSLSocket {
        final String[] supported;
        String[] enabled = {"TLSv1"};
        boolean closed;
        LegacySocket(String... supported) { this.supported = supported; }
        public String[] getSupportedProtocols() { return supported; }
        public String[] getEnabledProtocols() { return enabled; }
        public void setEnabledProtocols(String[] protocols) { enabled = protocols; }
        public String[] getSupportedCipherSuites() { return new String[0]; }
        public String[] getEnabledCipherSuites() { return new String[0]; }
        public void setEnabledCipherSuites(String[] suites) {}
        public SSLSession getSession() { return null; }
        public void addHandshakeCompletedListener(HandshakeCompletedListener listener) {}
        public void removeHandshakeCompletedListener(HandshakeCompletedListener listener) {}
        public void startHandshake() {}
        public void setUseClientMode(boolean mode) {}
        public boolean getUseClientMode() { return true; }
        public void setNeedClientAuth(boolean need) {}
        public boolean getNeedClientAuth() { return false; }
        public void setWantClientAuth(boolean want) {}
        public boolean getWantClientAuth() { return false; }
        public void setEnableSessionCreation(boolean flag) {}
        public boolean getEnableSessionCreation() { return true; }
        public void close() { closed = true; }
    }

    public static void main(String[] args) throws Exception {
        LegacySocket old = new LegacySocket("SSLv3", "TLSv1", "TLSv1.1", "TLSv1.2");
        NetworkTls.ModernTlsFactory.configure(old);
        if (!Arrays.equals(old.enabled, new String[]{"TLSv1.2"}))
            throw new AssertionError("Android 4.1-4.4 must explicitly enable supported TLS 1.2");
        LegacySocket modern = new LegacySocket("TLSv1", "TLSv1.2", "TLSv1.3");
        NetworkTls.ModernTlsFactory.configure(modern);
        if (!Arrays.equals(modern.enabled, new String[]{"TLSv1.2", "TLSv1.3"}))
            throw new AssertionError("Keep modern protocols enabled");
        LegacySocket unsupported = new LegacySocket("SSLv3", "TLSv1");
        try {
            NetworkTls.ModernTlsFactory.configure(unsupported);
            throw new AssertionError("API14 TLS must report an explicit compatibility failure");
        } catch (IOException expected) {
            if (!unsupported.closed || !expected.getMessage().contains("TLS 1.2"))
                throw new AssertionError("Unsupported socket must close with an actionable error");
        }
        TrustManager[] tms = NetworkTls.getDefaultTrustManagers();
        if (tms == null || tms.length == 0 || !(tms[0] instanceof X509TrustManager))
            throw new AssertionError("Default trust managers must include X509TrustManager");
        X509TrustManager tm = (X509TrustManager) tms[0];
        boolean hasIsrg = false;
        for (java.security.cert.X509Certificate cert : tm.getAcceptedIssuers()) {
            if (cert.getSubjectDN().getName().contains("ISRG Root X1")) {
                hasIsrg = true;
                break;
            }
        }
        if (!hasIsrg)
            throw new AssertionError("Composite TrustManager must include embedded ISRG Root X1");

        // M-A8: TrustManager, SSLContext, and SSLSocketFactory must be cached across connections
        TrustManager[] tms2 = NetworkTls.getDefaultTrustManagers();
        if (tms != tms2 || tms[0] != tms2[0])
            throw new AssertionError("Default TrustManager array and instance must be cached");

        SSLContext ctx1 = NetworkTls.context(null);
        SSLContext ctx2 = NetworkTls.context(null);
        if (ctx1 == null || ctx1 != ctx2)
            throw new AssertionError("Default SSLContext must be cached across calls");

        java.net.URL httpsUrl = new java.net.URL("https://tls.example/");
        HttpsURLConnection conn1 = (HttpsURLConnection) httpsUrl.openConnection();
        HttpsURLConnection conn2 = (HttpsURLConnection) httpsUrl.openConnection();
        NetworkTls.configure(conn1);
        NetworkTls.configure(conn2);
        if (conn1.getSSLSocketFactory() != conn2.getSSLSocketFactory())
            throw new AssertionError("HttpsURLConnection must reuse cached SSLSocketFactory");

        // M-A8: Loading Conscrypt throwing UnsatisfiedLinkError / Throwable must fall back to system TLS
        final UnsatisfiedLinkError jniError =
                new UnsatisfiedLinkError("dlopen failed: libconscrypt_jni.so is 32-bit");
        NetworkTls.lastFallbackCause = null;
        SSLContext fallbackCtx =
                NetworkTls.buildContext(
                        tms,
                        new NetworkTls.ProviderFactory() {
                            public java.security.Provider create() throws Throwable {
                                throw jniError;
                            }
                        });
        if (fallbackCtx == null || fallbackCtx.getSocketFactory() == null)
            throw new AssertionError("UnsatisfiedLinkError must fall back to a working system SSLContext");
        if (NetworkTls.lastFallbackCause != jniError)
            throw new AssertionError("Fallback cause must be recorded and logged when Conscrypt fails");

        final ExceptionInInitializerError initError = new ExceptionInInitializerError(jniError);
        SSLContext fallbackCtx2 =
                NetworkTls.buildContext(
                        tms,
                        new NetworkTls.ProviderFactory() {
                            public java.security.Provider create() throws Throwable {
                                throw initError;
                            }
                        });
        if (fallbackCtx2 == null || NetworkTls.lastFallbackCause != initError)
            throw new AssertionError("ExceptionInInitializerError must also fall back cleanly");

        System.out.println("PASS 8 Lite TLS capability checks");
    }
}
