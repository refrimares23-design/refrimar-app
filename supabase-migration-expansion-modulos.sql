-- ============================================================
-- MIGRACIÓN: Módulos Compras, Kardex y Gastos + Dashboard
-- REFRIMAR OS
-- ------------------------------------------------------------
-- Cómo aplicar:
-- 1. Supabase → SQL Editor → New query
-- 2. Pega TODO este archivo y presiona "Run"
-- 3. Es seguro volver a correrlo (usa IF NOT EXISTS / OR REPLACE)
--
-- Aplica ANTES de desplegar el frontend.
-- Requiere que ya estén aplicadas las migraciones:
--   - supabase-migration-sucursales.sql  (tabla sucursal_stock)
--   - supabase-migration-compras-proveedores.sql (compras_proveedores)
-- ============================================================

-- ------------------------------------------------------------
-- 1. PROVEEDORES (catálogo maestro)
-- ------------------------------------------------------------
create table if not exists proveedores (
    id uuid primary key default gen_random_uuid(),
    nombre text not null,
    rif text,
    telefono text,
    direccion text,
    email text,
    created_at timestamptz not null default now()
);

alter table proveedores enable row level security;

drop policy if exists "proveedores_select" on proveedores;
create policy "proveedores_select" on proveedores for select using (true);

drop policy if exists "proveedores_insert" on proveedores;
create policy "proveedores_insert" on proveedores for insert with check (true);

drop policy if exists "proveedores_update" on proveedores;
create policy "proveedores_update" on proveedores for update using (true) with check (true);

drop policy if exists "proveedores_delete" on proveedores;
create policy "proveedores_delete" on proveedores for delete using (true);

-- ------------------------------------------------------------
-- 2. ÓRDENES DE COMPRA (cabecera + detalles)
--    Los INSERT pasan SIEMPRE por compra_registrar (atómico).
-- ------------------------------------------------------------
create table if not exists ordenes_compra (
    id uuid primary key default gen_random_uuid(),
    numero text not null unique,
    proveedor_id uuid references proveedores(id) on delete set null,
    proveedor_nombre text,
    fecha date not null default current_date,
    estado text not null default 'recibida',
    subtotal numeric not null default 0,
    notas text,
    usuario_nombre text,
    sucursal_id uuid,
    sucursal_nombre text,
    recibida_at timestamptz not null default now(),
    created_at timestamptz not null default now()
);

create table if not exists compra_detalles (
    id uuid primary key default gen_random_uuid(),
    compra_id uuid not null references ordenes_compra(id) on delete cascade,
    producto_codigo text not null,
    descripcion text,
    cantidad numeric not null default 0,
    costo_unitario numeric not null default 0,
    subtotal numeric not null default 0,
    created_at timestamptz not null default now()
);

create index if not exists idx_ordenes_compra_proveedor on ordenes_compra(proveedor_id);
create index if not exists idx_compra_detalles_compra on compra_detalles(compra_id);

alter table ordenes_compra enable row level security;
alter table compra_detalles enable row level security;

drop policy if exists "ordenes_compra_select" on ordenes_compra;
create policy "ordenes_compra_select" on ordenes_compra for select using (true);

drop policy if exists "compra_detalles_select" on compra_detalles;
create policy "compra_detalles_select" on compra_detalles for select using (true);

-- ------------------------------------------------------------
-- 3. GASTOS (operativos) + categorías
-- ------------------------------------------------------------
create table if not exists gasto_categorias (
    id uuid primary key default gen_random_uuid(),
    nombre text not null unique,
    created_at timestamptz not null default now()
);

create table if not exists gastos (
    id uuid primary key default gen_random_uuid(),
    categoria text not null,
    concepto text not null,
    monto_usd numeric not null default 0,
    monto_bs numeric not null default 0,
    fecha date not null default current_date,
    metodo_pago text default 'efectivo',
    usuario_nombre text,
    sucursal_id uuid,
    notas text,
    caja_movimiento_id uuid,
    created_at timestamptz not null default now()
);

create index if not exists idx_gastos_fecha on gastos(fecha);
create index if not exists idx_gastos_categoria on gastos(categoria);

alter table gastos enable row level security;
alter table gasto_categorias enable row level security;

drop policy if exists "gastos_select" on gastos;
create policy "gastos_select" on gastos for select using (true);

drop policy if exists "gasto_categorias_select" on gasto_categorias;
create policy "gasto_categorias_select" on gasto_categorias for select using (true);

drop policy if exists "gasto_categorias_insert" on gasto_categorias;
create policy "gasto_categorias_insert" on gasto_categorias for insert with check (true);

drop policy if exists "gasto_categorias_delete" on gasto_categorias;
create policy "gasto_categorias_delete" on gasto_categorias for delete using (true);

-- Categorías por defecto (solo si la tabla está vacía)
insert into gasto_categorias (nombre)
select unnest(array['Servicios','Nómina','Alquiler','Combustible','Impuestos','Transporte','Mantenimiento','Publicidad','Otros'])
where not exists (select 1 from gasto_categorias);

-- ------------------------------------------------------------
-- 4. KARDEX (movimientos de inventario con costo promedio)
--    Las salidas por VENTA se calculan desde detalle_venta
--    (join a ventas no anuladas); aquí solo se registran:
--    entradas de compra, ajustes de entrada y salida.
-- ------------------------------------------------------------
create table if not exists kardex_movimientos (
    id uuid primary key default gen_random_uuid(),
    producto_codigo text not null,
    producto_descripcion text,
    fecha date not null default current_date,
    tipo text not null,
    cantidad numeric not null default 0,
    costo_unitario numeric not null default 0,
    costo_total numeric not null default 0,
    saldo_cantidad numeric not null default 0,
    saldo_costo_promedio numeric not null default 0,
    referencia text,
    usuario_nombre text,
    sucursal_id uuid,
    created_at timestamptz not null default now()
);

create index if not exists idx_kardex_producto on kardex_movimientos(producto_codigo, fecha);
create index if not exists idx_kardex_sucursal on kardex_movimientos(sucursal_id);

alter table kardex_movimientos enable row level security;

drop policy if exists "kardex_movimientos_select" on kardex_movimientos;
create policy "kardex_movimientos_select" on kardex_movimientos for select using (true);

-- ------------------------------------------------------------
-- 5. RPC: COMPRA REGISTRAR (recepción atómica)
--    - Inserta orden_compra + detalles
--    - Actualiza stock en Casa Matriz (productos) o sucursal
--    - Actualiza costo promedio global (productos.costo)
--    - Escribe kardex de entrada
--    Si algo falla, revierte TODO.
-- ------------------------------------------------------------
create or replace function compra_registrar(
    p_proveedor_id uuid,
    p_proveedor_nombre text,
    p_fecha date,
    p_notas text,
    p_sucursal_id uuid,
    p_sucursal_nombre text,
    p_usuario text,
    p_items jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_casa uuid := '00000000-0000-0000-0000-000000000001';
    v_numero text;
    v_compra_id uuid;
    v_item jsonb;
    v_codigo text;
    v_desc text;
    v_cant numeric;
    v_costo numeric;
    v_subtotal numeric := 0;
    v_total numeric := 0;
    v_stock_actual numeric;
    v_costo_actual numeric;
    v_nuevo_stock numeric;
    v_nuevo_costo numeric;
    v_contador integer;
begin
    -- Número de orden: OC-YYYYMMDD-XXXXXX
    select coalesce(count(*), 0) into v_contador from ordenes_compra where numero like 'OC-' || to_char(coalesce(p_fecha, current_date), 'YYYYMMDD') || '-%';
    v_numero := 'OC-' || to_char(coalesce(p_fecha, current_date), 'YYYYMMDD') || '-' || lpad((v_contador + 1)::text, 6, '0');

    -- Validar que haya al menos un item
    if p_items is null or jsonb_array_length(p_items) = 0 then
        raise exception 'Debe incluir al menos un producto en la compra';
    end if;

    insert into ordenes_compra (numero, proveedor_id, proveedor_nombre, fecha, notas, usuario_nombre, sucursal_id, sucursal_nombre)
    values (v_numero, p_proveedor_id, p_proveedor_nombre, coalesce(p_fecha, current_date), p_notas, p_usuario, p_sucursal_id, p_sucursal_nombre)
    returning id into v_compra_id;

    for v_item in select * from jsonb_array_elements(p_items)
    loop
        v_codigo := coalesce(v_item->>'codigo', '');
        v_cant := coalesce((v_item->>'cantidad')::numeric, 0);
        v_costo := coalesce((v_item->>'costo_unitario')::numeric, 0);

        if v_codigo = '' or v_cant <= 0 then
            raise exception 'Producto inválido en la compra';
        end if;

        select descripcion, coalesce(costo, 0) into v_desc, v_costo_actual
        from productos where codigo = v_codigo;

        if not found then
            raise exception 'Producto % no existe', v_codigo;
        end if;

        v_subtotal := v_cant * v_costo;

        -- ---- Stock según ubicación ----
        if p_sucursal_id is null or p_sucursal_id = v_casa then
            select coalesce(stock, 0) into v_stock_actual from productos where codigo = v_codigo;
            v_nuevo_stock := v_stock_actual + v_cant;
            update productos set stock = v_nuevo_stock where codigo = v_codigo;
        else
            select coalesce(stock, 0) into v_stock_actual from sucursal_stock where sucursal_id = p_sucursal_id and producto_codigo = v_codigo;
            v_nuevo_stock := v_stock_actual + v_cant;
            insert into sucursal_stock (sucursal_id, producto_codigo, producto_descripcion, stock)
            values (p_sucursal_id, v_codigo, coalesce(v_desc, v_codigo), v_cant)
            on conflict (sucursal_id, producto_codigo)
            do update set stock = sucursal_stock.stock + excluded.stock, producto_descripcion = excluded.producto_descripcion, updated_at = now();
        end if;

        -- ---- Costo promedio ponderado global ----
        if v_costo > 0 then
            select coalesce(stock, 0) into v_stock_actual from productos where codigo = v_codigo;
            if v_stock_actual + v_cant > 0 then
                v_nuevo_costo := (v_stock_actual * v_costo_actual + v_cant * v_costo) / (v_stock_actual + v_cant);
                update productos set costo = v_nuevo_costo where codigo = v_codigo;
            end if;
        else
            select coalesce(costo, 0) into v_nuevo_costo from productos where codigo = v_codigo;
        end if;

        insert into compra_detalles (compra_id, producto_codigo, descripcion, cantidad, costo_unitario, subtotal)
        values (v_compra_id, v_codigo, coalesce(v_desc, v_codigo), v_cant, v_costo, v_subtotal);

        insert into kardex_movimientos (producto_codigo, producto_descripcion, fecha, tipo, cantidad, costo_unitario, costo_total, saldo_cantidad, saldo_costo_promedio, referencia, usuario_nombre, sucursal_id)
        values (v_codigo, coalesce(v_desc, v_codigo), coalesce(p_fecha, current_date), 'entrada_compra', v_cant, v_costo, v_subtotal, v_nuevo_stock, v_nuevo_costo, v_numero, p_usuario, p_sucursal_id);

        v_total := v_total + v_subtotal;
    end loop;

    update ordenes_compra set subtotal = v_total where id = v_compra_id;

    return jsonb_build_object('ok', true, 'compra_id', v_compra_id, 'numero', v_numero, 'total', v_total);
end;
$$;

grant execute on function compra_registrar(uuid, text, date, text, uuid, text, text, jsonb) to anon, authenticated;

-- ------------------------------------------------------------
-- 6. RPC: GASTO REGISTRAR (inserta gasto + egreso de caja)
-- ------------------------------------------------------------
create or replace function gasto_registrar(
    p_categoria text,
    p_concepto text,
    p_monto_usd numeric,
    p_monto_bs numeric,
    p_fecha date,
    p_metodo_pago text,
    p_sucursal_id uuid,
    p_usuario text,
    p_notas text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_gasto_id uuid;
    v_caja_id uuid;
begin
    if p_concepto is null or trim(p_concepto) = '' then
        raise exception 'El concepto es obligatorio';
    end if;
    if coalesce(p_monto_usd, 0) <= 0 and coalesce(p_monto_bs, 0) <= 0 then
        raise exception 'Debe indicar un monto';
    end if;

    -- Egreso de caja (solo el monto principal definido; si ambos, prioriza USD)
    insert into caja_movimientos (tipo, concepto, monto_usd, monto_bs, sucursal_id, usuario_nombre, metodo_pago)
    values (
        'egreso',
        'Gasto (' || p_categoria || '): ' || p_concepto,
        coalesce(p_monto_usd, 0),
        coalesce(p_monto_bs, 0),
        p_sucursal_id,
        coalesce(p_usuario, 'Sistema'),
        coalesce(p_metodo_pago, 'efectivo')
    )
    returning id into v_caja_id;

    insert into gastos (categoria, concepto, monto_usd, monto_bs, fecha, metodo_pago, usuario_nombre, sucursal_id, notas, caja_movimiento_id)
    values (p_categoria, p_concepto, coalesce(p_monto_usd, 0), coalesce(p_monto_bs, 0), coalesce(p_fecha, current_date), coalesce(p_metodo_pago, 'efectivo'), p_usuario, p_sucursal_id, p_notas, v_caja_id)
    returning id into v_gasto_id;

    return jsonb_build_object('ok', true, 'gasto_id', v_gasto_id);
end;
$$;

grant execute on function gasto_registrar(text, text, numeric, numeric, date, text, uuid, text, text) to anon, authenticated;

-- ------------------------------------------------------------
-- 7. RPC: GASTO ELIMINAR (borra gasto + su egreso de caja)
-- ------------------------------------------------------------
create or replace function gasto_eliminar(p_gasto_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_caja_id uuid;
begin
    select caja_movimiento_id into v_caja_id from gastos where id = p_gasto_id;

    if not found then
        raise exception 'Gasto no encontrado';
    end if;

    delete from gastos where id = p_gasto_id;

    if v_caja_id is not null then
        delete from caja_movimientos where id = v_caja_id;
    end if;

    return jsonb_build_object('ok', true);
end;
$$;

grant execute on function gasto_eliminar(uuid) to anon, authenticated;

-- ------------------------------------------------------------
-- 8. RPC: KARDEX AJUSTE (entrada/salida manual atómica)
-- ------------------------------------------------------------
create or replace function kardex_ajuste(
    p_producto_codigo text,
    p_tipo text,
    p_cantidad numeric,
    p_costo_unitario numeric,
    p_concepto text,
    p_sucursal_id uuid,
    p_usuario text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_casa uuid := '00000000-0000-0000-0000-000000000001';
    v_desc text;
    v_stock_actual numeric;
    v_costo_actual numeric;
    v_nuevo_stock numeric;
    v_nuevo_costo numeric;
    v_kardex_tipo text;
begin
    if p_producto_codigo is null or p_producto_codigo = '' then
        raise exception 'Debe indicar un producto';
    end if;
    if p_cantidad is null or p_cantidad <= 0 then
        raise exception 'La cantidad debe ser mayor a cero';
    end if;
    if p_tipo not in ('entrada', 'salida') then
        raise exception 'Tipo debe ser entrada o salida';
    end if;

    select descripcion, coalesce(costo, 0) into v_desc, v_costo_actual
    from productos where codigo = p_producto_codigo;

    if not found then
        raise exception 'Producto % no existe', p_producto_codigo;
    end if;

    v_kardex_tipo := case when p_tipo = 'entrada' then 'entrada_ajuste' else 'salida_ajuste' end;

    -- Stock según ubicación
    if p_sucursal_id is null or p_sucursal_id = v_casa then
        select coalesce(stock, 0) into v_stock_actual from productos where codigo = p_producto_codigo;
        if p_tipo = 'salida' and v_stock_actual < p_cantidad then
            raise exception 'Stock insuficiente (actual: %)', v_stock_actual;
        end if;
        v_nuevo_stock := case when p_tipo = 'entrada' then v_stock_actual + p_cantidad else v_stock_actual - p_cantidad end;
        update productos set stock = v_nuevo_stock where codigo = p_producto_codigo;
    else
        select coalesce(stock, 0) into v_stock_actual from sucursal_stock where sucursal_id = p_sucursal_id and producto_codigo = p_producto_codigo;
        if p_tipo = 'salida' and v_stock_actual < p_cantidad then
            raise exception 'Stock insuficiente (actual: %)', v_stock_actual;
        end if;
        v_nuevo_stock := case when p_tipo = 'entrada' then v_stock_actual + p_cantidad else v_stock_actual - p_cantidad end;
        insert into sucursal_stock (sucursal_id, producto_codigo, producto_descripcion, stock)
        values (p_sucursal_id, p_producto_codigo, coalesce(v_desc, p_producto_codigo), v_nuevo_stock)
        on conflict (sucursal_id, producto_codigo)
        do update set stock = excluded.stock, producto_descripcion = excluded.producto_descripcion, updated_at = now();
    end if;

    -- Costo promedio ponderado en entrada con costo informado
    if p_tipo = 'entrada' and coalesce(p_costo_unitario, 0) > 0 then
        select coalesce(stock, 0) into v_stock_actual from productos where codigo = p_producto_codigo;
        if v_stock_actual > 0 then
            v_nuevo_costo := (v_stock_actual * v_costo_actual + p_cantidad * p_costo_unitario) / (v_stock_actual + p_cantidad);
            update productos set costo = v_nuevo_costo where codigo = p_producto_codigo;
        else
            v_nuevo_costo := p_costo_unitario;
            update productos set costo = p_costo_unitario where codigo = p_producto_codigo;
        end if;
    else
        select coalesce(costo, 0) into v_nuevo_costo from productos where codigo = p_producto_codigo;
    end if;

    insert into kardex_movimientos (producto_codigo, producto_descripcion, fecha, tipo, cantidad, costo_unitario, costo_total, saldo_cantidad, saldo_costo_promedio, referencia, usuario_nombre, sucursal_id)
    values (p_producto_codigo, coalesce(v_desc, p_producto_codigo), current_date, v_kardex_tipo,
            case when p_tipo = 'entrada' then p_cantidad else -p_cantidad end,
            coalesce(p_costo_unitario, 0),
            case when p_tipo = 'entrada' then p_cantidad * coalesce(p_costo_unitario, 0) else p_cantidad * v_costo_actual end,
            v_nuevo_stock, v_nuevo_costo,
            coalesce(p_concepto, v_kardex_tipo), p_usuario, p_sucursal_id);

    return jsonb_build_object('ok', true, 'stock', v_nuevo_stock, 'costo_promedio', v_nuevo_costo);
end;
$$;

grant execute on function kardex_ajuste(text, text, numeric, numeric, text, uuid, text) to anon, authenticated;

-- ============================================================
-- FIN
-- ============================================================
