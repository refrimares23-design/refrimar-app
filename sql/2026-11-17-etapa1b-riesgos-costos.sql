-- ============================================================
-- REFRIMAR — Etapa 1b (17-nov-2026): la pantalla de Riesgos solo muestra costos a quien puede verlos
-- (la versión anterior de riesgos_resumen le mostraba el costo a cualquiera con permiso de inventario).
-- Supabase → SQL Editor → New query → pega TODO → Run. Se puede correr varias veces.
-- ============================================================
create schema if not exists respaldo_inventario;
revoke all on schema respaldo_inventario from anon, authenticated, public;
do $$ begin
    execute format('create table if not exists respaldo_inventario.%I as table public.productos',
                   'productos_' || to_char(now() at time zone 'America/Caracas', 'YYYYMMDD_HH24MISS'));
end $$;

create or replace function public.riesgos_resumen()
returns jsonb language plpgsql stable security definer set search_path = public as
$$
declare
    v_uid uuid := refrimar_sesion_uid(30);
    v_costos boolean;
    v_incl boolean := coalesce((select bool_or(coalesce(iva_incluido, false) or coalesce((opciones->>'iva_incluido')::boolean, false)) from configuracion), false);
begin
    if v_uid is null then raise exception 'Tu sesión venció. Vuelve a entrar.'; end if;
    if not refrimar_tiene_permiso(v_uid, 'ver_inventario') then raise exception 'Sin permiso para ver el inventario'; end if;
    v_costos := refrimar_tiene_permiso(v_uid, 'ver_costos');
    return jsonb_build_object(
        'ver_costos', v_costos,
        'stock_negativo', coalesce((
            select jsonb_agg(x order by x->>'tienda', x->>'descripcion') from (
                select jsonb_build_object('codigo', codigo, 'descripcion', descripcion, 'tienda', 'Principal', 'stock', stock) x
                from productos where stock < 0 and coalesce(tipo_producto, 'fisico') = 'fisico'
                union all
                select jsonb_build_object('codigo', ss.producto_codigo, 'descripcion', coalesce(p.descripcion, ss.producto_descripcion), 'tienda', s.nombre, 'stock', ss.stock)
                from sucursal_stock ss join sucursales s on s.id = ss.sucursal_id left join productos p on p.codigo = ss.producto_codigo
                where ss.stock < 0 and coalesce(p.tipo_producto, 'fisico') = 'fisico'
                limit 500) q), '[]'::jsonb),
        'margen_negativo', case when not v_costos then '[]'::jsonb else coalesce((
            select jsonb_agg(jsonb_build_object('codigo', codigo, 'descripcion', descripcion, 'costo', round(costo, 4), 'precio', precio,
                                                'precio_sin_iva', round(psi, 4)) order by descripcion)
            from (select codigo, descripcion, costo, precio,
                         case when v_incl then precio / (1 + coalesce(iva_tasa, 16) / 100) else precio end as psi
                  from productos where activo is not false and precio > 0 and costo > 0) q
            where psi < costo), '[]'::jsonb) end,
        'sin_precio', coalesce((
            select jsonb_agg(jsonb_build_object('codigo', codigo, 'descripcion', descripcion, 'stock', stock) order by descripcion)
            from (select codigo, descripcion, stock from productos
                  where activo is not false and coalesce(precio, 0) <= 0 and coalesce(tipo_producto, 'fisico') = 'fisico' limit 500) q), '[]'::jsonb),
        'facturas_repetidas', case when not refrimar_tiene_permiso(v_uid, 'ver_cxp') then '[]'::jsonb else coalesce((
            select jsonb_agg(jsonb_build_object('numero', numero, 'proveedor', proveedor, 'veces', n, 'monto_usd', total))
            from (select min(numero) numero, min(proveedor) proveedor, count(*) n, sum(monto_usd) total
                  from compras_proveedores where refrimar_norm(numero) <> ''
                  group by refrimar_norm(numero), coalesce(proveedor_id::text, refrimar_norm_proveedor(proveedor))
                  having count(*) > 1) q), '[]'::jsonb) end
    );
end;
$$;
revoke execute on function public.riesgos_resumen() from public, anon;
grant execute on function public.riesgos_resumen() to anon, authenticated;

insert into public.migraciones_aplicadas (nombre, descripcion, version_app)
values ('2026-11-17-etapa1b-riesgos-costos', 'riesgos_resumen sin costos para quien no los ve; lista de productos sin precio', 'v3.9.23')
on conflict (nombre) do nothing;
notify pgrst, 'reload schema';
select 'Listo' as resultado;
