// ============================================================
// ALERTAS DE WHATSAPP — REFRIMAR OS
// ------------------------------------------------------------
// Envía en segundo plano una alerta al WhatsApp del dueño cada
// vez que se registra un Pago Móvil (desde caja.html o
// facturacion.html). El envío real lo hace el Cloudflare Worker
// (ruta /api/notificar-pago-movil) usando CallMeBot, para no
// exponer la API Key en el navegador.
//
// Uso:
//   enviarAlertaPagoMovil({
//       monto: '1.234,56 Bs',
//       referencia: '1234',
//       sucursal: 'Casa Matriz',
//       usuario: 'Juan'
//   });
// ============================================================

function enviarAlertaPagoMovil(datos) {
    if (!datos) return;
    try {
        fetch('/api/notificar-pago-movil', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                monto: datos.monto || '-',
                referencia: datos.referencia || '-',
                sucursal: datos.sucursal || 'Casa Matriz',
                usuario: datos.usuario || 'Sistema'
            })
        }).catch(function(err) {
            console.warn('[WHATSAPP] No se pudo enviar la alerta:', err);
        });
    } catch (e) {
        console.warn('[WHATSAPP] Error enviando la alerta:', e);
    }
}
