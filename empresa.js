/* ============================================================
 * EMPRESA ACTIVA Y SU MARCA (multiempresa)
 * ------------------------------------------------------------
 * - Lo que antes estaba fijo en las páginas (REFRIMAR, el logo, el RIF,
 *   "Casa Matriz") sale de la configuración de cada empresa.
 * - REFRIMAR (esquema public) se ve exactamente igual que siempre.
 * - En otra empresa se cambian los textos y logos visibles, sin tocar el
 *   diseño, y también lo que se agrega después a la página.
 * - Muestra el aviso de suscripción (prueba por vencer, vencida).
 * Uso: RefEmpresa.actual(), RefEmpresa.marca(), RefEmpresa.elegir(codigo),
 *      RefEmpresa.cambiar(), RefEmpresa.texto('REFRIMAR')
 * ============================================================ */
(function () {
    'use strict';
    var KEY = 'ref_empresa', MARCA = 'ref_empresa_marca:';
    var REFRIMAR = { comercial: 'REFRIMAR', razon: 'Comercial Refrimar 2023, C.A.', rif: 'J-50357586-7', principal: 'Casa Matriz', correo: 'refrimar.es23@gmail.com' };

    // RIF venezolano: letra + 8 dígitos + dígito verificador (módulo 11)
    function normRif(v) {
        var d = String(v || '').toUpperCase().replace(/[^A-Z0-9]/g, '');
        return /^[VEJPGC][0-9]{9}$/.test(d) ? d.charAt(0) + '-' + d.slice(1, 9) + '-' + d.charAt(9) : null;
    }
    function rifValido(v) {
        var r = normRif(v); if (!r) return false;
        var d = r.replace(/-/g, ''), L = { V: 1, E: 2, J: 3, P: 4, G: 5, C: 3 }[d.charAt(0)], p = [3, 2, 7, 6, 5, 4, 3, 2], s = L * 4;
        for (var i = 0; i < 8; i++) s += Number(d.charAt(i + 1)) * p[i];
        var c = 11 - (s % 11); if (c >= 10) c = 0;
        return c === Number(d.charAt(9));
    }

    function actual() { return window.refEmpresaActiva ? window.refEmpresaActiva() : { esquema: 'public', slug: 'refrimar', nombre: '' }; }
    function acentoActual() {
        try { if (actual().esquema === 'public') return '#00AAFF'; var r = localStorage.getItem('refrimar_rubro'); var P = window.RefEmpresa && window.RefEmpresa.paletas; return (P && P[r] && P[r][0]) || '#00AAFF'; } catch (e) { return '#00AAFF'; }
    }
    function esPrincipal() { return actual().esquema === 'public'; }
    function leer(k) { try { return JSON.parse(localStorage.getItem(k) || 'null'); } catch (e) { return null; } }
    function guardarLS(k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch (e) {} }

    // Datos de marca guardados (se actualizan solos al entrar)
    function marca() {
        var e = actual(), m = leer(MARCA + e.esquema) || {};
        if (e.esquema === 'public') {
            return {
                comercial: m.comercial || REFRIMAR.comercial, razon: m.razon || REFRIMAR.razon, rif: m.rif || REFRIMAR.rif,
                principal: m.principal || REFRIMAR.principal, correo: m.correo || REFRIMAR.correo, logo: m.logo || null,
                direccion: m.direccion || '', telefono: m.telefono || ''
            };
        }
        var nom = m.comercial || e.nombre || 'Mi empresa';
        return { comercial: nom, razon: m.razon || nom, rif: m.rif || '', principal: m.principal || 'Principal', correo: m.correo || '',
                 logo: m.logo || e.logo || null, direccion: m.direccion || '', telefono: m.telefono || '' };
    }

    async function refrescarMarca() {
        if (!window.supabaseClient || window.supabaseClient.__sinLibreria) return;
        try {
            var r = await window.supabaseClient.from('configuracion').select('nombre_negocio,rif,direccion,telefono,email,opciones').limit(1).maybeSingle();
            if (r.error || !r.data) return;
            var d = r.data, o = d.opciones || {}, e = actual();
            // En REFRIMAR solo se usan los datos de la configuración si el RIF guardado es válido
            // (así una configuración vieja o de ejemplo nunca cambia lo que ya se ve bien)
            var fiscalOk = rifValido(d.rif);
            var m = {
                comercial: o.nombre_comercial || (e.esquema === 'public' ? REFRIMAR.comercial : d.nombre_negocio),
                razon: fiscalOk || e.esquema !== 'public' ? (d.nombre_negocio || '') : '', rif: fiscalOk ? normRif(d.rif) : (e.esquema === 'public' ? '' : d.rif || ''),
                direccion: d.direccion || '', telefono: d.telefono || '',
                correo: d.email || '', logo: o.logo || null,
                principal: o.nombre_principal || (e.esquema === 'public' ? REFRIMAR.principal : 'Principal'),
                asistente: o.asistente ? { terminado: !!o.asistente.terminado, hechos: (o.asistente.hechos || []).length } : null
            };
            var antes = JSON.stringify(leer(MARCA + e.esquema));
            guardarLS(MARCA + e.esquema, m);
            if (antes !== JSON.stringify(m)) aplicar(document.body);
        } catch (e) {}
    }

    function productoNombre() {
        try { return localStorage.getItem('ref_producto_nombre') || (window.REF_PRODUCTO && window.REF_PRODUCTO.nombre) || 'Cuadra'; } catch (e) { return 'Cuadra'; }
    }
    function refrescarProducto() {
        if (esPrincipal() || !window.refPlataforma || sessionStorage.getItem('ref_producto_ok')) return;
        window.refPlataforma().rpc('saas_producto').then(function (r) {
            if (r && r.data && r.data.nombre) { try { localStorage.setItem('ref_producto_nombre', r.data.nombre); sessionStorage.setItem('ref_producto_ok', '1'); } catch (e) {} }
        }, function () {});
    }

    // Elegir empresa por su código (el que aparece en el registro / login)
    async function elegir(codigo) {
        var r = await window.refPlataforma().rpc('saas_empresa', { p_slug: String(codigo || '').trim().toLowerCase() });
        if (r.error) throw new Error(r.error.message || 'No se pudo buscar la empresa');
        if (!r.data || !r.data.ok) throw new Error((r.data && r.data.error) || 'No encontramos esa empresa');
        fijar(r.data);
        return r.data;
    }
    function fijar(d) {
        var antes = actual();
        guardarLS(KEY, { esquema: d.esquema, slug: d.slug, nombre: d.nombre || '', logo: d.logo || null });
        if (antes.esquema !== d.esquema) limpiarSesion();
    }
    // Volver a REFRIMAR (o dejar que el login pregunte)
    function cambiar() {
        try { localStorage.removeItem(KEY); } catch (e) {}
        limpiarSesion();
    }
    function limpiarSesion() {
        try { sessionStorage.removeItem('refrimar_user'); sessionStorage.removeItem('refrimar_sucursal'); } catch (e) {}
        // Datos de la empresa anterior guardados en este equipo
        ['refrimar_pos_token', 'refrimar_ultima_tienda', 'refrimar_rubro', 'refrimar_opciones_negocio', 'refrimar_stock_minimo_global', 'ref_suscripcion']
            .forEach(function (k) { try { localStorage.removeItem(k); sessionStorage.removeItem(k); } catch (e) {} });
    }

    // ---------- Textos y logos ----------
    function reemplazos() {
        var m = marca(), out = [];
        function par(de, a) { if (a && de !== a) out.push([de, a]); }
        // El programa de caja para Windows lleva el nombre del producto, no el de la empresa
        if (!esPrincipal()) { par('REFRIMAR POS', productoNombre() + ' POS'); par('Refrimar POS', productoNombre() + ' POS'); }
        par(REFRIMAR.razon, m.razon);
        par(REFRIMAR.razon.toUpperCase(), (m.razon || '').toUpperCase());
        par(REFRIMAR.rif, m.rif || '—');
        par(REFRIMAR.correo, m.correo || '');
        par('Casa Matriz', m.principal);
        par('casa matriz', (m.principal || '').toLowerCase());
        return { lista: out, nombre: m.comercial !== REFRIMAR.comercial ? m.comercial : null };
    }
    var RX_NOMBRE = /(^|[^\w.@\/-])(REFRIMAR|Refrimar)(?![\w.@\/-])/g;
    function cambiarTexto(t, R) {
        var s = t;
        for (var i = 0; i < R.lista.length; i++) if (s.indexOf(R.lista[i][0]) >= 0) s = s.split(R.lista[i][0]).join(R.lista[i][1]);
        if (R.nombre && /refrimar/i.test(s)) s = s.replace(RX_NOMBRE, function (x, a) { return a + R.nombre; });
        return s;
    }
    function logoSVG(nombre, ancho) {
        var n = String(nombre || '').trim(), ini = n.split(/\s+/).map(function (p) { return p.charAt(0); }).join('').slice(0, 2).toUpperCase();
        var svg = ancho
            ? '<svg xmlns="http://www.w3.org/2000/svg" width="' + Math.max(160, n.length * 22) + '" height="48"><text x="0" y="36" font-family="Poppins,Inter,sans-serif" font-weight="800" font-size="34" fill="' + acentoActual() + '">' + n.replace(/[<&"]/g, '') + '</text></svg>'
            : '<svg xmlns="http://www.w3.org/2000/svg" width="96" height="96"><rect width="96" height="96" rx="24" fill="#0A2540"/><text x="48" y="61" text-anchor="middle" font-family="Poppins,Inter,sans-serif" font-weight="800" font-size="38" fill="' + acentoActual() + '">' + ini + '</text></svg>';
        return 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(svg);
    }
    var RX_LOGO = /logo-refrimar|logo-mark|img\/logo\b|icon-(180|192|512)\.png/;
    function aplicar(raiz) {
        if (!raiz) return;
        var R = reemplazos();
        if (!R.lista.length && !R.nombre && !marca().logo) return;   // REFRIMAR sin cambios: nada que hacer
        // Textos visibles
        var w = document.createTreeWalker(raiz, NodeFilter.SHOW_TEXT, {
            acceptNode: function (n) {
                var p = n.parentNode && n.parentNode.nodeName;
                if (p === 'SCRIPT' || p === 'STYLE' || p === 'TEXTAREA' || p === 'NOSCRIPT') return NodeFilter.FILTER_REJECT;
                return /efrimar|EFRIMAR|asa [Mm]atriz|J-50357586|refrimar\.es23/.test(n.nodeValue) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_SKIP;
            }
        });
        var n, cambios = [];
        while ((n = w.nextNode())) cambios.push(n);
        cambios.forEach(function (t) { var v = cambiarTexto(t.nodeValue, R); if (v !== t.nodeValue) t.nodeValue = v; });
        // Atributos visibles
        var conAttr = raiz.querySelectorAll ? raiz.querySelectorAll('[alt],[title],[placeholder],[aria-label]') : [];
        Array.prototype.forEach.call(conAttr, function (el) {
            ['alt', 'title', 'placeholder', 'aria-label'].forEach(function (a) {
                var v = el.getAttribute(a);
                if (v && /efrimar|EFRIMAR|asa [Mm]atriz/.test(v)) { var x = cambiarTexto(v, R); if (x !== v) el.setAttribute(a, x); }
            });
        });
        // Logos
        if (!esPrincipal() || marca().logo) {
            var imgs = raiz.querySelectorAll ? raiz.querySelectorAll('img') : [];
            Array.prototype.forEach.call(imgs, function (im) {
                if (im.dataset.refLogo) return;
                var src = im.getAttribute('src') || '';
                if (!RX_LOGO.test(src)) return;
                var ancho = /logo-refrimar/.test(src);
                im.dataset.refLogo = '1';
                var pic = im.parentNode && im.parentNode.nodeName === 'PICTURE' ? im.parentNode : null;
                if (pic) Array.prototype.forEach.call(pic.querySelectorAll('source'), function (s) { s.remove(); });
                im.src = marca().logo || logoSVG(marca().comercial, ancho);
                if (marca().logo) im.style.objectFit = 'contain';
            });
        }
        if (document.title && /REFRIMAR|Refrimar/.test(document.title)) document.title = cambiarTexto(document.title, R);
    }

    var pendiente = false, nodos = [];
    function observar() {
        if (!window.MutationObserver || !document.body) return;
        new MutationObserver(function (ms) {
            ms.forEach(function (m) {
                if (m.type === 'characterData') nodos.push(m.target.parentNode);
                else Array.prototype.forEach.call(m.addedNodes, function (x) { nodos.push(x.nodeType === 3 ? x.parentNode : x); });
            });
            if (pendiente) return;
            pendiente = true;
            requestAnimationFrame(function () {
                pendiente = false;
                var lista = nodos; nodos = [];
                lista.forEach(function (x) { if (x && x.isConnected) aplicar(x); });
            });
        }).observe(document.body, { childList: true, subtree: true, characterData: true });
    }

    // ---------- Aviso de suscripción ----------
    async function suscripcion() {
        if (esPrincipal() || !window.refPlataforma || !window.refTokenSesion || !window.refTokenSesion()) return null;
        var cache = null;
        try { cache = JSON.parse(sessionStorage.getItem('ref_suscripcion') || 'null'); } catch (e) {}
        if (cache && cache.esquema === actual().esquema && Date.now() - cache.t < 30 * 60 * 1000) return cache.d;
        try {
            var r = await window.refPlataforma().rpc('saas_mi_suscripcion', { p_esquema: actual().esquema });
            if (r.error || !r.data || !r.data.ok) return null;
            try { sessionStorage.setItem('ref_suscripcion', JSON.stringify({ t: Date.now(), esquema: actual().esquema, d: r.data })); } catch (e) {}
            return r.data;
        } catch (e) { return null; }
    }
    function diasHasta(f) { if (!f) return null; var d = new Date(f + 'T23:59:59'); return Math.ceil((d - new Date()) / 86400000); }
    async function avisoSuscripcion() {
        if (/\/(login|registro|invitacion|mi-plan)\.html/.test(location.pathname)) return;
        var s = await suscripcion();
        if (!s) return;
        var texto = null, grave = false;
        if (s.estado === 'vencida') { texto = s.pagado_hasta ? 'Tu suscripción venció. Puedes consultar, pero no registrar ventas.' : 'Tu período de prueba terminó. Puedes consultar, pero no registrar ventas.'; grave = true; }
        else if (s.estado === 'prueba') { var d = diasHasta(s.prueba_hasta); if (d != null && d <= 5) texto = d <= 0 ? 'Tu prueba termina hoy.' : 'Te quedan ' + d + (d === 1 ? ' día' : ' días') + ' de prueba.'; }
        else if (s.estado === 'activa' && s.pagado_hasta) { var p = diasHasta(s.pagado_hasta); if (p != null && p <= 3) texto = p < 0 ? 'Tu pago está vencido.' : 'Tu plan vence en ' + p + (p === 1 ? ' día.' : ' días.'); }
        if (!texto || document.getElementById('ref-aviso-plan')) return;
        var b = document.createElement('div');
        b.id = 'ref-aviso-plan';
        b.setAttribute('role', 'status');
        b.style.cssText = 'position:fixed;z-index:9000;left:50%;top:10px;transform:translateX(-50%);max-width:min(620px,calc(100% - 20px));display:flex;align-items:center;gap:12px;padding:10px 10px 10px 16px;border-radius:999px;font:500 14px/1.35 Inter,system-ui,sans-serif;box-shadow:0 10px 26px rgba(10,37,64,.22);' +
            (grave ? 'background:#0A2540;color:#fff' : 'background:#E6F6FF;color:#0A2540');
        b.innerHTML = '<span style="flex:1">' + texto + '</span><a href="mi-plan.html" style="text-decoration:none;border-radius:999px;padding:8px 14px;font:600 13px Poppins,sans-serif;background:var(--rubro-acento,#00AAFF);color:#0A2540;white-space:nowrap">Ver mi plan</a>' +
            '<button type="button" aria-label="Cerrar aviso" style="border:0;background:transparent;color:inherit;font-size:20px;line-height:1;cursor:pointer;padding:4px 6px">×</button>';
        b.querySelector('button').onclick = function () { b.remove(); };
        document.body.appendChild(b);
    }

    // Empresa nueva que no ha terminado la configuración: invitación en el tablero
    function avisoAsistente() {
        if (esPrincipal() || !/\/dashboard\.html$/.test(location.pathname) || document.getElementById('ref-aviso-asistente')) return;
        if (!window.can || !window.can('configuracion')) return;
        var a = (leer(MARCA + actual().esquema) || {}).asistente;
        if (a && a.terminado) return;
        // Primera vez que la empresa entra: se abre el asistente (una vez por sesión)
        if ((!a || !a.hechos) && !sessionStorage.getItem('ref_asistente_visto')) {
            try { sessionStorage.setItem('ref_asistente_visto', '1'); } catch (e) {}
            location.replace('asistente.html');
            return;
        }
        var b = document.createElement('div');
        b.id = 'ref-aviso-asistente';
        b.setAttribute('role', 'status');
        b.style.cssText = 'position:fixed;z-index:8900;left:50%;bottom:16px;transform:translateX(-50%);width:max-content;max-width:min(560px,calc(100% - 20px));display:flex;align-items:center;gap:12px;padding:10px 10px 10px 18px;border-radius:999px;background:#0A2540;color:#fff;font:500 14px/1.35 Inter,system-ui,sans-serif;box-shadow:0 12px 30px rgba(10,37,64,.28)';
        b.innerHTML = '<span style="flex:1">Termina de configurar tu empresa' + (a ? ' (' + a.hechos + ' de 13 pasos)' : '') + '.</span><a href="asistente.html" style="text-decoration:none;border-radius:999px;padding:8px 14px;font:600 13px Poppins,sans-serif;background:var(--rubro-acento,#00AAFF);color:#0A2540;white-space:nowrap">Continuar</a>' +
            '<button type="button" aria-label="Cerrar aviso" style="border:0;background:transparent;color:#fff;font-size:20px;line-height:1;cursor:pointer;padding:4px 6px">×</button>';
        b.querySelector('button').onclick = function () { b.remove(); };
        document.body.appendChild(b);
    }


    // ---- Colores según el rubro (solo empresas de la plataforma; REFRIMAR sigue azul) ----
    // acento: botones y destacados (texto oscuro encima, contraste AA) · oscuro: textos y enlaces · suave: fondos
    var PALETAS = {
        ferreteria:   ['#FF9A3D', '#B85400', '#FFF1E3', '255 154 61', '184 84 0'],
        refrigeracion:['#38BDF8', '#0369A1', '#E0F4FF', '56 189 248', '3 105 161'],
        supermercado: ['#34D27B', '#15803D', '#E8F8EE', '52 210 123', '21 128 61'],
        farmacia:     ['#2DD4BF', '#0F766E', '#E6FAF7', '45 212 191', '15 118 110'],
        panaderia:    ['#F5B041', '#9A5B05', '#FFF5E0', '245 176 65', '154 91 5'],
        licoreria:    ['#C4A5FF', '#6D28D9', '#F3EEFF', '196 165 255', '109 40 217'],
        autopartes:   ['#FF8A8A', '#B91C1C', '#FEECEC', '255 138 138', '185 28 28'],
        ropa:         ['#F68FC5', '#BE185D', '#FDEBF5', '246 143 197', '190 24 93'],
        electronica:  ['#93A0FF', '#4338CA', '#EEF0FF', '147 160 255', '67 56 202']
    };
    function aplicarColores() {
        var vieja = document.getElementById('ref-colores-rubro'); if (vieja) vieja.remove();
        if (esPrincipal()) return;
        var r = ''; try { r = localStorage.getItem('refrimar_rubro') || ''; } catch (e) {}
        var c = PALETAS[r]; if (!c) return;
        var st = document.createElement('style'); st.id = 'ref-colores-rubro';
        st.textContent = ':root{--primary-container:' + c[3] + ';--primary:' + c[4] + ';--ds-primary:' + c[1] + ';--ds-primary-container:' + c[0] +
            ';--nk-orange:' + c[0] + ';--nk-orange-text:' + c[1] + ';--az:' + c[0] + ';--az-t:' + c[1] + ';--az-s:' + c[2] + ';--az-s2:' + c[2] +
            ';--volt:' + c[0] + ';--wash:' + c[2] + ';--rf-hover:' + c[0] + ';--rubro-acento:' + c[0] + ';--rubro-oscuro:' + c[1] + ';--rubro-suave:' + c[2] + '}';
        (document.head || document.documentElement).appendChild(st);
    }
    aplicarColores();
    // Empresa nueva sin rubro guardado en este equipo: se lee una vez de la base
    function cargarRubro() {
        if (esPrincipal() || typeof supabaseClient === 'undefined' || !supabaseClient.from) return;
        var r = ''; try { r = localStorage.getItem('refrimar_rubro') || ''; } catch (e) {}
        if (r) return;
        supabaseClient.from('configuracion').select('rubro').limit(1).maybeSingle().then(function (x) {
            var v = x && !x.error && x.data && x.data.rubro;
            if (v) { try { localStorage.setItem('refrimar_rubro', v); } catch (e) {} aplicarColores(); }
        }, function () {});
    }
    window.addEventListener('storage', function (e) { if (e.key === 'refrimar_rubro' || e.key === 'ref_empresa') aplicarColores(); });

    window.RefEmpresa = {
        actual: actual, esPrincipal: esPrincipal, marca: marca, elegir: elegir, fijar: fijar, cambiar: cambiar,
        refrescar: refrescarMarca, suscripcion: suscripcion, aplicar: aplicar,
        rifValido: rifValido, normRif: normRif, producto: productoNombre,
        texto: function (t) { return cambiarTexto(String(t == null ? '' : t), reemplazos()); },
        logoSVG: logoSVG, colores: aplicarColores, paletas: PALETAS
    };

    function iniciar() {
        aplicar(document.body);
        observar();
        refrescarMarca().then(avisoAsistente, avisoAsistente);
        refrescarProducto();
        avisoSuscripcion();
        cargarRubro();
    }
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', iniciar); else iniciar();
})();
