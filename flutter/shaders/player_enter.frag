// Copyright (C) 2026 Pilipala
// SPDX-License-Identifier: GPL-3.0-only
//
// Cinema Portal detail-to-player transition shader (clean-room rectangular viewport).
// Coordinate contract: FlutterFragCoord().xy and all pixel/rect uniforms are in
// CustomPainter logical pixels (lp); never pre-multiply by devicePixelRatio.
// Output contract: strictly premultiplied RGBA (rgb * alpha, alpha).
#include <flutter/runtime_effect.glsl>

// Float slots 0..14 (15 floats total)
uniform vec2 uViewport;        // 0..1: canvas logical size (width, height)
uniform float uProgress;       // 2: normalized progress [0.0, 1.0] (enter 0->1, exit 1->0)
uniform float uRecedeTilt;     // 3: perspective tilt 0.10 * sin(pi * uProgress)
uniform vec4 uPosterOrigin;    // 4..7: poster rect (left, top, width, height) in lp
uniform vec4 uSafePadding;     // 8..11: safe-area insets (left, top, right, bottom) in lp
uniform float uPosterRadius;   // 12: initial poster corner radius in lp
uniform float uPosterAvailable;// 13: 1.0 when poster texture is ready, 0.0 for placeholder
uniform float uPosterAspect;   // 14: source poster width / max(height, 1.0)

// Sampler slots 0..1 (2 samplers total)
uniform sampler2D uBackdropTex; // 0: downsampled detail RepaintBoundary capture
uniform sampler2D uPosterTex;   // 1: poster texture (or 1x1 transparent singleton)

out vec4 fragColor;

vec4 sampleBackdrop(vec2 normUv) {
    vec2 uv = clamp(normUv, vec2(0.0), vec2(1.0));
#ifdef IMPELLER_TARGET_OPENGLES
    uv.y = 1.0 - uv.y;
#endif
    return texture(uBackdropTex, uv);
}

vec4 samplePoster(vec2 normUv) {
    vec2 uv = clamp(normUv, vec2(0.0), vec2(1.0));
#ifdef IMPELLER_TARGET_OPENGLES
    uv.y = 1.0 - uv.y;
#endif
    return texture(uPosterTex, uv);
}

void main() {
    vec2 viewport = max(uViewport, vec2(1.0));
    vec2 fragCoord = FlutterFragCoord().xy;
    vec2 p = fragCoord / viewport;
    float progress = clamp(uProgress, 0.0, 1.0);

    // 1) Detail page subtle perspective recede & cinema vignette darkening to #000000.
    float scaleBg = mix(1.0, 0.91, smoothstep(0.0, 0.85, progress));
    float perspDenom = max(0.35, 1.0 - uRecedeTilt * (p.y - 0.5));
    float perspX = (p.x - 0.5) / perspDenom + 0.5;
    vec2 bgUv = (vec2(perspX, p.y) - 0.5) / max(scaleBg, 0.001) + 0.5;

    vec2 fw = vec2(1.0) / viewport;
    vec2 edgeAa = smoothstep(-fw, fw, bgUv) * (1.0 - smoothstep(1.0 - fw, 1.0 + fw, bgUv));
    float inBounds = mix(1.0, edgeAa.x * edgeAa.y, smoothstep(0.0, 0.05, progress));

    float bgDim = 1.0 - smoothstep(0.10, 0.88, progress);
    vec2 centered = (p - 0.5) * 2.0;
    float vignette = 1.0 - smoothstep(0.35, 1.35, length(centered)) * (0.55 * progress);
    vec4 bgSample = sampleBackdrop(bgUv);
    vec3 bgRgb = bgSample.rgb * inBounds * bgDim * clamp(vignette, 0.0, 1.0);

    // 2) Target 16:9 Cinema Portal rectangle centered inside safe area insets.
    vec2 safeOrigin = uSafePadding.xy;
    vec2 safeSize = max(viewport - uSafePadding.xy - uSafePadding.zw, vec2(1.0));
    float safeAspect = safeSize.x / safeSize.y;
    float targetAspect = 16.0 / 9.0;
    vec2 targetSize = safeAspect > targetAspect
        ? vec2(safeSize.y * targetAspect, safeSize.y)
        : vec2(safeSize.x, safeSize.x / targetAspect);
    vec2 targetPos = safeOrigin + (safeSize - targetSize) * 0.5;
    vec4 targetRect = vec4(targetPos, targetSize);

    float rectT = smoothstep(0.0, 0.82, progress);
    vec4 curRect = mix(uPosterOrigin, targetRect, rectT);
    vec2 curSize = max(curRect.zw, vec2(1.0));
    float maxRadius = 0.5 * min(curSize.x, curSize.y);
    float r = clamp(
        mix(uPosterRadius, 0.0, smoothstep(0.15, 0.75, progress)),
        0.0,
        maxRadius
    );

    // 3) Aspect-ratio preserving BoxFit.cover poster crop (eliminates 2:3 -> 16:9 stretch).
    vec2 localUv = (fragCoord - curRect.xy) / curSize;
    float rectAspect = curSize.x / curSize.y;
    float safePosterAspect = max(uPosterAspect, 0.0001);
    vec2 coverScale = rectAspect > safePosterAspect
        ? vec2(1.0, safePosterAspect / rectAspect)
        : vec2(rectAspect / safePosterAspect, 1.0);
    vec2 posterUv = clamp((localUv - 0.5) * coverScale + 0.5, vec2(0.0), vec2(1.0));
    float posterFade = 1.0 - smoothstep(0.45, 0.80, progress);
    vec4 posterSample = uPosterAvailable > 0.5 ? samplePoster(posterUv) : vec4(0.0);
    vec3 placeholderRgb = vec3(0.071, 0.071, 0.086) * posterFade;
    vec3 posterRgb = uPosterAvailable > 0.5
        ? posterSample.rgb * posterFade
        : placeholderRgb;

    // 4) Rounded-rectangle SDF anti-aliased mask + subtle cinema frame rim.
    vec2 rectHalfSize = curSize * 0.5;
    vec2 rectCenter = curRect.xy + rectHalfSize;
    vec2 q = abs(fragCoord - rectCenter) - rectHalfSize + vec2(r);
    float sdf = length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - r;
    float mask = 1.0 - smoothstep(-0.75, 0.75, sdf);

    float rimBand = (1.0 - smoothstep(0.0, 1.75, abs(sdf)))
        * sin(3.14159265 * progress)
        * (1.0 - smoothstep(0.55, 0.85, progress));
    vec3 portalRgb = clamp(posterRgb + vec3(0.16, 0.18, 0.22) * rimBand, vec3(0.0), vec3(1.0));

    float portalPresence = step(1.0, uPosterOrigin.z) * step(1.0, uPosterOrigin.w);
    float effectiveMask = mask * portalPresence;

    // Premultiplied alpha composition: outPremul = fgPremul + bgPremul * (1.0 - fgPremul.a).
    vec4 bgPremul = vec4(clamp(bgRgb, vec3(0.0), vec3(1.0)), 1.0);
    vec4 fgPremul = vec4(portalRgb * effectiveMask, effectiveMask);
    vec4 composed = fgPremul + bgPremul * (1.0 - fgPremul.a);

    // 5) Final handoff (0.68 -> 1.0): dissolve overlay cleanly to reveal active video surface.
    float handoffAlpha = 1.0 - smoothstep(0.68, 1.0, progress);
    fragColor = vec4(composed.rgb * handoffAlpha, handoffAlpha);
}
