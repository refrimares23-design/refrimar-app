// ============================================================
// ACCIONES RÁPIDAS — REFRIMAR OS
// ------------------------------------------------------------
// FAB (botón flotante) + panel de acciones rápidas compartido
// por todas las páginas internas del sistema (se incluye con
// <script src="quick-actions.js"> justo antes de </body>).
//
// Acciones (cada una abre su formulario en la página destino):
//   1. nueva-venta        -> facturacion.html (focus buscador)
//   2. nuevo-producto     -> inventario.html (modal alta producto)
//   3. pago-movil         -> caja.html       (modal pago móvil)
//   4. traspaso           -> sucursales.html (form traspaso)
//
// Navegación entre páginas:
//   - Si YA se está en la página destino, se lanza el evento
//     'qa-action' (detail = id de la acción) y la página abre su
//     formulario sin recargar.
//   - Si no, se navega a "<página>?qa=<id>" y la página lee el
//     query param al cargar (ver handlers en cada página).
//
// La sucursal actual vive en sessionStorage (sucursal-selector.js),
// así que navegar NO la pierde: no hay que hacer nada extra.
//
// Estética: misma paleta Cyberstock Frontier (clases Tailwind
// bg-primary / surface-container-lowest / outline-variant), iconos
// Material Symbols (los que ya usa todo el sistema) y fuente
// JetBrains Mono para las etiquetas.
// ============================================================

(function () {
    'use strict';

    // ===== Configuración =====
    var PAGINA = (location.pathname.split('/').pop() || 'index.html');

    // Si por error se incluye en la portada o el login, no hacer nada.
    if (PAGINA === 'login.html' || PAGINA === 'index.html') return;

    // Las 4 acciones rápidas. "pagina" es el destino y "id" el valor
    // del query param / evento que la página destino sabe interpretar.
    var ACCIONES = [
        { id: 'nueva-venta',    etiqueta: 'Nueva venta',          detalle: 'Abrir facturación',  icono: 'receipt_long',    pagina: 'facturacion.html', perm: 'facturar' },
        { id: 'nuevo-producto', etiqueta: 'Agregar producto',     detalle: 'Alta de producto',   icono: 'inventory_2',     pagina: 'inventario.html', perm: 'editar_inventario' },
        { id: 'pago-movil',     etiqueta: 'Registrar pago móvil', detalle: 'Pagos móviles',      icono: 'phone_iphone',    pagina: 'caja.html', perm: 'caja_admin' },
        { id: 'traspaso',       etiqueta: 'Transferir a sucursal',detalle: 'Traspaso de producto', icono: 'local_shipping', pagina: 'sucursales.html', perm: 'gestionar_sucursales' }
    ].filter(function (a) { return typeof window.can !== 'function' || window.can(a.perm); });

    // ===== Inyectar CSS propio (posicionamiento + animación) =====
    // El resto del aspecto se logra con clases Tailwind del sistema.
    var estilo = document.createElement('style');
    estilo.textContent =
        '.qa-fab{position:fixed;right:20px;bottom:20px;z-index:35;width:58px;height:58px;' +
        'border-radius:9999px;display:flex;align-items:center;justify-content:center;cursor:pointer;' +
        'box-shadow:0 8px 24px rgba(0,144,217,.35),0 2px 8px rgba(0,0,0,.12);' +
        'transition:transform .2s ease,box-shadow .2s ease;}' +
        '.qa-fab:hover{transform:scale(1.06);}' +
        '.qa-fab:active{transform:scale(.94);}' +
        '.qa-fab .qa-fab-icon{transition:transform .25s ease;}' +
        '.qa-fab[aria-expanded="true"] .qa-fab-icon{transform:rotate(45deg);}' +
        '.qa-panel{position:fixed;right:20px;bottom:92px;z-index:45;width:320px;max-width:calc(100vw - 32px);' +
        'border-radius:16px;opacity:0;pointer-events:none;transform:translateY(12px) scale(.98);' +
        'transform-origin:bottom right;transition:opacity .22s ease-out,transform .22s ease-out;}' +
        '.qa-panel.open{opacity:1;pointer-events:auto;transform:translateY(0) scale(1);}' +
        '@media (max-width:767px){' +
        '.qa-fab{bottom:84px;}' +
        '.qa-panel{left:16px;right:16px;width:auto;bottom:156px;transform:translateY(20px) scale(1);}' +
        '.qa-panel.open{transform:translateY(0) scale(1);}' +
        '}' +
        '@media (prefers-reduced-motion:reduce){.qa-fab,.qa-panel,.qa-fab .qa-fab-icon{transition:none;}}';
    document.head.appendChild(estilo);

    // ===== FAB =====
    var fab = document.createElement('button');
    fab.type = 'button';
    fab.id = 'qa-fab';
    fab.className = 'qa-fab bg-gradient-to-r from-primary to-primary-container text-white';
    fab.setAttribute('aria-label', 'Acciones rápidas');
    fab.setAttribute('aria-haspopup', 'menu');
    fab.setAttribute('aria-expanded', 'false');
    fab.innerHTML = '<span class="material-symbols-outlined qa-fab-icon" style="font-size:30px;">add</span>';
    fab.addEventListener('click', function () { QA_abierta() ? QA_cerrar() : QA_abrir(); });

    // ===== Panel de acciones =====
    var panel = document.createElement('div');
    panel.id = 'qa-panel';
    panel.className = 'qa-panel bg-surface-container-lowest/95 backdrop-blur-md border border-outline-variant/50 shadow-2xl overflow-hidden';
    panel.setAttribute('role', 'menu');
    panel.setAttribute('aria-label', 'Acciones rápidas');

    var header = document.createElement('div');
    header.className = 'px-4 py-3 border-b border-outline-variant/30 bg-primary/5 flex items-center justify-between';
    header.innerHTML = '<span class="text-[11px] font-black uppercase tracking-wider text-primary font-mono-data">Acciones rápidas</span>' +
        '<button type="button" id="qa-close" aria-label="Cerrar panel" class="text-on-surface-variant hover:opacity-70 p-1 rounded-md hover:bg-surface-container-high transition-colors">' +
        '<span class="material-symbols-outlined" style="font-size:18px;">close</span></button>';
    panel.appendChild(header);

    var lista = document.createElement('div');
    lista.className = 'p-1.5 flex flex-col gap-0.5';
    ACCIONES.forEach(function (a) {
        var btn = document.createElement('button');
        btn.type = 'button';
        btn.className = 'qa-item flex items-center gap-3 w-full text-left px-3 py-2.5 rounded-xl hover:bg-surface-container-high/60 active:scale-[0.98] transition-all cursor-pointer';
        btn.setAttribute('role', 'menuitem');
        btn.innerHTML =
            '<span class="shrink-0 w-9 h-9 rounded-lg bg-primary/10 text-primary flex items-center justify-center">' +
            '<span class="material-symbols-outlined" style="font-size:19px;">' + a.icono + '</span></span>' +
            '<span class="min-w-0">' +
            '<span class="block font-mono-data text-sm font-bold text-on-background truncate">' + a.etiqueta + '</span>' +
            '<span class="block text-[11px] text-on-surface-variant truncate">' + a.detalle + '</span>' +
            '</span>';
        btn.addEventListener('click', function () { QA_ejecutar(a); });
        btn.addEventListener('keydown', function (e) {
            // Navegación con flechas dentro del panel (accesibilidad).
            var items = lista.querySelectorAll('.qa-item');
            var i = Array.prototype.indexOf.call(items, btn);
            if (e.key === 'ArrowDown') { e.preventDefault(); items[(i + 1) % items.length].focus(); }
            else if (e.key === 'ArrowUp') { e.preventDefault(); items[(i - 1 + items.length) % items.length].focus(); }
        });
        lista.appendChild(btn);
    });
    panel.appendChild(lista);

    document.body.appendChild(fab);
    document.body.appendChild(panel);

    // ===== Lógica de apertura / cierre =====
    function QA_abierta() { return panel.classList.contains('open'); }

    function QA_abrir() {
        fab.setAttribute('aria-expanded', 'true');
        panel.classList.add('open');
        var primero = panel.querySelector('.qa-item');
        if (primero) setTimeout(function () { primero.focus(); }, 30);
    }

    function QA_cerrar() {
        fab.setAttribute('aria-expanded', 'false');
        panel.classList.remove('open');
        fab.focus();
    }

    function QA_ejecutar(accion) {
        QA_cerrar();
        // Si ya estamos en la página destino, la página abre su
        // formulario vía el evento 'qa-action' (sin recargar).
        if (PAGINA === accion.pagina) {
            window.dispatchEvent(new CustomEvent('qa-action', { detail: accion.id }));
            return;
        }
        // Si no, navegamos; sessionStorage conserva la sucursal actual.
        window.location.href = accion.pagina + '?qa=' + accion.id;
    }

    // Cerrar al tocar fuera del FAB/panel.
    document.addEventListener('pointerdown', function (e) {
        if (!QA_abierta()) return;
        if (fab.contains(e.target) || panel.contains(e.target)) return;
        QA_cerrar();
    });

    // Cerrar con Escape y devolver el foco al FAB.
    document.addEventListener('keydown', function (e) {
        if (e.key === 'Escape' && QA_abierta()) {
            e.preventDefault();
            QA_cerrar();
        }
    });

    // Botón de cierre del encabezado del panel.
    var btnCerrar = document.getElementById('qa-close');
    if (btnCerrar) btnCerrar.addEventListener('click', QA_cerrar);
})();
