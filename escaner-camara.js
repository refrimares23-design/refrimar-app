/* REFRIMAR · Escanear códigos de barra con la cámara del celular (Chrome en Android y la mayoría de navegadores nuevos).
 * RefCamara.disponible() → true si el navegador puede leer códigos con la cámara.
 * RefCamara.escanear(function (codigo) {...}, { continuo: true }) → abre la cámara; cada código leído llama a la función.
 */
(function () {
    'use strict';
    var FORMATOS = ['ean_13', 'ean_8', 'upc_a', 'upc_e', 'code_128', 'code_39', 'itf', 'qr_code'];
    window.RefCamara = {
        disponible: function () { return 'BarcodeDetector' in window && !!(navigator.mediaDevices && navigator.mediaDevices.getUserMedia); },
        escanear: async function (alLeer, op) {
            op = op || {};
            if (!this.disponible()) { (window.nk ? nk.toast : alert)('Este navegador no puede leer códigos con la cámara. Usa Chrome en Android o un lector de código de barras.', 'warning'); return; }
            var det; try { det = new window.BarcodeDetector({ formats: FORMATOS }); } catch (e) { det = new window.BarcodeDetector(); }
            var w = document.createElement('div');
            w.style.cssText = 'position:fixed;inset:0;z-index:10000;background:rgba(10,37,64,.92);display:flex;flex-direction:column;align-items:center;justify-content:center;gap:12px;padding:16px';
            w.innerHTML = '<div style="position:relative;width:min(92vw,520px);aspect-ratio:3/4;border-radius:22px;overflow:hidden;background:#000"><video playsinline muted style="width:100%;height:100%;object-fit:cover"></video>' +
                '<div style="position:absolute;left:10%;right:10%;top:42%;height:16%;border:3px solid #00AAFF;border-radius:14px;box-shadow:0 0 0 2000px rgba(0,0,0,.25)"></div></div>' +
                '<div id="rc-msg" style="color:#E6F6FF;font:500 15px Inter,system-ui,sans-serif;text-align:center">Apunta al código de barras</div>' +
                '<button type="button" style="height:48px;padding:0 28px;border-radius:999px;background:#00AAFF;color:#0A2540;font:600 15px Poppins,sans-serif;border:0">Listo</button>';
            document.body.appendChild(w);
            var video = w.querySelector('video'), msg = w.querySelector('#rc-msg'), stream = null, vivo = true, ultimo = '', ultimoT = 0;
            function cerrar() { vivo = false; if (stream) stream.getTracks().forEach(function (t) { t.stop(); }); w.remove(); }
            w.querySelector('button').addEventListener('click', cerrar);
            try {
                stream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: 'environment' }, audio: false });
                video.srcObject = stream; await video.play();
            } catch (e) { msg.textContent = 'No se pudo abrir la cámara: da permiso en el navegador.'; return; }
            (async function ciclo() {
                while (vivo) {
                    try {
                        var r = await det.detect(video);
                        if (r && r.length) {
                            var cod = String(r[0].rawValue || '').trim(), ahora = Date.now();
                            if (cod && (cod !== ultimo || ahora - ultimoT > 1500)) {
                                ultimo = cod; ultimoT = ahora;
                                if (navigator.vibrate) navigator.vibrate(60);
                                msg.textContent = 'Leído: ' + cod;
                                alLeer(cod);
                                if (!op.continuo) { cerrar(); return; }
                            }
                        }
                    } catch (e) {}
                    await new Promise(function (ok) { setTimeout(ok, 180); });
                }
            })();
        }
    };
})();
