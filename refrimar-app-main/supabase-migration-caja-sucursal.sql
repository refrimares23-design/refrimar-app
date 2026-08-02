-- ============================================================
-- ADENDO: etiquetar cada movimiento de caja y pago móvil con
-- la sucursal donde se registró
-- REFRIMAR OS — correr DESPUÉS de supabase-migration-sucursales.sql
-- ------------------------------------------------------------
-- No llevan foreign key a `sucursales` porque también deben poder
-- guardar el UUID fijo de "Casa Matriz" (00000000-0000-0000-0000-000000000001),
-- que no es una fila real de esa tabla.
-- ============================================================

alter table caja_movimientos add column if not exists sucursal_id uuid;

create index if not exists idx_caja_movimientos_sucursal on caja_movimientos(sucursal_id);

alter table pagos_moviles add column if not exists sucursal_id uuid;

create index if not exists idx_pagos_moviles_sucursal on pagos_moviles(sucursal_id);
