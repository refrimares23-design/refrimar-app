/* ============================================================
 * REFRIMAR · Escanear y fotografiar (escaneo continuo con captura automática)
 * ------------------------------------------------------------
 * Abre la cámara y lee códigos de barra sin parar (@zxing/browser 0.1.5).
 * En cuanto lee un código:
 *   1. Toma la foto de ESE mismo momento (fotograma del <video> en un <canvas> oculto).
 *   2. Apaga el escáner (controls.stop()) y suelta la cámara.
 *   3. Busca el producto por el código:
 *        - Si existe → no crea nada nuevo: guarda la foto en ese producto
 *          (foto principal o reemplazar todas), con producto_imagenes_guardar.
 *        - Si no existe → ofrece crear el producto con la foto ya puesta
 *          (producto-form.html?barra=CODIGO).
 * Uso: botón con  data-escaner-foto  (se conecta solo) o RefEscanerFoto.abrir().
 * No toca carrito, precios, inventario ni sesión. No cambia la base de datos.
 * ============================================================ */
(function () {
    'use strict';
    var LIB_LOCAL = '/js/lib/zxing-browser-0.1.5.min.js';
    var LIB_CDN = 'https://cdn.jsdelivr.net/npm/@zxing/browser@0.1.5/umd/zxing-browser.min.js';
    var CLAVE_NUEVO = 'refrimar_foto_escaneo';   // foto para producto-form.html (producto nuevo)
    var MAX_LADO = 900, MAX_BYTES = 300000, MAX_FOTOS = 4;   // mismo formato que fotos.html / producto-form
    var EAN_UPC = { EAN_13: 1, EAN_8: 1, UPC_A: 1, UPC_E: 1 };   // traen dígito verificador: se aceptan a la primera

    var activo = null;   // { controls, video, caja } mientras la cámara está abierta

    function toast(m, t) { if (window.nk && nk.toast) nk.toast(m, t || 'info'); else alert(m); }
    function esc(s) { return window.nk && nk.esc ? nk.esc(s) : String(s == null ? '' : s).replace(/[&<>"']/g, function (c) { return '&#' + c.charCodeAt(0) + ';'; }); }
    function puedeEditar() { return typeof window.can !== 'function' || window.can('editar_inventario'); }

    // ---------- Librería ----------
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

    // ---------- Cámara ----------
    function css() {
        if (document.getElementById('ef-css')) return;
        var s = document.createElement('style'); s.id = 'ef-css';
        s.textContent =
            '.ef-wrap{position:fixed;inset:0;z-index:10000;background:rgba(10,37,64,.94);display:flex;flex-direction:column;align-items:center;justify-content:center;gap:12px;padding:16px}' +
            '.ef-cam{position:relative;width:min(92vw,520px);aspect-ratio:3/4;max-height:70vh;border-radius:22px;overflow:hidden;background:#000}' +
            '.ef-cam video{width:100%;height:100%;object-fit:cover;display:block}' +
            '.ef-guia{position:absolute;left:8%;right:8%;top:38%;height:24%;border:3px solid #00AAFF;border-radius:14px;box-shadow:0 0 0 2000px rgba(0,0,0,.22);transition:border-color .15s}' +
            '.ef-guia.ok{border-color:#22C55E}' +
            '.ef-flash{position:absolute;inset:0;background:#fff;opacity:0;pointer-events:none;transition:opacity .25s}' +
            '.ef-msg{color:#E6F6FF;font:500 15px Inter,system-ui,sans-serif;text-align:center;max-width:520px;min-height:22px}' +
            '.ef-bar{display:flex;gap:10px;flex-wrap:wrap;justify-content:center}' +
            '.ef-bt{height:48px;padding:0 24px;border-radius:999px;border:0;font:600 15px Poppins,sans-serif;cursor:pointer;display:inline-flex;align-items:center;gap:6px}' +
            '.ef-bt.pri{background:#00AAFF;color:#0A2540}.ef-bt.sec{background:rgba(255,255,255,.12);color:#fff}' +
            '.ef-prev{width:100%;max-height:300px;object-fit:contain;border-radius:16px;background:#F6F7F8;display:block;margin-bottom:12px}' +
            '.ef-cod{font-family:ui-monospace,monospace;background:#F1F4F7;border-radius:6px;padding:1px 6px}' +
            '.ef-acc{display:flex;flex-direction:column;gap:8px;margin-top:14px}.ef-acc .nk-btn{width:100%;justify-content:center}';
        document.head.appendChild(s);
    }

    function soltarCamara() {
        if (!activo) return;
        var a = activo; activo = null;
        try { if (a.controls) a.controls.stop(); } catch (e) {}
        // Por si acaso: apaga cualquier pista que quede viva y desconecta el video
        try { var st = a.video && a.video.srcObject; if (st && st.getTracks) st.getTracks().forEach(function (t) { t.stop(); }); } catch (e) {}
        try { if (a.video) { a.video.pause(); a.video.srcObject = null; } } catch (e) {}
        if (a.caja) a.caja.remove();
        document.removeEventListener('keydown', a.onKey);
        document.removeEventListener('visibilitychange', a.onHide);
        window.removeEventListener('pagehide', soltarCamara);
    }

    // Fotograma actual del video → JPEG en base64 (≤900 px, ≤300 KB), igual que las demás fotos
    function capturar(video) {
        var w = video.videoWidth, h = video.videoHeight;
        if (!w || !h) return null;
        var full = document.createElement('canvas');   // canvas oculto: nunca se agrega a la página
        full.width = w; full.height = h;
        full.getContext('2d').drawImage(video, 0, 0, w, h);
        var k = Math.min(1, MAX_LADO / Math.max(w, h)), cw = Math.round(w * k), ch = Math.round(h * k);
        var cv = document.createElement('canvas'); cv.width = cw; cv.height = ch;
        var cx = cv.getContext('2d');
        cx.imageSmoothingEnabled = true; cx.imageSmoothingQuality = 'high';
        cx.fillStyle = '#fff'; cx.fillRect(0, 0, cw, ch);
        cx.drawImage(full, 0, 0, cw, ch);
        full.width = full.height = 0;   // libera memoria
        var q = 0.85, data = cv.toDataURL('image/jpeg', q);
        while (data.length > MAX_BYTES && q > 0.45) { q -= 0.1; data = cv.toDataURL('image/jpeg', q); }
        return data;
    }

    async function abrir() {
        if (activo) return;
        if (!puedeEditar()) return toast('No tienes permiso para cambiar fotos de productos', 'warning');
        if (!(navigator.mediaDevices && navigator.mediaDevices.getUserMedia)) return toast('Este navegador no deja usar la cámara. Abre la página con https en Chrome o Safari.', 'warning');
        css();
        var caja = document.createElement('div'); caja.className = 'ef-wrap';
        caja.setAttribute('role', 'dialog'); caja.setAttribute('aria-label', 'Escanear y fotografiar');
        caja.innerHTML = '<div class="ef-cam"><video playsinline muted autoplay></video><div class="ef-guia"></div><div class="ef-flash"></div></div>' +
            '<div class="ef-msg" aria-live="polite">Abriendo la cámara…</div>' +
            '<div class="ef-bar"><button type="button" class="ef-bt sec" data-ef="luz" hidden><span class="material-symbols-outlined">flashlight_on</span>Linterna</button>' +
            '<button type="button" class="ef-bt pri" data-ef="cerrar">Cerrar</button></div>';
        document.body.appendChild(caja);
        var video = caja.querySelector('video'), msg = caja.querySelector('.ef-msg');
        activo = { controls: null, video: video, caja: caja,
            onKey: function (e) { if (e.key === 'Escape') soltarCamara(); },
            onHide: function () { if (document.hidden) soltarCamara(); } };
        var yo = activo;
        document.addEventListener('keydown', activo.onKey);
        document.addEventListener('visibilitychange', activo.onHide);   // si cambia de app, se apaga la cámara
        window.addEventListener('pagehide', soltarCamara);
        caja.querySelector('[data-ef="cerrar"]').addEventListener('click', soltarCamara);

        try { await cargarLib(); } catch (e) { msg.textContent = e.message; return; }
        if (activo !== yo) return;   // la cerró mientras cargaba

        var Z = window.ZXingBrowser, previo = '', listo = false;
        var lector = new Z.BrowserMultiFormatReader(undefined, { delayBetweenScanAttempts: 120, delayBetweenScanSuccess: 120 });
        var restr = { audio: false, video: { facingMode: { ideal: 'environment' }, width: { ideal: 1920 }, height: { ideal: 1080 } } };
        try {
            yo.controls = await lector.decodeFromConstraints(restr, video, function (res, err, controls) {
                if (!res || listo || activo !== yo) return;
                var cod = String(res.getText() || '').trim();
                var fmt = Z.BarcodeFormat[res.getBarcodeFormat()] || '';
                if (!cod) return;
                // Códigos sin dígito verificador (CODE 128, 39, ITF…): deben leerse igual 2 veces seguidas
                if (!EAN_UPC[fmt] && cod !== previo) { previo = cod; return; }
                listo = true;
                var foto = capturar(video);           // 1) foto del momento exacto de la lectura
                var fl = caja.querySelector('.ef-flash'); fl.style.opacity = '.85';
                caja.querySelector('.ef-guia').classList.add('ok');
                if (navigator.vibrate) navigator.vibrate(60);
                try { controls.stop(); } catch (e) {}  // 2) detener escáner
                soltarCamara();                         //    y soltar la cámara
                if (!foto) return toast('Se leyó ' + cod + ' pero no se pudo tomar la foto. Intenta otra vez.', 'warning');
                resolver(cod, foto);                    // 3) unir la foto con el producto
            });
            if (activo !== yo) { try { yo.controls.stop(); } catch (e) {} return; }
            msg.textContent = 'Apunta al código de barras. La foto se toma sola al leerlo.';
            var pista = null; try { pista = video.srcObject.getVideoTracks()[0]; } catch (e) {}
            var conLuz = false; try { conLuz = !!(pista && pista.getCapabilities && pista.getCapabilities().torch); } catch (e) {}
            if (conLuz && yo.controls && typeof yo.controls.switchTorch === 'function') {
                var luz = caja.querySelector('[data-ef="luz"]'), on = false; luz.hidden = false;
                luz.addEventListener('click', function () { on = !on; yo.controls.switchTorch(on).catch(function () { luz.hidden = true; }); });
            }
        } catch (e) {
            var n = e && e.name;
            msg.textContent = n === 'NotAllowedError' ? 'No hay permiso para la cámara. Actívalo en el candado de la barra de direcciones.'
                : n === 'NotFoundError' || n === 'OverconstrainedError' ? 'No se encontró una cámara en este equipo.'
                : n === 'NotReadableError' ? 'La cámara está ocupada por otra aplicación. Ciérrala e intenta otra vez.'
                : 'No se pudo abrir la cámara: ' + ((e && e.message) || e);
            try { var st = video.srcObject; if (st) st.getTracks().forEach(function (t) { t.stop(); }); video.srcObject = null; } catch (x) {}
        }
    }

    // ---------- Producto ----------
    function variantes(c) {
        var v = [c];
        if (/^\d{12}$/.test(c)) v.push('0' + c);            // UPC-A leído como 12 dígitos
        if (/^0\d{12}$/.test(c)) v.push(c.slice(1));         // EAN-13 con 0 delante
        return v;
    }
    async function buscarProducto(cod) {
        var vs = variantes(cod);
        var r = await supabaseClient.from('productos').select('codigo,descripcion').in('codigo', vs).limit(1);
        if (r.error) throw r.error;
        if (r.data && r.data.length) return r.data[0];
        for (var i = 0; i < vs.length; i++) {   // códigos alternos (otra barra del mismo producto)
            var a = await supabaseClient.from('productos').select('codigo,descripcion').contains('codigos_alternos', [vs[i]]).limit(1);
            if (!a.error && a.data && a.data.length) return a.data[0];
        }
        return null;
    }
    async function fotosDe(codigo) {
        var r = await supabaseClient.from('producto_imagenes').select('imagenes').eq('producto_codigo', codigo).maybeSingle();
        return (r && !r.error && r.data && Array.isArray(r.data.imagenes)) ? r.data.imagenes : [];
    }

    function modal(title, body, footer) {
        return nk.modal({ title: title, body: body, footer: footer || '' });
    }

    async function resolver(cod, foto) {
        var cargando = modal('Código ' + cod, '<img class="ef-prev" src="' + foto + '" alt="Foto tomada"/><p class="nk-hint">Buscando el producto…</p>');
        var prod, fotos = [];
        try { prod = await buscarProducto(cod); if (prod) fotos = await fotosDe(prod.codigo); }
        catch (e) { cargando.close(); return toast(window.nk && nk.errMsg ? nk.errMsg(e) : String(e), 'error'); }
        cargando.close();
        if (prod) existente(prod, fotos, foto); else nuevo(cod, foto);
    }

    function existente(prod, fotos, foto) {
        var n = fotos.length;
        var acc = n
            ? '<button type="button" class="nk-btn" data-x="principal"><span class="material-symbols-outlined">star</span>Usar como foto principal' + (n >= MAX_FOTOS ? ' (reemplaza la última)' : '') + '</button>' +
              '<button type="button" class="nk-btn nk-btn-outline" data-x="reemplazar"><span class="material-symbols-outlined">swap_horiz</span>Reemplazar ' + (n === 1 ? 'la foto que tiene' : 'sus ' + n + ' fotos') + '</button>'
            : '<button type="button" class="nk-btn" data-x="principal"><span class="material-symbols-outlined">save</span>Guardar foto</button>';
        acc += '<button type="button" class="nk-btn nk-btn-ghost" data-x="otra"><span class="material-symbols-outlined">photo_camera</span>Tomar la foto otra vez</button>';
        var m = modal('Producto encontrado',
            '<img class="ef-prev" src="' + foto + '" alt="Foto tomada"/>' +
            '<b style="font-weight:600">' + esc(prod.descripcion || '') + '</b><br><small style="color:#71717A">' + esc(prod.codigo) + ' · ' + (n ? 'ya tiene ' + n + ' foto(s)' : 'sin foto') + '</small>' +
            '<p class="nk-hint" style="margin-top:8px">Ya existe: no se crea otro producto, solo se cambia la foto.</p>' +
            '<div class="ef-acc">' + acc + '</div>');
        m.$('[data-x="otra"]').addEventListener('click', function () { m.close(); abrir(); });
        m.el.querySelectorAll('[data-x="principal"],[data-x="reemplazar"]').forEach(function (b) {
            b.addEventListener('click', function () {
                nk.busy(b, async function () {
                    var imgs = b.dataset.x === 'reemplazar' ? [foto] : [foto].concat(fotos.filter(function (x) { return x !== foto; })).slice(0, MAX_FOTOS);
                    var r = await supabaseClient.rpc('producto_imagenes_guardar', { p_codigo: prod.codigo, p_imagenes: imgs });
                    if (r.error) return toast(nk.errMsg(r.error), 'error');
                    m.close();
                    listoGuardado(prod);
                });
            });
        });
    }

    function listoGuardado(prod) {
        var m = modal('Foto guardada',
            '<p><b style="font-weight:600">' + esc(prod.descripcion || prod.codigo) + '</b> ya tiene su foto nueva.</p>' +
            '<div class="ef-acc"><button type="button" class="nk-btn" data-x="sig"><span class="material-symbols-outlined">qr_code_scanner</span>Escanear el siguiente</button>' +
            '<button type="button" class="nk-btn nk-btn-ghost" data-x="fin">Terminar</button></div>');
        m.$('[data-x="sig"]').addEventListener('click', function () { m.close(); abrir(); });
        m.$('[data-x="fin"]').addEventListener('click', function () { m.close(); });
        setTimeout(function () { var b = m.$('[data-x="sig"]'); if (b) b.focus(); }, 30);
        try { document.dispatchEvent(new CustomEvent('refrimar:foto-guardada', { detail: { codigo: prod.codigo } })); } catch (e) {}
    }

    function nuevo(cod, foto) {
        var m = modal('Código no registrado',
            '<img class="ef-prev" src="' + foto + '" alt="Foto tomada"/>' +
            '<p>No hay ningún producto con el código <span class="ef-cod">' + esc(cod) + '</span>.</p>' +
            '<div class="ef-acc"><button type="button" class="nk-btn" data-x="crear"><span class="material-symbols-outlined">add</span>Crear producto con esta foto</button>' +
            '<button type="button" class="nk-btn nk-btn-ghost" data-x="otra"><span class="material-symbols-outlined">qr_code_scanner</span>Escanear otro</button></div>');
        m.$('[data-x="otra"]').addEventListener('click', function () { m.close(); abrir(); });
        m.$('[data-x="crear"]').addEventListener('click', function () {
            try { sessionStorage.setItem(CLAVE_NUEVO, JSON.stringify({ barra: cod, img: foto, t: Date.now() })); }
            catch (e) { return toast('No se pudo pasar la foto al formulario (memoria llena). Crea el producto y súbela ahí.', 'warning'); }
            location.href = 'producto-form.html?barra=' + encodeURIComponent(cod);
        });
    }

    // Para producto-form.html: devuelve la foto escaneada para ese código (una sola vez)
    function tomarFotoPendiente(barra) {
        try {
            var raw = sessionStorage.getItem(CLAVE_NUEVO); if (!raw) return null;
            sessionStorage.removeItem(CLAVE_NUEVO);
            var o = JSON.parse(raw);
            if (!o || o.barra !== barra || Date.now() - o.t > 30 * 60000 || !/^data:image\//.test(o.img || '')) return null;
            return o.img;
        } catch (e) { return null; }
    }

    function conectar() {
        document.querySelectorAll('[data-escaner-foto]').forEach(function (b) {
            if (b.dataset.efOk) return; b.dataset.efOk = '1';
            b.addEventListener('click', function (e) { e.preventDefault(); abrir(); });
        });
    }
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', conectar); else conectar();

    window.RefEscanerFoto = { abrir: abrir, cerrar: soltarCamara, tomarFotoPendiente: tomarFotoPendiente };
})();
