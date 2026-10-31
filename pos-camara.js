/* ============================================================
 * REFRIMAR POS · Escanear con la cámara (teléfono / tablet / webcam)
 * ------------------------------------------------------------
 * Agrega un botón de cámara dentro del buscador de la factura.
 * La cámara se queda abierta y cada código que lee entra a la factura
 * EXACTAMENTE igual que con la pistola lectora: escribe el código en el
 * buscador y pulsa Enter (la misma lógica de pos-app.js: stock, empaques,
 * balanza, precios… no se toca nada).
 *   - Mismo código pegado frente a la cámara: no se repite. Para sumar otra
 *     unidad se aparta y se vuelve a mostrar.
 *   - Código que no está en el catálogo de la tienda: avisa y no agrega nada.
 * Rápido para la caja:
 *   - Android/Chrome: usa el lector propio del teléfono (BarcodeDetector), el más veloz.
 *   - iPhone y demás: @zxing/browser 0.1.5 solo con códigos de barra 1D (EAN, UPC,
 *     Code 128/39, ITF…), que es más rápido que buscar también QR.
 *   - El lector se precarga al abrir la caja y la cámara queda abierta para
 *     escanear un producto tras otro sin cerrar.
 * ============================================================ */
(function () {
    'use strict';
    var LIB_LOCAL = '/js/lib/zxing-browser-0.1.5.min.js';
    var LIB_CDN = 'https://cdn.jsdelivr.net/npm/@zxing/browser@0.1.5/umd/zxing-browser.min.js';
    var EAN_UPC = { EAN_13: 1, EAN_8: 1, UPC_A: 1, UPC_E: 1 };
    var PAUSA_MISMO = 1200;   // ms sin ver el código antes de poder sumarlo otra vez
    var activo = null, NATIVO = null;   // NATIVO: BarcodeDetector listo, o null
    var NATIVO_FMT = ['ean_13', 'ean_8', 'upc_a', 'upc_e', 'code_128', 'code_39', 'code_93', 'codabar', 'itf'];
    var NOMBRE_FMT = { ean_13: 'EAN_13', ean_8: 'EAN_8', upc_a: 'UPC_A', upc_e: 'UPC_E' };

    function $(id) { return document.getElementById(id); }
    function esc(s) { return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); }
    function pos() { return window.__POS || null; }

    function script(src) {
        return new Promise(function (ok, ko) {
            var s = document.createElement('script'); s.src = src;
            s.onload = function () { ok(); };
            s.onerror = function () { s.remove(); ko(new Error('No se pudo cargar el lector de códigos. Revisa tu internet.')); };
            document.head.appendChild(s);
        });
    }
    function cargarLib() {
        if (window.ZXingBrowser) return Promise.resolve();
        return script(LIB_LOCAL).catch(function () { return script(LIB_CDN); }).then(function () {
            if (!window.ZXingBrowser) throw new Error('No se pudo cargar el lector de códigos.');
        });
    }

    function css() {
        if ($('pc-css')) return;
        var s = document.createElement('style'); s.id = 'pc-css';
        s.textContent =
            '.busca .in{padding-right:100px}' +
            '.pc-cam-btn{position:absolute;right:52px;top:50%;transform:translateY(-50%);width:40px;height:40px;border-radius:999px;border:0;background:transparent;color:var(--tx2,#52525B);display:inline-flex;align-items:center;justify-content:center;cursor:pointer}' +
            '.pc-cam-btn:hover,.pc-cam-btn:focus-visible{background:var(--rubro-suave,#E6F6FF);color:#0A2540;outline:0}' +
            '.pc-cam-btn .material-symbols-outlined{font-size:24px}' +
            '.pc-ov{position:fixed;inset:0;z-index:10050;background:rgba(10,37,64,.94);display:flex;flex-direction:column;align-items:center;justify-content:flex-start;gap:10px;padding:16px;overflow:auto}' +
            '.pc-cam{position:relative;width:min(94vw,560px);aspect-ratio:4/3;max-height:52vh;border-radius:22px;overflow:hidden;background:#000;flex:none}' +
            '.pc-cam video{width:100%;height:100%;object-fit:cover;display:block}' +
            '.pc-guia{position:absolute;left:8%;right:8%;top:34%;height:32%;border:3px solid #00AAFF;border-radius:14px;box-shadow:0 0 0 2000px rgba(0,0,0,.22);transition:border-color .12s}' +
            '.pc-guia.ok{border-color:#22C55E}.pc-guia.mal{border-color:#F59E0B}' +
            '.pc-msg{color:#E6F6FF;font:500 15px Inter,system-ui,sans-serif;text-align:center;min-height:22px;max-width:560px}' +
            '.pc-lista{width:min(94vw,560px);display:flex;flex-direction:column;gap:6px}' +
            '.pc-it{display:flex;align-items:center;gap:10px;background:rgba(255,255,255,.08);color:#fff;border-radius:14px;padding:9px 12px;font:14px Inter,system-ui,sans-serif}' +
            '.pc-it b{flex:1;min-width:0;font-weight:500;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}' +
            '.pc-it small{color:#A5D8FF;white-space:nowrap}.pc-it.mal{background:rgba(245,158,11,.18)}.pc-it.mal small{color:#FCD34D}' +
            '.pc-bar{display:flex;gap:10px;flex-wrap:wrap;justify-content:center;margin-top:4px}' +
            '.pc-bt{height:48px;padding:0 26px;border-radius:999px;border:0;font:600 15px Poppins,sans-serif;cursor:pointer;display:inline-flex;align-items:center;gap:6px}' +
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

    function soltar() {
        if (!activo) return;
        var a = activo; activo = null;
        a.vivo = false;
        try { if (a.controls) a.controls.stop(); } catch (e) {}
        try { if (a.stream) a.stream.getTracks().forEach(function (t) { t.stop(); }); } catch (e) {}
        try { var st = a.video && a.video.srcObject; if (st && st.getTracks) st.getTracks().forEach(function (t) { t.stop(); }); } catch (e) {}
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
        ov.innerHTML = '<div class="pc-cam"><video playsinline muted autoplay></video><div class="pc-guia"></div></div>' +
            '<div class="pc-msg" aria-live="polite">Abriendo la cámara…</div>' +
            '<div class="pc-bar"><button type="button" class="pc-bt sec" data-pc="luz" hidden><span class="material-symbols-outlined">flashlight_on</span>Linterna</button>' +
            '<button type="button" class="pc-bt pri" data-pc="listo">Listo</button></div>' +
            '<div class="pc-lista"></div>';
        document.body.appendChild(ov);
        var video = ov.querySelector('video'), msg = ov.querySelector('.pc-msg'), guia = ov.querySelector('.pc-guia'), lista = ov.querySelector('.pc-lista');
        activo = { ov: ov, video: video, controls: null,
            onKey: function (e) { if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); soltar(); } },
            onHide: function () { if (document.hidden) soltar(); } };
        var yo = activo;
        document.addEventListener('keydown', activo.onKey, true);
        document.addEventListener('visibilitychange', activo.onHide);
        window.addEventListener('pagehide', soltar);
        ov.querySelector('[data-pc="listo"]').addEventListener('click', soltar);

        var ultimo = '', visto = 0, previo = '', n = 0, tGuia = null;
        function marcar(cls) { guia.className = 'pc-guia ' + cls; clearTimeout(tGuia); tGuia = setTimeout(function () { guia.className = 'pc-guia'; }, 700); }
        function fila(nombre, detalle, mal) {
            var d = document.createElement('div'); d.className = 'pc-it' + (mal ? ' mal' : '');
            d.innerHTML = '<span class="material-symbols-outlined">' + (mal ? 'error' : 'check_circle') + '</span><b>' + esc(nombre) + '</b><small>' + esc(detalle) + '</small>';
            lista.insertBefore(d, lista.firstChild);
            while (lista.children.length > 6) lista.removeChild(lista.lastChild);
        }
        function leido(cod, fmt) {
                    if (activo !== yo) return;
                    cod = String(cod || '').trim(); var ahora = Date.now();
                    if (!cod) return;
                    if (cod === ultimo && ahora - visto < PAUSA_MISMO) { visto = ahora; return; }   // sigue frente a la cámara
                    if (!EAN_UPC[fmt] && cod !== previo) { previo = cod; return; }                  // sin dígito verificador: 2 lecturas
                    previo = ''; ultimo = cod; visto = ahora;
                    var f = encontrar(cod);
                    if (!f) {
                        marcar('mal'); fila('No está en el catálogo', cod, true);
                        msg.textContent = 'Código ' + cod + ' no está en esta tienda';
                        if (P.h && P.h.beep) try { P.h.beep('error'); } catch (e) {}
                        return;
                    }
                    var ok = agregarALaFactura(f.texto);
                    if (ok && (f.p.stock > 0 || f.p.servicio)) {
                        n++; marcar('ok'); if (navigator.vibrate) navigator.vibrate(50);
                        fila(f.p.descripcion, f.empaque ? f.empaque.nombre : f.p.codigo, false);
                        msg.textContent = n + (n === 1 ? ' producto agregado' : ' productos agregados') + ' · Listo para el siguiente';
                    } else {
                        marcar('mal'); fila(f.p.descripcion, 'Sin stock', true);
                        msg.textContent = 'Sin stock: ' + f.p.descripcion;
                    }
        }
        try {
            if (!NATIVO) cargarLib().catch(function () {});   // en paralelo con abrir la cámara
            yo.stream = await navigator.mediaDevices.getUserMedia({ audio: false, video: { facingMode: { ideal: 'environment' }, width: { ideal: 1280 }, height: { ideal: 720 } } });
            if (activo !== yo) { yo.stream.getTracks().forEach(function (t) { t.stop(); }); return; }
            try { var tr = yo.stream.getVideoTracks()[0], cap = tr.getCapabilities ? tr.getCapabilities() : {};
                if (cap.focusMode && cap.focusMode.indexOf('continuous') >= 0) tr.applyConstraints({ advanced: [{ focusMode: 'continuous' }] }).catch(function () {}); } catch (e) {}
            yo.vivo = true;
            if (NATIVO) {
                video.srcObject = yo.stream; await video.play().catch(function () {});
                (function ciclo() {
                    if (!yo.vivo) return;
                    if (video.readyState < 2) return setTimeout(ciclo, 60);
                    NATIVO.detect(video).then(function (r) {
                        if (r && r.length && yo.vivo) leido(r[0].rawValue, NOMBRE_FMT[r[0].format] || r[0].format);
                    }).catch(function () {}).then(function () { if (yo.vivo) setTimeout(ciclo, 60); });
                })();
            } else {
                await cargarLib();
                if (activo !== yo) return;
                var Z = window.ZXingBrowser;
                var lector = new Z.BrowserMultiFormatOneDReader(undefined, { delayBetweenScanAttempts: 60, delayBetweenScanSuccess: 60 });
                yo.controls = await lector.decodeFromStream(yo.stream, video, function (res) {
                    if (res) leido(res.getText(), Z.BarcodeFormat[res.getBarcodeFormat()] || '');
                });
                if (activo !== yo) { try { yo.controls.stop(); } catch (e) {} return; }
            }
            msg.textContent = 'Apunta al código de barras. Cada producto entra solo a la factura.';
            var pista = null; try { pista = yo.stream.getVideoTracks()[0]; } catch (e) {}
            var conLuz = false; try { conLuz = !!(pista && pista.getCapabilities && pista.getCapabilities().torch); } catch (e) {}
            if (conLuz) {
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
    }
    // Deja listo el lector desde que abre la caja, para que la cámara arranque al instante
    function precargar() {
        var listo = function () { if (!NATIVO) cargarLib().catch(function () {}); };
        if ('BarcodeDetector' in window && window.BarcodeDetector.getSupportedFormats) {
            window.BarcodeDetector.getSupportedFormats().then(function (f) {
                var usa = NATIVO_FMT.filter(function (x) { return f.indexOf(x) >= 0; });
                if (usa.indexOf('ean_13') >= 0) NATIVO = new window.BarcodeDetector({ formats: usa });
            }).catch(function () {}).then(function () { setTimeout(listo, 1500); });
        } else setTimeout(listo, 1500);
    }
    function iniciar() { montar(); precargar(); }
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', iniciar); else iniciar();
    window.RefPosCamara = { abrir: abrir, cerrar: soltar };
})();
