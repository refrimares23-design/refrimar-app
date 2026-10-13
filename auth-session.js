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
        'configuracion.html': 'configuracion'
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

    // ---- 2. Sidebar agrupado; links sin permiso no se renderizan ----
    var GRUPOS = [
        { titulo: null, paginas: ['dashboard.html'] },
        { titulo: 'Operación', paginas: ['facturacion.html', 'cotizaciones.html', 'caja.html', 'devoluciones.html'] },
        { titulo: 'Gestión', paginas: ['inventario.html', 'kardex.html', 'clientes.html', 'compras.html', 'gastos.html', 'carga-ia.html'] },
        { titulo: 'Finanzas', paginas: ['cuentas_por_cobrar.html', 'cuentas_por_pagar.html', 'cierre_diario.html', 'reportes.html'] },
        { titulo: 'Admin', paginas: ['usuarios.html', 'sucursales.html', 'configuracion.html'] }
    ];
    var ETIQUETAS = { 'facturacion.html': 'POS / Facturación', 'cuentas_por_cobrar.html': 'Cuentas x Cobrar', 'cuentas_por_pagar.html': 'Cuentas x Pagar' };

    window.organizarSidebar = function () {
        var nav = document.querySelector('#sidebar nav');
        if (!nav || nav.dataset.refOrganizado) return;
        var mapa = {};
        nav.querySelectorAll('a.nav-link').forEach(function (a) {
            var pag = (a.getAttribute('href') || '').split('?')[0].toLowerCase();
            mapa[pag] = a;
        });
        nav.querySelectorAll('.sidebar-section-label').forEach(function (l) { l.remove(); });
        var usados = {};
        GRUPOS.forEach(function (g) {
            var visibles = g.paginas.filter(function (p) {
                return mapa[p] && window.can(PAGINA_PERMISO[p] || 'x');
            });
            if (!visibles.length) return;
            if (g.titulo) {
                var lab = document.createElement('div');
                lab.className = 'sidebar-section-label';
                lab.textContent = g.titulo;
                nav.appendChild(lab);
            }
            visibles.forEach(function (p) {
                var a = mapa[p];
                if (ETIQUETAS[p]) { var sp = a.querySelector('span.font-mono-data'); if (sp) sp.textContent = ETIQUETAS[p]; }
                nav.appendChild(a);
                usados[p] = true;
            });
        });
        // Lo que no tiene permiso (o no está en grupos) ni siquiera se renderiza.
        Object.keys(mapa).forEach(function (p) {
            if (!usados[p]) mapa[p].remove();
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
