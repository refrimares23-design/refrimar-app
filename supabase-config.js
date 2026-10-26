// ============================================================
// CONFIGURACIÓN DE SUPABASE — REFRIMAR OS
// ------------------------------------------------------------
// 1. Ve a https://supabase.com → tu proyecto → Settings → API
// 2. Copia "Project URL" y pégalo abajo en SUPABASE_URL
// 3. Copia la clave "anon public" y pégala en SUPABASE_ANON_KEY
// ============================================================
var SUPABASE_URL = "https://hjecifftqidqeswcpvwt.supabase.co";
var SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImhqZWNpZmZ0cWlkcWVzd2Nwdnd0Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODUxMDE0NzAsImV4cCI6MjEwMDY3NzQ3MH0.X0pqSe-CVjDgEVO2Cgd89pucXs-cfC7MbJIlx4hfKGM";

// Columnas de "usuarios" que puede leer la página. El PIN NO se puede leer desde
// internet (ver el SQL de seguridad), así que nunca usar select('*') en usuarios.
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
    return fetch(input, init).then(refErroresAmigables);
}
// Los errores técnicos de la base (tablas, columnas, restricciones) no se muestran al usuario:
// se cambian por un mensaje claro y el detalle queda solo en la consola del navegador.
window.refErrorAmigable = function (code, msg) {
    code = String(code || ''); msg = String(msg || '');
    if (code === 'P0001' || /^PT4/.test(code)) return msg;                       // mensajes escritos para el usuario
    if (code === '42501' || /permission denied/i.test(msg)) return 'No tienes permiso para hacer esto.';
    if (code === '23505') return 'Ya existe un registro con ese dato (código o número repetido).';
    if (code === '23503') return 'No se puede: hay otros registros que dependen de este.';
    if (code === '23502') return 'Falta un dato obligatorio.';
    if (code === '23514') return 'Hay un dato fuera de lo permitido.';
    if (/^22/.test(code)) return 'Hay un dato con formato inválido (revisa números y fechas).';
    if (code === '57014') return 'La operación tardó demasiado. Intenta de nuevo.';
    if (code === 'PGRST202' || code === '42883' || /Could not find the function|schema cache/i.test(msg)) return 'Falta actualizar la base de datos (corre el último archivo SQL en Supabase).';
    if (/relation|column|syntax|violates|function|constraint|operator|null value/i.test(msg)) return 'No se pudo completar la operación. Intenta de nuevo; si sigue, avísale al administrador.';
    return msg;
};
function refErroresAmigables(r) {
    try {
        if (r.ok || r.status < 400 || !/\/rest\/v1\//.test(r.url || '')) return r;
        return r.clone().json().then(function (j) {
            if (!j || typeof j !== 'object' || !j.message) return r;
            var nuevo = window.refErrorAmigable(j.code, j.message);
            if (nuevo === j.message) return r;
            console.warn('[base de datos]', j.code, j.message, j.details || '', j.hint || '');
            var b = Object.assign({}, j, { message: nuevo, details: null, hint: null });
            return new Response(JSON.stringify(b), { status: r.status, statusText: r.statusText, headers: r.headers });
        }, function () { return r; });
    } catch (e) { return r; }
}

// Cabeceras para las rutas propias del servidor (/api/...): sesión y empresa
window.refCabecerasApi = function (extra) {
    var h = Object.assign({ 'Content-Type': 'application/json' }, extra || {});
    try { var t = window.refTokenSesion(); if (t) h['x-refrimar-sesion'] = t; } catch (e) {}
    try { h['x-refrimar-empresa'] = window.refEmpresaEsquema(); } catch (e) {}
    return h;
};

// Escapa texto antes de meterlo en HTML (nombres de productos, tiendas, clientes)
window.refEsc = function (v) { return String(v == null ? '' : v).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); };

// ---- Empresa activa (multiempresa) ----
// Cada empresa tiene su propio espacio de datos. REFRIMAR usa "public".
// La empresa elegida en el login queda guardada en este equipo (ref_empresa).
window.refEmpresaActiva = function () {
    try {
        var e = JSON.parse(localStorage.getItem('ref_empresa') || 'null');
        if (e && /^(public|e_[a-z0-9_]{2,40})$/.test(e.esquema || '')) return e;
    } catch (e) {}
    return { esquema: 'public', slug: 'refrimar', nombre: '' };
};
window.refEmpresaEsquema = function () { return window.refEmpresaActiva().esquema; };

// ---- Librería de Supabase ----
// Se busca en este orden: la que trae la página → copia en la raíz del sitio →
// carpeta vendor/ → CDN. Si ninguna carga (sin internet la primera vez), la página
// NO se rompe: muestra un aviso claro y cada consulta responde con ese error.
(function () {
    var LIB = 'supabase-js-2.117.2.js';
    var FUENTES = ['/' + LIB, '/vendor/' + LIB, 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.117.2/dist/umd/supabase.js'];
    var lista = function () { return window.supabase && typeof window.supabase.createClient === 'function'; };

    if (lista()) {
        var opts = { global: { fetch: refFetchConSesion } };
        var esq = window.refEmpresaEsquema();
        if (esq !== 'public') opts.db = { schema: esq };
        window.supabaseClient = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY, opts);
        // Funciones de la plataforma (registro, empresas, suscripción): siempre en public
        window.refPlataforma = function () { return esq === 'public' ? window.supabaseClient : window.supabaseClient.schema('public'); };
        return;
    }
    var n = window.__refSbIntento || 0;
    if (n < FUENTES.length && document.readyState === 'loading') {
        // Mientras la página se está leyendo, document.write mantiene el orden:
        // la librería y esta configuración quedan ANTES de auth-session.js y demás.
        window.__refSbIntento = n + 1;
        document.write('<script src="' + FUENTES[n] + '"><\/script><script src="/supabase-config.js?intento=' + (n + 1) + '"><\/script>');
        return;
    }

    // Ninguna fuente cargó: cliente "de aviso" para que nada lance supabaseClient is not defined
    var MSG = 'No se pudo cargar la conexión con la base de datos. Revisa el internet y recarga la página (Ctrl+F5).';
    var err = { message: MSG, code: 'REF_SIN_LIBRERIA' };
    function respuesta() { return Promise.resolve({ data: null, error: err, count: null }); }
    function constructor() {
        var p = respuesta();
        return new Proxy(function () {}, {
            get: function (t, k) {
                if (k === 'then') return p.then.bind(p);
                if (k === 'catch') return p.catch.bind(p);
                if (k === 'finally') return p.finally.bind(p);
                return function () { return constructor(); };
            },
            apply: function () { return constructor(); }
        });
    }
    var authVacio = {
        getSession: function () { return Promise.resolve({ data: { session: null }, error: err }); },
        getUser: function () { return Promise.resolve({ data: { user: null }, error: err }); },
        onAuthStateChange: function () { return { data: { subscription: { unsubscribe: function () {} } } }; },
        signInWithOAuth: function () { return Promise.resolve({ data: null, error: err }); },
        signOut: function () { return Promise.resolve({ error: null }); }
    };
    window.supabaseClient = {
        from: function () { return constructor(); },
        rpc: function () { return constructor(); },
        channel: function () { return { on: function () { return this; }, subscribe: function () { return this; } }; },
        removeChannel: function () {},
        storage: { from: function () { return constructor(); } },
        auth: new Proxy(authVacio, { get: function (t, k) { return t[k] || function () { return Promise.resolve({ data: null, error: err }); }; } }),
        __sinLibreria: true
    };
    window.refPlataforma = function () { return window.supabaseClient; };
    function aviso() {
        if (document.getElementById('ref-aviso-conexion')) return;
        var d = document.createElement('div');
        d.id = 'ref-aviso-conexion';
        d.setAttribute('role', 'alert');
        d.style.cssText = 'position:fixed;left:50%;bottom:16px;transform:translateX(-50%);z-index:99999;max-width:min(560px,calc(100% - 24px));background:#0A2540;color:#fff;border-radius:16px;padding:14px 16px;font:500 14px/1.45 Inter,system-ui,sans-serif;box-shadow:0 12px 30px rgba(10,37,64,.3);display:flex;gap:12px;align-items:center';
        d.innerHTML = '<span style="flex:1">' + MSG + '</span><button type="button" style="border:0;border-radius:999px;background:#00AAFF;color:#0A2540;font:600 14px Poppins,sans-serif;padding:9px 16px;cursor:pointer">Recargar</button>';
        d.querySelector('button').onclick = function () { location.reload(); };
        document.body.appendChild(d);
    }
    if (document.body) aviso(); else document.addEventListener('DOMContentLoaded', aviso);
    try { console.error('[REFRIMAR] ' + MSG); } catch (e) {}
})();
// Alias global (las páginas usan "supabaseClient" directamente)
var supabaseClient = window.supabaseClient;
