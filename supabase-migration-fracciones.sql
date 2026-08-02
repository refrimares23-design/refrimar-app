-- ============================================================
-- VENTA POR METRO / KILOGRAMO (fracciones) — REFRIMAR OS
-- ------------------------------------------------------------
-- 1. El stock deja de ser entero y pasa a decimal (numeric):
--    productos.stock, productos.stock_minimo, sucursal_stock.stock,
--    detalle_venta.cantidad y sucursal_movimientos.cantidad.
-- 2. Cada producto tiene su unidad de venta: uds / mt / kg.
--    - uds (unidad): la cantidad debe ser número entero (2, 5, ...).
--    - mt / kg: se puede vender con decimales (1.5 mt, 2.25 kg).
-- 3. Las funciones atómicas (registrar_venta y traspasos) se
--    actualizan para validar y trabajar con decimales.
--
-- Cómo aplicar: Supabase → SQL Editor → New query → Run
-- (idempotente: seguro volver a correrlo).
-- ============================================================

-- ------------------------------------------------------------
-- 1. Tipos de columna: entero -> decimal
-- ------------------------------------------------------------
alter table productos alter column stock type numeric using stock::numeric;
alter table productos alter column stock_minimo type numeric using stock_minimo::numeric;

alter table sucursal_stock alter column stock type numeric using stock::numeric;

alter table detalle_venta alter column cantidad type numeric using cantidad::numeric;

alter table sucursal_movimientos alter column cantidad type numeric using cantidad::numeric;

-- ------------------------------------------------------------
-- 2. Unidad de venta por producto
-- ------------------------------------------------------------
alter table productos add column if not exists unidad text not null default 'uds';

alter table productos drop constraint if exists productos_unidad_check;
alter table productos add constraint productos_unidad_check check (unidad in ('uds', 'mt', 'kg'));

-- ------------------------------------------------------------
-- 3. Eliminar el traspaso con cantidad entera (cambia a decimal)
-- ------------------------------------------------------------
drop function if exists transferir_stock_sucursal(text, integer, numeric, uuid, uuid, text);

-- ============================================================
-- REGISTRAR VENTA (atómico) con decimales + unidad
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
    v_stock numeric;
    v_cantidad numeric;
    v_unidad text;
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

-- ============================================================
-- TRASPASO entre sucursales con decimales
-- ============================================================
create or replace function transferir_stock_sucursal(
    p_producto_codigo text,
    p_cantidad numeric,
    p_costo_unitario numeric,
    p_sucursal_origen_id uuid,
    p_sucursal_destino_id uuid,
    p_usuario_nombre text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_casa_matriz uuid := '00000000-0000-0000-0000-000000000001';
    v_producto_id uuid;
    v_producto_descripcion text;
    v_stock_origen numeric;
    v_movimiento_id uuid;
    v_monto numeric;
begin
    if p_cantidad is null or p_cantidad <= 0 then
        raise exception 'La cantidad debe ser mayor a 0';
    end if;
    if p_sucursal_origen_id is null or p_sucursal_destino_id is null then
        raise exception 'Debes indicar sucursal de origen y destino';
    end if;
    if p_sucursal_origen_id = p_sucursal_destino_id then
        raise exception 'La sucursal de origen y destino no pueden ser la misma';
    end if;

    select id, descripcion into v_producto_id, v_producto_descripcion
    from productos
    where codigo = p_producto_codigo
    for update;

    if not found then
        raise exception 'Producto "%" no encontrado en el catálogo', p_producto_codigo;
    end if;

    v_monto := p_cantidad * coalesce(p_costo_unitario, 0);

    -- ---- 1. DESCONTAR del origen ----
    if p_sucursal_origen_id = v_casa_matriz then
        select stock into v_stock_origen from productos where id = v_producto_id for update;
        if v_stock_origen < p_cantidad then
            raise exception 'Stock insuficiente en Casa Matriz (disponible: %)', v_stock_origen;
        end if;
        update productos set stock = stock - p_cantidad where id = v_producto_id;
    else
        select stock into v_stock_origen
        from sucursal_stock
        where sucursal_id = p_sucursal_origen_id and producto_codigo = p_producto_codigo
        for update;

        if not found or v_stock_origen < p_cantidad then
            raise exception 'Stock insuficiente en la sucursal de origen (disponible: %)', coalesce(v_stock_origen, 0);
        end if;

        update sucursal_stock
        set stock = stock - p_cantidad, updated_at = now()
        where sucursal_id = p_sucursal_origen_id and producto_codigo = p_producto_codigo;
    end if;

    -- ---- 2. ACREDITAR al destino ----
    if p_sucursal_destino_id = v_casa_matriz then
        update productos set stock = stock + p_cantidad where id = v_producto_id;
    else
        insert into sucursal_stock (sucursal_id, producto_codigo, producto_descripcion, stock)
        values (p_sucursal_destino_id, p_producto_codigo, v_producto_descripcion, p_cantidad)
        on conflict (sucursal_id, producto_codigo)
        do update set stock = sucursal_stock.stock + excluded.stock, updated_at = now();
    end if;

    -- ---- 3. Registrar el movimiento (kardex de deuda de la sucursal) ----
    if p_sucursal_origen_id = v_casa_matriz then
        insert into sucursal_movimientos
            (sucursal_id, tipo, producto_codigo, producto_descripcion, cantidad, costo_unitario, monto, usuario_nombre)
        values
            (p_sucursal_destino_id, 'traspaso', p_producto_codigo, v_producto_descripcion, p_cantidad, p_costo_unitario, v_monto, p_usuario_nombre)
        returning id into v_movimiento_id;
    elsif p_sucursal_destino_id = v_casa_matriz then
        insert into sucursal_movimientos
            (sucursal_id, tipo, producto_codigo, producto_descripcion, cantidad, costo_unitario, monto, usuario_nombre, notas)
        values
            (p_sucursal_origen_id, 'abono', p_producto_codigo, v_producto_descripcion, p_cantidad, p_costo_unitario, v_monto, p_usuario_nombre, 'Devolución de mercancía a Casa Matriz')
        returning id into v_movimiento_id;
    end if;

    return jsonb_build_object(
        'ok', true,
        'movimiento_id', v_movimiento_id,
        'producto_codigo', p_producto_codigo,
        'cantidad', p_cantidad
    );
end;
$$;

grant execute on function transferir_stock_sucursal(text, numeric, numeric, uuid, uuid, text) to anon, authenticated;
