// SPDX-License-Identifier: GPL-3.0-only
package com.pilipala.marcomovie;

/**
 * Pure-JVM playback-scoped danmu ownership coordinator and per-episode runtime status model.
 *
 * <p>Binds asynchronous plugin callbacks, direct URL loads, and custom danmu service sessions to
 * the exact playback resolve request (site + video + line + episode + monotonic serial) so late
 * callbacks from a previous episode, line, or exited player session can never contaminate the
 * current episode.
 */
final class DanmuOwnership {

    static final Coordinator GLOBAL = new Coordinator();

    enum State {
        IDLE,
        LOADING,
        LOADED,
        EMPTY_NO_MATCH,
        EMPTY_NO_COMMENTS,
        ERROR_AUTH,
        ERROR_RATE_LIMIT,
        ERROR_SERVICE,
        ERROR_NETWORK,
        ERROR_PARSE,
        DISABLED
    }

    enum SourceKind {
        NONE,
        SOURCE_BUNDLED,
        PLUGIN_PUSH,
        LOCAL_FILE,
        CUSTOM_SERVICE
    }

    static final class RequestContext {
        final long requestId;
        final String siteKey;
        final String videoId;
        final String lineName;
        final String episodeName;
        final String episodeUrl;
        final int episodeIndex;
        final boolean switchedFromPrior;
        final long createdAtMs;

        RequestContext(
                long requestId,
                String siteKey,
                String videoId,
                String lineName,
                String episodeName,
                String episodeUrl,
                int episodeIndex,
                boolean switchedFromPrior,
                long createdAtMs) {
            this.requestId = requestId;
            this.siteKey = siteKey == null ? "" : siteKey;
            this.videoId = videoId == null ? "" : videoId;
            this.lineName = lineName == null ? "" : lineName;
            this.episodeName = episodeName == null ? "" : episodeName;
            this.episodeUrl = episodeUrl == null ? "" : episodeUrl;
            this.episodeIndex = episodeIndex;
            this.switchedFromPrior = switchedFromPrior;
            this.createdAtMs = createdAtMs;
        }

        boolean matches(RequestContext other) {
            if (other == null) return false;
            return requestId == other.requestId
                    && siteKey.equals(other.siteKey)
                    && videoId.equals(other.videoId)
                    && lineName.equals(other.lineName)
                    && episodeName.equals(other.episodeName)
                    && episodeUrl.equals(other.episodeUrl);
        }

        boolean matchesPlaybackTarget(
                String site, String vid, String line, String epName, String epUrl) {
            return siteKey.equals(site == null ? "" : site)
                    && videoId.equals(vid == null ? "" : vid)
                    && lineName.equals(line == null ? "" : line)
                    && episodeName.equals(epName == null ? "" : epName)
                    && episodeUrl.equals(epUrl == null ? "" : epUrl);
        }

        String anonId() {
            return "r" + requestId + "-e" + Math.max(0, episodeIndex);
        }
    }

    static final class PushResolution {
        final boolean accepted;
        final String url;
        final RequestContext owner;
        final String rejectReason;

        private PushResolution(
                boolean accepted, String url, RequestContext owner, String rejectReason) {
            this.accepted = accepted;
            this.url = url == null ? "" : url;
            this.owner = owner;
            this.rejectReason = rejectReason == null ? "" : rejectReason;
        }

        static PushResolution accept(String url, RequestContext owner) {
            return new PushResolution(true, url, owner, "");
        }

        static PushResolution reject(String reason) {
            return new PushResolution(false, "", null, reason);
        }
    }

    static final class Coordinator {
        private static final long POST_EXIT_AMBIGUITY_WINDOW_MS = 30000L;

        private final InheritableThreadLocal<RequestContext> threadScope =
                new InheritableThreadLocal<RequestContext>();
        private final Object lock = new Object();

        private long nextRequestId = 1L;
        private RequestContext activeContext;
        private boolean currentHasConfirmedDanmu;
        private String pendingUrl = "";
        private RequestContext pendingOwner;
        private long pendingAtMs = 0L;
        private long lastInvalidatedAtMs = 0L;

        RequestContext beginResolve(
                String siteKey,
                String videoId,
                String lineName,
                String episodeName,
                String episodeUrl,
                int episodeIndex,
                boolean explicitSwitch) {
            long now = System.currentTimeMillis();
            synchronized (lock) {
                boolean switched =
                        explicitSwitch
                                || activeContext != null
                                || (lastInvalidatedAtMs > 0L
                                        && (now - lastInvalidatedAtMs)
                                                < POST_EXIT_AMBIGUITY_WINDOW_MS);
                long id = nextRequestId++;
                RequestContext ctx =
                        new RequestContext(
                                id,
                                siteKey,
                                videoId,
                                lineName,
                                episodeName,
                                episodeUrl,
                                episodeIndex,
                                switched,
                                now);
                activeContext = ctx;
                currentHasConfirmedDanmu = false;
                pendingUrl = "";
                pendingOwner = null;
                pendingAtMs = 0L;
                return ctx;
            }
        }

        RequestContext ensureActiveContext(
                String siteKey,
                String videoId,
                String lineName,
                String episodeName,
                String episodeUrl,
                int episodeIndex) {
            synchronized (lock) {
                if (activeContext != null
                        && activeContext.matchesPlaybackTarget(
                                siteKey, videoId, lineName, episodeName, episodeUrl)) {
                    return activeContext;
                }
            }
            return beginResolve(
                    siteKey, videoId, lineName, episodeName, episodeUrl, episodeIndex, false);
        }

        void invalidateForSwitch() {
            long now = System.currentTimeMillis();
            synchronized (lock) {
                nextRequestId++;
                activeContext = null;
                currentHasConfirmedDanmu = false;
                pendingUrl = "";
                pendingOwner = null;
                pendingAtMs = 0L;
                lastInvalidatedAtMs = now;
            }
        }

        void clearActiveScope() {
            invalidateForSwitch();
        }

        RequestContext activeContext() {
            synchronized (lock) {
                return activeContext;
            }
        }

        boolean isCurrentOwner(RequestContext owner) {
            if (owner == null) return false;
            synchronized (lock) {
                return activeContext != null && activeContext.matches(owner);
            }
        }

        void markConfirmedDanmuMounted(RequestContext owner) {
            if (owner == null) return;
            synchronized (lock) {
                if (activeContext != null && activeContext.matches(owner)) {
                    currentHasConfirmedDanmu = true;
                }
            }
        }

        RequestContext bindThreadScope(RequestContext ctx) {
            RequestContext prev = threadScope.get();
            if (ctx == null) {
                threadScope.remove();
            } else {
                threadScope.set(ctx);
            }
            return prev;
        }

        void restoreThreadScope(RequestContext prev) {
            if (prev == null) {
                threadScope.remove();
            } else {
                threadScope.set(prev);
            }
        }

        PushResolution onPluginPush(String rawUrl) {
            return onPluginPush(rawUrl, null);
        }

        PushResolution onPluginPush(String rawUrl, RequestContext explicitOwner) {
            String trimmed = rawUrl == null ? "" : rawUrl.trim();
            if (trimmed.isEmpty()) {
                return PushResolution.reject("empty");
            }
            RequestContext boundOwner = explicitOwner != null ? explicitOwner : threadScope.get();
            long now = System.currentTimeMillis();
            synchronized (lock) {
                if (activeContext == null) {
                    return PushResolution.reject("no_active_scope");
                }
                if (boundOwner != null) {
                    if (!boundOwner.matches(activeContext)) {
                        return PushResolution.reject("stale_bound_owner");
                    }
                    pendingUrl = trimmed;
                    pendingOwner = boundOwner;
                    pendingAtMs = now;
                    return PushResolution.accept(trimmed, boundOwner);
                }
                if (currentHasConfirmedDanmu) {
                    return PushResolution.reject("unbound_cannot_overwrite_confirmed");
                }
                if (activeContext.switchedFromPrior) {
                    return PushResolution.reject("ambiguous_after_switch");
                }
                pendingUrl = trimmed;
                pendingOwner = activeContext;
                pendingAtMs = now;
                return PushResolution.accept(trimmed, activeContext);
            }
        }

        String consumePending(RequestContext expectedOwner, long maxAgeMs) {
            if (expectedOwner == null) return "";
            long now = System.currentTimeMillis();
            synchronized (lock) {
                if (pendingUrl.isEmpty()
                        || pendingOwner == null
                        || activeContext == null
                        || !activeContext.matches(expectedOwner)
                        || !pendingOwner.matches(expectedOwner)) {
                    return "";
                }
                if (pendingAtMs <= 0L || (now - pendingAtMs) > maxAgeMs) {
                    pendingUrl = "";
                    pendingOwner = null;
                    pendingAtMs = 0L;
                    return "";
                }
                String out = pendingUrl;
                pendingUrl = "";
                pendingOwner = null;
                pendingAtMs = 0L;
                return out;
            }
        }

        void resetForTest() {
            threadScope.remove();
            synchronized (lock) {
                nextRequestId = 1L;
                activeContext = null;
                currentHasConfirmedDanmu = false;
                pendingUrl = "";
                pendingOwner = null;
                pendingAtMs = 0L;
                lastInvalidatedAtMs = 0L;
            }
        }
    }

    static final class EpisodeStatus {
        String episodeLabel = "";
        State state = State.IDLE;
        SourceKind sourceKind = SourceKind.NONE;
        int knownCount = -1;
        String matchedLabel = "";
        String commentId = "";
        int httpStatus = 0;
        long retryAfterMs = 0L;
        String reasonDetail = "";
        private String lastAutoToastKey = "";

        void reset(String epLabel) {
            this.episodeLabel = epLabel == null ? "" : epLabel.trim();
            this.state = State.IDLE;
            this.sourceKind = SourceKind.NONE;
            this.knownCount = -1;
            this.matchedLabel = "";
            this.commentId = "";
            this.httpStatus = 0;
            this.retryAfterMs = 0L;
            this.reasonDetail = "";
            this.lastAutoToastKey = "";
        }

        void markLoading(SourceKind source) {
            this.state = State.LOADING;
            this.sourceKind = source == null ? SourceKind.NONE : source;
            this.knownCount = -1;
            this.httpStatus = 0;
            this.retryAfterMs = 0L;
            this.reasonDetail = "";
        }

        void markLoaded(SourceKind source, int countIfKnown, String matched, String cid) {
            this.state = State.LOADED;
            this.sourceKind = source == null ? SourceKind.NONE : source;
            this.knownCount = countIfKnown;
            this.matchedLabel = matched == null ? "" : matched.trim();
            this.commentId = cid == null ? "" : cid.trim();
            this.httpStatus = 0;
            this.retryAfterMs = 0L;
            this.reasonDetail = "";
        }

        void markNoMatch() {
            this.state = State.EMPTY_NO_MATCH;
            this.knownCount = -1;
            this.matchedLabel = "";
            this.commentId = "";
            this.httpStatus = 0;
            this.retryAfterMs = 0L;
            this.reasonDetail = "未匹配到本集弹幕";
        }

        void markNoComments(SourceKind source, String matched, String cid) {
            this.state = State.EMPTY_NO_COMMENTS;
            this.sourceKind = source == null ? SourceKind.NONE : source;
            this.knownCount = 0;
            this.matchedLabel = matched == null ? "" : matched.trim();
            this.commentId = cid == null ? "" : cid.trim();
            this.httpStatus = 0;
            this.retryAfterMs = 0L;
            this.reasonDetail = "本集暂无弹幕";
        }

        void markFailure(SourceKind source, DanmuProvider.FailureInfo info) {
            this.sourceKind = source == null ? this.sourceKind : source;
            this.knownCount = -1;
            if (info == null) {
                this.state = State.ERROR_NETWORK;
                this.httpStatus = 0;
                this.retryAfterMs = 0L;
                this.reasonDetail = "加载失败";
                return;
            }
            this.httpStatus = info.httpStatus;
            this.retryAfterMs = info.retryAfterMs;
            this.reasonDetail = info.shortReason;
            switch (info.kind) {
                case AUTH:
                    this.state = State.ERROR_AUTH;
                    break;
                case RATE_LIMIT:
                    this.state = State.ERROR_RATE_LIMIT;
                    break;
                case SERVICE_ERROR:
                    this.state = State.ERROR_SERVICE;
                    break;
                case NO_DATA:
                    this.state = State.EMPTY_NO_MATCH;
                    break;
                default:
                    this.state = State.ERROR_NETWORK;
                    break;
            }
        }

        void markParseError(SourceKind source, String detail) {
            this.sourceKind = source == null ? this.sourceKind : source;
            this.state = State.ERROR_PARSE;
            this.knownCount = -1;
            this.httpStatus = 0;
            this.retryAfterMs = 0L;
            this.reasonDetail =
                    (detail == null || detail.trim().isEmpty()) ? "弹幕格式无法识别" : detail.trim();
        }

        void markDisabled() {
            this.state = State.DISABLED;
        }

        boolean isFailure() {
            return state == State.ERROR_AUTH
                    || state == State.ERROR_RATE_LIMIT
                    || state == State.ERROR_SERVICE
                    || state == State.ERROR_NETWORK
                    || state == State.ERROR_PARSE;
        }

        boolean shouldEmitAutoToast(String key) {
            String k = episodeLabel + "|" + (key == null ? "" : key);
            if (k.equals(lastAutoToastKey)) return false;
            lastAutoToastKey = k;
            return true;
        }

        String sourceLabel() {
            switch (sourceKind) {
                case SOURCE_BUNDLED:
                    return "片源自带";
                case PLUGIN_PUSH:
                    return "插件推送";
                case LOCAL_FILE:
                    return "本地文件";
                case CUSTOM_SERVICE:
                    return "自定义服务";
                default:
                    return "";
            }
        }

        String statusHeadline() {
            String ep = episodeLabel.isEmpty() ? "当前剧集" : episodeLabel;
            String src = sourceLabel();
            switch (state) {
                case LOADING:
                    return ep + (src.isEmpty() ? "" : " · " + src) + " · 正在加载弹幕…";
                case LOADED:
                    String countPart = knownCount > 0 ? ("已加载 " + knownCount + " 条") : "已加载";
                    return ep + (src.isEmpty() ? "" : " · " + src) + " · " + countPart;
                case EMPTY_NO_MATCH:
                    return ep + " · 尚未匹配";
                case EMPTY_NO_COMMENTS:
                    return ep + (src.isEmpty() ? "" : " · " + src) + " · 本集暂无弹幕";
                case DISABLED:
                    return ep + " · 弹幕已关闭";
                case ERROR_AUTH:
                case ERROR_RATE_LIMIT:
                case ERROR_SERVICE:
                case ERROR_NETWORK:
                case ERROR_PARSE:
                    String why = reasonDetail.isEmpty() ? "加载失败" : reasonDetail;
                    return ep + (src.isEmpty() ? "" : " · " + src) + " · " + why;
                case IDLE:
                default:
                    return ep + " · 未加载弹幕";
            }
        }

        /**
         * Recommended initial focus in the TV danmu panel:
         * <ul>
         *   <li>{@code "retry"} when loading failed
         *   <li>{@code "correct"} when episode could not be matched
         *   <li>{@code "toggle"} under normal states
         * </ul>
         */
        String recommendedInitialFocusAction() {
            if (isFailure()) return "retry";
            if (state == State.EMPTY_NO_MATCH) return "correct";
            return "toggle";
        }
    }
}
