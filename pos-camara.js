/* ============================================================
 * REFRIMAR POS · Escanear con la cámara (teléfono / tablet / webcam de la PC)
 * ------------------------------------------------------------
 * Botón de cámara dentro del buscador de la factura. La cámara queda abierta
 * y cada código que lee entra a la factura EXACTAMENTE igual que con la
 * pistola lectora: escribe el código en el buscador y pulsa Enter (misma
 * lógica de pos-app.js: stock, empaques, balanza, precios… no se toca nada).
 *   - Mismo código pegado frente a la cámara: no se repite. Para sumar otra
 *     unidad se aparta y se vuelve a mostrar.
 *   - Código que no está en el catálogo de la tienda: avisa y no agrega nada.
 *
 * Velocidad (de más rápido a respaldo):
 *   1. Lector propio del equipo (BarcodeDetector: Android, Mac).
 *   2. zxing-wasm 3.1.5 (zxing-cpp en WebAssembly): PC con Windows, iPhone…
 *      Lee cuadro tras cuadro, sin pausas, a la mayor resolución de la cámara.
 *      Si no lo encuentra, afila la imagen (las webcams salen borrosas) y
 *      vuelve a intentar en el mismo cuadro: duplica las lecturas en imágenes borrosas.
 *   3. @zxing/browser 0.1.5 si el navegador no soporta WebAssembly.
 * Se precarga al abrir la caja. En la webcam de la PC la imagen sale en
 * espejo (como un espejo normal); el botón "Voltear" lo cambia y se recuerda.
 * ============================================================ */
(function () {
    'use strict';
    var WASM_JS = '/js/lib/zxing-wasm-3.1.5/reader.js';
    var WASM_BIN = '/js/lib/zxing-wasm-3.1.5/zxing_reader.wasm';
    var ZX_LOCAL = '/js/lib/zxing-browser-0.1.5.min.js';
    var ZX_CDN = 'https://cdn.jsdelivr.net/npm/@zxing/browser@0.1.5/umd/zxing-browser.min.js';
    var K_ESPEJO = 'refrimar_pos_cam_espejo';
    var PAUSA_MISMO = 1200;   // ms sin ver el código antes de poder sumarlo otra vez
    var CON_VERIFICADOR = { EAN13: 1, EAN8: 1, UPCA: 1, UPCE: 1, EAN_13: 1, EAN_8: 1, UPC_A: 1, UPC_E: 1, ean_13: 1, ean_8: 1, upc_a: 1, upc_e: 1 };
    var NATIVO_FMT = ['ean_13', 'ean_8', 'upc_a', 'upc_e', 'code_128', 'code_39', 'code_93', 'codabar', 'itf'];
    var WASM_OPC = { formats: ['EAN13', 'EAN8', 'UPCA', 'UPCE', 'Code128', 'Code39', 'Code93', 'Codabar', 'ITF'],
        tryHarder: true, tryRotate: true, tryInvert: false, tryDownscale: true, maxNumberOfSymbols: 1 };

    var activo = null, NATIVO = null, WASM = null, PREPARANDO = null;

    function $(id) { return document.getElementById(id); }
    function esc(s) { return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); }
    function pos() { return window.__POS || null; }
    function ls(k, v) { try { if (v === undefined) return localStorage.getItem(k); localStorage.setItem(k, v); } catch (e) { return null; } }
    function script(src) {
        return new Promise(function (ok, ko) {
            var s = document.createElement('script'); s.src = src;
            s.onload = function () { ok(); };
            s.onerror = function () { s.remove(); ko(new Error('No se pudo cargar el lector de códigos. Revisa tu internet.')); };
            document.head.appendChild(s);
        });
    }

    // ---------- Preparar el lector más rápido disponible (una sola vez) ----------
    function preparar() {
        if (PREPARANDO) return PREPARANDO;
        PREPARANDO = (async function () {
            if ('BarcodeDetector' in window && window.BarcodeDetector.getSupportedFormats) {
                try {
                    var f = await window.BarcodeDetector.getSupportedFormats();
                    var usa = NATIVO_FMT.filter(function (x) { return f.indexOf(x) >= 0; });
                    if (usa.indexOf('ean_13') >= 0) { NATIVO = new window.BarcodeDetector({ formats: usa }); return 'nativo'; }
                } catch (e) {}
            }
            if (typeof WebAssembly === 'object') {
                try {
                    if (!window.ZXingWASM) await script(WASM_JS);
                    window.ZXingWASM.prepareZXingModule({
                        overrides: { locateFile: function (p, pre) { return /\.wasm$/.test(p) ? WASM_BIN : pre + p; } },
                        fireImmediately: true
                    });
                    // Calienta el motor con una imagen vacía (así el primer código sale al instante)
                    await window.ZXingWASM.readBarcodes(new ImageData(8, 8), WASM_OPC);
                    WASM = window.ZXingWASM; return 'wasm';
                } catch (e) { WASM = null; }
            }
            if (!window.ZXingBrowser) await script(ZX_LOCAL).catch(function () { return script(ZX_CDN); });
            return 'zxing';
        })();
        PREPARANDO.catch(function () { PREPARANDO = null; });
        return PREPARANDO;
    }

    function css() {
        if ($('pc-css')) return;
        var s = document.createElement('style'); s.id = 'pc-css';
        s.textContent =
            '.busca .in{padding-right:100px}' +
            '.pc-cam-btn{position:absolute;right:52px;top:50%;transform:translateY(-50%);width:40px;height:40px;border-radius:999px;border:0;background:transparent;color:var(--tx2,#52525B);display:inline-flex;align-items:center;justify-content:center;cursor:pointer}' +
            '.pc-cam-btn[hidden]{display:none}.pc-cam-btn:hover,.pc-cam-btn:focus-visible{background:var(--rubro-suave,#E6F6FF);color:#0A2540;outline:0}' +
            '.pc-cam-btn .material-symbols-outlined{font-size:24px}' +
            '.pc-ov{position:fixed;inset:0;z-index:10050;background:rgba(10,37,64,.94);display:flex;flex-direction:column;align-items:center;justify-content:flex-start;gap:10px;padding:16px;overflow:auto}' +
            '.pc-cam{position:relative;width:min(96vw,1040px);aspect-ratio:16/9;max-height:58vh;border-radius:22px;overflow:hidden;background:#000;flex:none}' +
            '@media (max-width:700px){.pc-cam{aspect-ratio:3/4;max-height:62vh}}' +
            '.pc-cam video,.pc-cam svg{position:absolute;inset:0;width:100%;height:100%;display:block}' +
            '.pc-cam video{object-fit:cover}' +
            '.pc-cam.espejo video,.pc-cam.espejo svg{transform:scaleX(-1)}' +
            '.pc-cam svg polygon{fill:rgba(34,197,94,.18);stroke:#22C55E;stroke-width:4;stroke-linejoin:round;opacity:0;transition:opacity .15s}' +
            '.pc-cam svg polygon.on{opacity:1}.pc-cam svg polygon.mal{fill:rgba(245,158,11,.18);stroke:#F59E0B}' +
            '.pc-guia{position:absolute;left:3%;right:3%;top:8%;bottom:8%;border:3px solid rgba(0,170,255,.85);border-radius:18px;transition:border-color .12s;pointer-events:none}' +
            '.pc-guia.ok{border-color:#22C55E}.pc-guia.mal{border-color:#F59E0B}' +
            '.pc-msg{color:#E6F6FF;font:500 15px Inter,system-ui,sans-serif;text-align:center;min-height:22px;max-width:1040px}' +
            '.pc-lista{width:min(96vw,1040px);display:flex;flex-direction:column;gap:6px}' +
            '.pc-it{display:flex;align-items:center;gap:10px;background:rgba(255,255,255,.08);color:#fff;border-radius:14px;padding:9px 12px;font:14px Inter,system-ui,sans-serif}' +
            '.pc-it b{flex:1;min-width:0;font-weight:500;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}' +
            '.pc-it small{color:#A5D8FF;white-space:nowrap}.pc-it.mal{background:rgba(245,158,11,.18)}.pc-it.mal small{color:#FCD34D}' +
            '.pc-th{width:48px;height:48px;flex:none;border-radius:12px;background:#fff;display:flex;align-items:center;justify-content:center;overflow:hidden;color:#8FCFF0}' +
            '.pc-th img{width:100%;height:100%;object-fit:contain}' +
            '.pc-it:first-child{padding:12px 16px;background:rgba(255,255,255,.14)}.pc-it:first-child.mal{background:rgba(245,158,11,.22)}' +
            '.pc-it:first-child .pc-th{width:88px;height:88px;border-radius:16px}' +
            '.pc-it:first-child b{font:600 20px Poppins,sans-serif;white-space:normal}.pc-it:first-child small{font-size:17px;color:#fff;font-weight:600}' +
            '.pc-bar{display:flex;gap:10px;flex-wrap:wrap;justify-content:center;margin-top:4px}' +
            '.pc-bt{height:48px;padding:0 22px;border-radius:999px;border:0;font:600 15px Poppins,sans-serif;cursor:pointer;display:inline-flex;align-items:center;gap:6px}' +
            '.pc-bt.pri{background:#00AAFF;color:#0A2540}.pc-bt.sec{background:rgba(255,255,255,.12);color:#fff}';
        document.head.appendChild(s);
    }

    // Busca el producto igual que pos-app.js (código, códigos alternos, empaques) — solo para mostrar el nombre
    function encontrar(cod) {
        var P = pos(); if (!P || !P.S) return null;
        var S = P.S, t = String(cod || '').trim().toLowerCase(), vs = [t];
        if (/^\d{12}$/.test(t)) vs.push('0' + t);
        if (/^0\d{12}$/.test(t)) vs.push(t.slice(1));
        for (var k = 0; k < vs.length; k++) {
            var v = vs[k];
            if (S.porCodigo && S.porCodigo[v]) return { p: S.porCodigo[v], texto: v };
            for (var i = 0; i < (S.catalogo || []).length; i++) {
                var p = S.catalogo[i];
                if ((p.alt || []).indexOf(v) >= 0) return { p: p, texto: v };
                var e = (p.empaques || []).find(function (x) { return x.barra === v; });
                if (e) return { p: p, texto: v, empaque: e };
            }
        }
        return null;
    }

    // Mete el código a la factura por el mismo camino que la pistola lectora
    function agregarALaFactura(texto) {
        var inp = $('f-buscar'); if (!inp) return false;
        inp.value = texto;
        inp.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true, cancelable: true }));
        return inp.value === '';   // pos-app.js limpia el buscador cuando lo agregó
    }

    // Afilado (máscara de enfoque) en escala de grises: g + k·(g − desenfoque de caja de radio r)
    // Probados con imágenes borrosas de webcam: estos 3 alternados leen 3,5 veces más que sin afilar
    var AFILADOS = [[3, 6], [2, 4], [5, 8]];
    var BUF = {};
    function afilar(img, r, k) {
        var w = img.width, h = img.height, n = w * h, d = img.data, i, x, y;
        if (BUF.n !== n) BUF = { n: n, g: new Float32Array(n), t: new Float32Array(n) };
        var g = BUF.g, t = BUF.t, win = 2 * r + 1;
        for (i = 0; i < n; i++) g[i] = (d[i * 4] * 77 + d[i * 4 + 1] * 150 + d[i * 4 + 2] * 29) >> 8;
        for (y = 0; y < h; y++) {          // desenfoque horizontal
            var o = y * w, s = 0;
            for (x = -r; x <= r; x++) s += g[o + Math.min(w - 1, Math.max(0, x))];
            for (x = 0; x < w; x++) {
                t[o + x] = s / win;
                s += g[o + Math.min(w - 1, x + r + 1)] - g[o + Math.max(0, x - r)];
            }
        }
        for (x = 0; x < w; x++) {          // desenfoque vertical + afilado
            var s2 = 0;
            for (y = -r; y <= r; y++) s2 += t[Math.min(h - 1, Math.max(0, y)) * w + x];
            for (y = 0; y < h; y++) {
                var p = y * w + x, v = g[p] + k * (g[p] - s2 / win);
                v = v < 0 ? 0 : v > 255 ? 255 : v;
                d[p * 4] = d[p * 4 + 1] = d[p * 4 + 2] = v;
                s2 += t[Math.min(h - 1, y + r + 1) * w + x] - t[Math.max(0, y - r) * w + x];
            }
        }
        return img;
    }

    function soltar() {
        if (!activo) return;
        var a = activo; activo = null;
        a.vivo = false;
        try { if (a.controls) a.controls.stop(); } catch (e) {}
        try { if (a.stream) a.stream.getTracks().forEach(function (t) { t.stop(); }); } catch (e) {}
        try { if (a.video) { a.video.pause(); a.video.srcObject = null; } } catch (e) {}
        if (a.ov) a.ov.remove();
        document.removeEventListener('keydown', a.onKey, true);
        document.removeEventListener('visibilitychange', a.onHide);
        window.removeEventListener('pagehide', soltar);
        var inp = $('f-buscar'); if (inp && window.matchMedia('(pointer:fine)').matches) inp.focus();
    }

    async function abrir() {
        if (activo) return;
        var P = pos();
        if (!P || !P.S || !(P.S.catalogo || []).length) return aviso('Espera que carguen los productos');
        if (!(navigator.mediaDevices && navigator.mediaDevices.getUserMedia)) return aviso('Este navegador no deja usar la cámara (hace falta https).');
        css();
        var ov = document.createElement('div'); ov.className = 'pc-ov';
        ov.setAttribute('role', 'dialog'); ov.setAttribute('aria-label', 'Escanear con la cámara');
        ov.innerHTML = '<div class="pc-cam"><video playsinline muted autoplay></video><svg preserveAspectRatio="none"><polygon points=""/></svg><div class="pc-guia"></div></div>' +
            '<div class="pc-msg" aria-live="polite">Abriendo la cámara…</div>' +
            '<div class="pc-bar"><button type="button" class="pc-bt sec" data-pc="voltear"><span class="material-symbols-outlined">flip</span>Voltear</button>' +
            '<button type="button" class="pc-bt sec" data-pc="luz" hidden><span class="material-symbols-outlined">flashlight_on</span>Linterna</button>' +
            '<button type="button" class="pc-bt pri" data-pc="listo">Listo</button></div>' +
            '<div class="pc-lista"></div>';
        document.body.appendChild(ov);
        var cam = ov.querySelector('.pc-cam'), video = ov.querySelector('video'), svg = ov.querySelector('svg'), poly = ov.querySelector('polygon');
        var msg = ov.querySelector('.pc-msg'), guia = ov.querySelector('.pc-guia'), lista = ov.querySelector('.pc-lista');
        activo = { ov: ov, video: video, controls: null, stream: null, vivo: false,
            onKey: function (e) { if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); soltar(); } },
            onHide: function () { if (document.hidden) soltar(); } };
        var yo = activo;
        document.addEventListener('keydown', activo.onKey, true);
        document.addEventListener('visibilitychange', activo.onHide);
        window.addEventListener('pagehide', soltar);
        ov.querySelector('[data-pc="listo"]').addEventListener('click', soltar);
        ov.querySelector('[data-pc="voltear"]').addEventListener('click', function () {
            var on = !cam.classList.contains('espejo'); cam.classList.toggle('espejo', on); ls(K_ESPEJO, on ? '1' : '0');
        });

        // ---- Qué hacer con cada lectura ----
        var ultimo = '', visto = 0, previo = '', n = 0, tGuia = null, tBox = null;
        function marcar(cls) { guia.className = 'pc-guia ' + cls; clearTimeout(tGuia); tGuia = setTimeout(function () { guia.className = 'pc-guia'; }, 700); }
        function caja(puntos, mal) {   // recuadro verde encima del código (en píxeles del video)
            if (!puntos || !puntos.length || !video.videoWidth) return;
            svg.setAttribute('viewBox', '0 0 ' + video.videoWidth + ' ' + video.videoHeight);
            svg.setAttribute('preserveAspectRatio', 'xMidYMid slice');
            poly.setAttribute('points', puntos.map(function (p) { return Math.round(p.x) + ',' + Math.round(p.y); }).join(' '));
            poly.setAttribute('class', 'on' + (mal ? ' mal' : ''));
            clearTimeout(tBox); tBox = setTimeout(function () { poly.setAttribute('class', ''); }, 350);
        }
        function fila(nombre, detalle, mal, codigo) {
            var d = document.createElement('div'); d.className = 'pc-it' + (mal ? ' mal' : '');
            var V = window.RefPosVista, f = codigo && V ? V.fotoYa(codigo) : null;
            d.innerHTML = (codigo ? '<span class="pc-th">' + (f ? '<img src="' + esc(f) + '" alt=""/>' : '<span class="material-symbols-outlined">inventory_2</span>') + '</span>'
                : '<span class="material-symbols-outlined">' + (mal ? 'error' : 'check_circle') + '</span>') +
                '<b>' + esc(nombre) + '</b><small>' + esc(detalle) + '</small>';
            lista.insertBefore(d, lista.firstChild);
            while (lista.children.length > 6) lista.removeChild(lista.lastChild);
            if (codigo && !f && V) V.foto(codigo, function (img) { var t = d.querySelector('.pc-th'); if (t) t.innerHTML = '<img src="' + esc(img) + '" alt=""/>'; });
        }
        function leido(cod, fmt, puntos) {
            if (activo !== yo) return;
            cod = String(cod || '').trim(); var ahora = Date.now();
            if (!cod) return;
            if (cod === ultimo && ahora - visto < PAUSA_MISMO) { visto = ahora; caja(puntos); return; }   // sigue frente a la cámara
            if (!CON_VERIFICADOR[fmt] && cod !== previo) { previo = cod; return; }                     // sin dígito verificador: 2 lecturas
            previo = ''; ultimo = cod; visto = ahora;
            var f = encontrar(cod);
            if (!f) {
                caja(puntos, true); marcar('mal'); fila('No está en el catálogo', cod, true);
                msg.textContent = 'Código ' + cod + ' no está en esta tienda';
                if (P.h && P.h.beep) try { P.h.beep('error'); } catch (e) {}
                return;
            }
            var ok = agregarALaFactura(f.texto);
            if (ok && (f.p.stock > 0 || f.p.servicio)) {
                n++; caja(puntos); marcar('ok'); if (navigator.vibrate) navigator.vibrate(50);
                var H = P.h, pf = P.precioFinal(f.p);
                fila(f.p.descripcion, (f.empaque ? f.empaque.nombre + ' · ' : '') + (H ? H.bs(pf * P.S.tasa) + ' · ' + H.usd(pf) : f.p.codigo), false, f.p.codigo);
                msg.textContent = n + (n === 1 ? ' producto agregado' : ' productos agregados') + ' · Listo para el siguiente';
            } else {
                caja(puntos, true); marcar('mal'); fila(f.p.descripcion, 'Sin stock', true, f.p.codigo);
                msg.textContent = 'Sin stock: ' + f.p.descripcion;
            }
        }

        try {
            var motorP = preparar();   // en paralelo con abrir la cámara
            // La mayor resolución que dé la cámara (más píxeles por barra = lee más lejos y más rápido)
            yo.stream = await navigator.mediaDevices.getUserMedia({ audio: false, video: { facingMode: { ideal: 'environment' }, width: { ideal: 1920 }, height: { ideal: 1080 }, frameRate: { ideal: 30 } } });
            if (activo !== yo) { yo.stream.getTracks().forEach(function (t) { t.stop(); }); return; }
            var pista = yo.stream.getVideoTracks()[0], cap = {}, conf = {};
            try { cap = pista.getCapabilities ? pista.getCapabilities() : {}; conf = pista.getSettings ? pista.getSettings() : {}; } catch (e) {}
            if (cap.focusMode && cap.focusMode.indexOf('continuous') >= 0) pista.applyConstraints({ advanced: [{ focusMode: 'continuous' }] }).catch(function () {});
            // Espejo: cámara frontal o webcam de PC → como un espejo; cámara trasera del teléfono → normal
            var guardado = ls(K_ESPEJO);
            var espejo = guardado != null ? guardado === '1'
                : conf.facingMode ? conf.facingMode === 'user' : !/Android|iPhone|iPad|iPod|Mobile/i.test(navigator.userAgent);
            cam.classList.toggle('espejo', espejo);
            video.srcObject = yo.stream;
            await video.play().catch(function () {});
            var motor = await motorP;
            if (activo !== yo) return;
            yo.vivo = true;
            msg.textContent = 'Muestra el código a la cámara (a unos 15–20 cm). Cada producto entra solo a la factura.';

            if (motor === 'nativo' || motor === 'wasm') {
                var cv = document.createElement('canvas'), cx = cv.getContext('2d', { willReadFrequently: true }), vuelta = 0;
                var siguiente = function (fn) { if (video.requestVideoFrameCallback) video.requestVideoFrameCallback(fn); else requestAnimationFrame(fn); };
                var ciclo = async function () {
                    if (!yo.vivo) return;
                    var w = video.videoWidth, h = video.videoHeight;
                    if (w && h && video.readyState >= 2) {
                        try {
                            if (motor === 'nativo') {
                                var r = await NATIVO.detect(video);
                                if (r && r.length && yo.vivo) leido(r[0].rawValue, r[0].format, r[0].cornerPoints);
                            } else {
                                // Lo que está dentro del recuadro (casi toda la imagen)
                                var sx = Math.round(w * 0.03), sy = Math.round(h * 0.08), sw = w - 2 * sx, sh = h - 2 * sy;
                                if (cv.width !== sw || cv.height !== sh) { cv.width = sw; cv.height = sh; }
                                cx.drawImage(video, sx, sy, sw, sh, 0, 0, sw, sh);
                                var img = cx.getImageData(0, 0, sw, sh);
                                var res = await WASM.readBarcodes(img, WASM_OPC);
                                var b = res && res.find(function (x) { return x.isValid; });
                                if (!b && yo.vivo) {   // borroso: afilar y probar otra vez en el mismo cuadro
                                    var af = AFILADOS[vuelta++ % AFILADOS.length];   // un afilado distinto en cada cuadro
                                    afilar(img, af[0], af[1]);
                                    res = await WASM.readBarcodes(img, WASM_OPC);
                                    b = res && res.find(function (x) { return x.isValid; });
                                }
                                if (b && yo.vivo) {
                                    var pp = b.position, pts = pp ? [pp.topLeft, pp.topRight, pp.bottomRight, pp.bottomLeft].map(function (p) { return { x: p.x + sx, y: p.y + sy }; }) : null;
                                    leido(b.text, b.format, pts);
                                }
                            }
                        } catch (e) {}
                    }
                    if (yo.vivo) siguiente(ciclo);
                };
                siguiente(ciclo);
            } else {
                var Z = window.ZXingBrowser;
                var lector = new Z.BrowserMultiFormatOneDReader(undefined, { delayBetweenScanAttempts: 40, delayBetweenScanSuccess: 40 });
                yo.controls = await lector.decodeFromStream(yo.stream, video, function (res) {
                    if (res) leido(res.getText(), (Z.BarcodeFormat[res.getBarcodeFormat()] || ''), null);
                });
                if (activo !== yo) { try { yo.controls.stop(); } catch (e) {} return; }
            }
            yo.motor = motor;
            if (cap.torch) {
                var luz = ov.querySelector('[data-pc="luz"]'), on = false; luz.hidden = false;
                luz.addEventListener('click', function () { on = !on; pista.applyConstraints({ advanced: [{ torch: on }] }).catch(function () { luz.hidden = true; }); });
            }
        } catch (e) {
            var nm = e && e.name;
            msg.textContent = nm === 'NotAllowedError' ? 'No hay permiso para la cámara. Actívalo en el candado de la barra de direcciones.'
                : nm === 'NotFoundError' || nm === 'OverconstrainedError' ? 'No se encontró una cámara en este equipo.'
                : nm === 'NotReadableError' ? 'La cámara está ocupada por otra aplicación.'
                : 'No se pudo abrir la cámara: ' + ((e && e.message) || e);
            try { if (yo.stream) yo.stream.getTracks().forEach(function (t) { t.stop(); }); video.srcObject = null; } catch (x) {}
            yo.vivo = false;
        }
    }

    function aviso(t) { var P = pos(); if (P && P.toast) P.toast(t, '', 'warning'); else alert(t); }

    function montar() {
        var caja = document.querySelector('#v-factura .busca'), inp = $('f-buscar');
        if (!caja || !inp || $('pc-cam-btn')) return;
        css();
        var b = document.createElement('button');
        b.type = 'button'; b.id = 'pc-cam-btn'; b.className = 'pc-cam-btn';
        b.title = 'Escanear con la cámara'; b.setAttribute('aria-label', 'Escanear con la cámara');
        b.innerHTML = '<span class="material-symbols-outlined">photo_camera</span>';
        b.addEventListener('mousedown', function (e) { e.preventDefault(); });   // no quita el foco del buscador
        b.addEventListener('click', abrir);
        caja.appendChild(b);
        // Sin cámara en el equipo: no se muestra el botón (la caja trabaja con el buscador o la pistola)
        try {
            if (!(navigator.mediaDevices && navigator.mediaDevices.enumerateDevices)) { b.hidden = true; return; }
            navigator.mediaDevices.enumerateDevices().then(function (ds) {
                if (!ds.some(function (d) { return d.kind === 'videoinput'; })) b.hidden = true;
            }, function () {});
        } catch (e) {}
    }
    function iniciar() { montar(); setTimeout(function () { preparar().catch(function () {}); }, 1200); }   // lector listo desde que abre la caja
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', iniciar); else iniciar();
    window.RefPosCamara = { abrir: abrir, cerrar: soltar, motor: function () { return activo && activo.motor; } };
})();
