/* REFRIMAR POS — cobro, emisión, impresión, facturas, notas de crédito, caja, dispositivos y ajustes */
(function () {
'use strict';
var P = window.__POS; if (!P) return;
var S = P.S, H = P.h, $ = H.$, esc = H.esc, f2 = H.f2, bs = H.bs, usd = H.usd, num = H.num, r2 = H.r2, cant = H.cant, toast = P.toast, modal = P.modal;
var CASA = H.CASA;

/* ============================================================
   COBRO (Resumen de compra + Métodos de pago)
   ============================================================ */
var METODO = 'efectivo';
// IGTF 3 % sobre lo pagado en divisas (Configuración → Tipo de negocio). Apagado por defecto.
var IGTF_TASA = 0.03;
function opcionesNegocio() { try { return JSON.parse(localStorage.getItem('refrimar_opciones_negocio') || '{}') || {}; } catch (e) { return {}; } }
function igtfActivo() { return opcionesNegocio().igtf === true; }
// Métodos de pago que acepta el negocio (Configuración → Primeros pasos): solo esos se ven en la caja
function aplicarMetodosPago() {
    var l = opcionesNegocio().metodos_pago;
    if (!Array.isArray(l) || !l.length) return;
    var tabs = document.querySelectorAll('#p-tabs [data-p]'), primero = null;
    tabs.forEach(function (b) { var ok = l.indexOf(b.dataset.p) >= 0; b.style.display = ok ? '' : 'none'; if (ok && !primero) primero = b; });
    if (primero && l.indexOf(METODO) < 0) { METODO = primero.dataset.p; tabs.forEach(function (x) { x.classList.toggle('on', x === primero); }); }
}
function esDivisa(p) { return p.moneda === 'USD' && p.metodo !== 'credito'; }
// Refresca las opciones del negocio desde la base de datos (sin bloquear el cobro)
(function () { try { supabaseClient.from('configuracion').select('opciones').limit(1).maybeSingle().then(function (r) { if (r && r.data && r.data.opciones) { try { localStorage.setItem('refrimar_opciones_negocio', JSON.stringify(r.data.opciones)); } catch (e) {} try { aplicarMetodosPago(); } catch (e) {} } }, function () {}); } catch (e) {} })();
P.irCobro = function () { S.pagos = S.pagos || []; P.ir('cobro'); $('c-titulo').textContent = S.borradorId ? 'Factura (borrador)' : 'Factura'; pintarResumen(); pintarForm(); pintarPagos(); };
function sumaPagos() {
    var t = P.totales(), pagado = 0, credito = 0, divisas = 0;
    S.pagos.forEach(function (p) { if (p.metodo === 'credito') credito += p.monto_usd; else pagado += p.monto_usd; if (esDivisa(p)) divisas += p.monto_usd; });
    // La base del IGTF es lo pagado en divisas, hasta el total de la factura
    var igtf = igtfActivo() ? r2(Math.min(divisas, t.totalUsd) * IGTF_TASA) : 0;
    var resto = r2(t.totalUsd + igtf - pagado - credito);
    return { t: t, pagado: r2(pagado), credito: r2(credito), igtf: igtf, divisas: r2(divisas), cobrar: r2(t.totalUsd + igtf), restante: resto > 0.004 ? resto : 0, exceso: resto < -0.004 ? -resto : 0 };
}
// Monto sugerido si el resto se paga en divisas (incluye el IGTF que genera ese pago)
function restoEnDivisas(s) {
    if (!igtfActivo() || !s.restante) return s.restante;
    var hueco = Math.max(0, s.t.totalUsd - s.divisas);
    return r2(s.restante + Math.min(s.restante, hueco) * IGTF_TASA);
}
function enMon(u) { return S.monUSD ? usd(u) : bs(u * S.tasa); }
function pintarResumen() {
    var c = S.cliente;
    $('r-cli').innerHTML = '<div style="font-size:16px;text-transform:uppercase">' + esc(c ? c.nombre : 'Consumidor final') + '</div>' + (c && c.rif ? '<div style="color:var(--tx3)">' + esc(c.rif) + '</div>' : '');
    $('r-items').innerHTML = S.carro.map(function (i) {
        var lt = P.lineaTotal(i), iv = P.lineaIva(i);
        return '<div class="rs-it"><span class="q">' + cant(i.cantidad) + '</span><div class="n">' + esc(i.descripcion) + '<small>' + cant(i.cantidad) + ' ' + (i.unidad === 'uds' ? (i.cantidad === 1 ? 'unidad' : 'unidades') : esc(i.unidad)) + (i.descuento ? ' · −' + f2(i.descuento, 1) + '%' : '') + '</small></div>' +
            '<div class="m">' + enMon(lt) + '<small>' + (Number(i.iva) ? 'IVA (' + f2(i.iva, 0) + '%): ' + enMon(iv) : 'Exento') + '</small></div></div>';
    }).join('');
    var s = sumaPagos();
    $('r-tot').innerHTML = '<div class="big"><span>Total</span><b>' + enMon(s.t.totalUsd) + '</b></div>' +
        '<div><span>Descuento</span><span>' + enMon(s.t.descuento) + '</span></div>' +
        '<div><span>Impuesto (IVA)</span><span>' + enMon(S.ivaIncluido ? S.carro.reduce(function (a, i) { return a + P.lineaIva(i); }, 0) : s.t.iva) + '</span></div>' +
        (s.igtf ? '<div><span>IGTF 3 % (pago en divisas)</span><span>' + enMon(s.igtf) + '</span></div><div><span>Total a cobrar</span><span>' + enMon(s.cobrar) + '</span></div>' : '') +
        '<div><span>Recibido</span><span>' + enMon(s.pagado + s.credito) + '</span></div>' +
        (s.exceso ? '<div class="vuel big"><span>Vuelto</span><b>' + enMon(s.exceso) + '</b></div>' : '<div class="rest big"><span>Restante</span><b>' + enMon(s.restante) + '</b></div>') +
        '<div style="font-size:13px;color:var(--tx3)"><span>Tasa de cambio</span><span>' + f2(S.tasa, 2) + ' Bs/$</span></div>';
    $('p-emitir').disabled = s.restante > 0 || !S.pagos.length;
}
$('r-mon').addEventListener('click', function () { S.monUSD = !S.monUSD; this.classList.toggle('on', S.monUSD); pintarResumen(); pintarPagos(); });
document.querySelectorAll('#p-tabs [data-p]').forEach(function (b) { b.addEventListener('click', function () { METODO = b.dataset.p; document.querySelectorAll('#p-tabs [data-p]').forEach(function (x) { x.classList.toggle('on', x === b); }); pintarForm(); }); });
function bancosOpts() { return '<option value="">Banco</option>' + H.BANCOS.map(function (b) { return '<option>' + esc(b) + '</option>'; }).join(''); }
function pintarForm() {
    try { aplicarMetodosPago(); } catch (e) {}
    var s = sumaPagos(), restBs = r2(s.restante * S.tasa), restUsd = restoEnDivisas(s), h = '';
    var monto = function (val, ph) { return '<div class="campo"><span>Monto</span><input id="pf-monto" class="in" inputmode="decimal" value="' + (val ? f2(val) : '') + '" placeholder="' + (ph || '0,00') + '"/></div>'; };
    var agregar = '<button type="button" class="btn" id="pf-add" style="height:44px">Agregar</button>';
    if (METODO === 'efectivo') h = '<div class="mp-form"><div class="campo"><span>Moneda</span><select id="pf-mon" class="in"><option value="VES">Bolívar Venezolano</option><option value="USD">US Dollar</option></select></div>' + monto(restBs) + agregar + '</div>';
    else if (METODO === 'pago_movil') h = '<div class="mp-form">' + monto(restBs, 'Monto en Bs') + '<div class="campo"><span>Banco</span><select id="pf-banco" class="in">' + bancosOpts() + '</select></div><div class="campo"><span>Referencia</span><input id="pf-ref" class="in" inputmode="numeric" placeholder="Últimos dígitos"/></div>' + agregar + '</div>';
    else if (METODO === 'punto') h = '<div class="mp-form">' + monto(restBs, 'Monto en Bs') + '<div class="campo"><span>Referencia / lote (opcional)</span><input id="pf-ref" class="in"/></div>' + agregar + '</div>';
    else if (METODO === 'transferencia') h = '<div class="mp-form"><div class="campo"><span>Moneda</span><select id="pf-mon" class="in"><option value="VES">Bolívares</option><option value="USD">Dólares (Zelle)</option></select></div>' + monto(restBs) + '<div class="campo"><span>Banco</span><select id="pf-banco" class="in">' + bancosOpts() + '</select></div><div class="campo"><span>Referencia</span><input id="pf-ref" class="in"/></div>' + agregar + '</div>';
    else if (METODO === 'credito') {
        var c = S.cliente;
        if (!c || !c.existe) h = window.refEstado('pagos', 'Crédito no disponible', 'Para vender a crédito busca o registra al cliente con su documento en la factura.', '', 'xs');
        else if (!H.can('ver_mi_caja') && !H.can('facturar')) h = '';
        else h = '<div style="font-size:14px;color:var(--tx2);margin-bottom:10px">' + esc(c.nombre) + ' · Saldo pendiente: <b>' + usd(c.saldo || 0) + '</b>' + (c.limite ? ' · Límite: <b>' + usd(c.limite) + '</b> · Disponible: <b>' + usd(Math.max(0, c.limite - (c.saldo || 0))) + '</b>' : ' · Sin límite') + '</div>' +
            '<div class="mp-form"><div class="campo"><span>Monto a crédito (USD)</span><input id="pf-monto" class="in" inputmode="decimal" value="' + (s.restante ? f2(s.restante) : '') + '"/></div>' + agregar + '</div>';
    } else if (METODO === 'otros') h = '<div class="mp-form"><div class="campo"><span>Método</span><select id="pf-tipo" class="in"><option value="zelle">Zelle</option><option value="binance">Binance / USDT</option><option value="otro">Otro (USD)</option></select></div><div class="campo"><span>Monto (USD)</span><input id="pf-monto" class="in" inputmode="decimal" value="' + (restUsd ? f2(restUsd) : '') + '"/></div><div class="campo"><span>Referencia</span><input id="pf-ref" class="in"/></div>' + agregar + '</div>';
    $('p-form').innerHTML = h;
    var mon = $('pf-mon');
    if (mon) mon.addEventListener('change', function () { var x = sumaPagos(); $('pf-monto').value = x.restante ? f2(this.value === 'USD' ? restoEnDivisas(x) : x.restante * S.tasa) : ''; });
    var add = $('pf-add'); if (add) add.addEventListener('click', agregarPago);
    var mi = $('pf-monto'); if (mi) mi.addEventListener('keydown', function (e) { if (e.key === 'Enter') agregarPago(); });
}
function agregarPago() {
    var monto = num($('pf-monto') && $('pf-monto').value); if (!(monto > 0)) return toast('Escribe el monto', '', 'warning');
    var p = { metodo: METODO, moneda: 'VES' };
    if (METODO === 'efectivo') { p.moneda = $('pf-mon').value; p.metodo = p.moneda === 'USD' ? 'divisa' : 'efectivo'; }
    else if (METODO === 'transferencia') { p.moneda = $('pf-mon').value; if (p.moneda === 'USD') p.metodo = 'zelle'; }
    else if (METODO === 'credito') p.moneda = 'USD';
    else if (METODO === 'otros') { p.moneda = 'USD'; p.metodo = $('pf-tipo').value; }
    if ($('pf-banco')) p.banco = $('pf-banco').value;
    if ($('pf-ref')) p.referencia = $('pf-ref').value.trim();
    if (METODO === 'pago_movil' && !p.referencia) return toast('Escribe la referencia del pago móvil', '', 'warning');
    p.monto = r2(monto);
    p.monto_usd = p.moneda === 'USD' ? p.monto : r2(p.monto / S.tasa);
    p.monto_bs = p.moneda === 'VES' ? p.monto : r2(p.monto * S.tasa);
    if (p.metodo === 'credito') {
        var c = S.cliente, s = sumaPagos();
        if (p.monto_usd > s.restante + 0.01) return toast('El crédito no puede ser mayor al restante', usd(s.restante), 'warning');
        if (c.limite && (c.saldo || 0) + s.credito + p.monto_usd > c.limite + 0.001) return toast('Excede el límite de crédito', 'Disponible: ' + usd(Math.max(0, c.limite - (c.saldo || 0) - s.credito)), 'error');
    }
    S.pagos.push(p); H.beep('ok');
    pintarPagos(); pintarResumen(); pintarForm();
}
function pintarPagos() {
    $('p-lista').innerHTML = S.pagos.length ? S.pagos.map(function (p, i) {
        return '<div class="pg"><span class="material-symbols-outlined">' + (H.METODO_ICONO[p.metodo] || 'payments') + '</span><div class="n">' + esc(H.METODO_NOMBRE[p.metodo] || p.metodo) + ' · ' + (p.moneda === 'USD' ? 'US Dollar' : 'Bolívar') + '<small>' + esc([p.banco, p.referencia ? 'Ref. ' + p.referencia : ''].filter(Boolean).join(' · ')) + '</small></div>' +
            '<div class="m">' + (p.moneda === 'USD' ? usd(p.monto) : bs(p.monto)) + '<small>' + (p.moneda === 'USD' ? bs(p.monto_bs) : usd(p.monto_usd)) + '</small></div><button type="button" class="dots" data-q="' + i + '" title="Quitar"><span class="material-symbols-outlined">close</span></button></div>';
    }).join('') : '<div style="color:var(--tx3);font-size:14px;padding:6px 2px">Aún no hay pagos. Elige el método, escribe el monto y presiona Agregar.</div>';
}
$('p-lista').addEventListener('click', function (e) { var b = e.target.closest('[data-q]'); if (!b) return; S.pagos.splice(Number(b.dataset.q), 1); pintarPagos(); pintarResumen(); pintarForm(); });
$('p-volver').addEventListener('click', function () { P.ir('factura'); });
$('p-emitir').addEventListener('click', function () {
    var s = sumaPagos();
    if (s.restante > 0) return toast('Falta cobrar ' + bs(s.restante * S.tasa), '', 'warning');
    if (s.exceso > 0.004) return detalleVuelto(s.exceso);
    S.vuelto = []; emitir();
});

// ---------- Detalle de vuelto (multimoneda) ----------
function detalleVuelto(excesoUsd) {
    var totBs = r2(excesoUsd * S.tasa);
    var filas = [['efectivo', 'USD', 'Efectivo', 'US Dollar'], ['efectivo', 'VES', 'Efectivo', 'Bolívar Venezolano'], ['pago_movil', 'VES', 'Pago móvil', 'Bolívar Venezolano']];
    var m = modal({ titulo: 'Detalle de vuelto', ancho: true, texto: 'Aquí puedes verificar el cambio entregado al cliente. Gestiona el vuelto fácilmente, incluso en múltiples monedas.',
        cuerpo: '<div style="border-top:1px solid var(--ln);border-bottom:1px solid var(--ln);padding:10px 0;margin-bottom:10px">' +
            '<div style="display:flex;justify-content:space-between;font-size:16px"><span>Vuelto total</span><b style="font-weight:500">' + bs(totBs) + '</b></div>' +
            '<div style="display:flex;justify-content:space-between;font-size:13px;color:var(--tx2)"><span>Total devuelto</span><span id="vt-dev">0,00 Bs</span></div>' +
            '<div style="display:flex;justify-content:space-between;font-size:16px;margin-top:8px"><span>Restante</span><b style="font-weight:500" id="vt-rest">' + bs(totBs) + '</b></div>' +
            '<div style="text-align:right;font-size:13px;color:var(--tx3)" id="vt-rest-u">' + usd(excesoUsd) + '</div></div>' +
            '<div style="font-size:14px;color:var(--tx2);margin-bottom:8px">Métodos de pago</div>' +
            filas.map(function (f, i) { return '<div style="display:grid;grid-template-columns:1fr 1.3fr 1.2fr;gap:10px;align-items:center;margin-bottom:10px"><span>' + f[2] + '</span><span>' + f[3] + '</span><input class="in" data-v="' + i + '" inputmode="decimal" placeholder="Monto"/></div>'; }).join('') +
            '<button type="button" id="vt-sin" style="color:var(--az-t);font-size:13px;margin-top:4px">El cliente no quiere vuelto (queda en caja)</button>',
        pie: '<button type="button" class="btn out" data-c>Cancelar</button><button type="button" class="btn" data-ok disabled>Confirmar</button>' });
    var inps = m.el.querySelectorAll('[data-v]');
    inps[1].value = f2(totBs);
    function calc() {
        var dev = 0;
        inps.forEach(function (inp) { var f = filas[inp.dataset.v], v = num(inp.value); dev += f[1] === 'USD' ? v * S.tasa : v; });
        var rest = r2(totBs - dev);
        m.q('#vt-dev').textContent = bs(dev); m.q('#vt-rest').textContent = bs(rest); m.q('#vt-rest-u').textContent = usd(rest / S.tasa);
        m.q('#vt-rest').style.color = Math.abs(rest) < 0.01 ? 'var(--ok)' : 'var(--err)';
        m.q('[data-ok]').disabled = Math.abs(rest) >= 0.01;
    }
    inps.forEach(function (i) { i.addEventListener('input', calc); });
    calc();
    m.q('[data-c]').addEventListener('click', m.cerrar);
    m.q('#vt-sin').addEventListener('click', function () { S.vuelto = []; m.cerrar(); emitir(); });
    m.q('[data-ok]').addEventListener('click', function () {
        S.vuelto = [];
        inps.forEach(function (inp) {
            var f = filas[inp.dataset.v], v = r2(num(inp.value)); if (!(v > 0)) return;
            var metodo = f[0] === 'efectivo' ? (f[1] === 'USD' ? 'divisa' : 'efectivo') : f[0];
            S.vuelto.push({ metodo: metodo, moneda: f[1], monto: v, monto_usd: f[1] === 'USD' ? v : r2(v / S.tasa), monto_bs: f[1] === 'VES' ? v : r2(v * S.tasa) });
        });
        m.cerrar(); emitir();
    });
}

/* ============================================================
   EMITIR FACTURA
   ============================================================ */
var EMITIENDO = false;
function ivaIncl() { return r2(S.carro.reduce(function (a, i) { return a + P.lineaIva(i); }, 0)); }
async function emitir() {
    if (EMITIENDO) return; EMITIENDO = true;
    var btn = $('p-emitir'); btn.disabled = true; btn.innerHTML = 'Emitiendo…';
    try {
        var t = P.totales(), c = S.cliente || {}, sp = sumaPagos();
        // IGTF: se reparte entre los pagos en divisas (la base de datos lo suma en ventas.igtf_usd)
        var pagosV = S.pagos.map(function (p) { return Object.assign({}, p); });
        if (sp.igtf > 0 && sp.divisas > 0) {
            var asignado = 0, ult = null;
            pagosV.forEach(function (p) { if (esDivisa(p)) { p.igtf_usd = r2(sp.igtf * p.monto_usd / sp.divisas); asignado = r2(asignado + p.igtf_usd); ult = p; } });
            if (ult) ult.igtf_usd = r2(ult.igtf_usd + sp.igtf - asignado);
        }
        var venta = {
            numero: 'F-' + Date.now().toString().slice(-7),
            cliente: { nombre: c.nombre || 'Consumidor Final', rif: c.rif || null, email: c.email || null },
            subtotal: S.ivaIncluido ? r2(t.totalUsd - ivaIncl()) : r2(t.subtotal - t.descuento), iva: S.ivaIncluido ? ivaIncl() : t.iva, total_usd: t.totalUsd, total_bs: t.totalBs, tasa: S.tasa,
            sucursal_id: S.tienda.id, sucursal_nombre: S.tienda.nombre, usuario: S.user.nombre, turno_id: S.turno ? S.turno.id : null, terminal: H.ls(H.K_TERM),
            estado_fiscal: S.cfg.modo === 'fiscal' ? 'pendiente' : null,
            items: S.carro.map(function (i) { var bruto = i.precio * i.cantidad, d = bruto * (i.descuento || 0) / 100; return { codigo: i.codigo, descripcion: i.descripcion, cantidad: i.cantidad, precio: i.precio, costo: i.costo || 0, descuento: i.descuento || 0, total: r2(bruto - d), iva: i.iva, unidad: i.unidad }; }),
            pagos: pagosV, vuelto: (S.vuelto || []).slice(),
            igtf_usd: sp.igtf || 0, igtf_bs: sp.igtf ? r2(sp.igtf * S.tasa) : 0
        };
        var guardada = await guardarVenta(venta);
        if (!guardada) return;
        venta.fecha = new Date().toISOString(); venta.local = guardada === 'local';
        H.ls(H.K_ULT, venta);
        // Descuenta el stock en pantalla
        venta.items.forEach(function (i) { var p = S.porCodigo[String(i.codigo).toLowerCase()]; if (p && !p.servicio) p.stock = r2(p.stock - i.cantidad); });
        if (S.borradorId) supabaseClient.rpc('pos_borrador_eliminar', { p_id: S.borradorId }).then(function () {}, function () {});
        var hayEfectivo = venta.pagos.some(function (p) { return p.metodo === 'efectivo' || p.metodo === 'divisa'; });
        P.limpiarFactura(); P.ir('factura'); P.pintarSync();
        toast('¡Operación realizada con éxito!', 'Factura ' + venta.numero + ' generada correctamente' + (venta.local ? ' (guardada sin internet, se sincroniza sola)' : ''));
        if (window.refExito) window.refExito('Factura creada', venta.numero, 1100);
        await imprimirDoc('factura', venta);
        if (hayEfectivo && S.cfg.gaveta) abrirGaveta(true);
        P.pintarCarro();
    } finally {
        EMITIENDO = false; btn.innerHTML = '<span class="material-symbols-outlined">receipt_long</span>Emitir factura';
        if (S.vista === 'cobro') pintarResumen();
    }
}
async function guardarVenta(venta) {
    var payload = { p_venta: venta };
    if (!navigator.onLine && window.refEncolarVenta) { window.refEncolarVenta(payload); return 'local'; }
    var r = await supabaseClient.rpc('pos_facturar', payload);
    if (r.error && H.faltaFn(r.error)) r = await registrarVentaClasica(venta);
    if (r.error) {
        if (window.refEsErrorDeRed && window.refEsErrorDeRed(r.error) && window.refEncolarVenta) { window.refEncolarVenta(payload); return 'local'; }
        var m = H.errMsg(r.error);
        toast('No se pudo emitir la factura', /l[ií]mite de cr[eé]dito/i.test(m) ? m : m, 'error');
        return false;
    }
    return 'ok';
}
// Respaldo si aún no se corrió la migración nueva: usa registrar_venta (un método, o mixto efectivo + otro)
async function registrarVentaClasica(v) {
    var pg = v.pagos, metodo, args = {};
    if (pg.length === 1) metodo = pg[0].metodo;
    else if (pg.length === 2 && pg.some(function (p) { return p.metodo === 'efectivo' || p.metodo === 'divisa'; })) {
        var ef = pg.find(function (p) { return p.metodo === 'efectivo' || p.metodo === 'divisa'; }), otro = pg.find(function (p) { return p !== ef; });
        metodo = 'mixto'; args = { p_metodo_2: otro.metodo, p_efectivo_usd: ef.monto_usd, p_efectivo_bs: ef.monto_bs };
    } else return { error: { message: 'Para cobrar con más de dos métodos corre en Supabase el archivo supabase-migration-pos-precios.sql' } };
    var pm = pg.find(function (p) { return p.metodo === 'pago_movil'; });
    return supabaseClient.rpc('registrar_venta', Object.assign({ p_numero: v.numero, p_cliente_nombre: v.cliente.nombre, p_cliente_rif: v.cliente.rif, p_subtotal: v.subtotal, p_iva: v.iva, p_total_usd: v.total_usd,
        p_tasa_bcv: v.tasa, p_total_bs: v.total_bs, p_metodo: metodo, p_sucursal_id: v.sucursal_id, p_sucursal_nombre: v.sucursal_nombre, p_usuario: v.usuario, p_items: v.items,
        p_pm_banco: pm ? pm.banco : null, p_pm_remitente: pm ? v.cliente.nombre : null, p_pm_referencia: pm ? pm.referencia : null }, args));
}

/* ============================================================
   IMPRESIÓN: fiscal, ticket térmico o navegador
   ============================================================ */
function linea(c, W) { var s = ''; for (var i = 0; i < W; i++) s += c; return s; }
function centro(s, W) { s = String(s); return s.length >= W ? s.slice(0, W) : linea(' ', Math.floor((W - s.length) / 2)) + s; }
function izqDer(a, b, W) { a = String(a); b = String(b); var n = W - b.length - 1; if (a.length > n) a = a.slice(0, n - 1) + '~'; return a + linea(' ', W - a.length - b.length) + b; }
function ticketTexto(tipo, d) {
    var W = Number(S.cfg.ancho) === 32 ? 32 : 42, N = S.negocio || {}, L = [];
    L.push(centro(N.nombre_negocio || 'COMERCIAL REFRIMAR', W));
    if (N.rif) L.push(centro('RIF: ' + N.rif, W));
    if (N.direccion) String(N.direccion).match(new RegExp('.{1,' + W + '}', 'g')).forEach(function (x) { L.push(centro(x.trim(), W)); });
    if (N.telefono) L.push(centro('Tel: ' + N.telefono, W));
    L.push(linea('-', W));
    // Sin máquina fiscal este papel NO es una factura legal: se llama comprobante (la factura la emite la máquina o el formato de imprenta)
    var noFiscal = S.cfg.modo !== 'fiscal' && tipo !== 'turno';
    L.push(centro(tipo === 'nc' ? (noFiscal ? 'COMPROBANTE DE DEVOLUCION' : 'NOTA DE CREDITO') : tipo === 'turno' ? 'CIERRE DE TURNO' : (noFiscal ? 'COMPROBANTE DE VENTA' : 'FACTURA'), W));
    if (noFiscal) L.push(centro('(Documento no fiscal)', W));
    L.push('N°: ' + d.numero + (d.factura ? '  Fact: ' + d.factura : ''));
    L.push('Fecha: ' + H.fecha(d.fecha || new Date().toISOString()) + ' ' + H.hora(d.fecha || new Date().toISOString()));
    if (tipo !== 'turno') { L.push('Cliente: ' + ((d.cliente && d.cliente.nombre) || 'Consumidor Final')); if (d.cliente && d.cliente.rif) L.push('RIF/CI: ' + d.cliente.rif); }
    L.push('Caja: ' + (H.ls(H.K_TERM) || '-') + '  Cajero: ' + (d.usuario || S.user.nombre));
    L.push('Tienda: ' + (d.sucursal_nombre || S.tienda.nombre));
    L.push(linea('-', W));
    if (d.items) d.items.forEach(function (i) {
        L.push(String(i.descripcion).slice(0, W));
        L.push(izqDer('  ' + cant(i.cantidad) + ' x ' + f2(i.precio * S.tasa) + (Number(i.iva) === 0 ? ' (E)' : ''), f2((i.total_bs != null ? i.total_bs : i.total * (d.tasa || S.tasa))), W));
    });
    if (d.lineas) d.lineas.forEach(function (x) { L.push(izqDer(x[0], x[1], W)); });
    L.push(linea('-', W));
    if (d.total_usd != null) {
        var ts = d.tasa || S.tasa;
        if (d.subtotal != null) L.push(izqDer('SUBTOTAL Bs', f2(d.subtotal * ts), W));
        if (d.iva) L.push(izqDer('IVA Bs', f2(d.iva * ts), W));
        L.push(izqDer('TOTAL Bs', f2(d.total_bs != null ? d.total_bs : d.total_usd * ts), W));
        L.push(izqDer('TOTAL USD', f2(d.total_usd), W));
        if (Number(d.igtf_usd) > 0) { L.push(izqDer('IGTF 3% Bs', f2(d.igtf_bs || d.igtf_usd * ts), W)); L.push(izqDer('TOTAL A PAGAR Bs', f2((d.total_bs != null ? d.total_bs : d.total_usd * ts) + (d.igtf_bs || d.igtf_usd * ts)), W)); }
        L.push(izqDer('Tasa BCV', f2(ts, 2), W));
    }
    if (d.pagos && d.pagos.length) { L.push(linea('-', W)); d.pagos.forEach(function (p) { L.push(izqDer((H.METODO_NOMBRE[p.metodo] || p.metodo) + ' ' + (p.moneda === 'USD' ? '$' : 'Bs'), f2(p.monto), W)); }); }
    if (d.vuelto && d.vuelto.length) d.vuelto.forEach(function (p) { L.push(izqDer('Vuelto ' + (H.METODO_NOMBRE[p.metodo] || p.metodo) + ' ' + (p.moneda === 'USD' ? '$' : 'Bs'), f2(p.monto), W)); });
    L.push(linea('-', W));
    L.push(centro(N.mensaje || '¡Gracias por su compra!', W));
    return L.join('\n');
}
function itemsFiscales(items, tasa) {
    return items.map(function (i) {
        var neto = (i.precio * i.cantidad * (1 - (i.descuento || 0) / 100)) / i.cantidad, iva = Number(i.iva) || 0;
        if (S.ivaIncluido) neto = neto / (1 + iva / 100);
        return { descripcion: String(i.descripcion).replace(/[^\x20-\x7EáéíóúÁÉÍÓÚñÑ]/g, '').slice(0, 40), precio: r2(neto * tasa), cantidad: i.cantidad, iva: iva };
    });
}
async function imprimirDoc(tipo, d) {
    // Forma libre (formato de imprenta con número de control): factura completa en carta o media carta
    var FN = opcionesNegocio().facturacion || {};
    if ((tipo === 'factura' || tipo === 'nc') && FN.modo === 'forma_libre' && S.cfg.modo !== 'fiscal' && window.RefDocs && !d.local) {
        try {
            var rd = tipo === 'nc' ? await window.RefDocs.notaCredito(d.numero) : await window.RefDocs.factura(d.numero);
            if (rd && rd.control) toast('Usa el formato con N.º de control ' + rd.control, rd.aviso || 'El número quedó registrado para el Libro de Ventas.', rd.aviso ? 'warning' : 'info');
            return true;
        } catch (e) { toast('No se pudo preparar la factura en forma libre', e.message || '', 'error'); }
    }
    if (S.cfg.modo === 'fiscal' && tipo !== 'turno') {
        var pagos = (d.pagos || []).map(function (p) { return { codigo: S.cfg.codigos[p.metodo] || '01', monto: r2(p.monto_bs != null ? p.monto_bs : p.monto_usd * (d.tasa || S.tasa)), metodo: p.metodo, divisa: p.moneda === 'USD', igtf: r2((p.igtf_usd || 0) * (d.tasa || S.tasa)) }; });
        var cuerpo = { documento: tipo === 'nc' ? 'nota_credito' : 'factura', numero_interno: d.numero, cajero: d.usuario || S.user.nombre,
            cliente: { rif: (d.cliente && d.cliente.rif) || '', nombre: (d.cliente && d.cliente.nombre) || 'CONSUMIDOR FINAL' },
            items: itemsFiscales(d.items || [], d.tasa || S.tasa), pagos: pagos, puerto: S.cfg.puerto,
            igtf: r2((Number(d.igtf_usd) || 0) * (d.tasa || S.tasa)),
            factura_afectada: d.factura_fiscal || null, factura_fecha: d.factura_fecha || null, factura_serial: d.factura_serial || null,
            // Operación pactada en divisas: monto en divisas y tipo de cambio en la factura (Providencia 0071, art. 14)
            comentarios: (opcionesNegocio().moneda_precios || 'USD') === 'USD' && Number(d.total_usd) > 0 ? ['TOTAL US$ ' + f2(d.total_usd) + ' TASA BCV ' + f2(d.tasa || S.tasa, 2)] : [] };
        var r = await P.puente('/fiscal/' + (tipo === 'nc' ? 'nota_credito' : 'factura'), cuerpo, 45000);
        if (r && r.ok) {
            var rr = await supabaseClient.rpc('pos_fiscal_registrar', { p_tipo: tipo === 'nc' ? 'nota_credito' : 'factura', p_numero: d.numero, p_numero_fiscal: r.numero_fiscal || null, p_serial: r.serial || null, p_estado: 'fiscalizada' });
            if (rr.error && !d.local) console.warn(rr.error);
            toast('Documento fiscal impreso', 'N° fiscal ' + (r.numero_fiscal || '-') + (r.serial ? ' · Serial ' + r.serial : ''), 'info');
            return true;
        }
        toast('La impresora fiscal no imprimió', ((r && (r.error || r.message)) || 'Sin respuesta') + '. El documento quedó guardado como pendiente: fiscalízalo desde Facturas.', 'error');
        return false;
    }
    var texto = ticketTexto(tipo, d);
    if (S.cfg.modo === 'ticket') {
        var t = await P.puente('/print', { text: texto, width: Number(S.cfg.ancho) === 32 ? 32 : 42 }, 5000);
        if (t && t.ok) return true;
        toast('No se pudo imprimir el ticket', (t && (t.error || t.message)) || 'Revisa la impresora', 'warning');
    }
    imprimirNavegador(texto);
    return true;
}
function imprimirNavegador(texto) {
    var f = document.createElement('iframe'); f.style.cssText = 'position:fixed;width:0;height:0;border:0;right:0;bottom:0';
    document.body.appendChild(f);
    f.contentDocument.write('<html><head><style>@page{margin:4mm}body{margin:0;font:12px/1.35 "Courier New",monospace;white-space:pre}</style></head><body>' + esc(texto) + '</body></html>');
    f.contentDocument.close();
    setTimeout(function () { try { f.contentWindow.focus(); f.contentWindow.print(); } catch (e) {} setTimeout(function () { f.remove(); }, 2000); }, 200);
}
async function abrirGaveta(silencioso) {
    var r = S.cfg.modo === 'fiscal' ? await P.puente('/fiscal/gaveta', { puerto: S.cfg.puerto }, 8000) : await P.puente('/drawer', {}, 4000);
    if (!silencioso) toast(r && r.ok ? 'Gaveta abierta' : 'No se pudo abrir la gaveta', r && !r.ok ? (r.error || r.message || '') : '', r && r.ok ? 'success' : 'warning');
}
P.imprimirDoc = imprimirDoc; P.abrirGaveta = abrirGaveta; P.ticketTexto = ticketTexto;

/* ============================================================
   FACTURAS Y BORRADORES
   ============================================================ */
var HIST = { tab: 'facturas', filas: [] };
document.querySelectorAll('#h-tabs [data-t]').forEach(function (b) { b.addEventListener('click', function () { HIST.tab = b.dataset.t; document.querySelectorAll('#h-tabs [data-t]').forEach(function (x) { x.classList.toggle('on', x === b); }); $('h-fil').style.display = HIST.tab === 'facturas' ? 'flex' : 'none'; P.cargarFacturas(); }); });
['h-tipo', 'h-fiscal', 'h-dias'].forEach(function (id) { $(id).addEventListener('change', function () { if (id === 'h-dias') P.cargarFacturas(); else pintarHist(); }); });
$('h-q').addEventListener('input', pintarHist);
function porTienda(q, col) { col = col || 'sucursal_id'; return S.tienda.id === CASA ? q.or(col + '.eq.' + CASA + ',' + col + '.is.null') : q.eq(col, S.tienda.id); }
P.cargarFacturas = async function () {
    var box = $('h-lista');
    box.innerHTML = window.refEstado('cargando', 'Cargando…', '', '', 'xs');
    if (HIST.tab === 'borradores') return cargarBorradores();
    var desde = new Date(Date.now() - Number($('h-dias').value) * 864e5); desde.setHours(0, 0, 0, 0);
    var rv = await porTienda(supabaseClient.from('ventas').select('*').gte('created_at', desde.toISOString())).order('created_at', { ascending: false }).limit(400);
    var rn = await porTienda(supabaseClient.from('notas_credito').select('*').gte('created_at', desde.toISOString())).order('created_at', { ascending: false }).limit(200);
    if (rv.error) { box.innerHTML = window.refEstado('error', 'No se pudieron cargar las facturas', H.errMsg(rv.error), '', 'sm'); return; }
    HIST.filas = (rv.data || []).map(function (v) { return Object.assign({ _t: 'factura' }, v); }).concat(((rn && rn.data) || []).map(function (n) { return Object.assign({ _t: 'nc' }, n); }));
    HIST.filas.sort(function (a, b) { return String(b.created_at).localeCompare(String(a.created_at)); });
    pintarHist();
};
function estadoFiscal(r) { return r.estado_fiscal === 'fiscalizada' ? 'Fiscalizada' : r.estado_fiscal === 'pendiente' ? 'Pendiente' : r.estado_fiscal === 'error' ? 'Error fiscal' : r.estado === 'anulada' ? 'Anulada' : 'No fiscal'; }
function pintarHist() {
    if (HIST.tab !== 'facturas') return;
    var q = $('h-q').value.trim().toLowerCase(), tipo = $('h-tipo').value, fis = $('h-fiscal').value;
    var l = HIST.filas.filter(function (r) {
        if (tipo && r._t !== tipo) return false;
        if (fis === 'fiscalizada' && r.estado_fiscal !== 'fiscalizada') return false;
        if (fis === 'pendiente' && r.estado_fiscal !== 'pendiente' && r.estado_fiscal !== 'error') return false;
        if (fis === 'no' && r.estado_fiscal) return false;
        if (q && [r.numero, r.cliente_nombre, r.cliente_rif, r.numero_fiscal, r.venta_numero].join(' ').toLowerCase().indexOf(q) < 0) return false;
        return true;
    });
    if (!l.length) { $('h-lista').innerHTML = window.refEstado(q ? 'busqueda' : 'vacio', q ? 'Sin resultados' : 'No hay facturas en estas fechas', q ? 'Prueba con otro número o cliente.' : 'Las facturas que emitas aparecerán aquí.', '', 'sm'); return; }
    $('h-lista').innerHTML = '<table class="t"><thead><tr><th>Identificador</th><th>Tipo</th><th>Fecha</th><th>Número fiscal</th><th>Cliente</th><th>Cajero</th><th class="r">Monto total</th><th class="r">Tasa de cambio</th><th class="r">Acciones</th></tr></thead><tbody>' +
        l.slice(0, 300).map(function (r, i) {
            var nc = r._t === 'nc', ef = estadoFiscal(r);
            return '<tr><td>' + esc(r.numero) + '<span class="sub">' + esc(ef) + '</span></td>' +
                '<td><span class="' + (nc ? 'txt-err' : r.estado === 'anulada' ? 'txt-err' : 'txt-ok') + '">' + (nc ? 'Nota de crédito' : r.estado === 'anulada' ? 'Anulada' : 'Factura') + '</span>' + (nc ? '<span class="sub">De ' + esc(r.venta_numero || '') + '</span>' : '') + '</td>' +
                '<td>' + H.fecha(r.created_at) + '<span class="sub">' + H.hora(r.created_at) + '</span></td>' +
                '<td>' + esc(r.numero_fiscal || '—') + (r.serial_fiscal ? '<span class="sub">Serial: ' + esc(r.serial_fiscal) + '</span>' : '') + '</td>' +
                '<td style="text-transform:uppercase">' + esc(r.cliente_nombre || 'Consumidor final') + (r.cliente_rif ? '<span class="sub">' + esc(r.cliente_rif) + '</span>' : '') + '</td>' +
                '<td style="text-transform:uppercase">' + esc(r.usuario_nombre || '—') + '</td>' +
                '<td class="r">' + bs(r.total_bs) + '<span class="sub">' + usd(r.total_usd) + '</span></td>' +
                '<td class="r">' + f2(r.tasa_bcv || (r.total_usd ? r.total_bs / r.total_usd : 0)) + '</td>' +
                '<td class="r"><button type="button" class="dots" data-i="' + i + '"><span class="material-symbols-outlined">more_horiz</span></button></td></tr>';
        }).join('') + '</tbody></table>';
    $('h-lista').querySelectorAll('[data-i]').forEach(function (b) { b.addEventListener('click', function (e) { e.stopPropagation(); acciones(b, l[Number(b.dataset.i)]); }); });
}
function acciones(btn, r) {
    var nc = r._t === 'nc', items = [{ ic: 'visibility', t: 'Ver detalle', fn: function () { detalle(r); } }, { ic: 'print', t: 'Reimprimir', fn: function () { reimprimir(r); } }];
    if (!nc && r.estado === 'completada') items.push({ ic: 'assignment_return', t: 'Nota de crédito', off: !H.can('devoluciones'), fn: function () { abrirNC(r); } });
    if (!nc) items.push({ ic: 'replay', t: 'Refacturar (usar sus productos)', fn: function () { refacturar(r); } });
    if ((r.estado_fiscal === 'pendiente' || r.estado_fiscal === 'error') && S.cfg.modo === 'fiscal') items.push({ ic: 'verified', t: 'Fiscalizar ahora', fn: function () { fiscalizar(r); } });
    P.menuEn(btn, items);
}
async function itemsDe(r) {
    if (r._t === 'nc') { var d = await supabaseClient.from('notas_credito_detalle').select('*').eq('nota_id', r.id); return (d.data || []).map(function (x) { return { codigo: x.producto_codigo, descripcion: x.descripcion, cantidad: Number(x.cantidad), precio: Number(x.precio_unitario), total: Number(x.total), descuento: 0, iva: 0 }; }); }
    var dv = await supabaseClient.from('detalle_venta').select('*').eq('venta_id', r.id);
    return (dv.data || []).map(function (x) { var p = S.porCodigo[String(x.producto_codigo).toLowerCase()]; return { codigo: x.producto_codigo, descripcion: x.descripcion, cantidad: Number(x.cantidad), precio: Number(x.precio_unitario), costo: Number(x.costo_unitario) || 0, descuento: Number(x.descuento) || 0, total: Number(x.total), iva: p ? p.iva : 16, unidad: p ? p.unidad : 'uds' }; });
}
function docDe(r, items) { return { numero: r.numero, fecha: r.created_at, cliente: { nombre: r.cliente_nombre, rif: r.cliente_rif }, items: items, subtotal: r.subtotal, iva: r.iva, total_usd: r.total_usd, total_bs: r.total_bs, tasa: r.tasa_bcv || (r.total_usd ? r.total_bs / r.total_usd : S.tasa), pagos: r.pagos || [], vuelto: r.vuelto || [], usuario: r.usuario_nombre, sucursal_nombre: r.sucursal_nombre, factura: r.venta_numero }; }
async function detalle(r) {
    var items = await itemsDe(r), ts = r.tasa_bcv || (r.total_usd ? r.total_bs / r.total_usd : S.tasa);
    modal({ titulo: (r._t === 'nc' ? 'Nota de crédito ' : 'Factura ') + r.numero, ancho: true,
        texto: H.fecha(r.created_at) + ' ' + H.hora(r.created_at) + ' · ' + esc(r.cliente_nombre || 'Consumidor final') + (r.cliente_rif ? ' · ' + esc(r.cliente_rif) : '') + ' · Cajero: ' + esc(r.usuario_nombre || '-') + (r.numero_fiscal ? ' · N° fiscal ' + esc(r.numero_fiscal) : ''),
        cuerpo: items.map(function (i) { return '<div class="rs-it"><span class="q">' + cant(i.cantidad) + '</span><div class="n">' + esc(i.descripcion) + '<small>' + esc(i.codigo) + '</small></div><div class="m">' + bs(i.total * ts) + '<small>' + usd(i.total) + '</small></div></div>'; }).join('') +
            '<div class="rs-tot" style="margin-top:8px"><div class="big"><span>Total</span><b>' + bs(r.total_bs) + '</b></div><div><span>En dólares</span><span>' + usd(r.total_usd) + '</span></div>' +
            ((r.pagos || []).map(function (p) { return '<div><span>' + esc(H.METODO_NOMBRE[p.metodo] || p.metodo) + ' (' + (p.moneda === 'USD' ? '$' : 'Bs') + ')</span><span>' + (p.moneda === 'USD' ? usd(p.monto) : bs(p.monto)) + '</span></div>'; }).join('')) + '</div>' });
}
async function reimprimir(r) { var items = await itemsDe(r); var d = docDe(r, items); var modo = S.cfg.modo; if (modo === 'fiscal') S.cfg.modo = 'ticket'; try { await imprimirDoc(r._t === 'nc' ? 'nc' : 'factura', d); } finally { S.cfg.modo = modo; } }
async function fiscalizar(r) { var items = await itemsDe(r); var d = docDe(r, items); if (r._t === 'nc') { var v = HIST.filas.find(function (x) { return x._t === 'factura' && x.id === r.venta_id; }) || {}; d.factura_fiscal = v.numero_fiscal; d.factura_fecha = v.fecha_fiscal || v.created_at; d.factura_serial = v.serial_fiscal; } if (await imprimirDoc(r._t === 'nc' ? 'nc' : 'factura', d)) P.cargarFacturas(); }
async function refacturar(r) {
    if (S.carro.length && !(await window.refConfirm('Se reemplazará la factura en curso con los productos de ' + r.numero + '. ¿Continuar?', { peligro: false }))) return;
    var items = await itemsDe(r), faltan = [];
    S.carro = [];
    items.forEach(function (i) { var p = S.porCodigo[String(i.codigo).toLowerCase()]; if (!p) { faltan.push(i.descripcion); return; } S.carro.push({ codigo: p.codigo, descripcion: p.descripcion, precio: p.precio, costo: p.costo, cantidad: Math.min(i.cantidad, p.servicio ? 1e9 : p.stock) || i.cantidad, descuento: i.descuento || 0, stock: p.servicio ? 1e9 : p.stock, unidad: p.unidad, iva: p.iva, iva_extra: p.iva_extra, servicio: p.servicio }); });
    S.cliente = r.cliente_rif ? { rif: r.cliente_rif, nombre: r.cliente_nombre, existe: true } : null;
    P.pintarCliente(); P.pintarCarro(); P.ir('factura');
    toast('Productos cargados', faltan.length ? 'No están en esta tienda: ' + faltan.join(', ') : 'Con precios actuales.', faltan.length ? 'warning' : 'info');
}
async function cargarBorradores() {
    var r = await supabaseClient.from('pos_borradores').select('*').eq('sucursal_id', S.tienda.id).order('updated_at', { ascending: false }).limit(100);
    if (r.error) { $('h-lista').innerHTML = window.refEstado('error', 'Borradores no disponibles', H.faltaFn(r.error) || /relation|does not exist/i.test(r.error.message) ? 'Falta correr supabase-migration-pos-precios.sql en Supabase.' : H.errMsg(r.error), '', 'sm'); return; }
    var l = r.data || [];
    if (!l.length) { $('h-lista').innerHTML = window.refEstado('vacio', 'No hay borradores', 'Guarda una factura como borrador para retomarla después.', '', 'sm'); return; }
    $('h-lista').innerHTML = '<table class="t"><thead><tr><th>Borrador</th><th>Cliente</th><th class="r">Productos</th><th class="r">Total</th><th>Guardado por</th><th>Fecha</th><th class="r">Acciones</th></tr></thead><tbody>' +
        l.map(function (b, i) { return '<tr><td>' + esc(b.nombre || 'Borrador') + '</td><td style="text-transform:uppercase">' + esc((b.cliente && b.cliente.nombre) || 'Consumidor final') + '</td><td class="r">' + (b.items || []).length + '</td><td class="r">' + bs(b.total_usd * S.tasa) + '<span class="sub">' + usd(b.total_usd) + '</span></td><td style="text-transform:uppercase">' + esc(b.usuario_nombre || '-') + '</td><td>' + H.fecha(b.updated_at) + '<span class="sub">' + H.hora(b.updated_at) + '</span></td>' +
            '<td class="r"><button type="button" class="btn out sm" data-ab="' + i + '">Abrir</button> <button type="button" class="dots" data-el="' + i + '" title="Eliminar"><span class="material-symbols-outlined">delete</span></button></td></tr>'; }).join('') + '</tbody></table>';
    $('h-lista').querySelectorAll('[data-ab]').forEach(function (b) { b.addEventListener('click', async function () {
        var x = l[Number(b.dataset.ab)];
        if (S.carro.length && !(await window.refConfirm('Se reemplazará la factura en curso. ¿Continuar?', { peligro: false }))) return;
        S.carro = (x.items || []).map(function (i) { var p = S.porCodigo[String(i.codigo).toLowerCase()]; return p ? Object.assign({}, i, { precio: p.precio, stock: p.servicio ? 1e9 : p.stock }) : i; });
        S.cliente = x.cliente || null; S.borradorId = x.id; P.pintarCliente(); P.pintarCarro(); P.ir('factura');
    }); });
    $('h-lista').querySelectorAll('[data-el]').forEach(function (b) { b.addEventListener('click', async function () {
        var x = l[Number(b.dataset.el)];
        if (!(await window.refConfirm('¿Eliminar el borrador "' + (x.nombre || 'Borrador') + '"?'))) return;
        await supabaseClient.rpc('pos_borrador_eliminar', { p_id: x.id }); cargarBorradores();
    }); });
}

/* ============================================================
   NOTA DE CRÉDITO
   ============================================================ */
var NC_MET = [['efectivo', 'VES', 'Efectivo Bs'], ['divisa', 'USD', 'Efectivo $'], ['pago_movil', 'VES', 'Pago móvil'], ['transferencia', 'VES', 'Transferencia'], ['punto', 'VES', 'Débito']];
async function abrirNC(v) {
    var dv = await supabaseClient.from('detalle_venta').select('*').eq('venta_id', v.id);
    var prev = await supabaseClient.from('notas_credito').select('id').eq('venta_id', v.id), dev = {};
    if (prev.data && prev.data.length) { var dd = await supabaseClient.from('notas_credito_detalle').select('producto_codigo,cantidad').in('nota_id', prev.data.map(function (x) { return x.id; })); (dd.data || []).forEach(function (d) { dev[d.producto_codigo] = (dev[d.producto_codigo] || 0) + Number(d.cantidad); }); }
    var ag = {};
    (dv.data || []).forEach(function (d) { var k = d.producto_codigo; if (!ag[k]) ag[k] = { codigo: k, descripcion: d.descripcion, cant: 0, total: 0 }; ag[k].cant += Number(d.cantidad); ag[k].total += Number(d.total); });
    var lineas = Object.keys(ag).map(function (k) { var a = ag[k]; a.max = Math.max(0, r2(a.cant - (dev[k] || 0))); a.precio = a.cant ? a.total / a.cant : 0; a.sel = 0; return a; });
    var credito = v.metodo_pago === 'credito';
    S.nc = { venta: v, lineas: lineas, metodo: credito ? 'rebaja_deuda' : (v.metodo_pago === 'divisa' ? 'divisa' : v.metodo_pago && NC_MET.some(function (m) { return m[0] === v.metodo_pago; }) ? v.metodo_pago : 'efectivo'), tasa: v.tasa_bcv || (v.total_usd ? v.total_bs / v.total_usd : S.tasa) };
    $('n-doc').innerHTML = '<div><div style="font-size:15px;color:var(--tx2)">Documento</div><div style="font-size:16px;text-transform:uppercase;margin-top:4px">' + esc(v.cliente_nombre || 'Consumidor final') + '</div><div style="color:var(--tx3)">' + esc(v.cliente_rif || '') + '</div></div>' +
        '<div style="text-align:right"><div style="font-size:16px">Factura ' + esc(v.numero) + '</div>' + (v.numero_fiscal ? '<div style="color:var(--tx2)">Número fiscal: ' + esc(v.numero_fiscal) + '</div>' : '') + '<div style="color:var(--tx3)">' + H.fecha(v.created_at) + '</div></div>';
    $('n-tabs').innerHTML = credito ? '<button type="button" class="on"><span class="material-symbols-outlined">handshake</span>Rebaja de deuda</button>' :
        NC_MET.map(function (m) { return '<button type="button" data-nm="' + m[0] + '" class="' + (m[0] === S.nc.metodo ? 'on' : '') + '"><span class="material-symbols-outlined">' + (H.METODO_ICONO[m[0]] || 'payments') + '</span>' + m[2] + '</button>'; }).join('');
    $('n-metodo-info').textContent = credito ? 'La venta fue a crédito: el monto se rebaja de la deuda del cliente.' : 'El dinero sale de la caja con este método.';
    $('n-motivo').value = ''; $('n-todos').checked = false;
    pintarNC(); P.ir('nc');
}
$('n-tabs').addEventListener('click', function (e) { var b = e.target.closest('[data-nm]'); if (!b) return; S.nc.metodo = b.dataset.nm; document.querySelectorAll('#n-tabs [data-nm]').forEach(function (x) { x.classList.toggle('on', x === b); }); });
function pintarNC() {
    var n = S.nc;
    $('n-items').innerHTML = n.lineas.map(function (a, i) {
        return '<div class="rs-it" style="align-items:center"><input type="checkbox" data-ck="' + i + '"' + (a.sel > 0 ? ' checked' : '') + (a.max <= 0 ? ' disabled' : '') + ' style="width:20px;height:20px;accent-color:var(--az)"/>' +
            '<input class="in" data-qn="' + i + '" inputmode="decimal" placeholder="Cantidad" value="' + (a.sel || '') + '"' + (a.max <= 0 ? ' disabled' : '') + ' style="width:120px;height:38px"/>' +
            '<div class="n">' + esc(a.descripcion) + '<small>' + cant(a.cant) + ' vendido(s)' + (a.cant - a.max > 0 ? ' · ' + cant(a.cant - a.max) + ' ya devuelto(s)' : '') + '</small></div><div class="m">' + bs(a.sel * a.precio * n.tasa) + '<small>' + usd(a.sel * a.precio) + '</small></div></div>';
    }).join('');
    var tot = n.lineas.reduce(function (s, a) { return s + a.sel * a.precio; }, 0);
    $('n-tot').innerHTML = '<div class="big"><span>Total</span><b>' + bs(tot * n.tasa) + '</b></div><div><span>En dólares</span><span>' + usd(tot) + '</span></div>';
    $('n-emitir').disabled = !(tot > 0);
}
$('n-items').addEventListener('change', function (e) {
    var n = S.nc, t = e.target;
    if (t.dataset.ck != null) { var a = n.lineas[Number(t.dataset.ck)]; a.sel = t.checked ? a.max : 0; }
    if (t.dataset.qn != null) { var b = n.lineas[Number(t.dataset.qn)]; b.sel = Math.max(0, Math.min(b.max, num(t.value))); }
    pintarNC();
});
$('n-todos').addEventListener('change', function () { var on = this.checked; S.nc.lineas.forEach(function (a) { a.sel = on ? a.max : 0; }); pintarNC(); });
$('n-volver').addEventListener('click', function () { P.ir('facturas'); });
$('n-emitir').addEventListener('click', async function () {
    var n = S.nc, items = n.lineas.filter(function (a) { return a.sel > 0; }).map(function (a) { return { codigo: a.codigo, cantidad: a.sel }; });
    var tot = n.lineas.reduce(function (s, a) { return s + a.sel * a.precio; }, 0);
    if (!items.length) return;
    if (!(await window.refConfirm('¿Emitir nota de crédito por ' + bs(tot * n.tasa) + ' (' + usd(tot) + ')? Los productos vuelven al inventario.', { peligro: false, si: 'Emitir' }))) return;
    var b = this; b.disabled = true;
    var motivo = $('n-motivo').value.trim() || null, metodo = n.metodo === 'rebaja_deuda' ? null : n.metodo;
    var r = await supabaseClient.rpc('pos_nota_credito', { p_venta_id: n.venta.id, p_items: items, p_motivo: motivo, p_usuario: S.user.nombre, p_metodo: metodo, p_estado_fiscal: S.cfg.modo === 'fiscal' && n.venta.numero_fiscal ? 'pendiente' : null });
    if (r.error && H.faltaFn(r.error)) r = await supabaseClient.rpc('nota_credito_registrar', { p_venta_id: n.venta.id, p_items: items, p_motivo: motivo, p_usuario: S.user.nombre });
    b.disabled = false;
    if (r.error) return toast('No se pudo emitir la nota de crédito', H.errMsg(r.error), 'error');
    toast('¡Operación realizada con éxito!', 'Nota de crédito ' + r.data.numero + ' generada correctamente');
    var dItems = n.lineas.filter(function (a) { return a.sel > 0; }).map(function (a) { var p = S.porCodigo[String(a.codigo).toLowerCase()]; if (p && !p.servicio) p.stock = r2(p.stock + a.sel); return { codigo: a.codigo, descripcion: a.descripcion, cantidad: a.sel, precio: a.precio, total: r2(a.sel * a.precio), descuento: 0, iva: p ? p.iva : 16 }; });
    var doc = { numero: r.data.numero, fecha: new Date().toISOString(), cliente: { nombre: n.venta.cliente_nombre, rif: n.venta.cliente_rif }, items: dItems, total_usd: r.data.total_usd, total_bs: r.data.total_bs, tasa: n.tasa, factura: n.venta.numero,
        factura_fiscal: n.venta.numero_fiscal, factura_fecha: n.venta.fecha_fiscal || n.venta.created_at, factura_serial: n.venta.serial_fiscal, usuario: S.user.nombre,
        pagos: metodo ? [{ metodo: metodo, moneda: metodo === 'divisa' ? 'USD' : 'VES', monto: metodo === 'divisa' ? r.data.total_usd : r.data.total_bs, monto_bs: r.data.total_bs, monto_usd: r.data.total_usd }] : [] };
    if (S.cfg.modo !== 'fiscal' || n.venta.numero_fiscal) await imprimirDoc('nc', doc);
    else { var modo = S.cfg.modo; S.cfg.modo = 'ticket'; await imprimirDoc('nc', doc); S.cfg.modo = modo; }
    P.ir('facturas');
});

/* ============================================================
   CAJA: turno y arqueo
   ============================================================ */
var ARQ = { filas: [], docs: 0 };
function claveMetodo(m) {
    var met = m.metodo_pago || 'efectivo';
    if (met === 'credito' || met === 'rebaja_deuda') return null;
    var usdM = ['divisa', 'zelle', 'binance', 'otro'].indexOf(met) >= 0;
    return { k: met, metodo: met === 'divisa' ? 'efectivo' : met, moneda: usdM ? 'USD' : 'VES', nombre: (H.METODO_NOMBRE[met] || met), monto: usdM ? Number(m.monto_usd) || 0 : Number(m.monto_bs) || 0 };
}
P.pintarCaja = async function () {
    var box = $('v-caja');
    await P.cargarTurno();
    if (S.turnoDisponible === false) { box.innerHTML = window.refEstado('error', 'Turnos no activados', 'Falta correr en Supabase la migración de turnos (supabase-migration-norkut-completo.sql).', '', 'sm'); return; }
    if (!S.turno) {
        box.innerHTML = '<div class="vh"><div><h1>Caja</h1><p>Abre tu turno con el efectivo inicial para empezar a facturar.</p></div></div>' +
            '<div class="card" style="max-width:520px">' + window.refEstado('pagos', 'No tienes un turno abierto', 'Al abrir el turno quedan registradas todas tus ventas hasta el arqueo.', '<button type="button" class="btn" id="cj-abrir"><span class="material-symbols-outlined">lock_open</span>Abrir turno</button>', 'sm') + '</div>';
        $('cj-abrir').addEventListener('click', function () { P.abrirTurno(); });
        return;
    }
    box.innerHTML = window.refEstado('cargando', 'Calculando arqueo…', '', '', 'sm');
    var t = S.turno;
    var q = supabaseClient.from('caja_movimientos').select('*').eq('usuario_nombre', S.user.nombre).gte('fecha', t.abierto_at);
    q = S.tienda.id === CASA ? q.or('sucursal_id.eq.' + CASA + ',sucursal_id.is.null') : q.eq('sucursal_id', S.tienda.id);
    var rm = await q.limit(5000), filas = {};
    filas.efectivo_VES = { k: 'efectivo', metodo: 'efectivo', moneda: 'VES', nombre: 'Efectivo', sistema: Number(t.fondo_bs) || 0 };
    filas.efectivo_USD = { k: 'divisa', metodo: 'efectivo', moneda: 'USD', nombre: 'Efectivo', sistema: Number(t.fondo_usd) || 0 };
    ((rm && rm.data) || []).forEach(function (m) {
        if (m.tipo === 'apertura' || m.tipo === 'cierre') return;
        var c = claveMetodo(m); if (!c) return;
        var key = c.metodo + '_' + c.moneda;
        if (!filas[key]) filas[key] = { k: c.k, metodo: c.metodo, moneda: c.moneda, nombre: c.nombre, sistema: 0 };
        filas[key].sistema += (m.tipo === 'venta' || m.tipo === 'ingreso') ? c.monto : -c.monto;
    });
    ARQ.filas = Object.keys(filas).map(function (k) { var f = filas[k]; f.sistema = r2(f.sistema); f.conteo = null; return f; });
    var rv = await supabaseClient.from('ventas').select('id', { count: 'exact', head: true }).eq('usuario_nombre', S.user.nombre).gte('created_at', t.abierto_at);
    ARQ.docs = rv && rv.count != null ? rv.count : '—';
    box.innerHTML = '<div class="vh"><div><h1>Arqueo de caja</h1><p>En esta sección puedes realizar el arqueo de caja: revisa tus ingresos, valida los pagos registrados y asegúrate de que todo esté en orden al cierre.</p></div>' +
        '<div style="display:flex;gap:8px;flex-wrap:wrap"><button type="button" class="btn out sm" id="cj-mov"><span class="material-symbols-outlined">swap_vert</span>Ingreso / egreso</button>' + (S.cfg.modo === 'fiscal' ? '<button type="button" class="btn out sm" id="cj-x"><span class="material-symbols-outlined">print</span>Reporte X</button>' : '') + '</div></div>' +
        '<div class="arq"><div style="display:flex;flex-direction:column;gap:16px"><div class="card"><h2>General</h2><div class="gen"><div>Usuario: <b style="text-transform:uppercase">' + esc(S.user.nombre) + '</b></div><div>Punto de venta: <b>' + esc(H.ls(H.K_TERM) || 'Esta caja') + '</b></div><div>Fecha actual: <b>' + H.fecha(new Date().toISOString()) + '</b></div>' +
            '<div>Tienda: <b>' + esc(S.tienda.nombre) + '</b></div><div>Documentos emitidos: <b>' + ARQ.docs + '</b></div><div>Turno: <b>' + esc(t.numero) + ' · ' + H.fecha(t.abierto_at) + ' ' + H.hora(t.abierto_at) + '</b></div></div></div>' +
            '<div class="card"><h2>Pagos</h2><div id="cj-filas"></div></div></div>' +
            '<div class="card"><h2>Detalle de recolección</h2><div class="rec" id="cj-rec"></div><div class="campo" style="margin-top:12px"><span>Observaciones</span><textarea id="cj-obs" class="in" placeholder="Observaciones"></textarea></div>' +
            '<button type="button" class="btn xl" id="cj-cerrar"><span class="material-symbols-outlined">lock</span>Guardar y cerrar turno</button></div></div>';
    pintarArqueo();
    $('cj-cerrar').addEventListener('click', cerrarTurno);
    $('cj-mov').addEventListener('click', movimientoCaja);
    var bx = $('cj-x'); if (bx) bx.addEventListener('click', function () { reporteFiscal('X'); });
};
function pintarArqueo() {
    $('cj-filas').innerHTML = ARQ.filas.map(function (f, i) {
        var dif = f.conteo == null ? -f.sistema : f.conteo - f.sistema, fm = function (v) { return f.moneda === 'USD' ? usd(v) : bs(v); };
        return '<div class="ap"><span class="ic"><span class="material-symbols-outlined">' + (H.METODO_ICONO[f.k] || 'payments') + '</span></span><div>' + esc(f.nombre) + '<small>' + (f.moneda === 'USD' ? 'US Dollar' : 'Bolívar Venezolano') + '</small></div>' +
            '<div><small>Sistema</small>' + fm(f.sistema) + '</div><div class="dif"><small>Diferencia</small><span class="' + (Math.abs(dif) < 0.005 ? 'txt-ok' : 'txt-err') + '">' + fm(dif) + '</span></div><input class="in" data-cf="' + i + '" inputmode="decimal" placeholder="Conteo" value="' + (f.conteo == null ? '' : f2(f.conteo)) + '"/></div>';
    }).join('');
    var sisU = 0, conU = 0;
    ARQ.filas.forEach(function (f) { var a = f.moneda === 'USD' ? 1 : 1 / (S.tasa || 1); sisU += f.sistema * a; conU += (f.conteo || 0) * a; });
    var dif = conU - sisU;
    $('cj-rec').innerHTML = '<div><span>Sistema</span><b style="font-weight:500">' + bs(sisU * S.tasa) + '</b></div><div style="font-size:13px;color:var(--tx3);margin-top:-6px"><span></span><span>' + usd(sisU) + '</span></div>' +
        '<div><span>Conteo</span><span>' + bs(conU * S.tasa) + '</span></div><div class="big"><span>Diferencia</span><b class="' + (Math.abs(dif) < 0.005 ? 'txt-ok' : 'txt-err') + '" style="font-weight:500">' + bs(dif * S.tasa) + '</b></div><div style="font-size:13px;color:var(--tx3);margin-top:-6px"><span></span><span>' + usd(dif) + '</span></div>';
}
document.addEventListener('change', function (e) { if (e.target.dataset && e.target.dataset.cf != null && S.vista === 'caja') { var f = ARQ.filas[Number(e.target.dataset.cf)]; f.conteo = e.target.value.trim() === '' ? null : num(e.target.value); pintarArqueo(); } });
async function cerrarTurno() {
    var sinContar = ARQ.filas.filter(function (f) { return f.conteo == null && Math.abs(f.sistema) > 0.004; });
    if (sinContar.length && !(await window.refConfirm('Hay ' + sinContar.length + ' método(s) sin conteo. Se guardará conteo 0 en esos. ¿Cerrar el turno?', { peligro: true, si: 'Cerrar turno' }))) return;
    if (!sinContar.length && !(await window.refConfirm('¿Guardar el arqueo y cerrar el turno ' + S.turno.numero + '?', { peligro: false, si: 'Cerrar turno' }))) return;
    var efVes = ARQ.filas.find(function (f) { return f.k === 'efectivo' && f.moneda === 'VES'; }), efUsd = ARQ.filas.find(function (f) { return f.k === 'divisa'; });
    var conteo = ARQ.filas.map(function (f) { return { metodo: f.k, moneda: f.moneda, sistema: f.sistema, conteo: f.conteo || 0, diferencia: r2((f.conteo || 0) - f.sistema) }; });
    var args = { p_id: S.turno.id, p_contado_usd: efUsd ? efUsd.conteo || 0 : 0, p_contado_bs: efVes ? efVes.conteo || 0 : 0, p_conteo: conteo, p_notas: $('cj-obs').value.trim() || null };
    var r = await supabaseClient.rpc('pos_turno_cerrar', args);
    if (r.error && H.faltaFn(r.error)) r = await supabaseClient.rpc('turno_cerrar', { p_id: args.p_id, p_contado_usd: args.p_contado_usd, p_contado_bs: args.p_contado_bs, p_notas: args.p_notas });
    if (r.error) return toast('No se pudo cerrar el turno', H.errMsg(r.error), 'error');
    var t = S.turno;
    toast('¡Operación realizada con éxito!', 'Turno ' + t.numero + ' cerrado correctamente');
    var modo = S.cfg.modo; if (modo === 'fiscal') S.cfg.modo = 'ticket';
    await imprimirDoc('turno', { numero: t.numero, fecha: new Date().toISOString(), usuario: S.user.nombre, lineas: [['Abierto', H.fecha(t.abierto_at) + ' ' + H.hora(t.abierto_at)], ['Documentos', String(ARQ.docs)]].concat(conteo.map(function (c) { return [(H.METODO_NOMBRE[c.metodo] || c.metodo) + ' ' + (c.moneda === 'USD' ? '$' : 'Bs'), f2(c.sistema) + ' / ' + f2(c.conteo)]; })) });
    S.cfg.modo = modo;
    if (S.cfg.modo === 'fiscal' && (await window.refConfirm('¿Imprimir también el Reporte Z de la impresora fiscal? (cierra el día fiscal)', { peligro: true, si: 'Imprimir Z' }))) await reporteFiscal('Z', true);
    S.turno = null; P.cargarTurno(); P.pintarCaja();
}
function movimientoCaja() {
    var m = modal({ titulo: 'Movimiento de caja', texto: 'Registra dinero que entra o sale de la caja sin ser una venta (ej: pago a un proveedor, cambio de billetes).',
        cuerpo: '<div class="g2"><div class="campo"><span>Tipo</span><select id="mc-t" class="in"><option value="ingreso">Ingreso</option><option value="egreso">Egreso</option></select></div><div class="campo"><span>Método</span><select id="mc-m" class="in"><option value="efectivo">Efectivo Bs</option><option value="divisa">Efectivo $</option><option value="pago_movil">Pago móvil</option></select></div></div>' +
            '<div class="g2"><div class="campo"><span>Monto en $</span><input id="mc-u" class="in" inputmode="decimal" value="0"/></div><div class="campo"><span>Monto en Bs</span><input id="mc-b" class="in" inputmode="decimal" value="0"/></div></div><div class="campo"><span>Concepto *</span><input id="mc-c" class="in" maxlength="120"/></div>',
        pie: '<button type="button" class="btn out" data-c>Cancelar</button><button type="button" class="btn" data-ok>Registrar</button>' });
    m.q('[data-c]').addEventListener('click', m.cerrar);
    m.q('[data-ok]').addEventListener('click', async function () {
        var c = m.q('#mc-c').value.trim(), u = num(m.q('#mc-u').value), b = num(m.q('#mc-b').value);
        if (!c) return m.q('#mc-c').classList.add('err');
        if (!u && !b) return toast('Escribe el monto', '', 'warning');
        var r = await window.rpcConFallback('caja_registrar_movimiento', { p_tipo: m.q('#mc-t').value, p_concepto: c, p_monto_usd: u, p_monto_bs: b, p_sucursal_id: S.tienda.id, p_usuario: S.user.nombre, p_metodo_pago: m.q('#mc-m').value }, ['p_metodo_pago']);
        if (r.error) return toast('No se pudo registrar', H.errMsg(r.error), 'error');
        m.cerrar(); toast('Movimiento registrado', c); P.pintarCaja();
    });
}
async function reporteFiscal(tipo, sinConfirmar) {
    if (tipo === 'Z' && !sinConfirmar && !(await window.refConfirm('El Reporte Z cierra el día fiscal de la impresora. Solo se hace una vez al final del día. ¿Continuar?', { peligro: true, si: 'Imprimir Reporte Z' }))) return;
    toast('Enviando Reporte ' + tipo + '…', '', 'info');
    var r = await P.puente('/fiscal/reporte', { tipo: tipo, puerto: S.cfg.puerto }, 60000);
    toast(r && r.ok ? 'Reporte ' + tipo + ' impreso' : 'No se pudo imprimir el Reporte ' + tipo, r && !r.ok ? (r.error || r.message || '') : (r.numero_z ? 'Z N° ' + r.numero_z : ''), r && r.ok ? 'success' : 'error');
}

/* ============================================================
   DISPOSITIVOS
   ============================================================ */
P.pintarDispositivos = async function () {
    $('d-fiscal').innerHTML = $('d-ticket').innerHTML = '<div class="card">' + window.refEstado('cargando', 'Buscando dispositivos…', '', '', 'xs') + '</div>';
    var b = await P.estadoPuente();
    if (!b.ok) {
        var sin = '<div class="card" style="grid-column:1/-1">' + window.refEstado('error', 'Falta el programa de impresión en esta computadora', 'Instala REFRIMAR POS para Windows en esta computadora: trae el programa de la impresora fiscal PNP y de tickets, y se conecta solo. Si Windows avisa, pulsa "Más información" y "Ejecutar de todas formas".', '<a class="btn" href="REFRIMAR-POS-Setup.exe" download><span class="material-symbols-outlined">download</span>Descargar REFRIMAR POS</a>', 'sm') + '</div>';
        $('d-fiscal').innerHTML = sin; $('d-ticket').innerHTML = ''; return;
    }
    var f = b.fiscal || {};
    $('d-fiscal').innerHTML = f.ok && f.conectada ?
        '<div class="dev ok"><span class="st"><span class="material-symbols-outlined" style="font-size:18px">check</span></span><div class="inf"><b>' + esc(f.modelo || S.cfg.modelo) + '</b><div>Tipo de dispositivo: ' + (f.simulada ? 'Simulado (prueba)' : 'Físico') + '</div><div>Identificador: ' + esc(f.serial || '—') + '</div><div>Puerto: ' + esc(f.puerto || 'Automático') + '</div>' + (f.ultima_factura ? '<div>Última factura: ' + esc(f.ultima_factura) + '</div>' : '') + '</div><button type="button" class="dots" id="d-fmenu"><span class="material-symbols-outlined">more_horiz</span></button></div>' :
        '<div class="dev err"><div class="inf"><b>Impresora fiscal</b><div>' + esc(f.error || 'No conectada') + '</div><div>Puerto: ' + esc(S.cfg.puerto === 'AUTO' ? 'automático' : S.cfg.puerto) + ' · Modo de impresión: ' + esc(S.cfg.modo === 'fiscal' ? 'Fiscal' : S.cfg.modo === 'ticket' ? 'Ticket' : 'Navegador') + '</div><div style="margin-top:8px"><button type="button" class="btn out sm" id="d-cfg">Configurar en Ajustes</button></div></div></div>';
    $('d-ticket').innerHTML = '<div class="dev ' + (b.printer ? 'ok' : 'err') + '">' + (b.printer ? '<span class="st"><span class="material-symbols-outlined" style="font-size:18px">check</span></span>' : '') + '<div class="inf"><b>' + esc(b.printer || 'Sin impresora de tickets') + '</b><div>Tipo: térmica ESC/POS · ' + (Number(S.cfg.ancho) === 32 ? '58 mm' : '80 mm') + '</div><div>Gaveta conectada a la impresora</div></div><button type="button" class="dots" id="d-tmenu"><span class="material-symbols-outlined">more_horiz</span></button></div>';
    var fm = $('d-fmenu'); if (fm) fm.addEventListener('click', function (e) { e.stopPropagation(); P.menuEn(fm, [{ ic: 'print', t: 'Reporte X', fn: function () { reporteFiscal('X'); } }, { ic: 'print', t: 'Reporte Z', fn: function () { reporteFiscal('Z'); } }, { ic: 'point_of_sale', t: 'Abrir gaveta de efectivo', fn: function () { var mo = S.cfg.modo; S.cfg.modo = 'fiscal'; abrirGaveta(false).then(function () { S.cfg.modo = mo; }); } }]); });
    var tm = $('d-tmenu'); tm.addEventListener('click', function (e) { e.stopPropagation(); P.menuEn(tm, [{ ic: 'receipt', t: 'Imprimir ticket de prueba', fn: async function () { var r = await P.puente('/print', { text: P.ticketTexto('factura', { numero: 'PRUEBA', items: [{ descripcion: 'Producto de prueba', cantidad: 1, precio: 1, total: 1, iva: 16 }], total_usd: 1.16, subtotal: 1, iva: 0.16, pagos: [] }) }); toast(r.ok ? 'Ticket de prueba enviado' : 'No se pudo imprimir', r.ok ? '' : (r.error || r.message), r.ok ? 'success' : 'error'); } }, { ic: 'point_of_sale', t: 'Abrir gaveta de efectivo', fn: async function () { var r = await P.puente('/drawer', {}); toast(r.ok ? 'Gaveta abierta' : 'No se pudo abrir la gaveta', r.ok ? '' : (r.error || r.message), r.ok ? 'success' : 'warning'); } }]); });
    var dc = $('d-cfg'); if (dc) dc.addEventListener('click', function () { P.ir('ajustes'); });
};
$('d-refrescar').addEventListener('click', function () { P.pintarDispositivos(); });

// ---------- Impresoras fiscales detectadas (todas las marcas) ----------
var DRIVERS_USB = '<a href="https://www.wch-ic.com/downloads/CH341SER_EXE.html" target="_blank" rel="noopener">CH340</a> · <a href="https://www.prolific.com.tw/US/ShowProduct.aspx?p_id=225&pcid=41" target="_blank" rel="noopener">Prolific PL2303</a> · <a href="https://ftdichip.com/drivers/vcp-drivers/" target="_blank" rel="noopener">FTDI</a>';
async function detectarFiscales() {
    var box = $('d-detectados');
    box.innerHTML = '<div class="card">' + window.refEstado('cargando', 'Revisando todos los puertos…', 'PNP, HKA/Bixolon, Epson. Puede tardar hasta 30 segundos.', '', 'xs') + '</div>';
    var r = await P.puente('/fiscal/detectar', undefined, 90000);
    if (!r || r.ok === false && !r.dispositivos) {
        box.innerHTML = '<div class="card">' + window.refEstado('error', 'No se pudo buscar', (r && (r.error || r.message)) || 'Revisa que el programa REFRIMAR POS esté instalado y abierto en esta computadora.', '', 'xs') + '</div>';
        return;
    }
    if (r.error && /Not Found/i.test(r.error)) { box.innerHTML = '<div class="card">' + window.refEstado('pagos', 'Actualiza el programa de la caja', 'Esta versión del programa no busca impresoras de otras marcas. Instala la versión nueva (abajo).', '', 'xs') + '</div>'; return; }
    var l = r.dispositivos || [];
    if (!l.length) {
        box.innerHTML = '<div class="dev err"><div class="inf"><b>No se encontró ninguna impresora fiscal</b>' + (r.ayuda || []).map(function (x) { return '<div>• ' + esc(x) + '</div>'; }).join('') +
            '<div style="margin-top:6px">Drivers USB: ' + DRIVERS_USB + '</div><div style="margin-top:8px"><button type="button" class="btn out sm" id="d-otra">Volver a buscar</button></div></div></div>';
        $('d-otra').addEventListener('click', detectarFiscales);
        return;
    }
    box.innerHTML = '<div class="devs">' + l.map(function (d, i) {
        var actual = d.marca === r.marca_actual && (r.puerto_actual === 'AUTO' || r.puerto_actual === d.puerto);
        return '<div class="dev ' + (actual ? 'ok' : '') + '">' + (actual ? '<span class="st"><span class="material-symbols-outlined" style="font-size:18px">check</span></span>' : '') +
            '<div class="inf"><b>' + esc(d.modelo) + '</b><div>Marca / protocolo: ' + esc(d.protocolo) + (d.por_probar ? ' · <span style="color:var(--warn,#B45309)">por probar en esta máquina</span>' : '') + '</div>' +
            '<div>Serial fiscal: ' + esc(d.serial || '—') + (d.rif ? ' · RIF ' + esc(d.rif) : '') + '</div><div>Puerto: ' + esc(d.puerto) + ' · Última factura: ' + esc(d.ultima_factura || '—') + '</div><div>Estado: ' + esc(d.estado || '—') + '</div>' +
            '<div style="display:flex;gap:6px;flex-wrap:wrap;margin-top:8px">' + (actual ? '' : '<button type="button" class="btn sm" data-usar="' + i + '">Usar esta</button>') +
            '<button type="button" class="btn out sm" data-x="' + i + '">Reporte X</button><button type="button" class="btn out sm" data-z="' + i + '">Reporte Z</button><button type="button" class="btn out sm" data-g="' + i + '">Abrir gaveta</button></div></div></div>';
    }).join('') + '</div>';
    async function usar(d) {
        var x = await P.puente('/fiscal/usar', { marca: d.marca, puerto: d.puerto });
        if (!x || !x.ok) { toast('No se pudo elegir la impresora', (x && x.error) || '', 'error'); return false; }
        S.cfg.puerto = d.puerto; S.cfg.puertoManual = true; S.cfg.modelo = d.modelo; if (x.factura) S.cfg.modo = 'fiscal'; P.guardarCfg();
        return x;
    }
    box.querySelectorAll('[data-usar]').forEach(function (b) { b.addEventListener('click', async function () { var d = l[b.dataset.usar]; var x = await usar(d); if (!x) return; toast('Impresora fiscal elegida', d.modelo + ' en ' + d.puerto + (x.factura ? '' : ' · todavía no factura (por probar): usa modo Ticket'), x.factura ? 'success' : 'warning'); detectarFiscales(); P.estadoPuente(); }); });
    box.querySelectorAll('[data-x],[data-z]').forEach(function (b) { b.addEventListener('click', async function () { var d = l[b.dataset.x || b.dataset.z]; if (!(await usar(d))) return; reporteFiscal(b.dataset.x ? 'X' : 'Z'); }); });
    box.querySelectorAll('[data-g]').forEach(function (b) { b.addEventListener('click', async function () { var d = l[b.dataset.g]; if (!(await usar(d))) return; var mo = S.cfg.modo; S.cfg.modo = 'fiscal'; abrirGaveta(false).then(function () { S.cfg.modo = mo; }); }); });
}
$('d-detectar').addEventListener('click', detectarFiscales);

// ---------- Facturas pendientes por fiscalizar (ninguna se pierde) ----------
async function pintarPendientesFiscales() {
    var box = $('d-pend'); if (!box || S.cfg.modo !== 'fiscal') { if (box) box.innerHTML = ''; return; }
    var r = await supabaseClient.from('ventas').select('id,numero,created_at,total_bs,total_usd,estado_fiscal').in('estado_fiscal', ['pendiente', 'error']).eq('terminal', H.ls(H.K_TERM) || '').order('created_at', { ascending: true }).limit(20);
    var l = (r && r.data) || [];
    box.innerHTML = l.length ? '<div class="dev err" style="margin-top:12px"><div class="inf"><b>' + l.length + ' factura(s) pendiente(s) por fiscalizar en esta caja</b><div>Se guardaron, pero la impresora fiscal no las imprimió. Fiscalízalas desde <b>Facturas → ⋯ → Fiscalizar ahora</b> apenas la impresora esté lista.</div>' +
        '<div>' + l.slice(0, 6).map(function (v) { return esc(v.numero) + ' · ' + H.fecha(v.created_at) + ' ' + H.hora(v.created_at); }).join('<br/>') + '</div><div style="margin-top:8px"><button type="button" class="btn out sm" id="d-ver-pend">Ver en Facturas</button></div></div></div>' : '';
    var b = $('d-ver-pend'); if (b) b.addEventListener('click', function () { P.ir('facturas'); });
}

// ---------- Versión del programa de la caja ----------
async function pintarVersion() {
    var box = $('d-version'); if (!box) return;
    var r = await P.puente('/version', undefined, 25000);
    if (!r || r.error && /Not Found/i.test(r.error)) { box.innerHTML = '<div class="card" style="font-size:14px">Tienes una versión anterior del programa. <a class="btn sm" href="REFRIMAR-POS-Setup.exe" download style="margin-left:8px">Descargar la nueva</a></div>'; return; }
    box.innerHTML = '<div class="dev ' + (r.nueva ? 'err' : 'ok') + '">' + (r.nueva ? '' : '<span class="st"><span class="material-symbols-outlined" style="font-size:18px">check</span></span>') + '<div class="inf"><b>REFRIMAR POS ' + esc(r.actual || '') + '</b><div>' + (r.nueva ? 'Hay una versión nueva: ' + esc(r.disponible) + (r.notas ? ' · ' + esc(r.notas) : '') : r.ok ? 'Está al día. Se actualiza sola de noche.' : 'No se pudo revisar: ' + esc(r.error || '')) + '</div>' +
        (r.nueva ? '<div style="margin-top:8px"><button type="button" class="btn sm" id="d-act">Actualizar ahora</button> <span style="font-size:12px;color:var(--tx3)">La caja se cerrará un momento.</span></div>' : '') + '</div></div>';
    var b = $('d-act'); if (b) b.addEventListener('click', async function () {
        if (S.carro.length) return toast('Termina la factura en curso antes de actualizar', '', 'warning');
        b.disabled = true; b.textContent = 'Descargando…';
        var x = await P.puente('/version?instalar=1', undefined, 600000);
        toast(x && x.instalando ? 'Instalando la actualización' : 'No se pudo actualizar', x && x.instalando ? 'La caja se reabre sola en unos segundos.' : ((x && x.error) || ''), x && x.instalando ? 'info' : 'error');
    });
}
// ---------- Balanza (pesables) ----------
async function pintarBalanza() {
    var box = $('d-balanza'); if (!box) return;
    box.innerHTML = '<div class="dev ' + (S.cfg.balanza ? 'ok' : '') + '">' + (S.cfg.balanza ? '<span class="st"><span class="material-symbols-outlined" style="font-size:18px">check</span></span>' : '') +
        '<div class="inf"><b>' + (S.cfg.balanza ? 'Balanza en ' + esc(S.cfg.balanza) : 'Sin balanza') + '</b><div>Los productos por kilo toman el peso solo al escanearlos.</div><div style="font-size:12px;color:var(--tx3)">Por probar con tu balanza (CAS, Toledo, Systel y similares por puerto serial).</div>' +
        '<div style="display:flex;gap:6px;flex-wrap:wrap;margin-top:8px"><button type="button" class="btn out sm" id="d-bz-buscar">Buscar balanza</button>' + (S.cfg.balanza ? '<button type="button" class="btn out sm" id="d-bz-leer">Leer peso</button><button type="button" class="btn out sm" id="d-bz-quitar">No usar balanza</button>' : '') + '</div></div></div>';
    $('d-bz-buscar').addEventListener('click', async function () {
        this.disabled = true; this.textContent = 'Buscando…';
        var r = await P.puente('/balanza/detectar', undefined, 60000);
        if (r && r.ok) { S.cfg.balanza = r.puerto; P.guardarCfg(); toast('Balanza encontrada en ' + r.puerto, 'Peso: ' + f2(r.peso, 3) + ' kg', 'success'); }
        else toast('No se encontró la balanza', (r && r.error) || 'Actualiza el programa de la caja', 'warning');
        pintarBalanza();
    });
    var l = $('d-bz-leer'); if (l) l.addEventListener('click', async function () { var r = await P.puente('/balanza/peso', undefined, 5000); toast(r && r.ok ? 'Peso: ' + f2(r.peso, 3) + ' kg' : 'No se leyó la balanza', r && r.ok ? (r.estable ? 'Estable' : 'Inestable') : ((r && r.error) || ''), r && r.ok ? 'info' : 'error'); });
    var q = $('d-bz-quitar'); if (q) q.addEventListener('click', function () { S.cfg.balanza = ''; P.guardarCfg(); pintarBalanza(); });
}
var pintarDispBase = P.pintarDispositivos;
P.pintarDispositivos = async function () { await pintarDispBase(); pintarPendientesFiscales(); pintarBalanza(); pintarVersion(); };

/* ============================================================
   AJUSTES
   ============================================================ */
P.pintarAjustes = function () {
    var c = S.cfg, term = H.ls(H.K_TERM), tok = H.ls(H.K_TOKEN), n = window.refContarPendientes ? window.refContarPendientes() : 0;
    $('v-ajustes').innerHTML = '<div class="vh"><div><h1>Ajustes</h1><p>Configura esta caja: su tienda, la impresora y la apariencia.</p></div></div>' +
        '<div style="display:grid;grid-template-columns:repeat(auto-fill,minmax(360px,1fr));gap:16px;align-items:start">' +
        '<div class="card"><h2>Esta caja</h2><div class="campo"><span>Tienda</span><div style="display:flex;gap:8px"><input class="in" value="' + esc(S.tienda.nombre) + '" disabled/>' + (S.user.rol === 'admin' || (S.user.sucursales || []).length !== 1 ? '<button type="button" class="btn out sm" id="aj-tienda" style="height:44px">Cambiar</button>' : '') + '</div></div>' +
            '<div class="campo"><span>Nombre de la caja</span><div style="display:flex;gap:8px"><input class="in" id="aj-term" value="' + esc(term || '') + '" placeholder="Ej: CAJA 1"' + (tok ? ' disabled' : '') + '/>' + (tok ? '' : '<button type="button" class="btn out sm" id="aj-reg" style="height:44px">Registrar</button>') + '</div>' + (tok ? '<span style="font-size:12px;color:var(--ok)">Registrada en el sistema (aparece en Puntos de venta)</span>' : '<span style="font-size:12px;color:var(--tx3)">Registrar la caja permite verla y controlarla desde el sistema administrativo.</span>') + '</div></div>' +
        '<div class="card"><h2>Impresión</h2><div class="campo"><span>Modo de impresión</span><select id="aj-modo" class="in"><option value="ticket">Ticket térmico (no fiscal)</option><option value="fiscal">Impresora fiscal (SENIAT)</option><option value="navegador">Diálogo del navegador</option></select></div>' +
            '<div class="g2"><div class="campo"><span>Ancho del ticket</span><select id="aj-ancho" class="in"><option value="42">80 mm</option><option value="32">58 mm</option></select></div><div class="campo"><span>Puerto fiscal</span><input id="aj-puerto" class="in" value="' + esc(c.puerto === 'AUTO' ? '' : c.puerto) + '" placeholder="Automático"/></div></div>' +
            '<label style="display:flex;align-items:center;justify-content:space-between;gap:10px;padding:6px 0;cursor:pointer"><span>Abrir gaveta al cobrar en efectivo</span><button type="button" class="sw' + (c.gaveta ? ' on' : '') + '" id="aj-gav"></button></label>' +
            '<details style="margin-top:8px"><summary style="cursor:pointer;color:var(--az-t);font-size:14px">Códigos de pago (solo impresoras Bixolon / HKA)</summary><div class="g3" style="margin-top:10px">' +
            Object.keys(c.codigos).map(function (k) { return '<div class="campo"><span>' + esc(H.METODO_NOMBRE[k] || k) + (k === 'divisa' ? ' $' : '') + '</span><input class="in" data-cod="' + k + '" value="' + esc(c.codigos[k]) + '" maxlength="2"/></div>'; }).join('') + '</div><span style="font-size:12px;color:var(--tx3)">Deben coincidir con los medios de pago programados en la impresora fiscal (01 a 16).</span></details></div>' +
        '<div class="card"><h2>Pantalla</h2><label style="display:flex;align-items:center;justify-content:space-between;gap:10px;padding:6px 0;cursor:pointer"><span>Tema oscuro</span><button type="button" class="sw' + (window.temaActual() === 'oscuro' ? ' on' : '') + '" id="aj-tema"></button></label>' +
            '<label style="display:flex;align-items:center;justify-content:space-between;gap:10px;padding:6px 0;cursor:pointer"><span>Sonidos al escanear</span><button type="button" class="sw' + (c.sonido ? ' on' : '') + '" id="aj-son"></button></label>' +
            '<button type="button" class="btn out sm" id="aj-instalar" style="margin-top:8px"><span class="material-symbols-outlined">install_desktop</span>Instalar como aplicación</button> <a class="btn out sm" href="REFRIMAR-POS-Setup.exe" download style="margin-top:8px"><span class="material-symbols-outlined">download</span>App para Windows</a></div>' +
        '<div class="card"><h2>Datos</h2><div style="font-size:14px;color:var(--tx2);line-height:1.8">Productos en esta caja: <b>' + S.catalogo.length + '</b><br/>Ventas por sincronizar: <b>' + n + '</b><br/>Versión: <b>' + H.VERSION + '</b></div>' +
            '<div style="display:flex;gap:8px;flex-wrap:wrap;margin-top:10px"><button type="button" class="btn out sm" id="aj-cat"><span class="material-symbols-outlined">sync</span>Actualizar catálogo</button><button type="button" class="btn out sm" id="aj-sync"><span class="material-symbols-outlined">cloud_upload</span>Sincronizar ventas</button></div></div></div>';
    $('aj-modo').value = c.modo; $('aj-ancho').value = String(c.ancho);
    $('aj-modo').addEventListener('change', function () { c.modo = this.value; c.modoManual = true; P.guardarCfg(); P.estadoPuente(); toast('Modo de impresión: ' + this.options[this.selectedIndex].text, '', 'info'); });
    $('aj-ancho').addEventListener('change', function () { c.ancho = Number(this.value); P.guardarCfg(); });
    $('aj-puerto').addEventListener('change', function () { c.puerto = this.value.trim().toUpperCase() || 'AUTO'; c.puertoManual = c.puerto !== 'AUTO'; P.guardarCfg(); P.puente('/fiscal/config', { puerto: c.puerto }); });
    $('aj-gav').addEventListener('click', function () { c.gaveta = !c.gaveta; this.classList.toggle('on', c.gaveta); P.guardarCfg(); });
    $('aj-son').addEventListener('click', function () { c.sonido = !c.sonido; this.classList.toggle('on', c.sonido); P.guardarCfg(); });
    $('aj-tema').addEventListener('click', function () { var o = window.temaActual() !== 'oscuro'; window.ponerTema(o ? 'oscuro' : 'claro'); this.classList.toggle('on', o); });
    document.querySelectorAll('[data-cod]').forEach(function (i) { i.addEventListener('change', function () { c.codigos[i.dataset.cod] = i.value.replace(/\D/g, '').padStart(2, '0').slice(-2); i.value = c.codigos[i.dataset.cod]; P.guardarCfg(); }); });
    $('aj-cat').addEventListener('click', function () { P.cargarConfig().then(P.cargarCatalogo).then(function () { toast('Catálogo actualizado', S.catalogo.length + ' productos'); P.pintarAjustes(); }); });
    $('aj-sync').addEventListener('click', function () { if (window.refSincronizarPendientes) window.refSincronizarPendientes(); setTimeout(function () { P.pintarSync(); P.pintarAjustes(); }, 1500); });
    var bt = $('aj-tienda'); if (bt) bt.addEventListener('click', async function () {
        if (S.carro.length) return toast('Termina o borra la factura en curso antes de cambiar de tienda', '', 'warning');
        var tiendas = await P.cargarTiendas(), perm = S.user.rol === 'admin' ? null : S.user.sucursales || [];
        var op = perm && perm.length ? tiendas.filter(function (t) { return perm.indexOf(t.id) >= 0; }) : tiendas;
        var t = await P.elegirTienda(op, 'Tienda de esta caja'); if (!t) return;
        S.tienda = t; H.ls(H.K_TIENDA, t); window.guardarSucursalSesion(t);
        $('t-tienda-v').textContent = t.nombre; P.cargarCatalogo(); P.cargarTurno(); P.pintarAjustes(); toast('Esta caja ahora es de ' + t.nombre, '', 'info');
    });
    var br = $('aj-reg'); if (br) br.addEventListener('click', async function () {
        var nm = $('aj-term').value.trim(); if (!nm) return $('aj-term').classList.add('err');
        var r = await supabaseClient.rpc('terminal_registrar', { p_nombre: nm, p_sucursal_id: S.tienda.id, p_sucursal_nombre: S.tienda.nombre });
        if (r.error) return toast('No se pudo registrar la caja', H.errMsg(r.error), 'error');
        H.ls(H.K_TOKEN, r.data.token); H.ls(H.K_TERM, nm.toUpperCase()); toast('Caja registrada', nm.toUpperCase()); P.pintarAjustes();
    });
    $('aj-instalar').addEventListener('click', function () {
        if (window.__posInstall) { window.__posInstall.prompt(); window.__posInstall = null; }
        else toast('Para instalarla', 'En Chrome o Edge usa el ícono de instalar en la barra de direcciones (o Menú → Instalar REFRIMAR POS).', 'info');
    });
};
window.addEventListener('beforeinstallprompt', function (e) { e.preventDefault(); window.__posInstall = e; });
})();
