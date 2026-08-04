-- ============================================================
-- RLS DE SEGURIDAD EN VENTAS — REFRIMAR OS
-- ------------------------------------------------------------
-- Cierra el acceso de escritura directo (anon key) a las tablas
-- de ventas. TODA escritura a ventas/detalle_venta pasa por las
-- funciones registrar_venta y anular_venta (SECURITY DEFINER),
-- que ejecutan con permisos del dueño de la BD y NO son afectadas
-- por RLS.
--
-- Con esta migración:
--   - La anon key (el navegador) solo puede LEER (SELECT).
--   - INSERT/UPDATE/DELETE directos quedan DENEGADOS a anon:
--     si un tercero extrae la anon key del código fuente no podrá
--     forjar ventas ni alterar detalles.
--   - El flujo normal de facturación NO cambia: sigue usando las
--     RPCs transaccionales.
--
-- Cómo aplicar:
-- 1. Supabase → SQL Editor → New query
-- 2. Pega TODO este archivo y presiona "Run"
-- 3. Es seguro volver a correrlo (usa DROP POLICY IF EXISTS).
-- ============================================================

alter table ventas enable row level security;
alter table detalle_venta enable row level security;

-- SELECT: la app lee ventas/detalle desde el navegador (reportes,
-- devoluciones, facturacion, clientes). Se permite la lectura a
-- cualquiera con la anon key (igual que ya se hace con el resto de
-- las tablas). NO se crean policies de INSERT/UPDATE/DELETE, así
-- que la escritura directa queda bloqueada.

drop policy if exists "ventas_select" on ventas;
create policy "ventas_select" on ventas
  for select using (true);

drop policy if exists "detalle_venta_select" on detalle_venta;
create policy "detalle_venta_select" on detalle_venta
  for select using (true);

-- Revoca explícitamente los privilegios de escritura del rol anon
-- (defensa en profundidad: aunque una policy se olvide en el futuro,
-- la anon key no podrá escribir).

revoke insert, update, delete on ventas from anon;
revoke insert, update, delete on detalle_venta from anon;

-- El rol authenticated tampoco debe escribir directo (todo va por RPC).
revoke insert, update, delete on ventas from authenticated;
revoke insert, update, delete on detalle_venta from authenticated;

-- Las funciones SECURITY DEFINER siguen pudiendo insertar/borrar
-- porque su rol ejecutor es el dueño de las tablas (postgres),
-- que conserva todos los privilegios.

grant select on ventas to anon, authenticated;
grant select on detalle_venta to anon, authenticated;
