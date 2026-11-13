// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
package com.pilipala.marcomovie.lite;

import android.util.Log;
import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.net.InetAddress;
import java.net.Socket;
import java.security.KeyStore;
import java.security.Provider;
import java.security.cert.CertificateException;
import java.security.cert.CertificateFactory;
import java.security.cert.X509Certificate;
import java.util.ArrayList;
import java.util.Arrays;
import javax.net.ssl.*;

/** Uses the packaged provider or the platform TLS implementation, retaining certificate checks. */
public final class NetworkTls {
    public static final String ISRG_ROOT_X1_PEM =
            "-----BEGIN CERTIFICATE-----\n"
                    + "MIIFazCCA1OgAwIBAgIRAIIQz7DSQONZRGPgu2OCiwAwDQYJKoZIhvcNAQELBQAw\n"
                    + "TzELMAkGA1UEBhMCVVMxKTAnBgNVBAoTIEludGVybmV0IFNlY3VyaXR5IFJlc2Vh\n"
                    + "cmNoIEdyb3VwMRUwEwYDVQQDEwxJU1JHIFJvb3QgWDEwHhcNMTUwNjA0MTEwNDM4\n"
                    + "WhcNMzUwNjA0MTEwNDM4WjBPMQswCQYDVQQGEwJVUzEpMCcGA1UEChMgSW50ZXJu\n"
                    + "ZXQgU2VjdXJpdHkgUmVzZWFyY2ggR3JvdXAxFTATBgNVBAMTDElTUkcgUm9vdCBY\n"
                    + "MTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAK3oJHP0FDfzm54rVygc\n"
                    + "h77ct984kIxuPOZXoHj3dcKi/vVqbvYATyjb3miGbESTtrFj/RQSa78f0uoxmyF+\n"
                    + "0TM8ukj13Xnfs7j/EvEhmkvBioZxaUpmZmyPfjxwv60pIgbz5MDmgK7iS4+3mX6U\n"
                    + "A5/TR5d8mUgjU+g4rk8Kb4Mu0UlXjIB0ttov0DiNewNwIRt18jA8+o+u3dpjq+sW\n"
                    + "T8KOEUt+zwvo/7V3LvSye0rgTBIlDHCNAymg4VMk7BPZ7hm/ELNKjD+Jo2FR3qyH\n"
                    + "B5T0Y3HsLuJvW5iB4YlcNHlsdu87kGJ55tukmi8mxdAQ4Q7e2RCOFvu396j3x+UC\n"
                    + "B5iPNgiV5+I3lg02dZ77DnKxHZu8A/lJBdiB3QW0KtZB6awBdpUKD9jf1b0SHzUv\n"
                    + "KBds0pjBqAlkd25HN7rOrFleaJ1/ctaJxQZBKT5ZPt0m9STJEadao0xAH0ahmbWn\n"
                    + "OlFuhjuefXKnEgV4We0+UXgVCwOPjdAvBbI+e0ocS3MFEvzG6uBQE3xDk3SzynTn\n"
                    + "jh8BCNAw1FtxNrQHusEwMFxIt4I7mKZ9YIqioymCzLq9gwQbooMDQaHWBfEbwrbw\n"
                    + "qHyGO0aoSCqI3Haadr8faqU9GY/rOPNk3sgrDQoo//fb4hVC1CLQJ13hef4Y53CI\n"
                    + "rU7m2Ys6xt0nUW7/vGT1M0NPAgMBAAGjQjBAMA4GA1UdDwEB/wQEAwIBBjAPBgNV\n"
                    + "HRMBAf8EBTADAQH/MB0GA1UdDgQWBBR5tFnme7bl5AFzgAiIyBpY9umbbjANBgkq\n"
                    + "hkiG9w0BAQsFAAOCAgEAVR9YqbyyqFDQDLHYGmkgJykIrGF1XIpu+ILlaS/V9lZL\n"
                    + "ubhzEFnTIZd+50xx+7LSYK05qAvqFyFWhfFQDlnrzuBZ6brJFe+GnY+EgPbk6ZGQ\n"
                    + "3BebYhtF8GaV0nxvwuo77x/Py9auJ/GpsMiu/X1+mvoiBOv/2X/qkSsisRcOj/KK\n"
                    + "NFtY2PwByVS5uCbMiogziUwthDyC3+6WVwW6LLv3xLfHTjuCvjHIInNzktHCgKQ5\n"
                    + "ORAzI4JMPJ+GslWYHb4phowim57iaztXOoJwTdwJx4nLCgdNbOhdjsnvzqvHu7Ur\n"
                    + "TkXWStAmzOVyyghqpZXjFaH3pO3JLF+l+/+sKAIuvtd7u+Nxe5AW0wdeRlN8NwdC\n"
                    + "jNPElpzVmbUq4JUagEiuTDkHzsxHpFKVK7q4+63SM1N95R1NbdWhscdCb+ZAJzVc\n"
                    + "oyi3B43njTOQ5yOf+1CceWxG1bQVs5ZufpsMljq4Ui0/1lvh+wjChP4kqKOJ2qxq\n"
                    + "4RgqsahDYVvTH9w7jXbyLeiNdd8XM2w9U/t7y0Ff/9yi0GE44Za4rF2LN9d11TPA\n"
                    + "mRGunUHBcnWEvgJBQl9nJEiU0Zsnvgc/ubhPgXRR4Xq37Z0j4r7g1SgEEzwxA57d\n"
                    + "emyPxgcYxn/eR44/KJ4EBs+lVDR3veyJm+kXQ99b21/+jh5Xos1AnX5iItreGCc=\n"
                    + "-----END CERTIFICATE-----";

    private static final String TAG = "NetworkTls";
    private static final Object CACHE_LOCK = new Object();
    private static volatile TrustManager[] cachedTrustManagers;
    private static volatile SSLContext cachedSslContext;
    private static volatile SSLSocketFactory cachedSocketFactory;
    static volatile Throwable lastFallbackCause;

    interface ProviderFactory {
        Provider create() throws Throwable;
    }

    private static final ProviderFactory DEFAULT_CONSCRYPT_FACTORY =
            new ProviderFactory() {
                public Provider create() throws Throwable {
                    Class<?> type = Class.forName("org.conscrypt.Conscrypt");
                    return (Provider) type.getMethod("newProvider").invoke(null);
                }
            };

    public static TrustManager[] getDefaultTrustManagers() {
        TrustManager[] existing = cachedTrustManagers;
        if (existing != null) {
            return existing;
        }
        synchronized (CACHE_LOCK) {
            if (cachedTrustManagers == null) {
                cachedTrustManagers = buildDefaultTrustManagers();
            }
            return cachedTrustManagers;
        }
    }

    private static TrustManager[] buildDefaultTrustManagers() {
        X509TrustManager systemTm = null;
        try {
            TrustManagerFactory tmf =
                    TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm());
            tmf.init((KeyStore) null);
            for (TrustManager tm : tmf.getTrustManagers()) {
                if (tm instanceof X509TrustManager) {
                    systemTm = (X509TrustManager) tm;
                    break;
                }
            }
        } catch (Throwable ignored) {
        }

        X509TrustManager isrgTm = null;
        try {
            CertificateFactory cf = CertificateFactory.getInstance("X.509");
            ByteArrayInputStream bais =
                    new ByteArrayInputStream(ISRG_ROOT_X1_PEM.getBytes("UTF-8"));
            X509Certificate isrgCert = (X509Certificate) cf.generateCertificate(bais);
            KeyStore ks = KeyStore.getInstance(KeyStore.getDefaultType());
            ks.load(null, null);
            ks.setCertificateEntry("isrg_root_x1", isrgCert);

            TrustManagerFactory isrgTmf =
                    TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm());
            isrgTmf.init(ks);
            for (TrustManager tm : isrgTmf.getTrustManagers()) {
                if (tm instanceof X509TrustManager) {
                    isrgTm = (X509TrustManager) tm;
                    break;
                }
            }
        } catch (Throwable ignored) {
        }

        final X509TrustManager finalSystemTm = systemTm;
        final X509TrustManager finalIsrgTm = isrgTm;
        X509TrustManager compositeTm =
                new X509TrustManager() {
                    public void checkClientTrusted(X509Certificate[] chain, String authType)
                            throws CertificateException {
                        if (finalSystemTm != null) {
                            finalSystemTm.checkClientTrusted(chain, authType);
                        }
                    }

                    public void checkServerTrusted(X509Certificate[] chain, String authType)
                            throws CertificateException {
                        try {
                            if (finalSystemTm != null) {
                                finalSystemTm.checkServerTrusted(chain, authType);
                                return;
                            }
                        } catch (CertificateException e) {
                            // Fall through to ISRG Root X1 trust manager
                        }
                        if (finalIsrgTm != null) {
                            finalIsrgTm.checkServerTrusted(chain, authType);
                        } else {
                            throw new CertificateException("No trust manager available for validation");
                        }
                    }

                    public X509Certificate[] getAcceptedIssuers() {
                        ArrayList<X509Certificate> list = new ArrayList<X509Certificate>();
                        if (finalSystemTm != null) {
                            list.addAll(Arrays.asList(finalSystemTm.getAcceptedIssuers()));
                        }
                        if (finalIsrgTm != null) {
                            list.addAll(Arrays.asList(finalIsrgTm.getAcceptedIssuers()));
                        }
                        return list.toArray(new X509Certificate[list.size()]);
                    }
                };
        return new TrustManager[] {compositeTm};
    }

    static SSLContext buildContext(TrustManager[] trust, ProviderFactory conscryptFactory)
            throws Exception {
        TrustManager[] effectiveTrust = trust != null ? trust : getDefaultTrustManagers();
        try {
            Provider provider = conscryptFactory.create();
            SSLContext conscryptCtx = SSLContext.getInstance("TLS", provider);
            conscryptCtx.init(null, effectiveTrust, null);
            return conscryptCtx;
        } catch (Throwable failure) {
            lastFallbackCause = failure;
            Log.w(
                    TAG,
                    "Conscrypt TLS provider unavailable; falling back to platform TLS",
                    failure);
        }
        SSLContext fallback = SSLContext.getInstance("TLS");
        fallback.init(null, effectiveTrust, null);
        return fallback;
    }

    static SSLContext getDefaultContext() throws Exception {
        SSLContext existing = cachedSslContext;
        if (existing != null) {
            return existing;
        }
        synchronized (CACHE_LOCK) {
            if (cachedSslContext == null) {
                cachedSslContext =
                        buildContext(getDefaultTrustManagers(), DEFAULT_CONSCRYPT_FACTORY);
            }
            return cachedSslContext;
        }
    }

    static SSLSocketFactory getDefaultSocketFactory() throws Exception {
        SSLSocketFactory existing = cachedSocketFactory;
        if (existing != null) {
            return existing;
        }
        synchronized (CACHE_LOCK) {
            if (cachedSocketFactory == null) {
                cachedSocketFactory = new ModernTlsFactory(getDefaultContext().getSocketFactory());
            }
            return cachedSocketFactory;
        }
    }

    static SSLContext context(TrustManager[] trust) throws Exception {
        if (trust == null) {
            return getDefaultContext();
        }
        return buildContext(trust, DEFAULT_CONSCRYPT_FACTORY);
    }

    public static void configure(HttpsURLConnection connection) throws java.io.IOException {
        try {
            connection.setSSLSocketFactory(getDefaultSocketFactory());
        } catch (Exception failure) {
            throw new java.io.IOException("HTTPS 加密组件无法初始化", failure);
        } catch (LinkageError failure) {
            throw new java.io.IOException("HTTPS 加密组件不适用于此设备", failure);
        }
    }

    static final class ModernTlsFactory extends SSLSocketFactory {
        private final SSLSocketFactory delegate;

        ModernTlsFactory(SSLSocketFactory delegate) {
            this.delegate = delegate;
        }

        static Socket configure(Socket socket) throws IOException {
            if (!(socket instanceof SSLSocket)) return socket;
            SSLSocket ssl = (SSLSocket) socket;
            ArrayList<String> protocols = new ArrayList<String>();
            for (String protocol : ssl.getSupportedProtocols())
                if ("TLSv1.2".equals(protocol) || "TLSv1.3".equals(protocol))
                    protocols.add(protocol);
            if (protocols.isEmpty()) {
                try {
                    socket.close();
                } catch (IOException ignored) {
                }
                throw new IOException("此系统的安全连接组件不支持 TLS 1.2，请升级系统或使用兼容的片源");
            }
            ssl.setEnabledProtocols(protocols.toArray(new String[protocols.size()]));
            return socket;
        }

        public String[] getDefaultCipherSuites() {
            return delegate.getDefaultCipherSuites();
        }

        public String[] getSupportedCipherSuites() {
            return delegate.getSupportedCipherSuites();
        }

        public Socket createSocket() throws IOException {
            return configure(delegate.createSocket());
        }

        public Socket createSocket(Socket socket, String host, int port, boolean close)
                throws IOException {
            return configure(delegate.createSocket(socket, host, port, close));
        }

        public Socket createSocket(String host, int port) throws IOException {
            return configure(delegate.createSocket(host, port));
        }

        public Socket createSocket(
                String host, int port, InetAddress local, int localPort)
                throws IOException {
            return configure(delegate.createSocket(host, port, local, localPort));
        }

        public Socket createSocket(InetAddress host, int port) throws IOException {
            return configure(delegate.createSocket(host, port));
        }

        public Socket createSocket(
                InetAddress host, int port, InetAddress local, int localPort)
                throws IOException {
            return configure(delegate.createSocket(host, port, local, localPort));
        }
    }
}
