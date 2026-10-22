/* REFRIMAR · Plantillas de Excel profesionales (importar y exportar con el MISMO formato).
 * - Hoja de datos con encabezados de colores (obligatorios en azul marino), ancho correcto,
 *   códigos como TEXTO (Excel no los convierte en 7,59E+12) y listas desplegables.
 * - Hoja "Instrucciones" (qué poner en cada columna) y hoja "Listas" (valores válidos).
 * Usa ExcelJS (se carga solo cuando se necesita). Requiere js/rubros.js para las de productos.
 *
 * RefPlantillas.descargar(tipo, { rubro, sucursales:[nombres], categorias:[...] })
 * RefPlantillas.exportar(tipo, filas, { rubro, columnas:[k], formato:'xlsx'|'csv', nombre, extra:{h,k} })
 * RefPlantillas.columnas(tipo, rubro) → [{k,h,req,...}]
 */
(function () {
    'use strict';
    var NAVY = 'FF0A2540', CELESTE = 'FF00AAFF', WASH = 'FFE6F6FF', ROJO = 'FFFEE2E2';

    var LISTAS = {
        tipo: ['Venta por unidad', 'Venta por metro', 'Venta por kilo', 'Venta por rollo', 'Servicio'],
        iva: ['16', '8', 'Exento', '31'],
        sino: ['Sí', 'No'],
        origen: ['Nacional', 'Importado'],
        tipodoc: ['V', 'E', 'J', 'G', 'P'],
        tipocli: ['final', 'mayorista', 'empresa'],
        estadocxp: ['Pendiente', 'Pagada']
    };

    // ---- Columnas de cada plantilla ----
    function colsProductos(rubro) {
        var base = [
            { k: 'nombre', h: 'Nombre', req: true, ancho: 42, ayuda: 'Nombre del producto tal como sale en la factura.' },
            { k: 'barra', h: 'Barra', req: true, ancho: 18, texto: true, ayuda: 'Código de barras o código con el que se vende. Los internos empiezan por 299.' },
            { k: 'barra2', h: 'Barra adicional', ancho: 18, texto: true, ayuda: 'Otro código que también encuentra el producto en el POS.' },
            { k: 'sku', h: 'SKU', ancho: 14, texto: true },
            { k: 'tipo', h: 'Tipo producto', ancho: 18, lista: 'tipo', ayuda: 'Venta por unidad, por metro, por kilo, por rollo o servicio. Cada forma de venta va en su propia fila con su propio código.' },
            { k: 'categoria', h: 'Categoría', ancho: 20, lista: 'categoria', ayuda: 'Elige de la lista o escribe una nueva.' },
            { k: 'subcategoria', h: 'Subcategoría', ancho: 18 },
            { k: 'marca', h: 'Marca', ancho: 16, ayuda: 'Si la dejas vacía queda "Genérico".' },
            { k: 'refint', h: 'Referencia interna', ancho: 16, texto: true },
            { k: 'costo', h: 'Costo', ancho: 11, num: '0.00', ayuda: 'Costo unitario en dólares (o en Bs si lo eliges al importar).' },
            { k: 'precio', h: 'PVP', ancho: 11, num: '0.00', ayuda: 'Precio de venta unitario.' },
            { k: 'stock', h: 'Inventario actual', ancho: 12, num: '0.###' },
            { k: 'min', h: 'Inventario mínimo', ancho: 12, num: '0.###' },
            { k: 'max', h: 'Inventario máximo', ancho: 12, num: '0.###' },
            { k: 'iva', h: 'IVA', ancho: 9, lista: 'iva', ayuda: '16 general · 8 reducido · Exento · 31 lujo.' },
            { k: 'pesable', h: 'Pesable', ancho: 9, lista: 'sino' },
            { k: 'balanza', h: 'Código balanza', ancho: 12, texto: true },
            { k: 'proveedor', h: 'Proveedor', ancho: 20, ayuda: 'Nombre o RIF del proveedor ya registrado.' },
            { k: 'origen', h: 'Origen', ancho: 11, lista: 'origen' },
            { k: 'present', h: 'Presentación', ancho: 14 },
            { k: 'reffab', h: 'Referencia de fábrica', ancho: 18, texto: true },
            { k: 'detalle', h: 'Descripción', ancho: 30 }
        ];
        var R = window.RefRubro ? window.RefRubro.get(rubro) : null;
        (R ? R.campos : []).forEach(function (c) {
            base.push({ k: 'attr:' + c.k, h: c.label, ancho: Math.max(12, Math.min(26, c.label.length + 4)), texto: c.tipo === 'texto', fecha: c.tipo === 'fecha',
                num: c.tipo === 'numero' ? '0.##' : null, lista: c.tipo === 'lista' ? 'attr:' + c.k : c.tipo === 'si_no' ? 'sino' : null, opciones: c.opciones, ayuda: c.ayuda || '' });
        });
        return base;
    }
    // Inventario inicial: columnas según el rubro (lote y vencimiento, serial/IMEI, ubicación)
    function colsInventario(rubro) {
        var R = window.RefRubro ? window.RefRubro.get(rubro) : null, ks = (R ? R.campos : []).map(function (c) { return c.k; });
        var c = [{ k: 'barra', h: 'Barra', req: true, ancho: 18, texto: true }, { k: 'nombre', h: 'Nombre', ancho: 40, ayuda: 'Solo de referencia; no cambia el nombre.' },
            { k: 'stock', h: 'Inventario actual', req: true, ancho: 14, num: '0.###' }, { k: 'costo', h: 'Costo', ancho: 11, num: '0.00', ayuda: 'Opcional: actualiza el costo.' }];
        if (ks.indexOf('lote') >= 0 || ks.indexOf('vencimiento') >= 0) {
            c.push({ k: 'lote', h: 'Lote', ancho: 14, texto: true, ayuda: 'Una fila por lote del mismo producto.' });
            c.push({ k: 'vence', h: 'Vencimiento', ancho: 14, fecha: true, ayuda: 'Fecha de vencimiento del lote (AAAA-MM-DD).' });
        }
        if (ks.indexOf('imei') >= 0 || (R && R.requiereSerial)) c.push({ k: 'serial', h: 'Serial / IMEI', ancho: 20, texto: true, ayuda: 'Una fila por equipo; la cantidad es 1.' });
        return c;
    }
    var TIPOS = {
        productos: { titulo: 'Productos', hoja: 'Productos', cols: colsProductos,
            pasos: ['Llena una fila por producto. Nombre y Barra son obligatorios.', 'Si un producto se vende por metro y también por rollo, son dos filas con códigos distintos.', 'Guarda el archivo y súbelo en Productos → Importar.'] },
        inventario: { titulo: 'Inventario inicial por tienda', hoja: 'Inventario', cols: colsInventario,
            pasos: ['Una fila por producto que YA existe en el sistema.', 'Al importar elige la tienda: el número reemplaza el inventario de esa tienda.',
                'Si tu negocio maneja lotes: una fila por lote con su vencimiento y su cantidad. El inventario del producto es la suma de sus lotes.',
                'Si maneja seriales o IMEI: una fila por equipo con su serial (cantidad 1).'] },
        precios: { titulo: 'Actualización masiva de precios', hoja: 'Precios', cols: function () { return [
            { k: 'barra', h: 'Barra', req: true, ancho: 18, texto: true }, { k: 'nombre', h: 'Nombre', ancho: 40, ayuda: 'Solo de referencia.' },
            { k: 'costo', h: 'Costo', ancho: 11, num: '0.00' }, { k: 'precio', h: 'PVP', req: true, ancho: 11, num: '0.00' }]; },
            pasos: ['Exporta tus productos, cambia el PVP y vuelve a subirlo.', 'No toca el inventario.'] },
        conteo: { titulo: 'Conteo físico', hoja: 'Conteo', cols: function () { return [
            { k: 'barra', h: 'Barra', req: true, ancho: 18, texto: true }, { k: 'nombre', h: 'Nombre', ancho: 40 },
            { k: 'ubicacion', h: 'Ubicación', ancho: 14 }, { k: 'stock', h: 'Inventario actual', req: true, ancho: 14, num: '0.###', ayuda: 'Lo que contaste.' }]; },
            pasos: ['Cuenta y anota la cantidad real.', 'Al importar, la cantidad contada reemplaza el inventario de la tienda y queda en el kardex.'] },
        clientes: { titulo: 'Clientes', hoja: 'Clientes', cols: function () { return [
            { k: 'rif', h: 'Cédula o RIF', req: true, ancho: 16, texto: true, ayuda: 'Ej. V-12345678 o J-50357586-7' },
            { k: 'nombre', h: 'Nombre o razón social', req: true, ancho: 36 }, { k: 'telefono', h: 'Teléfono', ancho: 16, texto: true },
            { k: 'email', h: 'Correo', ancho: 26 }, { k: 'direccion', h: 'Dirección', ancho: 36 },
            { k: 'tipo', h: 'Tipo de cliente', ancho: 14, lista: 'tipocli' }, { k: 'limite', h: 'Límite de crédito', ancho: 14, num: '0.00' }, { k: 'notas', h: 'Notas', ancho: 26 }]; },
            pasos: ['Si la cédula o RIF ya existe, el cliente se actualiza.'] },
        proveedores: { titulo: 'Proveedores', hoja: 'Proveedores', cols: function () { return [
            { k: 'rif', h: 'RIF', req: true, ancho: 16, texto: true }, { k: 'nombre', h: 'Nombre', req: true, ancho: 36 },
            { k: 'telefono', h: 'Teléfono', ancho: 16, texto: true }, { k: 'email', h: 'Correo', ancho: 26 }, { k: 'direccion', h: 'Dirección', ancho: 36 }]; },
            pasos: ['Si el RIF ya existe, el proveedor se actualiza.'] },
        cxc: { titulo: 'Cuentas por cobrar iniciales', hoja: 'CxC', cols: function () { return [
            { k: 'rif', h: 'Cédula o RIF', req: true, ancho: 16, texto: true }, { k: 'nombre', h: 'Cliente', req: true, ancho: 32 },
            { k: 'numero', h: 'N.º documento', req: true, ancho: 14, texto: true }, { k: 'monto', h: 'Monto USD', req: true, ancho: 12, num: '0.00', ayuda: 'Lo que el cliente debe hoy.' },
            { k: 'dias', h: 'Días de crédito', ancho: 12, num: '0' }, { k: 'notas', h: 'Notas', ancho: 26 }]; },
            pasos: ['Una fila por factura pendiente. Si el cliente no existe, se crea.'] },
        cxp: { titulo: 'Cuentas por pagar iniciales', hoja: 'CxP', cols: function () { return [
            { k: 'Numero_Factura', h: 'Numero_Factura', req: true, ancho: 16, texto: true }, { k: 'Proveedor', h: 'Proveedor', req: true, ancho: 30 },
            { k: 'RIF', h: 'RIF', ancho: 16, texto: true }, { k: 'Fecha_Emision', h: 'Fecha_Emision', ancho: 14, fecha: true }, { k: 'Fecha_Vencimiento', h: 'Fecha_Vencimiento', ancho: 16, fecha: true },
            { k: 'Monto_USD', h: 'Monto_USD', req: true, ancho: 12, num: '0.00' }, { k: 'Monto_BS', h: 'Monto_BS', ancho: 14, num: '0.00' },
            { k: 'Saldo_Pendiente', h: 'Saldo_Pendiente', ancho: 14, num: '0.00' }, { k: 'Estado', h: 'Estado', ancho: 12, lista: 'estadocxp' }, { k: 'Notas', h: 'Notas', ancho: 26 }]; },
            pasos: ['Se sube en Finanzas → Cuentas por pagar → Importar datos anteriores.', 'Las fechas van como AAAA-MM-DD.'] }
    };

    function ejemplos(tipo, rubro) {
        var R = window.RefRubro ? window.RefRubro.get(rubro) : null;
        var ej = (R && R.ejemplos) || [];
        if (tipo === 'productos') return ej.map(function (e) {
            var o = { nombre: e.nombre, barra: e.barra, tipo: e.tipo, categoria: e.categoria, subcategoria: e.subcategoria || '', marca: e.marca, costo: e.costo, precio: e.precio, stock: e.stock, min: e.min,
                iva: e.iva === 0 ? 'Exento' : String(e.iva), pesable: e.pesable || (e.tipo === 'Venta por kilo' ? 'Sí' : 'No'), balanza: e.balanza || '', origen: 'Nacional' };
            Object.keys(e.attr || {}).forEach(function (k) { o['attr:' + k] = e.attr[k]; });
            return o;
        });
        if (tipo === 'inventario' || tipo === 'conteo') {
            var filas = [];
            ej.filter(function (e) { return e.tipo !== 'Servicio'; }).slice(0, 3).forEach(function (e) {
                var a = e.attr || {};
                if (tipo === 'inventario' && R && R.requiereSerial) {
                    filas.push({ barra: e.barra, nombre: e.nombre, stock: 1, costo: e.costo, serial: '356789100000011' }, { barra: e.barra, nombre: e.nombre, stock: 1, costo: e.costo, serial: '356789100000029' });
                } else if (tipo === 'inventario' && (a.lote || a.vencimiento)) {
                    // Dos lotes del mismo producto: el inventario es la suma
                    var mitad = Math.max(1, Math.floor((Number(e.stock) || 2) / 2));
                    filas.push({ barra: e.barra, nombre: e.nombre, stock: mitad, costo: e.costo, lote: a.lote || 'L-001', vence: a.vencimiento || '' },
                               { barra: e.barra, nombre: e.nombre, stock: Math.max(0, (Number(e.stock) || 0) - mitad), costo: e.costo, lote: (a.lote || 'L-001') + 'B', vence: a.vencimiento || '' });
                } else filas.push({ barra: e.barra, nombre: e.nombre, stock: e.stock, costo: e.costo, ubicacion: a.ubicacion || '' });
            });
            return filas;
        }
        if (tipo === 'precios') return ej.slice(0, 3).map(function (e) { return { barra: e.barra, nombre: e.nombre, costo: e.costo, precio: e.precio }; });
        if (tipo === 'clientes') return [{ rif: 'V-12345678', nombre: 'PEDRO PÉREZ', telefono: '0412-0000000', email: 'pedro@correo.com', direccion: 'Caracas', tipo: 'final', limite: 0 }, { rif: 'J-00000000-0', nombre: 'CONSTRUCTORA EJEMPLO, C.A.', telefono: '0212-0000000', tipo: 'empresa', limite: 500 }];
        if (tipo === 'proveedores') return [{ rif: 'J-00000000-0', nombre: 'DISTRIBUIDORA EJEMPLO, C.A.', telefono: '0212-0000000', email: 'ventas@ejemplo.com', direccion: 'Caracas' }];
        if (tipo === 'cxc') return [{ rif: 'V-12345678', nombre: 'PEDRO PÉREZ', numero: 'A-0001', monto: 45.5, dias: 15, notas: 'Saldo del sistema anterior' }];
        if (tipo === 'cxp') return [{ Numero_Factura: '001-323-26', Proveedor: 'DISTRIBUIDORA EJEMPLO', RIF: 'J-00000000-0', Fecha_Emision: '2026-10-01', Fecha_Vencimiento: '2026-10-31', Monto_USD: 54, Saldo_Pendiente: 54, Estado: 'Pendiente' }];
        return [];
    }

    function cargarExcelJS() {
        if (window.ExcelJS) return Promise.resolve(window.ExcelJS);
        function una(src) {
            return new Promise(function (ok, mal) {
                var s = document.createElement('script'); s.src = src; s.async = true;
                s.onload = function () { window.ExcelJS ? ok(window.ExcelJS) : mal(new Error('ExcelJS no cargó')); };
                s.onerror = function () { mal(new Error('No se pudo descargar ExcelJS')); };
                document.head.appendChild(s);
            });
        }
        return una('https://cdnjs.cloudflare.com/ajax/libs/exceljs/4.4.0/exceljs.min.js').catch(function () { return una('https://cdn.jsdelivr.net/npm/exceljs@4.4.0/dist/exceljs.min.js'); });
    }
    function colLetra(n) { var s = ''; n++; while (n > 0) { var m = (n - 1) % 26; s = String.fromCharCode(65 + m) + s; n = Math.floor((n - 1) / 26); } return s; }
    function bajar(blob, nombre) { var a = document.createElement('a'); a.href = URL.createObjectURL(blob); a.download = nombre; document.body.appendChild(a); a.click(); setTimeout(function () { URL.revokeObjectURL(a.href); a.remove(); }, 1500); }
    function hoyISO() { var d = new Date(); return d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' + String(d.getDate()).padStart(2, '0'); }

    function columnas(tipo, rubro) { var T = TIPOS[tipo]; if (!T) throw new Error('Plantilla desconocida: ' + tipo); return T.cols(rubro || (window.RefRubro ? window.RefRubro.actualId() : 'ferreteria')); }

    // Construye el libro: datos + Instrucciones + Listas
    async function libro(tipo, filas, op) {
        op = op || {};
        var X = await cargarExcelJS();
        var T = TIPOS[tipo], rubro = op.rubro || (window.RefRubro ? window.RefRubro.actualId() : 'ferreteria');
        var cols = columnas(tipo, rubro);
        if (op.columnas && op.columnas.length) cols = cols.filter(function (c) { return c.req || op.columnas.indexOf(c.k) >= 0; });
        if (op.extra) cols = cols.concat(op.extra);
        var wb = new X.Workbook(); wb.creator = 'REFRIMAR'; wb.created = new Date();
        var ws = wb.addWorksheet(T.hoja, { views: [{ state: 'frozen', ySplit: 1 }], properties: { tabColor: { argb: CELESTE } } });
        var guia = wb.addWorksheet('Instrucciones', { properties: { tabColor: { argb: NAVY } } });
        var listas = wb.addWorksheet('Listas');

        // ---- Listas ----
        var R = window.RefRubro ? window.RefRubro.get(rubro) : null;
        var L = Object.assign({}, LISTAS);
        var cats = (op.categorias && op.categorias.length ? op.categorias : (R ? Object.keys(R.categorias || {}) : [])).slice(0, 300);
        L.categoria = cats.length ? cats : ['GENERAL'];
        if (op.sucursales && op.sucursales.length) L.sucursal = op.sucursales;
        cols.forEach(function (c) { if (c.opciones) L[c.lista] = c.opciones; });
        var rangoLista = {}, li = 0;
        Object.keys(L).forEach(function (nombre) {
            var usada = cols.some(function (c) { return c.lista === nombre; });
            if (!usada) return;
            var letra = colLetra(li++);
            listas.getCell(letra + '1').value = nombre.replace(/^attr:/, '');
            listas.getCell(letra + '1').font = { bold: true, color: { argb: 'FFFFFFFF' } };
            listas.getCell(letra + '1').fill = { type: 'pattern', pattern: 'solid', fgColor: { argb: NAVY } };
            L[nombre].forEach(function (v, i) { listas.getCell(letra + (i + 2)).value = v; });
            listas.getColumn(letra).width = 24;
            rangoLista[nombre] = 'Listas!$' + letra + '$2:$' + letra + '$' + (L[nombre].length + 1);
        });

        // ---- Hoja de datos ----
        ws.columns = cols.map(function (c) { return { header: c.h, key: c.k, width: c.ancho || 14 }; });
        var head = ws.getRow(1); head.height = 30;
        cols.forEach(function (c, i) {
            var cell = head.getCell(i + 1);
            var esExtra = op.extra && op.extra.some(function (x) { return x.k === c.k; });
            cell.font = { bold: true, color: { argb: esExtra ? 'FF7F1D1D' : c.req ? 'FFFFFFFF' : 'FF0A2540' }, name: 'Calibri', size: 11 };
            cell.fill = { type: 'pattern', pattern: 'solid', fgColor: { argb: esExtra ? ROJO : c.req ? NAVY : WASH } };
            cell.alignment = { vertical: 'middle', horizontal: 'center', wrapText: true };
            cell.border = { bottom: { style: 'medium', color: { argb: CELESTE } } };
            if (c.ayuda || c.req) cell.note = (c.req ? 'OBLIGATORIO. ' : '') + (c.ayuda || '');
            var col = ws.getColumn(i + 1);
            if (c.texto || c.fecha) col.numFmt = '@';
            else if (c.num) col.numFmt = c.num;
        });
        (filas || []).forEach(function (f) {
            var fila = {};
            cols.forEach(function (c) {
                var v = f[c.k];
                if (v === undefined || v === null) v = '';
                if ((c.texto || c.fecha) && v !== '') v = String(v);
                else if (c.num && v !== '' && !isNaN(Number(v))) v = Number(v);
                fila[c.k] = v;
            });
            ws.addRow(fila);
        });
        var ultima = Math.max(2000, (filas || []).length + 500);
        cols.forEach(function (c, i) {
            var letra = colLetra(i);
            var rango = letra + '2:' + letra + ultima;
            if (c.lista && rangoLista[c.lista]) {
                ws.dataValidations.add(rango, { type: 'list', allowBlank: !c.req, formulae: [rangoLista[c.lista]], showErrorMessage: c.lista !== 'categoria',
                    errorStyle: 'warning', errorTitle: 'Valor no válido', error: 'Elige un valor de la lista.' });
            } else if (c.num) {
                ws.dataValidations.add(rango, { type: 'decimal', operator: 'greaterThanOrEqual', allowBlank: true, formulae: [0], showErrorMessage: true, errorTitle: 'Número no válido', error: 'Escribe un número igual o mayor que cero (sin letras).' });
            }
        });
        ws.autoFilter = { from: 'A1', to: colLetra(cols.length - 1) + '1' };

        // ---- Instrucciones ----
        guia.columns = [{ width: 26 }, { width: 14 }, { width: 70 }, { width: 26 }];
        guia.getCell('A1').value = 'REFRIMAR · Plantilla de ' + T.titulo + (tipo === 'productos' && R ? ' (' + R.label + ')' : '');
        guia.getCell('A1').font = { bold: true, size: 16, color: { argb: NAVY } };
        guia.mergeCells('A1:D1');
        var r = 3;
        (T.pasos || []).concat(tipo === 'productos' && R && R.notas ? R.notas : []).concat(['Columnas en azul marino = obligatorias. En celeste claro = opcionales.', 'No cambies los títulos de la primera fila: así el sistema reconoce cada columna.', 'Los códigos de barra se guardan como texto (no se convierten en 7,59E+12).']).forEach(function (p, i) {
            guia.getCell('A' + r).value = (i + 1) + '.'; guia.getCell('B' + r).value = ''; guia.getCell('C' + r).value = p; guia.getCell('C' + r).alignment = { wrapText: true }; r++;
        });
        r++;
        ['Columna', 'Obligatoria', 'Qué poner', 'Valores válidos'].forEach(function (h, i) {
            var c = guia.getCell(colLetra(i) + r); c.value = h; c.font = { bold: true, color: { argb: 'FFFFFFFF' } }; c.fill = { type: 'pattern', pattern: 'solid', fgColor: { argb: NAVY } };
        });
        r++;
        cols.forEach(function (c) {
            guia.getCell('A' + r).value = c.h;
            guia.getCell('B' + r).value = c.req ? 'Sí' : 'No';
            guia.getCell('C' + r).value = c.ayuda || (c.num ? 'Número (usa coma o punto para decimales).' : c.fecha ? 'Fecha AAAA-MM-DD.' : '');
            guia.getCell('C' + r).alignment = { wrapText: true };
            guia.getCell('D' + r).value = c.lista && L[c.lista] ? L[c.lista].slice(0, 8).join(', ') + (L[c.lista].length > 8 ? '…' : '') : '';
            if (c.req) guia.getCell('B' + r).font = { bold: true, color: { argb: 'FFB91C1C' } };
            r++;
        });
        // Instrucciones primero al abrir
        wb.views = [{ activeTab: 0 }];
        return { wb: wb, cols: cols, T: T };
    }

    async function descargar(tipo, op) {
        op = op || {};
        var lb = await libro(tipo, ejemplos(tipo, op.rubro), op);
        var buf = await lb.wb.xlsx.writeBuffer();
        var R = window.RefRubro ? window.RefRubro.get(op.rubro) : null;
        bajar(new Blob([buf], { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' }),
            'plantilla_' + tipo + (tipo === 'productos' && R ? '_' + R.id : '') + '.xlsx');
    }

    async function exportar(tipo, filas, op) {
        op = op || {};
        var nombre = (op.nombre || (tipo + '_' + hoyISO())).replace(/[^\w\-áéíóúñÁÉÍÓÚÑ ]+/g, '_');
        if (op.formato === 'csv') {
            var cols = columnas(tipo, op.rubro);
            if (op.columnas && op.columnas.length) cols = cols.filter(function (c) { return c.req || op.columnas.indexOf(c.k) >= 0; });
            if (op.extra) cols = cols.concat(op.extra);
            var esc = function (v) { v = v == null ? '' : String(v); return /[";\n\r]/.test(v) || /^0\d|^\d{11,}$/.test(v) ? '"' + v.replace(/"/g, '""') + '"' : v; };
            var csv = '﻿' + [cols.map(function (c) { return esc(c.h); }).join(';')].concat((filas || []).map(function (f) { return cols.map(function (c) { return esc(f[c.k]); }).join(';'); })).join('\r\n');
            bajar(new Blob([csv], { type: 'text/csv;charset=utf-8' }), nombre + '.csv');
            return;
        }
        var lb = await libro(tipo, filas, op);
        var buf = await lb.wb.xlsx.writeBuffer();
        bajar(new Blob([buf], { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' }), nombre + '.xlsx');
    }

    window.RefPlantillas = { tipos: TIPOS, listas: LISTAS, columnas: columnas, descargar: descargar, exportar: exportar, cargarExcelJS: cargarExcelJS };
})();
