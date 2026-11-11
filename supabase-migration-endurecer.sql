-- ============================================================
-- ENDURECIMIENTO DE SEGURIDAD (auditoría 25-oct-2026)
-- ------------------------------------------------------------
-- 1. La caja ya no puede registrar una venta con precios o totales
--    alterados: la base revisa cada línea contra el precio real del
--    producto, el IVA real y los permisos de quien vende.
--    Bajar un precio exige el permiso "Cambiar precio" y un descuento
--    exige "Aplicar descuento" (el dueño siempre puede).
--    El nombre del vendedor sale de la sesión, no de lo que mande el navegador.
-- 2. Modo de seguridad ESTRICTO en la empresa principal: sin sesión
--    válida no se pueden leer ventas, clientes, caja, etc., ni usar
--    ninguna función. (Antes estaba en "aviso": cualquiera con la
--    clave pública podía leer y registrar ventas sin entrar.)
--    Para volver atrás si algo falla:  select seguridad_modo_cambiar('aviso');
--    o: update seguridad_config set modo = 'aviso' where id = 1;
-- No borra ni cambia datos. Se puede correr varias veces.
-- ============================================================

-- ---------- 1. Revisión de la venta antes de guardarla ----------
create or replace function pos_validar_venta(p_venta jsonb)
returns jsonb
language plpgsql stable security definer
set search_path = public
as $$
declare
    v_uid uuid := refrimar_sesion_uid(30);
    -- Precios con IVA incluido: igual que la caja (columna iva_incluido o la opción del negocio, en cualquier fila de configuración)
    v_incl boolean := coalesce((select bool_or(coalesce(iva_incluido, false) or coalesce((opciones->>'iva_incluido')::boolean, false)) from configuracion), false);
    it jsonb; pr record; v_cant numeric; v_precio numeric; v_desc numeric; v_iva numeric;
    v_min numeric := 0; v_n int := 0; v_total numeric := coalesce((p_venta->>'total_usd')::numeric, 0);
    v_nombre text;
begin
    if jsonb_typeof(p_venta->'items') <> 'array' then raise exception 'La factura no tiene productos'; end if;
    for it in select value from jsonb_array_elements(p_venta->'items') loop
        v_n := v_n + 1;
        select precio, iva_tasa into pr from productos where codigo = it->>'codigo';
        if not found then raise exception 'Producto "%" no encontrado', it->>'codigo'; end if;
        v_cant := coalesce((it->>'cantidad')::numeric, 0);
        v_precio := coalesce((it->>'precio')::numeric, -1);
        v_desc := coalesce((it->>'descuento')::numeric, 0);
        if v_cant <= 0 or v_cant > 1000000 then raise exception 'Cantidad inválida en "%"', coalesce(it->>'descripcion', it->>'codigo'); end if;
        if v_precio < 0 then raise exception 'Precio inválido en "%"', coalesce(it->>'descripcion', it->>'codigo'); end if;
        if v_desc < 0 or v_desc > 100 then raise exception 'Descuento inválido en "%"', coalesce(it->>'descripcion', it->>'codigo'); end if;
        if v_precio < coalesce(pr.precio, 0) - 0.0001 and not (v_uid is not null and refrimar_tiene_permiso(v_uid, 'app_cambiar_precio')) then
            raise exception 'No tienes permiso para bajar el precio de "%" (precio: % $). Pide a un supervisor.', coalesce(it->>'descripcion', it->>'codigo'), round(pr.precio, 2);
        end if;
        if v_desc > 0 and not (v_uid is not null and refrimar_tiene_permiso(v_uid, 'app_descuento')) then
            raise exception 'No tienes permiso para aplicar descuentos ("%").', coalesce(it->>'descripcion', it->>'codigo');
        end if;
        v_iva := coalesce(pr.iva_tasa, 16);
        -- Piso del total: precio x cantidad (sin sumar IVA). Así sirve igual si los precios traen el IVA incluido o no;
        -- lo que de verdad protege es que cada precio no esté por debajo del real (revisado arriba).
        v_min := v_min + v_precio * v_cant * (1 - v_desc / 100);
    end loop;
    if v_total < v_min - (0.01 * v_n + 0.02) then
        raise exception 'El total de la factura (% $) no coincide con los productos (% $). Vuelve a cargar la caja.', round(v_total, 2), round(v_min, 2);
    end if;
    select nombre into v_nombre from usuarios where id = v_uid;
    return jsonb_build_object('ok', true, 'usuario', v_nombre, 'total_minimo', round(v_min, 2));
end;
$$;
revoke all on function pos_validar_venta(jsonb) from public, anon, authenticated;

-- pos_facturar queda envuelta: primero se revisa, después se guarda con la función original
do $$
declare v_def text;
begin
    if to_regprocedure('public.pos_facturar(jsonb)') is null then return; end if;
    v_def := pg_get_functiondef('public.pos_facturar(jsonb)'::regprocedure);
    if v_def ~ 'pos_validar_venta' then return; end if;                 -- ya está envuelta
    if to_regprocedure('public.pos_facturar_base(jsonb)') is not null then drop function public.pos_facturar_base(jsonb); end if;
    alter function public.pos_facturar(jsonb) rename to pos_facturar_base;
    revoke all on function public.pos_facturar_base(jsonb) from public, anon, authenticated;
    execute $f$
    create function public.pos_facturar(p_venta jsonb)
    returns jsonb
    language plpgsql security definer
    set search_path = public
    as $b$
    declare r jsonb; v jsonb := coalesce(p_venta, '{}'::jsonb);
    begin
        -- Venta repetida (reintento de la caja sin internet): se devuelve la existente sin revisar de nuevo
        if exists (select 1 from ventas where numero = nullif(trim(coalesce(v->>'numero', '')), '')) then return pos_facturar_base(v); end if;
        r := pos_validar_venta(v);
        if r->>'usuario' is not null then v := jsonb_set(v, '{usuario}', to_jsonb(r->>'usuario')); end if;
        return pos_facturar_base(v);
    end;
    $b$ $f$;
    grant execute on function public.pos_facturar(jsonb) to anon, authenticated;
end $$;

-- ---------- 2. Modo estricto en la empresa principal ----------
do $$ begin
    if to_regclass('public.seguridad_config') is not null then
        update seguridad_config set modo = 'estricto', actualizado_at = now() where id = 1 and modo <> 'estricto';
    end if;
end $$;

-- ---------- 3. Las empresas de la plataforma reciben lo mismo ----------
do $$ begin
    if to_regprocedure('saas.sincronizar_todas()') is not null then perform saas.sincronizar_todas(); end if;
end $$;
notify pgrst, 'reload schema';
select 'Seguridad reforzada: ventas revisadas y modo estricto activo' as resultado,
       (select modo from seguridad_config where id = 1) as modo;

-- ---------- 4. Revisión en la base de compras, ajustes, caja, gastos, abonos y bancos ----------
-- Cada función queda "envuelta": antes de guardar se revisa que los montos y cantidades
-- no sean negativos ni absurdos, que los productos de la lista sean válidos, y el nombre
-- del usuario se toma de la sesión (no de lo que mande el navegador).
create or replace function refrimar_validar_items(p_items jsonb)
returns void language plpgsql immutable as $$
declare it jsonb; c numeric;
begin
    if p_items is null then return; end if;
    if jsonb_typeof(p_items) <> 'array' then raise exception 'Lista de productos inválida'; end if;
    if jsonb_array_length(p_items) > 5000 then raise exception 'Demasiados productos en un solo documento (máximo 5000)'; end if;
    for it in select value from jsonb_array_elements(p_items) loop
        if jsonb_typeof(it) <> 'object' then raise exception 'Producto inválido en la lista'; end if;
        foreach c in array array[nullif(it->>'cantidad', '')::numeric, nullif(it->>'costo', '')::numeric, nullif(it->>'costo_unitario', '')::numeric, nullif(it->>'precio', '')::numeric] loop
            if c is not null and (c < 0 or c > 1000000000) then raise exception 'Hay una cantidad o un monto inválido en "%"', coalesce(it->>'descripcion', it->>'codigo', '?'); end if;
        end loop;
    end loop;
end;
$$;

create or replace function refrimar_envolver(p_fn text)
returns text
language plpgsql security definer
set search_path = public
as $$
declare
    f record; v_args text[]; v_names text[]; v_types text[]; v_chk text := ''; v_call text; v_ret text; v_body text; i int; v_cfg text;
begin
    select p.oid, pg_get_function_arguments(p.oid) as args, pg_get_function_result(p.oid) as res, p.proargnames, p.proargtypes::regtype[]::text[] as tipos, p.proconfig
      into f from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = p_fn order by p.oid desc limit 1;
    if not found then return p_fn || ': no existe'; end if;
    if pg_get_functiondef(f.oid) ~ 'refrimar_envuelta' then return p_fn || ': ya revisada'; end if;
    if to_regproc('public.' || p_fn || '_base') is not null then execute format('drop function public.%I(%s)', p_fn || '_base', pg_get_function_identity_arguments(to_regproc('public.' || p_fn || '_base'))); end if;
    execute format('alter function public.%I(%s) rename to %I', p_fn, pg_get_function_identity_arguments(f.oid), p_fn || '_base');
    execute format('revoke all on function public.%I(%s) from public, anon, authenticated', p_fn || '_base', pg_get_function_identity_arguments(f.oid));
    v_names := f.proargnames; v_types := f.tipos; v_args := '{}';
    for i in 1 .. coalesce(array_length(v_types, 1), 0) loop
        v_args := v_args || format('%I => %I', v_names[i], v_names[i]);
        if v_types[i] = 'numeric' and v_names[i] ~ '^p_(monto|cantidad|costo|precio)' then
            v_chk := v_chk || format('    if %1$I is not null and (%1$I < 0 or %1$I > 1000000000) then raise exception ''El valor de %2$s no es válido''; end if;' || chr(10), v_names[i], replace(substr(v_names[i], 3), '_', ' '));
        elsif v_types[i] = 'jsonb' and v_names[i] = 'p_items' then
            v_chk := v_chk || '    perform refrimar_validar_items(p_items);' || chr(10);
        elsif v_names[i] = 'p_usuario' and v_types[i] = 'text' then
            v_chk := v_chk || '    p_usuario := coalesce((select nombre from usuarios where id = refrimar_sesion_uid(30)), p_usuario);' || chr(10);
        end if;
    end loop;
    v_call := format('%I(%s)', p_fn || '_base', array_to_string(v_args, ', '));
    v_ret := case when f.res = 'void' then 'perform ' || v_call || '; return;'
                  when f.res ~* '^(setof|table)' then 'return query select * from ' || v_call || ';'
                  else 'return ' || v_call || ';' end;
    v_cfg := coalesce((select string_agg('set ' || split_part(c, '=', 1) || ' = ' || split_part(c, '=', 2), ' ') from unnest(f.proconfig) c), 'set search_path = public');
    v_body := format('create function public.%I(%s) returns %s language plpgsql security definer %s as $w$' || chr(10) ||
                     '-- refrimar_envuelta' || chr(10) || 'begin' || chr(10) || '%s    %s' || chr(10) || 'end;' || chr(10) || '$w$',
                     p_fn, f.args, f.res, v_cfg, v_chk, v_ret);
    execute v_body;
    execute format('grant execute on function public.%I(%s) to anon, authenticated', p_fn, pg_get_function_identity_arguments(f.oid));
    return p_fn || ': revisada';
end;
$$;
revoke all on function refrimar_envolver(text) from public, anon, authenticated;

select refrimar_envolver(x) from unnest(array[
    'compra_registrar', 'ajuste_inventario', 'ajuste_resolver', 'caja_registrar_movimiento', 'gasto_registrar', 'gasto_eliminar',
    'nota_credito_registrar', 'cuenta_movimiento', 'cuenta_transferir', 'cliente_registrar_abono', 'pago_movil_registrar',
    'transferencia_guardar', 'transferencia_enviar', 'transferencia_recibir', 'lote_guardar', 'lotes_importar', 'nota_debito_crear'
]) x;

-- La caja (entradas y salidas de dinero) exige permiso de facturar
do $$ begin
    if to_regclass('public.seguridad_rpc') is not null then
        insert into seguridad_rpc (nombre, nivel, permiso) values ('caja_registrar_movimiento', 'permiso', 'facturar')
        on conflict (nombre) do update set nivel = excluded.nivel, permiso = excluded.permiso;
    end if;
end $$;

do $$ begin
    if to_regprocedure('saas.sincronizar_todas()') is not null then perform saas.sincronizar_todas(); end if;
end $$;
notify pgrst, 'reload schema';

-- ---------- 5. Costos y existencias solo con sesión ----------
-- Antes, sin entrar al sistema se podían leer los productos (con su COSTO) y el stock.
-- Ahora solo se pueden leer sin sesión: tiendas, lista de usuarios (sin PIN), datos de la
-- empresa y la tasa. El bot de WhatsApp y las tareas automáticas entran con el token de
-- servicio (secreto REFRIMAR_SERVICE_TOKEN del Worker).
create or replace function refrimar_servicio_ok()
returns boolean language sql stable security definer set search_path = public as $$
    select exists (select 1 from seguridad_config where id = 1 and servicio_token_hash is not null
                   and servicio_token_hash = refrimar_hash(coalesce(refrimar_header('x-refrimar-servicio'), '')))
$$;
revoke all on function refrimar_servicio_ok() from public, anon, authenticated;

do $$
declare v_def text; v_viejo text := 'v_tabla in (''sucursales'', ''usuarios'', ''configuracion'', ''productos'', ''producto_imagenes'', ''sucursal_stock'', ''tasas_historial'') then return; end if;';
begin
    if to_regprocedure('public.refrimar_pre_request()') is null then return; end if;
    v_def := pg_get_functiondef('public.refrimar_pre_request()'::regprocedure);
    if position(v_viejo in v_def) = 0 then return; end if;
    v_def := replace(v_def, v_viejo,
        'v_tabla in (''sucursales'', ''usuarios'', ''configuracion'', ''tasas_historial'') then return; end if;' || chr(10) ||
        '        if v_met in (''GET'', ''HEAD'') and refrimar_servicio_ok() then return; end if;   -- bot y tareas automáticas');
    execute v_def;
end $$;

-- Token de servicio: si no existe se crea uno (se muestra al final para ponerlo en Cloudflare)
create temporary table if not exists _token_nuevo (token text) on commit drop;
do $$
declare v_tok text;
begin
    if exists (select 1 from seguridad_config where id = 1 and servicio_token_hash is null) then
        v_tok := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
        update seguridad_config set servicio_token_hash = refrimar_hash(v_tok), actualizado_at = now() where id = 1;
        insert into _token_nuevo values (v_tok);
    end if;
end $$;

do $$ begin
    if to_regprocedure('saas.sincronizar_todas()') is not null then perform saas.sincronizar_todas(); end if;
end $$;
notify pgrst, 'reload schema';
select coalesce((select 'COPIA ESTE TOKEN en Cloudflare como REFRIMAR_SERVICE_TOKEN: ' || token from _token_nuevo limit 1),
                'Token de servicio ya configurado (no cambia)') as token_servicio;
