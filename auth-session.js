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
            ['inventario.html', 'inventory_2', 'Productos e inventario', 'inventario'],
            ['conteos.html', 'fact_check', 'Conteo de inventario', 'inventario'],
            ['precios.html', 'sell', 'Actualización de precios', 'inventario'],
            ['kardex.html', 'swap_vert', 'Kardex', 'kardex'],
            ['carga-ia.html', 'document_scanner', 'Carga IA de facturas', 'carga-ia']] },
        { titulo: 'Compras', items: [
            ['ordenes_compra.html', 'shopping_cart', 'Órdenes de compra', 'compras'],
            ['compras.html', 'local_shipping', 'Recepción y proveedores', 'compras'],
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
        'conteos.html': 'Inventario', 'precios.html': 'Inventario', 'ordenes_compra.html': 'Compras'
    };
    var NOMBRE = {
        'facturacion.html': 'Punto de venta', 'cotizaciones.html': 'Cotizaciones', 'caja.html': 'Caja', 'devoluciones.html': 'Devoluciones',
        'inventario.html': 'Inventario', 'kardex.html': 'Kardex', 'clientes.html': 'Clientes', 'compras.html': 'Compras', 'gastos.html': 'Gastos', 'carga-ia.html': 'Carga IA',
        'cuentas_por_cobrar.html': 'Cuentas por cobrar', 'cuentas_por_pagar.html': 'Cuentas por pagar', 'cierre_diario.html': 'Cierre diario', 'reportes.html': 'Reportes',
        'usuarios.html': 'Colaboradores', 'sucursales.html': 'Sucursales', 'configuracion.html': 'Configuración', 'dashboard.html': 'Dashboard',
        'facturas.html': 'Facturas', 'turnos.html': 'Turnos', 'app-pos.html': 'App POS y cajas',
        'conteos.html': 'Conteo de inventario', 'precios.html': 'Actualización de precios', 'ordenes_compra.html': 'Órdenes de compra'
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

    function linkActivo() {
        var pag = pagina();
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
        var bar = document.createElement('div');
        bar.className = 'nk-topbar';
        bar.innerHTML =
            '<div class="nk-crumbs">' + (SECCION[pag] ? esc(SECCION[pag]) + ' <span>/</span> ' : '') + '<b>' + esc(NOMBRE[pag] || '') + '</b></div>' +
            '<div class="nk-top-right">' +
                '<span class="nk-pill nk-pill-suc" title="Sucursal activa"><span class="material-symbols-outlined">storefront</span>' + esc(suc.nombre || 'Casa Matriz') + '</span>' +
                '<span class="nk-pill" title="Tasa BCV"><span class="material-symbols-outlined">currency_exchange</span><span id="nk-tasa">—</span> VES</span>' +
                '<div class="nk-user"><button type="button" class="nk-user-btn"><span class="nk-avatar">' + esc(ini) + '</span>' + esc(nombre) +
                    '<span class="material-symbols-outlined" style="font-size:18px">expand_more</span></button>' +
                    '<div class="nk-user-menu"><div class="nk-menu-head"><b>' + esc(nombre) + '</b>' + (u.rol === 'admin' ? 'Administrador' : 'Empleado · ' + esc(u.rol)) + '</div>' +
                    (window.can('configuracion') ? '<button type="button" data-nk="config"><span class="material-symbols-outlined">settings</span>Configuración</button>' : '') +
                    '<button type="button" data-nk="salir"><span class="material-symbols-outlined">logout</span>Cerrar sesión</button></div>' +
                '</div>' +
            '</div>';
        main.insertBefore(bar, main.firstChild);
        var box = bar.querySelector('.nk-user');
        bar.querySelector('.nk-user-btn').addEventListener('click', function (e) { e.stopPropagation(); box.classList.toggle('open'); });
        document.addEventListener('click', function () { box.classList.remove('open'); });
        bar.querySelectorAll('[data-nk]').forEach(function (b) {
            b.addEventListener('click', function () {
                if (b.dataset.nk === 'salir') window.cerrarSesion();
                else location.href = 'configuracion.html';
            });
        });
        cargarTasa();
    }

    function ponerTasa(v) { var el = document.getElementById('nk-tasa'); if (el && v) el.textContent = fmtTasa(v); }
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
