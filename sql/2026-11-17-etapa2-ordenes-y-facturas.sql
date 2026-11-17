-- ============================================================
-- REFRIMAR — Etapa 2 (17-nov-2026): orden ↔ recepción ↔ factura, y pedido sugerido
--
-- 1. Respaldo.
-- 2. La factura del proveedor se puede unir a su orden de compra y guarda las diferencias
--    (llegó más o menos de lo pedido, precio distinto al de la orden, producto que no se pidió).
-- 3. Las deudas que quedaron en la tabla vieja "cuentas_por_pagar" pasan a Cuentas por pagar
--    (compras_proveedores), donde sí se ven. No se borra nada.
-- 4. recepcion_registrar: además de lo de la etapa 1, recibe contra una orden de compra y
--    compara. También lo puede usar quien tiene permiso de compras.
-- 5. compra_registrar ("Recepción directa") usa el mismo circuito: antes fallaba en la
--    Principal y en la Sucursal dejaba la deuda en la tabla vieja y no promediaba el costo.
-- 6. orden_sugerida: qué pedirle a un proveedor según lo vendido en los últimos días.
-- 7. riesgos_resumen: agrega las facturas con diferencias.
--
-- Supabase → SQL Editor → New query → pega TODO → Run. Se puede correr varias veces.
-- ============================================================

-- 1. Respaldo
create schema if not exists respaldo_inventario;
revoke all on schema respaldo_inventario from anon, authenticated, public;
do $$ begin
    execute format('create table if not exists respaldo_inventario.%I as table public.productos',
                   'productos_' || to_char(now() at time zone 'America/Caracas', 'YYYYMMDD_HH24MISS'));
    execute format('create table if not exists respaldo_inventario.%I as table public.compras_proveedores',
                   'compras_proveedores_' || to_char(now() at time zone 'America/Caracas', 'YYYYMMDD_HH24MISS'));
    execute format('create table if not exists respaldo_inventario.%I as table public.ordenes_compra',
                   'ordenes_compra_' || to_char(now() at time zone 'America/Caracas', 'YYYYMMDD_HH24MISS'));
end $$;

-- 2. Factura ↔ orden y diferencias
alter table public.compras_proveedores add column if not exists orden_compra_id uuid;
alter table public.compras_proveedores add column if not exists diferencias jsonb not null default '[]'::jsonb;
alter table public.compras_proveedores add column if not exists diferencias_revisadas boolean not null default false;
do $$ begin
    if not exists (select 1 from pg_constraint where conname = 'compras_proveedores_orden_compra_id_fkey') then
        alter table public.compras_proveedores
            add constraint compras_proveedores_orden_compra_id_fkey foreign key (orden_compra_id) references public.ordenes_compra(id) on delete set null;
    end if;
end $$;
create index if not exists compras_proveedores_orden_idx on public.compras_proveedores (orden_compra_id);

-- 3. Deudas de la tabla vieja → Cuentas por pagar (una sola vez por fila: factura_origen_id)
insert into public.compras_proveedores (proveedor, numero, fecha_emision, fecha_vencimiento, monto_usd, monto_abonado, saldo_pendiente,
                                        estado, notas, origen, sucursal_id, sucursal_nombre, proveedor_id, orden_compra_id, factura_origen_id)
select coalesce(nullif(trim(c.proveedor_nombre), ''), 'Proveedor sin nombre'),
       coalesce(nullif(trim(c.numero_factura), ''), 'S/N-' || left(c.id::text, 8)),
       coalesce(c.fecha, c.creado_en::date), c.fecha_vencimiento, c.monto, greatest(c.monto - c.saldo, 0), c.saldo,
       case when c.saldo <= 0 then 'Pagada' when c.saldo < c.monto then 'Parcial' else 'Pendiente' end,
       concat_ws(' · ', nullif(c.notas, ''), 'Pasada de la tabla vieja de cuentas por pagar'),
       'cxp_vieja', c.sucursal_id, c.sucursal_nombre,
       (select p.id from public.proveedores p where p.id = c.proveedor_id),
       (select o.id from public.ordenes_compra o where o.id = c.orden_compra_id), c.id
from public.cuentas_por_pagar c
where c.monto > 0
  and not exists (select 1 from public.compras_proveedores x where x.factura_origen_id = c.id)
  and not exists (select 1 from public.compras_proveedores x
                  where x.sucursal_id is not distinct from c.sucursal_id
                    and x.proveedor = coalesce(nullif(trim(c.proveedor_nombre), ''), 'Proveedor sin nombre')
                    and x.numero = coalesce(nullif(trim(c.numero_factura), ''), 'S/N-' || left(c.id::text, 8)));

-- 4. Recepción (v2): todo o nada + contra orden de compra
create or replace function public.recepcion_registrar(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as
$$
declare
    v_casa constant uuid := '00000000-0000-0000-0000-000000000001';
    v_uid uuid := refrimar_sesion_uid(30);
    v_usuario text;
    v_suc uuid := nullif(p->>'sucursal_id', '')::uuid;
    v_suc_nombre text := nullif(trim(coalesce(p->>'sucursal_nombre', '')), '');
    v_prov_nombre text := nullif(trim(coalesce(p->>'proveedor', '')), '');
    v_rif text := nullif(trim(coalesce(p->>'rif', '')), '');
    v_numero text := nullif(trim(coalesce(p->>'numero', '')), '');
    v_fecha date := coalesce(nullif(p->>'fecha', '')::date, current_date);
    v_moneda text := upper(coalesce(nullif(p->>'moneda', ''), 'USD'));
    v_tasa numeric := nullif(p->>'tasa', '')::numeric;
    v_factor numeric := 1;
    v_prov uuid := nullif(p->>'proveedor_id', '')::uuid;
    v_oc_id uuid := nullif(p->>'orden_compra_id', '')::uuid;
    v_oc record; v_det record; v_oc_num text;
    v_crear_cxp boolean := coalesce((p->>'crear_cxp')::boolean, true);
    v_incl boolean := coalesce((select bool_or(coalesce(iva_incluido, false) or coalesce((opciones->>'iva_incluido')::boolean, false)) from configuracion), false);
    it jsonb; v_cod text; v_alt text; v_cant numeric; v_costo numeric; v_precio numeric; v_pend numeric;
    pr record; v_nuevos int := 0; v_actualizados int := 0; v_total numeric := 0;
    v_avisos jsonb := '[]'::jsonb; v_sin_precio jsonb := '[]'::jsonb; v_dif jsonb := '[]'::jsonb;
    v_cxp uuid; v_ref text; v_vistos text[] := '{}';
begin
    if v_uid is null then raise exception 'Tu sesión venció. Vuelve a entrar.' using errcode = 'P0001'; end if;
    if not (refrimar_tiene_permiso(v_uid, 'editar_inventario') or refrimar_tiene_permiso(v_uid, 'compras')) then
        raise exception 'Tu usuario no tiene permiso para cargar mercancía.';
    end if;
    select nombre into v_usuario from usuarios where id = v_uid;
    if jsonb_typeof(p->'items') <> 'array' or jsonb_array_length(p->'items') = 0 then
        raise exception 'La factura no tiene productos';
    end if;
    if jsonb_array_length(p->'items') > 2000 then raise exception 'Demasiadas líneas en una sola factura (máximo 2000)'; end if;
    if v_moneda not in ('USD', 'VES') then raise exception 'Moneda inválida: %', v_moneda; end if;
    if v_moneda = 'VES' then
        if v_tasa is null or v_tasa <= 0 then raise exception 'Falta la tasa para convertir la factura en bolívares'; end if;
        v_factor := 1 / v_tasa;
    end if;

    if v_oc_id is not null then
        select * into v_oc from ordenes_compra where id = v_oc_id for update;
        if not found then raise exception 'La orden de compra no existe'; end if;
        if v_oc.estado not in ('ordenada', 'parcial', 'borrador') then
            raise exception 'La orden % está % y no puede recibir mercancía', v_oc.numero, v_oc.estado;
        end if;
        v_oc_num := v_oc.numero;
        v_suc := coalesce(v_suc, v_oc.sucursal_id);
        v_suc_nombre := coalesce(v_suc_nombre, v_oc.sucursal_nombre);
        v_prov := coalesce(v_prov, v_oc.proveedor_id);
        v_prov_nombre := coalesce(v_prov_nombre, v_oc.proveedor_nombre);
    end if;
    if v_suc = v_casa then v_suc := null; end if;
    if v_suc is not null and not exists (select 1 from sucursales where id = v_suc) then raise exception 'La tienda indicada no existe'; end if;

    if v_prov is null and (v_prov_nombre is not null or v_rif is not null) then
        select id into v_prov from proveedores
        where (refrimar_norm(v_rif) <> '' and refrimar_norm(rif) = refrimar_norm(v_rif))
           or (v_prov_nombre is not null and refrimar_norm_proveedor(nombre) = refrimar_norm_proveedor(v_prov_nombre))
        order by (refrimar_norm(rif) = refrimar_norm(v_rif)) desc nulls last limit 1;
    end if;
    if v_prov is not null and v_prov_nombre is null then select nombre into v_prov_nombre from proveedores where id = v_prov; end if;
    if v_prov is not null and v_rif is null then select nullif(rif, '') into v_rif from proveedores where id = v_prov; end if;

    if v_crear_cxp then
        if v_prov_nombre is null then raise exception 'Falta el proveedor para crear la factura por pagar'; end if;
        if v_numero is null then raise exception 'Falta el número de factura'; end if;
        perform refrimar_bloquear_factura_repetida(v_prov_nombre, v_rif, v_numero, v_prov, null);
    end if;
    v_ref := 'Factura ' || coalesce(v_numero, 's/n') || coalesce(' · ' || v_oc_num, '') || coalesce(' · ' || v_prov_nombre, '');

    for it in select value from jsonb_array_elements(p->'items') loop
        v_cod := nullif(trim(coalesce(it->>'codigo', '')), '');
        v_alt := nullif(trim(coalesce(it->>'codigo_alterno', '')), '');
        v_cant := coalesce(nullif(it->>'cantidad', '')::numeric, 0);
        v_costo := round(coalesce(nullif(it->>'costo', '')::numeric, 0) * v_factor, 6);
        v_precio := nullif(it->>'precio', '')::numeric;
        if v_cod is null then raise exception 'Hay una línea sin código ("%")', coalesce(it->>'descripcion', '?'); end if;
        if v_cant <= 0 or v_cant > 1000000 then raise exception 'Cantidad inválida en "%"', coalesce(it->>'descripcion', v_cod); end if;
        if v_costo < 0 then raise exception 'Costo inválido en "%"', coalesce(it->>'descripcion', v_cod); end if;
        if v_precio is not null and v_precio < 0 then raise exception 'Precio inválido en "%"', coalesce(it->>'descripcion', v_cod); end if;

        select * into pr from productos where codigo = v_cod for update;
        if not found then
            if not coalesce((it->>'nuevo')::boolean, false) then
                raise exception 'El producto % no existe. Márcalo como nuevo o elige uno existente.', v_cod;
            end if;
            if nullif(trim(coalesce(it->>'descripcion', '')), '') is null then raise exception 'Falta la descripción del producto nuevo %', v_cod; end if;
            insert into productos (codigo, descripcion, costo, precio, stock, stock_minimo, unidad, categoria, marca, activo)
            values (v_cod, trim(it->>'descripcion'), v_costo, coalesce(v_precio, 0), 0,
                    coalesce(nullif(it->>'stock_minimo', '')::numeric, 0),
                    coalesce(nullif(it->>'unidad', ''), 'uds'), nullif(it->>'categoria', ''), nullif(it->>'marca', ''), true)
            returning * into pr;
            v_nuevos := v_nuevos + 1;
        else
            v_actualizados := v_actualizados + 1;
        end if;

        -- Contra la orden de compra: cantidad y precio
        if v_oc_id is not null then
            select * into v_det from compra_detalles where compra_id = v_oc_id and producto_codigo = v_cod for update;
            if not found then
                v_dif := v_dif || jsonb_build_object('codigo', v_cod, 'descripcion', pr.descripcion, 'tipo', 'no_pedido',
                                                     'detalle', 'No estaba en la orden', 'facturado', v_cant, 'monto', round(v_cant * v_costo, 2));
            else
                v_vistos := array_append(v_vistos, v_cod);
                v_pend := v_det.cantidad - v_det.cantidad_recibida;
                if v_cant > v_pend + 0.0005 then
                    v_dif := v_dif || jsonb_build_object('codigo', v_cod, 'descripcion', pr.descripcion, 'tipo', 'de_mas',
                                                         'detalle', 'Llegó más de lo pedido', 'pedido', v_pend, 'facturado', v_cant,
                                                         'monto', round((v_cant - v_pend) * v_costo, 2));
                end if;
                if v_det.costo_unitario > 0 and abs(v_costo - v_det.costo_unitario) > greatest(0.01, v_det.costo_unitario * 0.01) then
                    v_dif := v_dif || jsonb_build_object('codigo', v_cod, 'descripcion', pr.descripcion, 'tipo', 'precio',
                                                         'detalle', case when v_costo > v_det.costo_unitario then 'Cobraron más caro que en la orden' else 'Cobraron más barato que en la orden' end,
                                                         'costo_orden', v_det.costo_unitario, 'costo_factura', v_costo,
                                                         'monto', round((v_costo - v_det.costo_unitario) * v_cant, 2));
                end if;
                update compra_detalles set cantidad_recibida = cantidad_recibida + v_cant where id = v_det.id;
            end if;
        end if;

        if v_alt is not null and refrimar_norm(v_alt) <> refrimar_norm(v_cod)
           and not (coalesce(pr.codigos_alternos, '{}') @> array[v_alt]) then
            update productos set codigos_alternos = array_append(coalesce(codigos_alternos, '{}'), v_alt) where codigo = v_cod;
        end if;
        if v_suc is not null then
            perform 1 from sucursal_stock where sucursal_id = v_suc and producto_codigo = v_cod for update;
        end if;

        perform kardex_ajuste(v_cod, 'entrada', v_cant, v_costo, v_ref, v_suc, coalesce(v_usuario, 'Sistema'));
        if v_suc is not null and v_costo > 0 then
            update sucursal_stock set costo = v_costo where sucursal_id = v_suc and producto_codigo = v_cod;
        end if;

        if v_precio is not null and v_precio > 0 then
            update productos set precio = v_precio, updated_at = now() where codigo = v_cod;
        end if;
        select precio, costo, iva_tasa, descripcion into pr from productos where codigo = v_cod;
        if coalesce(pr.precio, 0) <= 0 then
            v_sin_precio := v_sin_precio || jsonb_build_object('codigo', v_cod, 'descripcion', pr.descripcion);
        elsif (case when v_incl then pr.precio / (1 + coalesce(pr.iva_tasa, 16) / 100) else pr.precio end) < coalesce(pr.costo, 0) then
            v_avisos := v_avisos || jsonb_build_object('codigo', v_cod, 'descripcion', pr.descripcion, 'costo', pr.costo, 'precio', pr.precio,
                                                       'aviso', 'Se vende por debajo del costo');
        end if;
        v_total := v_total + v_cant * v_costo;
    end loop;

    if v_oc_id is not null then
        -- Lo que faltó por llegar (normal en entregas parciales; queda anotado)
        select v_dif || coalesce(jsonb_agg(jsonb_build_object('codigo', d.producto_codigo, 'descripcion', d.descripcion, 'tipo', 'falta',
                                   'detalle', 'Falta por llegar', 'pedido', d.cantidad, 'recibido', d.cantidad_recibida,
                                   'monto', round((d.cantidad - d.cantidad_recibida) * d.costo_unitario, 2))), '[]'::jsonb)
        into v_dif
        from compra_detalles d where d.compra_id = v_oc_id and d.cantidad_recibida < d.cantidad - 0.0005;
        update ordenes_compra set
            estado = case when exists (select 1 from compra_detalles where compra_id = v_oc_id and cantidad_recibida < cantidad - 0.0005) then 'parcial' else 'recibida' end,
            recibida_at = now()
        where id = v_oc_id;
    end if;

    if v_crear_cxp and v_total > 0 then
        insert into compras_proveedores (proveedor, rif, numero, fecha_emision, fecha_vencimiento, monto_usd, monto_abonado,
                                         saldo_pendiente, estado, notas, origen, sucursal_id, sucursal_nombre, proveedor_id, tasa_bcv,
                                         orden_compra_id, diferencias)
        values (v_prov_nombre, v_rif, v_numero, v_fecha, nullif(p->>'fecha_vencimiento', '')::date, round(v_total, 2), 0,
                round(v_total, 2), 'Pendiente', nullif(p->>'notas', ''), coalesce(nullif(p->>'origen', ''), 'carga_ia'),
                v_suc, coalesce(v_suc_nombre, case when v_suc is null then 'Principal' end), v_prov, v_tasa,
                v_oc_id, (select coalesce(jsonb_agg(d), '[]'::jsonb) from jsonb_array_elements(v_dif) d where d->>'tipo' <> 'falta'))
        returning id into v_cxp;
    end if;

    return jsonb_build_object('ok', true, 'nuevos', v_nuevos, 'actualizados', v_actualizados, 'total_usd', round(v_total, 2),
                              'factura_id', v_cxp, 'sin_precio', v_sin_precio, 'avisos', v_avisos, 'diferencias', v_dif,
                              'orden_estado', (select estado from ordenes_compra where id = v_oc_id));
end;
$$;
revoke execute on function public.recepcion_registrar(jsonb) from public, anon;
grant execute on function public.recepcion_registrar(jsonb) to anon, authenticated;
update public.seguridad_rpc set permiso = null, nivel = 'sesion' where nombre = 'recepcion_registrar';   -- la función revisa compras o inventario

-- 5. Recepción directa: el mismo circuito (registra la orden como recibida + la deuda en Cuentas por pagar)
create or replace function public.compra_registrar(p_proveedor_id uuid, p_proveedor_nombre text, p_fecha date, p_notas text, p_sucursal_id uuid, p_sucursal_nombre text, p_usuario text, p_items text)
returns jsonb language plpgsql security definer set search_path = public as
$$
declare
    v_items jsonb := coalesce(nullif(p_items, ''), '[]')::jsonb;
    v_oc uuid; v_num text; it jsonb; v_rec jsonb; v_lineas jsonb := '[]'::jsonb; v_total numeric := 0;
    v_suc uuid := case when p_sucursal_id = '00000000-0000-0000-0000-000000000001' then null else p_sucursal_id end;
begin
    if jsonb_typeof(v_items) <> 'array' or jsonb_array_length(v_items) = 0 then raise exception 'Agrega al menos un producto'; end if;
    v_num := 'ODC-' || lpad(nextval('seq_odc')::text, 8, '0');
    insert into ordenes_compra (numero, proveedor_id, proveedor_nombre, fecha, notas, usuario_nombre, sucursal_id, sucursal_nombre, estado, referencia)
    values (v_num, p_proveedor_id, p_proveedor_nombre, coalesce(p_fecha, current_date), p_notas, p_usuario, v_suc,
            coalesce(p_sucursal_nombre, case when v_suc is null then 'Casa Matriz' end), 'ordenada', 'Recepción directa')
    returning id into v_oc;
    for it in select value from jsonb_array_elements(v_items) loop
        insert into compra_detalles (compra_id, producto_codigo, descripcion, cantidad, costo_unitario, subtotal, cantidad_recibida)
        values (v_oc, it->>'codigo', coalesce(it->>'descripcion', (select descripcion from productos where codigo = it->>'codigo')),
                coalesce((it->>'cantidad')::numeric, 0), coalesce((it->>'costo_unitario')::numeric, 0),
                round(coalesce((it->>'cantidad')::numeric, 0) * coalesce((it->>'costo_unitario')::numeric, 0), 2), 0);
        v_lineas := v_lineas || jsonb_build_object('codigo', it->>'codigo', 'cantidad', it->>'cantidad', 'costo', it->>'costo_unitario');
        v_total := v_total + coalesce((it->>'cantidad')::numeric, 0) * coalesce((it->>'costo_unitario')::numeric, 0);
    end loop;
    update ordenes_compra set subtotal = round(v_total, 2) where id = v_oc;
    v_rec := recepcion_registrar(jsonb_build_object(
        'orden_compra_id', v_oc, 'proveedor_id', p_proveedor_id, 'proveedor', p_proveedor_nombre,
        'numero', v_num, 'fecha', coalesce(p_fecha, current_date), 'sucursal_id', v_suc, 'sucursal_nombre', p_sucursal_nombre,
        'crear_cxp', p_proveedor_nombre is not null or p_proveedor_id is not null,
        'notas', concat_ws(' · ', nullif(p_notas, ''), 'Recepción directa: cambia el número por el de la factura del proveedor'),
        'origen', 'recepcion_directa', 'items', v_lineas));
    return jsonb_build_object('id', v_oc, 'numero', v_num, 'ok', true, 'factura_id', v_rec->>'factura_id');
end;
$$;
revoke execute on function public.compra_registrar(uuid, text, date, text, uuid, text, text, text) from public, anon;
grant execute on function public.compra_registrar(uuid, text, date, text, uuid, text, text, text) to anon, authenticated;

-- 6. Pedido sugerido para un proveedor
create or replace function public.orden_sugerida(p_proveedor_id uuid default null, p_sucursal_id uuid default null, p_dias integer default 30, p_cobertura integer default 15)
returns jsonb language plpgsql stable security definer set search_path = public as
$$
declare
    v_uid uuid := refrimar_sesion_uid(30);
    v_suc uuid := case when p_sucursal_id = '00000000-0000-0000-0000-000000000001' then null else p_sucursal_id end;
    v_prov_nombre text;
    v_dias integer := greatest(coalesce(p_dias, 30), 7);
    v_cob integer := greatest(coalesce(p_cobertura, 15), 1);
begin
    if v_uid is null then raise exception 'Tu sesión venció. Vuelve a entrar.'; end if;
    if not (refrimar_tiene_permiso(v_uid, 'compras') or refrimar_tiene_permiso(v_uid, 'editar_inventario')) then
        raise exception 'Sin permiso para hacer pedidos';
    end if;
    select nombre into v_prov_nombre from proveedores where id = p_proveedor_id;
    return coalesce((
        with del_proveedor as (
            select p.codigo from productos p
            where p_proveedor_id is null
               or (v_prov_nombre is not null and exists (select 1 from unnest(coalesce(p.proveedores, '{}')) x
                                                         where refrimar_norm_proveedor(x) = refrimar_norm_proveedor(v_prov_nombre) or x = p_proveedor_id::text))
               or exists (select 1 from compra_detalles d join ordenes_compra o on o.id = d.compra_id
                          where d.producto_codigo = p.codigo and o.proveedor_id = p_proveedor_id)
               or exists (select 1 from compras_proveedores c join kardex_movimientos k on k.referencia like 'Factura ' || c.numero || '%'
                          where c.proveedor_id = p_proveedor_id and k.producto_codigo = p.codigo)
        ),
        vendido as (
            select d.producto_codigo codigo, sum(d.cantidad) cant
            from detalle_venta d join ventas v on v.id = d.venta_id
            where v.estado = 'completada' and v.created_at >= now() - make_interval(days => v_dias)
              and (v_suc is null and (v.sucursal_id is null or v.sucursal_id = '00000000-0000-0000-0000-000000000001') or v.sucursal_id = v_suc)
            group by d.producto_codigo
        ),
        pendiente as (
            select d.producto_codigo codigo, sum(d.cantidad - d.cantidad_recibida) cant
            from compra_detalles d join ordenes_compra o on o.id = d.compra_id
            where o.estado in ('ordenada', 'parcial') and o.sucursal_id is not distinct from v_suc
            group by d.producto_codigo
        ),
        base as (
            select p.codigo, p.descripcion, p.costo, coalesce(p.stock_minimo, 0) minimo,
                   case when v_suc is null then p.stock else coalesce((select ss.stock from sucursal_stock ss where ss.sucursal_id = v_suc and ss.producto_codigo = p.codigo), 0) end stock,
                   coalesce(vd.cant, 0) vendido, coalesce(pe.cant, 0) en_camino
            from productos p join del_proveedor dp on dp.codigo = p.codigo
            left join vendido vd on vd.codigo = p.codigo left join pendiente pe on pe.codigo = p.codigo
            where p.activo is not false and coalesce(p.tipo_producto, 'fisico') = 'fisico'
        ),
        calc as (
            select *, round(vendido / v_dias, 3) diario,
                   greatest(ceil(vendido / v_dias * v_cob), minimo) objetivo
            from base
        )
        select jsonb_agg(jsonb_build_object('codigo', codigo, 'descripcion', descripcion, 'costo', costo, 'stock', stock,
                                            'vendido', vendido, 'diario', diario, 'en_camino', en_camino, 'minimo', minimo,
                                            'sugerido', ceil(objetivo - stock - en_camino),
                                            'dias_quedan', case when diario > 0 then floor(greatest(stock, 0) / diario) end)
                         order by (case when diario > 0 then greatest(stock, 0) / diario else 9999 end), descripcion)
        from calc
        where objetivo - stock - en_camino >= 1
    ), '[]'::jsonb);
end;
$$;
revoke execute on function public.orden_sugerida(uuid, uuid, integer, integer) from public, anon;
grant execute on function public.orden_sugerida(uuid, uuid, integer, integer) to anon, authenticated;

-- 7. Riesgos: + facturas con diferencias
create or replace function public.riesgos_resumen()
returns jsonb language plpgsql stable security definer set search_path = public as
$$
declare
    v_uid uuid := refrimar_sesion_uid(30);
    v_costos boolean;
    v_cxp boolean;
    v_incl boolean := coalesce((select bool_or(coalesce(iva_incluido, false) or coalesce((opciones->>'iva_incluido')::boolean, false)) from configuracion), false);
begin
    if v_uid is null then raise exception 'Tu sesión venció. Vuelve a entrar.'; end if;
    if not refrimar_tiene_permiso(v_uid, 'ver_inventario') then raise exception 'Sin permiso para ver el inventario'; end if;
    v_costos := refrimar_tiene_permiso(v_uid, 'ver_costos');
    v_cxp := refrimar_tiene_permiso(v_uid, 'ver_cxp');
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
        'facturas_repetidas', case when not v_cxp then '[]'::jsonb else coalesce((
            select jsonb_agg(jsonb_build_object('numero', numero, 'proveedor', proveedor, 'veces', n, 'monto_usd', total))
            from (select min(numero) numero, min(proveedor) proveedor, count(*) n, sum(monto_usd) total
                  from compras_proveedores where refrimar_norm(numero) <> ''
                  group by refrimar_norm(numero), coalesce(proveedor_id::text, refrimar_norm_proveedor(proveedor))
                  having count(*) > 1) q), '[]'::jsonb) end,
        'facturas_diferencias', case when not v_cxp then '[]'::jsonb else coalesce((
            select jsonb_agg(jsonb_build_object('id', id, 'numero', numero, 'proveedor', proveedor, 'fecha', fecha_emision,
                                                'diferencias', diferencias,
                                                'monto', (select sum(abs(coalesce((d->>'monto')::numeric, 0))) from jsonb_array_elements(diferencias) d))
                             order by fecha_emision desc)
            from compras_proveedores
            where jsonb_array_length(diferencias) > 0 and not diferencias_revisadas
              and fecha_emision >= current_date - 120), '[]'::jsonb) end
    );
end;
$$;
revoke execute on function public.riesgos_resumen() from public, anon;
grant execute on function public.riesgos_resumen() to anon, authenticated;

-- 7b. Marcar revisadas las diferencias de una factura (ya se reclamó o se aceptó)
create or replace function public.factura_diferencias_revisar(p_id uuid, p_nota text default null)
returns jsonb language plpgsql security definer set search_path = public as
$$
declare v_uid uuid := refrimar_sesion_uid(30); v_nombre text;
begin
    if v_uid is null then raise exception 'Tu sesión venció. Vuelve a entrar.'; end if;
    if not (refrimar_tiene_permiso(v_uid, 'ver_cxp') or refrimar_tiene_permiso(v_uid, 'compras')) then raise exception 'Sin permiso'; end if;
    select nombre into v_nombre from usuarios where id = v_uid;
    update compras_proveedores set diferencias_revisadas = true,
           notas = concat_ws(' · ', nullif(notas, ''), 'Diferencias revisadas por ' || coalesce(v_nombre, '?') || ' el ' || to_char(now() at time zone 'America/Caracas', 'DD/MM/YYYY') || coalesce(': ' || nullif(trim(p_nota), ''), ''))
    where id = p_id;
    if not found then raise exception 'Factura no encontrada'; end if;
    return jsonb_build_object('ok', true);
end;
$$;
revoke execute on function public.factura_diferencias_revisar(uuid, text) from public, anon;
grant execute on function public.factura_diferencias_revisar(uuid, text) to anon, authenticated;

-- Seguridad y registro
insert into public.seguridad_rpc (nombre, nivel, permiso, gracia_dias)
select v.* from (values ('orden_sugerida', 'sesion', null, 0), ('factura_diferencias_revisar', 'sesion', null, 0)) as v(nombre, nivel, permiso, gracia)
where not exists (select 1 from public.seguridad_rpc s where s.nombre = v.nombre);

insert into public.migraciones_aplicadas (nombre, descripcion, version_app)
values ('2026-11-17-etapa2-ordenes-y-facturas', 'Factura↔orden con diferencias, deudas viejas a CxP, recepción directa por el circuito, pedido sugerido', 'v3.9.24')
on conflict (nombre) do nothing;
notify pgrst, 'reload schema';

select 'Listo' as resultado,
       (select count(*) from compras_proveedores where origen = 'cxp_vieja') as deudas_viejas_pasadas;
