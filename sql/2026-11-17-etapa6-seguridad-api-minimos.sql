-- ============================================================
-- REFRIMAR — Etapa 6 (17-nov-2026): seguridad de la API y mínimos de stock reales
--
-- 1. Respaldo.
-- 2. El guardián de la API (refrimar_pre_request) ya NO deja pasar una petición cuando le
--    ocurre un error inesperado (antes la dejaba pasar). Y el acceso "de servicio" (Worker,
--    resúmenes, recordatorios) exige siempre el token de servicio: si no está configurado,
--    nadie entra por esa vía (antes entraba cualquiera).
-- 3. Proveedores y categorías de gastos: solo se cambian por funciones que revisan permisos.
-- 4. Mínimos de stock calculados con las ventas reales (con deshacer).
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
    foreach t in array array['productos', 'proveedores', 'gasto_categorias'] loop
        if to_regclass('public.' || t) is not null then
            execute format('create table if not exists respaldo_inventario.%I as table public.%I', t || '_' || s, t);
        end if;
    end loop;
end $$;

-- ============================================================
-- 2. Guardián de la API
-- ============================================================
create or replace function public.refrimar_pre_request()
returns void language plpgsql security definer set search_path = public as
$function$
declare
    v_path text := coalesce(current_setting('request.path', true), '');
    v_met text := upper(coalesce(current_setting('request.method', true), 'GET'));
    v_rpc text; v_tabla text; v_nivel text; v_perm text; v_gracia int := 0;
    v_uid uuid; v_motivo text; v_modo text;
begin
    if v_path like '/rpc/%' then
        v_rpc := lower(split_part(substr(v_path, 6), '?', 1));
        select nivel, permiso, gracia_dias into v_nivel, v_perm, v_gracia from seguridad_rpc where nombre = v_rpc;
        if v_nivel = 'publico' then return; end if;
        if v_nivel = 'compat' then
            if refrimar_modo() = 'estricto' then
                raise exception using errcode = 'PT403', message = 'Actualiza la página: el acceso cambió por seguridad.';
            end if;
            return;
        end if;
        -- Servicio (Worker): solo con el token de servicio correcto. Sin token configurado, nadie pasa por aquí;
        -- un administrador con sesión sigue pudiendo usar estas funciones (se revisa abajo).
        if v_nivel = 'servicio' and refrimar_servicio_ok() then return; end if;
    else
        v_tabla := lower(split_part(ltrim(v_path, '/'), '?', 1));
        -- Lecturas que necesita la página ANTES de entrar (login, tienda, bot de WhatsApp)
        if v_met in ('GET', 'HEAD') and v_tabla in ('sucursales', 'usuarios', 'configuracion', 'tasas_historial') then return; end if;
        if v_met in ('GET', 'HEAD') and refrimar_servicio_ok() then return; end if;   -- bot y tareas automáticas
        if v_tabla = '' then return; end if;   -- esquema OpenAPI
    end if;

    v_uid := refrimar_sesion_uid(coalesce(v_gracia, 0));
    if v_uid is null then
        v_motivo := 'sin_sesion';
    elsif v_perm is not null and not refrimar_tiene_permiso(v_uid, v_perm) then
        v_motivo := 'sin_permiso:' || v_perm;
    elsif not exists (select 1 from usuarios where id = v_uid and activo is not false) then
        v_motivo := 'usuario_inactivo';
    end if;
    if v_motivo is null then return; end if;

    -- Anotar el intento no debe impedir la decisión
    begin perform refrimar_evento(v_path, v_met, v_motivo, v_uid); exception when others then null; end;
    v_modo := refrimar_modo();
    if v_modo = 'estricto' then
        if v_motivo = 'sin_sesion' then
            raise exception using errcode = 'PT401', message = 'Tu sesión venció. Vuelve a entrar.';
        end if;
        raise exception using errcode = 'PT403', message = 'Tu usuario no tiene permiso para esta operación.';
    end if;
exception
    when others then
        if SQLSTATE in ('PT401', 'PT403') then raise; end if;
        -- Falla inesperada: en modo estricto se BLOQUEA (antes se dejaba pasar). En modo aviso se deja pasar.
        begin v_modo := refrimar_modo(); exception when others then v_modo := 'estricto'; end;
        if v_modo = 'estricto' then
            raise exception using errcode = 'PT503', message = 'No se pudo revisar el acceso. Intenta de nuevo en un momento.';
        end if;
        return;
end;
$function$;

-- ============================================================
-- 3. Proveedores y categorías de gastos por funciones
-- ============================================================
create or replace function public.proveedor_guardar(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as
$$
declare
    v_uid uuid := refrimar_sesion_uid(30);
    v_id uuid := nullif(p->>'id', '')::uuid;
    v_nombre text := nullif(left(trim(coalesce(p->>'nombre', '')), 160), '');
    v_rif text := nullif(upper(left(trim(coalesce(p->>'rif', '')), 30)), '');
    r record;
begin
    if v_uid is null then raise exception 'Tu sesión venció. Vuelve a entrar.'; end if;
    if not (refrimar_tiene_permiso(v_uid, 'proveedores') or refrimar_tiene_permiso(v_uid, 'compras') or refrimar_tiene_permiso(v_uid, 'editar_inventario')) then
        raise exception 'Tu usuario no puede editar proveedores';
    end if;
    if v_nombre is null then raise exception 'El nombre del proveedor es obligatorio'; end if;
    if v_rif is not null and exists (select 1 from proveedores where refrimar_norm(rif) = refrimar_norm(v_rif) and id is distinct from v_id) then
        raise exception 'Ya existe un proveedor con el RIF %', v_rif;
    end if;
    if v_id is null then
        insert into proveedores (nombre, rif, telefono, email, direccion)
        values (v_nombre, v_rif, nullif(left(trim(coalesce(p->>'telefono', '')), 40), ''), nullif(left(trim(coalesce(p->>'email', '')), 120), ''), nullif(left(trim(coalesce(p->>'direccion', '')), 300), ''))
        returning id, nombre, rif into r;
    else
        update proveedores set nombre = v_nombre, rif = v_rif,
            telefono = nullif(left(trim(coalesce(p->>'telefono', '')), 40), ''), email = nullif(left(trim(coalesce(p->>'email', '')), 120), ''),
            direccion = nullif(left(trim(coalesce(p->>'direccion', '')), 300), '')
        where id = v_id returning id, nombre, rif into r;
        if not found then raise exception 'Proveedor no encontrado'; end if;
    end if;
    return jsonb_build_object('id', r.id, 'nombre', r.nombre, 'rif', r.rif);
end;
$$;
revoke execute on function public.proveedor_guardar(jsonb) from public, anon;
grant execute on function public.proveedor_guardar(jsonb) to anon, authenticated;

create or replace function public.proveedor_eliminar(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as
$$
declare v_uid uuid := refrimar_sesion_uid(30);
begin
    if v_uid is null then raise exception 'Tu sesión venció. Vuelve a entrar.'; end if;
    if not (refrimar_tiene_permiso(v_uid, 'proveedores') or refrimar_tiene_permiso(v_uid, 'compras')) then raise exception 'Tu usuario no puede eliminar proveedores'; end if;
    begin
        delete from proveedores where id = p_id;
    exception when foreign_key_violation then
        raise exception 'No se puede eliminar: tiene órdenes o facturas asociadas';
    end;
    return jsonb_build_object('ok', true);
end;
$$;
revoke execute on function public.proveedor_eliminar(uuid) from public, anon;
grant execute on function public.proveedor_eliminar(uuid) to anon, authenticated;

create or replace function public.gasto_categoria_guardar(p_nombre text)
returns jsonb language plpgsql security definer set search_path = public as
$$
declare v_uid uuid := refrimar_sesion_uid(30); v_n text := nullif(left(trim(coalesce(p_nombre, '')), 80), ''); v_id uuid;
begin
    if v_uid is null then raise exception 'Tu sesión venció. Vuelve a entrar.'; end if;
    if not (refrimar_tiene_permiso(v_uid, 'gastos') or refrimar_tiene_permiso(v_uid, 'gestionar_finanzas')) then raise exception 'Tu usuario no puede editar gastos'; end if;
    if v_n is null then raise exception 'Escribe el nombre de la categoría'; end if;
    select id into v_id from gasto_categorias where lower(nombre) = lower(v_n);
    if v_id is null then insert into gasto_categorias (nombre) values (v_n) returning id into v_id; end if;
    return jsonb_build_object('id', v_id, 'nombre', v_n);
end;
$$;
revoke execute on function public.gasto_categoria_guardar(text) from public, anon;
grant execute on function public.gasto_categoria_guardar(text) to anon, authenticated;

create or replace function public.gasto_categoria_eliminar(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as
$$
declare v_uid uuid := refrimar_sesion_uid(30);
begin
    if v_uid is null then raise exception 'Tu sesión venció. Vuelve a entrar.'; end if;
    if not (refrimar_tiene_permiso(v_uid, 'gastos') or refrimar_tiene_permiso(v_uid, 'gestionar_finanzas')) then raise exception 'Tu usuario no puede editar gastos'; end if;
    delete from gasto_categorias where id = p_id;
    return jsonb_build_object('ok', true);
end;
$$;
revoke execute on function public.gasto_categoria_eliminar(uuid) from public, anon;
grant execute on function public.gasto_categoria_eliminar(uuid) to anon, authenticated;

do $$ begin
    if to_regclass('public.proveedores') is not null then execute 'revoke insert, update, delete on public.proveedores from anon, authenticated'; end if;
    if to_regclass('public.gasto_categorias') is not null then execute 'revoke insert, update, delete on public.gasto_categorias from anon, authenticated'; end if;
end $$;

-- ============================================================
-- 4. Mínimos de stock con las ventas reales
-- ============================================================
-- Mínimo sugerido = lo que vende en p_cobertura días la tienda que más lo vende (promedio de los últimos p_dias).
-- Productos sin ventas en el período: mínimo 0 (no generan alertas de "por debajo del mínimo").
create or replace function public.productos_minimos_sugeridos(p_dias int default 60, p_cobertura int default 7)
returns jsonb language plpgsql stable security definer set search_path = public as
$$
declare
    CASA constant uuid := '00000000-0000-0000-0000-000000000001';
    v_uid uuid := refrimar_sesion_uid(30);
    v_dias int := least(greatest(coalesce(p_dias, 60), 14), 365);
    v_cob int := least(greatest(coalesce(p_cobertura, 7), 1), 60);
begin
    if v_uid is null then raise exception 'Tu sesión venció. Vuelve a entrar.'; end if;
    if not refrimar_tiene_permiso(v_uid, 'ver_inventario') then raise exception 'Tu usuario no puede ver el inventario'; end if;
    return coalesce((select jsonb_agg(x order by (x->>'diaria')::numeric desc) from (
        select jsonb_build_object('codigo', p.codigo, 'descripcion', p.descripcion, 'unidad', p.unidad, 'stock', p.stock,
                                  'actual', p.stock_minimo, 'diaria', round(coalesce(v.diaria, 0), 3), 'ventas', coalesce(v.ventas, 0),
                                  'sugerido', case when coalesce(v.ventas, 0) < 2 then 0
                                                   when p.unidad in ('kg', 'mt', 'm', 'lt') then round(coalesce(v.diaria, 0) * v_cob, 1)
                                                   else greatest(ceil(coalesce(v.diaria, 0) * v_cob), 1) end) x
        from productos p
        left join (
            select cod, max(vendido) / v_dias diaria, sum(n) ventas
            from (select d.producto_codigo cod, coalesce(ve.sucursal_id, CASA) suc, sum(d.cantidad) vendido, count(distinct ve.id) n
                  from detalle_venta d join ventas ve on ve.id = d.venta_id
                  where ve.estado = 'completada' and ve.created_at >= now() - make_interval(days => v_dias)
                  group by 1, 2) t
            group by cod) v on v.cod = p.codigo
        where p.activo is not false and coalesce(p.tipo_producto, 'fisico') = 'fisico' and not coalesce(p.es_kit, false)
    ) q), '[]'::jsonb);
end;
$$;
revoke execute on function public.productos_minimos_sugeridos(int, int) from public, anon;
grant execute on function public.productos_minimos_sugeridos(int, int) to anon, authenticated;

-- Aplica mínimos distintos a muchos productos de una vez; queda en "Cambios masivos" con Deshacer
create or replace function public.productos_minimos_aplicar(p_items jsonb)
returns jsonb language plpgsql security definer set search_path = public as
$$
declare v_uid uuid := refrimar_sesion_uid(30); v_usuario text; v_antes jsonb; v_id uuid; v_n int;
begin
    if v_uid is null then raise exception 'Tu sesión venció. Vuelve a entrar.'; end if;
    if not refrimar_tiene_permiso(v_uid, 'editar_inventario') then raise exception 'Tu usuario no puede editar productos'; end if;
    select nombre into v_usuario from usuarios where id = v_uid;
    if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'No hay mínimos para aplicar'; end if;
    if jsonb_array_length(p_items) > 5000 then raise exception 'Máximo 5000 productos'; end if;
    with nuevos as (
        select x->>'codigo' codigo, (x->>'minimo')::numeric minimo from jsonb_array_elements(p_items) x
        where (x->>'minimo')::numeric >= 0 and (x->>'minimo')::numeric <= 100000)
    select coalesce(jsonb_agg(jsonb_build_object('codigo', p.codigo, 'antes', p.stock_minimo, 'nuevo', n.minimo)), '[]')
    into v_antes
    from nuevos n join productos p on p.codigo = n.codigo
    where p.stock_minimo is distinct from n.minimo;
    update productos p set stock_minimo = (x->>'nuevo')::numeric, updated_at = now()
    from jsonb_array_elements(v_antes) x where p.codigo = x->>'codigo';
    v_n := jsonb_array_length(v_antes);
    if v_n > 0 then
        insert into cambios_masivos (campo, valor, cantidad, antes, usuario_nombre)
        values ('stock_minimo', 'según ventas', v_n, v_antes, v_usuario) returning id into v_id;
    end if;
    return jsonb_build_object('ok', true, 'cambiados', v_n, 'id', v_id);
end;
$$;
revoke execute on function public.productos_minimos_aplicar(jsonb) from public, anon;
grant execute on function public.productos_minimos_aplicar(jsonb) to anon, authenticated;

-- Deshacer (igual que antes; ahora también deshace los mínimos distintos por producto)
create or replace function public.productos_cambio_deshacer(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as
$$
declare v_uid uuid := refrimar_sesion_uid(30); c record; x jsonb; v_n int := 0;
begin
    if v_uid is null then raise exception 'Tu sesión venció. Vuelve a entrar.'; end if;
    if not refrimar_tiene_permiso(v_uid, 'editar_inventario') then raise exception 'Tu usuario no puede editar productos'; end if;
    select * into c from cambios_masivos where id = p_id for update;
    if not found then raise exception 'Ese cambio no existe'; end if;
    if c.deshecho_at is not null then raise exception 'Ese cambio ya se deshizo'; end if;
    for x in select value from jsonb_array_elements(c.antes) loop
        if c.campo = 'ubicacion' and c.sucursal_id is not null then
            update sucursal_stock set ubicacion = x->>'antes'
            where sucursal_id = c.sucursal_id and producto_codigo = x->>'codigo' and ubicacion is not distinct from c.valor;
        elsif c.campo = 'categoria' then update productos set categoria = x->>'antes' where codigo = x->>'codigo' and categoria is not distinct from c.valor;
        elsif c.campo = 'marca' then update productos set marca = x->>'antes' where codigo = x->>'codigo' and marca is not distinct from c.valor;
        elsif c.campo = 'ubicacion' then update productos set ubicacion = x->>'antes' where codigo = x->>'codigo' and ubicacion is not distinct from c.valor;
        elsif c.campo = 'proveedor' then update productos set proveedores = array_remove(proveedores, c.valor) where codigo = x->>'codigo';
        elsif c.campo = 'garantia_dias' then update productos set garantia_dias = (x->>'antes')::int where codigo = x->>'codigo' and garantia_dias is not distinct from c.valor::int;
        elsif c.campo = 'stock_minimo' then update productos set stock_minimo = (x->>'antes')::numeric where codigo = x->>'codigo' and stock_minimo = coalesce((x->>'nuevo')::numeric, c.valor::numeric);
        end if;
        if found then v_n := v_n + 1; end if;
    end loop;
    update cambios_masivos set deshecho_at = now() where id = p_id;
    return jsonb_build_object('ok', true, 'restaurados', v_n);
end;
$$;
revoke execute on function public.productos_cambio_deshacer(uuid) from public, anon;
grant execute on function public.productos_cambio_deshacer(uuid) to anon, authenticated;

-- ============================================================
-- Seguridad y registro
-- ============================================================
insert into public.seguridad_rpc (nombre, nivel, permiso, gracia_dias)
select v.* from (values ('proveedor_guardar', 'sesion', null, 0), ('proveedor_eliminar', 'sesion', null, 0),
                        ('gasto_categoria_guardar', 'sesion', null, 0), ('gasto_categoria_eliminar', 'sesion', null, 0),
                        ('productos_minimos_sugeridos', 'sesion', null, 0), ('productos_minimos_aplicar', 'sesion', null, 0)) as v(nombre, nivel, permiso, gracia)
where not exists (select 1 from public.seguridad_rpc s where s.nombre = v.nombre);

insert into public.migraciones_aplicadas (nombre, descripcion, version_app)
values ('2026-11-17-etapa6-seguridad-api-minimos', 'Guardián de la API sin fallas abiertas, proveedores por funciones y mínimos según ventas', 'v3.9.29')
on conflict (nombre) do nothing;
notify pgrst, 'reload schema';

-- Comprobación. "servicio_configurado" en false = el resumen de WhatsApp y los recordatorios automáticos no
-- pueden entrar hasta configurar el token de servicio (avísale a Claude).
select (select modo from seguridad_config where id = 1) as modo,
       exists (select 1 from seguridad_config where id = 1 and servicio_token_hash is not null) as servicio_configurado,
       has_table_privilege('anon', 'public.proveedores', 'insert') as internet_crea_proveedores;
