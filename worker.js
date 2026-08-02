// ============================================================
// WORKER DE REFRIMAR-APP
// ------------------------------------------------------------
// Sirve los archivos estáticos normales (HTML, JS, CSS) y además
// atiende /api/analizar-factura, que manda la foto de la factura
// del proveedor a un modelo de IA (gratis, vía OpenRouter) para
// extraer los productos.
//
// Requiere un secreto configurado así (una sola vez, desde tu
// computadora, dentro de la carpeta del proyecto):
//
//     npx wrangler secret put OPENROUTER_API_KEY
//
// Te pedirá pegar la clave. Se consigue gratis en openrouter.ai
// (creas cuenta → Keys → Create Key). NO requiere tarjeta.
//
// Nota: los modelos gratis de OpenRouter leen fotos/imágenes muy
// bien. Con PDF son menos confiables — si un PDF no funciona,
// mejor toma una foto o captura de pantalla de la factura.
//
// ------------------------------------------------------------
// ALERTAS DE WHATSAPP POR PAGO MÓVIL (CallMeBot, gratis)
// ------------------------------------------------------------
// Atiende /api/notificar-pago-movil y le manda un WhatsApp al
// dueño cada vez que un cajero registra un Pago Móvil.
//
// Configuración (una sola vez):
//
//   1. Desde el celular que recibirá las alertas
//      (+584149264213), escribe un WhatsApp al bot de CallMeBot
//      (+34 644 46 82 91) con el texto EXACTO:
//
//          I allow callmebot to send me messages
//
//   2. Entra a https://www.callmebot.com/blog/free-api-whatsapp-messages/
//      e ingresa tu número completo para ver tu API Key.
//
//   3. Configura el secreto en el Worker:
//
//          npx wrangler secret put CALLMEBOT_API_KEY
//
//   (opcional: si algún día quieres otra celda, configura
//    npx wrangler secret put WHATSAPP_PHONE  con formato +58...)
//
// ------------------------------------------------------------
// TASA BCV AUTOMÁTICA
// ------------------------------------------------------------
// Atiende GET /api/tasa-bcv y devuelve la tasa oficial del dólar
// (Bs/$) consultada en dolarapi.com (respaldo: pydolarve.org).
// No requiere ninguna clave. Las páginas la usan para actualizar
// la tasa del día de forma automática.
// ============================================================

const PROMPT_FACTURA = `Analiza esta factura o nota de entrega de un proveedor de ferretería.
Extrae cada producto o línea que aparezca. Responde SOLO con un JSON
válido, sin texto adicional, sin explicaciones, sin markdown, con
este formato exacto:

{"items":[{"codigo":"","descripcion":"","cantidad":0,"costo":0}]}

Reglas:
- "codigo": el código o referencia del producto tal como aparece en la factura. Si no hay, deja "".
- "descripcion": el nombre/descripción del producto.
- "cantidad": número de unidades, como número entero.
- "costo": precio unitario de costo, solo el número, sin símbolo de moneda ni comas de miles.
- Si no puedes leer algún campo, usa 0 o "" según corresponda.
- No inventes productos que no estén realmente en la imagen.
- No incluyas líneas de subtotal, IVA o total como si fueran productos.`;

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    if (url.pathname === '/api/analizar-factura' && request.method === 'POST') {
      return handleAnalizarFactura(request, env);
    }

    if (url.pathname === '/api/notificar-pago-movil' && request.method === 'POST') {
      return handleNotificarPagoMovil(request, env);
    }

    if (url.pathname === '/api/tasa-bcv' && request.method === 'GET') {
      return handleTasaBcv();
    }

    // Todo lo demás (los .html, supabase-config.js, etc.) lo sirve
    // el binding de assets normal, como hasta ahora.
    return env.ASSETS.fetch(request);
  }
};

// Modelos gratis de OpenRouter con visión, en orden de preferencia.
// Si el primero falla o está saturado, se prueba el siguiente sin
// que el usuario tenga que hacer nada.
const MODELOS_RESPALDO = [
  'google/gemma-4-31b-it:free',
  'google/gemma-4-26b-a4b-it:free',
  'nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free',
  'openrouter/free'
];

async function handleAnalizarFactura(request, env) {
  try {
    if (!env.OPENROUTER_API_KEY) {
      return jsonResponse({ error: 'Falta configurar el secreto OPENROUTER_API_KEY en el Worker (ver worker.js).' }, 500);
    }

    const body = await request.json();
    const { mediaType, base64 } = body;
    if (!mediaType || !base64) {
      return jsonResponse({ error: 'Falta el archivo a analizar.' }, 400);
    }
    if (mediaType === 'application/pdf') {
      return jsonResponse({ error: 'Los PDF no son confiables con los modelos gratis. Toma una foto o captura de pantalla de la factura e inténtalo de nuevo.' }, 400);
    }

    const dataUrl = 'data:' + mediaType + ';base64,' + base64;

    let ultimoError = 'Error llamando a la IA.';

    for (let i = 0; i < MODELOS_RESPALDO.length; i++) {
      const modelo = MODELOS_RESPALDO[i];
      const resultado = await intentarConModelo(modelo, dataUrl, env);

      if (resultado.ok) {
        return jsonResponse({ items: resultado.items }, 200);
      }
      ultimoError = resultado.error;
    }

    return jsonResponse({ error: 'Los modelos gratis de IA no están disponibles en este momento (' + ultimoError + '). Espera un minuto e inténtalo de nuevo.' }, 503);
  } catch (err) {
    return jsonResponse({ error: err.message || 'Error inesperado analizando la factura.' }, 500);
  }
}

async function intentarConModelo(modelo, dataUrl, env) {
  const controller = new AbortController();
  const timeoutId = setTimeout(function() { controller.abort(); }, 30000);

  let orRes;
  try {
    orRes = await fetch('https://openrouter.ai/api/v1/chat/completions', {
      method: 'POST',
      signal: controller.signal,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ' + env.OPENROUTER_API_KEY,
        'HTTP-Referer': 'https://refrimar-app.refrimar-es23.workers.dev',
        'X-Title': 'Refrimar Carga IA'
      },
      body: JSON.stringify({
        model: modelo,
        messages: [
          {
            role: 'user',
            content: [
              { type: 'text', text: PROMPT_FACTURA },
              { type: 'image_url', image_url: { url: dataUrl } }
            ]
          }
        ]
      })
    });
  } catch (fetchErr) {
    clearTimeout(timeoutId);
    if (fetchErr.name === 'AbortError') {
      return { ok: false, error: modelo + ' tardó demasiado' };
    }
    return { ok: false, error: fetchErr.message || ('fallo de red con ' + modelo) };
  }
  clearTimeout(timeoutId);

  let data;
  try {
    data = await orRes.json();
  } catch (e) {
    return { ok: false, error: modelo + ' devolvió una respuesta inválida' };
  }

  if (!orRes.ok) {
    const msg = (data && data.error && data.error.message) ? data.error.message : (modelo + ' devolvió error');
    return { ok: false, error: msg };
  }

  let raw = (data.choices && data.choices[0] && data.choices[0].message && data.choices[0].message.content) || '{}';
  raw = raw.trim().replace(/^```json\s*/i, '').replace(/^```\s*/i, '').replace(/```$/i, '').trim();

  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (e) {
    // Algunos modelos agregan texto antes/después del JSON aunque se
    // les pida que no lo hagan. Buscamos el primer { y el último }
    // y probamos de nuevo con solo eso.
    const inicio = raw.indexOf('{');
    const fin = raw.lastIndexOf('}');
    if (inicio !== -1 && fin !== -1 && fin > inicio) {
      try {
        parsed = JSON.parse(raw.slice(inicio, fin + 1));
      } catch (e2) {
        return { ok: false, error: modelo + ' no devolvió un formato entendible' };
      }
    } else {
      return { ok: false, error: modelo + ' no devolvió un formato entendible' };
    }
  }

  return { ok: true, items: parsed.items || [] };
}

const WHATSAPP_PHONE_DEFAULT = '+584149264213';

async function handleNotificarPagoMovil(request, env) {
  try {
    if (!env.CALLMEBOT_API_KEY) {
      return jsonResponse({ ok: false, error: 'Falta configurar el secreto CALLMEBOT_API_KEY en el Worker (ver worker.js).' }, 500);
    }

    const body = await request.json();
    const { monto, referencia, sucursal, usuario } = body;

    const mensaje = [
      '🚨 NUEVO PAGO MÓVIL REGISTRADO',
      '💵 Monto: ' + (monto || '-'),
      '📌 Ref: ' + (referencia || '-'),
      '🏢 Sucursal: ' + (sucursal || 'Casa Matriz'),
      '👤 Registrado por: ' + (usuario || 'Sistema')
    ].join('\n');

    const phone = (env.WHATSAPP_PHONE || WHATSAPP_PHONE_DEFAULT).replace(/[^+\d]/g, '');
    const apiUrl = 'https://api.callmebot.com/whatsapp.php?phone=' + encodeURIComponent(phone) +
      '&text=' + encodeURIComponent(mensaje) +
      '&apikey=' + encodeURIComponent(env.CALLMEBOT_API_KEY);

    const resp = await fetch(apiUrl);
    const texto = await resp.text();

    // CallMeBot responde "Message Sent" o similar en éxito; "Error" o un
    // código distinto de 2xx cuando falla (número no activado, etc.).
    if (!resp.ok || /error/i.test(texto)) {
      return jsonResponse({ ok: false, error: 'CallMeBot: ' + (texto || 'error desconocido') }, 502);
    }
    return jsonResponse({ ok: true }, 200);
  } catch (err) {
    return jsonResponse({ ok: false, error: err.message || 'Error enviando la alerta.' }, 500);
  }
}

// Tasa BCV oficial (dólar), consultada automáticamente.
// Fuente principal: dolarapi.com; respaldo: pydolarve.org. Sin claves.
async function handleTasaBcv() {
  try {
    const res = await fetch('https://ve.dolarapi.com/v1/dolares', {
      headers: { 'Accept': 'application/json', 'User-Agent': 'Refrimar-App/1.0' }
    });
    if (!res.ok) throw new Error('dolarapi devolvió ' + res.status);
    const lista = await res.json();
    const oficial = (lista || []).find(function(d) { return d.fuente === 'oficial'; });
    const tasa = oficial && oficial.promedio ? Number(oficial.promedio) : null;
    if (!tasa) throw new Error('No se encontró la tasa oficial');
    return jsonResponse({ ok: true, tasa: tasa, fecha: oficial.fechaActualizacion || new Date().toISOString(), fuente: 'dolarapi.com' }, 200);
  } catch (err) {
    try {
      const res2 = await fetch('https://pydolarve.org/api/v1/dollar?moneda=usd');
      const data = await res2.json();
      const tasa2 = Number((data && data.price) || ((data && data.conversiones && data.conversiones.simed && data.conversiones.simed.avg) || 0));
      if (tasa2 > 0) {
        return jsonResponse({ ok: true, tasa: tasa2, fecha: new Date().toISOString(), fuente: 'pydolarve.org' }, 200);
      }
    } catch (e2) {}
    return jsonResponse({ ok: false, error: 'No se pudo obtener la tasa BCV (' + err.message + ')' }, 502);
  }
}

function jsonResponse(obj, status) {
  return new Response(JSON.stringify(obj), {
    status: status || 200,
    headers: { 'Content-Type': 'application/json' }
  });
}
