-- ============================================================
-- MIGRACIÓN: Stock real por sucursal + traspasos atómicos
-- REFRIMAR OS
-- ------------------------------------------------------------
-- Cómo aplicar:
-- 1. Entra a tu proyecto de Supabase → SQL Editor → New Query
-- 2. Pega TODO este archivo y presiona "Run"
-- 3. Es seguro volver a correrlo (usa IF NOT EXISTS / OR REPLACE)
-- ============================================================

-- ------------------------------------------------------------
-- 0. "Casa Matriz" como sucursal virtual
-- ------------------------------------------------------------
-- Casa Matriz NO es una fila en la tabla `sucursales` (su stock
-- ya vive en `productos.stock`). Para poder tratarla igual que
-- cualquier otra sucursal en el selector y en las funciones de
-- traspaso, usamos un UUID fijo ("sentinel") que representa
-- "Casa Matriz" en el frontend. Este UUID nunca se inserta en
-- la tabla `sucursales`, las funciones de abajo lo detectan y
-- redirigen las operaciones a `productos.stock`.
--
-- UUID reservado: 00000000-0000-0000-0000-000000000001
-- (definido también en sucursal-selector.js como CASA_MATRIZ_ID)

-- ------------------------------------------------------------
-- 1. Tabla de stock por sucursal
-- ------------------------------------------------------------
create table if not exists sucursal_stock (
    id uuid primary key default gen_random_uuid(),
    sucursal_id uuid not null references sucursales(id) on delete cascade,
    producto_codigo text not null,
    producto_descripcion text,
    stock integer not null default 0,
    updated_at timestamptz not null default now(),
    unique (sucursal_id, producto_codigo)
);

create index if not exists idx_sucursal_stock_sucursal on sucursal_stock(sucursal_id);
create index if not exists idx_sucursal_stock_codigo on sucursal_stock(producto_codigo);

alter table sucursal_stock enable row level security;

drop policy if exists "sucursal_stock_select" on sucursal_stock;
create policy "sucursal_stock_select" on sucursal_stock for select using (true);
-- Los INSERT/UPDATE/DELETE de stock pasan SIEMPRE por las funciones
-- RPC de abajo (security definer), así que no exponemos policies de
-- escritura directas a anon/authenticated sobre esta tabla.

-- ------------------------------------------------------------
-- 2. Traspasar stock entre dos sucursales (o Casa Matriz) en
--    una sola transacción atómica.
-- ------------------------------------------------------------
-- Si algo falla a mitad de camino (stock insuficiente, producto
-- inexistente, error de red a mitad de función, etc.) Postgres
-- revierte TODO automáticamente porque es una única función
-- plpgsql: no puede quedar "a medias" (descontado en origen pero
-- no acreditado en destino), que es justo el problema que tenías
-- con los dos `update` separados desde el navegador.
create or replace function transferir_stock_sucursal(
    p_producto_codigo text,
    p_cantidad integer,
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
    v_stock_origen integer;
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

    -- Bloquea la fila del producto para evitar traspasos concurrentes
    -- sobre el mismo producto (evita condiciones de carrera de stock).
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
    -- Solo se registra deuda cuando Casa Matriz es el origen (es la
    -- relación comercial que ya manejaba tu sistema). Los traspasos
    -- entre dos sucursales no generan deuda, solo mueven stock.
    if p_sucursal_origen_id = v_casa_matriz then
        insert into sucursal_movimientos
            (sucursal_id, tipo, producto_codigo, producto_descripcion, cantidad, costo_unitario, monto, usuario_nombre)
        values
            (p_sucursal_destino_id, 'traspaso', p_producto_codigo, v_producto_descripcion, p_cantidad, p_costo_unitario, v_monto, p_usuario_nombre)
        returning id into v_movimiento_id;
    elsif p_sucursal_destino_id = v_casa_matriz then
        -- Devolución de una sucursal hacia Casa Matriz: se registra como
        -- movimiento negativo (abono en especie) en el kardex de esa sucursal.
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

grant execute on function transferir_stock_sucursal(text, integer, numeric, uuid, uuid, text) to anon, authenticated;

-- ------------------------------------------------------------
-- 3. Anular/revertir un traspaso ya registrado (también atómico)
-- ------------------------------------------------------------
create or replace function revertir_traspaso_sucursal(p_movimiento_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_casa_matriz uuid := '00000000-0000-0000-0000-000000000001';
    v_mov record;
begin
    select * into v_mov from sucursal_movimientos where id = p_movimiento_id for update;
    if not found then
        raise exception 'Movimiento no encontrado';
    end if;

    if v_mov.tipo = 'traspaso' and v_mov.producto_codigo is not null then
        -- Traspaso original fue Casa Matriz -> sucursal destino (v_mov.sucursal_id).
        -- Revertir = devolver cantidad de la sucursal a Casa Matriz.
        update sucursal_stock
        set stock = greatest(stock - v_mov.cantidad, 0), updated_at = now()
        where sucursal_id = v_mov.sucursal_id and producto_codigo = v_mov.producto_codigo;

        update productos set stock = stock + v_mov.cantidad where codigo = v_mov.producto_codigo;
    end if;

    delete from sucursal_movimientos where id = p_movimiento_id;

    return jsonb_build_object('ok', true);
end;
$$;

grant execute on function revertir_traspaso_sucursal(uuid) to anon, authenticated;
