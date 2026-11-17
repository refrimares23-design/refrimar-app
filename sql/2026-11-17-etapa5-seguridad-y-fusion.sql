-- ============================================================
-- REFRIMAR — Etapa 5 (17-nov-2026): cerrar escrituras directas y unir productos duplicados
--
-- 1. Respaldo.
-- 2. Seguridad: nadie puede cambiar productos ni la tabla vieja de cuentas por pagar
--    "por fuera" (desde internet con la clave pública). La página ya lo hace todo por
--    funciones que revisan permisos, así que nada deja de funcionar.
-- 3. Arreglos de funciones viejas que fallaban por permisos:
--    - Cierre diario (guardar)  - Costo por tienda (sucursal_stock_set_costo)
-- 4. Unir dos productos duplicados en uno (con deshacer):
--    la existencia del que sale pasa al que queda (con kardex), su código queda como código
--    alterno del que queda (el escáner lo sigue encontrando) y el que sale se desactiva.
--
-- Supabase → SQL Editor → New query → pega TODO → Run. Se puede correr varias veces.
-- No borra nada.
-- ============================================================

-- 1. Respaldo
create schema if not exists respaldo_inventario;
revoke all on schema respaldo_inventario from anon, authenticated, public;
do $$
declare t text; s text := to_char(now() at time zone 'America/Caracas', 'YYYYMMDD_HH24MISS');
begin
    foreach t in array array['productos', 'sucursal_stock'] loop
        if to_regclass('public.' || t) is not null then
            execute format('create table if not exists respaldo_inventario.%I as table public.%I', t || '_' || s, t);
        end if;
    end loop;
end $$;

-- ============================================================
-- 2. Seguridad
-- ============================================================
do $$
declare t record;
begin
    -- Productos: se leen con la clave pública, pero solo se cambian por funciones (producto_guardar, recepción, ajustes…)
    if to_regclass('public.productos') is not null then
        execute 'revoke insert, update, delete on public.productos from anon, authenticated';
    end if;
    -- Tabla vieja de cuentas por pagar (la pantalla usa compras_proveedores): solo lectura
    if to_regclass('public.cuentas_por_pagar') is not null then
        execute 'revoke insert, update, delete on public.cuentas_por_pagar from anon, authenticated';
    end if;
    -- Permisos que la página nunca usa (vaciar tablas, crear disparadores, referencias) en TODAS las tablas
    for t in select tablename from pg_tables where schemaname = 'public' loop
        execute format('revoke truncate, trigger, references on public.%I from anon, authenticated', t.tablename);
    end loop;
end $$;

-- ============================================================
-- 3. Funciones viejas que fallaban por permisos
-- ============================================================
-- Cierre diario: la pantalla llama a esta versión; corre con permisos del sistema (la sesión la exige el guardián de la API)
do $$ begin
    if to_regprocedure('public.cierre_diario_guardar(date,numeric,numeric,numeric,numeric,numeric,numeric,numeric,numeric,numeric,numeric,numeric,uuid,text,text)') is not null then
        execute 'alter function public.cierre_diario_guardar(date,numeric,numeric,numeric,numeric,numeric,numeric,numeric,numeric,numeric,numeric,numeric,uuid,text,text) security definer set search_path = public';
    end if;
end $$;

-- Costo de un producto en una tienda (kardex, recepción directa, tiendas)
create or replace function public.sucursal_stock_set_costo(p_sucursal_id uuid, p_producto_codigo text, p_costo numeric)
returns void language plpgsql security definer set search_path = public as
$$
declare v_uid uuid := refrimar_sesion_uid(30);
begin
    if v_uid is null then raise exception 'Tu sesión venció. Vuelve a entrar.'; end if;
    if not (refrimar_tiene_permiso(v_uid, 'editar_inventario') or refrimar_tiene_permiso(v_uid, 'compras')) then
        raise exception 'Tu usuario no puede cambiar costos';
    end if;
    if p_costo is null or p_costo < 0 then raise exception 'Costo inválido'; end if;
    if p_sucursal_id is null or p_sucursal_id = '00000000-0000-0000-0000-000000000001' then return; end if;   -- la Principal usa productos.costo
    update public.sucursal_stock set costo = p_costo, updated_at = now()
    where sucursal_id = p_sucursal_id and producto_codigo = p_producto_codigo;
    if not found then
        insert into public.sucursal_stock (sucursal_id, producto_codigo, producto_descripcion, costo, stock)
        select p_sucursal_id, codigo, descripcion, p_costo, 0 from public.productos where codigo = p_producto_codigo;
    end if;
end;
$$;
revoke execute on function public.sucursal_stock_set_costo(uuid, text, numeric) from public, anon;
grant execute on function public.sucursal_stock_set_costo(uuid, text, numeric) to anon, authenticated;

-- ============================================================
-- 4. Unir productos duplicados
-- ============================================================
create table if not exists public.productos_fusiones (
    id uuid primary key default gen_random_uuid(),
    codigo_queda text not null,
    codigo_sale text not null,
    antes_sale jsonb not null,          -- cómo estaba el producto que sale (para deshacer)
    antes_queda jsonb not null,         -- códigos, empaques, proveedores y costo del que queda antes de unir
    movido jsonb not null default '[]'::jsonb,   -- [{sucursal_id, cantidad}]
    usuario_nombre text,
    deshecho_at timestamptz,
    created_at timestamptz not null default now()
);
alter table public.productos_fusiones enable row level security;
revoke all on table public.productos_fusiones from anon, authenticated, public;

-- Suma (o resta) existencia en una tienda y lo anota en el kardex. Uso interno.
create or replace function public.refrimar_mover_stock(p_cod text, p_suc uuid, p_delta numeric, p_costo numeric, p_ref text, p_usuario text)
returns numeric language plpgsql security definer set search_path = public as
$$
declare v_saldo numeric; v_desc text; v_costo numeric;
begin
    select descripcion, coalesce(costo, 0) into v_desc, v_costo from productos where codigo = p_cod;
    if p_suc is null or p_suc = '00000000-0000-0000-0000-000000000001' then
        update productos set stock = coalesce(stock, 0) + p_delta, updated_at = now() where codigo = p_cod returning stock into v_saldo;
        p_suc := null;
    else
        insert into sucursal_stock (sucursal_id, producto_codigo, producto_descripcion, stock)
        values (p_suc, p_cod, v_desc, p_delta)
        on conflict (sucursal_id, producto_codigo) do update set stock = coalesce(sucursal_stock.stock, 0) + excluded.stock, updated_at = now()
        returning stock into v_saldo;
    end if;
    insert into kardex_movimientos (producto_codigo, producto_descripcion, fecha, tipo, cantidad, costo_unitario, costo_total,
                                    saldo_cantidad, saldo_costo_promedio, referencia, usuario_nombre, sucursal_id)
    values (p_cod, coalesce(v_desc, p_cod), current_date, case when p_delta >= 0 then 'entrada_ajuste' else 'salida_ajuste' end, p_delta,
            coalesce(p_costo, v_costo), round(abs(p_delta) * coalesce(p_costo, v_costo), 2), v_saldo, v_costo, p_ref, p_usuario, p_suc);
    return v_saldo;
end;
$$;
revoke execute on function public.refrimar_mover_stock(text, uuid, numeric, numeric, text, text) from public, anon, authenticated;

create or replace function public.productos_fusionar(p_queda text, p_sale text)
returns jsonb language plpgsql security definer set search_path = public as
$$
declare
    v_uid uuid := refrimar_sesion_uid(30); v_usuario text;
    q record; s record; r record;
    v_movido jsonb := '[]'::jsonb; v_id uuid; v_ref text;
    v_cods text[]; v_emp jsonb; v_pos_q numeric; v_pos_s numeric;
begin
    if v_uid is null then raise exception 'Tu sesión venció. Vuelve a entrar.'; end if;
    if not refrimar_tiene_permiso(v_uid, 'editar_inventario') then raise exception 'Tu usuario no puede editar productos'; end if;
    select nombre into v_usuario from usuarios where id = v_uid;
    if p_queda is null or p_sale is null or p_queda = p_sale then raise exception 'Elige dos productos distintos'; end if;
    -- Siempre en el mismo orden para que dos uniones a la vez no se traben
    perform 1 from productos where codigo in (p_queda, p_sale) order by codigo for update;
    select * into q from productos where codigo = p_queda;
    if not found then raise exception 'El producto % no existe', p_queda; end if;
    select * into s from productos where codigo = p_sale;
    if not found then raise exception 'El producto % no existe', p_sale; end if;
    if s.activo is false and exists (select 1 from productos_fusiones where codigo_sale = p_sale and deshecho_at is null) then
        raise exception '% ya se unió a otro producto', s.descripcion;
    end if;
    if coalesce(q.es_kit, false) or coalesce(s.es_kit, false) then raise exception 'Los combos no se pueden unir'; end if;
    v_ref := 'Unión de duplicados: ' || s.codigo || ' → ' || q.codigo;

    -- Costo del que queda: promedio con lo que trae el que sale (todas las tiendas, solo existencias positivas)
    v_pos_q := greatest(coalesce(q.stock, 0), 0) + coalesce((select sum(greatest(stock, 0)) from sucursal_stock where producto_codigo = q.codigo), 0);
    v_pos_s := greatest(coalesce(s.stock, 0), 0) + coalesce((select sum(greatest(stock, 0)) from sucursal_stock where producto_codigo = s.codigo), 0);

    -- Existencias: Principal y cada tienda
    if coalesce(s.stock, 0) <> 0 then
        perform refrimar_mover_stock(s.codigo, null, -s.stock, s.costo, v_ref, v_usuario);
        perform refrimar_mover_stock(q.codigo, null, s.stock, s.costo, v_ref, v_usuario);
        v_movido := v_movido || jsonb_build_object('sucursal_id', null, 'cantidad', s.stock);
    end if;
    for r in select sucursal_id, stock, ubicacion from sucursal_stock where producto_codigo = s.codigo and coalesce(stock, 0) <> 0 order by sucursal_id loop
        perform refrimar_mover_stock(s.codigo, r.sucursal_id, -r.stock, s.costo, v_ref, v_usuario);
        perform refrimar_mover_stock(q.codigo, r.sucursal_id, r.stock, s.costo, v_ref, v_usuario);
        update sucursal_stock set ubicacion = coalesce(ubicacion, r.ubicacion) where sucursal_id = r.sucursal_id and producto_codigo = q.codigo;
        v_movido := v_movido || jsonb_build_object('sucursal_id', r.sucursal_id, 'cantidad', r.stock);
    end loop;

    -- El código y los códigos alternos del que sale pasan al que queda (el escáner lo sigue encontrando)
    select coalesce(array_agg(distinct c), '{}') into v_cods
    from unnest(coalesce(q.codigos_alternos, '{}') || array[s.codigo] || coalesce(s.codigos_alternos, '{}')) c
    where c is not null and c <> '' and c <> q.codigo;
    select coalesce(jsonb_agg(e), '[]'::jsonb) into v_emp from (
        select e from jsonb_array_elements(coalesce(q.empaques, '[]'::jsonb)) e
        union all
        select e from jsonb_array_elements(coalesce(s.empaques, '[]'::jsonb)) e
        where not exists (select 1 from jsonb_array_elements(coalesce(q.empaques, '[]'::jsonb)) x where lower(x->>'barra') = lower(e->>'barra'))) z;
    update productos set
        codigos_alternos = v_cods,
        empaques = v_emp,
        proveedores = (select coalesce(array_agg(distinct p), '{}') from unnest(coalesce(q.proveedores, '{}') || coalesce(s.proveedores, '{}')) p where p is not null and p <> ''),
        costo = case when v_pos_q + v_pos_s > 0 and coalesce(s.costo, 0) > 0 and coalesce(q.costo, 0) > 0
                     then round((v_pos_q * q.costo + v_pos_s * s.costo) / (v_pos_q + v_pos_s), 6)
                     when coalesce(q.costo, 0) = 0 then s.costo else q.costo end,
        ubicacion = coalesce(q.ubicacion, s.ubicacion),
        garantia_dias = coalesce(q.garantia_dias, s.garantia_dias),
        categoria = coalesce(q.categoria, s.categoria),
        marca = coalesce(q.marca, s.marca),
        updated_at = now()
    where codigo = q.codigo;
    update productos set activo = false, estatus = 'inactivo', codigos_alternos = '{}', empaques = '[]'::jsonb, updated_at = now()
    where codigo = s.codigo;

    insert into productos_fusiones (codigo_queda, codigo_sale, antes_sale, antes_queda, movido, usuario_nombre)
    values (q.codigo, s.codigo, to_jsonb(s),
            jsonb_build_object('codigos_alternos', to_jsonb(q.codigos_alternos), 'empaques', q.empaques, 'proveedores', to_jsonb(q.proveedores), 'costo', q.costo,
                               'ubicacion', q.ubicacion, 'garantia_dias', q.garantia_dias, 'categoria', q.categoria, 'marca', q.marca),
            v_movido, v_usuario)
    returning id into v_id;
    -- Ya no sale como posible duplicado
    if to_regclass('public.duplicados_descartados') is not null then
        insert into duplicados_descartados (codigo_a, codigo_b, usuario_nombre) values (least(q.codigo, s.codigo), greatest(q.codigo, s.codigo), v_usuario) on conflict do nothing;
    end if;
    return jsonb_build_object('ok', true, 'id', v_id, 'movido', v_movido, 'queda', q.codigo, 'sale', s.codigo);
end;
$$;
revoke execute on function public.productos_fusionar(text, text) from public, anon;
grant execute on function public.productos_fusionar(text, text) to anon, authenticated;

-- Deshace una unión: devuelve la existencia movida y deja ambos productos como estaban
create or replace function public.productos_fusion_deshacer(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as
$$
declare v_uid uuid := refrimar_sesion_uid(30); v_usuario text; f record; m jsonb; v_ref text; s jsonb; a jsonb;
begin
    if v_uid is null then raise exception 'Tu sesión venció. Vuelve a entrar.'; end if;
    if not refrimar_tiene_permiso(v_uid, 'editar_inventario') then raise exception 'Tu usuario no puede editar productos'; end if;
    select nombre into v_usuario from usuarios where id = v_uid;
    select * into f from productos_fusiones where id = p_id for update;
    if not found then raise exception 'Esa unión no existe'; end if;
    if f.deshecho_at is not null then raise exception 'Esa unión ya se deshizo'; end if;
    perform 1 from productos where codigo in (f.codigo_queda, f.codigo_sale) order by codigo for update;
    v_ref := 'Deshacer unión: ' || f.codigo_queda || ' → ' || f.codigo_sale;
    s := f.antes_sale; a := f.antes_queda;
    for m in select value from jsonb_array_elements(f.movido) loop
        perform refrimar_mover_stock(f.codigo_queda, nullif(m->>'sucursal_id', '')::uuid, -(m->>'cantidad')::numeric, (s->>'costo')::numeric, v_ref, v_usuario);
        perform refrimar_mover_stock(f.codigo_sale, nullif(m->>'sucursal_id', '')::uuid, (m->>'cantidad')::numeric, (s->>'costo')::numeric, v_ref, v_usuario);
    end loop;
    update productos set
        codigos_alternos = coalesce((select array_agg(x) from jsonb_array_elements_text(a->'codigos_alternos') x), '{}'),
        empaques = coalesce(a->'empaques', '[]'::jsonb),
        proveedores = coalesce((select array_agg(x) from jsonb_array_elements_text(a->'proveedores') x), '{}'),
        costo = coalesce((a->>'costo')::numeric, costo),
        ubicacion = a->>'ubicacion', garantia_dias = (a->>'garantia_dias')::int, categoria = a->>'categoria', marca = a->>'marca',
        updated_at = now()
    where codigo = f.codigo_queda;
    update productos set
        activo = coalesce((s->>'activo')::boolean, true), estatus = coalesce(s->>'estatus', 'activo'),
        codigos_alternos = coalesce((select array_agg(x) from jsonb_array_elements_text(s->'codigos_alternos') x), '{}'),
        empaques = coalesce(s->'empaques', '[]'::jsonb), updated_at = now()
    where codigo = f.codigo_sale;
    update productos_fusiones set deshecho_at = now() where id = p_id;
    if to_regclass('public.duplicados_descartados') is not null then
        delete from duplicados_descartados where codigo_a = least(f.codigo_queda, f.codigo_sale) and codigo_b = greatest(f.codigo_queda, f.codigo_sale);
    end if;
    return jsonb_build_object('ok', true);
end;
$$;
revoke execute on function public.productos_fusion_deshacer(uuid) from public, anon;
grant execute on function public.productos_fusion_deshacer(uuid) to anon, authenticated;

create or replace function public.productos_fusiones_recientes()
returns jsonb language plpgsql stable security definer set search_path = public as
$$
declare v_uid uuid := refrimar_sesion_uid(30);
begin
    if v_uid is null then raise exception 'Tu sesión venció. Vuelve a entrar.'; end if;
    if not refrimar_tiene_permiso(v_uid, 'editar_inventario') then raise exception 'Tu usuario no puede editar productos'; end if;
    return coalesce((select jsonb_agg(jsonb_build_object('id', f.id, 'queda', f.codigo_queda, 'queda_desc', p.descripcion, 'sale', f.codigo_sale,
                                                         'sale_desc', f.antes_sale->>'descripcion', 'usuario', f.usuario_nombre, 'fecha', f.created_at,
                                                         'deshecho', f.deshecho_at is not null) order by f.created_at desc)
                     from (select * from productos_fusiones order by created_at desc limit 15) f left join productos p on p.codigo = f.codigo_queda), '[]'::jsonb);
end;
$$;
revoke execute on function public.productos_fusiones_recientes() from public, anon;
grant execute on function public.productos_fusiones_recientes() to anon, authenticated;

-- ============================================================
-- Seguridad y registro
-- ============================================================
insert into public.seguridad_rpc (nombre, nivel, permiso, gracia_dias)
select v.* from (values ('productos_fusionar', 'sesion', null, 0), ('productos_fusion_deshacer', 'sesion', null, 0),
                        ('productos_fusiones_recientes', 'sesion', null, 0), ('sucursal_stock_set_costo', 'sesion', null, 0)) as v(nombre, nivel, permiso, gracia)
where not exists (select 1 from public.seguridad_rpc s where s.nombre = v.nombre);

insert into public.migraciones_aplicadas (nombre, descripcion, version_app)
values ('2026-11-17-etapa5-seguridad-y-fusion', 'Productos solo por funciones, arreglos de permisos y unir duplicados', 'v3.9.28')
on conflict (nombre) do nothing;
notify pgrst, 'reload schema';

-- Comprobación: debe salir false, false, true
select has_table_privilege('anon', 'public.productos', 'update') as internet_cambia_productos,
       has_table_privilege('anon', 'public.productos', 'insert') as internet_crea_productos,
       has_table_privilege('anon', 'public.productos', 'select') as internet_lee_productos;
