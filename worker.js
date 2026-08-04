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
este formato EXACTO (un array de objetos, sin envolverlo en otra clave):

[{"codigo":"...","nombre":"...","cantidad":0.00,"costo_unitario":0.00}]

DISTINGUE EL CÓDIGO DE PRODUCTO DEL RÓTULO DE "REFERENCIA":
- Busca la columna del CÓDIGO DEL PRODUCTO / SKU / CÓDIGO DE BARRAS
  (código interno o del fabricante del artículo).
- NO uses la "Referencia del Proveedor", "Nro. de Parte", "Part No.",
  "Referencia", "Código del Proveedor", el número de línea ni el
  número de factura como si fueran el código de producto.
- REGLA DE ORO: el "codigo" debe ser EXACTAMENTE el que está impreso
  en la factura, leído letra por letra y número por número, con sus
  guiones y símbolos. Si dudas de UN SOLO carácter, si no lo lees
  claramente o si sientes la tentación de completarlo o inventarlo,
  usa "codigo": null. NUNCA inventes, completes ni "corrijas" un
  código que creas ver.

Reglas de extracción:
- "codigo": el código de producto/SKU TAL CUAL está impreso, en
  MAYÚSCULAS y CONSERVANDO guiones, puntos y símbolos (ej: "FRT-10-128",
  "CAP-45UF"). Quita solo los espacios del inicio y del final. Si no
  estás 100% seguro de que ese código está impreso en la factura, usa
  null. NUNCA inventes ni cambies un código.
- "nombre": nombre o descripción del producto, limpio y completo.
  QUITA caracteres raros o basura (* _ | ~ , comillas, subrayados,
  símbolos), elimina espacios dobles y puntos finales, y escribe el
  texto con mayúsculas/minúsculas correctas (primera letra de cada
  palabra en mayúscula, p. ej. "Tornillo cabeza hexagonal 1/2 x 2"),
  nunca todo en mayúsculas.
- "cantidad": cantidad como número decimal con punto (ej: 1.50).
  Convierte las comas decimales a puntos (ej: "1,50" -> 1.50). Ignora
  unidades o "x" al final.
- "costo_unitario": precio unitario de costo, solo el número con punto
  decimal, sin símbolo de moneda ni comas de miles (ej: 12.75).
- Si no puedes leer un campo numérico, usa 0. Si el nombre no se lee,
  usa "".
- No inventes productos que no estén realmente en la imagen.
- No incluyas líneas de subtotal, IVA, total, notas ni encabezados
  como si fueran productos.`;

// ------------------------------------------------------------
// SEGURIDAD: rate-limit, CSP y caché de tasa
// ------------------------------------------------------------
// - Límite de peticiones por IP en los /api/* para evitar abuso
//   (alguien con la clave pública quemando la IA gratis o spam).
// - CSP y cabeceras de seguridad en todas las respuestas.
// - La tasa BCV se cachea 10 minutos (en vez de golpear dolarapi
//   en cada petición del navegador).
// ============================================================

const RATE_LIMITS = {
  '/api/analizar-factura': { windowMs: 60000, max: 5 },
  '/api/notificar-pago-movil': { windowMs: 60000, max: 5 },
  '/api/tasa-bcv': { windowMs: 60000, max: 30 }
};
const RATE_BUCKETS = new Map();

// Cuenta peticiones por IP dentro de una ventana fija (en memoria).
function rateLimit(ip, path, now) {
  const cfg = RATE_LIMITS[path];
  if (!cfg) return { ok: true };
  const id = path + '|' + ip;
  const b = RATE_BUCKETS.get(id);
  if (!b || now - b.start >= cfg.windowMs) {
    RATE_BUCKETS.set(id, { start: now, count: 1 });
    return { ok: true };
  }
  b.count++;
  if (b.count > cfg.max) {
    return { ok: false, retryAfter: Math.ceil((b.start + cfg.windowMs - now) / 1000) };
  }
  return { ok: true };
}

// CSP: permite inline (la app usa onclick y scripts de página) y los
// CDN que cargan los HTML, pero bloquea:
//   - scripts externos de dominios NO autorizados
//   - plugins (object-src none)
//   - que la app se incruste en iframes de otros sitios (frame-ancestors)
//   - form-action y base-uri fuera del propio dominio
// La cámara queda permitida para el lector de código de barras.
const CSP_VALUE = [
  "default-src 'self'",
  "script-src 'self' 'unsafe-inline' 'unsafe-eval' https://cdn.tailwindcss.com https://cdn.jsdelivr.net https://unpkg.com",
  "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com https://cdn.tailwindcss.com",
  "font-src 'self' data: https://fonts.gstatic.com",
  "img-src 'self' data: blob: https:",
  "connect-src 'self' https://hjecifftqidqeswcpvwt.supabase.co https://*.supabase.co wss://*.supabase.co",
  "object-src 'none'",
  "base-uri 'self'",
  "frame-ancestors 'none'",
  "form-action 'self'"
].join('; ');

const SECURITY_HEADERS = {
  'Content-Security-Policy': CSP_VALUE,
  'X-Content-Type-Options': 'nosniff',
  'X-Frame-Options': 'DENY',
  'Referrer-Policy': 'strict-origin-when-cross-origin',
  'Permissions-Policy': 'camera=(self), microphone=(), geolocation=()'
};

// Añade las cabeceras de seguridad a una respuesta sin tocar el cuerpo.
function addSecurityHeaders(response) {
  if (!response || typeof response.headers.append !== 'function') return response;
  const headers = new Headers(response.headers);
  Object.keys(SECURITY_HEADERS).forEach(function(k) {
    if (!headers.has(k)) headers.set(k, SECURITY_HEADERS[k]);
  });
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers: headers
  });
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const now = Date.now();
    const ip = request.headers.get('CF-Connecting-IP') || request.headers.get('x-real-ip') || 'unknown';

    if (url.pathname === '/api/analizar-factura' && request.method === 'POST') {
      const rl = rateLimit(ip, url.pathname, now);
      if (!rl.ok) {
        return jsonResponse({ error: 'Demasiadas peticiones. Espera unos segundos y vuelve a intentar.' }, 429, { 'Retry-After': String(rl.retryAfter) });
      }
      return handleAnalizarFactura(request, env);
    }

    if (url.pathname === '/api/notificar-pago-movil' && request.method === 'POST') {
      const rl = rateLimit(ip, url.pathname, now);
      if (!rl.ok) {
        return jsonResponse({ error: 'Demasiadas peticiones. Espera unos segundos.' }, 429, { 'Retry-After': String(rl.retryAfter) });
      }
      return handleNotificarPagoMovil(request, env);
    }

    if (url.pathname === '/api/tasa-bcv' && request.method === 'GET') {
      const rl = rateLimit(ip, url.pathname, now);
      if (!rl.ok) {
        return jsonResponse({ error: 'Demasiadas peticiones.' }, 429, { 'Retry-After': String(rl.retryAfter) });
      }
      return handleTasaBcv(now);
    }

    // Todo lo demás (los .html, supabase-config.js, etc.) lo sirve
    // el binding de assets normal, como hasta ahora.
    const assetResponse = await env.ASSETS.fetch(request);
    return addSecurityHeaders(assetResponse);
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

  // Normaliza la respuesta a la estructura estricta del contrato:
  // [{ codigo, nombre, cantidad, costo_unitario }]
  const items = normalizarItems(parsed);

  return { ok: true, items: items };
}

// Convierte el JSON que devuelva el modelo (aunque venga como objeto
// {"items": [...]} o directamente como array) al contrato estricto.
function normalizarItems(parsed) {
  let lista = Array.isArray(parsed) ? parsed : (parsed && Array.isArray(parsed.items) ? parsed.items : []);
  if (!Array.isArray(lista)) lista = [];

  return lista.map(function(it) {
    const codigoRaw = it && it.codigo != null ? String(it.codigo) : '';
    const nombre = formatearNombre((it && it.nombre != null) ? it.nombre : (it && it.descripcion != null ? it.descripcion : ''));
    const cantidad = numeroValido(it && it.cantidad);
    let costo = it && it.costo_unitario != null ? numeroValido(it.costo_unitario) : numeroValido(it && it.costo);
    if (costo < 0) costo = 0;

    const codigo = limpiarCodigo(codigoRaw);
    return {
      codigo: codigo === '' ? null : codigo,
      nombre: nombre,
      cantidad: cantidad,
      costo_unitario: costo
    };
  }).filter(function(it) {
    return it.nombre !== '' || it.codigo != null;
  });
}

// Limpieza estricta del nombre/descripción: quita caracteres basura,
// colapsa espacios y normaliza mayúsculas/minúsculas de forma legible
// (conserva siglas y medidas con dígitos).
const CONECTORES_MIN = new Set(['de','del','la','el','los','las','y','e','o','u','a','en','con','por','para','al','un','una']);

function formatearNombre(nombre) {
  let s = String(nombre || '');
  s = s
    .replace(/[\u0000-\u001f\u007f\u200b-\u200f\ufeff]/g, ' ')
    .replace(/[*_`|~^={}[\];:<>?]+/g, ' ')
    .replace(/[„“”"'«»]+/g, '')
    .replace(/\s+/g, ' ')
    .trim();
  if (!s) return '';
  const palabras = s.split(' ').map(function(w) {
    if (!w) return '';
    if (/\d/.test(w)) return w.toUpperCase();
    const baja = w.toLowerCase();
    if (CONECTORES_MIN.has(baja)) return baja;
    if (w === w.toUpperCase() && w.length <= 5) return w; // siglas: PVC, SDS, HD...
    return w.charAt(0).toUpperCase() + w.slice(1).toLowerCase();
  });
  return palabras.join(' ').replace(/[.]+$/g, '').trim();
}

// Limpia un código de producto. Solo se conserva un código que parezca
// SKU/código de barras: si el valor trae rótulo de "Referencia"/"Parte
// del proveedor" se descarta (devolverá null) para que se busque por nombre.
function limpiarCodigo(codigo) {
  let s = String(codigo || '').trim();
  if (!s || /^(null|n\/a|none|no code|sin código|sin codigo|s\/n|sin numero|sin número)$/i.test(s)) return '';
  if (!/[a-zA-Z0-9]/.test(s)) return '';
  // ¿Empieza por un rótulo de referencia/proveedor o número de línea? NO es el código de producto.
  if (/^(REF|REFERENCIA|PARTE|PART|NRO|NO|ITEM|N°)\b/i.test(s)) return '';
  // Quita rótulos legítimos de código: COD:, SKU:, BARCODE:, CÓDIGO:
  s = s.replace(/^\s*(CODIGO|COD|SKU|BARCODE|BARRAS)\s*[:.\-]?\s*/i, '');
  return s.toUpperCase();
}

function numeroValido(v) {
  if (v === null || v === undefined || v === '') return 0;
  let n = Number(v);
  if (isNaN(n)) {
    // Convierte "1,50" -> 1.5 y quita símbolos y espacios.
    const limpio = String(v).replace(/\s/g, '').replace(/\./g, '').replace(',', '.').replace(/[^0-9.\-]/g, '');
    n = Number(limpio);
  }
  return isNaN(n) ? 0 : n;
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
// El resultado se cachea TASA_CACHE_MS (10 min) para no golpear el
// proveedor en cada petición del navegador ni fallar por saturación.
const TASA_CACHE_MS = 10 * 60 * 1000;
let tasaCache = null;

async function handleTasaBcv(now) {
  const t0 = now || Date.now();

  // Cache válida: devolver sin tocar la red.
  if (tasaCache && t0 - tasaCache.t < TASA_CACHE_MS) {
    return jsonResponse({ ok: true, tasa: tasaCache.tasa, fecha: tasaCache.fecha, fuente: tasaCache.fuente, cacheado: true }, 200);
  }

  try {
    const res = await fetch('https://ve.dolarapi.com/v1/dolares', {
      headers: { 'Accept': 'application/json', 'User-Agent': 'Refrimar-App/1.0' }
    });
    if (!res.ok) throw new Error('dolarapi devolvió ' + res.status);
    const lista = await res.json();
    const oficial = (lista || []).find(function(d) { return d.fuente === 'oficial'; });
    const tasa = oficial && oficial.promedio ? Number(oficial.promedio) : null;
    if (!tasa || !(tasa > 0)) throw new Error('No se encontró la tasa oficial');
    tasaCache = { t: Date.now(), tasa: tasa, fecha: oficial.fechaActualizacion || new Date().toISOString(), fuente: 'dolarapi.com' };
    return jsonResponse({ ok: true, tasa: tasa, fecha: tasaCache.fecha, fuente: 'dolarapi.com' }, 200);
  } catch (err) {
    try {
      const res2 = await fetch('https://pydolarve.org/api/v1/dollar?moneda=usd');
      const data = await res2.json();
      const tasa2 = Number((data && data.price) || ((data && data.conversiones && data.conversiones.simed && data.conversiones.simed.avg) || 0));
      if (tasa2 > 0) {
        tasaCache = { t: Date.now(), tasa: tasa2, fecha: new Date().toISOString(), fuente: 'pydolarve.org' };
        return jsonResponse({ ok: true, tasa: tasa2, fecha: tasaCache.fecha, fuente: 'pydolarve.org' }, 200);
      }
    } catch (e2) {}
    return jsonResponse({ ok: false, error: 'No se pudo obtener la tasa BCV (' + err.message + ')' }, 502);
  }
}

function jsonResponse(obj, status, extraHeaders) {
  const headers = { 'Content-Type': 'application/json' };
  Object.keys(SECURITY_HEADERS).forEach(function(k) { headers[k] = SECURITY_HEADERS[k]; });
  if (extraHeaders) {
    Object.keys(extraHeaders).forEach(function(k) { headers[k] = extraHeaders[k]; });
  }
  return new Response(JSON.stringify(obj), {
    status: status || 200,
    headers: headers
  });
}
