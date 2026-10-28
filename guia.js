// ============================================================
// REFRIMAR — Guía de bienvenida para colaboradores nuevos
// ------------------------------------------------------------
// La primera vez que un colaborador NUEVO entra (aceptó su invitación hace
// menos de 21 días) se oscurece la pantalla y se resalta, paso a paso, lo
// esencial de la página: menú, tienda, punto de venta, productos, cerrar sesión…
// • Sale una sola vez por usuario y por página (dashboard / punto de venta).
// • Se puede volver a ver: Perfil → "Ver la guía otra vez", el menú del
//   usuario en el punto de venta, o abriendo la página con ?guia=1
// • Solo se muestran los pasos que esa persona puede ver según su rol.
// ============================================================
(function () {
    'use strict';
    var PAG = (location.pathname.split('/').pop() || 'index.html').toLowerCase();
    var DIAS_NUEVO = 21;
    var CLAVE = 'refrimar_guia_';

    var PASOS = {
        'dashboard.html': [
            { t: '¡Bienvenido/a a REFRIMAR!', d: 'Te mostramos lo más importante en menos de un minuto. Puedes saltar la guía cuando quieras.' },
            { sel: '#sidebar nav', menu: true, t: 'El menú', d: 'Aquí está todo el sistema. Solo ves las opciones que tu rol te permite.' },
            { sel: '.nk-topbar .nk-pill-suc', alt: '[data-sucursal-badge-mobile]', t: 'Tu tienda', d: 'Es la tienda en la que estás trabajando. Las ventas y el inventario que ves son de esta tienda.' },
            { sel: '.nk-topbar [data-nk-open="tasa"]', t: 'Tasa del día', d: 'La tasa del dólar en bolívares. Se usa en la caja y en las facturas.' },
            { sel: '#sidebar a.nav-link[href="pos.html"]', menu: true, t: 'Punto de venta', d: 'Para vender: abre tu turno, escanea o busca el producto y cobra. Se abre en una ventana aparte.' },
            { sel: '#sidebar a.nav-link[href="productos.html"]', menu: true, t: 'Productos', d: 'El catálogo con precios, fotos y existencia de cada producto.' },
            { sel: '#sidebar a.nav-link[href="horarios.html"]', menu: true, t: 'Horarios y asistencia', d: 'Los turnos de cada persona y quién marcó entrada y salida.' },
            { sel: '#rg-tareas', padre: '.rg-card', t: 'Tareas pendientes', d: 'Lo que tienes por hacer aparece aquí. Toca una tarea para ir directo.' },
            { sel: '.nk-topbar [data-nk-open="user"]', alt: '#sidebar a.nav-link[href="perfil.html"]', t: 'Tu perfil', d: 'Toca tu nombre para entrar a Mi perfil: ahí cambias tu PIN y tus datos, y puedes volver a ver esta guía.' },
            { sel: '#logout-btn', menu: true, t: 'Cerrar sesión', d: 'Al terminar tu turno, cierra sesión para que nadie use tu usuario.' }
        ],
        'pos.html': [
            { t: '¡Bienvenido/a al punto de venta!', d: 'Te mostramos cómo vender en menos de un minuto. Puedes saltar la guía cuando quieras.' },
            { sel: '#t-turno', t: 'Abre tu turno', d: 'Antes de vender, abre tu turno con el dinero que hay en la caja. Al final del día lo cierras.' },
            { sel: '#f-buscar', padre: '.busca', t: 'Busca o escanea', d: 'Pasa el código de barras por el lector o escribe el nombre del producto. Se agrega a la factura.' },
            { sel: '#f-grid', t: 'Catálogo', d: 'También puedes tocar el producto aquí. Usa el filtro de arriba para ver una categoría.' },
            { sel: '#c-doc', padre: '.cli', t: 'Cliente', d: 'Escribe la cédula o el RIF si el cliente quiere la factura a su nombre. Si no, queda como consumidor final.' },
            { sel: '#f-siguiente', alt: '#m-cobrar', t: 'Cobrar', d: 'Cuando tengas todo, toca Siguiente para elegir cómo paga y emitir la factura.' },
            { sel: '.rail [data-v="facturas"]', t: 'Facturas', d: 'Aquí buscas las facturas ya hechas y haces devoluciones.' },
            { sel: '.rail [data-v="caja"]', t: 'Caja', d: 'El arqueo y el cierre de tu turno.' },
            { sel: '#t-user', t: 'Tu usuario', d: 'Para cambiar de usuario o cerrar sesión al terminar. Desde aquí también puedes volver a ver esta guía.' }
        ]
    };

    function usuario() { try { return window.getSesionUsuario && window.getSesionUsuario(); } catch (e) { return null; } }
    function clave(u) { return CLAVE + PAG.replace('.html', '') + '_' + (u && u.id || 'x'); }
    function vista(u) { try { return localStorage.getItem(clave(u)) === '1'; } catch (e) { return false; } }
    function marcarVista(u) { try { localStorage.setItem(clave(u), '1'); } catch (e) {} }
    function esc(s) { return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); }

    async function esNuevo(u) {
        if (!u || !u.id || !window.supabaseClient) return false;
        try {
            var r = await window.supabaseClient.from('usuarios').select('aceptado_at,created_at').eq('id', u.id).maybeSingle();
            if (r.error || !r.data) return false;
            var f = r.data.aceptado_at || r.data.created_at;
            return !!f && (Date.now() - new Date(f).getTime()) < DIAS_NUEVO * 864e5;
        } catch (e) { return false; }
    }

    // ---------- Estilos (se agregan una sola vez, no tocan el diseño de la página) ----------
    function estilos() {
        if (document.getElementById('gg-css')) return;
        var s = document.createElement('style'); s.id = 'gg-css';
        s.textContent =
            '.gg-raiz{position:fixed;inset:0;z-index:10050}' +
            '.gg-bloq{position:fixed;inset:0;background:transparent}' +
            '.gg-luz{position:fixed;border-radius:14px;box-shadow:0 0 0 9999px rgba(8,15,28,.74);outline:2px solid var(--rubro-acento,#00AAFF);outline-offset:2px;pointer-events:none;transition:top .25s ease,left .25s ease,width .25s ease,height .25s ease}' +
            '.gg-luz.gg-sin{outline:0;width:0!important;height:0!important;top:50%!important;left:50%!important}' +
            '.gg-card{position:fixed;width:min(340px,calc(100vw - 32px));background:#fff;color:#0B1220;border-radius:22px;padding:18px 18px 14px;box-shadow:0 20px 50px -12px rgba(0,0,0,.45);font-family:Roboto,Arial,sans-serif;transition:top .25s ease,left .25s ease;animation:ggIn .2s ease-out}' +
            '@keyframes ggIn{from{opacity:0;transform:translateY(6px)}to{opacity:1;transform:none}}' +
            '.gg-card h3{font-family:Poppins,sans-serif;font-weight:700;font-size:17px;letter-spacing:-.01em;margin:0 0 6px}' +
            '.gg-card p{font-size:14px;line-height:1.5;color:#3D4550;margin:0}' +
            '.gg-pie{display:flex;align-items:center;gap:8px;margin-top:14px}' +
            '.gg-n{font-size:12px;color:#71717A;margin-right:auto}' +
            '.gg-b{height:38px;padding:0 16px;border-radius:999px;border:0;font-family:Poppins,sans-serif;font-weight:600;font-size:14px;cursor:pointer;display:inline-flex;align-items:center;gap:4px}' +
            '.gg-sig{background:var(--rubro-acento,#00AAFF);color:#0A2540}' +
            '.gg-atr{background:#F1F4F7;color:#0A2540}' +
            '.gg-sal{background:none;color:#52525B;padding:0 6px;font-weight:500;font-family:Roboto,Arial,sans-serif}' +
            '.gg-b:focus-visible{outline:2px solid #0A2540;outline-offset:2px}' +
            '.gg-puntos{display:flex;gap:4px;margin-top:12px}' +
            '.gg-puntos i{width:6px;height:6px;border-radius:99px;background:#E3E8ED}' +
            '.gg-puntos i.on{background:var(--rubro-acento,#00AAFF);width:16px}' +
            '@media (prefers-color-scheme:dark){:root:not([data-theme="light"]) .gg-card{background:#232326;color:#E4E4E7}:root:not([data-theme="light"]) .gg-card p{color:#A1A1AA}:root:not([data-theme="light"]) .gg-atr{background:#3F3F46;color:#E4E4E7}:root:not([data-theme="light"]) .gg-sal{color:#A1A1AA}}' +
            ':root[data-theme="dark"] .gg-card,html.dark .gg-card{background:#232326;color:#E4E4E7}:root[data-theme="dark"] .gg-card p,html.dark .gg-card p{color:#A1A1AA}:root[data-theme="dark"] .gg-atr,html.dark .gg-atr{background:#3F3F46;color:#E4E4E7}';
        document.head.appendChild(s);
    }

    // ---------- Menú lateral en celular (está escondido) ----------
    var menuAbiertoPorGuia = false, gruposAbiertos = [];
    function abrirMenu(si) {
        var sb = document.getElementById('sidebar'), ov = document.getElementById('sidebar-overlay');
        if (!sb || window.innerWidth >= 1024) return;
        if (si && !sb.classList.contains('open')) { sb.classList.add('open'); if (ov) ov.classList.add('active'); menuAbiertoPorGuia = true; }
        if (!si && menuAbiertoPorGuia) { sb.classList.remove('open'); if (ov) ov.classList.remove('active'); menuAbiertoPorGuia = false; }
    }

    function visible(el) {
        if (!el || !el.getClientRects().length) return false;
        var r = el.getBoundingClientRect(), cs = getComputedStyle(el);
        return r.width > 0 && r.height > 0 && cs.visibility !== 'hidden' && cs.display !== 'none';
    }
    function objetivo(p) {
        if (!p.sel) return null;
        var el = document.querySelector(p.sel);
        if (el && p.padre) el = el.closest(p.padre) || el;
        // Link dentro de un grupo cerrado del menú: se abre mientras dura el paso
        var g = el && el.closest && el.closest('.nk-grp');
        if (g && !g.classList.contains('open')) { g.classList.add('open'); gruposAbiertos.push(g); }
        if (!visible(el) && p.alt) el = document.querySelector(p.alt);
        return visible(el) ? el : null;
    }
    function pasoDisponible(p) {
        if (!p.sel) return true;
        if (p.menu) abrirMenu(true);
        var ok = !!objetivo(p);
        return ok;
    }

    // ---------- Recorrido ----------
    var G = null;
    function iniciar(forzar) {
        if (G) return;
        var u = usuario();
        var lista = PASOS[PAG];
        if (!lista) return;
        estilos();
        var pasos = lista.filter(pasoDisponible);
        abrirMenu(false);
        gruposAbiertos.forEach(function (g) { g.classList.remove('open'); }); gruposAbiertos = [];
        if (pasos.length < 2) return;
        var nombre = u && String(u.nombre || '').trim().split(/\s+/)[0];
        if (nombre && !pasos[0].sel) pasos[0] = Object.assign({}, pasos[0], { t: pasos[0].t.replace('¡Bienvenido/a', '¡Hola ' + nombre + ', bienvenido/a') });

        var raiz = document.createElement('div');
        raiz.className = 'gg-raiz'; raiz.setAttribute('role', 'dialog'); raiz.setAttribute('aria-modal', 'true'); raiz.setAttribute('aria-label', 'Guía de bienvenida');
        raiz.innerHTML = '<div class="gg-bloq"></div><div class="gg-luz gg-sin"></div><div class="gg-card" aria-live="polite"></div>';
        document.body.appendChild(raiz);
        G = { u: u, pasos: pasos, i: 0, raiz: raiz, luz: raiz.querySelector('.gg-luz'), card: raiz.querySelector('.gg-card'), el: null };
        document.addEventListener('keydown', teclas, true);
        window.addEventListener('resize', ubicar);
        window.addEventListener('scroll', ubicar, true);
        mostrar(0);
    }

    function mostrar(i) {
        var p = G.pasos[i]; G.i = i;
        gruposAbiertos.forEach(function (g) { g.classList.remove('open'); }); gruposAbiertos = [];
        abrirMenu(!!p.menu);
        G.el = objetivo(p);
        if (G.el) {
            var r = G.el.getBoundingClientRect();
            if (r.top < 0 || r.bottom > window.innerHeight) G.el.scrollIntoView({ block: 'center' });
        }
        var n = G.pasos.length, ult = i === n - 1;
        G.card.innerHTML = '<h3>' + esc(p.t) + '</h3><p>' + esc(p.d) + '</p>' +
            '<div class="gg-puntos">' + G.pasos.map(function (_, k) { return '<i' + (k === i ? ' class="on"' : '') + '></i>'; }).join('') + '</div>' +
            '<div class="gg-pie"><span class="gg-n">' + (i + 1) + ' de ' + n + '</span>' +
            (ult ? '' : '<button type="button" class="gg-b gg-sal" data-g="saltar">Saltar</button>') +
            (i > 0 ? '<button type="button" class="gg-b gg-atr" data-g="atras">Atrás</button>' : '') +
            '<button type="button" class="gg-b gg-sig" data-g="sig">' + (ult ? '¡Listo!' : 'Siguiente') + '</button></div>';
        G.card.querySelectorAll('[data-g]').forEach(function (b) {
            b.addEventListener('click', function () {
                var a = b.dataset.g;
                if (a === 'sig') { if (ult) terminar(); else mostrar(i + 1); }
                else if (a === 'atras') mostrar(i - 1);
                else terminar();
            });
        });
        requestAnimationFrame(function () { ubicar(); var s = G && G.card.querySelector('.gg-sig'); if (s) s.focus({ preventScroll: true }); });
    }

    function ubicar() {
        if (!G) return;
        var vw = window.innerWidth, vh = window.innerHeight, M = 16, PAD = 6;
        var cw = G.card.offsetWidth, ch = G.card.offsetHeight;
        if (!G.el || !visible(G.el)) {
            G.luz.classList.add('gg-sin');
            G.card.style.left = Math.max(M, (vw - cw) / 2) + 'px';
            G.card.style.top = Math.max(M, (vh - ch) / 2) + 'px';
            return;
        }
        var r = G.el.getBoundingClientRect();
        var top = Math.max(4, r.top - PAD), left = Math.max(4, r.left - PAD);
        var bottom = Math.min(vh - 4, r.bottom + PAD), right = Math.min(vw - 4, r.right + PAD);
        G.luz.classList.remove('gg-sin');
        G.luz.style.top = top + 'px'; G.luz.style.left = left + 'px';
        G.luz.style.width = Math.max(0, right - left) + 'px'; G.luz.style.height = Math.max(0, bottom - top) + 'px';
        var x, y;
        if (vh - bottom >= ch + 12 + M) { y = bottom + 12; x = left; }                 // abajo
        else if (top >= ch + 12 + M) { y = top - ch - 12; x = left; }                  // arriba
        else if (vw - right >= cw + 12 + M) { x = right + 12; y = top; }               // a la derecha
        else if (left >= cw + 12 + M) { x = left - cw - 12; y = top; }                 // a la izquierda
        else { x = (vw - cw) / 2; y = vh - ch - M; }                                    // encima, abajo de la pantalla
        G.card.style.left = Math.min(Math.max(M, x), vw - cw - M) + 'px';
        G.card.style.top = Math.min(Math.max(M, y), vh - ch - M) + 'px';
    }

    function teclas(e) {
        if (!G) return;
        if (e.key === 'Escape') { e.preventDefault(); terminar(); }
        else if (e.key === 'ArrowRight') { e.preventDefault(); if (G.i < G.pasos.length - 1) mostrar(G.i + 1); else terminar(); }
        else if (e.key === 'ArrowLeft') { e.preventDefault(); if (G.i > 0) mostrar(G.i - 1); }
        else if (e.key === 'Tab') { var bs = G.card.querySelectorAll('button'); if (bs.length) { e.preventDefault(); var k = Array.prototype.indexOf.call(bs, document.activeElement); bs[(k + (e.shiftKey ? bs.length - 1 : 1)) % bs.length].focus(); } return; }
        else if (e.key === 'Enter' || e.key === ' ') { if (G.card.contains(document.activeElement)) return; e.preventDefault(); }
        else return;
        e.stopPropagation();
    }

    function terminar() {
        if (!G) return;
        marcarVista(G.u);
        document.removeEventListener('keydown', teclas, true);
        window.removeEventListener('resize', ubicar);
        window.removeEventListener('scroll', ubicar, true);
        G.raiz.remove(); G = null;
        gruposAbiertos.forEach(function (g) { g.classList.remove('open'); }); gruposAbiertos = [];
        abrirMenu(false);
        try { history.replaceState(null, '', location.pathname + location.search.replace(/([?&])guia=1(&|$)/, function (m, a, b) { return b ? a : ''; }) + location.hash); } catch (e) {}
    }

    // Volver a verla: borra las marcas de este usuario
    function reiniciar() {
        var u = usuario();
        Object.keys(PASOS).forEach(function (p) { try { localStorage.removeItem(CLAVE + p.replace('.html', '') + '_' + (u && u.id || 'x')); } catch (e) {} });
    }
    window.refGuia = { iniciar: iniciar, reiniciar: reiniciar };

    // ---------- Arranque ----------
    function esperar(cond, ms) {
        return new Promise(function (ok) {
            var t0 = Date.now();
            (function mirar() { if (cond()) return ok(true); if (Date.now() - t0 > ms) return ok(false); setTimeout(mirar, 250); })();
        });
    }
    async function arrancar() {
        var forzar = /[?&]guia=1\b/.test(location.search);
        if (PAG === 'pos.html') {
            // El punto de venta muestra la guía cuando ya entró alguien (pantalla de venta visible)
            var app = document.getElementById('app');
            if (!app) return;
            var revisar = async function () {
                if (G || app.classList.contains('hide')) return;
                var u = usuario(); if (!u) return;
                if (!forzar && (vista(u) || !(await esNuevo(u)))) return;
                await esperar(function () { return !document.querySelector('.mov,.ref-dlg-ov'); }, 8000);
                setTimeout(function () { iniciar(forzar); forzar = false; }, 600);
            };
            new MutationObserver(revisar).observe(app, { attributes: true, attributeFilter: ['class'] });
            revisar();
            return;
        }
        if (!PASOS[PAG]) return;
        var u = usuario();
        if (!u) return;
        if (!forzar && (vista(u) || !(await esNuevo(u)))) return;
        // Que termine de pintarse la página (menú, tienda, tareas)
        await esperar(function () { var n = document.querySelector('#sidebar nav'); return n && n.children.length > 0; }, 6000);
        setTimeout(function () { iniciar(forzar); }, 700);
    }

    // Botón "Ver la guía otra vez" en Perfil y en el menú del usuario del punto de venta
    function botones() {
        if (PAG === 'perfil.html') {
            var tema = document.getElementById('pe-tema');
            if (tema && !document.getElementById('gg-ver')) {
                var b = document.createElement('button');
                b.type = 'button'; b.id = 'gg-ver'; b.className = 'nk-btn nk-btn-outline nk-btn-sm'; b.style.marginTop = '16px';
                b.innerHTML = '<span class="material-symbols-outlined">tour</span>Ver la guía de bienvenida otra vez';
                b.addEventListener('click', function () {
                    reiniciar();
                    var soloCaja = !(window.can && window.can('ver_dashboard')) && ['cajero', 'vendedor', 'empleado'].indexOf((usuario() || {}).rol) >= 0;
                    location.href = (soloCaja ? 'pos.html' : 'dashboard.html') + '?guia=1';
                });
                tema.parentNode.insertBefore(b, tema.nextSibling);
            }
        }
        if (PAG === 'pos.html') {
            var menu = document.getElementById('t-menu'), salir = menu && menu.querySelector('[data-m="salir"]');
            if (salir && !menu.querySelector('[data-g-ver]')) {
                var m = document.createElement('button');
                m.type = 'button'; m.setAttribute('data-g-ver', '1');
                m.innerHTML = '<span class="material-symbols-outlined">tour</span>Ver guía de bienvenida';
                m.addEventListener('click', function () { menu.classList.add('hide'); reiniciar(); iniciar(true); });
                menu.insertBefore(m, salir);
            }
        }
    }

    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', function () { botones(); arrancar(); });
    else { botones(); arrancar(); }
})();
