/* Only native structured arguments enter here; TeX is never executable script. */
// WebKit can report an already-resolved FontFaceSet.ready immediately after a
// DOM update, before style/layout starts loading a newly used math font. Explicit
// loading also covers first-use Size/AMS/Math-Italic faces before PDF capture.
let noemaFontLoad = null;
window.noemaRenderMath = async function (tex, display, fontSize, color, width) {
    const surface = document.getElementById('surface');
    const equation = document.getElementById('equation');
    const marker = document.getElementById('baseline');
    surface.style.transform = '';
    surface.style.fontSize = `${fontSize}px`;
    surface.style.color = color;
    // Use a fresh macro table per expression: user definitions never cross notes.
    katex.render(tex, equation, {
        displayMode: display, output: 'htmlAndMathml', throwOnError: true,
        trust: false, strict: 'ignore', maxExpand: 1000, maxSize: 50,
        macros: Object.create(null)
    });
    void surface.offsetWidth;
    noemaFontLoad ??= Promise.all(Array.from(document.fonts, face => face.load()));
    await noemaFontLoad;
    await document.fonts.ready;
    const rect = surface.getBoundingClientRect();
    const scale = Math.min(1, Math.max(1, width - 4) / Math.max(1, rect.width));
    const baselineFromTop = marker.getBoundingClientRect().top - rect.top;
    surface.style.transform = `scale(${scale})`;
    // Floating multiplication may exceed the exact fitted width by an ulp;
    // preserve the caller's measure instead of rounding that noise up a point.
    return { width: Math.min(width, Math.ceil(rect.width * scale) + 4),
             height: Math.ceil(rect.height * scale) + 4,
             baseline: (rect.height - baselineFromTop) * scale + 2 };
};
