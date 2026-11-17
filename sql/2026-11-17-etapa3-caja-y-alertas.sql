-- ============================================================
-- REFRIMAR — Etapa 3 (17-nov-2026): caja, devoluciones, ubicación y alertas
--
-- 1. Respaldo.
-- 2. Ubicación de cada producto en cada tienda (pasillo, estante…). Sale en la caja.
-- 3. Cotización → caja: la caja carga la cotización y, al facturar, la cotización queda
--    "convertida" con el número de la factura.
-- 4. Devolución de mercancía dañada: la nota de crédito puede marcar productos que
--    NO vuelven al inventario (queda anotado en el kardex con su costo, para reclamar).
-- 5. Abonos de clientes desde la caja: se cobran en la caja, rebajan la deuda (de la más
--    vieja a la más nueva) y entran al arqueo del turno en la moneda correcta.
-- 6. Alertas para la campana y el resumen diario que llega por WhatsApp.
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
    foreach t in array array['productos', 'sucursal_stock', 'cotizaciones', 'notas_credito_detalle'] loop
        if to_regclass('public.' || t) is not null then
            execute format('create table if not exists respaldo_inventario.%I as table public.%I', t || '_' || s, t);
        end if;
    end loop;
end $$;

-- ============================================================
-- 2. Ubicación (Principal en productos; las demás tiendas en sucursal_stock)
-- ============================================================
alter table public.productos add column if not exists ubicacion text;
alter table public.sucursal_stock add column if not exists ubicacion text;

create or replace function public.producto_ubicacion_guardar(p_codigo text, p_sucursal_id uuid, p_ubicacion text)
returns jsonb language plpgsql security definer set search_path = public as
$$
declare
    v_uid uuid := refrimar_sesion_uid(30);
    v_u text := nullif(left(trim(coalesce(p_ubicacion, '')), 60), '');
begin
    if v_uid is null then raise exception 'Tu sesión venció. Vuelve a entrar.'; end if;
    if not (refrimar_tiene_permiso(v_uid, 'editar_inventario') or refrimar_tiene_permiso(v_uid, 'contar_inventario')) then
        raise exception 'Tu usuario no puede cambiar la ubicación de los productos';
    end if;
    if not exists (select 1 from productos where codigo = p_codigo) then raise exception 'Producto % no existe', p_codigo; end if;
    if p_sucursal_id is null or p_sucursal_id = '00000000-0000-0000-0000-000000000001' then
        update productos set ubicacion = v_u where codigo = p_codigo and ubicacion is distinct from v_u;
    else
        insert into sucursal_stock (sucursal_id, producto_codigo, producto_descripcion, stock, ubicacion)
        select p_sucursal_id, codigo, descripcion, 0, v_u from productos where codigo = p_codigo
        on conflict (sucursal_id, producto_codigo) do update set ubicacion = excluded.ubicacion;
    end if;
    return jsonb_build_object('ok', true, 'ubicacion', v_u);
end;
$$;
revoke execute on function public.producto_ubicacion_guardar(text, uuid, text) from public, anon;
grant execute on function public.producto_ubicacion_guardar(text, uuid, text) to anon, authenticated;

-- ============================================================
-- 3. Cotización → caja
-- ============================================================
alter table public.cotizaciones add column if not exists venta_numero text;
alter table public.cotizaciones add column if not exists convertida_at timestamptz;

create or replace function public.cotizacion_convertir(p_id uuid, p_venta_numero text)
returns jsonb language plpgsql security definer set search_path = public as
$$
declare v_uid uuid := refrimar_sesion_uid(30); v_est text;
begin
    if v_uid is null then raise exception 'Tu sesión venció. Vuelve a entrar.'; end if;
    if not refrimar_tiene_permiso(v_uid, 'facturar') then raise exception 'Tu usuario no puede facturar'; end if;
    select estado into v_est from cotizaciones where id = p_id for update;
    if not found then raise exception 'Cotización no encontrada'; end if;
    if v_est = 'convertida' then return jsonb_build_object('ok', true, 'ya_estaba', true); end if;
    update cotizaciones set estado = 'convertida', venta_numero = nullif(trim(coalesce(p_venta_numero, '')), ''),
           convertida_at = now(), updated_at = now()
    where id = p_id;
    return jsonb_build_object('ok', true);
end;
$$;
revoke execute on function public.cotizacion_convertir(uuid, text) from public, anon;
grant execute on function public.cotizacion_convertir(uuid, text) to anon, authenticated;

-- ============================================================
-- 4. Devolución de mercancía dañada
-- ============================================================
alter table public.notas_credito_detalle add column if not exists danado boolean not null default false;

-- Igual que antes; lo único nuevo: si la línea trae "danado": true, el producto NO vuelve al stock.
-- Queda una línea en el kardex (cantidad 0, para no mover el saldo) con lo dañado y su costo.
create or replace function public.nota_credito_registrar_base(p_venta_id uuid, p_items jsonb, p_motivo text default null, p_usuario text default 'Sistema')
returns jsonb language plpgsql security definer set search_path = public as
$function$
declare
    v_venta record;
    v_item jsonb;
    v_codigo text;
    v_cant numeric;
    v_vendida numeric;
    v_total_linea_venta numeric;
    v_devuelta numeric;
    v_desc text;
    v_precio numeric;
    v_total numeric := 0;
    v_total_bs numeric;
    v_ratio numeric;
    v_nota_id uuid;
    v_numero text;
    v_metodo text;
    v_pendiente numeric;
    v_abono numeric;
    v_danado boolean;
    v_costo numeric;
begin
    select * into v_venta from ventas where id = p_venta_id for update;
    if not found then raise exception 'Factura no encontrada'; end if;
    if v_venta.estado <> 'completada' then raise exception 'Solo se puede hacer nota de crédito a facturas completadas'; end if;
    if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
        raise exception 'Selecciona al menos un producto a devolver';
    end if;

    v_numero := 'NC-' || lpad(nextval('seq_nota_credito')::text, 6, '0');
    v_metodo := case when v_venta.metodo_pago = 'credito' then 'rebaja_deuda'
                     when v_venta.metodo_pago = 'mixto' then 'efectivo'
                     else coalesce(v_venta.metodo_pago, 'efectivo') end;

    insert into notas_credito (numero, venta_id, venta_numero, cliente_nombre, cliente_rif, motivo,
        metodo_reembolso, sucursal_id, sucursal_nombre, usuario_nombre)
    values (v_numero, v_venta.id, v_venta.numero, v_venta.cliente_nombre, v_venta.cliente_rif,
        nullif(trim(coalesce(p_motivo, '')), ''), v_metodo, v_venta.sucursal_id, v_venta.sucursal_nombre,
        coalesce(p_usuario, 'Sistema'))
    returning id into v_nota_id;

    for v_item in select value from jsonb_array_elements(p_items) loop
        v_codigo := coalesce(v_item->>'codigo', '');
        v_cant := coalesce((v_item->>'cantidad')::numeric, 0);
        v_danado := coalesce(lower(v_item->>'danado') in ('true', '1', 'si', 'sí'), false);
        if v_codigo = '' or v_cant <= 0 then continue; end if;

        select coalesce(sum(cantidad), 0), coalesce(sum(total), 0), max(descripcion)
        into v_vendida, v_total_linea_venta, v_desc
        from detalle_venta where venta_id = v_venta.id and producto_codigo = v_codigo;

        if v_vendida <= 0 then raise exception 'El producto % no está en la factura', v_codigo; end if;

        select coalesce(sum(d.cantidad), 0) into v_devuelta
        from notas_credito_detalle d join notas_credito n on n.id = d.nota_id
        where n.venta_id = v_venta.id and d.producto_codigo = v_codigo and n.id <> v_nota_id;

        if v_cant > v_vendida - v_devuelta + 0.0005 then
            raise exception 'No puedes devolver % de "%": vendidos %, ya devueltos %', v_cant, coalesce(v_desc, v_codigo), v_vendida, v_devuelta;
        end if;

        v_precio := round(v_total_linea_venta / v_vendida, 4);
        insert into notas_credito_detalle (nota_id, producto_codigo, descripcion, cantidad, precio_unitario, total, danado)
        values (v_nota_id, v_codigo, v_desc, v_cant, v_precio, round(v_precio * v_cant, 2), v_danado);
        v_total := v_total + round(v_precio * v_cant, 2);

        if v_danado then
            -- Dañado: no vuelve al stock. Se anota (sin mover el saldo) con su costo, para reclamar o dar de baja.
            select coalesce(costo, 0) into v_costo from productos where codigo = v_codigo;
            insert into kardex_movimientos (producto_codigo, producto_descripcion, fecha, tipo, cantidad, costo_unitario, costo_total,
                saldo_cantidad, saldo_costo_promedio, referencia, usuario_nombre, sucursal_id)
            values (v_codigo, coalesce(v_desc, v_codigo), current_date, 'devolucion_danada', 0, coalesce(v_costo, 0), round(coalesce(v_costo, 0) * v_cant, 2),
                stock_en(v_codigo, v_venta.sucursal_id), 0,
                v_numero || ' (' || coalesce(v_venta.numero, '') || ') · ' || rtrim(to_char(v_cant, 'FM999999990.###'), '.') || ' dañado(s), no vuelve al inventario',
                coalesce(p_usuario, 'Sistema'), v_venta.sucursal_id);
        else
            -- El producto vuelve al stock de la sucursal donde se vendió
            perform stock_mover(v_codigo, v_venta.sucursal_id, v_cant);
            insert into kardex_movimientos (producto_codigo, producto_descripcion, fecha, tipo, cantidad, costo_unitario, costo_total,
                saldo_cantidad, saldo_costo_promedio, referencia, usuario_nombre, sucursal_id)
            values (v_codigo, coalesce(v_desc, v_codigo), current_date, 'entrada_devolucion', v_cant, 0, 0,
                stock_en(v_codigo, v_venta.sucursal_id), 0, v_numero || ' (' || coalesce(v_venta.numero, '') || ')',
                coalesce(p_usuario, 'Sistema'), v_venta.sucursal_id);
        end if;
    end loop;

    if v_total <= 0 then raise exception 'La nota de crédito no tiene productos'; end if;

    v_ratio := case when coalesce(v_venta.total_usd, 0) > 0 then coalesce(v_venta.total_bs, 0) / v_venta.total_usd
                    else coalesce(v_venta.tasa_bcv, 0) end;
    v_total_bs := round(v_total * v_ratio, 2);

    update notas_credito set total_usd = v_total, total_bs = v_total_bs where id = v_nota_id;
    update ventas set total_devuelto_usd = coalesce(total_devuelto_usd, 0) + v_total where id = v_venta.id;

    if v_venta.metodo_pago = 'credito' then
        -- Rebaja la deuda: se registra como abono "nota_credito"
        v_pendiente := greatest(coalesce(v_venta.total_usd, 0) - coalesce(v_venta.monto_abonado, 0), 0);
        v_abono := least(v_total, v_pendiente);
        if v_abono > 0 then
            insert into abonos_ventas (venta_id, monto, fecha, metodo, usuario_nombre, sucursal_id, notas)
            values (v_venta.id, v_abono, current_date, 'nota_credito', coalesce(p_usuario, 'Sistema'), v_venta.sucursal_id, v_numero);
            update ventas set monto_abonado = coalesce(monto_abonado, 0) + v_abono where id = v_venta.id;
            if coalesce(v_venta.cliente_rif, '') <> '' then
                update clientes set saldo_pendiente = greatest(coalesce(saldo_pendiente, 0) - v_abono, 0) where rif = v_venta.cliente_rif;
            end if;
        end if;
    else
        -- Reembolso: egreso de caja con el mismo método de pago
        insert into caja_movimientos (tipo, concepto, monto_usd, monto_bs, sucursal_id, usuario_nombre, metodo_pago)
        values ('egreso', 'Nota de crédito ' || v_numero || ' (factura ' || coalesce(v_venta.numero, '') || ')',
            v_total, v_total_bs, v_venta.sucursal_id, coalesce(p_usuario, 'Sistema'), v_metodo);
    end if;

    return jsonb_build_object('ok', true, 'nota_id', v_nota_id, 'numero', v_numero, 'total_usd', v_total, 'total_bs', v_total_bs);
end;
$function$;

-- Combos: si el combo devuelto viene dañado, sus componentes tampoco vuelven al stock
do $$ begin
    if to_regprocedure('public.kit_trg_nc()') is not null then
        execute $f$
        create or replace function public.kit_trg_nc()
        returns trigger language plpgsql security definer set search_path = public as
        $b$
        declare n record;
        begin
            if coalesce(new.danado, false) then return new; end if;
            if not exists (select 1 from productos where codigo = new.producto_codigo and es_kit) then return new; end if;
            select numero, sucursal_id, usuario_nombre into n from notas_credito where id = new.nota_id;
            perform kit_mover_componentes(new.producto_codigo, new.cantidad, n.sucursal_id, 1, 'Nota de crédito ' || coalesce(n.numero, ''), n.usuario_nombre);
            return new;
        end;
        $b$;
        $f$;
    end if;
end $$;

-- ============================================================
-- 5. Abonos de clientes desde la caja
-- ============================================================
-- Busca clientes con deudas (por nombre, RIF o número de factura). Sin texto: los que más deben.
create or replace function public.caja_deudas_buscar(p_q text default null)
returns jsonb language plpgsql stable security definer set search_path = public as
$$
declare
    v_uid uuid := refrimar_sesion_uid(30);
    v_q text := refrimar_norm(p_q);
    v_hoy date := (now() at time zone 'America/Caracas')::date;
begin
    if v_uid is null then raise exception 'Tu sesión venció. Vuelve a entrar.'; end if;
    if not (refrimar_tiene_permiso(v_uid, 'facturar') or refrimar_tiene_permiso(v_uid, 'ver_cxc')) then
        raise exception 'Tu usuario no puede cobrar abonos';
    end if;
    return coalesce((
        select jsonb_agg(c order by (c->>'vencidas')::int desc, (c->>'saldo')::numeric desc)
        from (
            select jsonb_build_object(
                'clave', clave, 'nombre', max(cliente_nombre), 'rif', max(cliente_rif),
                'saldo', round(sum(saldo), 2), 'vencidas', count(*) filter (where vence < v_hoy),
                'deudas', jsonb_agg(jsonb_build_object('venta_id', id, 'numero', coalesce(numero_doc, numero), 'fecha', created_at,
                                                       'vence', vence, 'total', total_usd, 'abonado', monto_abonado, 'saldo', round(saldo, 2),
                                                       'tienda', coalesce(sucursal_nombre, 'Principal')) order by created_at)) c
            from (
                select v.*, coalesce(nullif(refrimar_norm(v.cliente_rif), ''), 'N:' || refrimar_norm(v.cliente_nombre)) clave,
                       greatest(coalesce(v.total_usd, 0) - coalesce(v.monto_abonado, 0), 0) saldo,
                       ((v.created_at at time zone 'America/Caracas')::date + coalesce(v.dias_credito, 30)) vence
                from ventas v
                where v.metodo_pago = 'credito' and v.estado = 'completada'
                  and coalesce(v.total_usd, 0) - coalesce(v.monto_abonado, 0) > 0.005
            ) d
            group by clave
            having v_q = ''
                or bool_or(refrimar_norm(cliente_nombre) like '%' || v_q || '%')
                or bool_or(refrimar_norm(cliente_rif) like '%' || v_q || '%')
                or bool_or(refrimar_norm(coalesce(numero_doc, '') || ' ' || coalesce(numero, '')) like '%' || v_q || '%')
            order by count(*) filter (where vence < v_hoy) desc, sum(saldo) desc
            limit 20
        ) q), '[]'::jsonb);
end;
$$;
revoke execute on function public.caja_deudas_buscar(text) from public, anon;
grant execute on function public.caja_deudas_buscar(text) to anon, authenticated;

-- Cobra un abono en la caja.
--   p = { clave (del buscador) | venta_id, monto_usd, metodo, tasa, monto_bs?, referencia?, sucursal_id }
-- Con "clave" reparte el abono de la deuda más vieja a la más nueva. Quien cobra es el usuario de la sesión.
create or replace function public.caja_cobrar_abono(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as
$$
declare
    v_uid uuid := refrimar_sesion_uid(30);
    v_usuario text;
    v_monto numeric := round(coalesce((p->>'monto_usd')::numeric, 0), 2);
    v_metodo text := coalesce(nullif(trim(p->>'metodo'), ''), 'efectivo');
    v_tasa numeric := coalesce(nullif(p->>'tasa', '')::numeric, 0);
    v_bs numeric := nullif(p->>'monto_bs', '')::numeric;
    v_suc uuid := nullif(p->>'sucursal_id', '')::uuid;
    v_ref text := nullif(left(trim(coalesce(p->>'referencia', '')), 60), '');
    v_venta uuid := nullif(p->>'venta_id', '')::uuid;
    v_clave text := nullif(p->>'clave', '');
    v_fecha date := (now() at time zone 'America/Caracas')::date;
    v_debe numeric; v_resto numeric; v_aplica numeric;
    r record;
    v_lista jsonb := '[]'::jsonb; v_saldadas jsonb := '[]'::jsonb; v_nums text[] := '{}';
    v_rif text; v_cli text;
begin
    if v_uid is null then raise exception 'Tu sesión venció. Vuelve a entrar.'; end if;
    if not (refrimar_tiene_permiso(v_uid, 'facturar') or refrimar_tiene_permiso(v_uid, 'cxc')) then
        raise exception 'Tu usuario no puede cobrar abonos';
    end if;
    select nombre into v_usuario from usuarios where id = v_uid;
    if v_monto <= 0 then raise exception 'El monto del abono debe ser mayor a 0'; end if;
    if v_metodo not in ('efectivo', 'divisa', 'pago_movil', 'transferencia', 'punto', 'zelle', 'binance', 'otro') then
        raise exception 'Método de pago no válido: %', v_metodo;
    end if;
    if v_venta is null and v_clave is null then raise exception 'Elige el cliente o la deuda'; end if;

    -- Lo que debe (bloquea sus deudas para que dos cajas no cobren lo mismo a la vez)
    select coalesce(sum(greatest(coalesce(total_usd, 0) - coalesce(monto_abonado, 0), 0)), 0) into v_debe
    from (select total_usd, monto_abonado from ventas v
          where v.metodo_pago = 'credito' and v.estado = 'completada'
            and coalesce(v.total_usd, 0) - coalesce(v.monto_abonado, 0) > 0.005
            and (v.id = v_venta or (v_venta is null and coalesce(nullif(refrimar_norm(v.cliente_rif), ''), 'N:' || refrimar_norm(v.cliente_nombre)) = v_clave))
          for update) x;
    if v_debe <= 0 then raise exception 'Este cliente no tiene deudas pendientes'; end if;
    if v_monto > round(v_debe, 2) + 0.005 then
        raise exception 'El abono (% $) es mayor que lo que debe el cliente (% $)', v_monto, round(v_debe, 2);
    end if;

    v_resto := v_monto;
    for r in
        select id, numero, numero_doc, cliente_rif, cliente_nombre, total_usd, monto_abonado,
               greatest(coalesce(total_usd, 0) - coalesce(monto_abonado, 0), 0) saldo
        from ventas v
        where v.metodo_pago = 'credito' and v.estado = 'completada'
          and coalesce(v.total_usd, 0) - coalesce(v.monto_abonado, 0) > 0.005
          and (v.id = v_venta or (v_venta is null and coalesce(nullif(refrimar_norm(v.cliente_rif), ''), 'N:' || refrimar_norm(v.cliente_nombre)) = v_clave))
        order by created_at, numero
    loop
        exit when v_resto <= 0.004;
        v_aplica := round(least(v_resto, r.saldo), 2);
        if v_aplica <= 0 then continue; end if;
        insert into abonos_ventas (venta_id, monto, fecha, metodo, usuario_nombre, sucursal_id, notas)
        values (r.id, v_aplica, v_fecha, v_metodo, coalesce(v_usuario, 'Caja'), v_suc, concat_ws(' · ', 'Cobrado en caja', v_ref));
        update ventas set monto_abonado = coalesce(monto_abonado, 0) + v_aplica where id = r.id;
        v_resto := round(v_resto - v_aplica, 2);
        v_rif := coalesce(v_rif, nullif(r.cliente_rif, '')); v_cli := coalesce(v_cli, r.cliente_nombre);
        v_nums := v_nums || coalesce(r.numero_doc, r.numero);
        v_lista := v_lista || jsonb_build_object('venta_id', r.id, 'numero', coalesce(r.numero_doc, r.numero), 'monto', v_aplica, 'saldo', round(r.saldo - v_aplica, 2));
        if r.saldo - v_aplica <= 0.005 then v_saldadas := v_saldadas || to_jsonb(coalesce(r.numero_doc, r.numero)); end if;
    end loop;

    if v_rif is not null then
        update clientes set saldo_pendiente = greatest(coalesce(saldo_pendiente, 0) - v_monto, 0) where rif = v_rif;
    end if;

    -- Entra a la caja del turno: en Bs para los métodos en bolívares, en $ para los de divisas
    if v_bs is null then v_bs := round(v_monto * v_tasa, 2); end if;
    insert into caja_movimientos (tipo, concepto, monto_usd, monto_bs, metodo_pago, usuario_nombre, sucursal_id, notas)
    values ('ingreso', 'Abono de cliente ' || coalesce(v_cli, '') || ' (deuda ' || array_to_string(v_nums, ', ') || ')',
            v_monto, v_bs, v_metodo, coalesce(v_usuario, 'Caja'), v_suc, v_ref);

    return jsonb_build_object('ok', true, 'cliente', v_cli, 'rif', v_rif, 'monto_usd', v_monto, 'monto_bs', v_bs,
                              'aplicado', v_lista, 'saldadas', v_saldadas, 'saldo_restante', round(v_debe - v_monto, 2),
                              'usuario', v_usuario, 'fecha', now());
end;
$$;
revoke execute on function public.caja_cobrar_abono(jsonb) from public, anon;
grant execute on function public.caja_cobrar_abono(jsonb) to anon, authenticated;

-- ============================================================
-- 6. Alertas y resumen diario
-- ============================================================
-- Formato venezolano: 1.234,56
create or replace function public.refrimar_fmt(p numeric)
returns text language sql immutable as
$$ select translate(to_char(round(coalesce(p, 0), 2), 'FM999,999,999,990.00'), ',.', '.,') $$;

-- Las alertas. p_uid = usuario (solo ve lo de sus permisos); null = todas (resumen del dueño).
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
            'titulo', n || ' con existencia negativa', 'detalle', 'Se vendió más de lo que había en el sistema: cuéntalos'); end if;

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

    return a;
end;
$$;
revoke execute on function public.refrimar_alertas(uuid) from public, anon, authenticated;

-- Para la campana: las alertas que le tocan al usuario de la sesión
create or replace function public.alertas_resumen()
returns jsonb language plpgsql stable security definer set search_path = public as
$$
declare v_uid uuid := refrimar_sesion_uid(30);
begin
    if v_uid is null then raise exception 'Tu sesión venció. Vuelve a entrar.'; end if;
    return refrimar_alertas(v_uid);
end;
$$;
revoke execute on function public.alertas_resumen() from public, anon;
grant execute on function public.alertas_resumen() to anon, authenticated;

-- Resumen del día (lo manda el Worker por WhatsApp a las 6 pm; también se ve en Riesgos).
-- Solo lo puede pedir el Worker (token de servicio) o un administrador.
create or replace function public.resumen_diario(p_fecha date default null)
returns jsonb language plpgsql stable security definer set search_path = public as
$$
declare
    CASA constant uuid := '00000000-0000-0000-0000-000000000001';
    v_uid uuid := refrimar_sesion_uid(30);
    v_dia date := coalesce(p_fecha, (now() at time zone 'America/Caracas')::date);
    v_tiendas jsonb; v_alertas jsonb; v_abonos numeric; v_nc numeric; v_danado numeric; v_gastos numeric;
    v_lineas text[] := '{}'; r record; x jsonb;
begin
    if not (refrimar_servicio_ok() or (v_uid is not null and exists (select 1 from usuarios where id = v_uid and rol = 'admin' and activo is not false))) then
        raise exception 'Solo el administrador puede ver el resumen del día';
    end if;

    select coalesce(jsonb_agg(jsonb_build_object('tienda', s.nombre, 'ventas', coalesce(v.n, 0), 'total_usd', coalesce(v.total, 0), 'credito_usd', coalesce(v.credito, 0)) order by s.id <> CASA, s.nombre), '[]'::jsonb)
    into v_tiendas
    from sucursales s
    left join (select coalesce(sucursal_id, CASA) suc, count(*) n, round(sum(total_usd), 2) total,
                      round(sum(total_usd) filter (where metodo_pago = 'credito'), 2) credito
               from ventas where estado = 'completada' and (created_at at time zone 'America/Caracas')::date = v_dia
               group by 1) v on v.suc = s.id;

    select coalesce(sum(monto), 0) into v_abonos from abonos_ventas where fecha = v_dia and coalesce(metodo, '') <> 'nota_credito';
    select coalesce(sum(total_usd), 0) into v_nc from notas_credito where (created_at at time zone 'America/Caracas')::date = v_dia;
    select coalesce(sum(d.total), 0) into v_danado from notas_credito_detalle d join notas_credito n on n.id = d.nota_id
    where d.danado and (n.created_at at time zone 'America/Caracas')::date = v_dia;
    select coalesce(sum(monto_usd), 0) into v_gastos from gastos where fecha = v_dia;
    v_alertas := refrimar_alertas(null);

    v_lineas := v_lineas || ('📊 REFRIMAR — Resumen del ' || to_char(v_dia, 'DD/MM/YYYY'));
    for x in select value from jsonb_array_elements(v_tiendas) loop
        v_lineas := v_lineas || ('🏪 ' || (x->>'tienda') || ': ' || (x->>'ventas') || ' venta(s) · ' || refrimar_fmt((x->>'total_usd')::numeric) || ' $'
                                 || case when (x->>'credito_usd')::numeric > 0 then ' (a crédito ' || refrimar_fmt((x->>'credito_usd')::numeric) || ' $)' else '' end);
    end loop;
    if v_abonos > 0 then v_lineas := v_lineas || ('💵 Abonos cobrados: ' || refrimar_fmt(v_abonos) || ' $'); end if;
    if v_nc > 0 then v_lineas := v_lineas || ('↩️ Devoluciones: ' || refrimar_fmt(v_nc) || ' $' || case when v_danado > 0 then ' (dañado: ' || refrimar_fmt(v_danado) || ' $)' else '' end); end if;
    if v_gastos > 0 then v_lineas := v_lineas || ('🧾 Gastos: ' || refrimar_fmt(v_gastos) || ' $'); end if;
    if jsonb_array_length(v_alertas) > 0 then
        v_lineas := v_lineas || ''::text || '⚠️ Para revisar:'::text;
        for x in select value from jsonb_array_elements(v_alertas)
                 order by case value->>'nivel' when 'alta' then 0 when 'media' then 1 else 2 end loop
            v_lineas := v_lineas || ('• ' || (x->>'titulo') || coalesce(' — ' || nullif(x->>'detalle', ''), ''));
        end loop;
    else
        v_lineas := v_lineas || ''::text || '✅ Sin alertas pendientes.'::text;
    end if;

    return jsonb_build_object('fecha', v_dia, 'tiendas', v_tiendas, 'abonos_usd', v_abonos, 'devoluciones_usd', v_nc,
                              'danado_usd', v_danado, 'gastos_usd', v_gastos, 'alertas', v_alertas,
                              'texto', array_to_string(v_lineas, E'\n'));
end;
$$;
revoke execute on function public.resumen_diario(date) from public, anon;
grant execute on function public.resumen_diario(date) to anon, authenticated;

-- ============================================================
-- Seguridad y registro
-- ============================================================
insert into public.seguridad_rpc (nombre, nivel, permiso, gracia_dias)
select v.* from (values ('producto_ubicacion_guardar', 'sesion', null, 0), ('cotizacion_convertir', 'sesion', null, 0),
                        ('caja_deudas_buscar', 'sesion', null, 0), ('caja_cobrar_abono', 'sesion', null, 0),
                        ('alertas_resumen', 'sesion', null, 0), ('resumen_diario', 'servicio', null, 0)) as v(nombre, nivel, permiso, gracia)
where not exists (select 1 from public.seguridad_rpc s where s.nombre = v.nombre);

insert into public.migraciones_aplicadas (nombre, descripcion, version_app)
values ('2026-11-17-etapa3-caja-y-alertas', 'Ubicación, cotización→caja, devolución dañada, abonos en caja, alertas y resumen diario', 'v3.9.25')
on conflict (nombre) do nothing;
notify pgrst, 'reload schema';

select 'Listo' as resultado,
       exists (select 1 from seguridad_config where id = 1 and servicio_token_hash is not null) as whatsapp_diario_listo;
