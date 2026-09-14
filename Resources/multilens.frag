#version 150
uniform int mode, hasCapture, useDesktopSurface, bodyCount;
uniform sampler2D scene, desktop;
uniform sampler2DRect desktopSurface;
uniform vec2 resolution;
uniform vec4 captureRect, bodyRects[3];
out vec4 outputColor;

void main() {
    vec2 uv = gl_FragCoord.xy / resolution;
    vec2 topDown = vec2(uv.x, 1.0 - uv.y);
    if (mode == 0) {
        if (hasCapture == 0) { outputColor = vec4(0.0); return; }
        vec2 source = captureRect.xy + topDown * captureRect.zw;
        vec3 color = useDesktopSurface == 1 ?
            texture(desktopSurface, source * vec2(textureSize(desktopSurface))).rgb :
            texture(desktop, source).rgb;
        outputColor = vec4(color, 1.0);
        return;
    }
    vec4 color = texture(scene, uv);
    if (mode == 2) {
        float coverage = 0.0;
        for (int i = 0; i < 3; i++) {
            if (i >= bodyCount) break;
            vec2 local = (topDown - bodyRects[i].xy) / bodyRects[i].zw - 0.5;
            coverage = max(coverage, 1.0 - smoothstep(0.39, 0.49, length(local)));
        }
        color *= coverage;
    }
    outputColor = color;
}
