-- ================================================================
-- REFRIMAR · ACTUALIZAR TODO (un solo archivo)
-- Copia TODO este archivo en Supabase > SQL Editor > New query > Run.
-- Se puede correr las veces que quieras: no borra datos y no duplica nada.
-- Incluye: permisos por sucursal, módulos Norkut, ficha de productos,
-- transferencias/conteos/compras, equipo e invitaciones, App POS,
-- actualización de precios y diagnóstico del sistema.
-- ================================================================


-- ################################################################
-- ## rls-sucursal-fix
-- ################################################################

-- ============================================================
-- REFRIMAR OS — FIX MULTI-SUCURSAL + ROLES (RLS / RPC)
-- ------------------------------------------------------------
-- Qué hace (idempotente: seguro volver a correrlo):
--   1. clientes y cotizaciones quedan atados a su sucursal
--      (columna sucursal_id + RPCs que la guardan).
--   2. detalle_venta: si una venta llega SIN costo (el empleado
--      ya no recibe costos en el POS), el costo se completa en el
--      servidor con el costo de la sucursal o el de Casa Matriz.
--      → Así los reportes de utilidad siguen exactos.
--   3. Índices por sucursal_id en las tablas que se filtran.
--   4. RLS: cierra la tabla chat_bot_estado (no tenía RLS) y
--      revoca escritura directa (anon) en tablas que solo se
--      escriben por RPC.
--
-- IMPORTANTE (límite real): el login es por PIN con la anon key,
-- no con Supabase Auth. Postgres NO sabe qué usuario/sucursal
-- hace cada petición, así que una policy RLS "empleado solo ve
-- su sucursal" no se puede hacer cumplir en la BD todavía. Hoy
-- se cumple en la app (filtros por sucursal + Permission Guard)
-- y en las RPC (toda escritura lleva p_sucursal_id). Al final
-- del archivo quedan las policies listas (comentadas) para el
-- día que el login pase a Supabase Auth con claims rol/sucursal.
--
-- CÓMO APLICAR — ANTES de subir la versión nueva de la app:
--   Supabase → SQL Editor → New query → pega TODO → Run
-- ============================================================

-- ------------------------------------------------------------
-- 1. Columnas sucursal_id faltantes
-- ------------------------------------------------------------
alter table clientes     add column if not exists sucursal_id uuid;
alter table cotizaciones add column if not exists sucursal_id uuid;

-- ------------------------------------------------------------
-- 2. cliente_guardar con sucursal (al editar, se conserva la
--    sucursal original del cliente)
-- ------------------------------------------------------------
drop function if exists cliente_guardar(text, uuid, text, text, text, text, text, numeric, text);

create or replace function cliente_guardar(
    p_nombre text,
    p_id uuid default null,
    p_rif text default null,
    p_telefono text default null,
    p_email text default null,
    p_direccion text default null,
    p_tipo text default 'final',
    p_limite_credito numeric default 0,
    p_notas text default null,
    p_sucursal_id uuid default null
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
    v_id uuid;
begin
    if p_nombre is null or trim(p_nombre) = '' then
        raise exception 'El nombre del cliente es obligatorio';
    end if;
    if p_limite_credito is null then p_limite_credito := 0; end if;

    if p_id is null then
        insert into clientes (nombre, rif, telefono, email, direccion, tipo,
            limite_credito, notas, sucursal_id)
        values (trim(p_nombre), p_rif, p_telefono, p_email, p_direccion,
            coalesce(p_tipo, 'final'), p_limite_credito, p_notas, p_sucursal_id)
        returning id into v_id;
    else
        update clientes
        set nombre = trim(p_nombre), rif = p_rif, telefono = p_telefono,
            email = p_email, direccion = p_direccion, tipo = coalesce(p_tipo, 'final'),
            limite_credito = p_limite_credito, notas = p_notas,
            sucursal_id = coalesce(sucursal_id, p_sucursal_id)
        where id = p_id;
        v_id := p_id;
    end if;

    if v_id is null then
        raise exception 'No se pudo guardar el cliente';
    end if;
    return v_id;
end;
$$;

grant execute on function cliente_guardar(text, uuid, text, text, text, text, text, numeric, text, uuid) to anon, authenticated;

-- ------------------------------------------------------------
-- 3. cotizacion_guardar con sucursal
-- ------------------------------------------------------------
drop function if exists cotizacion_guardar(text, jsonb, text, text, numeric, numeric, numeric, numeric, numeric, integer, text);

create or replace function cotizacion_guardar(
    p_numero text,
    p_detalle jsonb,
    p_cliente_nombre text default 'Consumidor Final',
    p_cliente_rif text default null,
    p_subtotal numeric default 0,
    p_iva numeric default 0,
    p_total_usd numeric default 0,
    p_tasa_bcv numeric default 0,
    p_total_bs numeric default 0,
    p_validez_dias integer default 7,
    p_estado text default 'pendiente',
    p_sucursal_id uuid default null
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
    v_cotizacion_id uuid;
    v_row jsonb;
    v_count int := 0;
begin
    if p_numero is null or trim(p_numero) = '' then
        raise exception 'Falta el número de cotización';
    end if;
    if p_detalle is null or jsonb_typeof(p_detalle) <> 'array' or jsonb_array_length(p_detalle) = 0 then
        raise exception 'La cotización no tiene productos';
    end if;

    insert into cotizaciones
        (numero, cliente_nombre, cliente_rif, subtotal, iva, total_usd,
         tasa_bcv, total_bs, validez_dias, estado, sucursal_id)
    values
        (trim(p_numero),
         coalesce(nullif(trim(coalesce(p_cliente_nombre, '')), ''), 'Consumidor Final'),
         p_cliente_rif, coalesce(p_subtotal, 0), coalesce(p_iva, 0), coalesce(p_total_usd, 0),
         coalesce(p_tasa_bcv, 0), coalesce(p_total_bs, 0), coalesce(p_validez_dias, 7),
         coalesce(p_estado, 'pendiente'), p_sucursal_id)
    returning id into v_cotizacion_id;

    for v_row in select value from jsonb_array_elements(p_detalle)
    loop
        if coalesce(v_row->>'producto_codigo', '') = '' then
            continue;
        end if;
        insert into detalle_cotizacion
            (cotizacion_id, producto_codigo, descripcion, cantidad, precio_unitario, descuento, total)
        values
            (v_cotizacion_id,
             v_row->>'producto_codigo',
             v_row->>'descripcion',
             coalesce((v_row->>'cantidad')::numeric, 0),
             coalesce((v_row->>'precio_unitario')::numeric, 0),
             coalesce((v_row->>'descuento')::numeric, 0),
             coalesce((v_row->>'total')::numeric, 0));
        v_count := v_count + 1;
    end loop;

    if v_count = 0 then
        raise exception 'La cotización no tiene productos';
    end if;

    return v_cotizacion_id;
end;
$$;

grant execute on function cotizacion_guardar(text, jsonb, text, text, numeric, numeric, numeric, numeric, numeric, integer, text, uuid) to anon, authenticated;

-- ------------------------------------------------------------
-- 4. Costo de venta completado en el servidor
--    (el POS del empleado manda costo 0: nunca ve costos)
-- ------------------------------------------------------------
create or replace function detalle_venta_completar_costo()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
    v_casa uuid := '00000000-0000-0000-0000-000000000001';
    v_suc uuid;
    v_costo numeric;
begin
    if coalesce(new.costo_unitario, 0) > 0 then
        return new;
    end if;

    select sucursal_id into v_suc from ventas where id = new.venta_id;

    if v_suc is not null and v_suc <> v_casa then
        select costo into v_costo
        from sucursal_stock
        where sucursal_id = v_suc and producto_codigo = new.producto_codigo;
    end if;

    if coalesce(v_costo, 0) <= 0 then
        select costo into v_costo from productos where codigo = new.producto_codigo;
    end if;

    new.costo_unitario := coalesce(v_costo, 0);
    return new;
end;
$$;

drop trigger if exists trg_detalle_venta_costo on detalle_venta;
create trigger trg_detalle_venta_costo
    before insert on detalle_venta
    for each row execute function detalle_venta_completar_costo();

-- ------------------------------------------------------------
-- 5. Índices por sucursal (filtros de cada módulo)
-- ------------------------------------------------------------
create index if not exists idx_ventas_sucursal             on ventas(sucursal_id, created_at);
create index if not exists idx_caja_mov_sucursal           on caja_movimientos(sucursal_id, fecha);
create index if not exists idx_pagos_moviles_sucursal      on pagos_moviles(sucursal_id, fecha);
create index if not exists idx_clientes_sucursal           on clientes(sucursal_id);
create index if not exists idx_cotizaciones_sucursal       on cotizaciones(sucursal_id, created_at);
create index if not exists idx_gastos_sucursal             on gastos(sucursal_id, fecha);
create index if not exists idx_ordenes_compra_sucursal     on ordenes_compra(sucursal_id);
create index if not exists idx_kardex_mov_sucursal         on kardex_movimientos(sucursal_id);
create index if not exists idx_cierre_diario_sucursal      on cierre_diario(sucursal_id, fecha);
create index if not exists idx_abonos_ventas_sucursal      on abonos_ventas(sucursal_id);
create index if not exists idx_compras_proveedores_suc     on compras_proveedores(sucursal_id);
create index if not exists idx_abonos_compras_sucursal     on abonos_compras(sucursal_id);

-- ------------------------------------------------------------
-- 6. RLS: tablas que faltaban / escritura directa cerrada
-- ------------------------------------------------------------
-- chat_bot_estado no tenía RLS: cualquiera con la anon key podía
-- leer/escribir. Sus RPC son SECURITY DEFINER, así que siguen
-- funcionando con RLS activo y sin policies para anon.
do $$
begin
    if to_regclass('public.chat_bot_estado') is not null then
        execute 'alter table public.chat_bot_estado enable row level security';
        execute 'revoke all on public.chat_bot_estado from anon, authenticated';
    end if;
end $$;

-- Estas tablas solo se escriben por RPC (SECURITY DEFINER):
-- se revoca la escritura directa del rol anon/authenticated.
revoke insert, update, delete on
    gastos, ordenes_compra, compra_detalles, kardex_movimientos,
    cierre_diario, sucursal_stock, caja_movimientos, pagos_moviles,
    clientes, cotizaciones, detalle_cotizacion, abonos_ventas
from anon, authenticated;

grant select on
    gastos, ordenes_compra, compra_detalles, kardex_movimientos,
    cierre_diario, sucursal_stock, caja_movimientos, pagos_moviles,
    clientes, cotizaciones, detalle_cotizacion, abonos_ventas
to anon, authenticated;

-- ============================================================
-- 7. (FUTURO) Policies por sucursal con Supabase Auth
-- ------------------------------------------------------------
-- Actívalas SOLO cuando el login use Supabase Auth y el JWT
-- traiga app_metadata.rol y app_metadata.sucursal_id. Con la
-- anon key actual bloquearían TODA lectura, por eso van
-- comentadas. Patrón (repetir por tabla con sucursal_id):
--
-- create or replace function jwt_es_admin() returns boolean
-- language sql stable as $$
--   select coalesce(auth.jwt() -> 'app_metadata' ->> 'rol', '') = 'admin'
-- $$;
-- create or replace function jwt_sucursal() returns uuid
-- language sql stable as $$
--   select nullif(auth.jwt() -> 'app_metadata' ->> 'sucursal_id', '')::uuid
-- $$;
--
-- drop policy if exists "ventas_select" on ventas;
-- create policy "ventas_select_sucursal" on ventas for select
--   using (jwt_es_admin() or sucursal_id = jwt_sucursal()
--          or (sucursal_id is null and jwt_sucursal() = '00000000-0000-0000-0000-000000000001'));
--
-- Tablas: ventas, caja_movimientos, pagos_moviles, gastos,
-- cotizaciones, clientes, ordenes_compra, kardex_movimientos,
-- cierre_diario, abonos_ventas, compras_proveedores,
-- abonos_compras, sucursal_stock, sucursal_movimientos.
-- ============================================================


-- ################################################################
-- ## norkut-completo
-- ################################################################

-- ============================================================
-- REFRIMAR OS — ACTUALIZACIÓN ESTILO NORKUT (ARCHIVO ÚNICO)
-- ------------------------------------------------------------
-- Incluye: notas de crédito, actualización de precios, conteo de
-- inventario, turnos, órdenes de compra con estados, puntos de venta
-- (app POS), productos activos/subcategoría, importación desde Excel
-- e historial de la tasa BCV.
--
-- CÓMO APLICAR: Supabase → SQL Editor → New query → pega TODO → Run
-- Es seguro correrlo más de una vez.
-- ============================================================

-- ============================================================
-- REFRIMAR OS — MÓDULOS ESTILO NORKUT
-- ------------------------------------------------------------
--   1. Notas de crédito (devolución parcial de una factura)
--   2. Actualización de precios (masiva / por documento) + historial
--   3. Conteo de inventario (conteo físico → ajuste)
--   4. Turnos de caja por cajero
--   5. Órdenes de compra con estados (borrador → recibida)
--   6. Puntos de venta (terminales / app POS)
--
-- Todo se escribe por RPC SECURITY DEFINER (igual que el resto
-- del sistema). La anon key solo puede LEER estas tablas.
--
-- CÓMO APLICAR: Supabase → SQL Editor → New query → pega TODO → Run
-- Es seguro volver a correrlo.
-- ============================================================

-- ------------------------------------------------------------
-- 0. Columnas nuevas en tablas existentes
-- ------------------------------------------------------------
alter table ventas add column if not exists total_devuelto_usd numeric(14,2) not null default 0;
alter table ordenes_compra add column if not exists fecha_estimada date;
alter table compra_detalles add column if not exists cantidad_recibida numeric not null default 0;

-- Las compras viejas (recepción directa) ya entraron completas.
update compra_detalles d set cantidad_recibida = d.cantidad
where d.cantidad_recibida = 0
  and exists (select 1 from ordenes_compra o where o.id = d.compra_id and coalesce(o.estado, 'recibida') = 'recibida');

create sequence if not exists seq_nota_credito;
create sequence if not exists seq_precio_act;
create sequence if not exists seq_conteo;
create sequence if not exists seq_turno;
create sequence if not exists seq_odc;

-- Helper: stock actual de un producto en una ubicación (Casa Matriz = productos.stock)
create or replace function stock_en(p_codigo text, p_sucursal_id uuid)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
    select case
        when p_sucursal_id is null or p_sucursal_id = '00000000-0000-0000-0000-000000000001'
            then (select coalesce(stock, 0) from productos where codigo = p_codigo)
        else coalesce((select stock from sucursal_stock where sucursal_id = p_sucursal_id and producto_codigo = p_codigo), 0)
    end;
$$;

-- Helper: suma (o resta) stock en una ubicación
create or replace function stock_mover(p_codigo text, p_sucursal_id uuid, p_delta numeric)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
    v_desc text;
    v_nuevo numeric;
begin
    if p_sucursal_id is null or p_sucursal_id = '00000000-0000-0000-0000-000000000001' then
        update productos set stock = coalesce(stock, 0) + p_delta where codigo = p_codigo
        returning stock into v_nuevo;
        if not found then raise exception 'Producto % no existe', p_codigo; end if;
    else
        select descripcion into v_desc from productos where codigo = p_codigo;
        insert into sucursal_stock (sucursal_id, producto_codigo, producto_descripcion, stock)
        values (p_sucursal_id, p_codigo, coalesce(v_desc, p_codigo), p_delta)
        on conflict (sucursal_id, producto_codigo)
        do update set stock = sucursal_stock.stock + excluded.stock, updated_at = now()
        returning stock into v_nuevo;
    end if;
    return v_nuevo;
end;
$$;

-- ============================================================
-- 1. NOTAS DE CRÉDITO
-- ============================================================
create table if not exists notas_credito (
    id uuid primary key default gen_random_uuid(),
    numero text not null unique,
    venta_id uuid not null references ventas(id),
    venta_numero text,
    cliente_nombre text,
    cliente_rif text,
    motivo text,
    total_usd numeric(14,2) not null default 0,
    total_bs numeric(14,2) not null default 0,
    metodo_reembolso text,
    sucursal_id uuid,
    sucursal_nombre text,
    usuario_nombre text,
    created_at timestamptz not null default now()
);
create table if not exists notas_credito_detalle (
    id uuid primary key default gen_random_uuid(),
    nota_id uuid not null references notas_credito(id) on delete cascade,
    producto_codigo text not null,
    descripcion text,
    cantidad numeric not null,
    precio_unitario numeric not null default 0,
    total numeric not null default 0
);
create index if not exists idx_nc_venta on notas_credito(venta_id);
create index if not exists idx_nc_sucursal on notas_credito(sucursal_id, created_at);
create index if not exists idx_ncd_nota on notas_credito_detalle(nota_id);

create or replace function nota_credito_registrar(
    p_venta_id uuid,
    p_items jsonb,
    p_motivo text default null,
    p_usuario text default 'Sistema'
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
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
        insert into notas_credito_detalle (nota_id, producto_codigo, descripcion, cantidad, precio_unitario, total)
        values (v_nota_id, v_codigo, v_desc, v_cant, v_precio, round(v_precio * v_cant, 2));
        v_total := v_total + round(v_precio * v_cant, 2);

        -- El producto vuelve al stock de la sucursal donde se vendió
        perform stock_mover(v_codigo, v_venta.sucursal_id, v_cant);
        insert into kardex_movimientos (producto_codigo, producto_descripcion, fecha, tipo, cantidad, costo_unitario, costo_total,
            saldo_cantidad, saldo_costo_promedio, referencia, usuario_nombre, sucursal_id)
        values (v_codigo, coalesce(v_desc, v_codigo), current_date, 'entrada_devolucion', v_cant, 0, 0,
            stock_en(v_codigo, v_venta.sucursal_id), 0, v_numero || ' (' || coalesce(v_venta.numero, '') || ')',
            coalesce(p_usuario, 'Sistema'), v_venta.sucursal_id);
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
$$;

-- No se puede anular una factura que ya tiene notas de crédito (se devolvería doble).
create or replace function ventas_bloquear_anulacion_con_nc()
returns trigger
language plpgsql
as $$
begin
    if new.estado = 'anulada' and coalesce(old.estado, '') <> 'anulada' and coalesce(old.total_devuelto_usd, 0) > 0 then
        raise exception 'Esta factura tiene notas de crédito. Usa otra nota de crédito para devolver el resto.';
    end if;
    return new;
end;
$$;
drop trigger if exists trg_ventas_anular_nc on ventas;
create trigger trg_ventas_anular_nc before update on ventas
    for each row execute function ventas_bloquear_anulacion_con_nc();

-- ============================================================
-- 2. ACTUALIZACIÓN DE PRECIOS
-- ============================================================
create table if not exists precio_actualizaciones (
    id uuid primary key default gen_random_uuid(),
    numero text not null unique,
    tipo text not null,
    descripcion text,
    estado text not null default 'completada',
    procesados int not null default 0,
    errores int not null default 0,
    omitidos int not null default 0,
    total int not null default 0,
    usuario_nombre text,
    created_at timestamptz not null default now(),
    revertida_at timestamptz
);
create table if not exists precio_actualizacion_detalle (
    id uuid primary key default gen_random_uuid(),
    actualizacion_id uuid not null references precio_actualizaciones(id) on delete cascade,
    producto_codigo text not null,
    descripcion text,
    precio_anterior numeric,
    precio_nuevo numeric,
    resultado text not null default 'procesado'
);
create index if not exists idx_pad_act on precio_actualizacion_detalle(actualizacion_id);

create or replace function precios_actualizar(
    p_tipo text,
    p_descripcion text,
    p_items jsonb,
    p_usuario text default 'Sistema'
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_id uuid;
    v_numero text;
    v_item jsonb;
    v_codigo text;
    v_nuevo numeric;
    v_ant numeric;
    v_desc text;
    v_ok int := 0; v_err int := 0; v_omit int := 0; v_tot int := 0;
begin
    if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
        raise exception 'No hay productos para actualizar';
    end if;
    v_numero := 'AP-' || lpad(nextval('seq_precio_act')::text, 6, '0');
    insert into precio_actualizaciones (numero, tipo, descripcion, usuario_nombre)
    values (v_numero, coalesce(p_tipo, 'manual'), p_descripcion, coalesce(p_usuario, 'Sistema'))
    returning id into v_id;

    for v_item in select value from jsonb_array_elements(p_items) loop
        v_tot := v_tot + 1;
        v_codigo := trim(coalesce(v_item->>'codigo', ''));
        begin
            v_nuevo := round((v_item->>'precio')::numeric, 2);
        exception when others then
            v_nuevo := null;
        end;
        select precio, descripcion into v_ant, v_desc from productos where codigo = v_codigo;
        if not found then
            v_err := v_err + 1;
            insert into precio_actualizacion_detalle (actualizacion_id, producto_codigo, precio_nuevo, resultado)
            values (v_id, v_codigo, v_nuevo, 'error: código no existe');
            continue;
        end if;
        if v_nuevo is null or v_nuevo <= 0 or v_nuevo = coalesce(v_ant, 0) then
            v_omit := v_omit + 1;
            insert into precio_actualizacion_detalle (actualizacion_id, producto_codigo, descripcion, precio_anterior, precio_nuevo, resultado)
            values (v_id, v_codigo, v_desc, v_ant, v_nuevo, 'omitido');
            continue;
        end if;
        update productos set precio = v_nuevo where codigo = v_codigo;
        insert into precio_actualizacion_detalle (actualizacion_id, producto_codigo, descripcion, precio_anterior, precio_nuevo)
        values (v_id, v_codigo, v_desc, v_ant, v_nuevo);
        v_ok := v_ok + 1;
    end loop;

    update precio_actualizaciones set procesados = v_ok, errores = v_err, omitidos = v_omit, total = v_tot where id = v_id;
    return jsonb_build_object('ok', true, 'id', v_id, 'numero', v_numero, 'procesados', v_ok, 'errores', v_err, 'omitidos', v_omit, 'total', v_tot);
end;
$$;

create or replace function precios_revertir(p_id uuid, p_usuario text default 'Sistema')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_estado text;
    v_n int := 0;
    r record;
begin
    select estado into v_estado from precio_actualizaciones where id = p_id for update;
    if not found then raise exception 'Actualización no encontrada'; end if;
    if v_estado <> 'completada' then raise exception 'Esta actualización ya fue revertida'; end if;
    for r in select * from precio_actualizacion_detalle where actualizacion_id = p_id and resultado = 'procesado' loop
        update productos set precio = r.precio_anterior where codigo = r.producto_codigo and precio = r.precio_nuevo;
        if found then v_n := v_n + 1; end if;
    end loop;
    update precio_actualizaciones set estado = 'revertida', revertida_at = now() where id = p_id;
    return jsonb_build_object('ok', true, 'revertidos', v_n);
end;
$$;

-- ============================================================
-- 3. CONTEO DE INVENTARIO
-- ============================================================
create table if not exists conteos (
    id uuid primary key default gen_random_uuid(),
    numero text not null unique,
    nombre text,
    sucursal_id uuid,
    sucursal_nombre text,
    estado text not null default 'borrador',
    filtro_categoria text,
    notas text,
    usuario_nombre text,
    items_total int not null default 0,
    items_contados int not null default 0,
    diferencias int not null default 0,
    created_at timestamptz not null default now(),
    cerrado_at timestamptz
);
create table if not exists conteo_items (
    id uuid primary key default gen_random_uuid(),
    conteo_id uuid not null references conteos(id) on delete cascade,
    producto_codigo text not null,
    descripcion text,
    categoria text,
    stock_sistema numeric not null default 0,
    contado numeric,
    unique (conteo_id, producto_codigo)
);
create index if not exists idx_conteo_items on conteo_items(conteo_id);
create index if not exists idx_conteos_suc on conteos(sucursal_id, created_at);

create or replace function conteo_crear(
    p_nombre text,
    p_sucursal_id uuid,
    p_sucursal_nombre text,
    p_categoria text default null,
    p_usuario text default 'Sistema',
    p_notas text default null
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
    v_numero := 'CI-' || lpad(nextval('seq_conteo')::text, 6, '0');
    insert into conteos (numero, nombre, sucursal_id, sucursal_nombre, filtro_categoria, usuario_nombre, notas)
    values (v_numero, coalesce(nullif(trim(coalesce(p_nombre, '')), ''), 'Conteo ' || to_char(now(), 'DD/MM/YYYY')),
            p_sucursal_id, coalesce(p_sucursal_nombre, 'Casa Matriz'), nullif(trim(coalesce(p_categoria, '')), ''),
            coalesce(p_usuario, 'Sistema'), p_notas)
    returning id into v_id;

    insert into conteo_items (conteo_id, producto_codigo, descripcion, categoria, stock_sistema)
    select v_id, p.codigo, p.descripcion, p.categoria,
           case when v_casa then coalesce(p.stock, 0) else coalesce(ss.stock, 0) end
    from productos p
    left join sucursal_stock ss on ss.producto_codigo = p.codigo and ss.sucursal_id = p_sucursal_id
    where (nullif(trim(coalesce(p_categoria, '')), '') is null or p.categoria ilike trim(p_categoria))
      and (v_casa or ss.producto_codigo is not null);

    get diagnostics v_n = row_count;
    if v_n = 0 then raise exception 'No hay productos para contar con ese filtro'; end if;
    update conteos set items_total = v_n where id = v_id;
    return jsonb_build_object('ok', true, 'id', v_id, 'numero', v_numero, 'items', v_n);
end;
$$;

create or replace function conteo_guardar(p_id uuid, p_items jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_estado text;
    v_item jsonb;
    v_contado numeric;
begin
    select estado into v_estado from conteos where id = p_id for update;
    if not found then raise exception 'Conteo no encontrado'; end if;
    if v_estado in ('cerrada', 'cancelada') then raise exception 'Este conteo ya está %', v_estado; end if;
    for v_item in select value from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) loop
        if v_item->>'contado' is null or v_item->>'contado' = '' then
            v_contado := null;
        else
            v_contado := (v_item->>'contado')::numeric;
            if v_contado < 0 then raise exception 'La cantidad contada no puede ser negativa'; end if;
        end if;
        update conteo_items set contado = v_contado
        where conteo_id = p_id and producto_codigo = v_item->>'codigo';
    end loop;
    update conteos c set
        estado = case when c.estado = 'borrador' then 'en_progreso' else c.estado end,
        items_contados = (select count(*) from conteo_items i where i.conteo_id = p_id and i.contado is not null),
        diferencias = (select count(*) from conteo_items i where i.conteo_id = p_id and i.contado is not null and i.contado <> i.stock_sistema)
    where c.id = p_id;
    return jsonb_build_object('ok', true);
end;
$$;

create or replace function conteo_estado(p_id uuid, p_estado text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_estado text;
begin
    if p_estado not in ('en_progreso', 'revisado', 'cancelada') then raise exception 'Estado inválido'; end if;
    select estado into v_estado from conteos where id = p_id for update;
    if not found then raise exception 'Conteo no encontrado'; end if;
    if v_estado in ('cerrada', 'cancelada') then raise exception 'Este conteo ya está %', v_estado; end if;
    update conteos set estado = p_estado, cerrado_at = case when p_estado = 'cancelada' then now() else cerrado_at end where id = p_id;
    return jsonb_build_object('ok', true);
end;
$$;

-- Cierra el conteo y ajusta el stock. Se aplica la DIFERENCIA
-- (contado − stock al crear el conteo) sobre el stock actual, así
-- las ventas hechas mientras se contaba no se pierden.
create or replace function conteo_cerrar(p_id uuid, p_usuario text default 'Sistema')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_c record;
    r record;
    v_delta numeric;
    v_nuevo numeric;
    v_ajustes int := 0;
begin
    select * into v_c from conteos where id = p_id for update;
    if not found then raise exception 'Conteo no encontrado'; end if;
    if v_c.estado in ('cerrada', 'cancelada') then raise exception 'Este conteo ya está %', v_c.estado; end if;

    for r in select * from conteo_items where conteo_id = p_id and contado is not null and contado <> stock_sistema loop
        v_delta := r.contado - r.stock_sistema;
        v_nuevo := stock_mover(r.producto_codigo, v_c.sucursal_id, v_delta);
        if v_nuevo < 0 then
            v_nuevo := stock_mover(r.producto_codigo, v_c.sucursal_id, -v_nuevo);
        end if;
        insert into kardex_movimientos (producto_codigo, producto_descripcion, fecha, tipo, cantidad, costo_unitario, costo_total,
            saldo_cantidad, saldo_costo_promedio, referencia, usuario_nombre, sucursal_id)
        values (r.producto_codigo, coalesce(r.descripcion, r.producto_codigo), current_date,
            case when v_delta > 0 then 'entrada_ajuste' else 'salida_ajuste' end, v_delta, 0, 0,
            v_nuevo, 0, 'Conteo ' || v_c.numero, coalesce(p_usuario, 'Sistema'), v_c.sucursal_id);
        v_ajustes := v_ajustes + 1;
    end loop;

    update conteos set estado = 'cerrada', cerrado_at = now(), diferencias = v_ajustes where id = p_id;
    return jsonb_build_object('ok', true, 'ajustes', v_ajustes);
end;
$$;

-- ============================================================
-- 4. TURNOS DE CAJA POR CAJERO
-- ============================================================
create table if not exists turnos (
    id uuid primary key default gen_random_uuid(),
    numero text not null unique,
    usuario_id uuid,
    usuario_nombre text not null,
    sucursal_id uuid,
    sucursal_nombre text,
    terminal text,
    estado text not null default 'activo',
    fondo_usd numeric(14,2) not null default 0,
    fondo_bs numeric(14,2) not null default 0,
    abierto_at timestamptz not null default now(),
    cerrado_at timestamptz,
    ventas_count int,
    ventas_usd numeric(14,2),
    esperado_usd numeric(14,2),
    esperado_bs numeric(14,2),
    contado_usd numeric(14,2),
    contado_bs numeric(14,2),
    tasa_cierre numeric,
    diferencia_usd numeric(14,2),
    resumen jsonb,
    notas text
);
create index if not exists idx_turnos_usuario on turnos(usuario_nombre, estado);
create index if not exists idx_turnos_suc on turnos(sucursal_id, abierto_at);
create unique index if not exists uq_turno_activo_usuario on turnos(usuario_nombre) where estado = 'activo';

create or replace function turno_abrir(
    p_usuario_id uuid,
    p_usuario_nombre text,
    p_sucursal_id uuid,
    p_sucursal_nombre text,
    p_terminal text default null,
    p_fondo_usd numeric default 0,
    p_fondo_bs numeric default 0
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_id uuid;
    v_numero text;
begin
    if coalesce(trim(p_usuario_nombre), '') = '' then raise exception 'Falta el usuario'; end if;
    if exists (select 1 from turnos where usuario_nombre = p_usuario_nombre and estado = 'activo') then
        raise exception 'Ya tienes un turno abierto. Ciérralo antes de abrir otro.';
    end if;
    v_numero := 'T-' || lpad(nextval('seq_turno')::text, 6, '0');
    insert into turnos (numero, usuario_id, usuario_nombre, sucursal_id, sucursal_nombre, terminal, fondo_usd, fondo_bs)
    values (v_numero, p_usuario_id, p_usuario_nombre, p_sucursal_id, coalesce(p_sucursal_nombre, 'Casa Matriz'),
            p_terminal, greatest(coalesce(p_fondo_usd, 0), 0), greatest(coalesce(p_fondo_bs, 0), 0))
    returning id into v_id;
    return jsonb_build_object('ok', true, 'id', v_id, 'numero', v_numero);
end;
$$;

-- Resumen en vivo de un turno (ventas por método, efectivo esperado)
create or replace function turno_resumen(p_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
    v_t record;
    v_hasta timestamptz;
    v_casa boolean;
    v_res jsonb;
    v_ef_usd numeric; v_ef_bs numeric; v_ventas int; v_ventas_usd numeric;
begin
    select * into v_t from turnos where id = p_id;
    if not found then raise exception 'Turno no encontrado'; end if;
    v_hasta := coalesce(v_t.cerrado_at, now());
    v_casa := (v_t.sucursal_id is null or v_t.sucursal_id = '00000000-0000-0000-0000-000000000001');

    with movs as (
        select * from caja_movimientos m
        where m.usuario_nombre = v_t.usuario_nombre
          and m.fecha >= v_t.abierto_at and m.fecha <= v_hasta
          and (case when v_casa then (m.sucursal_id is null or m.sucursal_id = '00000000-0000-0000-0000-000000000001')
                    else m.sucursal_id = v_t.sucursal_id end)
          and m.tipo not in ('apertura', 'cierre')
    )
    select
        coalesce(sum(case when (metodo_pago is null or metodo_pago in ('efectivo', 'divisa'))
                          then (case when tipo in ('venta', 'ingreso') then coalesce(monto_usd, 0) else -coalesce(monto_usd, 0) end) else 0 end), 0),
        coalesce(sum(case when (metodo_pago is null or metodo_pago in ('efectivo', 'divisa'))
                          then (case when tipo in ('venta', 'ingreso') then coalesce(monto_bs, 0) else -coalesce(monto_bs, 0) end) else 0 end), 0),
        count(*) filter (where tipo = 'venta'),
        coalesce(sum(monto_usd) filter (where tipo = 'venta'), 0),
        coalesce((select jsonb_agg(jsonb_build_object('metodo', metodo, 'cantidad', n, 'usd', usd) order by usd desc)
                  from (select coalesce(metodo_pago, 'efectivo') metodo, count(*) n, sum(coalesce(monto_usd, 0)) usd
                        from movs where tipo = 'venta' group by 1) x), '[]'::jsonb)
    into v_ef_usd, v_ef_bs, v_ventas, v_ventas_usd, v_res
    from movs;

    return jsonb_build_object(
        'ventas_count', v_ventas, 'ventas_usd', round(v_ventas_usd, 2),
        'efectivo_usd', round(v_ef_usd, 2), 'efectivo_bs', round(v_ef_bs, 2),
        'esperado_usd', round(v_t.fondo_usd + v_ef_usd, 2), 'esperado_bs', round(v_t.fondo_bs + v_ef_bs, 2),
        'por_metodo', v_res);
end;
$$;

create or replace function turno_cerrar(
    p_id uuid,
    p_contado_usd numeric,
    p_contado_bs numeric,
    p_notas text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_t record;
    v_r jsonb;
    v_tasa numeric;
    v_dif numeric;
begin
    select * into v_t from turnos where id = p_id for update;
    if not found then raise exception 'Turno no encontrado'; end if;
    if v_t.estado <> 'activo' then raise exception 'Este turno ya está cerrado'; end if;

    v_r := turno_resumen(p_id);
    select coalesce(tasa_bcv_manual, 0) into v_tasa from configuracion limit 1;
    v_dif := coalesce(p_contado_usd, 0)
             + case when coalesce(v_tasa, 0) > 0 then coalesce(p_contado_bs, 0) / v_tasa else 0 end
             - (v_r->>'esperado_usd')::numeric;

    update turnos set
        estado = 'cerrado', cerrado_at = now(),
        ventas_count = (v_r->>'ventas_count')::int, ventas_usd = (v_r->>'ventas_usd')::numeric,
        esperado_usd = (v_r->>'esperado_usd')::numeric, esperado_bs = (v_r->>'esperado_bs')::numeric,
        contado_usd = coalesce(p_contado_usd, 0), contado_bs = coalesce(p_contado_bs, 0),
        tasa_cierre = v_tasa, diferencia_usd = round(v_dif, 2), resumen = v_r, notas = p_notas
    where id = p_id;
    return jsonb_build_object('ok', true, 'diferencia_usd', round(v_dif, 2), 'resumen', v_r);
end;
$$;

-- ============================================================
-- 5. ÓRDENES DE COMPRA CON ESTADOS
-- ============================================================
create or replace function oc_guardar(
    p_id uuid,
    p_proveedor_id uuid,
    p_proveedor_nombre text,
    p_fecha_estimada date,
    p_notas text,
    p_sucursal_id uuid,
    p_sucursal_nombre text,
    p_usuario text,
    p_estado text,
    p_items jsonb
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_id uuid := p_id;
    v_numero text;
    v_estado_actual text;
    v_item jsonb;
    v_codigo text; v_cant numeric; v_costo numeric; v_desc text;
    v_total numeric := 0;
begin
    if p_estado not in ('borrador', 'ordenada') then raise exception 'Estado inválido'; end if;
    if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
        raise exception 'Agrega al menos un producto a la orden';
    end if;

    if v_id is null then
        v_numero := 'ODC-' || lpad(nextval('seq_odc')::text, 8, '0');
        insert into ordenes_compra (numero, proveedor_id, proveedor_nombre, fecha, fecha_estimada, notas, usuario_nombre,
            sucursal_id, sucursal_nombre, estado)
        values (v_numero, p_proveedor_id, p_proveedor_nombre, current_date, p_fecha_estimada, p_notas, p_usuario,
            p_sucursal_id, coalesce(p_sucursal_nombre, 'Casa Matriz'), p_estado)
        returning id into v_id;
    else
        select estado, numero into v_estado_actual, v_numero from ordenes_compra where id = v_id for update;
        if not found then raise exception 'Orden no encontrada'; end if;
        if v_estado_actual not in ('borrador', 'ordenada') then raise exception 'Solo se pueden editar órdenes en borrador u ordenadas'; end if;
        update ordenes_compra set proveedor_id = p_proveedor_id, proveedor_nombre = p_proveedor_nombre,
            fecha_estimada = p_fecha_estimada, notas = p_notas, sucursal_id = p_sucursal_id,
            sucursal_nombre = coalesce(p_sucursal_nombre, 'Casa Matriz'), estado = p_estado
        where id = v_id;
        delete from compra_detalles where compra_id = v_id;
    end if;

    for v_item in select value from jsonb_array_elements(p_items) loop
        v_codigo := coalesce(v_item->>'codigo', '');
        v_cant := coalesce((v_item->>'cantidad')::numeric, 0);
        v_costo := coalesce((v_item->>'costo_unitario')::numeric, 0);
        if v_codigo = '' or v_cant <= 0 then raise exception 'Producto o cantidad inválida en la orden'; end if;
        select descripcion into v_desc from productos where codigo = v_codigo;
        if not found then raise exception 'Producto % no existe', v_codigo; end if;
        insert into compra_detalles (compra_id, producto_codigo, descripcion, cantidad, costo_unitario, subtotal, cantidad_recibida)
        values (v_id, v_codigo, v_desc, v_cant, v_costo, round(v_cant * v_costo, 2), 0);
        v_total := v_total + round(v_cant * v_costo, 2);
    end loop;
    update ordenes_compra set subtotal = v_total where id = v_id;
    return jsonb_build_object('ok', true, 'id', v_id, 'numero', v_numero, 'total', v_total);
end;
$$;

-- Recibe productos de una orden (total o parcial): entra stock a la sucursal de la orden
create or replace function oc_recibir(p_id uuid, p_items jsonb, p_usuario text default 'Sistema')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_oc record;
    v_item jsonb;
    v_det record;
    v_cant numeric;
    v_stock_global numeric;
    v_costo_actual numeric;
    v_nuevo_costo numeric;
    v_nuevo_stock numeric;
    v_pend numeric;
    v_recibidos int := 0;
begin
    select * into v_oc from ordenes_compra where id = p_id for update;
    if not found then raise exception 'Orden no encontrada'; end if;
    if v_oc.estado not in ('ordenada', 'parcial', 'borrador') then
        raise exception 'Esta orden está % y no puede recibir productos', v_oc.estado;
    end if;

    for v_item in select value from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) loop
        v_cant := coalesce((v_item->>'cantidad')::numeric, 0);
        if v_cant <= 0 then continue; end if;
        select * into v_det from compra_detalles where compra_id = p_id and producto_codigo = v_item->>'codigo' for update;
        if not found then raise exception 'El producto % no está en la orden', v_item->>'codigo'; end if;
        v_pend := v_det.cantidad - v_det.cantidad_recibida;
        if v_cant > v_pend + 0.0005 then
            raise exception 'De "%" faltan por recibir % (intentaste %)', coalesce(v_det.descripcion, v_det.producto_codigo), v_pend, v_cant;
        end if;

        -- Costo promedio ponderado global (igual que compra_registrar)
        select coalesce(stock, 0), coalesce(costo, 0) into v_stock_global, v_costo_actual from productos where codigo = v_det.producto_codigo;
        v_nuevo_stock := stock_mover(v_det.producto_codigo, v_oc.sucursal_id, v_cant);
        if v_det.costo_unitario > 0 then
            if v_stock_global + v_cant > 0 then
                v_nuevo_costo := (v_stock_global * v_costo_actual + v_cant * v_det.costo_unitario) / (v_stock_global + v_cant);
            else
                v_nuevo_costo := v_det.costo_unitario;
            end if;
            update productos set costo = round(v_nuevo_costo, 4) where codigo = v_det.producto_codigo;
            if v_oc.sucursal_id is not null and v_oc.sucursal_id <> '00000000-0000-0000-0000-000000000001' then
                update sucursal_stock set costo = v_det.costo_unitario where sucursal_id = v_oc.sucursal_id and producto_codigo = v_det.producto_codigo;
            end if;
        else
            v_nuevo_costo := v_costo_actual;
        end if;

        update compra_detalles set cantidad_recibida = cantidad_recibida + v_cant where id = v_det.id;
        insert into kardex_movimientos (producto_codigo, producto_descripcion, fecha, tipo, cantidad, costo_unitario, costo_total,
            saldo_cantidad, saldo_costo_promedio, referencia, usuario_nombre, sucursal_id)
        values (v_det.producto_codigo, coalesce(v_det.descripcion, v_det.producto_codigo), current_date, 'entrada_compra', v_cant,
            v_det.costo_unitario, round(v_cant * v_det.costo_unitario, 2), v_nuevo_stock, coalesce(v_nuevo_costo, 0),
            v_oc.numero, coalesce(p_usuario, 'Sistema'), v_oc.sucursal_id);
        v_recibidos := v_recibidos + 1;
    end loop;

    if v_recibidos = 0 then raise exception 'Indica cuántas unidades recibes de al menos un producto'; end if;

    update ordenes_compra set
        estado = case when exists (select 1 from compra_detalles where compra_id = p_id and cantidad_recibida < cantidad) then 'parcial' else 'recibida' end,
        recibida_at = now()
    where id = p_id;
    return jsonb_build_object('ok', true, 'estado', (select estado from ordenes_compra where id = p_id));
end;
$$;

create or replace function oc_estado(p_id uuid, p_estado text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_estado text; v_recibido numeric;
begin
    if p_estado not in ('ordenada', 'cerrada', 'cancelada') then raise exception 'Estado inválido'; end if;
    select estado into v_estado from ordenes_compra where id = p_id for update;
    if not found then raise exception 'Orden no encontrada'; end if;
    select coalesce(sum(cantidad_recibida), 0) into v_recibido from compra_detalles where compra_id = p_id;
    if p_estado = 'ordenada' and v_estado <> 'borrador' then raise exception 'Solo un borrador puede pasar a ordenada'; end if;
    if p_estado = 'cancelada' and v_recibido > 0 then raise exception 'No se puede cancelar: ya se recibieron productos. Ciérrala.'; end if;
    if v_estado in ('cerrada', 'cancelada') then raise exception 'La orden ya está %', v_estado; end if;
    if p_estado = 'cerrada' and v_estado = 'recibida' then raise exception 'La orden ya está recibida completa'; end if;
    update ordenes_compra set estado = p_estado where id = p_id;
    return jsonb_build_object('ok', true);
end;
$$;

-- ============================================================
-- 6. PUNTOS DE VENTA (terminales de la app POS)
-- ============================================================
create table if not exists pos_terminales (
    id uuid primary key default gen_random_uuid(),
    nombre text not null,
    token text not null unique,
    sucursal_id uuid,
    sucursal_nombre text,
    estado text not null default 'activo',
    ultima_conexion timestamptz,
    created_at timestamptz not null default now()
);

create or replace function terminal_registrar(p_nombre text, p_sucursal_id uuid, p_sucursal_nombre text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_token text; v_id uuid;
begin
    if coalesce(trim(p_nombre), '') = '' then raise exception 'Ponle un nombre a esta caja (ej: CAJA 1)'; end if;
    v_token := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 16));
    insert into pos_terminales (nombre, token, sucursal_id, sucursal_nombre, ultima_conexion)
    values (upper(trim(p_nombre)), v_token, p_sucursal_id, coalesce(p_sucursal_nombre, 'Casa Matriz'), now())
    returning id into v_id;
    return jsonb_build_object('ok', true, 'id', v_id, 'token', v_token);
end;
$$;

create or replace function terminal_ping(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_t record;
begin
    update pos_terminales set ultima_conexion = now() where token = p_token and estado = 'activo'
    returning * into v_t;
    if not found then return jsonb_build_object('ok', false); end if;
    return jsonb_build_object('ok', true, 'id', v_t.id, 'nombre', v_t.nombre, 'sucursal_id', v_t.sucursal_id, 'sucursal_nombre', v_t.sucursal_nombre);
end;
$$;

create or replace function terminal_estado(p_id uuid, p_estado text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
    if p_estado not in ('activo', 'inactivo') then raise exception 'Estado inválido'; end if;
    update pos_terminales set estado = p_estado where id = p_id;
    if not found then raise exception 'Terminal no encontrada'; end if;
    return jsonb_build_object('ok', true);
end;
$$;

-- ============================================================
-- 7. RLS: lectura para la app, escritura solo por RPC
-- ============================================================
do $$
declare t text;
begin
    foreach t in array array['notas_credito', 'notas_credito_detalle', 'precio_actualizaciones', 'precio_actualizacion_detalle',
                             'conteos', 'conteo_items', 'turnos', 'pos_terminales']
    loop
        execute format('alter table %I enable row level security', t);
        execute format('drop policy if exists %I on %I', t || '_select', t);
        execute format('create policy %I on %I for select using (true)', t || '_select', t);
        execute format('revoke insert, update, delete on %I from anon, authenticated', t);
        execute format('grant select on %I to anon, authenticated', t);
    end loop;
end $$;

revoke insert, update, delete on ordenes_compra, compra_detalles from anon, authenticated;

grant execute on function stock_en(text, uuid) to anon, authenticated;
grant execute on function nota_credito_registrar(uuid, jsonb, text, text) to anon, authenticated;
grant execute on function precios_actualizar(text, text, jsonb, text) to anon, authenticated;
grant execute on function precios_revertir(uuid, text) to anon, authenticated;
grant execute on function conteo_crear(text, uuid, text, text, text, text) to anon, authenticated;
grant execute on function conteo_guardar(uuid, jsonb) to anon, authenticated;
grant execute on function conteo_estado(uuid, text) to anon, authenticated;
grant execute on function conteo_cerrar(uuid, text) to anon, authenticated;
grant execute on function turno_abrir(uuid, text, uuid, text, text, numeric, numeric) to anon, authenticated;
grant execute on function turno_resumen(uuid) to anon, authenticated;
grant execute on function turno_cerrar(uuid, numeric, numeric, text) to anon, authenticated;
grant execute on function oc_guardar(uuid, uuid, text, date, text, uuid, text, text, text, jsonb) to anon, authenticated;
grant execute on function oc_recibir(uuid, jsonb, text) to anon, authenticated;
grant execute on function oc_estado(uuid, text) to anon, authenticated;
grant execute on function terminal_registrar(text, uuid, text) to anon, authenticated;
grant execute on function terminal_ping(text) to anon, authenticated;
grant execute on function terminal_estado(uuid, text) to anon, authenticated;
-- stock_mover NO se expone a la app (solo lo usan las RPC de arriba)
revoke execute on function stock_mover(text, uuid, numeric) from public, anon, authenticated;


-- ============================================================
-- REFRIMAR OS — PRODUCTOS ESTILO NORKUT + IMPORTACIÓN DESDE EXCEL
-- ------------------------------------------------------------
--   - productos.activo        (inactivo = no aparece en el POS)
--   - productos.subcategoria  (Categoría > Subcategoría)
--   - productos_importar(...) carga masiva desde Excel: crea o
--     actualiza por código y fija/suma el stock en la tienda elegida.
--   - producto_extra_guardar(...) guarda subcategoría y estatus.
--
-- CÓMO APLICAR: Supabase → SQL Editor → New query → pega TODO → Run
-- (idempotente: seguro volver a correrlo)
-- ============================================================

-- Stock actual en una ubicación (también está en el SQL de módulos; se repite para que este archivo funcione solo)
create or replace function stock_en(p_codigo text, p_sucursal_id uuid)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
    select case
        when p_sucursal_id is null or p_sucursal_id = '00000000-0000-0000-0000-000000000001'
            then (select coalesce(stock, 0) from productos where codigo = p_codigo)
        else coalesce((select stock from sucursal_stock where sucursal_id = p_sucursal_id and producto_codigo = p_codigo), 0)
    end;
$$;

alter table productos add column if not exists activo boolean not null default true;
alter table productos add column if not exists subcategoria text;
create index if not exists idx_productos_categoria on productos(categoria);

-- Normaliza la unidad que viene del Excel → uds / mt / kg
create or replace function unidad_normalizar(p text)
returns text
language sql
immutable
as $$
    select case
        when p is null or trim(p) = '' then 'uds'
        when lower(trim(p)) in ('mt', 'm', 'mts', 'metro', 'metros', 'mtr', 'ml') then 'mt'
        when lower(trim(p)) in ('kg', 'kgs', 'kilo', 'kilos', 'kilogramo', 'kilogramos') then 'kg'
        else 'uds'
    end;
$$;

create or replace function productos_importar(
    p_rows jsonb,
    p_sucursal_id uuid default null,
    p_modo_stock text default 'reemplazar',
    p_actualizar boolean default true,
    p_usuario text default 'Sistema'
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_casa boolean := (p_sucursal_id is null or p_sucursal_id = '00000000-0000-0000-0000-000000000001');
    r jsonb;
    v_fila int;
    v_cod text; v_barra text; v_desc text;
    v_costo numeric; v_precio numeric; v_stock numeric; v_min numeric;
    v_existe record;
    v_actual numeric; v_nuevo numeric; v_delta numeric;
    v_creados int := 0; v_actualizados int := 0; v_omitidos int := 0;
    v_errores jsonb := '[]'::jsonb;
    v_alt text[];
begin
    if p_modo_stock not in ('reemplazar', 'sumar', 'no_tocar') then raise exception 'Modo de stock inválido'; end if;
    if p_rows is null or jsonb_typeof(p_rows) <> 'array' then raise exception 'No hay filas para importar'; end if;

    for r in select value from jsonb_array_elements(p_rows) loop
        v_fila := coalesce((r->>'fila')::int, 0);
        begin
            v_cod := nullif(trim(coalesce(r->>'codigo', '')), '');
            v_barra := nullif(trim(coalesce(r->>'barra', '')), '');
            if v_cod is null then v_cod := v_barra; end if;
            if v_cod is null then raise exception 'Sin código'; end if;
            v_desc := nullif(trim(coalesce(r->>'descripcion', '')), '');
            v_costo := nullif(r->>'costo', '')::numeric;
            v_precio := nullif(r->>'precio', '')::numeric;
            v_stock := nullif(r->>'stock', '')::numeric;
            v_min := nullif(r->>'stock_minimo', '')::numeric;
            if v_costo < 0 or v_precio < 0 or v_min < 0 then raise exception 'Hay números negativos'; end if;

            select * into v_existe from productos where codigo = v_cod;

            if not found then
                if v_desc is null then raise exception 'Producto nuevo sin nombre'; end if;
                v_alt := case when v_barra is not null and v_barra <> v_cod then array[v_barra] else '{}'::text[] end;
                insert into productos (codigo, descripcion, categoria, subcategoria, marca, unidad, costo, precio, stock, stock_minimo, codigos_alternos, activo)
                values (v_cod, v_desc, nullif(trim(coalesce(r->>'categoria', '')), ''), nullif(trim(coalesce(r->>'subcategoria', '')), ''),
                        nullif(trim(coalesce(r->>'marca', '')), ''), unidad_normalizar(r->>'unidad'),
                        coalesce(v_costo, 0), coalesce(v_precio, 0), 0, coalesce(v_min, 0), v_alt, true);
                v_creados := v_creados + 1;
            elsif p_actualizar then
                update productos set
                    descripcion = coalesce(v_desc, descripcion),
                    categoria = coalesce(nullif(trim(coalesce(r->>'categoria', '')), ''), categoria),
                    subcategoria = coalesce(nullif(trim(coalesce(r->>'subcategoria', '')), ''), subcategoria),
                    marca = coalesce(nullif(trim(coalesce(r->>'marca', '')), ''), marca),
                    unidad = case when nullif(trim(coalesce(r->>'unidad', '')), '') is null then unidad else unidad_normalizar(r->>'unidad') end,
                    costo = coalesce(v_costo, costo),
                    precio = coalesce(v_precio, precio),
                    stock_minimo = coalesce(v_min, stock_minimo),
                    codigos_alternos = case when v_barra is not null and v_barra <> v_cod and not (v_barra = any(coalesce(codigos_alternos, '{}')))
                                            then array_append(coalesce(codigos_alternos, '{}'), v_barra) else codigos_alternos end
                where codigo = v_cod;
                v_actualizados := v_actualizados + 1;
            else
                v_omitidos := v_omitidos + 1;
                continue;
            end if;

            -- Stock en la tienda elegida
            if v_stock is not null and p_modo_stock <> 'no_tocar' then
                if v_stock < 0 then raise exception 'Stock negativo'; end if;
                v_actual := stock_en(v_cod, p_sucursal_id);
                v_nuevo := case when p_modo_stock = 'sumar' then v_actual + v_stock else v_stock end;
                v_delta := v_nuevo - v_actual;
                if v_delta <> 0 then
                    if v_casa then
                        update productos set stock = v_nuevo where codigo = v_cod;
                    else
                        insert into sucursal_stock (sucursal_id, producto_codigo, producto_descripcion, stock, costo)
                        values (p_sucursal_id, v_cod, coalesce(v_desc, v_existe.descripcion, v_cod), v_nuevo, v_costo)
                        on conflict (sucursal_id, producto_codigo)
                        do update set stock = excluded.stock, costo = coalesce(excluded.costo, sucursal_stock.costo), updated_at = now();
                    end if;
                    insert into kardex_movimientos (producto_codigo, producto_descripcion, fecha, tipo, cantidad, costo_unitario, costo_total,
                        saldo_cantidad, saldo_costo_promedio, referencia, usuario_nombre, sucursal_id)
                    values (v_cod, coalesce(v_desc, v_existe.descripcion, v_cod), current_date,
                        case when v_delta > 0 then 'entrada_ajuste' else 'salida_ajuste' end, v_delta,
                        coalesce(v_costo, 0), abs(v_delta) * coalesce(v_costo, 0), v_nuevo, coalesce(v_costo, 0),
                        'Importación Excel', coalesce(p_usuario, 'Sistema'), case when v_casa then null else p_sucursal_id end);
                elsif not v_casa and not exists (select 1 from sucursal_stock where sucursal_id = p_sucursal_id and producto_codigo = v_cod) then
                    -- stock 0 en sucursal: igual se registra para que el producto aparezca en esa tienda
                    insert into sucursal_stock (sucursal_id, producto_codigo, producto_descripcion, stock, costo)
                    values (p_sucursal_id, v_cod, coalesce(v_desc, v_existe.descripcion, v_cod), 0, v_costo)
                    on conflict (sucursal_id, producto_codigo) do nothing;
                end if;
            end if;
        exception when others then
            v_errores := v_errores || jsonb_build_object('fila', v_fila, 'codigo', coalesce(v_cod, ''), 'error', sqlerrm);
        end;
    end loop;

    return jsonb_build_object('ok', true, 'creados', v_creados, 'actualizados', v_actualizados,
        'omitidos', v_omitidos, 'errores', v_errores);
end;
$$;

create or replace function producto_extra_guardar(p_codigo text, p_subcategoria text, p_activo boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
    update productos set subcategoria = nullif(trim(coalesce(p_subcategoria, '')), ''), activo = coalesce(p_activo, true)
    where codigo = p_codigo;
    if not found then raise exception 'Producto % no existe', p_codigo; end if;
    return jsonb_build_object('ok', true);
end;
$$;

grant execute on function unidad_normalizar(text) to anon, authenticated;
grant execute on function productos_importar(jsonb, uuid, text, boolean, text) to anon, authenticated;
grant execute on function producto_extra_guardar(text, text, boolean) to anon, authenticated;

-- ============================================================
-- MONEDAS: historial de la tasa BCV (cada cambio queda registrado)
-- ============================================================
create table if not exists tasas_historial (
    id uuid primary key default gen_random_uuid(),
    tasa numeric not null,
    tasa_anterior numeric,
    created_at timestamptz not null default now()
);
create index if not exists idx_tasas_hist_fecha on tasas_historial(created_at desc);

create or replace function tasa_registrar_cambio()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    if new.tasa_bcv_manual is not null and (tg_op = 'INSERT' or new.tasa_bcv_manual is distinct from old.tasa_bcv_manual) then
        insert into tasas_historial (tasa, tasa_anterior)
        values (new.tasa_bcv_manual, case when tg_op = 'UPDATE' then old.tasa_bcv_manual else null end);
    end if;
    return new;
end;
$$;
drop trigger if exists trg_tasa_historial on configuracion;
create trigger trg_tasa_historial after insert or update of tasa_bcv_manual on configuracion
    for each row execute function tasa_registrar_cambio();

alter table tasas_historial enable row level security;
drop policy if exists "tasas_historial_select" on tasas_historial;
create policy "tasas_historial_select" on tasas_historial for select using (true);
revoke insert, update, delete on tasas_historial from anon, authenticated;
grant select on tasas_historial to anon, authenticated;

-- ============================================================
-- COLABORADORES: tienda asignada (el empleado solo entra a su tienda)
-- ============================================================
alter table usuarios add column if not exists sucursal_id uuid;

create or replace function usuario_asignar_sucursal(p_id uuid, p_sucursal_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
    update usuarios set sucursal_id = p_sucursal_id where id = p_id;
    if not found then raise exception 'Usuario no encontrado'; end if;
    return jsonb_build_object('ok', true);
end;
$$;
grant execute on function usuario_asignar_sucursal(uuid, uuid) to anon, authenticated;
-- ============================================================
-- REFRIMAR — FICHA COMPLETA DE PRODUCTO (estilo Norkut)
-- ------------------------------------------------------------
-- Qué agrega (idempotente: seguro volver a correrlo):
--   • Ficha de producto: SKU, descripción larga, tipo (físico /
--     servicio), IVA por producto, pesable + código de balanza,
--     referencia interna, estatus (borrador/activo/inactivo),
--     clasificación, origen, medidas, presentación, empaques,
--     impuestos adicionales, proveedores, atributos y otras
--     referencias (fábrica, CPE, registro sanitario).
--   • Fotos del producto (tabla aparte para que las listas
--     sigan cargando rápido).
--   • Servicios: no llevan inventario (se pueden vender siempre).
--   • Histórico de importaciones de Excel.
--   • Tasa: guarda qué usuario la cambió.
--   • La importación de Excel ahora también lee el IVA.
--
-- CÓMO APLICAR: Supabase → SQL Editor → New query → pega TODO → Run
-- ============================================================

-- ------------------------------------------------------------
-- 1. Columnas nuevas de productos
-- ------------------------------------------------------------
alter table productos add column if not exists sku text;
alter table productos add column if not exists detalle text;
alter table productos add column if not exists tipo_producto text not null default 'fisico';
alter table productos add column if not exists iva_tasa numeric not null default 16;
alter table productos add column if not exists sensible boolean not null default false;
alter table productos add column if not exists requiere_serial boolean not null default false;
alter table productos add column if not exists pesable boolean not null default false;
alter table productos add column if not exists codigo_balanza text;
alter table productos add column if not exists referencia_interna text;
alter table productos add column if not exists estatus text not null default 'activo';
alter table productos add column if not exists clasificacion text;
alter table productos add column if not exists origen text;
alter table productos add column if not exists tipo_medida text;
alter table productos add column if not exists medida text;
alter table productos add column if not exists presentacion text;
alter table productos add column if not exists empaques jsonb not null default '[]'::jsonb;
alter table productos add column if not exists impuestos_extra jsonb not null default '[]'::jsonb;
alter table productos add column if not exists proveedores text[] not null default '{}';
alter table productos add column if not exists atributos jsonb not null default '{}'::jsonb;
alter table productos add column if not exists ref_fabrica text;
alter table productos add column if not exists cpe text;
alter table productos add column if not exists registro_sanitario text;
alter table productos add column if not exists variante_grupo text;
alter table productos add column if not exists updated_at timestamptz default now();

-- estatus coherente con "activo" para los productos que ya existían
update productos set estatus = 'inactivo' where activo = false and estatus = 'activo';

create index if not exists idx_productos_sku on productos(sku);
create index if not exists idx_productos_variante on productos(variante_grupo);

-- ------------------------------------------------------------
-- 2. Fotos (hasta 4 por producto, comprimidas en el navegador)
-- ------------------------------------------------------------
create table if not exists producto_imagenes (
    producto_codigo text primary key,
    imagenes jsonb not null default '[]'::jsonb,
    updated_at timestamptz not null default now()
);
alter table producto_imagenes enable row level security;
drop policy if exists "producto_imagenes_select" on producto_imagenes;
create policy "producto_imagenes_select" on producto_imagenes for select using (true);
revoke insert, update, delete on producto_imagenes from anon, authenticated;
grant select on producto_imagenes to anon, authenticated;

create or replace function producto_imagenes_guardar(p_codigo text, p_imagenes jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
    if not exists (select 1 from productos where codigo = p_codigo) then
        raise exception 'Producto % no existe', p_codigo;
    end if;
    if p_imagenes is null or jsonb_typeof(p_imagenes) <> 'array' then p_imagenes := '[]'::jsonb; end if;
    if jsonb_array_length(p_imagenes) > 4 then raise exception 'Máximo 4 fotos por producto'; end if;
    if length(p_imagenes::text) > 1500000 then raise exception 'Las fotos pesan demasiado'; end if;
    insert into producto_imagenes (producto_codigo, imagenes, updated_at)
    values (p_codigo, p_imagenes, now())
    on conflict (producto_codigo) do update set imagenes = excluded.imagenes, updated_at = now();
    return jsonb_build_object('ok', true);
end;
$$;

-- ------------------------------------------------------------
-- 3. Guardar la ficha completa (se llama después de producto_guardar)
-- ------------------------------------------------------------
create or replace function producto_ficha_guardar(p_codigo text, p_ficha jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    f jsonb := coalesce(p_ficha, '{}'::jsonb);
    v_tipo text;
    v_estatus text;
    v_iva numeric;
    v_tipo_antes text;
begin
    select tipo_producto into v_tipo_antes from productos where codigo = p_codigo;
    if not found then
        raise exception 'Producto % no existe', p_codigo;
    end if;

    v_tipo := coalesce(nullif(f->>'tipo_producto', ''), 'fisico');
    if v_tipo not in ('fisico', 'servicio') then v_tipo := 'fisico'; end if;
    v_estatus := coalesce(nullif(f->>'estatus', ''), 'activo');
    if v_estatus not in ('borrador', 'activo', 'inactivo') then v_estatus := 'activo'; end if;
    v_iva := coalesce(nullif(f->>'iva_tasa', '')::numeric, 16);
    if v_iva < 0 or v_iva > 100 then raise exception 'IVA inválido'; end if;

    update productos set
        sku = nullif(trim(coalesce(f->>'sku', '')), ''),
        detalle = nullif(trim(coalesce(f->>'detalle', '')), ''),
        subcategoria = nullif(trim(coalesce(f->>'subcategoria', '')), ''),
        tipo_producto = v_tipo,
        iva_tasa = v_iva,
        sensible = coalesce((f->>'sensible')::boolean, false),
        requiere_serial = coalesce((f->>'requiere_serial')::boolean, false),
        pesable = coalesce((f->>'pesable')::boolean, false),
        codigo_balanza = nullif(trim(coalesce(f->>'codigo_balanza', '')), ''),
        referencia_interna = nullif(trim(coalesce(f->>'referencia_interna', '')), ''),
        estatus = v_estatus,
        activo = (v_estatus = 'activo'),
        clasificacion = nullif(trim(coalesce(f->>'clasificacion', '')), ''),
        origen = nullif(trim(coalesce(f->>'origen', '')), ''),
        tipo_medida = nullif(trim(coalesce(f->>'tipo_medida', '')), ''),
        medida = nullif(trim(coalesce(f->>'medida', '')), ''),
        presentacion = nullif(trim(coalesce(f->>'presentacion', '')), ''),
        empaques = case when jsonb_typeof(f->'empaques') = 'array' then f->'empaques' else '[]'::jsonb end,
        impuestos_extra = case when jsonb_typeof(f->'impuestos_extra') = 'array' then f->'impuestos_extra' else '[]'::jsonb end,
        proveedores = case when jsonb_typeof(f->'proveedores') = 'array'
                           then array(select jsonb_array_elements_text(f->'proveedores')) else '{}'::text[] end,
        atributos = case when jsonb_typeof(f->'atributos') = 'object' then f->'atributos' else '{}'::jsonb end,
        ref_fabrica = nullif(trim(coalesce(f->>'ref_fabrica', '')), ''),
        cpe = nullif(trim(coalesce(f->>'cpe', '')), ''),
        registro_sanitario = nullif(trim(coalesce(f->>'registro_sanitario', '')), ''),
        variante_grupo = nullif(trim(coalesce(f->>'variante_grupo', '')), ''),
        updated_at = now()
    where codigo = p_codigo;

    -- Un código de barra de empaque no puede chocar con otro producto
    if exists (
        select 1
        from jsonb_array_elements(case when jsonb_typeof(f->'empaques') = 'array' then f->'empaques' else '[]'::jsonb end) e
        join productos p on p.codigo = e->>'barra' and p.codigo <> p_codigo
    ) then
        raise exception 'Un código de barra de empaque ya es el código de otro producto';
    end if;

    -- Servicios: siempre disponibles en todas las tiendas
    if v_tipo = 'servicio' then
        perform servicio_stock_asegurar(p_codigo);
    elsif v_tipo_antes = 'servicio' then
        -- dejó de ser servicio: el stock "infinito" vuelve a 0
        update productos set stock = 0 where codigo = p_codigo;
        update sucursal_stock set stock = 0, updated_at = now() where producto_codigo = p_codigo and stock >= 999999;
    end if;

    return jsonb_build_object('ok', true);
end;
$$;

-- ------------------------------------------------------------
-- 4. Servicios sin inventario
--    registrar_venta exige stock; para no tocar esa función, un
--    servicio mantiene un stock "infinito" (999999) en todas las
--    tiendas. Las pantallas lo muestran como "Servicio".
-- ------------------------------------------------------------
create or replace function servicio_stock_asegurar(p_codigo text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
    v_desc text;
begin
    select descripcion into v_desc from productos where codigo = p_codigo;
    update productos set stock = 999999 where codigo = p_codigo;
    insert into sucursal_stock (sucursal_id, producto_codigo, producto_descripcion, stock)
    select s.id, p_codigo, v_desc, 999999 from sucursales s
    on conflict (sucursal_id, producto_codigo) do update set stock = 999999, updated_at = now();
end;
$$;

create or replace function productos_servicio_stock()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    if new.tipo_producto = 'servicio' and coalesce(new.stock, 0) < 999999 then
        new.stock := 999999;
    end if;
    return new;
end;
$$;
drop trigger if exists trg_productos_servicio_stock on productos;
create trigger trg_productos_servicio_stock before insert or update on productos
    for each row execute function productos_servicio_stock();

create or replace function sucursal_stock_servicio()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    if exists (select 1 from productos where codigo = new.producto_codigo and tipo_producto = 'servicio')
       and coalesce(new.stock, 0) < 999999 then
        new.stock := 999999;
    end if;
    return new;
end;
$$;
drop trigger if exists trg_sucursal_stock_servicio on sucursal_stock;
create trigger trg_sucursal_stock_servicio before insert or update on sucursal_stock
    for each row execute function sucursal_stock_servicio();

-- Una sucursal nueva también tiene los servicios disponibles
create or replace function sucursal_nueva_servicios()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    insert into sucursal_stock (sucursal_id, producto_codigo, producto_descripcion, stock)
    select new.id, p.codigo, p.descripcion, 999999 from productos p where p.tipo_producto = 'servicio'
    on conflict (sucursal_id, producto_codigo) do nothing;
    return new;
end;
$$;
drop trigger if exists trg_sucursal_nueva_servicios on sucursales;
create trigger trg_sucursal_nueva_servicios after insert on sucursales
    for each row execute function sucursal_nueva_servicios();

-- Los servicios no se cuentan en el conteo de inventario
create or replace function conteo_items_sin_servicios()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    if exists (select 1 from productos where codigo = new.producto_codigo and tipo_producto = 'servicio') then
        return null;
    end if;
    return new;
end;
$$;
do $$ begin
    if to_regclass('public.conteo_items') is not null then
        execute 'drop trigger if exists trg_conteo_items_sin_servicios on conteo_items';
        execute 'create trigger trg_conteo_items_sin_servicios before insert on conteo_items for each row execute function conteo_items_sin_servicios()';
    end if;
end $$;

-- ------------------------------------------------------------
-- 5. Histórico de importaciones de Excel
-- ------------------------------------------------------------
create table if not exists importaciones_productos (
    id uuid primary key default gen_random_uuid(),
    archivo text,
    sucursal_id uuid,
    sucursal_nombre text,
    usuario_nombre text,
    modo_stock text,
    filas int not null default 0,
    creados int not null default 0,
    actualizados int not null default 0,
    omitidos int not null default 0,
    errores int not null default 0,
    detalle_errores jsonb not null default '[]'::jsonb,
    created_at timestamptz not null default now()
);
create index if not exists idx_import_prod_fecha on importaciones_productos(created_at desc);
alter table importaciones_productos enable row level security;
drop policy if exists "importaciones_productos_select" on importaciones_productos;
create policy "importaciones_productos_select" on importaciones_productos for select using (true);
revoke insert, update, delete on importaciones_productos from anon, authenticated;
grant select on importaciones_productos to anon, authenticated;

create or replace function importacion_registrar(
    p_archivo text, p_sucursal_id uuid, p_sucursal_nombre text, p_usuario text, p_modo_stock text,
    p_filas int, p_creados int, p_actualizados int, p_omitidos int, p_errores jsonb
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_id uuid;
begin
    insert into importaciones_productos (archivo, sucursal_id, sucursal_nombre, usuario_nombre, modo_stock,
        filas, creados, actualizados, omitidos, errores, detalle_errores)
    values (left(p_archivo, 200), p_sucursal_id, p_sucursal_nombre, p_usuario, p_modo_stock,
        coalesce(p_filas, 0), coalesce(p_creados, 0), coalesce(p_actualizados, 0), coalesce(p_omitidos, 0),
        case when jsonb_typeof(p_errores) = 'array' then jsonb_array_length(p_errores) else 0 end,
        case when jsonb_typeof(p_errores) = 'array' then p_errores else '[]'::jsonb end)
    returning id into v_id;
    return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

-- ------------------------------------------------------------
-- 6. Tasa: quién la cambió
-- ------------------------------------------------------------
alter table tasas_historial add column if not exists usuario_nombre text;

create or replace function tasa_historial_firmar(p_usuario text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
    update tasas_historial set usuario_nombre = left(p_usuario, 80)
    where id = (select id from tasas_historial
                where usuario_nombre is null and created_at > now() - interval '2 minutes'
                order by created_at desc limit 1);
    return jsonb_build_object('ok', true);
end;
$$;

-- ------------------------------------------------------------
-- 7. Importación de Excel: también lee el IVA (16 / 8 / 0 / exento)
-- ------------------------------------------------------------
create or replace function iva_normalizar(p text)
returns numeric
language sql
immutable
as $$
    select case
        when p is null or trim(p) = '' then null
        when lower(trim(p)) in ('exento', 'e', 'ex', 'no', 'iva exento', '0', '0%') then 0
        when regexp_replace(p, '[^0-9.,]', '', 'g') = '' then null
        else least(100, greatest(0, replace(regexp_replace(p, '[^0-9.,]', '', 'g'), ',', '.')::numeric
                     * case when replace(regexp_replace(p, '[^0-9.,]', '', 'g'), ',', '.')::numeric < 1 then 100 else 1 end))
    end;
$$;

create or replace function productos_importar_extra(p_rows jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    r jsonb;
    v_cod text;
    v_iva numeric;
    n int := 0;
begin
    if p_rows is null or jsonb_typeof(p_rows) <> 'array' then return jsonb_build_object('ok', true, 'actualizados', 0); end if;
    for r in select value from jsonb_array_elements(p_rows) loop
        v_cod := nullif(trim(coalesce(r->>'codigo', '')), '');
        if v_cod is null then v_cod := nullif(trim(coalesce(r->>'barra', '')), ''); end if;
        if v_cod is null then continue; end if;
        begin
            v_iva := iva_normalizar(r->>'iva');
        exception when others then v_iva := null;
        end;
        update productos set
            iva_tasa = coalesce(v_iva, iva_tasa),
            sku = coalesce(nullif(trim(coalesce(r->>'sku', '')), ''), sku),
            detalle = coalesce(nullif(trim(coalesce(r->>'detalle', '')), ''), detalle)
        where codigo = v_cod
          and (v_iva is not null or nullif(trim(coalesce(r->>'sku', '')), '') is not null or nullif(trim(coalesce(r->>'detalle', '')), '') is not null);
        if found then n := n + 1; end if;
    end loop;
    return jsonb_build_object('ok', true, 'actualizados', n);
end;
$$;

-- ------------------------------------------------------------
-- 8. Permisos
-- ------------------------------------------------------------
grant execute on function producto_imagenes_guardar(text, jsonb) to anon, authenticated;
grant execute on function producto_ficha_guardar(text, jsonb) to anon, authenticated;
grant execute on function importacion_registrar(text, uuid, text, text, text, int, int, int, int, jsonb) to anon, authenticated;
grant execute on function tasa_historial_firmar(text) to anon, authenticated;
grant execute on function productos_importar_extra(jsonb) to anon, authenticated;
grant execute on function iva_normalizar(text) to anon, authenticated;
revoke execute on function servicio_stock_asegurar(text) from anon, authenticated, public;


-- ################################################################
-- ## productos-ficha
-- ################################################################

-- ============================================================
-- REFRIMAR — FICHA COMPLETA DE PRODUCTO (estilo Norkut)
-- ------------------------------------------------------------
-- Qué agrega (idempotente: seguro volver a correrlo):
--   • Ficha de producto: SKU, descripción larga, tipo (físico /
--     servicio), IVA por producto, pesable + código de balanza,
--     referencia interna, estatus (borrador/activo/inactivo),
--     clasificación, origen, medidas, presentación, empaques,
--     impuestos adicionales, proveedores, atributos y otras
--     referencias (fábrica, CPE, registro sanitario).
--   • Fotos del producto (tabla aparte para que las listas
--     sigan cargando rápido).
--   • Servicios: no llevan inventario (se pueden vender siempre).
--   • Histórico de importaciones de Excel.
--   • Tasa: guarda qué usuario la cambió.
--   • La importación de Excel ahora también lee el IVA.
--
-- CÓMO APLICAR: Supabase → SQL Editor → New query → pega TODO → Run
-- ============================================================

-- ------------------------------------------------------------
-- 1. Columnas nuevas de productos
-- ------------------------------------------------------------
alter table productos add column if not exists sku text;
alter table productos add column if not exists detalle text;
alter table productos add column if not exists tipo_producto text not null default 'fisico';
alter table productos add column if not exists iva_tasa numeric not null default 16;
alter table productos add column if not exists sensible boolean not null default false;
alter table productos add column if not exists requiere_serial boolean not null default false;
alter table productos add column if not exists pesable boolean not null default false;
alter table productos add column if not exists codigo_balanza text;
alter table productos add column if not exists referencia_interna text;
alter table productos add column if not exists estatus text not null default 'activo';
alter table productos add column if not exists clasificacion text;
alter table productos add column if not exists origen text;
alter table productos add column if not exists tipo_medida text;
alter table productos add column if not exists medida text;
alter table productos add column if not exists presentacion text;
alter table productos add column if not exists empaques jsonb not null default '[]'::jsonb;
alter table productos add column if not exists impuestos_extra jsonb not null default '[]'::jsonb;
alter table productos add column if not exists proveedores text[] not null default '{}';
alter table productos add column if not exists atributos jsonb not null default '{}'::jsonb;
alter table productos add column if not exists ref_fabrica text;
alter table productos add column if not exists cpe text;
alter table productos add column if not exists registro_sanitario text;
alter table productos add column if not exists variante_grupo text;
alter table productos add column if not exists updated_at timestamptz default now();

-- estatus coherente con "activo" para los productos que ya existían
update productos set estatus = 'inactivo' where activo = false and estatus = 'activo';

create index if not exists idx_productos_sku on productos(sku);
create index if not exists idx_productos_variante on productos(variante_grupo);

-- ------------------------------------------------------------
-- 2. Fotos (hasta 4 por producto, comprimidas en el navegador)
-- ------------------------------------------------------------
create table if not exists producto_imagenes (
    producto_codigo text primary key,
    imagenes jsonb not null default '[]'::jsonb,
    updated_at timestamptz not null default now()
);
alter table producto_imagenes enable row level security;
drop policy if exists "producto_imagenes_select" on producto_imagenes;
create policy "producto_imagenes_select" on producto_imagenes for select using (true);
revoke insert, update, delete on producto_imagenes from anon, authenticated;
grant select on producto_imagenes to anon, authenticated;

create or replace function producto_imagenes_guardar(p_codigo text, p_imagenes jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
    if not exists (select 1 from productos where codigo = p_codigo) then
        raise exception 'Producto % no existe', p_codigo;
    end if;
    if p_imagenes is null or jsonb_typeof(p_imagenes) <> 'array' then p_imagenes := '[]'::jsonb; end if;
    if jsonb_array_length(p_imagenes) > 4 then raise exception 'Máximo 4 fotos por producto'; end if;
    if length(p_imagenes::text) > 1500000 then raise exception 'Las fotos pesan demasiado'; end if;
    insert into producto_imagenes (producto_codigo, imagenes, updated_at)
    values (p_codigo, p_imagenes, now())
    on conflict (producto_codigo) do update set imagenes = excluded.imagenes, updated_at = now();
    return jsonb_build_object('ok', true);
end;
$$;

-- ------------------------------------------------------------
-- 3. Guardar la ficha completa (se llama después de producto_guardar)
-- ------------------------------------------------------------
create or replace function producto_ficha_guardar(p_codigo text, p_ficha jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    f jsonb := coalesce(p_ficha, '{}'::jsonb);
    v_tipo text;
    v_estatus text;
    v_iva numeric;
    v_tipo_antes text;
begin
    select tipo_producto into v_tipo_antes from productos where codigo = p_codigo;
    if not found then
        raise exception 'Producto % no existe', p_codigo;
    end if;

    v_tipo := coalesce(nullif(f->>'tipo_producto', ''), 'fisico');
    if v_tipo not in ('fisico', 'servicio') then v_tipo := 'fisico'; end if;
    v_estatus := coalesce(nullif(f->>'estatus', ''), 'activo');
    if v_estatus not in ('borrador', 'activo', 'inactivo') then v_estatus := 'activo'; end if;
    v_iva := coalesce(nullif(f->>'iva_tasa', '')::numeric, 16);
    if v_iva < 0 or v_iva > 100 then raise exception 'IVA inválido'; end if;

    update productos set
        sku = nullif(trim(coalesce(f->>'sku', '')), ''),
        detalle = nullif(trim(coalesce(f->>'detalle', '')), ''),
        subcategoria = nullif(trim(coalesce(f->>'subcategoria', '')), ''),
        tipo_producto = v_tipo,
        iva_tasa = v_iva,
        sensible = coalesce((f->>'sensible')::boolean, false),
        requiere_serial = coalesce((f->>'requiere_serial')::boolean, false),
        pesable = coalesce((f->>'pesable')::boolean, false),
        codigo_balanza = nullif(trim(coalesce(f->>'codigo_balanza', '')), ''),
        referencia_interna = nullif(trim(coalesce(f->>'referencia_interna', '')), ''),
        estatus = v_estatus,
        activo = (v_estatus = 'activo'),
        clasificacion = nullif(trim(coalesce(f->>'clasificacion', '')), ''),
        origen = nullif(trim(coalesce(f->>'origen', '')), ''),
        tipo_medida = nullif(trim(coalesce(f->>'tipo_medida', '')), ''),
        medida = nullif(trim(coalesce(f->>'medida', '')), ''),
        presentacion = nullif(trim(coalesce(f->>'presentacion', '')), ''),
        empaques = case when jsonb_typeof(f->'empaques') = 'array' then f->'empaques' else '[]'::jsonb end,
        impuestos_extra = case when jsonb_typeof(f->'impuestos_extra') = 'array' then f->'impuestos_extra' else '[]'::jsonb end,
        proveedores = case when jsonb_typeof(f->'proveedores') = 'array'
                           then array(select jsonb_array_elements_text(f->'proveedores')) else '{}'::text[] end,
        atributos = case when jsonb_typeof(f->'atributos') = 'object' then f->'atributos' else '{}'::jsonb end,
        ref_fabrica = nullif(trim(coalesce(f->>'ref_fabrica', '')), ''),
        cpe = nullif(trim(coalesce(f->>'cpe', '')), ''),
        registro_sanitario = nullif(trim(coalesce(f->>'registro_sanitario', '')), ''),
        variante_grupo = nullif(trim(coalesce(f->>'variante_grupo', '')), ''),
        updated_at = now()
    where codigo = p_codigo;

    -- Un código de barra de empaque no puede chocar con otro producto
    if exists (
        select 1
        from jsonb_array_elements(case when jsonb_typeof(f->'empaques') = 'array' then f->'empaques' else '[]'::jsonb end) e
        join productos p on p.codigo = e->>'barra' and p.codigo <> p_codigo
    ) then
        raise exception 'Un código de barra de empaque ya es el código de otro producto';
    end if;

    -- Servicios: siempre disponibles en todas las tiendas
    if v_tipo = 'servicio' then
        perform servicio_stock_asegurar(p_codigo);
    elsif v_tipo_antes = 'servicio' then
        -- dejó de ser servicio: el stock "infinito" vuelve a 0
        update productos set stock = 0 where codigo = p_codigo;
        update sucursal_stock set stock = 0, updated_at = now() where producto_codigo = p_codigo and stock >= 999999;
    end if;

    return jsonb_build_object('ok', true);
end;
$$;

-- ------------------------------------------------------------
-- 4. Servicios sin inventario
--    registrar_venta exige stock; para no tocar esa función, un
--    servicio mantiene un stock "infinito" (999999) en todas las
--    tiendas. Las pantallas lo muestran como "Servicio".
-- ------------------------------------------------------------
create or replace function servicio_stock_asegurar(p_codigo text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
    v_desc text;
begin
    select descripcion into v_desc from productos where codigo = p_codigo;
    update productos set stock = 999999 where codigo = p_codigo;
    insert into sucursal_stock (sucursal_id, producto_codigo, producto_descripcion, stock)
    select s.id, p_codigo, v_desc, 999999 from sucursales s
    on conflict (sucursal_id, producto_codigo) do update set stock = 999999, updated_at = now();
end;
$$;

create or replace function productos_servicio_stock()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    if new.tipo_producto = 'servicio' and coalesce(new.stock, 0) < 999999 then
        new.stock := 999999;
    end if;
    return new;
end;
$$;
drop trigger if exists trg_productos_servicio_stock on productos;
create trigger trg_productos_servicio_stock before insert or update on productos
    for each row execute function productos_servicio_stock();

create or replace function sucursal_stock_servicio()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    if exists (select 1 from productos where codigo = new.producto_codigo and tipo_producto = 'servicio')
       and coalesce(new.stock, 0) < 999999 then
        new.stock := 999999;
    end if;
    return new;
end;
$$;
drop trigger if exists trg_sucursal_stock_servicio on sucursal_stock;
create trigger trg_sucursal_stock_servicio before insert or update on sucursal_stock
    for each row execute function sucursal_stock_servicio();

-- Una sucursal nueva también tiene los servicios disponibles
create or replace function sucursal_nueva_servicios()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    insert into sucursal_stock (sucursal_id, producto_codigo, producto_descripcion, stock)
    select new.id, p.codigo, p.descripcion, 999999 from productos p where p.tipo_producto = 'servicio'
    on conflict (sucursal_id, producto_codigo) do nothing;
    return new;
end;
$$;
drop trigger if exists trg_sucursal_nueva_servicios on sucursales;
create trigger trg_sucursal_nueva_servicios after insert on sucursales
    for each row execute function sucursal_nueva_servicios();

-- Los servicios no se cuentan en el conteo de inventario
create or replace function conteo_items_sin_servicios()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    if exists (select 1 from productos where codigo = new.producto_codigo and tipo_producto = 'servicio') then
        return null;
    end if;
    return new;
end;
$$;
do $$ begin
    if to_regclass('public.conteo_items') is not null then
        execute 'drop trigger if exists trg_conteo_items_sin_servicios on conteo_items';
        execute 'create trigger trg_conteo_items_sin_servicios before insert on conteo_items for each row execute function conteo_items_sin_servicios()';
    end if;
end $$;

-- ------------------------------------------------------------
-- 5. Histórico de importaciones de Excel
-- ------------------------------------------------------------
create table if not exists importaciones_productos (
    id uuid primary key default gen_random_uuid(),
    archivo text,
    sucursal_id uuid,
    sucursal_nombre text,
    usuario_nombre text,
    modo_stock text,
    filas int not null default 0,
    creados int not null default 0,
    actualizados int not null default 0,
    omitidos int not null default 0,
    errores int not null default 0,
    detalle_errores jsonb not null default '[]'::jsonb,
    created_at timestamptz not null default now()
);
create index if not exists idx_import_prod_fecha on importaciones_productos(created_at desc);
alter table importaciones_productos enable row level security;
drop policy if exists "importaciones_productos_select" on importaciones_productos;
create policy "importaciones_productos_select" on importaciones_productos for select using (true);
revoke insert, update, delete on importaciones_productos from anon, authenticated;
grant select on importaciones_productos to anon, authenticated;

create or replace function importacion_registrar(
    p_archivo text, p_sucursal_id uuid, p_sucursal_nombre text, p_usuario text, p_modo_stock text,
    p_filas int, p_creados int, p_actualizados int, p_omitidos int, p_errores jsonb
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_id uuid;
begin
    insert into importaciones_productos (archivo, sucursal_id, sucursal_nombre, usuario_nombre, modo_stock,
        filas, creados, actualizados, omitidos, errores, detalle_errores)
    values (left(p_archivo, 200), p_sucursal_id, p_sucursal_nombre, p_usuario, p_modo_stock,
        coalesce(p_filas, 0), coalesce(p_creados, 0), coalesce(p_actualizados, 0), coalesce(p_omitidos, 0),
        case when jsonb_typeof(p_errores) = 'array' then jsonb_array_length(p_errores) else 0 end,
        case when jsonb_typeof(p_errores) = 'array' then p_errores else '[]'::jsonb end)
    returning id into v_id;
    return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

-- ------------------------------------------------------------
-- 6. Tasa: quién la cambió
-- ------------------------------------------------------------
alter table tasas_historial add column if not exists usuario_nombre text;

create or replace function tasa_historial_firmar(p_usuario text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
    update tasas_historial set usuario_nombre = left(p_usuario, 80)
    where id = (select id from tasas_historial
                where usuario_nombre is null and created_at > now() - interval '2 minutes'
                order by created_at desc limit 1);
    return jsonb_build_object('ok', true);
end;
$$;

-- ------------------------------------------------------------
-- 7. Importación de Excel: también lee el IVA (16 / 8 / 0 / exento)
-- ------------------------------------------------------------
create or replace function iva_normalizar(p text)
returns numeric
language sql
immutable
as $$
    select case
        when p is null or trim(p) = '' then null
        when lower(trim(p)) in ('exento', 'e', 'ex', 'no', 'iva exento', '0', '0%') then 0
        when regexp_replace(p, '[^0-9.,]', '', 'g') = '' then null
        else least(100, greatest(0, replace(regexp_replace(p, '[^0-9.,]', '', 'g'), ',', '.')::numeric
                     * case when replace(regexp_replace(p, '[^0-9.,]', '', 'g'), ',', '.')::numeric < 1 then 100 else 1 end))
    end;
$$;

create or replace function productos_importar_extra(p_rows jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    r jsonb;
    v_cod text;
    v_iva numeric;
    n int := 0;
begin
    if p_rows is null or jsonb_typeof(p_rows) <> 'array' then return jsonb_build_object('ok', true, 'actualizados', 0); end if;
    for r in select value from jsonb_array_elements(p_rows) loop
        v_cod := nullif(trim(coalesce(r->>'codigo', '')), '');
        if v_cod is null then v_cod := nullif(trim(coalesce(r->>'barra', '')), ''); end if;
        if v_cod is null then continue; end if;
        begin
            v_iva := iva_normalizar(r->>'iva');
        exception when others then v_iva := null;
        end;
        update productos set
            iva_tasa = coalesce(v_iva, iva_tasa),
            sku = coalesce(nullif(trim(coalesce(r->>'sku', '')), ''), sku),
            detalle = coalesce(nullif(trim(coalesce(r->>'detalle', '')), ''), detalle)
        where codigo = v_cod
          and (v_iva is not null or nullif(trim(coalesce(r->>'sku', '')), '') is not null or nullif(trim(coalesce(r->>'detalle', '')), '') is not null);
        if found then n := n + 1; end if;
    end loop;
    return jsonb_build_object('ok', true, 'actualizados', n);
end;
$$;

-- ------------------------------------------------------------
-- 8. Permisos
-- ------------------------------------------------------------
grant execute on function producto_imagenes_guardar(text, jsonb) to anon, authenticated;
grant execute on function producto_ficha_guardar(text, jsonb) to anon, authenticated;
grant execute on function importacion_registrar(text, uuid, text, text, text, int, int, int, int, jsonb) to anon, authenticated;
grant execute on function tasa_historial_firmar(text) to anon, authenticated;
grant execute on function productos_importar_extra(jsonb) to anon, authenticated;
grant execute on function iva_normalizar(text) to anon, authenticated;
revoke execute on function servicio_stock_asegurar(text) from anon, authenticated, public;


-- ################################################################
-- ## norkut-fase3
-- ################################################################

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


-- ################################################################
-- ## actualizacion
-- ################################################################

-- ============================================================
-- REFRIMAR — ACTUALIZACIÓN (ficha de producto + fase 3)
-- Pega TODO en Supabase → SQL Editor → New query → Run.
-- Se puede correr varias veces sin problema.
-- ============================================================

-- ============================================================
-- REFRIMAR — FICHA COMPLETA DE PRODUCTO (estilo Norkut)
-- ------------------------------------------------------------
-- Qué agrega (idempotente: seguro volver a correrlo):
--   • Ficha de producto: SKU, descripción larga, tipo (físico /
--     servicio), IVA por producto, pesable + código de balanza,
--     referencia interna, estatus (borrador/activo/inactivo),
--     clasificación, origen, medidas, presentación, empaques,
--     impuestos adicionales, proveedores, atributos y otras
--     referencias (fábrica, CPE, registro sanitario).
--   • Fotos del producto (tabla aparte para que las listas
--     sigan cargando rápido).
--   • Servicios: no llevan inventario (se pueden vender siempre).
--   • Histórico de importaciones de Excel.
--   • Tasa: guarda qué usuario la cambió.
--   • La importación de Excel ahora también lee el IVA.
--
-- CÓMO APLICAR: Supabase → SQL Editor → New query → pega TODO → Run
-- ============================================================

-- ------------------------------------------------------------
-- 1. Columnas nuevas de productos
-- ------------------------------------------------------------
alter table productos add column if not exists sku text;
alter table productos add column if not exists detalle text;
alter table productos add column if not exists tipo_producto text not null default 'fisico';
alter table productos add column if not exists iva_tasa numeric not null default 16;
alter table productos add column if not exists sensible boolean not null default false;
alter table productos add column if not exists requiere_serial boolean not null default false;
alter table productos add column if not exists pesable boolean not null default false;
alter table productos add column if not exists codigo_balanza text;
alter table productos add column if not exists referencia_interna text;
alter table productos add column if not exists estatus text not null default 'activo';
alter table productos add column if not exists clasificacion text;
alter table productos add column if not exists origen text;
alter table productos add column if not exists tipo_medida text;
alter table productos add column if not exists medida text;
alter table productos add column if not exists presentacion text;
alter table productos add column if not exists empaques jsonb not null default '[]'::jsonb;
alter table productos add column if not exists impuestos_extra jsonb not null default '[]'::jsonb;
alter table productos add column if not exists proveedores text[] not null default '{}';
alter table productos add column if not exists atributos jsonb not null default '{}'::jsonb;
alter table productos add column if not exists ref_fabrica text;
alter table productos add column if not exists cpe text;
alter table productos add column if not exists registro_sanitario text;
alter table productos add column if not exists variante_grupo text;
alter table productos add column if not exists updated_at timestamptz default now();

-- estatus coherente con "activo" para los productos que ya existían
update productos set estatus = 'inactivo' where activo = false and estatus = 'activo';

create index if not exists idx_productos_sku on productos(sku);
create index if not exists idx_productos_variante on productos(variante_grupo);

-- ------------------------------------------------------------
-- 2. Fotos (hasta 4 por producto, comprimidas en el navegador)
-- ------------------------------------------------------------
create table if not exists producto_imagenes (
    producto_codigo text primary key,
    imagenes jsonb not null default '[]'::jsonb,
    updated_at timestamptz not null default now()
);
alter table producto_imagenes enable row level security;
drop policy if exists "producto_imagenes_select" on producto_imagenes;
create policy "producto_imagenes_select" on producto_imagenes for select using (true);
revoke insert, update, delete on producto_imagenes from anon, authenticated;
grant select on producto_imagenes to anon, authenticated;

create or replace function producto_imagenes_guardar(p_codigo text, p_imagenes jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
    if not exists (select 1 from productos where codigo = p_codigo) then
        raise exception 'Producto % no existe', p_codigo;
    end if;
    if p_imagenes is null or jsonb_typeof(p_imagenes) <> 'array' then p_imagenes := '[]'::jsonb; end if;
    if jsonb_array_length(p_imagenes) > 4 then raise exception 'Máximo 4 fotos por producto'; end if;
    if length(p_imagenes::text) > 1500000 then raise exception 'Las fotos pesan demasiado'; end if;
    insert into producto_imagenes (producto_codigo, imagenes, updated_at)
    values (p_codigo, p_imagenes, now())
    on conflict (producto_codigo) do update set imagenes = excluded.imagenes, updated_at = now();
    return jsonb_build_object('ok', true);
end;
$$;

-- ------------------------------------------------------------
-- 3. Guardar la ficha completa (se llama después de producto_guardar)
-- ------------------------------------------------------------
create or replace function producto_ficha_guardar(p_codigo text, p_ficha jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    f jsonb := coalesce(p_ficha, '{}'::jsonb);
    v_tipo text;
    v_estatus text;
    v_iva numeric;
    v_tipo_antes text;
begin
    select tipo_producto into v_tipo_antes from productos where codigo = p_codigo;
    if not found then
        raise exception 'Producto % no existe', p_codigo;
    end if;

    v_tipo := coalesce(nullif(f->>'tipo_producto', ''), 'fisico');
    if v_tipo not in ('fisico', 'servicio') then v_tipo := 'fisico'; end if;
    v_estatus := coalesce(nullif(f->>'estatus', ''), 'activo');
    if v_estatus not in ('borrador', 'activo', 'inactivo') then v_estatus := 'activo'; end if;
    v_iva := coalesce(nullif(f->>'iva_tasa', '')::numeric, 16);
    if v_iva < 0 or v_iva > 100 then raise exception 'IVA inválido'; end if;

    update productos set
        sku = nullif(trim(coalesce(f->>'sku', '')), ''),
        detalle = nullif(trim(coalesce(f->>'detalle', '')), ''),
        subcategoria = nullif(trim(coalesce(f->>'subcategoria', '')), ''),
        tipo_producto = v_tipo,
        iva_tasa = v_iva,
        sensible = coalesce((f->>'sensible')::boolean, false),
        requiere_serial = coalesce((f->>'requiere_serial')::boolean, false),
        pesable = coalesce((f->>'pesable')::boolean, false),
        codigo_balanza = nullif(trim(coalesce(f->>'codigo_balanza', '')), ''),
        referencia_interna = nullif(trim(coalesce(f->>'referencia_interna', '')), ''),
        estatus = v_estatus,
        activo = (v_estatus = 'activo'),
        clasificacion = nullif(trim(coalesce(f->>'clasificacion', '')), ''),
        origen = nullif(trim(coalesce(f->>'origen', '')), ''),
        tipo_medida = nullif(trim(coalesce(f->>'tipo_medida', '')), ''),
        medida = nullif(trim(coalesce(f->>'medida', '')), ''),
        presentacion = nullif(trim(coalesce(f->>'presentacion', '')), ''),
        empaques = case when jsonb_typeof(f->'empaques') = 'array' then f->'empaques' else '[]'::jsonb end,
        impuestos_extra = case when jsonb_typeof(f->'impuestos_extra') = 'array' then f->'impuestos_extra' else '[]'::jsonb end,
        proveedores = case when jsonb_typeof(f->'proveedores') = 'array'
                           then array(select jsonb_array_elements_text(f->'proveedores')) else '{}'::text[] end,
        atributos = case when jsonb_typeof(f->'atributos') = 'object' then f->'atributos' else '{}'::jsonb end,
        ref_fabrica = nullif(trim(coalesce(f->>'ref_fabrica', '')), ''),
        cpe = nullif(trim(coalesce(f->>'cpe', '')), ''),
        registro_sanitario = nullif(trim(coalesce(f->>'registro_sanitario', '')), ''),
        variante_grupo = nullif(trim(coalesce(f->>'variante_grupo', '')), ''),
        updated_at = now()
    where codigo = p_codigo;

    -- Un código de barra de empaque no puede chocar con otro producto
    if exists (
        select 1
        from jsonb_array_elements(case when jsonb_typeof(f->'empaques') = 'array' then f->'empaques' else '[]'::jsonb end) e
        join productos p on p.codigo = e->>'barra' and p.codigo <> p_codigo
    ) then
        raise exception 'Un código de barra de empaque ya es el código de otro producto';
    end if;

    -- Servicios: siempre disponibles en todas las tiendas
    if v_tipo = 'servicio' then
        perform servicio_stock_asegurar(p_codigo);
    elsif v_tipo_antes = 'servicio' then
        -- dejó de ser servicio: el stock "infinito" vuelve a 0
        update productos set stock = 0 where codigo = p_codigo;
        update sucursal_stock set stock = 0, updated_at = now() where producto_codigo = p_codigo and stock >= 999999;
    end if;

    return jsonb_build_object('ok', true);
end;
$$;

-- ------------------------------------------------------------
-- 4. Servicios sin inventario
--    registrar_venta exige stock; para no tocar esa función, un
--    servicio mantiene un stock "infinito" (999999) en todas las
--    tiendas. Las pantallas lo muestran como "Servicio".
-- ------------------------------------------------------------
create or replace function servicio_stock_asegurar(p_codigo text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
    v_desc text;
begin
    select descripcion into v_desc from productos where codigo = p_codigo;
    update productos set stock = 999999 where codigo = p_codigo;
    insert into sucursal_stock (sucursal_id, producto_codigo, producto_descripcion, stock)
    select s.id, p_codigo, v_desc, 999999 from sucursales s
    on conflict (sucursal_id, producto_codigo) do update set stock = 999999, updated_at = now();
end;
$$;

create or replace function productos_servicio_stock()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    if new.tipo_producto = 'servicio' and coalesce(new.stock, 0) < 999999 then
        new.stock := 999999;
    end if;
    return new;
end;
$$;
drop trigger if exists trg_productos_servicio_stock on productos;
create trigger trg_productos_servicio_stock before insert or update on productos
    for each row execute function productos_servicio_stock();

create or replace function sucursal_stock_servicio()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    if exists (select 1 from productos where codigo = new.producto_codigo and tipo_producto = 'servicio')
       and coalesce(new.stock, 0) < 999999 then
        new.stock := 999999;
    end if;
    return new;
end;
$$;
drop trigger if exists trg_sucursal_stock_servicio on sucursal_stock;
create trigger trg_sucursal_stock_servicio before insert or update on sucursal_stock
    for each row execute function sucursal_stock_servicio();

-- Una sucursal nueva también tiene los servicios disponibles
create or replace function sucursal_nueva_servicios()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    insert into sucursal_stock (sucursal_id, producto_codigo, producto_descripcion, stock)
    select new.id, p.codigo, p.descripcion, 999999 from productos p where p.tipo_producto = 'servicio'
    on conflict (sucursal_id, producto_codigo) do nothing;
    return new;
end;
$$;
drop trigger if exists trg_sucursal_nueva_servicios on sucursales;
create trigger trg_sucursal_nueva_servicios after insert on sucursales
    for each row execute function sucursal_nueva_servicios();

-- Los servicios no se cuentan en el conteo de inventario
create or replace function conteo_items_sin_servicios()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    if exists (select 1 from productos where codigo = new.producto_codigo and tipo_producto = 'servicio') then
        return null;
    end if;
    return new;
end;
$$;
do $$ begin
    if to_regclass('public.conteo_items') is not null then
        execute 'drop trigger if exists trg_conteo_items_sin_servicios on conteo_items';
        execute 'create trigger trg_conteo_items_sin_servicios before insert on conteo_items for each row execute function conteo_items_sin_servicios()';
    end if;
end $$;

-- ------------------------------------------------------------
-- 5. Histórico de importaciones de Excel
-- ------------------------------------------------------------
create table if not exists importaciones_productos (
    id uuid primary key default gen_random_uuid(),
    archivo text,
    sucursal_id uuid,
    sucursal_nombre text,
    usuario_nombre text,
    modo_stock text,
    filas int not null default 0,
    creados int not null default 0,
    actualizados int not null default 0,
    omitidos int not null default 0,
    errores int not null default 0,
    detalle_errores jsonb not null default '[]'::jsonb,
    created_at timestamptz not null default now()
);
create index if not exists idx_import_prod_fecha on importaciones_productos(created_at desc);
alter table importaciones_productos enable row level security;
drop policy if exists "importaciones_productos_select" on importaciones_productos;
create policy "importaciones_productos_select" on importaciones_productos for select using (true);
revoke insert, update, delete on importaciones_productos from anon, authenticated;
grant select on importaciones_productos to anon, authenticated;

create or replace function importacion_registrar(
    p_archivo text, p_sucursal_id uuid, p_sucursal_nombre text, p_usuario text, p_modo_stock text,
    p_filas int, p_creados int, p_actualizados int, p_omitidos int, p_errores jsonb
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_id uuid;
begin
    insert into importaciones_productos (archivo, sucursal_id, sucursal_nombre, usuario_nombre, modo_stock,
        filas, creados, actualizados, omitidos, errores, detalle_errores)
    values (left(p_archivo, 200), p_sucursal_id, p_sucursal_nombre, p_usuario, p_modo_stock,
        coalesce(p_filas, 0), coalesce(p_creados, 0), coalesce(p_actualizados, 0), coalesce(p_omitidos, 0),
        case when jsonb_typeof(p_errores) = 'array' then jsonb_array_length(p_errores) else 0 end,
        case when jsonb_typeof(p_errores) = 'array' then p_errores else '[]'::jsonb end)
    returning id into v_id;
    return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

-- ------------------------------------------------------------
-- 6. Tasa: quién la cambió
-- ------------------------------------------------------------
alter table tasas_historial add column if not exists usuario_nombre text;

create or replace function tasa_historial_firmar(p_usuario text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
    update tasas_historial set usuario_nombre = left(p_usuario, 80)
    where id = (select id from tasas_historial
                where usuario_nombre is null and created_at > now() - interval '2 minutes'
                order by created_at desc limit 1);
    return jsonb_build_object('ok', true);
end;
$$;

-- ------------------------------------------------------------
-- 7. Importación de Excel: también lee el IVA (16 / 8 / 0 / exento)
-- ------------------------------------------------------------
create or replace function iva_normalizar(p text)
returns numeric
language sql
immutable
as $$
    select case
        when p is null or trim(p) = '' then null
        when lower(trim(p)) in ('exento', 'e', 'ex', 'no', 'iva exento', '0', '0%') then 0
        when regexp_replace(p, '[^0-9.,]', '', 'g') = '' then null
        else least(100, greatest(0, replace(regexp_replace(p, '[^0-9.,]', '', 'g'), ',', '.')::numeric
                     * case when replace(regexp_replace(p, '[^0-9.,]', '', 'g'), ',', '.')::numeric < 1 then 100 else 1 end))
    end;
$$;

create or replace function productos_importar_extra(p_rows jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    r jsonb;
    v_cod text;
    v_iva numeric;
    n int := 0;
begin
    if p_rows is null or jsonb_typeof(p_rows) <> 'array' then return jsonb_build_object('ok', true, 'actualizados', 0); end if;
    for r in select value from jsonb_array_elements(p_rows) loop
        v_cod := nullif(trim(coalesce(r->>'codigo', '')), '');
        if v_cod is null then v_cod := nullif(trim(coalesce(r->>'barra', '')), ''); end if;
        if v_cod is null then continue; end if;
        begin
            v_iva := iva_normalizar(r->>'iva');
        exception when others then v_iva := null;
        end;
        update productos set
            iva_tasa = coalesce(v_iva, iva_tasa),
            sku = coalesce(nullif(trim(coalesce(r->>'sku', '')), ''), sku),
            detalle = coalesce(nullif(trim(coalesce(r->>'detalle', '')), ''), detalle)
        where codigo = v_cod
          and (v_iva is not null or nullif(trim(coalesce(r->>'sku', '')), '') is not null or nullif(trim(coalesce(r->>'detalle', '')), '') is not null);
        if found then n := n + 1; end if;
    end loop;
    return jsonb_build_object('ok', true, 'actualizados', n);
end;
$$;

-- ------------------------------------------------------------
-- 8. Permisos
-- ------------------------------------------------------------
grant execute on function producto_imagenes_guardar(text, jsonb) to anon, authenticated;
grant execute on function producto_ficha_guardar(text, jsonb) to anon, authenticated;
grant execute on function importacion_registrar(text, uuid, text, text, text, int, int, int, int, jsonb) to anon, authenticated;
grant execute on function tasa_historial_firmar(text) to anon, authenticated;
grant execute on function productos_importar_extra(jsonb) to anon, authenticated;
grant execute on function iva_normalizar(text) to anon, authenticated;
revoke execute on function servicio_stock_asegurar(text) from anon, authenticated, public;

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


-- ################################################################
-- ## equipo
-- ################################################################

-- ============================================================
-- REFRIMAR · Gestión de equipo (estilo Norkut)
-- Roles, permisos por módulo, acceso a tiendas, invitaciones y
-- acceso con Google que ya sabe quién eres y a qué tienda vas.
-- Se puede correr varias veces (idempotente).
-- Requiere haber corrido antes supabase-migration-actualizacion.sql
-- ============================================================

alter table usuarios add column if not exists nombres text;
alter table usuarios add column if not exists apellido text;
alter table usuarios add column if not exists telefono text;
alter table usuarios add column if not exists estado text not null default 'activo';
alter table usuarios add column if not exists sucursales uuid[] not null default '{}';
alter table usuarios add column if not exists avatar_url text;
alter table usuarios add column if not exists invitado_at timestamptz;
alter table usuarios add column if not exists aceptado_at timestamptz;
alter table usuarios add column if not exists created_at timestamptz default now();

update usuarios set estado = 'inactivo' where estado = 'activo' and coalesce(activo, true) = false;
update usuarios set nombres = split_part(trim(nombre), ' ', 1),
    apellido = nullif(trim(substr(trim(nombre), length(split_part(trim(nombre), ' ', 1)) + 1)), '')
where nombres is null and nombre is not null;
update usuarios set sucursales = array[sucursal_id]
where sucursal_id is not null and (sucursales is null or sucursales = '{}');

-- Invitaciones: tabla cerrada (solo la leen las funciones)
create table if not exists invitaciones (
    token text primary key default replace(gen_random_uuid()::text, '-', ''),
    usuario_id uuid not null references usuarios(id) on delete cascade,
    email text not null,
    creada_por text,
    created_at timestamptz not null default now(),
    expira_at timestamptz not null default now() + interval '15 days',
    usada_at timestamptz,
    cancelada boolean not null default false
);
create index if not exists idx_invitaciones_usuario on invitaciones(usuario_id);
alter table invitaciones enable row level security;
revoke all on invitaciones from anon, authenticated;

-- ---------- Helpers ----------
create or replace function invitacion_vigente(p_usuario uuid, p_creada_por text default null)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare v_token text; v_email text;
begin
    select email into v_email from usuarios where id = p_usuario;
    if v_email is null then raise exception 'El colaborador no tiene correo'; end if;
    select token into v_token from invitaciones
    where usuario_id = p_usuario and not cancelada and usada_at is null and expira_at > now()
      and lower(email) = lower(v_email)
    order by created_at desc limit 1;
    if v_token is null then
        update invitaciones set cancelada = true where usuario_id = p_usuario and usada_at is null;
        insert into invitaciones (usuario_id, email, creada_por) values (p_usuario, lower(v_email), p_creada_por)
        returning token into v_token;
    end if;
    return v_token;
end;
$$;
revoke execute on function invitacion_vigente(uuid, text) from anon, authenticated, public;

-- ---------- Crear / editar colaborador ----------
create or replace function colaborador_guardar(p_id uuid, p_datos jsonb, p_usuario text default 'Sistema')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    d jsonb := coalesce(p_datos, '{}'::jsonb);
    v_id uuid := p_id;
    v_nombres text := nullif(trim(coalesce(d->>'nombres', '')), '');
    v_apellido text := nullif(trim(coalesce(d->>'apellido', '')), '');
    v_email text := nullif(lower(trim(coalesce(d->>'email', ''))), '');
    v_rol text := coalesce(nullif(trim(coalesce(d->>'rol', '')), ''), 'cajero');
    v_permisos jsonb := case when jsonb_typeof(d->'permisos') = 'array' then d->'permisos' else '[]'::jsonb end;
    v_suc uuid[];
    v_nombre text;
    v_estado text;
    v_token text;
begin
    if v_nombres is null then raise exception 'Escribe el nombre'; end if;
    if v_email is null then raise exception 'Escribe el correo'; end if;
    if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Correo inválido'; end if;
    v_suc := case when jsonb_typeof(d->'sucursales') = 'array'
                  then array(select distinct (x)::uuid from jsonb_array_elements_text(d->'sucursales') x)
                  else '{}'::uuid[] end;
    if v_rol <> 'admin' and coalesce(array_length(v_suc, 1), 0) = 0 then
        raise exception 'Selecciona al menos una tienda';
    end if;
    v_nombre := trim(v_nombres || ' ' || coalesce(v_apellido, ''));
    if exists (select 1 from usuarios where lower(nombre) = lower(v_nombre) and id is distinct from v_id) then
        raise exception 'Ya existe un colaborador llamado %', v_nombre;
    end if;
    if exists (select 1 from usuarios where lower(email) = v_email and id is distinct from v_id) then
        raise exception 'Ese correo ya está asignado a otro colaborador';
    end if;

    if v_id is null then
        insert into usuarios (nombre, nombres, apellido, email, telefono, rol, permisos, sucursales, sucursal_id,
                              activo, estado, invitado_at)
        values (v_nombre, v_nombres, v_apellido, v_email, nullif(trim(coalesce(d->>'telefono', '')), ''), v_rol, v_permisos, v_suc,
                case when array_length(v_suc, 1) = 1 then v_suc[1] else null end,
                false, 'pendiente', now())
        returning id into v_id;
        v_estado := 'pendiente';
    else
        select estado into v_estado from usuarios where id = v_id;
        if not found then raise exception 'Colaborador no encontrado'; end if;
        update usuarios set
            nombre = v_nombre, nombres = v_nombres, apellido = v_apellido, email = v_email,
            telefono = coalesce(nullif(trim(coalesce(d->>'telefono', '')), ''), telefono),
            rol = v_rol, permisos = v_permisos, sucursales = v_suc,
            sucursal_id = case when array_length(v_suc, 1) = 1 then v_suc[1] else null end
        where id = v_id;
    end if;

    if v_estado = 'pendiente' then
        v_token := invitacion_vigente(v_id, p_usuario);
    end if;
    return jsonb_build_object('ok', true, 'id', v_id, 'estado', v_estado, 'token', v_token);
end;
$$;

-- ---------- Cambiar estado: activo / inactivo / cancelado / pendiente (reinvitar) ----------
create or replace function colaborador_estado(p_id uuid, p_estado text, p_usuario text default 'Sistema')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare u record; v_token text;
begin
    select * into u from usuarios where id = p_id for update;
    if not found then raise exception 'Colaborador no encontrado'; end if;
    if p_estado = 'activo' then
        if u.pin is null then raise exception 'Este colaborador todavía no aceptó la invitación'; end if;
        update usuarios set estado = 'activo', activo = true where id = p_id;
    elsif p_estado = 'inactivo' then
        if u.rol = 'admin' and (select count(*) from usuarios where rol = 'admin' and activo and id <> p_id) = 0 then
            raise exception 'No puedes inactivar al único administrador';
        end if;
        update usuarios set estado = 'inactivo', activo = false where id = p_id;
    elsif p_estado = 'cancelado' then
        if u.estado <> 'pendiente' then raise exception 'Solo se cancelan invitaciones pendientes'; end if;
        update usuarios set estado = 'cancelado', activo = false where id = p_id;
        update invitaciones set cancelada = true where usuario_id = p_id and usada_at is null;
    elsif p_estado = 'pendiente' then
        if u.estado not in ('cancelado', 'pendiente') then raise exception 'Este colaborador ya aceptó la invitación'; end if;
        update usuarios set estado = 'pendiente', activo = false, invitado_at = now() where id = p_id;
        v_token := invitacion_vigente(p_id, p_usuario);
    else
        raise exception 'Estado inválido';
    end if;
    return jsonb_build_object('ok', true, 'estado', p_estado, 'token', v_token);
end;
$$;

-- Enlace de invitación para volver a compartirlo
create or replace function invitacion_enlace(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_estado text;
begin
    select estado into v_estado from usuarios where id = p_id;
    if not found then raise exception 'Colaborador no encontrado'; end if;
    if v_estado <> 'pendiente' then raise exception 'Este colaborador no tiene una invitación pendiente'; end if;
    return jsonb_build_object('ok', true, 'token', invitacion_vigente(p_id, null));
end;
$$;

-- Restablecer PIN (lo hace el administrador)
create or replace function colaborador_pin_restablecer(p_id uuid, p_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
    if p_pin is null or length(p_pin) < 32 then raise exception 'PIN inválido'; end if;
    update usuarios set pin = p_pin where id = p_id;
    if not found then raise exception 'Colaborador no encontrado'; end if;
    return jsonb_build_object('ok', true);
end;
$$;

-- Cambiar mi PIN (Perfil): pide el PIN actual
create or replace function usuario_cambiar_pin(p_id uuid, p_actual text, p_nuevo text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_pin text;
begin
    if p_nuevo is null or length(p_nuevo) < 32 then raise exception 'PIN nuevo inválido'; end if;
    select pin into v_pin from usuarios where id = p_id;
    if not found then raise exception 'Usuario no encontrado'; end if;
    if v_pin is not null and v_pin <> coalesce(p_actual, '') then raise exception 'El PIN actual no es correcto'; end if;
    update usuarios set pin = p_nuevo where id = p_id;
    return jsonb_build_object('ok', true);
end;
$$;

-- Perfil: nombre, apellido y teléfono propios
create or replace function usuario_perfil_guardar(p_id uuid, p_nombres text, p_apellido text, p_telefono text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_nombre text;
begin
    if nullif(trim(coalesce(p_nombres, '')), '') is null then raise exception 'Escribe tu nombre'; end if;
    v_nombre := trim(trim(p_nombres) || ' ' || coalesce(trim(p_apellido), ''));
    if exists (select 1 from usuarios where lower(nombre) = lower(v_nombre) and id <> p_id) then
        raise exception 'Ya existe un colaborador llamado %', v_nombre;
    end if;
    update usuarios set nombres = trim(p_nombres), apellido = nullif(trim(coalesce(p_apellido, '')), ''),
        nombre = v_nombre, telefono = nullif(trim(coalesce(p_telefono, '')), '')
    where id = p_id;
    if not found then raise exception 'Usuario no encontrado'; end if;
    return jsonb_build_object('ok', true, 'nombre', v_nombre);
end;
$$;

-- ---------- Datos públicos de una invitación (página invitacion.html) ----------
create or replace function invitacion_info(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare i record; u record; v_empresa text; v_tiendas text[];
begin
    select * into i from invitaciones where token = p_token;
    if not found then return jsonb_build_object('ok', false, 'error', 'Esta invitación no existe.'); end if;
    select * into u from usuarios where id = i.usuario_id;
    if i.usada_at is not null or u.estado = 'activo' then return jsonb_build_object('ok', false, 'usada', true, 'error', 'Esta invitación ya fue aceptada. Entra con tu cuenta de Google.'); end if;
    if i.cancelada or u.estado = 'cancelado' then return jsonb_build_object('ok', false, 'error', 'Esta invitación fue cancelada. Pídele una nueva al administrador.'); end if;
    if i.expira_at < now() then return jsonb_build_object('ok', false, 'error', 'Esta invitación venció. Pídele una nueva al administrador.'); end if;
    select coalesce(nullif(trim(nombre_negocio), ''), 'Comercial Refrimar') into v_empresa from configuracion limit 1;
    select array_agg(n order by n) into v_tiendas from (
        select case when x = '00000000-0000-0000-0000-000000000001'::uuid then 'Casa Matriz' else s.nombre end n
        from unnest(u.sucursales) x left join sucursales s on s.id = x) t;
    return jsonb_build_object('ok', true, 'nombre', u.nombres, 'nombre_completo', u.nombre, 'email', i.email,
        'rol', u.rol, 'empresa', coalesce(v_empresa, 'Comercial Refrimar'), 'tiendas', coalesce(to_jsonb(v_tiendas), '[]'::jsonb));
end;
$$;

-- ---------- Datos del colaborador para la sesión ----------
create or replace function usuario_sesion_json(p_id uuid)
returns jsonb
language sql
security definer
set search_path = public
as $$
    select jsonb_build_object('success', true, 'id', u.id, 'nombre', u.nombre, 'rol', u.rol,
        'permisos', coalesce(u.permisos, '[]'::jsonb), 'sucursal_id', u.sucursal_id,
        'sucursales', coalesce(to_jsonb(u.sucursales), '[]'::jsonb), 'email', u.email,
        'avatar_url', u.avatar_url, 'estado', u.estado)
    from usuarios u where u.id = p_id;
$$;
revoke execute on function usuario_sesion_json(uuid) from anon, authenticated, public;

-- ---------- Aceptar invitación (con la cuenta de Google ya iniciada) ----------
-- p_token es opcional: si no viene, se busca la invitación pendiente de ese correo.
create or replace function invitacion_aceptar(p_token text, p_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_email text; v_avatar text; u record; i record;
begin
    begin
        v_email := lower(coalesce(auth.jwt() ->> 'email', ''));
        v_avatar := coalesce(auth.jwt() -> 'user_metadata' ->> 'avatar_url', auth.jwt() -> 'user_metadata' ->> 'picture');
    exception when others then v_email := '';
    end;
    if v_email = '' then return jsonb_build_object('success', false, 'error', 'Primero entra con tu cuenta de Google'); end if;
    if p_pin is null or length(p_pin) < 32 then return jsonb_build_object('success', false, 'error', 'Crea un PIN de 4 dígitos'); end if;

    if nullif(p_token, '') is not null then
        select * into i from invitaciones where token = p_token;
        if not found or i.cancelada or i.usada_at is not null or i.expira_at < now() then
            return jsonb_build_object('success', false, 'error', 'La invitación ya no es válida. Pídele una nueva al administrador.');
        end if;
        if lower(i.email) <> v_email then
            return jsonb_build_object('success', false, 'error', 'Esta invitación es para ' || i.email || ' y entraste con ' || v_email || '. Entra con la cuenta correcta.');
        end if;
        select * into u from usuarios where id = i.usuario_id for update;
    else
        select * into u from usuarios where lower(email) = v_email and estado = 'pendiente' for update;
        if not found then return jsonb_build_object('success', false, 'error', 'No hay una invitación pendiente para ' || v_email); end if;
    end if;
    if u.estado not in ('pendiente') then
        return jsonb_build_object('success', false, 'error', 'Esta invitación ya no está pendiente.');
    end if;

    update usuarios set pin = p_pin, activo = true, estado = 'activo', aceptado_at = now(),
        avatar_url = coalesce(v_avatar, avatar_url)
    where id = u.id;
    update invitaciones set usada_at = now() where usuario_id = u.id and usada_at is null and not cancelada;
    return usuario_sesion_json(u.id);
end;
$$;

-- ---------- Entrar con Google: el correo dice quién eres, tu rol y tus tiendas ----------
create or replace function login_google()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_email text;
    v_avatar text;
    u record;
begin
    begin
        v_email := lower(coalesce(auth.jwt() ->> 'email', ''));
        v_avatar := coalesce(auth.jwt() -> 'user_metadata' ->> 'avatar_url', auth.jwt() -> 'user_metadata' ->> 'picture');
    exception when others then v_email := '';
    end;
    if v_email = '' then return jsonb_build_object('success', false, 'error', 'No hay una sesión de Google activa'); end if;
    select * into u from usuarios where lower(email) = v_email limit 1;
    if not found then
        return jsonb_build_object('success', false, 'error', 'El correo ' || v_email || ' no está registrado. Pídele al administrador que te invite en Configuración → Gestión de equipo.');
    end if;
    if u.estado = 'pendiente' then
        return jsonb_build_object('success', false, 'pendiente', true, 'nombre', u.nombres, 'email', v_email,
            'error', 'Tienes una invitación pendiente: crea tu PIN para activarla.');
    end if;
    if u.estado = 'cancelado' then
        return jsonb_build_object('success', false, 'error', 'Tu invitación fue cancelada. Habla con el administrador.');
    end if;
    if not coalesce(u.activo, false) then
        return jsonb_build_object('success', false, 'error', 'Tu usuario está inactivo. Habla con el administrador.');
    end if;
    if v_avatar is not null then update usuarios set avatar_url = v_avatar where id = u.id; end if;
    return usuario_sesion_json(u.id);
end;
$$;

grant execute on function colaborador_guardar(uuid, jsonb, text) to anon, authenticated;
grant execute on function colaborador_estado(uuid, text, text) to anon, authenticated;
grant execute on function invitacion_enlace(uuid) to anon, authenticated;
grant execute on function colaborador_pin_restablecer(uuid, text) to anon, authenticated;
grant execute on function usuario_cambiar_pin(uuid, text, text) to anon, authenticated;
grant execute on function usuario_perfil_guardar(uuid, text, text, text) to anon, authenticated;
grant execute on function invitacion_info(text) to anon, authenticated;
revoke execute on function invitacion_aceptar(text, text) from anon, public;
grant execute on function invitacion_aceptar(text, text) to authenticated;
revoke execute on function login_google() from anon, public;
grant execute on function login_google() to authenticated;


-- ################################################################
-- ## pos-precios
-- ################################################################

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


-- ################################################################
-- ## diagnóstico
-- ################################################################

-- ============================================================
-- Diagnóstico: la página "Estado del sistema" lo usa para saber
-- qué funciones y tablas existen y si todo está actualizado.
-- ============================================================
create or replace function sistema_diagnostico()
returns jsonb
language sql
security definer
set search_path = public
as $$
    select jsonb_build_object(
        'version', '2026-10-14',
        'funciones', (select coalesce(jsonb_agg(distinct p.proname), '[]'::jsonb) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public'),
        'sin_permiso', (select coalesce(jsonb_agg(distinct p.proname), '[]'::jsonb) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                        where n.nspname = 'public' and p.prosecdef and not has_function_privilege('anon', p.oid, 'execute')),
        'tablas', (select coalesce(jsonb_agg(table_name::text), '[]'::jsonb) from information_schema.tables where table_schema = 'public'),
        'productos', (select count(*) from productos),
        'clientes', (select count(*) from clientes),
        'usuarios', (select count(*) from usuarios where coalesce(activo, true)),
        'sucursales', (select count(*) from sucursales),
        'tasa', (select tasa_bcv_manual from configuracion limit 1),
        'ventas_hoy', (select count(*) from ventas where created_at >= (date_trunc('day', now() at time zone 'America/Caracas') at time zone 'America/Caracas')),
        'ahora', now()
    );
$$;
grant execute on function sistema_diagnostico() to anon, authenticated;


notify pgrst, 'reload schema';
select 'REFRIMAR actualizado correctamente' as resultado;
