/*
 * REFRIMAR OS — Service Worker
 * Cachea assets estáticos para funcionamiento offline.
 * Las llamadas a la API (Supabase/Worker) no se cachean — van directo a red.
 */

const CACHE_NAME = 'refrimar-v1';
const STATIC_ASSETS = [
  '/',
  '/index.html',
  '/login.html',
  '/facturacion.html',
  '/dashboard.html',
  '/caja.html',
  '/cierre_diario.html',
  '/reportes.html',
  '/inventario.html',
  '/clientes.html',
  '/cotizaciones.html',
  '/devoluciones.html',
  '/compras.html',
  '/gastos.html',
  '/kardex.html',
  '/sucursales.html',
  '/usuarios.html',
  '/configuracion.html',
  '/carga-ia.html',
  '/css/design-system.css',
  '/auth-session.js',
  '/supabase-config.js',
  '/sucursal-selector.js',
  '/quick-actions.js',
  '/mobile-tables.js',
  '/offline-manager.js',
  '/whatsapp-alerta.js',
  '/manifest.json'
];

self.addEventListener('install', function(event) {
  event.waitUntil(
    caches.open(CACHE_NAME).then(function(cache) {
      return cache.addAll(STATIC_ASSETS).catch(function(err) {
        console.warn('[SW] Cache addAll fallback:', err);
        return Promise.allSettled(
          STATIC_ASSETS.map(function(url) {
            return cache.add(url).catch(function() {
              console.warn('[SW] No se pudo cachear:', url);
            });
          })
        );
      });
    })
  );
  self.skipWaiting();
});

self.addEventListener('activate', function(event) {
  event.waitUntil(
    caches.keys().then(function(names) {
      return Promise.all(
        names.filter(function(name) { return name !== CACHE_NAME; })
             .map(function(name) { return caches.delete(name); })
      );
    })
  );
  self.clients.claim();
});

self.addEventListener('fetch', function(event) {
  var url = new URL(event.request.url);

  // No cachear llamadas a APIs externas
  if (url.hostname !== location.hostname) return;
  if (url.pathname.startsWith('/api/')) return;

  // Network-first para HTML (siempre buscar versión fresca)
  if (event.request.mode === 'navigate' || event.request.headers.get('accept')?.includes('text/html')) {
    event.respondWith(
      fetch(event.request).then(function(response) {
        var clone = response.clone();
        caches.open(CACHE_NAME).then(function(cache) { cache.put(event.request, clone); });
        return response;
      }).catch(function() {
        return caches.match(event.request).then(function(cached) {
          return cached || caches.match('/');
        });
      })
    );
    return;
  }

  // Cache-first para assets estáticos (CSS, JS, imágenes)
  event.respondWith(
    caches.match(event.request).then(function(cached) {
      if (cached) return cached;
      return fetch(event.request).then(function(response) {
        if (response.ok) {
          var clone = response.clone();
          caches.open(CACHE_NAME).then(function(cache) { cache.put(event.request, clone); });
        }
        return response;
      });
    })
  );
});
