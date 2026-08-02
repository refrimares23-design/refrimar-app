-- ============================================================
-- RECUPERACIÓN: stock faltante en sucursal (traspasos viejos)
-- REFRIMAR OS
-- ------------------------------------------------------------
-- Los traspasos registrados ANTES de que la versión atómica
-- (RPC transferir_stock_sucursal) estuviera activa quedaban
-- anotados en sucursal_movimientos (kardex) y descontaban de
-- Casa Matriz, pero NUNCA creaban la fila en sucursal_stock.
-- Resultado: productos físicamente enviados a la sucursal que
-- no aparecían en su inventario.
--
-- Este script crea (solo si no existen) las filas de
-- sucursal_stock para cada producto traspasado, con la cantidad
-- total traspasada. Es idempotente: se puede correr las veces
-- que quieras. NO toca las filas ya existentes (las de los
-- traspasos recientes que ya quedaron bien).
--
-- Cómo aplicar: Supabase → SQL Editor → New query → Run
-- ============================================================

insert into sucursal_stock (sucursal_id, producto_codigo, producto_descripcion, stock)
select
    m.sucursal_id,
    m.producto_codigo,
    max(m.producto_descripcion) as producto_descripcion,
    sum(m.cantidad) as stock
from sucursal_movimientos m
where m.tipo = 'traspaso'
  and m.producto_codigo is not null
group by m.sucursal_id, m.producto_codigo
on conflict (sucursal_id, producto_codigo) do nothing;

-- Verificación: cuántas filas tiene cada sucursal después de la recuperación
select s.nombre, count(st.id) as productos_con_stock
from sucursal_stock st
join sucursales s on s.id = st.sucursal_id
group by s.nombre;
