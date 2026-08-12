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

// ------------------------------------------------------------
// AVISOS WHATSAPP DE CUENTAS POR COBRAR
// ------------------------------------------------------------
// 1. /api/notificar-factura-pagada (POST): la página Cuentas por
//    Cobrar lo llama cuando una deuda queda saldada en su
//    totalidad. Manda un WhatsApp: "FACTURA PAGADA".
// 2. Cron diario (08:00 y 18:00 hora de Venezuela): consulta
//    deudas_por_avisar() en Supabase y manda UN WhatsApp con el
//    resumen de las facturas por vencer o vencidas. No repite la
//    misma deuda el mismo día (lo controla la RPC + ultimo_aviso).
//    Requiere las variables SUPABASE_URL y SUPABASE_ANON_KEY en
//    wrangler.jsonc (son públicas, igual que en supabase-config.js).
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
  '/api/notificar-factura-pagada': { windowMs: 60000, max: 10 },
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
  "connect-src 'self' https://hjecifftqidqeswcpvwt.supabase.co https://*.supabase.co wss://*.supabase.co https://api.open-meteo.com",
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

    if (url.pathname === '/api/notificar-factura-pagada' && request.method === 'POST') {
      const rl = rateLimit(ip, url.pathname, now);
      if (!rl.ok) {
        return jsonResponse({ error: 'Demasiadas peticiones. Espera unos segundos.' }, 429, { 'Retry-After': String(rl.retryAfter) });
      }
      return handleNotificarFacturaPagada(request, env);
    }

    if (url.pathname === '/api/tasa-bcv' && request.method === 'GET') {
      const rl = rateLimit(ip, url.pathname, now);
      if (!rl.ok) {
        return jsonResponse({ error: 'Demasiadas peticiones.' }, 429, { 'Retry-After': String(rl.retryAfter) });
      }
      return handleTasaBcv(now);
    }

    // ============================================================
    // BOT DE VENTAS CON IA — WhatsApp Cloud API + Messenger
    // ------------------------------------------------------------
    // GET  /webhook/whatsapp   -> verificación (challenge) de Meta
    // POST /webhook/whatsapp   -> eventos de WhatsApp
    // GET  /webhook/messenger  -> verificación (challenge) de Meta
    // POST /webhook/messenger  -> eventos de Messenger
    // ============================================================
    if (url.pathname === '/webhook/whatsapp') {
      if (request.method === 'GET') return webhookVerify(url, env.WA_WEBHOOK_VERIFY_TOKEN);
      if (request.method === 'POST') return webhookReceive(request, env, ctx, 'whatsapp');
      return new Response('Method Not Allowed', { status: 405 });
    }

    if (url.pathname === '/webhook/messenger') {
      if (request.method === 'GET') return webhookVerify(url, env.MSGR_WEBHOOK_VERIFY_TOKEN);
      if (request.method === 'POST') return webhookReceive(request, env, ctx, 'messenger');
      return new Response('Method Not Allowed', { status: 405 });
    }

    // Todo lo demás (los .html, supabase-config.js, etc.) lo sirve
    // el binding de assets normal, como hasta ahora.
    const assetResponse = await env.ASSETS.fetch(request);
    return addSecurityHeaders(assetResponse);
  },

  // Cron diario: recordatorio de facturas por vencer / vencidas.
  async scheduled(event, env, ctx) {
    ctx.waitUntil(procesarRecordatoriosDeudas(env));
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

// Envía un texto a WhatsApp del dueño usando CallMeBot.
async function enviarWhatsApp(texto, env) {
  if (!env.CALLMEBOT_API_KEY) return { ok: false, error: 'Falta configurar el secreto CALLMEBOT_API_KEY' };
  const phone = (env.WHATSAPP_PHONE || WHATSAPP_PHONE_DEFAULT).replace(/[^+\d]/g, '');
  const apiUrl = 'https://api.callmebot.com/whatsapp.php?phone=' + encodeURIComponent(phone) +
    '&text=' + encodeURIComponent(texto) +
    '&apikey=' + encodeURIComponent(env.CALLMEBOT_API_KEY);

  const resp = await fetch(apiUrl);
  const textoResp = await resp.text();

  // CallMeBot responde "Message Sent" o similar en éxito; "Error" o un
  // código distinto de 2xx cuando falla (número no activado, etc.).
  if (!resp.ok || /error/i.test(textoResp)) {
    return { ok: false, error: 'CallMeBot: ' + (textoResp || 'error desconocido') };
  }
  return { ok: true };
}

async function handleNotificarPagoMovil(request, env) {
  try {
    const body = await request.json();
    const { monto, referencia, sucursal, usuario } = body;

    const mensaje = [
      '🚨 NUEVO PAGO MÓVIL REGISTRADO',
      '💵 Monto: ' + (monto || '-'),
      '📌 Ref: ' + (referencia || '-'),
      '🏢 Sucursal: ' + (sucursal || 'Casa Matriz'),
      '👤 Registrado por: ' + (usuario || 'Sistema')
    ].join('\n');

    const r = await enviarWhatsApp(mensaje, env);
    if (!r.ok) return jsonResponse({ ok: false, error: r.error }, 502);
    return jsonResponse({ ok: true }, 200);
  } catch (err) {
    return jsonResponse({ ok: false, error: err.message || 'Error enviando la alerta.' }, 500);
  }
}

// Aviso al saldar por completo una deuda de cliente (Cuentas por Cobrar).
async function handleNotificarFacturaPagada(request, env) {
  try {
    if (!env.CALLMEBOT_API_KEY) {
      return jsonResponse({ ok: false, error: 'Falta configurar el secreto CALLMEBOT_API_KEY en el Worker (ver worker.js).' }, 500);
    }

    const body = await request.json();
    const { numero, cliente, monto, sucursal, usuario } = body;

    const mensaje = [
      '✅ REFRIMAR — FACTURA PAGADA',
      '🧾 N°: ' + (numero || '-'),
      '👤 Cliente: ' + (cliente || '-'),
      '💵 Monto: ' + (monto || '-'),
      '🏢 Sucursal: ' + (sucursal || 'Casa Matriz'),
      '👤 Registrado por: ' + (usuario || 'Sistema')
    ].join('\n');

    const r = await enviarWhatsApp(mensaje, env);
    if (!r.ok) return jsonResponse({ ok: false, error: r.error }, 502);
    return jsonResponse({ ok: true }, 200);
  } catch (err) {
    return jsonResponse({ ok: false, error: err.message || 'Error enviando la alerta.' }, 500);
  }
}

// Cron diario: consulta Supabase y manda UN resumen con las facturas
// por vencer / vencidas que aún no han sido avisadas.
async function procesarRecordatoriosDeudas(env) {
  try {
    if (!env.CALLMEBOT_API_KEY || !env.SUPABASE_URL || !env.SUPABASE_ANON_KEY) {
      console.warn('[CXC-AVISOS] Faltan CALLMEBOT_API_KEY, SUPABASE_URL o SUPABASE_ANON_KEY.');
      return;
    }

    const cab = {
      'Content-Type': 'application/json',
      'apikey': env.SUPABASE_ANON_KEY,
      'Authorization': 'Bearer ' + env.SUPABASE_ANON_KEY
    };

    const res = await fetch(env.SUPABASE_URL + '/rest/v1/rpc/deudas_por_avisar', {
      method: 'POST',
      headers: cab,
      body: JSON.stringify({ p_dias: 3 })
    });
    if (!res.ok) {
      console.warn('[CXC-AVISOS] deudas_por_avisar devolvió ' + res.status);
      return;
    }
    const lista = await res.json();
    if (!Array.isArray(lista) || lista.length === 0) return;

    const MAX = 8;
    const top = lista.slice(0, MAX);
    const hoy = new Date();
    hoy.setHours(0, 0, 0, 0);

    const lineas = top.map(function(d, i) {
      const saldo = Number(d.saldo) || 0;
      const vence = d.vence ? new Date(String(d.vence).slice(0, 10) + 'T00:00:00') : null;
      const diasRest = vence ? Math.round((vence - hoy) / 86400000) : null;
      const detalle = (diasRest !== null && diasRest < 0)
        ? ('VENCIDA (hace ' + Math.abs(diasRest) + ' d)')
        : ('vence ' + (vence ? vence.toLocaleDateString('es-VE') : '-') + (diasRest !== null ? ' (' + diasRest + ' d)' : ''));
      return (i + 1) + ') ' + (d.cliente_nombre || '-') + ' — ' + (d.numero || '-') + ' — $' + saldo.toFixed(2) + ' — ' + detalle;
    });

    let mensaje = [
      '🔔 REFRIMAR — DEUDAS POR COBRAR',
      'Hay ' + lista.length + ' factura(s) por vencer o vencidas:',
      '',
      lineas.join('\n')
    ];
    if (lista.length > MAX) mensaje.push('... y ' + (lista.length - MAX) + ' más.');

    const r = await enviarWhatsApp(mensaje.join('\n'), env);
    if (!r.ok) {
      console.warn('[CXC-AVISOS] No se envió el recordatorio:', r.error);
      return;
    }

    // Solo se marcan como avisadas si el mensaje sí se envió.
    await Promise.all(top.map(function(d) {
      return fetch(env.SUPABASE_URL + '/rest/v1/rpc/deuda_marcar_avisada', {
        method: 'POST',
        headers: cab,
        body: JSON.stringify({ p_venta_id: d.venta_id })
      }).catch(function() {});
    }));
  } catch (err) {
    console.warn('[CXC-AVISOS] Error:', err);
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

// ============================================================
// BOT DE VENTAS CON IA — WHATSAPP CLOUD API + MESSENGER
// ------------------------------------------------------------
// Atiende /webhook/whatsapp y /webhook/messenger. Cuando llega un
// mensaje, la IA (OpenAI o OpenRouter) decide si necesita consultar
// el inventario (Supabase) y responde automáticamente con precio y
// disponibilidad reales. Si el cliente pide un humano, la conversación
// se escala y el bot deja de responder en esa conversación por 12h.
//
// Variables a configurar (ver README / guía de instalación):
//   VARS (wrangler.jsonc):
//     WA_WEBHOOK_VERIFY_TOKEN  -> texto que tú elijas (el mismo que pondrás
//                                 en WhatsApp Manager > Webhook)
//     MSGR_WEBHOOK_VERIFY_TOKEN -> texto que tú elijas (el mismo que pondrás
//                                 en la Página de Facebook > Messenger > Webhooks)
//     WA_PHONE_NUMBER_ID        -> lo da WhatsApp Manager (Settings > Phone numbers)
//     WA_BUSINESS_PHONE         -> tu número comercial completo, ej "+584149264213"
//                                 (para que el bot ignore sus propios mensajes)
//     MESSENGER_PAGE_ID         -> ID de tu Página de Facebook
//     AI_PROVIDER               -> 'openai' (defecto) o 'openrouter'
//     AI_MODEL                  -> ej 'gpt-4o-mini' (defecto)
//     AI_SYSTEM_PROMPT          -> (opcional) texto que anula la personalidad del bot
//     GRAPH_VERSION             -> ej 'v22.0' (defecto)
//   SECRETS (npx wrangler secret put ...):
//     OPENAI_API_KEY            -> si usas openai (o reutiliza OPENROUTER_API_KEY)
//     META_GRAPH_TOKEN          -> token permanente del System User (whatsapp_business_messaging)
//     MESSENGER_PAGE_TOKEN      -> token de acceso de la Página (pages_messaging)
//     META_APP_SECRET           -> (recomendado) firma de webhooks de Meta
// ============================================================

const PROMPT_BOT_DEFAULT = `Eres "Alexis", el asistente virtual oficial de Ferretería Refrimar.
Tu canal: WhatsApp y Messenger. Respondes SIEMPRE en español, breve y cordial,
con el tono de un vendedor de ferretería que conoce su catálogo.

REGLAS:
1. Saludo: "¡Hola! 👋 Soy Alexis, el asistente de Ferretería Refrimar. ¿En qué puedo ayudarte?"
   Nunca des un precio ni afirmes disponibilidad SIN llamar primero a la función buscarProducto.
2. Precios y disponibilidad: responde SOLO con los datos reales que devuelva buscarProducto
   (precio en USD, stock y unidad). Ejemplo: "La cadena plástica de 25m cuesta $2.00 por metro
   y tenemos 25m disponibles."
3. Si el producto está AGOTADO: "Este producto no lo tenemos disponible en este momento.
   ¿Quieres que te avise cuando llegue o te muestro una alternativa similar?"
4. Formas de pago: "Aceptamos efectivo, Pago Móvil y Zelle."
5. Si el cliente pide hablar con una persona, se queja o menciona temas delicados
   (garantías, reclamaciones, pagos): di "Te comunico con un asesor humano ahora mismo,
   un momento por favor." y llama a escalarHumano.
6. Si buscarProducto no devuelve coincidencias: "No logro ubicarlo con esa referencia.
   ¿Puedes enviarme el código de barras o una foto? Con gusto lo busco."
7. Nunca inventes precios, promesas ni plazos. Si dudas, escala a humano.
8. No envíes enlaces externos ni contenido prohibido.`;

const TOOL_DEFINICIONES = [
  {
    type: 'function',
    function: {
      name: 'buscarProducto',
      description: 'Busca un producto en el inventario REAL de Ferretería Refrimar y devuelve precio (USD), stock disponible y unidad de medida.',
      parameters: {
        type: 'object',
        properties: {
          consulta: { type: 'string', description: 'Nombre, descripción o código del producto que pregunta el cliente.' }
        },
        required: ['consulta']
      }
    }
  },
  {
    type: 'function',
    function: {
      name: 'escalarHumano',
      description: 'Avisa que un asesor humano debe tomar la conversación (reclamos, garantías, dudas difíciles o pedido explícito de hablar con una persona).',
      parameters: {
        type: 'object',
        properties: {
          motivo: { type: 'string', description: 'Motivo por el que se escala al humano.' }
        },
        required: ['motivo']
      }
    }
  }
];

function webhookVerify(url, token) {
  const mode = url.searchParams.get('hub.mode');
  const verifyToken = url.searchParams.get('hub.verify_token');
  const challenge = url.searchParams.get('hub.challenge');
  if (mode === 'subscribe' && token && verifyToken === token && challenge) {
    return new Response(challenge, { status: 200, headers: { 'Content-Type': 'text/plain' } });
  }
  return new Response('Verificación fallida', { status: 403 });
}

async function webhookReceive(request, env, ctx, canal) {
  const raw = await request.text();
  if (!(await verificarFirmaMeta(request, raw, env))) {
    return new Response('Invalid signature', { status: 403 });
  }
  let body;
  try { body = JSON.parse(raw); } catch (e) { return new Response('Bad JSON', { status: 400 }); }
  // Responder 200 ya; el trabajo pesado corre en segundo plano.
  ctx.waitUntil(procesarWebhook(body, env, canal));
  return new Response('ok', { status: 200 });
}

async function verificarFirmaMeta(request, raw, env) {
  if (!env.META_APP_SECRET) return true;
  const sig = request.headers.get('X-Hub-Signature-256') || '';
  const expected = 'sha256=' + await hmacSha256Hex(env.META_APP_SECRET, raw);
  if (!sig || sig.length !== expected.length) return false;
  let diff = 0;
  for (let i = 0; i < sig.length; i++) diff |= sig.charCodeAt(i) ^ expected.charCodeAt(i);
  return diff === 0;
}

async function hmacSha256Hex(secret, data) {
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const sig = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(data));
  return Array.from(new Uint8Array(sig)).map(function(b) { return b.toString(16).padStart(2, '0'); }).join('');
}

async function procesarWebhook(body, env, canal) {
  try {
    if (canal === 'whatsapp') {
      for (const entry of (body.entry || [])) {
        for (const change of (entry.changes || [])) {
          const value = change.value || {};
          for (const msg of (value.messages || [])) {
            if (!msg || !msg.from) continue;
            if (env.WA_BUSINESS_PHONE && String(msg.from) === String(env.WA_BUSINESS_PHONE).replace(/[^+\d]/g, '')) continue;
            const texto = msg.text && msg.text.body ? msg.text.body.trim() : null;
            if (!texto) {
              await enviarPorCanal('whatsapp', msg.from, 'Por ahora solo atiendo mensajes de texto. Escríbeme el nombre o el código del producto que buscas.', env);
              continue;
            }
            await atenderMensaje({ canal: 'whatsapp', senderId: msg.from, texto: texto }, env);
          }
        }
      }
    } else if (canal === 'messenger') {
      for (const entry of (body.entry || [])) {
        for (const ev of (entry.messaging || [])) {
          if (!ev || !ev.sender || !ev.sender.id) continue;
          if (ev.message && ev.message.is_echo) continue;
          const texto = ev.message && ev.message.text ? String(ev.message.text).trim() : null;
          if (!texto) continue;
          await atenderMensaje({ canal: 'messenger', senderId: ev.sender.id, texto: texto }, env);
        }
      }
    }
  } catch (err) {
    console.error('[BOT] Error en procesarWebhook:', err);
  }
}

async function atenderMensaje({ canal, senderId, texto }, env) {
  try {
    // Si un humano ya está atendiendo esta conversación, el bot se calla.
    const estado = await chatBotEstadoGet(senderId, canal, env);
    if (estado && estado.escalado) {
      const at = estado.escalado_at ? new Date(estado.escalado_at).getTime() : 0;
      if (at && Date.now() - at < 12 * 3600 * 1000) return;
    }

    const respuesta = await generarRespuestaIA(senderId, canal, texto, env);
    if (!respuesta) return;
    await enviarPorCanal(canal, senderId, respuesta, env);
  } catch (err) {
    console.error('[BOT] Error atendiendo a ' + senderId + ':', err);
  }
}

function configIA(env) {
  const provider = (env.AI_PROVIDER || 'openai').toLowerCase();
  if (provider === 'openrouter') {
    return { url: 'https://openrouter.ai/api/v1/chat/completions', key: env.OPENROUTER_API_KEY, model: env.AI_MODEL || 'openai/gpt-4o-mini' };
  }
  return { url: 'https://api.openai.com/v1/chat/completions', key: env.OPENAI_API_KEY, model: env.AI_MODEL || 'gpt-4o-mini' };
}

async function llamarIA(env, messages) {
  const cfg = configIA(env);
  if (!cfg.key) throw new Error('Falta la clave de la IA (OPENAI_API_KEY u OPENROUTER_API_KEY)');
  const controller = new AbortController();
  const timer = setTimeout(function() { controller.abort(); }, 30000);
  try {
    const res = await fetch(cfg.url, {
      method: 'POST',
      signal: controller.signal,
      headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + cfg.key },
      body: JSON.stringify({ model: cfg.model, messages: messages, tools: TOOL_DEFINICIONES, tool_choice: 'auto', max_tokens: 500 })
    });
    const data = await res.json();
    if (!res.ok) throw new Error((data.error && data.error.message) || ('IA devolvió ' + res.status));
    return data.choices && data.choices[0] && data.choices[0].message;
  } finally {
    clearTimeout(timer);
  }
}

async function generarRespuestaIA(senderId, canal, texto, env) {
  const messages = [
    { role: 'system', content: env.AI_SYSTEM_PROMPT || PROMPT_BOT_DEFAULT },
    { role: 'user', content: texto }
  ];
  for (let i = 0; i < 5; i++) {
    const msj = await llamarIA(env, messages);
    const llamadas = (msj && msj.tool_calls || []).filter(function(tc) { return tc && tc.function; });
    if (!llamadas.length) return (msj && msj.content || '').trim();
    messages.push(msj);
    for (const tc of llamadas) {
      const nombre = tc.function.name;
      let args = {};
      try { args = JSON.parse(tc.function.arguments || '{}'); } catch (e) {}
      let out;
      if (nombre === 'buscarProducto') {
        out = await buscarProducto(String(args.consulta || ''), env);
      } else if (nombre === 'escalarHumano') {
        await chatBotEstadoEscalar(senderId, canal, env);
        out = { ok: true };
      } else {
        out = { ok: false, error: 'Función desconocida: ' + nombre };
      }
      messages.push({ role: 'tool', tool_call_id: tc.id, content: JSON.stringify(out) });
    }
  }
  return 'Un momento por favor, te atiende un asesor.';
}

async function buscarProducto(consulta, env) {
  try {
    const q = String(consulta || '').trim();
    if (!q) return { ok: false, error: 'Consulta vacía' };
    const cab = { apikey: env.SUPABASE_ANON_KEY, Authorization: 'Bearer ' + env.SUPABASE_ANON_KEY };
    const texto = q.replace(/[%_]/g, ' ').trim();
    const params = new URLSearchParams();
    params.set('select', 'codigo,descripcion,costo,precio,stock,unidad,stock_minimo');
    params.set('or', '(descripcion.ilike.%' + texto + '%,codigo.ilike.%' + texto + '%)');
    params.set('limit', '8');
    const res = await fetch(env.SUPABASE_URL + '/rest/v1/productos?' + params.toString(), { headers: cab });
    let data = await res.json();
    if (!res.ok) throw new Error('Supabase devolvió ' + res.status);
    if (!Array.isArray(data) || data.length === 0) {
      data = await buscarProductoNormalizado(q, env);
    }
    return { ok: true, items: (data || []).map(function(p) {
      return {
        codigo: p.codigo,
        descripcion: p.descripcion,
        precio: Number(p.precio) || 0,
        stock: Number(p.stock) || 0,
        unidad: p.unidad || 'uds',
        costo: Number(p.costo) || 0
      };
    }) };
  } catch (err) {
    return { ok: false, error: err.message || 'Error buscando el producto' };
  }
}

function normalizarTexto(s) {
  return String(s || '').toLowerCase()
    .replace(/[áàäâ]/g, 'a').replace(/[éèëê]/g, 'e').replace(/[íìïî]/g, 'i')
    .replace(/[óòöô]/g, 'o').replace(/[úùüû]/g, 'u').replace(/ñ/g, 'n')
    .replace(/[^a-z0-9\s]/g, ' ').replace(/\s+/g, ' ').trim();
}

async function buscarProductoNormalizado(q, env) {
  const cab = { apikey: env.SUPABASE_ANON_KEY, Authorization: 'Bearer ' + env.SUPABASE_ANON_KEY };
  const params = new URLSearchParams();
  params.set('select', 'codigo,descripcion,costo,precio,stock,unidad,stock_minimo');
  params.set('limit', '300');
  const res = await fetch(env.SUPABASE_URL + '/rest/v1/productos?' + params.toString(), { headers: cab });
  const data = await res.json();
  if (!Array.isArray(data)) return [];
  const tokens = normalizarTexto(q).split(' ').filter(Boolean);
  return (data || [])
    .map(function(p) {
      const hay = normalizarTexto(p.descripcion + ' ' + p.codigo);
      const aciertos = tokens.filter(function(t) { return hay.indexOf(t) !== -1; }).length;
      return { p: p, aciertos: aciertos };
    })
    .filter(function(x) { return x.aciertos > 0; })
    .sort(function(a, b) { return b.aciertos - a.aciertos; })
    .slice(0, 8)
    .map(function(x) { return x.p; });
}

async function chatBotEstadoGet(telefono, canal, env) {
  try {
    const cab = { 'Content-Type': 'application/json', apikey: env.SUPABASE_ANON_KEY, Authorization: 'Bearer ' + env.SUPABASE_ANON_KEY };
    const res = await fetch(env.SUPABASE_URL + '/rest/v1/rpc/chat_bot_estado_get', {
      method: 'POST', headers: cab, body: JSON.stringify({ p_telefono: telefono, p_canal: canal })
    });
    if (!res.ok) return null;
    return await res.json();
  } catch (e) { return null; }
}

async function chatBotEstadoEscalar(telefono, canal, env) {
  try {
    const cab = { 'Content-Type': 'application/json', apikey: env.SUPABASE_ANON_KEY, Authorization: 'Bearer ' + env.SUPABASE_ANON_KEY };
    await fetch(env.SUPABASE_URL + '/rest/v1/rpc/chat_bot_estado_escalar', {
      method: 'POST', headers: cab, body: JSON.stringify({ p_telefono: telefono, p_canal: canal })
    });
  } catch (e) {}
}

async function enviarPorCanal(canal, destino, texto, env) {
  if (canal === 'whatsapp') return enviarWhatsAppCloud(destino, texto, env);
  return enviarMessenger(destino, texto, env);
}

async function enviarWhatsAppCloud(waId, texto, env) {
  if (!env.META_GRAPH_TOKEN || !env.WA_PHONE_NUMBER_ID) {
    console.error('[BOT] Faltan META_GRAPH_TOKEN o WA_PHONE_NUMBER_ID');
    return { ok: false };
  }
  const ver = env.GRAPH_VERSION || 'v22.0';
  try {
    const res = await fetch('https://graph.facebook.com/' + ver + '/' + env.WA_PHONE_NUMBER_ID + '/messages', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + env.META_GRAPH_TOKEN },
      body: JSON.stringify({ messaging_product: 'whatsapp', to: waId, type: 'text', text: { body: texto } })
    });
    if (!res.ok) {
      const data = await res.json().catch(function() { return null; });
      console.error('[BOT] WhatsApp send error:', JSON.stringify(data || res.status));
      return { ok: false };
    }
    return { ok: true };
  } catch (err) {
    console.error('[BOT] WhatsApp send exception:', err.message);
    return { ok: false };
  }
}

async function enviarMessenger(psid, texto, env) {
  if (!env.MESSENGER_PAGE_TOKEN) {
    console.error('[BOT] Falta MESSENGER_PAGE_TOKEN');
    return { ok: false };
  }
  const ver = env.GRAPH_VERSION || 'v22.0';
  try {
    const res = await fetch('https://graph.facebook.com/' + ver + '/me/messages', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + env.MESSENGER_PAGE_TOKEN },
      body: JSON.stringify({ recipient: { id: psid }, message: { text: texto } })
    });
    if (!res.ok) {
      const data = await res.json().catch(function() { return null; });
      console.error('[BOT] Messenger send error:', JSON.stringify(data || res.status));
      return { ok: false };
    }
    return { ok: true };
  } catch (err) {
    console.error('[BOT] Messenger send exception:', err.message);
    return { ok: false };
  }
}
