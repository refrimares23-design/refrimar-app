-- ============================================================
-- ASISTENTE DE PRIMERA CONFIGURACIÓN
-- ------------------------------------------------------------
-- • config_opciones_guardar: guarda opciones sueltas (se suman a las que ya hay).
-- • config_fiscal_guardar: datos fiscales con el RIF validado (y el logo).
-- • asistente_estado: qué está listo y qué falta, contado en la base de datos.
-- Se corre sobre public; las empresas lo reciben con saas.sincronizar_todas().
-- Se puede correr varias veces.
-- ============================================================

create or replace function config_opciones_guardar(p_opciones jsonb)
returns jsonb
language plpgsql security definer
set search_path = public
as $$
declare v_id uuid;
begin
    if jsonb_typeof(p_opciones) <> 'object' then raise exception 'Opciones inválidas'; end if;
    if p_opciones ? 'logo' and length(coalesce(p_opciones ->> 'logo', '')) > 120000 then raise exception 'El logo es muy pesado: usa una imagen más pequeña'; end if;
    select id into v_id from configuracion limit 1;
    if v_id is null then
        insert into configuracion (nombre_negocio, opciones) values ('Mi empresa', p_opciones);
    else
        update configuracion set opciones = coalesce(opciones, '{}'::jsonb) || (p_opciones - 'iva_incluido'),
            iva_incluido = case when p_opciones ? 'iva_incluido' then coalesce((p_opciones ->> 'iva_incluido')::boolean, iva_incluido) else iva_incluido end,
            updated_at = now() where id = v_id;
    end if;
    return jsonb_build_object('ok', true);
end;
$$;
grant execute on function config_opciones_guardar(jsonb) to anon, authenticated;

-- RIF venezolano (letra, 8 dígitos y dígito verificador)
create or replace function rif_valido(p text)
returns boolean language plpgsql immutable as $$
declare d text := upper(regexp_replace(coalesce(p, ''), '[^A-Za-z0-9]', '', 'g')); s int; pesos int[] := array[3, 2, 7, 6, 5, 4, 3, 2]; i int; v int;
begin
    if d !~ '^[VEJPGC][0-9]{9}$' then return false; end if;
    s := 4 * (case substr(d, 1, 1) when 'V' then 1 when 'E' then 2 when 'J' then 3 when 'P' then 4 when 'G' then 5 when 'C' then 3 end);
    for i in 1..8 loop s := s + substr(d, i + 1, 1)::int * pesos[i]; end loop;
    v := 11 - (s % 11);
    if v >= 10 then v := 0; end if;
    return v = substr(d, 10, 1)::int;
end;
$$;
grant execute on function rif_valido(text) to anon, authenticated;

create or replace function config_fiscal_guardar(p jsonb)
returns jsonb
language plpgsql security definer
set search_path = public
as $$
declare
    v_id uuid; v_rif text := upper(regexp_replace(coalesce(p ->> 'rif', ''), '[^A-Za-z0-9]', '', 'g'));
    v_razon text := nullif(trim(coalesce(p ->> 'razon_social', '')), '');
    v_extra jsonb := '{}'::jsonb;
begin
    if v_razon is null then raise exception 'Escribe la razón social'; end if;
    if not rif_valido(v_rif) then raise exception 'El RIF no es válido. Escríbelo así: J-12345678-9'; end if;
    v_rif := substr(v_rif, 1, 1) || '-' || substr(v_rif, 2, 8) || '-' || substr(v_rif, 10, 1);
    if p ? 'nombre_comercial' then v_extra := v_extra || jsonb_build_object('nombre_comercial', nullif(trim(p ->> 'nombre_comercial'), '')); end if;
    if p ? 'logo' then
        if length(coalesce(p ->> 'logo', '')) > 120000 then raise exception 'El logo es muy pesado: usa una imagen más pequeña'; end if;
        v_extra := v_extra || jsonb_build_object('logo', nullif(p ->> 'logo', ''));
    end if;
    if p ? 'ciudad' then v_extra := v_extra || jsonb_build_object('ciudad', nullif(trim(p ->> 'ciudad'), '')); end if;
    if p ? 'estado_ve' then v_extra := v_extra || jsonb_build_object('estado_ve', nullif(trim(p ->> 'estado_ve'), '')); end if;
    select id into v_id from configuracion limit 1;
    if v_id is null then
        insert into configuracion (nombre_negocio, rif, direccion, telefono, email, opciones)
        values (v_razon, v_rif, nullif(trim(p ->> 'direccion'), ''), nullif(trim(p ->> 'telefono'), ''), nullif(lower(trim(p ->> 'email')), ''), v_extra);
    else
        update configuracion set nombre_negocio = v_razon, rif = v_rif,
            direccion = nullif(trim(coalesce(p ->> 'direccion', '')), ''), telefono = nullif(trim(coalesce(p ->> 'telefono', '')), ''),
            email = nullif(lower(trim(coalesce(p ->> 'email', ''))), ''),
            opciones = coalesce(opciones, '{}'::jsonb) || v_extra, updated_at = now()
        where id = v_id;
    end if;
    -- La ficha de la empresa en la plataforma queda igual (si es una empresa de la plataforma)
    begin
        if to_regclass('saas.empresas') is not null and current_schema() <> 'public' then
            execute 'update saas.empresas set razon_social = $1, rif = $2, nombre = coalesce($3, nombre), actualizada_at = now() where esquema = $4'
            using v_razon, v_rif, nullif(trim(coalesce(p ->> 'nombre_comercial', '')), ''), current_schema();
        end if;
    exception when others then null;
    end;
    return jsonb_build_object('ok', true, 'rif', v_rif);
end;
$$;
grant execute on function config_fiscal_guardar(jsonb) to anon, authenticated;

-- Qué está listo (contado de verdad) para el tablero "lo que te falta"
create or replace function asistente_estado()
returns jsonb
language plpgsql stable security definer
set search_path = public
as $$
declare c record; o jsonb; r jsonb;
begin
    select * into c from configuracion limit 1;
    o := coalesce(c.opciones, '{}'::jsonb);
    r := jsonb_build_object(
        'fiscal', c.rif is not null and rif_valido(c.rif) and c.nombre_negocio is not null and coalesce(c.direccion, '') <> '',
        'logo', coalesce(o ->> 'logo', '') <> '',
        'rubro', coalesce(c.rubro, '') <> '' and (coalesce((o ->> 'rubro_confirmado')::boolean, false) or current_schema() = 'public'),
        'sucursales', (select count(*) from sucursales),
        'tasa', coalesce(c.tasa_bcv_manual, 0) > 0,
        'usuarios', (select count(*) from usuarios where activo is not false),
        'productos', (select count(*) from productos where activo is not false),
        'con_stock', (select count(*) from productos where coalesce(stock, 0) > 0) + coalesce((select count(*) from sucursal_stock where stock > 0), 0),
        'clientes', (select count(*) from clientes),
        'clientes_saldo', (select count(*) from clientes where coalesce(saldo_pendiente, 0) > 0),
        'proveedores', (select count(*) from proveedores),
        'cxp', case when to_regclass('compras_proveedores') is null then 0 else (select count(*) from compras_proveedores) end,
        'ventas', (select count(*) from ventas),
        'opciones', o - 'logo'
    );
    return r;
end;
$$;
grant execute on function asistente_estado() to anon, authenticated;

do $$ begin
    if to_regclass('public.seguridad_rpc') is not null then
        insert into seguridad_rpc (nombre, nivel, permiso) values
            ('config_opciones_guardar', 'permiso', 'configuracion'),
            ('config_fiscal_guardar', 'permiso', 'configuracion'),
            ('asistente_estado', 'sesion', null),
            ('rif_valido', 'publico', null)
        on conflict (nombre) do update set nivel = excluded.nivel, permiso = excluded.permiso;
    end if;
end $$;

-- Empresas de la plataforma: reciben estas funciones y sus permisos
do $$ begin
    if to_regprocedure('saas.sincronizar_todas()') is not null then perform saas.sincronizar_todas(); end if;
end $$;
notify pgrst, 'reload schema';
select 'Asistente listo' as resultado;
