// ============================================================
// CONFIGURACIÓN DE SUPABASE — REFRIMAR OS
// ------------------------------------------------------------
// 1. Ve a https://supabase.com → tu proyecto → Settings → API
// 2. Copia "Project URL" y pégalo abajo en SUPABASE_URL
// 3. Copia la clave "anon public" y pégala en SUPABASE_ANON_KEY
// ============================================================
const SUPABASE_URL = "https://hjecifftqidqeswcpvwt.supabase.co";
const SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImhqZWNpZmZ0cWlkcWVzd2Nwdnd0Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODUxMDE0NzAsImV4cCI6MjEwMDY3NzQ3MH0.X0pqSe-CVjDgEVO2Cgd89pucXs-cfC7MbJIlx4hfKGM";

// Columnas de "usuarios" que puede leer la página. El PIN NO se puede leer desde
// internet (ver REFRIMAR-SQL-actualizacion-octubre-2026.sql), así que nunca usar select('*') en usuarios.
window.REF_USUARIO_COLS = 'id,nombre,nombres,apellido,rol,activo,estado,permisos,sucursal_id,sucursales,email,telefono,avatar_url,invitado_at,aceptado_at,created_at';

// ---- Token de sesión ----
// Cada llamada a la base de datos lleva el token del colaborador que entró
// (cabecera x-refrimar-sesion). La base de datos lo revisa antes de dejar
// escribir: así nadie puede facturar o cambiar precios solo con la clave pública.
window.refTokenSesion = function () {
    try {
        var u = JSON.parse(sessionStorage.getItem('refrimar_user') || 'null');
        if (u && u.token) return u.token;
    } catch (e) {}
    // Caja (POS): último token guardado en este equipo, para sincronizar ventas
    // que quedaron pendientes sin internet aunque se haya cerrado la ventana.
    try { return localStorage.getItem('refrimar_pos_token') || ''; } catch (e) { return ''; }
};
function refFetchConSesion(input, init) {
    try {
        var url = typeof input === 'string' ? input : (input && input.url) || '';
        var tok = url.indexOf('/rest/v1/') >= 0 ? window.refTokenSesion() : '';
        if (tok) {
            init = Object.assign({}, init || {});
            var h = new Headers((init && init.headers) || (typeof input !== 'string' && input && input.headers) || {});
            h.set('x-refrimar-sesion', tok);
            init.headers = h;
        }
    } catch (e) {}
    return fetch(input, init);
}

const supabaseClient = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY, { global: { fetch: refFetchConSesion } });
