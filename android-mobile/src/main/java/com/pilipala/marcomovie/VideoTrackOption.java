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
        String trackDesc = selectedTrack == null ? "自动优选" : selectedTrack.formatLabel();
        String decodedDesc =
                decodedWidth > 0 && decodedHeight > 0 ? (decodedWidth + "×" + decodedHeight) : "未知";
        return "已选轨道: " + trackDesc + " | 实际解码: " + decodedDesc;
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
