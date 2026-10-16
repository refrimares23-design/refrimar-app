/* REFRIMAR · Protección anti-spam de formularios públicos (login, invitación).
 * 1) Campo trampa (honeypot): si un robot lo llena, se rechaza.
 * 2) Bloqueo progresivo en el navegador: 5 fallos → espera 1 min, luego 5 min.
 * 3) Cloudflare Turnstile: solo si REF_SITIO.turnstileSiteKey tiene valor. El token se valida
 *    en el Worker (/api/verificar-humano) con el secreto TURNSTILE_SECRET.
 * El límite real de intentos de PIN también se aplica en la base de datos (ver supabase-migration-seguridad.sql).
 */
(function () {
    'use strict';
    var S = window.REF_SITIO || {};
    var widgetId = null, token = '', cargando = null;

    function estado(k) { try { return JSON.parse(localStorage.getItem('refrimar_intentos_' + k) || '{}'); } catch (e) { return {}; } }
    function guardar(k, v) { try { localStorage.setItem('refrimar_intentos_' + k, JSON.stringify(v)); } catch (e) {} }

    function cargarTurnstile() {
        if (!S.turnstileSiteKey) return Promise.resolve(false);
        if (cargando) return cargando;
        cargando = new Promise(function (ok) {
            window.__refTsListo = function () { ok(true); };
            var s = document.createElement('script');
            s.src = 'https://challenges.cloudflare.com/turnstile/v0/api.js?onload=__refTsListo&render=explicit';
            s.async = true; s.defer = true; s.onerror = function () { ok(false); };
            document.head.appendChild(s);
        });
        return cargando;
    }
    function montar() {
        var box = document.getElementById('rf-turnstile');
        if (!box || !S.turnstileSiteKey) return;
        cargarTurnstile().then(function (ok) {
            if (!ok || !window.turnstile || widgetId !== null) return;
            box.hidden = false;
            widgetId = window.turnstile.render(box, {
                sitekey: S.turnstileSiteKey, language: 'es', theme: 'light',
                callback: function (t) { token = t; },
                'expired-callback': function () { token = ''; },
                'error-callback': function () { token = ''; }
            });
        });
    }

    window.RefAntiSpam = {
        verificar: async function (k) {
            var trampa = document.getElementById('rf-web');
            if (trampa && trampa.value) return { ok: false, error: 'No se pudo verificar. Recarga la página.' };
            var e = estado(k), ahora = Date.now();
            if (e.hasta && e.hasta > ahora) return { ok: false, error: 'Demasiados intentos. Espera ' + Math.ceil((e.hasta - ahora) / 1000) + ' s.' };
            if (!S.turnstileSiteKey) return { ok: true };
            if (!token) { montar(); return { ok: false, error: 'Confirma que no eres un robot.' }; }
            try {
                var r = await fetch('/api/verificar-humano', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ token: token, accion: k }) });
                var j = await r.json().catch(function () { return {}; });
                if (window.turnstile && widgetId !== null) { window.turnstile.reset(widgetId); token = ''; }
                if (r.ok && j.ok) return { ok: true };
                return { ok: false, error: j.error || 'No se pudo verificar. Intenta de nuevo.' };
            } catch (err) {
                // Sin internet o sin worker: no bloquear el acceso por eso
                return { ok: true };
            }
        },
        fallo: function (k) {
            var e = estado(k); e.n = (e.n || 0) + 1;
            if (e.n % 5 === 0) e.hasta = Date.now() + (e.n >= 10 ? 300000 : 60000);
            guardar(k, e);
        },
        exito: function (k) { guardar(k, {}); },
        montar: montar
    };
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', montar); else montar();
})();
