/* ============================================================
   REFRIMAR POS — aplicación de punto de venta (estilo Norkut)
   Factura → Siguiente → Métodos de pago → Emitir factura
   Facturas / borradores · Nota de crédito · Arqueo · Dispositivos
   Todo se guarda en la misma base (Supabase) que el sistema
   administrativo. La impresora fiscal / de tickets se maneja con
   el programa de impresión local (REFRIMAR POS para Windows → http://localhost:3001).
   ============================================================ */
(function () {
'use strict';
var CASA = window.CASA_MATRIZ_ID || '00000000-0000-0000-0000-000000000001';
var BRIDGE = 'http://localhost:3001';
var VERSION = '1.0.0';
var $ = function (id) { return document.getElementById(id); };
var K_TIENDA = 'refrimar_pos_tienda', K_CFG = 'refrimar_pos_cfg', K_CARRO = 'refrimar_pos_carrito', K_TOKEN = 'refrimar_terminal_token', K_TERM = 'refrimar_terminal_nombre', K_ULT = 'refrimar_pos_ultima';

function ls(k, v) { try { if (v === undefined) return JSON.parse(localStorage.getItem(k) || 'null'); if (v === null) localStorage.removeItem(k); else localStorage.setItem(k, JSON.stringify(v)); } catch (e) { return null; } }
function esc(s) { return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); }
function f2(n, d) { d = d == null ? 2 : d; return Number(n || 0).toLocaleString('es-VE', { minimumFractionDigits: d, maximumFractionDigits: d }); }
function bs(n) { return f2(n) + ' Bs'; }
function usd(n) { return f2(n) + ' $'; }
function num(t) { t = String(t == null ? '' : t).trim().replace(/[^0-9.,-]/g, ''); if (!t) return 0; var c = t.lastIndexOf(','), d = t.lastIndexOf('.'); if (c > -1 && d > -1) t = c > d ? t.replace(/\./g, '').replace(',', '.') : t.replace(/,/g, ''); else if (c > -1) t = t.replace(/\./g, '').replace(',', '.'); var n = Number(t); return isFinite(n) ? n : 0; }
function r2(n) { return Math.round((Number(n) || 0) * 100) / 100; }
function cant(n) { var v = Number(n) || 0; return Number.isInteger(v) ? String(v) : v.toLocaleString('es-VE', { maximumFractionDigits: 3 }); }
function norm(s) { return String(s || '').toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, ''); }
function fecha(iso) { try { var d = new Date(iso); return d.toLocaleDateString('es-VE', { day: '2-digit', month: '2-digit', year: 'numeric' }).replace(/\//g, '-'); } catch (e) { return ''; } }
function hora(iso) { try { return new Date(iso).toLocaleTimeString('es-VE', { hour: '2-digit', minute: '2-digit' }); } catch (e) { return ''; } }
function sha256(str) { return crypto.subtle.digest('SHA-256', new TextEncoder().encode(str)).then(function (b) { return Array.from(new Uint8Array(b)).map(function (x) { return x.toString(16).padStart(2, '0'); }).join(''); }); }
function errMsg(e) { var m = (e && (e.message || e.details)) || String(e || 'Error'); return m; }
function faltaFn(e) { return /Could not find the function|schema cache|does not exist/i.test((e && e.message) || ''); }
function can(p) { return window.can ? window.can(p) : false; }
var METODO_NOMBRE = { efectivo: 'Efectivo', divisa: 'Efectivo', pago_movil: 'Pago móvil', punto: 'Débito', transferencia: 'Transferencia', zelle: 'Zelle', binance: 'Binance', otro: 'Otro', credito: 'Crédito', mixto: 'Mixto', rebaja_deuda: 'Rebaja de deuda' };
var METODO_ICONO = { efectivo: 'payments', divisa: 'payments', pago_movil: 'smartphone', punto: 'credit_card', transferencia: 'account_balance', zelle: 'currency_exchange', binance: 'currency_bitcoin', otro: 'more_horiz', credito: 'handshake' };
var BANCOS = ['Banco de Venezuela', 'Banesco', 'Mercantil', 'Provincial (BBVA)', 'Bancamiga', 'BNC', 'Banco del Tesoro', 'Bicentenario', 'Exterior', 'Venezolano de Crédito', 'Banplus', 'Sofitasa', 'Caroní', 'Plaza', 'Activo', 'Otro'];

var CFG_DEF = { modo: 'ticket', ancho: 42, gaveta: true, sonido: true, puerto: 'AUTO', modelo: 'Impresora fiscal PNP', codigos: { efectivo: '01', divisa: '02', pago_movil: '03', punto: '04', transferencia: '05', zelle: '06', binance: '07', otro: '08', credito: '09' } };
var S = {
    user: null, tienda: ls(K_TIENDA), cfg: Object.assign({}, CFG_DEF, ls(K_CFG) || {}), negocio: {}, ivaIncluido: false, tasa: 0,
    catalogo: [], porCodigo: {}, imgs: {}, carro: [], cliente: null, borradorId: null, turno: null, pagos: [], vuelto: [],
    vista: 'factura', monUSD: false, bridge: { ok: false, fiscal: null, printer: null }, nc: null
};
S.cfg.codigos = Object.assign({}, CFG_DEF.codigos, (ls(K_CFG) || {}).codigos || {});
if (!S.cfg.puertoManual) S.cfg.puerto = 'AUTO';
function guardarCfg() { ls(K_CFG, S.cfg); }

// ---------- Sonido ----------
var audio = null;
function beep(t) {
    if (!S.cfg.sonido) return;
    try { audio = audio || new (window.AudioContext || window.webkitAudioContext)(); var o = audio.createOscillator(), g = audio.createGain(); o.connect(g); g.connect(audio.destination); o.frequency.value = t === 'error' ? 220 : 880; g.gain.value = .05; o.start(); o.stop(audio.currentTime + (t === 'error' ? .25 : .07)); } catch (e) {}
}

// ---------- Avisos (abajo, como Norkut) ----------
function toast(titulo, detalle, tipo) {
    var ic = { success: 'check_circle', error: 'error', warning: 'warning', info: 'info' }[tipo || 'success'];
    var t = document.createElement('div');
    t.className = 'toast ' + (tipo || 'success');
    t.innerHTML = '<span class="material-symbols-outlined">' + ic + '</span><div><b>' + esc(titulo) + '</b>' + (detalle ? '<span class="d">' + esc(detalle) + '</span>' : '') + '</div>';
    $('toasts').appendChild(t);
    if (tipo === 'error') beep('error');
    setTimeout(function () { t.style.transition = 'opacity .3s'; t.style.opacity = '0'; setTimeout(function () { t.remove(); }, 300); }, tipo === 'error' ? 6000 : 3800);
}
window.showToast = function (m, tipo) { toast(m, '', tipo === 'success' || !tipo ? 'success' : tipo); };

// ---------- Modal ----------
function modal(o) {
    var w = document.createElement('div'); w.className = 'mov';
    w.innerHTML = '<div class="mbox' + (o.ancho ? ' ancho' : '') + '"><div class="mh2"><h3>' + esc(o.titulo || '') + '</h3><button type="button" data-x aria-label="Cerrar"><span class="material-symbols-outlined">close</span></button></div>' +
        (o.texto ? '<div class="mtx">' + o.texto + '</div>' : '') + (o.cuerpo || '') + (o.pie ? '<div class="mpie">' + o.pie + '</div>' : '') + '</div>';
    document.body.appendChild(w);
    function cerrar() { w.remove(); document.removeEventListener('keydown', k, true); if (o.alCerrar) o.alCerrar(); }
    function k(e) { if (e.key === 'Escape') { e.stopPropagation(); cerrar(); } }
    document.addEventListener('keydown', k, true);
    w.querySelector('[data-x]').addEventListener('click', cerrar);
    w.addEventListener('mousedown', function (e) { if (e.target === w) cerrar(); });
    var f = w.querySelector('input:not([type=checkbox]):not([disabled]),select'); if (f) setTimeout(function () { f.focus(); if (f.select) f.select(); }, 40);
    return { el: w, cerrar: cerrar, q: function (s) { return w.querySelector(s); } };
}
function menuEn(btn, items) {
    document.querySelectorAll('.pop').forEach(function (p) { p.remove(); });
    var r = btn.getBoundingClientRect(), p = document.createElement('div'); p.className = 'pop';
    p.innerHTML = items.map(function (it, i) { return '<button type="button" data-i="' + i + '"' + (it.off ? ' disabled' : '') + '><span class="material-symbols-outlined">' + it.ic + '</span>' + esc(it.t) + '</button>'; }).join('');
    document.body.appendChild(p);
    var top = r.bottom + 6, left = Math.max(8, r.right - p.offsetWidth);
    if (top + p.offsetHeight > innerHeight - 8) top = r.top - p.offsetHeight - 6;
    p.style.top = top + 'px'; p.style.left = left + 'px';
    p.addEventListener('click', function (e) { var b = e.target.closest('[data-i]'); if (!b || b.disabled) return; p.remove(); items[Number(b.dataset.i)].fn(); });
    setTimeout(function () { document.addEventListener('click', function f(e) { if (!p.contains(e.target)) { p.remove(); document.removeEventListener('click', f); } }); }, 0);
}

// ---------- Puente local (impresoras) ----------
async function puente(ruta, cuerpo, ms) {
    var ctl = new AbortController(), t = setTimeout(function () { ctl.abort(); }, ms || 4000);
    try {
        var r = await fetch(BRIDGE + ruta, cuerpo === undefined ? { signal: ctl.signal } : { method: 'POST', headers: { 'Content-Type': 'text/plain' }, body: JSON.stringify(cuerpo), signal: ctl.signal });
        clearTimeout(t);
        var d = await r.json().catch(function () { return {}; });
        if (!r.ok && d.ok === undefined) d.ok = false;
        return d;
    } catch (e) { clearTimeout(t); return { ok: false, sinPuente: true, error: 'No se encontró el programa de impresión en esta computadora. Instala REFRIMAR POS para Windows (Dispositivos → Descargar).' }; }
}
async function estadoPuente() {
    var h = await puente('/health', undefined, 2500);
    S.bridge.ok = !h.sinPuente; S.bridge.printer = h.ok ? h.printer : null;
    S.bridge.fiscal = null;
    if (!h.sinPuente) { var f = await puente('/fiscal/estado', undefined, 15000); S.bridge.fiscal = f; }
    // Si hay impresora fiscal conectada y nadie eligió otro modo a mano, se usa sola
    if (S.bridge.fiscal && S.bridge.fiscal.conectada && S.cfg.modo !== 'fiscal' && !S.cfg.modoManual) {
        S.cfg.modo = 'fiscal'; guardarCfg();
        toast('Impresora fiscal lista', (S.bridge.fiscal.modelo || 'Impresora fiscal') + (S.bridge.fiscal.puerto ? ' en ' + S.bridge.fiscal.puerto : '') + '. Las facturas saldrán por ahí.', 'info');
    }
    var st = $('t-imp-st');
    if (st) {
        var bien = S.cfg.modo === 'fiscal' ? !!(S.bridge.fiscal && S.bridge.fiscal.ok && S.bridge.fiscal.conectada) : S.cfg.modo === 'navegador' ? true : !!S.bridge.printer;
        st.className = bien ? '' : (S.bridge.ok ? 'err' : 'off');
        $('t-imp').title = S.cfg.modo === 'fiscal' ? (bien ? 'Impresora fiscal conectada' : 'Impresora fiscal no disponible') : S.cfg.modo === 'navegador' ? 'Impresión por el navegador' : (bien ? 'Impresora: ' + S.bridge.printer : 'Sin impresora de tickets');
    }
    return S.bridge;
}

/* ============================================================
   INICIO DE SESIÓN (PIN o Google) — la caja queda en su tienda
   ============================================================ */
var LOGIN = { modo: 'pin', pin: '', usuarios: [] };
function tiendaTxt() { var t = ls(K_TERM); return (t ? 'Caja ' + t + ' · ' : '') + (S.tienda ? S.tienda.nombre : 'Caja sin tienda asignada'); }
async function mostrarLogin(msg) {
    $('app').classList.add('hide'); $('login').classList.remove('hide');
    $('l-tienda').textContent = tiendaTxt();
    $('l-msg').textContent = msg || '';
    LOGIN.pin = ''; pintarPin();
    var r = await supabaseClient.from('usuarios').select('id,nombre,rol,sucursales,sucursal_id,activo').eq('activo', true).order('nombre');
    if (r.error) r = await supabaseClient.from('usuarios').select('id,nombre,rol,sucursal_id,activo').eq('activo', true).order('nombre');
    LOGIN.usuarios = (r.data || []).filter(function (u) {
        if (!S.tienda || u.rol === 'admin') return true;
        var l = (u.sucursales && u.sucursales.length) ? u.sucursales : (u.sucursal_id ? [u.sucursal_id] : []);
        return !l.length || l.indexOf(S.tienda.id) >= 0;
    });
    var ult = ls('refrimar_pos_ultimo_usuario');
    $('l-user').innerHTML = '<option value="">Selecciona tu usuario…</option>' + LOGIN.usuarios.map(function (u) { return '<option' + (u.nombre === ult ? ' selected' : '') + '>' + esc(u.nombre) + '</option>'; }).join('');
}
function pintarPin() { document.querySelectorAll('#l-dots i').forEach(function (d, i) { d.classList.toggle('on', i < LOGIN.pin.length); }); }
document.querySelectorAll('.lop').forEach(function (b) {
    b.addEventListener('click', function () {
        LOGIN.modo = b.dataset.lm;
        document.querySelectorAll('.lop').forEach(function (x) { x.classList.toggle('on', x === b); });
        $('l-pin').classList.toggle('hide', LOGIN.modo !== 'pin'); $('l-google').classList.toggle('hide', LOGIN.modo !== 'google');
        $('l-msg').textContent = '';
    });
});
$('l-pad').addEventListener('click', function (e) {
    var b = e.target.closest('button'); if (!b) return;
    if (b.dataset.k === 'borrar') { LOGIN.pin = ''; pintarPin(); return; }
    if (b.dataset.k === 'ok') { entrarPin(); return; }
    if (LOGIN.pin.length < 4) { LOGIN.pin += b.textContent.trim(); pintarPin(); }
    if (LOGIN.pin.length === 4) entrarPin();
});
document.addEventListener('keydown', function (e) {
    if ($('login').classList.contains('hide') || LOGIN.modo !== 'pin' || document.activeElement === $('l-user') && e.key.length > 1 && e.key !== 'Backspace' && e.key !== 'Enter') return;
    if (/^\d$/.test(e.key) && LOGIN.pin.length < 4) { LOGIN.pin += e.key; pintarPin(); if (LOGIN.pin.length === 4) entrarPin(); }
    else if (e.key === 'Backspace') { LOGIN.pin = LOGIN.pin.slice(0, -1); pintarPin(); }
    else if (e.key === 'Enter') entrarPin();
});
async function entrarPin() {
    if (LOGIN.ocupado) return;
    LOGIN.ocupado = true;
    try { await entrarPinX(); } finally { LOGIN.ocupado = false; }
}
async function entrarPinX() {
    var nombre = $('l-user').value, msg = $('l-msg');
    if (!nombre) { msg.textContent = 'Selecciona tu usuario'; LOGIN.pin = ''; pintarPin(); return; }
    if (LOGIN.pin.length !== 4) { msg.textContent = 'Ingresa los 4 dígitos de tu PIN'; return; }
    msg.style.color = 'var(--tx3)'; msg.textContent = 'Verificando…';
    var r = await window.refLoginPin(nombre, await sha256(LOGIN.pin), 'pos');
    msg.style.color = '';
    if (r.error || !r.data || !r.data.success) { msg.textContent = (r.data && r.data.bloqueado && r.data.error) || 'PIN incorrecto'; LOGIN.pin = ''; pintarPin(); beep('error'); return; }
    ls('refrimar_pos_ultimo_usuario', nombre);
    msg.textContent = '';
    var u = await supabaseClient.from('usuarios').select(window.REF_USUARIO_COLS || 'id,nombre,rol').eq('id', r.data.id).maybeSingle();
    var d = (u && u.data) || {};
    await iniciarSesion({ id: r.data.id, nombre: r.data.nombre, rol: r.data.rol, permisos: d.permisos || r.data.permisos || [], sucursales: d.sucursales || (d.sucursal_id ? [d.sucursal_id] : []), email: d.email || null, avatar_url: d.avatar_url || null, token: r.data.token || null }, 'pin');
}
$('l-gbtn').addEventListener('click', async function () {
    try { localStorage.setItem('refrimar_pos_google', '1'); } catch (e) {}
    this.disabled = true; $('l-msg').textContent = 'Abriendo Google…';
    var r = await supabaseClient.auth.signInWithOAuth({ provider: 'google', options: { redirectTo: location.origin + location.pathname, queryParams: { prompt: 'select_account' } } });
    if (r.error) { this.disabled = false; $('l-msg').textContent = /not enabled|Unsupported/i.test(r.error.message || '') ? 'El acceso con Google aún no está activado.' : 'No se pudo abrir Google: ' + r.error.message; try { localStorage.removeItem('refrimar_pos_google'); } catch (e) {} }
});
async function terminarGoogle() {
    var p = null; try { p = localStorage.getItem('refrimar_pos_google'); localStorage.removeItem('refrimar_pos_google'); } catch (e) {}
    if (!p || !supabaseClient.auth) return false;
    var s = await supabaseClient.auth.getSession();
    if (!s || !s.data || !s.data.session) { $('l-msg').textContent = 'No se completó el acceso con Google.'; return false; }
    var r = await window.refLoginGoogle('pos');
    if (r.data && r.data.pendiente) { location.replace('invitacion.html'); return true; }
    if (r.error || !r.data || !r.data.success) { $('l-msg').textContent = (r.data && r.data.error) || 'Tu correo no está registrado.'; await supabaseClient.auth.signOut(); return false; }
    var d = r.data, md = (s.data.session.user && s.data.session.user.user_metadata) || {};
    await iniciarSesion({ id: d.id, nombre: d.nombre, rol: d.rol, permisos: d.permisos || [], sucursales: d.sucursales || [], email: d.email, avatar_url: d.avatar_url || md.avatar_url || md.picture || null, token: d.token || null }, 'google');
    return true;
}
async function iniciarSesion(u, metodo) {
    window.guardarSesion(Object.assign({}, u, { loginAt: Date.now(), metodo: metodo }));
    // La caja guarda el último token para sincronizar ventas pendientes aunque se cierre la ventana
    if (u.token) { try { localStorage.setItem('refrimar_pos_token', u.token); } catch (e) {} }
    if (!can('facturar')) { window.limpiarSesion(true); mostrarLogin('Tu usuario no tiene permiso para usar el punto de venta.'); return; }
    var permitidas = u.rol === 'admin' ? null : (u.sucursales || []);
    if (S.tienda && permitidas && permitidas.length && permitidas.indexOf(S.tienda.id) < 0) {
        window.limpiarSesion(true); mostrarLogin('No tienes acceso a la tienda de esta caja (' + S.tienda.nombre + ').'); return;
    }
    if (!S.tienda) {
        var tiendas = await cargarTiendas();
        var op = permitidas && permitidas.length ? tiendas.filter(function (t) { return permitidas.indexOf(t.id) >= 0; }) : tiendas;
        S.tienda = op.length === 1 ? op[0] : await elegirTienda(op, '¿En qué tienda está esta caja?');
        if (!S.tienda) { window.limpiarSesion(true); mostrarLogin(); return; }
        ls(K_TIENDA, S.tienda);
    }
    window.guardarSucursalSesion({ id: S.tienda.id, nombre: S.tienda.nombre });
    entrarApp();
}
async function cargarTiendas() {
    var r = await supabaseClient.from('sucursales').select('id,nombre').order('nombre');
    return [{ id: CASA, nombre: 'Casa Matriz' }].concat((r && r.data) || []);
}
function elegirTienda(lista, titulo) {
    return new Promise(function (ok) {
        var m = modal({ titulo: titulo, texto: 'Las ventas, el stock y la caja quedarán en la tienda que elijas. Puedes cambiarlo luego en Ajustes.',
            cuerpo: lista.map(function (t) { return '<button type="button" class="btn ghost" data-id="' + t.id + '" style="width:100%;justify-content:flex-start;margin-bottom:8px"><span class="material-symbols-outlined">storefront</span>' + esc(t.nombre) + '</button>'; }).join(''),
            alCerrar: function () { ok(null); } });
        m.el.querySelectorAll('[data-id]').forEach(function (b) { b.addEventListener('click', function () { var t = lista.find(function (x) { return x.id === b.dataset.id; }); m.el.remove(); ok(t); }); });
    });
}

/* ============================================================
   APP
   ============================================================ */
function entrarApp() {
    S.user = window.getSesionUsuario();
    $('login').classList.add('hide'); $('app').classList.remove('hide');
    var ini = String(S.user.nombre || '?').trim().split(/\s+/).map(function (p) { return p.charAt(0); }).join('').slice(0, 2).toUpperCase();
    $('t-av').innerHTML = S.user.avatar_url ? '<img src="' + esc(S.user.avatar_url) + '" alt="" referrerpolicy="no-referrer"/>' : esc(ini);
    $('t-nombre').textContent = S.user.nombre; $('m-nombre').textContent = S.user.nombre;
    $('m-rol').textContent = (window.nombreRol ? window.nombreRol(S.user.rol) : S.user.rol) + ' · ' + S.tienda.nombre;
    $('m-admin').classList.toggle('hide', !can('ver_dashboard') || (window.esSoloCaja && window.esSoloCaja()));
    $('t-tienda-v').textContent = S.tienda.nombre;
    window.REF_SYNC_FN = async function (payload) {
        var r = payload && payload.p_venta ? await supabaseClient.rpc('pos_facturar', payload) : await supabaseClient.rpc('registrar_venta', payload);
        if (r.error) throw r.error;
        return r;
    };
    window.REF_TRAS_SINCRONIZAR = function () { pintarSync(); };
    S.carro = ls(K_CARRO) || []; S.cliente = (ls(K_CARRO + '_cli')) || null;
    cargarConfig().then(function () { cargarCatalogo(); });
    cargarTurno(); estadoPuente(); pintarSync(); pintarCarro(); pintarCliente();
    ir('factura');
    var hv = location.hash.slice(1); if (['facturas', 'caja', 'dispositivos', 'ajustes'].indexOf(hv) >= 0) setTimeout(function () { ir(hv); }, 0);
    if (supabaseClient.rpc) supabaseClient.rpc('precios_programados_aplicar').then(function () {}, function () {});
    var tok = ls(K_TOKEN); if (tok) supabaseClient.rpc('terminal_ping', { p_token: tok }).then(function (r) { if (r && r.data && r.data.ok) ls(K_TERM, r.data.nombre); }, function () {});
}
function pintarSync() {
    var n = window.refContarPendientes ? window.refContarPendientes() : 0, b = $('r-sync');
    if (!b) return;
    b.classList.toggle('off', n > 0 || !navigator.onLine);
    b.dataset.tip = n > 0 ? n + ' venta(s) por sincronizar' : (navigator.onLine ? 'Sincronizado' : 'Sin conexión');
    b.querySelector('.material-symbols-outlined').textContent = n > 0 ? 'sync_problem' : navigator.onLine ? 'cloud_done' : 'cloud_off';
}
window.addEventListener('online', function () { pintarSync(); if (window.refSincronizarPendientes) window.refSincronizarPendientes(); });
window.addEventListener('offline', pintarSync);
$('r-sync').addEventListener('click', function () { if (window.refSincronizarPendientes) window.refSincronizarPendientes(); setTimeout(pintarSync, 1500); });

function ir(v) {
    S.vista = v;
    ['factura', 'cobro', 'facturas', 'nc', 'caja', 'dispositivos', 'ajustes'].forEach(function (k) { $('v-' + k).classList.toggle('hide', k !== v); });
    var railV = v === 'cobro' ? 'factura' : v === 'nc' ? 'facturas' : v;
    document.querySelectorAll('.rail [data-v]').forEach(function (b) { b.classList.toggle('on', b.dataset.v === railV); });
    if (v === 'factura') setTimeout(function () { $('f-buscar').focus(); }, 30);
    var P = window.__POS || {};
    if (v === 'facturas' && P.cargarFacturas) P.cargarFacturas();
    if (v === 'caja' && P.pintarCaja) P.pintarCaja();
    if (v === 'dispositivos' && P.pintarDispositivos) P.pintarDispositivos();
    if (v === 'ajustes' && P.pintarAjustes) P.pintarAjustes();
}
document.querySelectorAll('.rail [data-v]').forEach(function (b) { b.addEventListener('click', function () { if (S.vista === 'cobro' && b.dataset.v === 'factura') return ir('factura'); ir(b.dataset.v); }); });

// Menú de usuario
$('t-user').addEventListener('click', function (e) { e.stopPropagation(); $('t-menu').classList.toggle('hide'); });
document.addEventListener('click', function (e) { if (!$('t-menu').contains(e.target)) $('t-menu').classList.add('hide'); });
$('t-menu').addEventListener('click', async function (e) {
    var b = e.target.closest('[data-m]'); if (!b) return;
    $('t-menu').classList.add('hide');
    if (b.dataset.m === 'cambiar' || b.dataset.m === 'salir') {
        if (S.carro.length && !(await window.refConfirm('Hay una factura en curso. Queda guardada en esta caja para cuando vuelvas a entrar. ¿Salir?', { peligro: false }))) return;
        window.limpiarSesion(true);
        try { if (supabaseClient.auth) await supabaseClient.auth.signOut(); } catch (err) {}
        mostrarLogin();
    } else if (b.dataset.m === 'admin') { window.open('dashboard.html', 'refrimar_admin'); }
    else if (b.dataset.m === 'tema') { window.ponerTema(window.temaActual() === 'oscuro' ? 'claro' : 'oscuro'); }
});
$('t-refrescar').addEventListener('click', function () { cargarConfig().then(cargarCatalogo); estadoPuente(); toast('Actualizando catálogo y tasa…', '', 'info'); });
$('t-imp').addEventListener('click', function () { ir('dispositivos'); });

// ---------- Configuración y tasa ----------
async function cargarConfig() {
    var c = window.refCacheGet && window.refCacheGet('refrimar_cache_config');
    if (c) aplicarConfig(c);
    var r = await supabaseClient.from('configuracion').select('*').limit(1).maybeSingle();
    if (r && !r.error && r.data) { aplicarConfig(r.data); if (window.refCacheSet) window.refCacheSet('refrimar_cache_config', r.data); }
    if (!S.tasa) {
        var h = await supabaseClient.from('tasas_historial').select('tasa').order('created_at', { ascending: false }).limit(1);
        if (h && !h.error && h.data && h.data[0]) S.tasa = Number(h.data[0].tasa) || 0;
    }
    $('t-tasa-v').textContent = S.tasa ? f2(S.tasa) : 'Sin tasa';
    pintarCarro();
}
function aplicarConfig(c) { S.negocio = c; S.ivaIncluido = c.iva_incluido === true; if (c.tasa_bcv_manual) S.tasa = Number(c.tasa_bcv_manual); }
$('t-tasa').addEventListener('click', function () {
    if (!can('actualizar_tasa')) { toast('Tasa de cambio: ' + f2(S.tasa, 4) + ' Bs/$', 'Solo quien tiene permiso puede cambiarla.', 'info'); return; }
    var m = modal({ titulo: 'Tasa de cambio', texto: 'Se usa en todas las cajas, facturas y cotizaciones.',
        cuerpo: '<div class="campo"><span>Bolívares por dólar</span><input id="tt-v" class="in" inputmode="decimal" value="' + f2(S.tasa, 4) + '"/></div><div id="tt-bcv" style="font-size:13px;color:var(--tx2)">Tasa según BCV: consultando…</div>',
        pie: '<button type="button" class="btn out" data-c>Cancelar</button><button type="button" class="btn" data-ok>Actualizar</button>' });
    m.q('[data-c]').addEventListener('click', m.cerrar);
    fetch('/api/tasa-bcv').then(function (r) { return r.json(); }).then(function (d) {
        if (d && d.ok) { m.q('#tt-bcv').innerHTML = 'Tasa según BCV: <b>' + f2(d.tasa, 4) + '</b> <button type="button" style="color:var(--az-t);font-weight:500">Usar tasa</button>'; m.q('#tt-bcv button').addEventListener('click', function () { m.q('#tt-v').value = f2(d.tasa, 4); }); }
        else m.q('#tt-bcv').textContent = 'Tasa según BCV: no disponible';
    }).catch(function () { m.q('#tt-bcv').textContent = 'Tasa según BCV: no disponible'; });
    m.q('[data-ok]').addEventListener('click', async function () {
        var t = num(m.q('#tt-v').value); if (!(t > 0)) return toast('Escribe una tasa válida', '', 'warning');
        var r = await supabaseClient.rpc('config_actualizar_tasa', { p_tasa: t });
        if (r.error) return toast('No se pudo guardar la tasa', errMsg(r.error), 'error');
        supabaseClient.rpc('tasa_historial_firmar', { p_usuario: S.user.nombre }).then(function () {}, function () {});
        S.tasa = t; $('t-tasa-v').textContent = f2(t); pintarCarro(); m.cerrar(); toast('Tasa actualizada', f2(t, 4) + ' Bs/$');
    });
});

/* ============================================================
   CATÁLOGO
   ============================================================ */
async function cargarCatalogo() {
    var key = 'refrimar_cache_catalogo_' + S.tienda.id, verCostos = can('ver_costos');
    $('f-n').textContent = 'Cargando productos…';
    // Abre al instante con el último catálogo guardado en este equipo; luego se actualiza solo
    if (!S.catalogo || !S.catalogo.length) {
        var previo = window.refCacheGet && window.refCacheGet(key);
        if (previo && previo.length) { S.catalogo = previo; indexar(); pintarGrid(); $('f-n').textContent = previo.length + ' productos · actualizando…'; }
    }
    var todos = [], desde = 0, error = null;
    while (true) {
        var r = await supabaseClient.from('productos').select('*').order('descripcion').range(desde, desde + 999);
        if (r.error) { error = r.error; break; }
        todos = todos.concat(r.data || []);
        if (!r.data || r.data.length < 1000) break;
        desde += 1000;
    }
    if (error) {
        var cache = window.refCacheGet && window.refCacheGet(key);
        if (cache && cache.length) { S.catalogo = cache; indexar(); $('f-n').textContent = S.catalogo.length + ' productos (sin conexión)'; pintarGrid(); return; }
        $('f-n').textContent = 'Sin conexión y sin catálogo guardado'; return;
    }
    var base = todos.filter(function (p) { return p.activo !== false && p.estatus !== 'inactivo' && p.estatus !== 'borrador'; }).map(function (p) {
        return { codigo: p.codigo, descripcion: p.descripcion, categoria: p.categoria || '', precio: Number(p.precio) || 0, costo: verCostos ? Number(p.costo) || 0 : 0,
            stock: p.stock != null ? Number(p.stock) : 0, unidad: p.unidad || 'uds', alt: (p.codigos_alternos || []).map(function (x) { return String(x).toLowerCase(); }),
            iva: p.iva_tasa == null ? 16 : Number(p.iva_tasa), iva_extra: (p.impuestos_extra || []).reduce(function (s, t) { return s + (Number(t.porcentaje) || 0); }, 0),
            empaques: (p.empaques || []).filter(function (e) { return e && e.barra && Number(e.cantidad) > 0; }).map(function (e) { return { barra: String(e.barra).toLowerCase(), cantidad: Number(e.cantidad), nombre: e.nombre || 'Empaque' }; }),
            sensible: !!p.sensible, requiere_serial: !!p.requiere_serial, servicio: p.tipo_producto === 'servicio', kit: !!p.es_kit,
            // Datos del rubro que sirven para buscar (OEM, vehículo, principio activo, talla, color…) y una pista corta para el resultado
            extra: [p.marca, p.sku, p.referencia_interna, p.ref_fabrica].concat(Object.keys(p.atributos || {}).map(function (k) { return p.atributos[k]; })).filter(function (x) { return x != null && x !== ''; }).join(' '),
            info: infoRubro(p.atributos || {}) };
    });
    if (S.tienda.id !== CASA) {
        var st = await supabaseClient.from('sucursal_stock').select('producto_codigo,stock').eq('sucursal_id', S.tienda.id);
        var mapa = {}; ((st && st.data) || []).forEach(function (x) { mapa[x.producto_codigo] = Number(x.stock) || 0; });
        base = base.filter(function (p) { return mapa[p.codigo] != null; }).map(function (p) { p.stock = mapa[p.codigo]; return p; });
    }
    // Combos: alcanzan para lo que alcancen sus componentes en esta tienda
    if (base.some(function (p) { return p.kit; })) {
        var kc = await supabaseClient.from('producto_componentes').select('kit_codigo,componente_codigo,cantidad');
        if (kc && !kc.error && kc.data) {
            var stockDe = {}; base.forEach(function (p) { stockDe[p.codigo] = p.stock; });
            var comp = {}; kc.data.forEach(function (c) { (comp[c.kit_codigo] = comp[c.kit_codigo] || []).push(c); });
            base.forEach(function (p) {
                if (!p.kit || !comp[p.codigo]) return;
                p.stock = Math.max(0, Math.min.apply(null, comp[p.codigo].map(function (c) { return Math.floor((stockDe[c.componente_codigo] || 0) / Number(c.cantidad)); })));
                p.componentes = comp[p.codigo].map(function (c) { return { codigo: c.componente_codigo, cantidad: Number(c.cantidad) }; });
            });
        }
    }
    S.catalogo = base; indexar();
    if (window.refCacheSet) window.refCacheSet(key, base);
    var cats = {}; base.forEach(function (p) { if (p.categoria) cats[p.categoria] = 1; });
    $('f-cat').innerHTML = '<option value="">Ver catálogo · todas las categorías</option>' + Object.keys(cats).sort().map(function (c) { return '<option>' + esc(c) + '</option>'; }).join('');
    pintarGrid();
}
function indexar() { S.porCodigo = {}; S.catalogo.forEach(function (p) { S.porCodigo[String(p.codigo).toLowerCase()] = p; p._h = norm(p.descripcion + ' ' + p.codigo + ' ' + (p.alt || []).join(' ') + ' ' + (p.extra || '')); }); }
function infoRubro(a) {
    var v = function (k) { return a[k] != null && a[k] !== '' ? String(a[k]) : ''; };
    var partes = [v('oem') && 'OEM ' + v('oem'), [v('vehiculo_marca'), v('vehiculo_modelo'), v('vehiculo_anios')].filter(Boolean).join(' '),
        [v('principio_activo'), v('concentracion')].filter(Boolean).join(' '), [v('talla') && 'Talla ' + v('talla'), v('color')].filter(Boolean).join(' · '),
        v('vencimiento') && 'Vence ' + v('vencimiento'), v('ubicacion') && 'Ubic. ' + v('ubicacion')];
    return partes.filter(Boolean).slice(0, 2).join(' · ');
}
function precioFinal(p) { return S.ivaIncluido ? p.precio : p.precio * (1 + ((p.iva || 0) + (p.iva_extra || 0)) / 100); }
var GRID_N = 40;
function pintarGrid() {
    var cat = $('f-cat').value, lista = S.catalogo.filter(function (p) { return !cat || p.categoria === cat; });
    lista.sort(function (a, b) { return (b.stock > 0) - (a.stock > 0) || a.descripcion.localeCompare(b.descripcion); });
    $('f-n').textContent = lista.length + ' productos disponibles';
    var vis = lista.slice(0, GRID_N);
    $('f-grid').innerHTML = vis.map(function (p) {
        var pf = precioFinal(p), ag = p.stock <= 0 && !p.servicio, img = S.imgs[p.codigo];
        var ini = String(p.descripcion || '?').replace(/[^A-Za-zÁÉÍÓÚÑ0-9 ]/gi, '').trim().split(/\s+/).map(function (w) { return w.charAt(0); }).join('').slice(0, 2).toUpperCase();
        return '<button type="button" class="pc' + (ag ? ' agotado' : '') + '" data-c="' + esc(p.codigo) + '"><div class="img">' + (img ? '<img src="' + esc(img) + '" alt="" loading="lazy"/>' : '<span>' + esc(ini) + '</span>') + '</div>' +
            '<div class="nm">' + esc(p.descripcion) + '</div><div class="pr">' + bs(pf * S.tasa) + '<small>' + usd(pf) + '</small></div>' +
            '<div class="stk">' + (p.servicio ? 'Servicio' : ag ? 'Agotado' : 'Disponible: ' + cant(p.stock) + ' ' + esc(p.unidad)) + '</div></button>';
    }).join('') + (lista.length > GRID_N ? '<div style="grid-column:1/-1;text-align:center"><button type="button" class="btn out sm" id="f-mas">Ver más productos</button></div>' : '') +
        (!lista.length ? '<div style="grid-column:1/-1">' + window.refEstado('vacio', 'Sin productos', S.catalogo.length ? 'No hay productos en esta categoría.' : 'Aún no hay productos cargados en esta tienda.', '', 'sm') + '</div>' : '');
    var mas = $('f-mas'); if (mas) mas.addEventListener('click', function () { GRID_N += 40; pintarGrid(); });
    cargarImagenes(vis.map(function (p) { return p.codigo; }).filter(function (c) { return S.imgs[c] === undefined; }));
}
async function cargarImagenes(codigos) {
    if (!codigos.length) return;
    codigos.forEach(function (c) { S.imgs[c] = null; });
    for (var i = 0; i < codigos.length; i += 30) {
        var r = await supabaseClient.from('producto_imagenes').select('producto_codigo,img:imagenes->>0').in('producto_codigo', codigos.slice(i, i + 30));
        if (r.error || !r.data) return;
        var hubo = false;
        r.data.forEach(function (x) { if (x.img) { S.imgs[x.producto_codigo] = x.img; hubo = true; } });
        if (hubo) r.data.forEach(function (x) { var b = document.querySelector('.pc[data-c="' + CSS.escape(x.producto_codigo) + '"] .img'); if (b && x.img) b.innerHTML = '<img src="' + esc(x.img) + '" alt="" loading="lazy"/>'; });
    }
}
$('f-cat').addEventListener('change', function () { GRID_N = 40; pintarGrid(); });
$('f-grid').addEventListener('click', function (e) { var b = e.target.closest('.pc'); if (b) agregar(S.porCodigo[b.dataset.c.toLowerCase()]); });

// ---------- Búsqueda y escáner ----------
var RES = [], RES_I = -1;
function exacto(t) {
    t = String(t || '').trim().toLowerCase(); if (!t) return null;
    if (S.porCodigo[t]) return S.porCodigo[t];
    for (var i = 0; i < S.catalogo.length; i++) {
        var p = S.catalogo[i];
        if (p.alt.indexOf(t) >= 0) return p;
        var e = p.empaques.find(function (x) { return x.barra === t; });
        if (e) return Object.assign({}, p, { _empaque: e });
    }
    return null;
}
function buscar(q) {
    var n = norm(q).trim(); if (!n) return [];
    var pal = n.split(/\s+/);
    return S.catalogo.filter(function (p) { var h = p._h || norm(p.descripcion + ' ' + p.codigo + ' ' + p.alt.join(' ')); return pal.every(function (w) { return h.indexOf(w) >= 0; }); }).slice(0, 12);
}
function pintarRes() {
    var box = $('f-res');
    if (!RES.length) { box.classList.add('hide'); return; }
    box.innerHTML = RES.map(function (p, i) { return '<button type="button" data-i="' + i + '" class="' + (i === RES_I ? 'on' : '') + '"><span style="flex:1;min-width:0"><b>' + esc(p.descripcion) + '</b><span class="sub">' + esc(p.codigo) + ' · ' + (p.servicio ? 'Servicio' : 'Stock ' + cant(p.stock)) + (p.info ? ' · ' + esc(p.info) : '') + '</span></span><span style="text-align:right;white-space:nowrap"><b>' + bs(precioFinal(p) * S.tasa) + '</b><span class="sub">' + usd(precioFinal(p)) + '</span></span></button>'; }).join('');
    box.classList.remove('hide');
}
$('f-buscar').addEventListener('input', function () { var q = this.value.replace(/\*\s*[\d.,]+\s*$/, ''); RES = buscar(q); RES_I = RES.length ? 0 : -1; pintarRes(); });
$('f-buscar').addEventListener('keydown', function (e) {
    if (e.key === 'ArrowDown') { e.preventDefault(); RES_I = Math.min(RES.length - 1, RES_I + 1); pintarRes(); }
    else if (e.key === 'ArrowUp') { e.preventDefault(); RES_I = Math.max(0, RES_I - 1); pintarRes(); }
    else if (e.key === 'Escape') { RES = []; pintarRes(); }
    else if (e.key === 'Enter') {
        e.preventDefault();
        var raw = this.value.trim(), m = raw.match(/^(.+?)\s*\*\s*(\d+(?:[.,]\d+)?)$/), q = m ? m[1] : raw, c = m ? num(m[2]) : 1;
        var p = exacto(q) || (RES_I >= 0 ? RES[RES_I] : null);
        if (!p) { toast('Producto no encontrado', '"' + q + '" no está en el catálogo de esta tienda.', 'warning'); return; }
        agregar(p, c); this.value = ''; RES = []; pintarRes();
    }
});
$('f-res').addEventListener('mousedown', function (e) { var b = e.target.closest('[data-i]'); if (!b) return; e.preventDefault(); agregar(RES[Number(b.dataset.i)]); $('f-buscar').value = ''; RES = []; pintarRes(); $('f-buscar').focus(); });
$('f-buscar').addEventListener('blur', function () { setTimeout(function () { RES = []; pintarRes(); }, 150); });
// Lector de código de barras cuando el foco no está en un campo
var SCAN = { buf: '', t: 0 };
document.addEventListener('keydown', function (e) {
    if (S.vista !== 'factura' || $('app').classList.contains('hide') || document.querySelector('.mov,.ref-dlg-ov')) return;
    var tag = (document.activeElement && document.activeElement.tagName) || '';
    if (/INPUT|SELECT|TEXTAREA/.test(tag)) return;
    var ahora = Date.now();
    if (e.key === 'Enter') { if (SCAN.buf.length >= 3) { var p = exacto(SCAN.buf); if (p) agregar(p); else toast('Código no encontrado', SCAN.buf, 'warning'); } SCAN.buf = ''; return; }
    if (e.key.length === 1) { if (ahora - SCAN.t > 80) SCAN.buf = ''; SCAN.buf += e.key; SCAN.t = ahora; }
});

/* ============================================================
   CARRITO
   ============================================================ */
async function agregar(p, cantidad) {
    if (!p) return;
    if (p.stock <= 0 && !p.servicio) { toast('Producto sin stock', p.descripcion, 'error'); return; }
    var q = Number(cantidad) > 0 ? Number(cantidad) : 1;
    // Pesables: si hay balanza configurada y no escribieron cantidad, se lee el peso
    if (p.unidad === 'kg' && !(Number(cantidad) > 0) && S.cfg.balanza) {
        var bz = await puente('/balanza/peso', undefined, 5000);
        if (bz && bz.ok && bz.peso > 0) { q = Math.round(bz.peso * 1000) / 1000; if (!bz.estable) toast('Peso inestable', 'Revisa que el producto esté quieto en la balanza', 'warning'); }
        else if (bz && bz.ok) { toast('La balanza marca 0', 'Pon el producto en la balanza o escribe el peso', 'warning'); return; }
        else toast('No se leyó la balanza', (bz && bz.error) || '', 'warning');
    }
    if (p.unidad === 'uds') q = Math.max(1, Math.round(q));
    if (p._empaque) { q = q * p._empaque.cantidad; toast(p._empaque.nombre, '+' + cant(q) + ' ' + p.unidad + ' de ' + p.descripcion, 'info'); }
    var ex = S.carro.find(function (i) { return i.codigo === p.codigo; });
    if (p.sensible && !ex && !(await window.refConfirm('"' + p.descripcion + '" es un producto SENSIBLE.\n\nVerifica antes de venderlo. ¿Agregarlo a la factura?', { peligro: false, si: 'Agregar' }))) return;
    var serial = null;
    if (p.requiere_serial) {
        serial = await window.refPrompt('Número de serie de "' + p.descripcion + '"' + (q > 1 ? ' (separa varios con coma)' : ''), '', { titulo: 'Número de serie' });
        if (serial === null) return;
        serial = serial.trim(); if (!serial) { toast('Este producto requiere número de serie', '', 'warning'); return; }
    }
    if (ex) {
        if (!p.servicio && ex.cantidad + q > p.stock + 1e-9) { toast('Stock insuficiente', 'Disponible: ' + cant(p.stock) + ' ' + p.unidad, 'warning'); return; }
        ex.cantidad = r2(ex.cantidad + q) || ex.cantidad + q; if (serial) ex.descripcion += ', ' + serial;
    } else {
        if (!p.servicio && q > p.stock + 1e-9) { toast('Stock insuficiente', 'Disponible: ' + cant(p.stock) + ' ' + p.unidad, 'warning'); return; }
        S.carro.push({ codigo: p.codigo, descripcion: p.descripcion + (serial ? ' · S/N: ' + serial : ''), precio: p.precio, costo: p.costo || 0, cantidad: q, descuento: 0, stock: p.servicio ? 1e9 : p.stock, unidad: p.unidad, iva: p.iva, iva_extra: p.iva_extra || 0, servicio: p.servicio });
    }
    beep('ok'); pintarCarro();
}
function totales(items) {
    items = items || S.carro;
    var sub = 0, desc = 0, iva = 0;
    items.forEach(function (i) {
        var bruto = i.precio * i.cantidad, d = bruto * (i.descuento || 0) / 100, neto = bruto - d;
        sub += bruto; desc += d;
        if (!S.ivaIncluido) iva += neto * ((Number(i.iva) || 0) + (Number(i.iva_extra) || 0)) / 100;
    });
    iva = r2(iva);
    var total = r2(sub - desc + iva);
    return { subtotal: r2(sub), descuento: r2(desc), iva: iva, totalUsd: total, totalBs: r2(total * S.tasa), tasa: S.tasa, n: items.reduce(function (s, i) { return s + (i.unidad === 'uds' ? i.cantidad : 1); }, 0) };
}
function lineaTotal(i) { var neto = i.precio * i.cantidad * (1 - (i.descuento || 0) / 100); return S.ivaIncluido ? neto : neto * (1 + ((Number(i.iva) || 0) + (Number(i.iva_extra) || 0)) / 100); }
function lineaIva(i) { var neto = i.precio * i.cantidad * (1 - (i.descuento || 0) / 100); return S.ivaIncluido ? neto - neto / (1 + (Number(i.iva) || 0) / 100) : neto * (Number(i.iva) || 0) / 100; }
function pintarCarro() {
    ls(K_CARRO, S.carro);
    var c = $('f-carro'); if (!c) return;
    if (!S.carro.length) c.innerHTML = window.refEstado('vacio', 'Factura vacía', 'Busca o escanea un producto para empezar.', '', 'xs');
    else c.innerHTML = S.carro.map(function (i, k) {
        var lt = lineaTotal(i);
        return '<div class="li" data-k="' + k + '"><div class="ln">' + esc(i.descripcion) + '<span class="sub">' + bs(precioFinal(i) * S.tasa) + ' c/u' + (i.descuento ? ' · <span class="ld">−' + f2(i.descuento, 1) + '%</span>' : '') + (Number(i.iva) ? ' · IVA ' + f2(i.iva, 0) + '%' : ' · Exento') + '</span></div>' +
            '<div class="lp">' + bs(lt * S.tasa) + '<small>' + usd(lt) + '</small></div>' +
            '<div class="lc"><button type="button" data-a="menos" aria-label="Quitar uno">−</button><input data-a="cant" value="' + cant(i.cantidad) + '" inputmode="decimal"/><button type="button" data-a="mas" aria-label="Agregar uno">+</button><span style="font-size:12px;color:var(--tx3)">' + esc(i.unidad) + '</span></div>' +
            '<div class="lx">' + (can('app_descuento') ? '<button type="button" class="ed" data-a="desc" title="Descuento"><span class="material-symbols-outlined" style="font-size:18px">percent</span></button>' : '') +
            (can('app_cambiar_precio') ? '<button type="button" class="ed" data-a="precio" title="Cambiar precio"><span class="material-symbols-outlined" style="font-size:18px">edit</span></button>' : '') +
            (can('app_eliminar') || S.user && S.user.rol === 'admin' || !window.esPermisosV2(S.user) ? '<button type="button" data-a="quitar" title="Quitar"><span class="material-symbols-outlined" style="font-size:18px">delete</span></button>' : '') + '</div></div>';
    }).join('');
    var t = totales();
    $('f-cant').textContent = cant(t.n);
    $('f-total').textContent = bs(t.totalBs); $('f-total-usd').textContent = usd(t.totalUsd);
    $('f-detalle').innerHTML = '<div><span>Subtotal</span><span>' + bs(t.subtotal * S.tasa) + '</span></div>' + (t.descuento ? '<div><span>Descuento</span><span>−' + bs(t.descuento * S.tasa) + '</span></div>' : '') +
        '<div><span>' + (S.ivaIncluido ? 'IVA incluido' : 'IVA') + '</span><span>' + bs((S.ivaIncluido ? S.carro.reduce(function (s, i) { return s + lineaIva(i); }, 0) : t.iva) * S.tasa) + '</span></div><div><span>Tasa</span><span>' + f2(S.tasa, 2) + ' Bs/$</span></div>';
    $('f-siguiente').disabled = !S.carro.length;
    $('f-titulo').textContent = S.borradorId ? 'Factura (borrador)' : 'Nueva factura';
}
$('f-carro').addEventListener('click', async function (e) {
    var b = e.target.closest('[data-a]'); if (!b || b.dataset.a === 'cant') return;
    var k = Number(b.closest('.li').dataset.k), i = S.carro[k]; if (!i) return;
    var paso = i.unidad === 'uds' ? 1 : 1;
    if (b.dataset.a === 'mas') { if (!i.servicio && i.cantidad + paso > i.stock + 1e-9) return toast('Stock máximo', cant(i.stock) + ' ' + i.unidad, 'warning'); i.cantidad = r2(i.cantidad + paso); }
    else if (b.dataset.a === 'menos') { if (i.cantidad - paso <= 0) { S.carro.splice(k, 1); } else i.cantidad = r2(i.cantidad - paso); }
    else if (b.dataset.a === 'quitar') S.carro.splice(k, 1);
    else if (b.dataset.a === 'desc') { var d = await window.refPrompt('Descuento en % para "' + i.descripcion + '"', String(i.descuento || ''), { titulo: 'Aplicar descuento', placeholder: 'Ej: 5' }); if (d === null) return; i.descuento = Math.max(0, Math.min(100, num(d))); }
    else if (b.dataset.a === 'precio') { var p = await window.refPrompt('Nuevo precio en dólares (sin IVA) para "' + i.descripcion + '"', f2(i.precio), { titulo: 'Cambiar precio' }); if (p === null) return; if (num(p) > 0) i.precio = num(p); }
    pintarCarro();
});
$('f-carro').addEventListener('change', function (e) {
    if (e.target.dataset.a !== 'cant') return;
    var k = Number(e.target.closest('.li').dataset.k), i = S.carro[k]; if (!i) return;
    var n = num(e.target.value); if (i.unidad === 'uds') n = Math.round(n);
    if (n <= 0) S.carro.splice(k, 1);
    else { if (!i.servicio && n > i.stock) { toast('Stock máximo', cant(i.stock) + ' ' + i.unidad, 'warning'); n = i.stock; } i.cantidad = n; }
    pintarCarro();
});
$('f-det-btn').addEventListener('click', function () { $('f-detalle').classList.toggle('hide'); });
$('f-limpiar').addEventListener('click', async function () {
    if (!S.carro.length && !S.cliente) return;
    if (!(await window.refConfirm('¿Borrar todos los productos y el cliente de esta factura?'))) return;
    limpiarFactura();
});
function limpiarFactura() { S.carro = []; S.cliente = null; S.borradorId = null; S.pagos = []; S.vuelto = []; $('c-doc').value = ''; ls(K_CARRO + '_cli', null); pintarCliente(); pintarCarro(); }
$('f-borrador').addEventListener('click', async function () {
    if (!S.carro.length) return toast('Agrega productos para guardar el borrador', '', 'warning');
    var nombre = await window.refPrompt('Nombre del borrador (opcional)', S.cliente ? S.cliente.nombre : '', { titulo: 'Guardar borrador', si: 'Guardar' });
    if (nombre === null) return;
    var r = await supabaseClient.rpc('pos_borrador_guardar', { p_id: S.borradorId, p_datos: { nombre: nombre, sucursal_id: S.tienda.id, usuario_nombre: S.user.nombre, terminal: ls(K_TERM), cliente: S.cliente, items: S.carro, total_usd: totales().totalUsd } });
    if (r.error) return toast('No se pudo guardar el borrador', faltaFn(r.error) ? 'Falta correr supabase-migration-pos-precios.sql en Supabase.' : errMsg(r.error), 'error');
    toast('Borrador guardado', 'Lo encuentras en Facturas → Borradores.');
    limpiarFactura();
});

// ---------- Cliente ----------
function docRif() { var d = $('c-doc').value.trim().replace(/[^0-9A-Za-z]/g, ''); return d ? $('c-tipo').value + '-' + d.toUpperCase() : ''; }
function pintarCliente() {
    ls(K_CARRO + '_cli', S.cliente);
    var c = S.cliente, info = $('c-info');
    if (!c) { info.innerHTML = 'Consumidor final'; return; }
    if (c.rif && !$('c-doc').value) { var m = c.rif.match(/^([VEJGP])-?(.*)$/i); if (m) { $('c-tipo').value = m[1].toUpperCase(); $('c-doc').value = m[2]; } }
    info.innerHTML = '<span class="material-symbols-outlined" style="font-size:16px;color:var(--ok)">person</span><b>' + esc(c.nombre) + '</b>' + (c.existe && Number(c.limite) > 0 ? '<span class="tag">Crédito: ' + usd(Math.max(0, c.limite - (c.saldo || 0))) + ' disp.</span>' : '') +
        '<button type="button" id="c-quitar" style="margin-left:auto;color:var(--tx3);font-size:13px">Quitar</button>';
    $('c-quitar').addEventListener('click', function () { S.cliente = null; $('c-doc').value = ''; pintarCliente(); });
}
async function buscarCliente() {
    var rif = docRif(); if (!rif) { S.cliente = null; pintarCliente(); return; }
    var dig = rif.split('-')[1];
    var r = await supabaseClient.from('clientes').select('id,nombre,rif,email,telefono,limite_credito,saldo_pendiente').or('rif.eq.' + rif + ',rif.eq.' + rif.replace('-', '') + ',rif.eq.' + dig).limit(1);
    var c = r && !r.error && r.data && r.data[0];
    if (c) {
        S.cliente = { rif: c.rif, nombre: c.nombre, email: c.email || '', telefono: c.telefono || '', limite: Number(c.limite_credito) || 0, saldo: Number(c.saldo_pendiente) || 0, existe: true };
        pintarCliente();
        if (!c.email) pedirCorreo();
        return;
    }
    registrarCliente(rif);
}
$('c-doc').addEventListener('keydown', function (e) { if (e.key === 'Enter') { e.preventDefault(); buscarCliente(); } });
$('c-buscar').addEventListener('click', buscarCliente);
function pedirCorreo() {
    var m = modal({ titulo: 'Dato de cliente', texto: 'Ayúdenos a mejorar su experiencia ingresando su correo.', cuerpo: '<input id="dc-email" type="email" class="in" placeholder="Ingresar correo"/>',
        pie: '<button type="button" class="btn out" data-c>Cancelar</button><button type="button" class="btn" data-ok disabled>Confirmar</button>' });
    var inp = m.q('#dc-email'), ok = m.q('[data-ok]');
    inp.addEventListener('input', function () { ok.disabled = !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(inp.value.trim()); });
    inp.addEventListener('keydown', function (e) { if (e.key === 'Enter' && !ok.disabled) ok.click(); });
    m.q('[data-c]').addEventListener('click', m.cerrar);
    ok.addEventListener('click', function () { if (S.cliente) S.cliente.email = inp.value.trim(); pintarCliente(); m.cerrar(); });
}
function registrarCliente(rif) {
    var m = modal({ titulo: 'Registrar cliente', texto: 'El documento <b>' + esc(rif) + '</b> no está registrado.',
        cuerpo: '<div class="campo"><span>Nombre o razón social *</span><input id="rc-n" class="in" maxlength="100"/></div><div class="g2"><div class="campo"><span>Teléfono</span><input id="rc-t" class="in" inputmode="tel" placeholder="0412-0000000"/></div><div class="campo"><span>Correo</span><input id="rc-e" type="email" class="in"/></div></div>',
        pie: '<button type="button" class="btn out" data-sin>Solo para esta factura</button><button type="button" class="btn" data-ok>Registrar</button>' });
    m.q('[data-sin]').addEventListener('click', function () { var n = m.q('#rc-n').value.trim(); if (!n) return m.q('#rc-n').classList.add('err'); S.cliente = { rif: rif, nombre: n, email: m.q('#rc-e').value.trim(), existe: false }; pintarCliente(); m.cerrar(); });
    m.q('[data-ok]').addEventListener('click', async function () {
        var n = m.q('#rc-n').value.trim(); if (!n) return m.q('#rc-n').classList.add('err');
        this.disabled = true;
        var r = await window.rpcConFallback('cliente_guardar', { p_id: null, p_nombre: n, p_rif: rif, p_telefono: m.q('#rc-t').value.trim() || null, p_email: m.q('#rc-e').value.trim() || null, p_direccion: null, p_tipo: 'final', p_limite_credito: 0, p_notas: null, p_sucursal_id: S.tienda.id }, ['p_sucursal_id']);
        this.disabled = false;
        if (r.error) return toast('No se pudo registrar el cliente', errMsg(r.error), 'error');
        S.cliente = { rif: rif, nombre: n, email: m.q('#rc-e').value.trim(), limite: 0, saldo: 0, existe: true };
        pintarCliente(); m.cerrar(); toast('Cliente registrado', n);
    });
}

// ---------- Turno ----------
async function cargarTurno() {
    var r = await supabaseClient.from('turnos').select('*').eq('usuario_nombre', S.user.nombre).eq('estado', 'activo').maybeSingle();
    S.turno = r && !r.error ? r.data : null;
    S.turnoDisponible = !(r && r.error);
    pintarTurno();
}
function pintarTurno() {
    var t = S.turno, ch = $('t-turno');
    ch.className = 'chip ' + (t ? 'ok' : 'warn');
    ch.querySelector('.material-symbols-outlined').textContent = t ? 'lock_open' : 'lock';
    $('t-turno-v').textContent = t ? 'Turno ' + t.numero : (S.turnoDisponible === false ? 'Turnos no activos' : 'Abrir turno');
    $('f-abrir-turno').classList.toggle('hide', !!t || S.turnoDisponible === false);
}
$('t-turno').addEventListener('click', function () { if (S.turno) ir('caja'); else abrirTurno(); });
$('f-abrir-turno').addEventListener('click', function () { abrirTurno(); });
function abrirTurno(despues) {
    var m = modal({ titulo: 'Abrir turno', texto: 'Indica el efectivo con el que empiezas (fondo de caja).',
        cuerpo: '<div class="g2"><div class="campo"><span>Fondo en dólares</span><input id="at-u" class="in" inputmode="decimal" value="0"/></div><div class="campo"><span>Fondo en bolívares</span><input id="at-b" class="in" inputmode="decimal" value="0"/></div></div>',
        pie: '<button type="button" class="btn out" data-c>Cancelar</button><button type="button" class="btn" data-ok>Abrir turno</button>' });
    m.q('[data-c]').addEventListener('click', m.cerrar);
    m.q('[data-ok]').addEventListener('click', async function () {
        this.disabled = true;
        var r = await supabaseClient.rpc('turno_abrir', { p_usuario_id: S.user.id, p_usuario_nombre: S.user.nombre, p_sucursal_id: S.tienda.id, p_sucursal_nombre: S.tienda.nombre, p_terminal: ls(K_TERM), p_fondo_usd: num(m.q('#at-u').value), p_fondo_bs: num(m.q('#at-b').value) });
        this.disabled = false;
        if (r.error) return toast('No se pudo abrir el turno', errMsg(r.error), 'error');
        m.cerrar(); toast('¡Operación realizada con éxito!', 'Turno ' + r.data.numero + ' generado correctamente');
        await cargarTurno();
        if (despues) despues();
        if (S.vista === 'caja' && window.__POS.pintarCaja) window.__POS.pintarCaja();
    });
}
$('f-siguiente').addEventListener('click', function () {
    if (!S.carro.length) return;
    if (!S.tasa) return toast('No hay tasa de cambio', 'Actualiza la tasa antes de facturar.', 'error');
    if (!S.turno && S.turnoDisponible !== false) return abrirTurno(function () { irCobro(); });
    irCobro();
});

// placeholder: se completan en la segunda parte
window.__POS = { S: S, ir: ir, toast: toast, modal: modal, menuEn: menuEn, puente: puente, estadoPuente: estadoPuente, totales: totales, lineaTotal: lineaTotal, lineaIva: lineaIva, precioFinal: precioFinal,
    pintarCarro: pintarCarro, pintarCliente: pintarCliente, limpiarFactura: limpiarFactura, cargarTurno: cargarTurno, abrirTurno: abrirTurno, cargarCatalogo: cargarCatalogo, cargarConfig: cargarConfig,
    cargarTiendas: cargarTiendas, elegirTienda: elegirTienda, guardarCfg: guardarCfg, pintarSync: pintarSync, mostrarLogin: mostrarLogin,
    h: { $: $, ls: ls, esc: esc, f2: f2, bs: bs, usd: usd, num: num, r2: r2, cant: cant, fecha: fecha, hora: hora, errMsg: errMsg, faltaFn: faltaFn, can: can, beep: beep, METODO_NOMBRE: METODO_NOMBRE, METODO_ICONO: METODO_ICONO, BANCOS: BANCOS, K_TERM: K_TERM, K_TOKEN: K_TOKEN, K_TIENDA: K_TIENDA, K_ULT: K_ULT, CASA: CASA, VERSION: VERSION } };
function irCobro() { if (window.__POS.irCobro) window.__POS.irCobro(); }

// ---------- Arranque ----------
(async function () {
    if (window.temaActual && window.temaActual() === 'oscuro') document.documentElement.classList.add('nk-dark');
    var u = window.getSesionUsuario && window.getSesionUsuario();
    // Equipo nuevo: si ya entró al sistema eligiendo tienda, la caja usa esa misma tienda
    if (u && !S.tienda) { try { var st = JSON.parse(sessionStorage.getItem(window.REF_SUCURSAL_KEY) || 'null'); if (st && st.id) { S.tienda = { id: st.id, nombre: st.nombre }; ls(K_TIENDA, S.tienda); } } catch (e) {} }
    if (u && S.tienda && can('facturar') && Date.now() - (u.loginAt || 0) < 12 * 3600e3) { entrarApp(); return; }
    if (await terminarGoogle()) return;
    mostrarLogin();
})();
})();
