// ============================================================
// REFRIMAR — Selector de usuario bonito (inicio de sesión con PIN)
// ------------------------------------------------------------
// La lista nativa del navegador salía negra y fea. Este script deja el <select>
// original escondido (el login lo sigue leyendo igual) y muestra encima una
// lista propia: tarjeta blanca, inicial de cada persona, nombre y rol.
// Se usa en login.html (#user-select) y en la caja pos.html (#l-user).
// ============================================================
(function () {
    'use strict';
    var IDS = ['user-select', 'l-user'];

    function css() {
        if (document.getElementById('su-css')) return;
        var s = document.createElement('style'); s.id = 'su-css';
        s.textContent =
            '.su{position:relative;width:100%;margin-bottom:18px}' +
            '.su-sel{position:absolute!important;opacity:0!important;pointer-events:none!important;width:1px!important;height:1px!important;margin:0!important}' +
            '.su-btn{width:100%;height:48px;display:flex;align-items:center;gap:10px;padding:0 14px 0 6px;border-radius:999px;border:1px solid #CBD3DB;background:#fff;color:#0B1220;font-family:Roboto,Arial,sans-serif;font-size:15px;cursor:pointer;text-align:left;transition:border-color .15s,box-shadow .15s}' +
            '.su-btn:hover{border-color:#94A3B8}' +
            '.su-btn:focus-visible,.su.abierto .su-btn{outline:0;border-color:#0A2540;box-shadow:0 0 0 3px rgba(0,170,255,.18)}' +
            '.su-btn .su-txt{flex:1;min-width:0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}' +
            '.su-btn .su-txt.vacio{color:#71717A;padding-left:8px}' +
            '.su-btn .su-flecha{font-size:22px;color:#52525B;transition:transform .2s}' +
            '.su.abierto .su-flecha{transform:rotate(180deg)}' +
            '.su-av{width:36px;height:36px;flex:none;border-radius:999px;background:var(--rubro-suave,#E6F6FF);color:#0A2540;display:inline-flex;align-items:center;justify-content:center;font-family:Poppins,sans-serif;font-weight:600;font-size:13px}' +
            '.su-lista{position:absolute;left:0;right:0;top:calc(100% + 6px);z-index:60;background:#fff;border-radius:20px;padding:6px;box-shadow:0 0 0 1px rgba(10,37,64,.06),0 18px 40px -12px rgba(10,37,64,.35);max-height:290px;overflow:auto;animation:suIn .14s ease-out}' +
            '@keyframes suIn{from{opacity:0;transform:translateY(-4px)}to{opacity:1;transform:none}}' +
            '.su-op{width:100%;display:flex;align-items:center;gap:10px;padding:7px 10px 7px 7px;border:0;background:none;border-radius:14px;cursor:pointer;text-align:left;color:#0B1220;font-family:Roboto,Arial,sans-serif}' +
            '.su-op:hover,.su-op.act{background:var(--rubro-suave,#E6F6FF)}' +
            '.su-op b{display:block;font-weight:500;font-size:15px;text-transform:capitalize;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}' +
            '.su-op small{display:block;font-size:12px;color:#52525B}' +
            '.su-op .su-ok{margin-left:auto;font-size:20px;color:var(--rubro-oscuro,#0090D9);visibility:hidden}' +
            '.su-op[aria-selected="true"] .su-ok{visibility:visible}' +
            '.su-vacio{padding:14px;text-align:center;font-size:14px;color:#71717A}' +
            '.su-buscar{width:100%;height:40px;border:1px solid #E3E8ED;border-radius:999px;padding:0 14px;margin:2px 0 6px;font-size:14px;outline:none;color:#0B1220;background:#fff}' +
            '.su-buscar:focus{border-color:#0A2540}';
        document.head.appendChild(s);
    }
    function esc(s) { return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); }
    function ini(n) { return String(n || '?').trim().split(/\s+/).map(function (p) { return p.charAt(0); }).join('').slice(0, 2).toUpperCase(); }
    function rolDe(op) {
        var r = op.getAttribute('data-rol');
        if (!r) { var m = /\(([^)]+)\)\s*$/.exec(op.textContent || ''); r = m ? m[1] : ''; }
        return r ? (window.nombreRol ? window.nombreRol(r) : r) : '';
    }
    function nombreDe(op) { return String(op.textContent || '').replace(/\s*\([^)]*\)\s*$/, '').trim(); }

    function mejorar(sel) {
        if (!sel || sel.dataset.su) return;
        sel.dataset.su = '1';
        css();
        var caja = document.createElement('div'); caja.className = 'su';
        try { caja.style.marginBottom = getComputedStyle(sel).marginBottom; } catch (e) {}
        sel.parentNode.insertBefore(caja, sel);
        caja.appendChild(sel);
        sel.classList.add('su-sel'); sel.tabIndex = -1; sel.setAttribute('aria-hidden', 'true');
        var btn = document.createElement('button');
        btn.type = 'button'; btn.className = 'su-btn';
        btn.setAttribute('aria-haspopup', 'listbox'); btn.setAttribute('aria-expanded', 'false');
        caja.appendChild(btn);
        var lista = null, act = -1;

        function opciones() { return Array.prototype.filter.call(sel.options, function (o) { return o.value; }); }
        function pintarBoton() {
            var o = sel.options[sel.selectedIndex];
            if (o && o.value) btn.innerHTML = '<span class="su-av">' + esc(ini(nombreDe(o))) + '</span><span class="su-txt" style="text-transform:capitalize">' + esc(nombreDe(o)) + '</span><span class="material-symbols-outlined su-flecha">expand_more</span>';
            else btn.innerHTML = '<span class="su-txt vacio">' + esc((sel.options[0] && sel.options[0].textContent) || 'Selecciona usuario…') + '</span><span class="material-symbols-outlined su-flecha">expand_more</span>';
        }
        function cerrar(foco) {
            if (!lista) return;
            lista.remove(); lista = null; caja.classList.remove('abierto'); btn.setAttribute('aria-expanded', 'false');
            if (foco) btn.focus();
        }
        function elegir(o) {
            sel.value = o.value;
            sel.dispatchEvent(new Event('change', { bubbles: true }));
            pintarBoton(); cerrar(false);
            btn.blur(); // los números del PIN van directo al teclado numérico de la página
        }
        function marcar(i) {
            var items = lista ? lista.querySelectorAll('.su-op') : [];
            items.forEach(function (x, k) { x.classList.toggle('act', k === i); });
            act = i; if (items[i]) items[i].scrollIntoView({ block: 'nearest' });
        }
        function abrir() {
            if (lista) return cerrar(true);
            var ops = opciones();
            lista = document.createElement('div'); lista.className = 'su-lista'; lista.setAttribute('role', 'listbox');
            var buscar = ops.length > 7 ? '<input class="su-buscar" type="text" placeholder="Buscar nombre…" autocomplete="off"/>' : '';
            lista.innerHTML = buscar + (ops.length ? ops.map(function (o, i) {
                var rol = rolDe(o);
                return '<button type="button" class="su-op" role="option" data-i="' + i + '" aria-selected="' + (o.value === sel.value) + '"><span class="su-av">' + esc(ini(nombreDe(o))) + '</span><span style="min-width:0"><b>' + esc(nombreDe(o)) + '</b>' + (rol ? '<small>' + esc(rol) + '</small>' : '') + '</span><span class="material-symbols-outlined su-ok">check</span></button>';
            }).join('') : '<div class="su-vacio">No hay usuarios activos en esta tienda.</div>');
            caja.appendChild(lista); caja.classList.add('abierto'); btn.setAttribute('aria-expanded', 'true');
            lista.addEventListener('click', function (e) { var b = e.target.closest('.su-op'); if (b) elegir(ops[+b.dataset.i]); });
            var q = lista.querySelector('.su-buscar');
            if (q) {
                q.addEventListener('input', function () {
                    var t = q.value.trim().toLowerCase();
                    lista.querySelectorAll('.su-op').forEach(function (b) { b.style.display = nombreDe(ops[+b.dataset.i]).toLowerCase().indexOf(t) >= 0 ? '' : 'none'; });
                });
                setTimeout(function () { q.focus(); }, 0);
            }
            marcar(Math.max(0, ops.findIndex(function (o) { return o.value === sel.value; })));
        }
        btn.addEventListener('click', function (e) { e.stopPropagation(); abrir(); });
        caja.addEventListener('keydown', function (e) {
            if (!lista) { if (e.key === 'ArrowDown' && document.activeElement === btn) { e.preventDefault(); abrir(); } return; }
            var vis = Array.prototype.filter.call(lista.querySelectorAll('.su-op'), function (b) { return b.style.display !== 'none'; });
            var pos = vis.findIndex(function (b) { return +b.dataset.i === act; });
            if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); cerrar(true); }
            else if (e.key === 'ArrowDown' || e.key === 'ArrowUp') { e.preventDefault(); e.stopPropagation(); var n = vis[Math.min(vis.length - 1, Math.max(0, pos + (e.key === 'ArrowDown' ? 1 : -1)))]; if (n) marcar(+n.dataset.i); }
            else if (e.key === 'Enter') { e.preventDefault(); e.stopPropagation(); var o = opciones()[act]; if (o) elegir(o); }
            else e.stopPropagation(); // al escribir en "Buscar" no se marcan números del PIN
        });
        document.addEventListener('click', function (e) { if (!caja.contains(e.target)) cerrar(false); });
        // El login rellena el <select> después (al elegir tienda): se vuelve a pintar solo
        new MutationObserver(function () { pintarBoton(); if (lista) { cerrar(false); } }).observe(sel, { childList: true });
        sel.addEventListener('change', pintarBoton);
        pintarBoton();
    }

    function iniciar() { IDS.forEach(function (id) { mejorar(document.getElementById(id)); }); }
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', iniciar); else iniciar();
    window.refSelectorUsuario = { mejorar: mejorar };
})();
