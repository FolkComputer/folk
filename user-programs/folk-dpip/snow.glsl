float snow(vec2 uv, float scale)
{
    float w = smoothstep(20., 0., -uv.y * (scale / 10.));
    if (w < .1) return 0.;
    uv += iTime / scale;
    uv.y += iTime * 2. / scale;
    uv.x += sin(uv.y + iTime * .5) / scale;
    uv *= scale;

    vec2 s = floor(uv), f = fract(uv), p;
    float k = 3., d;
    p = .5 + .35 * sin(11. * fract(sin((s + p + scale) * mat2(7, 3, 6, 5)) * 5.)) - f;
    d = length(p);
    k = min(d, k);
    k = smoothstep(0., k, sin(f.x + f.y) * 0.01);
    return k * w;
}

void mainImage(out vec4 fragColor, in vec2 fragCoord)
{
    vec2 uv = (fragCoord * 2.0 - iResolution.xy) / min(iResolution.x, iResolution.y); 
    vec3 finalColor = vec3(0);

    //float c = smoothstep(1., 0.3, clamp(uv.y * .3 + .9, 0., .75));
    float c = 0.;
    //c += snow(uv, 30.) * .3;
    //c += snow(uv, 20.) * .5;
    //c += snow(uv, 15.) * .8;
    //c += snow(uv, 10.);
    //c += snow(uv, 8.);
    //c += snow(uv, 6.);
    //c += snow(uv, 5.);
    c += snow(uv, 8.);
    c += snow(uv, 5.);
    c += snow(uv, 2.);
    c += snow(uv, 1.);

    //finalColor = vec3(c * 0.9, c * 0.3, c);
    finalColor = vec3(c);
    //finalColor = vec3(uv.x, uv.y, 0.);
    fragColor = vec4(finalColor, 1.0);
}