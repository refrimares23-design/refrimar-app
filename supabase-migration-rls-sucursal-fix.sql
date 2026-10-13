-- ============================================================
-- REFRIMAR OS — FIX MULTI-SUCURSAL + ROLES (RLS / RPC)
-- ------------------------------------------------------------
-- Qué hace (idempotente: seguro volver a correrlo):
--   1. clientes y cotizaciones quedan atados a su sucursal
--      (columna sucursal_id + RPCs que la guardan).
--   2. detalle_venta: si una venta llega SIN costo (el empleado
--      ya no recibe costos en el POS), el costo se completa en el
--      servidor con el costo de la sucursal o el de Casa Matriz.
--      → Así los reportes de utilidad siguen exactos.
--   3. Índices por sucursal_id en las tablas que se filtran.
--   4. RLS: cierra la tabla chat_bot_estado (no tenía RLS) y
--      revoca escritura directa (anon) en tablas que solo se
--      escriben por RPC.
--
-- IMPORTANTE (límite real): el login es por PIN con la anon key,
-- no con Supabase Auth. Postgres NO sabe qué usuario/sucursal
-- hace cada petición, así que una policy RLS "empleado solo ve
-- su sucursal" no se puede hacer cumplir en la BD todavía. Hoy
-- se cumple en la app (filtros por sucursal + Permission Guard)
-- y en las RPC (toda escritura lleva p_sucursal_id). Al final
-- del archivo quedan las policies listas (comentadas) para el
-- día que el login pase a Supabase Auth con claims rol/sucursal.
--
-- CÓMO APLICAR — ANTES de subir la versión nueva de la app:
--   Supabase → SQL Editor → New query → pega TODO → Run
-- ============================================================

-- ------------------------------------------------------------
-- 1. Columnas sucursal_id faltantes
-- ------------------------------------------------------------
alter table clientes     add column if not exists sucursal_id uuid;
alter table cotizaciones add column if not exists sucursal_id uuid;

-- ------------------------------------------------------------
-- 2. cliente_guardar con sucursal (al editar, se conserva la
--    sucursal original del cliente)
-- ------------------------------------------------------------
drop function if exists cliente_guardar(text, uuid, text, text, text, text, text, numeric, text);

create or replace function cliente_guardar(
    p_nombre text,
    p_id uuid default null,
    p_rif text default null,
    p_telefono text default null,
    p_email text default null,
    p_direccion text default null,
    p_tipo text default 'final',
    p_limite_credito numeric default 0,
    p_notas text default null,
    p_sucursal_id uuid default null
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
    v_id uuid;
begin
    if p_nombre is null or trim(p_nombre) = '' then
        raise exception 'El nombre del cliente es obligatorio';
    end if;
    if p_limite_credito is null then p_limite_credito := 0; end if;

    if p_id is null then
        insert into clientes (nombre, rif, telefono, email, direccion, tipo,
            limite_credito, notas, sucursal_id)
        values (trim(p_nombre), p_rif, p_telefono, p_email, p_direccion,
            coalesce(p_tipo, 'final'), p_limite_credito, p_notas, p_sucursal_id)
        returning id into v_id;
    else
        update clientes
        set nombre = trim(p_nombre), rif = p_rif, telefono = p_telefono,
            email = p_email, direccion = p_direccion, tipo = coalesce(p_tipo, 'final'),
            limite_credito = p_limite_credito, notas = p_notas,
            sucursal_id = coalesce(sucursal_id, p_sucursal_id)
        where id = p_id;
        v_id := p_id;
    end if;

    if v_id is null then
        raise exception 'No se pudo guardar el cliente';
    end if;
    return v_id;
end;
$$;

grant execute on function cliente_guardar(text, uuid, text, text, text, text, text, numeric, text, uuid) to anon, authenticated;

-- ------------------------------------------------------------
-- 3. cotizacion_guardar con sucursal
-- ------------------------------------------------------------
drop function if exists cotizacion_guardar(text, jsonb, text, text, numeric, numeric, numeric, numeric, numeric, integer, text);

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
    p_estado text default 'pendiente',
    p_sucursal_id uuid default null
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
         tasa_bcv, total_bs, validez_dias, estado, sucursal_id)
    values
        (trim(p_numero),
         coalesce(nullif(trim(coalesce(p_cliente_nombre, '')), ''), 'Consumidor Final'),
         p_cliente_rif, coalesce(p_subtotal, 0), coalesce(p_iva, 0), coalesce(p_total_usd, 0),
         coalesce(p_tasa_bcv, 0), coalesce(p_total_bs, 0), coalesce(p_validez_dias, 7),
         coalesce(p_estado, 'pendiente'), p_sucursal_id)
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

grant execute on function cotizacion_guardar(text, jsonb, text, text, numeric, numeric, numeric, numeric, numeric, integer, text, uuid) to anon, authenticated;

-- ------------------------------------------------------------
-- 4. Costo de venta completado en el servidor
--    (el POS del empleado manda costo 0: nunca ve costos)
-- ------------------------------------------------------------
create or replace function detalle_venta_completar_costo()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
    v_casa uuid := '00000000-0000-0000-0000-000000000001';
    v_suc uuid;
    v_costo numeric;
begin
    if coalesce(new.costo_unitario, 0) > 0 then
        return new;
    end if;

    select sucursal_id into v_suc from ventas where id = new.venta_id;

    if v_suc is not null and v_suc <> v_casa then
        select costo into v_costo
        from sucursal_stock
        where sucursal_id = v_suc and producto_codigo = new.producto_codigo;
    end if;

    if coalesce(v_costo, 0) <= 0 then
        select costo into v_costo from productos where codigo = new.producto_codigo;
    end if;

    new.costo_unitario := coalesce(v_costo, 0);
    return new;
end;
$$;

drop trigger if exists trg_detalle_venta_costo on detalle_venta;
create trigger trg_detalle_venta_costo
    before insert on detalle_venta
    for each row execute function detalle_venta_completar_costo();

-- ------------------------------------------------------------
-- 5. Índices por sucursal (filtros de cada módulo)
-- ------------------------------------------------------------
create index if not exists idx_ventas_sucursal             on ventas(sucursal_id, created_at);
create index if not exists idx_caja_mov_sucursal           on caja_movimientos(sucursal_id, fecha);
create index if not exists idx_pagos_moviles_sucursal      on pagos_moviles(sucursal_id, fecha);
create index if not exists idx_clientes_sucursal           on clientes(sucursal_id);
create index if not exists idx_cotizaciones_sucursal       on cotizaciones(sucursal_id, created_at);
create index if not exists idx_gastos_sucursal             on gastos(sucursal_id, fecha);
create index if not exists idx_ordenes_compra_sucursal     on ordenes_compra(sucursal_id);
create index if not exists idx_kardex_mov_sucursal         on kardex_movimientos(sucursal_id);
create index if not exists idx_cierre_diario_sucursal      on cierre_diario(sucursal_id, fecha);
create index if not exists idx_abonos_ventas_sucursal      on abonos_ventas(sucursal_id);
create index if not exists idx_compras_proveedores_suc     on compras_proveedores(sucursal_id);
create index if not exists idx_abonos_compras_sucursal     on abonos_compras(sucursal_id);

-- ------------------------------------------------------------
-- 6. RLS: tablas que faltaban / escritura directa cerrada
-- ------------------------------------------------------------
-- chat_bot_estado no tenía RLS: cualquiera con la anon key podía
-- leer/escribir. Sus RPC son SECURITY DEFINER, así que siguen
-- funcionando con RLS activo y sin policies para anon.
do $$
begin
    if to_regclass('public.chat_bot_estado') is not null then
        execute 'alter table public.chat_bot_estado enable row level security';
        execute 'revoke all on public.chat_bot_estado from anon, authenticated';
    end if;
end $$;

-- Estas tablas solo se escriben por RPC (SECURITY DEFINER):
-- se revoca la escritura directa del rol anon/authenticated.
revoke insert, update, delete on
    gastos, ordenes_compra, compra_detalles, kardex_movimientos,
    cierre_diario, sucursal_stock, caja_movimientos, pagos_moviles,
    clientes, cotizaciones, detalle_cotizacion, abonos_ventas
from anon, authenticated;

grant select on
    gastos, ordenes_compra, compra_detalles, kardex_movimientos,
    cierre_diario, sucursal_stock, caja_movimientos, pagos_moviles,
    clientes, cotizaciones, detalle_cotizacion, abonos_ventas
to anon, authenticated;

-- ============================================================
-- 7. (FUTURO) Policies por sucursal con Supabase Auth
-- ------------------------------------------------------------
-- Actívalas SOLO cuando el login use Supabase Auth y el JWT
-- traiga app_metadata.rol y app_metadata.sucursal_id. Con la
-- anon key actual bloquearían TODA lectura, por eso van
-- comentadas. Patrón (repetir por tabla con sucursal_id):
--
-- create or replace function jwt_es_admin() returns boolean
-- language sql stable as $$
--   select coalesce(auth.jwt() -> 'app_metadata' ->> 'rol', '') = 'admin'
-- $$;
-- create or replace function jwt_sucursal() returns uuid
-- language sql stable as $$
--   select nullif(auth.jwt() -> 'app_metadata' ->> 'sucursal_id', '')::uuid
-- $$;
--
-- drop policy if exists "ventas_select" on ventas;
-- create policy "ventas_select_sucursal" on ventas for select
--   using (jwt_es_admin() or sucursal_id = jwt_sucursal()
--          or (sucursal_id is null and jwt_sucursal() = '00000000-0000-0000-0000-000000000001'));
--
-- Tablas: ventas, caja_movimientos, pagos_moviles, gastos,
-- cotizaciones, clientes, ordenes_compra, kardex_movimientos,
-- cierre_diario, abonos_ventas, compras_proveedores,
-- abonos_compras, sucursal_stock, sucursal_movimientos.
-- ============================================================
