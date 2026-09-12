#version 150
// Added uniforms: diskPhase, dustPhase, codexEnergySmooth,
// codexTrailSmooth, codexParticlesSmooth.  The Swift renderer uploads these
// continuously so visual state survives reconnects and renderer restarts.
uniform sampler2D desktop;
uniform vec2 iResolution;
uniform vec4 captureRect;
uniform float iTime, LENS_DEPTH, temperature, inclination, rollAngle, brightness;
uniform int style, hasCapture, useCustomColor;
uniform float spin, charge, massScale;
uniform vec3 customRGB;
uniform int codexState;
uniform float codexEnergy, codexTrail, codexParticles, codexPulse;
uniform float diskPhase, dustPhase;
uniform float codexEnergySmooth, codexTrailSmooth, codexParticlesSmooth;
out vec4 outputColor;
vec4 desktopSample(vec2 uv) {
 if(hasCapture == 0) return vec4(0.0);
 return texture(desktop, captureRect.xy + uv * captureRect.zw);
}
#define N_STEPS 64
struct DiskLook { float temp, incl, roll, inner, outer, opac, dopp, beam, gain, contr, wind, speed, expo, star; };
#define B_CRIT 2.5980762

// ------------------------------------------------------------------- noise --
float hash21(vec2 p) {
    p = fract(p * vec2(234.34, 435.345));
    p += dot(p, p + 34.23);
    return fract(p.x * p.y);
}

// value noise whose y lattice wraps every perY cells — used for the disk's
// angular dimension so the streaks tile seamlessly across the atan branch cut
// (perY must be an integer; y must advance by exactly perY per full turn)
float vnoiseWrapY(vec2 p, float perY) {
    vec2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float y0 = mod(i.y, perY), y1 = mod(i.y + 1.0, perY);
    return mix(mix(hash21(vec2(i.x, y0)),       hash21(vec2(i.x + 1.0, y0)), f.x),
               mix(hash21(vec2(i.x, y1)),       hash21(vec2(i.x + 1.0, y1)), f.x),
               f.y);
}

// mirrored repeat keeps lensed samples on-screen without edge smearing
vec2 mirrorUV(vec2 u) { return 1.0 - abs(1.0 - mod(u, 2.0)); }

vec2 rot(vec2 v, float a) {
    float c = cos(a), s = sin(a);
    return vec2(c * v.x - s * v.y, s * v.x + c * v.y);
}

// A visible screen-space lens term layered on top of the geodesic mapping.
// The ray tracer supplies the physical shadow and disk geometry; this term
// keeps ordinary desktop text visibly bent at the edge of a small pet window,
// where a fully physical far-field deflection would otherwise be sub-pixel.
vec2 visibleLensOffset(vec2 p, float rh, float depth, float scale) {
    float r = length(p);
    if (r <= rh * 0.90) return vec2(0.0);
    vec2 dir = p / max(r, 1e-4);
    float bend = clamp(depth / 13.0, 0.45, 2.8) * scale;
    float envelope = 1.0 - smoothstep(0.78 * rh, 7.0 * rh, r);
    float falloff = pow(clamp(rh / max(r, 0.78 * rh), 0.0, 1.0), 1.18);
    float radial = 0.52 * rh * bend * falloff * envelope;
    float tangential = spin * 0.10 * rh * falloff * envelope;
    return dir * radial + vec2(-dir.y, dir.x) * tangential;
}

// unit Lissajous wander: 2+2 incommensurate sines per axis, so the orbit
// never visibly repeats; scale the argument for speed, the result for reach
vec2 lissa(float t) {
    return vec2(0.75 * sin(t * 0.37) + 0.25 * sin(t * 0.83 + 1.0),
                0.70 * sin(t * 0.54 + 2.1) + 0.30 * sin(t * 1.07));
}

// blackbody color from temperature in Kelvin (Tanner Helland fit, normalized)
vec3 blackbody(float T) {
    float t = clamp(T, 1500.0, 40000.0) / 100.0;
    float r = t <= 66.0 ? 1.0
                        : clamp(1.292936 * pow(t - 60.0, -0.1332047), 0.0, 1.0);
    float g = t <= 66.0 ? clamp(0.3900816 * log(t) - 0.6318414, 0.0, 1.0)
                        : clamp(1.1298909 * pow(t - 60.0, -0.0755148), 0.0, 1.0);
    float b = t >= 66.0 ? 1.0
                        : (t <= 19.0 ? 0.0
                                     : clamp(0.5432068 * log(t - 10.0) - 1.1962540, 0.0, 1.0));
    return vec3(r, g, b);
}

// sparse procedural starfield indexed by ray direction — because it is
// sampled with the *bent* ray, stars smear into arcs around the hole for free
vec3 stars(vec3 d) {
    vec2 sph = vec2(atan(d.x, -d.z), asin(clamp(d.y, -1.0, 1.0)));
    vec2 g   = sph * 40.0;
    vec2 id  = floor(g);
    float h  = hash21(id);
    if (h < 0.92) return vec3(0.0);
    vec2 f   = fract(g) - 0.5;
    vec2 off = (vec2(hash21(id + 17.3), hash21(id + 31.7)) - 0.5) * 0.7;
    float spark = 1.0 - smoothstep(0.0, 0.10, length(f - off));
    float tw    = 0.7 + 0.3 * sin(iTime * (0.5 + 2.0 * hash21(id + 5.1)) + 40.0 * h);
    vec3 tint   = mix(vec3(1.0, 0.82, 0.60), vec3(0.75, 0.85, 1.0), hash21(id + 2.9));
    return tint * spark * tw * ((h - 0.92) / 0.08);
}

// Project a point from disk-plane coordinates into the screen.  Inclination
// makes the disk an ellipse, roll sets its major-axis orientation, and spin
// gives the state particles a signed orbital direction without touching the
// geodesic integrator below.
vec2 projectDiskPoint(vec2 diskPoint, float diskCos, float diskRoll) {
    return rot(vec2(diskPoint.x, diskPoint.y * diskCos), diskRoll);
}

// A restrained particle field that only appears near the projected disk. It
// is state-driven, but its phase is supplied by the renderer so a reconnect
// cannot make particles jump backwards or replay old motion.
vec3 codexDust(vec2 p, float rh, float phase) {
    float energy = clamp(codexEnergySmooth > 0.001 ? codexEnergySmooth : codexEnergy, 0.0, 1.0);
    float particles = clamp(codexParticlesSmooth > 0.001 ? codexParticlesSmooth : codexParticles, 0.0, 1.0);
    float visibility = smoothstep(0.05, 0.95, particles);
    float diskInclination = style == 2 ? 0.45 : inclination;
    float diskCos = clamp(abs(cos(diskInclination)), 0.16, 1.0);
    // Keep the overlay in the same plane as the traced disk. Spin changes
    // direction below; it must not make the particle plane wobble separately.
    float diskRoll = rollAngle;
    float shadowClear = smoothstep(1.10 * rh, 1.48 * rh, length(p));
    float outc = 0.0;
    float instability = codexState == 5 ? 1.0 : 0.0;
    float spinSign = spin < 0.0 ? -1.0 : 1.0;
    float orbitPhase = phase * spinSign * (0.72 + 0.28 * abs(spin));

    for (int i = 0; i < 14; i++) {
        float fi = float(i);
        float direction = i % 2 == 0 ? 1.0 : -1.0;
        float particlePhase = fi * 2.399963 + orbitPhase * direction + spin * fi * 0.17;
        float ring = rh * (2.10 + 1.50 * fract(sin(fi * 17.13) * 43758.5453));
        ring += sin(phase * 1.7 + fi * 3.2) * rh * 0.11 * instability;
        vec2 cDisk = vec2(cos(particlePhase), sin(particlePhase)) * ring;
        vec2 c = projectDiskPoint(cDisk, diskCos, diskRoll);
        vec2 delta = p - c;
        float size = rh * (0.025 + 0.025 * fract(sin(fi * 8.1) * 912.4));
        float minorSize = size * mix(0.34, 1.0, diskCos);
        float spark = exp(-(delta.x * delta.x / max(size * size, 1e-4) +
                            delta.y * delta.y / max(minorSize * minorSize, 1e-4)));
        outc += spark * (0.24 + 0.95 * particles) * smoothstep(0.0, 1.0, visibility);
    }

    // Command mode gets inward-falling fragments. Long-task state (3) keeps
    // that same ingress structure while error mode adds a jittering phase.
    if (codexState == 2 || codexState == 3 || codexState == 5) {
        float fallPhase = fract(phase * 0.72);
        for (int j = 0; j < 4; j++) {
            float fj = float(j);
            float errorJitter = codexState == 5 ? 0.16 * sin(phase * 3.7 + fj * 2.4) : 0.0;
            float a = fj * 1.57 + spinSign * phase * 0.22 + errorJitter;
            float rr = rh * mix(4.9, 1.65, fract(fallPhase + fj * 0.21));
            vec2 cDisk = vec2(cos(a), sin(a)) * rr;
            vec2 c = projectDiskPoint(cDisk, diskCos, diskRoll);
            vec2 delta = p - c;
            float minorSize = rh * 0.11 * mix(0.42, 1.0, diskCos);
            float spark = exp(-(delta.x * delta.x / max(rh * rh * 0.012, 1e-4) +
                                delta.y * delta.y / max(minorSize * minorSize, 1e-4)));
            outc += spark * (0.35 + 0.65 * particles);
        }
    }

    vec3 dustColor = codexState == 3 ? vec3(0.66, 0.55, 1.0) :
                     (codexState == 4 ? vec3(0.62, 1.0, 0.72) :
                     (codexState == 5 ? vec3(1.0, 0.30, 0.16) : vec3(1.0, 0.64, 0.32)));
    return dustColor * outc * visibility * (0.34 + 0.72 * energy) * shadowClear;
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
 vec2 uv = fragCoord / iResolution;
 float aspect = iResolution.x / iResolution.y;
 float energy = clamp(codexEnergySmooth > 0.001 ? codexEnergySmooth : codexEnergy, 0.0, 1.0);
 float trail = clamp(codexTrailSmooth > 0.001 ? codexTrailSmooth : codexTrail, 0.0, 1.0);
 DiskLook L = DiskLook(temperature, inclination, rollAngle, 1.8, 8.0, 0.9, 0.6, 2.5, brightness, 1.6, 7.0, 5.0, 1.4, 0.0);
 L.gain *= 1.0 + energy * 0.52;
 L.opac *= 1.0 + energy * 0.16;
 L.speed *= 1.0 + energy * 0.34;
 if(style == 2) { L.incl = 0.45; L.inner = 2.2; L.outer = 6.0; }
 if(style == 3) { L.gain = 0.0; L.opac = 0.0; }
 L.dopp = clamp(L.dopp + abs(spin)*0.35, 0.0, 1.0);
 L.speed *= spin < 0.0 ? -1.0 : 1.0;
 float rin = max(L.inner - abs(spin)*0.18 + charge*charge*0.6, 1.6), rout = max(L.outer, rin + 0.5);
 vec2 center = vec2(0.5);
 float rh = 0.085 * massScale * (1.0 - 0.16 * charge * charge);
 float dil = 0.6;
 float shield = 1.0;
    // aspect-corrected frame centered on the hole (y in units of screen height)
    vec2  p    = (uv - center) * vec2(aspect, 1.0);
    float plen = length(p);

    // screen <-> world mapping: the shadow's true angular size is B_CRIT r_s,
    // and we want it rh screen units wide, so 1 screen unit = W Schwarzschild
    // radii. pr is the pixel in world units, y-up, with the system roll applied.
    float W  = B_CRIT / max(rh, 1e-4);
    // Artistic rotating/charged family approximation, not Kerr geodesic integration.
    // Localized forward/inverse screen warp keeps far-field texture mapping continuous.
    float frameDrag = spin * 0.65 * exp(-dot(p,p)/(rh*rh*12.0));
    vec2 warpedP = rot(p, frameDrag);
    warpedP.x += spin * rh * 0.28 * exp(-dot(p,p)/(rh*rh*10.0));
    vec2 pr = rot(vec2(warpedP.x, -warpedP.y), L.roll) * W;
    float b  = length(pr);              // the ray's impact parameter, in r_s

    // distance-window: real lensing falls off as 1/b and would shimmer text
    // across the whole screen as the hole drifts; fade it out a few disk
    // diameters away (deliberately unphysical, like the work-area shield)
    float window = exp(-pow(plen / (7.0 * rh), 2.0));

    float bmax = rout + 3.0;            // rays beyond this can't touch the disk
    float Z0   = max(14.0, rout + 5.0); // camera distance (shared with the tracer)

    // ================= far field: analytic weak deflection ==================
    // The geodesic region's rays start at the finite camera z = Z0 and get
    // projected back onto the sky plane, so they bend *less* than the
    // textbook alpha = 2 r_s/b from infinity — using that raw leaves a ~20%
    // displacement jump at the handoff radius, a visible circular seam.
    // This is the same finite-camera mapping, fitted against the integrator
    // (sub-1% at the boundary): disp = (2/b)(1.29u + 0.07)(L - 2.14u + 0.75)
    // in world units, with u = Z0/sqrt(Z0^2 + b^2).
    vec3 bg = vec3(0.0);
    vec3 emitc = vec3(0.0);
    float trans = 1.0;
    bool captured = false;
    if (b >= bmax) {
        float u    = Z0 * inversesqrt(Z0 * Z0 + b * b);
        float defl = (2.0 / (W * W)) / max(plen, 1e-4)
                   * (1.29 * u + 0.07) * max(LENS_DEPTH - 2.14 * u + 0.75, 0.0)
                   * window * shield;
        vec2  dir  = p / max(plen, 1e-5);
        vec3  term;
        // mild chromatic aberration: blue bends a touch more than red; faded
        // in away from the handoff circle (the geodesic side has none)
        float ab = 0.035 * smoothstep(1.0, 2.0, b / bmax);
        for (int i = 0; i < 3; i++) {
            float k   = 1.0 + (float(i) - 1.0) * ab;
            vec2  sp  = p - dir * defl * k;
            sp += visibleLensOffset(p, rh, LENS_DEPTH, style == 3 ? 1.25 : 0.72) * window;
            vec2  suv = mirrorUV(center + sp / vec2(aspect, 1.0));
            term[i]   = desktopSample(suv)[i];
        }
        // same starfield as the geodesic region, lit through the weak-field
        // bend so stars don't pop at the boundary circle
        vec3 d = normalize(vec3(-(pr / b) * (2.0 / b), -1.0));
        bg = term + stars(d) * L.star * window * shield;
    } else {

    // ====================== near field: trace the geodesic ==================
    // Parallel rays from a distant camera at +z. The hole is at the origin,
    // r_s = 1. Integrate  x'' = -(3/2) h² x / r⁵  (exact Schwarzschild photon
    // bending; h = |x×v| is conserved, so it's computed once).
    vec3  x  = vec3(pr, Z0);
    vec3  v  = vec3(0.0, 0.0, -1.0);
    float h2 = dot(pr, pr);

    // disk plane: normal tilted DISK_INCL about the screen x-axis
    float ci = cos(L.incl), si = sin(L.incl);
    vec3  n  = vec3(0.0, si, ci);
    vec3  e2 = vec3(0.0, ci, -si);      // in-plane axis completing (x̂, e2, n)
    float sdir = L.speed < 0.0 ? -1.0 : 1.0;

    // accumulated disk light (HDR)
    float sPrev = dot(x, n);
    vec3  xPrev = x;

    for (int i = 0; i < N_STEPS; i++) {
        float r2 = dot(x, x);
        if (r2 < 1.0) { captured = true; break; }        // through the horizon
        if (x.z < -Z0 && v.z < 0.0) break;               // escaped out the back
        if (r2 > 4.0 * Z0 * Z0) break;                   // flung far sideways
        float r  = sqrt(r2);
        // step scales with radius: fine near the photon sphere, coarse far
        // out (the far cap is loose — bending falls off as 1/r^4, and longer
        // approach/exit strides leave more of the N_STEPS budget for the
        // strongly curved region)
        float dt = clamp(0.16 * r, 0.03, 1.5);
        // leapfrog (kick-drift-kick) keeps the near-critical orbits stable
        vec3 a = -1.5 * h2 * x / (r2 * r2 * r);
        v += a * (0.5 * dt);
        x += v * dt;
        r2 = dot(x, x);
        r  = sqrt(r2);
        a  = -1.5 * h2 * x / (r2 * r2 * r);
        v += a * (0.5 * dt);

        // ---- thin-disk crossing: the ray pierced the disk plane ----
        float s = dot(x, n);
        if (s * sPrev < 0.0 && trans > 0.02) {
            float tc = sPrev / (sPrev - s);
            vec3  xc = mix(xPrev, x, tc);
            float rc = length(xc);
            if (rc > rin && rc < rout) {
                float band = smoothstep(rin, rin * 1.25, rc)
                           * (1.0 - smoothstep(rout * 0.70, rout, rc));

                // disk-plane polar coords for the streak texture
                float phi   = atan(dot(xc, e2), xc.x);
                float turns = phi / 6.2831853;
                float kep   = pow(rin / rc, 1.5);
                // √(1 − 1.5/r): time runs slower for the inner orbits — the
                // pattern visibly freezes toward the inner edge; dil winds the
                // whole disk down as the hole grows
                float gloc  = sqrt(max(1.0 - 1.5 / rc, 0.02));
                float swirl = rc * L.wind * 0.12 - diskPhase * kep * gloc * dil;
                float streaks = vnoiseWrapY(vec2(rc * 2.8, turns * 19.0 + swirl * 3.0), 19.0) * 0.65 +
                                vnoiseWrapY(vec2(rc * 1.0, turns * 9.0  + swirl * 1.5 + 7.0), 9.0) * 0.35;
                streaks = 0.35 + L.contr * streaks * streaks;

                // relativistic Doppler + gravitational shift for gas on a
                // circular geodesic: g = √(1 − 1.5/r) / (1 − β·k̂), with the
                // photon direction at the crossing taken from the ray itself
                vec3  gasdir = normalize(cross(n, xc)) * sdir;
                float beta   = clamp(inversesqrt(max(2.0 * (rc - 1.0), 0.2)), 0.0, 0.99);
                float g      = gloc / max(1.0 + beta * dot(gasdir, normalize(v)), 0.05);
                g = mix(1.0, g, L.dopp);

                // Shakura–Sunyaev temperature profile, peak normalized to 1
                float xpr   = max(1.0 - sqrt(rin / rc), 0.0);
                float tprof = pow(rin / rc, 0.75) * pow(xpr, 0.25) / 0.488;
                vec3  cbb   = blackbody(L.temp * tprof * g);      // doppler-shifted color
                float boost = pow(g, L.beam);                     // relativistic beaming

                float density = band * streaks;
                emitc += trans * cbb * (L.gain * 2.2 * density * tprof * tprof * boost);
                trans *= 1.0 - clamp(L.opac * density, 0.0, 1.0);
            }
        }
        sPrev = s;
        xPrev = x;
    }
    // rays still wound up near the photon sphere when the budget ran out are
    // as good as captured
    if (!captured && dot(x, x) < 4.0) captured = true;

    // ---- background: where did the escaped ray come from? ----
    if (!captured) {
        vec3 d = normalize(v);
        bg += stars(d) * L.star * window * shield;
        if (d.z < -0.05) {
            // project the straight exit ray onto the terminal sky plane at
            // z = -LENS_DEPTH and map back to screen space
            float tpl = (-LENS_DEPTH - x.z) / d.z;
            vec3  hp  = x + d * tpl;
            vec2  q   = rot(hp.xy, -L.roll) / W;
            vec2 sp = vec2(q.x, -q.y);
            sp.x -= spin * rh * 0.28 * exp(-dot(p,p)/(rh*rh*10.0));
            sp = rot(sp, -frameDrag);
            sp += visibleLensOffset(p, rh, LENS_DEPTH, style == 3 ? 1.25 : 0.72) * window;
            // the *displacement* is faded by window/shield, never the color —
            // a continuous warp leaves no seam at the work area or far field
            vec2  suv = mirrorUV(center + (p + (sp - p) * window * shield) / vec2(aspect, 1.0));
            // rays bent past ~90° never reach the sky plane behind the hole;
            // they fade to the starfield instead of sampling garbage
            float toward = smoothstep(0.05, 0.35, -d.z);
            bg += desktopSample(suv).rgb * toward;
        }
    }
    }

    // disk light is HDR; tonemap it on top of the (untouched) terminal sample
    vec3 diskLight = vec3(1.0) - exp(-emitc * L.expo);
    if(useCustomColor == 1) diskLight = customRGB * max(diskLight.r,max(diskLight.g,diskLight.b));
    // Local procedural halo: it carries the long-task trail without sampling
    // offset desktop texels, so the black-hole shadow stays uncontaminated by
    // a second, misregistered copy of the work area.
    float haloRadius = rh * (2.25 + 0.18 * abs(spin));
    float haloWidth = max(rh * (0.36 + 0.16 * trail), 1e-4);
    float haloBand = exp(-pow((plen - haloRadius) / haloWidth, 2.0));
    float haloEdge = smoothstep(1.08 * rh, 1.36 * rh, plen) *
                     (1.0 - smoothstep(5.2 * rh, 7.0 * rh, plen));
    float haloAngle = atan(p.y, p.x);
    float haloMotion = 0.72 + 0.28 * sin(dustPhase * (1.1 + 0.45 * abs(spin)) +
                                             haloAngle * (2.0 + 1.5 * abs(spin)) + spin * 0.7);
    vec3 haloColor = codexState == 3 ? vec3(0.72, 0.60, 1.0) :
                     (codexState == 4 ? vec3(0.46, 1.0, 0.70) :
                     (codexState == 5 ? vec3(1.0, 0.24, 0.12) : vec3(0.95, 0.62, 0.34)));
    vec3 halo = haloColor * trail * haloBand * haloEdge * haloMotion * (0.12 + 0.28 * energy);

    vec3 dust = codexDust(p, rh, dustPhase);
    float resultPhase = dustPhase + haloAngle * 0.35;
    bool isComplete = codexState == 4;
    bool isError = codexState == 5;
    float pulseRadius = rh * (isError ? 2.04 + 0.14 * sin(resultPhase * 8.0) :
                              (isComplete ? 2.15 + 0.035 * sin(resultPhase * 3.2) : 2.15));
    float pulseWidth = rh * (isError ? 0.54 : (isComplete ? 0.62 : 0.60));
    float pulseRing = exp(-pow((plen - pulseRadius) / max(pulseWidth, 1e-4), 2.0));
    float pulseMotion = isError ? 0.84 + 0.28 * sin(resultPhase * 11.0 + haloAngle * 3.0) :
                        (isComplete ? 0.94 + 0.08 * sin(resultPhase * 4.0 + haloAngle) : 1.0);
    vec3 pulseColor = isComplete ? vec3(0.44, 1.0, 0.68) :
                      (isError ? vec3(1.0, 0.22, 0.10) : vec3(1.0, 0.78, 0.46));
    float pulseClear = smoothstep(1.08 * rh, 1.34 * rh, plen);
    vec3 pulse = pulseColor * codexPulse * pulseRing * pulseMotion * pulseClear * 1.25;
    vec3 col = bg * trans + diskLight + halo + dust + pulse;
    float a = hasCapture == 1 ? 1.0 : (captured ? 1.0 : clamp(max(col.r,max(col.g,col.b)) + 1.0-trans,0.0,1.0));
    fragColor = vec4(col, a);
}

void main() {
 vec2 coord = vec2(gl_FragCoord.x, iResolution.y-gl_FragCoord.y);
 float r = length(coord/iResolution - 0.5);
 if(r > 0.5) { outputColor=vec4(0); return; }
 vec4 c; mainImage(c, coord);
 float fade=1.0-smoothstep(0.40,0.50,r);
 outputColor=vec4(c.rgb*fade,c.a*fade);
}
