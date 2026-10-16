/* REFRIMAR · Tipos de negocio (rubros).
 * El rubro se guarda en configuracion.rubro y adapta: campos extra del producto (se guardan en
 * productos.atributos), categorías sugeridas, plantilla de Excel y filas de ejemplo.
 * Para agregar un rubro: agrega un objeto a RUBROS. Nada más cambia.
 *
 * Campo extra: { k: clave en atributos, label, tipo: 'texto'|'numero'|'fecha'|'lista'|'si_no', opciones:[], ayuda, ancho }
 */
(function () {
    'use strict';

    var RUBROS = [
        {
            id: 'ferreteria', label: 'Ferretería', icono: 'hardware',
            desc: 'Venta por unidad, metro, kilo o rollo en filas separadas, medidas y referencia de fábrica.',
            campos: [
                { k: 'diametro', label: 'Diámetro', tipo: 'texto', ayuda: 'Ej. 1/2", 3/4", 10 mm' },
                { k: 'calibre', label: 'Calibre', tipo: 'texto', ayuda: 'Ej. #12, #14, 18 AWG' },
                { k: 'largo', label: 'Largo', tipo: 'texto', ayuda: 'Ej. 3 m, 6", 100 m' },
                { k: 'material', label: 'Material', tipo: 'texto', ayuda: 'PVC, cobre, acero galvanizado…' },
                { k: 'ubicacion', label: 'Ubicación', tipo: 'texto', ayuda: 'Pasillo / estante. Ej. P3-E2' }
            ],
            categorias: {
                'PLOMERÍA': ['TUBERÍA', 'CONEXIONES', 'GRIFERÍA', 'TANQUES'], 'ELECTRICIDAD': ['CABLES', 'BREAKERS', 'TOMAS E INTERRUPTORES', 'ILUMINACIÓN'],
                'HERRAMIENTAS': ['MANUALES', 'ELÉCTRICAS', 'MEDICIÓN'], 'FIJACIÓN': ['TORNILLOS', 'CLAVOS', 'TACOS', 'PEGAMENTOS'],
                'CONSTRUCCIÓN': ['CEMENTO', 'BLOQUES', 'CABILLAS'], 'PINTURAS': ['CAUCHO', 'ESMALTE', 'ACCESORIOS'], 'SERVICIOS': []
            },
            ejemplos: [
                { nombre: 'TUBO PVC 1/2" AGUAS BLANCAS 3 MTS', barra: '7591234000018', tipo: 'Venta por unidad', categoria: 'PLOMERÍA', subcategoria: 'TUBERÍA', marca: 'Pavco', costo: 2.10, precio: 3.50, stock: 40, min: 10, iva: 16, attr: { diametro: '1/2"', largo: '3 m', material: 'PVC', ubicacion: 'P1-E3' } },
                { nombre: 'CABLE THHN #12 (POR METRO)', barra: '2990000000017', tipo: 'Venta por metro', categoria: 'ELECTRICIDAD', subcategoria: 'CABLES', marca: 'Cablesa', costo: 0.35, precio: 0.60, stock: 500, min: 100, iva: 16, attr: { calibre: '#12', material: 'Cobre' } },
                { nombre: 'CABLE THHN #12 ROLLO 100 M', barra: '2990000000024', tipo: 'Venta por unidad', categoria: 'ELECTRICIDAD', subcategoria: 'CABLES', marca: 'Cablesa', costo: 32, precio: 52, stock: 5, min: 1, iva: 16, attr: { calibre: '#12', largo: '100 m' } },
                { nombre: 'CLAVO DE ACERO 3" (POR KILO)', barra: '2990000000031', tipo: 'Venta por kilo', categoria: 'FIJACIÓN', subcategoria: 'CLAVOS', marca: 'Genérico', costo: 1.80, precio: 2.90, stock: 25, min: 5, iva: 16, attr: { largo: '3"' } },
                { nombre: 'CORTE DE TUBO', barra: 'SRV-CORTE', tipo: 'Servicio', categoria: 'SERVICIOS', marca: 'Genérico', costo: 0, precio: 1, iva: 16 }
            ],
            notas: ['Cada forma de venta va en su propia fila con su propio código (ej. "Cable #12 por metro" y "Cable #12 rollo 100 m").']
        },
        {
            id: 'refrigeracion', label: 'Refrigeración / línea blanca', icono: 'ac_unit',
            desc: 'Repuestos con número de parte, equipos compatibles, voltaje y garantía.',
            campos: [
                { k: 'num_parte', label: 'N.º de parte', tipo: 'texto', ayuda: 'Número de parte del fabricante' },
                { k: 'compatibilidad', label: 'Equipos compatibles', tipo: 'texto', ayuda: 'Marcas/modelos: "Whirlpool WRT, Mabe RMA…"' },
                { k: 'voltaje', label: 'Voltaje', tipo: 'lista', opciones: ['110 V', '220 V', '110/220 V', '12 V', '24 V'] },
                { k: 'refrigerante', label: 'Refrigerante', tipo: 'lista', opciones: ['R-134a', 'R-410A', 'R-22', 'R-600a', 'R-404A', 'R-32'] },
                { k: 'garantia_meses', label: 'Garantía (meses)', tipo: 'numero' },
                { k: 'ubicacion', label: 'Ubicación', tipo: 'texto' }
            ],
            categorias: { 'COMPRESORES': [], 'GASES REFRIGERANTES': [], 'CAPACITORES': [], 'TERMOSTATOS': [], 'MOTORES Y VENTILADORES': [], 'TUBERÍA DE COBRE': [], 'REPUESTOS LAVADORA': [], 'HERRAMIENTAS DE REFRIGERACIÓN': [] },
            ejemplos: [
                { nombre: 'CAPACITOR DE MARCHA 35+5 MFD 370V', barra: '7590005000011', tipo: 'Venta por unidad', categoria: 'CAPACITORES', marca: 'Genérico', costo: 4, precio: 7.5, stock: 30, min: 5, iva: 16, attr: { voltaje: '220 V', compatibilidad: 'Aires de ventana y split', garantia_meses: 3 } },
                { nombre: 'GAS REFRIGERANTE R-410A (POR KILO)', barra: '2990000000048', tipo: 'Venta por kilo', categoria: 'GASES REFRIGERANTES', marca: 'Genetron', costo: 9, precio: 15, stock: 11.3, min: 2, iva: 16, attr: { refrigerante: 'R-410A' } }
            ]
        },
        {
            id: 'supermercado', label: 'Supermercado / abasto', icono: 'shopping_basket',
            desc: 'Pesables con código de balanza, lote y vencimiento, compra por caja y venta por unidad.',
            campos: [
                { k: 'lote', label: 'Lote', tipo: 'texto' },
                { k: 'vencimiento', label: 'Vencimiento', tipo: 'fecha', ayuda: 'AAAA-MM-DD' },
                { k: 'unidades_por_caja', label: 'Unidades por caja', tipo: 'numero', ayuda: 'Compra en caja, venta por unidad' },
                { k: 'contenido', label: 'Contenido neto', tipo: 'texto', ayuda: 'Ej. 1 kg, 500 ml' },
                { k: 'registro_sanitario', label: 'Registro sanitario', tipo: 'texto' }
            ],
            categorias: { 'VÍVERES': ['GRANOS', 'PASTAS', 'HARINAS', 'ACEITES'], 'CHARCUTERÍA': [], 'LÁCTEOS': [], 'BEBIDAS': [], 'LIMPIEZA': [], 'CUIDADO PERSONAL': [], 'FRUTAS Y VERDURAS': [], 'CARNES': [] },
            ejemplos: [
                { nombre: 'HARINA DE MAÍZ PAN 1 KG', barra: '7591002000011', tipo: 'Venta por unidad', categoria: 'VÍVERES', subcategoria: 'HARINAS', marca: 'P.A.N.', costo: 0.95, precio: 1.30, stock: 120, min: 24, iva: 0, attr: { contenido: '1 kg', unidades_por_caja: 20, vencimiento: '2027-03-31', lote: 'L2410' } },
                { nombre: 'QUESO BLANCO DURO (POR KILO)', barra: '2000001', tipo: 'Venta por kilo', categoria: 'CHARCUTERÍA', marca: 'Genérico', costo: 4.2, precio: 6.5, stock: 18.5, min: 3, iva: 0, pesable: 'Sí', balanza: '00001', attr: { vencimiento: '2026-11-15' } }
            ]
        },
        {
            id: 'autopartes', label: 'Autopartes / repuestos', icono: 'directions_car',
            desc: 'Número de parte OEM, códigos alternos, compatibilidad marca/modelo/año y ubicación en estante.',
            campos: [
                { k: 'oem', label: 'N.º de parte OEM', tipo: 'texto' },
                { k: 'codigos_equivalentes', label: 'Códigos equivalentes', tipo: 'texto', ayuda: 'Separados por coma' },
                { k: 'vehiculo_marca', label: 'Marca de vehículo', tipo: 'texto', ayuda: 'Toyota, Chevrolet…' },
                { k: 'vehiculo_modelo', label: 'Modelo', tipo: 'texto', ayuda: 'Corolla, Aveo…' },
                { k: 'vehiculo_anios', label: 'Años', tipo: 'texto', ayuda: 'Ej. 2008-2014' },
                { k: 'motor', label: 'Motor', tipo: 'texto', ayuda: 'Ej. 1.8 16V' },
                { k: 'ubicacion', label: 'Ubicación', tipo: 'texto', ayuda: 'Pasillo / estante' }
            ],
            categorias: { 'FRENOS': ['PASTILLAS', 'DISCOS', 'BANDAS'], 'SUSPENSIÓN': ['AMORTIGUADORES', 'MESETAS', 'TERMINALES'], 'MOTOR': ['FILTROS', 'CORREAS', 'EMPACADURAS'], 'ELÉCTRICO': ['BUJÍAS', 'BATERÍAS', 'BOMBILLOS'], 'LUBRICANTES': [] },
            ejemplos: [
                { nombre: 'PASTILLA DE FRENO DELANTERA', barra: '7593000000017', tipo: 'Venta por unidad', categoria: 'FRENOS', subcategoria: 'PASTILLAS', marca: 'Bosch', costo: 14, precio: 24, stock: 8, min: 2, iva: 16, attr: { oem: '04465-02220', vehiculo_marca: 'Toyota', vehiculo_modelo: 'Corolla', vehiculo_anios: '2009-2013', ubicacion: 'A2-E4' } }
            ]
        },
        {
            id: 'farmacia', label: 'Farmacia', icono: 'medication',
            desc: 'Principio activo, concentración, lote, vencimiento y control de vencidos.',
            campos: [
                { k: 'principio_activo', label: 'Principio activo', tipo: 'texto' },
                { k: 'concentracion', label: 'Concentración', tipo: 'texto', ayuda: 'Ej. 500 mg' },
                { k: 'forma', label: 'Forma', tipo: 'lista', opciones: ['Tabletas', 'Cápsulas', 'Jarabe', 'Suspensión', 'Crema', 'Gotas', 'Inyectable', 'Otro'] },
                { k: 'lote', label: 'Lote', tipo: 'texto' },
                { k: 'vencimiento', label: 'Vencimiento', tipo: 'fecha' },
                { k: 'registro_sanitario', label: 'Registro sanitario', tipo: 'texto' },
                { k: 'requiere_recipe', label: 'Requiere récipe', tipo: 'si_no' }
            ],
            categorias: { 'MEDICAMENTOS': ['ANALGÉSICOS', 'ANTIBIÓTICOS', 'ANTIGRIPALES', 'TENSIÓN'], 'CUIDADO PERSONAL': [], 'BEBÉ': [], 'VITAMINAS': [] },
            ejemplos: [
                { nombre: 'ACETAMINOFÉN 500 MG X 10 TAB', barra: '7594000000014', tipo: 'Venta por unidad', categoria: 'MEDICAMENTOS', subcategoria: 'ANALGÉSICOS', marca: 'Genven', costo: 0.6, precio: 1.1, stock: 200, min: 40, iva: 0, attr: { principio_activo: 'Acetaminofén', concentracion: '500 mg', forma: 'Tabletas', lote: 'A123', vencimiento: '2027-06-30', requiere_recipe: 'No' } }
            ]
        },
        {
            id: 'ropa', label: 'Ropa y calzado', icono: 'checkroom',
            desc: 'Variantes de talla y color con un código por variante.',
            campos: [
                { k: 'modelo', label: 'Modelo (agrupa variantes)', tipo: 'texto', ayuda: 'El mismo valor en todas las tallas/colores del modelo' },
                { k: 'talla', label: 'Talla', tipo: 'texto', ayuda: 'S, M, L, 38, 40…' },
                { k: 'color', label: 'Color', tipo: 'texto' },
                { k: 'genero', label: 'Género', tipo: 'lista', opciones: ['Dama', 'Caballero', 'Niño', 'Niña', 'Unisex'] },
                { k: 'temporada', label: 'Temporada', tipo: 'texto' }
            ],
            categorias: { 'DAMA': ['BLUSAS', 'PANTALONES', 'VESTIDOS'], 'CABALLERO': ['CAMISAS', 'PANTALONES'], 'CALZADO': ['DEPORTIVO', 'CASUAL'], 'NIÑOS': [], 'ACCESORIOS': [] },
            ejemplos: [
                { nombre: 'FRANELA BÁSICA NEGRA M', barra: '7595000000011', tipo: 'Venta por unidad', categoria: 'CABALLERO', subcategoria: 'CAMISAS', marca: 'Genérico', costo: 3, precio: 7, stock: 12, min: 3, iva: 16, attr: { modelo: 'FRANELA-BASICA', talla: 'M', color: 'Negro', genero: 'Caballero' } },
                { nombre: 'FRANELA BÁSICA NEGRA L', barra: '7595000000028', tipo: 'Venta por unidad', categoria: 'CABALLERO', subcategoria: 'CAMISAS', marca: 'Genérico', costo: 3, precio: 7, stock: 10, min: 3, iva: 16, attr: { modelo: 'FRANELA-BASICA', talla: 'L', color: 'Negro', genero: 'Caballero' } }
            ],
            notas: ['Cada talla y color es una fila con su propio código. Usa el mismo "Modelo" para agruparlas.']
        },
        {
            id: 'licoreria', label: 'Licorería', icono: 'liquor',
            desc: 'Grado alcohólico, volumen, unidades por caja y lote.',
            campos: [
                { k: 'grado', label: 'Grado alcohólico (%)', tipo: 'numero' },
                { k: 'volumen', label: 'Volumen', tipo: 'texto', ayuda: 'Ej. 750 ml, 1 L' },
                { k: 'unidades_por_caja', label: 'Unidades por caja', tipo: 'numero' },
                { k: 'lote', label: 'Lote', tipo: 'texto' }
            ],
            categorias: { 'RON': [], 'WHISKY': [], 'CERVEZA': [], 'VINOS': [], 'ANÍS': [], 'REFRESCOS Y HIELO': [] },
            ejemplos: [
                { nombre: 'RON AÑEJO 0,75 L', barra: '7596000000018', tipo: 'Venta por unidad', categoria: 'RON', marca: 'Genérico', costo: 6, precio: 10, stock: 24, min: 6, iva: 16, attr: { grado: 40, volumen: '750 ml', unidades_por_caja: 12 } }
            ]
        },
        {
            id: 'panaderia', label: 'Panadería / charcutería', icono: 'bakery_dining',
            desc: 'Pesables con código de balanza, producción del día y vencimiento corto.',
            campos: [
                { k: 'vencimiento_dias', label: 'Dura (días)', tipo: 'numero' },
                { k: 'contenido', label: 'Contenido', tipo: 'texto' },
                { k: 'produccion_propia', label: 'Producción propia', tipo: 'si_no' }
            ],
            categorias: { 'PANADERÍA': ['PAN SALADO', 'PAN DULCE'], 'PASTELERÍA': [], 'CHARCUTERÍA': ['QUESOS', 'EMBUTIDOS'], 'BEBIDAS': [], 'VÍVERES': [] },
            ejemplos: [
                { nombre: 'PAN CANILLA', barra: '2990000000055', tipo: 'Venta por unidad', categoria: 'PANADERÍA', subcategoria: 'PAN SALADO', marca: 'Propia', costo: 0.25, precio: 0.6, stock: 80, min: 0, iva: 0, attr: { vencimiento_dias: 1, produccion_propia: 'Sí' } },
                { nombre: 'JAMÓN DE PIERNA (POR KILO)', barra: '2000010', tipo: 'Venta por kilo', categoria: 'CHARCUTERÍA', subcategoria: 'EMBUTIDOS', marca: 'Genérico', costo: 7, precio: 11, stock: 6.2, min: 1, iva: 16, pesable: 'Sí', balanza: '00010' }
            ]
        },
        {
            id: 'electronica', label: 'Electrónica / celulares', icono: 'smartphone',
            desc: 'Serial o IMEI por unidad, garantía y modelo.',
            campos: [
                { k: 'modelo', label: 'Modelo', tipo: 'texto' },
                { k: 'capacidad', label: 'Capacidad', tipo: 'texto', ayuda: 'Ej. 128 GB' },
                { k: 'color', label: 'Color', tipo: 'texto' },
                { k: 'garantia_meses', label: 'Garantía (meses)', tipo: 'numero' },
                { k: 'imei', label: 'Serial / IMEI', tipo: 'texto', ayuda: 'Un producto por equipo si cada uno lleva su serial' }
            ],
            requiereSerial: true,
            categorias: { 'CELULARES': [], 'ACCESORIOS': ['CARGADORES', 'FORROS', 'AUDÍFONOS'], 'COMPUTACIÓN': [], 'AUDIO': [], 'TV Y VIDEO': [] },
            ejemplos: [
                { nombre: 'AUDÍFONOS INALÁMBRICOS TWS', barra: '7597000000015', tipo: 'Venta por unidad', categoria: 'ACCESORIOS', subcategoria: 'AUDÍFONOS', marca: 'Genérico', costo: 6, precio: 14, stock: 15, min: 3, iva: 16, attr: { color: 'Blanco', garantia_meses: 1 } }
            ]
        },
        {
            id: 'generico', label: 'Genérico / otro', icono: 'storefront',
            desc: 'Solo los campos básicos. Puedes agregar atributos libres en cada producto.',
            campos: [{ k: 'ubicacion', label: 'Ubicación', tipo: 'texto' }],
            categorias: { 'GENERAL': [] },
            ejemplos: [{ nombre: 'PRODUCTO DE EJEMPLO', barra: 'PROD-001', tipo: 'Venta por unidad', categoria: 'GENERAL', marca: 'Genérico', costo: 1, precio: 2, stock: 10, min: 2, iva: 16 }]
        }
    ];

    var POR_ID = {}; RUBROS.forEach(function (r) { POR_ID[r.id] = r; });
    var CLAVE = 'refrimar_rubro';

    function leerLocal() { try { return localStorage.getItem(CLAVE) || ''; } catch (e) { return ''; } }
    function guardarLocal(v) { try { localStorage.setItem(CLAVE, v); } catch (e) {} }

    window.RefRubro = {
        lista: RUBROS,
        get: function (id) { return POR_ID[id] || POR_ID.ferreteria; },
        // Rubro del negocio (primero el guardado en el equipo, luego se confirma con la base de datos)
        actualId: function () { var v = leerLocal(); return POR_ID[v] ? v : 'ferreteria'; },
        actual: function () { return this.get(this.actualId()); },
        cargar: async function () {
            try {
                var r = await supabaseClient.from('configuracion').select('rubro,opciones').limit(1).maybeSingle();
                if (r && r.data) {
                    if (r.data.rubro && POR_ID[r.data.rubro]) guardarLocal(r.data.rubro);
                    window.REF_OPCIONES_NEGOCIO = r.data.opciones || {};
                    try { localStorage.setItem('refrimar_opciones_negocio', JSON.stringify(window.REF_OPCIONES_NEGOCIO)); } catch (e) {}
                }
            } catch (e) {}
            return this.actual();
        },
        guardar: async function (id, opciones) {
            var r = await supabaseClient.rpc('config_rubro_guardar', { p_rubro: id, p_opciones: opciones || null });
            if (!r.error) guardarLocal(id);
            return r;
        },
        // Opciones del negocio (bloquear sin stock, IGTF, retención…) guardadas en este equipo
        opciones: function () { if (window.REF_OPCIONES_NEGOCIO) return window.REF_OPCIONES_NEGOCIO; try { return JSON.parse(localStorage.getItem('refrimar_opciones_negocio') || '{}'); } catch (e) { return {}; } },
        // Todas las claves de campos de rubro (para no repetirlas como atributo libre)
        todasLasClaves: function () { var s = {}; RUBROS.forEach(function (r) { r.campos.forEach(function (c) { s[c.k] = 1; }); }); return Object.keys(s); }
    };
})();
