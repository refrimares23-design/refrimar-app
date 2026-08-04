-- ============================================================
-- MIGRACIÓN: PAGO MIXTO CON DESGLOSE OBLIGATORIO — REFRIMAR OS
-- ------------------------------------------------------------
-- QUÉ HACE
--   Actualiza registrar_venta para que un pago "mixto" se
--   registre en caja en DOS movimientos:
--     1) Efectivo  -> metodo_pago = 'efectivo'
--     2) Electrónico -> metodo_pago = pago_movil / transferencia / punto
--   Así el arqueo de caja al final del día cuadra al 100%:
--   solo el monto en efectivo queda como físico y el resto se
--   suma a los ingresos no físicos.
--
--   Si el resto se paga con Pago Móvil, además se inserta en
--   pagos_moviles con el monto electrónico (cuadre del banco).
--
-- CÓMO APLICAR (OBLIGATORIO ANTES DE DESPLEGAR LA VERSIÓN NUEVA)
--   1. Supabase → SQL Editor → New query
--   2. Pega TODO este archivo y presiona "Run"
--   3. Solo DESPUÉS despliega la app (npx wrangler deploy).
--
--   Es seguro volver a correrlo (drop + create or replace).
--
-- FIRMA NUEVA de registrar_venta (19 parámetros):
--   (... los 15 originales ...,
--    p_pm_banco text default null,
--    p_pm_remitente text default null,
--    p_pm_referencia text default null,
--    p_metodo_2 text default null,
--    p_efectivo_usd numeric default null,
--    p_efectivo_bs numeric default null)
-- ============================================================

-- ------------------------------------------------------------
-- 0. Quitar la versión anterior de la función (firma de 15)
-- ------------------------------------------------------------
drop function if exists registrar_venta(text, text, text, numeric, numeric, numeric, numeric, numeric, text, uuid, text, text, jsonb, text, text, text);

-- ------------------------------------------------------------
-- 1. Función con desglose mixto
-- ------------------------------------------------------------
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
    p_pm_referencia text default null,
    p_metodo_2 text default null,
    p_efectivo_usd numeric default null,
    p_efectivo_bs numeric default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_casa uuid := '00000000-0000-0000-0000-000000000001';
    v_item record;
    v_venta_id uuid;
    v_stock numeric;
    v_cantidad numeric;
    v_unidad text;
    v_saldo numeric;
    v_limite numeric;
    v_efectivo_bs numeric;
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

    -- ---- 2. Por cada ítem: validar, descontar y guardar detalle ----
    for v_item in
        select value from jsonb_array_elements(p_items)
    loop
        if v_item.value->>'codigo' is null or v_item.value->>'cantidad' is null then
            raise exception 'Item inválido: %', v_item.value;
        end if;

        v_cantidad := (v_item.value->>'cantidad')::numeric;
        if v_cantidad <= 0 then
            raise exception 'La cantidad de "%" debe ser mayor a 0', v_item.value->>'codigo';
        end if;

        -- Unidad del producto: si se vende por unidad (uds) la cantidad debe ser entera
        v_unidad := null;
        select coalesce(unidad, 'uds') into v_unidad
        from productos
        where codigo = v_item.value->>'codigo';

        if v_unidad is null then
            raise exception 'Producto "%" no encontrado', v_item.value->>'codigo';
        end if;

        if v_unidad = 'uds' and v_cantidad <> floor(v_cantidad) then
            raise exception 'El producto "%" se vende por unidad; la cantidad debe ser un número entero.', v_item.value->>'codigo';
        end if;

        if p_sucursal_id is null or p_sucursal_id = v_casa then
            select stock into v_stock
            from productos
            where codigo = v_item.value->>'codigo'
            for update;

            if not found then
                raise exception 'Producto "%" no encontrado', v_item.value->>'codigo';
            end if;
            if v_stock < v_cantidad then
                raise exception 'Stock insuficiente de "%" en Casa Matriz (disponible: %)',
                    v_item.value->>'codigo', v_stock;
            end if;

            update productos set stock = stock - v_cantidad
            where codigo = v_item.value->>'codigo';
        else
            select stock into v_stock
            from sucursal_stock
            where sucursal_id = p_sucursal_id and producto_codigo = v_item.value->>'codigo'
            for update;

            if not found then
                raise exception 'Producto "%" sin stock en esta sucursal', v_item.value->>'codigo';
            end if;
            if v_stock < v_cantidad then
                raise exception 'Stock insuficiente de "%" en la sucursal (disponible: %)',
                    v_item.value->>'codigo', v_stock;
            end if;

            update sucursal_stock
            set stock = stock - v_cantidad, updated_at = now()
            where sucursal_id = p_sucursal_id and producto_codigo = v_item.value->>'codigo';
        end if;

        insert into detalle_venta (venta_id, producto_codigo, descripcion, cantidad,
            precio_unitario, costo_unitario, descuento, total)
        values (v_venta_id,
            v_item.value->>'codigo',
            v_item.value->>'descripcion',
            v_cantidad,
            (v_item.value->>'precio')::numeric,
            coalesce((v_item.value->>'costo')::numeric, 0),
            coalesce((v_item.value->>'descuento')::numeric, 0),
            (v_item.value->>'total')::numeric);
    end loop;

    -- ---- 3. Registrar en caja (si no es crédito) ----
    if p_metodo = 'mixto' then
        -- Pago mixto: validar el desglose obligatorio.
        if p_efectivo_usd is null or p_efectivo_usd <= 0 or p_metodo_2 is null then
            raise exception 'Para pagos mixtos debes indicar el desglose: cuánto se recibe en efectivo y con qué método se paga el resto';
        end if;
        if p_efectivo_usd >= p_total_usd then
            raise exception 'El monto en efectivo del pago mixto debe ser menor al total';
        end if;

        v_efectivo_bs := coalesce(p_efectivo_bs, 0);

        -- 3.1 Parte en efectivo (queda en la caja física)
        insert into caja_movimientos (tipo, concepto, monto_usd, monto_bs, sucursal_id, usuario_nombre, metodo_pago)
        values ('venta', 'Venta ' || p_numero || ' - ' || p_cliente_nombre || ' (efectivo)',
                p_efectivo_usd, v_efectivo_bs, p_sucursal_id, p_usuario, 'efectivo');

        -- 3.2 Parte electrónica (no es físico; no entra al arqueo)
        insert into caja_movimientos (tipo, concepto, monto_usd, monto_bs, sucursal_id, usuario_nombre, metodo_pago)
        values ('venta', 'Venta ' || p_numero || ' - ' || p_cliente_nombre || ' (' || p_metodo_2 || ')',
                p_total_usd - p_efectivo_usd, p_total_bs - v_efectivo_bs, p_sucursal_id, p_usuario, p_metodo_2);

        -- 3.3 Si el resto se pagó con Pago Móvil: cuadre del banco
        if p_metodo_2 = 'pago_movil' then
            insert into pagos_moviles (banco, remitente, monto, referencia, sucursal_id, usuario_nombre, venta_numero)
            values (coalesce(p_pm_banco, ''), coalesce(p_pm_remitente, p_cliente_nombre),
                    p_total_bs - v_efectivo_bs, p_pm_referencia, p_sucursal_id, p_usuario, p_numero);
        end if;
    elsif p_metodo != 'credito' then
        insert into caja_movimientos (tipo, concepto, monto_usd, monto_bs, sucursal_id, usuario_nombre, metodo_pago)
        values ('venta', 'Venta ' || p_numero || ' - ' || p_cliente_nombre,
                p_total_usd, p_total_bs, p_sucursal_id, p_usuario, p_metodo);
    end if;

    -- ---- 4. Pago móvil puro: registrarlo en pagos_moviles ----
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

grant execute on function registrar_venta(text, text, text, numeric, numeric, numeric, numeric, numeric, text, uuid, text, text, jsonb, text, text, text, text, numeric, numeric) to anon, authenticated;
