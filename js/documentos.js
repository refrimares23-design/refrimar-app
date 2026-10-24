/* ============================================================
 * DOCUMENTOS PARA IMPRIMIR (SENIAT)
 * ------------------------------------------------------------
 * Arma factura, nota de crédito, nota de débito y guía de despacho
 * con los requisitos de la Providencia SNAT/2011/00071 (forma libre)
 * y la SNAT/2024/000102 (factura digital).
 *  - Forma libre: el número de control viene PREIMPRESO en el papel
 *    de la imprenta (art. 13, num. 3). El sistema lo asigna en orden y lo
 *    guarda para el Libro de Ventas; por defecto no lo vuelve a imprimir.
 *  - Moneda extranjera: si el precio se pactó en divisas, se muestra el
 *    monto en divisas, su equivalente en bolívares y el tipo de cambio
 *    (art. 13, num. 14).
 *  - Copias: llevan "Sin derecho a crédito fiscal" (art. 13, num. 13).
 * Uso: RefDocs.factura(numero, { copia }) · RefDocs.notaDebito(numero) · RefDocs.guia(transferenciaId)
 * ============================================================ */
(function () {
    'use strict';
    function esc(s) { return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); }
    function n2(v) { return (Number(v) || 0).toLocaleString('es-VE', { minimumFractionDigits: 2, maximumFractionDigits: 2 }); }
    function q3(v) { var x = Number(v) || 0; return x.toLocaleString('es-VE', { maximumFractionDigits: 3 }); }
    function fecha8(iso) { var d = new Date(iso || Date.now()); return ('0' + d.getDate()).slice(-2) + '/' + ('0' + (d.getMonth() + 1)).slice(-2) + '/' + d.getFullYear(); }
    function hora(iso) { var d = new Date(iso || Date.now()), h = d.getHours(), ap = h >= 12 ? 'p.m.' : 'a.m.'; h = h % 12 || 12; return ('0' + h).slice(-2) + ':' + ('0' + d.getMinutes()).slice(-2) + ':' + ('0' + d.getSeconds()).slice(-2) + ' ' + ap; }

    async function negocio() {
        var r = await supabaseClient.from('configuracion').select('nombre_negocio,rif,direccion,telefono,email,iva_incluido,opciones').limit(1).maybeSingle();
        var c = (r && r.data) || {}, o = c.opciones || {};
        return { razon: c.nombre_negocio || '', rif: c.rif || '', direccion: c.direccion || '', telefono: c.telefono || '', email: c.email || '',
                 comercial: o.nombre_comercial || '', logo: o.logo || '', ivaIncluido: !!c.iva_incluido, F: o.facturacion || {}, moneda: o.moneda_precios || 'USD',
                 contribuyenteEspecial: !!o.contribuyente_especial };
    }

    // Base imponible e IVA por alícuota (en divisas), a partir de las líneas
    function desglose(items, ivas, ivaIncluido) {
        var t = { exento: 0, bases: {}, ivas: {}, desc: 0 };
        items.forEach(function (d) {
            var tasa = ivas[d.producto_codigo] != null ? Number(ivas[d.producto_codigo]) : (d.iva != null ? Number(d.iva) : 16);
            var bruto = Number(d.total) || 0, neto = ivaIncluido && tasa > 0 ? bruto / (1 + tasa / 100) : bruto;
            if (!tasa) t.exento += neto; else { t.bases[tasa] = (t.bases[tasa] || 0) + neto; t.ivas[tasa] = (t.ivas[tasa] || 0) + neto * tasa / 100; }
            d._tasa = tasa;
        });
        return t;
    }
    var NOMBRE_ALICUOTA = { 16: 'General 16 %', 8: 'Reducida 8 %', 31: 'Adicional 31 %' };

    function css(papel) {
        return '<style>@page{size:' + (papel === 'media' ? '216mm 140mm' : 'letter') + ';margin:10mm}*{box-sizing:border-box}body{font:11px/1.35 Arial,Helvetica,sans-serif;color:#111;margin:0}' +
            '.doc{max-width:196mm;margin:0 auto}.cab{display:flex;justify-content:space-between;gap:12px;align-items:flex-start}.emi b{font-size:14px}.emi img{max-height:46px;max-width:160px;display:block;margin-bottom:4px}' +
            '.tit{text-align:right}.tit h1{font-size:18px;margin:0 0 4px;letter-spacing:.04em}.tit div{white-space:nowrap}.caja{border:1px solid #333;border-radius:4px;padding:6px 8px;margin-top:8px}' +
            '.g2{display:grid;grid-template-columns:1fr 1fr;gap:2px 16px}table{width:100%;border-collapse:collapse;margin-top:8px}th,td{padding:4px 5px;border-bottom:1px solid #ddd;text-align:left;vertical-align:top}' +
            'th{background:#f1f3f5;font-size:10px;text-transform:uppercase}.r{text-align:right}.tot{margin-left:auto;width:62%;margin-top:6px}.tot td{border:0;padding:2px 5px}.tot .g td{font-weight:bold;font-size:13px;border-top:1px solid #333}' +
            '.div{margin-top:8px;border:1px dashed #555;padding:5px 8px}.pie{margin-top:10px;font-size:9.5px;color:#333}.leyenda{margin-top:6px;font-weight:bold;text-align:center;letter-spacing:.05em}' +
            '.marca{position:fixed;top:45%;left:0;right:0;text-align:center;font-size:42px;color:rgba(0,0,0,.07);transform:rotate(-18deg);font-weight:bold}.hueco{height:var(--hueco,0)}' +
            '@media screen{body{background:#eee;padding:16px}.doc{background:#fff;padding:14mm;box-shadow:0 2px 10px rgba(0,0,0,.15)}}</style>';
    }

    function abrir(html, titulo) {
        var w = window.open('', '_blank', 'width=900,height=1000');
        if (!w) { (window.nk ? nk.toast('Permite las ventanas emergentes para imprimir', 'warning') : alert('Permite las ventanas emergentes para imprimir')); return null; }
        w.document.write('<!doctype html><html lang="es-VE"><head><meta charset="utf-8"><title>' + esc(titulo) + '</title></head><body>' + html +
            '<script>window.onload=function(){setTimeout(function(){window.print();},250);}<\/script></body></html>');
        w.document.close();
        return w;
    }

    // ---------- Factura ----------
    async function factura(numero, op) {
        op = op || {};
        var N = await negocio(), F = N.F, modo = F.modo || 'fiscal';
        var vr = await supabaseClient.from('ventas').select('*').eq('numero', numero).maybeSingle();
        if (vr.error || !vr.data) throw new Error('No se encontró la factura ' + numero);
        var v = vr.data;
        var dr = await supabaseClient.from('detalle_venta').select('*').eq('venta_id', v.id);
        var items = (dr && dr.data) || [];
        var cods = items.map(function (d) { return d.producto_codigo; }).filter(Boolean);
        var ivas = {};
        if (cods.length) { var pr = await supabaseClient.from('productos').select('codigo,iva_tasa').in('codigo', cods); ((pr && pr.data) || []).forEach(function (p) { ivas[p.codigo] = p.iva_tasa == null ? 16 : p.iva_tasa; }); }
        var cli = null;
        if (v.cliente_rif) { var cr = await supabaseClient.from('clientes').select('nombre,rif,direccion,telefono').eq('rif', v.cliente_rif).limit(1).maybeSingle(); cli = cr && cr.data; }
        // Forma libre: número de control en orden (si aún no tiene)
        var control = v.numero_control || null, aviso = '';
        if (modo === 'forma_libre' && !control && !op.copia) {
            var ca = await supabaseClient.rpc('documento_control_asignar', { p_tipo: 'factura', p_numero: numero });
            if (ca.error) throw new Error(ca.error.message);
            if (!ca.data.ok) throw new Error(ca.data.error);
            control = ca.data.numero_control;
            if (ca.data.restantes != null && ca.data.restantes < 50) aviso = 'Quedan ' + ca.data.restantes + ' números de control. Pide formatos nuevos a la imprenta.';
        }
        var html = armarFactura({ N: N, v: v, items: items, ivas: ivas, cli: cli, control: control, copia: !!op.copia, modo: modo, titulo: 'FACTURA' });
        abrir(html, 'Factura ' + numero);
        return { control: control, aviso: aviso };
    }

    function armarFactura(x) {
        var N = x.N, F = N.F, v = x.v, ts = Number(v.tasa_bcv) || (v.total_usd ? Number(v.total_bs) / Number(v.total_usd) : 0);
        var T = desglose(x.items, x.ivas, N.ivaIncluido);
        var preimpreso = x.modo === 'forma_libre' && F.imprimir_control !== true;   // el papel ya trae número de control y datos de la imprenta
        var serie = v.serie || F.serie || '';
        var h = css(F.papel) + '<div class="doc">' + (x.copia ? '<div class="marca">COPIA</div>' : '');
        if (preimpreso && F.margen_superior_mm) h += '<div class="hueco" style="--hueco:' + Number(F.margen_superior_mm) + 'mm"></div>';
        // Emisor (art. 13 num. 5)
        h += '<div class="cab"><div class="emi">' + (N.logo && !preimpreso ? '<img src="' + esc(N.logo) + '" alt=""/>' : '') +
            '<b>' + esc(N.razon) + '</b>' + (N.comercial && N.comercial !== N.razon ? '<div>' + esc(N.comercial) + '</div>' : '') +
            '<div>RIF: ' + esc(N.rif) + '</div><div>Domicilio fiscal: ' + esc(N.direccion) + '</div>' + (N.telefono ? '<div>Tel.: ' + esc(N.telefono) + '</div>' : '') + '</div>' +
            '<div class="tit"><h1>' + x.titulo + '</h1>' +
            '<div>N.º ' + (serie ? 'Serie ' + esc(serie) + ' ' : '') + esc(v.numero) + '</div>' +
            (x.control && (!preimpreso || x.modo === 'digital') ? '<div>N.º de control: ' + esc(x.control) + '</div>' : '') +
            '<div>Fecha: ' + fecha8(v.created_at) + '</div>' + (x.modo === 'digital' ? '<div>Hora: ' + hora(v.created_at) + '</div>' : '') + '</div></div>';
        // Comprador (art. 13 num. 7)
        var cn = (x.cli && x.cli.nombre) || v.cliente_nombre || '', cr = v.cliente_rif || '';
        h += '<div class="caja g2"><div><b>Cliente:</b> ' + esc(cn || 'Sin nombre') + '</div><div><b>' + (/^[JGC]/i.test(cr) ? 'RIF' : 'RIF / C.I.') + ':</b> ' + esc(cr || '—') + '</div>' +
            '<div><b>Domicilio fiscal:</b> ' + esc((x.cli && x.cli.direccion) || '—') + '</div><div><b>Condición:</b> ' + (Number(v.dias_credito) > 0 ? 'Crédito ' + Number(v.dias_credito) + ' días' : 'Contado') + '</div></div>';
        // Detalle (art. 13 num. 8 y 9)
        h += '<table><thead><tr><th>Código</th><th>Descripción</th><th class="r">Cant.</th><th class="r">Precio unit. Bs</th><th class="r">Desc.</th><th class="r">Monto Bs</th></tr></thead><tbody>';
        x.items.forEach(function (d) {
            var cant = Number(d.cantidad) || 0, total = Number(d.total) || 0, pu = cant ? (Number(d.precio_unitario) || total / cant) : 0;
            var neto = N.ivaIncluido && d._tasa > 0 ? 1 / (1 + d._tasa / 100) : 1;
            h += '<tr><td>' + esc(d.producto_codigo || '') + '</td><td>' + esc(d.descripcion || '') + (d._tasa === 0 ? ' (E)' : '') + '</td><td class="r">' + q3(cant) + '</td>' +
                '<td class="r">' + n2(pu * neto * ts) + '</td><td class="r">' + (Number(d.descuento) ? q3(d.descuento) + ' %' : '') + '</td><td class="r">' + n2(total * neto * ts) + '</td></tr>';
        });
        h += '</tbody></table>';
        // Totales por alícuota (art. 13 num. 10, 11 y 12)
        h += '<table class="tot"><tbody>';
        if (T.exento) h += '<tr><td>Monto exento (E)</td><td class="r">Bs ' + n2(T.exento * ts) + '</td></tr>';
        Object.keys(T.bases).sort().forEach(function (k) {
            h += '<tr><td>Base imponible ' + (NOMBRE_ALICUOTA[k] || k + ' %') + '</td><td class="r">Bs ' + n2(T.bases[k] * ts) + '</td></tr>' +
                 '<tr><td>IVA ' + k + ' %</td><td class="r">Bs ' + n2(T.ivas[k] * ts) + '</td></tr>';
        });
        var totalBs = Number(v.total_bs) || (Number(v.total_usd) || 0) * ts;
        h += '<tr class="g"><td>TOTAL A PAGAR</td><td class="r">Bs ' + n2(totalBs) + '</td></tr>';
        if (Number(v.igtf_bs) > 0 || Number(v.igtf_usd) > 0) h += '<tr><td>IGTF 3 % (pago en divisas)</td><td class="r">Bs ' + n2(Number(v.igtf_bs) || Number(v.igtf_usd) * ts) + '</td></tr>';
        h += '</tbody></table>';
        // Moneda extranjera (art. 13 num. 14)
        if (N.moneda === 'USD' && ts > 0) {
            h += '<div class="div">Operación pactada en divisas: <b>US$ ' + n2(v.total_usd) + '</b> · Tipo de cambio BCV: <b>Bs ' + n2(ts) + ' por US$</b> · Equivalente: <b>Bs ' + n2(totalBs) + '</b></div>';
        }
        // Pie: imprenta (art. 13 num. 15 y 16) y leyendas
        h += '<div class="pie">';
        if (x.modo === 'digital') {
            h += 'Imprenta digital: ' + esc(F.imprenta_nombre || '—') + ' · RIF ' + esc(F.imprenta_rif || '—') + ' · Providencia ' + esc(F.imprenta_providencia || '—') +
                (F.control_desde ? ' · Números de control asignados desde el N.º ' + esc(F.control_desde) + ' hasta el N.º ' + esc(F.control_hasta || '') : '') +
                '<br/>Documento emitido conforme a la Providencia Administrativa SNAT/2024/000102.';
        } else if (!preimpreso && x.modo === 'forma_libre') {
            h += 'Imprenta: ' + esc(F.imprenta_nombre || '—') + ' · RIF ' + esc(F.imprenta_rif || '—') + ' · Providencia ' + esc(F.imprenta_providencia || '—') +
                (F.control_desde ? ' · Control desde el N.º ' + esc(F.control_desde) + ' hasta el N.º ' + esc(F.control_hasta || '') : '');
        }
        if (x.modo !== 'forma_libre' && x.modo !== 'digital') h += 'Documento no fiscal: la factura legal la emite la máquina fiscal.';
        h += '</div>';
        if (x.copia) h += '<div class="leyenda">COPIA — SIN DERECHO A CRÉDITO FISCAL</div>';
        return h + '</div>';
    }

    // ---------- Nota de crédito (forma libre / digital) ----------
    async function notaCredito(numero, op) {
        op = op || {};
        var N = await negocio(), F = N.F, modo = F.modo || 'fiscal';
        var r = await supabaseClient.from('notas_credito').select('*').eq('numero', numero).maybeSingle();
        if (r.error || !r.data) throw new Error('No se encontró la nota de crédito ' + numero);
        var nc = r.data;
        var fr = await supabaseClient.from('ventas').select('numero,created_at,numero_control,tasa_bcv,dias_credito').eq('id', nc.venta_id).maybeSingle();
        var fac = (fr && fr.data) || {};
        var dr = await supabaseClient.from('notas_credito_detalle').select('*').eq('nota_id', nc.id);
        var items = (dr && dr.data) || [];
        var ivas = {}, cods = items.map(function (d) { return d.producto_codigo; });
        if (cods.length) { var pr = await supabaseClient.from('productos').select('codigo,iva_tasa').in('codigo', cods); ((pr && pr.data) || []).forEach(function (p) { ivas[p.codigo] = p.iva_tasa == null ? 16 : p.iva_tasa; }); }
        var control = nc.numero_control || null;
        if (modo === 'forma_libre' && !control && !op.copia) {
            var ca = await supabaseClient.rpc('documento_control_asignar', { p_tipo: 'nota_credito', p_numero: numero });
            if (ca.error) throw new Error(ca.error.message);
            control = ca.data && ca.data.numero_control;
        }
        var ts = Number(fac.tasa_bcv) || (nc.total_usd ? Number(nc.total_bs) / Number(nc.total_usd) : 0);
        var v = { numero: nc.numero, created_at: nc.created_at, cliente_nombre: nc.cliente_nombre, cliente_rif: nc.cliente_rif, tasa_bcv: ts, total_usd: nc.total_usd, total_bs: nc.total_bs };
        var html = armarFactura({ N: N, v: v, items: items, ivas: ivas, cli: null, control: control, copia: !!op.copia, modo: modo, titulo: 'NOTA DE CRÉDITO' });
        // Referencia a la factura afectada (art. 23: fecha, número y monto)
        html = html.replace('<table>', '<div class="caja"><b>Factura afectada:</b> ' + esc(fac.numero || nc.venta_numero || '') + (fac.numero_control ? ' · Control ' + esc(fac.numero_control) : '') +
            (fac.created_at ? ' · Fecha ' + fecha8(fac.created_at) : '') + (nc.motivo ? ' · Motivo: ' + esc(nc.motivo) : '') + '</div><table>');
        abrir(html, 'Nota de crédito ' + numero);
        return { control: control };
    }

    // ---------- Nota de débito ----------
    async function notaDebito(numero, op) {
        op = op || {};
        var N = await negocio(), F = N.F, modo = F.modo || 'fiscal';
        var r = await supabaseClient.from('notas_debito').select('*').eq('numero', numero).maybeSingle();
        if (r.error || !r.data) throw new Error('No se encontró la nota de débito ' + numero);
        var d = r.data, control = d.numero_control;
        if (modo === 'forma_libre' && !control && !op.copia) {
            var ca = await supabaseClient.rpc('documento_control_asignar', { p_tipo: 'nota_debito', p_numero: numero });
            if (ca.error) throw new Error(ca.error.message);
            control = ca.data && ca.data.numero_control;
        }
        var ts = Number(d.tasa_bcv) || 0;
        var h = css(F.papel) + '<div class="doc">' + (op.copia ? '<div class="marca">COPIA</div>' : '') +
            '<div class="cab"><div class="emi"><b>' + esc(N.razon) + '</b><div>RIF: ' + esc(N.rif) + '</div><div>Domicilio fiscal: ' + esc(N.direccion) + '</div></div>' +
            '<div class="tit"><h1>NOTA DE DÉBITO</h1><div>N.º ' + esc(d.numero) + '</div>' + (control && (modo !== 'forma_libre' || F.imprimir_control) ? '<div>N.º de control: ' + esc(control) + '</div>' : '') +
            '<div>Fecha: ' + fecha8(d.fecha) + '</div></div></div>' +
            '<div class="caja g2"><div><b>Cliente:</b> ' + esc(d.cliente_nombre || '') + '</div><div><b>RIF / C.I.:</b> ' + esc(d.cliente_rif || '—') + '</div>' +
            '<div><b>Factura afectada:</b> ' + esc(d.factura_numero) + (d.factura_control ? ' · Control ' + esc(d.factura_control) : '') + '</div><div><b>Fecha de la factura:</b> ' + (d.factura_fecha ? fecha8(d.factura_fecha) : '—') + '</div></div>' +
            '<table><thead><tr><th>Concepto</th><th class="r">Monto Bs</th></tr></thead><tbody><tr><td>' + esc(d.motivo) + (Number(d.iva_pct) === 0 ? ' (E)' : '') + '</td><td class="r">' + n2(d.subtotal_usd * ts) + '</td></tr></tbody></table>' +
            '<table class="tot"><tbody>' + (Number(d.iva_pct) === 0 ? '<tr><td>Monto exento (E)</td><td class="r">Bs ' + n2(d.subtotal_usd * ts) + '</td></tr>' :
                '<tr><td>Base imponible ' + (NOMBRE_ALICUOTA[Number(d.iva_pct)] || d.iva_pct + ' %') + '</td><td class="r">Bs ' + n2(d.subtotal_usd * ts) + '</td></tr><tr><td>IVA ' + Number(d.iva_pct) + ' %</td><td class="r">Bs ' + n2(d.iva_usd * ts) + '</td></tr>') +
            '<tr class="g"><td>TOTAL</td><td class="r">Bs ' + n2(d.total_bs) + '</td></tr></tbody></table>' +
            (N.moneda === 'USD' && ts ? '<div class="div">Monto en divisas: <b>US$ ' + n2(d.total_usd) + '</b> · Tipo de cambio BCV: <b>Bs ' + n2(ts) + ' por US$</b></div>' : '') +
            (modo === 'digital' ? '<div class="pie">Documento emitido conforme a la Providencia Administrativa SNAT/2024/000102.</div>' : '') +
            (op.copia ? '<div class="leyenda">COPIA — SIN DERECHO A CRÉDITO FISCAL</div>' : '') + '</div>';
        abrir(h, 'Nota de débito ' + numero);
        return { control: control };
    }

    // ---------- Guía de despacho (traslado entre tiendas, sin venta) ----------
    async function guia(transferenciaId) {
        var N = await negocio(), F = N.F;
        var tr = await supabaseClient.from('transferencias').select('*').eq('id', transferenciaId).maybeSingle();
        if (tr.error || !tr.data) throw new Error('No se encontró la transferencia');
        var t = tr.data;
        var it = await supabaseClient.from('transferencia_items').select('*').eq('transferencia_id', transferenciaId);
        var items = (it && it.data) || [];
        var h = css(F.papel) + '<div class="doc"><div class="cab"><div class="emi"><b>' + esc(N.razon) + '</b><div>RIF: ' + esc(N.rif) + '</div><div>Domicilio fiscal: ' + esc(N.direccion) + '</div></div>' +
            '<div class="tit"><h1>GUÍA DE DESPACHO</h1><div>N.º ' + esc(t.numero || '') + '</div><div>Fecha: ' + fecha8(t.created_at) + '</div></div></div>' +
            '<div class="caja g2"><div><b>Origen:</b> ' + esc(t.origen_nombre || '') + '</div><div><b>Destino:</b> ' + esc(t.destino_nombre || '') + '</div>' +
            '<div><b>Receptor:</b> ' + esc(N.razon) + ' · RIF ' + esc(N.rif) + '</div><div><b>Motivo del traslado:</b> traslado de mercancía entre tiendas de la misma empresa (no es una venta)</div></div>' +
            '<table><thead><tr><th>Código</th><th>Descripción</th><th class="r">Cantidad</th></tr></thead><tbody>' +
            items.map(function (i) { return '<tr><td>' + esc(i.producto_codigo) + '</td><td>' + esc(i.descripcion || '') + '</td><td class="r">' + q3(i.cantidad) + '</td></tr>'; }).join('') +
            '</tbody></table>' + (t.notas ? '<div class="pie">Notas: ' + esc(t.notas) + '</div>' : '') +
            '<div class="leyenda">SIN DERECHO A CRÉDITO FISCAL</div>' +
            '<div class="g2" style="margin-top:28px"><div style="border-top:1px solid #333;padding-top:4px">Despachado por</div><div style="border-top:1px solid #333;padding-top:4px">Recibido por</div></div></div>';
        abrir(h, 'Guía de despacho ' + (t.numero || ''));
    }

    window.RefDocs = { factura: factura, notaCredito: notaCredito, notaDebito: notaDebito, guia: guia, _armarFactura: armarFactura, _desglose: desglose };
})();
