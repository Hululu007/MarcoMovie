package com.pilipala.marcomovie;

import android.content.Context;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;
import android.view.Surface;
import androidx.media3.common.C;
import androidx.media3.common.MediaItem;
import androidx.media3.common.MimeTypes;
import androidx.media3.common.PlaybackException;
import androidx.media3.common.Player;
import androidx.media3.common.VideoSize;
import androidx.media3.common.util.Util;
import androidx.media3.datasource.DefaultDataSource;
import androidx.media3.datasource.DefaultHttpDataSource;
import androidx.media3.exoplayer.DefaultRenderersFactory;
import androidx.media3.exoplayer.ExoPlayer;
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.Callable;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.FutureTask;
import java.util.concurrent.TimeUnit;

/** Small Media3 adapter for the app's existing TV controls. All player access is
 * marshalled to the main looper, including reads made by device instrumentation. */
public class MoviePlayer {
    public interface OnPreparedListener {
        void onPrepared(MoviePlayer player);
    }

    public interface OnCompletionListener {
        void onCompletion(MoviePlayer player);
    }

    public interface OnVideoSizeChangedListener {
        void onVideoSizeChanged(MoviePlayer player, int width, int height);
    }

    public interface OnErrorListener {
        boolean onError(MoviePlayer player, int what, int extra);
    }

    private static volatile String sDefaultUserAgent = null;

    static String defaultUserAgent(Context context) {
        if (sDefaultUserAgent != null) return sDefaultUserAgent;
        String version = null;
        if (context != null) {
            try {
                version =
                        context.getPackageManager()
                                .getPackageInfo(context.getPackageName(), 0)
                                .versionName;
            } catch (Exception ignored) {
            }
        }
        if (version == null || version.isEmpty() || "未知".equals(version)) {
            version = "0.5.22";
        }
        sDefaultUserAgent = "MarcoMovie/" + version;
        return sDefaultUserAgent;
    }

    private final Handler main = new Handler(Looper.getMainLooper());
    private final Context context;
    private ExoPlayer exo;
    private Uri uri;
    private Map<String, String> headers = Collections.emptyMap();
    private OnPreparedListener preparedListener;
    private OnCompletionListener completionListener;
    private OnVideoSizeChangedListener sizeListener;
    private OnErrorListener errorListener;
    private OnHdrChangedListener hdrChangedListener;
    private boolean readySent, unsupportedVideo, hdrVideo, unsupportedDvProfile5;
    private volatile boolean released;
    private int preparation;
    private volatile RequestScope probeScope;
    private long prepareStarted, firstFrameMs = -1;
    private String lastError = "";
    private String videoDecoder = "", audioDecoder = "";
    private int lastHttpStatus, lastErrorTrack;
    private org.json.JSONObject options = new org.json.JSONObject();
    private DefaultMediaSourceFactory mediaSourceFactory;
    private String mediaMime;
    private boolean hlsFallbackAttempted;
    private final boolean ijkMode;

    public interface OnHdrChangedListener {
        void onHdrChanged(boolean hdr);
    }

    public interface SubtitleListener {
        void text(CharSequence text);
    }

    private SubtitleListener subtitleListener;

    public interface CueListener {
        void cues(androidx.media3.common.text.CueGroup group);
    }

    private CueListener cueListener;

    public static MoviePlayer createIjk(Context context) {
        return new MoviePlayer(context, true, -1, true);
    }

    public MoviePlayer(Context context) {
        this(context, true, -1, false);
    }

    public MoviePlayer(Context context, int decoderMode) {
        this(context, true, decoderMode, false);
    }

    public MoviePlayer(Context context, int decoderMode, boolean forceIjk) {
        this(context, true, decoderMode, forceIjk);
    }

    protected MoviePlayer(Context context, boolean initializeExo) {
        this(context, initializeExo, -1, false);
    }

    private MoviePlayer(
            Context context, boolean initializeExo, int requestedDecoder, boolean forceIjk) {
        this.context = context.getApplicationContext();
        this.ijkMode = forceIjk;
        if (!initializeExo) return;
        onMain(
                () -> {
                    int userDecoder =
                            this.context
                                    .getSharedPreferences(Prefs.FILE, 0)
                                    .getInt(Prefs.DECODER_MODE, 0);
                    int decoderMode =
                            requestedDecoder >= 0
                                    ? requestedDecoder
                                    : (this.ijkMode && userDecoder == 0 ? 3 : userDecoder);
                    DefaultRenderersFactory renderers =
                            new DecoderRenderersFactory(this.context, decoderMode);
                    renderers.setMediaCodecSelector(
                            (mime, secure, tunneling) -> {
                                java.util.List<androidx.media3.exoplayer.mediacodec.MediaCodecInfo>
                                        raw =
                                                new java.util.ArrayList<>(
                                                        androidx.media3.exoplayer.mediacodec
                                                                .MediaCodecUtil.getDecoderInfos(
                                                                mime, secure, tunneling));
                                if (MimeTypes.AUDIO_E_AC3_JOC.equals(mime)) {
                                    for (androidx.media3.exoplayer.mediacodec.MediaCodecInfo eac3 :
                                            androidx.media3.exoplayer.mediacodec.MediaCodecUtil
                                                    .getDecoderInfos(
                                                            MimeTypes.AUDIO_E_AC3,
                                                            secure,
                                                            tunneling)) {
                                        boolean exists = false;
                                        for (androidx.media3.exoplayer.mediacodec.MediaCodecInfo c :
                                                raw) {
                                            if (c.name.equals(eac3.name)) {
                                                exists = true;
                                                break;
                                            }
                                        }
                                        if (!exists) raw.add(eac3);
                                    }
                                }
                                if (mime.startsWith("video/") && decoderMode != 2) {
                                    raw = DecoderRenderersFactory.prioritizeHardwareDecoders(raw);
                                }
                                if (decoderMode == 0 || decoderMode == 3) return raw;
                                java.util.List<androidx.media3.exoplayer.mediacodec.MediaCodecInfo>
                                        selected = new java.util.ArrayList<>();
                                for (androidx.media3.exoplayer.mediacodec.MediaCodecInfo codec :
                                        raw)
                                    if (!mime.startsWith("video/")
                                            || (decoderMode == 2
                                                    ? DecoderRenderersFactory.isSoftwareCodec(codec)
                                                    : (!DecoderRenderersFactory.isSoftwareCodec(
                                                                    codec)
                                                            && codec.hardwareAccelerated)))
                                        selected.add(codec);
                                return selected.isEmpty() ? raw : selected;
                            });
                    int buffer =
                            Math.max(
                                            15,
                                            Math.min(
                                                    50,
                                                    this.context
                                                            .getSharedPreferences(Prefs.FILE, 0)
                                                            .getInt(Prefs.BUFFER_SECONDS, 30)))
                                    * 1000;
                    int minBuffer = Math.min(12000, buffer);
                    int maxBuffer = Math.max(20000, buffer);
                    int startBufferMs = this.ijkMode ? 400 : 500;
                    int rebufferMs = this.ijkMode ? 1000 : 1400;
                    exo =
                            new ExoPlayer.Builder(this.context, renderers)
                                    .setVideoChangeFrameRateStrategy(
                                            C.VIDEO_CHANGE_FRAME_RATE_STRATEGY_OFF)
                                    .setLoadControl(
                                            new androidx.media3.exoplayer.DefaultLoadControl
                                                            .Builder()
                                                    .setBufferDurationsMs(
                                                            minBuffer,
                                                            maxBuffer,
                                                            startBufferMs,
                                                            rebufferMs)
                                                    .setPrioritizeTimeOverSizeThresholds(true)
                                                    .setTargetBufferBytes(64 * 1024 * 1024)
                                                    .build())
                                    .setLooper(Looper.getMainLooper())
                                    .build();
                    androidx.media3.exoplayer.trackselection.DefaultTrackSelector.Parameters.Builder
                            trackParams =
                                    new androidx.media3.exoplayer.trackselection
                                                    .DefaultTrackSelector.Parameters.Builder(
                                                    this.context)
                                            .setExceedRendererCapabilitiesIfNecessary(true)
                                            .setExceedVideoConstraintsIfNecessary(true)
                                            .setExceedAudioConstraintsIfNecessary(true);
                    android.content.SharedPreferences sp =
                            this.context.getSharedPreferences(Prefs.FILE, 0);
                    if (sp.getBoolean(Prefs.PREFER_AAC, false))
                        trackParams.setPreferredAudioMimeTypes(MimeTypes.AUDIO_AAC);
                    if (!this.ijkMode && sp.getBoolean(Prefs.TUNNELED_PLAYBACK, false))
                        trackParams.setTunnelingEnabled(true);
                    exo.setTrackSelectionParameters(trackParams.build());
                    exo.addAnalyticsListener(
                            new androidx.media3.exoplayer.analytics.AnalyticsListener() {
                                @Override
                                public void onVideoDecoderInitialized(
                                        EventTime time,
                                        String name,
                                        long completed,
                                        long duration) {
                                    videoDecoder = name;
                                }

                                @Override
                                public void onAudioDecoderInitialized(
                                        EventTime time,
                                        String name,
                                        long completed,
                                        long duration) {
                                    audioDecoder = name;
                                }

                                @Override
                                public void onRenderedFirstFrame(
                                        EventTime time, Object output, long renderTimeMs) {
                                    firstFrameMs =
                                            android.os.SystemClock.elapsedRealtime()
                                                    - prepareStarted;
                                }
                            });
                    exo.addListener(
                            new Player.Listener() {
                                @Override
                                public void onPlaybackStateChanged(int state) {
                                    if (released) return;
                                    if (state == Player.STATE_READY
                                            && !readySent
                                            && !unsupportedVideo) {
                                        readySent = true;
                                        if (preparedListener != null)
                                            preparedListener.onPrepared(MoviePlayer.this);
                                    } else if (state == Player.STATE_ENDED
                                            && completionListener != null)
                                        completionListener.onCompletion(MoviePlayer.this);
                                }

                                @Override
                                public void onTracksChanged(androidx.media3.common.Tracks tracks) {
                                    boolean video = false, supported = false;
                                    boolean detectedHdr = false, detectedDvP5 = false;
                                    for (androidx.media3.common.Tracks.Group group :
                                            tracks.getGroups())
                                        if (group.getType() == C.TRACK_TYPE_VIDEO) {
                                            video = true;
                                            supported |=
                                                    group.isSupported(true) || group.isSelected();
                                            for (int i = 0; i < group.length; i++) {
                                                androidx.media3.common.Format f =
                                                        group.getTrackFormat(i);
                                                if (DecoderRenderersFactory.isDolbyVisionProfile5(
                                                        f)) {
                                                    detectedDvP5 = true;
                                                }
                                                if (group.isTrackSelected(i)
                                                        && (androidx.media3.common.ColorInfo
                                                                        .isTransferHdr(f.colorInfo)
                                                                || MimeTypes.VIDEO_DOLBY_VISION
                                                                        .equals(
                                                                                f.sampleMimeType))) {
                                                    detectedHdr = true;
                                                }
                                            }
                                        }
                                    if (hdrVideo != detectedHdr) {
                                        hdrVideo = detectedHdr;
                                        if (hdrChangedListener != null) {
                                            hdrChangedListener.onHdrChanged(hdrVideo);
                                        }
                                    }
                                    if (video && !supported && !unsupportedVideo) {
                                        unsupportedVideo = true;
                                        unsupportedDvProfile5 = detectedDvP5;
                                        lastError = "ERROR_CODE_DECODING_FORMAT_UNSUPPORTED";
                                        lastErrorTrack = C.TRACK_TYPE_VIDEO;
                                        exo.pause();
                                        if (errorListener != null)
                                            errorListener.onError(
                                                    MoviePlayer.this,
                                                    PlaybackException
                                                            .ERROR_CODE_DECODING_FORMAT_UNSUPPORTED,
                                                    0);
                                    }
                                }

                                @Override
                                public void onVideoSizeChanged(VideoSize size) {
                                    if (!released && sizeListener != null)
                                        sizeListener.onVideoSizeChanged(
                                                MoviePlayer.this,
                                                Math.round(size.width * size.pixelWidthHeightRatio),
                                                size.height);
                                }

                                @Override
                                public void onPlayerError(PlaybackException error) {
                                    if (released) return;
                                    if (!hlsFallbackAttempted
                                            && uri != null
                                            && mediaSourceFactory != null) {
                                        String scheme = uri.getScheme();
                                        if ("http".equalsIgnoreCase(scheme)
                                                || "https".equalsIgnoreCase(scheme)) {
                                            if ((error.errorCode
                                                                    == PlaybackException
                                                                            .ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED
                                                            || error.errorCode
                                                                    == PlaybackException
                                                                            .ERROR_CODE_PARSING_CONTAINER_MALFORMED)
                                                    && mediaMime == null) {
                                                hlsFallbackAttempted = true;
                                                mediaMime = MimeTypes.APPLICATION_M3U8;
                                                try {
                                                    exo.setMediaSource(playbackSource(uri));
                                                    exo.prepare();
                                                    return;
                                                } catch (Exception ignored) {
                                                }
                                            } else if ((ijkMode
                                                            || options.optBoolean("live", false))
                                                    && MimeTypes.APPLICATION_M3U8.equalsIgnoreCase(
                                                            mediaMime)
                                                    && (error.errorCode
                                                                    == PlaybackException
                                                                            .ERROR_CODE_PARSING_MANIFEST_MALFORMED
                                                            || error.errorCode
                                                                    == PlaybackException
                                                                            .ERROR_CODE_PARSING_CONTAINER_MALFORMED)) {
                                                hlsFallbackAttempted = true;
                                                mediaMime = null;
                                                try {
                                                    exo.setMediaSource(playbackSource(uri));
                                                    exo.prepare();
                                                    return;
                                                } catch (Exception ignored) {
                                                }
                                            }
                                        }
                                    }
                                    lastError = error.getErrorCodeName();
                                    lastErrorTrack =
                                            error
                                                            instanceof
                                                            androidx.media3.exoplayer
                                                                    .ExoPlaybackException
                                                    ? (((androidx.media3.exoplayer
                                                                                            .ExoPlaybackException)
                                                                                    error)
                                                                            .rendererFormat
                                                                    == null
                                                            ? C.TRACK_TYPE_UNKNOWN
                                                            : MimeTypes.getTrackType(
                                                                    ((androidx.media3.exoplayer
                                                                                            .ExoPlaybackException)
                                                                                    error)
                                                                            .rendererFormat
                                                                            .sampleMimeType))
                                                    : C.TRACK_TYPE_UNKNOWN;
                                    lastHttpStatus = 0;
                                    for (Throwable cause = error;
                                            cause != null;
                                            cause = cause.getCause())
                                        if (cause
                                                instanceof
                                                androidx.media3.datasource.HttpDataSource
                                                        .InvalidResponseCodeException) {
                                            lastHttpStatus =
                                                    ((androidx.media3.datasource.HttpDataSource
                                                                            .InvalidResponseCodeException)
                                                                    cause)
                                                            .responseCode;
                                            break;
                                        }
                                    if (errorListener != null)
                                        errorListener.onError(MoviePlayer.this, error.errorCode, 0);
                                }

                                @Override
                                public void onCues(androidx.media3.common.text.CueGroup group) {
                                    if (cueListener != null) cueListener.cues(group);
                                    if (subtitleListener != null) {
                                        StringBuilder text = new StringBuilder();
                                        for (androidx.media3.common.text.Cue cue : group.cues)
                                            if (cue.text != null) {
                                                if (text.length() > 0) text.append('\n');
                                                text.append(cue.text);
                                            }
                                        subtitleListener.text(text);
                                    }
                                }
                            });
                    return null;
                });
    }

    public void configureDefaultAudio() {
        if (android.os.Build.VERSION.SDK_INT >= 21) {
            setAudioAttributes(
                    new android.media.AudioAttributes.Builder()
                            .setUsage(android.media.AudioAttributes.USAGE_MEDIA)
                            .setContentType(android.media.AudioAttributes.CONTENT_TYPE_MOVIE)
                            .build());
        }
    }

    void bindSubtitles(final SubtitleOverlayView view, final SubtitleListener textCallback) {
        setCuesListener(
                group -> {
                    if (view != null) {
                        view.setCues(group.cues);
                    }
                    if (textCallback != null) {
                        textCallback.text(
                                group.cues.isEmpty() ? "" : String.valueOf(group.cues.get(0).text));
                    }
                });
    }

    public void setAudioAttributes(android.media.AudioAttributes attributes) {
        onMain(
                () -> {
                    check();
                    exo.setAudioAttributes(
                            new androidx.media3.common.AudioAttributes.Builder()
                                    .setUsage(attributes.getUsage())
                                    .setContentType(attributes.getContentType())
                                    .build(),
                            true);
                    return null;
                });
    }

    public void setDataSource(Context unused, Uri uri, Map<String, String> headers) {
        onMain(
                () -> {
                    check();
                    this.uri = uri;
                    this.headers = Collections.unmodifiableMap(new LinkedHashMap<>(headers));
                    return null;
                });
    }

    public void setSurface(Surface surface) {
        onMain(
                () -> {
                    check();
                    exo.setVideoSurface(surface);
                    return null;
                });
    }

    public void setOnPreparedListener(OnPreparedListener listener) {
        onMain(
                () -> {
                    preparedListener = listener;
                    return null;
                });
    }

    public void setOnCompletionListener(OnCompletionListener listener) {
        onMain(
                () -> {
                    completionListener = listener;
                    return null;
                });
    }

    public void setOnVideoSizeChangedListener(OnVideoSizeChangedListener listener) {
        onMain(
                () -> {
                    sizeListener = listener;
                    return null;
                });
    }

    public void setOnErrorListener(OnErrorListener listener) {
        onMain(
                () -> {
                    errorListener = listener;
                    return null;
                });
    }

    public void setOnHdrChangedListener(OnHdrChangedListener listener) {
        if (exo == null) return;
        onMain(
                () -> {
                    hdrChangedListener = listener;
                    if (listener != null && hdrVideo) {
                        listener.onHdrChanged(true);
                    }
                    return null;
                });
    }

    public boolean isHdrVideo() {
        if (exo == null) return false;
        return onMain(
                () -> {
                    if (released) return false;
                    if (hdrVideo) return true;
                    androidx.media3.common.Format vf = exo.getVideoFormat();
                    return vf != null
                            && (androidx.media3.common.ColorInfo.isTransferHdr(vf.colorInfo)
                                    || MimeTypes.VIDEO_DOLBY_VISION.equals(vf.sampleMimeType));
                });
    }

    public boolean isUnsupportedDolbyVisionProfile5() {
        if (exo == null) return false;
        return onMain(() -> unsupportedDvProfile5);
    }

    public void setOptions(org.json.JSONObject metadata) {
        onMain(
                () -> {
                    options = new org.json.JSONObject(metadata.toString());
                    return null;
                });
    }

    static final int PROBE_BUDGET_MS = 3000;
    static final int PROBE_MAX_BYTES = 512;

    private static Map<String, String> sanitizeHeadersForAddress(
            Uri address, Map<String, String> sourceHeaders) {
        Map<String, String> out = new LinkedHashMap<>(sourceHeaders);
        if (address != null && ProxyAddress.isLoopbackHost(address.getHost())) {
            for (java.util.Iterator<Map.Entry<String, String>> it = out.entrySet().iterator();
                    it.hasNext(); ) {
                Map.Entry<String, String> e = it.next();
                String k = e.getKey();
                if ("Origin".equalsIgnoreCase(k)) {
                    String v = e.getValue();
                    it.remove();
                    if (v != null && !v.isEmpty()) out.put("X-Movie-Origin", v);
                    break;
                }
            }
            for (java.util.Iterator<Map.Entry<String, String>> it = out.entrySet().iterator();
                    it.hasNext(); ) {
                Map.Entry<String, String> e = it.next();
                String k = e.getKey();
                if ("Host".equalsIgnoreCase(k)) {
                    String v = e.getValue();
                    it.remove();
                    if (v != null && !v.isEmpty()) out.put("X-Movie-Host", v);
                    break;
                }
            }
        }
        return out;
    }

    public void prepareAsync() {
        onMain(
                () -> {
                    check();
                    if (uri == null) throw new IllegalStateException("No media item");
                    final int ticket = ++preparation;
                    RequestScope previousScope = probeScope;
                    if (previousScope != null) previousScope.cancel();
                    final RequestScope scope = new RequestScope();
                    probeScope = scope;
                    final Uri address = uri;
                    final Map<String, String> requestHeaders =
                            sanitizeHeadersForAddress(address, headers);
                    final String epName =
                            options.optString("_episodeName", "").toLowerCase(Locale.ROOT);
                    final boolean isLive = options.optBoolean("live", false);
                    readySent = false;
                    hlsFallbackAttempted = false;
                    maxKnownDurationMs = 0;
                    prepareStarted = android.os.SystemClock.elapsedRealtime();
                    firstFrameMs = -1;

                    String declared = MediaOptions.mime(options);
                    String fullLower = address.toString().toLowerCase(Locale.ROOT);
                    boolean explicitHls =
                            fullLower.contains(".m3u8") || (isLive && fullLower.contains("m3u8"));
                    boolean explicitDash = fullLower.contains(".mpd");
                    boolean knownContainer =
                            !explicitHls
                                    && !explicitDash
                                    && !detectKnownContainer(epName, address).isEmpty();
                    boolean cloudOrLocalProxy =
                            !isLive
                                    && !explicitHls
                                    && !explicitDash
                                    && isCloudDriveOrLocalProxyContainer(address, fullLower);
                    if (isLive
                            || declared != null
                            || explicitHls
                            || explicitDash
                            || knownContainer
                            || cloudOrLocalProxy) {
                        String fastMime =
                                declared != null
                                        ? declared
                                        : explicitHls
                                                ? MimeTypes.APPLICATION_M3U8
                                                : explicitDash ? MimeTypes.APPLICATION_MPD : null;
                        startExoPrepare(address, requestHeaders, scope, fastMime, ticket);
                        return null;
                    }

                    // Ambiguous extensionless HTTP URLs: inspect a bounded response prefix off the
                    // UI thread so HLS/DASH uses the right parser without blocking main looper.
                    Thread sniff =
                            new Thread(
                                    () -> {
                                        String mime = null;
                                        try {
                                            mime =
                                                    scope.call(
                                                            () ->
                                                                    sniffMime(
                                                                            context,
                                                                            address,
                                                                            requestHeaders,
                                                                            scope));
                                        } catch (Exception ignored) {
                                        }
                                        if (scope.cancelled) return;
                                        final String resolvedMime = mime;
                                        main.post(
                                                () ->
                                                        startExoPrepare(
                                                                address,
                                                                requestHeaders,
                                                                scope,
                                                                resolvedMime,
                                                                ticket));
                                    },
                                    "media-type-probe");
                    sniff.setDaemon(true);
                    sniff.start();
                    return null;
                });
    }

    private void startExoPrepare(
            Uri address,
            Map<String, String> requestHeaders,
            RequestScope scope,
            String resolvedMime,
            int ticket) {
        if (released || (scope != null && scope.cancelled) || ticket != preparation) return;
        try {
            String userAgent =
                    options.optBoolean("live", false) ? Cms.USER_AGENT : defaultUserAgent(context);
            for (Map.Entry<String, String> header : requestHeaders.entrySet())
                if (header.getKey().equalsIgnoreCase("User-Agent")) userAgent = header.getValue();
            DefaultHttpDataSource.Factory http =
                    new DefaultHttpDataSource.Factory()
                            .setUserAgent(userAgent)
                            .setDefaultRequestProperties(requestHeaders)
                            .setAllowCrossProtocolRedirects(true)
                            .setConnectTimeoutMs(ijkMode ? 20000 : 15000)
                            .setReadTimeoutMs(ijkMode ? 45000 : 30000);
            DefaultDataSource.Factory data =
                    new DefaultDataSource.Factory(
                            context, new ChunkedProxyDataSource.Factory(http));
            mediaMime = resolvedMime;
            androidx.media3.extractor.DefaultExtractorsFactory extractors =
                    new androidx.media3.extractor.DefaultExtractorsFactory()
                            .setConstantBitrateSeekingEnabled(true)
                            .setTsExtractorTimestampSearchBytes((ijkMode ? 3600 : 1500) * 188);
            if (ijkMode) {
                extractors.setTsExtractorFlags(
                        androidx.media3.extractor.ts.DefaultTsPayloadReaderFactory
                                        .FLAG_ALLOW_NON_IDR_KEYFRAMES
                                | androidx.media3.extractor.ts.DefaultTsPayloadReaderFactory
                                        .FLAG_DETECT_ACCESS_UNITS
                                | androidx.media3.extractor.ts.DefaultTsPayloadReaderFactory
                                        .FLAG_ENABLE_HDMV_DTS_AUDIO_STREAMS
                                | androidx.media3.extractor.ts.DefaultTsPayloadReaderFactory
                                        .FLAG_IGNORE_SPLICE_INFO_STREAM);
            }
            mediaSourceFactory =
                    new DefaultMediaSourceFactory(data, wrapDisguisedMp3Extractors(extractors));
            exo.setMediaSource(playbackSource(address));
            exo.prepare();
        } catch (Exception error) {
            lastError = error.getClass().getSimpleName();
            if (errorListener != null)
                errorListener.onError(
                        MoviePlayer.this, PlaybackException.ERROR_CODE_UNSPECIFIED, 0);
        }
    }

    static boolean isCloudDriveOrLocalProxyContainer(Uri address, String fullLower) {
        if (fullLower == null || fullLower.isEmpty()) return false;
        if (fullLower.contains("m3u8") || fullLower.contains(".mpd")) return false;
        String host =
                address == null || address.getHost() == null
                        ? ""
                        : address.getHost().toLowerCase(Locale.ROOT);
        if (("127.0.0.1".equals(host) || "localhost".equals(host))
                && fullLower.contains("/proxy")) {
            return true;
        }
        return host.contains("quark.cn")
                || host.contains("uc.cn")
                || host.contains("aliyundrive")
                || host.contains("alipan")
                || host.contains("baidupcs")
                || host.contains("pcs.baidu")
                || host.contains("115.com")
                || host.contains("115cdn")
                || host.contains("123pan")
                || host.contains("189.cn")
                || host.contains("139.com")
                || host.contains("xunlei");
    }

    static androidx.media3.extractor.ExtractorsFactory wrapDisguisedMp3Extractors(
            final androidx.media3.extractor.DefaultExtractorsFactory base) {
        return new androidx.media3.extractor.ExtractorsFactory() {
            @Override
            public androidx.media3.extractor.Extractor[] createExtractors() {
                return reorderDisguisedMp3Extractors(base.createExtractors());
            }

            @Override
            public androidx.media3.extractor.Extractor[] createExtractors(
                    Uri uri, Map<String, java.util.List<String>> responseHeaders) {
                return reorderDisguisedMp3Extractors(base.createExtractors(uri, responseHeaders));
            }
        };
    }

    /**
     * Netdisk shares frequently rename MP4/MKV/FLV video files to {@code .mp3} to evade content
     * filters (#31). When Media3 places {@code Mp3Extractor} at index 0 based on the {@code .mp3}
     * suffix or {@code audio/mpeg} header, its permissive sync-word scan can false-match H.264/HEVC
     * bitstreams and drop the video track. Moving strict magic-byte video container extractors
     * ahead of {@code Mp3Extractor} lets real video containers match at byte 0 while genuine MP3
     * audio files fall through to {@code Mp3Extractor} immediately.
     */
    static androidx.media3.extractor.Extractor[] reorderDisguisedMp3Extractors(
            androidx.media3.extractor.Extractor[] list) {
        if (list == null || list.length <= 1) return list;
        if (!list[0].getClass().getSimpleName().contains("Mp3")) return list;
        java.util.List<androidx.media3.extractor.Extractor> strictVideo =
                new java.util.ArrayList<androidx.media3.extractor.Extractor>(6);
        java.util.List<androidx.media3.extractor.Extractor> rest =
                new java.util.ArrayList<androidx.media3.extractor.Extractor>(list.length);
        for (int i = 0; i < list.length; i++) {
            androidx.media3.extractor.Extractor ex = list[i];
            String name = ex.getClass().getSimpleName();
            if (name.contains("Mp4")
                    || name.contains("Matroska")
                    || name.contains("Mkv")
                    || name.contains("Flv")
                    || name.contains("Avi")) {
                strictVideo.add(ex);
            } else {
                rest.add(ex);
            }
        }
        if (strictVideo.isEmpty()) return list;
        androidx.media3.extractor.Extractor[] out =
                new androidx.media3.extractor.Extractor[list.length];
        int idx = 0;
        for (int i = 0; i < strictVideo.size(); i++) out[idx++] = strictVideo.get(i);
        for (int i = 0; i < rest.size(); i++) out[idx++] = rest.get(i);
        return out;
    }

    private static String sniffMime(
            Context context, Uri address, Map<String, String> requestHeaders, RequestScope scope) {
        if (scope != null && scope.cancelled) return null;
        int type = Util.inferContentType(address);
        if (type == C.CONTENT_TYPE_HLS) return MimeTypes.APPLICATION_M3U8;
        if (type == C.CONTENT_TYPE_DASH) return MimeTypes.APPLICATION_MPD;
        String path = address.getPath();
        boolean mp3Path = path != null && path.toLowerCase(Locale.ROOT).endsWith(".mp3");
        if (path != null
                && !mp3Path
                && path.toLowerCase(Locale.ROOT)
                        .matches(".*\\.(mp4|mkv|webm|aac|flac|ogg|ts|flv|mov|avi)$")) return null;
        String fullUri = address.toString().toLowerCase(Locale.ROOT);
        if (fullUri.contains(".m3u8")) return MimeTypes.APPLICATION_M3U8;
        if (fullUri.contains(".mpd")) return MimeTypes.APPLICATION_MPD;
        if (fullUri.contains(".mkv")
                || fullUri.contains(".mp4")
                || fullUri.contains(".flv")
                || fullUri.contains(".ts")) return null;
        String scheme = address.getScheme();
        if (!"http".equalsIgnoreCase(scheme) && !"https".equalsIgnoreCase(scheme)) return null;
        long deadlineNs = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(PROBE_BUDGET_MS);
        HttpURLConnection connection = null;
        try {
            connection = ProxyAddress.openHttpConnection(new URL(address.toString()));
            RequestScope.attach(connection);
            connection.setConnectTimeout(1200);
            connection.setReadTimeout(1200);
            connection.setInstanceFollowRedirects(true);
            connection.setRequestProperty("User-Agent", defaultUserAgent(context));
            if (ProxyAddress.isLoopbackHost(address.getHost())) {
                connection.setRequestProperty(ChunkedProxyDataSource.HEADER_CHUNKED_CLIENT, "1");
            }
            connection.setRequestProperty("Range", "bytes=0-" + (PROBE_MAX_BYTES - 1));
            for (Map.Entry<String, String> header : requestHeaders.entrySet())
                connection.setRequestProperty(header.getKey(), header.getValue());
            if (scope != null && scope.cancelled) return null;
            String contentType = connection.getContentType();
            if (contentType != null) {
                String lower = contentType.toLowerCase(Locale.ROOT);
                if (lower.contains("mpegurl")) return MimeTypes.APPLICATION_M3U8;
                if (lower.contains("dash+xml")) return MimeTypes.APPLICATION_MPD;
                if (!mp3Path
                        && (lower.startsWith("video/")
                                || lower.startsWith("audio/")
                                || lower.contains("matroska")
                                || lower.contains("octet-stream"))) return null;
            }
            byte[] prefix = new byte[PROBE_MAX_BYTES];
            int count = 0;
            try (InputStream stream = connection.getInputStream()) {
                while (count < prefix.length && System.nanoTime() < deadlineNs) {
                    if (scope != null && scope.cancelled) return null;
                    int remainingMs =
                            (int)
                                    Math.max(
                                            250L,
                                            TimeUnit.NANOSECONDS.toMillis(
                                                    deadlineNs - System.nanoTime()));
                    connection.setReadTimeout(Math.min(2500, remainingMs));
                    int n = stream.read(prefix, count, prefix.length - count);
                    if (n < 0) break;
                    count += n;
                    if (count >= 4
                            && (prefix[0] & 0xFF) == 0x1A
                            && (prefix[1] & 0xFF) == 0x45
                            && (prefix[2] & 0xFF) == 0xDF
                            && (prefix[3] & 0xFF) == 0xA3) {
                        // EBML / Matroska (.mkv / .webm) magic bytes
                        return null;
                    }
                    String partial = new String(prefix, 0, count, "UTF-8").trim();
                    if (partial.startsWith("\ufeff")) partial = partial.substring(1).trim();
                    if (partial.startsWith("#EXTM3U")) return MimeTypes.APPLICATION_M3U8;
                    if (partial.contains("<MPD")) return MimeTypes.APPLICATION_MPD;
                    if (count >= 16 && !partial.startsWith("<") && !partial.startsWith("#"))
                        return null;
                }
            }
            String start = new String(prefix, 0, count, "UTF-8").trim();
            if (start.startsWith("\ufeff")) start = start.substring(1).trim();
            if (start.startsWith("#EXTM3U")) return MimeTypes.APPLICATION_M3U8;
            if (start.contains("<MPD")) return MimeTypes.APPLICATION_MPD;
        } catch (Exception ignored) {
            /* The real loader reports transport failures. */
        } finally {
            if (connection != null) RequestScope.detach(connection);
            if (connection != null) connection.disconnect();
        }
        return null;
    }

    public void start() {
        onMain(
                () -> {
                    check();
                    exo.play();
                    return null;
                });
    }

    public void pause() {
        onMain(
                () -> {
                    if (!released) exo.pause();
                    return null;
                });
    }

    public void seekTo(int ms) {
        onMain(
                () -> {
                    check();
                    exo.seekTo(Math.max(0, ms));
                    return null;
                });
    }

    public boolean isPlaying() {
        return onMain(() -> !released && exo.isPlaying());
    }

    public int getCurrentPosition() {
        return onMain(() -> released ? 0 : milliseconds(exo.getCurrentPosition()));
    }

    private int maxKnownDurationMs = 0;

    public int getDuration() {
        return onMain(
                () -> {
                    if (released) return 0;
                    long raw = exo.getDuration();
                    if (raw == C.TIME_UNSET || raw <= 0) {
                        raw = exo.getContentDuration();
                    }
                    int ms = milliseconds(raw);
                    if (ms > maxKnownDurationMs) {
                        maxKnownDurationMs = ms;
                    }
                    return ms > 0 ? ms : maxKnownDurationMs;
                });
    }

    public int getVideoWidth() {
        return onMain(
                () ->
                        released
                                ? 0
                                : Math.round(
                                        exo.getVideoSize().width
                                                * exo.getVideoSize().pixelWidthHeightRatio));
    }

    private static String shortVideoCodec(String mime) {
        if (mime == null) return "";
        String m = mime.toLowerCase(Locale.ROOT);
        if (m.contains("dolby-vision") || m.contains("dvhe") || m.contains("dvh1")) return "杜比视界";
        if (m.contains("hevc") || m.contains("h265")) return "HEVC";
        if (m.contains("avc") || m.contains("h264")) return "H.264";
        if (m.contains("av01") || m.contains("av1")) return "AV1";
        if (m.contains("vp9")) return "VP9";
        if (m.contains("mp4v")) return "MPEG4";
        return "";
    }

    private static String shortAudioCodec(String mime) {
        if (mime == null) return "";
        String m = mime.toLowerCase(Locale.ROOT);
        if (m.contains("eac3")) return "EAC3";
        if (m.contains("ac3")) return "AC3";
        if (m.contains("truehd")) return "TrueHD";
        if (m.contains("dts")) return "DTS";
        if (m.contains("flac")) return "FLAC";
        if (m.contains("opus")) return "Opus";
        if (m.contains("mp4a") || m.contains("aac")) return "AAC";
        if (m.contains("mpeg") || m.contains("mp3")) return "MP3";
        return "";
    }

    private static final java.util.regex.Pattern CONTAINER_EXT_PATTERN =
            java.util.regex.Pattern.compile(
                    "(?i)\\.(mkv|mp4|m4v|webm|avi|mov|flv|ts|m2ts)(?:$|[^a-z0-9])");

    private static final java.util.regex.Pattern QUERY_CONTAINER_EXT_PATTERN =
            java.util.regex.Pattern.compile(
                    "(?i)\\.(mkv|mp4|m4v|webm|avi|mov|flv|m2ts)(?:$|[^a-z0-9])");

    static String detectKnownContainer(String epName, Uri address) {
        String candidate = matchContainerToken(epName, CONTAINER_EXT_PATTERN);
        if (!candidate.isEmpty()) return candidate;
        if (address != null) {
            candidate = matchContainerToken(address.getPath(), CONTAINER_EXT_PATTERN);
            if (!candidate.isEmpty()) return candidate;
            candidate = matchContainerToken(address.getQuery(), QUERY_CONTAINER_EXT_PATTERN);
            if (!candidate.isEmpty()) return candidate;
        }
        return "";
    }

    private static String matchContainerToken(String input, java.util.regex.Pattern pattern) {
        if (input == null || input.isEmpty()) return "";
        java.util.regex.Matcher m = pattern.matcher(input);
        if (!m.find()) return "";
        String ext = m.group(1).toLowerCase(Locale.ROOT);
        switch (ext) {
            case "mkv":
                return "MKV";
            case "mp4":
            case "m4v":
                return "MP4";
            case "webm":
                return "WebM";
            case "avi":
                return "AVI";
            case "mov":
                return "MOV";
            case "flv":
                return "FLV";
            case "ts":
            case "m2ts":
                return "TS";
            default:
                return "";
        }
    }

    private String shortContainerFormat() {
        String epName =
                options != null
                        ? options.optString("_episodeName", "").toLowerCase(Locale.ROOT)
                        : "";
        String u = uri != null ? uri.toString().toLowerCase(Locale.ROOT) : "";
        String m = mediaMime != null ? mediaMime.toLowerCase(Locale.ROOT) : "";
        if (m.contains("mpegurl") || u.contains(".m3u8")) return "HLS";
        if (m.contains("dash") || u.contains(".mpd")) return "DASH";
        if (m.contains("matroska")) return "MKV";
        String detected = detectKnownContainer(epName, uri);
        if (!detected.isEmpty()) return detected;
        return "";
    }

    public String videoResolution() {
        return onMain(
                () -> {
                    if (released) return "分辨率未知";
                    androidx.media3.common.Format format = exo.getVideoFormat();
                    androidx.media3.common.Format audioFormat = exo.getAudioFormat();
                    int w =
                            format != null && format.width > 0
                                    ? format.width
                                    : exo.getVideoSize().width;
                    int h =
                            format != null && format.height > 0
                                    ? format.height
                                    : exo.getVideoSize().height;
                    if (w <= 0 || h <= 0) return "分辨率未知";
                    int longEdge = Math.max(w, h);
                    String tier =
                            longEdge >= 3800
                                    ? "4K "
                                    : longEdge >= 2500
                                            ? "2K "
                                            : longEdge >= 1900
                                                    ? "1080P "
                                                    : longEdge >= 1200 ? "720P " : "";
                    StringBuilder sb = new StringBuilder();
                    sb.append(tier).append(w).append(" × ").append(h);
                    String vCodec = format != null ? shortVideoCodec(format.sampleMimeType) : "";
                    if (!vCodec.isEmpty()) sb.append(" · ").append(vCodec);
                    if (format != null
                            && format.colorInfo != null
                            && androidx.media3.common.ColorInfo.isTransferHdr(format.colorInfo)
                            && !"杜比视界".equals(vCodec)) {
                        sb.append(" HDR");
                    }
                    String aCodec =
                            audioFormat != null ? shortAudioCodec(audioFormat.sampleMimeType) : "";
                    if (!aCodec.isEmpty()) sb.append(" · ").append(aCodec);
                    String container = shortContainerFormat();
                    if (!container.isEmpty()) sb.append(" · ").append(container);
                    return sb.toString();
                });
    }

    public java.util.List<String> mediaBadges() {
        return onMain(
                () -> {
                    java.util.List<String> out = new java.util.ArrayList<>(4);
                    if (released) return out;
                    androidx.media3.common.Format vf = exo.getVideoFormat();
                    androidx.media3.common.Format af = exo.getAudioFormat();
                    int w = vf != null && vf.width > 0 ? vf.width : exo.getVideoSize().width;
                    int h = vf != null && vf.height > 0 ? vf.height : exo.getVideoSize().height;
                    int longEdge = Math.max(w, h);
                    String tier =
                            longEdge >= 3800
                                    ? "4K"
                                    : longEdge >= 2500
                                            ? "2K"
                                            : longEdge >= 1900
                                                    ? "1080P"
                                                    : longEdge >= 1200
                                                            ? "720P"
                                                            : (w > 0 && h > 0 ? h + "P" : "");
                    String vMime =
                            vf != null && vf.sampleMimeType != null
                                    ? vf.sampleMimeType.toLowerCase(Locale.ROOT)
                                    : "";
                    String vCodecs =
                            vf != null && vf.codecs != null
                                    ? vf.codecs.toLowerCase(Locale.ROOT)
                                    : "";
                    boolean isDv =
                            vMime.contains("dolby-vision")
                                    || vCodecs.contains("dvhe")
                                    || vCodecs.contains("dvh1")
                                    || vCodecs.contains("dav1");
                    String dvProfile = "";
                    if (isDv) {
                        java.util.regex.Matcher m =
                                java.util.regex.Pattern.compile("(?:dvhe|dvh1|dav1)\\.0*(\\d+)")
                                        .matcher(vCodecs);
                        if (m.find()) dvProfile = "P" + m.group(1);
                    }
                    if (!dvProfile.isEmpty() && !tier.isEmpty()) {
                        out.add("DOLBY " + dvProfile + " · " + tier);
                    } else if (!tier.isEmpty()) {
                        out.add(tier);
                    }

                    if (isDv) {
                        out.add("DOLBY VISION");
                    } else if (vf != null
                            && vf.colorInfo != null
                            && androidx.media3.common.ColorInfo.isTransferHdr(vf.colorInfo)) {
                        out.add(
                                vf.colorInfo.colorTransfer == C.COLOR_TRANSFER_HLG
                                        ? "HLG HDR"
                                        : "HDR10");
                    } else if (vf != null) {
                        String vc = shortVideoCodec(vf.sampleMimeType);
                        if (!vc.isEmpty() && !"杜比视界".equals(vc)) out.add(vc);
                    }

                    if (af != null && af.sampleMimeType != null) {
                        String am = af.sampleMimeType.toLowerCase(Locale.ROOT);
                        int ch = af.channelCount;
                        String chTag =
                                ch >= 8
                                        ? " 7.1"
                                        : ch == 6
                                                ? " 5.1"
                                                : ch == 2
                                                        ? " 2.0"
                                                        : ch == 1
                                                                ? " 1.0"
                                                                : (ch > 0 ? " " + ch + "CH" : "");
                        if (am.contains("eac3-joc")) out.add("DD+ ATMOS" + chTag);
                        else if (am.contains("eac3")) out.add("DD+" + chTag);
                        else if (am.contains("ac3")) out.add("DOLBY AUDIO" + chTag);
                        else if (am.contains("truehd")) out.add("TRUEHD" + chTag);
                        else if (am.contains("vnd.dts.hd")) out.add("DTS-HD" + chTag);
                        else if (am.contains("dts")) out.add("DTS" + chTag);
                        else if (am.contains("flac")) out.add("FLAC" + chTag);
                        else if (am.contains("opus")) out.add("OPUS" + chTag);
                        else if (am.contains("mp4a") || am.contains("aac")) out.add("AAC" + chTag);
                        else if (am.contains("mpeg") || am.contains("mp3")) out.add("MP3");
                    }

                    String dec = videoDecoder == null ? "" : videoDecoder.toLowerCase(Locale.ROOT);
                    boolean swDec =
                            dec.contains("ffmpeg")
                                    || dec.contains("dav1d")
                                    || dec.contains("libvpx")
                                    || dec.startsWith("c2.android.")
                                    || dec.startsWith("omx.google.");
                    out.add(ijkMode ? "IJK 播放" : (swDec ? "软解播放" : "原生播放"));
                    return out;
                });
    }

    public int getVideoHeight() {
        return onMain(() -> released ? 0 : exo.getVideoSize().height);
    }

    public String getLastError() {
        return onMain(() -> lastError);
    }

    public int softFallbackMode() {
        return onMain(() -> lastErrorTrack == C.TRACK_TYPE_AUDIO ? 3 : 2);
    }

    public String getFailureMessage(int code) {
        return onMain(() -> PlaybackFailure.message(code, lastHttpStatus));
    }

    public org.json.JSONObject decoderDiagnostics() {
        return onMain(
                () -> {
                    org.json.JSONObject info =
                            new org.json.JSONObject()
                                    .put("video_decoder", videoDecoder)
                                    .put("audio_decoder", audioDecoder);
                    if (released) return info;
                    androidx.media3.common.Format vf = exo.getVideoFormat(),
                            af = exo.getAudioFormat();
                    if (vf != null) {
                        info.put("video_mime", vf.sampleMimeType)
                                .put("width", vf.width)
                                .put("height", vf.height)
                                .put("frame_rate", vf.frameRate);
                        if (vf.colorInfo != null)
                            info.put("color_space", vf.colorInfo.colorSpace)
                                    .put("color_transfer", vf.colorInfo.colorTransfer)
                                    .put("color_range", vf.colorInfo.colorRange)
                                    .put("luma_bitdepth", vf.colorInfo.lumaBitdepth)
                                    .put(
                                            "hdr",
                                            androidx.media3.common.ColorInfo.isTransferHdr(
                                                    vf.colorInfo));
                    }
                    info.put("first_frame_ms", firstFrameMs);
                    if (af != null)
                        info.put("audio_mime", af.sampleMimeType).put("channels", af.channelCount);
                    androidx.media3.exoplayer.DecoderCounters vc = exo.getVideoDecoderCounters(),
                            ac = exo.getAudioDecoderCounters();
                    if (vc != null) {
                        vc.ensureUpdated();
                        info.put("video_rendered", vc.renderedOutputBufferCount)
                                .put("video_dropped", vc.droppedBufferCount);
                    }
                    if (ac != null) {
                        ac.ensureUpdated();
                        info.put("audio_rendered", ac.renderedOutputBufferCount);
                    }
                    return info;
                });
    }

    public String playbackInfo() {
        org.json.JSONObject d = decoderDiagnostics();
        return (ijkMode ? "IJK 兼容模式 (Media3 + FFmpeg)\n视频：" : "Exo (Media3)\n视频：")
                + d.optString("video_mime", "尚未识别")
                + " · "
                + d.optString("video_decoder", "尚未启动")
                + "\n音频："
                + d.optString("audio_mime", "尚未识别")
                + " · "
                + d.optString("audio_decoder", "尚未启动")
                + "\n"
                + d.optInt("width")
                + " × "
                + d.optInt("height")
                + (getLastError().isEmpty() ? "" : "\n" + getLastError());
    }

    public int getAudioSessionId() {
        return onMain(() -> released ? 0 : exo.getAudioSessionId());
    }

    public void setCuesListener(CueListener listener) {
        onMain(
                () -> {
                    cueListener = listener;
                    return null;
                });
    }

    private androidx.media3.exoplayer.source.MediaSource playbackSource(Uri address)
            throws Exception {
        androidx.media3.exoplayer.source.MediaSource video =
                mediaSourceFactory.createMediaSource(mediaItem(address));
        org.json.JSONObject extra = options.optJSONObject("extra");
        String audio = extra == null ? "" : extra.optString("audio");
        if (!Cms.isHttp(audio)) return video;
        return new androidx.media3.exoplayer.source.MergingMediaSource(
                true, video, mediaSourceFactory.createMediaSource(MediaItem.fromUri(audio)));
    }

    private MediaItem mediaItem(Uri address) throws Exception {
        MediaItem.Builder item = new MediaItem.Builder().setUri(address);
        if (mediaMime != null
                && (MimeTypes.APPLICATION_M3U8.equalsIgnoreCase(mediaMime)
                        || MimeTypes.APPLICATION_MPD.equalsIgnoreCase(mediaMime)
                        || MimeTypes.APPLICATION_SS.equalsIgnoreCase(mediaMime))) {
            item.setMimeType(mediaMime);
        }
        if (options.optBoolean("live", false)) {
            item.setLiveConfiguration(
                    new MediaItem.LiveConfiguration.Builder()
                            .setTargetOffsetMs(3500)
                            .setMinPlaybackSpeed(0.97f)
                            .setMaxPlaybackSpeed(1.04f)
                            .build());
        }
        java.util.List<MediaItem.SubtitleConfiguration> tracks = new java.util.ArrayList<>();
        org.json.JSONArray subtitles = options.optJSONArray("subtitles");
        if (subtitles != null)
            for (int i = 0; i < subtitles.length(); i++) {
                org.json.JSONObject sub = subtitles.optJSONObject(i);
                if (sub == null || sub.optString("url").isEmpty()) continue;
                tracks.add(
                        new MediaItem.SubtitleConfiguration.Builder(Uri.parse(sub.optString("url")))
                                .setMimeType(
                                        MediaOptions.subtitleMime(
                                                sub.optString("url"), sub.optString("mimeType")))
                                .setLabel(sub.optString("name", "外挂字幕"))
                                .setLanguage(sub.optString("language", "zh"))
                                .setSelectionFlags(i == 0 ? C.SELECTION_FLAG_DEFAULT : 0)
                                .build());
            }
        item.setSubtitleConfigurations(tracks);
        org.json.JSONObject drm = options.optJSONObject("drm");
        String scheme =
                drm == null
                        ? options.optString("drmScheme")
                        : drm.optString("scheme", drm.optString("type"));
        String license =
                drm == null
                        ? options.optString("drmLicenseUrl")
                        : drm.optString("licenseUrl", drm.optString("licenseUri"));
        if (!scheme.isEmpty()) {
            java.util.UUID uuid = Util.getDrmUuid(scheme);
            if (uuid == null || !Cms.isHttp(license))
                throw new IllegalArgumentException("来源缺少有效DRM许可配置");
            java.util.Map<String, String> licenseHeaders = new LinkedHashMap<>();
            if (drm != null && drm.optJSONObject("headers") != null)
                MediaOptions.headers(licenseHeaders, drm.optJSONObject("headers"));
            item.setDrmConfiguration(
                    new MediaItem.DrmConfiguration.Builder(uuid)
                            .setLicenseUri(license)
                            .setLicenseRequestHeaders(licenseHeaders)
                            .build());
        }
        return item.build();
    }

    public void addExternalSubtitle(Uri subtitle, String name, String mime) {
        onMain(
                () -> {
                    check();
                    if (mediaSourceFactory == null) throw new IllegalStateException("请等待视频开始播放");
                    org.json.JSONArray tracks = options.optJSONArray("subtitles");
                    if (tracks == null) {
                        tracks = new org.json.JSONArray();
                        options.put("subtitles", tracks);
                    }
                    tracks.put(
                            new org.json.JSONObject()
                                    .put("url", subtitle.toString())
                                    .put("name", name)
                                    .put("mimeType", mime));
                    long position = exo.getCurrentPosition();
                    boolean play = exo.getPlayWhenReady();
                    exo.setMediaSource(playbackSource(uri), position);
                    exo.prepare();
                    exo.setPlayWhenReady(play);
                    return null;
                });
    }

    public void setSubtitleListener(SubtitleListener listener) {
        onMain(
                () -> {
                    subtitleListener = listener;
                    return null;
                });
    }

    public void setSpeed(float speed) {
        onMain(
                () -> {
                    check();
                    exo.setPlaybackSpeed(speed);
                    return null;
                });
    }

    public float getSpeed() {
        return onMain(() -> exo.getPlaybackParameters().speed);
    }

    public void setRepeatOne(boolean repeat) {
        onMain(
                () -> {
                    check();
                    exo.setRepeatMode(repeat ? Player.REPEAT_MODE_ONE : Player.REPEAT_MODE_OFF);
                    return null;
                });
    }

    public java.util.List<String> trackLabels(int type) {
        return onMain(
                () -> {
                    java.util.List<String> out = new java.util.ArrayList<>();
                    for (androidx.media3.common.Tracks.Group group :
                            exo.getCurrentTracks().getGroups())
                        if (group.getType() == type)
                            for (int i = 0; i < group.length; i++)
                                if (group.isTrackSupported(i)) {
                                    androidx.media3.common.Format f = group.getTrackFormat(i);
                                    String label =
                                            f.label != null
                                                    ? f.label
                                                    : f.language != null
                                                            ? f.language
                                                            : "轨道 " + (out.size() + 1);
                                    if (f.channelCount > 0) label += " · " + f.channelCount + " 声道";
                                    out.add((group.isTrackSelected(i) ? "✓ " : "") + label);
                                }
                    return out;
                });
    }

    public void selectTrack(int type, int index) {
        onMain(
                () -> {
                    check();
                    androidx.media3.common.TrackSelectionParameters.Builder p =
                            exo.getTrackSelectionParameters()
                                    .buildUpon()
                                    .clearOverridesOfType(type)
                                    .setTrackTypeDisabled(type, index == -2);
                    if (index >= 0) {
                        int count = 0;
                        for (androidx.media3.common.Tracks.Group group :
                                exo.getCurrentTracks().getGroups())
                            if (group.getType() == type)
                                for (int i = 0; i < group.length; i++)
                                    if (group.isTrackSupported(i) && count++ == index)
                                        p.addOverride(
                                                new androidx.media3.common.TrackSelectionOverride(
                                                        group.getMediaTrackGroup(), i));
                    }
                    exo.setTrackSelectionParameters(p.build());
                    return null;
                });
    }

    public void release() {
        RequestScope activeScope = probeScope;
        if (activeScope != null) activeScope.cancel();
        onMain(
                () -> {
                    if (!released) {
                        released = true;
                        preparation++;
                        RequestScope current = probeScope;
                        if (current != null) current.cancel();
                        exo.release();
                    }
                    return null;
                });
    }

    private static int milliseconds(long value) {
        return value == C.TIME_UNSET || value < 0 ? 0 : (int) Math.min(Integer.MAX_VALUE, value);
    }

    private void check() {
        if (released) throw new IllegalStateException("Player released");
    }

    private <T> T onMain(Callable<T> work) {
        if (Looper.myLooper() == Looper.getMainLooper())
            try {
                return work.call();
            } catch (RuntimeException e) {
                throw e;
            } catch (Exception e) {
                throw new IllegalStateException(e);
            }
        FutureTask<T> task = new FutureTask<>(work);
        if (!main.post(task)) throw new IllegalStateException("Main looper unavailable");
        try {
            return task.get(15, TimeUnit.SECONDS);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new IllegalStateException("Player call interrupted", e);
        } catch (ExecutionException e) {
            Throwable cause = e.getCause();
            if (cause instanceof RuntimeException) throw (RuntimeException) cause;
            throw new IllegalStateException(cause);
        } catch (java.util.concurrent.TimeoutException e) {
            task.cancel(false);
            throw new IllegalStateException("Player UI thread timed out", e);
        }
    }

    /**
     * Bridges Media3 open-ended progressive reads ({@code length == C.LENGTH_UNSET}) with
     * loopback {@code /proxy} spiders that serve large netdisk files in bounded {@code 206}
     * slices (e.g. 1 MB {@code byte[]} chunks with {@code Content-Range: bytes a-b/total}).
     *
     * <p>Media3's {@code DefaultHttpDataSource} computes stream length from {@code (b - a + 1)}
     * rather than {@code /total}, which would otherwise truncate multi-GB MKV/MP4 files at the
     * first chunk. This wrapper exposes {@code total - position} to the extractor, chains
     * subsequent chunks on demand, and closes each chunk cleanly in sub-millisecond time when
     * {@code MatroskaExtractor} seeks to end-of-file {@code Cues}.
     */
    static final class ChunkedProxyDataSource implements androidx.media3.datasource.DataSource {
        static final String HEADER_CHUNKED_CLIENT = "X-Movie-Chunked-Client";

        static final class Factory implements androidx.media3.datasource.DataSource.Factory {
            private final androidx.media3.datasource.DataSource.Factory innerFactory;

            Factory(androidx.media3.datasource.DataSource.Factory innerFactory) {
                this.innerFactory = innerFactory;
            }

            @Override
            public androidx.media3.datasource.DataSource createDataSource() {
                return new ChunkedProxyDataSource(innerFactory.createDataSource());
            }
        }

        private final androidx.media3.datasource.DataSource inner;
        private androidx.media3.datasource.DataSpec baseSpec;
        private Uri lastUri;
        private Map<String, java.util.List<String>> lastHeaders = Collections.emptyMap();
        private boolean innerOpen;
        private boolean chunkMode;
        private long totalLength = C.LENGTH_UNSET;
        private long currentPos;
        private long chunkRemaining;

        ChunkedProxyDataSource(androidx.media3.datasource.DataSource inner) {
            this.inner = inner;
        }

        @Override
        public void addTransferListener(androidx.media3.datasource.TransferListener listener) {
            inner.addTransferListener(listener);
        }

        @Override
        public long open(androidx.media3.datasource.DataSpec spec) throws java.io.IOException {
            closeInnerQuietly();
            baseSpec = spec;
            chunkMode = false;
            totalLength = C.LENGTH_UNSET;
            currentPos = Math.max(0L, spec.position);
            chunkRemaining = 0L;
            lastUri = spec.uri;
            lastHeaders = Collections.emptyMap();

            boolean eligible =
                    spec.uri != null
                            && ProxyAddress.isLoopbackHost(spec.uri.getHost())
                            && spec.length == C.LENGTH_UNSET;
            if (!eligible) {
                long len = inner.open(spec);
                innerOpen = true;
                if (inner.getUri() != null) lastUri = inner.getUri();
                lastHeaders = inner.getResponseHeaders();
                return len;
            }

            try {
                long innerLen = inner.open(buildChunkSpec(spec, currentPos));
                innerOpen = true;
                if (inner.getUri() != null) lastUri = inner.getUri();
                lastHeaders = inner.getResponseHeaders();
                long[] cr = parseResponseContentRange(lastHeaders);
                if (cr != null && (cr[2] == C.LENGTH_UNSET || cr[2] > currentPos)) {
                    if (cr[0] > currentPos || cr[1] < currentPos) {
                        throw new java.io.IOException(
                                "Unexpected Content-Range "
                                        + cr[0]
                                        + "-"
                                        + cr[1]
                                        + " at offset "
                                        + currentPos);
                    }
                    if (cr[0] < currentPos) {
                        skipInnerFully(currentPos - cr[0]);
                    }
                    chunkMode = true;
                    totalLength = cr[2];
                    chunkRemaining = (cr[1] - currentPos) + 1L;
                    return totalLength != C.LENGTH_UNSET
                            ? (totalLength - currentPos)
                            : C.LENGTH_UNSET;
                }
                return innerLen;
            } catch (java.io.IOException | RuntimeException e) {
                closeInnerQuietly();
                throw e;
            }
        }

        @Override
        public int read(byte[] buffer, int offset, int length) throws java.io.IOException {
            if (length == 0) return 0;
            if (!chunkMode) {
                return inner.read(buffer, offset, length);
            }
            if (totalLength != C.LENGTH_UNSET && currentPos >= totalLength) {
                return C.RESULT_END_OF_INPUT;
            }
            while (chunkRemaining <= 0L) {
                if (totalLength != C.LENGTH_UNSET && currentPos >= totalLength) {
                    return C.RESULT_END_OF_INPUT;
                }
                if (!openNextChunk()) {
                    return C.RESULT_END_OF_INPUT;
                }
            }
            int toRead = (int) Math.min((long) length, chunkRemaining);
            int n = inner.read(buffer, offset, toRead);
            if (n == C.RESULT_END_OF_INPUT) {
                if (totalLength != C.LENGTH_UNSET && currentPos >= totalLength) {
                    return C.RESULT_END_OF_INPUT;
                }
                throw new java.io.EOFException(
                        "Chunk stream truncated at offset "
                                + currentPos
                                + " (missing "
                                + chunkRemaining
                                + " bytes)");
            }
            currentPos += n;
            chunkRemaining -= n;
            return n;
        }

        @Override
        public Uri getUri() {
            Uri active = innerOpen ? inner.getUri() : null;
            return active != null ? active : lastUri;
        }

        @Override
        public Map<String, java.util.List<String>> getResponseHeaders() {
            return innerOpen ? inner.getResponseHeaders() : lastHeaders;
        }

        @Override
        public void close() throws java.io.IOException {
            chunkMode = false;
            chunkRemaining = 0L;
            closeInner();
        }

        private boolean openNextChunk() throws java.io.IOException {
            closeInner();
            long innerLen;
            try {
                innerLen = inner.open(buildChunkSpec(baseSpec, currentPos));
                innerOpen = true;
            } catch (androidx.media3.datasource.HttpDataSource.InvalidResponseCodeException e) {
                if (e.responseCode == 416
                        && (totalLength == C.LENGTH_UNSET || currentPos >= totalLength)) {
                    return false;
                }
                throw e;
            }
            try {
                if (inner.getUri() != null) lastUri = inner.getUri();
                lastHeaders = inner.getResponseHeaders();
                long[] cr = parseResponseContentRange(lastHeaders);
                if (cr != null) {
                    if (cr[2] > 0) {
                        totalLength = cr[2];
                    }
                    if (cr[0] > currentPos || cr[1] < currentPos) {
                        throw new java.io.IOException(
                                "Unexpected Content-Range "
                                        + cr[0]
                                        + "-"
                                        + cr[1]
                                        + " at offset "
                                        + currentPos);
                    }
                    if (cr[0] < currentPos) {
                        skipInnerFully(currentPos - cr[0]);
                    }
                    chunkRemaining = (cr[1] - currentPos) + 1L;
                    return chunkRemaining > 0L;
                }
                if (innerLen == 0L) {
                    return false;
                }
                chunkRemaining = innerLen != C.LENGTH_UNSET ? innerLen : Long.MAX_VALUE;
                return true;
            } catch (java.io.IOException | RuntimeException e) {
                closeInnerQuietly();
                throw e;
            }
        }

        private void skipInnerFully(long bytesToSkip) throws java.io.IOException {
            if (bytesToSkip <= 0L) return;
            byte[] scratch = new byte[(int) Math.min(16384L, bytesToSkip)];
            long remaining = bytesToSkip;
            while (remaining > 0L) {
                if (Thread.currentThread().isInterrupted()) {
                    throw new java.io.InterruptedIOException();
                }
                int n = inner.read(scratch, 0, (int) Math.min((long) scratch.length, remaining));
                if (n == C.RESULT_END_OF_INPUT) {
                    throw new java.io.EOFException(
                            "Unexpected EOF skipping " + bytesToSkip + " bytes");
                }
                remaining -= n;
            }
        }

        private void closeInner() throws java.io.IOException {
            if (innerOpen) {
                innerOpen = false;
                inner.close();
            }
        }

        private void closeInnerQuietly() {
            if (innerOpen) {
                innerOpen = false;
                try {
                    inner.close();
                } catch (java.io.IOException ignored) {
                }
            }
        }

        private static androidx.media3.datasource.DataSpec buildChunkSpec(
                androidx.media3.datasource.DataSpec template, long offset) {
            Map<String, String> reqHeaders = new LinkedHashMap<>(template.httpRequestHeaders);
            reqHeaders.put(HEADER_CHUNKED_CLIENT, "1");
            reqHeaders.put("Range", "bytes=" + offset + "-");
            return template.buildUpon()
                    .setPosition(offset)
                    .setLength(C.LENGTH_UNSET)
                    .setHttpRequestHeaders(reqHeaders)
                    .build();
        }

        private static long[] parseResponseContentRange(
                Map<String, java.util.List<String>> responseHeaders) {
            if (responseHeaders == null) return null;
            for (Map.Entry<String, java.util.List<String>> e : responseHeaders.entrySet()) {
                if (e.getKey() != null
                        && "Content-Range".equalsIgnoreCase(e.getKey())
                        && e.getValue() != null
                        && !e.getValue().isEmpty()) {
                    long[] parsed = LocalProxy.parseContentRange(e.getValue().get(0));
                    if (parsed != null) {
                        if (parsed[2] < 0) parsed[2] = C.LENGTH_UNSET;
                        return parsed;
                    }
                }
            }
            return null;
        }
    }
}
