// ============================================================
// REFRIMAR OS — Sidebar dinámico compartido
// Genera la navegación lateral de forma consistente en todas las páginas
// ============================================================

(function() {
    'use strict';

    // Definición de la estructura del sidebar
    var SIDEBAR_ITEMS = [
        { perm: 'dashboard', href: 'dashboard.html', icon: 'space_dashboard', label: 'Dashboard', section: null },
        { section: 'Ventas y clientes' },
        { perm: 'facturacion', href: 'facturacion.html', icon: 'receipt_long', label: 'Facturación' },
        { perm: 'cotizaciones', href: 'cotizaciones.html', icon: 'request_quote', label: 'Cotizaciones' },
        { perm: 'clientes', href: 'clientes.html', icon: 'person', label: 'Clientes' },
        { perm: 'devoluciones', href: 'devoluciones.html', icon: 'assignment_return', label: 'Devoluciones', adminOnly: true },
        { section: 'Inventario y compras' },
        { perm: 'inventario', href: 'inventario.html', icon: 'inventory_2', label: 'Inventario' },
        { perm: 'kardex', href: 'kardex.html', icon: 'swap_vert', label: 'Kardex', adminOnly: true },
        { perm: 'compras', href: 'compras.html', icon: 'local_shipping', label: 'Compras', adminOnly: true },
        { section: 'Finanzas y caja' },
        { perm: 'caja', href: 'caja.html', icon: 'point_of_sale', label: 'Caja' },
        { perm: 'cierre', href: 'cierre_diario.html', icon: 'event_note', label: 'Cierre Diario', adminOnly: true },
        { perm: 'cxc', href: 'cuentas-por-cobrar.html', icon: 'payments', label: 'Cuentas por Cobrar', adminOnly: true },
        { perm: 'gastos', href: 'gastos.html', icon: 'payments', label: 'Gastos', adminOnly: true },
        { section: 'Gestión' },
        { perm: 'carga-ia', href: 'carga-ia.html', icon: 'neurology', label: 'Carga IA', adminOnly: true },
        { perm: 'reportes', href: 'reportes.html', icon: 'bar_chart', label: 'Reportes' },
        { perm: 'sucursales', href: 'sucursales.html', icon: 'storefront', label: 'Sucursales', adminOnly: true },
        { perm: 'configuracion', href: 'configuracion.html', icon: 'settings', label: 'Configuración', adminOnly: true },
        { perm: 'usuarios', href: 'usuarios.html', icon: 'group', label: 'Usuarios', adminOnly: true }
    ];

    function buildSidebar(currentHref) {
        var nav = document.createElement('nav');
        nav.className = 'flex flex-col gap-xs flex-1 overflow-y-auto';

        var currentPath = currentHref || window.location.pathname;

        SIDEBAR_ITEMS.forEach(function(item) {
            if (item.section) {
                var label = document.createElement('div');
                label.className = 'sidebar-section-label';
                label.textContent = item.section;
                nav.appendChild(label);
                return;
            }

            var a = document.createElement('a');
            a.href = item.href;
            a.dataset.perm = item.perm;
            a.className = 'nav-link flex items-center gap-md px-md py-sm text-on-surface-variant hover:bg-surface-container-highest/50 rounded-lg transition-all cursor-pointer';

            var isActive = currentPath.endsWith(item.href) || (item.href === 'dashboard.html' && (currentPath === '/' || currentPath.endsWith('index.html')));
            if (isActive) {
                a.className = 'nav-link flex items-center gap-md px-md py-sm bg-primary-container text-on-primary-container rounded-lg font-bold border border-primary cursor-pointer';
            }

            a.innerHTML = '<span class="material-symbols-outlined">' + item.icon + '</span><span class="font-mono-data text-sm">' + item.label + '</span>';
            nav.appendChild(a);
        });

        return nav;
    }

    function renderSidebar(currentHref) {
        var sidebar = document.getElementById('sidebar');
        if (!sidebar) return;

        var navContainer = sidebar.querySelector('nav');
        if (navContainer) {
            navContainer.remove();
        }

        var newNav = buildSidebar(currentHref);
        // Insertar después del badge de sucursal
        var sucursalBadge = sidebar.querySelector('[data-sucursal-badge]');
        if (sucursalBadge) {
            sucursalBadge.parentNode.insertBefore(newNav, sucursalBadge.nextSibling);
        } else {
            sidebar.appendChild(newNav);
        }
    }

    // Exponer globalmente
    window.renderSidebar = renderSidebar;
})();