/* REFRIMAR · Pie de página con la marca en puntos (adaptación sin React de "Halftone Wordmark Footer").
 * La palabra se dibuja como una trama de puntos; los puntos crecen y se encienden en celeste cerca del puntero.
 * Uso: RefPiePagina(contenedor, { palabra, etiqueta, meta, columnas:[{titulo, links:[{t, href}]}], arriba:true })
 */
(function () {
    'use strict';
    var CSS = [
        '.hf-root{--hf-bg:#0A2540;--hf-ink:#E6F6FF;--hf-warm:#00AAFF;--hf-soft:rgba(230,246,255,.6);position:relative;overflow:hidden;background:var(--hf-bg);color:var(--hf-ink);border-radius:24px;padding:28px 28px 18px;margin-top:28px;font-family:"Poppins","Inter",system-ui,"Segoe UI",Roboto,Arial,sans-serif;isolation:isolate}',
        '.hf-root::before{content:"";position:absolute;inset:-40% -10% auto auto;width:60%;height:120%;background:radial-gradient(closest-side,rgba(0,170,255,.22),transparent 70%);pointer-events:none;z-index:-1}',
        '.hf-top{display:flex;flex-wrap:wrap;gap:24px 40px;align-items:flex-start;justify-content:space-between}',
        '.hf-brand{display:flex;flex-direction:column;gap:6px;max-width:280px}',
        '.hf-brand b{font-size:15px;font-weight:700;letter-spacing:-.01em}',
        '.hf-brand span{font-size:12.5px;color:var(--hf-soft);line-height:1.5}',
        '.hf-cols{display:flex;flex-wrap:wrap;gap:20px 44px}',
        '.hf-col{display:flex;flex-direction:column;gap:7px;min-width:120px}',
        '.hf-col h4{margin:0 0 3px;font-size:11px;font-weight:600;letter-spacing:.08em;text-transform:uppercase;color:var(--hf-warm)}',
        '.hf-col a,.hf-up{color:var(--hf-ink);text-decoration:none;font-size:13.5px;opacity:.86;transition:opacity .2s,color .2s}',
        '.hf-col a:hover,.hf-up:hover{opacity:1;color:#fff}',
        '.hf-col a:focus-visible,.hf-up:focus-visible{outline:2px solid var(--hf-warm);outline-offset:3px;border-radius:4px}',
        '.hf-up{all:unset;cursor:pointer;display:inline-flex;align-items:center;gap:6px;font-size:13px;font-weight:600;padding:9px 16px;border-radius:999px;background:rgba(230,246,255,.08);box-shadow:inset 0 0 0 1px rgba(230,246,255,.16);opacity:1}',
        '.hf-up:hover{background:rgba(0,170,255,.18)}',
        '.hf-mark{position:relative;width:100%;margin:22px 0 6px;touch-action:pan-y}',
        '.hf-mark canvas{display:block;width:100%;height:100%}',
        '.hf-bar{display:flex;flex-wrap:wrap;justify-content:space-between;gap:8px;border-top:1px solid rgba(230,246,255,.12);padding-top:12px;font-size:11.5px;color:var(--hf-soft);font-family:"Inter",system-ui,sans-serif;letter-spacing:.02em}',
        '.hf-root.hf-solo{background:transparent;padding:0;margin:0;border-radius:0;overflow:visible}.hf-root.hf-solo::before{display:none}.hf-solo .hf-mark{margin:0}',
        '@media (max-width:640px){.hf-root{padding:22px 18px 14px;border-radius:18px;margin-bottom:72px}.hf-cols{gap:18px 28px}}'
    ].join('\n');

    function inyectar() { if (document.getElementById('hf-css')) return; var s = document.createElement('style'); s.id = 'hf-css'; s.textContent = CSS; document.head.appendChild(s); }
    function esc(s) { return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); }
    function rgb(hex) { var h = hex.replace('#', ''); var n = parseInt(h.length === 3 ? h.replace(/./g, '$&$&') : h, 16); return [(n >> 16) & 255, (n >> 8) & 255, n & 255]; }

    window.RefPiePagina = function (contenedor, o) {
        inyectar();
        o = o || {};
        var palabra = o.palabra || 'refrimar';
        // Otra empresa (multiempresa): su propio nombre en vez de "refrimar"
        try { var emp = JSON.parse(localStorage.getItem('ref_empresa') || 'null'); if (emp && emp.esquema && emp.esquema !== 'public' && emp.nombre && palabra === 'refrimar') palabra = String(emp.nombre).toLowerCase().slice(0, 18); } catch (e) {}
        var root = document.createElement('footer');
        root.className = 'hf-root';
        root.setAttribute('role', 'contentinfo');
        var cols = (o.columnas || []).map(function (c) {
            return '<nav class="hf-col" aria-label="' + esc(c.titulo) + '"><h4>' + esc(c.titulo) + '</h4>' + c.links.map(function (l) { return '<a href="' + esc(l.href) + '">' + esc(l.t) + '</a>'; }).join('') + '</nav>';
        }).join('');
        if (o.soloMarca) root.classList.add('hf-solo');
        root.innerHTML = o.soloMarca ? '<div class="hf-mark" aria-label="' + esc(palabra) + '" role="img"><canvas aria-hidden="true"></canvas></div>' : '<div class="hf-top"><div class="hf-brand"><b>' + esc(o.etiqueta || '') + '</b><span>' + esc(o.texto || '') + '</span></div>' +
            '<div class="hf-cols">' + cols + '</div>' +
            (o.arriba === false ? '' : '<button type="button" class="hf-up">Volver arriba <span aria-hidden="true">↑</span></button>') + '</div>' +
            '<div class="hf-mark" aria-label="' + esc(palabra) + '" role="img"><canvas aria-hidden="true"></canvas></div>' +
            '<div class="hf-bar"><span>© ' + new Date().getFullYear() + ' ' + esc(o.etiqueta || '') + '</span><span>' + esc(o.meta || '') + '</span></div>';
        contenedor.appendChild(root);
        var up = root.querySelector('.hf-up');
        if (up) up.addEventListener('click', function () { window.scrollTo({ top: 0, behavior: 'smooth' }); var m = document.querySelector('main'); if (m && m.scrollTop) m.scrollTo({ top: 0, behavior: 'smooth' }); });

        var box = root.querySelector('.hf-mark'), cv = box.querySelector('canvas'), ctx = cv.getContext('2d');
        if (!ctx) return root;
        var cs = getComputedStyle(root);
        var INK = rgb((cs.getPropertyValue('--hf-ink') || '#E6F6FF').trim()), WARM = rgb((cs.getPropertyValue('--hf-warm') || '#00AAFF').trim());
        var reducir = window.matchMedia && matchMedia('(prefers-reduced-motion: reduce)').matches;
        var dots = [], W = 0, H = 0, celda = 7, dpr = 1, raf = 0, t0 = 0;
        var ptr = { x: -9999, y: -9999, on: false }, foco = { x: -9999, y: -9999, k: 0 };

        function medir() {
            W = box.clientWidth; if (!W) return false;
            celda = W < 520 ? 4 : W < 900 ? 6 : 7;
            H = Math.round(W * (W < 520 ? 0.24 : 0.2));
            box.style.height = H + 'px';
            dpr = Math.min(2, window.devicePixelRatio || 1);
            cv.width = Math.round(W * dpr); cv.height = Math.round(H * dpr);
            // máscara: la palabra en negrita, ajustada al ancho
            var m = document.createElement('canvas'), mw = Math.ceil(W / celda), mh = Math.ceil(H / celda);
            m.width = mw * 4; m.height = mh * 4;
            var mx = m.getContext('2d');
            var fs = m.height * 1.05;
            mx.font = '800 ' + fs + 'px Poppins, "Arial Black", Arial, sans-serif';
            var ancho = mx.measureText(palabra).width;
            fs = Math.min(fs, fs * (m.width * 0.995) / ancho);
            mx.font = '800 ' + fs + 'px Poppins, "Arial Black", Arial, sans-serif';
            mx.textBaseline = 'alphabetic'; mx.textAlign = 'center';
            mx.fillStyle = '#000';
            mx.fillText(palabra, m.width / 2, m.height * 0.86);
            var px = mx.getImageData(0, 0, m.width, m.height).data;
            dots = [];
            for (var gy = 0; gy < mh; gy++) {
                for (var gx = 0; gx < mw; gx++) {
                    var a = 0;
                    for (var sy = 0; sy < 4; sy++) for (var sx = 0; sx < 4; sx++) a += px[((gy * 4 + sy) * m.width + gx * 4 + sx) * 4 + 3];
                    a /= 16 * 255;
                    if (a < 0.04) continue;
                    var cx = (gx + 0.5) * celda, cy = (gy + 0.5) * celda;
                    // degradado de trama: más lleno arriba, más fino hacia abajo
                    var g = 1 - 0.55 * (cy / H);
                    dots.push({ x: cx, y: cy, r: celda * 0.5 * Math.sqrt(a) * (0.38 + 0.62 * g), d: Math.random() });
                }
            }
            return true;
        }
        function pintar(t) {
            ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
            ctx.clearRect(0, 0, W, H);
            var entra = reducir ? 1 : Math.min(1, (t - t0) / 1100);
            foco.x += (ptr.x - foco.x) * 0.18; foco.y += (ptr.y - foco.y) * 0.18;
            foco.k += ((ptr.on ? 1 : 0) - foco.k) * 0.08;
            var R = Math.max(70, W * 0.11), R2 = R * R;
            for (var i = 0; i < dots.length; i++) {
                var p = dots[i];
                var aparece = Math.max(0, Math.min(1, entra * 1.6 - (p.x / W) * 0.6 - p.d * 0.15));
                if (aparece <= 0) continue;
                var dx = p.x - foco.x, dy = p.y - foco.y, d2 = dx * dx + dy * dy, e = 0;
                if (foco.k > 0.01 && d2 < R2) { e = 1 - Math.sqrt(d2) / R; e = e * e * (3 - 2 * e) * foco.k; }
                var r = p.r * aparece * (1 + e * 0.75);
                if (r < 0.25) continue;
                var c0 = INK[0] + (WARM[0] - INK[0]) * e, c1 = INK[1] + (WARM[1] - INK[1]) * e, c2 = INK[2] + (WARM[2] - INK[2]) * e;
                ctx.fillStyle = 'rgba(' + (c0 | 0) + ',' + (c1 | 0) + ',' + (c2 | 0) + ',' + (0.55 + 0.45 * Math.max(aparece * 0.8, e)) + ')';
                ctx.beginPath(); ctx.arc(p.x, p.y, Math.min(r, celda * 0.62), 0, 6.2832); ctx.fill();
            }
            var sigue = entra < 1 || Math.abs(foco.k - (ptr.on ? 1 : 0)) > 0.005 || (ptr.on && (Math.abs(ptr.x - foco.x) > 0.5 || Math.abs(ptr.y - foco.y) > 0.5));
            raf = sigue ? requestAnimationFrame(pintar) : 0;
        }
        function animar() { if (!raf) raf = requestAnimationFrame(pintar); }
        function arrancar() { if (!medir()) return; t0 = performance.now(); animar(); }

        box.addEventListener('pointermove', function (e) { var r = box.getBoundingClientRect(); ptr.x = e.clientX - r.left; ptr.y = e.clientY - r.top; if (!ptr.on) { foco.x = ptr.x; foco.y = ptr.y; } ptr.on = true; animar(); });
        box.addEventListener('pointerleave', function () { ptr.on = false; animar(); });

        var ultimoW = 0;
        if ('ResizeObserver' in window) new ResizeObserver(function () { if (Math.abs(box.clientWidth - ultimoW) < 2) return; ultimoW = box.clientWidth; if (medir()) { t0 = performance.now() - 5000; animar(); } }).observe(box);
        var empezar = function () { ultimoW = box.clientWidth; arrancar(); };
        var conFuente = document.fonts && document.fonts.load ? document.fonts.load('800 40px Poppins').catch(function () {}) : Promise.resolve();
        if ('IntersectionObserver' in window) {
            var io = new IntersectionObserver(function (en) { if (!en.some(function (x) { return x.isIntersecting; })) return; io.disconnect(); conFuente.then(empezar); }, { threshold: 0.2 });
            io.observe(box);
        } else conFuente.then(empezar);
        return root;
    };
})();
