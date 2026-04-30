#include <flutter/runtime_effect.glsl>

uniform float u_time;
uniform float u_width;
uniform float u_height;
uniform float u_collapse;

out vec4 fragColor;

// ── Utilities ────────────────────────────────────────────────────────────────
float hash(float n) { return fract(sin(n) * 43758.5453123); }

// ── 4D Rotations (three independent planes) ──────────────────────────────────
vec4 rotate14(vec4 p, float t) {
    float c = cos(t), s = sin(t);
    return vec4(c*p.x - s*p.w, p.y, p.z, s*p.x + c*p.w);
}
vec4 rotate23(vec4 p, float t) {
    float c = cos(t), s = sin(t);
    return vec4(p.x, c*p.y - s*p.z, s*p.y + c*p.z, p.w);
}
vec4 rotate12(vec4 p, float t) {
    float c = cos(t), s = sin(t);
    return vec4(c*p.x - s*p.y, s*p.x + c*p.y, p.z, p.w);
}

// ── Stereographic projection 4D→2D ───────────────────────────────────────────
// d=2.6 keeps fibers spread across the full screen rather than collapsing center
vec3 project(vec4 p, float collapse) {
    float d = 2.6 + (collapse * collapse * 18.0);
    float w = 1.0 / max(d - p.w, 0.05);
    return vec3(p.x, p.y, p.z) * w;
}

// ── HSV to RGB (for per-fiber hue cycling) ────────────────────────────────────
vec3 hsv2rgb(vec3 c) {
    vec4 K = vec4(1.0, 2.0/3.0, 1.0/3.0, 3.0);
    vec3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
    return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}

void main() {
    vec2 uv = (FlutterFragCoord().xy / u_height) * 2.0
              - vec2(u_width / u_height, 1.0);

    // Accelerate spin near collapse for the "Final Heartbeat" burst
    float t       = u_time * (0.7 + u_collapse * 2.5);
    vec3  color   = vec3(0.0);
    float fadeOut = 1.0 - pow(u_collapse, 3.0);

    // ── Central energy core ───────────────────────────────────────────────────
    // Grows brighter as the shape collapses, like a dying star contracting.
    float coreRadius  = length(uv);
    float corePulse   = 0.5 + 0.5 * sin(u_time * 6.0);
    float coreGlow    = exp(-coreRadius * (8.0 - u_collapse * 5.0)) 
                      * (0.15 + 0.10 * corePulse) * u_collapse;
    color += vec3(0.6, 0.3, 1.0) * coreGlow;

    // ── Hopf Fibration ────────────────────────────────────────────────────────
    // S3 parameterized via Hopf coordinates. Each fiber fi is a great circle
    // on S3. With STEPS=64 the circles render as visually continuous arcs.
    //
    // Hopf map: (θ,φ) on S2 → great circle parameterized by χ ∈ [0, 2π)
    //   p = (sin(θ/2)·cos(φ+χ), sin(θ/2)·sin(φ+χ), cos(θ/2)·cos(χ), cos(θ/2)·sin(χ))
    //
    const float FIBERS = 12.0;   // number of great circles
    const float STEPS  = 36.0;   // points per circle (dense enough for solid arcs)

    float goldenAngle = 2.39996318; // 2π/φ² — near-uniform S2 base distribution

    for (float fi = 0.0; fi < FIBERS; fi++) {
        // Spherical Fibonacci lattice → uniform base points on S2
        float cosTheta  = 1.0 - (2.0 * fi + 1.0) / FIBERS;
        float phi       = fi * goldenAngle;
        float halfTheta = acos(clamp(cosTheta, -1.0, 1.0)) * 0.5;

        // Per-fiber hue: spread evenly around color wheel + slow drift over time
        float hue = fract((fi / FIBERS) + u_time * 0.04);

        for (float si = 0.0; si < STEPS; si++) {
            float chi = (si / STEPS) * 6.28318530;

            // Point on S3 — |p| = 1 by construction
            vec4 p = vec4(
                sin(halfTheta) * cos(phi + chi),
                sin(halfTheta) * sin(phi + chi),
                cos(halfTheta) * cos(chi),
                cos(halfTheta) * sin(chi)
            );

            // True 4D tumbling: 3 independent rotation planes, different speeds
            p = rotate14(p, t * 1.00);
            p = rotate23(p, t * 0.61);
            p = rotate12(p, t * 0.38);

            vec3  q  = project(p, u_collapse);
            float d2 = length(uv - q.xy);

            // Energy pulse that travels along each fiber like an electrical arc
            float pulse = 0.55 + 0.45 * sin(chi * 5.0 - u_time * 7.0 + fi * 1.3);

            // Sharp core so fibers look like solid glowing wires, not blobs
            // Low multipliers since 64 steps × 20 fibers = 1280 total samples
            // Núcleo hiper-definido sin sangrado de luz (Cero neblina ambiental)
            float glow = exp(-d2 * 600.0) * (0.45 * pulse);

            // Per-fiber hue with depth (p.w) modulating saturation
            float depth = p.w * 0.5 + 0.5;
            vec3 fiberColor = hsv2rgb(vec3(hue, 0.75 + depth * 0.25, 1.0));

            color += fiberColor * glow;
        }
    }

    // ── Outer shimmer ring ────────────────────────────────────────────────────
    // A faint toroidal halo at r≈0.9 that pulses like a heartbeat
    float ring    = abs(coreRadius - (0.85 - u_collapse * 0.4));
    float ringGlow = exp(-ring * 30.0) * 0.06 * (0.5 + 0.5 * sin(u_time * 3.0));
    color += vec3(0.3, 0.7, 1.0) * ringGlow;

    // ── Tone mapping & output ─────────────────────────────────────────────────
    // Filmic-style soft clip: prevents any channel from going pure white
    color = color / (color + vec3(0.85));

    // Gamma lift for perceived contrast
    color = pow(max(color, vec3(0.0)), vec3(0.72));

    fragColor = vec4(color * fadeOut, 1.0);
}