-- ============================================================
-- REFRIMAR — Etapa 6b (17-nov-2026): textos del resumen de WhatsApp
-- Solo corrige el texto de una alerta ("1 con existencia negativa" → "1 producto con existencia negativa").
-- Supabase → SQL Editor → New query → pega TODO → Run. Se puede correr varias veces. No borra nada.
-- ============================================================
create or replace function public.refrimar_alertas(p_uid uuid)
returns jsonb language plpgsql stable security definer set search_path = public as
$$
declare
    CASA constant uuid := '00000000-0000-0000-0000-000000000001';
    v_hoy date := (now() at time zone 'America/Caracas')::date;
    v_inv boolean := p_uid is null or refrimar_tiene_permiso(p_uid, 'ver_inventario');
    v_costos boolean := p_uid is null or refrimar_tiene_permiso(p_uid, 'ver_costos');
    v_cxc boolean := p_uid is null or refrimar_tiene_permiso(p_uid, 'ver_cxc');
    v_cxp boolean := p_uid is null or refrimar_tiene_permiso(p_uid, 'ver_cxp') or refrimar_tiene_permiso(p_uid, 'compras');
    v_cot boolean := p_uid is null or refrimar_tiene_permiso(p_uid, 'cotizar');
    v_caja boolean := p_uid is null or refrimar_tiene_permiso(p_uid, 'caja_admin');
    v_fact boolean := p_uid is null or refrimar_tiene_permiso(p_uid, 'facturar');
    v_fin boolean := p_uid is null or refrimar_tiene_permiso(p_uid, 'ver_finanzas');
    v_incl boolean := coalesce((select bool_or(coalesce(iva_incluido, false) or coalesce((opciones->>'iva_incluido')::boolean, false)) from configuracion), false);
    a jsonb := '[]'::jsonb;
    n int; m numeric; t text; v_d date;
begin
    if v_inv then
        -- Agotados que sí se venden (vendidos en los últimos 30 días en esa tienda)
        select count(*), string_agg(descripcion, ', ' order by vendido desc) filter (where rn <= 4) into n, t
        from (select p.descripcion, v.vendido, row_number() over (order by v.vendido desc) rn
              from (select coalesce(ve.sucursal_id, CASA) suc, d.producto_codigo cod, sum(d.cantidad) vendido
                    from detalle_venta d join ventas ve on ve.id = d.venta_id
                    where ve.estado = 'completada' and ve.created_at >= now() - interval '30 days'
                    group by 1, 2) v
              join productos p on p.codigo = v.cod
              where coalesce(p.tipo_producto, 'fisico') = 'fisico' and p.activo is not false and not coalesce(p.es_kit, false)
                and stock_en(v.cod, v.suc) <= 0) q;
        if n > 0 then a := a || jsonb_build_object('clave', 'agotados', 'nivel', 'alta', 'cantidad', n, 'href', 'inventario.html',
            'titulo', n || case when n = 1 then ' producto agotado que se vende' else ' productos agotados que se venden' end,
            'detalle', t || case when n > 4 then '…' else '' end); end if;

        -- Por debajo del mínimo (solo los que se vendieron en los últimos 60 días)
        select count(*), string_agg(descripcion, ', ') filter (where rn <= 4) into n, t
        from (select p.descripcion, row_number() over (order by p.descripcion) rn
              from (select distinct coalesce(ve.sucursal_id, CASA) suc, d.producto_codigo cod
                    from detalle_venta d join ventas ve on ve.id = d.venta_id
                    where ve.estado = 'completada' and ve.created_at >= now() - interval '60 days') v
              join productos p on p.codigo = v.cod
              where coalesce(p.tipo_producto, 'fisico') = 'fisico' and p.activo is not false and not coalesce(p.es_kit, false)
                and coalesce(p.stock_minimo, 0) > 0
                and stock_en(v.cod, v.suc) > 0 and stock_en(v.cod, v.suc) <= p.stock_minimo) q;
        if n > 0 then a := a || jsonb_build_object('clave', 'minimo', 'nivel', 'media', 'cantidad', n, 'href', 'oc-form.html',
            'titulo', n || case when n = 1 then ' producto por debajo del mínimo' else ' productos por debajo del mínimo' end,
            'detalle', t || case when n > 4 then '…' else '' end || ' · Haz el pedido'); end if;

        select (select count(*) from productos where stock < 0 and coalesce(tipo_producto, 'fisico') = 'fisico')
             + (select count(*) from sucursal_stock ss left join productos p on p.codigo = ss.producto_codigo
                where ss.stock < 0 and coalesce(p.tipo_producto, 'fisico') = 'fisico') into n;
        if n > 0 then a := a || jsonb_build_object('clave', 'negativo', 'nivel', 'media', 'cantidad', n, 'href', 'riesgos.html#negativo',
            'titulo', n || case when n = 1 then ' producto con existencia negativa' else ' productos con existencia negativa' end, 'detalle', 'Se vendió más de lo que había en el sistema: cuéntalos'); end if;

        select count(*) into n from productos
        where activo is not false and coalesce(precio, 0) <= 0 and coalesce(tipo_producto, 'fisico') = 'fisico'
          and (stock > 0 or exists (select 1 from sucursal_stock ss where ss.producto_codigo = productos.codigo and ss.stock > 0));
        if n > 0 then a := a || jsonb_build_object('clave', 'sin_precio', 'nivel', 'media', 'cantidad', n, 'href', 'riesgos.html#sin_precio',
            'titulo', n || case when n = 1 then ' producto sin precio' else ' productos sin precio' end, 'detalle', 'Tienen existencia pero no se pueden vender'); end if;

        select count(*), coalesce(sum(costo_total), 0) into n, m from kardex_movimientos
        where tipo = 'devolucion_danada' and fecha >= v_hoy - 7;
        if n > 0 then a := a || jsonb_build_object('clave', 'danados', 'nivel', 'baja', 'cantidad', n, 'href', 'kardex.html',
            'titulo', 'Mercancía dañada devuelta (7 días)',
            'detalle', n || ' devolución(es)' || case when v_costos then ' · costo ' || refrimar_fmt(m) || ' $' else '' end || ' · Reclama al proveedor'); end if;
    end if;

    if v_costos then
        select count(*) into n from productos
        where activo is not false and precio > 0 and costo > 0
          and (case when v_incl then precio / (1 + coalesce(iva_tasa, 16) / 100) else precio end) < costo;
        if n > 0 then a := a || jsonb_build_object('clave', 'perdida', 'nivel', 'alta', 'cantidad', n, 'href', 'riesgos.html#perdida',
            'titulo', n || case when n = 1 then ' producto se vende a pérdida' else ' productos se venden a pérdida' end, 'detalle', 'El precio es menor que el costo'); end if;
    end if;

    if v_cxc then
        select count(*), coalesce(sum(coalesce(total_usd, 0) - coalesce(monto_abonado, 0)), 0) into n, m from ventas
        where metodo_pago = 'credito' and estado = 'completada' and coalesce(total_usd, 0) - coalesce(monto_abonado, 0) > 0.005
          and (created_at at time zone 'America/Caracas')::date + coalesce(dias_credito, 30) < v_hoy;
        if n > 0 then a := a || jsonb_build_object('clave', 'cxc_vencidas', 'nivel', 'alta', 'cantidad', n, 'monto', round(m, 2), 'href', 'cuentas_por_cobrar.html',
            'titulo', n || case when n = 1 then ' deuda de cliente vencida' else ' deudas de clientes vencidas' end, 'detalle', 'Por cobrar: ' || refrimar_fmt(m) || ' $'); end if;
    end if;

    if v_cxp then
        select count(*), coalesce(sum(saldo_pendiente), 0), min(fecha_vencimiento) into n, m, v_d from compras_proveedores
        where saldo_pendiente > 0.005 and fecha_vencimiento is not null and fecha_vencimiento <= v_hoy + 3
          and lower(coalesce(estado, '')) not similar to '(pagad|anulad|cancelad)%';
        if n > 0 then a := a || jsonb_build_object('clave', 'cxp', 'nivel', case when v_d < v_hoy then 'alta' else 'media' end, 'cantidad', n, 'monto', round(m, 2), 'href', 'cuentas_por_pagar.html',
            'titulo', n || case when n = 1 then ' factura de proveedor por pagar' else ' facturas de proveedor por pagar' end,
            'detalle', refrimar_fmt(m) || ' $ · ' || case when v_d < v_hoy then 'hay vencidas' else 'vencen en 3 días o menos' end); end if;

        select count(*) into n from compras_proveedores
        where jsonb_array_length(coalesce(diferencias, '[]'::jsonb)) > 0 and not coalesce(diferencias_revisadas, false) and fecha_emision >= v_hoy - 120;
        if n > 0 then a := a || jsonb_build_object('clave', 'diferencias', 'nivel', 'media', 'cantidad', n, 'href', 'riesgos.html#diferencia',
            'titulo', n || case when n = 1 then ' factura no coincide con su orden' else ' facturas no coinciden con su orden' end, 'detalle', 'Revisa precios y cantidades con el proveedor'); end if;
    end if;

    if v_cot then
        select count(*) into n from cotizaciones
        where estado = 'pendiente' and created_at + make_interval(days => coalesce(validez_dias, 7)) between now() and now() + interval '2 days';
        if n > 0 then a := a || jsonb_build_object('clave', 'cotizaciones', 'nivel', 'baja', 'cantidad', n, 'href', 'cotizaciones.html',
            'titulo', n || case when n = 1 then ' cotización vence pronto' else ' cotizaciones vencen pronto' end, 'detalle', 'Llama al cliente antes de que venzan'); end if;
    end if;

    if v_caja then
        select count(*), coalesce(sum(diferencia_usd), 0), string_agg(usuario_nombre || ' ' || refrimar_fmt(diferencia_usd) || ' $', ', ') into n, m, t from turnos
        where estado <> 'activo' and cerrado_at >= now() - interval '2 days' and abs(coalesce(diferencia_usd, 0)) >= 1;
        if n > 0 then a := a || jsonb_build_object('clave', 'caja', 'nivel', 'alta', 'cantidad', n, 'monto', round(m, 2), 'href', 'turnos.html',
            'titulo', n || case when n = 1 then ' cierre de caja con diferencia' else ' cierres de caja con diferencia' end, 'detalle', t); end if;
    end if;

    if v_fact then
        select (max(created_at) at time zone 'America/Caracas')::date into v_d from tasas_historial;
        n := case when extract(isodow from v_hoy) = 1 then 3 else 1 end;   -- el lunes cuenta desde el viernes
        if v_d is not null and extract(isodow from v_hoy) between 1 and 5 and v_d < v_hoy - n then
            a := a || jsonb_build_object('clave', 'tasa', 'nivel', 'media', 'cantidad', 1, 'href', 'monedas.html',
                'titulo', 'La tasa no se actualiza desde el ' || to_char(v_d, 'DD/MM'), 'detalle', 'Revisa la tasa del BCV antes de facturar');
        end if;
    end if;

    -- Etapa 4b: despachos atrasados y garantías estancadas
    if v_fact and to_regclass('public.despachos') is not null then
        select count(*), string_agg(numero || ' ' || coalesce(cliente_nombre, ''), ', ') filter (where true) into n, t
        from (select numero, cliente_nombre from despachos
              where estado in ('pendiente', 'en_ruta', 'parcial') and fecha_programada is not null and fecha_programada < v_hoy
              order by fecha_programada limit 50) q;
        if n > 0 then a := a || jsonb_build_object('clave', 'despachos', 'nivel', 'alta', 'cantidad', n, 'href', 'despachos.html',
            'titulo', n || case when n = 1 then ' despacho atrasado' else ' despachos atrasados' end, 'detalle', left(t, 160)); end if;
    end if;
    if v_fact and to_regclass('public.garantias') is not null then
        select count(*) into n from garantias where estado in ('recibida', 'en_proveedor') and created_at < now() - interval '15 days';
        if n > 0 then a := a || jsonb_build_object('clave', 'garantias', 'nivel', 'media', 'cantidad', n, 'href', 'garantias.html',
            'titulo', n || case when n = 1 then ' garantía lleva más de 15 días' else ' garantías llevan más de 15 días' end, 'detalle', 'El cliente está esperando: llama al proveedor'); end if;
    end if;

    return a;
end;
$$;
revoke execute on function public.refrimar_alertas(uuid) from public, anon, authenticated;

insert into public.migraciones_aplicadas (nombre, descripcion, version_app)
values ('2026-11-17-etapa6b-textos-whatsapp', 'Texto de la alerta de existencia negativa', 'v3.9.30')
on conflict (nombre) do nothing;

select 'Listo' as resultado;
