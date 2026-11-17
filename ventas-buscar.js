// Buscador de facturas para garantías y despachos (v3.9.27).
// refBuscarFactura(contenedor, alElegir(venta, lineas)) pinta el buscador dentro de "contenedor".
(function () {
    function esc(s) { return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); }
    function usd(v) { return '$' + Number(v || 0).toLocaleString('es-VE', { minimumFractionDigits: 2, maximumFractionDigits: 2 }); }
    function fecha(f) { return f ? new Date(f).toLocaleDateString('es-VE') : ''; }

    window.refBuscarFactura = function (cont, alElegir) {
        cont.innerHTML = '<div class="vb-row"><label class="nk-field"><span>Factura</span><input class="nk-input" data-vb-q placeholder="Número de factura o nombre del cliente" autocomplete="off"/></label>' +
            '<button type="button" class="nk-btn nk-btn-outline" data-vb-b><span class="material-symbols-outlined">search</span>Buscar</button></div><div class="vb-res" data-vb-res></div>';
        var q = cont.querySelector('[data-vb-q]'), res = cont.querySelector('[data-vb-res]'), lista = [];
        async function buscar() {
            var t = q.value.trim().replace(/[,()*%]/g, ' ').trim();
            if (t.length < 2) { res.innerHTML = '<p class="nk-hint">Escribe el número de la factura (o parte) o el nombre del cliente.</p>'; return; }
            res.innerHTML = '<p class="nk-hint">Buscando…</p>';
            var r = await window.supabaseClient.from('ventas').select('id,numero,numero_doc,cliente_nombre,cliente_rif,cliente_telefono,total_usd,created_at,estado,sucursal_id,sucursal_nombre')
                .or('numero_doc.ilike.*' + t + '*,numero.ilike.*' + t + '*,cliente_nombre.ilike.*' + t + '*')
                .eq('estado', 'completada').order('created_at', { ascending: false }).limit(8);
            if (r.error) { res.innerHTML = '<p class="nk-hint">' + esc(r.error.message) + '</p>'; return; }
            lista = r.data || [];
            res.innerHTML = lista.length ? lista.map(function (v, i) {
                return '<button type="button" data-vb-i="' + i + '"><span><b>' + esc(v.numero_doc || v.numero) + ' · ' + esc(v.cliente_nombre || 'Consumidor final') + '</b><small>' + fecha(v.created_at) + ' · ' + esc(v.sucursal_nombre || 'Principal') + '</small></span><b>' + usd(v.total_usd) + '</b></button>';
            }).join('') : '<p class="nk-hint">No hay facturas con "' + esc(t) + '".</p>';
            res.querySelectorAll('[data-vb-i]').forEach(function (b) {
                b.addEventListener('click', async function () {
                    res.querySelectorAll('[data-vb-i]').forEach(function (x) { x.classList.toggle('on', x === b); });
                    var v = lista[Number(b.dataset.vbI)];
                    var d = await window.supabaseClient.from('detalle_venta').select('producto_codigo,descripcion,cantidad,precio_unitario,total').eq('venta_id', v.id);
                    var por = {};
                    ((d && d.data) || []).forEach(function (l) {
                        var k = l.producto_codigo;
                        if (!por[k]) por[k] = { codigo: k, descripcion: l.descripcion, cantidad: 0 };
                        por[k].cantidad += Number(l.cantidad) || 0;
                    });
                    alElegir(v, Object.keys(por).map(function (k) { return por[k]; }));
                });
            });
        }
        cont.querySelector('[data-vb-b]').addEventListener('click', buscar);
        q.addEventListener('keydown', function (e) { if (e.key === 'Enter') { e.preventDefault(); buscar(); } });
        setTimeout(function () { q.focus(); }, 50);
    };

    // 0414-123.45.67 → 584141234567 (para wa.me)
    window.refTelWhatsApp = function (t) {
        var d = String(t || '').replace(/\D/g, '');
        if (!d) return '';
        if (d.indexOf('58') === 0 && d.length >= 12) return d;
        if (d.charAt(0) === '0') d = d.slice(1);
        return d.length === 10 ? '58' + d : d;
    };
})();
