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

// Tema claro / oscuro (se guarda en este navegador)
function temaActual() { try { return localStorage.getItem('refrimar_tema') === 'oscuro' ? 'oscuro' : 'claro'; } catch (e) { return 'claro'; } }
function ponerTema(t) {
    try { localStorage.setItem('refrimar_tema', t === 'oscuro' ? 'oscuro' : 'claro'); } catch (e) {}
    document.documentElement.classList.toggle('nk-dark', t === 'oscuro');
}
window.temaActual = temaActual; window.ponerTema = ponerTema;
if (temaActual() === 'oscuro') document.documentElement.classList.add('nk-dark');

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
window.limpiarSesion = function(porSalir) {
    // Si no viene de "Cerrar sesión" es porque la sesión venció: login.html lo avisa
    try { if (!porSalir && sessionStorage.getItem(window.REF_SESION_KEY)) sessionStorage.setItem('refrimar_expirada', '1'); } catch (e) {}
    var claves = [window.REF_SESION_KEY, window.REF_SUCURSAL_KEY];
    claves.forEach(function(k) {
        try { localStorage.removeItem(k); } catch (e) {}
        try { sessionStorage.removeItem(k); } catch (e) {}
    });
};

// Cierra sesión y vuelve al flujo inicial de login.html.
window.cerrarSesion = function() {
    window.limpiarSesion(true);
    var ir = function () { window.location.href = 'login.html'; };
    try {
        if (typeof supabaseClient !== 'undefined' && supabaseClient.auth) {
            var t = setTimeout(ir, 1500);
            supabaseClient.auth.signOut().then(function () { clearTimeout(t); ir(); }, function () { clearTimeout(t); ir(); });
            return;
        }
    } catch (e) {}
    ir();
};

// ============================================================
// PERMISSION GUARD — Administrador vs Empleado (estilo Norkut)
// ------------------------------------------------------------
//   can('ver_costos')  -> true/false según el rol logueado.
//   Admin: acceso total. Empleado (cajero/vendedor/otro): solo
//   facturar, su caja (en el POS), clientes, inventario en
//   lectura, cotizar y su dashboard (sin utilidades).
// Además:
//   - Bloquea la ruta aunque escriban la URL directa.
//   - Quita del DOM los links del menú sin permiso.
//   - Quita del DOM los elementos [data-can="permiso"].
// ============================================================
(function () {
    var PERMISOS_EMPLEADO = ['facturar', 'ver_mi_caja', 'registrar_clientes', 'ver_inventario', 'cotizar', 'ver_dashboard'];


    // ---- Permisos por módulo (estilo Norkut) ----
    // [clave, nombre, descripción, permisos internos que otorga]
    var PERMISOS_ARBOL = [
        { id: 'gestion', nombre: 'Gestión', desc: 'Administra configuraciones generales del sistema.', items: [
            ['gestion.ver', 'Visualizar gestión', 'Consulta el panel de usuarios y su estado actual sin realizar cambios.', ['ver_equipo', 'usuarios']],
            ['gestion.invitar', 'Invitar usuario', 'Envía invitaciones para que nuevos usuarios se unan al equipo.', ['ver_equipo', 'invitar_usuario']],
            ['gestion.permisos', 'Modificar permisos de usuario', 'Asigna o revoca permisos de acceso de otros usuarios.', ['ver_equipo', 'modificar_permisos']],
            ['gestion.suspender', 'Suspender usuario', 'Restringe temporalmente el acceso de un usuario al sistema.', ['ver_equipo', 'suspender_usuario']],
            ['gestion.cancelar', 'Cancelar invitación de usuario', 'Anula invitaciones pendientes de usuarios no registrados.', ['ver_equipo', 'cancelar_invitacion']],
            ['gestion.tasa', 'Actualizar tasa de cambio', 'Modifica las tasas de cambio utilizadas en el sistema.', ['actualizar_tasa']],
            ['gestion.crear', 'Crear usuario', 'Registra nuevos usuarios en la plataforma.', ['ver_equipo', 'invitar_usuario']]] },
        { id: 'productos', nombre: 'Productos', desc: 'Crea, edita y organiza productos del catálogo.', items: [
            ['productos.ver', 'Visualizar productos', 'Consulta el catálogo de productos sin realizar cambios.', ['ver_inventario', 'inventario']],
            ['productos.gestionar', 'Gestionar productos', 'Crea, edita y elimina productos del catálogo.', ['ver_inventario', 'inventario', 'editar_inventario', 'ver_costos']],
            ['productos.datos', 'Modificar datos generales', 'Edita información general de los productos.', ['ver_inventario', 'inventario', 'editar_inventario']],
            ['productos.importar', 'Importar productos', 'Carga productos masivamente desde archivos externos.', ['ver_inventario', 'inventario', 'importar_productos', 'carga-ia']],
            ['productos.sucursal', 'Modificar datos de sucursal', 'Actualiza información de productos por sucursal.', ['ver_inventario', 'inventario', 'editar_inventario']],
            ['productos.empaques', 'Gestionar empaques', 'Administra empaques y presentaciones de productos.', ['ver_inventario', 'inventario', 'editar_inventario']]] },
        { id: 'inventario', nombre: 'Inventario', desc: 'Controla stock, movimientos y ajustes de inventario.', items: [
            ['inventario.ver', 'Visualizar inventario', 'Consulta niveles de stock y movimientos sin realizar cambios.', ['ver_inventario', 'inventario']],
            ['inventario.ajustar', 'Ajustar inventario', 'Realiza ajustes manuales de stock en inventario.', ['ver_inventario', 'inventario', 'editar_inventario', 'ver_costos', 'kardex']],
            ['inventario.contar', 'Contar inventario', 'Ejecuta conteos físicos de inventario.', ['ver_inventario', 'inventario', 'contar_inventario']],
            ['inventario.planificar', 'Planificar conteo', 'Programa y organiza conteos de inventario.', ['ver_inventario', 'inventario', 'contar_inventario', 'planificar_conteo']]] },
        { id: 'transferencias', nombre: 'Transferencias', desc: 'Gestiona movimientos de stock entre sucursales.', items: [
            ['transferencias.ver', 'Visualizar transferencias', 'Consulta transferencias entre sucursales sin realizar cambios.', ['ver_transferencias', 'inventario']],
            ['transferencias.gestionar', 'Gestionar transferencia', 'Crea y envía transferencias de stock entre sucursales.', ['ver_transferencias', 'inventario', 'gestionar_transferencias']],
            ['transferencias.modificar', 'Modificar transferencia', 'Edita transferencias en curso.', ['ver_transferencias', 'inventario', 'gestionar_transferencias']],
            ['transferencias.recibir', 'Recibir transferencia', 'Confirma la recepción de stock transferido.', ['ver_transferencias', 'inventario', 'recibir_transferencia']],
            ['transferencias.cancelar', 'Cancelar transferencia', 'Anula transferencias pendientes o en tránsito.', ['ver_transferencias', 'inventario', 'cancelar_transferencia']]] },
        { id: 'compras', nombre: 'Órdenes de compra', desc: 'Crea y administra pedidos a proveedores.', items: [
            ['compras.ver', 'Visualizar órdenes de compra', 'Consulta órdenes de compra sin realizar cambios.', ['ver_compras', 'compras_mod']],
            ['compras.gestionar', 'Gestionar órdenes', 'Crea y administra órdenes de compra a proveedores.', ['ver_compras', 'compras_mod', 'compras']],
            ['compras.modificar', 'Modificar orden', 'Edita órdenes de compra existentes.', ['ver_compras', 'compras_mod', 'compras']],
            ['compras.recibir', 'Recibir orden', 'Registra la recepción de mercancía de órdenes de compra.', ['ver_compras', 'compras_mod', 'compras', 'recibir_compra']],
            ['compras.cancelar', 'Cancelar orden', 'Anula órdenes de compra pendientes.', ['ver_compras', 'compras_mod', 'cancelar_compra']],
            ['compras.validar', 'Validar orden', 'Aprueba órdenes de compra antes de su procesamiento.', ['ver_compras', 'compras_mod', 'validar_compra']],
            ['compras.proveedores', 'Gestionar proveedores', 'Administra el catálogo de proveedores.', ['proveedores', 'compras_mod']]] },
        { id: 'pos', nombre: 'Punto de venta', desc: 'Opera ventas, cobros y transacciones en tienda.', items: [
            ['pos.ver', 'Visualizar punto de venta', 'Consulta información del punto de venta sin realizar cambios.', ['facturar', 'facturacion']],
            ['pos.cajas', 'Gestión de cajas de venta', 'Configura y administra cajas de venta.', ['facturar', 'facturacion', 'caja_admin', 'caja']],
            ['pos.turnos', 'Gestión de turnos', 'Administra apertura y cierre de turnos de caja.', ['facturar', 'facturacion', 'ver_mi_caja']],
            ['pos.facturas', 'Gestión de facturas', 'Consulta y administra facturas emitidas.', ['facturar', 'facturacion']],
            ['pos.modificar_facturas', 'Modificar facturas', 'Edita facturas ya emitidas.', ['facturar', 'facturacion', 'devoluciones']],
            ['pos.descargar', 'Descargar punto de venta', 'Descarga la aplicación de punto de venta.', ['facturar', 'facturacion']],
            ['pos.catalogos_ver', 'Visualizar catálogos', 'Consulta catálogos de productos en el punto de venta.', ['facturar', 'facturacion']],
            ['pos.catalogos_gestionar', 'Gestionar catálogos', 'Configura catálogos disponibles en el punto de venta.', ['facturar', 'facturacion', 'gestionar_catalogos']]] },
        { id: 'tienda', nombre: 'Gestión de tienda', desc: 'Configure sucursales, usuarios y operaciones.', items: [
            ['tienda.ver', 'Visualizar gestión de tienda', 'Consulta configuración de tiendas sin realizar cambios.', ['ver_tiendas', 'sucursales']],
            ['tienda.gestionar', 'Gestionar tiendas', 'Crea y administra sucursales y tiendas.', ['ver_tiendas', 'sucursales', 'gestionar_sucursales', 'todas_sucursales']]] },
        { id: 'finanzas', nombre: 'Finanzas', desc: 'Accede a reportes financieros y movimientos de dinero.', items: [
            ['finanzas.ver', 'Visualizar finanzas', 'Consulta reportes y movimientos financieros sin realizar cambios.', ['ver_finanzas', 'ver_cxc', 'ver_cxp', 'cxc', 'cxp', 'ver_costos', 'ver_utilidades']],
            ['finanzas.gestionar', 'Gestionar finanzas', 'Administra operaciones y configuraciones financieras.', ['ver_finanzas', 'gestionar_finanzas', 'ver_cxc', 'ver_cxp', 'cxc', 'cxp', 'caja_admin', 'caja', 'gastos', 'cierre_diario', 'cierre', 'ver_costos', 'ver_utilidades']]] },
        { id: 'marketing', nombre: 'Marketing', desc: 'Administra campañas, promociones y clientes.', items: [
            ['marketing.ver', 'Visualizar marketing', 'Consulta campañas y promociones sin realizar cambios.', ['ver_marketing']],
            ['marketing.campana', 'Gestionar de campaña', 'Crea y administra campañas de marketing.', ['ver_marketing', 'gestionar_campanas']],
            ['marketing.editar', 'Editar campaña en curso', 'Modifica campañas de marketing en curso.', ['ver_marketing', 'gestionar_campanas']],
            ['marketing.clientes', 'Gestionar clientes', 'Administra la base de datos de clientes.', ['registrar_clientes', 'clientes', 'cotizar', 'cotizaciones']]] },
        { id: 'analitica', nombre: 'Analítica', desc: 'Visualiza métricas, reportes y rendimiento del negocio.', items: [
            ['analitica.ver', 'Visualizar analítica', 'Consulta métricas y dashboards analíticos.', ['ver_analitica', 'reportes']],
            ['analitica.reportes', 'Gestionar reportes', 'Accede a reportes del negocio sin realizar cambios.', ['ver_analitica', 'ver_reportes', 'reportes']]] },
        { id: 'app', nombre: 'Aplicación de ventas', desc: 'Usa la app de ventas para gestionar operaciones comerciales.', items: [
            ['app.emitir', 'Emitir factura', 'Registra ventas y emite facturas desde la app.', ['facturar', 'facturacion']],
            ['app.modificar_productos', 'Modificar productos', 'Edita productos durante una venta activa.', ['app_modificar_productos']],
            ['app.formas_pago', 'Modificar formas de pago', 'Cambia métodos de pago en transacciones.', ['app_formas_pago']],
            ['app.reiniciar', 'Reiniciar factura', 'Cancela y reinicia una factura en curso.', ['app_reiniciar']],
            ['app.buscar_facturas', 'Buscar facturas', 'Busca facturas emitidas anteriormente.', ['facturar']],
            ['app.nota_credito', 'Emitir nota de crédito', 'Emite notas de crédito sobre facturas existentes.', ['devoluciones']],
            ['app.reimprimir', 'Reimprimir documento', 'Reimprime facturas y comprobantes de venta.', ['app_reimprimir']],
            ['app.fiscalizar', 'Fiscalizar documento', 'Envía documentación a sistemas fiscales.', ['app_fiscalizar']],
            ['app.buscar_turnos', 'Buscar turnos', 'Consulta turnos de caja anteriores.', ['facturar']],
            ['app.cerrar_turnos', 'Cerrar turnos', 'Cierra turnos de caja al finalizar la jornada.', ['ver_mi_caja']],
            ['app.disp_fiscales', 'Configurar dispositivos fiscales', 'Configura equipos fiscales conectados al POS.', ['app_fiscal']],
            ['app.impresoras', 'Configurar impresoras', 'Configura impresoras de tickets y facturas.', ['app_impresoras']],
            ['app.reporte_x', 'Imprimir reporte X', 'Imprime reportes X de cierre parcial de caja.', ['app_reporte_x']],
            ['app.reporte_z', 'Imprimir reporte Z', 'Imprime reportes Z de cierre total de caja.', ['app_reporte_z']],
            ['app.descuento', 'Aplicar descuento', 'Aplica descuentos a productos en venta.', ['app_descuento']],
            ['app.preferencias', 'Configurar preferencias', 'Ajusta preferencias de la aplicación de ventas.', ['app_preferencias']],
            ['app.cambiar_precio', 'Cambiar precio de producto', 'Modifica precios de productos durante la venta.', ['app_cambiar_precio']],
            ['app.gaveta', 'Abrir gaveta de efectivo', 'Abre la gaveta de efectivo desde la app.', ['app_gaveta']],
            ['app.eliminar', 'Eliminar productos', 'Elimina productos de una venta en curso.', ['app_eliminar']],
            ['app.pesados', 'Modificar productos pesados', 'Modifica el peso de los productos pesados en la venta.', ['app_pesados']]] },
        { id: 'masivas', nombre: 'Actualizaciones masivas', desc: 'Actualiza precios y datos de productos de forma masiva.', items: [
            ['masivas.precios', 'Precios de productos', 'Actualiza precios de productos de forma masiva.', ['actualizar_precios', 'inventario']]] },
        { id: 'fiscal', nombre: 'Configuración fiscal', desc: 'Configura parámetros fiscales y tributarios del negocio.', items: [
            ['fiscal.ver', 'Visualizar configuración fiscal', 'Consulta configuración fiscal sin realizar cambios.', ['ver_fiscal']],
            ['fiscal.gestionar', 'Gestionar configuración fiscal', 'Administra parámetros y configuración fiscal del negocio.', ['ver_fiscal', 'configuracion']]] }
    ];
    // Todo colaborador con permisos nuevos ve su Resumen general y su perfil
    var PERMISOS_BASE = ['ver_dashboard', 'dashboard'];
    var MAPA_PERMISO = {};
    PERMISOS_ARBOL.forEach(function (g) { g.items.forEach(function (it) { MAPA_PERMISO[it[0]] = it[3] || []; }); });
    function todasLasClaves() { var r = []; PERMISOS_ARBOL.forEach(function (g) { g.items.forEach(function (it) { r.push(it[0]); }); }); return r; }
    function sinApp(lista) { return lista; }
    var ROLES = [
        { id: 'admin', nombre: 'Administrador', permisos: '*' },
        { id: 'supervisor_tienda', nombre: 'Supervisor de tienda', permisos: ['gestion.ver', 'gestion.tasa', 'productos.ver', 'productos.datos', 'productos.sucursal', 'inventario.ver', 'inventario.ajustar', 'inventario.contar', 'inventario.planificar',
            'transferencias.ver', 'transferencias.gestionar', 'transferencias.modificar', 'transferencias.recibir', 'transferencias.cancelar', 'compras.ver', 'compras.recibir',
            'pos.ver', 'pos.cajas', 'pos.turnos', 'pos.facturas', 'pos.modificar_facturas', 'pos.descargar', 'pos.catalogos_ver', 'tienda.ver', 'finanzas.ver', 'marketing.ver', 'marketing.clientes', 'analitica.ver', 'analitica.reportes',
            'app.emitir', 'app.modificar_productos', 'app.formas_pago', 'app.reiniciar', 'app.buscar_facturas', 'app.nota_credito', 'app.reimprimir', 'app.buscar_turnos', 'app.cerrar_turnos', 'app.impresoras', 'app.reporte_x', 'app.reporte_z', 'app.descuento', 'app.cambiar_precio', 'app.gaveta', 'app.eliminar', 'app.pesados', 'masivas.precios'] },
        { id: 'gestor_compras', nombre: 'Gestor de compras', permisos: ['productos.ver', 'inventario.ver', 'transferencias.ver', 'compras.ver', 'compras.gestionar', 'compras.modificar', 'compras.recibir', 'compras.cancelar', 'compras.validar', 'compras.proveedores', 'analitica.ver'] },
        { id: 'gestor_inventario', nombre: 'Gestor de inventario', permisos: ['productos.ver', 'productos.gestionar', 'productos.datos', 'productos.importar', 'productos.sucursal', 'productos.empaques', 'inventario.ver', 'inventario.ajustar', 'inventario.contar', 'inventario.planificar',
            'transferencias.ver', 'transferencias.gestionar', 'transferencias.modificar', 'transferencias.recibir', 'transferencias.cancelar', 'compras.ver', 'compras.recibir', 'masivas.precios'] },
        { id: 'receptor_mercancia', nombre: 'Receptor de mercancía', permisos: ['productos.ver', 'inventario.ver', 'inventario.contar', 'transferencias.ver', 'transferencias.recibir', 'compras.ver', 'compras.recibir'] },
        { id: 'supervisor_caja', nombre: 'Supervisor de caja', permisos: ['gestion.tasa', 'productos.ver', 'inventario.ver', 'pos.ver', 'pos.cajas', 'pos.turnos', 'pos.facturas', 'pos.modificar_facturas', 'pos.descargar', 'pos.catalogos_ver', 'finanzas.ver', 'marketing.clientes', 'analitica.ver',
            'app.emitir', 'app.modificar_productos', 'app.formas_pago', 'app.reiniciar', 'app.buscar_facturas', 'app.nota_credito', 'app.reimprimir', 'app.buscar_turnos', 'app.cerrar_turnos', 'app.impresoras', 'app.reporte_x', 'app.reporte_z', 'app.descuento', 'app.cambiar_precio', 'app.gaveta', 'app.eliminar', 'app.pesados'] },
        { id: 'cajero', nombre: 'Cajero', permisos: ['productos.ver', 'inventario.ver', 'inventario.contar', 'transferencias.ver', 'transferencias.recibir', 'pos.ver', 'pos.turnos', 'pos.descargar', 'pos.catalogos_ver', 'marketing.clientes',
            'app.emitir', 'app.modificar_productos', 'app.formas_pago', 'app.reiniciar', 'app.buscar_facturas', 'app.nota_credito', 'app.reimprimir', 'app.buscar_turnos', 'app.cerrar_turnos', 'app.reporte_x', 'app.gaveta', 'app.eliminar'] }
    ];
    var NOMBRE_ROL = { vendedor: 'Vendedor', empleado: 'Empleado' };
    ROLES.forEach(function (r) { NOMBRE_ROL[r.id] = r.nombre; });
    window.REF_PERMISOS = PERMISOS_ARBOL;
    window.REF_ROLES = ROLES;
    window.nombreRol = function (rol) { return NOMBRE_ROL[rol] || (rol ? String(rol).charAt(0).toUpperCase() + String(rol).slice(1) : 'Colaborador'); };
    window.permisosDeRol = function (rol) { var r = ROLES.find(function (x) { return x.id === rol; }); if (!r) return []; return r.permisos === '*' ? todasLasClaves() : r.permisos.slice(); };
    // Lista que se guarda en usuarios.permisos: claves del árbol + permisos internos (páginas viejas los leen tal cual)
    window.permisosExpandidos = function (claves) {
        var set = {}; (claves || []).forEach(function (k) { set[k] = 1; (MAPA_PERMISO[k] || []).forEach(function (x) { set[x] = 1; }); });
        PERMISOS_BASE.forEach(function (x) { set[x] = 1; });
        set.v2 = 1;
        return Object.keys(set);
    };
    window.esPermisosV2 = function (u) { return !!(u && Array.isArray(u.permisos) && u.permisos.indexOf('v2') >= 0); };
    var cacheEfectivos = { k: null, set: null };
    function efectivos(u) {
        var k = JSON.stringify(u.permisos || []);
        if (cacheEfectivos.k === k) return cacheEfectivos.set;
        var set = {}; window.permisosExpandidos(u.permisos || []).forEach(function (x) { set[x] = 1; });
        cacheEfectivos = { k: k, set: set };
        return set;
    }

    // Página -> permiso requerido para entrar.
    var PAGINA_PERMISO = {
        'dashboard.html': 'ver_dashboard',
        'tienda-virtual.html': 'ver_analitica',
        'facturacion.html': 'facturar',
        'cotizaciones.html': 'cotizar',
        'clientes.html': 'registrar_clientes',
        'inventario.html': 'ver_inventario',
        'caja.html': 'caja_admin',
        'devoluciones.html': 'devoluciones',
        'kardex.html': 'ver_costos',
        'compras.html': 'compras',
        'gastos.html': 'gastos',
        'carga-ia.html': 'editar_inventario',
        'cuentas_por_cobrar.html': 'ver_cxc',
        'cuentas_por_pagar.html': 'ver_cxp',
        'cierre_diario.html': 'cierre_diario',
        'usuarios.html': 'ver_equipo',
        'colaborador-form.html': 'ver_equipo',
        'sucursales.html': 'ver_tiendas',
        'configuracion.html': 'configuracion',
        'sistema.html': 'configuracion',
        'facturas.html': 'facturar',
        'productos.html': 'ver_inventario',
        'producto.html': 'ver_inventario',
        'producto-form.html': 'editar_inventario',
        'importar.html': 'importar_productos',
        'transferencias.html': 'ver_transferencias',
        'transferencia-form.html': 'gestionar_transferencias',
        'oc-form.html': 'compras',
        'conteo-form.html': 'planificar_conteo',
        'cliente-form.html': 'registrar_clientes',
        'finanzas.html': 'ver_finanzas',
        'bancos.html': 'ver_finanzas',
        'cuenta-form.html': 'gestionar_finanzas',
        'reportes-personalizados.html': 'ver_reportes',
        'reporte.html': 'ver_reportes',
        'proveedores.html': 'proveedores',
        'monedas.html': 'configuracion',
        'turnos.html': 'facturar',
        'app-pos.html': 'facturar',
        'pos.html': 'facturar',
        'conteos.html': 'contar_inventario',
        'precios.html': 'actualizar_precios',
        'precio-form.html': 'actualizar_precios',
        'ordenes_compra.html': 'ver_compras',
        'reportes.html': 'ver_analitica'
    };
    window.REF_PAGINA_PERMISO = PAGINA_PERMISO;

    window.esAdmin = function () {
        var u = window.getSesionUsuario();
        return !!(u && u.rol === 'admin');
    };

    window.can = function (permiso) {
        var u = window.getSesionUsuario();
        if (!u) return false;
        if (u.rol === 'admin') return true;
        if (window.esPermisosV2(u)) return !!efectivos(u)[permiso];
        return PERMISOS_EMPLEADO.indexOf(permiso) >= 0;
    };

    // Elimina campos de costo de filas traídas de Supabase (empleado).
    var CAMPOS_COSTO = ['costo', 'costo_unitario', 'costo_promedio', 'costo_usd'];
    window.quitarCostos = function (rows) {
        if (window.can('ver_costos') || !Array.isArray(rows)) return rows;
        return rows.map(function (r) {
            if (!r || typeof r !== 'object') return r;
            var c = Object.assign({}, r);
            CAMPOS_COSTO.forEach(function (k) { delete c[k]; });
            return c;
        });
    };

    function paginaActual() {
        return (location.pathname.split('/').pop() || 'index.html').toLowerCase();
    }

    function destinoSeguro() {
        var u = window.getSesionUsuario();
        var tieneDash = u && (u.rol === 'admin' || (u.permisos || []).indexOf('dashboard') >= 0);
        return tieneDash ? 'dashboard.html' : (window.can && window.can('facturar')) ? 'pos.html' : 'perfil.html';
    }

    // ---- 1. Bloqueo de ruta (URL directa) ----
    var permPagina = PAGINA_PERMISO[paginaActual()];
    // pos.html tiene su propio inicio de sesión (otro cajero puede entrar ahí)
    if (permPagina && paginaActual() !== 'pos.html' && window.getSesionUsuario() && !window.can(permPagina)) {
        window.__refSinPermiso = true;
        try { document.documentElement.style.visibility = 'hidden'; } catch (e) {}
        try { sessionStorage.setItem('refrimar_flash', 'Sin permiso para entrar a esa sección'); } catch (e) {}
        var dest = destinoSeguro();
        if (dest === paginaActual()) dest = 'facturacion.html';
        location.replace(dest);
    }

    // ---- 2. Menú lateral central (estilo Norkut) ----
    // Se construye aquí para TODAS las páginas: una sola definición.
    // [página, ícono, etiqueta, módulo (permisos por usuario)]
    var MENU = [
        { titulo: 'Inicio', items: [
            ['dashboard.html', 'home', 'Resumen general', 'dashboard'],
            ['tienda-virtual.html', 'view_in_ar', 'Tiendas en vivo', 'reportes'],
            ['reportes.html', 'monitoring', 'Dashboard', 'reportes']] },
        { titulo: 'Cadena de suministro', items: [
            { grupo: 'Productos e inventario', items: [
                ['productos.html', 'inventory_2', 'Productos', 'inventario'],
                ['inventario.html', 'warehouse', 'Inventario', 'inventario'],
                ['conteos.html', 'fact_check', 'Conteo de inventario', 'inventario'],
                ['transferencias.html', 'sync_alt', 'Transferencias', 'inventario'],
                ['precios.html', 'sell', 'Actualización de precios', 'inventario'],
                ['kardex.html', 'swap_vert', 'Kardex', 'kardex'],
                ['carga-ia.html', 'document_scanner', 'Carga IA de facturas', 'carga-ia']] },
            { grupo: 'Compras', items: [
                ['ordenes_compra.html', 'shopping_cart', 'Órdenes de compra', 'compras'],
                ['proveedores.html', 'domain', 'Proveedores', 'compras'],
                ['compras.html', 'local_shipping', 'Recepción directa', 'compras']] }] },
        { titulo: 'Marketing', items: [
            ['clientes.html', 'group', 'Clientes', 'clientes'],
            ['cotizaciones.html', 'request_quote', 'Cotizaciones', 'cotizaciones']] },
        { titulo: 'Reportes', items: [
            ['reportes-personalizados.html', 'query_stats', 'Reportes personalizados', 'reportes']] },
        { titulo: 'Finanzas', items: [
            ['finanzas.html', 'account_balance', 'Resumen', 'reportes'],
            { grupo: 'Cuentas', items: [
                ['cuentas_por_pagar.html', 'output', 'Cuentas por pagar', 'cxp'],
                ['cuentas_por_cobrar.html', 'input', 'Cuentas por cobrar', 'cxc']] },
            { grupo: 'Tesorería', items: [
                ['bancos.html', 'account_balance', 'Bancos', 'caja'],
                ['caja.html', 'payments', 'Caja', 'caja'],
                ['gastos.html', 'receipt', 'Gastos', 'gastos'],
                ['cierre_diario.html', 'event_note', 'Cierre diario', 'cierre']] }] },
        { titulo: 'Tienda', items: [
            { grupo: 'POS', items: [
                ['pos.html', 'point_of_sale', 'Abrir punto de venta', 'facturacion', 'pos'],
                ['app-pos.html', 'install_desktop', 'Puntos de venta', 'facturacion'],
                ['facturas.html', 'receipt_long', 'Facturas', 'facturacion'],
                ['turnos.html', 'schedule', 'Turnos', 'facturacion'],
                ['devoluciones.html', 'assignment_return', 'Anulaciones', 'devoluciones']] }] },
        { titulo: null, items: [
            ['@config', 'settings', 'Configuración', 'configuracion']] }
    ];
    // Submenú de Configuración (como Norkut): [página, ícono, nombre, permiso]
    var CONFIG_PAGINAS = [
        ['perfil.html', 'person', 'Perfil', null],
        ['configuracion.html', 'apartment', 'Empresa', 'configuracion'],
        ['monedas.html', 'settings', 'Sistema', 'configuracion'],
        ['usuarios.html', 'group', 'Gestión de equipo', 'ver_equipo'],
        ['sucursales.html', 'storefront', 'Tiendas', 'ver_tiendas'],
        ['notificaciones.html', 'notifications', 'Notificaciones', null],
        ['sistema.html', 'monitor_heart', 'Estado del sistema', 'configuracion']
    ];
    window.REF_CONFIG_PAGINAS = CONFIG_PAGINAS;
    window.configPaginasVisibles = function () { return CONFIG_PAGINAS.filter(function (c) { return !c[3] || window.can(c[3]); }); };
    window.REF_MENU = MENU;

    function permisoModulo(u, modulo) {
        if (!u) return false;
        if (u.rol === 'admin') return true;
        if (window.esPermisosV2(u)) return true; // permisos nuevos: manda el permiso de la página
        // Igual que cada página: el módulo debe estar marcado en Usuarios.
        return (u.permisos || []).indexOf(modulo) >= 0 || modulo === 'facturacion';
    }
    var ALIAS_PAGINA = { 'producto.html': 'productos.html', 'producto-form.html': 'productos.html', 'importar.html': 'productos.html',
        'transferencia-form.html': 'transferencias.html', 'oc-form.html': 'ordenes_compra.html', 'conteo-form.html': 'conteos.html',
        'cliente-form.html': 'clientes.html', 'reporte.html': 'reportes-personalizados.html', 'cuenta-form.html': 'bancos.html', 'colaborador-form.html': 'usuarios.html', 'precio-form.html': 'precios.html' };
    window.REF_ALIAS_PAGINA = ALIAS_PAGINA;
    function paginaMenu() { var p = (location.pathname.split('/').pop() || 'index.html').toLowerCase(); return ALIAS_PAGINA[p] || p; }

    window.organizarSidebar = function () {
        var nav = document.querySelector('#sidebar nav');
        if (!nav || nav.dataset.refOrganizado) return;
        var u = window.getSesionUsuario();
        var base = 'nav-link flex items-center gap-md px-md py-sm rounded-lg transition-all cursor-pointer';
        var actual = paginaMenu();
        var abiertos = {};
        try { abiertos = JSON.parse(sessionStorage.getItem('refrimar_menu_abiertos') || '{}') || {}; } catch (e) {}
        function visible(it) { if (it[0] === '@config') return true; return window.can(PAGINA_PERMISO[it[0]] || 'x') && permisoModulo(u, it[3]); }
        function link(it, cont) {
            var a = document.createElement('a');
            a.href = it[0];
            if (it[0] === '@config') {
                var cp = window.configPaginasVisibles();
                var pref = cp.find(function (c) { return c[0] === 'configuracion.html'; }) || cp[0];
                a.href = pref[0]; a.dataset.config = '1';
            }
            a.className = base;
            if (it[4] === 'pos') { a.target = 'refrimar_pos'; a.title = 'Se abre aparte, como la App POS'; }
            a.innerHTML = '<span class="material-symbols-outlined">' + it[1] + '</span><span class="font-mono-data text-sm">' + it[2] + '</span>';
            cont.appendChild(a);
        }
        nav.innerHTML = '';
        MENU.forEach(function (sec) {
            var hay = sec.items.some(function (x) { return Array.isArray(x) ? visible(x) : x.items.some(visible); });
            if (!hay) return;
            if (sec.titulo) {
                var lab = document.createElement('div');
                lab.className = 'sidebar-section-label';
                lab.textContent = sec.titulo;
                nav.appendChild(lab);
            }
            sec.items.forEach(function (x) {
                if (Array.isArray(x)) { if (visible(x)) link(x, nav); return; }
                var vis = x.items.filter(visible);
                if (!vis.length) return;
                var activo = vis.some(function (it) { return it[0] === actual; });
                var grp = document.createElement('div');
                grp.className = 'nk-grp' + (activo ? ' nk-grp-act' : '');
                var abierto = activo || abiertos[x.grupo] === true;
                if (abierto) grp.classList.add('open');
                grp.innerHTML = '<button type="button" class="nk-grp-head"><span>' + x.grupo + '</span><span class="material-symbols-outlined">expand_more</span></button><div class="nk-grp-body"></div>';
                var body = grp.querySelector('.nk-grp-body');
                vis.forEach(function (it) { link(it, body); });
                grp.querySelector('.nk-grp-head').addEventListener('click', function () {
                    var o = grp.classList.toggle('open');
                    abiertos[x.grupo] = o;
                    try { sessionStorage.setItem('refrimar_menu_abiertos', JSON.stringify(abiertos)); } catch (e) {}
                });
                nav.appendChild(grp);
            });
        });
        nav.dataset.refOrganizado = '1';
        // El menú conserva su posición de scroll al cambiar de página
        var navGuardado = 0, navListo = false;
        try { navGuardado = Number(sessionStorage.getItem('refrimar_nav_scroll')) || 0; } catch (e) {}
        var restaurar = function () { if (navGuardado && nav.scrollTop !== navGuardado) nav.scrollTop = navGuardado; };
        restaurar();
        document.addEventListener('DOMContentLoaded', restaurar);
        requestAnimationFrame(function () { restaurar(); requestAnimationFrame(function () { restaurar(); navListo = true; }); });
        window.addEventListener('load', restaurar);
        var guardarScroll = function () { if (!navListo) return; try { sessionStorage.setItem('refrimar_nav_scroll', String(nav.scrollTop)); } catch (e) {} };
        nav.addEventListener('scroll', guardarScroll, { passive: true });
        window.addEventListener('pagehide', guardarScroll);
        // Precarga la página al pasar el mouse / tocar un link (navegación casi instantánea)
        var precargadas = {};
        var precargar = function (e) {
            var a = e.target.closest && e.target.closest('a.nav-link');
            if (!a || precargadas[a.href]) return;
            precargadas[a.href] = true;
            var l = document.createElement('link'); l.rel = 'prefetch'; l.href = a.href; document.head.appendChild(l);
        };
        nav.addEventListener('mouseover', precargar, { passive: true });
        nav.addEventListener('touchstart', precargar, { passive: true });
    };

    // Oculta títulos de sección cuyos links quedaron todos ocultos.
    function limpiarTitulosVacios() {
        var nav = document.querySelector('#sidebar nav');
        if (!nav) return;
        nav.querySelectorAll('.sidebar-section-label').forEach(function (lab) {
            var n = lab.nextElementSibling, alguno = false;
            while (n && !n.classList.contains('sidebar-section-label')) {
                if ((n.matches('a.nav-link') || n.matches('.nk-grp')) && !n.classList.contains('hidden-modal')) { alguno = true; break; }
                n = n.nextElementSibling;
            }
            lab.style.display = alguno ? '' : 'none';
        });
    }

    // ---- 3. Elementos marcados con data-can ----
    window.aplicarPermisosDOM = function (root) {
        (root || document).querySelectorAll('[data-can]').forEach(function (el) {
            if (!window.can(el.getAttribute('data-can'))) el.remove();
        });
    };

    function aplicarTodo() {
        if (!window.getSesionUsuario()) return;
        window.organizarSidebar();
        window.aplicarPermisosDOM();
    }
    // El script se carga al final del <body>: el DOM ya existe.
    aplicarTodo();
    document.addEventListener('DOMContentLoaded', function () {
        aplicarTodo();
        limpiarTitulosVacios();
        var flash = null;
        try { flash = sessionStorage.getItem('refrimar_flash'); sessionStorage.removeItem('refrimar_flash'); } catch (e) {}
        if (flash) setTimeout(function () { if (typeof window.showToast === 'function') window.showToast(flash, 'error'); }, 300);
        var info = null;
        try { info = sessionStorage.getItem('refrimar_flash_info'); sessionStorage.removeItem('refrimar_flash_info'); } catch (e) {}
        if (info) setTimeout(function () { if (typeof window.showToast === 'function') window.showToast(info, 'info'); }, 400);
    });
    window.addEventListener('load', limpiarTitulosVacios);
})();

// ============================================================
// SUCURSAL ACTIVA — helpers comunes para INSERT/SELECT
// ============================================================
// Id de la sucursal activa (la elegida en login.html).
window.sucursalActivaId = function () {
    try {
        var raw = sessionStorage.getItem(window.REF_SUCURSAL_KEY);
        var s = raw ? JSON.parse(raw) : null;
        return (s && s.id) || '00000000-0000-0000-0000-000000000001';
    } catch (e) { return '00000000-0000-0000-0000-000000000001'; }
};

// Filtra un query por la sucursal activa. En Casa Matriz incluye los
// registros históricos sin sucursal (NULL). opts.nullEnTodas incluye
// NULL en cualquier sucursal (catálogos compartidos heredados).
window.filtrarPorSucursal = function (q, columna, opts) {
    opts = opts || {};
    var col = columna || 'sucursal_id';
    var casa = '00000000-0000-0000-0000-000000000001';
    var id = window.sucursalActivaId();
    if (id === casa || opts.nullEnTodas) return q.or(col + '.eq.' + id + ',' + col + '.is.null');
    return q.eq(col, id);
};

// Llama un RPC con parámetros nuevos (ej. p_sucursal_id). Si la
// migración aún no se corrió en Supabase (firma vieja), reintenta
// sin esos parámetros para no romper la operación.
window.rpcConFallback = async function (fn, args, clavesNuevas) {
    var res = await supabaseClient.rpc(fn, args);
    if (res.error && (res.error.code === 'PGRST202' || /Could not find the function|schema cache/i.test(res.error.message || ''))) {
        var viejo = Object.assign({}, args);
        (clavesNuevas || []).forEach(function (k) { delete viejo[k]; });
        res = await supabaseClient.rpc(fn, viejo);
    }
    return res;
};

// Ejecuta un SELECT filtrado por sucursal; si la columna sucursal_id
// aún no existe (migración pendiente), repite el query sin filtro.
//   await window.selectPorSucursal(function(){ return supabaseClient.from('x').select('*'); }, { nullEnTodas: true })
window.selectPorSucursal = async function (crearQuery, opts) {
    opts = opts || {};
    var res = await window.filtrarPorSucursal(crearQuery(), opts.columna || 'sucursal_id', opts);
    if (res.error && (res.error.code === '42703' || /column .*sucursal_id.* does not exist/i.test(res.error.message || ''))) {
        res = await crearQuery();
    }
    return res;
};

// ============================================================
// ESTILO NORKUT — logo, link activo, barra superior y títulos
// ============================================================
(function () {
    var PI = 'Cadena de suministro <span>/</span> Productos e inventario', CO = 'Cadena de suministro <span>/</span> Compras';
    var SECCION = {
        'dashboard.html': 'Inicio', 'reportes.html': 'Inicio',
        'productos.html': PI, 'producto.html': PI, 'producto-form.html': PI, 'importar.html': PI, 'inventario.html': PI, 'conteos.html': PI, 'conteo-form.html': PI,
        'transferencias.html': PI, 'transferencia-form.html': PI, 'precios.html': PI, 'precio-form.html': PI, 'kardex.html': PI, 'carga-ia.html': PI,
        'ordenes_compra.html': CO, 'oc-form.html': CO, 'proveedores.html': CO, 'compras.html': CO,
        'clientes.html': 'Marketing', 'cliente-form.html': 'Marketing', 'cotizaciones.html': 'Marketing',
        'reportes-personalizados.html': 'Reportes', 'reporte.html': 'Reportes',
        'finanzas.html': 'Finanzas', 'cuentas_por_pagar.html': 'Finanzas <span>/</span> Cuentas', 'cuentas_por_cobrar.html': 'Finanzas <span>/</span> Cuentas',
        'caja.html': 'Finanzas <span>/</span> Tesorería', 'bancos.html': 'Finanzas <span>/</span> Tesorería', 'cuenta-form.html': 'Finanzas <span>/</span> Tesorería', 'gastos.html': 'Finanzas <span>/</span> Tesorería', 'cierre_diario.html': 'Finanzas <span>/</span> Tesorería',
        'sucursales.html': 'Configuración', 'usuarios.html': 'Configuración', 'colaborador-form.html': 'Configuración <span>/</span> Gestión de equipo', 'monedas.html': 'Configuración',
        'perfil.html': 'Configuración', 'notificaciones.html': 'Configuración', 'sistema.html': 'Configuración',
        'facturacion.html': 'Tienda <span>/</span> POS', 'app-pos.html': 'Tienda <span>/</span> POS', 'facturas.html': 'Tienda <span>/</span> POS', 'turnos.html': 'Tienda <span>/</span> POS', 'devoluciones.html': 'Tienda <span>/</span> POS',
        'configuracion.html': 'Configuración'
    };
    var NOMBRE = {
        'dashboard.html': 'Resumen general', 'tienda-virtual.html': 'Tiendas en vivo', 'reportes.html': 'Dashboard',
        'productos.html': 'Productos', 'producto.html': 'Productos <span>/</span> Detalle', 'producto-form.html': 'Productos <span>/</span> Ficha', 'importar.html': 'Productos <span>/</span> Importar',
        'inventario.html': 'Inventario', 'conteos.html': 'Conteo de inventario', 'conteo-form.html': 'Conteo de inventario <span>/</span> Nuevo conteo',
        'transferencias.html': 'Transferencias', 'transferencia-form.html': 'Transferencias <span>/</span> Nueva transferencia',
        'precios.html': 'Actualización de precios', 'precio-form.html': 'Actualización de precios <span>/</span> Nueva actualización de precios', 'kardex.html': 'Kardex', 'carga-ia.html': 'Carga IA',
        'ordenes_compra.html': 'Órdenes de compra', 'oc-form.html': 'Órdenes de compra <span>/</span> Nueva orden de compra', 'proveedores.html': 'Proveedores', 'compras.html': 'Recepción directa',
        'clientes.html': 'Clientes', 'cliente-form.html': 'Clientes <span>/</span> Registro de cliente', 'cotizaciones.html': 'Cotizaciones',
        'reportes-personalizados.html': 'Reportes personalizados', 'reporte.html': 'Reportes personalizados <span>/</span> Reporte',
        'finanzas.html': 'Resumen', 'cuentas_por_pagar.html': 'Cuentas por pagar', 'cuentas_por_cobrar.html': 'Cuentas por cobrar',
        'caja.html': 'Caja', 'bancos.html': 'Cuentas bancarias', 'cuenta-form.html': 'Cuentas bancarias <span>/</span> Registrar cuenta', 'gastos.html': 'Gastos', 'cierre_diario.html': 'Cierre diario',
        'sucursales.html': 'Tiendas', 'usuarios.html': 'Gestión de equipo', 'colaborador-form.html': 'Colaborador', 'monedas.html': 'Sistema',
        'perfil.html': 'Perfil', 'notificaciones.html': 'Notificaciones', 'sistema.html': 'Estado del sistema',
        'facturacion.html': 'Punto de venta', 'app-pos.html': 'Puntos de venta', 'facturas.html': 'Facturas', 'turnos.html': 'Turnos', 'devoluciones.html': 'Anulaciones',
        'configuracion.html': 'Empresa'
    };
    function pagina() { return (location.pathname.split('/').pop() || 'index.html').toLowerCase(); }
    function esc(s) { return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); }

    function logo() {
        var t = document.querySelector('#sidebar .text-2xl.font-black');
        if (!t || t.dataset.nk) return;
        var cont = t.parentElement;
        cont.innerHTML = '<div class="nk-logo"><img src="img/logo-refrimar-azul.png" alt="REFRIMAR" class="nk-logo-img"/></div>' +
            '<div class="nk-logo-sub">Sistema de gestión · POS</div>';
        cont.dataset.nk = '1';
    }

    function linkActivo() {
        var pag = (window.REF_ALIAS_PAGINA || {})[pagina()] || pagina();
        var esCfg = esPaginaConfig();
        document.querySelectorAll('#sidebar a.nav-link').forEach(function (a) {
            var href = (a.getAttribute('href') || '').split('?')[0].toLowerCase();
            a.classList.toggle('nk-active', esCfg ? a.dataset.config === '1' : href === pag);
        });
    }

    function tituloLimpio() {
        var h = document.querySelector('main header h1');
        if (!h || h.dataset.nk) return;
        var txt = h.textContent.replace(/^\s*REFRIMAR\s*\/\/\s*/i, '').trim();
        if (txt && txt === txt.toUpperCase()) txt = txt.charAt(0) + txt.slice(1).toLowerCase();
        if (NOMBRE[pagina()] && /^punto de venta$/i.test(txt) === false && pagina() === 'facturacion.html') txt = 'Punto de venta';
        h.textContent = txt;
        h.dataset.nk = '1';
    }

    function esPaginaConfig() {
        var p = pagina(); if (p === 'colaborador-form.html') p = 'usuarios.html';
        return (window.REF_CONFIG_PAGINAS || []).some(function (c) { return c[0] === p; });
    }
    // Submenú de Configuración a la izquierda del contenido (como Norkut)
    function configNav() {
        var main = document.querySelector('main');
        if (!main || !esPaginaConfig() || main.querySelector('.nk-cfg')) return;
        var p = pagina(); if (p === 'colaborador-form.html') p = 'usuarios.html';
        var wrap = document.createElement('div');
        wrap.className = 'nk-cfg';
        var nav = document.createElement('nav');
        nav.className = 'nk-cfg-nav';
        nav.innerHTML = '<div class="nk-cfg-tit">Configuraciones</div>' + window.configPaginasVisibles().map(function (c) {
            return '<a href="' + c[0] + '" class="' + (c[0] === p ? 'on' : '') + '"><span class="material-symbols-outlined">' + c[1] + '</span>' + esc(c[2]) + '</a>';
        }).join('');
        var cont = document.createElement('div');
        cont.className = 'nk-cfg-body';
        var top = main.querySelector('.nk-topbar');
        Array.prototype.slice.call(main.childNodes).forEach(function (n) { if (n !== top) cont.appendChild(n); });
        wrap.appendChild(nav); wrap.appendChild(cont);
        main.appendChild(wrap);
    }

    function fmtTasa(n) { return Number(n || 0).toLocaleString('es-VE', { minimumFractionDigits: 2, maximumFractionDigits: 4 }); }

    function topbar() {
        var main = document.querySelector('main');
        var u = window.getSesionUsuario && window.getSesionUsuario();
        if (!main || !u || main.querySelector('.nk-topbar')) return;
        var pag = pagina();
        var suc = null;
        try { suc = JSON.parse(sessionStorage.getItem(window.REF_SUCURSAL_KEY) || 'null'); } catch (e) {}
        suc = suc || { nombre: 'Casa Matriz' };
        var nombre = String(u.nombre || 'Usuario');
        var ini = nombre.split(/\s+/).map(function (p) { return p.charAt(0); }).join('').slice(0, 2).toUpperCase();
        var editaTasa = window.can('actualizar_tasa') || window.can('configuracion');
        var admin = u.rol === 'admin';
        var multiTienda = admin || (Array.isArray(u.sucursales) && u.sucursales.length > 1);
        var avatar = u.avatar_url ? '<img src="' + esc(u.avatar_url) + '" alt="" referrerpolicy="no-referrer"/>' : esc(ini);
        var tema = temaActual();
        var bar = document.createElement('div');
        bar.className = 'nk-topbar';
        bar.innerHTML =
            '<div class="nk-crumbs">' + (SECCION[pag] ? SECCION[pag].split(' <span>/</span> ').map(esc).join(' <span>/</span> ') + ' <span>/</span> ' : '') + '<b>' + (NOMBRE[pag] || '').split(' <span>/</span> ').map(esc).join('</b> <span>/</span> <b>') + '</b></div>' +
            '<div class="nk-top-right">' +
                '<button type="button" class="nk-pill nk-pill-suc' + (multiTienda ? '' : ' ro') + '" data-nk-open="suc" title="Tienda activa"><span class="material-symbols-outlined">storefront</span>' + esc(suc.nombre || 'Casa Matriz') + '</button>' +
                '<div class="nk-pop-wrap" data-nk-box="tasa">' +
                    '<button type="button" class="nk-pill" data-nk-open="tasa" title="Tasa de cambio"><span class="material-symbols-outlined">currency_exchange</span><span id="nk-tasa">—</span> VES</button>' +
                    '<div class="nk-pop nk-pop-tasa">' +
                        '<div class="nk-pop-title">Tasa de cambio</div>' +
                        '<div class="nk-pop-sub">Se usa en el punto de venta, facturas, cotizaciones y documentos internos.</div>' +
                        '<div class="nk-pop-cur">VES <span class="material-symbols-outlined">sync_alt</span> <b>USD</b></div>' +
                        '<div class="nk-stepper' + (editaTasa ? '' : ' ro') + '">' +
                            (editaTasa ? '<button type="button" data-step="-1" aria-label="Bajar">−</button>' : '') +
                            '<input id="nk-tasa-in" type="text" inputmode="decimal" ' + (editaTasa ? '' : 'readonly') + '/>' +
                            (editaTasa ? '<button type="button" data-step="1" aria-label="Subir">+</button>' : '') +
                        '</div>' +
                        '<div class="nk-pop-bcv">Tasa según BCV: <b id="nk-bcv">consultando…</b>' + (editaTasa ? ' <button type="button" id="nk-usar-bcv" disabled>Usar tasa</button>' : '') + '</div>' +
                        '<div class="nk-pop-upd"><span class="material-symbols-outlined">schedule</span><span id="nk-tasa-upd">Última actualización: —</span></div>' +
                        '<div class="nk-pop-sep"></div>' +
                        '<div class="nk-pop-venta"><span>Equivalencia</span><b id="nk-tasa-eq">1 USD = — VES</b></div>' +
                        '<div class="nk-pop-foot"><a href="monedas.html">Ver historial <span class="material-symbols-outlined">open_in_new</span></a>' +
                            (editaTasa ? '<button type="button" class="nk-btn" id="nk-tasa-ok"><span class="material-symbols-outlined">save</span>Actualizar</button>' : '') + '</div>' +
                    '</div>' +
                '</div>' +
                '<a href="notificaciones.html" class="nk-bell" title="Notificaciones"><span class="material-symbols-outlined">notifications</span><i id="nk-bell-n" hidden></i></a>' +
                '<div class="nk-pop-wrap nk-user" data-nk-box="user">' +
                    '<button type="button" class="nk-user-btn" data-nk-open="user"><span class="nk-avatar">' + avatar + '</span><span class="nk-user-name">' + esc(nombre) + '</span>' +
                    '<span class="material-symbols-outlined" style="font-size:18px">expand_more</span></button>' +
                    '<div class="nk-pop nk-user-menu">' +
                        '<div class="nk-menu-head"><span class="nk-avatar nk-avatar-lg">' + avatar + '<i></i></span><div><b>' + esc(nombre) + '</b><span>' + esc(window.nombreRol ? window.nombreRol(u.rol) : (admin ? 'Administrador' : 'Empleado')) + (u.email ? ' · ' + esc(u.email) : '') + '</span></div></div>' +
                        '<button type="button" data-nk="perfil"><span class="material-symbols-outlined">person</span>Mi perfil</button>' +
                        '<button type="button" data-nk-sub="tema"><span class="material-symbols-outlined">palette</span>Tema<span class="nk-menu-val">' + (tema === 'oscuro' ? 'Oscuro' : 'Claro') + '</span><span class="material-symbols-outlined nk-chev">expand_more</span></button>' +
                        '<div class="nk-submenu" data-sub="tema">' +
                            '<button type="button" data-tema="claro"' + (tema !== 'oscuro' ? ' class="on"' : '') + '><span class="material-symbols-outlined">light_mode</span>Claro</button>' +
                            '<button type="button" data-tema="oscuro"' + (tema === 'oscuro' ? ' class="on"' : '') + '><span class="material-symbols-outlined">dark_mode</span>Oscuro</button>' +
                        '</div>' +
                        (multiTienda ? '<button type="button" data-nk="tienda"><span class="material-symbols-outlined">domain</span>Cambiar tienda</button>' : '') +
                        (true ? '<button type="button" data-nk="config"><span class="material-symbols-outlined">settings</span>Configuración</button>' : '') +
                        '<div class="nk-pop-sep"></div>' +
                        '<button type="button" data-nk="salir"><span class="material-symbols-outlined">logout</span>Cerrar sesión</button>' +
                    '</div>' +
                '</div>' +
            '</div>';
        main.insertBefore(bar, main.firstChild);

        function cerrarTodo(salvo) { bar.querySelectorAll('[data-nk-box]').forEach(function (b) { if (b !== salvo) b.classList.remove('open'); }); }
        bar.querySelectorAll('[data-nk-open]').forEach(function (btn) {
            btn.addEventListener('click', function (e) {
                e.stopPropagation();
                var k = btn.dataset.nkOpen;
                if (k === 'suc') { if (multiTienda) abrirTiendas(); return; }
                var box = bar.querySelector('[data-nk-box="' + k + '"]');
                cerrarTodo(box);
                box.classList.toggle('open');
                if (k === 'tasa' && box.classList.contains('open')) abrirTasa();
            });
        });
        bar.querySelectorAll('.nk-pop').forEach(function (p) { p.addEventListener('click', function (e) { e.stopPropagation(); }); });
        document.addEventListener('click', function () { cerrarTodo(null); });
        document.addEventListener('keydown', function (e) { if (e.key === 'Escape') cerrarTodo(null); });

        bar.querySelector('[data-nk-sub="tema"]').addEventListener('click', function () { this.parentElement.querySelector('[data-sub="tema"]').classList.toggle('open'); this.classList.toggle('open'); });
        bar.querySelectorAll('[data-tema]').forEach(function (b) {
            b.addEventListener('click', function () {
                ponerTema(b.dataset.tema);
                bar.querySelectorAll('[data-tema]').forEach(function (x) { x.classList.toggle('on', x === b); });
                bar.querySelector('.nk-menu-val').textContent = b.dataset.tema === 'oscuro' ? 'Oscuro' : 'Claro';
            });
        });
        bar.querySelectorAll('[data-nk]').forEach(function (b) {
            b.addEventListener('click', function () {
                if (b.dataset.nk === 'salir') window.cerrarSesion();
                else if (b.dataset.nk === 'tienda') { cerrarTodo(null); abrirTiendas(); }
                else if (b.dataset.nk === 'perfil') location.href = 'perfil.html';
                else { var cp = window.configPaginasVisibles ? window.configPaginasVisibles() : []; var c = cp.find(function (x) { return x[0] === 'configuracion.html'; }) || cp[0]; location.href = c ? c[0] : 'perfil.html'; }
            });
        });
        if (editaTasa) prepararTasa(bar);
        cargarTasa();
        setTimeout(function () {
            if (pag === 'notificaciones.html' || !window.refNotificaciones) return;
            window.refNotificaciones().then(function (l) {
                var n = l.filter(function (x) { return !x.leida; }).length, b = document.getElementById('nk-bell-n');
                if (b && n) { b.hidden = false; b.textContent = n > 9 ? '9+' : n; }
            }).catch(function () {});
        }, 800);
    }

    // ---------- Tasa ----------
    var TASA = { actual: 0, bcv: 0 };
    function numTasa(t) {
        t = String(t == null ? '' : t).trim().replace(/\s/g, '');
        if (!t) return 0;
        var c = t.lastIndexOf(','), d = t.lastIndexOf('.');
        if (c > -1 && d > -1) t = c > d ? t.replace(/\./g, '').replace(',', '.') : t.replace(/,/g, '');
        else if (c > -1) t = t.replace(',', '.');
        var n = Number(t);
        return isFinite(n) ? n : 0;
    }
    function fmtFecha(iso) { try { var d = new Date(iso); return d.toLocaleDateString('es-VE', { day: '2-digit', month: '2-digit', year: 'numeric' }) + ' ' + d.toLocaleTimeString('es-VE', { hour: '2-digit', minute: '2-digit' }); } catch (e) { return ''; } }
    function pintarEq() {
        var inp = document.getElementById('nk-tasa-in'); if (!inp) return;
        var v = numTasa(inp.value) || TASA.actual;
        var eq = document.getElementById('nk-tasa-eq'); if (eq) eq.textContent = '1 USD = ' + fmtTasa(v) + ' VES';
    }
    function abrirTasa() {
        var inp = document.getElementById('nk-tasa-in');
        if (inp) { inp.value = TASA.actual ? Number(TASA.actual).toLocaleString('es-VE', { minimumFractionDigits: 2, maximumFractionDigits: 4 }) : ''; }
        pintarEq();
        if (typeof supabaseClient !== 'undefined') {
            supabaseClient.from('tasas_historial').select('*').order('created_at', { ascending: false }).limit(1).then(function (r) {
                var el = document.getElementById('nk-tasa-upd'); if (!el) return;
                var h = r && !r.error && r.data && r.data[0];
                el.textContent = h ? 'Última actualización: ' + fmtFecha(h.created_at) + (h.usuario_nombre ? ' por ' + h.usuario_nombre : '') : 'Última actualización: sin registro';
            });
        }
        if (!TASA.bcv) {
            fetch('/api/tasa-bcv').then(function (r) { return r.json(); }).then(function (d) {
                var b = document.getElementById('nk-bcv'), bt = document.getElementById('nk-usar-bcv');
                if (d && d.ok && d.tasa > 0) { TASA.bcv = Number(d.tasa); if (b) b.textContent = fmtTasa(TASA.bcv); if (bt) bt.disabled = false; }
                else if (b) b.textContent = 'no disponible';
            }).catch(function () { var b = document.getElementById('nk-bcv'); if (b) b.textContent = 'no disponible'; });
        }
    }
    function prepararTasa(bar) {
        var inp = bar.querySelector('#nk-tasa-in');
        inp.addEventListener('input', pintarEq);
        inp.addEventListener('keydown', function (e) { if (e.key === 'Enter') { e.preventDefault(); guardarTasa(); } });
        bar.querySelectorAll('[data-step]').forEach(function (b) {
            var timer = null;
            function paso() { var v = numTasa(inp.value) || TASA.actual || 0; v = Math.max(0.01, Math.round((v + Number(b.dataset.step) * 0.01) * 10000) / 10000); inp.value = v.toLocaleString('es-VE', { minimumFractionDigits: 2, maximumFractionDigits: 4 }); pintarEq(); }
            b.addEventListener('click', paso);
            b.addEventListener('pointerdown', function () { timer = setTimeout(function rep() { paso(); timer = setTimeout(rep, 60); }, 450); });
            ['pointerup', 'pointerleave', 'pointercancel'].forEach(function (ev) { b.addEventListener(ev, function () { clearTimeout(timer); }); });
        });
        var ub = bar.querySelector('#nk-usar-bcv');
        if (ub) ub.addEventListener('click', function () { if (TASA.bcv) { inp.value = TASA.bcv.toLocaleString('es-VE', { minimumFractionDigits: 2, maximumFractionDigits: 4 }); pintarEq(); } });
        bar.querySelector('#nk-tasa-ok').addEventListener('click', guardarTasa);
    }
    async function guardarTasa() {
        var inp = document.getElementById('nk-tasa-in'), btn = document.getElementById('nk-tasa-ok');
        var t = numTasa(inp && inp.value);
        if (!(t > 0)) { aviso('Escribe una tasa válida', 'warning'); return; }
        if (TASA.actual && Math.abs(t - TASA.actual) / TASA.actual > 0.25 && !await refConfirm('La tasa cambia más de 25% (de ' + fmtTasa(TASA.actual) + ' a ' + fmtTasa(t) + '). ¿Seguro?')) return;
        btn.disabled = true;
        supabaseClient.rpc('config_actualizar_tasa', { p_tasa: t }).then(function (r) {
            btn.disabled = false;
            if (r.error) { aviso('No se pudo guardar la tasa: ' + (r.error.message || ''), 'error'); return; }
            var u = window.getSesionUsuario && window.getSesionUsuario();
            supabaseClient.rpc('tasa_historial_firmar', { p_usuario: u ? u.nombre : '' }).then(function () {}, function () {});
            TASA.actual = t; ponerTasa(t);
            try { var cc = window.refCacheGet && window.refCacheGet('refrimar_cache_config'); if (cc) { cc.tasa_bcv_manual = t; window.refCacheSet('refrimar_cache_config', cc); } } catch (e) {}
            aviso('Tasa actualizada: ' + fmtTasa(t) + ' VES', 'success');
            var box = document.querySelector('[data-nk-box="tasa"]'); if (box) box.classList.remove('open');
            try { window.dispatchEvent(new CustomEvent('refrimar:tasa', { detail: { tasa: t } })); } catch (e) {}
        });
    }
    function aviso(msg, tipo) {
        if (typeof window.showToast === 'function') window.showToast(msg, tipo);
        else if (window.nk && nk.toast) nk.toast(msg, tipo);
        else alert(msg);
    }

    // ---------- Cambiar tienda (solo admin) ----------
    function abrirTiendas() {
        if (typeof supabaseClient === 'undefined') return;
        var actual = null; try { actual = JSON.parse(sessionStorage.getItem(window.REF_SUCURSAL_KEY) || 'null'); } catch (e) {}
        var casa = window.CASA_MATRIZ_ID || '00000000-0000-0000-0000-000000000001';
        supabaseClient.from('sucursales').select('id,nombre').order('nombre').then(function (r) {
            var lista = [{ id: casa, nombre: 'Casa Matriz' }].concat((r && r.data) || []);
            var yo = window.getSesionUsuario && window.getSesionUsuario();
            if (yo && yo.rol !== 'admin' && Array.isArray(yo.sucursales) && yo.sucursales.length) lista = lista.filter(function (s) { return yo.sucursales.indexOf(s.id) >= 0; });
            var ov = document.createElement('div');
            ov.className = 'nk-store-ov';
            ov.innerHTML = '<div class="nk-store-box"><div class="nk-pop-title">Cambiar tienda</div><div class="nk-pop-sub">Todo lo que hagas (ventas, stock, caja) quedará en la tienda que elijas.</div>' +
                lista.map(function (s) { var on = actual && actual.id === s.id; return '<button type="button" data-id="' + esc(s.id) + '" class="' + (on ? 'on' : '') + '"><span class="material-symbols-outlined">storefront</span>' + esc(s.nombre) + (on ? '<span class="nk-menu-val">Actual</span>' : '') + '</button>'; }).join('') +
                '<button type="button" class="nk-store-x">Cancelar</button></div>';
            document.body.appendChild(ov);
            function cerrar() { ov.remove(); }
            ov.addEventListener('click', function (e) { if (e.target === ov) cerrar(); });
            ov.querySelector('.nk-store-x').addEventListener('click', cerrar);
            ov.querySelectorAll('[data-id]').forEach(function (b) {
                b.addEventListener('click', function () {
                    var s = lista.find(function (x) { return x.id === b.dataset.id; });
                    if (!s) return;
                    window.guardarSucursalSesion({ id: s.id, nombre: s.nombre });
                    location.reload();
                });
            });
        });
    }

    function ponerTasa(v) { if (v) TASA.actual = Number(v); var el = document.getElementById('nk-tasa'); if (el && v) el.textContent = fmtTasa(v); }
    function cargarTasa() {
        try { var c = window.refCacheGet && window.refCacheGet('refrimar_cache_config'); if (c && c.tasa_bcv_manual) ponerTasa(c.tasa_bcv_manual); } catch (e) {}
        try {
            if (typeof supabaseClient === 'undefined') return;
            supabaseClient.from('configuracion').select('tasa_bcv_manual').limit(1).maybeSingle().then(function (r) {
                if (r && r.data && r.data.tasa_bcv_manual) { ponerTasa(r.data.tasa_bcv_manual); return; }
                // Sin tasa en configuración: usa la última registrada en el historial
                supabaseClient.from('tasas_historial').select('tasa').order('created_at', { ascending: false }).limit(1).then(function (h) {
                    var t = h && !h.error && h.data && h.data[0] && h.data[0].tasa;
                    if (t) ponerTasa(t); else { var el = document.getElementById('nk-tasa'); if (el) el.textContent = 'Sin tasa'; }
                });
            });
        } catch (e) {}
    }

    function aplicar() {
        if (!window.getSesionUsuario || !window.getSesionUsuario()) return;
        if (!document.getElementById('sidebar')) return; // login, portada: sin barra del sistema
        try { logo(); linkActivo(); tituloLimpio(); topbar(); configNav(); } catch (e) { console.warn('[nk]', e); }
    }
    aplicar();
    document.addEventListener('DOMContentLoaded', aplicar);
})();

// ============================================================
// NOTIFICACIONES / ÚLTIMOS MOVIMIENTOS (campana, Resumen general)
// Se arman con lo que pasó en los últimos días; cada usuario
// puede descartarlas (se guarda en este navegador).
// ============================================================
(function () {
    var K_OCULTAS = 'refrimar_notif_ocultas', K_VISTO = 'refrimar_notif_visto';
    function leer(k, d) { try { var v = JSON.parse(localStorage.getItem(k) || 'null'); return v == null ? d : v; } catch (e) { return d; } }
    function escribir(k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch (e) {} }
    var cache = null;
    function seguro(p) { return Promise.resolve(p).then(function (r) { return (r && !r.error && r.data) || []; }, function () { return []; }); }
    function fmtN(n) { return Number(n || 0).toLocaleString('es-VE', { maximumFractionDigits: 4 }); }

    window.refNotificaciones = function (forzar) {
        if (cache && !forzar) return cache;
        if (typeof supabaseClient === 'undefined' || !window.getSesionUsuario()) return Promise.resolve([]);
        var can = window.can || function () { return false; };
        var desde = new Date(Date.now() - 14 * 864e5).toISOString();
        var q = [];
        q.push(seguro(supabaseClient.from('tasas_historial').select('id,tasa,tasa_anterior,created_at,usuario_nombre').gte('created_at', desde).order('created_at', { ascending: false }).limit(10)).then(function (rows) {
            return rows.map(function (r) { return { id: 'tasa-' + r.id, icono: 'currency_exchange', titulo: 'Cambio de tasa', detalle: (r.tasa_anterior ? fmtN(r.tasa_anterior) + ' → ' : '') + fmtN(r.tasa) + ' VES' + (r.usuario_nombre ? ' · ' + r.usuario_nombre : ''), fecha: r.created_at, href: 'monedas.html' }; });
        }));
        if (can('ver_inventario')) q.push(seguro(supabaseClient.from('productos').select('codigo,descripcion,updated_at').gte('updated_at', desde).order('updated_at', { ascending: false }).limit(300)).then(function (rows) {
            var dias = {};
            rows.forEach(function (r) { var d = String(r.updated_at).slice(0, 10); (dias[d] = dias[d] || []).push(r); });
            return Object.keys(dias).map(function (d) {
                var l = dias[d];
                return { id: 'prod-' + d + '-' + l.length, icono: 'inventory_2', titulo: 'Cambio de producto', detalle: l.length === 1 ? l[0].descripcion : l.length + ' productos actualizados (' + l.slice(0, 2).map(function (x) { return x.descripcion; }).join(', ') + '…)', fecha: l[0].updated_at, href: l.length === 1 ? 'producto.html?codigo=' + encodeURIComponent(l[0].codigo) : 'productos.html' };
            });
        }));
        if (can('importar_productos')) q.push(seguro(supabaseClient.from('importaciones_productos').select('*').gte('created_at', desde).order('created_at', { ascending: false }).limit(10)).then(function (rows) {
            return rows.map(function (r) { return { id: 'imp-' + r.id, icono: 'upload_file', titulo: 'Importación de productos', detalle: (r.creados || 0) + ' creados · ' + (r.actualizados || 0) + ' actualizados' + (r.usuario_nombre ? ' · ' + r.usuario_nombre : ''), fecha: r.created_at, href: 'productos.html#historico' }; });
        }));
        if (can('ver_transferencias')) q.push(seguro(supabaseClient.from('transferencias').select('id,numero,estado,origen_nombre,destino_nombre,created_at,completada_at').gte('created_at', desde).order('created_at', { ascending: false }).limit(10)).then(function (rows) {
            return rows.map(function (r) { return { id: 'tr-' + r.id + '-' + r.estado, icono: 'sync_alt', titulo: r.estado === 'completada' ? 'Transferencia completada' : r.estado === 'cancelada' ? 'Transferencia cancelada' : 'Transferencia en borrador', detalle: r.numero + ' · ' + (r.origen_nombre || '') + ' → ' + (r.destino_nombre || ''), fecha: r.completada_at || r.created_at, href: 'transferencias.html' }; });
        }));
        if (can('contar_inventario')) q.push(seguro(supabaseClient.from('conteos').select('id,numero,nombre,estado,created_at,sucursal_nombre').gte('created_at', desde).order('created_at', { ascending: false }).limit(10)).then(function (rows) {
            return rows.map(function (r) { return { id: 'ct-' + r.id + '-' + r.estado, icono: 'fact_check', titulo: 'Conteo de inventario', detalle: (r.numero || '') + ' · ' + (r.nombre || '') + (r.sucursal_nombre ? ' · ' + r.sucursal_nombre : ''), fecha: r.created_at, href: 'conteos.html?abrir=' + r.id }; });
        }));
        if (can('ver_equipo')) q.push(seguro(supabaseClient.from('usuarios').select('id,nombre,aceptado_at').gte('aceptado_at', desde).order('aceptado_at', { ascending: false }).limit(10)).then(function (rows) {
            return rows.map(function (r) { return { id: 'eq-' + r.id, icono: 'person_add', titulo: 'Nuevo colaborador', detalle: r.nombre + ' aceptó la invitación', fecha: r.aceptado_at, href: 'colaborador-form.html?id=' + r.id }; });
        }));
        if (can('configuracion')) q.push(Promise.resolve(supabaseClient.rpc('sistema_diagnostico')).then(function (r) {
            var falta = !!(r && r.error && /Could not find the function|schema cache/i.test(r.error.message || ''));
            if (!falta && r && r.data) { var f = r.data.funciones || []; falta = ['pos_facturar', 'precios_actualizacion_crear', 'colaborador_guardar', 'turno_abrir', 'transferencia_guardar', 'oc_guardar', 'conteo_crear_lista'].some(function (n) { return f.indexOf(n) < 0; }); }
            return falta ? [{ id: 'sistema-sql-' + new Date().toISOString().slice(0, 10), icono: 'database', titulo: 'Actualiza la base de datos', detalle: 'Hay funciones nuevas sin instalar en Supabase. Toca aquí y sigue los 4 pasos.', fecha: new Date().toISOString(), href: 'sistema.html' }] : [];
        }, function () { return []; }));
        cache = Promise.all(q).then(function (grupos) {
            var ocultas = leer(K_OCULTAS, []), visto = leer(K_VISTO, '');
            var todo = [].concat.apply([], grupos).filter(function (n) { return n.fecha && ocultas.indexOf(n.id) < 0; });
            todo.sort(function (a, b) { return String(b.fecha).localeCompare(String(a.fecha)); });
            todo.forEach(function (n) { n.leida = !!visto && String(n.fecha) <= visto; });
            return todo.slice(0, 40);
        });
        return cache;
    };
    window.refNotifDescartar = function (id) {
        var o = leer(K_OCULTAS, []); if (o.indexOf(id) < 0) o.push(id); escribir(K_OCULTAS, o.slice(-400)); cache = null;
    };
    window.refNotifMarcarVistas = function () { escribir(K_VISTO, new Date().toISOString()); cache = null; var b = document.getElementById('nk-bell-n'); if (b) b.hidden = true; };
})();

// ============================================================
// ESTADOS ILUSTRADOS (mascota REFRIMAR): vacio, busqueda, error,
// exito, cargando, notificaciones, pagos  →  img/estados/<tipo>.svg
//   refEstado('busqueda', 'Sin resultados', 'Prueba con otra palabra', '<a ...>Acción</a>', 'sm')
// ============================================================
window.REF_ESTADOS = ['vacio', 'busqueda', 'error', 'exito', 'cargando', 'notificaciones', 'pagos'];
window.refEstado = function (tipo, titulo, texto, accion, tam) {
    if (window.REF_ESTADOS.indexOf(tipo) < 0) tipo = 'vacio';
    var e = function (x) { return String(x == null ? '' : x).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); };
    return '<div class="ref-estado' + (tam ? ' ref-estado-' + tam : '') + '" data-estado="' + tipo + '"><img src="img/estados/' + tipo + '.svg" alt="" draggable="false"/>' +
        (titulo ? '<b>' + e(titulo) + '</b>' : '') + (texto ? '<span>' + e(texto) + '</span>' : '') + (accion ? '<div class="ref-estado-acc">' + accion + '</div>' : '') + '</div>';
};

// Destello de éxito con la mascota (no bloquea: se va solo)
//   refExito('Venta guardada', 'F-000123')
window.refExito = function (titulo, texto, ms) {
    try {
        var old = document.getElementById('ref-exito'); if (old) old.remove();
        var d = document.createElement('div');
        d.id = 'ref-exito';
        d.setAttribute('role', 'status');
        d.style.cssText = 'position:fixed;inset:0;z-index:10050;display:flex;align-items:center;justify-content:center;pointer-events:none;background:rgba(15,23,42,.10);opacity:0;transition:opacity .2s';
        d.innerHTML = '<div style="background:#fff;border-radius:28px;padding:14px 26px 22px;text-align:center;box-shadow:0 20px 60px rgba(0,0,0,.18);transform:scale(.92);transition:transform .25s cubic-bezier(.2,1.4,.4,1);max-width:86vw">' +
            '<img src="img/estados/exito.svg" alt="" style="width:220px;max-width:70vw;height:auto;display:block;margin:0 auto"/>' +
            '<div style="font-family:Poppins,sans-serif;font-size:20px;font-weight:800;letter-spacing:-.02em;color:#0B1220">' + String(titulo || '¡Listo!').replace(/</g, '&lt;') + '</div>' +
            (texto ? '<div style="font-size:14px;color:#52525B;margin-top:2px">' + String(texto).replace(/</g, '&lt;') + '</div>' : '') + '</div>';
        document.body.appendChild(d);
        requestAnimationFrame(function () { d.style.opacity = '1'; d.firstChild.style.transform = 'scale(1)'; });
        setTimeout(function () { d.style.opacity = '0'; setTimeout(function () { d.remove(); }, 250); }, ms || 1500);
    } catch (e) {}
};

// ============================================================
// AVISOS PROPIOS (reemplazan confirm/prompt del navegador, que salen
// con el color del tema de Chrome). Devuelven una promesa.
//   if (!(await refConfirm('¿Eliminar?'))) return;
//   var sn = await refPrompt('Número de serie', '');
// ============================================================
(function () {
    function css() {
        if (document.getElementById('ref-dlg-css')) return;
        var st = document.createElement('style'); st.id = 'ref-dlg-css';
        st.textContent = '.ref-dlg-ov{position:fixed;inset:0;z-index:10060;background:rgba(15,23,42,.38);display:flex;align-items:center;justify-content:center;padding:16px;animation:refDlgF .15s ease-out}' +
            '.ref-dlg{background:#fff;border-radius:24px;width:100%;max-width:420px;padding:22px 22px 18px;box-shadow:0 24px 70px rgba(0,0,0,.25);animation:refDlgI .18s cubic-bezier(.2,1.2,.4,1);font-family:Roboto,Arial,sans-serif}' +
            '.ref-dlg-h{display:flex;align-items:center;gap:10px;margin-bottom:8px}.ref-dlg-ic{width:38px;height:38px;border-radius:999px;display:inline-flex;align-items:center;justify-content:center;flex:none;font-size:20px;font-weight:700}' +
            '.ref-dlg-t{font-family:Poppins,Roboto,sans-serif;font-size:18px;font-weight:700;letter-spacing:-.015em;color:#0B1220}.ref-dlg-m{font-size:14px;line-height:1.5;color:#3F3F46;white-space:pre-line;margin:2px 0 4px}' +
            '.ref-dlg-in{width:100%;height:42px;border:1px solid #E4E4E7;border-radius:999px;padding:0 16px;font-size:15px;margin-top:10px;outline:none}.ref-dlg-in:focus{border-color:#0A2540;box-shadow:0 0 0 3px rgba(0,170,255,.18)}' +
            '.ref-dlg-b{display:flex;gap:10px;justify-content:flex-end;margin-top:18px}.ref-dlg-b button{height:40px;padding:0 20px;border-radius:999px;font-family:Poppins,Roboto,sans-serif;font-size:14px;font-weight:600;cursor:pointer;border:1px solid #00AAFF;transition:background .15s}.ref-dlg-b button:focus-visible{outline:2px solid #0A2540;outline-offset:2px}.ref-dlg-b button:focus:not(:focus-visible){outline:none}' +
            '.ref-dlg-no{background:#fff;color:#0A2540;border-color:#0A2540!important}.ref-dlg-no:hover{background:#E6F6FF}.ref-dlg-si{background:#00AAFF;color:#0A2540}.ref-dlg-si:hover{background:#33BBFF;border-color:#33BBFF}.ref-dlg-si.rojo{background:#C62828;border-color:#C62828;color:#fff}.ref-dlg-si.rojo:hover{background:#B71C1C}' +
            '@keyframes refDlgF{from{opacity:0}}@keyframes refDlgI{from{opacity:0;transform:translateY(8px) scale(.97)}}';
        document.head.appendChild(st);
    }
    function abrir(msg, opts, conInput) {
        opts = opts || {};
        css();
        return new Promise(function (resolve) {
            var peligro = opts.peligro != null ? opts.peligro : /eliminar|anular|cancelar|quitar|reemplaz|borrar|descartar|limpiar/i.test(msg);
            var e = function (x) { return String(x == null ? '' : x).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); };
            var ov = document.createElement('div'); ov.className = 'ref-dlg-ov';
            ov.innerHTML = '<div class="ref-dlg" role="dialog" aria-modal="true"><div class="ref-dlg-h"><span class="ref-dlg-ic" style="background:' + (peligro ? '#FEE2E2;color:#C62828' : '#E6F6FF;color:#0A2540') + '">' + (peligro ? '!' : '?') + '</span>' +
                '<span class="ref-dlg-t">' + e(opts.titulo || (conInput ? 'Escribe el dato' : peligro ? '¿Estás seguro?' : 'Confirmar')) + '</span></div>' +
                '<div class="ref-dlg-m">' + e(msg) + '</div>' + (conInput ? '<input class="ref-dlg-in" value="' + e(opts.valor || '') + '" placeholder="' + e(opts.placeholder || '') + '"/>' : '') +
                '<div class="ref-dlg-b">' + (opts.soloOk ? '' : '<button type="button" class="ref-dlg-no">' + e(opts.no || 'Cancelar') + '</button>') + '<button type="button" class="ref-dlg-si' + (peligro && !conInput ? ' rojo' : '') + '">' + e(opts.si || 'Aceptar') + '</button></div></div>';
            document.body.appendChild(ov);
            var inp = ov.querySelector('.ref-dlg-in');
            function fin(v) { document.removeEventListener('keydown', tecla, true); if (!conInput && window.__refSetConfirm) window.__refSetConfirm(v); ov.remove(); resolve(v); }
            function ok() { fin(conInput ? inp.value : true); }
            function no() { fin(conInput ? null : false); }
            function tecla(ev) { if (ev.key === 'Escape') { ev.preventDefault(); ev.stopPropagation(); no(); } else if (ev.key === 'Enter') { ev.preventDefault(); ev.stopPropagation(); ok(); } }
            document.addEventListener('keydown', tecla, true);
            ov.querySelector('.ref-dlg-si').addEventListener('click', ok);
            var bn = ov.querySelector('.ref-dlg-no'); if (bn) bn.addEventListener('click', no);
            ov.addEventListener('mousedown', function (ev) { if (ev.target === ov) no(); });
            setTimeout(function () { (inp || ov.querySelector('.ref-dlg-si')).focus(); if (inp) inp.select(); }, 30);
        });
    }
    window.refConfirm = function (msg, opts) { return abrir(msg, opts, false); };
    window.refPrompt = function (msg, valor, opts) { return abrir(msg, Object.assign({ valor: valor }, opts || {}), true); };
    window.refAviso = function (msg, opts) { return abrir(msg, Object.assign({ soloOk: true, peligro: false, titulo: 'Aviso' }, opts || {}), false); };
})();

// Actualizaciones de precio programadas: se aplican solas al llegar la hora (revisa cada 5 min al abrir páginas)
(function () {
    try {
        if (!window.getSesionUsuario() || typeof supabaseClient === 'undefined') return;
        var k = 'refrimar_prog_check', ult = Number(localStorage.getItem(k) || 0);
        if (Date.now() - ult < 5 * 60 * 1000) return;
        localStorage.setItem(k, String(Date.now()));
        setTimeout(function () { supabaseClient.rpc('precios_programados_aplicar').then(function (r) { if (r && r.data && r.data.aplicadas && window.showToast) window.showToast(r.data.aplicadas + ' actualización(es) de precios programada(s) aplicada(s)', 'info'); }, function () {}); }, 2500);
    } catch (e) {}
})();

// Estilo único de botones: los textos que vienen en MAYÚSCULAS se muestran en tipo oración
// ("REGISTRAR MOVIMIENTO" → "Registrar movimiento"), respetando siglas (BCV, IVA, POS…). Solo apariencia.
(function () {
    var SIGLAS = /^(BCV|IVA|IGTF|POS|USD|VES|BS|RIF|CSV|PDF|PIN|IA|OK|QR|SKU|CXC|CXP|ID|NC|F\d{1,2}|PNP|HKA|USB|SQL|C\.A\.?|J|V|E|G|\$)$/;
    var SEL = 'button, a.btn, a.nk-btn, a[class*="bg-primary"], a.rounded-lg.border, [role=button], .nk-tab, .cd-tab';
    function oracion(t) {
        var primero = true;
        return t.replace(/[A-Za-zÁÉÍÓÚÜÑáéíóúüñ.$\d]+/g, function (w) {
            var limpio = w.replace(/[.:,]+$/, '');
            if (SIGLAS.test(limpio.toUpperCase()) && limpio === limpio.toUpperCase() && !(primero && limpio.length > 3)) { primero = false; return w; }
            var r = w.toLowerCase();
            if (primero && /[a-záéíóúüñ]/.test(r)) { r = r.charAt(0).toUpperCase() + r.slice(1); primero = false; }
            return r;
        });
    }
    function arreglar(el) {
        if (!el || el.closest('.material-symbols-outlined')) return;
        var w = document.createTreeWalker(el, NodeFilter.SHOW_TEXT, null), n, nodos = [];
        while ((n = w.nextNode())) nodos.push(n);
        nodos.forEach(function (tn) {
            var p = tn.parentElement; if (!p || p.closest('.material-symbols-outlined, .material-symbols-rounded, kbd, code')) return;
            var t = tn.nodeValue, letras = t.replace(/[^A-Za-zÁÉÍÓÚÜÑáéíóúüñ]/g, '');
            if (letras.length < 3 || letras !== letras.toUpperCase()) return;
            var nuevo = oracion(t); if (nuevo !== t) tn.nodeValue = nuevo;
        });
    }
    function barrer(raiz) { (raiz.querySelectorAll ? raiz : document).querySelectorAll(SEL).forEach(arreglar); if (raiz.matches && raiz.matches(SEL)) arreglar(raiz); }
    function iniciar() {
        barrer(document);
        if (!('MutationObserver' in window)) return;
        var pend = [], t = 0;
        new MutationObserver(function (ms) {
            ms.forEach(function (m) { m.addedNodes.forEach(function (x) { if (x.nodeType === 1) pend.push(x); else if (x.nodeType === 3 && x.parentElement) pend.push(x.parentElement.closest(SEL) || x.parentElement); }); if (m.type === 'characterData' && m.target.parentElement) pend.push(m.target.parentElement.closest(SEL)); });
            if (!t) t = requestAnimationFrame(function () { t = 0; var l = pend; pend = []; l.forEach(function (x) { if (x && x.isConnected) { var b = x.closest && x.closest(SEL); if (b) arreglar(b); else barrer(x); } }); });
        }).observe(document.body, { childList: true, subtree: true, characterData: true });
    }
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', iniciar); else iniciar();
})();
