// ============================================================
// OFFLINE MANAGER — COMERCIAL REFRIMAR (PWA)
// ------------------------------------------------------------
// Responsabilidades:
//  1. Registrar el Service Worker.
//  2. Detectar en línea/offline y mostrar la barra indicadora
//     (🟢 En línea / 🔴 Modo Offline) en cualquier pantalla.
//  3. Cola local de ventas pendientes (localStorage) cuando no
//     hay internet.
//  4. Sincronización automática al recuperar la conexión.
//  5. Caché ligera de datos (catálogo, config, ventas) para que
//     facturacion.html funcione sin internet.
//
// Cada página define qué hacer al sincronizar asignando:
//   window.REF_SYNC_FN = async function(payload) { ... registrar_venta ... };
//   window.REF_TRAS_SINCRONIZAR = function() { ... recargar listas ... };
// ============================================================

(function() {
  const COLA_KEY = 'refrimar_cola_ventas';
  const ONLINE = 'online', OFFLINE = 'offline', SYNC = 'sync';

  // ---------- Estado de conexión ----------
  function esEnLinea() {
    return navigator.onLine !== false;
  }
  function esErrorDeRed(err) {
    if (!err) return false;
    if (!esEnLinea()) return true;
    const m = String(err.message || '').toLowerCase();
    const c = String(err.code || '');
    return m.indexOf('failed to fetch') !== -1 ||
           m.indexOf('networkerror') !== -1 ||
           m.indexOf('fetch failed') !== -1 ||
           m.indexOf('network request failed') !== -1 ||
           m.indexOf('load failed') !== -1 ||
           c === 'NETWORK_ERROR' || c === 'UNABLE_TO_CONNECT' || c === 'CONNECTION_ERR';
  }

  // ---------- UI: barra superior + pastilla ----------
  function inyectarUI() {
    const root = document.createElement('div');
    root.id = 'ref-netbar-root';
    root.innerHTML =
      '<div id="ref-netbar" class="ref-bar">' +
        '<span id="ref-netbar-msg"></span>' +
      '</div>' +
      '<div id="ref-netpill" class="ref-pill">🟢 EN LÍNEA</div>';
    document.body.appendChild(root);

    const style = document.createElement('style');
    style.textContent =
      '#ref-netbar-root{font-family:Inter,system-ui,sans-serif;}' +
      '.ref-bar{position:fixed;top:0;left:0;right:0;z-index:2147483000;transform:translateY(-110%);transition:transform .35s ease;text-align:center;padding:9px 14px;font-size:12px;font-weight:700;letter-spacing:.04em;box-shadow:0 6px 24px rgba(0,0,0,.35);}' +
      '.ref-bar.show{transform:translateY(0);}' +
      '.ref-bar.red{background:rgba(185,28,28,.95);color:#fff;}' +
      '.ref-bar.amber{background:rgba(180,122,0,.95);color:#fff;}' +
      '.ref-pill{position:fixed;top:10px;right:10px;z-index:2147483001;background:rgba(5,150,105,.95);color:#fff;padding:6px 12px;border-radius:9999px;font-size:11px;font-weight:800;letter-spacing:.06em;box-shadow:0 4px 18px rgba(0,0,0,.35);opacity:0;pointer-events:none;transition:opacity .4s ease;}' +
      '.ref-pill.show{opacity:1;}' +
      'body.ref-net-padding{padding-top:38px;}';
    document.head.appendChild(style);
  }

  let pillTimer = null;
  function mostrarPastilla(texto) {
    const p = document.getElementById('ref-netpill');
    if (!p) return;
    p.textContent = texto;
    p.classList.add('show');
    clearTimeout(pillTimer);
    pillTimer = setTimeout(function() { p.classList.remove('show'); }, 2600);
  }

  function actualizarUI(estado, pendientes) {
    const bar = document.getElementById('ref-netbar');
    const msg = document.getElementById('ref-netbar-msg');
    if (!bar || !msg) return;
    const n = pendientes || contarPendientes();

    if (estado === OFFLINE) {
      bar.className = 'ref-bar red';
      msg.textContent = '🔴 SIN CONEXIÓN — MODO OFFLINE' + (n > 0 ? ' • ' + n + ' venta(s) pendiente(s) de sincronizar' : ' • las ventas se guardarán localmente');
      bar.classList.add('show');
    } else if (estado === SYNC) {
      bar.className = 'ref-bar amber';
      msg.textContent = '🟡 RECONECTADO — sincronizando ' + n + ' venta(s) pendiente(s)…';
      bar.classList.add('show');
    } else {
      bar.classList.remove('show');
      if (n > 0) mostrarPastilla('🔄 ' + n + ' venta(s) sincronizada(s)');
      else mostrarPastilla('🟢 EN LÍNEA');
    }
  }

  function notificar(estado) {
    window.dispatchEvent(new CustomEvent('refnetchange', { detail: { online: estado === ONLINE } }));
    if (document.getElementById('conn-status')) {
      const el = document.getElementById('conn-status');
      if (estado === OFFLINE) {
        el.textContent = '🔴 Modo Offline';
        el.className = 'text-xs font-mono-data px-3 py-1 rounded-full bg-error/10 text-error font-bold';
      } else if (estado === ONLINE) {
        el.textContent = '🟢 En línea';
        el.className = 'text-xs font-mono-data px-3 py-1 rounded-full bg-emerald-100 text-emerald-700 font-bold';
      }
    }
  }

  // ---------- Cola local de ventas ----------
  function leerCola() {
    try { return JSON.parse(localStorage.getItem(COLA_KEY) || '[]'); } catch (e) { return []; }
  }
  function guardarCola(cola) {
    try { localStorage.setItem(COLA_KEY, JSON.stringify(cola)); } catch (e) {}
  }
  function encolarVenta(payload) {
    const cola = leerCola();
    cola.push({ id: 'q' + Date.now() + Math.floor(Math.random() * 1000), creado: new Date().toISOString(), payload: payload });
    guardarCola(cola);
    actualizarUI(esEnLinea() ? ONLINE : OFFLINE);
  }
  function contarPendientes() { return leerCola().length; }
  function quitarDeCola(id) {
    guardarCola(leerCola().filter(function(i) { return i.id !== id; }));
  }

  // ---------- Caché ligera de datos ----------
  function cacheSet(key, val) {
    try { localStorage.setItem(key, JSON.stringify({ t: Date.now(), v: val })); } catch (e) {}
  }
  function cacheGet(key) {
    try {
      const raw = localStorage.getItem(key);
      if (!raw) return null;
      const obj = JSON.parse(raw);
      return obj.v;
    } catch (e) { return null; }
  }

  // ---------- Sincronización automática ----------
  async function sincronizarPendientes() {
    const cola = leerCola();
    if (cola.length === 0 || !esEnLinea()) { actualizarUI(esEnLinea() ? ONLINE : OFFLINE); return; }
    if (!window.REF_SYNC_FN) { actualizarUI(ONLINE); return; }

    actualizarUI(SYNC, cola.length);
    let detenido = false;

    for (let i = 0; i < cola.length; i++) {
      const item = cola[i];
      if (!esEnLinea()) { detenido = true; break; }
      try {
        await window.REF_SYNC_FN(item.payload);
        quitarDeCola(item.id);
      } catch (err) {
        if (esErrorDeRed(err)) { detenido = true; break; }
        // Error de datos (ej: validación): queda en cola pero se guarda el
        // motivo para mostrarlo y permitir quitarla manualmente.
        const actual = leerCola();
        const it = actual.find(function(x) { return x.id === item.id; });
        if (it) { it.error = (err && err.message) || 'Error de validación'; guardarCola(actual); }
      }
    }

    const restantes = contarPendientes();
    if (window.REF_TRAS_SINCRONIZAR) {
      try { window.REF_TRAS_SINCRONIZAR(restantes); } catch (e) {}
    }
    if (restantes === 0) {
      actualizarUI(ONLINE);
      mostrarPastilla('🟢 TODAS LAS VENTAS SINCRONIZADAS');
    } else if (!detenido) {
      actualizarUI(ONLINE); // quedan por error de datos, se muestran en la lista
    } else {
      actualizarUI(OFFLINE, restantes);
    }
  }

  // ---------- API pública ----------
  window.refEsEnLinea = esEnLinea;
  window.refEsErrorDeRed = esErrorDeRed;
  window.refEncolarVenta = encolarVenta;
  window.refObtenerCola = leerCola;
  window.refContarPendientes = contarPendientes;
  window.refQuitarDeCola = quitarDeCola;
  window.refSincronizarPendientes = sincronizarPendientes;
  window.refCacheSet = cacheSet;
  window.refCacheGet = cacheGet;
  window.refActualizarUI = actualizarUI;

  // ---------- Registro del Service Worker ----------
  function registrarSW() {
    if ('serviceWorker' in navigator) {
      window.addEventListener('load', function() {
        navigator.serviceWorker.register('sw.js', { scope: '/' }).catch(function(e) {
          console.warn('[SW] No se pudo registrar:', e);
        });
      });
    }
  }

  // ---------- Arranque ----------
  function init() {
    inyectarUI();
    registrarSW();

    window.addEventListener('online', function() {
      notificar(ONLINE);
      actualizarUI(ONLINE);
      sincronizarPendientes();
      window.dispatchEvent(new CustomEvent('refbackonline'));
    });
    window.addEventListener('offline', function() {
      notificar(OFFLINE);
      actualizarUI(OFFLINE);
    });

    if (!esEnLinea()) {
      notificar(OFFLINE);
      actualizarUI(OFFLINE);
    }
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
})();
