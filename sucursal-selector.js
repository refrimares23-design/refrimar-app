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
