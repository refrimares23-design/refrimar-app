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
