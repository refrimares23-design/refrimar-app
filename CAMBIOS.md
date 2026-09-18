# CAMBIOS — PARTE 1: Seguridad (Cloudflare Worker)

## Archivos nuevos

| Archivo | Descripción |
|---------|-------------|
| `_worker.js` | Cloudflare Worker. Endpoints específicos, JWT HMAC-SHA256 (24h), rate limiting KV (5 intentos → 15min lockout), validación de rol + sucursal. |
| `wrangler.jsonc` | Configuración Cloudflare: binding KV RATE_LIMIT, binding ASSETS, variables de entorno (placeholder), security headers. |
| `CAMBIOS.md` | Este archivo. |
| `backup-original/` | Copias de TODOS los archivos originales de producción (28 entries). |

## Archivos modificados

### `login.html`
- **Eliminado**: `<script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"></script>`
- **JWT guardado en**: `localStorage.setItem('token', result.token)` (antes era sessionStorage)
- **Manejo específico**: 429 → "Demasiados intentos. Espera 15 minutos." / 403 → "PIN o sucursal incorrectos."
- **Sin** llamadas a supabaseClient — todo va por fetch al Worker

### `caja.html`
- **Eliminado**: `<script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"></script>`
- **Eliminado**: `<script src="supabase-config.js"></script>`
- **4 llamadas reemplazadas**:
  1. `supabaseClient.from('cierre_diario').select('*')` → `apiFetch('/api/cierres')`
  2. `supabaseClient.rpc('cierre_diario_eliminar', ...)` → `apiFetch('/api/cierres?id=...', {method:'DELETE'})`
  3. `supabaseClient.rpc('cierre_diario_guardar', ...)` → `apiFetch('/api/cierres/registrar', {method:'POST', body:...})`
  4. `supabaseClient.rpc('cierre_diario_importar', ...)` → `apiFetch('/api/cierres/importar', {method:'POST', body:...})`
- **Helper** `apiFetch()` con JWT automático desde `localStorage.getItem('token')` y redirect a login en 401

## Endpoints del Worker

### Públicos (sin auth)
| Método | Ruta | Descripción |
|--------|------|-------------|
| POST | `/api/login` | Login: recibe `{nombre, pin_hash, sucursal_id}`. Llama a RPC `login_usuario`. Rate limit KV. |
| GET | `/api/sucursales-public` | Lista sucursales para pantalla de login |
| GET | `/api/usuarios-public` | Lista usuarios activos para pantalla de login |

### Autenticados (requieren JWT)
| Método | Ruta | Roles | Qué hace |
|--------|------|-------|----------|
| GET | `/api/productos` | todos | Lista productos filtrados por sucursal del token |
| GET | `/api/ventas` | admin, cajero | Lista ventas de la sucursal del token |
| POST | `/api/ventas` | admin, cajero | Registra venta via RPC `registrar_venta`. Sucursal validada desde token. |
| GET | `/api/caja-movimientos` | admin, cajero | Lista movimientos de caja de la sucursal del token |
| POST | `/api/caja-movimientos` | admin, cajero | Inserta movimiento de caja. Sucursal desde token. |
| GET | `/api/clientes` | todos | Lista clientes de la sucursal |
| POST | `/api/clientes` | admin, cajero | Inserta cliente via RPC `cliente_guardar` |
| GET | `/api/cierres` | admin, cajero | Lista cierres diarios de la sucursal |
| POST | `/api/cierres/registrar` | admin, cajero | Guarda cierre via RPC `cierre_diario_guardar`. Sucursal validada. |
| DELETE | `/api/cierres?id=X` | admin | Elimina cierre via RPC `cierre_diario_eliminar` |
| POST | `/api/cierres/importar` | admin | Importa cierres via RPC `cierre_diario_importar`. Sucursal validada. |

## Matriz de permisos

| Rol | Productos | Clientes | Ventas | Caja | Cierres |
|-----|-----------|----------|--------|------|---------|
| **desarrollador** | CRUD (todas) | CRUD (todas) | CRUD (todas) | CRUD (todas) | CRUD (todas) |
| **admin** | CRUD (su sucursal) | CRUD (su sucursal) | CRUD (su sucursal) | CRUD (su sucursal) | CRUD (su sucursal) |
| **cajero** | R (su sucursal) | R + INSERT | R + INSERT | R + INSERT | R + INSERT/registrar |

## Cómo probar localmente

```bash
# 1. Instalar wrangler si no lo tenés
npm install -g wrangler

# 2. Crear namespace KV
wrangler kv namespace create RATE_LIMIT

# 3. Copiar el ID en wrangler.jsonc

# 4. Configurar secrets (reemplazar valores placeholder)
wrangler secret put SUPABASE_SERVICE_KEY
wrangler secret put JWT_SECRET

# 5. Levantar localmente
wrangler dev

# 6. Abrir http://localhost:8787/login.html
```

## Qué falta hacer (próximas partes)

- Migrar las otras 13 páginas (facturacion, inventario, reportes, configuracion, usuarios, sucursales, cotizaciones, devoluciones, clientes, gastos, dashboard, compras, kardex)
- Deploy a Cloudflare (cuando el usuario lo apruebe)
- Configurar secrets reales (SUPABASE_SERVICE_KEY, JWT_SECRET)
- Crear namespace KV real y poner el ID en wrangler.jsonc

## Cero cambios en Supabase

No se tocaron tablas, columnas, RLS, funciones RPC, ni datos. Todo el control de acceso vive en el Worker.
