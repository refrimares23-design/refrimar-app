-- ============================================================
-- ADENDO: etiquetar cada venta con la sucursal donde se facturó
-- REFRIMAR OS — correr DESPUÉS de supabase-migration-sucursales.sql
-- ------------------------------------------------------------
-- No lleva foreign key a `sucursales` porque también debe poder
-- guardar el UUID fijo de "Casa Matriz" (00000000-0000-0000-0000-000000000001),
-- que no es una fila real de esa tabla.
-- ============================================================

alter table ventas add column if not exists sucursal_id uuid;
alter table ventas add column if not exists sucursal_nombre text;

create index if not exists idx_ventas_sucursal on ventas(sucursal_id);
