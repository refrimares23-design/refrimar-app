-- ============================================================
-- REFRIMAR OS — COSTO PROPIO POR SUCURSAL (sucursal_stock.costo)
-- ------------------------------------------------------------
-- Objetivo: el inventario de cada sucursal debe valorar con el
-- costo con el que recibió la mercancía (traspaso o compra),
-- NO con el costo actual global de Casa Matriz.
-- Idempotente: se puede correr más de una vez sin problema.
-- ============================================================

-- 1) Columna de costo por sucursal
alter table public.sucursal_stock add column if not exists costo numeric;
alter table public.sucursal_stock alter column costo set default 0;

-- 2) Backfill: costo = costo unitario del ÚLTIMO traspaso recibido
--    en esa sucursal (sucursal_movimientos guarda costo_unitario).
update public.sucursal_stock ss
set costo = t.costo_unitario
from (
    select distinct on (sucursal_id, producto_codigo)
        sucursal_id, producto_codigo, costo_unitario
    from public.sucursal_movimientos
    where tipo = 'traspaso' and cantidad > 0 and costo_unitario > 0
    order by sucursal_id, producto_codigo, fecha desc
) t
where ss.sucursal_id = t.sucursal_id
  and ss.producto_codigo = t.producto_codigo;

-- 3) Los que no llegaron por traspaso (compra directa, etc.) toman
--    el costo actual del producto como referencia.
update public.sucursal_stock ss
set costo = p.costo
from public.productos p
where p.codigo = ss.producto_codigo
  and ss.costo is null;

-- 4) Nunca dejar nulo
update public.sucursal_stock set costo = 0 where costo is null;

-- 5) CASO ESPECIAL: CADENA PLASTICA 25M se transfirió como 1 rollo ($50)
--    pero ahora se maneja por metro ($2/m) con stock 25m.
--    Su valor debe ser 25 x $2 = $50 (igual a lo traspasado), por eso su
--    costo en la sucursal queda en $2 (por metro).
update public.sucursal_stock
set costo = 2.00
where sucursal_id = 'dd07bd88-ca35-421b-bea9-4807b8ab2681'
  and producto_codigo = '6942431455469';

-- 6) RPC que usa la app para fijar el costo de un producto en una
--    sucursal después de cada traspaso, compra o ajuste de kardex.
create or replace function public.sucursal_stock_set_costo(
    p_sucursal_id uuid,
    p_producto_codigo text,
    p_costo numeric
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
    if p_costo is not null and p_costo >= 0 then
        update public.sucursal_stock
        set costo = p_costo, updated_at = now()
        where sucursal_id = p_sucursal_id
          and producto_codigo = p_producto_codigo;
    end if;
end;
$$;

grant execute on function public.sucursal_stock_set_costo(uuid, text, numeric) to anon, authenticated;

-- ============================================================
-- VERIFICACIÓN (opcional): después de correr lo anterior,
-- el valor de la sucursal debe cuadrar con la suma de traspasos.
-- ============================================================
-- select
--   (select sum(monto) from sucursal_movimientos
--     where sucursal_id = 'dd07bd88-ca35-421b-bea9-4807b8ab2681' and tipo = 'traspaso') as total_traspasado,
--   (select sum(round(stock * costo, 2)) from sucursal_stock
--     where sucursal_id = 'dd07bd88-ca35-421b-bea9-4807b8ab2681' and stock > 0) as valor_inventario;
