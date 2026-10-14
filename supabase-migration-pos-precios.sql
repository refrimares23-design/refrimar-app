-- ============================================================
-- REFRIMAR · Actualización de precios (estilo Norkut) + App POS
-- Se puede correr varias veces (idempotente).
-- ============================================================

-- ---------- 1. Actualización de precios: tipos nuevos y programadas ----------
alter table precio_actualizaciones add column if not exists programada_para timestamptz;
alter table precio_actualizaciones add column if not exists items jsonb;
alter table precio_actualizaciones add column if not exists tasa_nueva numeric;
alter table precio_actualizaciones add column if not exists parametros jsonb;
alter table precio_actualizaciones add column if not exists ejecutada_at timestamptz;

-- Aplica una lista de {codigo, precio} a una actualización ya creada
create or replace function precio_actualizacion_aplicar_items(p_id uuid, p_items jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_item jsonb; v_codigo text; v_nuevo numeric; v_ant numeric; v_desc text;
    v_ok int := 0; v_err int := 0; v_omit int := 0; v_tot int := 0;
begin
    for v_item in select value from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) loop
        v_tot := v_tot + 1;
        v_codigo := trim(coalesce(v_item->>'codigo', ''));
        begin v_nuevo := round((v_item->>'precio')::numeric, 2); exception when others then v_nuevo := null; end;
        select precio, descripcion into v_ant, v_desc from productos where codigo = v_codigo;
        if not found then
            v_err := v_err + 1;
            insert into precio_actualizacion_detalle (actualizacion_id, producto_codigo, precio_nuevo, resultado)
            values (p_id, v_codigo, v_nuevo, 'error: código no existe');
            continue;
        end if;
        if v_nuevo is null or v_nuevo <= 0 or v_nuevo = coalesce(v_ant, 0) then
            v_omit := v_omit + 1;
            insert into precio_actualizacion_detalle (actualizacion_id, producto_codigo, descripcion, precio_anterior, precio_nuevo, resultado)
            values (p_id, v_codigo, v_desc, v_ant, v_nuevo, 'omitido');
            continue;
        end if;
        update productos set precio = v_nuevo where codigo = v_codigo;
        insert into precio_actualizacion_detalle (actualizacion_id, producto_codigo, descripcion, precio_anterior, precio_nuevo)
        values (p_id, v_codigo, v_desc, v_ant, v_nuevo);
        v_ok := v_ok + 1;
    end loop;
    update precio_actualizaciones set procesados = v_ok, errores = v_err, omitidos = v_omit, total = v_tot,
        estado = 'completada', ejecutada_at = now()
    where id = p_id;
    return jsonb_build_object('procesados', v_ok, 'errores', v_err, 'omitidos', v_omit, 'total', v_tot);
end;
$$;
revoke execute on function precio_actualizacion_aplicar_items(uuid, jsonb) from anon, authenticated, public;

-- Crear actualización: ahora (p_cuando null) o programada (p_cuando = fecha/hora futura).
-- p_tasa_nueva: si viene, también cambia la tasa del sistema (ajuste por tasa de cambio).
create or replace function precios_actualizacion_crear(
    p_tipo text, p_descripcion text, p_items jsonb, p_usuario text default 'Sistema',
    p_cuando timestamptz default null, p_tasa_nueva numeric default null, p_parametros jsonb default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_id uuid; v_numero text; v_res jsonb := '{}'::jsonb;
begin
    if (p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0) and p_tasa_nueva is null then
        raise exception 'No hay productos para actualizar';
    end if;
    if p_tasa_nueva is not null and p_tasa_nueva <= 0 then raise exception 'Tasa inválida'; end if;
    if p_cuando is not null and p_cuando < now() - interval '1 minute' then raise exception 'La fecha programada ya pasó'; end if;
    v_numero := 'AP-' || lpad(nextval('seq_precio_act')::text, 6, '0');
    insert into precio_actualizaciones (numero, tipo, descripcion, usuario_nombre, estado, programada_para, items, tasa_nueva, parametros)
    values (v_numero, coalesce(p_tipo, 'manual'), p_descripcion, coalesce(p_usuario, 'Sistema'),
            case when p_cuando is null then 'completada' else 'programada' end, p_cuando, coalesce(p_items, '[]'::jsonb), p_tasa_nueva, p_parametros)
    returning id into v_id;
    if p_cuando is null then
        if p_tasa_nueva is not null then perform config_actualizar_tasa(p_tasa_nueva); end if;
        v_res := precio_actualizacion_aplicar_items(v_id, p_items);
    end if;
    return jsonb_build_object('ok', true, 'id', v_id, 'numero', v_numero,
        'estado', case when p_cuando is null then 'completada' else 'programada' end) || v_res;
end;
$$;

-- Ejecuta las programadas que ya llegaron a su hora (lo llama el sistema al abrir y el cron del worker)
create or replace function precios_programados_aplicar()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare r record; n int := 0;
begin
    for r in select * from precio_actualizaciones
             where estado = 'programada' and programada_para <= now()
             order by programada_para for update skip locked loop
        if r.tasa_nueva is not null then perform config_actualizar_tasa(r.tasa_nueva); end if;
        perform precio_actualizacion_aplicar_items(r.id, r.items);
        n := n + 1;
    end loop;
    return jsonb_build_object('ok', true, 'aplicadas', n);
end;
$$;

create or replace function precio_programada_cancelar(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
    update precio_actualizaciones set estado = 'cancelada' where id = p_id and estado = 'programada';
    if not found then raise exception 'Solo se pueden cancelar actualizaciones programadas'; end if;
    return jsonb_build_object('ok', true);
end;
$$;

grant execute on function precios_actualizacion_crear(text, text, jsonb, text, timestamptz, numeric, jsonb) to anon, authenticated;
grant execute on function precios_programados_aplicar() to anon, authenticated;
grant execute on function precio_programada_cancelar(uuid) to anon, authenticated;

-- ============================================================
-- 2. APP POS (facturar, cobrar con varios métodos y monedas,
--    vuelto, borradores, notas de crédito, arqueo e impresora fiscal)
-- ============================================================
alter table ventas add column if not exists usuario_nombre text;
alter table ventas add column if not exists pagos jsonb;
alter table ventas add column if not exists vuelto jsonb;
alter table ventas add column if not exists cliente_email text;
alter table ventas add column if not exists numero_fiscal text;
alter table ventas add column if not exists serial_fiscal text;
alter table ventas add column if not exists estado_fiscal text;
alter table ventas add column if not exists fecha_fiscal timestamptz;
alter table ventas add column if not exists turno_id uuid;
alter table ventas add column if not exists terminal text;
alter table ventas add column if not exists monto_abonado numeric default 0;
alter table notas_credito add column if not exists numero_fiscal text;
alter table notas_credito add column if not exists serial_fiscal text;
alter table notas_credito add column if not exists estado_fiscal text;
alter table notas_credito add column if not exists fecha_fiscal timestamptz;
alter table clientes add column if not exists email text;
create index if not exists idx_ventas_numero on ventas(numero);
create index if not exists idx_ventas_turno on ventas(turno_id);

-- Borradores de factura (se retoman desde Facturas → Borradores)
create table if not exists pos_borradores (
    id uuid primary key default gen_random_uuid(),
    nombre text,
    sucursal_id uuid,
    usuario_nombre text,
    terminal text,
    cliente jsonb,
    items jsonb not null default '[]'::jsonb,
    total_usd numeric not null default 0,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);
create index if not exists idx_pos_borr_suc on pos_borradores(sucursal_id, updated_at desc);
alter table pos_borradores enable row level security;
drop policy if exists "pos_borradores_select" on pos_borradores;
create policy "pos_borradores_select" on pos_borradores for select using (true);
revoke insert, update, delete on pos_borradores from anon, authenticated;
grant select on pos_borradores to anon, authenticated;

create or replace function pos_borrador_guardar(p_id uuid, p_datos jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare d jsonb := coalesce(p_datos, '{}'::jsonb); v_id uuid := p_id;
begin
    if jsonb_typeof(d->'items') <> 'array' or jsonb_array_length(d->'items') = 0 then raise exception 'El borrador no tiene productos'; end if;
    if v_id is null or not exists (select 1 from pos_borradores where id = v_id) then
        insert into pos_borradores (nombre, sucursal_id, usuario_nombre, terminal, cliente, items, total_usd)
        values (nullif(trim(coalesce(d->>'nombre', '')), ''), nullif(d->>'sucursal_id', '')::uuid, d->>'usuario_nombre', d->>'terminal',
                d->'cliente', d->'items', coalesce((d->>'total_usd')::numeric, 0))
        returning id into v_id;
    else
        update pos_borradores set nombre = nullif(trim(coalesce(d->>'nombre', '')), ''), cliente = d->'cliente', items = d->'items',
            total_usd = coalesce((d->>'total_usd')::numeric, 0), usuario_nombre = coalesce(d->>'usuario_nombre', usuario_nombre), updated_at = now()
        where id = v_id;
    end if;
    return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

create or replace function pos_borrador_eliminar(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
    delete from pos_borradores where id = p_id;
    return jsonb_build_object('ok', true);
end;
$$;

-- Emitir factura desde la App POS.
-- p_venta: { numero, cliente:{nombre,rif,email}, subtotal, iva, total_usd, total_bs, tasa,
--            sucursal_id, sucursal_nombre, usuario, turno_id, terminal, estado_fiscal,
--            items:[{codigo,descripcion,cantidad,precio,costo,descuento,total}],
--            pagos:[{metodo,moneda,monto,monto_usd,monto_bs,referencia,banco}],
--            vuelto:[{metodo,moneda,monto_usd,monto_bs}] }
-- Si el número ya existe (reintento sin internet) devuelve la misma venta sin duplicarla.
create or replace function pos_facturar(p_venta jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v jsonb := coalesce(p_venta, '{}'::jsonb);
    v_casa uuid := '00000000-0000-0000-0000-000000000001';
    v_numero text := nullif(trim(coalesce(v->>'numero', '')), '');
    v_suc uuid := nullif(v->>'sucursal_id', '')::uuid;
    v_usuario text := coalesce(nullif(v->>'usuario', ''), 'Sistema');
    v_cli_nombre text := coalesce(nullif(trim(coalesce(v->'cliente'->>'nombre', '')), ''), 'Consumidor Final');
    v_cli_rif text := nullif(trim(coalesce(v->'cliente'->>'rif', '')), '');
    v_total numeric := coalesce((v->>'total_usd')::numeric, 0);
    v_total_bs numeric := coalesce((v->>'total_bs')::numeric, 0);
    v_tasa numeric := coalesce((v->>'tasa')::numeric, 0);
    v_id uuid; v_item jsonb; v_cant numeric; v_unidad text; v_stock numeric;
    p jsonb; v_pagado numeric := 0; v_credito numeric := 0; v_vuelto numeric := 0;
    v_metodos text[] := '{}'; v_metodo text; v_saldo numeric; v_limite numeric;
begin
    if v_numero is null then raise exception 'Falta el número de la factura'; end if;
    select id into v_id from ventas where numero = v_numero limit 1;
    if found then return jsonb_build_object('ok', true, 'venta_id', v_id, 'numero', v_numero, 'duplicada', true); end if;
    if jsonb_typeof(v->'items') <> 'array' or jsonb_array_length(v->'items') = 0 then raise exception 'La factura no tiene productos'; end if;
    if jsonb_typeof(v->'pagos') <> 'array' or jsonb_array_length(v->'pagos') = 0 then raise exception 'Agrega al menos un método de pago'; end if;

    for p in select value from jsonb_array_elements(v->'pagos') loop
        if coalesce((p->>'monto_usd')::numeric, 0) <= 0 then raise exception 'Hay un pago sin monto'; end if;
        if p->>'metodo' = 'credito' then v_credito := v_credito + (p->>'monto_usd')::numeric;
        else v_pagado := v_pagado + (p->>'monto_usd')::numeric;
             if not (p->>'metodo' = any(v_metodos)) then v_metodos := v_metodos || (p->>'metodo'); end if;
        end if;
    end loop;
    if jsonb_typeof(v->'vuelto') = 'array' then
        select coalesce(sum((x->>'monto_usd')::numeric), 0) into v_vuelto from jsonb_array_elements(v->'vuelto') x;
    end if;
    if v_pagado - v_vuelto + v_credito < v_total - 0.01 then
        raise exception 'Los pagos (%) no cubren el total de la factura (%)', round(v_pagado - v_vuelto + v_credito, 2), round(v_total, 2);
    end if;
    if v_vuelto > v_pagado + 0.01 then raise exception 'El vuelto no puede ser mayor a lo recibido'; end if;
    v_metodo := case when v_credito > 0 then 'credito' when array_length(v_metodos, 1) = 1 then v_metodos[1] else 'mixto' end;

    if v_credito > 0 then
        if v_cli_rif is null then raise exception 'Para vender a crédito indica el documento del cliente'; end if;
        select saldo_pendiente, limite_credito into v_saldo, v_limite from clientes where rif = v_cli_rif for update;
        if not found then raise exception 'El cliente % no está registrado. Regístralo antes de vender a crédito.', v_cli_rif; end if;
        if coalesce(v_limite, 0) > 0 and coalesce(v_saldo, 0) + v_credito > v_limite then
            raise exception 'La venta excede el límite de crédito del cliente (saldo: %, límite: %)', coalesce(v_saldo, 0), v_limite;
        end if;
    end if;

    insert into ventas (numero, cliente_nombre, cliente_rif, cliente_email, subtotal, iva, total_usd, tasa_bcv, total_bs, metodo_pago, estado,
                        sucursal_id, sucursal_nombre, usuario_nombre, pagos, vuelto, turno_id, terminal, estado_fiscal, monto_abonado)
    values (v_numero, v_cli_nombre, v_cli_rif, nullif(trim(coalesce(v->'cliente'->>'email', '')), ''),
            coalesce((v->>'subtotal')::numeric, v_total), coalesce((v->>'iva')::numeric, 0), v_total, v_tasa, v_total_bs, v_metodo, 'completada',
            v_suc, coalesce(v->>'sucursal_nombre', 'Casa Matriz'), v_usuario, v->'pagos', v->'vuelto',
            nullif(v->>'turno_id', '')::uuid, v->>'terminal', nullif(v->>'estado_fiscal', ''),
            case when v_credito > 0 then greatest(v_total - v_credito, 0) else 0 end)
    returning id into v_id;

    for v_item in select value from jsonb_array_elements(v->'items') loop
        v_cant := coalesce((v_item->>'cantidad')::numeric, 0);
        if v_item->>'codigo' is null or v_cant <= 0 then raise exception 'Producto o cantidad inválida: %', v_item->>'codigo'; end if;
        select coalesce(unidad, 'uds') into v_unidad from productos where codigo = v_item->>'codigo';
        if not found then raise exception 'Producto "%" no encontrado', v_item->>'codigo'; end if;
        if v_unidad = 'uds' and v_cant <> floor(v_cant) then raise exception 'El producto "%" se vende por unidad; la cantidad debe ser entera.', v_item->>'codigo'; end if;
        if v_suc is null or v_suc = v_casa then
            select stock into v_stock from productos where codigo = v_item->>'codigo' for update;
            if coalesce(v_stock, 0) < v_cant then raise exception 'Stock insuficiente de "%" (disponible: %)', coalesce(v_item->>'descripcion', v_item->>'codigo'), coalesce(v_stock, 0); end if;
            update productos set stock = stock - v_cant where codigo = v_item->>'codigo';
        else
            select stock into v_stock from sucursal_stock where sucursal_id = v_suc and producto_codigo = v_item->>'codigo' for update;
            if not found then raise exception 'Producto "%" sin stock en esta tienda', coalesce(v_item->>'descripcion', v_item->>'codigo'); end if;
            if v_stock < v_cant then raise exception 'Stock insuficiente de "%" en la tienda (disponible: %)', coalesce(v_item->>'descripcion', v_item->>'codigo'), v_stock; end if;
            update sucursal_stock set stock = stock - v_cant, updated_at = now() where sucursal_id = v_suc and producto_codigo = v_item->>'codigo';
        end if;
        insert into detalle_venta (venta_id, producto_codigo, descripcion, cantidad, precio_unitario, costo_unitario, descuento, total)
        values (v_id, v_item->>'codigo', v_item->>'descripcion', v_cant, coalesce((v_item->>'precio')::numeric, 0),
                coalesce((v_item->>'costo')::numeric, 0), coalesce((v_item->>'descuento')::numeric, 0), coalesce((v_item->>'total')::numeric, 0));
    end loop;

    -- Caja: un movimiento por cada pago (el crédito no entra a caja)
    for p in select value from jsonb_array_elements(v->'pagos') loop
        continue when p->>'metodo' = 'credito';
        insert into caja_movimientos (tipo, concepto, monto_usd, monto_bs, sucursal_id, usuario_nombre, metodo_pago)
        values ('venta', 'Venta ' || v_numero || ' - ' || v_cli_nombre || ' (' || (p->>'metodo') || coalesce(' ' || nullif(p->>'moneda', ''), '') || ')',
                round((p->>'monto_usd')::numeric, 2), round(coalesce((p->>'monto_bs')::numeric, (p->>'monto_usd')::numeric * v_tasa), 2), v_suc, v_usuario, p->>'metodo');
        if p->>'metodo' = 'pago_movil' then
            insert into pagos_moviles (banco, remitente, monto, referencia, sucursal_id, usuario_nombre, venta_numero)
            values (coalesce(p->>'banco', ''), coalesce(nullif(p->>'remitente', ''), v_cli_nombre),
                    round(coalesce((p->>'monto_bs')::numeric, (p->>'monto_usd')::numeric * v_tasa), 2), nullif(p->>'referencia', ''), v_suc, v_usuario, v_numero);
        end if;
    end loop;
    -- Vuelto entregado (sale de la caja)
    if jsonb_typeof(v->'vuelto') = 'array' then
        for p in select value from jsonb_array_elements(v->'vuelto') loop
            continue when coalesce((p->>'monto_usd')::numeric, 0) <= 0;
            insert into caja_movimientos (tipo, concepto, monto_usd, monto_bs, sucursal_id, usuario_nombre, metodo_pago)
            values ('egreso', 'Vuelto venta ' || v_numero || ' (' || (p->>'metodo') || coalesce(' ' || nullif(p->>'moneda', ''), '') || ')',
                    round((p->>'monto_usd')::numeric, 2), round(coalesce((p->>'monto_bs')::numeric, (p->>'monto_usd')::numeric * v_tasa), 2), v_suc, v_usuario, p->>'metodo');
        end loop;
    end if;

    if v_credito > 0 then
        update clientes set saldo_pendiente = coalesce(saldo_pendiente, 0) + v_credito where rif = v_cli_rif;
    end if;
    if nullif(trim(coalesce(v->'cliente'->>'email', '')), '') is not null and v_cli_rif is not null then
        update clientes set email = trim(v->'cliente'->>'email') where rif = v_cli_rif and coalesce(email, '') = '';
    end if;
    return jsonb_build_object('ok', true, 'venta_id', v_id, 'numero', v_numero, 'metodo', v_metodo);
end;
$$;

-- Guarda el número fiscal que devolvió la impresora fiscal
create or replace function pos_fiscal_registrar(p_tipo text, p_numero text, p_numero_fiscal text, p_serial text, p_estado text default 'fiscalizada')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
    if p_tipo = 'nota_credito' then
        update notas_credito set numero_fiscal = p_numero_fiscal, serial_fiscal = p_serial, estado_fiscal = p_estado, fecha_fiscal = now() where numero = p_numero;
    else
        update ventas set numero_fiscal = p_numero_fiscal, serial_fiscal = p_serial, estado_fiscal = p_estado, fecha_fiscal = now() where numero = p_numero;
    end if;
    if not found then raise exception 'Documento % no encontrado', p_numero; end if;
    return jsonb_build_object('ok', true);
end;
$$;

-- Nota de crédito desde el POS: igual que la del sistema, pero eligiendo cómo se devuelve el dinero
create or replace function pos_nota_credito(p_venta_id uuid, p_items jsonb, p_motivo text, p_usuario text, p_metodo text default null, p_estado_fiscal text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare r jsonb;
begin
    r := nota_credito_registrar(p_venta_id, p_items, p_motivo, p_usuario);
    if p_metodo is not null and p_metodo <> '' then
        update caja_movimientos set metodo_pago = p_metodo
        where tipo = 'egreso' and concepto like 'Nota de crédito ' || (r->>'numero') || '%';
        update notas_credito set metodo_reembolso = p_metodo where numero = r->>'numero' and metodo_reembolso <> 'rebaja_deuda';
    end if;
    if p_estado_fiscal is not null then update notas_credito set estado_fiscal = p_estado_fiscal where numero = r->>'numero'; end if;
    return r;
end;
$$;

-- Cierre de turno con el conteo detallado por método y moneda (arqueo)
create or replace function pos_turno_cerrar(p_id uuid, p_contado_usd numeric, p_contado_bs numeric, p_conteo jsonb, p_notas text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare r jsonb;
begin
    r := turno_cerrar(p_id, p_contado_usd, p_contado_bs, p_notas);
    update turnos set resumen = coalesce(resumen, '{}'::jsonb) || jsonb_build_object('conteo', coalesce(p_conteo, '[]'::jsonb)) where id = p_id;
    return r;
end;
$$;

grant execute on function pos_borrador_guardar(uuid, jsonb) to anon, authenticated;
grant execute on function pos_borrador_eliminar(uuid) to anon, authenticated;
grant execute on function pos_facturar(jsonb) to anon, authenticated;
grant execute on function pos_fiscal_registrar(text, text, text, text, text) to anon, authenticated;
grant execute on function pos_nota_credito(uuid, jsonb, text, text, text, text) to anon, authenticated;
grant execute on function pos_turno_cerrar(uuid, numeric, numeric, jsonb, text) to anon, authenticated;
