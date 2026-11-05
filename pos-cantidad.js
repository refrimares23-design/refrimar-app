/* ============================================================
 * REFRIMAR POS · Cantidad por metro / por kilo (cables, mallas, granel)
 * ------------------------------------------------------------
 * refPedirCantidad(producto, actual) → Promise<number|null>
 *   Ventana rápida para escribir 0,5 m · 1,2 m · 0,25 kg…
 *   - Botones de un toque (0,10 · 0,25 · 0,5 · 1 · 1,5 · 2 …): agregan al instante.
 *   - Teclado numérico grande (sirve en pantalla táctil) o el teclado de la PC.
 *   - Acepta coma o punto. También "250g" (kilo) o "30cm" (metro).
 *   - Muestra el total mientras se escribe y avisa si no alcanza el stock.
 * En la factura, tocar la cantidad de una línea por metro/kilo abre esta misma ventana.
 * No cambia precios: el total es precio unitario × cantidad, sin redondear la cantidad a entero.
 * ============================================================ */
(function () {
    'use strict';
    var RAPIDAS = { mt: [0.1, 0.25, 0.5, 1, 1.5, 2, 3, 5, 10], kg: [0.1, 0.2, 0.25, 0.5, 1, 2, 3, 5, 10] };
    var NOMBRE = { mt: { corto: 'm', largo: 'metros', uno: 'metro' }, kg: { corto: 'kg', largo: 'kilos', uno: 'kilo' } };

    function $(id) { return document.getElementById(id); }
    function P() { return window.__POS || null; }
    function esc(s) { return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); }
    function fmt(n) { return (Number(n) || 0).toLocaleString('es-VE', { maximumFractionDigits: 3 }); }
    function r3(n) { return Math.round((Number(n) || 0) * 1000) / 1000; }

    // "0,5" "0.5" "1,25" "250g" "30cm" → número en la unidad del producto (o NaN)
    function leer(txt, uni) {
        var t = String(txt || '').trim().toLowerCase().replace(/\s+/g, '');
        if (!t) return NaN;
        var div = 1;
        if (uni === 'kg' && /^[\d.,]+(g|gr|grs|gramos?)$/.test(t)) { div = 1000; t = t.replace(/[a-z]+$/, ''); }
        else if (uni === 'mt' && /^[\d.,]+(cm|cms)$/.test(t)) { div = 100; t = t.replace(/[a-z]+$/, ''); }
        else t = t.replace(/(kg|kgs|kilos?|m|mts?|metros?)$/, '');
        if (!/^\d*[.,]?\d*$/.test(t) || t === '.' || t === ',') return NaN;
        var n = Number(t.replace(',', '.'));
        return isFinite(n) ? n / div : NaN;
    }

    function css() {
        if ($('pq-css')) return;
        var s = document.createElement('style'); s.id = 'pq-css';
        s.textContent =
            '.pq-ov{position:fixed;inset:0;z-index:10100;background:rgba(10,37,64,.55);display:flex;align-items:center;justify-content:center;padding:14px;animation:pqIn .12s ease-out}' +
            '@keyframes pqIn{from{opacity:0}to{opacity:1}}' +
            '.pq{width:min(460px,100%);max-height:calc(100vh - 28px);overflow:auto;background:#fff;border-radius:26px;padding:18px 18px 16px;box-shadow:0 30px 80px -20px rgba(10,37,64,.55);font-family:Inter,Roboto,system-ui,sans-serif;color:#0B1220}' +
            '.pq-top{display:flex;gap:10px;align-items:flex-start;justify-content:space-between}' +
            '.pq-top b{font:600 18px/1.25 Poppins,sans-serif;display:block}' +
            '.pq-top small{display:block;color:#52525B;font-size:14px;margin-top:3px}' +
            '.pq-x{width:38px;height:38px;flex:none;border-radius:999px;border:0;background:#F4F4F5;font-size:20px;cursor:pointer;color:#3F3F46}' +
            '.pq-in{display:flex;align-items:center;gap:8px;margin:14px 0 6px;border:2px solid var(--az,#00AAFF);border-radius:20px;padding:6px 16px;background:#F7FCFF}' +
            '.pq-in input{flex:1;min-width:0;border:0;background:transparent;outline:none;font:700 40px/1.1 Poppins,sans-serif;color:#0B1220;padding:4px 0}' +
            '.pq-in span{font:600 22px Poppins,sans-serif;color:#52525B}' +
            '.pq-tot{display:flex;justify-content:space-between;align-items:baseline;gap:10px;font-size:15px;color:#52525B;min-height:28px}' +
            '.pq-tot b{font:700 22px Poppins,sans-serif;color:#0B1220}.pq-tot.mal b,.pq-tot.mal{color:#B91C1C}' +
            '.pq-ayuda{font-size:13px;color:#71717A;margin:2px 0 10px}' +
            '.pq-rap{display:grid;grid-template-columns:repeat(5,1fr);gap:8px;margin-bottom:12px}' +
            '.pq-rap button{height:48px;border-radius:14px;border:1px solid #D5DCE3;background:#fff;font:600 16px Poppins,sans-serif;color:#0B1220;cursor:pointer}' +
            '.pq-rap button:hover,.pq-rap button:focus-visible{border-color:var(--az,#00AAFF);background:var(--az-s,#E6F6FF);outline:0}' +
            '.pq-rap button[disabled]{opacity:.35;cursor:not-allowed}' +
            '.pq-pad{display:grid;grid-template-columns:repeat(3,1fr);gap:8px;margin-bottom:12px}' +
            '.pq-pad button{height:54px;border-radius:16px;border:0;background:#F4F4F5;font:600 22px Poppins,sans-serif;color:#0B1220;cursor:pointer}' +
            '.pq-pad button:active{background:var(--az-s,#E6F6FF)}' +
            '.pq-ok{width:100%;height:56px;border-radius:999px;border:0;background:var(--az,#00AAFF);color:#0A2540;font:700 18px Poppins,sans-serif;cursor:pointer}' +
            '.pq-ok[disabled]{opacity:.45;cursor:not-allowed}' +
            '@media (pointer:fine) and (min-height:700px){.pq-pad{display:none}}';   // en la PC se escribe con el teclado
        document.head.appendChild(s);
    }

    function pedir(p, actual, opc) {
        opc = opc || {};
        return new Promise(function (listo) {
            var pos = P(); css();
            var uni = p.unidad === 'kg' ? 'kg' : 'mt', N = NOMBRE[uni];
            var pu = pos && pos.precioFinal ? pos.precioFinal(p) : Number(p.precio) || 0;
            var tasa = pos && pos.S ? pos.S.tasa : 0, H = pos && pos.h;
            var bs = function (v) { return H && H.bs ? H.bs(v) : fmt(v) + ' Bs'; }, usd = function (v) { return H && H.usd ? H.usd(v) : fmt(v) + ' $'; };
            var stock = p.servicio ? Infinity : Number(opc.stock != null ? opc.stock : p.stock);
            var ov = document.createElement('div'); ov.className = 'pq-ov';
            ov.setAttribute('role', 'dialog'); ov.setAttribute('aria-modal', 'true'); ov.setAttribute('aria-label', 'Cantidad en ' + N.largo);
            ov.innerHTML = '<div class="pq">' +
                '<div class="pq-top"><div><b>' + esc(p.descripcion) + '</b><small>Se vende por ' + N.uno + ' · ' + bs(pu * tasa) + ' / ' + N.corto + ' (' + usd(pu) + ')' + (isFinite(stock) ? ' · hay ' + fmt(stock) + ' ' + N.corto : '') + '</small></div>' +
                '<button type="button" class="pq-x" aria-label="Cancelar">✕</button></div>' +
                '<label class="pq-in"><input inputmode="decimal" autocomplete="off" aria-label="Cantidad en ' + N.largo + '" placeholder="0,5"/><span>' + N.corto + '</span></label>' +
                '<div class="pq-tot"><span>Total</span><b>—</b></div>' +
                '<div class="pq-ayuda">' + (uni === 'kg' ? 'Ej.: 0,5 = medio kilo · 0,25 = 250 g · también puedes escribir 250g' : 'Ej.: 0,5 = medio metro · 1,2 = 1 metro y 20 cm · también puedes escribir 30cm') + '</div>' +
                '<div class="pq-rap">' + RAPIDAS[uni].map(function (v) { return '<button type="button" data-v="' + v + '"' + (v > stock + 1e-9 ? ' disabled' : '') + '>' + fmt(v) + '</button>'; }).join('') + '</div>' +
                '<div class="pq-pad">' + ['7', '8', '9', '4', '5', '6', '1', '2', '3', ',', '0', '⌫'].map(function (k) { return '<button type="button" data-k="' + k + '">' + k + '</button>'; }).join('') + '</div>' +
                '<button type="button" class="pq-ok" disabled>' + (opc.editar ? 'Guardar cantidad' : 'Agregar a la factura') + '</button></div>';
            document.body.appendChild(ov);
            var inp = ov.querySelector('input'), ok = ov.querySelector('.pq-ok'), tot = ov.querySelector('.pq-tot');
            if (actual > 0) inp.value = String(fmt(actual)).replace(/\./g, '');
            function valor() { return leer(inp.value, uni); }
            function pintar() {
                var q = valor(), b = tot.querySelector('b');
                if (!(q > 0)) { b.textContent = '—'; tot.className = 'pq-tot'; ok.disabled = true; return; }
                if (q > stock + 1e-9) { b.textContent = 'Solo hay ' + fmt(stock) + ' ' + N.corto; tot.className = 'pq-tot mal'; ok.disabled = true; return; }
                b.textContent = bs(pu * q * tasa) + ' · ' + usd(pu * q); tot.className = 'pq-tot'; ok.disabled = false;
            }
            var cerrado = false;
            function cerrar(v) {
                if (cerrado) return; cerrado = true;
                document.removeEventListener('keydown', teclas, true); ov.remove();
                var b = $('f-buscar'); if (b && window.matchMedia('(pointer:fine)').matches) setTimeout(function () { b.focus(); }, 0);
                listo(v == null ? null : r3(v));
            }
            function confirmar() { var q = valor(); if (q > 0 && q <= stock + 1e-9) cerrar(q); else pintar(); }
            function teclas(e) {
                if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); cerrar(null); }
                else if (e.key === 'Enter') { e.preventDefault(); e.stopPropagation(); confirmar(); }
                else e.stopPropagation();   // no dispara atajos de la caja mientras se escribe
            }
            document.addEventListener('keydown', teclas, true);
            inp.addEventListener('input', pintar);
            ok.addEventListener('click', confirmar);
            ov.querySelector('.pq-x').addEventListener('click', function () { cerrar(null); });
            ov.addEventListener('mousedown', function (e) { if (e.target === ov) cerrar(null); });
            ov.querySelector('.pq-rap').addEventListener('click', function (e) { var b = e.target.closest('[data-v]'); if (b && !b.disabled) cerrar(Number(b.dataset.v)); });
            ov.querySelector('.pq-pad').addEventListener('click', function (e) {
                var b = e.target.closest('[data-k]'); if (!b) return;
                var k = b.dataset.k;
                if (k === '⌫') inp.value = inp.value.slice(0, -1);
                else if (k === ',') { if (!/[.,]/.test(inp.value)) inp.value = (inp.value || '0') + ','; }
                else inp.value += k;
                pintar();
            });
            pintar();
            inp.focus(); inp.select();   // listo para escribir al instante
            setTimeout(function () { if (document.activeElement !== inp) { inp.focus(); inp.select(); } }, 30);
        });
    }
    window.refPedirCantidad = pedir;

    // En la factura: tocar la cantidad de una línea por metro/kilo abre la misma ventana
    function enganchar() {
        var c = $('f-carro'); if (!c || c.dataset.pq) return;
        c.dataset.pq = '1';
        function abrir(e) {
            var inp = e.target.closest && e.target.closest('input[data-a="cant"]'); if (!inp) return;
            var pos = P(); if (!pos) return;
            var li = inp.closest('.li'), it = li && pos.S.carro[Number(li.dataset.k)];
            if (!it || it.unidad === 'uds') return;
            e.preventDefault(); inp.blur();
            pedir(it, it.cantidad, { editar: true, stock: it.stock }).then(function (q) {
                if (q === null || !inp.isConnected) return;
                inp.value = String(q);
                inp.dispatchEvent(new Event('change', { bubbles: true }));   // la caja hace el resto (stock, totales)
            });
        }
        c.addEventListener('mousedown', abrir);
        c.addEventListener('touchstart', function (e) { if (e.target.closest && e.target.closest('input[data-a="cant"]')) abrir(e); }, { passive: false });
        c.addEventListener('focusin', function (e) { if (e.target.matches && e.target.matches('input[data-a="cant"]') && !e.target.dataset.pqSkip) abrir(e); });
    }
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', enganchar); else enganchar();
})();
