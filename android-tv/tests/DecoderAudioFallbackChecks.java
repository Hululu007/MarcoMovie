package com.pilipala.marcomovie;

import androidx.media3.common.C;
import androidx.media3.common.DrmInitData;
import androidx.media3.common.Format;
import androidx.media3.common.MimeTypes;
import androidx.media3.common.audio.AudioProcessor;
import androidx.media3.exoplayer.mediacodec.MediaCodecInfo;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;

/**
 * Pure-JVM verification of Android TV audio decoder fallback rules:
 * clear vendor Dolby/DTS fallback to FFmpeg AND DRM-encrypted track preservation.
 */
public final class DecoderAudioFallbackChecks {
    private static int checks;

    private static void check(boolean condition, String message) {
        checks++;
        if (!condition) throw new AssertionError("FAILED: " + message);
    }

    private static MediaCodecInfo fakeCodec(String name, String mime, boolean secure) {
        return MediaCodecInfo.newInstance(name, mime, mime, null, true, false, true, false, secure);
    }

    private static MediaCodecInfo fakeCodec(String name, String mime) {
        return fakeCodec(name, mime, false);
    }

    private static Format formatOf(String mime, int cryptoType, boolean withDrmInitData) {
        Format.Builder b =
                new Format.Builder()
                        .setSampleMimeType(mime)
                        .setChannelCount(6)
                        .setSampleRate(48000)
                        .setCryptoType(cryptoType);
        if (withDrmInitData) {
            b.setDrmInitData(new DrmInitData("cenc"));
        }
        return b.build();
    }

    public static void main(String[] args) {
        // 1. Cinema surround MIMEs recognized
        for (String mime :
                new String[] {
                    MimeTypes.AUDIO_AC3,
                    MimeTypes.AUDIO_E_AC3,
                    MimeTypes.AUDIO_E_AC3_JOC,
                    MimeTypes.AUDIO_DTS,
                    MimeTypes.AUDIO_DTS_HD,
                    MimeTypes.AUDIO_DTS_EXPRESS,
                    MimeTypes.AUDIO_DTS_X,
                    MimeTypes.AUDIO_TRUEHD
                }) {
            check(DecoderRenderersFactory.isCinemaAudioMime(mime), "cinema mime " + mime);
        }
        check(!DecoderRenderersFactory.isCinemaAudioMime(MimeTypes.AUDIO_AAC), "aac not cinema");
        check(!DecoderRenderersFactory.isCinemaAudioMime(MimeTypes.AUDIO_MPEG), "mp3 not cinema");
        check(!DecoderRenderersFactory.isCinemaAudioMime(MimeTypes.AUDIO_OPUS), "opus not cinema");

        // 2. Broken Amlogic vendor audio decoders ALWAYS flagged
        check(
                DecoderRenderersFactory.isSilentOrUnreliableVendorAudioCodec(
                        "OMX.amlogic.audio.decoder.ac3", MimeTypes.AUDIO_AC3),
                "amlogic ac3 flagged");
        check(
                DecoderRenderersFactory.isSilentOrUnreliableVendorAudioCodec(
                        "OMX.amlogic.audio.decoder.eac3", MimeTypes.AUDIO_E_AC3),
                "amlogic eac3 flagged");
        check(
                DecoderRenderersFactory.isSilentOrUnreliableVendorAudioCodec(
                        "OMX.amlogic.audio.decoder.eac3", MimeTypes.AUDIO_E_AC3_JOC),
                "amlogic eac3 for atmos flagged");
        check(
                DecoderRenderersFactory.isSilentOrUnreliableVendorAudioCodec(
                        "OMX.amlogic.audio.decoder.dtshd", MimeTypes.AUDIO_DTS_HD),
                "amlogic dtshd flagged");
        check(
                DecoderRenderersFactory.isSilentOrUnreliableVendorAudioCodec(
                        "OMX.amlogic.audio.decoder.ffmpeg", MimeTypes.AUDIO_AAC),
                "amlogic ffmpeg audio stub flagged");
        check(
                DecoderRenderersFactory.isSilentOrUnreliableVendorAudioCodec(
                        "OMX.MTK.AUDIO.DECODER.AC3", MimeTypes.AUDIO_AC3),
                "vendor mtk ac3 flagged");

        // 3. Standard AOSP audio decoders preserved
        check(
                !DecoderRenderersFactory.isSilentOrUnreliableVendorAudioCodec(
                        "OMX.google.aac.decoder", MimeTypes.AUDIO_AAC),
                "google aac preserved");
        check(
                !DecoderRenderersFactory.isSilentOrUnreliableVendorAudioCodec(
                        "c2.android.aac.decoder", MimeTypes.AUDIO_AAC),
                "c2 android aac preserved");
        check(
                !DecoderRenderersFactory.isSilentOrUnreliableVendorAudioCodec(
                        "OMX.google.opus.decoder", MimeTypes.AUDIO_OPUS),
                "google opus preserved");

        // 4. Clear tracks: filter strips silent Amlogic AC-3/E-AC-3/Atmos when FFmpeg + PCM sink
        // can handle
        MediaCodecInfo amlAc3 = fakeCodec("OMX.amlogic.audio.decoder.ac3", MimeTypes.AUDIO_AC3);
        MediaCodecInfo amlEac3 = fakeCodec("OMX.amlogic.audio.decoder.eac3", MimeTypes.AUDIO_E_AC3);
        MediaCodecInfo vendorSecureEac3 =
                fakeCodec("OMX.vendor.audio.decoder.eac3.secure", MimeTypes.AUDIO_E_AC3, true);
        MediaCodecInfo gooAac = fakeCodec("OMX.google.aac.decoder", MimeTypes.AUDIO_AAC);
        MediaCodecInfo amlFfmpegAac =
                fakeCodec("OMX.amlogic.audio.decoder.ffmpeg", MimeTypes.AUDIO_AAC);

        Format clearAc3 = formatOf(MimeTypes.AUDIO_AC3, C.CRYPTO_TYPE_NONE, false);
        Format clearEac3 = formatOf(MimeTypes.AUDIO_E_AC3, C.CRYPTO_TYPE_NONE, false);
        Format clearAtmos = formatOf(MimeTypes.AUDIO_E_AC3_JOC, C.CRYPTO_TYPE_NONE, false);
        Format clearAac = formatOf(MimeTypes.AUDIO_AAC, C.CRYPTO_TYPE_NONE, false);

        List<MediaCodecInfo> ac3Out =
                DecoderRenderersFactory.filterAudioDecodersForFormat(
                        clearAc3,
                        MimeTypes.AUDIO_AC3,
                        Collections.singletonList(amlAc3),
                        false,
                        false,
                        true,
                        true,
                        true);
        check(ac3Out.isEmpty(), "clear ac3 drops amlogic stub so Media3 uses FfmpegAudioRenderer");

        List<MediaCodecInfo> eac3Out =
                DecoderRenderersFactory.filterAudioDecodersForFormat(
                        clearEac3,
                        MimeTypes.AUDIO_E_AC3,
                        Collections.singletonList(amlEac3),
                        false,
                        false,
                        true,
                        true,
                        true);
        check(
                eac3Out.isEmpty(),
                "clear eac3 drops amlogic stub so Media3 uses FfmpegAudioRenderer");

        List<MediaCodecInfo> eac3JocOut =
                DecoderRenderersFactory.filterAudioDecodersForFormat(
                        clearAtmos,
                        MimeTypes.AUDIO_E_AC3_JOC,
                        Collections.singletonList(amlEac3),
                        false,
                        false,
                        true,
                        true,
                        true);
        check(
                eac3JocOut.isEmpty(),
                "clear eac3-joc drops amlogic stub so Media3 uses FfmpegAudioRenderer");

        List<MediaCodecInfo> aacOut =
                DecoderRenderersFactory.filterAudioDecodersForFormat(
                        clearAac,
                        MimeTypes.AUDIO_AAC,
                        Arrays.asList(amlFfmpegAac, gooAac),
                        false,
                        false,
                        true,
                        true,
                        true);
        check(
                aacOut.size() == 1 && "OMX.google.aac.decoder".equals(aacOut.get(0).name),
                "clear aac keeps google decoder and drops amlogic stub");

        // 5. R14 P1 DRM-protected tracks: BOTH secure-decoder-required AND
        // encrypted-without-secure-decoder
        //    MUST preserve platform vendor decoders because FfmpegAudioRenderer returns
        // FORMAT_UNSUPPORTED_DRM!
        Format protectedEac3 = formatOf(MimeTypes.AUDIO_E_AC3, C.CRYPTO_TYPE_FRAMEWORK, false);
        Format protectedDrmInitOnly = formatOf(MimeTypes.AUDIO_E_AC3, C.CRYPTO_TYPE_NONE, true);
        Format protectedAac = formatOf(MimeTypes.AUDIO_AAC, C.CRYPTO_TYPE_FRAMEWORK, false);

        List<MediaCodecInfo> protectedSecureOut =
                DecoderRenderersFactory.filterAudioDecodersForFormat(
                        protectedEac3,
                        MimeTypes.AUDIO_E_AC3,
                        Collections.singletonList(vendorSecureEac3),
                        true,
                        false,
                        true,
                        true,
                        true);
        check(
                protectedSecureOut.size() == 1
                        && "OMX.vendor.audio.decoder.eac3.secure"
                                .equals(protectedSecureOut.get(0).name),
                "R14 P1: protected E-AC-3 requiring secure decoder preserves platform codec");

        List<MediaCodecInfo> protectedNoSecureOut =
                DecoderRenderersFactory.filterAudioDecodersForFormat(
                        protectedEac3,
                        MimeTypes.AUDIO_E_AC3,
                        Collections.singletonList(amlEac3),
                        false,
                        false,
                        true,
                        true,
                        true);
        check(
                protectedNoSecureOut.size() == 1
                        && "OMX.amlogic.audio.decoder.eac3"
                                .equals(protectedNoSecureOut.get(0).name),
                "R14 P1: encrypted E-AC-3 with requiresSecureDecoder=false STILL preserves platform codec");

        List<MediaCodecInfo> protectedDrmInitOut =
                DecoderRenderersFactory.filterAudioDecodersForFormat(
                        protectedDrmInitOnly,
                        MimeTypes.AUDIO_E_AC3,
                        Collections.singletonList(amlEac3),
                        false,
                        false,
                        true,
                        true,
                        true);
        check(
                protectedDrmInitOut.size() == 1,
                "R14 P1: track carrying drmInitData preserves platform codec");

        List<MediaCodecInfo> protectedAacOut =
                DecoderRenderersFactory.filterAudioDecodersForFormat(
                        protectedAac,
                        MimeTypes.AUDIO_AAC,
                        Collections.singletonList(gooAac),
                        false,
                        false,
                        true,
                        true,
                        true);
        check(
                protectedAacOut.size() == 1
                        && "OMX.google.aac.decoder".equals(protectedAacOut.get(0).name),
                "R14 P1: protected AAC control preserves AOSP codec");

        // 6. Controls: tunneling, FFmpeg unavailable, MIME unsupported by FFmpeg, or sink doesn't
        // support PCM
        List<MediaCodecInfo> tunneledClear =
                DecoderRenderersFactory.filterAudioDecodersForFormat(
                        clearEac3,
                        MimeTypes.AUDIO_E_AC3,
                        Collections.singletonList(amlEac3),
                        false,
                        true,
                        true,
                        true,
                        true);
        check(tunneledClear.size() == 1, "keep vendor codec when tunneling (clear)");

        List<MediaCodecInfo> tunneledProtected =
                DecoderRenderersFactory.filterAudioDecodersForFormat(
                        protectedEac3,
                        MimeTypes.AUDIO_E_AC3,
                        Collections.singletonList(vendorSecureEac3),
                        true,
                        true,
                        true,
                        true,
                        true);
        check(tunneledProtected.size() == 1, "keep vendor codec when tunneling (protected)");

        List<MediaCodecInfo> noFfmpegClear =
                DecoderRenderersFactory.filterAudioDecodersForFormat(
                        clearAc3,
                        MimeTypes.AUDIO_AC3,
                        Collections.singletonList(amlAc3),
                        false,
                        false,
                        false,
                        false,
                        true);
        check(noFfmpegClear.size() == 1, "keep vendor codec when ffmpeg unavailable (clear)");

        List<MediaCodecInfo> noFfmpegProtected =
                DecoderRenderersFactory.filterAudioDecodersForFormat(
                        protectedEac3,
                        MimeTypes.AUDIO_E_AC3,
                        Collections.singletonList(vendorSecureEac3),
                        true,
                        false,
                        false,
                        false,
                        true);
        check(
                noFfmpegProtected.size() == 1,
                "keep vendor codec when ffmpeg unavailable (protected)");

        List<MediaCodecInfo> noSinkPcm =
                DecoderRenderersFactory.filterAudioDecodersForFormat(
                        clearAc3,
                        MimeTypes.AUDIO_AC3,
                        Collections.singletonList(amlAc3),
                        false,
                        false,
                        true,
                        true,
                        false);
        check(noSinkPcm.size() == 1, "keep vendor codec when AudioSink cannot accept PCM output");

        // 7. Legacy helper direct control checks preserved
        check(
                DecoderRenderersFactory.filterAudioDecodersForFfmpegFallback(
                                MimeTypes.AUDIO_AC3, Collections.singletonList(amlAc3), false, true)
                        .isEmpty(),
                "legacy MIME filter empties clear ac3");
        check(
                DecoderRenderersFactory.filterAudioDecodersForFfmpegFallback(
                                        MimeTypes.AUDIO_AC3,
                                        Collections.singletonList(amlAc3),
                                        false,
                                        false)
                                .size()
                        == 1,
                "legacy MIME filter preserves ac3 when ffmpeg unavailable");
        check(
                DecoderRenderersFactory.filterAudioDecodersForFfmpegFallback(
                                        MimeTypes.AUDIO_AC3,
                                        Collections.singletonList(amlAc3),
                                        true,
                                        true)
                                .size()
                        == 1,
                "legacy MIME filter preserves ac3 when tunneling");

        // 8. In-app Media3 PCM DSP (TvAudioEffectProcessor) replaces vendor android.media.audiofx
        check(
                !PlaybackEffects.shouldUsePlatformAudioFx(true, false)
                        && !PlaybackEffects.shouldUsePlatformAudioFx(false, true)
                        && PlaybackEffects.shouldUsePlatformAudioFx(false, false),
                "Media3 & MPV avoid platform android.media.audiofx; SystemPlayer keeps fallback");

        verifyInAppAudioEffectProcessor();

        System.out.println("DecoderAudioFallbackChecks OK (" + checks + " checks)");
    }

    private static double measurePcm16Rms(
            int preset, int boostDb, int channels, double freqHz, double amplitude) {
        TvAudioEffectProcessor dsp = new TvAudioEffectProcessor(preset, boostDb);
        AudioProcessor.AudioFormat fmt =
                new AudioProcessor.AudioFormat(48000, channels, C.ENCODING_PCM_16BIT);
        try {
            AudioProcessor.AudioFormat outFmt = dsp.configure(fmt);
            check(
                    outFmt.sampleRate == 48000
                            && outFmt.channelCount == channels
                            && outFmt.encoding == C.ENCODING_PCM_16BIT,
                    "TvAudioEffectProcessor accepts " + channels + "ch PCM_16BIT");
            dsp.flush();
            int frames = 2048;
            ByteBuffer in =
                    ByteBuffer.allocateDirect(frames * channels * 2).order(ByteOrder.nativeOrder());
            for (int f = 0; f < frames; f++) {
                short s =
                        (short)
                                Math.round(
                                        Math.sin(2.0 * Math.PI * freqHz * f / 48000.0)
                                                * amplitude
                                                * 32767.0);
                for (int c = 0; c < channels; c++) in.putShort(s);
            }
            in.flip();
            dsp.queueInput(in);
            check(!in.hasRemaining(), "TvAudioEffectProcessor consumes full PCM_16BIT input");
            ByteBuffer out = dsp.getOutput().order(ByteOrder.nativeOrder());
            check(
                    out.remaining() == frames * channels * 2,
                    "TvAudioEffectProcessor outputs exact frame count for preset=" + preset);
            double sumSq = 0.0;
            int samples = 0;
            // Skip initial 256-frame transient so steady-state biquad response is measured.
            for (int f = 0; f < frames; f++) {
                for (int c = 0; c < channels; c++) {
                    short v = out.getShort();
                    if (f >= 256) {
                        double norm = v / 32768.0;
                        sumSq += norm * norm;
                        samples++;
                    }
                }
            }
            return Math.sqrt(sumSq / Math.max(1, samples));
        } catch (AudioProcessor.UnhandledAudioFormatException e) {
            throw new AssertionError("Unexpected format rejection", e);
        }
    }

    private static void verifyInAppAudioEffectProcessor() {
        double base100 = measurePcm16Rms(TvAudioEffectProcessor.PRESET_ORIGINAL, 0, 2, 100.0, 0.25);
        double cinema100 = measurePcm16Rms(TvAudioEffectProcessor.PRESET_CINEMA, 0, 2, 100.0, 0.25);
        double softBass100 =
                measurePcm16Rms(TvAudioEffectProcessor.PRESET_SOFT_BASS, 0, 2, 100.0, 0.25);
        double base1600 =
                measurePcm16Rms(TvAudioEffectProcessor.PRESET_ORIGINAL, 0, 2, 1600.0, 0.25);
        double vocal1600 = measurePcm16Rms(TvAudioEffectProcessor.PRESET_VOCAL, 0, 2, 1600.0, 0.25);
        double boosted1600 =
                measurePcm16Rms(TvAudioEffectProcessor.PRESET_ORIGINAL, 6, 2, 1600.0, 0.25);
        double ch6Cinema = measurePcm16Rms(TvAudioEffectProcessor.PRESET_CINEMA, 6, 6, 440.0, 0.25);

        check(base100 > 0.15 && cinema100 > base100 * 1.25, "Cinema preset boosts 100Hz low-end");
        check(
                softBass100 > 0.05 && softBass100 < base100 * 0.85,
                "Soft Bass preset attenuates 100Hz low-end");
        check(vocal1600 > base1600 * 1.20, "Vocal preset lifts 1600Hz dialogue band");
        check(
                boosted1600 > base1600 * 1.75 && boosted1600 <= 0.99,
                "6dB loudness boost amplifies cleanly without clipping");
        check(ch6Cinema > 0.25, "6-channel (5.1) Cinema + Loudness produces strong non-zero PCM");

        // Float PCM NaN/Inf sanitization & soft-knee limiting
        try {
            TvAudioEffectProcessor floatDsp =
                    new TvAudioEffectProcessor(TvAudioEffectProcessor.PRESET_CINEMA, 15);
            floatDsp.configure(new AudioProcessor.AudioFormat(48000, 2, C.ENCODING_PCM_FLOAT));
            floatDsp.flush();
            ByteBuffer in = ByteBuffer.allocateDirect(8 * 4).order(ByteOrder.nativeOrder());
            in.putFloat(Float.NaN);
            in.putFloat(Float.POSITIVE_INFINITY);
            in.putFloat(2.5f);
            in.putFloat(-2.5f);
            in.putFloat(0.4f);
            in.putFloat(-0.4f);
            in.putFloat(0.2f);
            in.putFloat(-0.2f);
            in.flip();
            floatDsp.queueInput(in);
            ByteBuffer out = floatDsp.getOutput().order(ByteOrder.nativeOrder());
            while (out.remaining() >= 4) {
                float v = out.getFloat();
                check(
                        Float.isFinite(v) && Math.abs(v) <= 1.0f,
                        "Float DSP output stays finite and strictly within [-1, 1]");
            }
        } catch (AudioProcessor.UnhandledAudioFormatException e) {
            throw new AssertionError("Float PCM rejected unexpectedly", e);
        }
    }
}
