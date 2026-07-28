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

    // Todo lo demás (los .html, supabase-config.js, etc.) lo sirve
    // el binding de assets normal, como hasta ahora.
    return env.ASSETS.fetch(request);
  }
};

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

    const orRes = await fetch('https://openrouter.ai/api/v1/chat/completions', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ' + env.OPENROUTER_API_KEY,
        'HTTP-Referer': 'https://refrimar-app.refrimar-es23.workers.dev',
        'X-Title': 'Refrimar Carga IA'
      },
      body: JSON.stringify({
        // "openrouter/free" elige solo entre modelos gratis que sí
        // soportan imagen. Si te da problemas, puedes fijar uno
        // directo, ej: "google/gemma-4-31b-it:free"
        model: 'openrouter/free',
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

    const data = await orRes.json();

    if (!orRes.ok) {
      const msg = (data && data.error && data.error.message) ? data.error.message : 'Error llamando a la IA.';
      return jsonResponse({ error: msg }, 500);
    }

    let raw = (data.choices && data.choices[0] && data.choices[0].message && data.choices[0].message.content) || '{}';
    raw = raw.trim().replace(/^```json\s*/i, '').replace(/^```\s*/i, '').replace(/```$/i, '').trim();

    let parsed;
    try {
      parsed = JSON.parse(raw);
    } catch (e) {
      return jsonResponse({ error: 'La IA no devolvió un formato entendible. Intenta con una foto más clara.' }, 500);
    }

    return jsonResponse({ items: parsed.items || [] }, 200);
  } catch (err) {
    return jsonResponse({ error: err.message || 'Error inesperado analizando la factura.' }, 500);
  }
}

function jsonResponse(obj, status) {
  return new Response(JSON.stringify(obj), {
    status: status || 200,
    headers: { 'Content-Type': 'application/json' }
  });
}
