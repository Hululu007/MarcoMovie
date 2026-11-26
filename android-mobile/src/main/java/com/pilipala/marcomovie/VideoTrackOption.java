package com.pilipala.marcomovie;

import java.util.Locale;

/**
 * Pure-JVM representation of an enumerated Media3 / MPV video track and quality-switch snapshot.
 */
public final class VideoTrackOption {
    public final int index;
    public final int width;
    public final int height;
    public final int bitrateBps;
    public final float frameRate;
    public final String codec;
    public final boolean hdr;
    public final boolean selected;
    public final String rawLabel;

    public VideoTrackOption(
            int index,
            int width,
            int height,
            int bitrateBps,
            float frameRate,
            String codec,
            boolean hdr,
            boolean selected,
            String rawLabel) {
        this.index = index;
        this.width = Math.max(0, width);
        this.height = Math.max(0, height);
        this.bitrateBps = Math.max(0, bitrateBps);
        this.frameRate = frameRate > 0f ? frameRate : 0f;
        this.codec = codec == null ? "" : codec.trim();
        this.hdr = hdr;
        this.selected = selected;
        this.rawLabel = rawLabel == null ? "" : rawLabel.trim();
    }

    public static String qualityTier(int width, int height) {
        int longEdge = Math.max(width, height);
        if (longEdge >= 3800 || height >= 2100) return "4K";
        if (longEdge >= 2500 || height >= 1400) return "2K";
        if (longEdge >= 1900 || height >= 1000) return "1080P";
        if (longEdge >= 1200 || height >= 700) return "720P";
        if (height > 0) return height + "P";
        return "";
    }

    public String formatLabel() {
        StringBuilder sb = new StringBuilder();
        if (width > 0 && height > 0) {
            String tier = qualityTier(width, height);
            if (!tier.isEmpty()) {
                sb.append(tier).append(" · ");
            }
            sb.append(width).append("×").append(height);
        } else if (!rawLabel.isEmpty()) {
            sb.append(rawLabel);
        } else {
            sb.append("视频轨 ").append(index + 1);
        }
        if (!codec.isEmpty()) {
            sb.append(" · ").append(codec);
        }
        if (hdr) {
            sb.append(" · HDR");
        }
        if (bitrateBps >= 1_000_000) {
            sb.append(String.format(Locale.ROOT, " · %.1f Mbps", bitrateBps / 1_000_000.0));
        } else if (bitrateBps >= 1000) {
            sb.append(" · ").append(bitrateBps / 1000).append(" kbps");
        }
        if (frameRate >= 1f) {
            sb.append(" · ").append(Math.round(frameRate)).append(" 帧");
        }
        return sb.toString();
    }

    public static String formatSelectionRecord(
            VideoTrackOption selectedTrack, int decodedWidth, int decodedHeight) {
        String policyDesc =
                selectedTrack == null ? "自动选择策略" : ("手动锁定 " + selectedTrack.formatLabel());
        String decodedDesc =
                decodedWidth > 0 && decodedHeight > 0 ? (decodedWidth + "×" + decodedHeight) : "未知";
        return "选择策略: " + policyDesc + " | 当前解码轨道: " + decodedDesc;
    }

    /**
     * Explicit separation of "auto-selection policy" ({@link #autoPolicy}) vs "currently decoded
     * track" ({@link #decodedTrackIndex} / {@link #decodedResolution}), so switching {@code auto ->
     * 1080p -> auto} accurately reflects both the active selection policy and the active decoder
     * output.
     */
    public static final class SelectionState {
        public final boolean autoPolicy;
        public final int manualTrackIndex;
        public final int decodedTrackIndex;
        public final String decodedResolution;

        public SelectionState(
                boolean autoPolicy,
                int manualTrackIndex,
                int decodedTrackIndex,
                String decodedResolution) {
            this.autoPolicy = autoPolicy;
            this.manualTrackIndex = autoPolicy ? -1 : manualTrackIndex;
            this.decodedTrackIndex = decodedTrackIndex;
            this.decodedResolution = decodedResolution == null ? "" : decodedResolution.trim();
        }

        private String resolveDecodedTier(java.util.List<VideoTrackOption> tracks) {
            if (decodedTrackIndex >= 0 && tracks != null && decodedTrackIndex < tracks.size()) {
                VideoTrackOption d = tracks.get(decodedTrackIndex);
                String tier = qualityTier(d.width, d.height);
                if (!tier.isEmpty()) return tier;
                if (d.width > 0 && d.height > 0) return d.width + "×" + d.height;
            }
            return decodedResolution;
        }

        public String policySummary(java.util.List<VideoTrackOption> tracks) {
            String decodedTier = resolveDecodedTier(tracks);
            if (autoPolicy) {
                return decodedTier.isEmpty() ? "策略：自动优选" : ("策略：自动优选 · 当前解码 " + decodedTier);
            }
            return decodedTier.isEmpty() ? "策略：手动锁定轨道" : ("策略：手动锁定 · 当前解码 " + decodedTier);
        }

        public String formatAutoOptionLabel(java.util.List<VideoTrackOption> tracks) {
            if (!autoPolicy) return "视频轨 · 自动优选";
            String decodedTier = resolveDecodedTier(tracks);
            return decodedTier.isEmpty()
                    ? "视频轨 · 自动优选（当前策略）"
                    : ("视频轨 · 自动优选（当前策略 · 解码 " + decodedTier + "）");
        }

        public String formatTrackOptionLabel(VideoTrackOption opt) {
            if (opt == null) return "";
            boolean isLocked = !autoPolicy && manualTrackIndex == opt.index;
            boolean isDecoded = decodedTrackIndex == opt.index || opt.selected;
            String tag;
            if (isLocked && isDecoded) tag = "（已锁定 · 当前解码）";
            else if (isLocked) tag = "（已锁定）";
            else if (isDecoded) tag = "（当前解码）";
            else tag = "";
            return "视频轨 · " + opt.formatLabel() + tag;
        }

        /** Returns 0 when auto policy is active, or {@code 1 + manualTrackIndex} when locked. */
        public int menuSelectedOffset() {
            return (autoPolicy || manualTrackIndex < 0) ? 0 : (1 + manualTrackIndex);
        }
    }

    /** Captures playback position and paused state before a quality/variant switch. */
    public static final class SwitchState {
        public final int resumePositionMs;
        public final boolean startPaused;

        public SwitchState(int resumePositionMs, boolean startPaused) {
            this.resumePositionMs = Math.max(0, resumePositionMs);
            this.startPaused = startPaused;
        }

        public static SwitchState capture(
                boolean isLive, boolean prepared, int currentPosMs, boolean isPlaying) {
            int pos = (!isLive && prepared && currentPosMs > 0) ? currentPosMs : 0;
            boolean paused = prepared && !isPlaying;
            return new SwitchState(pos, paused);
        }
    }
}
