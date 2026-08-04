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
