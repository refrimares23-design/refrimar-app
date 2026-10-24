// ============================================================
// SERVICE WORKER — COMERCIAL REFRIMAR (PWA / Modo Offline)
// ------------------------------------------------------------
// Estrategia (para que todo abra al instante, incluso con internet lento):
//  - Archivos de la app (APP_SHELL: páginas, JS, CSS, imágenes): se
//    guardan al instalar y se sirven DESDE EL EQUIPO. Todos son de la
//    misma versión, así que nunca se mezcla un HTML nuevo con un JS viejo.
//  - Cada vez que se publica algo hay que subir VERSION: el navegador
//    baja la versión nueva en segundo plano y la usa desde la página siguiente.
//  - Otros archivos del sitio: primero internet; si no hay, la copia guardada.
//  - Fuentes de Google y librerías de CDN con versión fija: se guardan
//    aparte y no se vuelven a bajar.
//  - /api/*, Supabase y demás datos: siempre a internet, nunca se guardan.
// ============================================================

const VERSION = 'refrimar-v3.7.5';
const CACHE_FUENTES = 'refrimar-fuentes-v1';
const CACHE_LIBS = 'refrimar-libs-v1';

const APP_SHELL = [
  '/',
  '/404.html',
  '/app-pos.html',
  '/asistente.html',
  '/auditoria.html',
  '/aviso-legal.html',
  '/bancos.html',
  '/caja.html',
  '/carga-ia.html',
  '/cierre_diario.html',
  '/cliente-form.html',
  '/clientes.html',
  '/colaborador-form.html',
  '/compras.html',
  '/configuracion.html',
  '/conteo-form.html',
  '/conteos.html',
  '/cotizaciones.html',
  '/cuenta-form.html',
  '/cuentas_por_cobrar.html',
  '/cuentas_por_pagar.html',
  '/dashboard.html',
  '/devoluciones.html',
  '/facturacion-clasica.html',
  '/facturacion.html',
  '/facturas.html',
  '/finanzas.html',
  '/gastos.html',
  '/importar.html',
  '/index.html',
  '/inventario-analisis.html',
  '/inventario.html',
  '/invitacion.html',
  '/kardex.html',
  '/libros-fiscales.html',
  '/login.html',
  '/mi-plan.html',
  '/monedas.html',
  '/notificaciones.html',
  '/oc-form.html',
  '/ordenes_compra.html',
  '/perfil.html',
  '/pos.html',
  '/precio-form.html',
  '/precios.html',
  '/privacidad.html',
  '/producto-form.html',
  '/producto.html',
  '/productos.html',
  '/proveedores.html',
  '/registro.html',
  '/reportes-personalizados.html',
  '/reportes.html',
  '/sistema.html',
  '/software.html',
  '/sucursales.html',
  '/superadmin.html',
  '/terminos.html',
  '/tienda-virtual.html',
  '/transferencia-form.html',
  '/transferencias.html',
  '/turnos.html',
  '/usuarios.html',
  '/auth-session.js',
  '/css/design-system.css',
  '/css/fuentes.css',
  '/fonts/inter-latin-300-normal.woff2',
  '/fonts/inter-latin-400-normal.woff2',
  '/fonts/inter-latin-500-normal.woff2',
  '/fonts/inter-latin-600-normal.woff2',
  '/fonts/inter-latin-700-normal.woff2',
  '/fonts/inter-latin-900-normal.woff2',
  '/fonts/jetbrains-mono-latin-400-normal.woff2',
  '/fonts/jetbrains-mono-latin-500-normal.woff2',
  '/fonts/jetbrains-mono-latin-700-normal.woff2',
  '/fonts/material-symbols-outlined.woff2',
  '/fonts/poppins-latin-300-normal.woff2',
  '/fonts/poppins-latin-400-normal.woff2',
  '/fonts/poppins-latin-500-normal.woff2',
  '/fonts/poppins-latin-600-normal.woff2',
  '/fonts/poppins-latin-700-normal.woff2',
  '/fonts/poppins-latin-800-normal.woff2',
  '/fonts/roboto-latin-300-normal.woff2',
  '/fonts/roboto-latin-400-normal.woff2',
  '/fonts/roboto-latin-500-normal.woff2',
  '/fonts/roboto-latin-700-normal.woff2',
  '/css/legal.css',
  '/css/tailwind.css',
  '/icons/icon-180.png',
  '/icons/icon-512.png',
  '/img/estados/cargando.svg',
  '/img/estados/error.svg',
  '/img/estados/exito.svg',
  '/img/favicon.png',
  '/img/logo-mark.png',
  '/img/logo-refrimar-azul.png',
  '/js/anti-spam.js',
  '/js/documentos.js',
  '/js/empresa.js',
  '/js/escaner-camara.js',
  '/js/glass-folders.js',
  '/js/halftone-footer.js',
  '/js/importar-otros.js',
  '/js/nk-ui.js',
  '/js/plantillas.js',
  '/js/pos-app.js',
  '/js/pos-cobro.js',
  '/js/rubros.js',
  '/js/sitio-config.js',
  '/js/sitio-publico.js',
  '/js/ui-animations.js',
  '/manifest-pos.json',
  '/manifest.json',
  '/mobile-tables.js',
  '/offline-manager.js',
  '/quick-actions.js',
  '/sucursal-selector.js',
  '/supabase-config.js',
  '/supabase-js-2.117.2.js',
  '/whatsapp-alerta.js'
];

self.addEventListener('install', function(event) {
  event.waitUntil((async function() {
    const cache = await caches.open(VERSION);
    // Uno por uno: si falta un archivo, no se cae toda la instalación
    await Promise.all(APP_SHELL.map(function(u) {
      return fetch(new Request(u, { cache: 'reload' })).then(function(r) {
        if (!r.ok) return;
        // Cloudflare puede redirigir /pagina.html → /pagina: se guarda el contenido sin la redirección
        if (r.redirected) return r.blob().then(function(b) { return cache.put(u, new Response(b, { status: 200, headers: r.headers })); });
        return cache.put(u, r);
      }).catch(function() {});
    }));
    await self.skipWaiting();
  })());
});

self.addEventListener('activate', function(event) {
  event.waitUntil(
    caches.keys().then(function(keys) {
      return Promise.all(
        keys.filter(function(k) { return k !== VERSION && k !== CACHE_FUENTES && k !== CACHE_LIBS; })
            .map(function(k) { return caches.delete(k); })
      );
    }).then(function() {
      return self.clients.claim();
    })
  );
});

const EN_SHELL = new Set(APP_SHELL);
const LIB_FIJA = /^https:\/\/(cdnjs\.cloudflare\.com\/ajax\/libs\/[^/]+\/\d|cdn\.jsdelivr\.net\/npm\/[^/]+@\d+\.\d+\.\d+|unpkg\.com\/[^/]+@\d+\.\d+\.\d+)/;

self.addEventListener('fetch', function(event) {
  const request = event.request;
  if (request.method !== 'GET') return;
  const url = new URL(request.url);

  if (url.origin !== self.location.origin) {
    if (url.hostname === 'fonts.googleapis.com' || url.hostname === 'fonts.gstatic.com') {
      event.respondWith(staleWhileRevalidate(request, CACHE_FUENTES));
    } else if (LIB_FIJA.test(request.url)) {
      event.respondWith(cacheFirst(request, CACHE_LIBS));
    }
    return;   // Supabase y demás: directo a internet
  }
  if (url.pathname.indexOf('/api/') === 0 || /pos-version\.json$|\.exe$/.test(url.pathname)) return;

  let ruta = url.pathname;
  if (request.mode === 'navigate' && !EN_SHELL.has(ruta) && EN_SHELL.has(ruta + '.html')) ruta = ruta + '.html';
  // Las páginas leen sus parámetros (?codigo=…) con JS: la misma copia sirve para todas
  if (EN_SHELL.has(ruta) && (!url.search || request.mode === 'navigate' || /\.html$/.test(ruta))) {
    event.respondWith(desdeShell(request, ruta, url));
    return;
  }
  event.respondWith(networkFirst(request, url));
});

async function desdeShell(request, ruta, url) {
  const cache = await caches.open(VERSION);
  const hit = await cache.match(ruta);
  if (hit) return hit;
  return networkFirst(request, url);
}

async function networkFirst(request, url) {
  try {
    const fresh = await fetch(request);
    if (fresh.ok && url.search === '') {
      const copy = fresh.clone();
      caches.open(VERSION).then(function(cache) { cache.put(request, copy); });
    }
    return fresh;
  } catch (err) {
    const cache = await caches.open(VERSION);
    let hit = await cache.match(request, { ignoreSearch: true });
    if (!hit) {
      const alt = url.pathname.indexOf('.html') !== -1 ? url.pathname : url.pathname + '.html';
      hit = await cache.match(alt);
    }
    if (!hit && request.mode === 'navigate') {
      hit = await cache.match('/index.html') || await cache.match('/login.html');
    }
    if (hit) return hit;
    return new Response('Sin conexión', { status: 503, statusText: 'Offline' });
  }
}

async function cacheFirst(request, nombre) {
  const cache = await caches.open(nombre);
  const hit = await cache.match(request);
  if (hit) return hit;
  const fresh = await fetch(request);
  if (fresh.ok || fresh.type === 'opaque') cache.put(request, fresh.clone());
  return fresh;
}

async function staleWhileRevalidate(request, nombre) {
  const cache = await caches.open(nombre);
  const cached = await cache.match(request);
  const fetchPromise = fetch(request)
    .then(function(fresh) {
      if (fresh.ok || fresh.type === 'opaque') cache.put(request, fresh.clone());
      return fresh;
    })
    .catch(function() { return cached; });
  return cached || fetchPromise;
}
