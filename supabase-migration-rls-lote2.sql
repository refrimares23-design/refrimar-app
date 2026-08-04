-- ============================================================
-- RLS LOTES 2 — REFRIMAR OS
-- Cierra la escritura directa (anon key) en el catálogo y las
-- operaciones: productos, sucursales, sucursal_movimientos,
-- cotizaciones, detalle_cotizacion, compras_proveedores,
-- abonos_compras.
-- ------------------------------------------------------------
-- Toda escritura pasa por funciones RPC SECURITY DEFINER que:
--   - validan los datos,
--   - ejecutan como el dueño de la BD (saltan RLS),
--   - dejan la anon key SOLO con lectura (SELECT).
-- sucursal_stock ya estaba protegida (RLS select-only); aquí se
-- refuerza con revoke y se integra su stock inicial al crear un
-- producto desde una sucursal (producto_guardar).
--
-- Cómo aplicar:
-- 1. Supabase → SQL Editor → New query
-- 2. Pega TODO este archivo y presiona "Run"
-- 3. Es seguro volver a correrlo (usa DROP POLICY IF EXISTS y
--    CREATE OR REPLACE FUNCTION).
-- ============================================================

-- ============================================================
-- 1. PRODUCTOS (catálogo)
-- ============================================================

-- Guardar (crear o editar) un producto. Si se pasa
-- p_sucursal_stock_id + p_stock_inicial, el stock inicial se
-- acredita a esa sucursal en la misma transacción (antes eran
-- 2 llamadas sueltas; la segunda ya fallaba por RLS).
create or replace function producto_guardar(
    p_codigo text,
    p_descripcion text,
    p_id uuid default null,
    p_categoria text default null,
    p_marca text default null,
    p_unidad text default 'uds',
    p_costo numeric default 0,
    p_precio numeric default 0,
    p_stock numeric default 0,
    p_stock_minimo numeric default 0,
    p_codigos_alternos jsonb default null,
    p_stock_inicial numeric default 0,
    p_sucursal_stock_id uuid default null
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
    v_id uuid;
    v_stock numeric;
    v_codigos_alternos text[] := '{}';
    v_descripcion text;
begin
    if p_codigo is null or trim(p_codigo) = '' then
        raise exception 'El código es obligatorio';
    end if;
    if p_descripcion is null or trim(p_descripcion) = '' then
        raise exception 'La descripción es obligatoria';
    end if;

    if p_codigos_alternos is not null and jsonb_typeof(p_codigos_alternos) = 'array' then
        select coalesce(array_agg(x), '{}') into v_codigos_alternos
        from jsonb_array_elements_text(p_codigos_alternos) x;
    end if;

    -- Si el producto se crea estando en una sucursal, el stock del
    -- catálogo (Casa Matriz) queda en 0 y el stock inicial se
    -- acredita a la sucursal.
    v_stock := case when p_sucursal_stock_id is not null then 0 else coalesce(p_stock, 0) end;
    v_descripcion := trim(p_descripcion);

    if p_id is null then
        insert into productos
            (codigo, descripcion, categoria, marca, unidad, costo, precio, stock, stock_minimo, codigos_alternos)
        values
            (trim(p_codigo), v_descripcion, p_categoria, p_marca, coalesce(p_unidad, 'uds'),
             coalesce(p_costo, 0), coalesce(p_precio, 0), v_stock, coalesce(p_stock_minimo, 0),
             v_codigos_alternos)
        returning id into v_id;
    else
        update productos
        set codigo = trim(p_codigo), descripcion = v_descripcion, categoria = p_categoria,
            marca = p_marca, unidad = coalesce(p_unidad, 'uds'),
            costo = coalesce(p_costo, 0), precio = coalesce(p_precio, 0), stock = v_stock,
            stock_minimo = coalesce(p_stock_minimo, 0),
            codigos_alternos = case when p_codigos_alternos is not null
                                    then v_codigos_alternos else codigos_alternos end
        where id = p_id;
        v_id := p_id;
    end if;

    if v_id is null then
        raise exception 'No se pudo guardar el producto';
    end if;

    -- Stock inicial a sucursal (producto nuevo creado desde una sucursal)
    if p_sucursal_stock_id is not null and coalesce(p_stock_inicial, 0) > 0 then
        insert into sucursal_stock (sucursal_id, producto_codigo, producto_descripcion, stock)
        values (p_sucursal_stock_id, trim(p_codigo), v_descripcion, p_stock_inicial)
        on conflict (sucursal_id, producto_codigo)
        do update set stock = sucursal_stock.stock + excluded.stock, updated_at = now();
    end if;

    return v_id;
end;
$$;

create or replace function producto_eliminar(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
    if p_id is null then
        raise exception 'Falta el producto';
    end if;
    delete from productos where id = p_id;
end;
$$;

-- ============================================================
-- 2. SUCURSALES
-- ============================================================

create or replace function sucursal_guardar(
    p_nombre text,
    p_id uuid default null,
    p_direccion text default null
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
    v_id uuid;
begin
    if p_nombre is null or trim(p_nombre) = '' then
        raise exception 'El nombre es obligatorio';
    end if;

    if p_id is null then
        insert into sucursales (nombre, direccion)
        values (trim(p_nombre), p_direccion)
        returning id into v_id;
    else
        update sucursales set nombre = trim(p_nombre), direccion = p_direccion where id = p_id;
        v_id := p_id;
    end if;

    if v_id is null then
        raise exception 'No se pudo guardar la sucursal';
    end if;
    return v_id;
end;
$$;

-- ============================================================
-- 3. SUCURSAL MOVIMIENTOS (kardex de sucursal)
-- ============================================================

create or replace function sucursal_movimiento_registrar(
    p_sucursal_id uuid,
    p_tipo text,
    p_monto numeric default 0,
    p_notas text default null,
    p_usuario_nombre text default 'Sistema',
    p_producto_codigo text default null,
    p_producto_descripcion text default null,
    p_cantidad numeric default null,
    p_costo_unitario numeric default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
    if p_sucursal_id is null then
        raise exception 'Falta la sucursal';
    end if;
    if p_tipo is null or trim(p_tipo) = '' then
        raise exception 'Falta el tipo de movimiento';
    end if;
    if trim(p_tipo) not in ('abono', 'traspaso') then
        raise exception 'Tipo de movimiento inválido';
    end if;
    if trim(p_tipo) = 'abono' and (p_monto is null or p_monto <= 0) then
        raise exception 'El monto del abono debe ser mayor a 0';
    end if;

    insert into sucursal_movimientos
        (sucursal_id, tipo, monto, notas, usuario_nombre,
         producto_codigo, producto_descripcion, cantidad, costo_unitario)
    values
        (p_sucursal_id, trim(p_tipo), coalesce(p_monto, 0), p_notas,
         coalesce(p_usuario_nombre, 'Sistema'),
         p_producto_codigo, p_producto_descripcion, p_cantidad, p_costo_unitario);
end;
$$;

-- Solo permite eliminar ABONOS directamente. Los traspasos deben
-- anularse con revertir_traspaso_sucursal (que además devuelve el
-- stock a Casa Matriz).
create or replace function sucursal_movimiento_eliminar(p_movimiento_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
    v_tipo text;
begin
    if p_movimiento_id is null then
        raise exception 'Falta el movimiento';
    end if;

    select tipo into v_tipo from sucursal_movimientos where id = p_movimiento_id;
    if not found then
        raise exception 'Movimiento no encontrado';
    end if;

    if coalesce(v_tipo, '') <> 'abono' then
        raise exception 'Los traspasos se anulan con revertir_traspaso_sucursal';
    end if;

    delete from sucursal_movimientos where id = p_movimiento_id;
end;
$$;

-- ============================================================
-- 4. COTIZACIONES (cabecera + detalle en una sola transacción)
-- ============================================================

create or replace function cotizacion_guardar(
    p_numero text,
    p_detalle jsonb,
    p_cliente_nombre text default 'Consumidor Final',
    p_cliente_rif text default null,
    p_subtotal numeric default 0,
    p_iva numeric default 0,
    p_total_usd numeric default 0,
    p_tasa_bcv numeric default 0,
    p_total_bs numeric default 0,
    p_validez_dias integer default 7,
    p_estado text default 'pendiente'
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
    v_cotizacion_id uuid;
    v_row jsonb;
    v_count int := 0;
begin
    if p_numero is null or trim(p_numero) = '' then
        raise exception 'Falta el número de cotización';
    end if;
    if p_detalle is null or jsonb_typeof(p_detalle) <> 'array' or jsonb_array_length(p_detalle) = 0 then
        raise exception 'La cotización no tiene productos';
    end if;

    insert into cotizaciones
        (numero, cliente_nombre, cliente_rif, subtotal, iva, total_usd,
         tasa_bcv, total_bs, validez_dias, estado)
    values
        (trim(p_numero),
         coalesce(nullif(trim(coalesce(p_cliente_nombre, '')), ''), 'Consumidor Final'),
         p_cliente_rif, coalesce(p_subtotal, 0), coalesce(p_iva, 0), coalesce(p_total_usd, 0),
         coalesce(p_tasa_bcv, 0), coalesce(p_total_bs, 0), coalesce(p_validez_dias, 7),
         coalesce(p_estado, 'pendiente'))
    returning id into v_cotizacion_id;

    for v_row in select value from jsonb_array_elements(p_detalle)
    loop
        if coalesce(v_row->>'producto_codigo', '') = '' then
            continue;
        end if;
        insert into detalle_cotizacion
            (cotizacion_id, producto_codigo, descripcion, cantidad, precio_unitario, descuento, total)
        values
            (v_cotizacion_id,
             v_row->>'producto_codigo',
             v_row->>'descripcion',
             coalesce((v_row->>'cantidad')::numeric, 0),
             coalesce((v_row->>'precio_unitario')::numeric, 0),
             coalesce((v_row->>'descuento')::numeric, 0),
             coalesce((v_row->>'total')::numeric, 0));
        v_count := v_count + 1;
    end loop;

    if v_count = 0 then
        raise exception 'La cotización no tiene productos';
    end if;

    return v_cotizacion_id;
end;
$$;

-- ============================================================
-- 5. COMPRAS PROVEEDORES (cuentas por pagar)
-- ============================================================

create or replace function compra_proveedor_guardar(
    p_proveedor text,
    p_numero text,
    p_sucursal_id uuid,
    p_id uuid default null,
    p_rif text default null,
    p_fecha_emision date default current_date,
    p_fecha_vencimiento date default null,
    p_monto numeric default 0,
    p_estado text default 'Pendiente',
    p_notas text default null,
    p_sucursal_nombre text default null
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
    v_id uuid;
begin
    if p_proveedor is null or trim(p_proveedor) = '' then
        raise exception 'El proveedor es obligatorio';
    end if;
    if p_numero is null or trim(p_numero) = '' then
        raise exception 'El número de factura es obligatorio';
    end if;

    if p_id is null then
        if p_monto is null or p_monto <= 0 then
            raise exception 'El monto debe ser mayor a 0';
        end if;
        insert into compras_proveedores
            (proveedor, rif, numero, fecha_emision, fecha_vencimiento, monto_usd,
             monto_abonado, saldo_pendiente, estado, notas, sucursal_id, sucursal_nombre)
        values
            (trim(p_proveedor), p_rif, trim(p_numero), coalesce(p_fecha_emision, current_date),
             p_fecha_vencimiento, p_monto, 0, p_monto, coalesce(p_estado, 'Pendiente'),
             p_notas, p_sucursal_id, p_sucursal_nombre)
        returning id into v_id;
    else
        -- Al editar NO se tocan monto_abonado / saldo_pendiente para
        -- no romper la integridad de los abonos ya aplicados.
        update compras_proveedores
        set proveedor = trim(p_proveedor), rif = p_rif, numero = trim(p_numero),
            fecha_emision = coalesce(p_fecha_emision, fecha_emision),
            fecha_vencimiento = p_fecha_vencimiento,
            estado = coalesce(p_estado, estado), notas = p_notas,
            sucursal_id = p_sucursal_id, sucursal_nombre = p_sucursal_nombre
        where id = p_id;
        v_id := p_id;
    end if;

    if v_id is null then
        raise exception 'No se pudo guardar la factura';
    end if;
    return v_id;
end;
$$;

-- ============================================================
-- 6. RLS: habilitar y dejar SOLO lectura a anon/authenticated
-- ============================================================

alter table productos enable row level security;
alter table sucursales enable row level security;
alter table sucursal_movimientos enable row level security;
alter table cotizaciones enable row level security;
alter table detalle_cotizacion enable row level security;
alter table abonos_compras enable row level security;

drop policy if exists "productos_select" on productos;
create policy "productos_select" on productos for select using (true);

drop policy if exists "sucursales_select" on sucursales;
create policy "sucursales_select" on sucursales for select using (true);

drop policy if exists "sucursal_movimientos_select" on sucursal_movimientos;
create policy "sucursal_movimientos_select" on sucursal_movimientos for select using (true);

drop policy if exists "cotizaciones_select" on cotizaciones;
create policy "cotizaciones_select" on cotizaciones for select using (true);

drop policy if exists "detalle_cotizacion_select" on detalle_cotizacion;
create policy "detalle_cotizacion_select" on detalle_cotizacion for select using (true);

drop policy if exists "abonos_compras_select" on abonos_compras;
create policy "abonos_compras_select" on abonos_compras for select using (true);

-- compras_proveedores conserva su policy de SELECT (ya existía).

-- Las tablas de CXP traían policies de escritura abiertas de la
-- migración original: se eliminan.
drop policy if exists "compras_proveedores_insert" on compras_proveedores;
drop policy if exists "compras_proveedores_update" on compras_proveedores;
drop policy if exists "compras_proveedores_delete" on compras_proveedores;
drop policy if exists "abonos_compras_insert" on abonos_compras;
drop policy if exists "abonos_compras_delete" on abonos_compras;

-- Bloquea la escritura directa a nivel de rol (independiente de RLS).
revoke insert, update, delete on productos, sucursales, sucursal_stock,
    sucursal_movimientos, cotizaciones, detalle_cotizacion,
    compras_proveedores, abonos_compras from anon, authenticated;

grant select on productos, sucursales, sucursal_stock, sucursal_movimientos,
    cotizaciones, detalle_cotizacion, compras_proveedores, abonos_compras
    to anon, authenticated;

-- ============================================================
-- 7. Permitir ejecutar las RPCs a anon (las usa el navegador)
-- ============================================================

grant execute on function producto_guardar(text, text, uuid, text, text, text, numeric, numeric, numeric, numeric, jsonb, numeric, uuid) to anon, authenticated;
grant execute on function producto_eliminar(uuid) to anon, authenticated;
grant execute on function sucursal_guardar(text, uuid, text) to anon, authenticated;
grant execute on function sucursal_movimiento_registrar(uuid, text, numeric, text, text, text, text, numeric, numeric) to anon, authenticated;
grant execute on function sucursal_movimiento_eliminar(uuid) to anon, authenticated;
grant execute on function cotizacion_guardar(text, jsonb, text, text, numeric, numeric, numeric, numeric, numeric, integer, text) to anon, authenticated;
grant execute on function compra_proveedor_guardar(text, text, uuid, uuid, text, date, date, numeric, text, text, text) to anon, authenticated;
