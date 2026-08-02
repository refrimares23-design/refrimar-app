// ============================================================
// SELECTOR GLOBAL DE "SUCURSAL ACTUAL" — REFRIMAR OS
// ------------------------------------------------------------
// Se incluye en cada página DESPUÉS de supabase-config.js.
// Inyecta un dropdown en la cabecera (arriba del <main>) con
// "Casa Matriz" + todas las filas de la tabla `sucursales`.
//
// La selección se guarda en localStorage y se anuncia al resto
// del sistema con un evento global 'sucursalActualChanged', para
// que cualquier página pueda escucharlo y refiltrar sus datos:
//
//   window.addEventListener('sucursalActualChanged', function(e) {
//       console.log(e.detail.id, e.detail.nombre);
//       // volver a cargar lo que corresponda...
//   });
//
// También expone window.getSucursalActual() para leerla en
// cualquier momento (por ejemplo al cargar la página).
// ============================================================

window.CASA_MATRIZ_ID = '00000000-0000-0000-0000-000000000001';
const SUCURSAL_STORAGE_KEY = 'refrimar_sucursal_actual';

function getSucursalActual() {
    try {
        var raw = localStorage.getItem(SUCURSAL_STORAGE_KEY);
        if (!raw) return { id: window.CASA_MATRIZ_ID, nombre: 'Casa Matriz' };
        return JSON.parse(raw);
    } catch (e) {
        return { id: window.CASA_MATRIZ_ID, nombre: 'Casa Matriz' };
    }
}
window.getSucursalActual = getSucursalActual;

function setSucursalActual(id, nombre) {
    var val = { id: id, nombre: nombre };
    localStorage.setItem(SUCURSAL_STORAGE_KEY, JSON.stringify(val));
    window.dispatchEvent(new CustomEvent('sucursalActualChanged', { detail: val }));
}
window.setSucursalActual = setSucursalActual;

async function initSucursalSelector() {
    if (typeof supabaseClient === 'undefined') return;

    var main = document.querySelector('.main-content');
    if (!main) return;

    var bar = document.createElement('div');
    bar.id = 'sucursal-actual-bar';
    bar.className = 'flex items-center justify-end gap-2 mb-3';
    bar.innerHTML =
        '<label for="sucursal-actual-select" class="text-[11px] font-bold uppercase text-on-surface-variant flex items-center gap-1">' +
        '<span class="material-symbols-outlined" style="font-size:16px;">storefront</span>Sucursal Actual</label>' +
        '<select id="sucursal-actual-select" class="rounded-md border border-outline-variant/60 px-2 py-1.5 text-xs font-mono-data outline-none focus:border-primary bg-white"></select>';
    main.insertBefore(bar, main.firstChild);

    var select = document.getElementById('sucursal-actual-select');

    var actual = getSucursalActual();
    select.innerHTML = '<option value="' + window.CASA_MATRIZ_ID + '">Casa Matriz</option>';

    var res = await supabaseClient.from('sucursales').select('id,nombre').order('nombre');
    if (!res.error && res.data) {
        res.data.forEach(function(s) {
            var opt = document.createElement('option');
            opt.value = s.id;
            opt.textContent = s.nombre;
            select.appendChild(opt);
        });
        // Si la sucursal guardada ya no existe, cae a Casa Matriz
        var existe = actual.id === window.CASA_MATRIZ_ID || res.data.some(function(s) { return s.id === actual.id; });
        if (!existe) actual = { id: window.CASA_MATRIZ_ID, nombre: 'Casa Matriz' };
    }

    select.value = actual.id;
    // Asegura que quede persistida (por si era la primera vez / había caído a Casa Matriz)
    setSucursalActual(actual.id, select.options[select.selectedIndex] ? select.options[select.selectedIndex].textContent : 'Casa Matriz');

    select.addEventListener('change', function() {
        var nombre = select.options[select.selectedIndex].textContent;
        setSucursalActual(select.value, nombre);
    });
}

document.addEventListener('DOMContentLoaded', function() {
    // checkAuth() en cada página corre de forma síncrona antes de esto;
    // damos un tick para no pelear con el render inicial del sidebar.
    setTimeout(initSucursalSelector, 0);
});
