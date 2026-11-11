-- ============================================================
-- REFRIMAR — REEMPLAZAR EL CATÁLOGO DESDE UN EXCEL
-- ------------------------------------------------------------
-- Opción del importador "Productos que NO están en el archivo → Desactivarlos".
-- • No se borra nada: las ventas, facturas y kardex viejos se conservan.
-- • Los desactivados no salen en la caja ni en las búsquedas; se pueden reactivar.
-- • Servicios y combos no se tocan.
-- • "Deshacer importación" también los vuelve a activar.
-- Se puede correr varias veces.
-- ============================================================

create or replace function importacion_desactivar_faltantes(p_id uuid, p_codigos text[], p_usuario text default 'Sistema')
returns jsonb
language plpgsql security definer
set search_path = public
as $$
declare v_n int := 0; v_suc uuid;
begin
    select sucursal_id into v_suc from importaciones_productos where id = p_id and deshecha_at is null and estado in ('en_curso', 'completada');
    if not found then raise exception 'La importación no existe o ya se deshizo'; end if;
    if coalesce(array_length(p_codigos, 1), 0) = 0 then raise exception 'El archivo no trae códigos'; end if;

    -- Respaldo: cómo estaba cada producto antes de desactivarlo
    insert into importacion_cambios (importacion_id, codigo, accion, antes, sucursal_id)
    select p_id, p.codigo, 'desactivado', to_jsonb(p), null
    from productos p
    where coalesce(p.activo, true)
      and lower(p.codigo) <> all (select lower(c) from unnest(p_codigos) c)
      and coalesce(to_jsonb(p)->>'tipo_producto', 'fisico') <> 'servicio'
      and coalesce((to_jsonb(p)->>'es_kit')::boolean, false) = false
      and not exists (select 1 from importacion_cambios x where x.importacion_id = p_id and x.codigo = p.codigo);

    update productos p set activo = false
    from importacion_cambios x
    where x.importacion_id = p_id and x.accion = 'desactivado' and x.codigo = p.codigo and coalesce(p.activo, true);
    get diagnostics v_n = row_count;

    return jsonb_build_object('ok', true, 'desactivados', v_n);
end;
$$;
grant execute on function importacion_desactivar_faltantes(uuid, text[], text) to anon, authenticated;

-- Deshacer: igual que antes + reactiva los que se desactivaron por no venir en el archivo
create or replace function importacion_deshacer(p_id uuid, p_usuario text default 'Sistema')
returns jsonb
language plpgsql security definer
set search_path = public
as $$
declare
    imp record; c record; v_cols text; v_actual numeric; v_nuevo numeric; v_delta numeric;
    n_rest int := 0; n_desact int := 0; n_stock int := 0; n_react int := 0;
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
        elsif c.accion = 'desactivado' then
            update productos set activo = coalesce((c.antes->>'activo')::boolean, true) where codigo = c.codigo;
            n_react := n_react + 1;
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
        deshacer_resumen = jsonb_build_object('restaurados', n_rest, 'desactivados', n_desact, 'stock', n_stock, 'reactivados', n_react)
    where id = p_id;
    return jsonb_build_object('ok', true, 'restaurados', n_rest, 'desactivados', n_desact, 'stock', n_stock, 'reactivados', n_react);
end;
$$;
grant execute on function importacion_deshacer(uuid, text) to anon, authenticated;

do $$ begin
    if to_regclass('public.seguridad_rpc') is not null then
        insert into seguridad_rpc (nombre, nivel, permiso) values ('importacion_desactivar_faltantes', 'permiso', 'importar_productos')
        on conflict (nombre) do update set nivel = excluded.nivel, permiso = excluded.permiso;
    end if;
end $$;

notify pgrst, 'reload schema';
select 'Reemplazar catálogo listo' as resultado;
