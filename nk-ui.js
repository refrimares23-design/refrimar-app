/* ============================================================
   REFRIMAR — componentes estilo Norkut (listas, modales, formatos)
   Lo usan las páginas nuevas: facturas, turnos, conteos, precios,
   órdenes de compra y app POS.
   ============================================================ */
(function () {
    'use strict';
    var nk = window.nk = {};
    var CASA = '00000000-0000-0000-0000-000000000001';

    nk.esc = function (s) {
        return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
            return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
        });
    };
    nk.num = function (n, dec) {
        var v = Number(n) || 0;
        return v.toLocaleString('es-VE', { minimumFractionDigits: dec == null ? 2 : dec, maximumFractionDigits: dec == null ? 2 : dec });
    };
    nk.qty = function (n) {
        var v = Number(n) || 0;
        if (v >= 999999) return '∞';
        return Number.isInteger(v) ? String(v) : v.toLocaleString('es-VE', { maximumFractionDigits: 3 });
    };
    nk.usd = function (n) { var v = Number(n) || 0; return (v < 0 ? '−$' : '$') + nk.num(Math.abs(v)); };
    nk.bs = function (n) { return nk.num(n) + ' Bs'; };
    nk.fecha = function (iso) {
        if (!iso) return '-';
        var d = new Date(String(iso).length === 10 ? iso + 'T12:00:00' : iso);
        return isNaN(d) ? '-' : d.toLocaleDateString('es-VE', { day: '2-digit', month: '2-digit', year: 'numeric' });
    };
    nk.hora = function (iso) {
        if (!iso) return '';
        var d = new Date(iso);
        return isNaN(d) ? '' : d.toLocaleTimeString('es-VE', { hour: '2-digit', minute: '2-digit' });
    };
    nk.fechaHora = function (iso) { return iso ? nk.fecha(iso) + ' ' + nk.hora(iso) : '-'; };
    nk.hoyISO = function () { var d = new Date(); d.setMinutes(d.getMinutes() - d.getTimezoneOffset()); return d.toISOString().slice(0, 10); };

    nk.user = function () { return window.getSesionUsuario ? window.getSesionUsuario() : null; };
    nk.esAdmin = function () { var u = nk.user(); return !!(u && u.rol === 'admin'); };
    nk.suc = function () {
        var s = window.getSucursalActual ? window.getSucursalActual() : null;
        return s && s.id ? s : { id: CASA, nombre: 'Casa Matriz' };
    };
    nk.esCasa = function (id) { id = id === undefined ? nk.suc().id : id; return !id || id === CASA; };
    nk.CASA = CASA;

    // Filtro por sucursal activa (Casa Matriz incluye registros viejos sin sucursal)
    nk.porSucursal = function (q, col) {
        col = col || 'sucursal_id';
        var id = nk.suc().id;
        return nk.esCasa(id) ? q.or(col + '.eq.' + CASA + ',' + col + '.is.null') : q.eq(col, id);
    };

    function toastPropio(msg, type) {
        var c = document.getElementById('toast-container');
        if (!c) { alert(msg); return; }
        var t = document.createElement('div');
        t.className = 'toast toast-' + (type || 'success');
        var icon = type === 'error' ? 'error' : type === 'warning' ? 'warning' : type === 'info' ? 'info' : 'check_circle';
        t.innerHTML = '<span class="material-symbols-outlined" style="font-size:18px;">' + icon + '</span><span>' + nk.esc(msg) + '</span>';
        c.appendChild(t);
        requestAnimationFrame(function () { t.classList.add('show'); });
        setTimeout(function () { t.classList.remove('show'); setTimeout(function () { t.remove(); }, 350); }, 3800);
    }
    nk.toast = function (msg, type) {
        var f = (typeof window.showToast === 'function' && window.showToast !== nk.toast) ? window.showToast : toastPropio;
        return f(msg, type);
    };
    if (typeof window.showToast !== 'function') window.showToast = toastPropio;

    nk.errMsg = function (e) {
        var m = (e && (e.message || e.error_description || e.details)) || String(e || 'Error');
        if (/Could not find the function|schema cache|does not exist/i.test(m)) {
            return 'Falta correr en Supabase el archivo supabase-migration-norkut-completo.sql';
        }
        return m;
    };

    // Sesión obligatoria (la página de permisos la valida auth-session.js)
    nk.boot = function () {
        var u = nk.user();
        if (!u) { location.href = 'login.html'; return null; }
        if (Date.now() - (u.loginAt || 0) > 8 * 60 * 60 * 1000) { window.limpiarSesion(); location.href = 'login.html'; return null; }
        var n = document.getElementById('user-name'); if (n) n.textContent = u.nombre;
        var r = document.getElementById('user-rol'); if (r) r.textContent = u.rol;
        var lo = document.getElementById('logout-btn'); if (lo) lo.addEventListener('click', function () { window.cerrarSesion(); });
        window.toggleSidebar = function () {
            document.getElementById('sidebar').classList.toggle('open');
            document.getElementById('sidebar-overlay').classList.toggle('active');
        };
        return u;
    };

    // ---------- Pastillas de estado ----------
    var ESTADOS = {
        activo: ['Activo', 'nk-b-green'], completada: ['Completada', 'nk-b-green'], recibida: ['Recibida', 'nk-b-green'],
        factura: ['Factura', 'nk-b-green'], procesado: ['Procesado', 'nk-b-green'], asignado: ['Asignado', 'nk-b-violet'],
        cerrado: ['Cerrado', 'nk-b-gray'], cerrada: ['Cerrada', 'nk-b-gray'], inactivo: ['Inactivo', 'nk-b-gray'],
        borrador: ['Borrador', 'nk-b-gray'], omitido: ['Omitido', 'nk-b-gray'], revertida: ['Revertida', 'nk-b-gray'],
        pendiente: ['Pendiente', 'nk-b-amber'], en_progreso: ['En progreso', 'nk-b-blue'], parcial: ['Parcial', 'nk-b-amber'],
        ordenada: ['Ordenada', 'nk-b-blue'], programada: ['Programada', 'nk-b-blue'], cancelado: ['Cancelado', 'nk-b-red'], revisado: ['Revisado', 'nk-b-violet'],
        cancelada: ['Cancelada', 'nk-b-red'], anulada: ['Anulada', 'nk-b-red'], nota_credito: ['Nota de crédito', 'nk-b-violet'],
        error: ['Error', 'nk-b-red'],
        optimo: ['Stock óptimo', 'nk-b-green'], excedente: ['Stock excedente', 'nk-b-amber'], bajo: ['Stock bajo', 'nk-b-amber'], critico: ['Stock crítico', 'nk-b-red'], servicio: ['Servicio', 'nk-b-blue']
    };
    nk.badge = function (estado, label) {
        var key = String(estado || '').toLowerCase();
        if (key.indexOf('error') === 0) key = 'error';
        var e = ESTADOS[key] || [estado || '-', 'nk-b-gray'];
        return '<span class="nk-badge ' + e[1] + '">' + nk.esc(label || e[0]) + '</span>';
    };

    // ---------- Modal ----------
    nk.modal = function (opts) {
        var wrap = document.createElement('div');
        wrap.className = 'nk-modal-wrap';
        wrap.innerHTML = '<div class="nk-modal' + (opts.wide ? ' nk-modal-wide' : '') + '">' +
            '<div class="nk-modal-head"><h3>' + nk.esc(opts.title || '') + '</h3>' +
            '<button type="button" class="nk-icon-close" aria-label="Cerrar"><span class="material-symbols-outlined">close</span></button></div>' +
            '<div class="nk-modal-body">' + (opts.body || '') + '</div>' +
            (opts.footer ? '<div class="nk-modal-foot">' + opts.footer + '</div>' : '') + '</div>';
        document.body.appendChild(wrap);
        function close() { wrap.remove(); document.removeEventListener('keydown', onKey); if (opts.onClose) opts.onClose(); }
        function onKey(e) { if (e.key === 'Escape') close(); }
        wrap.querySelector('.nk-icon-close').addEventListener('click', close);
        wrap.addEventListener('mousedown', function (e) { if (e.target === wrap) close(); });
        document.addEventListener('keydown', onKey);
        var first = wrap.querySelector('input:not([type=hidden]):not([disabled]), select, textarea');
        if (first) setTimeout(function () { first.focus(); }, 30);
        return { el: wrap, close: close, $: function (sel) { return wrap.querySelector(sel); } };
    };

    // Botón ocupado mientras corre una acción async
    nk.busy = async function (btn, fn) {
        if (btn && btn.disabled) return;
        var txt = btn ? btn.innerHTML : '';
        if (btn) { btn.disabled = true; btn.innerHTML = 'Procesando…'; }
        try { return await fn(); }
        finally { if (btn) { btn.disabled = false; btn.innerHTML = txt; } }
    };

    // ---------- Tabla con pestañas, búsqueda, filtros y paginación ----------
    nk.table = function (opts) {
        var st = { rows: [], tab: (opts.tabs && opts.tabs[0] && opts.tabs[0].key) || null, q: '', filtros: {}, page: 1, size: opts.pageSize || 10 };
        var el = typeof opts.el === 'string' ? document.querySelector(opts.el) : opts.el;
        el.classList.add('nk-card');
        el.innerHTML =
            (opts.tabs ? '<div class="nk-tabs">' + opts.tabs.map(function (t) {
                return '<button type="button" class="nk-tab" data-tab="' + t.key + '">' + (t.icon ? '<span class="material-symbols-outlined">' + t.icon + '</span>' : '') + nk.esc(t.label) + '<span class="nk-tab-count"></span></button>';
            }).join('') + '</div>' : '') +
            '<label class="nk-search"><input type="search" placeholder="' + nk.esc(opts.placeholder || 'Buscar') + '"/><span class="material-symbols-outlined">search</span></label>' +
            (opts.filters && opts.filters.length ? '<div class="nk-chips">' + opts.filters.map(function (f) {
                return '<select class="nk-chip" data-filtro="' + f.key + '"><option value="">' + nk.esc(f.label) + '</option>' +
                    (f.options || []).map(function (o) { return '<option value="' + nk.esc(o.value) + '">' + nk.esc(o.label) + '</option>'; }).join('') + '</select>';
            }).join('') + '</div>' : '') +
            '<div class="nk-table-wrap"><table class="nk-table"><thead><tr>' + opts.columns.map(function (c) {
                return '<th class="' + (c.thCls || c.cls || '') + '">' + nk.esc(c.label) + '</th>';
            }).join('') + '</tr></thead><tbody></tbody></table></div>' +
            '<div class="nk-empty hidden-modal"></div>' +
            '<div class="nk-pag"><span>Filas por página</span><select class="nk-size"><option>10</option><option>25</option><option>50</option><option>100</option></select>' +
            '<span class="nk-pag-info"></span><button type="button" data-p="first">«</button><button type="button" data-p="prev">‹</button>' +
            '<span class="nk-pag-cur">1</span><button type="button" data-p="next">›</button><button type="button" data-p="last">»</button></div>';

        var tbody = el.querySelector('tbody');
        el.querySelectorAll('.nk-tab').forEach(function (b) {
            b.addEventListener('click', function () { st.tab = b.dataset.tab; st.page = 1; render(); });
        });
        el.querySelector('.nk-search input').addEventListener('input', function (e) { st.q = e.target.value.trim().toLowerCase(); st.page = 1; render(); });
        el.querySelectorAll('[data-filtro]').forEach(function (s) {
            s.addEventListener('change', function () { st.filtros[s.dataset.filtro] = s.value; st.page = 1; render(); s.classList.toggle('on', !!s.value); });
        });
        el.querySelector('.nk-size').addEventListener('change', function (e) { st.size = Number(e.target.value) || 10; st.page = 1; render(); });
        el.querySelectorAll('[data-p]').forEach(function (b) {
            b.addEventListener('click', function () {
                var pages = Math.max(1, Math.ceil(filtrados().length / st.size));
                if (b.dataset.p === 'first') st.page = 1;
                if (b.dataset.p === 'prev') st.page = Math.max(1, st.page - 1);
                if (b.dataset.p === 'next') st.page = Math.min(pages, st.page + 1);
                if (b.dataset.p === 'last') st.page = pages;
                render();
            });
        });

        function pasaTab(r, key) {
            var t = (opts.tabs || []).find(function (x) { return x.key === key; });
            return !t || !t.test || t.test(r);
        }
        function filtrados() {
            return st.rows.filter(function (r) {
                if (st.tab && !pasaTab(r, st.tab)) return false;
                if (st.q && opts.search && String(opts.search(r) || '').toLowerCase().indexOf(st.q) < 0) return false;
                for (var k in st.filtros) {
                    var v = st.filtros[k];
                    if (!v) continue;
                    var f = opts.filters.find(function (x) { return x.key === k; });
                    if (f && f.test && !f.test(r, v)) return false;
                }
                return true;
            });
        }
        function render() {
            el.querySelectorAll('.nk-tab').forEach(function (b) {
                b.classList.toggle('active', b.dataset.tab === st.tab);
                var n = st.rows.filter(function (r) { return pasaTab(r, b.dataset.tab); }).length;
                b.querySelector('.nk-tab-count').textContent = st.rows.length ? ' ' + n : '';
            });
            var list = filtrados();
            var pages = Math.max(1, Math.ceil(list.length / st.size));
            if (st.page > pages) st.page = pages;
            var slice = list.slice((st.page - 1) * st.size, st.page * st.size);
            tbody.innerHTML = slice.map(function (r, i) {
                return '<tr data-i="' + i + '"' + (opts.onRow ? ' class="nk-row-click"' : '') + '>' + opts.columns.map(function (c) {
                    return '<td class="' + (c.cls || '') + '">' + c.render(r) + '</td>';
                }).join('') + '</tr>';
            }).join('');
            if (opts.onRow) {
                tbody.querySelectorAll('tr').forEach(function (tr) {
                    tr.addEventListener('click', function (e) {
                        if (e.target.closest('button, a, input, select')) return;
                        opts.onRow(slice[Number(tr.dataset.i)]);
                    });
                });
            }
            if (opts.afterRender) opts.afterRender(tbody, slice);
            var empty = el.querySelector('.nk-empty');
            if (!list.length) {
                var buscando = !!st.q || Object.keys(st.filtros).some(function (k) { return st.filtros[k]; });
                var e = opts.empty || {};
                empty.innerHTML = buscando && st.rows.length ?
                    window.refEstado('busqueda', 'Sin resultados', st.q ? 'No encontramos nada con "' + st.q + '". Prueba con otra palabra o quita los filtros.' : 'Ningún registro coincide con los filtros.', '', 'sm') :
                    window.refEstado(e.tipo || 'vacio', e.title || 'No hay registros', e.sub || '', '', 'sm');
                empty.classList.remove('hidden-modal');
            } else empty.classList.add('hidden-modal');
            el.querySelector('.nk-pag-info').textContent = 'de ' + list.length + ' filas.';
            el.querySelector('.nk-pag-cur').textContent = st.page;
        }
        return {
            setRows: function (rows) { st.rows = rows || []; render(); },
            rows: function () { return st.rows; },
            refresh: render,
            setLoading: function () { tbody.innerHTML = '<tr><td colspan="' + opts.columns.length + '" class="nk-loading">' + window.refEstado('cargando', 'Cargando…', '', '', 'sm') + '</td></tr>'; }
        };
    };

    // ---------- Etiquetas con código de barras ----------
    nk.cargarScript = function (src, test) {
        return new Promise(function (ok, ko) {
            if (test && test()) return ok();
            var s = document.createElement('script'); s.src = src;
            s.onload = function () { ok(); }; s.onerror = function () { ko(new Error('No se pudo cargar ' + src.split('/').pop() + '. Revisa tu internet.')); };
            document.head.appendChild(s);
        });
    };
    function eanValido(c) {
        if (!/^\d{13}$/.test(c)) return false;
        var s = 0; for (var i = 0; i < 12; i++) s += Number(c[i]) * (i % 2 ? 3 : 1);
        return (10 - s % 10) % 10 === Number(c[12]);
    }
    nk.barcodeSVG = function (codigo, alto) {
        var svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
        var cod = String(codigo || '').trim();
        try {
            window.JsBarcode(svg, cod, { format: eanValido(cod) ? 'EAN13' : 'CODE128', height: alto || 40, width: 1.6, fontSize: 12, margin: 0, displayValue: true, flat: true });
        } catch (e) {
            window.JsBarcode(svg, cod.replace(/[^\x20-\x7E]/g, '') || '0', { format: 'CODE128', height: alto || 40, width: 1.4, fontSize: 12, margin: 0 });
        }
        return svg.outerHTML;
    };
    nk.etiquetas = function (productos) {
        productos = (productos || []).filter(function (p) { return p && p.codigo; });
        if (!productos.length) { nk.toast('Selecciona al menos un producto', 'warning'); return; }
        var m = nk.modal({
            title: 'Imprimir etiquetas (' + productos.length + ' producto' + (productos.length > 1 ? 's' : '') + ')',
            body: '<div class="nk-grid2">' +
                '<label class="nk-field"><span>Tamaño</span><select id="et-tam" class="nk-input"><option value="50x25">Rollo térmico 50 × 25 mm</option><option value="40x30">Rollo térmico 40 × 30 mm</option><option value="58x40">Rollo térmico 58 × 40 mm</option><option value="a4">Hoja carta/A4 (3 columnas)</option></select></label>' +
                '<label class="nk-field"><span>Copias de cada una</span><input id="et-cop" type="number" min="1" max="200" value="1" class="nk-input"/></label>' +
                '<label class="nk-field"><span>Precio</span><select id="et-precio" class="nk-input"><option value="usd">En dólares</option><option value="bs">En bolívares</option><option value="ambos">Dólares y bolívares</option><option value="no">Sin precio</option></select></label>' +
                '<label class="nk-field"><span>Nombre</span><select id="et-nom" class="nk-input"><option value="1">Mostrar nombre</option><option value="0">Solo código</option></select></label>' +
                '</div><p class="nk-hint">Los códigos de 13 dígitos válidos se imprimen como EAN-13; los demás como Code 128. Ambos los lee cualquier escáner.</p>',
            footer: '<button class="nk-btn" data-a="ok"><span class="material-symbols-outlined">print</span>Imprimir</button>'
        });
        m.$('[data-a="ok"]').addEventListener('click', function (e) {
            var tam = m.$('#et-tam').value, cop = Math.max(1, Math.min(200, Number(m.$('#et-cop').value) || 1)), modoP = m.$('#et-precio').value, conNom = m.$('#et-nom').value === '1';
            nk.busy(e.currentTarget, async function () {
                try { await nk.cargarScript('https://cdn.jsdelivr.net/npm/jsbarcode@3.11.6/dist/JsBarcode.all.min.js', function () { return !!window.JsBarcode; }); }
                catch (err) { nk.toast(err.message, 'error'); return; }
                var tasa = 0;
                if (modoP === 'bs' || modoP === 'ambos') {
                    try { var r = await supabaseClient.from('configuracion').select('tasa_bcv_manual').limit(1).maybeSingle(); tasa = r && r.data ? Number(r.data.tasa_bcv_manual) || 0 : 0; } catch (x) {}
                }
                var dims = { '50x25': [50, 25, 26], '40x30': [40, 30, 30], '58x40': [58, 40, 42] }[tam];
                var labels = [];
                productos.forEach(function (p) {
                    var precio = Number(p.precio) || 0;
                    var ptxt = modoP === 'no' ? '' : modoP === 'usd' ? nk.usd(precio) : modoP === 'bs' ? (tasa ? nk.bs(precio * tasa) : nk.usd(precio)) : nk.usd(precio) + (tasa ? ' · ' + nk.bs(precio * tasa) : '');
                    var html = '<div class="et">' + (conNom ? '<div class="n">' + nk.esc(p.descripcion) + '</div>' : '') + '<div class="b">' + nk.barcodeSVG(p.codigo, dims ? dims[2] : 38) + '</div>' + (ptxt ? '<div class="p">' + nk.esc(ptxt) + '</div>' : '') + '</div>';
                    for (var i = 0; i < cop; i++) labels.push(html);
                });
                var css = dims ?
                    '@page{size:' + dims[0] + 'mm ' + dims[1] + 'mm;margin:0}body{margin:0}.et{width:' + dims[0] + 'mm;height:' + dims[1] + 'mm;box-sizing:border-box;padding:1.2mm 2mm;display:flex;flex-direction:column;align-items:center;justify-content:center;overflow:hidden;page-break-after:always;break-after:page}' :
                    '@page{size:auto;margin:8mm}body{margin:0}.wrap{display:grid;grid-template-columns:repeat(3,1fr);gap:3mm}.et{border:1px dashed #bbb;height:32mm;box-sizing:border-box;padding:2mm;display:flex;flex-direction:column;align-items:center;justify-content:center;overflow:hidden;break-inside:avoid}';
                css += '*{font-family:Arial,Helvetica,sans-serif;color:#000}.n{font-size:8.5pt;line-height:1.1;text-align:center;max-height:2.3em;overflow:hidden;width:100%;font-weight:bold}.b{width:100%;display:flex;justify-content:center}.b svg{max-width:100%;height:auto}.p{font-size:11pt;font-weight:bold;margin-top:.4mm}';
                var doc = '<!doctype html><html><head><meta charset="utf-8"><title>Etiquetas</title><style>' + css + '</style></head><body>' + (dims ? labels.join('') : '<div class="wrap">' + labels.join('') + '</div>') + '</body></html>';
                var fr = document.createElement('iframe');
                fr.style.cssText = 'position:fixed;right:0;bottom:0;width:0;height:0;border:0;visibility:hidden';
                document.body.appendChild(fr);
                fr.onload = function () {
                    setTimeout(function () {
                        try { fr.contentWindow.focus(); fr.contentWindow.print(); } catch (x) { nk.toast('No se pudo abrir la impresión', 'error'); }
                        setTimeout(function () { fr.remove(); }, 60000);
                    }, 250);
                };
                fr.srcdoc = doc;
                m.close();
                nk.toast(labels.length + ' etiqueta' + (labels.length > 1 ? 's' : '') + ' enviada' + (labels.length > 1 ? 's' : '') + ' a imprimir', 'success');
            });
        });
    };

    // ---------- Buscador de productos (para órdenes, transferencias, conteos) ----------
    // opts: { productos: [...], titulo, extra(p) → html a la derecha, onPick(p) }
    nk.buscadorProductos = function (opts) {
        var lista = opts.productos || [];
        var m = nk.modal({
            title: opts.titulo || 'Buscador de productos', wide: true,
            body: '<label class="nk-search" style="margin:0 0 10px"><input type="search" id="bp-q" placeholder="Escanea o escribe nombre, código o marca" autocomplete="off"/><span class="material-symbols-outlined">search</span></label>' +
                '<div class="nk-hint" id="bp-n" style="margin-bottom:6px"></div><div class="bp-list" id="bp-list"></div>',
            footer: '<button class="nk-btn" data-a="ok">Listo</button>'
        });
        var agregados = 0;
        function norm(t) { return String(t == null ? '' : t).toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, ''); }
        function pintar() {
            var q = norm(m.$('#bp-q').value.trim());
            var res = !q ? lista.slice(0, 60) : lista.filter(function (p) { return norm(p.descripcion + ' ' + p.codigo + ' ' + (p.marca || '') + ' ' + (p.codigos_alternos || []).join(' ')).indexOf(q) >= 0; }).slice(0, 80);
            m.$('#bp-n').textContent = (q ? res.length + ' resultado(s)' : 'Escribe para buscar · ' + lista.length + ' productos') + (agregados ? ' · ' + agregados + ' agregado(s)' : '');
            m.$('#bp-list').innerHTML = res.map(function (p, i) {
                return '<button type="button" class="bp-it" data-i="' + i + '"><div><b>' + nk.esc(p.descripcion) + '</b><span>' + nk.esc(p.codigo) + (p.marca ? ' · ' + nk.esc(p.marca) : '') + '</span></div><div class="bp-r">' + (opts.extra ? opts.extra(p) : '') + '<span class="material-symbols-outlined">add_circle</span></div></button>';
            }).join('') || window.refEstado('busqueda', 'Sin resultados', 'Prueba con otro nombre o código', '', 'xs');
            m.$('#bp-list').querySelectorAll('.bp-it').forEach(function (b) {
                b.addEventListener('click', function () { opts.onPick(res[Number(b.dataset.i)]); agregados++; b.classList.add('bp-ok'); setTimeout(function () { b.classList.remove('bp-ok'); }, 600); m.$('#bp-n').textContent = agregados + ' agregado(s)'; });
            });
        }
        m.$('#bp-q').addEventListener('input', pintar);
        m.$('#bp-q').addEventListener('keydown', function (e) {
            if (e.key !== 'Enter') return;
            e.preventDefault();
            var q = norm(this.value.trim()); if (!q) return;
            var ex = lista.find(function (p) { return norm(p.codigo) === q || (p.codigos_alternos || []).some(function (a) { return norm(a) === q; }); });
            if (ex) { opts.onPick(ex); agregados++; this.value = ''; pintar(); nk.toast('Agregado: ' + ex.descripcion, 'success'); }
        });
        m.$('[data-a="ok"]').addEventListener('click', m.close);
        pintar();
        return m;
    };
    // Lee un Excel/CSV con columnas código + cantidad (+ costo opcional)
    nk.leerListaExcel = async function (file) {
        await nk.cargarScript('https://cdnjs.cloudflare.com/ajax/libs/xlsx/0.18.5/xlsx.full.min.js', function () { return !!window.XLSX; });
        var wb = window.XLSX.read(await file.arrayBuffer(), { type: 'array' });
        var filas = window.XLSX.utils.sheet_to_json(wb.Sheets[wb.SheetNames[0]], { header: 1, raw: true, defval: '' });
        function n(t) { return String(t == null ? '' : t).toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '').trim(); }
        var h = -1, ci = -1, qi = -1, ki = -1;
        for (var i = 0; i < Math.min(filas.length, 10) && h < 0; i++) {
            (filas[i] || []).forEach(function (c, j) {
                var t = n(c);
                if (ci < 0 && /^(codigo|cod|barra|codigo de barras|sku|referencia)/.test(t)) ci = j;
                if (qi < 0 && /^(cantidad|cant|unidades|qty|conteo|contado)/.test(t)) qi = j;
                if (ki < 0 && /^(costo|precio costo|costo unitario)/.test(t)) ki = j;
            });
            if (ci >= 0) h = i;
        }
        if (h < 0) { h = -1; ci = 0; qi = 1; }
        var out = [];
        filas.slice(h + 1).forEach(function (f) {
            var cod = String(f[ci] == null ? '' : f[ci]).trim(); if (!cod) return;
            if (/e\+/i.test(cod)) cod = String(Number(cod));
            var q = Number(String(f[qi] == null ? '' : f[qi]).replace(',', '.'));
            var k = ki >= 0 ? Number(String(f[ki]).replace(',', '.')) : null;
            out.push({ codigo: cod, cantidad: isFinite(q) ? q : 0, costo: isFinite(k) ? k : null });
        });
        return out;
    };

    // Catálogo completo (paginado) y tiendas
    nk.cargarProductos = async function (cols) {
        var all = [], from = 0;
        while (true) {
            var x = await supabaseClient.from('productos').select(cols || '*').order('descripcion').range(from, from + 999);
            if (x.error) break;
            all = all.concat(x.data || []);
            if (!x.data || x.data.length < 1000) break;
            from += 1000;
        }
        return window.quitarCostos ? window.quitarCostos(all) : all;
    };
    nk.cargarTiendas = async function () {
        var r = await supabaseClient.from('sucursales').select('id,nombre').order('nombre');
        return [{ id: nk.CASA, nombre: 'Casa Matriz' }].concat((r && r.data) || []);
    };
    // Stock de una tienda: { codigo: stock }
    nk.stockTienda = async function (sucId, productos) {
        var m = {};
        if (!sucId || sucId === nk.CASA) { (productos || []).forEach(function (p) { m[p.codigo] = Number(p.stock) || 0; }); return m; }
        var from = 0;
        while (true) {
            var x = await supabaseClient.from('sucursal_stock').select('producto_codigo,stock').eq('sucursal_id', sucId).range(from, from + 999);
            if (x.error) break;
            (x.data || []).forEach(function (r) { m[r.producto_codigo] = Number(r.stock) || 0; });
            if (!x.data || x.data.length < 1000) break;
            from += 1000;
        }
        return m;
    };
    nk.dropdown = function (wrap) {
        var btn = wrap.querySelector('button');
        btn.addEventListener('click', function (e) { e.stopPropagation(); wrap.classList.toggle('open'); });
        wrap.querySelectorAll('.nk-dd-menu button').forEach(function (b) { b.addEventListener('click', function () { wrap.classList.remove('open'); }); });
        document.addEventListener('click', function () { wrap.classList.remove('open'); });
    };

    // ---------- Invitación de colaborador: copiar / Gmail / WhatsApp ----------
    nk.enlaceInvitacion = function (token) {
        var base = location.origin + location.pathname.replace(/[^\/]*$/, '');
        return base + 'invitacion.html?t=' + encodeURIComponent(token);
    };
    nk.compartirInvitacion = function (u, token) {
        var link = nk.enlaceInvitacion(token);
        var nombre = (u.nombres || String(u.nombre || '').split(' ')[0] || '').trim();
        var asunto = 'Invitación para unirte a Comercial Refrimar';
        var cuerpo = 'Hola ' + nombre + ',\n\nComercial Refrimar te invitó a su sistema de ventas e inventario.\n\n' +
            'Para aceptar, abre este enlace, entra con tu cuenta de Google (' + (u.email || '') + ') y crea tu PIN:\n' + link +
            '\n\nEl enlace vence en 15 días.\n\nSaludos,\nComercial Refrimar';
        var tel = String(u.telefono || '').replace(/\D/g, '');
        if (tel && tel.charAt(0) === '0') tel = '58' + tel.slice(1);
        var m = nk.modal({
            title: 'Invitación lista',
            body: '<p style="font-size:14px;color:#3F3F46;margin-bottom:12px">Envíale este enlace a <b style="text-transform:capitalize">' + nk.esc(u.nombre || '') + '</b>. Lo abre, entra con su Google <b>' + nk.esc(u.email || '') + '</b> y crea su PIN. Queda en <b>Pendientes</b> hasta que lo haga.</p>' +
                '<div class="pf-inbtn" style="margin-bottom:14px"><input class="pf-in" id="inv-link" readonly value="' + nk.esc(link) + '"/><button type="button" id="inv-copiar" title="Copiar"><span class="material-symbols-outlined">content_copy</span></button></div>' +
                '<div style="display:grid;grid-template-columns:1fr 1fr;gap:10px">' +
                '<a class="nk-btn nk-btn-outline" target="_blank" rel="noopener" href="https://mail.google.com/mail/?view=cm&fs=1&to=' + encodeURIComponent(u.email || '') + '&su=' + encodeURIComponent(asunto) + '&body=' + encodeURIComponent(cuerpo) + '"><span class="material-symbols-outlined">mail</span>Enviar por Gmail</a>' +
                '<a class="nk-btn nk-btn-outline" target="_blank" rel="noopener" href="https://wa.me/' + tel + '?text=' + encodeURIComponent(cuerpo) + '"><span class="material-symbols-outlined">chat</span>Enviar por WhatsApp</a>' +
                '</div><a href="mailto:' + encodeURIComponent(u.email || '') + '?subject=' + encodeURIComponent(asunto) + '&body=' + encodeURIComponent(cuerpo) + '" style="display:inline-block;margin-top:12px;font-size:13px;color:#0090D9">Abrir en otra app de correo</a>',
            footer: '<button type="button" class="nk-btn" id="inv-ok">Listo</button>'
        });
        m.$('#inv-ok').addEventListener('click', m.close);
        m.$('#inv-copiar').addEventListener('click', function () {
            var inp = m.$('#inv-link');
            (navigator.clipboard ? navigator.clipboard.writeText(link) : Promise.reject()).catch(function () { inp.select(); document.execCommand('copy'); });
            nk.toast('Enlace copiado', 'success');
        });
        return m;
    };
    window.compartirInvitacion = nk.compartirInvitacion;
})();
