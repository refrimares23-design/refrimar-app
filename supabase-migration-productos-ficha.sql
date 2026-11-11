-- ============================================================
-- REFRIMAR — FICHA COMPLETA DE PRODUCTO (estilo Norkut)
-- ------------------------------------------------------------
-- Qué agrega (idempotente: seguro volver a correrlo):
--   • Ficha de producto: SKU, descripción larga, tipo (físico /
--     servicio), IVA por producto, pesable + código de balanza,
--     referencia interna, estatus (borrador/activo/inactivo),
--     clasificación, origen, medidas, presentación, empaques,
--     impuestos adicionales, proveedores, atributos y otras
--     referencias (fábrica, CPE, registro sanitario).
--   • Fotos del producto (tabla aparte para que las listas
--     sigan cargando rápido).
--   • Servicios: no llevan inventario (se pueden vender siempre).
--   • Histórico de importaciones de Excel.
--   • Tasa: guarda qué usuario la cambió.
--   • La importación de Excel ahora también lee el IVA.
--
-- CÓMO APLICAR: Supabase → SQL Editor → New query → pega TODO → Run
-- ============================================================

-- ------------------------------------------------------------
-- 1. Columnas nuevas de productos
-- ------------------------------------------------------------
alter table productos add column if not exists sku text;
alter table productos add column if not exists detalle text;
alter table productos add column if not exists tipo_producto text not null default 'fisico';
alter table productos add column if not exists iva_tasa numeric not null default 16;
alter table productos add column if not exists sensible boolean not null default false;
alter table productos add column if not exists requiere_serial boolean not null default false;
alter table productos add column if not exists pesable boolean not null default false;
alter table productos add column if not exists codigo_balanza text;
alter table productos add column if not exists referencia_interna text;
alter table productos add column if not exists estatus text not null default 'activo';
alter table productos add column if not exists clasificacion text;
alter table productos add column if not exists origen text;
alter table productos add column if not exists tipo_medida text;
alter table productos add column if not exists medida text;
alter table productos add column if not exists presentacion text;
alter table productos add column if not exists empaques jsonb not null default '[]'::jsonb;
alter table productos add column if not exists impuestos_extra jsonb not null default '[]'::jsonb;
alter table productos add column if not exists proveedores text[] not null default '{}';
alter table productos add column if not exists atributos jsonb not null default '{}'::jsonb;
alter table productos add column if not exists ref_fabrica text;
alter table productos add column if not exists cpe text;
alter table productos add column if not exists registro_sanitario text;
alter table productos add column if not exists variante_grupo text;
alter table productos add column if not exists updated_at timestamptz default now();

-- estatus coherente con "activo" para los productos que ya existían
update productos set estatus = 'inactivo' where activo = false and estatus = 'activo';

create index if not exists idx_productos_sku on productos(sku);
create index if not exists idx_productos_variante on productos(variante_grupo);

-- ------------------------------------------------------------
-- 2. Fotos (hasta 4 por producto, comprimidas en el navegador)
-- ------------------------------------------------------------
create table if not exists producto_imagenes (
    producto_codigo text primary key,
    imagenes jsonb not null default '[]'::jsonb,
    updated_at timestamptz not null default now()
);
alter table producto_imagenes enable row level security;
drop policy if exists "producto_imagenes_select" on producto_imagenes;
create policy "producto_imagenes_select" on producto_imagenes for select using (true);
revoke insert, update, delete on producto_imagenes from anon, authenticated;
grant select on producto_imagenes to anon, authenticated;

create or replace function producto_imagenes_guardar(p_codigo text, p_imagenes jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
    if not exists (select 1 from productos where codigo = p_codigo) then
        raise exception 'Producto % no existe', p_codigo;
    end if;
    if p_imagenes is null or jsonb_typeof(p_imagenes) <> 'array' then p_imagenes := '[]'::jsonb; end if;
    if jsonb_array_length(p_imagenes) > 4 then raise exception 'Máximo 4 fotos por producto'; end if;
    if length(p_imagenes::text) > 1500000 then raise exception 'Las fotos pesan demasiado'; end if;
    insert into producto_imagenes (producto_codigo, imagenes, updated_at)
    values (p_codigo, p_imagenes, now())
    on conflict (producto_codigo) do update set imagenes = excluded.imagenes, updated_at = now();
    return jsonb_build_object('ok', true);
end;
$$;

-- ------------------------------------------------------------
-- 3. Guardar la ficha completa (se llama después de producto_guardar)
-- ------------------------------------------------------------
create or replace function producto_ficha_guardar(p_codigo text, p_ficha jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    f jsonb := coalesce(p_ficha, '{}'::jsonb);
    v_tipo text;
    v_estatus text;
    v_iva numeric;
    v_tipo_antes text;
begin
    select tipo_producto into v_tipo_antes from productos where codigo = p_codigo;
    if not found then
        raise exception 'Producto % no existe', p_codigo;
    end if;

    v_tipo := coalesce(nullif(f->>'tipo_producto', ''), 'fisico');
    if v_tipo not in ('fisico', 'servicio') then v_tipo := 'fisico'; end if;
    v_estatus := coalesce(nullif(f->>'estatus', ''), 'activo');
    if v_estatus not in ('borrador', 'activo', 'inactivo') then v_estatus := 'activo'; end if;
    v_iva := coalesce(nullif(f->>'iva_tasa', '')::numeric, 16);
    if v_iva < 0 or v_iva > 100 then raise exception 'IVA inválido'; end if;

    update productos set
        sku = nullif(trim(coalesce(f->>'sku', '')), ''),
        detalle = nullif(trim(coalesce(f->>'detalle', '')), ''),
        subcategoria = nullif(trim(coalesce(f->>'subcategoria', '')), ''),
        tipo_producto = v_tipo,
        iva_tasa = v_iva,
        sensible = coalesce((f->>'sensible')::boolean, false),
        requiere_serial = coalesce((f->>'requiere_serial')::boolean, false),
        pesable = coalesce((f->>'pesable')::boolean, false),
        codigo_balanza = nullif(trim(coalesce(f->>'codigo_balanza', '')), ''),
        referencia_interna = nullif(trim(coalesce(f->>'referencia_interna', '')), ''),
        estatus = v_estatus,
        activo = (v_estatus = 'activo'),
        clasificacion = nullif(trim(coalesce(f->>'clasificacion', '')), ''),
        origen = nullif(trim(coalesce(f->>'origen', '')), ''),
        tipo_medida = nullif(trim(coalesce(f->>'tipo_medida', '')), ''),
        medida = nullif(trim(coalesce(f->>'medida', '')), ''),
        presentacion = nullif(trim(coalesce(f->>'presentacion', '')), ''),
        empaques = case when jsonb_typeof(f->'empaques') = 'array' then f->'empaques' else '[]'::jsonb end,
        impuestos_extra = case when jsonb_typeof(f->'impuestos_extra') = 'array' then f->'impuestos_extra' else '[]'::jsonb end,
        proveedores = case when jsonb_typeof(f->'proveedores') = 'array'
                           then array(select jsonb_array_elements_text(f->'proveedores')) else '{}'::text[] end,
        atributos = case when jsonb_typeof(f->'atributos') = 'object' then f->'atributos' else '{}'::jsonb end,
        ref_fabrica = nullif(trim(coalesce(f->>'ref_fabrica', '')), ''),
        cpe = nullif(trim(coalesce(f->>'cpe', '')), ''),
        registro_sanitario = nullif(trim(coalesce(f->>'registro_sanitario', '')), ''),
        variante_grupo = nullif(trim(coalesce(f->>'variante_grupo', '')), ''),
        updated_at = now()
    where codigo = p_codigo;

    -- Un código de barra de empaque no puede chocar con otro producto
    if exists (
        select 1
        from jsonb_array_elements(case when jsonb_typeof(f->'empaques') = 'array' then f->'empaques' else '[]'::jsonb end) e
        join productos p on p.codigo = e->>'barra' and p.codigo <> p_codigo
    ) then
        raise exception 'Un código de barra de empaque ya es el código de otro producto';
    end if;

    -- Servicios: siempre disponibles en todas las tiendas
    if v_tipo = 'servicio' then
        perform servicio_stock_asegurar(p_codigo);
    elsif v_tipo_antes = 'servicio' then
        -- dejó de ser servicio: el stock "infinito" vuelve a 0
        update productos set stock = 0 where codigo = p_codigo;
        update sucursal_stock set stock = 0, updated_at = now() where producto_codigo = p_codigo and stock >= 999999;
    end if;

    return jsonb_build_object('ok', true);
end;
$$;

-- ------------------------------------------------------------
-- 4. Servicios sin inventario
--    registrar_venta exige stock; para no tocar esa función, un
--    servicio mantiene un stock "infinito" (999999) en todas las
--    tiendas. Las pantallas lo muestran como "Servicio".
-- ------------------------------------------------------------
create or replace function servicio_stock_asegurar(p_codigo text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
    v_desc text;
begin
    select descripcion into v_desc from productos where codigo = p_codigo;
    update productos set stock = 999999 where codigo = p_codigo;
    insert into sucursal_stock (sucursal_id, producto_codigo, producto_descripcion, stock)
    select s.id, p_codigo, v_desc, 999999 from sucursales s
    on conflict (sucursal_id, producto_codigo) do update set stock = 999999, updated_at = now();
end;
$$;

create or replace function productos_servicio_stock()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    if new.tipo_producto = 'servicio' and coalesce(new.stock, 0) < 999999 then
        new.stock := 999999;
    end if;
    return new;
end;
$$;
drop trigger if exists trg_productos_servicio_stock on productos;
create trigger trg_productos_servicio_stock before insert or update on productos
    for each row execute function productos_servicio_stock();

create or replace function sucursal_stock_servicio()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    if exists (select 1 from productos where codigo = new.producto_codigo and tipo_producto = 'servicio')
       and coalesce(new.stock, 0) < 999999 then
        new.stock := 999999;
    end if;
    return new;
end;
$$;
drop trigger if exists trg_sucursal_stock_servicio on sucursal_stock;
create trigger trg_sucursal_stock_servicio before insert or update on sucursal_stock
    for each row execute function sucursal_stock_servicio();

-- Una sucursal nueva también tiene los servicios disponibles
create or replace function sucursal_nueva_servicios()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    insert into sucursal_stock (sucursal_id, producto_codigo, producto_descripcion, stock)
    select new.id, p.codigo, p.descripcion, 999999 from productos p where p.tipo_producto = 'servicio'
    on conflict (sucursal_id, producto_codigo) do nothing;
    return new;
end;
$$;
drop trigger if exists trg_sucursal_nueva_servicios on sucursales;
create trigger trg_sucursal_nueva_servicios after insert on sucursales
    for each row execute function sucursal_nueva_servicios();

-- Los servicios no se cuentan en el conteo de inventario
create or replace function conteo_items_sin_servicios()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    if exists (select 1 from productos where codigo = new.producto_codigo and tipo_producto = 'servicio') then
        return null;
    end if;
    return new;
end;
$$;
do $$ begin
    if to_regclass('public.conteo_items') is not null then
        execute 'drop trigger if exists trg_conteo_items_sin_servicios on conteo_items';
        execute 'create trigger trg_conteo_items_sin_servicios before insert on conteo_items for each row execute function conteo_items_sin_servicios()';
    end if;
end $$;

-- ------------------------------------------------------------
-- 5. Histórico de importaciones de Excel
-- ------------------------------------------------------------
create table if not exists importaciones_productos (
    id uuid primary key default gen_random_uuid(),
    archivo text,
    sucursal_id uuid,
    sucursal_nombre text,
    usuario_nombre text,
    modo_stock text,
    filas int not null default 0,
    creados int not null default 0,
    actualizados int not null default 0,
    omitidos int not null default 0,
    errores int not null default 0,
    detalle_errores jsonb not null default '[]'::jsonb,
    created_at timestamptz not null default now()
);
create index if not exists idx_import_prod_fecha on importaciones_productos(created_at desc);
alter table importaciones_productos enable row level security;
drop policy if exists "importaciones_productos_select" on importaciones_productos;
create policy "importaciones_productos_select" on importaciones_productos for select using (true);
revoke insert, update, delete on importaciones_productos from anon, authenticated;
grant select on importaciones_productos to anon, authenticated;

create or replace function importacion_registrar(
    p_archivo text, p_sucursal_id uuid, p_sucursal_nombre text, p_usuario text, p_modo_stock text,
    p_filas int, p_creados int, p_actualizados int, p_omitidos int, p_errores jsonb
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_id uuid;
begin
    insert into importaciones_productos (archivo, sucursal_id, sucursal_nombre, usuario_nombre, modo_stock,
        filas, creados, actualizados, omitidos, errores, detalle_errores)
    values (left(p_archivo, 200), p_sucursal_id, p_sucursal_nombre, p_usuario, p_modo_stock,
        coalesce(p_filas, 0), coalesce(p_creados, 0), coalesce(p_actualizados, 0), coalesce(p_omitidos, 0),
        case when jsonb_typeof(p_errores) = 'array' then jsonb_array_length(p_errores) else 0 end,
        case when jsonb_typeof(p_errores) = 'array' then p_errores else '[]'::jsonb end)
    returning id into v_id;
    return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

-- ------------------------------------------------------------
-- 6. Tasa: quién la cambió
-- ------------------------------------------------------------
alter table tasas_historial add column if not exists usuario_nombre text;

create or replace function tasa_historial_firmar(p_usuario text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
    update tasas_historial set usuario_nombre = left(p_usuario, 80)
    where id = (select id from tasas_historial
                where usuario_nombre is null and created_at > now() - interval '2 minutes'
                order by created_at desc limit 1);
    return jsonb_build_object('ok', true);
end;
$$;

-- ------------------------------------------------------------
-- 7. Importación de Excel: también lee el IVA (16 / 8 / 0 / exento)
-- ------------------------------------------------------------
create or replace function iva_normalizar(p text)
returns numeric
language sql
immutable
as $$
    select case
        when p is null or trim(p) = '' then null
        when lower(trim(p)) in ('exento', 'e', 'ex', 'no', 'iva exento', '0', '0%') then 0
        when regexp_replace(p, '[^0-9.,]', '', 'g') = '' then null
        else least(100, greatest(0, replace(regexp_replace(p, '[^0-9.,]', '', 'g'), ',', '.')::numeric
                     * case when replace(regexp_replace(p, '[^0-9.,]', '', 'g'), ',', '.')::numeric < 1 then 100 else 1 end))
    end;
$$;

create or replace function productos_importar_extra(p_rows jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    r jsonb;
    v_cod text;
    v_iva numeric;
    n int := 0;
begin
    if p_rows is null or jsonb_typeof(p_rows) <> 'array' then return jsonb_build_object('ok', true, 'actualizados', 0); end if;
    for r in select value from jsonb_array_elements(p_rows) loop
        v_cod := nullif(trim(coalesce(r->>'codigo', '')), '');
        if v_cod is null then v_cod := nullif(trim(coalesce(r->>'barra', '')), ''); end if;
        if v_cod is null then continue; end if;
        begin
            v_iva := iva_normalizar(r->>'iva');
        exception when others then v_iva := null;
        end;
        update productos set
            iva_tasa = coalesce(v_iva, iva_tasa),
            sku = coalesce(nullif(trim(coalesce(r->>'sku', '')), ''), sku),
            detalle = coalesce(nullif(trim(coalesce(r->>'detalle', '')), ''), detalle)
        where codigo = v_cod
          and (v_iva is not null or nullif(trim(coalesce(r->>'sku', '')), '') is not null or nullif(trim(coalesce(r->>'detalle', '')), '') is not null);
        if found then n := n + 1; end if;
    end loop;
    return jsonb_build_object('ok', true, 'actualizados', n);
end;
$$;

-- ------------------------------------------------------------
-- 8. Permisos
-- ------------------------------------------------------------
grant execute on function producto_imagenes_guardar(text, jsonb) to anon, authenticated;
grant execute on function producto_ficha_guardar(text, jsonb) to anon, authenticated;
grant execute on function importacion_registrar(text, uuid, text, text, text, int, int, int, int, jsonb) to anon, authenticated;
grant execute on function tasa_historial_firmar(text) to anon, authenticated;
grant execute on function productos_importar_extra(jsonb) to anon, authenticated;
grant execute on function iva_normalizar(text) to anon, authenticated;
revoke execute on function servicio_stock_asegurar(text) from anon, authenticated, public;
