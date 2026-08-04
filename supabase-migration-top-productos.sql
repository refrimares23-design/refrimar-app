-- ============================================================
-- TOP PRODUCTOS MÁS VENDIDOS POR SUCURSAL — REFRIMAR OS
-- ------------------------------------------------------------
-- Nueva RPC para la pantalla de Facturación (atajos del cajero):
-- devuelve los 10 productos más vendidos de una sucursal (o de
-- todas si no se pasa sucursal), excluyendo ventas anuladas.
--
-- Es SECURITY DEFINER para poder leer ventas/detalle_venta (que
-- tienen RLS de solo-lectura para anon) sin exponer las tablas.
--
-- Cómo aplicar:
-- 1. Supabase → SQL Editor → New query
-- 2. Pega TODO este archivo y presiona "Run"
-- 3. Es seguro volver a correrlo (usa OR REPLACE).
-- ============================================================

create or replace function top_productos_vendidos(p_sucursal_id uuid default null)
returns table(producto_codigo text, descripcion text, cantidad numeric, stock numeric, precio numeric)
language sql
security definer
set search_path = public
as $$
    select
        d.producto_codigo,
        coalesce((select pr.descripcion from productos pr where pr.codigo = d.producto_codigo limit 1), d.descripcion) as descripcion,
        sum(d.cantidad) as cantidad,
        coalesce((select pr.stock from productos pr where pr.codigo = d.producto_codigo limit 1), 0) as stock,
        coalesce((select pr.precio from productos pr where pr.codigo = d.producto_codigo limit 1), 0) as precio
    from detalle_venta d
    join ventas v on v.id = d.venta_id
    where v.estado is distinct from 'anulada'
      and (p_sucursal_id is null or v.sucursal_id = p_sucursal_id)
    group by d.producto_codigo, d.descripcion
    order by sum(d.cantidad) desc
    limit 10;
$$;

revoke all on function top_productos_vendidos(uuid) from public;
grant execute on function top_productos_vendidos(uuid) to anon, authenticated, service_role;
