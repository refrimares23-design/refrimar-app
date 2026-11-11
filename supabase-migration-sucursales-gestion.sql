-- ============================================================
-- TIENDAS: crear, cambiar nombre y eliminar
-- ------------------------------------------------------------
-- Eliminar una tienda solo se permite si:
--   • no es la tienda principal,
--   • no le queda inventario (pásalo antes a otra tienda),
--   • no tiene una caja abierta.
-- Las ventas, transferencias y movimientos viejos NO se borran: siguen en los
-- reportes con el nombre de la tienda. Antes de borrarla se guarda una copia
-- en sucursales_eliminadas. Se puede correr varias veces.
-- ============================================================

create table if not exists sucursales_eliminadas (
    id uuid primary key default gen_random_uuid(),
    sucursal_id uuid not null,
    nombre text,
    datos jsonb not null,
    eliminado_por text,
    eliminado_at timestamptz not null default now()
);
alter table sucursales_eliminadas enable row level security;
revoke all on sucursales_eliminadas from anon, authenticated;

create or replace function sucursal_eliminar(p_id uuid, p_usuario text default null)
returns jsonb
language plpgsql security definer
set search_path = public
as $$
declare v_suc record; v_stock numeric; v_prod int; v_turno text;
begin
    if p_id is null or p_id = '00000000-0000-0000-0000-000000000001' then
        raise exception 'La tienda principal no se puede eliminar.';
    end if;
    select * into v_suc from sucursales where id = p_id;
    if not found then raise exception 'Esa tienda ya no existe.'; end if;

    select count(*), coalesce(sum(stock), 0) into v_prod, v_stock from sucursal_stock where sucursal_id = p_id and coalesce(stock, 0) <> 0;
    if v_prod > 0 then
        raise exception 'A "%" le quedan % producto(s) con inventario (% unidades). Pásalos primero a otra tienda con una transferencia.', v_suc.nombre, v_prod, trim(to_char(v_stock, 'FM999999990.##'));
    end if;

    if to_regclass('public.turnos') is not null then
        execute 'select numero from turnos where sucursal_id = $1 and estado = ''activo'' limit 1' into v_turno using p_id;
        if v_turno is not null then
            raise exception 'La tienda "%" tiene la caja % abierta. Ciérrala antes de eliminar la tienda.', v_suc.nombre, v_turno;
        end if;
    end if;

    insert into sucursales_eliminadas (sucursal_id, nombre, datos, eliminado_por)
    values (p_id, v_suc.nombre, to_jsonb(v_suc), p_usuario);

    -- Quien tenía acceso solo a esa tienda queda sin tienda fija (el dueño le asigna otra)
    update usuarios set sucursales = array_remove(sucursales, p_id) where p_id = any(sucursales);
    begin
        execute 'update usuarios set sucursal_id = null where sucursal_id = $1' using p_id;
    exception when undefined_column then null;
    end;

    begin
        delete from sucursales where id = p_id;   -- borra también sus filas de stock en cero
    exception when foreign_key_violation then
        raise exception 'No se pudo eliminar "%": hay registros que dependen de ella (%). Escríbenos y lo revisamos.', v_suc.nombre, sqlerrm;
    end;
    return jsonb_build_object('ok', true, 'nombre', v_suc.nombre);
end;
$$;
revoke all on function sucursal_eliminar(uuid, text) from public;
grant execute on function sucursal_eliminar(uuid, text) to anon, authenticated;

do $$ begin
    if to_regclass('public.seguridad_rpc') is not null then
        insert into seguridad_rpc (nombre, nivel, permiso) values ('sucursal_eliminar', 'permiso', 'gestionar_sucursales')
        on conflict (nombre) do update set nivel = excluded.nivel, permiso = excluded.permiso;
    end if;
end $$;

do $$ begin
    if to_regprocedure('saas.sincronizar_todas()') is not null then perform saas.sincronizar_todas(); end if;
end $$;
notify pgrst, 'reload schema';
select 'Gestión de tiendas lista' as resultado;
