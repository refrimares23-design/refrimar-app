-- ============================================================
-- REFRIMAR — ACTUALIZACIÓN (ficha de producto + fase 3)
-- Pega TODO en Supabase → SQL Editor → New query → Run.
-- Se puede correr varias veces sin problema.
-- ============================================================

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

-- ============================================================
-- REFRIMAR — FASE 3 (estilo Norkut)
-- ------------------------------------------------------------
-- Requiere haber corrido antes:
--   supabase-migration-norkut-completo.sql  (o productos-ficha)
-- Qué agrega (idempotente: seguro volver a correrlo):
--   • Importación de Excel con todos los campos de la ficha.
--   • Transferencias entre tiendas (con varios productos, borrador,
--     transporte y referencia).
--   • Órdenes de compra: negociación de pago, transporte, tracking.
--   • Conteos: fechas de inicio/fin y descripción.
--   • Clientes: persona natural/jurídica, apellidos, documento,
--     ubicación y datos personales.
--   • Usuarios: correo para entrar con Google.
--
-- CÓMO APLICAR: Supabase → SQL Editor → New query → pega TODO → Run
-- ============================================================

-- ------------------------------------------------------------
-- 1. Importación con ficha completa
-- ------------------------------------------------------------
alter table productos add column if not exists stock_maximo numeric;

create or replace function producto_stock_maximo(p_codigo text, p_max numeric)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
    if p_max is not null and p_max < 0 then raise exception 'El stock máximo no puede ser negativo'; end if;
    update productos set stock_maximo = nullif(p_max, 0) where codigo = p_codigo;
    if not found then raise exception 'Producto % no existe', p_codigo; end if;
    return jsonb_build_object('ok', true);
end;
$$;
grant execute on function producto_stock_maximo(text, numeric) to anon, authenticated;
create or replace function productos_importar_ficha(p_rows jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    r jsonb;
    v_cod text;
    v_iva numeric;
    v_tipo text;
    n int := 0;
begin
    if p_rows is null or jsonb_typeof(p_rows) <> 'array' then return jsonb_build_object('ok', true, 'actualizados', 0); end if;
    for r in select value from jsonb_array_elements(p_rows) loop
        v_cod := nullif(trim(coalesce(r->>'codigo', '')), '');
        if v_cod is null then continue; end if;
        begin v_iva := iva_normalizar(r->>'iva'); exception when others then v_iva := null; end;
        v_tipo := case when r->>'tipo_producto' = 'servicio' then 'servicio' else 'fisico' end;
        update productos set
            iva_tasa = coalesce(v_iva, iva_tasa),
            sku = coalesce(nullif(trim(coalesce(r->>'sku', '')), ''), sku),
            detalle = coalesce(nullif(trim(coalesce(r->>'detalle', '')), ''), detalle),
            tipo_producto = v_tipo,
            pesable = coalesce((r->>'pesable')::boolean, pesable),
            codigo_balanza = coalesce(nullif(trim(coalesce(r->>'codigo_balanza', '')), ''), codigo_balanza),
            clasificacion = coalesce(nullif(trim(coalesce(r->>'clasificacion', '')), ''), clasificacion),
            origen = coalesce(nullif(trim(coalesce(r->>'origen', '')), ''), origen),
            tipo_medida = coalesce(nullif(trim(coalesce(r->>'tipo_medida', '')), ''), tipo_medida),
            medida = coalesce(nullif(trim(coalesce(r->>'medida', '')), ''), medida),
            presentacion = coalesce(nullif(trim(coalesce(r->>'presentacion', '')), ''), presentacion),
            ref_fabrica = coalesce(nullif(trim(coalesce(r->>'ref_fabrica', '')), ''), ref_fabrica),
            referencia_interna = coalesce(nullif(trim(coalesce(r->>'referencia_interna', '')), ''), referencia_interna),
            stock_maximo = coalesce(nullif(r->>'stock_maximo', '')::numeric, stock_maximo),
            proveedores = case when jsonb_typeof(r->'proveedores') = 'array' and jsonb_array_length(r->'proveedores') > 0
                               then array(select distinct x from unnest(coalesce(proveedores, '{}') || array(select jsonb_array_elements_text(r->'proveedores'))) x)
                               else proveedores end,
            updated_at = now()
        where codigo = v_cod;
        if found then
            n := n + 1;
            if v_tipo = 'servicio' then perform servicio_stock_asegurar(v_cod); end if;
        end if;
    end loop;
    return jsonb_build_object('ok', true, 'actualizados', n);
end;
$$;
grant execute on function productos_importar_ficha(jsonb) to anon, authenticated;

-- ------------------------------------------------------------
-- 2. Transferencias entre tiendas
-- ------------------------------------------------------------
create sequence if not exists seq_transferencia;
create table if not exists transferencias (
    id uuid primary key default gen_random_uuid(),
    numero text not null unique,
    origen_id uuid not null,
    origen_nombre text,
    destino_id uuid not null,
    destino_nombre text,
    estado text not null default 'borrador',
    fecha_estimada date,
    fecha_envio date,
    fecha_recepcion date,
    tipo_transporte text,
    empresa_transporte text,
    ref_transporte text,
    referencia text,
    observaciones text,
    usuario_nombre text,
    total_items int not null default 0,
    total_unidades numeric not null default 0,
    total_costo numeric not null default 0,
    created_at timestamptz not null default now(),
    completada_at timestamptz
);
create table if not exists transferencia_items (
    id uuid primary key default gen_random_uuid(),
    transferencia_id uuid not null references transferencias(id) on delete cascade,
    producto_codigo text not null,
    descripcion text,
    cantidad numeric not null,
    costo_unitario numeric not null default 0
);
create index if not exists idx_transf_fecha on transferencias(created_at desc);
create index if not exists idx_transf_items on transferencia_items(transferencia_id);
alter table transferencias enable row level security;
alter table transferencia_items enable row level security;
drop policy if exists "transferencias_select" on transferencias;
create policy "transferencias_select" on transferencias for select using (true);
drop policy if exists "transferencia_items_select" on transferencia_items;
create policy "transferencia_items_select" on transferencia_items for select using (true);
revoke insert, update, delete on transferencias, transferencia_items from anon, authenticated;
grant select on transferencias, transferencia_items to anon, authenticated;

create or replace function transferencia_guardar(p_id uuid, p_datos jsonb, p_items jsonb, p_procesar boolean, p_usuario text default 'Sistema')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    d jsonb := coalesce(p_datos, '{}'::jsonb);
    v_id uuid := p_id;
    v_numero text;
    v_estado text;
    v_origen uuid := nullif(d->>'origen_id', '')::uuid;
    v_destino uuid := nullif(d->>'destino_id', '')::uuid;
    it jsonb;
    v_cod text; v_cant numeric; v_costo numeric; v_desc text;
    v_n int := 0; v_u numeric := 0; v_c numeric := 0;
    v_casa uuid := '00000000-0000-0000-0000-000000000001';
begin
    if v_origen is null or v_destino is null then raise exception 'Elige la tienda de origen y la de destino'; end if;
    if v_origen = v_destino then raise exception 'El origen y el destino no pueden ser la misma tienda'; end if;
    if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'Agrega al menos un producto'; end if;

    if v_id is null then
        v_numero := 'TR-' || lpad(nextval('seq_transferencia')::text, 6, '0');
        insert into transferencias (numero, origen_id, destino_id) values (v_numero, v_origen, v_destino) returning id into v_id;
    else
        select estado, numero into v_estado, v_numero from transferencias where id = v_id for update;
        if not found then raise exception 'Transferencia no encontrada'; end if;
        if v_estado <> 'borrador' then raise exception 'Solo se puede editar una transferencia en borrador'; end if;
        delete from transferencia_items where transferencia_id = v_id;
    end if;

    for it in select value from jsonb_array_elements(p_items) loop
        v_cod := nullif(trim(coalesce(it->>'codigo', '')), '');
        v_cant := coalesce((it->>'cantidad')::numeric, 0);
        if v_cod is null or v_cant <= 0 then raise exception 'Producto o cantidad inválida'; end if;
        select descripcion, costo into v_desc, v_costo from productos where codigo = v_cod;
        if not found then raise exception 'Producto % no existe', v_cod; end if;
        if v_origen <> v_casa then
            select coalesce(nullif(costo, 0), v_costo) into v_costo from sucursal_stock where sucursal_id = v_origen and producto_codigo = v_cod;
        end if;
        v_costo := coalesce(v_costo, 0);
        insert into transferencia_items (transferencia_id, producto_codigo, descripcion, cantidad, costo_unitario)
        values (v_id, v_cod, v_desc, v_cant, v_costo);
        v_n := v_n + 1; v_u := v_u + v_cant; v_c := v_c + v_cant * v_costo;
    end loop;

    update transferencias set
        origen_id = v_origen, origen_nombre = coalesce(d->>'origen_nombre', origen_nombre),
        destino_id = v_destino, destino_nombre = coalesce(d->>'destino_nombre', destino_nombre),
        fecha_estimada = nullif(d->>'fecha_estimada', '')::date, fecha_envio = nullif(d->>'fecha_envio', '')::date,
        fecha_recepcion = nullif(d->>'fecha_recepcion', '')::date,
        tipo_transporte = nullif(trim(coalesce(d->>'tipo_transporte', '')), ''), empresa_transporte = nullif(trim(coalesce(d->>'empresa_transporte', '')), ''),
        ref_transporte = nullif(trim(coalesce(d->>'ref_transporte', '')), ''), referencia = nullif(trim(coalesce(d->>'referencia', '')), ''),
        observaciones = nullif(trim(coalesce(d->>'observaciones', '')), ''), usuario_nombre = coalesce(p_usuario, usuario_nombre),
        total_items = v_n, total_unidades = v_u, total_costo = round(v_c, 2)
    where id = v_id;

    if p_procesar then
        for it in select to_jsonb(ti) from transferencia_items ti where ti.transferencia_id = v_id loop
            perform transferir_stock_sucursal(it->>'producto_codigo', (it->>'cantidad')::numeric, (it->>'costo_unitario')::numeric, v_origen, v_destino, coalesce(p_usuario, 'Sistema'));
            insert into kardex_movimientos (producto_codigo, producto_descripcion, fecha, tipo, cantidad, costo_unitario, costo_total, saldo_cantidad, saldo_costo_promedio, referencia, usuario_nombre, sucursal_id)
            values (it->>'producto_codigo', it->>'descripcion', current_date, 'salida_traslado', -((it->>'cantidad')::numeric), (it->>'costo_unitario')::numeric,
                    (it->>'cantidad')::numeric * (it->>'costo_unitario')::numeric, stock_en(it->>'producto_codigo', v_origen), (it->>'costo_unitario')::numeric,
                    v_numero || ' → ' || coalesce(d->>'destino_nombre', ''), coalesce(p_usuario, 'Sistema'), case when v_origen = v_casa then null else v_origen end),
                   (it->>'producto_codigo', it->>'descripcion', current_date, 'entrada_traslado', (it->>'cantidad')::numeric, (it->>'costo_unitario')::numeric,
                    (it->>'cantidad')::numeric * (it->>'costo_unitario')::numeric, stock_en(it->>'producto_codigo', v_destino), (it->>'costo_unitario')::numeric,
                    v_numero || ' ← ' || coalesce(d->>'origen_nombre', ''), coalesce(p_usuario, 'Sistema'), case when v_destino = v_casa then null else v_destino end);
        end loop;
        update transferencias set estado = 'completada', completada_at = now(),
            fecha_envio = coalesce(fecha_envio, current_date), fecha_recepcion = coalesce(fecha_recepcion, current_date)
        where id = v_id;
    end if;
    return jsonb_build_object('ok', true, 'id', v_id, 'numero', v_numero, 'estado', case when p_procesar then 'completada' else 'borrador' end);
end;
$$;

create or replace function transferencia_cancelar(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
    update transferencias set estado = 'cancelada' where id = p_id and estado = 'borrador';
    if not found then raise exception 'Solo se puede cancelar una transferencia en borrador'; end if;
    return jsonb_build_object('ok', true);
end;
$$;
grant execute on function transferencia_guardar(uuid, jsonb, jsonb, boolean, text) to anon, authenticated;
grant execute on function transferencia_cancelar(uuid) to anon, authenticated;

-- ------------------------------------------------------------
-- 3. Conteos con lista de productos, fechas y descripción
-- ------------------------------------------------------------
alter table conteos add column if not exists fecha_inicio date;
alter table conteos add column if not exists fecha_fin date;

create or replace function conteo_crear_lista(
    p_nombre text, p_sucursal_id uuid, p_sucursal_nombre text, p_codigos jsonb,
    p_usuario text default 'Sistema', p_descripcion text default null,
    p_fecha_inicio date default null, p_fecha_fin date default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_id uuid;
    v_numero text;
    v_n int;
    v_casa boolean := (p_sucursal_id is null or p_sucursal_id = '00000000-0000-0000-0000-000000000001');
begin
    if p_codigos is null or jsonb_typeof(p_codigos) <> 'array' or jsonb_array_length(p_codigos) = 0 then raise exception 'Agrega al menos un producto al conteo'; end if;
    if p_fecha_inicio is not null and p_fecha_fin is not null and p_fecha_fin < p_fecha_inicio then raise exception 'La fecha fin no puede ser antes de la fecha inicio'; end if;
    v_numero := 'CI-' || lpad(nextval('seq_conteo')::text, 6, '0');
    insert into conteos (numero, nombre, sucursal_id, sucursal_nombre, usuario_nombre, notas, fecha_inicio, fecha_fin)
    values (v_numero, coalesce(nullif(trim(coalesce(p_nombre, '')), ''), 'Conteo ' || to_char(now(), 'DD/MM/YYYY')),
            p_sucursal_id, coalesce(p_sucursal_nombre, 'Casa Matriz'), coalesce(p_usuario, 'Sistema'), p_descripcion, p_fecha_inicio, p_fecha_fin)
    returning id into v_id;

    insert into conteo_items (conteo_id, producto_codigo, descripcion, categoria, stock_sistema)
    select v_id, p.codigo, p.descripcion, p.categoria,
           case when v_casa then coalesce(p.stock, 0) else coalesce(ss.stock, 0) end
    from (select distinct value as codigo from jsonb_array_elements_text(p_codigos)) c
    join productos p on p.codigo = c.codigo
    left join sucursal_stock ss on ss.producto_codigo = p.codigo and ss.sucursal_id = p_sucursal_id;

    get diagnostics v_n = row_count;
    if v_n = 0 then raise exception 'Ninguno de los productos existe (o son servicios)'; end if;
    update conteos set items_total = v_n where id = v_id;
    return jsonb_build_object('ok', true, 'id', v_id, 'numero', v_numero, 'items', v_n);
end;
$$;
grant execute on function conteo_crear_lista(text, uuid, text, jsonb, text, text, date, date) to anon, authenticated;

-- ------------------------------------------------------------
-- 4. Órdenes de compra: negociación de pago y entrega
-- ------------------------------------------------------------
alter table ordenes_compra add column if not exists tipo_negociacion text;
alter table ordenes_compra add column if not exists moneda_pago text;
alter table ordenes_compra add column if not exists forma_pago text;
alter table ordenes_compra add column if not exists contacto text;
alter table ordenes_compra add column if not exists fecha_vencimiento date;
alter table ordenes_compra add column if not exists empresa_transporte text;
alter table ordenes_compra add column if not exists tracking text;
alter table ordenes_compra add column if not exists referencia text;
alter table ordenes_compra add column if not exists total_impuestos numeric not null default 0;

create or replace function oc_extra_guardar(p_id uuid, p_extra jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare e jsonb := coalesce(p_extra, '{}'::jsonb);
begin
    update ordenes_compra set
        tipo_negociacion = nullif(trim(coalesce(e->>'tipo_negociacion', '')), ''),
        moneda_pago = nullif(trim(coalesce(e->>'moneda_pago', '')), ''),
        forma_pago = nullif(trim(coalesce(e->>'forma_pago', '')), ''),
        contacto = nullif(trim(coalesce(e->>'contacto', '')), ''),
        fecha_vencimiento = nullif(e->>'fecha_vencimiento', '')::date,
        empresa_transporte = nullif(trim(coalesce(e->>'empresa_transporte', '')), ''),
        tracking = nullif(trim(coalesce(e->>'tracking', '')), ''),
        referencia = nullif(trim(coalesce(e->>'referencia', '')), ''),
        total_impuestos = coalesce(nullif(e->>'total_impuestos', '')::numeric, 0)
    where id = p_id;
    if not found then raise exception 'Orden no encontrada'; end if;
    return jsonb_build_object('ok', true);
end;
$$;
grant execute on function oc_extra_guardar(uuid, jsonb) to anon, authenticated;

-- ------------------------------------------------------------
-- 5. Bancos (cuentas bancarias, saldos, transferencias)
-- ------------------------------------------------------------
create table if not exists cuentas_bancarias (
    id uuid primary key default gen_random_uuid(),
    banco text not null,
    alias text not null,
    numero text,
    moneda text not null default 'VES',
    saldo numeric not null default 0,
    metodos text[] not null default '{}',
    por_defecto boolean not null default false,
    activa boolean not null default true,
    created_at timestamptz not null default now()
);
create table if not exists cuenta_movimientos (
    id uuid primary key default gen_random_uuid(),
    cuenta_id uuid not null references cuentas_bancarias(id) on delete cascade,
    fecha date not null default current_date,
    tipo text not null,
    monto numeric not null,
    saldo_despues numeric not null default 0,
    motivo text,
    referencia text,
    usuario_nombre text,
    transferencia_id uuid,
    created_at timestamptz not null default now()
);
create index if not exists idx_cta_mov on cuenta_movimientos(cuenta_id, created_at desc);
alter table cuentas_bancarias enable row level security;
alter table cuenta_movimientos enable row level security;
drop policy if exists "cuentas_bancarias_select" on cuentas_bancarias;
create policy "cuentas_bancarias_select" on cuentas_bancarias for select using (true);
drop policy if exists "cuenta_movimientos_select" on cuenta_movimientos;
create policy "cuenta_movimientos_select" on cuenta_movimientos for select using (true);
revoke insert, update, delete on cuentas_bancarias, cuenta_movimientos from anon, authenticated;
grant select on cuentas_bancarias, cuenta_movimientos to anon, authenticated;

create or replace function cuenta_guardar(p_id uuid, p_datos jsonb, p_usuario text default 'Sistema')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    d jsonb := coalesce(p_datos, '{}'::jsonb);
    v_id uuid := p_id;
    v_saldo numeric := coalesce(nullif(d->>'saldo', '')::numeric, 0);
    v_moneda text := upper(coalesce(nullif(d->>'moneda', ''), 'VES'));
    v_def boolean := coalesce((d->>'por_defecto')::boolean, false);
begin
    if nullif(trim(coalesce(d->>'banco', '')), '') is null then raise exception 'Selecciona el banco'; end if;
    if nullif(trim(coalesce(d->>'alias', '')), '') is null then raise exception 'Escribe el alias de la cuenta'; end if;
    if v_moneda not in ('VES', 'USD') then raise exception 'Moneda inválida'; end if;
    if v_def then update cuentas_bancarias set por_defecto = false where moneda = v_moneda; end if;
    if v_id is null then
        insert into cuentas_bancarias (banco, alias, numero, moneda, saldo, metodos, por_defecto)
        values (trim(d->>'banco'), trim(d->>'alias'), nullif(trim(coalesce(d->>'numero', '')), ''), v_moneda, v_saldo,
                case when jsonb_typeof(d->'metodos') = 'array' then array(select jsonb_array_elements_text(d->'metodos')) else '{}' end, v_def)
        returning id into v_id;
        insert into cuenta_movimientos (cuenta_id, tipo, monto, saldo_despues, motivo, usuario_nombre)
        values (v_id, 'saldo_inicial', v_saldo, v_saldo, 'Saldo inicial', p_usuario);
    else
        update cuentas_bancarias set banco = trim(d->>'banco'), alias = trim(d->>'alias'), numero = nullif(trim(coalesce(d->>'numero', '')), ''),
            moneda = v_moneda, por_defecto = v_def, activa = coalesce((d->>'activa')::boolean, activa),
            metodos = case when jsonb_typeof(d->'metodos') = 'array' then array(select jsonb_array_elements_text(d->'metodos')) else metodos end
        where id = v_id;
        if not found then raise exception 'Cuenta no encontrada'; end if;
    end if;
    return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

create or replace function cuenta_movimiento(p_cuenta uuid, p_tipo text, p_monto numeric, p_motivo text, p_fecha date default current_date, p_referencia text default null, p_usuario text default 'Sistema')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_saldo numeric; v_delta numeric;
begin
    if p_tipo not in ('ingreso', 'egreso', 'ajuste') then raise exception 'Tipo inválido'; end if;
    if p_monto is null or (p_tipo <> 'ajuste' and p_monto <= 0) then raise exception 'El monto debe ser mayor a 0'; end if;
    select saldo into v_saldo from cuentas_bancarias where id = p_cuenta for update;
    if not found then raise exception 'Cuenta no encontrada'; end if;
    v_delta := case when p_tipo = 'egreso' then -p_monto when p_tipo = 'ingreso' then p_monto else p_monto - v_saldo end;
    update cuentas_bancarias set saldo = saldo + v_delta where id = p_cuenta returning saldo into v_saldo;
    insert into cuenta_movimientos (cuenta_id, fecha, tipo, monto, saldo_despues, motivo, referencia, usuario_nombre)
    values (p_cuenta, coalesce(p_fecha, current_date), p_tipo, v_delta, v_saldo, p_motivo, p_referencia, p_usuario);
    return jsonb_build_object('ok', true, 'saldo', v_saldo);
end;
$$;

create or replace function cuenta_transferir(p_origen uuid, p_destino uuid, p_fecha date, p_monto numeric, p_monto_destino numeric, p_motivo text, p_usuario text default 'Sistema')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    o record; d record; v_tid uuid := gen_random_uuid(); v_md numeric;
begin
    if p_origen = p_destino then raise exception 'El banco origen y destino no pueden ser el mismo'; end if;
    if p_monto is null or p_monto <= 0 then raise exception 'El monto debe ser mayor a 0'; end if;
    select * into o from cuentas_bancarias where id = p_origen for update;
    if not found then raise exception 'Cuenta origen no encontrada'; end if;
    select * into d from cuentas_bancarias where id = p_destino for update;
    if not found then raise exception 'Cuenta destino no encontrada'; end if;
    if o.moneda <> d.moneda and (p_monto_destino is null or p_monto_destino <= 0) then raise exception 'Las cuentas tienen monedas distintas: indica el monto que llega al destino'; end if;
    v_md := case when o.moneda = d.moneda then p_monto else p_monto_destino end;
    update cuentas_bancarias set saldo = saldo - p_monto where id = p_origen;
    update cuentas_bancarias set saldo = saldo + v_md where id = p_destino;
    insert into cuenta_movimientos (cuenta_id, fecha, tipo, monto, saldo_despues, motivo, usuario_nombre, transferencia_id)
    values (p_origen, coalesce(p_fecha, current_date), 'transferencia_salida', -p_monto, o.saldo - p_monto, coalesce(nullif(p_motivo, ''), 'Transferencia a ' || d.alias), p_usuario, v_tid),
           (p_destino, coalesce(p_fecha, current_date), 'transferencia_entrada', v_md, d.saldo + v_md, coalesce(nullif(p_motivo, ''), 'Transferencia desde ' || o.alias), p_usuario, v_tid);
    return jsonb_build_object('ok', true, 'id', v_tid);
end;
$$;
grant execute on function cuenta_guardar(uuid, jsonb, text) to anon, authenticated;
grant execute on function cuenta_movimiento(uuid, text, numeric, text, date, text, text) to anon, authenticated;
grant execute on function cuenta_transferir(uuid, uuid, date, numeric, numeric, text, text) to anon, authenticated;

-- ------------------------------------------------------------
-- 6. Clientes: ficha completa (natural / jurídico, ubicación, datos personales)
-- ------------------------------------------------------------
alter table clientes add column if not exists tipo_persona text default 'natural';
alter table clientes add column if not exists nombres text;
alter table clientes add column if not exists apellidos text;
alter table clientes add column if not exists tipo_documento text;
alter table clientes add column if not exists documento text;
alter table clientes add column if not exists estado_ve text;
alter table clientes add column if not exists ciudad text;
alter table clientes add column if not exists calle text;
alter table clientes add column if not exists genero text;
alter table clientes add column if not exists fecha_nacimiento date;
alter table clientes add column if not exists estado_civil text;
alter table clientes add column if not exists hijos int;
alter table clientes add column if not exists credito_habilitado boolean not null default false;

create or replace function cliente_ficha_guardar(p_id uuid, p_ficha jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare f jsonb := coalesce(p_ficha, '{}'::jsonb);
begin
    update clientes set
        tipo_persona = case when f->>'tipo_persona' = 'juridico' then 'juridico' else 'natural' end,
        nombres = nullif(trim(coalesce(f->>'nombres', '')), ''),
        apellidos = nullif(trim(coalesce(f->>'apellidos', '')), ''),
        tipo_documento = nullif(trim(coalesce(f->>'tipo_documento', '')), ''),
        documento = nullif(trim(coalesce(f->>'documento', '')), ''),
        estado_ve = nullif(trim(coalesce(f->>'estado_ve', '')), ''),
        ciudad = nullif(trim(coalesce(f->>'ciudad', '')), ''),
        calle = nullif(trim(coalesce(f->>'calle', '')), ''),
        genero = nullif(trim(coalesce(f->>'genero', '')), ''),
        fecha_nacimiento = nullif(f->>'fecha_nacimiento', '')::date,
        estado_civil = nullif(trim(coalesce(f->>'estado_civil', '')), ''),
        hijos = nullif(f->>'hijos', '')::int,
        credito_habilitado = coalesce((f->>'credito_habilitado')::boolean, false)
    where id = p_id;
    if not found then raise exception 'Cliente no encontrado'; end if;
    return jsonb_build_object('ok', true);
end;
$$;
grant execute on function cliente_ficha_guardar(uuid, jsonb) to anon, authenticated;

-- ------------------------------------------------------------
-- 7. Entrar con Google (Supabase Auth)
--    El correo de Google se asigna a cada colaborador. Al entrar,
--    Postgres lee el correo verificado del token de Google.
-- ------------------------------------------------------------
alter table usuarios add column if not exists email text;
create unique index if not exists idx_usuarios_email on usuarios(lower(email)) where email is not null;

create or replace function usuario_email_guardar(p_id uuid, p_email text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v text := nullif(lower(trim(coalesce(p_email, ''))), '');
begin
    if v is not null and v !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Correo inválido'; end if;
    if v is not null and exists (select 1 from usuarios where lower(email) = v and id <> p_id) then raise exception 'Ese correo ya está asignado a otro colaborador'; end if;
    update usuarios set email = v where id = p_id;
    if not found then raise exception 'Usuario no encontrado'; end if;
    return jsonb_build_object('ok', true);
end;
$$;

create or replace function login_google()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_email text;
    u record;
begin
    begin
        v_email := lower(coalesce(auth.jwt() ->> 'email', ''));
    exception when others then v_email := '';
    end;
    if v_email = '' then return jsonb_build_object('success', false, 'error', 'No hay una sesión de Google activa'); end if;
    select * into u from usuarios where lower(email) = v_email and activo = true limit 1;
    if not found then return jsonb_build_object('success', false, 'error', 'El correo ' || v_email || ' no está asignado a ningún colaborador activo. Pídele al administrador que lo agregue en Colaboradores.'); end if;
    return jsonb_build_object('success', true, 'id', u.id, 'nombre', u.nombre, 'rol', u.rol, 'permisos', coalesce(to_jsonb(u.permisos), '[]'::jsonb), 'sucursal_id', u.sucursal_id, 'email', v_email);
end;
$$;
grant execute on function usuario_email_guardar(uuid, text) to anon, authenticated;
revoke execute on function login_google() from anon, public;
grant execute on function login_google() to authenticated;
