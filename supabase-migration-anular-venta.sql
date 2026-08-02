-- ============================================================
-- ANULAR VENTA (atómico) — REFRIMAR OS
-- ------------------------------------------------------------
-- Reemplaza el viejo flujo del navegador (restaurar stock en
-- productos + cambiar estado), que tenía DOS errores graves:
--   1. Siempre restauraba a Casa Matriz (productos.stock), aunque
--      la venta hubiese descontado de sucursal_stock.
--   2. No corregía la caja: el movimiento tipo 'venta' seguía
--      contando el dinero aunque la venta estuviera anulada.
--
-- Esta función hace TODO en una sola transacción:
--   - Restaura stock al origen correcto (Casa o sucursal).
--   - Inserta un egreso de caja compensatorio (neto = 0 del día).
--   - Marca la venta como 'anulada'.
--
-- Cómo aplicar:
-- 1. Supabase → SQL Editor → New query
-- 2. Pega TODO este archivo y presiona "Run"
-- 3. Es seguro volver a correrlo (usa OR REPLACE).
-- ============================================================

create or replace function anular_venta(p_venta_id uuid, p_usuario text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_casa uuid := '00000000-0000-0000-0000-000000000001';
    v_venta record;
    v_det record;
begin
    select * into v_venta from ventas where id = p_venta_id for update;

    if not found then
        raise exception 'Venta no encontrada';
    end if;

    if v_venta.estado = 'anulada' then
        raise exception 'La venta ya está anulada';
    end if;

    -- ---- 1. Restaurar stock al origen correcto ----
    for v_det in
        select * from detalle_venta where venta_id = p_venta_id
    loop
        if v_venta.sucursal_id is null or v_venta.sucursal_id = v_casa then
            update productos set stock = stock + v_det.cantidad
            where codigo = v_det.producto_codigo;
        else
            insert into sucursal_stock (sucursal_id, producto_codigo, producto_descripcion, stock)
            values (v_venta.sucursal_id, v_det.producto_codigo, v_det.descripcion, v_det.cantidad)
            on conflict (sucursal_id, producto_codigo)
            do update set stock = sucursal_stock.stock + excluded.stock, updated_at = now();
        end if;
    end loop;

    -- ---- 2. Compensar la caja (solo si la venta registró movimiento) ----
    -- Inserta un egreso con el mismo monto y el mismo método de pago:
    -- el "efectivo esperado" del día queda igual que antes de la venta.
    if v_venta.metodo_pago != 'credito' then
        insert into caja_movimientos (tipo, concepto, monto_usd, monto_bs, sucursal_id, usuario_nombre, metodo_pago)
        values (
            'egreso',
            'Anulación de venta ' || coalesce(v_venta.numero, '') || ' - ' || coalesce(v_venta.cliente_nombre, ''),
            coalesce(v_venta.total_usd, 0),
            coalesce(v_venta.total_bs, 0),
            v_venta.sucursal_id,
            coalesce(p_usuario, 'Sistema'),
            v_venta.metodo_pago
        );
    end if;

    -- ---- 2b. Revertir pagos asociados ----
    if v_venta.metodo_pago = 'credito' then
        update clientes set saldo_pendiente = greatest(coalesce(saldo_pendiente, 0) - coalesce(v_venta.total_usd, 0), 0)
        where rif = v_venta.cliente_rif;
    elsif v_venta.metodo_pago = 'pago_movil' then
        delete from pagos_moviles where venta_numero = v_venta.numero;
    end if;

    -- ---- 3. Marcar como anulada ----
    update ventas set estado = 'anulada' where id = p_venta_id;

    return jsonb_build_object('ok', true);
end;
$$;

grant execute on function anular_venta(uuid, text) to anon, authenticated;
