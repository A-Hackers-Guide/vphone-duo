/// Kept as source, rather than a .metal build input: the system Metal compiler
/// compiles this on the rendering Mac. Building VPhone needs no Metal toolchain.
enum VPhoneHomePodShader {
    static let source = #"""
    #include <metal_stdlib>
    using namespace metal;

    struct CapUniforms {
        float4 viewport; // pixel width/height, cap center x/y
        float4 cap;      // radius in pixels, LED count, plus/minus light
    };
    struct CapLED { float4 position; float4 color; };

    vertex float4 capVertex(uint index [[vertex_id]]) {
        constexpr float2 triangle[] = {float2(-1, -1), float2(3, -1), float2(-1, 3)};
        return float4(triangle[index], 0, 1);
    }

    float stroke(float2 p, float2 center, bool plus, float aa) {
        float2 q = abs(p - center);
        float horizontal = max(q.x - 0.052, q.y - 0.0026);
        float vertical = max(q.x - 0.0026, q.y - 0.052);
        return 1.0 - smoothstep(-aa, aa, plus ? min(horizontal, vertical) : horizontal);
    }

    fragment float4 capFragment(float4 screen [[position]],
                               constant CapUniforms &u [[buffer(0)]],
                               device const CapLED *leds [[buffer(1)]]) {
        float radius = max(u.cap.x, 1.0);
        float2 p = (screen.xy - u.viewport.zw) / (radius * 2.0) + 0.5;
        float r = length(p - 0.5) * 2.0;
        float aa = 0.65 / radius;
        // All values below are linear; the sRGB render target performs the
        // display transfer exactly once, after optical mixing.
        const float3 background = float3(0.0044);
        if (r > 1.0 + aa * 2.0) return float4(background, 1);

        // A broad point-spread function merges neighbouring emitters beneath
        // the glass. Normalize the optical footprint, not the active colors:
        // inactive LEDs continue to contribute zero, preserving guest patterns.
        float3 light = 0;
        float weightSum = 0;
        for (uint i = 0; i < uint(u.cap.y); ++i) {
            float2 d = p - leds[i].position.xy;
            float d2 = dot(d, d);
            float weight = 0.86 * exp(-d2 / (2.0 * 0.155 * 0.155))
                         + 0.14 * exp(-d2 / (2.0 * 0.29 * 0.29));
            light += leds[i].color.rgb * weight;
            weightSum += weight;
        }
        light /= max(weightSum, 0.001);
        // The original mini's opaque edge masks scattered light; there are no
        // visible LED points or time-based effects added by the host.
        float edge = 1.0 - smoothstep(0.70, 0.985, r);
        light *= edge * 1.55;
        light = light / (1.0 + 0.45 * light);

        float glass = 0.0014 + 0.0015 * pow(max(0.0, 1.0 - r * r), 3.0);
        float reflection = 0.0022 * exp(-dot(p - float2(0.38, 0.24), p - float2(0.38, 0.24)) / 0.12);
        float3 surface = light + glass + reflection;

        float minus = stroke(p, float2(0.20, 0.5), false, aa * 0.5);
        float plus = stroke(p, float2(0.80, 0.5), true, aa * 0.5);
        // Etched markings remain faintly visible in reflected light. Their
        // emitted white light is a separate, guest-controlled HID channel.
        surface = mix(surface, float3(0.006) + surface * 0.12, max(minus, plus));
        surface += float3(minus * u.cap.w + plus * u.cap.z) * 0.9;

        float rim = exp(-pow((r - 0.992) / max(aa * 1.7, 0.002), 2.0));
        surface += rim * 0.012;
        float cover = 1.0 - smoothstep(1.0 - aa, 1.0 + aa, r);
        return float4(mix(background, surface, cover), 1);
    }
    """#
}
