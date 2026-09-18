// ============================================================
// UBICACIÓN ACTUAL — REFRIMAR OS
// ------------------------------------------------------------
// La ubicación (Casa Matriz / Sucursal) se elige SOLO al iniciar
// sesión en login.html (Paso 1, obligatorio) y queda guardada en
// sessionStorage. Este archivo se incluye en cada página para que
// pueda leerse en cualquier momento:
//
//   var suc = window.getSucursalActual();
//   console.log(suc.id, suc.nombre);
//
// NO se muestra ningún selector en las pantallas: la ubicación no
// se puede cambiar a mitad de sesión desde la esquina. Para cambiar
// de tienda, el usuario cierra sesión y vuelve a elegir ubicación
// en login.html.
// ============================================================

window.CASA_MATRIZ_ID = '00000000-0000-0000-0000-000000000001';
const SUCURSAL_STORAGE_KEY = 'refrimar_sucursal_actual';

function getSucursalActual() {
    try {
        var raw = sessionStorage.getItem(SUCURSAL_STORAGE_KEY);
        if (!raw) return { id: window.CASA_MATRIZ_ID, nombre: 'Casa Matriz' };
        return JSON.parse(raw);
    } catch (e) {
        return { id: window.CASA_MATRIZ_ID, nombre: 'Casa Matriz' };
    }
}
window.getSucursalActual = getSucursalActual;

function setSucursalActual(id, nombre) {
    var val = { id: id, nombre: nombre };
    sessionStorage.setItem(SUCURSAL_STORAGE_KEY, JSON.stringify(val));
    window.dispatchEvent(new CustomEvent('sucursalActualChanged', { detail: val }));
}
window.setSucursalActual = setSucursalActual;

// ============================================================
// INDICADOR DE SUCURSAL ACTIVA — badge reutilizable
// ------------------------------------------------------------
// Muestra en qué ubicación se está trabajando. Se usa en el sidebar
// de todas las páginas ([data-sucursal-badge]) y como chip flotante
// en móvil ([data-sucursal-badge-mobile]). Solo admins pueden hacer
// clic para ir a Sucursales (los demás ven el chip, no lo navegan).
// ============================================================

// True si el usuario logueado tiene rol admin (usa auth-session.js).
function esAdminActual() {
    try {
        var u = window.getSesionUsuario ? window.getSesionUsuario() : null;
        return !!(u && u.rol === 'admin');
    } catch (e) { return false; }
}
window.esAdminActual = esAdminActual;

// Estado de render de la ubicación (evita repetir esta lógica).
function sucursalActualRenderState() {
    var actual = window.getSucursalActual ? window.getSucursalActual() : { id: window.CASA_MATRIZ_ID, nombre: 'Casa Matriz' };
    var esCasaMatriz = !actual || actual.id === window.CASA_MATRIZ_ID;
    return {
        actual: actual,
        esCasaMatriz: esCasaMatriz,
        nombre: esCasaMatriz ? 'Casa Matriz' : (actual.nombre || 'Sucursal')
    };
}
window.sucursalActualRenderState = sucursalActualRenderState;

// Chip de ubicación: ícono warehouse (Casa Matriz) / storefront (sucursal).
// Si el usuario es admin y no está en sucursales.html, el chip navega ahí.
function renderSucursalBadge(container, opts) {
    if (!container) return;
    opts = opts || {};
    var estado = sucursalActualRenderState();
    var esCasa = estado.esCasaMatriz;
    var icono = esCasa ? 'warehouse' : 'storefront';
    var admin = opts.admin === undefined ? esAdminActual() : opts.admin;
    var esSucursalesPage = /sucursales\.html/.test(window.location.pathname);
    var clickable = admin && !esSucursalesPage && opts.clickable !== false;
    var tono = esCasa
        ? 'bg-surface-container-lowest/90 backdrop-blur-md border-primary/40 text-primary'
        : 'bg-surface-container-lowest/90 backdrop-blur-md border-[#006970]/40 text-[#006970]';
    var chip = '<span class="material-symbols-outlined" style="font-size:18px;">' + icono + '</span>'
        + '<span class="font-mono-data text-xs font-bold truncate">' + estado.nombre + '</span>'
        + (clickable ? '<span class="material-symbols-outlined" style="font-size:15px;opacity:.7;">open_in_new</span>' : '');
    var cls = 'flex items-center gap-2 px-3 py-2 rounded-lg border shadow-sm transition-all ' + tono;
    if (clickable) {
        cls += ' cursor-pointer hover:brightness-95 active:scale-[0.98]';
        container.innerHTML = '<a href="sucursales.html" title="Ir a Sucursales" class="' + cls + '">' + chip + '</a>';
    } else {
        container.innerHTML = '<div class="' + cls + '">' + chip + '</div>';
    }
}
window.renderSucursalBadge = renderSucursalBadge;

// Nota bajo el título de Inventario/Facturación: badge con más peso visual.
// En una sucursal incluye candado + tono de advertencia para aclarar que
// la edición de catálogo está deshabilitada aquí.
function renderSucursalVistaInfo(container) {
    if (!container) return;
    var estado = sucursalActualRenderState();
    if (estado.esCasaMatriz) {
        container.innerHTML =
            '<div class="inline-flex items-center gap-2 mt-1.5 px-3 py-1.5 rounded-lg bg-primary/10 border border-primary/25 text-primary font-mono-data text-[11px]">'
            + '<span class="material-symbols-outlined" style="font-size:16px;">warehouse</span>'
            + '<span>Viendo: <b>Casa Matriz</b> — catálogo completo</span>'
            + '</div>';
    } else {
        container.innerHTML =
            '<div class="inline-flex flex-wrap items-center gap-x-2 gap-y-1 mt-1.5 px-3 py-1.5 rounded-lg bg-[#006970]/5 border border-[#006970]/25 text-on-surface-variant font-mono-data text-[11px]">'
            + '<span class="material-symbols-outlined" style="font-size:16px;color:#006970;">storefront</span>'
            + '<span>Viendo: <b>' + estado.nombre + '</b> — stock propio de esta sucursal</span>'
            + '<span class="inline-flex items-center gap-1 text-error/90"><span class="material-symbols-outlined" style="font-size:14px;">lock</span>edición de catálogo deshabilitada aquí</span>'
            + '</div>';
    }
}
window.renderSucursalVistaInfo = renderSucursalVistaInfo;

// Pastilla compacta (ícono + nombre) para headers tipo facturacion/caja.
function renderSucursalPill(container) {
    if (!container) return;
    var estado = sucursalActualRenderState();
    container.innerHTML =
        '<span class="material-symbols-outlined" style="font-size:16px;">' + (estado.esCasaMatriz ? 'warehouse' : 'storefront') + '</span>'
        + '<span class="truncate">' + estado.nombre + '</span>';
}
window.renderSucursalPill = renderSucursalPill;

// Auto-render: si la página tiene los contenedores, los llena al cargar
// y los mantiene al día cuando cambia la ubicación (sucursalActualChanged).
function renderSucursalIndicadores() {
    document.querySelectorAll('[data-sucursal-badge]').forEach(function(c) { renderSucursalBadge(c); });
    document.querySelectorAll('[data-sucursal-badge-mobile]').forEach(function(c) { renderSucursalBadge(c); });
    var vista = document.getElementById('inv-sucursal-info');
    if (vista) renderSucursalVistaInfo(vista);
    var pill = document.getElementById('fact-sucursal-badge');
    if (pill) renderSucursalPill(pill);
}
window.renderSucursalIndicadores = renderSucursalIndicadores;

window.addEventListener('DOMContentLoaded', renderSucursalIndicadores);
window.addEventListener('sucursalActualChanged', renderSucursalIndicadores);
