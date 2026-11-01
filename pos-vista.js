/* ============================================================
 * REFRIMAR POS · Vista tipo supermercado
 * ------------------------------------------------------------
 * 1. "Último producto": al escanear o agregar algo, sale en grande arriba
 *    (foto, nombre, precio, cantidad y total de esa línea).
 * 2. Factura más grande y clara: cada línea con su foto, letra más grande,
 *    botones − / + más cómodos, y la línea recién agregada resaltada.
 * Solo dibuja: lee S.carro de pos-app.js cuando la factura se vuelve a pintar
 * (MutationObserver). No cambia precios, stock, cobro ni nada de la lógica.
 * ============================================================ */
(function () {
    'use strict';
    var FOTOS = {}, PIDIENDO = {}, ANTES = {}, ULTIMO = null, tPop = null;

    function $(id) { return document.getElementById(id); }
    function P() { return window.__POS || null; }
    function esc(s) { return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); }
    function iniciales(n) { return String(n || '?').replace(/[^A-Za-zÁÉÍÓÚÑáéíóúñ0-9 ]/g, ' ').trim().split(/\s+/).slice(0, 2).map(function (x) { return x.charAt(0); }).join('').toUpperCase() || '?'; }

    // ---------- Fotos (usa las que la caja ya cargó; si no, la pide una vez) ----------
    function fotoYa(c) { var p = P(); return FOTOS[c] || (p && p.S.imgs && p.S.imgs[c]) || null; }
    function pedirFoto(c, alLlegar) {
        var ya = fotoYa(c); if (ya) return alLlegar(ya);
        if (FOTOS[c] === false) return;
        (PIDIENDO[c] = PIDIENDO[c] || []).push(alLlegar);
        if (PIDIENDO[c].length > 1 || !window.supabaseClient) return;
        supabaseClient.from('producto_imagenes').select('img:imagenes->>0').eq('producto_codigo', c).maybeSingle().then(function (r) {
            var img = r && !r.error && r.data && r.data.img ? r.data.img : null;
            FOTOS[c] = img || false;
            var fs = PIDIENDO[c] || []; delete PIDIENDO[c];
            if (img) fs.forEach(function (f) { try { f(img); } catch (e) {} });
        }, function () { delete PIDIENDO[c]; });
    }
    function cajaFoto(item, cls) {
        var f = fotoYa(item.codigo);
        return '<div class="' + cls + '" data-foto="' + esc(item.codigo) + '">' + (f ? '<img src="' + esc(f) + '" alt=""/>' : '<span>' + esc(iniciales(item.descripcion)) + '</span>') + '</div>';
    }
    function ponerFotos(raiz) {
        raiz.querySelectorAll('[data-foto]').forEach(function (d) {
            if (d.querySelector('img')) return;
            pedirFoto(d.dataset.foto, function (img) { if (d.isConnected) d.innerHTML = '<img src="' + esc(img) + '" alt=""/>'; });
        });
    }

    function css() {
        if ($('pv-css')) return;
        var s = document.createElement('style'); s.id = 'pv-css';
        s.textContent =
            // ----- Último producto -----
            '.pv-hero{display:grid;grid-template-columns:168px minmax(0,1fr);gap:20px;align-items:center;background:#fff;border-radius:26px;padding:16px 22px 16px 16px;margin:0 0 14px;box-shadow:0 0 0 1px rgba(10,37,64,.06),0 10px 30px -18px rgba(10,37,64,.35)}' +
            '.pv-hero[hidden]{display:none}' +
            '.pv-hero.pv-pop{animation:pvPop .35s ease-out}' +
            '@keyframes pvPop{0%{transform:scale(.97);box-shadow:0 0 0 3px var(--az,#00AAFF)}60%{transform:scale(1.01)}100%{transform:none}}' +
            '.pv-foto{width:168px;height:168px;border-radius:20px;background:linear-gradient(135deg,#F3F9FD,#E6F6FF);display:flex;align-items:center;justify-content:center;overflow:hidden}' +
            '.pv-foto img{width:100%;height:100%;object-fit:contain;background:#fff}' +
            '.pv-foto span{font-family:Poppins,sans-serif;font-size:46px;font-weight:700;color:#8FCFF0}' +
            '.pv-et{display:inline-flex;align-items:center;gap:6px;font-size:13px;font-weight:600;color:var(--ok,#16A34A);background:var(--ok-s,#E8F8EE);border-radius:999px;padding:4px 12px;margin-bottom:8px}' +
            '.pv-et .material-symbols-outlined{font-size:16px}' +
            '.pv-nom{font-family:Poppins,sans-serif;font-size:26px;line-height:1.2;font-weight:600;color:#0B1220;letter-spacing:-.01em;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden}' +
            '.pv-cod{font-size:14px;color:var(--tx3,#71717A);margin-top:4px}' +
            '.pv-fila{display:flex;align-items:flex-end;justify-content:space-between;gap:16px;margin-top:12px;flex-wrap:wrap}' +
            '.pv-pu{font-size:15px;color:var(--tx2,#52525B)}.pv-pu b{display:block;font-family:Poppins,sans-serif;font-size:30px;font-weight:700;color:#0B1220;letter-spacing:-.02em;line-height:1.1}' +
            '.pv-pu small{font-size:14px;color:var(--tx3,#71717A)}' +
            '.pv-tl{text-align:right;font-size:15px;color:var(--tx2,#52525B)}.pv-tl b{display:block;font-family:Poppins,sans-serif;font-size:22px;font-weight:600;color:var(--az-t,#0090D9)}' +
            // ----- Factura más grande -----
            '@media (min-width:1300px){.fac{grid-template-columns:minmax(0,1fr) 470px}}' +
            '.carro{padding:12px 16px}' +
            '.li{grid-template-columns:64px minmax(0,1fr) auto;gap:6px 12px;padding:12px;border-radius:20px;margin-bottom:10px;align-items:center;transition:background .3s,border-color .3s}' +
            '.li .pv-th{grid-row:span 2;width:64px;height:64px;border-radius:14px;background:linear-gradient(135deg,#F3F9FD,#E6F6FF);display:flex;align-items:center;justify-content:center;overflow:hidden;align-self:start}' +
            '.li .pv-th img{width:100%;height:100%;object-fit:contain;background:#fff}' +
            '.li .pv-th span{font-family:Poppins,sans-serif;font-size:18px;font-weight:700;color:#8FCFF0}' +
            '.li .ln{font-size:16px;font-weight:500;color:#18181B;line-height:1.3}' +
            '.li .ln .sub{font-size:13px;font-weight:400;margin-top:2px}' +
            '.li .lp{font-family:Poppins,sans-serif;font-size:18px;font-weight:700;color:#0B1220}' +
            '.li .lp small{font-family:Inter,system-ui,sans-serif;font-size:13px}' +
            '.li .lc button{width:38px;height:38px;font-size:20px}' +
            '.li .lc input{width:66px;height:38px;font-size:16px;font-weight:600}' +
            '.li .lx button{width:38px;height:38px}' +
            '.li.pv-nuevo{border-color:var(--az,#00AAFF);background:var(--az-s,#E6F6FF)}' +
            '.fd-pie .fl.tot b{font-size:30px}' +
            // ----- Detalles que se veían raros -----
            '*{scrollbar-width:thin;scrollbar-color:rgba(10,37,64,.22) transparent}' +           // sin barras grises con flechitas (Windows)
            '.cli-in select{gap:8px;padding:0 12px 0 16px}' +
            '.carro .ref-estado{padding:8px 6px}.carro .ref-estado img{width:92px}.carro .ref-estado b{font-size:16px}' +   // "Factura vacía" entra completo
            '.pc .img:has(img){background:#fff}.pc .img img{width:100%;height:100%;object-fit:contain}' +                   // foto sin franja azul al lado
            // ----- Pantallas bajas (laptop o zoom de Windows): la factura es lo primero que se tiene que ver -----
            '@media (min-width:761px) and (max-height:820px){' +
                '.pv-hero{grid-template-columns:112px minmax(0,1fr);gap:16px;padding:10px 18px 10px 10px;margin-bottom:10px;border-radius:22px}' +
                '.pv-foto{width:112px;height:112px;border-radius:16px}.pv-foto span{font-size:32px}' +
                '.pv-et{font-size:12px;padding:2px 10px;margin-bottom:4px}.pv-nom{font-size:21px;-webkit-line-clamp:1}.pv-cod{font-size:13px;margin-top:2px}' +
                '.pv-fila{margin-top:6px}.pv-pu b{font-size:25px}.pv-tl b{font-size:19px}' +
                '.cli{margin-top:8px;padding:8px 12px}.cli>b{font-size:14px;margin-bottom:6px}.cli-in{height:42px}.cli-info{margin-top:5px}' +
                '.fd-top{padding-top:10px}.carro{padding:8px 14px}' +
                '.li{grid-template-columns:52px minmax(0,1fr) auto;padding:9px 10px;margin-bottom:8px;gap:4px 10px}.li .pv-th{width:52px;height:52px}' +
                '.li .ln{font-size:15px}.li .lp{font-size:17px}.li .lc button,.li .lx button{width:34px;height:34px}.li .lc input{height:34px;width:60px}' +
                '.fd-pie{padding:10px 18px 14px}.fd-pie .fl{margin-bottom:3px}.fd-pie .fl.tot b{font-size:26px}.fd-pie .btn.xl{height:50px}' +
            '}' +
            '@media (max-width:760px){.pv-hero{grid-template-columns:96px minmax(0,1fr);gap:14px;padding:12px}.pv-foto{width:96px;height:96px;border-radius:16px}.pv-foto span{font-size:30px}.pv-nom{font-size:19px}.pv-pu b{font-size:23px}.pv-tl b{font-size:18px}' +
            '.li{grid-template-columns:52px minmax(0,1fr) auto}.li .pv-th{width:52px;height:52px}}';
        document.head.appendChild(s);
    }

    // ---------- Último producto ----------
    function montarHero() {
        if ($('pv-hero')) return $('pv-hero');
        var busca = document.querySelector('#v-factura .busca'); if (!busca) return null;
        var h = document.createElement('div'); h.id = 'pv-hero'; h.className = 'pv-hero'; h.hidden = true;
        h.setAttribute('aria-live', 'polite');
        busca.parentNode.insertBefore(h, busca.nextSibling);
        return h;
    }
    function pintarHero(item, nuevo) {
        var h = montarHero(), p = P(); if (!h || !p) return;
        if (!item) { h.hidden = true; ULTIMO = null; return; }
        var H = p.h, S = p.S, pu = p.precioFinal(item) * (1 - (item.descuento || 0) / 100), lt = p.lineaTotal(item);
        h.innerHTML = cajaFoto(item, 'pv-foto') +
            '<div style="min-width:0"><div class="pv-et"><span class="material-symbols-outlined">check_circle</span>' + (nuevo ? 'Agregado' : 'Último producto') + '</div>' +
            '<div class="pv-nom">' + esc(item.descripcion) + '</div><div class="pv-cod">' + esc(item.codigo) + '</div>' +
            '<div class="pv-fila"><div class="pv-pu">Precio<b>' + H.bs(pu * S.tasa) + '</b><small>' + H.usd(pu) + ' c/u</small></div>' +
            '<div class="pv-tl">' + H.cant(item.cantidad) + ' ' + esc(item.unidad || '') + ' en la factura<b>' + H.bs(lt * S.tasa) + '</b></div></div></div>';
        h.hidden = false;
        ponerFotos(h);
        if (nuevo) { h.classList.remove('pv-pop'); void h.offsetWidth; h.classList.add('pv-pop'); }
    }

    // ---------- Cada vez que la caja vuelve a pintar la factura ----------
    function alPintar() {
        var p = P(), c = $('f-carro'); if (!p || !c) return;
        var carro = p.S.carro || [], ahora = {}, cambiado = null;
        carro.forEach(function (i, k) {
            ahora[i.codigo] = Number(i.cantidad) || 0;
            if (ahora[i.codigo] > (ANTES[i.codigo] || 0)) cambiado = k;   // nuevo o con más cantidad
        });
        var habiaAlgo = Object.keys(ANTES).length > 0 || ULTIMO !== null;
        ANTES = ahora;
        // Fotos en cada línea
        c.querySelectorAll('.li').forEach(function (li) {
            var it = carro[Number(li.dataset.k)]; if (!it || li.querySelector('.pv-th')) return;
            li.insertAdjacentHTML('afterbegin', cajaFoto(it, 'pv-th'));
        });
        ponerFotos(c);
        if (!carro.length) { pintarHero(null); return; }
        if (cambiado !== null && (habiaAlgo || carro.length)) {
            ULTIMO = carro[cambiado].codigo;
            var li = c.querySelector('.li[data-k="' + cambiado + '"]');
            if (li) {
                li.classList.add('pv-nuevo');
                li.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
                clearTimeout(tPop); tPop = setTimeout(function () { var x = c.querySelector('.pv-nuevo'); if (x) x.classList.remove('pv-nuevo'); }, 1600);
            }
            pintarHero(carro[cambiado], true);
            return;
        }
        // Sin producto nuevo (bajó cantidad, se quitó, descuento…): refresca el último o muestra el final
        var u = carro.find(function (i) { return i.codigo === ULTIMO; }) || carro[carro.length - 1];
        ULTIMO = u.codigo; pintarHero(u, false);
    }

    function iniciar() {
        var c = $('f-carro'); if (!c) return;
        css(); montarHero();
        // Lo que ya estaba en la factura al abrir la caja no cuenta como "recién agregado"
        var p = P(); if (p) (p.S.carro || []).forEach(function (i) { ANTES[i.codigo] = Number(i.cantidad) || 0; });
        new MutationObserver(alPintar).observe(c, { childList: true });
        alPintar();
    }
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', iniciar); else iniciar();
    window.RefPosVista = { foto: pedirFoto, fotoYa: fotoYa };
})();
