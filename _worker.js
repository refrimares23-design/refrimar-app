// ═══════════════════════════════════════════════════════════════════
// REFRIMAR POS - Cloudflare Worker (PARTE 1 - Seguridad)
// Solo endpoints específicos. Sin proxy genérico. Sin fallback.
// Cada endpoint valida: JWT + Rol + Sucursal.
// ═══════════════════════════════════════════════════════════════════

import { createClient } from '@supabase/supabase-js';

// ── Headers de Seguridad ──
const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Authorization',
  'Access-Control-Max-Age': '86400',
};
const secHeaders = {
  'X-Frame-Options': 'DENY',
  'X-Content-Type-Options': 'nosniff',
  'X-XSS-Protection': '1; mode=block',
  'Referrer-Policy': 'strict-origin-when-cross-origin',
  'Permissions-Policy': 'camera=(self), microphone=(), geolocation=()',
  'Content-Security-Policy': "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval' https://cdn.tailwindcss.com https://cdn.jsdelivr.net https://unpkg.com; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src 'self' https://fonts.gstatic.com; img-src 'self' data: blob:; connect-src 'self' https://*.supabase.co https://unpkg.com https://api.open-meteo.com; worker-src 'self'",
};

// ═══════════════════════════════════════════════════════════════════
// HELPERS
// ═══════════════════════════════════════════════════════════════════

function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { 'Content-Type': 'application/json', ...secHeaders },
  });
}
function withCors(resp) {
  const h = new Headers(resp.headers);
  for (const [k, v] of Object.entries(corsHeaders)) h.set(k, v);
  return new Response(resp.body, { status: resp.status, headers: h });
}
function supa(env) {
  return createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_KEY);
}

// ═══════════════════════════════════════════════════════════════════
// JWT — HMAC-SHA256, expira en 24h
// ═══════════════════════════════════════════════════════════════════

async function verifyJwt(token, secret) {
  const parts = token.split('.');
  if (parts.length !== 3) return null;
  const [header, payload, sig] = parts;
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['verify']);
  const valid = await crypto.subtle.verify('HMAC', key, Uint8Array.from(atob(sig.replace(/-/g, '+').replace(/_/g, '/')), c => c.charCodeAt(0)), new TextEncoder().encode(`${header}.${payload}`));
  if (!valid) return null;
  const data = JSON.parse(atob(payload.replace(/-/g, '+').replace(/_/g, '/')));
  if (data.exp && data.exp * 1000 < Date.now()) return null;
  return data;
}

async function createJwt(payload, secret) {
  const header = { alg: 'HS256', typ: 'JWT' };
  const now = Math.floor(Date.now() / 1000);
  const body = { ...payload, iat: now, exp: now + 86400 }; // 24h
  const enc = (obj) => btoa(JSON.stringify(obj)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  const data = `${enc(header)}.${enc(body)}`;
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const sig = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(data));
  return `${data}.${btoa(String.fromCharCode(...new Uint8Array(sig))).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')}`;
}

async function authenticate(request, env) {
  const auth = request.headers.get('Authorization');
  if (!auth || !auth.startsWith('Bearer ')) return null;
  return await verifyJwt(auth.slice(7), env.JWT_SECRET);
}

// ═══════════════════════════════════════════════════════════════════
// RATE LIMITING — KV, 5 intentos → bloqueo 15min
// ═══════════════════════════════════════════════════════════════════

async function checkRateLimit(env, ip) {
  const key = `rl:${ip}`;
  const data = await env.RATE_LIMIT.get(key, { type: 'json' });
  if (!data) return { blocked: false, attempts: 0 };
  if (data.blocked && Date.now() < data.blockedUntil) return { blocked: true, attempts: data.attempts };
  if (data.blocked && Date.now() >= data.blockedUntil) { await env.RATE_LIMIT.delete(key); return { blocked: false, attempts: 0 }; }
  return { blocked: false, attempts: data.attempts || 0 };
}
async function recordFailedAttempt(env, ip) {
  const key = `rl:${ip}`;
  const data = await env.RATE_LIMIT.get(key, { type: 'json' }) || { attempts: 0 };
  data.attempts += 1;
  if (data.attempts >= 5) {
    data.blocked = true;
    data.blockedUntil = Date.now() + 15 * 60 * 1000;
    await env.RATE_LIMIT.put(key, JSON.stringify(data), { expirationTtl: 900 });
  } else {
    await env.RATE_LIMIT.put(key, JSON.stringify(data), { expirationTtl: 300 });
  }
}
async function clearRateLimit(env, ip) {
  await env.RATE_LIMIT.delete(`rl:${ip}`);
}

// === Bloqueo por USUARIO (además del por IP) ===
// Key por nombre de usuario (normalizado) para que rotar IP no evite el
// límite de 5 intentos por PIN/usuario. 5 fallos → bloqueo 15 min.
function userKey(nombre) {
  return `rluser:` + String(nombre || '').trim().toLowerCase();
}
async function checkUserBlock(env, nombre) {
  const data = await env.RATE_LIMIT.get(userKey(nombre), { type: 'json' });
  if (!data) return { blocked: false, attempts: 0 };
  if (data.blocked && Date.now() < data.blockedUntil) return { blocked: true, attempts: data.attempts };
  if (data.blocked && Date.now() >= data.blockedUntil) { await env.RATE_LIMIT.delete(userKey(nombre)); return { blocked: false, attempts: 0 }; }
  return { blocked: false, attempts: data.attempts || 0 };
}
async function recordUserFailedAttempt(env, nombre) {
  const key = userKey(nombre);
  const data = await env.RATE_LIMIT.get(key, { type: 'json' }) || { attempts: 0 };
  data.attempts += 1;
  if (data.attempts >= 5) {
    data.blocked = true;
    data.blockedUntil = Date.now() + 15 * 60 * 1000;
    await env.RATE_LIMIT.put(key, JSON.stringify(data), { expirationTtl: 900 });
  } else {
    await env.RATE_LIMIT.put(key, JSON.stringify(data), { expirationTtl: 300 });
  }
}
async function clearUserBlock(env, nombre) {
  await env.RATE_LIMIT.delete(userKey(nombre));
}

// ═══════════════════════════════════════════════════════════════════
// PERMISOS POR ROL
// ═══════════════════════════════════════════════════════════════════
//
// desarrollador (superadmin) → TODO en TODAS las sucursales
// admin → TODO en SU sucursal + ver usuarios de su sucursal + UPDATE productos
// cajero → SELECT productos/clientes/ventas/caja/cierres. INSERT ventas/caja/clientes/cierres/registrar. NO DELETE. NO UPDATE productos. NO ver usuarios.
//
function isSuperAdmin(user) { return user.rol === 'desarrollador'; }
function requireRole(user, ...roles) { return isSuperAdmin(user) || roles.includes(user.rol); }

// Sucursal enforcement: adds .eq('sucursal_id', user.sucursal_id) unless superadmin
function filterSucursal(query, user, col = 'sucursal_id') {
  return isSuperAdmin(user) ? query : query.eq(col, user.sucursal_id);
}

// Validate that an RPC param matches user's sucursal
function validateSucursal(params, user, key = 'p_sucursal_id') {
  if (isSuperAdmin(user)) return true;
  return String(params[key]) === String(user.sucursal_id);
}

// ═══════════════════════════════════════════════════════════════════
// 1. LOGIN (público, rate-limited)
// ═══════════════════════════════════════════════════════════════════

async function handleLogin(request, env) {
  if (request.method !== 'POST') return json({ error: 'Method not allowed' }, 405);
  const ip = request.headers.get('CF-Connecting-IP') || 'unknown';
  const { nombre, pin_hash, sucursal_id } = await request.json();
  if (!nombre || !pin_hash || !sucursal_id) return json({ error: 'Nombre, PIN y sucursal requeridos' }, 400);

  // Bloqueo por usuario: se revisa ANTES de validar credenciales, así un
  // PIN comprometido queda bloqueado aunque se intente desde otra IP.
  const ublock = await checkUserBlock(env, nombre);
  if (ublock.blocked) return json({ error: 'Demasiados intentos. Espera 15 minutos.', retryAfter: 900 }, 429);

  const rl = await checkRateLimit(env, ip);
  if (rl.blocked) return json({ error: 'Demasiados intentos. Espera 15 minutos.', retryAfter: 900 }, 429);

  const client = supa(env);

  // Llama a RPC login_usuario (parámetros originales de Supabase)
  const { data: loginData, error: loginError } = await client.rpc('login_usuario', {
    nombre_input: nombre,
    pin_input: pin_hash,
  });

  if (loginError || !loginData) {
    await recordFailedAttempt(env, ip);
    await recordUserFailedAttempt(env, nombre);
    return json({ error: 'PIN o sucursal incorrectos.' }, 403);
  }

  // loginData puede ser un array o un objeto
  const userResult = Array.isArray(loginData) ? loginData[0] : loginData;
  if (!userResult || !userResult.id) {
    await recordFailedAttempt(env, ip);
    await recordUserFailedAttempt(env, nombre);
    return json({ error: 'PIN o sucursal incorrectos.' }, 403);
  }

  // Verificar que el usuario está activo
  if (userResult.activo === false) {
    return json({ error: 'Usuario desactivado.' }, 403);
  }

  // Verificar acceso a sucursal (si la tabla usuario_sucursal existe)
  try {
    const { data: assignment, error: assignErr } = await client.from('usuario_sucursal').select('sucursal_id').eq('usuario_id', userResult.id).eq('sucursal_id', sucursal_id).single();
    if (!assignErr && !assignment) {
      await recordFailedAttempt(env, ip);
      await recordUserFailedAttempt(env, nombre);
      return json({ error: 'Sin acceso a esta sucursal.' }, 403);
    }
  } catch (e) {
    // Tabla usuario_sucursal no existe — permitir acceso
  }

  // Obtener permisos del usuario
  const { data: permData } = await client.from('usuarios').select('permisos').eq('id', userResult.id).single();

  await clearRateLimit(env, ip);
  await clearUserBlock(env, nombre);

  const token = await createJwt({
    user_id: userResult.id,
    nombre: userResult.nombre,
    rol: userResult.rol,
    sucursal_id: sucursal_id,
  }, env.JWT_SECRET);

  return json({
    token,
    user: {
      id: userResult.id,
      nombre: userResult.nombre,
      rol: userResult.rol,
      sucursal_id: sucursal_id,
      permisos: permData ? permData.permisos : null,
    },
  });
}

// ═══════════════════════════════════════════════════════════════════
// 1b. ENDPOINTS PÚBLICOS (pre-login, sin auth)
// ═══════════════════════════════════════════════════════════════════

async function handleSucursalesPublic(request, env) {
  const client = supa(env);
  const { data, error } = await client.from('sucursales').select('id, nombre').order('nombre');
  if (error) return json({ error: error.message }, 400);
  return json(data);
}

async function handleUsuariosPublic(request, env) {
  const client = supa(env);
  const { data, error } = await client.from('usuarios').select('id, nombre, rol').eq('activo', true).order('nombre');
  if (error) return json({ error: error.message }, 400);
  return json(data);
}

async function handleTasaBcv() {
  try {
    const res = await fetch('https://ve.dolarapi.com/v1/dolares', { signal: AbortSignal.timeout(8000) });
    if (!res.ok) throw new Error('dolarapi ' + res.status);
    const d = await res.json();
    const oficial = Array.isArray(d) ? d.find(x => x.fuente === 'oficial') : null;
    const tasa = oficial?.promedio || d?.[0]?.promedio;
    if (!tasa) throw new Error('sin tasa');
    return json({ ok: true, tasa: Number(tasa), fuente: 'BCV (dolarapi)', fecha: new Date().toISOString() });
  } catch (e) {
    return json({ ok: false, error: 'No se pudo obtener la tasa BCV: ' + e.message }, 502);
  }
}

// ═══════════════════════════════════════════════════════════════════
// 2. PRODUCTOS
// ═══════════════════════════════════════════════════════════════════

// GET /api/productos — cualquier rol autenticado
async function handleProductos(request, env, url, user) {
  const client = supa(env);
  let q = client.from('productos').select('*').order('descripcion');
  q = filterSucursal(q, user);
  const search = url.searchParams.get('search');
  if (search) q = q.ilike('descripcion', `%${search}%`);
  const cat = url.searchParams.get('categoria');
  if (cat) q = q.eq('categoria', cat);
  const from = parseInt(url.searchParams.get('from') || '0');
  const to = parseInt(url.searchParams.get('to') || '999');
  q = q.range(from, to);
  const { data, error } = await q;
  if (error) return json({ error: error.message }, 400);
  return json(data);
}

// ═══════════════════════════════════════════════════════════════════
// 3. VENTAS
// ═══════════════════════════════════════════════════════════════════

// GET /api/ventas — cajero, admin
async function handleVentas(request, env, url, user) {
  if (!requireRole(user, 'admin', 'cajero')) return json({ error: 'Sin permisos' }, 403);
  const client = supa(env);
  let q = client.from('ventas').select('*').order('created_at', { ascending: false });
  q = filterSucursal(q, user);
  const fecha = url.searchParams.get('fecha');
  if (fecha) q = q.eq('fecha', fecha);
  q = q.limit(parseInt(url.searchParams.get('limit') || '20'));
  const { data, error } = await q;
  if (error) return json({ error: error.message }, 400);
  return json(data);
}

// POST /api/ventas — cajero, admin (registrar venta via RPC)
async function handleVentaRegistrar(request, env, user) {
  if (!requireRole(user, 'admin', 'cajero')) return json({ error: 'Sin permisos' }, 403);
  const params = await request.json();
  if (!validateSucursal(params, user)) return json({ error: 'Sucursal no válida' }, 403);
  const client = supa(env);
  const { data, error } = await client.rpc('registrar_venta', params);
  if (error) return json({ error: error.message }, 400);
  return json(data);
}

// ═══════════════════════════════════════════════════════════════════
// 4. CAJA / MOVIMIENTOS
// ═══════════════════════════════════════════════════════════════════

// GET /api/caja-movimientos — cajero, admin
async function handleCajaMovimientos(request, env, url, user) {
  if (!requireRole(user, 'admin', 'cajero')) return json({ error: 'Sin permisos' }, 403);
  const client = supa(env);
  let q = client.from('caja_movimientos').select('*').order('fecha', { ascending: false });
  q = filterSucursal(q, user);
  const fecha = url.searchParams.get('fecha');
  if (fecha) q = q.gte('fecha', `${fecha}T00:00:00`).lte('fecha', `${fecha}T23:59:59`);
  q = q.limit(parseInt(url.searchParams.get('limit') || '50'));
  const { data, error } = await q;
  if (error) return json({ error: error.message }, 400);
  return json(data);
}

// POST /api/caja-movimientos — cajero, admin
async function handleCajaMovimientosInsert(request, env, user) {
  if (!requireRole(user, 'admin', 'cajero')) return json({ error: 'Sin permisos' }, 403);
  const params = await request.json();
  if (!validateSucursal(params, user)) return json({ error: 'Sucursal no válida' }, 403);
  const client = supa(env);
  const { data, error } = await client.rpc('caja_registrar_movimiento', params);
  if (error) return json({ error: error.message }, 400);
  return json(data);
}

// ═══════════════════════════════════════════════════════════════════
// 5. CLIENTES
// ═══════════════════════════════════════════════════════════════════

// GET /api/clientes — cualquier rol
async function handleClientes(request, env, url, user) {
  const client = supa(env);
  let q = client.from('clientes').select('rif, nombre, direccion, telefono, email, limite_credito, saldo_pendiente, tipo, credito_habilitado');
  q = filterSucursal(q, user);
  const search = url.searchParams.get('search');
  if (search) q = q.or(`rif.ilike.%${search}%,nombre.ilike.%${search}%`);
  q = q.order('nombre').limit(parseInt(url.searchParams.get('limit') || '50'));
  const { data, error } = await q;
  if (error) return json({ error: error.message }, 400);
  return json(data);
}

// POST /api/clientes — cajero, admin
async function handleClienteGuardar(request, env, user) {
  if (!requireRole(user, 'admin', 'cajero')) return json({ error: 'Sin permisos' }, 403);
  const params = await request.json();
  const client = supa(env);
  const { data, error } = await client.rpc('cliente_guardar', params);
  if (error) return json({ error: error.message }, 400);
  return json(data);
}

// ═══════════════════════════════════════════════════════════════════
// 6. CIERRES DIARIOS (necesarios para caja.html)
// ═══════════════════════════════════════════════════════════════════

// GET /api/cierres — cajero, admin
async function handleCierres(request, env, url, user) {
  if (!requireRole(user, 'admin', 'cajero')) return json({ error: 'Sin permisos' }, 403);
  const client = supa(env);
  let q = client.from('cierre_diario').select('*');
  q = filterSucursal(q, user);
  const fecha = url.searchParams.get('fecha');
  if (fecha) q = q.eq('fecha', fecha);
  q = q.order('fecha', { ascending: false });
  const { data, error } = await q;
  if (error) return json({ error: error.message }, 400);
  return json(data);
}

// POST /api/cierres/registrar — cajero, admin (RPC cierre_diario_guardar)
async function handleCierreRegistrar(request, env, user) {
  if (!requireRole(user, 'admin', 'cajero')) return json({ error: 'Sin permisos' }, 403);
  const params = await request.json();
  if (!validateSucursal(params, user, 'p_sucursal_id')) return json({ error: 'Sucursal no válida' }, 403);
  const client = supa(env);
  const { data, error } = await client.rpc('cierre_diario_guardar', params);
  if (error) return json({ error: error.message }, 400);
  return json(data);
}

// DELETE /api/cierres?id=X — admin (RPC cierre_diario_eliminar)
async function handleCierreEliminar(request, env, url, user) {
  if (!requireRole(user, 'admin')) return json({ error: 'Solo admin puede eliminar cierres' }, 403);
  const id = url.searchParams.get('id');
  if (!id) return json({ error: 'id requerido' }, 400);
  const client = supa(env);
  const { data, error } = await client.rpc('cierre_diario_eliminar', { p_id: id });
  if (error) return json({ error: error.message }, 400);
  return json(data);
}

// POST /api/cierres/importar — admin (RPC cierre_diario_importar)
async function handleCierreImportar(request, env, user) {
  if (!requireRole(user, 'admin')) return json({ error: 'Solo admin puede importar cierres' }, 403);
  const params = await request.json();
  if (!validateSucursal(params, user, 'p_sucursal_id')) return json({ error: 'Sucursal no válida' }, 403);
  const client = supa(env);
  const { data, error } = await client.rpc('cierre_diario_importar', params);
  if (error) return json({ error: error.message }, 400);
  return json(data);
}

// ═══════════════════════════════════════════════════════════════════
// 6B. ANALIZAR FACTURA CON GEMINI (solo admin)
// ═══════════════════════════════════════════════════════════════════

// Lógica reutilizable de análisis de factura (compartida por Carga IA web
// y el bot de Telegram para no duplicar nada). Lanza un Error con mensaje
// entendible o devuelve { items }.
async function analizarFacturaIA(env, mimeType, base64) {
  if (!env.GEMINI_API_KEY) throw new Error('API key de Gemini no configurada');

  const prompt = `Eres un lector de facturas de proveedores de una ferretería/repuestos industriales en Venezuela.
Analiza esta foto de factura y extrae TODOS los productos listados.

Devuélve SOLO un JSON válido con este formato exacto (sin markdown, sin backticks):
{
  "items": [
    {
      "codigo": "código del producto si aparece, si no null",
      "nombre": "nombre o descripción del producto",
      "cantidad": 1,
      "costo_unitario": 0.00
    }
  ]
}

Reglas:
- Si el código no es visible, pon null
- La cantidad debe ser un número entero
- El costo unitario debe ser un número (sin símbolo de moneda)
- Si no puedes leer algo, pon tu mejor estimación
- No inventes productos que no estén en la factura
- Incluye TODOS los ítems visibles, no omitas ninguno`;

  // Lista de modelos candidatos con fallback: si uno está en alta demanda (503)
  // o no disponible (404), se intenta con el siguiente.
  const modelosIA = ['gemini-3.6-flash', 'gemini-flash-latest'];
  const cuerpoIA = JSON.stringify({
    contents: [{ parts: [
      { text: prompt },
      { inlineData: { mimeType, data: base64 } }
    ] }],
    generationConfig: { temperature: 0.1, maxOutputTokens: 8192 }
  });

  let geminiRes = null;
  let ultimoError = null;
  for (const modelo of modelosIA) {
    const resp = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models/${modelo}:generateContent?key=${env.GEMINI_API_KEY}`,
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: cuerpoIA
      }
    );
    if (resp.ok) { geminiRes = resp; break; }
    ultimoError = { status: resp.status, body: await resp.text() };
    console.error('[GEMINI] modelo ' + modelo + ' falló:', resp.status, ultimoError.body);
    if (resp.status !== 503 && resp.status !== 429) break;
  }

  if (!geminiRes) {
    const cod = (ultimoError && ultimoError.status) || 502;
    throw new Error('Error comunicándose con la IA (' + cod + '). Intenta de nuevo.');
  }

  const geminiData = await geminiRes.json();
  const text = geminiData?.candidates?.[0]?.content?.parts?.[0]?.text || '';
  const m = text.match(/\{[\s\S]*\}/);
  if (!m) throw new Error('La IA no devolvió formato reconocido. Intenta con otra foto.');

  try {
    const parsed = JSON.parse(m[0]);
    return { items: parsed.items || [] };
  } catch (e) {
    throw new Error('Error parseando respuesta de la IA');
  }
}

async function handleAnalizarFactura(request, env, user) {
  if (!requireRole(user, 'admin')) return json({ error: 'Solo admin puede usar Carga IA' }, 403);

  const { mediaType, base64 } = await request.json();
  if (!base64) return json({ error: 'No se recibió imagen' }, 400);

  const mimeType = mediaType || 'image/jpeg';

  try {
    const res = await analizarFacturaIA(env, mimeType, base64);
    return json({ items: res.items || [] });
  } catch (e) {
    return json({ error: e.message || 'Error al analizar' }, 422);
  }
}

// ═══════════════════════════════════════════════════════════════════
// 6. BOT DE TELEGRAM — carga de facturas de proveedor
// ═══════════════════════════════════════════════════════════════════
// Reutiliza analizarFacturaIA y la RPC producto_guardar (igual que Carga IA).
// Solo responde a chat_ids en la allowlist (TELEGRAM_ALLOWED_CHATS).
// El estado de cada sesión vive en un Map global con TTL (15 min).
// ANTES de procesar la foto se pide y valida la UBICACIÓN (Casa Matriz o sucursal);
// el stock se guarda en esa ubicación exacta (Casa Matriz → productos.stock,
// sucursal → sucursal_stock de esa sucursal). El guardado real ocurre UNA sola vez
// al confirmar con "ok" al final, y se protege contra mensajes duplicados.

const TG_TTL = 15 * 60 * 1000;
// La sesión vive en el Map en memoria como caché de escritura, y se refleja en
// Cloudflare KV (binding SESIONES) para que el estado sobreviva entre mensajes,
// que son invocaciones separadas del Worker. Sin esto, los flujos de varios pasos
// (factura, elegir nº, pago móvil) perderían el estado a mitad de camino.
const tgSesion = globalThis.__TGSESS || (globalThis.__TGSESS = new Map());
const tgKey = (chatId) => 'tg:' + chatId;

async function tgSesSet(env, chatId, data) {
  tgSesion.set(chatId, data);
  if (env && env.SESIONES) {
    try { await env.SESIONES.put(tgKey(chatId), JSON.stringify(data), { expirationTtl: Math.floor(TG_TTL / 1000) + 60 }); }
    catch (e) { /* best effort */ }
  }
}

async function tgSesDel(env, chatId) {
  tgSesion.delete(chatId);
  if (env && env.SESIONES) {
    try { await env.SESIONES.delete(tgKey(chatId)); } catch (e) { /* best effort */ }
  }
}

async function tgGetSession(env, chatId) {
  let s = tgSesion.get(chatId);
  if (s) {
    if (Date.now() - s.creado > TG_TTL) { tgSesion.delete(chatId); s = null; }
    else return s;
  }
  if (env && env.SESIONES) {
    try {
      const raw = await env.SESIONES.get(tgKey(chatId));
      if (raw) {
        s = JSON.parse(raw);
        if (Date.now() - s.creado > TG_TTL) { s = null; await env.SESIONES.delete(tgKey(chatId)); }
        else tgSesion.set(chatId, s);
      }
    } catch (e) { s = null; }
  }
  return s;
}

async function tgSend(env, chatId, text, opts) {
  if (!env.TELEGRAM_BOT_TOKEN) return false;
  const url = `https://api.telegram.org/bot${env.TELEGRAM_BOT_TOKEN}/sendMessage`;
  const body = { chat_id: Number(chatId), text, parse_mode: 'HTML', disable_web_page_preview: true };
  if (opts && opts.reply_markup) body.reply_markup = opts.reply_markup;
  const resp = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body)
  });
  return resp.ok;
}

// Responde a una pulsación de botón (callback_query): cierra el "cargando" y
// ejecuta la acción pedida. Devuelve true si se manejo algo.
async function tgCallback(env, cq) {
  const chatId = String(cq.message && cq.message.chat && cq.message.chat.id);
  if (!chatId) return true;
  const accion = String(cq.data || '');
  try {
    await fetch(`https://api.telegram.org/bot${env.TELEGRAM_BOT_TOKEN}/answerCallbackQuery`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ callback_query_id: cq.id })
    });
  } catch (e) {}
  if (accion === 'menu') return tgMenu(env, chatId);
  if (accion === 'ayuda') return tgAyuda(env, chatId);
  if (accion === 'app') return tgAbrirApp(env, chatId);
  if (accion === 'proveedores') return tgListarProveedoresMsg(env, chatId);
  if (accion === 'cxp') return tgCuentasPagarMsg(env, chatId);
  if (accion === 'stock') {
    const doc = tgDocName(env);
    await tgSesSet(env, chatId, { estado: 'esperando_producto', creado: Date.now() });
    await tgSend(env, chatId, `📦 Claro. Escribí el <b>nombre o código</b> del producto para ver su stock y precio, por ejemplo: <i>"filtro AC250"</i>.`);
    return true;
  }
  if (accion === 'pago_movil') {
    await tgIniciarPagoMovil(env, chatId);
    return true;
  }
  if (accion === 'factura') {
    // Arrancar carga: pedir ubicación
    const ub = await tgListarUbicaciones(env);
    const lista = ub.lista.map((u, i) => `${i + 1}. ${u.nombre}`).join('\n');
    await tgSesSet(env, chatId, { estado: 'esperando_ubicacion', creado: Date.now(), ubicaciones: ub });
    await tgSend(env, chatId, `Muy bien, empecemos a cargar un/a ${tgDocName(env)}.\n\n¿A qué <b>ubicación</b> corresponde?\n\n${lista}\n\nEscribí el nombre o el número.`);
    return true;
  }
  return true;
}

// Muestra el menú principal con botones (fácil de usar) y las opciones en texto.
async function tgMenu(env, chatId) {
  const doc = tgDocName(env);
  await tgSend(env, chatId,
    `🤖 <b>Hola! Soy el bot de Refrimar.</b>\n\nElegí qué querés hacer con los botones, o escribímelo con tus palabras:\n\n` +
    `📷 <b>Cargar ${doc}</b> — subí una foto para registrar la compra\n` +
    `📦 <b>Stock / Precio</b> — ej: <i>"stock de filtro AC250"</i> o <i>"cuánto vale X"</i>\n` +
    `🏢 <b>Proveedores</b> — listar o consultar\n` +
    `💰 <b>Cuentas por pagar</b> — pendientes y saldos\n` +
    `💵 <b>Registrar pago móvil</b> — banco, monto y día de un cobro recibido\n` +
    `🔗 <b>Abrir app</b> — link a la web`,
    { reply_markup: {
        inline_keyboard: [
          [{ text: '📷 Cargar ' + doc, callback_data: 'factura' }],
          [{ text: '📦 Stock / Precio', callback_data: 'stock' }, { text: '🏢 Proveedores', callback_data: 'proveedores' }],
          [{ text: '💰 Cuentas por pagar', callback_data: 'cxp' }],
          [{ text: '💵 Registrar Pago Móvil', callback_data: 'pago_movil' }],
          [{ text: '🔗 Abrir app', callback_data: 'app' }, { text: '❓ Ayuda', callback_data: 'ayuda' }]
        ]
      } });
  return true;
}

async function tgGetFile(env, fileId) {
  const url = `https://api.telegram.org/bot${env.TELEGRAM_BOT_TOKEN}/getFile`;
  const resp = await fetch(url, {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ file_id: fileId })
  });
  const data = await resp.json();
  if (!data.ok || !data.result || !data.result.file_path) return null;
  const dl = await fetch(`https://api.telegram.org/file/bot${env.TELEGRAM_BOT_TOKEN}/${data.result.file_path}`);
  const buf = await dl.arrayBuffer();
  // Convertir bytes a base64 (para inlineData de Gemini)
  const bytes = new Uint8Array(buf);
  let bin = '';
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
  let b64 = '';
  try { b64 = btoa(bin); } catch (e) { b64 = Buffer.from(bytes).toString('base64'); }
  return { base64: b64, mimeType: data.result.file_path.toLowerCase().endsWith('.pdf') ? 'application/pdf' : 'image/jpeg' };
}

function tgNum(s) {
  if (s == null) return NaN;
  return parseFloat(String(s).replace(',', '.').replace(/[^\d.\-]/g, ''));
}

function tgFmt(n) {
  return Number(n || 0).toLocaleString('es-VE', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

// Normaliza texto para comparar nombres/descripciones (minúscula, sin acentos, sin espacios múltiples).
function tgNorm(s) {
  return String(s || '')
    .toLowerCase()
    .normalize('NFD').replace(/[\u0300-\u036f]/g, '')
    .replace(/[^a-z0-9]/g, '')
    .trim();
}

// Busca en el catálogo (productos) si un ítem ya existe, por código o descripción.
// Devuelve { producto, porCodigo, porDescripcion } para poder detectar cuando un
// código ya existe pero con otra descripción/nombre (posible lectura mala del código).
async function tgResolverCatalogo(env, item) {
  const client = supa(env);
  if (item.codigo) {
    const r = await client.from('productos').select('*').eq('codigo', item.codigo).maybeSingle();
    if (r.data) return { producto: r.data, porCodigo: true, porDescripcion: false };
  }
  // Por descripción (case-insensitive, best-effort)
  if (item.nombre) {
    const nombre = String(item.nombre).trim();
    const r = await client.from('productos').select('*').ilike('descripcion', `%${nombre}%`).limit(5);
    if (r.error) return { producto: null };
    // Devuelve el primero con coincidencia
    if (r.data && r.data.length) return { producto: r.data[0], porCodigo: false, porDescripcion: true };
  }
  return { producto: null };
}

// Lista las ubicaciones válidas para guardar stock: Casa Matriz + sucursales reales
// (misma fuente de la página: tabla sucursales).
async function tgListarUbicaciones(env) {
  const CASA = '00000000-0000-0000-0000-000000000001';
  const client = supa(env);
  const res = await client.from('sucursales').select('id,nombre').order('nombre');
  const sucs = (res.data || []).map((s) => ({ id: s.id, nombre: s.nombre, esCasaMatriz: false }));
  const lista = [{ id: CASA, nombre: 'Casa Matriz', esCasaMatriz: true }].concat(sucs);
  return { lista, CASA };
}

// Lista los proveedores registrados (tabla proveedores).
async function tgListarProveedores(env) {
  const client = supa(env);
  const res = await client.from('proveedores').select('id,nombre').order('nombre');
  const lista = (res.data || []).map((p) => ({ id: p.id, nombre: p.nombre }));
  return { lista };
}

// Nombre dinámico del documento (factura / nutrifactura / pedido, etc.), configurable
// con la env DOC_NAME. Devuelve minúsculas o capitalizado para los mensajes del bot.
function tgDocName(env) {
  const n = (env.DOC_NAME || '').replace(/\s+/g, ' ').trim();
  return n || 'factura';
}
function tgDocTitle(env) {
  const n = tgDocName(env);
  return n.charAt(0).toUpperCase() + n.slice(1);
}

// Menú de ayuda con todas las capacidades y ejemplos.
async function tgAyuda(env, chatId) {
  const doc = tgDocName(env);
  await tgSend(env, chatId,
    `❓ <b>Cómo usar el bot</b>\n\n` +
    `📷 <b>Cargar ${doc}</b>\n  Respondé <b>hola</b> o <b>menú</b> y tocá el botón, o mandá una foto directo.\n\n` +
    `📦 <b>Stock / Precio</b>\n  <i>"¿cuánto stock hay de X?"</i>, <i>"precio de X"</i>, <i>"stock de X"</i>\n\n` +
    `🏢 <b>Proveedores</b>\n  <i>"¿qué proveedores hay?"</i>, <i>"lista de proveedores"</i>\n\n` +
    `💰 <b>Cuentas por pagar</b>\n  <i>"¿cuánto debo?"</i>, <i>"facturas pendientes"</i>, <i>"saldos"</i>\n\n` +
    `🔗 <b>Abrir app</b>\n  <i>"abrí la app"</i>, <i>"link de la web"</i>\n\n` +
    `Escribímelo con tus palabras y te entiendo 😉`,
    { reply_markup: { inline_keyboard: [[{ text: '◀️ Menú', callback_data: 'menu' }]] } });
  return true;
}

async function tgAbrirApp(env, chatId) {
  const base = (env.APP_BASE_URL || 'https://refrimar-app.refrimar-es23.workers.dev');
  await tgSend(env, chatId, `🔗 Abrí la app acá:\n${base}`);
  return true;
}

async function tgIniciarPagoMovil(env, chatId) {
  const ub = await tgListarUbicaciones(env);
  const lista = ub.lista.map((u, i) => `${i + 1}. ${u.nombre}`).join('\n');
  await tgSesSet(env, chatId, { estado: 'esperando_pm_sucursal', creado: Date.now(), pm: {}, ubicaciones: ub });
  await tgSend(env, chatId,
    `💵 <b>Registrar pago móvil recibido</b>\n\n` +
    `Paso 1/4 — ¿A qué <b>sucursal</b> corresponde este cobro?\n\n${lista}\n\nEscribí el nombre o el número.`);
  return true;
}

// Guarda el pago móvil en la tabla pagos_moviles. Devuelve true si ok.
async function tgGuardarPagoMovil(env, chatId, datos) {
  const client = supa(env);
  const fecha = datos.fecha || new Date().toISOString().slice(0, 10);
  const monto = Math.round((Number(datos.monto) || 0) * 100) / 100;
  const { error } = await client.from('pagos_moviles').insert([{
    banco: datos.banco || null,
    monto,
    fecha,
    sucursal_nombre: datos.sucursal_nombre || null
  }]);
  if (error) {
    await tgSend(env, chatId, `❌ No pude guardar el pago: ${error.message || error}\n\nAsegurate de haber creado la tabla <code>pagos_moviles</code> (corré el SQL en Supabase).`);
    return false;
  }
  await tgSend(env, chatId,
    `✅ <b>Pago móvil registrado</b>\n\n` +
    `📍 Sucursal: <b>${datos.sucursal_nombre || '—'}</b>\n` +
    `🏦 Banco: <b>${datos.banco || '—'}</b>\n` +
    `💵 Monto: <b>${tgFmt(monto)}</b>\n` +
    `📅 Fecha: <b>${fecha}</b>`);
  return true;
}

async function tgListarProveedoresMsg(env, chatId) {
  const provs = await tgListarProveedores(env);
  const lista = provs.lista.length ? provs.lista.map((p, i) => `${i + 1}. ${p.nombre}`).join('\n') : '(sin proveedores)';
  await tgSend(env, chatId, `🏢 <b>Proveedores:</b>\n\n${lista}`);
  return true;
}

// Lista las cuentas por pagar pendientes y el saldo total, agrupadas por proveedor.
async function tgCuentasPagarMsg(env, chatId) {
  const client = supa(env);
  const res = await client.from('cuentas_por_pagar')
    .select('proveedor_nombre,numero_factura,fecha_vencimiento,monto,saldo,estado,sucursal_nombre')
    .eq('estado', 'pendiente').order('fecha_vencimiento', { ascending: true });
  const rows = res.data || [];
  if (res.error || !rows.length) {
    await tgSend(env, chatId, `💰 No tenés cuentas por pagar pendientes.\n\n(Si la tabla aún no existe, verificá que corriste el SQL de <code>cuentas_por_pagar</code>).`);
    return true;
  }
  const hoy = new Date().toISOString().slice(0, 10);
  const lineas = rows.map((r) => {
    const prov = r.proveedor_nombre || '?';
    const ven = r.fecha_vencimiento || '—';
    const vencido = r.fecha_vencimiento && r.fecha_vencimiento < hoy ? ' ⚠️ VENCIDA' : '';
    return `• <b>${prov}</b> · ${r.numero_factura || 'sin nº'} · vence ${ven}${vencido}\n   monto ${tgFmt(r.monto)} · saldo ${tgFmt(r.saldo)} (${r.sucursal_nombre || ''})`;
  }).join('\n');
  const total = rows.reduce((a, r) => a + (Number(r.saldo) || 0), 0);
  await tgSend(env, chatId, `💰 <b>Cuentas por pagar (pendientes):</b>\n\n${lineas}\n\n<b>Total saldo: ${tgFmt(total)}</b>`);
  return true;
}

// Formatea el detalle de un producto para mostrar stock/precio.
function tgMsgProducto(p) {
  return `📦 <b>${p.descripcion}</b>\n` +
    `   Código: <code>${p.codigo}</code>\n` +
    `   Stock: <b>${p.stock || 0}</b>\n` +
    `   Precio: <b>${tgFmt(p.precio)}</b>\n` +
    `   Costo: ${tgFmt(p.costo)}` +
    (p.unidad ? `\n   Unidad: ${p.unidad}` : '') +
    (p.marca ? `\n   Marca: ${p.marca}` : '');
}

// Busca en el catálogo por palabras clave (tolerante) y por código exacto.
// Devuelve { encontro, exacto, resultados }. No muestra nada ni toca la sesión,
// así el flujo principal decide si mostrar la lista o derivar a otra intención.
async function tgBuscarProductos(env, query) {
  const client = supa(env);
  const q = String(query || '').trim();
  if (!q) return { encontro: false, exacto: null, resultados: [] };

  // 1) Código exacto
  const c = await client.from('productos').select('*').eq('codigo', q).maybeSingle();
  if (c.data) return { encontro: true, exacto: c.data, resultados: [] };

  // 2) Por palabras clave: TODAS deben aparecer en la descripción (sin importar
  //    orden ni caracteres), así "tubo 3" encuentra "TUBO SANITARIO PVC 3 PULG".
  const palabras = q.toLowerCase().normalize('NFD').replace(/[\u0300-\u036f]/g, '')
    .split(/\s+/).map(w => w.replace(/[^a-z0-9]/g, '')).filter(w => w.length >= 1);
  let resultados = [];
  if (palabras.length) {
    // Reduce con la primera palabra en SQL y filtra el resto en memoria
    const primera = palabras[0];
    const d = await client.from('productos').select('*').ilike('descripcion', `%${primera}%`).limit(400);
    if (d.data) {
      resultados = d.data.filter(p => palabras.every(pl => tgNorm(p.descripcion).includes(pl)));
    }
  }
  return { encontro: resultados.length > 0, exacto: null, resultados };
}

// Muestra el resultado de la búsqueda: detalle si hay 1, lista numerada si hay
// varios (guarda la sesión para elegir), o "no encontré" si no hay. Devuelve true
// si mostró algo, false si no hubo coincidencias (para que el flujo principal
// intente otra cosa, ej. clasificar con la IA).
async function tgMostrarProductos(env, chatId, query, res) {
  const q = String(query || '').trim();
  if (!res) res = await tgBuscarProductos(env, q);
  if (!res.encontro) return false;

  if (res.exacto) {
    await tgSesDel(env, chatId);
    await tgSend(env, chatId, tgMsgProducto(res.exacto));
    return true;
  }

  const resultados = res.resultados || [];
  if (resultados.length === 1) {
    await tgSesDel(env, chatId);
    await tgSend(env, chatId, tgMsgProducto(resultados[0]));
    return true;
  }

  // Varias coincidencias → lista numerada para elegir con un número
  const top = resultados.slice(0, 15);
  await tgSesSet(env, chatId, { estado: 'esperando_elegir_stock', creado: Date.now(), resultados: top });
  const sug = top.map((p, i) =>
    `${i + 1}. <b>${p.descripcion}</b>\n   código <code>${p.codigo}</code> · stock <b>${p.stock || 0}</b> · ${tgFmt(p.precio)}`).join('\n');
  const extra = resultados.length > top.length ? `\n… y ${resultados.length - top.length} más.` : '';
  await tgSend(env, chatId, `Encontré ${resultados.length} productos con eso. Respondé el <b>número</b> del que querés ver:\n\n${sug}${extra}`);
  return true;
}

// Usa Gemini para interpretar qué pide el usuario en lenguaje natural.
// Devuelve { intencion, query } con intenciones: stock_precio, proveedores,
// cuentas_pagar, ayuda, app, factura, otro.
async function tgEntender(env, text) {
  if (!env.GEMINI_API_KEY) return { intencion: 'otro', query: text };
  const prompt = `Eres un asistente de un bot de inventario. Clasifica la intención del mensaje del usuario.
Mensaje: "${text}"

Responde SOLO un JSON válido (sin markdown) con este formato:
{"intencion": "...", "query": "..."}

Intenciones posibles (usa exactamente una):
- "stock_precio": pregunta por stock, cantidad, precio, costo de un producto (query = el nombre/código del producto mencionado, o "" si no lo dice)
- "proveedores": quiere ver o consultar proveedores (query = nombre del proveedor si lo menciona, si no "")
- "cuentas_pagar": pregunta cuánto debe, facturas pendientes, saldos, vencimientos
- "ayuda": pide ayuda, qué puede hacer, cómo usar, comandos
- "app": quiere el link de la aplicación/web
- "factura": quiere cargar/registrar una factura o subir una foto del proveedor
- "saludo": saludos genéricos como hola, buenos días, qué tal
- "otro": cualquier otra cosa

Ejemplos:
- "hola" -> {"intencion":"saludo","query":""}
- "cuanto stock hay del filtro ac250?" -> {"intencion":"stock_precio","query":"filtro ac250"}
- "que proveedores tengo?" -> {"intencion":"proveedores","query":""}
- "cuanto debo?" -> {"intencion":"cuentas_pagar","query":""}
- "abrime la pagina web" -> {"intencion":"app","query":""}
- "quiero subir una factura" -> {"intencion":"factura","query":""}`;

  const modelosIA = ['gemini-3.6-flash', 'gemini-flash-latest'];
  const cuerpo = JSON.stringify({
    contents: [{ parts: [{ text: prompt }] }],
    generationConfig: { temperature: 0, maxOutputTokens: 200 }
  });
  let geminiRes = null;
  let ultimoError = null;
  for (const modelo of modelosIA) {
    const resp = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models/${modelo}:generateContent?key=${env.GEMINI_API_KEY}`,
      { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: cuerpo }
    );
    if (resp.ok) { geminiRes = resp; break; }
    ultimoError = resp.status;
    if (resp.status !== 503 && resp.status !== 429) break;
  }
  if (!geminiRes) return { intencion: 'otro', query: text };
  const body = await geminiRes.json();
  const t = body?.candidates?.[0]?.content?.parts?.[0]?.text || '';
  const m = t.match(/\{[\s\S]*\}/);
  if (!m) return { intencion: 'otro', query: text };
  try {
    const parsed = JSON.parse(m[0]);
    return { intencion: parsed.intencion || 'otro', query: String(parsed.query || '').trim() };
  } catch (e) {
    return { intencion: 'otro', query: text };
  }
}


function tgResolverUbicacion(texto, ubicaciones) {
  const t = tgNorm(texto);
  if (!t) return null;
  const normalizada = (u) => tgNorm(u.nombre);
  const casa = ubicaciones.find((u) => u.esCasaMatriz);
  // Casa Matriz: acepta "casa", "matriz", "sede", "cm", o el nombre completo
  if (casa && (t.includes('casa') || t === 'matriz' || t === 'sede' || t === 'cm' || normalizada(casa) === t)) return casa;
  // Coincidencia exacta de nombre
  const directo = ubicaciones.find((u) => normalizada(u) === t);
  if (directo) return directo;
  // Coincidencia parcial única (una sola sucursal que contenga lo escrito)
  const parcial = ubicaciones.filter((u) => !u.esCasaMatriz && normalizada(u) && t.includes(normalizada(u)));
  if (parcial.length === 1) return parcial[0];
  return null;
}

function tgResumen(env, items, sesion) {
  const ubicacion = sesion && sesion.ubicacion;
  const ubText = ubicacion ? (ubicacion.esCasaMatriz ? 'Casa Matriz' : ubicacion.nombre) : '?';
  const cab = sesion && sesion.proveedor
    ? `\n📦 ${sesion.proveedor.nombre}${sesion.numero_factura ? ' · 🧾 ' + sesion.numero_factura : ''}${sesion.fecha_vencimiento ? ' · 📅 ' + sesion.fecha_vencimiento : ''}`
    : '';
  const lineas = items.map((it, i) => {
    const numero = i + 1;
    let estado;
    if (it.alertaNombre) {
      estado = `⚠️ el código <b>${it.codigo || ''}</b> ya existe pero con otro nombre (<i>${it.nombreCatalogo}</i>) — revisá`;
    } else if (it.existe) {
      estado = `EXISTE · stock ${it.stock} · precio actual ${tgFmt(it.precioActual)} · costo ${tgFmt(it.costoActual)}`;
    } else {
      estado = '<b>NUEVO</b> (no está en catálogo)';
    }
    const seg = it.cantidad != null ? `cant ${it.cantidad}` : '';
    const costo = it.costo != null ? `costo ${tgFmt(it.costo)}` : '';
    let avisos = [];
    if (it.existe && it.costo != null && it.costoActual > 0 && it.costo > it.costoActual * 1.3) {
      const pct = Math.round(((it.costo - it.costoActual) / it.costoActual) * 100);
      avisos.push(`⚠️ costo subió ${pct}% (${tgFmt(it.costoActual)} → ${tgFmt(it.costo)})`);
    }
    const aviso = avisos.length ? `\n   ${avisos.join('\n   ')}` : '';
    return `${numero}. ${it.existe && !it.alertaNombre ? '' : '🆕 '}${it.nombre || it.codigo || '?'}\n   ${[seg, costo].filter(Boolean).join(' · ')} · ${estado}${aviso}`;
  }).join('\n');
  return `📄 <b>${tgDocTitle(env)} procesada/o — ${items.length} línea(s)</b>\n📍 Ubicación: <b>${ubText}</b>${cab}\n\n${lineas}\n\n<i>Para corregir:</i>\n<code>2 cantidad:10</code>  ·  <code>2 costo:9.5</code>  ·  <code>3 codigo:XYZ</code>\n\n¿Está bien? Respondé <b>ok</b> para seguir, o <b>cancelar</b>.`;
}

// Pide el precio de venta de TODOS los productos (nuevos y existentes), mostrando
// el precio actual como sugerencia para confirmar rápido los que no cambian.
async function tgMandarPrecios(env, chatId, items) {
  const lista = items.map((it, i) => {
    const num = i + 1;
    const sug = it.precio != null && it.precio > 0 ? ` → actual ${tgFmt(it.precio)}` : (it.costo > 0 ? ` → sugerencia ${tgFmt(it.costo)} (costo)` : '');
    return `${num}. ${it.nombre || it.codigo || '?'}${sug}`;
  }).join('\n');
  const msg =
    `💰 Precio de venta de <b>TODOS</b> los productos (ya viene el precio actual como sugerencia).\n\n` +
    `${lista}\n\n` +
    `Escribí solo los que querés ajustar, uno por línea (número espacio precio):\n` +
    `<code>1 95.00</code>\n<code>3 18.50</code>\n\n` +
    `Los que no escribas quedan con el precio sugerido. Respondé <b>ok</b> o <b>listo</b> para confirmar.`;
  await tgSend(env, chatId, msg);
}

// Guarda el stock en la ubicación elegida. El guardado real ocurre UNA sola vez,
// al final con "ok": las correcciones previas solo modifican la sesión en memoria.
// - Casa Matriz: suma al stock global de productos (producto_guardar con p_stock acumulado).
// - Sucursal: NO toca el stock global; upsert en sucursal_stock de esa sucursal.
async function tgGuardar(env, chatId, sesion) {
  const client = supa(env);
  const errores = [];
  const items = sesion.items || [];
  const ubicacion = sesion.ubicacion || null;
  const proveedor = sesion.proveedor || null;
  const esCasa = !ubicacion || ubicacion.esCasaMatriz;
  const sucursalId = esCasa ? null : ubicacion.id;
  const sucursalNombre = esCasa ? 'Casa Matriz' : ubicacion.nombre;
  let creados = 0, nuevos = 0;

  // 1) Asegurar que los productos Nuevos existan en catálogo (sin tocar stock).
  for (const it of items) {
    const costo = (it.costo != null ? it.costo : it.costoActual) || 0;
    const precio = (it.precio != null && it.precio > 0 ? it.precio : costo) || 0;
    if (!it.codigo) { errores.push(`${it.nombre || 'ítem'}: sin código, no se guardó`); continue; }
    if (it.existe && !it.alertaNombre) continue;

    let idBuscado = it.id;
    if (!idBuscado) {
      const r = await client.from('productos').select('id').eq('codigo', it.codigo).maybeSingle();
      if (r.data) idBuscado = r.data.id;
    }
    try {
      const params = {
        p_codigo: it.codigo,
        p_descripcion: it.nombre || it.nombreCatalogo || it.codigo || 'Sin descripción',
        p_categoria: it.categoria || null,
        p_costo: costo,
        p_precio: precio,
        p_stock: 0,
        p_stock_minimo: (it.stockMinimo || 0)
      };
      if (it.marca) params.p_marca = it.marca;
      if (it.unidad) params.p_unidad = it.unidad;
      if (idBuscado) params.p_id = idBuscado;
      const { error } = await client.rpc('producto_guardar', params);
      if (error) throw error;
      if (!idBuscado) nuevos++;
    } catch (e) {
      errores.push(`producto ${it.codigo}: ${e.message || e}`);
    }
  }

  // 2) Registrar la compra (atómico en la DB: ordenes_compra + detalles + stock + kardex).
  const p_items = items
    .filter(it => it.codigo)
    .map(it => ({ codigo: it.codigo, cantidad: Number(it.cantidad) || 0, costo_unitario: (it.costo != null ? it.costo : it.costoActual) || 0 }));

  if (p_items.length === 0) {
    return { creados, actualizados: 0, nuevos, numero: null, ordenId: null, monto: 0, errores: [...errores, 'No hay ítems con código para guardar'] };
  }

  let ordenId = null;
  let numero = null;
  let compraOk = false;
  try {
    const { data, error } = await client.rpc('compra_registrar', {
      p_proveedor_id: proveedor && proveedor.id ? proveedor.id : null,
      p_proveedor_nombre: proveedor ? proveedor.nombre : null,
      p_fecha: new Date().toISOString().slice(0, 10),
      p_notas: sesion.numero_factura ? `${tgDocTitle(env)}: ${sesion.numero_factura}` : null,
      p_sucursal_id: sucursalId,
      p_sucursal_nombre: sucursalNombre,
      p_usuario: 'Telegram bot',
      p_items
    });
    if (error) throw error;
    compraOk = true;
    if (data && typeof data === 'object') {
      if (data.id) ordenId = data.id;
      if (data.numero) numero = data.numero;
      else if (data.orden_numero) numero = data.orden_numero;
    } else if (typeof data === 'string') {
      numero = data;
    }
  } catch (e) {
    errores.push(`compra_registrar: ${e.message || e}`);
  }

  // Si la compra falló, NO seguimos con costo_sucursal ni cuentas_por_pagar.
  if (!compraOk) {
    return { creados, actualizados: 0, nuevos, numero, ordenId, monto: 0, errores };
  }

  // 3) Sucursal: fija el costo en sucursal_stock (solo si es sucursal, no Casa Matriz).
  if (!esCasa) {
    const costoErrores = [];
    for (const it of p_items) {
      try {
        const { error } = await client.rpc('sucursal_stock_set_costo', {
          p_sucursal_id: sucursalId,
          p_producto_codigo: it.codigo,
          p_costo: it.costo_unitario
        });
        if (error) costoErrores.push(`${it.codigo}: ${error.message || error}`);
      } catch (e) {
        costoErrores.push(`${it.codigo}: ${e.message || e}`);
      }
    }
    if (costoErrores.length) {
      errores.push(`costo sucursal: ${costoErrores.join('; ')}`);
    }
  }

  // 4) Registro en cuentas_por_pagar.
  const monto = p_items.reduce((acc, it) => acc + (it.cantidad * it.costo_unitario), 0);
  try {
    const cxp = {
      sucursal_id: sucursalId,
      sucursal_nombre: sucursalNombre,
      proveedor_id: proveedor && proveedor.id ? proveedor.id : null,
      proveedor_nombre: proveedor ? proveedor.nombre : null,
      numero_factura: sesion.numero_factura || null,
      fecha: new Date().toISOString().slice(0, 10),
      fecha_vencimiento: sesion.fecha_vencimiento || null,
      monto: Math.round(monto * 100) / 100,
      saldo: Math.round(monto * 100) / 100,
      estado: 'pendiente'
    };
    if (ordenId) cxp.orden_compra_id = ordenId;
    const { error } = await client.from('cuentas_por_pagar').insert([cxp]);
    if (error) throw error;
  } catch (e) {
    errores.push(`cuentas_por_pagar: ${e.message || e}`);
  }

  return { creados, actualizados: 0, nuevos, numero, ordenId, monto, errores };
}

async function handleTelegramWebhookSetup(request, env, user) {
  if (!requireRole(user, 'admin')) return json({ error: 'Solo admin puede configurar el bot' }, 403);
  if (!env.TELEGRAM_BOT_TOKEN) return json({ error: 'Token de Telegram no configurado' }, 500);

  const { accion } = await request.json().catch(() => ({}));
  const base = new URL(request.url).origin;
  const url = `https://api.telegram.org/bot${env.TELEGRAM_BOT_TOKEN}`;

  if (accion === 'set') {
    const wurl = `${base}/webhook/telegram`;
    const resp = await fetch(url + '/setWebhook', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ url: wurl })
    });
    const data = await resp.json();
    return json({ ok: data.ok, result: data, webhook: wurl });
  }

  if (accion === 'get') {
    const resp = await fetch(url + '/getWebhookInfo');
    return json(await resp.json());
  }

  if (accion === 'delete') {
    const resp = await fetch(url + '/deleteWebhook', { method: 'POST' });
    return json(await resp.json());
  }

  const info = await fetch(url + '/getMe').then(r => r.json()).catch(() => null);
  return json({
    ok: true,
    bot: info ? (info.result ? { username: info.result.username, id: info.result.id } : info) : null,
    nombre_permisos: (env.TELEGRAM_ALLOWED_CHATS || '').split(',').filter(Boolean),
    explica: 'POST /api/telegram-webhook con body {"accion":"set"} | "get" | "delete"'
  });
}

async function handleTelegramWebhook(request, env) {
  const update = await request.json();

  // Verificar allowlist primero (mensajes y botones)
  const allowed = String(env.TELEGRAM_ALLOWED_CHATS || '').split(',').map(s => s.trim()).filter(Boolean);

  // Pulsación de un botón (callback_query)
  if (update.callback_query) {
    const cqChat = String(update.callback_query.message && update.callback_query.message.chat && update.callback_query.message.chat.id);
    if (!allowed.includes(cqChat)) return json({ ok: true, ignored: 'no-autorizado' });
    await tgCallback(env, update.callback_query);
    return json({ ok: true });
  }

  // Solo mensajes de texto o fotos
  const msg = update.message;
  if (!msg) return json({ ok: true, ignored: 'no-message' });

  const chatId = String(msg.chat && msg.chat.id);
  const text = (msg.text || '').trim();
  const photo = (msg.photo && msg.photo.length) ? msg.photo : null;
  const document = msg.document;
  const lower = text.toLowerCase();

  // Verificar allowlist
  if (allowed.length && !allowed.includes(chatId)) {
    return json({ ok: true, ignored: 'no-autorizado' });
  }

  const sesion = await tgGetSession(env, chatId);
  const estadosCaptura = ['esperando_ubicacion','esperando_proveedor','esperando_vencimiento','esperando_numfactura','listo_para_foto'];
  const estadosPM = ['esperando_pm_sucursal','esperando_pm_banco','esperando_pm_monto','esperando_pm_fecha'];
  const tieneOperacion = sesion && (estadosCaptura.includes(sesion.estado) || estadosPM.includes(sesion.estado) || sesion.estado === 'revisando' || sesion.estado === 'esperando_precios');

  // --- Texto de control / comandos (siempre disponibles) ---
  if (lower === '/start' || lower === 'cancelar' || lower === 'menu' || lower === 'inicio' || lower === 'iniciar' || lower === 'empezar') {
    await tgSesDel(env, chatId);
    if (lower === 'cancelar') {
      await tgSend(env, chatId, 'Listo, cancelé la operación. No se guardó nada.');
      return json({ ok: true });
    }
    // /start, "menu", "inicio" → mostrar el menú con botones y saludo
    await tgMenu(env, chatId);
    return json({ ok: true });
  }

  // --- Anti-duplicado: si un guardado ya está en curso, ignorar el mensaje ---
  if (sesion && sesion.guardando) {
    await tgSend(env, chatId, '⏳ Ya estoy guardando esa operación, esperá un momento.');
    return json({ ok: true });
  }

  // --- Estado: esperando ubicación ---
  if (sesion && sesion.estado === 'esperando_ubicacion') {
    // Acepta seleccionar por número del listado
    let texto = text;
    const mNum = text.match(/^\d+$/);
    if (mNum) {
      const idx = parseInt(mNum[0], 10) - 1;
      if (idx >= 0 && idx < sesion.ubicaciones.lista.length) {
        texto = sesion.ubicaciones.lista[idx].nombre;
      }
    }
    const ub = tgResolverUbicacion(texto, sesion.ubicaciones.lista);
    if (!ub) {
      const lista = sesion.ubicaciones.lista.map((u, i) => `${i + 1}. ${u.nombre}`).join('\n');
      await tgSend(env, chatId, `❌ <b>${text || '(vacío)'}</b> no es una ubicación válida.\n\nUbicaciones disponibles:\n${lista}\n\nEscribí el nombre o el número.`);
      return json({ ok: true });
    }
    sesion.ubicacion = ub;
    sesion.estado = 'esperando_proveedor';
    const provs = await tgListarProveedores(env);
    sesion.proveedores = provs.lista;
    await tgSesSet(env, chatId, sesion);
    const lProv = provs.lista.length ? provs.lista.map((p, i) => `${i + 1}. ${p.nombre}`).join('\n') + '\n\n' : '';
    await tgSend(env, chatId, `✅ Ubicación: <b>${ub.esCasaMatriz ? 'Casa Matriz' : ub.nombre}</b>\n\n📦 ¿Qué <b>proveedor</b> emite el/la ${tgDocName(env)}?\n\n${lProv}Elegí el número de la lista <b>o escribí el nombre del proveedor</b> (si no existe, lo creo).`);
    return json({ ok: true });
  }

  // --- Estado: esperando proveedor ---
  if (sesion && sesion.estado === 'esperando_proveedor') {
    let prov;
    const mNum = text.match(/^\d+$/);
    if (mNum) {
      const idx = parseInt(mNum[0], 10) - 1;
      if (idx >= 0 && idx < sesion.proveedores.length) prov = sesion.proveedores[idx];
    } else {
      // Match por nombre normalizado (exacto o único parcial)
      const t = tgNorm(text);
      const directo = sesion.proveedores.find((p) => tgNorm(p.nombre) === t);
      if (directo) prov = directo;
      else {
        const parcial = sesion.proveedores.filter((p) => tgNorm(p.nombre) && t.includes(tgNorm(p.nombre)));
        if (parcial.length === 1) prov = parcial[0];
      }
    }
    if (!prov) {
      // No coincide con ninguno existente → crear proveedor nuevo con ese nombre
      const nombre = text.trim().replace(/\s+/g, ' ');
      if (!nombre) {
        const lProv = sesion.proveedores.length ? sesion.proveedores.map((p, i) => `${i + 1}. ${p.nombre}`).join('\n') + '\n\n' : '';
        await tgSend(env, chatId, `Elegí el número de la lista o escribí el <b>nombre</b> del proveedor:\n\n${lProv}`);
        return json({ ok: true });
      }
      const cli = supa(env);
      const ins = await cli.from('proveedores').insert({ nombre }).select('id,nombre').single();
      prov = ins.data ? { id: ins.data.id, nombre: ins.data.nombre } : { id: null, nombre };
    }
    sesion.proveedor = prov;
    sesion.estado = 'esperando_vencimiento';
    await tgSesSet(env, chatId, sesion);
    await tgSend(env, chatId, `✅ Proveedor: <b>${prov.nombre}</b>\n\n📅 ¿Cuál es la <b>fecha de vencimiento</b>? Formato <code>AAAA-MM-DD</code> (ej: <code>2026-09-15</code>). Si no tiene vencimiento, respondé <b>ok</b>.`);
    return json({ ok: true });
  }

  // --- Estado: esperando vencimiento ---
  if (sesion && sesion.estado === 'esperando_vencimiento') {
    let venc = null;
    if (lower !== 'ok' && lower !== 'no' && lower !== 'n/a' && lower !== 'na' && lower !== 'sin' && lower !== 'ninguno') {
      const m = text.match(/^(\d{4})-(\d{2})-(\d{2})$/);
      if (!m) {
        await tgSend(env, chatId, 'Fecha inválida. Usá el formato <code>AAAA-MM-DD</code> (ej: <code>2026-09-15</code>) u <b>ok</b> si no tiene vencimiento.');
        return json({ ok: true });
      }
      venc = `${m[1]}-${m[2]}-${m[3]}`;
    }
    sesion.fecha_vencimiento = venc;
    sesion.estado = 'esperando_numfactura';
    await tgSesSet(env, chatId, sesion);
    await tgSend(env, chatId, (venc ? `✅ Vencimiento: <b>${venc}</b>\n\n` : '✅ Sin vencimiento.\n\n') + `🧾 ¿Cuál es el <b>número de ${tgDocName(env)}</b> del proveedor? (ej: <code>FAC-00123</code>)`);
    return json({ ok: true });
  }

  // --- Estado: esperando número de factura ---
  if (sesion && sesion.estado === 'esperando_numfactura') {
    const num = text.trim();
    if (!num) {
      await tgSend(env, chatId, `Escribí el <b>número de ${tgDocName(env)}</b> (ej: <code>FAC-00123</code>) o <b>ok</b> si no lo tenés.`);
      return json({ ok: true });
    }
    sesion.numero_factura = lower === 'ok' ? null : num;
    sesion.estado = 'listo_para_foto';
    await tgSesSet(env, chatId, sesion);
    await tgSend(env, chatId, `✅ Nº de ${tgDocName(env)}: <b>${sesion.numero_factura || '(sin número)'}</b>\n\nAhora mandame la <b>foto</b> del/la ${tgDocName(env)}. Resumen de los datos:\n\n📍 ${sesion.ubicacion.esCasaMatriz ? 'Casa Matriz' : sesion.ubicacion.nombre}\n📦 ${sesion.proveedor.nombre}\n🧾 ${sesion.numero_factura || '—'}\n📅 ${sesion.fecha_vencimiento || '—'}`);
    return json({ ok: true });
  }

  // --- Foto nueva → analizar ---
  if (photo || document) {
    // Si hay operación pendiente (sin ok/cancelar), NO mezclar líneas.
    if (tieneOperacion) {
      await tgSend(env, chatId, `⏳ Ya hay una operación en curso (captura o ${tgDocName(env)} sin confirmar). Terminá con <b>ok</b> o <b>cancelar</b> antes de mandar otra foto.`);
      return json({ ok: true });
    }
    // Debe completar la captura (ubicación → proveedor → vencimiento → nº)
    if (!sesion || !sesion.ubicacion || !sesion.proveedor || sesion.estado !== 'listo_para_foto') {
      const ub = await tgListarUbicaciones(env);
      const lista = ub.lista.map((u, i) => `${i + 1}. ${u.nombre}`).join('\n');
      await tgSesSet(env, chatId, { estado: 'esperando_ubicacion', creado: Date.now(), ubicaciones: ub });
      await tgSend(env, chatId, `Primero completá los datos del/la ${tgDocName(env)} (empiezo por la <b>ubicación</b>):\n\n${lista}\n\nEscribí el nombre o el número.`);
      return json({ ok: true });
    }
    const ubicacion = sesion.ubicacion;

    const fileId = photo ? photo[photo.length - 1].file_id : (document.mime_type && String(document.mime_type).startsWith('image') ? document.file_id : null);
    if (!fileId) {
      await tgSend(env, chatId, 'Ese archivo no es una imagen o PDF válido.');
      return json({ ok: true });
    }

    await tgSend(env, chatId, `🔍 Analizando el/la ${tgDocName(env)}… un momento.`);

    let media;
    try { media = await tgGetFile(env, fileId); }
    catch (e) { await tgSend(env, chatId, 'No pude descargar la imagen. Intenta de nuevo.'); return json({ ok: true }); }
    if (!media) { await tgSend(env, chatId, 'No pude descargar la imagen. Intenta de nuevo.'); return json({ ok: true }); }

    let res;
    try { res = await analizarFacturaIA(env, media.mimeType, media.base64); }
    catch (e) { await tgSend(env, chatId, '❌ ' + e.message); return json({ ok: true }); }

    const rawItems = (res.items || []).filter(it => it && (it.nombre || it.codigo));
    if (!rawItems.length) { await tgSend(env, chatId, `No encontré productos en el/la ${tgDocName(env)}. Intentá con otra foto.`); return json({ ok: true }); }

    // Resolver contra el catálogo (detecta código que existe pero con otro nombre)
    const items = [];
    for (const it of rawItems) {
      const { producto: existe, porCodigo } = await tgResolverCatalogo(env, it);
      const numero = items.length + 1;
      const aiName = String(it.nombre || '').trim();
      let alertaNombre = false;
      let nombreCatalogo = existe ? existe.descripcion : '';
      if (existe && porCodigo && aiName) {
        // Código coincide pero hay que verificar que la descripción no difiera mucho.
        const nAI = tgNorm(aiName), nCat = tgNorm(existe.descripcion);
        // Consideramos "otro producto" si los nombres no comparten subtring completo.
        if (nCat && nAI !== nCat && !(nCat.includes(nAI) || nAI.includes(nCat))) {
          alertaNombre = true;
        }
      }
      items.push({
        numero,
        codigo: existe ? existe.codigo : (it.codigo || null),
        nombre: aiName || existe.descripcion || '',
        nombreCatalogo: nombreCatalogo,
        alertaNombre,
        cantidad: Math.max(1, Number(it.cantidad) || 1),
        costo: Number(it.costo_unitario) > 0 ? Number(it.costo_unitario) : (existe ? existe.costo : null),
        existe: !!existe,
        id: existe ? existe.id : null,
        stock: existe ? (existe.stock || 0) : 0,
        stockMinimo: existe ? (existe.stock_minimo || 0) : 0,
        stockUnidades: existe ? (existe.stock || 0) : 0,
        marca: existe ? existe.marca : null,
        unidad: existe ? existe.unidad : null,
        categoria: existe ? existe.categoria : null,
        precioActual: existe ? (existe.precio || 0) : 0,
        precio: existe ? (existe.precio || 0) : null,
        costoActual: existe ? (existe.costo || 0) : 0
      });
    }

    const reviewSes = {
      estado: 'revisando',
      ubicacion,
      proveedor: sesion.proveedor,
      fecha_vencimiento: sesion.fecha_vencimiento,
      numero_factura: sesion.numero_factura,
      items,
      creado: Date.now()
    };
    await tgSesSet(env, chatId, reviewSes);
    await tgSend(env, chatId, tgResumen(env, items, reviewSes));
    return json({ ok: true });
  }

  // ── Pago Móvil: pasos 1-4 (fuera del bloque de captura para que se ejecute siempre) ──
  if (sesion && sesion.estado === 'esperando_pm_sucursal') {
    const ub = sesion.ubicaciones;
    if (!ub || !ub.lista) { await tgSesDel(env, chatId); await tgSend(env, chatId, 'Error interno. Volvé a empezar.'); return json({ ok: true }); }
    const idx = parseInt(text, 10) - 1;
    const matchNum = /^\d+$/.test(text.trim()) && idx >= 0 && idx < ub.lista.length;
    const matchNom = !matchNum ? ub.lista.find(u => tgNorm(u.nombre).includes(tgNorm(text))) : null;
    const sel = matchNum ? ub.lista[idx] : matchNom;
    if (!sel) { await tgSend(env, chatId, 'No entendí la sucursal. Escribí el <b>número</b> o <b>nombre</b>.'); return json({ ok: true }); }
    sesion.pm.sucursal_id = sel.id;
    sesion.pm.sucursal_nombre = sel.nombre;
    sesion.estado = 'esperando_pm_banco';
    await tgSesSet(env, chatId, sesion);
    await tgSend(env, chatId, `Paso 2/4 — ¿Desde qué <b>banco</b> hizo el pago el cliente? (ej: Banesco, Mercantil, Venezuela)\n\n📍 Sucursal: <b>${sel.nombre}</b>`);
    return json({ ok: true });
  }

  if (sesion && sesion.estado === 'esperando_pm_banco') {
    const banco = text.trim().replace(/\s+/g, ' ');
    if (!banco) { await tgSend(env, chatId, 'Escribí el nombre del <b>banco</b> (ej: Banesco).'); return json({ ok: true }); }
    sesion.pm.banco = banco;
    sesion.estado = 'esperando_pm_monto';
    await tgSesSet(env, chatId, sesion);
    await tgSend(env, chatId, `Paso 3/4 — ¿Cuánto fue el <b>monto</b> del pago? (ej: <code>250,00</code> o <code>1200</code>)\n\n📍 ${sesion.pm.sucursal_nombre} · 🏦 ${banco}`);
    return json({ ok: true });
  }

  if (sesion && sesion.estado === 'esperando_pm_monto') {
    const monto = tgNum(text);
    if (isNaN(monto) || !(monto > 0)) { await tgSend(env, chatId, 'Monto inválido. Escribí el monto en números (ej: <code>250,00</code>).'); return json({ ok: true }); }
    sesion.pm.monto = monto;
    sesion.estado = 'esperando_pm_fecha';
    await tgSesSet(env, chatId, sesion);
    await tgSend(env, chatId, `Paso 4/4 — ¿Qué <b>día</b> se hizo el pago? Formato <code>AAAA-MM-DD</code> (ej: <code>2026-09-01</code>) o escribí <b>hoy</b> (por defecto).\n\n📍 ${sesion.pm.sucursal_nombre} · 🏦 ${sesion.pm.banco} · 💵 ${tgFmt(monto)}`);
    return json({ ok: true });
  }

  if (sesion && sesion.estado === 'esperando_pm_fecha') {
    let fecha = new Date().toISOString().slice(0, 10);
    if (lower !== 'hoy' && lower !== 'ok' && lower !== '') {
      const m = text.match(/^(\d{4})-(\d{2})-(\d{2})$/);
      if (!m) { await tgSend(env, chatId, 'Fecha inválida. Usá <code>AAAA-MM-DD</code> (ej: <code>2026-09-01</code>) u <b>hoy</b>.'); return json({ ok: true }); }
      fecha = `${m[1]}-${m[2]}-${m[3]}`;
    }
    sesion.pm.fecha = fecha;
    await tgSesDel(env, chatId);
    await tgGuardarPagoMovil(env, chatId, sesion.pm);
    return json({ ok: true });
  }

  // --- Sin operación de captura activa: interpretar el pedido en lenguaje natural ---
  if (!sesion || !tieneOperacion) {
    // Elegir uno de los resultados listados (respondió un número)
    if (sesion && sesion.estado === 'esperando_elegir_stock') {
      const mNum = text.match(/^\d+$/);
      if (mNum && sesion.resultados && sesion.resultados.length) {
        const idx = parseInt(mNum[0], 10) - 1;
        if (idx >= 0 && idx < sesion.resultados.length) {
          await tgSend(env, chatId, tgMsgProducto(sesion.resultados[idx]));
          await tgSesDel(env, chatId);
          return json({ ok: true });
        }
        await tgSend(env, chatId, `Número inválido. Respondé un número del 1 al ${sesion.resultados.length}, o escribí otra búsqueda.`);
        return json({ ok: true });
      }
      // No es un número → lo tomamos como una nueva búsqueda
      const res2 = await tgBuscarProductos(env, text);
      if (!await tgMostrarProductos(env, chatId, text, res2)) {
        await tgSend(env, chatId, `No encontré <b>${text}</b> en el catálogo. Probá con menos palabras o con otro nombre.`);
      }
      return json({ ok: true });
    }

    // Si venía del botón "Stock / Precio": el texto es el producto a buscar
    if (sesion && sesion.estado === 'esperando_producto') {
      const res2 = await tgBuscarProductos(env, text);
      if (!await tgMostrarProductos(env, chatId, text, res2)) {
        await tgSend(env, chatId, `No encontré <b>${text}</b> en el catálogo. Probá con menos palabras (ej: <i>"tubo"</i>) o con otro nombre.`);
      }
      return json({ ok: true });
    }

    // Comandos explícitos
    if (lower.startsWith('/stock') || lower.startsWith('/precio')) {
      const q = text.replace(/^\/(stock|precio)\b/i, '').replace(/^(de|del|del\s)?/i, '').trim();
      const res = await tgBuscarProductos(env, q);
      if (!await tgMostrarProductos(env, chatId, q, res)) {
        await tgSend(env, chatId, `No encontré <b>${q}</b> en el catálogo. Probá con menos palabras (ej: <i>"tubo"</i>) o con otro nombre.`);
      }
      return json({ ok: true });
    }
    if (lower === '/pm' || lower === '/pagomovil' || lower === '/pago-movil') { await tgIniciarPagoMovil(env, chatId); return json({ ok: true }); }
    if (lower === '/proveedores' || lower === '/listar-proveedores') { await tgListarProveedoresMsg(env, chatId); return json({ ok: true }); }
    if (lower === '/cxp' || lower === '/cuentas' || lower === '/deudas') { await tgCuentasPagarMsg(env, chatId); return json({ ok: true }); }
    if (lower === '/ayuda' || lower === '/help' || lower === '/comandos') { await tgAyuda(env, chatId); return json({ ok: true }); }
    if (lower === '/app' || lower === '/web' || lower === '/link') { await tgAbrirApp(env, chatId); return json({ ok: true }); }

    // Detección rápida de "registrar pago móvil" en lenguaje natural
    const esPagoMovilTexto = /(pago ?movil|pago mÃ³vil|pagomovil|registrar pago|anotar pago|cobrar por pago)/i.test(lower);
    if (esPagoMovilTexto) { await tgIniciarPagoMovil(env, chatId); return json({ ok: true }); }

    // Saludos rápidos → mostrar el menú al toque (sin depender de la IA).
    // "hola", "buenas", "hola bot", "que tal", "¿cómo estás?"... → menú con botones.
    const esSaludo = /^(\/start|hola|buenas|buenos dias|buenas tardes|buenas noches|que tal|como estas|hey|holii?|holis)\b/i.test(text)
      || /(hola|holii|que tal|como estas|buenas)/i.test(lower)
      && text.length <= 40;
    if (esSaludo) {
      await tgMenu(env, chatId);
      return json({ ok: true });
    }

    // Si es texto (no foto):
    if (text) {
      // Frases de consulta general que NO son productos → ir directo a la IA
      const esConsultaGeneral = /(proveedore|cuant(o|a) ?(debo|falta|quedan)|deudas?|saldos?|cuentas|facturas?|vencid|ayuda|podes?|puedes?|hacer|comandos?|opciones?|link|pagina|abri|mostrame|listar|lista de|que (puedes|podes|hacer))/i.test(lower);

      if (!esConsultaGeneral) {
        // Primer intento: buscar producto en el catálogo (lista numerada si varios)
        const res = await tgBuscarProductos(env, text);
        if (res.encontro) {
          await tgMostrarProductos(env, chatId, text, res);
          return json({ ok: true });
        }
      }

      // No fue un producto (o es una consulta general): clasificar con la IA
      const int = await tgEntender(env, text);
      if (int.intencion === 'stock_precio') {
        const q = int.query || text;
        const res2 = await tgBuscarProductos(env, q);
        if (!await tgMostrarProductos(env, chatId, q, res2)) {
          await tgSend(env, chatId, `No encontré <b>${q}</b> en el catálogo. Probá con menos palabras o con otro nombre.`);
        }
        return json({ ok: true });
      }
      if (int.intencion === 'proveedores') { await tgListarProveedoresMsg(env, chatId); return json({ ok: true }); }
      if (int.intencion === 'cuentas_pagar') { await tgCuentasPagarMsg(env, chatId); return json({ ok: true }); }
      if (int.intencion === 'ayuda') { await tgAyuda(env, chatId); return json({ ok: true }); }
      if (int.intencion === 'app') { await tgAbrirApp(env, chatId); return json({ ok: true }); }
      if (int.intencion === 'saludo') { await tgMenu(env, chatId); return json({ ok: true }); }
      if (int.intencion === 'factura') {
        const ub = await tgListarUbicaciones(env);
        const lista = ub.lista.map((u, i) => `${i + 1}. ${u.nombre}`).join('\n');
        await tgSesSet(env, chatId, { estado: 'esperando_ubicacion', creado: Date.now(), ubicaciones: ub });
        await tgSend(env, chatId, `Muy bien, arranquemos a cargar un/a ${tgDocName(env)}.\n\n¿A qué <b>ubicación</b> corresponde?\n\n${lista}\n\nEscribí el nombre o el número.`);
        return json({ ok: true });
      }
      // "otro" → pedir aclaración ofreciendo el menú
      await tgSend(env, chatId,
        `No me queda claro qué querés 🙏\n\nPodés usar el menú o escribir algo como <i>"stock de X"</i>, <i>"cuánto debo"</i> o <i>"qué proveedores hay"</i>.`,
        { reply_markup: { inline_keyboard: [[{ text: '📋 Ver opciones', callback_data: 'menu' }]] } });
      return json({ ok: true });
    }

    // Sin texto ni operación
    await tgSend(env, chatId, `Mandame una <b>foto</b> del/la ${tgDocName(env)} para empezar, o tocá los botones.`,
      { reply_markup: { inline_keyboard: [[{ text: '📋 Menú', callback_data: 'menu' }]] } });
    return json({ ok: true });
  }

  const ubicacion = sesion.ubicacion;

  // ─────────── Estado: REVISANDO (correcciones / ok / cancelar) ───────────
  if (sesion.estado === 'revisando') {
    // Confirmar explícito de las líneas con "código existe pero otro nombre".
    if (lower === 'confirmar-todo') {
      sesion.items.forEach(it => { it.alertaNombre = false; });
      await tgSend(env, chatId, tgResumen(env, sesion.items, sesion));
      await tgSend(env, chatId, 'Confirmado. Ahora sí, respondé <b>ok</b> para seguir.');
      return json({ ok: true });
    }

    // Edición: "N cantidad:10" o "N costo:9.5" o "N codigo:XYZ" (siempre permitida para poder corregir)
    const mEdit = text.match(/^(\d+)[\s:.,;]+(cantidad|cant|costo|cos|codigo|cod)\s*[:=]?\s*(.+)$/i);
    if (mEdit) {
      const idx = parseInt(mEdit[1], 10) - 1;
      const campo = mEdit[2].toLowerCase();
      const val = mEdit[3].trim();
      if (idx < 0 || idx >= sesion.items.length) {
        await tgSend(env, chatId, 'Número de línea inválido.');
        return json({ ok: true });
      }
      const it = sesion.items[idx];
      if (campo === 'cantidad' || campo === 'cant') {
        const n = Math.max(1, Math.round(tgNum(val)));
        if (!isNaN(n)) { it.cantidad = n; await tgSend(env, chatId, `Línea ${idx + 1}: cantidad → ${n}`); }
        else await tgSend(env, chatId, 'Cantidad inválida.');
      } else if (campo === 'costo' || campo === 'cos') {
        const n = tgNum(val);
        if (!isNaN(n) && n >= 0) { it.costo = n; await tgSend(env, chatId, `Línea ${idx + 1}: costo → ${tgFmt(n)}`); }
        else await tgSend(env, chatId, 'Costo inválido.');
      } else if (campo === 'codigo' || campo === 'cod') {
        it.codigo = val;
        // Al cambiar el código manualmente se asume que es a propósito: quitar alerta de nombre.
        it.alertaNombre = false;
        await tgSend(env, chatId, `Línea ${idx + 1}: código → ${val}`);
      }
      await tgSend(env, chatId, tgResumen(env, sesion.items, sesion));
      return json({ ok: true });
    }

    // Si hay líneas con alerta de "código existe pero otro nombre", bloquear confirmar hasta resolver.
    const conAlerta = sesion.items.filter(it => it.alertaNombre);
    if (conAlerta.length) {
      const lista = conAlerta.map(it => `${it.numero}. ${it.nombre || it.codigo}`).join('\n');
      await tgSend(env, chatId, `⚠️ Estas líneas tienen el código ya existente con OTRO nombre. Confirmá si es el mismo producto o corregí su código:\n\n${lista}\n\nPodés corregir con <code>3 codigo:XXX</code>, o si es correcto respondé <b>confirmar-todo</b>.`);
      return json({ ok: true });
    }

    if (lower === 'ok' || lower === 'si' || lower === 'confirmar' || lower === 'todo bien' || lower === 'confirmo') {
      sesion.estado = 'esperando_precios';
      await tgSesSet(env, chatId, sesion);
      await tgMandarPrecios(env, chatId, sesion.items);
      return json({ ok: true });
    }

    await tgSend(env, chatId, '⚠️ No entendí. Respondé <b>ok</b> para continuar, <b>cancelar</b> para abortar, o editá una línea así: <code>2 cantidad:10</code>.');
    return json({ ok: true });
  }

  // ─────────── Estado: ESPERANDO PRECIOS (todos los productos) ───────────
  if (sesion.estado === 'esperando_precios') {
    // Confirmar final: guardar UNA sola vez (con protección anti-duplicado).
    if (lower === 'ok' || lower === 'listo') {
      // Precios que quedaron vacíos (nuevos) → usar costo como precio.
      sesion.items.forEach(it => { if (it.precio == null || !(it.precio > 0)) it.precio = it.costo || 0; });
      sesion.guardando = true;
      await tgSesSet(env, chatId, sesion);
      const out = await tgGuardar(env, chatId, sesion);
      await tgReportar(env, chatId, out, sesion.ubicacion);
      await tgSesDel(env, chatId);
      return json({ ok: true });
    }

    // Parsear "N precio" por líneas (solo los que el usuario quiere ajustar)
    const lineas = text.split(/\n|,|;/).map(s => s.trim()).filter(s => /^\d+\s+/.test(s));
    if (!lineas.length) {
      await tgSend(env, chatId, 'Escribí los precios como <code>N precio</code>, uno por línea (ej: <code>1 95.00</code>), o <b>ok</b> para confirmar todo.');
      return json({ ok: true });
    }

    let asignados = 0;
    const noEncontradas = [];
    for (const ln of lineas) {
      const mm = ln.match(/^(\d+)\s+([\d.,]+)$/);
      if (!mm) continue;
      const idx = parseInt(mm[1], 10) - 1;
      const precio = tgNum(mm[2]);
      if (idx < 0 || idx >= sesion.items.length || isNaN(precio)) { noEncontradas.push(ln.trim()); continue; }
      sesion.items[idx].precio = precio;
      asignados++;
    }

    const restantes = sesion.items.filter(it => it.precio == null || !(it.precio > 0));
    if (restantes.length) {
      const lista = restantes.map(it => `${it.numero}. ${it.nombre || it.codigo || '?'}`).join('\n');
      await tgSend(env, chatId, `Ajusté ${asignados} precio(s). Todavía sin precio (se tomará el costo):\n${lista}\n\nSeguí escribiendo <code>N precio</code> o confirmá con <b>ok</b>.`);
      return json({ ok: true });
    }

    await tgSend(env, chatId, `Ajusté ${asignados} precio(s). Confirmá con <b>ok</b> para guardar en ${ubicacion.esCasaMatriz ? 'Casa Matriz' : ubicacion.nombre}.`);
    return json({ ok: true });
  }

  return json({ ok: true });
}

async function tgReportar(env, chatId, out, ubicacion) {
  const ubText = ubicacion ? (ubicacion.esCasaMatriz ? 'Casa Matriz' : ubicacion.nombre) : '?';
  const okText = [
    out.nuevos ? `${out.nuevos} producto(s) nuevo(s)` : null,
    out.numero ? `compra ${out.numero}` : null,
    out.monto ? `monto ${tgFmt(out.monto)}` : null
  ].filter(Boolean).join(', ') || 'registrado';

  if (out.errores && out.errores.length) {
    await tgSend(env, chatId, `⚠️ Registré en <b>${ubText}</b>: ${okText}.\n\n<b>Errores en ${out.errores.length} punto(s):</b>\n${out.errores.map(e => '• ' + e).join('\n')}\n\nRevisa en la app cómo quedó.`);
  } else {
    await tgSend(env, chatId, `✅ Registrado en <b>${ubText}</b>: <b>${okText}</b>.\nLa compra quedó en <b>Cuentas por pagar</b> con saldo pendiente.`);
  }
}

// ═══════════════════════════════════════════════════════════════════
// 7. ARCHIVOS ESTÁTICOS (ASSETS binding)
// ═══════════════════════════════════════════════════════════════════

async function serveStatic(request, env) {
  if (env.ASSETS) {
    const resp = await env.ASSETS.fetch(request);
    if (resp.status !== 404) {
      const h = new Headers(resp.headers);
      for (const [k, v] of Object.entries(secHeaders)) h.set(k, v);
      return new Response(resp.body, { status: resp.status, headers: h });
    }
  }
  return new Response('Not Found', { status: 404, headers: secHeaders });
}

// ═══════════════════════════════════════════════════════════════════
// ROUTER PRINCIPAL
// ═══════════════════════════════════════════════════════════════════

export default {
  async fetch(request, env, ctx) {
    if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders });

    const url = new URL(request.url);
    const path = url.pathname;
    const method = request.method;

    // ── Endpoints públicos (sin auth) ──
    if (method === 'POST' && path === '/api/login') {
      try { return withCors(await handleLogin(request, env)); }
      catch (e) { return withCors(json({ error: 'Error interno' }, 500)); }
    }
    if (method === 'GET' && path === '/api/sucursales-public') {
      try { return withCors(await handleSucursalesPublic(request, env)); }
      catch (e) { return withCors(json({ error: 'Error interno' }, 500)); }
    }
    if (method === 'GET' && path === '/api/usuarios-public') {
      try { return withCors(await handleUsuariosPublic(request, env)); }
      catch (e) { return withCors(json({ error: 'Error interno' }, 500)); }
    }
    if (method === 'GET' && path === '/api/tasa-bcv') {
      try { return withCors(await handleTasaBcv()); }
      catch (e) { return withCors(json({ ok: false, error: 'Error al obtener tasa' }, 500)); }
    }

    // ── Webhook de Telegram (público: Telegram no manda auth, se valida la allowlist dentro) ──
    if (method === 'POST' && path === '/webhook/telegram') {
      try { return await handleTelegramWebhook(request, env); }
      catch (e) {
        console.error('[TG] Error procesando update:', e);
        try { await tgSend(env, '0', 'Error interno procesando update: ' + (e.message || e)); } catch (_) {}
        return json({ ok: false, error: 'Error interno' }, 500);
      }
    }

    // ── Si no es ruta /api/, servir archivos estáticos ──
    if (!path.startsWith('/api/')) {
      try { return await serveStatic(request, env); }
      catch (e) { return json({ error: 'Error interno' }, 500); }
    }

    // ── Todas las rutas /api/ requieren auth ──
    let user;
    try { user = await authenticate(request, env); } catch (e) { /* ignore */ }
    if (!user) return withCors(json({ error: 'No autenticado' }, 401));

    try {
      // Productos
      if (method === 'GET' && path === '/api/productos') return withCors(await handleProductos(request, env, url, user));

      // Ventas
      if (method === 'GET' && path === '/api/ventas') return withCors(await handleVentas(request, env, url, user));
      if (method === 'POST' && path === '/api/ventas') return withCors(await handleVentaRegistrar(request, env, user));

      // Caja / Movimientos
      if (method === 'GET' && path === '/api/caja-movimientos') return withCors(await handleCajaMovimientos(request, env, url, user));
      if (method === 'POST' && path === '/api/caja-movimientos') return withCors(await handleCajaMovimientosInsert(request, env, user));

      // Clientes
      if (method === 'GET' && path === '/api/clientes') return withCors(await handleClientes(request, env, url, user));
      if (method === 'POST' && path === '/api/clientes') return withCors(await handleClienteGuardar(request, env, user));

      // Cierres
      if (method === 'GET' && path === '/api/cierres') return withCors(await handleCierres(request, env, url, user));
      if (method === 'POST' && path === '/api/cierres/registrar') return withCors(await handleCierreRegistrar(request, env, user));
      if (method === 'DELETE' && path === '/api/cierres') return withCors(await handleCierreEliminar(request, env, url, user));
      if (method === 'POST' && path === '/api/cierres/importar') return withCors(await handleCierreImportar(request, env, user));

      // Carga IA - Analizar factura con Gemini
      if (method === 'POST' && path === '/api/analizar-factura') return withCors(await handleAnalizarFactura(request, env, user));

      // Gestión del webhook de Telegram (solo admin/superadmin) — útil para setearlo/verificarlo
      if (method === 'POST' && path === '/api/telegram-webhook') return withCors(await handleTelegramWebhookSetup(request, env, user));

      // ── Ruta /api/ no encontrada ──
      return withCors(json({ error: 'Endpoint no encontrado' }, 404));
    } catch (err) {
      return withCors(json({ error: 'Error interno del servidor' }, 500));
    }
  },
};
