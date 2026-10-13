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
        return Number.isInteger(v) ? String(v) : v.toLocaleString('es-VE', { maximumFractionDigits: 3 });
    };
    nk.usd = function (n) { return '$' + nk.num(n); };
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
        ordenada: ['Ordenada', 'nk-b-blue'], revisado: ['Revisado', 'nk-b-violet'],
        cancelada: ['Cancelada', 'nk-b-red'], anulada: ['Anulada', 'nk-b-red'], nota_credito: ['Nota de crédito', 'nk-b-violet'],
        error: ['Error', 'nk-b-red']
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
                empty.innerHTML = '<span class="material-symbols-outlined">inbox</span><b>' + nk.esc((opts.empty && opts.empty.title) || 'No hay registros') + '</b><span>' + nk.esc((opts.empty && opts.empty.sub) || '') + '</span>';
                empty.classList.remove('hidden-modal');
            } else empty.classList.add('hidden-modal');
            el.querySelector('.nk-pag-info').textContent = 'de ' + list.length + ' filas.';
            el.querySelector('.nk-pag-cur').textContent = st.page;
        }
        return {
            setRows: function (rows) { st.rows = rows || []; render(); },
            rows: function () { return st.rows; },
            refresh: render,
            setLoading: function () { tbody.innerHTML = '<tr><td colspan="' + opts.columns.length + '" class="nk-loading">Cargando…</td></tr>'; }
        };
    };
})();
