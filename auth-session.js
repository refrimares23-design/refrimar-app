// ============================================================
// REFRIMAR OS — Sesión de acceso segura (sessionStorage)
// ------------------------------------------------------------
// La sesión del usuario y la ubicación (Casa Matriz / Sucursal)
// viven SOLO en sessionStorage: se borran automáticamente al
// cerrar la pestaña o el navegador, por lo que al volver a
// entrar SIEMPRE se pasa por el flujo inicial de login.html:
//   1) seleccionar Ubicación   2) seleccionar Usuario + PIN
//
// 'Cerrar Sesión' también limpia cualquier resto en localStorage.
// ============================================================

window.REF_SESION_KEY = 'refrimar_user';
window.REF_SUCURSAL_KEY = 'refrimar_sucursal_actual';

// Tema claro / oscuro (se guarda en este navegador)
function temaActual() { try { return localStorage.getItem('refrimar_tema') === 'oscuro' ? 'oscuro' : 'claro'; } catch (e) { return 'claro'; } }
function ponerTema(t) {
    try { localStorage.setItem('refrimar_tema', t === 'oscuro' ? 'oscuro' : 'claro'); } catch (e) {}
    document.documentElement.classList.toggle('nk-dark', t === 'oscuro');
}
window.temaActual = temaActual; window.ponerTema = ponerTema;
if (temaActual() === 'oscuro') document.documentElement.classList.add('nk-dark');

// Lee el usuario autenticado (sessionStorage). Devuelve null si no hay.
window.getSesionUsuario = function() {
    try {
        var raw = sessionStorage.getItem(window.REF_SESION_KEY);
        return raw ? JSON.parse(raw) : null;
    } catch (e) { return null; }
};

// Guarda el usuario autenticado SOLO en sessionStorage.
window.guardarSesion = function(usuario) {
    sessionStorage.setItem(window.REF_SESION_KEY, JSON.stringify(usuario));
};

// Guarda la ubicación seleccionada SOLO en sessionStorage.
window.guardarSucursalSesion = function(sucursal) {
    sessionStorage.setItem(window.REF_SUCURSAL_KEY, JSON.stringify(sucursal));
};

// Limpia sesión y ubicación en sessionStorage y localStorage.
window.limpiarSesion = function() {
    var claves = [window.REF_SESION_KEY, window.REF_SUCURSAL_KEY];
    claves.forEach(function(k) {
        try { localStorage.removeItem(k); } catch (e) {}
        try { sessionStorage.removeItem(k); } catch (e) {}
    });
};

// Cierra sesión y vuelve al flujo inicial de login.html.
window.cerrarSesion = function() {
    window.limpiarSesion();
    window.location.href = 'login.html';
};

// ============================================================
// PERMISSION GUARD — Administrador vs Empleado (estilo Norkut)
// ------------------------------------------------------------
//   can('ver_costos')  -> true/false según el rol logueado.
//   Admin: acceso total. Empleado (cajero/vendedor/otro): solo
//   facturar, su caja (en el POS), clientes, inventario en
//   lectura, cotizar y su dashboard (sin utilidades).
// Además:
//   - Bloquea la ruta aunque escriban la URL directa.
//   - Quita del DOM los links del menú sin permiso.
//   - Quita del DOM los elementos [data-can="permiso"].
// ============================================================
(function () {
    var PERMISOS_EMPLEADO = ['facturar', 'ver_mi_caja', 'registrar_clientes', 'ver_inventario', 'cotizar', 'ver_dashboard'];

    // Página -> permiso requerido para entrar.
    var PAGINA_PERMISO = {
        'dashboard.html': 'ver_dashboard',
        'facturacion.html': 'facturar',
        'cotizaciones.html': 'cotizar',
        'clientes.html': 'registrar_clientes',
        'inventario.html': 'ver_inventario',
        'caja.html': 'caja_admin',
        'devoluciones.html': 'devoluciones',
        'kardex.html': 'ver_costos',
        'compras.html': 'compras',
        'gastos.html': 'gastos',
        'carga-ia.html': 'editar_inventario',
        'cuentas_por_cobrar.html': 'ver_cxc',
        'cuentas_por_pagar.html': 'ver_cxp',
        'cierre_diario.html': 'cierre_diario',
        'reportes.html': 'ver_reportes',
        'usuarios.html': 'gestionar_usuarios',
        'sucursales.html': 'gestionar_sucursales',
        'configuracion.html': 'configuracion',
        'facturas.html': 'facturar',
        'productos.html': 'ver_inventario',
        'producto.html': 'ver_inventario',
        'producto-form.html': 'editar_inventario',
        'proveedores.html': 'compras',
        'monedas.html': 'configuracion',
        'turnos.html': 'facturar',
        'app-pos.html': 'facturar',
        'conteos.html': 'editar_inventario',
        'precios.html': 'editar_inventario',
        'ordenes_compra.html': 'compras'
    };
    window.REF_PAGINA_PERMISO = PAGINA_PERMISO;

    window.esAdmin = function () {
        var u = window.getSesionUsuario();
        return !!(u && u.rol === 'admin');
    };

    window.can = function (permiso) {
        var u = window.getSesionUsuario();
        if (!u) return false;
        if (u.rol === 'admin') return true;
        return PERMISOS_EMPLEADO.indexOf(permiso) >= 0;
    };

    // Elimina campos de costo de filas traídas de Supabase (empleado).
    var CAMPOS_COSTO = ['costo', 'costo_unitario', 'costo_promedio', 'costo_usd'];
    window.quitarCostos = function (rows) {
        if (window.can('ver_costos') || !Array.isArray(rows)) return rows;
        return rows.map(function (r) {
            if (!r || typeof r !== 'object') return r;
            var c = Object.assign({}, r);
            CAMPOS_COSTO.forEach(function (k) { delete c[k]; });
            return c;
        });
    };

    function paginaActual() {
        return (location.pathname.split('/').pop() || 'index.html').toLowerCase();
    }

    function destinoSeguro() {
        var u = window.getSesionUsuario();
        var tieneDash = u && (u.rol === 'admin' || (u.permisos || []).indexOf('dashboard') >= 0);
        return tieneDash ? 'dashboard.html' : 'facturacion.html';
    }

    // ---- 1. Bloqueo de ruta (URL directa) ----
    var permPagina = PAGINA_PERMISO[paginaActual()];
    if (permPagina && window.getSesionUsuario() && !window.can(permPagina)) {
        window.__refSinPermiso = true;
        try { document.documentElement.style.visibility = 'hidden'; } catch (e) {}
        try { sessionStorage.setItem('refrimar_flash', 'Sin permiso para entrar a esa sección'); } catch (e) {}
        var dest = destinoSeguro();
        if (dest === paginaActual()) dest = 'facturacion.html';
        location.replace(dest);
    }

    // ---- 2. Menú lateral central (estilo Norkut) ----
    // Se construye aquí para TODAS las páginas: una sola definición.
    // [página, ícono, etiqueta, módulo (permisos por usuario)]
    var MENU = [
        { titulo: null, items: [['dashboard.html', 'space_dashboard', 'Dashboard', 'dashboard']] },
        { titulo: 'Operación', items: [
            ['facturacion.html', 'point_of_sale', 'Punto de venta', 'facturacion'],
            ['facturas.html', 'receipt_long', 'Facturas', 'facturacion'],
            ['turnos.html', 'schedule', 'Turnos', 'facturacion'],
            ['cotizaciones.html', 'request_quote', 'Cotizaciones', 'cotizaciones'],
            ['caja.html', 'payments', 'Caja', 'caja'],
            ['devoluciones.html', 'assignment_return', 'Anulaciones', 'devoluciones']] },
        { titulo: 'Inventario', items: [
            ['productos.html', 'inventory_2', 'Productos', 'inventario'],
            ['inventario.html', 'warehouse', 'Stock por tienda', 'inventario'],
            ['conteos.html', 'fact_check', 'Conteo de inventario', 'inventario'],
            ['precios.html', 'sell', 'Actualización de precios', 'inventario'],
            ['kardex.html', 'swap_vert', 'Kardex', 'kardex'],
            ['carga-ia.html', 'document_scanner', 'Carga IA de facturas', 'carga-ia']] },
        { titulo: 'Compras', items: [
            ['ordenes_compra.html', 'shopping_cart', 'Órdenes de compra', 'compras'],
            ['proveedores.html', 'domain', 'Proveedores', 'compras'],
            ['compras.html', 'local_shipping', 'Recepción directa', 'compras'],
            ['gastos.html', 'receipt', 'Gastos', 'gastos']] },
        { titulo: 'Clientes', items: [
            ['clientes.html', 'group', 'Clientes', 'clientes'],
            ['cuentas_por_cobrar.html', 'account_balance', 'Cuentas por cobrar', 'cxc']] },
        { titulo: 'Finanzas', items: [
            ['cuentas_por_pagar.html', 'account_balance_wallet', 'Cuentas por pagar', 'cxp'],
            ['cierre_diario.html', 'event_note', 'Cierre diario', 'cierre'],
            ['reportes.html', 'bar_chart', 'Reportes', 'reportes']] },
        { titulo: 'Tienda', items: [
            ['sucursales.html', 'storefront', 'Sucursales y traspasos', 'sucursales'],
            ['app-pos.html', 'install_desktop', 'App POS y cajas', 'facturacion'],
            ['monedas.html', 'currency_exchange', 'Monedas y tasa', 'configuracion'],
            ['usuarios.html', 'badge', 'Colaboradores', 'usuarios'],
            ['configuracion.html', 'settings', 'Configuración', 'configuracion']] }
    ];
    window.REF_MENU = MENU;

    function permisoModulo(u, modulo) {
        if (!u) return false;
        if (u.rol === 'admin') return true;
        // Igual que cada página: el módulo debe estar marcado en Usuarios.
        return (u.permisos || []).indexOf(modulo) >= 0 || modulo === 'facturacion';
    }

    window.organizarSidebar = function () {
        var nav = document.querySelector('#sidebar nav');
        if (!nav || nav.dataset.refOrganizado) return;
        var u = window.getSesionUsuario();
        var base = 'nav-link flex items-center gap-md px-md py-sm rounded-lg transition-all cursor-pointer';
        nav.innerHTML = '';
        MENU.forEach(function (g) {
            var visibles = g.items.filter(function (it) {
                return window.can(PAGINA_PERMISO[it[0]] || 'x') && permisoModulo(u, it[3]);
            });
            if (!visibles.length) return;
            if (g.titulo) {
                var lab = document.createElement('div');
                lab.className = 'sidebar-section-label';
                lab.textContent = g.titulo;
                nav.appendChild(lab);
            }
            visibles.forEach(function (it) {
                var a = document.createElement('a');
                a.href = it[0];
                a.className = base;
                a.innerHTML = '<span class="material-symbols-outlined">' + it[1] + '</span><span class="font-mono-data text-sm">' + it[2] + '</span>';
                nav.appendChild(a);
            });
        });
        nav.dataset.refOrganizado = '1';
        // El menú conserva su posición de scroll al cambiar de página
        var navGuardado = 0, navListo = false;
        try { navGuardado = Number(sessionStorage.getItem('refrimar_nav_scroll')) || 0; } catch (e) {}
        var restaurar = function () { if (navGuardado && nav.scrollTop !== navGuardado) nav.scrollTop = navGuardado; };
        restaurar();
        document.addEventListener('DOMContentLoaded', restaurar);
        requestAnimationFrame(function () { restaurar(); requestAnimationFrame(function () { restaurar(); navListo = true; }); });
        window.addEventListener('load', restaurar);
        var guardarScroll = function () { if (!navListo) return; try { sessionStorage.setItem('refrimar_nav_scroll', String(nav.scrollTop)); } catch (e) {} };
        nav.addEventListener('scroll', guardarScroll, { passive: true });
        window.addEventListener('pagehide', guardarScroll);
        // Precarga la página al pasar el mouse / tocar un link (navegación casi instantánea)
        var precargadas = {};
        var precargar = function (e) {
            var a = e.target.closest && e.target.closest('a.nav-link');
            if (!a || precargadas[a.href]) return;
            precargadas[a.href] = true;
            var l = document.createElement('link'); l.rel = 'prefetch'; l.href = a.href; document.head.appendChild(l);
        };
        nav.addEventListener('mouseover', precargar, { passive: true });
        nav.addEventListener('touchstart', precargar, { passive: true });
    };

    // Oculta títulos de sección cuyos links quedaron todos ocultos.
    function limpiarTitulosVacios() {
        var nav = document.querySelector('#sidebar nav');
        if (!nav) return;
        nav.querySelectorAll('.sidebar-section-label').forEach(function (lab) {
            var n = lab.nextElementSibling, alguno = false;
            while (n && !n.classList.contains('sidebar-section-label')) {
                if (n.matches('a.nav-link') && !n.classList.contains('hidden-modal')) { alguno = true; break; }
                n = n.nextElementSibling;
            }
            lab.style.display = alguno ? '' : 'none';
        });
    }

    // ---- 3. Elementos marcados con data-can ----
    window.aplicarPermisosDOM = function (root) {
        (root || document).querySelectorAll('[data-can]').forEach(function (el) {
            if (!window.can(el.getAttribute('data-can'))) el.remove();
        });
    };

    function aplicarTodo() {
        if (!window.getSesionUsuario()) return;
        window.organizarSidebar();
        window.aplicarPermisosDOM();
    }
    // El script se carga al final del <body>: el DOM ya existe.
    aplicarTodo();
    document.addEventListener('DOMContentLoaded', function () {
        aplicarTodo();
        limpiarTitulosVacios();
        var flash = null;
        try { flash = sessionStorage.getItem('refrimar_flash'); sessionStorage.removeItem('refrimar_flash'); } catch (e) {}
        if (flash) setTimeout(function () { if (typeof window.showToast === 'function') window.showToast(flash, 'error'); }, 300);
        var info = null;
        try { info = sessionStorage.getItem('refrimar_flash_info'); sessionStorage.removeItem('refrimar_flash_info'); } catch (e) {}
        if (info) setTimeout(function () { if (typeof window.showToast === 'function') window.showToast(info, 'info'); }, 400);
    });
    window.addEventListener('load', limpiarTitulosVacios);
})();

// ============================================================
// SUCURSAL ACTIVA — helpers comunes para INSERT/SELECT
// ============================================================
// Id de la sucursal activa (la elegida en login.html).
window.sucursalActivaId = function () {
    try {
        var raw = sessionStorage.getItem(window.REF_SUCURSAL_KEY);
        var s = raw ? JSON.parse(raw) : null;
        return (s && s.id) || '00000000-0000-0000-0000-000000000001';
    } catch (e) { return '00000000-0000-0000-0000-000000000001'; }
};

// Filtra un query por la sucursal activa. En Casa Matriz incluye los
// registros históricos sin sucursal (NULL). opts.nullEnTodas incluye
// NULL en cualquier sucursal (catálogos compartidos heredados).
window.filtrarPorSucursal = function (q, columna, opts) {
    opts = opts || {};
    var col = columna || 'sucursal_id';
    var casa = '00000000-0000-0000-0000-000000000001';
    var id = window.sucursalActivaId();
    if (id === casa || opts.nullEnTodas) return q.or(col + '.eq.' + id + ',' + col + '.is.null');
    return q.eq(col, id);
};

// Llama un RPC con parámetros nuevos (ej. p_sucursal_id). Si la
// migración aún no se corrió en Supabase (firma vieja), reintenta
// sin esos parámetros para no romper la operación.
window.rpcConFallback = async function (fn, args, clavesNuevas) {
    var res = await supabaseClient.rpc(fn, args);
    if (res.error && (res.error.code === 'PGRST202' || /Could not find the function|schema cache/i.test(res.error.message || ''))) {
        var viejo = Object.assign({}, args);
        (clavesNuevas || []).forEach(function (k) { delete viejo[k]; });
        res = await supabaseClient.rpc(fn, viejo);
    }
    return res;
};

// Ejecuta un SELECT filtrado por sucursal; si la columna sucursal_id
// aún no existe (migración pendiente), repite el query sin filtro.
//   await window.selectPorSucursal(function(){ return supabaseClient.from('x').select('*'); }, { nullEnTodas: true })
window.selectPorSucursal = async function (crearQuery, opts) {
    opts = opts || {};
    var res = await window.filtrarPorSucursal(crearQuery(), opts.columna || 'sucursal_id', opts);
    if (res.error && (res.error.code === '42703' || /column .*sucursal_id.* does not exist/i.test(res.error.message || ''))) {
        res = await crearQuery();
    }
    return res;
};

// ============================================================
// ESTILO NORKUT — logo, link activo, barra superior y títulos
// ============================================================
(function () {
    var SECCION = {
        'facturacion.html': 'Operación', 'cotizaciones.html': 'Operación', 'caja.html': 'Operación', 'devoluciones.html': 'Operación',
        'inventario.html': 'Inventario', 'kardex.html': 'Inventario', 'clientes.html': 'Clientes', 'compras.html': 'Compras', 'gastos.html': 'Compras', 'carga-ia.html': 'Inventario',
        'cuentas_por_cobrar.html': 'Clientes', 'cuentas_por_pagar.html': 'Finanzas', 'cierre_diario.html': 'Finanzas', 'reportes.html': 'Finanzas',
        'usuarios.html': 'Tienda', 'sucursales.html': 'Tienda', 'configuracion.html': 'Tienda', 'dashboard.html': 'Inicio',
        'facturas.html': 'Operación', 'turnos.html': 'Operación', 'app-pos.html': 'Tienda',
        'conteos.html': 'Inventario', 'precios.html': 'Inventario', 'ordenes_compra.html': 'Compras',
        'productos.html': 'Inventario', 'monedas.html': 'Tienda', 'proveedores.html': 'Compras',
        'producto.html': 'Inventario', 'producto-form.html': 'Inventario'
    };
    var NOMBRE = {
        'facturacion.html': 'Punto de venta', 'cotizaciones.html': 'Cotizaciones', 'caja.html': 'Caja', 'devoluciones.html': 'Devoluciones',
        'inventario.html': 'Inventario', 'kardex.html': 'Kardex', 'clientes.html': 'Clientes', 'compras.html': 'Compras', 'gastos.html': 'Gastos', 'carga-ia.html': 'Carga IA',
        'cuentas_por_cobrar.html': 'Cuentas por cobrar', 'cuentas_por_pagar.html': 'Cuentas por pagar', 'cierre_diario.html': 'Cierre diario', 'reportes.html': 'Reportes',
        'usuarios.html': 'Colaboradores', 'sucursales.html': 'Sucursales', 'configuracion.html': 'Configuración', 'dashboard.html': 'Dashboard',
        'facturas.html': 'Facturas', 'turnos.html': 'Turnos', 'app-pos.html': 'App POS y cajas',
        'conteos.html': 'Conteo de inventario', 'precios.html': 'Actualización de precios', 'ordenes_compra.html': 'Órdenes de compra',
        'productos.html': 'Productos', 'monedas.html': 'Monedas y tasa', 'inventario.html': 'Stock por tienda', 'proveedores.html': 'Proveedores', 'compras.html': 'Recepción directa',
        'producto.html': 'Productos <span>/</span> Detalle', 'producto-form.html': 'Productos <span>/</span> Ficha'
    };
    function pagina() { return (location.pathname.split('/').pop() || 'index.html').toLowerCase(); }
    function esc(s) { return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); }

    function logo() {
        var t = document.querySelector('#sidebar .text-2xl.font-black');
        if (!t || t.dataset.nk) return;
        var cont = t.parentElement;
        cont.innerHTML = '<div class="nk-logo"><img src="img/logo-refrimar-azul.png" alt="REFRIMAR" class="nk-logo-img"/></div>' +
            '<div class="nk-logo-sub">Sistema de gestión · POS</div>';
        cont.dataset.nk = '1';
    }

    var ALIAS_MENU = { 'producto.html': 'productos.html', 'producto-form.html': 'productos.html' };
    function linkActivo() {
        var pag = ALIAS_MENU[pagina()] || pagina();
        document.querySelectorAll('#sidebar a.nav-link').forEach(function (a) {
            var href = (a.getAttribute('href') || '').split('?')[0].toLowerCase();
            a.classList.toggle('nk-active', href === pag);
        });
    }

    function tituloLimpio() {
        var h = document.querySelector('main header h1');
        if (!h || h.dataset.nk) return;
        var txt = h.textContent.replace(/^\s*REFRIMAR\s*\/\/\s*/i, '').trim();
        if (txt && txt === txt.toUpperCase()) txt = txt.charAt(0) + txt.slice(1).toLowerCase();
        if (NOMBRE[pagina()] && /^punto de venta$/i.test(txt) === false && pagina() === 'facturacion.html') txt = 'Punto de venta';
        h.textContent = txt;
        h.dataset.nk = '1';
    }

    function fmtTasa(n) { return Number(n || 0).toLocaleString('es-VE', { minimumFractionDigits: 2, maximumFractionDigits: 4 }); }

    function topbar() {
        var main = document.querySelector('main');
        var u = window.getSesionUsuario && window.getSesionUsuario();
        if (!main || !u || main.querySelector('.nk-topbar')) return;
        var pag = pagina();
        var suc = null;
        try { suc = JSON.parse(sessionStorage.getItem(window.REF_SUCURSAL_KEY) || 'null'); } catch (e) {}
        suc = suc || { nombre: 'Casa Matriz' };
        var nombre = String(u.nombre || 'Usuario');
        var ini = nombre.split(/\s+/).map(function (p) { return p.charAt(0); }).join('').slice(0, 2).toUpperCase();
        var editaTasa = window.can('configuracion');
        var admin = u.rol === 'admin';
        var tema = temaActual();
        var bar = document.createElement('div');
        bar.className = 'nk-topbar';
        bar.innerHTML =
            '<div class="nk-crumbs">' + (SECCION[pag] ? esc(SECCION[pag]) + ' <span>/</span> ' : '') + '<b>' + (NOMBRE[pag] || '').split(' <span>/</span> ').map(esc).join('</b> <span>/</span> <b>') + '</b></div>' +
            '<div class="nk-top-right">' +
                '<button type="button" class="nk-pill nk-pill-suc" data-nk-open="suc" title="Tienda activa"><span class="material-symbols-outlined">storefront</span>' + esc(suc.nombre || 'Casa Matriz') + '</button>' +
                '<div class="nk-pop-wrap" data-nk-box="tasa">' +
                    '<button type="button" class="nk-pill" data-nk-open="tasa" title="Tasa de cambio"><span class="material-symbols-outlined">currency_exchange</span><span id="nk-tasa">—</span> VES</button>' +
                    '<div class="nk-pop nk-pop-tasa">' +
                        '<div class="nk-pop-title">Tasa de cambio</div>' +
                        '<div class="nk-pop-sub">Se usa en el punto de venta, facturas, cotizaciones y documentos internos.</div>' +
                        '<div class="nk-pop-cur">VES <span class="material-symbols-outlined">sync_alt</span> <b>USD</b></div>' +
                        '<div class="nk-stepper' + (editaTasa ? '' : ' ro') + '">' +
                            (editaTasa ? '<button type="button" data-step="-1" aria-label="Bajar">−</button>' : '') +
                            '<input id="nk-tasa-in" type="text" inputmode="decimal" ' + (editaTasa ? '' : 'readonly') + '/>' +
                            (editaTasa ? '<button type="button" data-step="1" aria-label="Subir">+</button>' : '') +
                        '</div>' +
                        '<div class="nk-pop-bcv">Tasa según BCV: <b id="nk-bcv">consultando…</b>' + (editaTasa ? ' <button type="button" id="nk-usar-bcv" disabled>Usar tasa</button>' : '') + '</div>' +
                        '<div class="nk-pop-upd"><span class="material-symbols-outlined">schedule</span><span id="nk-tasa-upd">Última actualización: —</span></div>' +
                        '<div class="nk-pop-sep"></div>' +
                        '<div class="nk-pop-venta"><span>Equivalencia</span><b id="nk-tasa-eq">1 USD = — VES</b></div>' +
                        '<div class="nk-pop-foot"><a href="monedas.html">Ver historial <span class="material-symbols-outlined">open_in_new</span></a>' +
                            (editaTasa ? '<button type="button" class="nk-btn" id="nk-tasa-ok"><span class="material-symbols-outlined">save</span>Actualizar</button>' : '') + '</div>' +
                    '</div>' +
                '</div>' +
                '<div class="nk-pop-wrap nk-user" data-nk-box="user">' +
                    '<button type="button" class="nk-user-btn" data-nk-open="user"><span class="nk-avatar">' + esc(ini) + '</span><span class="nk-user-name">' + esc(nombre) + '</span>' +
                    '<span class="material-symbols-outlined" style="font-size:18px">expand_more</span></button>' +
                    '<div class="nk-pop nk-user-menu">' +
                        '<div class="nk-menu-head"><span class="nk-avatar nk-avatar-lg">' + esc(ini) + '<i></i></span><div><b>' + esc(nombre) + '</b><span>Comercial Refrimar · ' + (admin ? 'Administrador' : 'Empleado') + '</span></div></div>' +
                        '<button type="button" data-nk-sub="tema"><span class="material-symbols-outlined">palette</span>Tema<span class="nk-menu-val">' + (tema === 'oscuro' ? 'Oscuro' : 'Claro') + '</span><span class="material-symbols-outlined nk-chev">expand_more</span></button>' +
                        '<div class="nk-submenu" data-sub="tema">' +
                            '<button type="button" data-tema="claro"' + (tema !== 'oscuro' ? ' class="on"' : '') + '><span class="material-symbols-outlined">light_mode</span>Claro</button>' +
                            '<button type="button" data-tema="oscuro"' + (tema === 'oscuro' ? ' class="on"' : '') + '><span class="material-symbols-outlined">dark_mode</span>Oscuro</button>' +
                        '</div>' +
                        (admin ? '<button type="button" data-nk="tienda"><span class="material-symbols-outlined">domain</span>Cambiar tienda</button>' : '') +
                        (window.can('configuracion') ? '<button type="button" data-nk="config"><span class="material-symbols-outlined">settings</span>Configuración</button>' : '') +
                        '<div class="nk-pop-sep"></div>' +
                        '<button type="button" data-nk="salir"><span class="material-symbols-outlined">logout</span>Cerrar sesión</button>' +
                    '</div>' +
                '</div>' +
            '</div>';
        main.insertBefore(bar, main.firstChild);

        function cerrarTodo(salvo) { bar.querySelectorAll('[data-nk-box]').forEach(function (b) { if (b !== salvo) b.classList.remove('open'); }); }
        bar.querySelectorAll('[data-nk-open]').forEach(function (btn) {
            btn.addEventListener('click', function (e) {
                e.stopPropagation();
                var k = btn.dataset.nkOpen;
                if (k === 'suc') { if (admin) abrirTiendas(); return; }
                var box = bar.querySelector('[data-nk-box="' + k + '"]');
                cerrarTodo(box);
                box.classList.toggle('open');
                if (k === 'tasa' && box.classList.contains('open')) abrirTasa();
            });
        });
        bar.querySelectorAll('.nk-pop').forEach(function (p) { p.addEventListener('click', function (e) { e.stopPropagation(); }); });
        document.addEventListener('click', function () { cerrarTodo(null); });
        document.addEventListener('keydown', function (e) { if (e.key === 'Escape') cerrarTodo(null); });

        bar.querySelector('[data-nk-sub="tema"]').addEventListener('click', function () { this.parentElement.querySelector('[data-sub="tema"]').classList.toggle('open'); this.classList.toggle('open'); });
        bar.querySelectorAll('[data-tema]').forEach(function (b) {
            b.addEventListener('click', function () {
                ponerTema(b.dataset.tema);
                bar.querySelectorAll('[data-tema]').forEach(function (x) { x.classList.toggle('on', x === b); });
                bar.querySelector('.nk-menu-val').textContent = b.dataset.tema === 'oscuro' ? 'Oscuro' : 'Claro';
            });
        });
        bar.querySelectorAll('[data-nk]').forEach(function (b) {
            b.addEventListener('click', function () {
                if (b.dataset.nk === 'salir') window.cerrarSesion();
                else if (b.dataset.nk === 'tienda') { cerrarTodo(null); abrirTiendas(); }
                else location.href = 'configuracion.html';
            });
        });
        if (editaTasa) prepararTasa(bar);
        cargarTasa();
    }

    // ---------- Tasa ----------
    var TASA = { actual: 0, bcv: 0 };
    function numTasa(t) {
        t = String(t == null ? '' : t).trim().replace(/\s/g, '');
        if (!t) return 0;
        var c = t.lastIndexOf(','), d = t.lastIndexOf('.');
        if (c > -1 && d > -1) t = c > d ? t.replace(/\./g, '').replace(',', '.') : t.replace(/,/g, '');
        else if (c > -1) t = t.replace(',', '.');
        var n = Number(t);
        return isFinite(n) ? n : 0;
    }
    function fmtFecha(iso) { try { var d = new Date(iso); return d.toLocaleDateString('es-VE', { day: '2-digit', month: '2-digit', year: 'numeric' }) + ' ' + d.toLocaleTimeString('es-VE', { hour: '2-digit', minute: '2-digit' }); } catch (e) { return ''; } }
    function pintarEq() {
        var inp = document.getElementById('nk-tasa-in'); if (!inp) return;
        var v = numTasa(inp.value) || TASA.actual;
        var eq = document.getElementById('nk-tasa-eq'); if (eq) eq.textContent = '1 USD = ' + fmtTasa(v) + ' VES';
    }
    function abrirTasa() {
        var inp = document.getElementById('nk-tasa-in');
        if (inp) { inp.value = TASA.actual ? Number(TASA.actual).toLocaleString('es-VE', { minimumFractionDigits: 2, maximumFractionDigits: 4 }) : ''; }
        pintarEq();
        if (typeof supabaseClient !== 'undefined') {
            supabaseClient.from('tasas_historial').select('*').order('created_at', { ascending: false }).limit(1).then(function (r) {
                var el = document.getElementById('nk-tasa-upd'); if (!el) return;
                var h = r && !r.error && r.data && r.data[0];
                el.textContent = h ? 'Última actualización: ' + fmtFecha(h.created_at) + (h.usuario_nombre ? ' por ' + h.usuario_nombre : '') : 'Última actualización: sin registro';
            });
        }
        if (!TASA.bcv) {
            fetch('/api/tasa-bcv').then(function (r) { return r.json(); }).then(function (d) {
                var b = document.getElementById('nk-bcv'), bt = document.getElementById('nk-usar-bcv');
                if (d && d.ok && d.tasa > 0) { TASA.bcv = Number(d.tasa); if (b) b.textContent = fmtTasa(TASA.bcv); if (bt) bt.disabled = false; }
                else if (b) b.textContent = 'no disponible';
            }).catch(function () { var b = document.getElementById('nk-bcv'); if (b) b.textContent = 'no disponible'; });
        }
    }
    function prepararTasa(bar) {
        var inp = bar.querySelector('#nk-tasa-in');
        inp.addEventListener('input', pintarEq);
        inp.addEventListener('keydown', function (e) { if (e.key === 'Enter') { e.preventDefault(); guardarTasa(); } });
        bar.querySelectorAll('[data-step]').forEach(function (b) {
            var timer = null;
            function paso() { var v = numTasa(inp.value) || TASA.actual || 0; v = Math.max(0.01, Math.round((v + Number(b.dataset.step) * 0.01) * 10000) / 10000); inp.value = v.toLocaleString('es-VE', { minimumFractionDigits: 2, maximumFractionDigits: 4 }); pintarEq(); }
            b.addEventListener('click', paso);
            b.addEventListener('pointerdown', function () { timer = setTimeout(function rep() { paso(); timer = setTimeout(rep, 60); }, 450); });
            ['pointerup', 'pointerleave', 'pointercancel'].forEach(function (ev) { b.addEventListener(ev, function () { clearTimeout(timer); }); });
        });
        var ub = bar.querySelector('#nk-usar-bcv');
        if (ub) ub.addEventListener('click', function () { if (TASA.bcv) { inp.value = TASA.bcv.toLocaleString('es-VE', { minimumFractionDigits: 2, maximumFractionDigits: 4 }); pintarEq(); } });
        bar.querySelector('#nk-tasa-ok').addEventListener('click', guardarTasa);
    }
    function guardarTasa() {
        var inp = document.getElementById('nk-tasa-in'), btn = document.getElementById('nk-tasa-ok');
        var t = numTasa(inp && inp.value);
        if (!(t > 0)) { aviso('Escribe una tasa válida', 'warning'); return; }
        if (TASA.actual && Math.abs(t - TASA.actual) / TASA.actual > 0.25 && !confirm('La tasa cambia más de 25% (de ' + fmtTasa(TASA.actual) + ' a ' + fmtTasa(t) + '). ¿Seguro?')) return;
        btn.disabled = true;
        supabaseClient.rpc('config_actualizar_tasa', { p_tasa: t }).then(function (r) {
            btn.disabled = false;
            if (r.error) { aviso('No se pudo guardar la tasa: ' + (r.error.message || ''), 'error'); return; }
            var u = window.getSesionUsuario && window.getSesionUsuario();
            supabaseClient.rpc('tasa_historial_firmar', { p_usuario: u ? u.nombre : '' }).then(function () {}, function () {});
            TASA.actual = t; ponerTasa(t);
            try { var cc = window.refCacheGet && window.refCacheGet('refrimar_cache_config'); if (cc) { cc.tasa_bcv_manual = t; window.refCacheSet('refrimar_cache_config', cc); } } catch (e) {}
            aviso('Tasa actualizada: ' + fmtTasa(t) + ' VES', 'success');
            var box = document.querySelector('[data-nk-box="tasa"]'); if (box) box.classList.remove('open');
            try { window.dispatchEvent(new CustomEvent('refrimar:tasa', { detail: { tasa: t } })); } catch (e) {}
        });
    }
    function aviso(msg, tipo) {
        if (typeof window.showToast === 'function') window.showToast(msg, tipo);
        else if (window.nk && nk.toast) nk.toast(msg, tipo);
        else alert(msg);
    }

    // ---------- Cambiar tienda (solo admin) ----------
    function abrirTiendas() {
        if (typeof supabaseClient === 'undefined') return;
        var actual = null; try { actual = JSON.parse(sessionStorage.getItem(window.REF_SUCURSAL_KEY) || 'null'); } catch (e) {}
        var casa = window.CASA_MATRIZ_ID || '00000000-0000-0000-0000-000000000001';
        supabaseClient.from('sucursales').select('id,nombre').order('nombre').then(function (r) {
            var lista = [{ id: casa, nombre: 'Casa Matriz' }].concat((r && r.data) || []);
            var ov = document.createElement('div');
            ov.className = 'nk-store-ov';
            ov.innerHTML = '<div class="nk-store-box"><div class="nk-pop-title">Cambiar tienda</div><div class="nk-pop-sub">Todo lo que hagas (ventas, stock, caja) quedará en la tienda que elijas.</div>' +
                lista.map(function (s) { var on = actual && actual.id === s.id; return '<button type="button" data-id="' + esc(s.id) + '" class="' + (on ? 'on' : '') + '"><span class="material-symbols-outlined">storefront</span>' + esc(s.nombre) + (on ? '<span class="nk-menu-val">Actual</span>' : '') + '</button>'; }).join('') +
                '<button type="button" class="nk-store-x">Cancelar</button></div>';
            document.body.appendChild(ov);
            function cerrar() { ov.remove(); }
            ov.addEventListener('click', function (e) { if (e.target === ov) cerrar(); });
            ov.querySelector('.nk-store-x').addEventListener('click', cerrar);
            ov.querySelectorAll('[data-id]').forEach(function (b) {
                b.addEventListener('click', function () {
                    var s = lista.find(function (x) { return x.id === b.dataset.id; });
                    if (!s) return;
                    window.guardarSucursalSesion({ id: s.id, nombre: s.nombre });
                    location.reload();
                });
            });
        });
    }

    function ponerTasa(v) { if (v) TASA.actual = Number(v); var el = document.getElementById('nk-tasa'); if (el && v) el.textContent = fmtTasa(v); }
    function cargarTasa() {
        try { var c = window.refCacheGet && window.refCacheGet('refrimar_cache_config'); if (c && c.tasa_bcv_manual) ponerTasa(c.tasa_bcv_manual); } catch (e) {}
        try {
            if (typeof supabaseClient === 'undefined') return;
            supabaseClient.from('configuracion').select('tasa_bcv_manual').limit(1).maybeSingle().then(function (r) {
                if (r && r.data && r.data.tasa_bcv_manual) ponerTasa(r.data.tasa_bcv_manual);
            });
        } catch (e) {}
    }

    function aplicar() {
        if (!window.getSesionUsuario || !window.getSesionUsuario()) return;
        try { logo(); linkActivo(); tituloLimpio(); topbar(); } catch (e) { console.warn('[nk]', e); }
    }
    aplicar();
    document.addEventListener('DOMContentLoaded', aplicar);
})();
