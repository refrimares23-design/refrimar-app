-- ============================================================
-- REGISTRAR VENTA (atómico) — REFRIMAR OS
-- ------------------------------------------------------------
-- Reemplaza el viejo flujo del navegador que hacía 4 pasos sueltos
-- (insertar venta → insertar detalle → loop descontando stock →
-- insertar caja). Si la red fallaba a mitad, quedaba una venta sin
-- stock descontado, sin caja, o duplicada al reintentar.
--
-- Esta función hace TODO en una sola transacción plpgsql:
--   - Valida el stock de cada ítem (bloqueando la fila).
--   - Inserta la venta, el detalle y el movimiento de caja.
--   - Descuenta el stock (Casa Matriz o sucursal según sucursal_id).
-- Si algo falla, Postgres revierte TODO automáticamente.
--
-- Cómo aplicar:
-- 1. Supabase → SQL Editor → New query
-- 2. Pega TODO este archivo y presiona "Run"
-- 3. Es seguro volver a correrlo (usa OR REPLACE).
-- ============================================================

create or replace function registrar_venta(
    p_numero text,
    p_cliente_nombre text,
    p_cliente_rif text,
    p_subtotal numeric,
    p_iva numeric,
    p_total_usd numeric,
    p_tasa_bcv numeric,
    p_total_bs numeric,
    p_metodo text,
    p_sucursal_id uuid,
    p_sucursal_nombre text,
    p_usuario text,
    p_items jsonb,
    p_pm_banco text default null,
    p_pm_remitente text default null,
    p_pm_referencia text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_casa uuid := '00000000-0000-0000-0000-000000000001';
    v_item record;
    v_venta_id uuid;
    v_stock integer;
    v_saldo numeric;
    v_limite numeric;
begin
    if p_items is null or jsonb_array_length(p_items) = 0 then
        raise exception 'La venta no tiene productos';
    end if;

    -- ---- 1. Insertar la venta ----
    insert into ventas (numero, cliente_nombre, cliente_rif, subtotal, iva, total_usd,
                        tasa_bcv, total_bs, metodo_pago, estado, sucursal_id, sucursal_nombre)
    values (p_numero, p_cliente_nombre, p_cliente_rif, p_subtotal, p_iva, p_total_usd,
            p_tasa_bcv, p_total_bs, p_metodo, 'completada', p_sucursal_id, p_sucursal_nombre)
    returning id into v_venta_id;

    -- ---- 2. Por cada ítem: validar stock, descontar y guardar detalle ----
    for v_item in
        select value from jsonb_array_elements(p_items)
    loop
        if v_item.value->>'codigo' is null or v_item.value->>'cantidad' is null then
            raise exception 'Item inválido: %', v_item.value;
        end if;

        if p_sucursal_id is null or p_sucursal_id = v_casa then
            select stock into v_stock
            from productos
            where codigo = v_item.value->>'codigo'
            for update;

            if not found then
                raise exception 'Producto "%" no encontrado', v_item.value->>'codigo';
            end if;
            if v_stock < (v_item.value->>'cantidad')::integer then
                raise exception 'Stock insuficiente de "%" en Casa Matriz (disponible: %)',
                    v_item.value->>'codigo', v_stock;
            end if;

            update productos set stock = stock - (v_item.value->>'cantidad')::integer
            where codigo = v_item.value->>'codigo';
        else
            select stock into v_stock
            from sucursal_stock
            where sucursal_id = p_sucursal_id and producto_codigo = v_item.value->>'codigo'
            for update;

            if not found then
                raise exception 'Producto "%" sin stock en esta sucursal', v_item.value->>'codigo';
            end if;
            if v_stock < (v_item.value->>'cantidad')::integer then
                raise exception 'Stock insuficiente de "%" en la sucursal (disponible: %)',
                    v_item.value->>'codigo', v_stock;
            end if;

            update sucursal_stock
            set stock = stock - (v_item.value->>'cantidad')::integer, updated_at = now()
            where sucursal_id = p_sucursal_id and producto_codigo = v_item.value->>'codigo';
        end if;

        insert into detalle_venta (venta_id, producto_codigo, descripcion, cantidad,
            precio_unitario, costo_unitario, descuento, total)
        values (v_venta_id,
            v_item.value->>'codigo',
            v_item.value->>'descripcion',
            (v_item.value->>'cantidad')::numeric,
            (v_item.value->>'precio')::numeric,
            coalesce((v_item.value->>'costo')::numeric, 0),
            coalesce((v_item.value->>'descuento')::numeric, 0),
            (v_item.value->>'total')::numeric);
    end loop;

    -- ---- 3. Registrar en caja (si no es crédito) ----
    if p_metodo != 'credito' then
        insert into caja_movimientos (tipo, concepto, monto_usd, monto_bs, sucursal_id, usuario_nombre, metodo_pago)
        values ('venta', 'Venta ' || p_numero || ' - ' || p_cliente_nombre,
                p_total_usd, p_total_bs, p_sucursal_id, p_usuario, p_metodo);
    end if;

    -- ---- 4. Pago móvil: registrarlo en pagos_moviles (cuadre del banco) ----
    if p_metodo = 'pago_movil' then
        insert into pagos_moviles (banco, remitente, monto, referencia, sucursal_id, usuario_nombre, venta_numero)
        values (coalesce(p_pm_banco, ''), coalesce(p_pm_remitente, p_cliente_nombre),
                p_total_bs, p_pm_referencia, p_sucursal_id, p_usuario, p_numero);
    elsif p_metodo = 'credito' then
        -- ---- 5. Crédito: actualizar la cuenta por cobrar del cliente ----
        select saldo_pendiente, limite_credito into v_saldo, v_limite
        from clientes
        where rif = p_cliente_rif
        for update;

        if not found then
            raise exception 'El cliente con RIF % no está registrado. Regístralo antes de vender a crédito.', p_cliente_rif;
        end if;
        if coalesce(v_limite, 0) > 0 and coalesce(v_saldo, 0) + p_total_usd > v_limite then
            raise exception 'La venta excede el límite de crédito del cliente (saldo: %, límite: %)',
                coalesce(v_saldo, 0), v_limite;
        end if;

        update clientes set saldo_pendiente = coalesce(v_saldo, 0) + p_total_usd
        where rif = p_cliente_rif;
    end if;

    return jsonb_build_object('ok', true, 'venta_id', v_venta_id);
end;
$$;

grant execute on function registrar_venta(text,text,text,numeric,numeric,numeric,numeric,numeric,text,uuid,text,text,jsonb,text,text,text) to anon, authenticated;
