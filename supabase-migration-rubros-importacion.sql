-- ============================================================
-- REFRIMAR — RUBRO DEL NEGOCIO + IMPORTACIÓN PROFESIONAL
-- ------------------------------------------------------------
-- Pega TODO en Supabase → SQL Editor → New query → Run.
-- Se puede correr varias veces. Requiere supabase-ACTUALIZAR-TODO.sql.
--
-- Qué agrega:
--   • configuracion.rubro (ferretería, supermercado, autopartes…)
--     y sus opciones (bloquear venta sin stock, retención de IVA…).
--   • Datos del rubro en cada producto (productos.atributos):
--     OEM, compatibilidad, lote, vencimiento, talla, color, IMEI…
--   • Importación en etapas: simulación sin guardar, lotes que
--     guardan "cómo estaba antes" y botón para DESHACER una importación.
-- ============================================================

-- ---------- 1. Rubro y opciones del negocio ----------
alter table configuracion add column if not exists rubro text not null default 'ferreteria';
alter table configuracion add column if not exists opciones jsonb not null default '{}'::jsonb;

create or replace function config_rubro_guardar(p_rubro text, p_opciones jsonb default null)
returns jsonb
language plpgsql security definer
set search_path = public
as $$
begin
    if p_rubro is null or p_rubro !~ '^[a-z_]{3,30}$' then raise exception 'Rubro inválido'; end if;
    update configuracion set rubro = p_rubro,
        opciones = case when jsonb_typeof(p_opciones) = 'object' then coalesce(opciones, '{}'::jsonb) || p_opciones else opciones end;
    if not found then
        insert into configuracion (rubro, opciones) values (p_rubro, coalesce(p_opciones, '{}'::jsonb));
    end if;
    return jsonb_build_object('ok', true, 'rubro', p_rubro);
end;
$$;
grant execute on function config_rubro_guardar(text, jsonb) to anon, authenticated;

-- ---------- 2. Datos del rubro en productos (se suman a productos.atributos) ----------
alter table productos add column if not exists atributos jsonb not null default '{}'::jsonb;
alter table productos add column if not exists requiere_serial boolean not null default false;
create index if not exists idx_productos_atributos on productos using gin (atributos);

create or replace function productos_importar_atributos(p_rows jsonb)
returns jsonb
language plpgsql security definer
set search_path = public
as $$
declare r jsonb; v_cod text; n int := 0; v_attr jsonb;
begin
    if p_rows is null or jsonb_typeof(p_rows) <> 'array' then return jsonb_build_object('ok', true, 'actualizados', 0); end if;
    for r in select value from jsonb_array_elements(p_rows) loop
        v_cod := nullif(trim(coalesce(r->>'codigo', '')), '');
        if v_cod is null then continue; end if;
        -- Solo se guardan los valores con texto (los vacíos no borran lo que ya había)
        select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) into v_attr
        from jsonb_each(case when jsonb_typeof(r->'atributos') = 'object' then r->'atributos' else '{}'::jsonb end)
        where coalesce(nullif(trim(value #>> '{}'), ''), null) is not null;
        update productos set
            atributos = coalesce(atributos, '{}'::jsonb) || v_attr,
            requiere_serial = case when r ? 'requiere_serial' then coalesce((r->>'requiere_serial')::boolean, requiere_serial) else requiere_serial end
        where codigo = v_cod;
        if found then n := n + 1; end if;
    end loop;
    return jsonb_build_object('ok', true, 'actualizados', n);
end;
$$;
grant execute on function productos_importar_atributos(jsonb) to anon, authenticated;

-- ---------- 3. Historial de importaciones con deshacer ----------
alter table importaciones_productos add column if not exists estado text not null default 'completada';
alter table importaciones_productos add column if not exists tipo text not null default 'productos';
alter table importaciones_productos add column if not exists duracion_ms int;
alter table importaciones_productos add column if not exists deshecha_at timestamptz;
alter table importaciones_productos add column if not exists deshecha_por text;
alter table importaciones_productos add column if not exists deshacer_resumen jsonb;

create table if not exists importacion_cambios (
    id bigserial primary key,
    importacion_id uuid not null references importaciones_productos(id) on delete cascade,
    codigo text not null,
    accion text not null,              -- creado | actualizado
    antes jsonb,                       -- fila completa del producto antes de importar
    sucursal_id uuid,
    stock_antes numeric,
    stock_despues numeric,
    created_at timestamptz not null default now()
);
create index if not exists idx_imp_cambios on importacion_cambios(importacion_id);
alter table importacion_cambios enable row level security;
revoke all on importacion_cambios from anon, authenticated;

create or replace function importacion_iniciar(p_archivo text, p_sucursal_id uuid, p_sucursal_nombre text, p_usuario text, p_modo_stock text, p_filas int, p_tipo text default 'productos')
returns jsonb
language plpgsql security definer
set search_path = public
as $$
declare v_id uuid;
begin
    insert into importaciones_productos (archivo, sucursal_id, sucursal_nombre, usuario_nombre, modo_stock, filas, estado, tipo)
    values (left(p_archivo, 200), p_sucursal_id, p_sucursal_nombre, p_usuario, p_modo_stock, coalesce(p_filas, 0), 'en_curso', coalesce(p_tipo, 'productos'))
    returning id into v_id;
    return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

-- Un lote: guarda cómo estaba cada producto, importa y anota el stock final
create or replace function productos_importar_lote(p_importacion_id uuid, p_rows jsonb, p_sucursal_id uuid default null,
    p_modo_stock text default 'reemplazar', p_actualizar boolean default true, p_usuario text default 'Sistema')
returns jsonb
language plpgsql security definer
set search_path = public
as $$
declare
    v_suc uuid := case when p_sucursal_id = '00000000-0000-0000-0000-000000000001' then null else p_sucursal_id end;
    v_codigos text[]; v_res jsonb;
begin
    if not exists (select 1 from importaciones_productos where id = p_importacion_id and estado = 'en_curso') then
        raise exception 'La importación no está abierta';
    end if;
    select array_agg(distinct c) into v_codigos from (
        select coalesce(nullif(trim(coalesce(value->>'codigo', '')), ''), nullif(trim(coalesce(value->>'barra', '')), '')) c
        from jsonb_array_elements(p_rows)) x where c is not null;
    v_codigos := coalesce(v_codigos, '{}');

    -- Estado anterior (solo la primera vez que aparece el código en esta importación)
    insert into importacion_cambios (importacion_id, codigo, accion, antes, sucursal_id, stock_antes)
    select p_importacion_id, p.codigo, 'actualizado', to_jsonb(p), v_suc, stock_en(p.codigo, p_sucursal_id)
    from productos p
    where p.codigo = any (v_codigos)
      and not exists (select 1 from importacion_cambios c where c.importacion_id = p_importacion_id and c.codigo = p.codigo);

    v_res := productos_importar(p_rows, p_sucursal_id, p_modo_stock, p_actualizar, p_usuario);

    -- Productos nuevos
    insert into importacion_cambios (importacion_id, codigo, accion, sucursal_id, stock_antes)
    select p_importacion_id, p.codigo, 'creado', v_suc, 0
    from productos p
    where p.codigo = any (v_codigos)
      and not exists (select 1 from importacion_cambios c where c.importacion_id = p_importacion_id and c.codigo = p.codigo);

    update importacion_cambios c set stock_despues = stock_en(c.codigo, p_sucursal_id)
    where c.importacion_id = p_importacion_id and c.codigo = any (v_codigos);

    return v_res;
end;
$$;

create or replace function importacion_finalizar(p_id uuid, p_creados int, p_actualizados int, p_omitidos int, p_errores jsonb, p_duracion_ms int)
returns jsonb
language plpgsql security definer
set search_path = public
as $$
begin
    update importaciones_productos set
        estado = 'completada', creados = coalesce(p_creados, 0), actualizados = coalesce(p_actualizados, 0), omitidos = coalesce(p_omitidos, 0),
        errores = case when jsonb_typeof(p_errores) = 'array' then jsonb_array_length(p_errores) else 0 end,
        detalle_errores = case when jsonb_typeof(p_errores) = 'array' then p_errores else '[]'::jsonb end,
        duracion_ms = p_duracion_ms
    where id = p_id;
    return jsonb_build_object('ok', true);
end;
$$;

-- Simulación: hace la importación de verdad y la deshace al final (no queda nada guardado)
create or replace function productos_importar_simular(p_rows jsonb, p_sucursal_id uuid default null, p_modo_stock text default 'reemplazar', p_actualizar boolean default true)
returns jsonb
language plpgsql security definer
set search_path = public
as $$
declare v_res jsonb;
begin
    begin
        v_res := productos_importar(p_rows, p_sucursal_id, p_modo_stock, p_actualizar, 'Simulación');
        raise exception using errcode = 'P0099', message = 'simulacion';
    exception when sqlstate 'P0099' then
        null;   -- todo lo hecho dentro del bloque se revierte
    end;
    return coalesce(v_res, '{}'::jsonb) || jsonb_build_object('simulacion', true);
end;
$$;

-- Deshacer: devuelve los productos actualizados a como estaban, desactiva los creados
-- (no se borran para no perder historial) y revierte el stock que movió la importación
-- (respetando las ventas que se hicieron después).
create or replace function importacion_deshacer(p_id uuid, p_usuario text default 'Sistema')
returns jsonb
language plpgsql security definer
set search_path = public
as $$
declare
    imp record; c record; v_cols text; v_actual numeric; v_nuevo numeric; v_delta numeric;
    n_rest int := 0; n_desact int := 0; n_stock int := 0;
begin
    select * into imp from importaciones_productos where id = p_id for update;
    if not found then raise exception 'Importación no encontrada'; end if;
    if imp.deshecha_at is not null then raise exception 'Esta importación ya se deshizo'; end if;
    if not exists (select 1 from importacion_cambios where importacion_id = p_id) then
        raise exception 'Esta importación se hizo antes de poder deshacer (no tiene respaldo)';
    end if;

    select string_agg(quote_ident(column_name), ', ' order by ordinal_position) into v_cols
    from information_schema.columns
    where table_schema = 'public' and table_name = 'productos'
      and column_name not in ('id', 'codigo', 'stock', 'created_at') and is_generated = 'NEVER';

    for c in select * from importacion_cambios where importacion_id = p_id order by id loop
        if c.accion = 'actualizado' and c.antes is not null then
            execute format('update productos p set (%s) = (select %s from jsonb_populate_record(null::productos, $1) x) where p.codigo = $2',
                           v_cols, regexp_replace(v_cols, '(^|, )', '\1x.', 'g'))
            using c.antes, c.codigo;
            n_rest := n_rest + 1;
        elsif c.accion = 'creado' then
            update productos set activo = false where codigo = c.codigo;
            n_desact := n_desact + 1;
        end if;
        -- Stock: se quita solo lo que movió la importación
        if c.stock_despues is not null and c.stock_antes is not null and c.stock_despues <> c.stock_antes then
            v_actual := stock_en(c.codigo, c.sucursal_id);
            v_delta := -(c.stock_despues - c.stock_antes);
            v_nuevo := v_actual + v_delta;
            if c.sucursal_id is null then
                update productos set stock = v_nuevo where codigo = c.codigo;
            else
                update sucursal_stock set stock = v_nuevo, updated_at = now() where sucursal_id = c.sucursal_id and producto_codigo = c.codigo;
            end if;
            insert into kardex_movimientos (producto_codigo, producto_descripcion, fecha, tipo, cantidad, costo_unitario, costo_total,
                saldo_cantidad, saldo_costo_promedio, referencia, usuario_nombre, sucursal_id)
            select c.codigo, p.descripcion, current_date, case when v_delta > 0 then 'entrada_ajuste' else 'salida_ajuste' end, v_delta,
                   coalesce(p.costo, 0), abs(v_delta) * coalesce(p.costo, 0), v_nuevo, coalesce(p.costo, 0),
                   'Deshacer importación ' || coalesce(imp.archivo, ''), coalesce(p_usuario, 'Sistema'), c.sucursal_id
            from productos p where p.codigo = c.codigo;
            n_stock := n_stock + 1;
        end if;
    end loop;

    update importaciones_productos set estado = 'deshecha', deshecha_at = now(), deshecha_por = p_usuario,
        deshacer_resumen = jsonb_build_object('restaurados', n_rest, 'desactivados', n_desact, 'stock', n_stock)
    where id = p_id;
    return jsonb_build_object('ok', true, 'restaurados', n_rest, 'desactivados', n_desact, 'stock', n_stock);
end;
$$;

grant execute on function importacion_iniciar(text, uuid, text, text, text, int, text) to anon, authenticated;
grant execute on function productos_importar_lote(uuid, jsonb, uuid, text, boolean, text) to anon, authenticated;
grant execute on function importacion_finalizar(uuid, int, int, int, jsonb, int) to anon, authenticated;
grant execute on function productos_importar_simular(jsonb, uuid, text, boolean) to anon, authenticated;
grant execute on function importacion_deshacer(uuid, text) to anon, authenticated;

-- Seguridad (si ya corriste supabase-migration-seguridad.sql)
do $$ begin
    if to_regclass('public.seguridad_rpc') is not null then
        insert into seguridad_rpc (nombre, nivel, permiso) values
            ('config_rubro_guardar', 'permiso', 'configuracion'),
            ('productos_importar_atributos', 'permiso', 'importar_productos'),
            ('importacion_iniciar', 'permiso', 'importar_productos'),
            ('productos_importar_lote', 'permiso', 'importar_productos'),
            ('importacion_finalizar', 'permiso', 'importar_productos'),
            ('productos_importar_simular', 'permiso', 'importar_productos'),
            ('importacion_deshacer', 'permiso', 'importar_productos')
        on conflict (nombre) do update set nivel = excluded.nivel, permiso = excluded.permiso;
    end if;
end $$;

notify pgrst, 'reload schema';
select 'Rubros e importación listos' as resultado;
