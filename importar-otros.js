/* REFRIMAR · Importar clientes, proveedores y cuentas por cobrar iniciales.
 * Mismo flujo que productos: leer → reconocer columnas → validar → vista previa con filtros →
 * importar fila por fila (si una falla, sigue con las demás) → resumen y errores descargables.
 * Usa las columnas de js/plantillas.js para reconocer los títulos.
 */
(function () {
    'use strict';
    var $ = function (id) { return document.getElementById(id); };
    function normTxt(s) { return String(s == null ? '' : s).toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/[^a-z0-9 ]/g, ' ').replace(/\s+/g, ' ').trim(); }
    function numero(t) {
        if (t === null || t === undefined || t === '') return null;
        if (typeof t === 'number') return isFinite(t) ? t : null;
        t = String(t).replace(/[^0-9.,-]/g, ''); if (!t) return null;
        var c = t.lastIndexOf(','), d = t.lastIndexOf('.');
        if (c > -1 && d > -1) t = c > d ? t.replace(/\./g, '').replace(',', '.') : t.replace(/,/g, '');
        else if (c > -1) t = t.replace(/\./g, '').replace(',', '.');
        var n = Number(t); return isFinite(n) ? n : null;
    }
    // Cédula / RIF venezolano: letra + números (se normaliza a V-12345678 / J-12345678-9)
    function normRif(v) {
        var t = String(v || '').toUpperCase().replace(/[\s.]/g, '');
        if (!t) return '';
        var m = t.match(/^([VEJGPC])-?(\d{5,9})-?(\d)?$/);
        if (m) return m[1] + '-' + m[2] + (m[3] ? '-' + m[3] : '');
        if (/^\d{5,9}$/.test(t)) return 'V-' + t;
        return t;
    }
    function rifValido(t) { return /^[VEJGPC]-\d{5,9}(-\d)?$/.test(t); }
    var SIN = {
        rif: ['rif', 'cedula', 'cedula o rif', 'ci', 'documento', 'rif cedula', 'cedula rif', 'identificacion'],
        nombre: ['nombre', 'nombre o razon social', 'razon social', 'cliente', 'proveedor', 'empresa'],
        telefono: ['telefono', 'tlf', 'celular', 'movil', 'whatsapp'],
        email: ['correo', 'email', 'e mail', 'correo electronico'],
        direccion: ['direccion', 'domicilio'],
        tipo: ['tipo de cliente', 'tipo'],
        limite: ['limite de credito', 'limite', 'credito'],
        notas: ['notas', 'observaciones', 'nota'],
        numero: ['n documento', 'numero', 'nro', 'factura', 'n factura', 'documento numero', 'numero de factura'],
        monto: ['monto usd', 'monto', 'saldo', 'deuda', 'pendiente', 'saldo usd'],
        dias: ['dias de credito', 'dias', 'plazo']
    };
    var ST = null, TABLA = null;

    function mapear(headers, tipo) {
        var cols = window.RefPlantillas.columnas(tipo);
        var mapa = {}, usados = {};
        cols.forEach(function (c) {
            var syn = [normTxt(c.h)].concat(SIN[c.k] || []);
            var i = headers.findIndex(function (h, j) { return !usados[j] && syn.indexOf(normTxt(h)) >= 0; });
            if (i >= 0) { mapa[c.k] = i; usados[i] = true; }
        });
        return { mapa: mapa, cols: cols };
    }

    async function leer(f, tipo, op) {
        try {
            var X = await nk.cargarScript('https://cdnjs.cloudflare.com/ajax/libs/xlsx/0.18.5/xlsx.full.min.js', function () { return !!window.XLSX; }).then(function () { return window.XLSX; });
            var wb = X.read(await f.arrayBuffer(), { type: 'array', raw: /\.csv$/i.test(f.name) });
            var hoja = wb.SheetNames.find(function (n) { return !/^(instrucciones|listas)$/i.test(n); }) || wb.SheetNames[0];
            var filas = X.utils.sheet_to_json(wb.Sheets[hoja], { header: 1, raw: true, defval: '' });
            var hIdx = 0, mejor = -1;
            for (var i = 0; i < Math.min(filas.length, 15); i++) { var m0 = mapear((filas[i] || []).map(String), tipo); var n = Object.keys(m0.mapa).length; if (n > mejor) { mejor = n; hIdx = i; } }
            var headers = (filas[hIdx] || []).map(function (h) { return String(h == null ? '' : h).trim(); });
            var mp = mapear(headers, tipo);
            var falta = mp.cols.filter(function (c) { return c.req && mp.mapa[c.k] == null; });
            if (falta.length) { nk.toast('No encontramos las columnas: ' + falta.map(function (c) { return c.h; }).join(', ') + '. Usa la plantilla.', 'error'); return; }
            ST = { tipo: tipo, archivo: f.name, op: op || {}, cols: mp.cols, mapa: mp.mapa, filas: [] };
            filas.slice(hIdx + 1).forEach(function (cel, k) {
                cel = cel || [];
                if (!cel.some(function (c) { return String(c == null ? '' : c).trim() !== ''; })) return;
                var r = { fila: hIdx + k + 2, _raw: {} };
                mp.cols.forEach(function (c) { var j = mp.mapa[c.k]; var v = j == null ? '' : cel[j]; r._raw[c.k] = String(v == null ? '' : v).trim(); r[c.k] = r._raw[c.k]; });
                ST.filas.push(r);
            });
            await validar();
            pintar();
        } catch (e) { nk.toast('No se pudo leer el archivo: ' + (e.message || e), 'error'); }
    }

    async function validar() {
        var t = ST.tipo, vistos = {};
        // Existentes (para decir si se crea o se actualiza)
        var exist = {};
        var tabla = t === 'proveedores' ? 'proveedores' : 'clientes';
        var r = await supabaseClient.from(tabla).select('id,rif,nombre').limit(10000);
        ((r && r.data) || []).forEach(function (x) { if (x.rif) exist[normRif(x.rif)] = x; });
        ST.existentes = exist;
        ST.filas.forEach(function (f) {
            f._err = ''; f._avisos = [];
            f.rif = normRif(f.rif);
            f.nombre = String(f.nombre || '').trim().toUpperCase();
            f._existe = !!exist[f.rif];
            if (!f.rif) f._err = 'Falta la cédula o RIF';
            else if (!f.nombre) f._err = 'Falta el nombre';
            else if (t !== 'cxc' && vistos[f.rif]) f._err = 'Cédula/RIF repetido en el archivo (fila ' + vistos[f.rif] + ')';
            else if (t === 'cxc' && !f.numero) f._err = 'Falta el número de documento';
            else if (t === 'cxc' && !(numero(f.monto) > 0)) f._err = 'El monto debe ser mayor que cero';
            if (f.rif && !vistos[f.rif]) vistos[f.rif] = f.fila;
            if (f._err) return;
            if (!rifValido(f.rif)) f._avisos.push('La cédula/RIF no tiene el formato V-12345678 o J-12345678-9');
            if (f.email && !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(f.email)) f._avisos.push('Correo con formato raro');
            if (f.limite && numero(f.limite) == null) f._avisos.push('Límite de crédito no es un número (queda en 0)');
        });
    }

    function pintar() {
        var box = $('io-trabajo');
        $('im-inicio').style.display = 'none';
        box.style.display = '';
        var n = ST.filas.length, err = ST.filas.filter(function (f) { return f._err; }).length, warn = ST.filas.filter(function (f) { return !f._err && f._avisos.length; }).length;
        var lbl = { clientes: 'clientes', proveedores: 'proveedores', cxc: 'cuentas por cobrar' }[ST.tipo];
        box.innerHTML = '<section class="im-card"><h2>Archivo</h2><div class="im-file"><span class="material-symbols-outlined">description</span><div class="im-file-i"><b>' + nk.esc(ST.archivo) + '</b><small>Importar ' + lbl + '</small><div class="im-bar"><i id="io-barra" style="width:0%"></i></div></div><span class="im-estado" id="io-estado">Pendiente</span></div>' +
            '<div class="im-kpis im-kpis-4"><div class="im-kpi"><span class="material-symbols-outlined">list_alt</span><div><b>' + n + '</b><small>Total registros</small></div></div>' +
            '<div class="im-kpi"><span class="material-symbols-outlined">check_circle</span><div><b>' + (n - err - warn) + '</b><small>Correctos</small></div></div>' +
            '<div class="im-kpi im-kpi-warn"><span class="material-symbols-outlined">warning</span><div><b>' + warn + '</b><small>Con advertencia</small></div></div>' +
            '<div class="im-kpi im-kpi-err"><span class="material-symbols-outlined">error</span><div><b>' + err + '</b><small>Con error</small></div></div></div>' +
            '<div class="nk-actions" style="margin-top:14px"><button type="button" class="nk-btn" id="io-ok"' + (n - err ? '' : ' disabled') + '>Importar ' + (n - err) + ' ' + lbl + '<span class="material-symbols-outlined">upload</span></button>' +
            (err ? '<button type="button" class="nk-btn nk-btn-outline" id="io-err">Descargar filas con error</button>' : '') + '<a class="nk-btn nk-btn-outline" href="importar.html#' + ST.tipo + '" onclick="setTimeout(function(){location.reload()},10)">Elegir otro archivo</a></div></section>' +
            '<section class="im-card"><h2>Vista previa</h2><div id="io-prev"></div></section><section class="im-card" id="io-final" style="display:none"></section>';
        var cols = ST.cols.filter(function (c) { return ST.mapa[c.k] != null; }).slice(0, 6);
        TABLA = nk.table({
            el: '#io-prev', pageSize: 10, placeholder: 'Buscar',
            tabs: [{ key: 'todo', label: 'Todas' }, { key: 'ok', label: 'Correctas', test: function (f) { return !f._err && !f._avisos.length; } }, { key: 'warn', label: 'Con advertencia', test: function (f) { return !f._err && f._avisos.length; } }, { key: 'err', label: 'Con error', test: function (f) { return !!f._err; } }],
            search: function (f) { return [f.rif, f.nombre, f.numero, f._err].join(' '); },
            columns: [{ label: 'Fila', render: function (f) { return f.fila; } }].concat(cols.map(function (c) { return { label: c.h, render: function (f) { return nk.esc(f[c.k] || '—'); } }; })).concat([
                { label: 'Estado', render: function (f) { return f._res ? f._res : f._err ? '<span class="nk-badge nk-b-red">' + nk.esc(f._err) + '</span>' : (ST.tipo === 'cxc' ? nk.badge('pendiente', 'Deuda nueva') : f._existe ? nk.badge('ordenada', 'Actualizar') : nk.badge('activo', 'Nuevo')) + (f._avisos.length ? '<span class="nk-sub im-aviso">⚠ ' + nk.esc(f._avisos[0]) + '</span>' : ''); } }]),
            afterRender: function (tb, sl) { tb.querySelectorAll('tr').forEach(function (tr, i) { var f = sl[i]; if (!f) return; tr.classList.toggle('im-err-row', !!f._err); tr.classList.toggle('im-warn-row', !f._err && f._avisos.length > 0); }); }
        });
        TABLA.setRows(ST.filas);
        $('io-ok').addEventListener('click', importar);
        var be = $('io-err'); if (be) be.addEventListener('click', function () { nk.busy(be, function () { return errores(ST.filas.filter(function (f) { return f._err; })); }); });
    }

    async function guardarCliente(f) {
        var ex = ST.existentes[f.rif];
        var r = await supabaseClient.rpc('cliente_guardar', { p_nombre: f.nombre, p_id: ex ? ex.id : null, p_rif: f.rif, p_telefono: f.telefono || null, p_email: f.email || null,
            p_direccion: f.direccion || null, p_tipo: f.tipo || 'final', p_limite_credito: numero(f.limite) || 0, p_notas: f.notas || null, p_sucursal_id: ST.op.sucursal ? ST.op.sucursal.id : null });
        if (r.error) throw new Error(nk.errMsg(r.error));
        var id = r.data; if (id && typeof id === 'object') id = id.id;
        ST.existentes[f.rif] = { id: id, rif: f.rif, nombre: f.nombre };
        return id;
    }
    async function guardarProveedor(f) {
        var ex = ST.existentes[f.rif];
        var payload = { nombre: f.nombre, rif: f.rif, telefono: f.telefono || null, email: f.email || null, direccion: f.direccion || null };
        var r = ex ? await supabaseClient.from('proveedores').update(payload).eq('id', ex.id) : await supabaseClient.from('proveedores').insert(payload);
        if (r.error) throw new Error(nk.errMsg(r.error));
    }
    async function guardarCxc(f) {
        var ex = ST.existentes[f.rif];
        var id = ex ? ex.id : await guardarCliente(f);
        var s = ST.op.sucursal || {};
        var r = await supabaseClient.rpc('deuda_venta_crear', { p_cliente_id: id, p_numero: String(f.numero), p_monto_usd: numero(f.monto), p_dias_credito: Math.round(numero(f.dias) || 30),
            p_notas: f.notas || 'Saldo inicial importado', p_sucursal_id: s.id || null, p_sucursal_nombre: s.nombre || null, p_usuario: (window.getSesionUsuario() || {}).nombre || 'Sistema' });
        if (r.error) throw new Error(nk.errMsg(r.error));
        if (r.data && r.data.ok === false) throw new Error(r.data.error || 'No se pudo crear la deuda');
    }

    async function importar() {
        var ok = ST.filas.filter(function (f) { return !f._err; });
        if (!await refConfirm('Se importarán ' + ok.length + ' registros. Si uno falla, se sigue con los demás. ¿Continuar?')) return;
        var btn = $('io-ok'); btn.disabled = true;
        $('io-estado').textContent = 'Procesando'; $('io-estado').className = 'im-estado run';
        var t0 = performance.now(), res = { creados: 0, actualizados: 0, errores: [] };
        var fn = ST.tipo === 'clientes' ? guardarCliente : ST.tipo === 'proveedores' ? guardarProveedor : guardarCxc;
        for (var i = 0; i < ok.length; i++) {
            var f = ok[i], existia = f._existe;
            try { await fn(f); if (existia && ST.tipo !== 'cxc') res.actualizados++; else res.creados++; f._res = nk.badge('completado', existia && ST.tipo !== 'cxc' ? 'Actualizado' : 'Creado'); }
            catch (e) { f._err = e.message || 'Error'; res.errores.push(f); f._res = '<span class="nk-badge nk-b-red">' + nk.esc(f._err) + '</span>'; }
            if (i % 5 === 0 || i === ok.length - 1) { var pct = Math.round((i + 1) / ok.length * 100); $('io-barra').style.width = pct + '%'; $('io-estado').textContent = 'Procesando ' + pct + '%'; }
        }
        var ms = Math.round(performance.now() - t0);
        $('io-estado').textContent = 'Completado'; $('io-estado').className = 'im-estado ok';
        TABLA.refresh();
        var malos = ST.filas.filter(function (f) { return f._err; });
        var fin = $('io-final'); fin.style.display = '';
        fin.innerHTML = '<h2>Resultado</h2><div class="im-res"><div><b>' + ST.filas.length + '</b><small>Filas enviadas</small></div><div class="ok"><b>' + (res.creados + res.actualizados) + '</b><small>Correctas (' + res.creados + ' nuevas, ' + res.actualizados + ' actualizadas)</small></div><div class="err"><b>' + malos.length + '</b><small>Con error</small></div><div><b>' + Math.round(ms / 1000) + ' s</b><small>Tiempo</small></div></div>' +
            (malos.length ? '<div class="nk-actions" style="margin-top:14px"><button type="button" class="nk-btn nk-btn-outline" id="io-err2">Descargar errores para corregir</button></div>' : '');
        var b2 = $('io-err2'); if (b2) b2.addEventListener('click', function () { nk.busy(b2, function () { return errores(malos); }); });
        try {
            var s = ST.op.sucursal || {};
            supabaseClient.rpc('importacion_registrar', { p_archivo: ST.archivo, p_sucursal_id: s.id || null, p_sucursal_nombre: s.nombre || null, p_usuario: (window.getSesionUsuario() || {}).nombre || 'Sistema', p_modo_stock: ST.tipo,
                p_filas: ST.filas.length, p_creados: res.creados, p_actualizados: res.actualizados, p_omitidos: 0, p_errores: malos.slice(0, 2000).map(function (f) { return { fila: f.fila, codigo: f.rif, error: f._err }; }) }).then(function () {}, function () {});
        } catch (e) {}
        nk.toast('Importación terminada', malos.length ? 'warning' : 'success');
        fin.scrollIntoView({ behavior: 'smooth', block: 'start' });
    }

    function errores(lista) {
        return window.RefPlantillas.exportar(ST.tipo, lista.map(function (f) { var o = Object.assign({}, f._raw); o.motivo = f._err; o.fila_original = f.fila; return o; }),
            { nombre: 'errores_' + ST.archivo.replace(/\.\w+$/, ''), extra: [{ k: 'motivo', h: 'Motivo del error', ancho: 44 }, { k: 'fila_original', h: 'Fila original', ancho: 10 }] });
    }

    window.RefImportarOtros = { leer: leer, normRif: normRif };
})();
