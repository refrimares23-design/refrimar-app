-- ============================================================
-- ADENDO: caja por método de pago + crédito con saldo pendiente
-- REFRIMAR OS
-- ------------------------------------------------------------
-- 1. caja_movimientos.metodo_pago: guarda con qué se pagó cada
--    movimiento de caja, para que el "efectivo esperado" solo sume
--    efectivo/divisa (dinero físico) y no pago móvil/tarjeta.
-- 2. pagos_moviles.venta_numero: enlaza cada pago móvil con la
--    factura que lo generó (para cuadrar el banco y revertirlo al
--    anular la venta).
--
-- Cómo aplicar: Supabase → SQL Editor → New query → Run
-- (idempotente, usa IF NOT EXISTS).
-- ============================================================

alter table caja_movimientos add column if not exists metodo_pago text;

alter table pagos_moviles add column if not exists venta_numero text;

create index if not exists idx_pagos_moviles_venta on pagos_moviles(venta_numero);
