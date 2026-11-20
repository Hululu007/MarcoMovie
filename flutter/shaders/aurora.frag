// Copyright (C) 2026 Pilipala
// SPDX-License-Identifier: GPL-3.0-only
//
// Marco Aurora four-tone low-frequency flowing backdrop shader (zero texture sampling).
// Coordinate contract: FlutterFragCoord().xy and uCanvasSize are in logical pixels (lp).
// Output contract: premultiplied opaque RGBA vec4(color, 1.0).
#include <flutter/runtime_effect.glsl>

// Float slots 0..15 (16 floats total, 0 samplers)
uniform vec2 uCanvasSize;  // 0..1: canvas logical size (width, height)
uniform float uElapsedSec; // 2: CPU-wrapped elapsed seconds mod 6283.1853 (2000 * pi)
uniform float uStrength;   // 3: aurora blend strength [0.0, 1.0] (default 0.62)
uniform vec3 uWaveBlue;    // 4..6: #0A84FF -> (0.039, 0.518, 1.000)
uniform vec3 uWaveTeal;    // 7..9: #5AC8FA -> (0.353, 0.784, 0.980)
uniform vec3 uWaveIndigo;  // 10..12: #5E5CE6 -> (0.369, 0.361, 0.902)
uniform vec3 uWavePurple;  // 13..15: #BF5AF2 -> (0.749, 0.353, 0.949)

out vec4 fragColor;

void main() {
    vec2 canvasSize = max(uCanvasSize, vec2(1.0));
    vec2 uv = (FlutterFragCoord().xy - 0.5 * canvasSize) / max(canvasSize.y, 1.0);
    float t = uElapsedSec * 0.38;

    float d1 = uv.y + 0.22 * sin(uv.x * 2.1 + t) + 0.12 * cos(uv.x * 1.3 - t * 0.7);
    float w1 = exp(-3.4 * d1 * d1);

    float d2 = uv.y - 0.18 * cos(uv.x * 1.7 - t * 0.85) + 0.15 * sin(t * 0.45);
    float w2 = exp(-4.2 * d2 * d2);

    float d3 = length(uv - vec2(0.28 * sin(t * 0.55), -0.16 * cos(t * 0.65))) - 0.34;
    float w3 = exp(-3.8 * d3 * d3);

    vec3 base = vec3(0.035, 0.035, 0.047); // #09090C
    float strength = clamp(uStrength, 0.0, 1.0);
    vec3 wave1Color = mix(uWaveBlue, uWaveTeal, 0.5 + 0.5 * sin(t));
    vec3 color = clamp(
        base + strength * (
            0.42 * w1 * wave1Color
            + 0.36 * w2 * uWaveIndigo
            + 0.30 * w3 * uWavePurple
        ),
        vec3(0.0),
        vec3(1.0)
    );
    fragColor = vec4(color, 1.0);
}
