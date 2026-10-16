/* REFRIMAR · Piezas de las páginas públicas (portada, login, legal, 404, invitación).
 * - Aviso de cookies (Aceptar / Rechazar). La analítica solo carga si acepta.
 * - Botón flotante de WhatsApp (no se usa dentro del POS).
 * - Datos estructurados JSON-LD para Google (solo si la página lo pide con data-jsonld).
 * Lee todo de js/sitio-config.js (window.REF_SITIO).
 */
(function () {
    'use strict';
    var S = window.REF_SITIO || {};
    var CLAVE = 'refrimar_cookies_v1';

    function leer() { try { return localStorage.getItem(CLAVE); } catch (e) { return null; } }
    function guardar(v) { try { localStorage.setItem(CLAVE, v); } catch (e) {} }
    function esc(s) { return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); }

    var CSS = [
        '.sp-cookies{position:fixed;left:16px;right:16px;bottom:16px;z-index:9998;max-width:520px;background:#fff;color:#3D4550;border-radius:22px;padding:18px 18px 16px;box-shadow:0 0 0 1px rgba(10,37,64,.08),0 18px 40px -12px rgba(10,37,64,.35);font:14px/1.5 Inter,system-ui,sans-serif}',
        '.sp-cookies b{display:block;font:700 15px/1.3 Poppins,sans-serif;color:#0A2540;margin-bottom:4px}',
        '.sp-cookies p{margin:0 0 12px}',
        '.sp-cookies a{color:#0A2540;font-weight:600}',
        '.sp-cookies .sp-acc{display:flex;flex-wrap:wrap;gap:8px}',
        '.sp-btn{all:unset;cursor:pointer;display:inline-flex;align-items:center;justify-content:center;height:42px;padding:0 20px;border-radius:999px;font:600 14px Poppins,sans-serif}',
        '.sp-btn.pri{background:#00AAFF;color:#0A2540}.sp-btn.pri:hover{background:#33BBFF}',
        '.sp-btn.sec{background:#fff;color:#0A2540;box-shadow:inset 0 0 0 1.5px #0A2540}.sp-btn.sec:hover{background:#E6F6FF}',
        '.sp-btn:focus-visible,.sp-wa:focus-visible{outline:3px solid #00AAFF;outline-offset:3px}',
        '.sp-wa{position:fixed;right:18px;bottom:18px;z-index:9997;width:58px;height:58px;border-radius:50%;background:#25D366;color:#fff;display:flex;align-items:center;justify-content:center;box-shadow:0 10px 24px -6px rgba(0,0,0,.35);transition:transform .15s}',
        '.sp-wa:hover{transform:scale(1.06)}',
        '.sp-wa svg{width:30px;height:30px;fill:#fff}',
        '@media (max-width:640px){.sp-cookies{left:10px;right:10px;bottom:10px}.sp-wa{right:14px;bottom:14px;width:54px;height:54px}.sp-con-aviso .sp-wa{bottom:200px}}',
        '@media (prefers-reduced-motion:reduce){.sp-wa{transition:none}}'
    ].join('\n');

    function css() { if (document.getElementById('sp-css')) return; var s = document.createElement('style'); s.id = 'sp-css'; s.textContent = CSS; document.head.appendChild(s); }

    // ---- Analítica (Cloudflare Web Analytics: no usa cookies; igual se pide permiso) ----
    function cargarAnalitica() {
        if (!S.analyticsToken || document.getElementById('sp-cfwa')) return;
        var s = document.createElement('script');
        s.id = 'sp-cfwa'; s.defer = true;
        s.src = 'https://static.cloudflareinsights.com/beacon.min.js';
        s.setAttribute('data-cf-beacon', JSON.stringify({ token: S.analyticsToken }));
        document.head.appendChild(s);
    }

    function avisoCookies() {
        var v = leer();
        if (v === 'si') { cargarAnalitica(); return; }
        if (v === 'no') return;
        var d = document.createElement('div');
        d.className = 'sp-cookies'; d.setAttribute('role', 'dialog'); d.setAttribute('aria-live', 'polite'); d.setAttribute('aria-label', 'Aviso de cookies');
        d.innerHTML = '<b>Usamos lo mínimo</b><p>Guardamos tu sesión para que puedas entrar al sistema. Si aceptas, también medimos visitas de forma anónima para mejorar la página. <a href="privacidad.html#cookies">Más información</a></p>' +
            '<div class="sp-acc"><button type="button" class="sp-btn pri" data-v="si">Aceptar</button><button type="button" class="sp-btn sec" data-v="no">Rechazar</button></div>';
        d.addEventListener('click', function (e) {
            var b = e.target.closest('[data-v]'); if (!b) return;
            guardar(b.getAttribute('data-v'));
            if (b.getAttribute('data-v') === 'si') cargarAnalitica();
            d.remove(); document.body.classList.remove('sp-con-aviso');
        });
        document.body.appendChild(d);
        document.body.classList.add('sp-con-aviso');
    }
    // Permite reabrir el aviso desde un enlace "Preferencias de cookies"
    window.refCookiesPreferencias = function () { try { localStorage.removeItem(CLAVE); } catch (e) {} var x = document.querySelector('.sp-cookies'); if (x) x.remove(); avisoCookies(); };

    function botonWhatsapp() {
        if (!S.whatsapp || document.body.hasAttribute('data-sin-whatsapp')) return;
        var a = document.createElement('a');
        a.className = 'sp-wa';
        a.href = 'https://wa.me/' + String(S.whatsapp).replace(/\D/g, '') + (S.whatsappMensaje ? '?text=' + encodeURIComponent(S.whatsappMensaje) : '');
        a.target = '_blank'; a.rel = 'noopener';
        a.setAttribute('aria-label', 'Escríbenos por WhatsApp');
        a.innerHTML = '<svg viewBox="0 0 32 32" aria-hidden="true"><path d="M16 3C8.8 3 3 8.7 3 15.8c0 2.5.7 4.9 2 7L3 29l6.4-2c2 1.1 4.3 1.7 6.6 1.7 7.2 0 13-5.7 13-12.8S23.2 3 16 3zm0 23.4c-2.1 0-4.1-.6-5.9-1.7l-.4-.3-3.8 1.2 1.2-3.7-.3-.4c-1.2-1.8-1.9-3.9-1.9-6.1C4.9 10 9.9 5.2 16 5.2S27.1 10 27.1 15.9 22.1 26.4 16 26.4zm6.1-7.9c-.3-.2-2-1-2.3-1.1-.3-.1-.5-.2-.8.2-.2.3-.9 1.1-1.1 1.3-.2.2-.4.3-.7.1-.3-.2-1.4-.5-2.7-1.7-1-.9-1.7-2-1.9-2.3-.2-.3 0-.5.1-.7l.5-.6c.2-.2.2-.4.3-.6.1-.2 0-.5 0-.6l-1-2.5c-.3-.7-.6-.6-.8-.6h-.7c-.2 0-.6.1-.9.4-.3.3-1.2 1.2-1.2 2.9s1.2 3.4 1.4 3.6c.2.2 2.4 3.7 5.9 5.1.8.4 1.5.6 2 .7.8.3 1.6.2 2.2.1.7-.1 2-.8 2.3-1.6.3-.8.3-1.5.2-1.6-.1-.2-.3-.3-.6-.4z"/></svg>';
        document.body.appendChild(a);
    }

    function jsonLd() {
        if (!document.body.hasAttribute('data-jsonld')) return;
        var tiendas = (S.tiendas || []).filter(function (t) { return t.direccion; });
        var horario = (S.horario || []).map(function (h) { return { '@type': 'OpeningHoursSpecification', dayOfWeek: h.dias.map(function (d) { return { Mo: 'Monday', Tu: 'Tuesday', We: 'Wednesday', Th: 'Thursday', Fr: 'Friday', Sa: 'Saturday', Su: 'Sunday' }[d]; }), opens: h.abre, closes: h.cierra }; });
        function base(nombre, t) {
            var o = { '@context': 'https://schema.org', '@type': 'HardwareStore', name: nombre, legalName: S.razonSocial, taxID: S.rif, email: S.correo, url: S.dominio + '/', logo: S.dominio + '/img/logo-refrimar-azul.png', image: S.dominio + '/img/og-refrimar.png', priceRange: '$$', currenciesAccepted: 'USD, VES' };
            if (S.telefono) o.telephone = S.telefono;
            if (t) o.address = { '@type': 'PostalAddress', streetAddress: t.direccion, addressLocality: t.ciudad || 'Caracas', addressRegion: t.estado || 'Distrito Capital', addressCountry: 'VE' };
            else o.address = { '@type': 'PostalAddress', addressLocality: 'Caracas', addressCountry: 'VE' };
            if (t && t.mapa) o.hasMap = t.mapa;
            if (horario.length) o.openingHoursSpecification = horario;
            var redes = [S.redes && S.redes.instagram, S.redes && S.redes.facebook].filter(Boolean);
            if (redes.length) o.sameAs = redes;
            return o;
        }
        var datos = tiendas.length ? tiendas.map(function (t) { return base((S.nombreComercial || 'REFRIMAR') + ' · ' + t.nombre, t); }) : [base(S.nombreComercial || 'REFRIMAR')];
        var s = document.createElement('script');
        s.type = 'application/ld+json';
        s.textContent = JSON.stringify(datos.length === 1 ? datos[0] : datos);
        document.head.appendChild(s);
    }

    // Rellena cualquier elemento con data-sitio="campo" (ej. data-sitio="rif")
    function rellenar() {
        document.querySelectorAll('[data-sitio]').forEach(function (el) {
            var v = S[el.getAttribute('data-sitio')];
            if (v) el.textContent = v;
        });
    }
    window.refSitioEsc = esc;

    function iniciar() { css(); rellenar(); jsonLd(); botonWhatsapp(); avisoCookies(); }
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', iniciar); else iniciar();
})();
