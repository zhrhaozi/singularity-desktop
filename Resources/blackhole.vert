#version 150
uniform float dustPhase, inclination, rollAngle, spin, massScale, charge;
uniform int style, codexState;
flat out vec4 dustCenters[9];

vec2 projectParticle(vec2 p, float diskCos) {
    p.y *= diskCos;
    float c=cos(rollAngle), s=sin(rollAngle);
    return vec2(c*p.x-s*p.y,s*p.x+c*p.y);
}

vec2 particleCenter(int index, float rh, float diskCos) {
    float spinSign=spin<0.0 ? -1.0 : 1.0;
    if(index<14) {
        float fi=float(index);
        float direction=index%2==0 ? 1.0 : -1.0;
        float orbitPhase=dustPhase*spinSign*(0.72+0.28*abs(spin));
        float phase=fi*2.399963+orbitPhase*direction+spin*fi*0.17;
        float ring=rh*(2.10+1.50*fract(sin(fi*17.13)*43758.5453));
        ring+=sin(dustPhase*1.7+fi*3.2)*rh*0.11*(codexState==5 ? 1.0 : 0.0);
        return projectParticle(vec2(cos(phase),sin(phase))*ring,diskCos);
    }
    float fj=float(index-14);
    float jitter=codexState==5 ? 0.16*sin(dustPhase*3.7+fj*2.4) : 0.0;
    float a=fj*1.57+spinSign*dustPhase*0.22+jitter;
    float rr=rh*mix(4.9,1.65,fract(fract(dustPhase*0.72)+fj*0.21));
    return projectParticle(vec2(cos(a),sin(a))*rr,diskCos);
}

void main() {
    vec2 p=vec2((gl_VertexID<<1)&2,gl_VertexID&2);
    gl_Position=vec4(p*2.0-1.0,0.0,1.0);
    float rh=0.085*massScale*(1.0-0.16*charge*charge);
    float diskCos=clamp(abs(cos(style==2 ? 0.45 : inclination)),0.16,1.0);
    // Uniform orbital positions need only three vertex invocations per frame.
    for(int i=0;i<9;i++) {
        dustCenters[i]=vec4(particleCenter(i*2,rh,diskCos),particleCenter(i*2+1,rh,diskCos));
    }
}
