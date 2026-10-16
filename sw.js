// ============================================================
// SERVICE WORKER — COMERCIAL REFRIMAR (PWA / Modo Offline)
// ------------------------------------------------------------
// Estrategia:
//  - Navegación, HTML y JS:  network-first  (siempre fresco
//    cuando hay internet; si cae, sirve la copia en caché).
//  - CSS, fuentes e imágenes: cache-first con revalidación en
//    segundo plano (carga instantánea y se actualiza sola).
//  - /api/* y llamadas cruzadas (Supabase, Open-Meteo): siempre
//    a la red; nunca se cachean respuestas de datos.
//
// IMPORTANTE: al desplegar una versión nueva, sube también la
// variable VERSION (ej: 'refrimar-v1.1.0') para que la caché
// vieja se invalide sola.
// ============================================================

const VERSION = 'refrimar-v3.5.0';

const APP_SHELL = [
  '/',
  '/index.html',
  '/login.html',
  '/facturacion.html',
  '/facturacion-clasica.html',
  '/pos.html',
  '/tienda-virtual.html',
  '/sistema.html',
  '/js/pos-app.js',
  '/js/pos-cobro.js',
  '/manifest-pos.json',
  '/precio-form.html',
  '/404.html',
  '/inventario.html',
  '/caja.html',
  '/cierre_diario.html',
  '/clientes.html',
  '/cotizaciones.html',
  '/reportes.html',
  '/sucursales.html',
  '/devoluciones.html',
  '/configuracion.html',
  '/usuarios.html',
  '/colaborador-form.html',
  '/perfil.html',
  '/notificaciones.html',
  '/carga-ia.html',
  '/cuentas_por_pagar.html',
  '/cuentas_por_cobrar.html',
  '/dashboard.html',
  '/compras.html',
  '/kardex.html',
  '/gastos.html',
  '/facturas.html',
  '/productos.html',
  '/producto.html',
  '/producto-form.html',
  '/cuenta-form.html',
  '/bancos.html',
  '/reportes-personalizados.html',
  '/finanzas.html',
  '/cliente-form.html',
  '/conteo-form.html',
  '/oc-form.html',
  '/transferencia-form.html',
  '/transferencias.html',
  '/importar.html',
  '/monedas.html',
  '/proveedores.html',
  '/css/tailwind.css',
  '/turnos.html',
  '/conteos.html',
  '/precios.html',
  '/ordenes_compra.html',
  '/app-pos.html',
  '/js/nk-ui.js',
  '/css/design-system.css',
  '/img/logo-refrimar-azul.png',
  '/img/favicon.png',
  '/supabase-config.js',
  '/auth-session.js',
  '/sucursal-selector.js',
  '/whatsapp-alerta.js',
  '/offline-manager.js',
  '/js/ui-animations.js',
  '/js/glass-folders.js',
  '/js/halftone-footer.js',
  '/manifest.json',
  '/icons/icon-180.png',
  '/icons/icon-192.png',
  '/icons/icon-512.png',
  '/aviso-legal.html',
  '/privacidad.html',
  '/css/legal.css',
  '/js/sitio-config.js',
  '/js/sitio-publico.js',
  '/js/anti-spam.js',
  '/js/rubros.js',
  '/js/plantillas.js',
  '/js/importar-otros.js',
  '/js/escaner-camara.js',
  '/inventario-analisis.html',
  '/auditoria.html',
  '/libros-fiscales.html',
  '/img/logo-mark.png',
  '/img/logo-mark.webp',
  '/img/logo-refrimar-azul.webp'
];

self.addEventListener('install', function(event) {
  event.waitUntil(
    caches.open(VERSION).then(function(cache) {
      return cache.addAll(APP_SHELL);
    }).then(function() {
      return self.skipWaiting();
    })
  );
});

self.addEventListener('activate', function(event) {
  event.waitUntil(
    caches.keys().then(function(keys) {
      return Promise.all(
        keys.filter(function(k) { return k !== VERSION; })
            .map(function(k) { return caches.delete(k); })
      );
    }).then(function() {
      return self.clients.claim();
    })
  );
});

self.addEventListener('fetch', function(event) {
  const request = event.request;
  if (request.method !== 'GET' && request.method !== 'HEAD') return;

  const url = new URL(request.url);

  // Nunca cachear llamadas a la API del Worker ni a orígenes externos.
  if (url.origin !== self.location.origin || url.pathname.indexOf('/api/') === 0) return;

  // Navegación, HTML y JS: network-first (fresco online, caché offline).
  if (request.mode === 'navigate' || url.pathname.indexOf('.html') !== -1 || url.pathname.indexOf('.js') !== -1) {
    event.respondWith(networkFirst(request, url));
    return;
  }

  // El resto (CSS, imágenes, fuentes): cache-first con revalidación.
  event.respondWith(staleWhileRevalidate(request));
});

async function networkFirst(request, url) {
  try {
    const fresh = await fetch(request);
    const copy = fresh.clone();
    caches.open(VERSION).then(function(cache) { cache.put(request, copy); });
    return fresh;
  } catch (err) {
    const cache = await caches.open(VERSION);
    let hit = await cache.match(request);
    if (!hit) {
      // Navegación sin extensión: busca la versión con .html.
      const alt = url.pathname.indexOf('.html') !== -1 ? url.pathname : url.pathname + '.html';
      hit = await cache.match(alt);
    }
    if (!hit) {
      hit = await cache.match('/index.html') || await cache.match('/login.html');
    }
    if (hit) return hit;
    return new Response('Sin conexión', { status: 503, statusText: 'Offline' });
  }
}

async function staleWhileRevalidate(request) {
  const cache = await caches.open(VERSION);
  const cached = await cache.match(request);
  const fetchPromise = fetch(request)
    .then(function(fresh) {
      cache.put(request, fresh.clone());
      return fresh;
    })
    .catch(function() {
      return cached;
    });
  return cached || fetchPromise;
}
