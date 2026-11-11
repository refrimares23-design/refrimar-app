-- ============================================================
-- REFRIMAR — FASE 3 (estilo Norkut)
-- ------------------------------------------------------------
-- Requiere haber corrido antes:
--   supabase-migration-norkut-completo.sql  (o productos-ficha)
-- Qué agrega (idempotente: seguro volver a correrlo):
--   • Importación de Excel con todos los campos de la ficha.
--   • Transferencias entre tiendas (con varios productos, borrador,
--     transporte y referencia).
--   • Órdenes de compra: negociación de pago, transporte, tracking.
--   • Conteos: fechas de inicio/fin y descripción.
--   • Clientes: persona natural/jurídica, apellidos, documento,
--     ubicación y datos personales.
--   • Usuarios: correo para entrar con Google.
--
-- CÓMO APLICAR: Supabase → SQL Editor → New query → pega TODO → Run
-- ============================================================

-- ------------------------------------------------------------
-- 1. Importación con ficha completa
-- ------------------------------------------------------------
alter table productos add column if not exists stock_maximo numeric;

create or replace function producto_stock_maximo(p_codigo text, p_max numeric)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
    if p_max is not null and p_max < 0 then raise exception 'El stock máximo no puede ser negativo'; end if;
    update productos set stock_maximo = nullif(p_max, 0) where codigo = p_codigo;
    if not found then raise exception 'Producto % no existe', p_codigo; end if;
    return jsonb_build_object('ok', true);
end;
$$;
grant execute on function producto_stock_maximo(text, numeric) to anon, authenticated;
create or replace function productos_importar_ficha(p_rows jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    r jsonb;
    v_cod text;
    v_iva numeric;
    v_tipo text;
    n int := 0;
begin
    if p_rows is null or jsonb_typeof(p_rows) <> 'array' then return jsonb_build_object('ok', true, 'actualizados', 0); end if;
    for r in select value from jsonb_array_elements(p_rows) loop
        v_cod := nullif(trim(coalesce(r->>'codigo', '')), '');
        if v_cod is null then continue; end if;
        begin v_iva := iva_normalizar(r->>'iva'); exception when others then v_iva := null; end;
        v_tipo := case when r->>'tipo_producto' = 'servicio' then 'servicio' else 'fisico' end;
        update productos set
            iva_tasa = coalesce(v_iva, iva_tasa),
            sku = coalesce(nullif(trim(coalesce(r->>'sku', '')), ''), sku),
            detalle = coalesce(nullif(trim(coalesce(r->>'detalle', '')), ''), detalle),
            tipo_producto = v_tipo,
            pesable = coalesce((r->>'pesable')::boolean, pesable),
            codigo_balanza = coalesce(nullif(trim(coalesce(r->>'codigo_balanza', '')), ''), codigo_balanza),
            clasificacion = coalesce(nullif(trim(coalesce(r->>'clasificacion', '')), ''), clasificacion),
            origen = coalesce(nullif(trim(coalesce(r->>'origen', '')), ''), origen),
            tipo_medida = coalesce(nullif(trim(coalesce(r->>'tipo_medida', '')), ''), tipo_medida),
            medida = coalesce(nullif(trim(coalesce(r->>'medida', '')), ''), medida),
            presentacion = coalesce(nullif(trim(coalesce(r->>'presentacion', '')), ''), presentacion),
            ref_fabrica = coalesce(nullif(trim(coalesce(r->>'ref_fabrica', '')), ''), ref_fabrica),
            referencia_interna = coalesce(nullif(trim(coalesce(r->>'referencia_interna', '')), ''), referencia_interna),
            stock_maximo = coalesce(nullif(r->>'stock_maximo', '')::numeric, stock_maximo),
            proveedores = case when jsonb_typeof(r->'proveedores') = 'array' and jsonb_array_length(r->'proveedores') > 0
                               then array(select distinct x from unnest(coalesce(proveedores, '{}') || array(select jsonb_array_elements_text(r->'proveedores'))) x)
                               else proveedores end,
            updated_at = now()
        where codigo = v_cod;
        if found then
            n := n + 1;
            if v_tipo = 'servicio' then perform servicio_stock_asegurar(v_cod); end if;
        end if;
    end loop;
    return jsonb_build_object('ok', true, 'actualizados', n);
end;
$$;
grant execute on function productos_importar_ficha(jsonb) to anon, authenticated;

-- ------------------------------------------------------------
-- 2. Transferencias entre tiendas
-- ------------------------------------------------------------
create sequence if not exists seq_transferencia;
create table if not exists transferencias (
    id uuid primary key default gen_random_uuid(),
    numero text not null unique,
    origen_id uuid not null,
    origen_nombre text,
    destino_id uuid not null,
    destino_nombre text,
    estado text not null default 'borrador',
    fecha_estimada date,
    fecha_envio date,
    fecha_recepcion date,
    tipo_transporte text,
    empresa_transporte text,
    ref_transporte text,
    referencia text,
    observaciones text,
    usuario_nombre text,
    total_items int not null default 0,
    total_unidades numeric not null default 0,
    total_costo numeric not null default 0,
    created_at timestamptz not null default now(),
    completada_at timestamptz
);
create table if not exists transferencia_items (
    id uuid primary key default gen_random_uuid(),
    transferencia_id uuid not null references transferencias(id) on delete cascade,
    producto_codigo text not null,
    descripcion text,
    cantidad numeric not null,
    costo_unitario numeric not null default 0
);
create index if not exists idx_transf_fecha on transferencias(created_at desc);
create index if not exists idx_transf_items on transferencia_items(transferencia_id);
alter table transferencias enable row level security;
alter table transferencia_items enable row level security;
drop policy if exists "transferencias_select" on transferencias;
create policy "transferencias_select" on transferencias for select using (true);
drop policy if exists "transferencia_items_select" on transferencia_items;
create policy "transferencia_items_select" on transferencia_items for select using (true);
revoke insert, update, delete on transferencias, transferencia_items from anon, authenticated;
grant select on transferencias, transferencia_items to anon, authenticated;

create or replace function transferencia_guardar(p_id uuid, p_datos jsonb, p_items jsonb, p_procesar boolean, p_usuario text default 'Sistema')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    d jsonb := coalesce(p_datos, '{}'::jsonb);
    v_id uuid := p_id;
    v_numero text;
    v_estado text;
    v_origen uuid := nullif(d->>'origen_id', '')::uuid;
    v_destino uuid := nullif(d->>'destino_id', '')::uuid;
    it jsonb;
    v_cod text; v_cant numeric; v_costo numeric; v_desc text;
    v_n int := 0; v_u numeric := 0; v_c numeric := 0;
    v_casa uuid := '00000000-0000-0000-0000-000000000001';
begin
    if v_origen is null or v_destino is null then raise exception 'Elige la tienda de origen y la de destino'; end if;
    if v_origen = v_destino then raise exception 'El origen y el destino no pueden ser la misma tienda'; end if;
    if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'Agrega al menos un producto'; end if;

    if v_id is null then
        v_numero := 'TR-' || lpad(nextval('seq_transferencia')::text, 6, '0');
        insert into transferencias (numero, origen_id, destino_id) values (v_numero, v_origen, v_destino) returning id into v_id;
    else
        select estado, numero into v_estado, v_numero from transferencias where id = v_id for update;
        if not found then raise exception 'Transferencia no encontrada'; end if;
        if v_estado <> 'borrador' then raise exception 'Solo se puede editar una transferencia en borrador'; end if;
        delete from transferencia_items where transferencia_id = v_id;
    end if;

    for it in select value from jsonb_array_elements(p_items) loop
        v_cod := nullif(trim(coalesce(it->>'codigo', '')), '');
        v_cant := coalesce((it->>'cantidad')::numeric, 0);
        if v_cod is null or v_cant <= 0 then raise exception 'Producto o cantidad inválida'; end if;
        select descripcion, costo into v_desc, v_costo from productos where codigo = v_cod;
        if not found then raise exception 'Producto % no existe', v_cod; end if;
        if v_origen <> v_casa then
            select coalesce(nullif(costo, 0), v_costo) into v_costo from sucursal_stock where sucursal_id = v_origen and producto_codigo = v_cod;
        end if;
        v_costo := coalesce(v_costo, 0);
        insert into transferencia_items (transferencia_id, producto_codigo, descripcion, cantidad, costo_unitario)
        values (v_id, v_cod, v_desc, v_cant, v_costo);
        v_n := v_n + 1; v_u := v_u + v_cant; v_c := v_c + v_cant * v_costo;
    end loop;

    update transferencias set
        origen_id = v_origen, origen_nombre = coalesce(d->>'origen_nombre', origen_nombre),
        destino_id = v_destino, destino_nombre = coalesce(d->>'destino_nombre', destino_nombre),
        fecha_estimada = nullif(d->>'fecha_estimada', '')::date, fecha_envio = nullif(d->>'fecha_envio', '')::date,
        fecha_recepcion = nullif(d->>'fecha_recepcion', '')::date,
        tipo_transporte = nullif(trim(coalesce(d->>'tipo_transporte', '')), ''), empresa_transporte = nullif(trim(coalesce(d->>'empresa_transporte', '')), ''),
        ref_transporte = nullif(trim(coalesce(d->>'ref_transporte', '')), ''), referencia = nullif(trim(coalesce(d->>'referencia', '')), ''),
        observaciones = nullif(trim(coalesce(d->>'observaciones', '')), ''), usuario_nombre = coalesce(p_usuario, usuario_nombre),
        total_items = v_n, total_unidades = v_u, total_costo = round(v_c, 2)
    where id = v_id;

    if p_procesar then
        for it in select to_jsonb(ti) from transferencia_items ti where ti.transferencia_id = v_id loop
            perform transferir_stock_sucursal(it->>'producto_codigo', (it->>'cantidad')::numeric, (it->>'costo_unitario')::numeric, v_origen, v_destino, coalesce(p_usuario, 'Sistema'));
            insert into kardex_movimientos (producto_codigo, producto_descripcion, fecha, tipo, cantidad, costo_unitario, costo_total, saldo_cantidad, saldo_costo_promedio, referencia, usuario_nombre, sucursal_id)
            values (it->>'producto_codigo', it->>'descripcion', current_date, 'salida_traslado', -((it->>'cantidad')::numeric), (it->>'costo_unitario')::numeric,
                    (it->>'cantidad')::numeric * (it->>'costo_unitario')::numeric, stock_en(it->>'producto_codigo', v_origen), (it->>'costo_unitario')::numeric,
                    v_numero || ' → ' || coalesce(d->>'destino_nombre', ''), coalesce(p_usuario, 'Sistema'), case when v_origen = v_casa then null else v_origen end),
                   (it->>'producto_codigo', it->>'descripcion', current_date, 'entrada_traslado', (it->>'cantidad')::numeric, (it->>'costo_unitario')::numeric,
                    (it->>'cantidad')::numeric * (it->>'costo_unitario')::numeric, stock_en(it->>'producto_codigo', v_destino), (it->>'costo_unitario')::numeric,
                    v_numero || ' ← ' || coalesce(d->>'origen_nombre', ''), coalesce(p_usuario, 'Sistema'), case when v_destino = v_casa then null else v_destino end);
        end loop;
        update transferencias set estado = 'completada', completada_at = now(),
            fecha_envio = coalesce(fecha_envio, current_date), fecha_recepcion = coalesce(fecha_recepcion, current_date)
        where id = v_id;
    end if;
    return jsonb_build_object('ok', true, 'id', v_id, 'numero', v_numero, 'estado', case when p_procesar then 'completada' else 'borrador' end);
end;
$$;

create or replace function transferencia_cancelar(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
    update transferencias set estado = 'cancelada' where id = p_id and estado = 'borrador';
    if not found then raise exception 'Solo se puede cancelar una transferencia en borrador'; end if;
    return jsonb_build_object('ok', true);
end;
$$;
grant execute on function transferencia_guardar(uuid, jsonb, jsonb, boolean, text) to anon, authenticated;
grant execute on function transferencia_cancelar(uuid) to anon, authenticated;

-- ------------------------------------------------------------
-- 3. Conteos con lista de productos, fechas y descripción
-- ------------------------------------------------------------
alter table conteos add column if not exists fecha_inicio date;
alter table conteos add column if not exists fecha_fin date;

create or replace function conteo_crear_lista(
    p_nombre text, p_sucursal_id uuid, p_sucursal_nombre text, p_codigos jsonb,
    p_usuario text default 'Sistema', p_descripcion text default null,
    p_fecha_inicio date default null, p_fecha_fin date default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_id uuid;
    v_numero text;
    v_n int;
    v_casa boolean := (p_sucursal_id is null or p_sucursal_id = '00000000-0000-0000-0000-000000000001');
begin
    if p_codigos is null or jsonb_typeof(p_codigos) <> 'array' or jsonb_array_length(p_codigos) = 0 then raise exception 'Agrega al menos un producto al conteo'; end if;
    if p_fecha_inicio is not null and p_fecha_fin is not null and p_fecha_fin < p_fecha_inicio then raise exception 'La fecha fin no puede ser antes de la fecha inicio'; end if;
    v_numero := 'CI-' || lpad(nextval('seq_conteo')::text, 6, '0');
    insert into conteos (numero, nombre, sucursal_id, sucursal_nombre, usuario_nombre, notas, fecha_inicio, fecha_fin)
    values (v_numero, coalesce(nullif(trim(coalesce(p_nombre, '')), ''), 'Conteo ' || to_char(now(), 'DD/MM/YYYY')),
            p_sucursal_id, coalesce(p_sucursal_nombre, 'Casa Matriz'), coalesce(p_usuario, 'Sistema'), p_descripcion, p_fecha_inicio, p_fecha_fin)
    returning id into v_id;

    insert into conteo_items (conteo_id, producto_codigo, descripcion, categoria, stock_sistema)
    select v_id, p.codigo, p.descripcion, p.categoria,
           case when v_casa then coalesce(p.stock, 0) else coalesce(ss.stock, 0) end
    from (select distinct value as codigo from jsonb_array_elements_text(p_codigos)) c
    join productos p on p.codigo = c.codigo
    left join sucursal_stock ss on ss.producto_codigo = p.codigo and ss.sucursal_id = p_sucursal_id;

    get diagnostics v_n = row_count;
    if v_n = 0 then raise exception 'Ninguno de los productos existe (o son servicios)'; end if;
    update conteos set items_total = v_n where id = v_id;
    return jsonb_build_object('ok', true, 'id', v_id, 'numero', v_numero, 'items', v_n);
end;
$$;
grant execute on function conteo_crear_lista(text, uuid, text, jsonb, text, text, date, date) to anon, authenticated;

-- ------------------------------------------------------------
-- 4. Órdenes de compra: negociación de pago y entrega
-- ------------------------------------------------------------
alter table ordenes_compra add column if not exists tipo_negociacion text;
alter table ordenes_compra add column if not exists moneda_pago text;
alter table ordenes_compra add column if not exists forma_pago text;
alter table ordenes_compra add column if not exists contacto text;
alter table ordenes_compra add column if not exists fecha_vencimiento date;
alter table ordenes_compra add column if not exists empresa_transporte text;
alter table ordenes_compra add column if not exists tracking text;
alter table ordenes_compra add column if not exists referencia text;
alter table ordenes_compra add column if not exists total_impuestos numeric not null default 0;

create or replace function oc_extra_guardar(p_id uuid, p_extra jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare e jsonb := coalesce(p_extra, '{}'::jsonb);
begin
    update ordenes_compra set
        tipo_negociacion = nullif(trim(coalesce(e->>'tipo_negociacion', '')), ''),
        moneda_pago = nullif(trim(coalesce(e->>'moneda_pago', '')), ''),
        forma_pago = nullif(trim(coalesce(e->>'forma_pago', '')), ''),
        contacto = nullif(trim(coalesce(e->>'contacto', '')), ''),
        fecha_vencimiento = nullif(e->>'fecha_vencimiento', '')::date,
        empresa_transporte = nullif(trim(coalesce(e->>'empresa_transporte', '')), ''),
        tracking = nullif(trim(coalesce(e->>'tracking', '')), ''),
        referencia = nullif(trim(coalesce(e->>'referencia', '')), ''),
        total_impuestos = coalesce(nullif(e->>'total_impuestos', '')::numeric, 0)
    where id = p_id;
    if not found then raise exception 'Orden no encontrada'; end if;
    return jsonb_build_object('ok', true);
end;
$$;
grant execute on function oc_extra_guardar(uuid, jsonb) to anon, authenticated;

-- ------------------------------------------------------------
-- 5. Bancos (cuentas bancarias, saldos, transferencias)
-- ------------------------------------------------------------
create table if not exists cuentas_bancarias (
    id uuid primary key default gen_random_uuid(),
    banco text not null,
    alias text not null,
    numero text,
    moneda text not null default 'VES',
    saldo numeric not null default 0,
    metodos text[] not null default '{}',
    por_defecto boolean not null default false,
    activa boolean not null default true,
    created_at timestamptz not null default now()
);
create table if not exists cuenta_movimientos (
    id uuid primary key default gen_random_uuid(),
    cuenta_id uuid not null references cuentas_bancarias(id) on delete cascade,
    fecha date not null default current_date,
    tipo text not null,
    monto numeric not null,
    saldo_despues numeric not null default 0,
    motivo text,
    referencia text,
    usuario_nombre text,
    transferencia_id uuid,
    created_at timestamptz not null default now()
);
create index if not exists idx_cta_mov on cuenta_movimientos(cuenta_id, created_at desc);
alter table cuentas_bancarias enable row level security;
alter table cuenta_movimientos enable row level security;
drop policy if exists "cuentas_bancarias_select" on cuentas_bancarias;
create policy "cuentas_bancarias_select" on cuentas_bancarias for select using (true);
drop policy if exists "cuenta_movimientos_select" on cuenta_movimientos;
create policy "cuenta_movimientos_select" on cuenta_movimientos for select using (true);
revoke insert, update, delete on cuentas_bancarias, cuenta_movimientos from anon, authenticated;
grant select on cuentas_bancarias, cuenta_movimientos to anon, authenticated;

create or replace function cuenta_guardar(p_id uuid, p_datos jsonb, p_usuario text default 'Sistema')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    d jsonb := coalesce(p_datos, '{}'::jsonb);
    v_id uuid := p_id;
    v_saldo numeric := coalesce(nullif(d->>'saldo', '')::numeric, 0);
    v_moneda text := upper(coalesce(nullif(d->>'moneda', ''), 'VES'));
    v_def boolean := coalesce((d->>'por_defecto')::boolean, false);
begin
    if nullif(trim(coalesce(d->>'banco', '')), '') is null then raise exception 'Selecciona el banco'; end if;
    if nullif(trim(coalesce(d->>'alias', '')), '') is null then raise exception 'Escribe el alias de la cuenta'; end if;
    if v_moneda not in ('VES', 'USD') then raise exception 'Moneda inválida'; end if;
    if v_def then update cuentas_bancarias set por_defecto = false where moneda = v_moneda; end if;
    if v_id is null then
        insert into cuentas_bancarias (banco, alias, numero, moneda, saldo, metodos, por_defecto)
        values (trim(d->>'banco'), trim(d->>'alias'), nullif(trim(coalesce(d->>'numero', '')), ''), v_moneda, v_saldo,
                case when jsonb_typeof(d->'metodos') = 'array' then array(select jsonb_array_elements_text(d->'metodos')) else '{}' end, v_def)
        returning id into v_id;
        insert into cuenta_movimientos (cuenta_id, tipo, monto, saldo_despues, motivo, usuario_nombre)
        values (v_id, 'saldo_inicial', v_saldo, v_saldo, 'Saldo inicial', p_usuario);
    else
        update cuentas_bancarias set banco = trim(d->>'banco'), alias = trim(d->>'alias'), numero = nullif(trim(coalesce(d->>'numero', '')), ''),
            moneda = v_moneda, por_defecto = v_def, activa = coalesce((d->>'activa')::boolean, activa),
            metodos = case when jsonb_typeof(d->'metodos') = 'array' then array(select jsonb_array_elements_text(d->'metodos')) else metodos end
        where id = v_id;
        if not found then raise exception 'Cuenta no encontrada'; end if;
    end if;
    return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

create or replace function cuenta_movimiento(p_cuenta uuid, p_tipo text, p_monto numeric, p_motivo text, p_fecha date default current_date, p_referencia text default null, p_usuario text default 'Sistema')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_saldo numeric; v_delta numeric;
begin
    if p_tipo not in ('ingreso', 'egreso', 'ajuste') then raise exception 'Tipo inválido'; end if;
    if p_monto is null or (p_tipo <> 'ajuste' and p_monto <= 0) then raise exception 'El monto debe ser mayor a 0'; end if;
    select saldo into v_saldo from cuentas_bancarias where id = p_cuenta for update;
    if not found then raise exception 'Cuenta no encontrada'; end if;
    v_delta := case when p_tipo = 'egreso' then -p_monto when p_tipo = 'ingreso' then p_monto else p_monto - v_saldo end;
    update cuentas_bancarias set saldo = saldo + v_delta where id = p_cuenta returning saldo into v_saldo;
    insert into cuenta_movimientos (cuenta_id, fecha, tipo, monto, saldo_despues, motivo, referencia, usuario_nombre)
    values (p_cuenta, coalesce(p_fecha, current_date), p_tipo, v_delta, v_saldo, p_motivo, p_referencia, p_usuario);
    return jsonb_build_object('ok', true, 'saldo', v_saldo);
end;
$$;

create or replace function cuenta_transferir(p_origen uuid, p_destino uuid, p_fecha date, p_monto numeric, p_monto_destino numeric, p_motivo text, p_usuario text default 'Sistema')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    o record; d record; v_tid uuid := gen_random_uuid(); v_md numeric;
begin
    if p_origen = p_destino then raise exception 'El banco origen y destino no pueden ser el mismo'; end if;
    if p_monto is null or p_monto <= 0 then raise exception 'El monto debe ser mayor a 0'; end if;
    select * into o from cuentas_bancarias where id = p_origen for update;
    if not found then raise exception 'Cuenta origen no encontrada'; end if;
    select * into d from cuentas_bancarias where id = p_destino for update;
    if not found then raise exception 'Cuenta destino no encontrada'; end if;
    if o.moneda <> d.moneda and (p_monto_destino is null or p_monto_destino <= 0) then raise exception 'Las cuentas tienen monedas distintas: indica el monto que llega al destino'; end if;
    v_md := case when o.moneda = d.moneda then p_monto else p_monto_destino end;
    update cuentas_bancarias set saldo = saldo - p_monto where id = p_origen;
    update cuentas_bancarias set saldo = saldo + v_md where id = p_destino;
    insert into cuenta_movimientos (cuenta_id, fecha, tipo, monto, saldo_despues, motivo, usuario_nombre, transferencia_id)
    values (p_origen, coalesce(p_fecha, current_date), 'transferencia_salida', -p_monto, o.saldo - p_monto, coalesce(nullif(p_motivo, ''), 'Transferencia a ' || d.alias), p_usuario, v_tid),
           (p_destino, coalesce(p_fecha, current_date), 'transferencia_entrada', v_md, d.saldo + v_md, coalesce(nullif(p_motivo, ''), 'Transferencia desde ' || o.alias), p_usuario, v_tid);
    return jsonb_build_object('ok', true, 'id', v_tid);
end;
$$;
grant execute on function cuenta_guardar(uuid, jsonb, text) to anon, authenticated;
grant execute on function cuenta_movimiento(uuid, text, numeric, text, date, text, text) to anon, authenticated;
grant execute on function cuenta_transferir(uuid, uuid, date, numeric, numeric, text, text) to anon, authenticated;

-- ------------------------------------------------------------
-- 6. Clientes: ficha completa (natural / jurídico, ubicación, datos personales)
-- ------------------------------------------------------------
alter table clientes add column if not exists tipo_persona text default 'natural';
alter table clientes add column if not exists nombres text;
alter table clientes add column if not exists apellidos text;
alter table clientes add column if not exists tipo_documento text;
alter table clientes add column if not exists documento text;
alter table clientes add column if not exists estado_ve text;
alter table clientes add column if not exists ciudad text;
alter table clientes add column if not exists calle text;
alter table clientes add column if not exists genero text;
alter table clientes add column if not exists fecha_nacimiento date;
alter table clientes add column if not exists estado_civil text;
alter table clientes add column if not exists hijos int;
alter table clientes add column if not exists credito_habilitado boolean not null default false;

create or replace function cliente_ficha_guardar(p_id uuid, p_ficha jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare f jsonb := coalesce(p_ficha, '{}'::jsonb);
begin
    update clientes set
        tipo_persona = case when f->>'tipo_persona' = 'juridico' then 'juridico' else 'natural' end,
        nombres = nullif(trim(coalesce(f->>'nombres', '')), ''),
        apellidos = nullif(trim(coalesce(f->>'apellidos', '')), ''),
        tipo_documento = nullif(trim(coalesce(f->>'tipo_documento', '')), ''),
        documento = nullif(trim(coalesce(f->>'documento', '')), ''),
        estado_ve = nullif(trim(coalesce(f->>'estado_ve', '')), ''),
        ciudad = nullif(trim(coalesce(f->>'ciudad', '')), ''),
        calle = nullif(trim(coalesce(f->>'calle', '')), ''),
        genero = nullif(trim(coalesce(f->>'genero', '')), ''),
        fecha_nacimiento = nullif(f->>'fecha_nacimiento', '')::date,
        estado_civil = nullif(trim(coalesce(f->>'estado_civil', '')), ''),
        hijos = nullif(f->>'hijos', '')::int,
        credito_habilitado = coalesce((f->>'credito_habilitado')::boolean, false)
    where id = p_id;
    if not found then raise exception 'Cliente no encontrado'; end if;
    return jsonb_build_object('ok', true);
end;
$$;
grant execute on function cliente_ficha_guardar(uuid, jsonb) to anon, authenticated;

-- ------------------------------------------------------------
-- 7. Entrar con Google (Supabase Auth)
--    El correo de Google se asigna a cada colaborador. Al entrar,
--    Postgres lee el correo verificado del token de Google.
-- ------------------------------------------------------------
alter table usuarios add column if not exists email text;
create unique index if not exists idx_usuarios_email on usuarios(lower(email)) where email is not null;

create or replace function usuario_email_guardar(p_id uuid, p_email text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v text := nullif(lower(trim(coalesce(p_email, ''))), '');
begin
    if v is not null and v !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Correo inválido'; end if;
    if v is not null and exists (select 1 from usuarios where lower(email) = v and id <> p_id) then raise exception 'Ese correo ya está asignado a otro colaborador'; end if;
    update usuarios set email = v where id = p_id;
    if not found then raise exception 'Usuario no encontrado'; end if;
    return jsonb_build_object('ok', true);
end;
$$;

create or replace function login_google()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_email text;
    u record;
begin
    begin
        v_email := lower(coalesce(auth.jwt() ->> 'email', ''));
    exception when others then v_email := '';
    end;
    if v_email = '' then return jsonb_build_object('success', false, 'error', 'No hay una sesión de Google activa'); end if;
    select * into u from usuarios where lower(email) = v_email and activo = true limit 1;
    if not found then return jsonb_build_object('success', false, 'error', 'El correo ' || v_email || ' no está asignado a ningún colaborador activo. Pídele al administrador que lo agregue en Colaboradores.'); end if;
    return jsonb_build_object('success', true, 'id', u.id, 'nombre', u.nombre, 'rol', u.rol, 'permisos', coalesce(to_jsonb(u.permisos), '[]'::jsonb), 'sucursal_id', u.sucursal_id, 'email', v_email);
end;
$$;
grant execute on function usuario_email_guardar(uuid, text) to anon, authenticated;
revoke execute on function login_google() from anon, public;
grant execute on function login_google() to authenticated;
