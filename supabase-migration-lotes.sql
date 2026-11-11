-- ============================================================
-- LOTES Y VENCIMIENTOS (farmacia, supermercado, licorería, panadería…)
-- ------------------------------------------------------------
-- Un producto puede tener varios lotes por tienda, cada uno con su
-- fecha de vencimiento y cantidad. Se cargan en la ficha del producto
-- o con la plantilla de inventario inicial (columnas Lote y Vencimiento).
-- El análisis de inventario usa el lote que vence primero.
-- Se puede correr varias veces.
-- ============================================================

create table if not exists producto_lotes (
    id uuid primary key default gen_random_uuid(),
    producto_codigo text not null,
    sucursal_id uuid,                       -- null = tienda principal
    lote text not null,
    vencimiento date,
    cantidad numeric not null default 0 check (cantidad >= 0),
    creado_at timestamptz not null default now(),
    actualizado_at timestamptz not null default now()
);
create unique index if not exists ux_producto_lotes on producto_lotes (producto_codigo, coalesce(sucursal_id, '00000000-0000-0000-0000-000000000001'::uuid), lote);
create index if not exists idx_producto_lotes_vence on producto_lotes (vencimiento) where cantidad > 0;
alter table producto_lotes enable row level security;
drop policy if exists "producto_lotes_select" on producto_lotes;
create policy "producto_lotes_select" on producto_lotes for select using (true);
revoke insert, update, delete on producto_lotes from anon, authenticated;
grant select on producto_lotes to anon, authenticated;

create or replace function lote_guardar(p_codigo text, p_lote text, p_vencimiento date, p_cantidad numeric, p_sucursal uuid default null)
returns jsonb
language plpgsql security definer
set search_path = public
as $$
declare v_suc uuid := case when p_sucursal = '00000000-0000-0000-0000-000000000001' then null else p_sucursal end; v_id uuid;
begin
    if not exists (select 1 from productos where codigo = p_codigo) then raise exception 'El producto % no existe', p_codigo; end if;
    if nullif(trim(coalesce(p_lote, '')), '') is null then raise exception 'Escribe el número de lote'; end if;
    if coalesce(p_cantidad, 0) < 0 then raise exception 'La cantidad no puede ser negativa'; end if;
    select id into v_id from producto_lotes
    where producto_codigo = p_codigo and coalesce(sucursal_id, '00000000-0000-0000-0000-000000000001'::uuid) = coalesce(v_suc, '00000000-0000-0000-0000-000000000001'::uuid)
      and lote = trim(p_lote);
    if v_id is null then
        insert into producto_lotes (producto_codigo, sucursal_id, lote, vencimiento, cantidad)
        values (p_codigo, v_suc, trim(p_lote), p_vencimiento, coalesce(p_cantidad, 0)) returning id into v_id;
    else
        update producto_lotes set vencimiento = p_vencimiento, cantidad = coalesce(p_cantidad, 0), actualizado_at = now() where id = v_id;
    end if;
    return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;
grant execute on function lote_guardar(text, text, date, numeric, uuid) to anon, authenticated;

create or replace function lote_eliminar(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
    delete from producto_lotes where id = p_id;
    return jsonb_build_object('ok', true);
end;
$$;
grant execute on function lote_eliminar(uuid) to anon, authenticated;

-- Desde la plantilla de inventario: filas {codigo, lote, vencimiento, cantidad}.
-- p_reemplazar = true: los lotes de esos productos en esa tienda quedan solo como dice el archivo.
create or replace function lotes_importar(p_rows jsonb, p_sucursal uuid default null, p_reemplazar boolean default true)
returns jsonb
language plpgsql security definer
set search_path = public
as $$
declare r jsonb; n int := 0; v_suc uuid := case when p_sucursal = '00000000-0000-0000-0000-000000000001' then null else p_sucursal end;
begin
    if jsonb_typeof(p_rows) <> 'array' then raise exception 'Filas inválidas'; end if;
    if p_reemplazar then
        delete from producto_lotes l
        where coalesce(l.sucursal_id, '00000000-0000-0000-0000-000000000001'::uuid) = coalesce(v_suc, '00000000-0000-0000-0000-000000000001'::uuid)
          and l.producto_codigo in (select distinct x ->> 'codigo' from jsonb_array_elements(p_rows) x);
    end if;
    for r in select value from jsonb_array_elements(p_rows) loop
        if nullif(trim(coalesce(r ->> 'lote', '')), '') is null or not exists (select 1 from productos where codigo = r ->> 'codigo') then continue; end if;
        perform lote_guardar(r ->> 'codigo', r ->> 'lote', nullif(r ->> 'vencimiento', '')::date, coalesce(nullif(r ->> 'cantidad', '')::numeric, 0), p_sucursal);
        n := n + 1;
    end loop;
    return jsonb_build_object('ok', true, 'lotes', n);
end;
$$;
grant execute on function lotes_importar(jsonb, uuid, boolean) to anon, authenticated;

do $$ begin
    if to_regclass('public.seguridad_rpc') is not null then
        insert into seguridad_rpc (nombre, nivel, permiso) values
            ('lote_guardar', 'permiso', 'editar_inventario'),
            ('lote_eliminar', 'permiso', 'editar_inventario'),
            ('lotes_importar', 'permiso', 'importar_productos')
        on conflict (nombre) do update set nivel = excluded.nivel, permiso = excluded.permiso;
    end if;
end $$;

do $$ begin
    if to_regprocedure('saas.sincronizar_todas()') is not null then perform saas.sincronizar_todas(); end if;
end $$;
notify pgrst, 'reload schema';
select 'Lotes listos' as resultado;
