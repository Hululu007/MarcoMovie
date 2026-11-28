package com.pilipala.marcomovie;

import androidx.media3.common.C;
import androidx.media3.common.audio.AudioProcessor;
import androidx.media3.common.audio.BaseAudioProcessor;

import java.nio.ByteBuffer;

/**
 * Pure-Java in-app PCM audio processor providing EQ presets and soft-limited loudness boost inside
 * Media3's {@code DefaultAudioSink}.
 *
 * <p>Running EQ/Bass/Loudness in-app avoids attaching vendor Android {@code android.media.audiofx}
 * session chains (such as NXP {@code Equalizer}/{@code BassBoost} or {@code LoudnessEnhancer}),
 * which on Xiaomi/Amlogic Android TVs trigger {@code EffectHAL SET_CONFIG Invalid argument} and
 * tear down the TV's hardware post-processing pipeline ({@code Hpeq}/{@code Avl}/{@code MS12 DAP}).
 */
final class TvAudioEffectProcessor extends BaseAudioProcessor {
    static final int PRESET_ORIGINAL = 0;
    static final int PRESET_CINEMA = 1;
    static final int PRESET_VOCAL = 2;
    static final int PRESET_SOFT_BASS = 3;

    private static final int MAX_CHANNELS = 8;
    private static final float LIMITER_KNEE = 0.85f;
    private static final float LIMITER_HEADROOM = 1.0f - LIMITER_KNEE;

    private volatile int requestedPreset = PRESET_ORIGINAL;
    private volatile int requestedBoostDb = 0;

    private int activePreset = -1;
    private int configuredSampleRate = 0;
    private int configuredChannels = 0;
    private int stageCount = 0;

    // Up to 3 cascaded biquad stages per audio channel (Direct Form II Transposed).
    private final double[] b0 = new double[3];
    private final double[] b1 = new double[3];
    private final double[] b2 = new double[3];
    private final double[] a1 = new double[3];
    private final double[] a2 = new double[3];
    private final double[][] z1 = new double[3][MAX_CHANNELS];
    private final double[][] z2 = new double[3][MAX_CHANNELS];

    TvAudioEffectProcessor() {}

    TvAudioEffectProcessor(int initialPreset, int initialBoostDb) {
        setAudioEffect(initialPreset);
        setLoudnessBoostDb(initialBoostDb);
    }

    static int clampPreset(int preset) {
        return Math.max(PRESET_ORIGINAL, Math.min(PRESET_SOFT_BASS, preset));
    }

    static int clampBoostDb(int boostDb) {
        return Math.max(0, Math.min(15, boostDb));
    }

    static float boostDbToLinearGain(int boostDb) {
        int clamped = clampBoostDb(boostDb);
        if (clamped <= 0) return 1.0f;
        return (float) Math.pow(10.0, clamped / 20.0);
    }

    /** Smooth soft-knee limiter keeping boosted PCM clean and strictly within [-1, 1]. */
    static float softLimit(float x) {
        if (!Float.isFinite(x)) return 0.0f;
        float abs = Math.abs(x);
        if (abs <= LIMITER_KNEE) return x;
        float excess = (abs - LIMITER_KNEE) / LIMITER_HEADROOM;
        float compressed = LIMITER_KNEE + LIMITER_HEADROOM * (float) Math.tanh(excess);
        return x >= 0.0f ? compressed : -compressed;
    }

    void setAudioEffect(int preset) {
        requestedPreset = clampPreset(preset);
    }

    void setLoudnessBoostDb(int boostDb) {
        requestedBoostDb = clampBoostDb(boostDb);
    }

    int getAudioEffect() {
        return requestedPreset;
    }

    int getLoudnessBoostDb() {
        return requestedBoostDb;
    }

    @Override
    protected AudioFormat onConfigure(AudioFormat inputAudioFormat)
            throws UnhandledAudioFormatException {
        if (inputAudioFormat == null
                || inputAudioFormat.sampleRate <= 0
                || inputAudioFormat.channelCount <= 0
                || inputAudioFormat.channelCount > MAX_CHANNELS) {
            return AudioFormat.NOT_SET;
        }
        if (inputAudioFormat.encoding != C.ENCODING_PCM_16BIT
                && inputAudioFormat.encoding != C.ENCODING_PCM_FLOAT) {
            return AudioFormat.NOT_SET;
        }
        return inputAudioFormat;
    }

    @Override
    public void queueInput(ByteBuffer inputBuffer) {
        int remaining = inputBuffer.remaining();
        if (remaining == 0) return;

        int preset = requestedPreset;
        int boostDb = requestedBoostDb;
        int channels = inputAudioFormat.channelCount;
        int sampleRate = inputAudioFormat.sampleRate;
        int encoding = inputAudioFormat.encoding;

        ByteBuffer out = replaceOutputBuffer(remaining);
        if (preset == PRESET_ORIGINAL && boostDb == 0) {
            if (activePreset != PRESET_ORIGINAL) {
                activePreset = PRESET_ORIGINAL;
                stageCount = 0;
                resetFilterStates();
            }
            out.put(inputBuffer);
            out.flip();
            return;
        }

        ensureFilterDesign(preset, sampleRate, channels);
        float gain = boostDbToLinearGain(boostDb);
        int stages = stageCount;

        if (encoding == C.ENCODING_PCM_16BIT) {
            int frameBytes = channels * 2;
            int frames = remaining / frameBytes;
            for (int f = 0; f < frames; f++) {
                for (int c = 0; c < channels; c++) {
                    double sample = inputBuffer.getShort() / 32768.0;
                    for (int s = 0; s < stages; s++) {
                        double y = b0[s] * sample + z1[s][c];
                        z1[s][c] = b1[s] * sample - a1[s] * y + z2[s][c];
                        z2[s][c] = b2[s] * sample - a2[s] * y;
                        sample = y;
                    }
                    float scaled = softLimit((float) (sample * gain));
                    int pcm = Math.round(scaled * 32767.0f);
                    if (pcm > 32767) pcm = 32767;
                    else if (pcm < -32768) pcm = -32768;
                    out.putShort((short) pcm);
                }
            }
            while (inputBuffer.hasRemaining()) {
                out.put(inputBuffer.get());
            }
        } else {
            int frameBytes = channels * 4;
            int frames = remaining / frameBytes;
            for (int f = 0; f < frames; f++) {
                for (int c = 0; c < channels; c++) {
                    float raw = inputBuffer.getFloat();
                    double sample = Float.isFinite(raw) ? raw : 0.0;
                    for (int s = 0; s < stages; s++) {
                        double y = b0[s] * sample + z1[s][c];
                        z1[s][c] = b1[s] * sample - a1[s] * y + z2[s][c];
                        z2[s][c] = b2[s] * sample - a2[s] * y;
                        sample = y;
                    }
                    out.putFloat(softLimit((float) (sample * gain)));
                }
            }
            while (inputBuffer.hasRemaining()) {
                out.put(inputBuffer.get());
            }
        }
        out.flip();
    }

    @Override
    protected void onFlush() {
        resetFilterStates();
    }

    @Override
    protected void onReset() {
        activePreset = -1;
        configuredSampleRate = 0;
        configuredChannels = 0;
        stageCount = 0;
        resetFilterStates();
    }

    private void resetFilterStates() {
        for (int s = 0; s < 3; s++) {
            for (int c = 0; c < MAX_CHANNELS; c++) {
                z1[s][c] = 0.0;
                z2[s][c] = 0.0;
            }
        }
    }

    private void ensureFilterDesign(int preset, int sampleRate, int channels) {
        if (preset == activePreset
                && sampleRate == configuredSampleRate
                && channels == configuredChannels) {
            return;
        }
        activePreset = preset;
        configuredSampleRate = sampleRate;
        configuredChannels = channels;
        resetFilterStates();

        if (preset == PRESET_CINEMA) {
            // Cinema: warm low-end punch + crisp high-frequency clarity.
            setLowShelf(0, sampleRate, 160.0, 0.75, 4.5);
            setHighShelf(1, sampleRate, 4500.0, 0.75, 1.5);
            stageCount = 2;
        } else if (preset == PRESET_VOCAL) {
            // Clear vocals: lift dialogue presence band, trim low rumble & harsh sibilance.
            setLowShelf(0, sampleRate, 150.0, 0.75, -1.5);
            setPeaking(1, sampleRate, 1600.0, 0.85, 3.5);
            setHighShelf(2, sampleRate, 6000.0, 0.75, -1.0);
            stageCount = 3;
        } else if (preset == PRESET_SOFT_BASS) {
            // Soft bass (night-friendly): attenuate sub/low bass, gently lift mid clarity.
            setLowShelf(0, sampleRate, 180.0, 0.75, -5.0);
            setPeaking(1, sampleRate, 1200.0, 0.85, 2.0);
            stageCount = 2;
        } else {
            stageCount = 0;
        }
    }

    private void setPeaking(int stage, int sr, double freqHz, double q, double gainDb) {
        double clampedFreq = Math.max(20.0, Math.min(freqHz, sr * 0.45));
        double a = Math.pow(10.0, gainDb / 40.0);
        double w0 = 2.0 * Math.PI * clampedFreq / sr;
        double cosW0 = Math.cos(w0);
        double alpha = Math.sin(w0) / (2.0 * q);
        double norm = 1.0 + alpha / a;
        b0[stage] = (1.0 + alpha * a) / norm;
        b1[stage] = (-2.0 * cosW0) / norm;
        b2[stage] = (1.0 - alpha * a) / norm;
        a1[stage] = (-2.0 * cosW0) / norm;
        a2[stage] = (1.0 - alpha / a) / norm;
    }

    private void setLowShelf(int stage, int sr, double freqHz, double slope, double gainDb) {
        double clampedFreq = Math.max(20.0, Math.min(freqHz, sr * 0.45));
        double a = Math.pow(10.0, gainDb / 40.0);
        double w0 = 2.0 * Math.PI * clampedFreq / sr;
        double cosW0 = Math.cos(w0);
        double sinW0 = Math.sin(w0);
        double alpha =
                (sinW0 / 2.0)
                        * Math.sqrt(Math.max(0.01, (a + 1.0 / a) * (1.0 / slope - 1.0) + 2.0));
        double twoSqrtAAlpha = 2.0 * Math.sqrt(a) * alpha;
        double norm = (a + 1.0) + (a - 1.0) * cosW0 + twoSqrtAAlpha;
        b0[stage] = (a * ((a + 1.0) - (a - 1.0) * cosW0 + twoSqrtAAlpha)) / norm;
        b1[stage] = (2.0 * a * ((a - 1.0) - (a + 1.0) * cosW0)) / norm;
        b2[stage] = (a * ((a + 1.0) - (a - 1.0) * cosW0 - twoSqrtAAlpha)) / norm;
        a1[stage] = (-2.0 * ((a - 1.0) + (a + 1.0) * cosW0)) / norm;
        a2[stage] = ((a + 1.0) + (a - 1.0) * cosW0 - twoSqrtAAlpha) / norm;
    }

    private void setHighShelf(int stage, int sr, double freqHz, double slope, double gainDb) {
        double clampedFreq = Math.max(20.0, Math.min(freqHz, sr * 0.45));
        double a = Math.pow(10.0, gainDb / 40.0);
        double w0 = 2.0 * Math.PI * clampedFreq / sr;
        double cosW0 = Math.cos(w0);
        double sinW0 = Math.sin(w0);
        double alpha =
                (sinW0 / 2.0)
                        * Math.sqrt(Math.max(0.01, (a + 1.0 / a) * (1.0 / slope - 1.0) + 2.0));
        double twoSqrtAAlpha = 2.0 * Math.sqrt(a) * alpha;
        double norm = (a + 1.0) - (a - 1.0) * cosW0 + twoSqrtAAlpha;
        b0[stage] = (a * ((a + 1.0) + (a - 1.0) * cosW0 + twoSqrtAAlpha)) / norm;
        b1[stage] = (-2.0 * a * ((a - 1.0) + (a + 1.0) * cosW0)) / norm;
        b2[stage] = (a * ((a + 1.0) + (a - 1.0) * cosW0 - twoSqrtAAlpha)) / norm;
        a1[stage] = (2.0 * ((a - 1.0) - (a + 1.0) * cosW0)) / norm;
        a2[stage] = ((a + 1.0) - (a - 1.0) * cosW0 - twoSqrtAAlpha) / norm;
    }
}
