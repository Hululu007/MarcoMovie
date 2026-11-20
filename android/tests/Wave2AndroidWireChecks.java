// Copyright (C) 2026 Pilipala
// SPDX-License-Identifier: GPL-3.0-only
package com.pilipala.marcomovie;

import android.animation.ValueAnimator;
import android.content.Context;
import android.view.View;
import android.widget.FrameLayout;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * Offline JVM regression suite for Wave 2 Android wiring:
 *
 * <ol>
 *   <li>PlaybackControls child Z-order strictly Video(0) -> DanmakuView(1) -> SubtitleOverlayView(2)
 *       -> HUD(3+).
 *   <li>API 23-32 GlassworkSurface freeze on transition start and idempotent unfreeze on animation
 *       end, cancel, and view detach.
 *   <li>FocusMotion Prefs.REDUCED 1.0f scale guard with high-contrast focus stroke retention.
 *   <li>TvV17DetailScreen.formatEpisodeFileCaption / extractFilenameFromUrl literal '+' and %XX
 *       UTF-8 percent-decoding without URLDecoder.
 *   <li>Onboarding, FirstPlayGestureHint, Danmu default empty server / TV adaptive row clamp, and
 *       wiring invariants.
 * </ol>
 */
public final class Wave2AndroidWireChecks {
    private static int checks;

    private static void check(boolean condition, String message) {
        checks++;
        if (!condition) {
            throw new AssertionError("FAILED: " + message);
        }
    }

    private static void checkEq(int expected, int actual, String label) {
        check(expected == actual, label + " expected=" + expected + " actual=" + actual);
    }

    private static void checkEq(boolean expected, boolean actual, String label) {
        check(expected == actual, label + " expected=" + expected + " actual=" + actual);
    }

    private static void checkEq(String expected, String actual, String label) {
        check(
                expected != null && expected.equals(actual),
                label + " expected=[" + expected + "] actual=[" + actual + "]");
    }

    private static void checkClose(float expected, float actual, float eps, String label) {
        check(
                Math.abs(expected - actual) <= eps,
                label + " expected=" + expected + " actual=" + actual);
    }

    private static void testPlaybackControlsZOrder() {
        Context ctx = new Context();
        FrameLayout playbackLayer = new FrameLayout(ctx);

        // Mirror PlaybackController.playerPage + PlayerChrome mount sequence:
        // [0] Video surface, [1..N] HUD overlays.
        View videoSurface = new View(ctx);
        videoSurface.setTag("video-surface");
        View hudOverlay = new View(ctx);
        hudOverlay.setTag("player-hud-overlay");
        View loadingPill = new View(ctx);
        loadingPill.setTag("player-loading");
        View startSpecBanner = new View(ctx);
        startSpecBanner.setTag("player-start-spec");
        View slimProgress = new View(ctx);
        slimProgress.setTag("player-slim-progress");
        View hintSlot = new View(ctx);
        hintSlot.setTag("player-first-play-gesture-hint-slot");

        playbackLayer.addView(videoSurface, new FrameLayout.LayoutParams(-1, -1));
        playbackLayer.addView(hudOverlay, new FrameLayout.LayoutParams(-1, -1));
        playbackLayer.addView(loadingPill, new FrameLayout.LayoutParams(-2, -2));
        playbackLayer.addView(startSpecBanner, new FrameLayout.LayoutParams(-2, -2));
        playbackLayer.addView(slimProgress, new FrameLayout.LayoutParams(-1, 6));
        playbackLayer.addView(hintSlot, new FrameLayout.LayoutParams(-1, -1));

        View danmakuView = new View(ctx);
        danmakuView.setTag("danmaku-view");
        View subtitleView = new View(ctx);
        subtitleView.setTag("subtitle-overlay-view");

        PlaybackControls.mountMediaOverlaysInZOrder(
                playbackLayer,
                danmakuView,
                new FrameLayout.LayoutParams(-1, -1),
                subtitleView,
                new FrameLayout.LayoutParams(-1, -1));

        // Append trailing HUD pills just as PlaybackControls does after mounting overlays.
        View skipCountdownPill = new View(ctx);
        skipCountdownPill.setTag("skip-countdown-pill");
        View sleepWarningPill = new View(ctx);
        sleepWarningPill.setTag("sleep-warning-pill");
        playbackLayer.addView(skipCountdownPill, new FrameLayout.LayoutParams(-2, -2));
        playbackLayer.addView(sleepWarningPill, new FrameLayout.LayoutParams(-2, -2));

        int idxVideo = playbackLayer.indexOfChild(videoSurface);
        int idxDanmu = playbackLayer.indexOfChild(danmakuView);
        int idxSubtitle = playbackLayer.indexOfChild(subtitleView);
        int idxHud = playbackLayer.indexOfChild(hudOverlay);
        int idxLoading = playbackLayer.indexOfChild(loadingPill);
        int idxSpec = playbackLayer.indexOfChild(startSpecBanner);
        int idxSlim = playbackLayer.indexOfChild(slimProgress);
        int idxHint = playbackLayer.indexOfChild(hintSlot);
        int idxSkip = playbackLayer.indexOfChild(skipCountdownPill);
        int idxSleep = playbackLayer.indexOfChild(sleepWarningPill);

        checkEq(0, idxVideo, "zorder.video");
        checkEq(1, idxDanmu, "zorder.danmaku");
        checkEq(2, idxSubtitle, "zorder.subtitle");
        check(idxVideo < idxDanmu, "video below danmaku");
        check(idxDanmu < idxSubtitle, "danmaku strictly below subtitle");
        check(idxSubtitle < idxHud, "subtitle strictly below HUD overlay");
        check(idxSubtitle < idxLoading, "subtitle strictly below loading pill");
        check(idxSubtitle < idxSpec, "subtitle strictly below start spec banner");
        check(idxSubtitle < idxSlim, "subtitle strictly below slim progress");
        check(idxSubtitle < idxHint, "subtitle strictly below first-play hint slot");
        check(idxSubtitle < idxSkip, "subtitle strictly below skip countdown pill");
        check(idxSubtitle < idxSleep, "subtitle strictly below sleep warning pill");

        // Re-mounting already attached views must preserve exact Video -> Danmaku -> Subtitle ->
        // HUD order.
        PlaybackControls.mountMediaOverlaysInZOrder(
                playbackLayer,
                danmakuView,
                new FrameLayout.LayoutParams(-1, -1),
                subtitleView,
                new FrameLayout.LayoutParams(-1, -1));
        checkEq(0, playbackLayer.indexOfChild(videoSurface), "remount.zorder.video");
        checkEq(1, playbackLayer.indexOfChild(danmakuView), "remount.zorder.danmaku");
        checkEq(2, playbackLayer.indexOfChild(subtitleView), "remount.zorder.subtitle");
        checkEq(3, playbackLayer.indexOfChild(hudOverlay), "remount.zorder.hud");

        // Defensive Z-order check (#12): mounting subtitle alone when a DanmakuView child is
        // already attached at index 1 must place Subtitle strictly ABOVE DanmakuView (index 2).
        FrameLayout incrementalLayer = new FrameLayout(ctx);
        View incVideo = new View(ctx);
        View incDanmaku = new View(ctx);
        incDanmaku.setTag("danmaku-view");
        View incHud = new View(ctx);
        incrementalLayer.addView(incVideo, new FrameLayout.LayoutParams(-1, -1));
        incrementalLayer.addView(incDanmaku, new FrameLayout.LayoutParams(-1, -1));
        incrementalLayer.addView(incHud, new FrameLayout.LayoutParams(-1, -1));
        View incSubtitle = new View(ctx);
        PlaybackControls.mountMediaOverlaysInZOrder(
                incrementalLayer, null, null, incSubtitle, new FrameLayout.LayoutParams(-1, -1));
        checkEq(0, incrementalLayer.indexOfChild(incVideo), "incremental.zorder.video");
        checkEq(1, incrementalLayer.indexOfChild(incDanmaku), "incremental.zorder.danmaku");
        checkEq(2, incrementalLayer.indexOfChild(incSubtitle), "incremental.zorder.subtitle");
        checkEq(3, incrementalLayer.indexOfChild(incHud), "incremental.zorder.hud");

        // Defensive Z-order check: inverted [Video, Subtitle, Danmaku, HUD] restored cleanly.
        FrameLayout invertedLayer = new FrameLayout(ctx);
        View invVideo = new View(ctx);
        View invSubtitle = new View(ctx);
        View invDanmaku = new View(ctx);
        invDanmaku.setTag("danmaku-view");
        View invHud = new View(ctx);
        invertedLayer.addView(invVideo, new FrameLayout.LayoutParams(-1, -1));
        invertedLayer.addView(invSubtitle, new FrameLayout.LayoutParams(-1, -1));
        invertedLayer.addView(invDanmaku, new FrameLayout.LayoutParams(-1, -1));
        invertedLayer.addView(invHud, new FrameLayout.LayoutParams(-1, -1));
        PlaybackControls.mountMediaOverlaysInZOrder(
                invertedLayer,
                invDanmaku,
                new FrameLayout.LayoutParams(-1, -1),
                invSubtitle,
                new FrameLayout.LayoutParams(-1, -1));
        checkEq(0, invertedLayer.indexOfChild(invVideo), "inverted.zorder.video");
        checkEq(1, invertedLayer.indexOfChild(invDanmaku), "inverted.zorder.danmaku");
        checkEq(2, invertedLayer.indexOfChild(invSubtitle), "inverted.zorder.subtitle");
        checkEq(3, invertedLayer.indexOfChild(invHud), "inverted.zorder.hud");
    }

    private static void testApi23GlassFreezeLifecycle() {
        // 1. Unit check GlassFreezeController ref-counting & GlassworkSurface option gate.
        AtomicInteger unfreezeEvents = new AtomicInteger();
        MainActivity.GlassFreezeController controller =
                new MainActivity.GlassFreezeController(unfreezeEvents::incrementAndGet);
        checkEq(false, controller.isFrozen(), "glass.initial.unfrozen");
        checkEq(false, controller.shouldReduceTransparency(false), "glass.gate.normal");
        checkEq(true, controller.shouldReduceTransparency(true), "glass.gate.userReduced");

        controller.setGlassFrozen(true);
        checkEq(true, controller.isFrozen(), "glass.frozen.afterTrue");
        checkEq(true, controller.shouldReduceTransparency(false), "glass.gate.frozenBlocksBlur");
        checkEq(0, unfreezeEvents.get(), "glass.unfreezeCount.whileFrozen");

        // Nested freeze stays frozen until matching unfreeze.
        controller.setGlassFrozen(true);
        controller.setGlassFrozen(false);
        checkEq(true, controller.isFrozen(), "glass.nested.stillFrozen");
        checkEq(0, unfreezeEvents.get(), "glass.nested.noEarlyUnfreeze");

        controller.setGlassFrozen(false);
        checkEq(false, controller.isFrozen(), "glass.nested.unfrozen");
        checkEq(1, unfreezeEvents.get(), "glass.nested.unfreezeCallbackOnce");
        checkEq(false, controller.shouldReduceTransparency(false), "glass.gate.restored");

        // Redundant unfreeze must remain a safe no-op.
        controller.setGlassFrozen(false);
        checkEq(false, controller.isFrozen(), "glass.extraUnfreeze.safe");
        checkEq(1, unfreezeEvents.get(), "glass.extraUnfreeze.noDoubleCallback");

        // forceUnfreeze clears arbitrary depth once.
        controller.setGlassFrozen(true);
        controller.setGlassFrozen(true);
        controller.forceUnfreeze();
        checkEq(false, controller.isFrozen(), "glass.forceUnfreeze.cleared");
        checkEq(2, unfreezeEvents.get(), "glass.forceUnfreeze.callback");

        // 2. Real PlayerTransitionHelper API 23-32 RenderNode transition: normal end.
        Context ctx = new Context();
        View detailLayer = new View(ctx);
        View posterView = new View(ctx);
        AtomicInteger completeEnd = new AtomicInteger();
        AtomicInteger unfreezeEnd = new AtomicInteger();
        MainActivity.GlassFreezeController freezeEnd =
                new MainActivity.GlassFreezeController(unfreezeEnd::incrementAndGet);

        ValueAnimator.clearLastStarted();
        PlayerTransitionHelper.TransitionHandle handleEnd =
                PlayerTransitionHelper.runApi23HardwareRenderNodeTransition(
                        detailLayer, posterView, freezeEnd, completeEnd::incrementAndGet);
        ValueAnimator animEnd = ValueAnimator.getLastStarted();
        check(animEnd != null, "api23.end.animatorStarted");
        checkEq(MotionTokens.DURATION_EMPHASIZED_MS, (int) animEnd.getDuration(), "api23.duration");
        checkEq(true, freezeEnd.isFrozen(), "api23.end.frozenDuringTransition");
        checkEq(View.LAYER_TYPE_HARDWARE, detailLayer.getLayerType(), "api23.end.hwLayerDetail");
        checkEq(View.LAYER_TYPE_HARDWARE, posterView.getLayerType(), "api23.end.hwLayerPoster");

        animEnd.stepTo(0.5f);
        checkClose(0.96f, detailLayer.getScaleX(), 1e-4f, "api23.mid.detailScale");
        checkClose(0.5f, detailLayer.getAlpha(), 1e-4f, "api23.mid.detailAlpha");
        checkClose(1.05f, posterView.getScaleX(), 1e-4f, "api23.mid.posterScale");
        checkEq(true, freezeEnd.isFrozen(), "api23.mid.stillFrozen");

        animEnd.finish();
        checkEq(1, completeEnd.get(), "api23.end.onCompleteOnce");
        checkEq(false, freezeEnd.isFrozen(), "api23.end.unfrozen");
        checkEq(1, unfreezeEnd.get(), "api23.end.unfreezeCallbackOnce");
        checkClose(1f, detailLayer.getScaleX(), 1e-4f, "api23.end.detailScaleRestored");
        checkClose(1f, detailLayer.getAlpha(), 1e-4f, "api23.end.detailAlphaRestored");
        checkClose(0f, detailLayer.getTranslationY(), 1e-4f, "api23.end.detailTransRestored");
        checkEq(View.LAYER_TYPE_NONE, detailLayer.getLayerType(), "api23.end.detailLayerRestored");
        checkClose(1f, posterView.getScaleX(), 1e-4f, "api23.end.posterScaleRestored");
        checkClose(1f, posterView.getAlpha(), 1e-4f, "api23.end.posterAlphaRestored");
        checkEq(View.LAYER_TYPE_NONE, posterView.getLayerType(), "api23.end.posterLayerRestored");
        checkEq(0, detailLayer.getAttachListenerCount(), "api23.end.detachListenerRemoved");
        handleEnd.cancel(); // idempotent post-end cancel
        checkEq(1, unfreezeEnd.get(), "api23.end.postCancelNoDoubleUnfreeze");

        // 3. Real PlayerTransitionHelper API 23-32 RenderNode transition: explicit cancel.
        AtomicInteger completeCancel = new AtomicInteger();
        AtomicInteger unfreezeCancel = new AtomicInteger();
        MainActivity.GlassFreezeController freezeCancel =
                new MainActivity.GlassFreezeController(unfreezeCancel::incrementAndGet);
        View detailCancel = new View(ctx);
        View posterCancel = new View(ctx);

        ValueAnimator.clearLastStarted();
        PlayerTransitionHelper.TransitionHandle handleCancel =
                PlayerTransitionHelper.runApi23HardwareRenderNodeTransition(
                        detailCancel, posterCancel, freezeCancel, completeCancel::incrementAndGet);
        ValueAnimator animCancel = ValueAnimator.getLastStarted();
        animCancel.stepTo(0.35f);
        checkEq(true, freezeCancel.isFrozen(), "api23.cancel.frozenBeforeCancel");
        handleCancel.cancel();
        checkEq(1, completeCancel.get(), "api23.cancel.onCompleteOnce");
        checkEq(false, freezeCancel.isFrozen(), "api23.cancel.unfrozen");
        checkEq(1, unfreezeCancel.get(), "api23.cancel.unfreezeCallbackOnce");
        checkClose(1f, detailCancel.getAlpha(), 1e-4f, "api23.cancel.alphaRestored");
        checkClose(1f, detailCancel.getScaleX(), 1e-4f, "api23.cancel.scaleRestored");
        checkEq(0, detailCancel.getAttachListenerCount(), "api23.cancel.detachListenerRemoved");

        // 4. Real PlayerTransitionHelper API 23-32 RenderNode transition: view detach mid-flight.
        AtomicInteger completeDetach = new AtomicInteger();
        AtomicInteger unfreezeDetach = new AtomicInteger();
        MainActivity.GlassFreezeController freezeDetach =
                new MainActivity.GlassFreezeController(unfreezeDetach::incrementAndGet);
        View detailDetach = new View(ctx);
        View posterDetach = new View(ctx);

        ValueAnimator.clearLastStarted();
        PlayerTransitionHelper.runApi23HardwareRenderNodeTransition(
                detailDetach, posterDetach, freezeDetach, completeDetach::incrementAndGet);
        ValueAnimator animDetach = ValueAnimator.getLastStarted();
        animDetach.stepTo(0.25f);
        checkEq(true, freezeDetach.isFrozen(), "api23.detach.frozenBeforeDetach");
        checkEq(1, detailDetach.getAttachListenerCount(), "api23.detach.listenerAttached");
        detailDetach.dispatchDetachedFromWindow();
        checkEq(1, completeDetach.get(), "api23.detach.onCompleteOnce");
        checkEq(false, freezeDetach.isFrozen(), "api23.detach.unfrozen");
        checkEq(1, unfreezeDetach.get(), "api23.detach.unfreezeCallbackOnce");
        checkClose(1f, detailDetach.getAlpha(), 1e-4f, "api23.detach.alphaRestored");
        checkClose(1f, posterDetach.getScaleX(), 1e-4f, "api23.detach.posterScaleRestored");
        checkEq(0, detailDetach.getAttachListenerCount(), "api23.detach.listenerRemoved");
    }

    private static void testFocusMotionReducedGuard() {
        // Reduced motion MUST clamp scale to strictly 1.0f regardless of gain, emphasis, or press.
        checkClose(
                1.0f,
                FocusMotion.resolveScale(1.06f, 1.0f, 0.0f, true),
                1e-6f,
                "focus.reduced.focused");
        checkClose(
                1.0f,
                FocusMotion.resolveScale(1.08f, 1.0f, 1.0f, true),
                1e-6f,
                "focus.reduced.pressed");
        checkClose(
                1.0f,
                FocusMotion.resolveScale(1.05f, 0.0f, 0.0f, true),
                1e-6f,
                "focus.reduced.idle");

        // Normal motion scales smoothly by gain and press compression.
        checkClose(
                1.06f,
                FocusMotion.resolveScale(1.06f, 1.0f, 0.0f, false),
                1e-5f,
                "focus.normal.focused");
        checkClose(
                1.06f * 0.97f,
                FocusMotion.resolveScale(1.06f, 1.0f, 1.0f, false),
                1e-5f,
                "focus.normal.pressed");
        checkClose(
                1.0f,
                FocusMotion.resolveScale(1.06f, 0.0f, 0.0f, false),
                1e-5f,
                "focus.normal.idle");

        // High-contrast focus stroke MUST remain visible under Prefs.REDUCED even when
        // border=false.
        checkEq(
                MotionTokens.TV_FOCUS_STROKE_ARGB,
                FocusMotion.resolveStrokeColor(false, 1.0f, true),
                "focus.reduced.strokeKeptEvenWithoutBorder");
        checkEq(
                MotionTokens.TV_FOCUS_STROKE_ARGB,
                FocusMotion.resolveStrokeColor(true, 0.8f, true),
                "focus.reduced.strokeKeptWithBorder");
        checkEq(
                0x00f5f5f7,
                FocusMotion.resolveStrokeColor(true, 0.0f, true),
                "focus.reduced.unfocusedTransparent");
        checkEq(
                0x00f5f5f7,
                FocusMotion.resolveStrokeColor(false, 1.0f, false),
                "focus.normal.noBorderStaysTransparent");
        checkEq(
                MotionTokens.TV_FOCUS_STROKE_ARGB,
                FocusMotion.resolveStrokeColor(true, 1.0f, false),
                "focus.normal.borderHighlighted");
    }

    private static void testTvV17EpisodeFileCaptionDecoding() {
        // Direct filename extraction tests covering literal '+', %2B, HDR10+, DD+, UTF-8, malformed
        // %ZZ/%2.
        checkEq(
                "Film.2025.2160p.HDR10+.DD+.5.1.mkv",
                TvV17DetailScreen.extractFilenameFromUrl(
                        "https://media.test/videos/Film.2025.2160p.HDR10+.DD+.5.1.mkv"),
                "caption.literalPlus.HDR10+_DD+");
        checkEq(
                "Film.HDR10+.DD+.Atmos.mkv",
                TvV17DetailScreen.extractFilenameFromUrl(
                        "https://media.test/videos/Film.HDR10%2B.DD%2B.Atmos.mkv"),
                "caption.percent2B");
        checkEq(
                "Film.HDR10+.DD+.Atmos.mp4",
                TvV17DetailScreen.extractFilenameFromUrl(
                        "https://media.test/videos/Film.HDR10+.DD%2B.Atmos.mp4?token=a+b#t=5"),
                "caption.mixedPlusAndQuery");
        checkEq(
                "中文.2160p.HDR10+.DD+.mkv",
                TvV17DetailScreen.extractFilenameFromUrl(
                        "https://media.test/v/%E4%B8%AD%E6%96%87.2160p.HDR10+.DD+.mkv"),
                "caption.utf8ChineseAndPlus");
        checkEq(
                "Clip.%ZZ.HDR10+.mp4",
                TvV17DetailScreen.extractFilenameFromUrl(
                        "https://media.test/v/Clip.%ZZ.HDR10+.mp4"),
                "caption.malformedPercentZZ");
        checkEq(
                "Clip.DD+.%2.mkv",
                TvV17DetailScreen.extractFilenameFromUrl("https://media.test/v/Clip.DD+.%2.mkv"),
                "caption.malformedPercent2");
        checkEq(
                "",
                TvV17DetailScreen.extractFilenameFromUrl("https://media.test/v/Clip.mp4%2"),
                "caption.trailingIncompletePercentSafe");
        checkEq(
                "",
                TvV17DetailScreen.extractFilenameFromUrl("https://media.test/hls/index.m3u8"),
                "caption.genericManifestIgnored");
        checkEq(
                "",
                TvV17DetailScreen.extractFilenameFromUrl(
                        "https://media.test/v/0123456789abcdef1234.mp4"),
                "caption.hexHashIgnored");

        // Minor 3 (#11 & #14): Pathless URLs carrying '/' in query or fragment must NOT extract
        // fake filenames.
        String pathlessHost = "https://host.example";
        checkEq(
                "",
                TvV17DetailScreen.extractRawHttpPath(pathlessHost + "?file=/a/b.mkv"),
                "caption.pathlessQuerySlash.rawPathEmpty");
        checkEq(
                "",
                TvV17DetailScreen.extractFilenameFromUrl(pathlessHost + "?file=/a/b.mkv"),
                "caption.pathlessQuerySlash.ignored");
        checkEq(
                "",
                TvV17DetailScreen.extractFilenameFromUrl(pathlessHost + "#x/b.mkv"),
                "caption.pathlessFragmentSlash.ignored");
        checkEq(
                "",
                TvV17DetailScreen.extractFilenameFromUrl(
                        pathlessHost + "?redirect=/clip.HDR10+.mp4"),
                "caption.pathlessQueryRedirect.ignored");
        checkEq(
                "Film.HDR10+.mkv",
                TvV17DetailScreen.extractFilenameFromUrl(
                        "https://host.example/v/Film.HDR10+.mkv?redirect=/other.mp4#frag/foo.mkv"),
                "caption.realPathWithQueryAndFragmentSlashes");

        // Full formatEpisodeFileCaption integration test.
        Cms.Line line = new Cms.Line();
        line.name = "原画线路";
        Cms.Episode ep = new Cms.Episode();
        ep.name = "正片";
        ep.url =
                "https://media.example/lib/%E4%B8%AD%E6%96%87.2160p.HDR10+.DD%2B.Atmos.mkv?sig=1+2";
        checkEq(
                "原画线路  ·  正片 · 中文.2160p.HDR10+.DD+.Atmos.mkv",
                TvV17DetailScreen.formatEpisodeFileCaption(line, ep),
                "formatEpisodeFileCaption.full");

        Cms.Episode malformedEp = new Cms.Episode();
        malformedEp.name = "HD";
        malformedEp.url = "https://media.example/lib/Movie.%ZZ.%2.HDR10+.mp4";
        checkEq(
                "原画线路  ·  HD · Movie.%ZZ.%2.HDR10+.mp4",
                TvV17DetailScreen.formatEpisodeFileCaption(line, malformedEp),
                "formatEpisodeFileCaption.malformedPercentPreserved");
    }

    private static void testOnboardingFirstPlayAndDanmuPolicies() {
        // 1. Onboarding first launch & settings replay flow.
        OnboardingScreen.MemoryStore store = new OnboardingScreen.MemoryStore();
        checkEq(
                true,
                OnboardingScreen.Controller.shouldShowOnLaunch(store),
                "onboarding.firstLaunchShows");
        OnboardingScreen.Controller ob = new OnboardingScreen.Controller(store);
        ob.complete(false);
        checkEq(
                false,
                OnboardingScreen.Controller.shouldShowOnLaunch(store),
                "onboarding.completedHidesOnNextLaunch");

        // 2. FirstPlayGestureHint 3-show cap + dismiss forever + replay reset.
        checkEq(true, FirstPlayGestureHint.Policy.shouldShow(store), "hint.show1");
        FirstPlayGestureHint.Policy.recordShown(store);
        checkEq(true, FirstPlayGestureHint.Policy.shouldShow(store), "hint.show2");
        FirstPlayGestureHint.Policy.recordShown(store);
        checkEq(true, FirstPlayGestureHint.Policy.shouldShow(store), "hint.show3");
        FirstPlayGestureHint.Policy.recordShown(store);
        checkEq(false, FirstPlayGestureHint.Policy.shouldShow(store), "hint.suppressedAfter3");

        OnboardingScreen.Controller.resetForReplay(store);
        checkEq(
                true,
                OnboardingScreen.Controller.shouldShowOnLaunch(store),
                "onboarding.replayResetsLaunchFlag");
        checkEq(
                true,
                FirstPlayGestureHint.Policy.shouldShow(store),
                "onboarding.replayResetsGestureHint");

        FirstPlayGestureHint.Policy.dismissForever(store);
        checkEq(
                false,
                FirstPlayGestureHint.Policy.shouldShow(store),
                "hint.dismissForeverSuppressesImmediately");

        // 3. Danmu defaults & TV ARM32 P90 adaptive row downgrade (2..8 rows).
        DanmuSettingsPanel.DanmuConfig mobileDef = DanmuSettingsPanel.DanmuConfig.defaults(false);
        DanmuSettingsPanel.DanmuConfig tvDef = DanmuSettingsPanel.DanmuConfig.defaults(true);
        checkEq("", mobileDef.serverUrls, "danmu.mobile.defaultServerEmpty");
        checkEq("", tvDef.serverUrls, "danmu.tv.defaultServerEmpty");
        checkEq(false, mobileDef.enabled, "danmu.mobile.defaultDisabled");
        checkEq(false, tvDef.enabled, "danmu.tv.defaultDisabled");
        checkEq(
                true,
                mobileDef.createProvider().getConfiguredOrigins().isEmpty(),
                "danmu.mobile.noOrigins");
        checkEq(
                true,
                tvDef.createProvider().getConfiguredOrigins().isEmpty(),
                "danmu.tv.noOrigins");
        checkEq(2, DanmuSettingsPanel.clampMaxRows(1, true), "danmu.tv.minRows2");
        checkEq(8, DanmuSettingsPanel.clampMaxRows(14, true), "danmu.tv.maxRows8");
        checkEq(14, DanmuSettingsPanel.clampMaxRows(20, false), "danmu.mobile.maxRows14");

        DanmuSegmentCache.FramePacingMonitor pacing = new DanmuSegmentCache.FramePacingMonitor();
        pacing.setCeilingRows(8);
        for (int i = 0; i < 60; i++) {
            pacing.recordFrameIntervalMs(28.0); // heavy jank triggers downgrade
        }
        int downgraded = pacing.getEffectiveMaxRows();
        check(downgraded >= 2 && downgraded < 8, "danmu.tv.p90DowngradedWithin2To8=" + downgraded);

        // 4. Gate 2 Review Fix Regressions (Majors 1-3 + Minors 1-2).
        // Major 1: TV Onboarding must NOT post container requestFocus over OnboardingScreen's
        // nextButton focus.
        checkEq(
                false,
                MainActivity.shouldPostOnboardingContainerFocus(true),
                "onboarding.tv.noContainerFocusSteal");
        checkEq(
                true,
                MainActivity.shouldPostOnboardingContainerFocus(false),
                "onboarding.mobile.postsContainerFocus");

        // Major 2: Act 5 "立即导入配置" after UI scale change must cancel deferred recreate() so
        // importDialog() stays open without WindowLeaked.
        final AtomicInteger recreateCalls = new AtomicInteger();
        final AtomicInteger restoreCalls = new AtomicInteger();
        final Runnable[] queuedRecreate = new Runnable[1];
        MainActivity.OnboardingFinishCoordinator importCoord =
                new MainActivity.OnboardingFinishCoordinator(100);
        checkEq(
                true,
                importCoord.onFinished(
                        120,
                        () ->
                                queuedRecreate[0] =
                                        () ->
                                                importCoord.runDeferredRecreateIfStillNeeded(
                                                        true, recreateCalls::incrementAndGet),
                        restoreCalls::incrementAndGet),
                "onboarding.act5ImportAfterScale.schedulesDeferredRecreate");
        checkEq(
                true,
                importCoord.beginFollowUpAction(true),
                "onboarding.act5ImportAfterScale.allowsImportDialog");
        check(queuedRecreate[0] != null, "onboarding.act5ImportAfterScale.deferredTaskPosted");
        queuedRecreate[0].run();
        checkEq(0, recreateCalls.get(), "onboarding.act5ImportAfterScale.recreateCancelled");
        checkEq(0, restoreCalls.get(), "onboarding.act5ImportAfterScale.noSpuriousRestore");

        // Act 5 finish/skip WITHOUT follow-up import after scale change MUST execute recreate().
        final AtomicInteger finishRecreateCalls = new AtomicInteger();
        final Runnable[] queuedFinishRecreate = new Runnable[1];
        MainActivity.OnboardingFinishCoordinator finishCoord =
                new MainActivity.OnboardingFinishCoordinator(100);
        finishCoord.onFinished(
                110,
                () ->
                        queuedFinishRecreate[0] =
                                () ->
                                        finishCoord.runDeferredRecreateIfStillNeeded(
                                                true, finishRecreateCalls::incrementAndGet),
                restoreCalls::incrementAndGet);
        checkEq(true, finishCoord.isRecreateScheduled(), "onboarding.finishScale.scheduled");
        queuedFinishRecreate[0].run();
        checkEq(1, finishRecreateCalls.get(), "onboarding.finishScale.recreatedOnce");
        checkEq(true, finishCoord.isRecreateExecuted(), "onboarding.finishScale.markedExecuted");
        checkEq(
                false,
                finishCoord.beginFollowUpAction(true),
                "onboarding.postRecreate.blocksFollowUpDialog");

        // Unchanged scale restores focus directly with zero recreate.
        final AtomicInteger unchangedRestore = new AtomicInteger();
        MainActivity.OnboardingFinishCoordinator unchangedCoord =
                new MainActivity.OnboardingFinishCoordinator(100);
        checkEq(
                false,
                unchangedCoord.onFinished(100, () -> {}, unchangedRestore::incrementAndGet),
                "onboarding.unchangedScale.noRecreate");
        checkEq(1, unchangedRestore.get(), "onboarding.unchangedScale.restoresFocus");

        // Major 3: Detached DanmuSegmentCache detection prevents 4-thread pool & tick leak.
        checkEq(
                true,
                PlaybackControls.shouldCloseDetachedSegmentCache(true, false),
                "danmu.detachedCache.triggersClose");
        checkEq(
                false,
                PlaybackControls.shouldCloseDetachedSegmentCache(true, true),
                "danmu.attachedCache.staysOpen");
        checkEq(
                false,
                PlaybackControls.shouldCloseDetachedSegmentCache(false, false),
                "danmu.noCache.noop");

        // Minor 1: Appearance tweak in DanmuSettingsPanel must NOT overwrite loaded source/local
        // danmaku when server signature is unchanged.
        String savedUrl = "https://danmu.example";
        String changedUrl = "https://danmu2.example";
        String savedSig = savedUrl + "||";
        String changedSig = changedUrl + "||";
        checkEq(
                false,
                PlaybackControls.shouldStartSegmentedSessionOnConfigUpdate(
                        true, savedUrl, false, true, savedSig, savedSig),
                "danmu.appearanceTweak.preservesLoadedLegacyDanmaku");
        checkEq(
                true,
                PlaybackControls.shouldStartSegmentedSessionOnConfigUpdate(
                        true, changedUrl, false, true, savedSig, changedSig),
                "danmu.serverChange.startsNewSegmentedSession");
        checkEq(
                true,
                PlaybackControls.shouldStartSegmentedSessionOnConfigUpdate(
                        true, savedUrl, false, false, savedSig, savedSig),
                "danmu.noLegacyLoaded.startsSegmentedSession");
        checkEq(
                false,
                PlaybackControls.shouldStartSegmentedSessionOnConfigUpdate(
                        false, savedUrl, false, false, "", savedSig),
                "danmu.disabled.neverStartsSession");
        checkEq(
                false,
                PlaybackControls.shouldStartSegmentedSessionOnConfigUpdate(
                        true, "", false, false, "", ""),
                "danmu.emptyServer.neverStartsSession");

        // Minor 2: Async match completion checks latest config (rejects if disabled or server
        // changed while match was in flight; accepts appearance tweaks so latestCfg applies).
        DanmuSettingsPanel.DanmuConfig reqCfg =
                new DanmuSettingsPanel.DanmuConfig(
                        true,
                        "https://danmu.example",
                        "",
                        "",
                        0.85f,
                        0.50f,
                        20f,
                        1.0f,
                        0L,
                        true,
                        true,
                        true,
                        10,
                        java.util.Collections.emptyList(),
                        false);
        DanmuSettingsPanel.DanmuConfig tweakedCfg =
                new DanmuSettingsPanel.DanmuConfig(
                        true,
                        "https://danmu.example",
                        "",
                        "",
                        0.50f,
                        0.75f,
                        24f,
                        1.25f,
                        500L,
                        true,
                        false,
                        true,
                        8,
                        java.util.Collections.emptyList(),
                        false);
        DanmuSettingsPanel.DanmuConfig disabledCfg =
                new DanmuSettingsPanel.DanmuConfig(
                        false,
                        "https://danmu.example",
                        "",
                        "",
                        0.85f,
                        0.50f,
                        20f,
                        1.0f,
                        0L,
                        true,
                        true,
                        true,
                        10,
                        java.util.Collections.emptyList(),
                        false);
        DanmuSettingsPanel.DanmuConfig switchedServerCfg =
                new DanmuSettingsPanel.DanmuConfig(
                        true,
                        "https://danmu2.example",
                        "",
                        "",
                        0.85f,
                        0.50f,
                        20f,
                        1.0f,
                        0L,
                        true,
                        true,
                        true,
                        10,
                        java.util.Collections.emptyList(),
                        false);
        checkEq(
                true,
                PlaybackControls.shouldApplyAsyncMatchResult(reqCfg, tweakedCfg),
                "danmu.asyncMatch.acceptsLatestAppearanceEdits");
        checkEq(
                false,
                PlaybackControls.shouldApplyAsyncMatchResult(reqCfg, disabledCfg),
                "danmu.asyncMatch.abortsIfDisabledInFlight");
        checkEq(
                false,
                PlaybackControls.shouldApplyAsyncMatchResult(reqCfg, switchedServerCfg),
                "danmu.asyncMatch.abortsIfServerChangedInFlight");
    }

    private static String readUtf8(Path path) throws Exception {
        return new String(Files.readAllBytes(path), StandardCharsets.UTF_8);
    }

    private static void testSourceWiringInvariants(Path root) throws Exception {
        Path src = root.resolve("android/src/main/java/com/pilipala/marcomovie");

        // Prefs.KEYS length must remain strictly 46.
        checkEq(46, Prefs.KEYS.length, "prefs.keys.length46");

        // TvV17DetailScreen must not use URLDecoder.decode.
        String tvDetail = readUtf8(src.resolve("TvV17DetailScreen.java"));
        check(!tvDetail.contains("URLDecoder.decode"), "tvDetail.noUrlDecoder");
        check(
                tvDetail.contains("MediaBadges.percentDecodeUtf8PreservePlus"),
                "tvDetail.usesPercentDecodePreservePlus");

        // PlaybackControls wiring: Z-order helper, DanmuSegmentCache, DanmuSettingsPanel,
        // FirstPlayGestureHint, NO Aurora.
        String playbackControls = readUtf8(src.resolve("PlaybackControls.java"));
        check(
                playbackControls.contains("mountMediaOverlaysInZOrder("),
                "playbackControls.usesZOrderHelper");
        check(
                playbackControls.contains("DanmuSegmentCache"),
                "playbackControls.wiresDanmuSegmentCache");
        check(
                playbackControls.contains("DanmuSettingsPanel.showDialog("),
                "playbackControls.wiresDanmuSettingsPanel");
        check(
                playbackControls.contains("FirstPlayGestureHint"),
                "playbackControls.wiresFirstPlayGestureHint");
        check(
                playbackControls.contains("setSubtitleBottomClearanceDp("),
                "playbackControls.syncsSubtitleClearance");
        check(
                !playbackControls.contains("AuroraSurfaceView"),
                "playbackControls.neverMountsAurora");
        check(
                playbackControls.contains("loadLocalDanmakuText(")
                        && playbackControls.contains("reconcileDetachedSegmentedDanmuSession()"),
                "playbackControls.closesSegmentedSessionOnLocalAndExternalLoad");
        check(
                playbackControls.contains("shouldApplyAsyncMatchResult(")
                        && playbackControls.contains("danmaku.applyConfig(latestCfg)"),
                "playbackControls.appliesLatestConfigAfterAsyncMatch");
        check(
                playbackControls.contains("shouldStartSegmentedSessionOnConfigUpdate("),
                "playbackControls.guardsAppearanceTweakAgainstLegacyOverwrite");

        String sourceController = readUtf8(src.resolve("SourceController.java"));
        check(
                sourceController.contains("controls.loadLocalDanmakuText(text)"),
                "sourceController.delegatesLocalDanmakuThroughControls");

        // PlayerChrome & PlaybackLoading wiring: BrandLogoLoaderView, NO Aurora.
        String playerChrome = readUtf8(src.resolve("PlayerChrome.java"));
        check(
                playerChrome.contains("new BrandLogoLoaderView("),
                "playerChrome.mountsBrandLogoLoader");
        check(
                playerChrome.contains("brandLoader.setActive(showSpinner)"),
                "playerChrome.syncsBrandLoaderActive");
        check(
                playerChrome.contains("syncDanmuPlaybackState()"),
                "playerChrome.syncsDanmuPlaybackState");
        check(!playerChrome.contains("AuroraSurfaceView"), "playerChrome.neverMountsAurora");

        String playbackLoading = readUtf8(src.resolve("PlaybackLoading.java"));
        check(
                playbackLoading.contains("new BrandLogoLoaderView("),
                "playbackLoading.mountsBrandLogoLoader");

        // Settings entries in both TV/Legacy SettingsScreen and MobileIosSettings.
        String settingsScreen = readUtf8(src.resolve("SettingsScreen.java"));
        check(
                settingsScreen.contains("DanmuSettingsPanel.showDialog("),
                "settingsScreen.wiresDanmuPanel");
        check(
                settingsScreen.contains("a.isFinishing()")
                        && settingsScreen.contains("a.isDestroyed()"),
                "settingsScreen.guardsDanmuDismissListener");
        check(
                settingsScreen.contains("重新查看新手引导")
                        && settingsScreen.contains("OnboardingScreen.resetForReplay("),
                "settingsScreen.wiresReplayOnboarding");

        String mobileSettings = readUtf8(src.resolve("MobileIosSettings.java"));
        check(
                mobileSettings.contains("DanmuSettingsPanel.showDialog("),
                "mobileSettings.wiresDanmuPanel");
        check(
                mobileSettings.contains("a.isFinishing()")
                        && mobileSettings.contains("a.isDestroyed()"),
                "mobileSettings.guardsDanmuDismissListener");
        check(
                mobileSettings.contains("重新查看新手引导")
                        && mobileSettings.contains("OnboardingScreen.resetForReplay("),
                "mobileSettings.wiresReplayOnboarding");
        check(
                mobileSettings.contains("new AuroraSurfaceView("),
                "mobileSettings.wiresAuroraInAbout");

        // MainActivity wiring: Onboarding, GlassFreezeController, graded transitions, TV page fade,
        // mobile-only Aurora.
        String mainActivity = readUtf8(src.resolve("MainActivity.java"));
        check(mainActivity.contains("GlassFreezeController"), "mainActivity.hasGlassFreeze");
        check(
                mainActivity.contains("FOCUS_AFTER_DESCENDANTS")
                        && mainActivity.contains("shouldPostOnboardingContainerFocus("),
                "mainActivity.preservesTvOnboardingInitialFocus");
        check(
                mainActivity.contains("OnboardingFinishCoordinator"),
                "mainActivity.coordinatesOnboardingScaleRecreateAndImport");
        check(
                mainActivity.contains("PlayerTransitionHelper.startDetailToPlayerTransition("),
                "mainActivity.wiresDetailToPlayerTransition");
        check(
                mainActivity.contains("PlayerTransitionHelper.animateTvPageFade("),
                "mainActivity.wiresTvDetailFade");
        check(
                mainActivity.contains("OnboardingScreen.shouldShow("),
                "mainActivity.wiresFirstLaunchOnboarding");
        check(
                mainActivity.contains("activeOnboarding.handleBackPressed()"),
                "mainActivity.routesBackToOnboarding");
        check(
                mainActivity.contains("prefs.getString(\"origin\", \"\")"),
                "mainActivity.preservesEmptyOriginDefault");
    }

    public static void main(String[] args) throws Exception {
        Path root = args.length > 0 ? Paths.get(args[0]) : Paths.get(".");
        testPlaybackControlsZOrder();
        testApi23GlassFreezeLifecycle();
        testFocusMotionReducedGuard();
        testTvV17EpisodeFileCaptionDecoding();
        testOnboardingFirstPlayAndDanmuPolicies();
        testSourceWiringInvariants(root);
        System.out.println("Wave2AndroidWireChecks OK (" + checks + " checks passed)");
    }
}
