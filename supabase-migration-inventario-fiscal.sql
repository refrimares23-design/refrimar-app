-- ============================================================
-- REFRIMAR — INVENTARIO, AUDITORÍA Y LIBROS FISCALES
-- ------------------------------------------------------------
-- Pega TODO en Supabase → SQL Editor → New query → Run.
-- Se puede correr varias veces. Requiere supabase-ACTUALIZAR-TODO.sql.
-- (Si corriste supabase-migration-seguridad.sql, la bitácora anota
--  el nombre real de quien hizo cada cambio.)
--
-- Qué agrega:
--   • IGTF por venta (ventas.igtf_usd / igtf_bs), calculado de los pagos.
--   • Bitácora de auditoría: quién creó, cambió o borró qué y cuándo.
--   • Ajustes de inventario con motivo obligatorio y aprobación por monto.
--   • Análisis de inventario: valorización (USD y Bs), reorden,
--     ABC, sin movimiento, por vencer.
--   • Libro de ventas y libro de compras (formato SENIAT) y resumen IVA/IGTF.
--   • Transferencias en dos pasos: enviada (en tránsito) → recibida con diferencias.
-- ============================================================

-- ---------- 1. IGTF ----------
alter table ventas add column if not exists igtf_usd numeric(14,2) not null default 0;
alter table ventas add column if not exists igtf_bs numeric(14,2) not null default 0;

create or replace function ventas_igtf_calcular()
returns trigger
language plpgsql
as $$
declare v numeric;
begin
    if jsonb_typeof(new.pagos) = 'array' then
        select coalesce(sum(nullif(x->>'igtf_usd', '')::numeric), 0) into v from jsonb_array_elements(new.pagos) x;
        new.igtf_usd := round(coalesce(v, 0), 2);
        new.igtf_bs := round(coalesce(v, 0) * coalesce(nullif(new.tasa_bcv, 0), case when coalesce(new.total_usd, 0) > 0 then new.total_bs / new.total_usd else 0 end), 2);
    end if;
    return new;
end;
$$;
drop trigger if exists trg_ventas_igtf on ventas;
create trigger trg_ventas_igtf before insert on ventas for each row execute function ventas_igtf_calcular();

-- ---------- 2. Bitácora de auditoría ----------
create table if not exists auditoria (
    id bigserial primary key,
    fecha timestamptz not null default now(),
    tabla text not null,
    accion text not null,            -- crear | editar | borrar
    registro text,                   -- código / número / id
    usuario_id uuid,
    usuario_nombre text,
    cambios jsonb                    -- { campo: [antes, después] }
);
create index if not exists idx_auditoria_fecha on auditoria(fecha desc);
create index if not exists idx_auditoria_tabla on auditoria(tabla, fecha desc);
create index if not exists idx_auditoria_registro on auditoria(registro);
alter table auditoria enable row level security;
revoke all on auditoria from anon, authenticated;

-- Quién está haciendo el cambio (token de sesión si existe la migración de seguridad)
create or replace function refrimar_quien()
returns jsonb
language plpgsql stable security definer
set search_path = public
as $$
declare v_uid uuid; v_nom text;
begin
    begin
        execute 'select refrimar_sesion_uid(30)' into v_uid;
    exception when others then v_uid := null;
    end;
    if v_uid is not null then select nombre into v_nom from usuarios where id = v_uid; end if;
    if v_nom is null then
        begin
            v_nom := nullif(coalesce(current_setting('request.jwt.claims', true), '{}')::json ->> 'email', '');
        exception when others then v_nom := null;
        end;
    end if;
    return jsonb_build_object('id', v_uid, 'nombre', coalesce(v_nom, 'Sistema'));
end;
$$;

create or replace function auditoria_registrar()
returns trigger
language plpgsql security definer
set search_path = public
as $$
declare
    v_old jsonb := case when tg_op <> 'INSERT' then to_jsonb(old) else '{}'::jsonb end;
    v_new jsonb := case when tg_op <> 'DELETE' then to_jsonb(new) else '{}'::jsonb end;
    v_ign text[] := array['updated_at', 'created_at', 'pin', 'stock', 'ultimo_aviso', 'ultima_conexion', 'saldo_pendiente', 'monto_abonado'];
    v_cambios jsonb := '{}'::jsonb; k text; v_quien jsonb; v_reg text;
begin
    if tg_op = 'UPDATE' then
        for k in select key from jsonb_each(v_new) loop
            if k = any (v_ign) then continue; end if;
            if (v_old -> k) is distinct from (v_new -> k) then
                v_cambios := v_cambios || jsonb_build_object(k, jsonb_build_array(v_old -> k, v_new -> k));
            end if;
        end loop;
        if v_cambios = '{}'::jsonb then return new; end if;     -- solo cambió el stock u otro campo automático
    elsif tg_op = 'INSERT' then
        v_cambios := v_new - v_ign;
    else
        v_cambios := v_old - v_ign;
    end if;
    v_reg := coalesce(v_new ->> 'codigo', v_old ->> 'codigo', v_new ->> 'numero', v_old ->> 'numero', v_new ->> 'rif', v_old ->> 'rif',
                      v_new ->> 'nombre', v_old ->> 'nombre', v_new ->> 'id', v_old ->> 'id');
    v_quien := refrimar_quien();
    insert into auditoria (tabla, accion, registro, usuario_id, usuario_nombre, cambios)
    values (tg_table_name, case tg_op when 'INSERT' then 'crear' when 'UPDATE' then 'editar' else 'borrar' end,
            left(v_reg, 120), nullif(v_quien ->> 'id', '')::uuid, v_quien ->> 'nombre', v_cambios);
    return coalesce(new, old);
exception when others then
    return coalesce(new, old);    -- la bitácora nunca bloquea una operación
end;
$$;

do $$
declare t text;
begin
    foreach t in array array['productos', 'usuarios', 'configuracion', 'clientes', 'proveedores', 'sucursales', 'cuentas_bancarias', 'gastos', 'compras_proveedores'] loop
        if to_regclass('public.' || t) is not null then
            execute format('drop trigger if exists trg_auditoria on %I', t);
            execute format('create trigger trg_auditoria after insert or update or delete on %I for each row execute function auditoria_registrar()', t);
        end if;
    end loop;
    -- Ventas: solo cambios (anulaciones, fiscalización), no cada venta nueva
    execute 'drop trigger if exists trg_auditoria on ventas';
    execute 'create trigger trg_auditoria after update or delete on ventas for each row execute function auditoria_registrar()';
end $$;

create or replace function auditoria_listar(p_desde date default null, p_hasta date default null, p_tabla text default null, p_texto text default null, p_limite int default 300)
returns jsonb
language plpgsql stable security definer
set search_path = public
as $$
declare v_uid uuid; v_ok boolean := true;
begin
    begin
        execute 'select refrimar_sesion_uid(0)' into v_uid;
        execute 'select refrimar_tiene_permiso($1, ''configuracion'') or refrimar_tiene_permiso($1, ''ver_equipo'')' into v_ok using v_uid;
        if v_uid is null then v_ok := (select coalesce(modo, 'aviso') = 'aviso' from seguridad_config where id = 1); end if;
    exception when others then v_ok := true;
    end;
    if not coalesce(v_ok, false) then raise exception 'Solo el dueño o administración pueden ver la bitácora'; end if;
    return coalesce((select jsonb_agg(a order by a.fecha desc) from (
        select id, fecha, tabla, accion, registro, usuario_nombre, cambios from auditoria
        where (p_desde is null or fecha >= p_desde) and (p_hasta is null or fecha < p_hasta + 1)
          and (p_tabla is null or p_tabla = '' or tabla = p_tabla)
          and (p_texto is null or p_texto = '' or registro ilike '%' || p_texto || '%' or usuario_nombre ilike '%' || p_texto || '%' or cambios::text ilike '%' || p_texto || '%')
        order by fecha desc limit least(greatest(coalesce(p_limite, 300), 1), 2000)) a), '[]'::jsonb);
end;
$$;
grant execute on function auditoria_listar(date, date, text, text, int) to anon, authenticated;

-- ---------- 3. Ajustes con motivo y aprobación ----------
create table if not exists ajustes_solicitudes (
    id uuid primary key default gen_random_uuid(),
    producto_codigo text not null,
    producto_descripcion text,
    tipo text not null check (tipo in ('entrada', 'salida')),
    cantidad numeric not null,
    costo_unitario numeric not null default 0,
    valor_usd numeric not null default 0,
    motivo text not null,
    detalle text,
    sucursal_id uuid,
    sucursal_nombre text,
    solicitado_por text,
    estado text not null default 'pendiente' check (estado in ('pendiente', 'aprobado', 'rechazado')),
    resuelto_por text,
    resuelto_at timestamptz,
    created_at timestamptz not null default now()
);
create index if not exists idx_ajustes_sol_estado on ajustes_solicitudes(estado, created_at desc);
alter table ajustes_solicitudes enable row level security;
drop policy if exists "ajustes_sol_select" on ajustes_solicitudes;
create policy "ajustes_sol_select" on ajustes_solicitudes for select using (true);
revoke insert, update, delete on ajustes_solicitudes from anon, authenticated;
grant select on ajustes_solicitudes to anon, authenticated;

create or replace function refrimar_puede_aprobar(p_usuario text)
returns boolean
language plpgsql stable security definer
set search_path = public
as $$
declare v_uid uuid; v_rol text;
begin
    begin execute 'select refrimar_sesion_uid(0)' into v_uid; exception when others then v_uid := null; end;
    if v_uid is not null then select rol into v_rol from usuarios where id = v_uid;
    else select rol into v_rol from usuarios where nombre = p_usuario and activo is not false limit 1; end if;
    return coalesce(v_rol, '') in ('admin', 'administrador', 'supervisor_tienda');
end;
$$;

create or replace function ajuste_inventario(p_codigo text, p_tipo text, p_cantidad numeric, p_costo numeric, p_motivo text, p_detalle text,
    p_sucursal_id uuid default null, p_sucursal_nombre text default null, p_usuario text default 'Sistema')
returns jsonb
language plpgsql security definer
set search_path = public
as $$
declare
    v_motivos text[] := array['Merma', 'Daño', 'Robo o pérdida', 'Vencido', 'Error de conteo', 'Uso interno', 'Devolución a proveedor', 'Entrada sin factura', 'Otro'];
    v_desc text; v_costo numeric; v_valor numeric; v_umbral numeric; v_res jsonb; v_id uuid;
begin
    if p_motivo is null or not (p_motivo = any (v_motivos)) then raise exception 'Elige el motivo del ajuste'; end if;
    if p_motivo = 'Otro' and nullif(trim(coalesce(p_detalle, '')), '') is null then raise exception 'Explica el motivo del ajuste'; end if;
    if p_tipo not in ('entrada', 'salida') then raise exception 'Tipo debe ser entrada o salida'; end if;
    if coalesce(p_cantidad, 0) <= 0 then raise exception 'La cantidad debe ser mayor a cero'; end if;
    select descripcion, coalesce(costo, 0) into v_desc, v_costo from productos where codigo = p_codigo;
    if not found then raise exception 'Producto % no existe', p_codigo; end if;
    v_valor := round(p_cantidad * coalesce(nullif(p_costo, 0), v_costo), 2);
    select coalesce(nullif(opciones ->> 'ajuste_aprobacion_usd', '')::numeric, 100) into v_umbral from configuracion limit 1;
    v_umbral := coalesce(v_umbral, 100);
    if v_umbral > 0 and v_valor > v_umbral and not refrimar_puede_aprobar(p_usuario) then
        insert into ajustes_solicitudes (producto_codigo, producto_descripcion, tipo, cantidad, costo_unitario, valor_usd, motivo, detalle, sucursal_id, sucursal_nombre, solicitado_por)
        values (p_codigo, v_desc, p_tipo, p_cantidad, coalesce(p_costo, 0), v_valor, p_motivo, p_detalle, p_sucursal_id, p_sucursal_nombre, p_usuario)
        returning id into v_id;
        return jsonb_build_object('ok', true, 'pendiente', true, 'id', v_id, 'valor_usd', v_valor, 'umbral', v_umbral);
    end if;
    v_res := kardex_ajuste(p_codigo, p_tipo, p_cantidad, coalesce(p_costo, 0),
        'Ajuste · ' || p_motivo || coalesce(' · ' || nullif(trim(p_detalle), ''), ''), p_sucursal_id, p_usuario);
    return v_res || jsonb_build_object('pendiente', false);
end;
$$;

create or replace function ajuste_resolver(p_id uuid, p_aprobar boolean, p_usuario text default 'Sistema')
returns jsonb
language plpgsql security definer
set search_path = public
as $$
declare s ajustes_solicitudes; v_res jsonb := '{}'::jsonb;
begin
    if not refrimar_puede_aprobar(p_usuario) then raise exception 'Tu usuario no puede aprobar ajustes'; end if;
    select * into s from ajustes_solicitudes where id = p_id for update;
    if not found then raise exception 'Solicitud no encontrada'; end if;
    if s.estado <> 'pendiente' then raise exception 'Esta solicitud ya fue %', s.estado; end if;
    if p_aprobar then
        v_res := kardex_ajuste(s.producto_codigo, s.tipo, s.cantidad, s.costo_unitario,
            'Ajuste · ' || s.motivo || coalesce(' · ' || nullif(trim(s.detalle), ''), '') || ' · aprobado por ' || coalesce(p_usuario, ''), s.sucursal_id, s.solicitado_por);
    end if;
    update ajustes_solicitudes set estado = case when p_aprobar then 'aprobado' else 'rechazado' end, resuelto_por = p_usuario, resuelto_at = now() where id = p_id;
    return jsonb_build_object('ok', true) || v_res;
end;
$$;
grant execute on function ajuste_inventario(text, text, numeric, numeric, text, text, uuid, text, text) to anon, authenticated;
grant execute on function ajuste_resolver(uuid, boolean, text) to anon, authenticated;

-- ---------- 4. Análisis de inventario ----------
-- Una fila por producto: stock y costo en la tienda, costo promedio (kardex), ventas del período,
-- última venta, mínimo/máximo y vencimiento (atributos del rubro).
create or replace function inventario_analisis(p_sucursal_id uuid default null, p_dias int default 30)
returns jsonb
language sql stable security definer
set search_path = public
as $$
    with suc as (select case when p_sucursal_id is null or p_sucursal_id = '00000000-0000-0000-0000-000000000001' then null else p_sucursal_id end as id),
    vend as (
        select d.producto_codigo, sum(d.cantidad) as cant, sum(d.total) as monto, max(v.created_at) as ultima
        from detalle_venta d join ventas v on v.id = d.venta_id, suc
        where v.estado = 'completada' and v.created_at >= now() - make_interval(days => greatest(coalesce(p_dias, 30), 1))
          and ((suc.id is null and (v.sucursal_id is null or v.sucursal_id = '00000000-0000-0000-0000-000000000001')) or v.sucursal_id = suc.id)
        group by d.producto_codigo),
    ultima as (
        select d.producto_codigo, max(v.created_at) as ultima
        from detalle_venta d join ventas v on v.id = d.venta_id
        where v.estado = 'completada' group by d.producto_codigo),
    prom as (
        select distinct on (producto_codigo) producto_codigo, saldo_costo_promedio
        from kardex_movimientos, suc
        where (suc.id is null and sucursal_id is null) or sucursal_id = suc.id
        order by producto_codigo, created_at desc)
    select coalesce(jsonb_agg(jsonb_build_object(
        'codigo', p.codigo, 'nombre', p.descripcion, 'categoria', p.categoria, 'marca', p.marca, 'unidad', p.unidad,
        'servicio', coalesce(p.tipo_producto, 'fisico') = 'servicio',
        'stock', case when suc.id is null then coalesce(p.stock, 0) else coalesce(ss.stock, 0) end,
        'costo', coalesce(nullif(ss.costo, 0), p.costo, 0),
        'costo_promedio', coalesce(nullif(pr.saldo_costo_promedio, 0), nullif(ss.costo, 0), p.costo, 0),
        'precio', coalesce(p.precio, 0),
        'minimo', coalesce(p.stock_minimo, 0), 'maximo', p.stock_maximo,
        'vendido', coalesce(vd.cant, 0), 'ingreso', coalesce(vd.monto, 0),
        'ultima_venta', ul.ultima,
        'vencimiento', nullif(p.atributos ->> 'vencimiento', ''),
        'lote', nullif(p.atributos ->> 'lote', ''),
        'ubicacion', nullif(p.atributos ->> 'ubicacion', ''),
        'proveedores', p.proveedores
    )), '[]'::jsonb)
    from productos p cross join suc
    left join sucursal_stock ss on ss.sucursal_id = suc.id and ss.producto_codigo = p.codigo
    left join vend vd on vd.producto_codigo = p.codigo
    left join ultima ul on ul.producto_codigo = p.codigo
    left join prom pr on pr.producto_codigo = p.codigo
    where coalesce(p.activo, true)
$$;
grant execute on function inventario_analisis(uuid, int) to anon, authenticated;

-- ---------- 5. Libros fiscales ----------
alter table compras_proveedores add column if not exists numero_control text;
alter table compras_proveedores add column if not exists base_imponible numeric(14,2);
alter table compras_proveedores add column if not exists exento numeric(14,2);
alter table compras_proveedores add column if not exists alicuota numeric(5,2);
alter table compras_proveedores add column if not exists iva_monto numeric(14,2);
alter table compras_proveedores add column if not exists retencion_iva numeric(14,2);
alter table compras_proveedores add column if not exists tasa_bcv numeric(14,4);

-- Libro de ventas: base por alícuota calculada de las líneas (el IVA de cada producto)
create or replace function libro_ventas(p_desde date, p_hasta date, p_sucursal_id uuid default null)
returns jsonb
language sql stable security definer
set search_path = public
as $$
    with v as (
        select v.*, coalesce(nullif(v.tasa_bcv, 0), case when v.total_usd > 0 then v.total_bs / v.total_usd else 0 end) as ts
        from ventas v
        where v.created_at >= p_desde and v.created_at < p_hasta + 1 and v.estado in ('completada', 'anulada', 'devuelta')
          and (p_sucursal_id is null or v.sucursal_id = p_sucursal_id
               or (p_sucursal_id = '00000000-0000-0000-0000-000000000001' and v.sucursal_id is null))),
    l as (
        select d.venta_id, coalesce(p.iva_tasa, 16) as tasa, sum(d.total) as monto
        from detalle_venta d join v on v.id = d.venta_id left join productos p on p.codigo = d.producto_codigo
        group by d.venta_id, coalesce(p.iva_tasa, 16)),
    lt as (select venta_id, sum(monto) as monto from l group by venta_id)
    select coalesce(jsonb_agg(x order by x->>'fecha', x->>'numero'), '[]'::jsonb) from (
        select jsonb_build_object(
            'tipo', 'FACT', 'fecha', v.created_at, 'numero', v.numero, 'numero_fiscal', v.numero_fiscal, 'serial_fiscal', v.serial_fiscal,
            'cliente_rif', v.cliente_rif, 'cliente_nombre', v.cliente_nombre, 'estado', v.estado, 'tasa', v.ts,
            'total_bs', round(coalesce(v.total_bs, v.total_usd * v.ts), 2),
            -- Si las líneas ya traen el IVA (precios con IVA incluido) se separa; si no, la base es la línea
            'incluido', abs(coalesce(lt.monto, 0) - coalesce(v.total_usd, 0)) < 0.02,
            'exento_bs', round(coalesce((select sum(monto) from l where l.venta_id = v.id and l.tasa = 0), 0) * v.ts, 2),
            'base16_bs', round(coalesce((select sum(case when abs(coalesce(lt.monto, 0) - coalesce(v.total_usd, 0)) < 0.02 then monto / 1.16 else monto end) from l where l.venta_id = v.id and l.tasa = 16), 0) * v.ts, 2),
            'base8_bs', round(coalesce((select sum(case when abs(coalesce(lt.monto, 0) - coalesce(v.total_usd, 0)) < 0.02 then monto / 1.08 else monto end) from l where l.venta_id = v.id and l.tasa = 8), 0) * v.ts, 2),
            'iva_bs', round(coalesce(v.iva, 0) * v.ts, 2),
            'igtf_bs', coalesce(v.igtf_bs, 0)
        ) as x
        from v left join lt on lt.venta_id = v.id
        union all
        select jsonb_build_object(
            'tipo', 'N/C', 'fecha', n.created_at, 'numero', n.numero, 'factura_afectada', n.venta_numero,
            'cliente_rif', n.cliente_rif, 'cliente_nombre', n.cliente_nombre, 'estado', 'nota_credito',
            'total_bs', -round(n.total_bs, 2), 'exento_bs', 0, 'base16_bs', -round(n.total_bs / 1.16, 2), 'base8_bs', 0,
            'iva_bs', -round(n.total_bs - n.total_bs / 1.16, 2), 'igtf_bs', 0)
        from notas_credito n
        where n.created_at >= p_desde and n.created_at < p_hasta + 1
          and (p_sucursal_id is null or n.sucursal_id = p_sucursal_id
               or (p_sucursal_id = '00000000-0000-0000-0000-000000000001' and n.sucursal_id is null))
    ) q
$$;

create or replace function libro_compras(p_desde date, p_hasta date, p_sucursal_id uuid default null)
returns jsonb
language sql stable security definer
set search_path = public
as $$
    select coalesce(jsonb_agg(jsonb_build_object(
        'id', c.id, 'fecha', c.fecha_emision, 'proveedor', c.proveedor, 'rif', c.rif, 'numero', c.numero, 'numero_control', c.numero_control,
        'monto_usd', c.monto_usd, 'tasa', c.tasa_bcv,
        'base_imponible', c.base_imponible, 'exento', c.exento, 'alicuota', c.alicuota, 'iva_monto', c.iva_monto, 'retencion_iva', c.retencion_iva,
        'desglosada', c.base_imponible is not null
    ) order by c.fecha_emision, c.numero), '[]'::jsonb)
    from compras_proveedores c
    where c.fecha_emision >= p_desde and c.fecha_emision <= p_hasta
      and (p_sucursal_id is null or c.sucursal_id = p_sucursal_id
           or (p_sucursal_id = '00000000-0000-0000-0000-000000000001' and c.sucursal_id is null))
$$;

-- Datos fiscales de una factura de compra (montos en bolívares de la factura)
create or replace function compra_fiscal_guardar(p_id uuid, p_numero_control text, p_base numeric, p_exento numeric, p_alicuota numeric, p_iva numeric, p_retencion numeric, p_tasa numeric)
returns jsonb
language plpgsql security definer
set search_path = public
as $$
begin
    if coalesce(p_base, 0) < 0 or coalesce(p_exento, 0) < 0 or coalesce(p_iva, 0) < 0 or coalesce(p_retencion, 0) < 0 then raise exception 'Los montos no pueden ser negativos'; end if;
    if p_alicuota is not null and p_alicuota not in (0, 8, 16, 31) then raise exception 'Alícuota inválida'; end if;
    update compras_proveedores set numero_control = nullif(trim(coalesce(p_numero_control, '')), ''), base_imponible = p_base, exento = p_exento,
        alicuota = p_alicuota, iva_monto = p_iva, retencion_iva = p_retencion, tasa_bcv = p_tasa
    where id = p_id;
    if not found then raise exception 'Factura de compra no encontrada'; end if;
    return jsonb_build_object('ok', true);
end;
$$;
grant execute on function libro_ventas(date, date, uuid) to anon, authenticated;
grant execute on function libro_compras(date, date, uuid) to anon, authenticated;
grant execute on function compra_fiscal_guardar(uuid, text, numeric, numeric, numeric, numeric, numeric, numeric) to anon, authenticated;


-- ---------- 7. Transferencias: enviada (en tránsito) → recibida y confirmada ----------
alter table transferencias add column if not exists enviada_at timestamptz;
alter table transferencias add column if not exists enviada_por text;
alter table transferencias add column if not exists recibida_at timestamptz;
alter table transferencias add column if not exists recibida_por text;
alter table transferencias add column if not exists diferencias jsonb;
alter table transferencia_items add column if not exists cantidad_recibida numeric;

-- Suma o resta stock en una tienda (Casa Matriz = productos.stock)
create or replace function refrimar_mover_stock(p_codigo text, p_sucursal uuid, p_delta numeric, p_desc text)
returns numeric
language plpgsql security definer
set search_path = public
as $$
declare v numeric;
begin
    if p_sucursal is null or p_sucursal = '00000000-0000-0000-0000-000000000001' then
        update productos set stock = coalesce(stock, 0) + p_delta where codigo = p_codigo returning stock into v;
    else
        insert into sucursal_stock (sucursal_id, producto_codigo, producto_descripcion, stock)
        values (p_sucursal, p_codigo, coalesce(p_desc, p_codigo), p_delta)
        on conflict (sucursal_id, producto_codigo) do update set stock = sucursal_stock.stock + p_delta, updated_at = now()
        returning stock into v;
    end if;
    return v;
end;
$$;
revoke execute on function refrimar_mover_stock(text, uuid, numeric, text) from anon, authenticated, public;

-- 1) Enviar: sale del origen y queda "en tránsito"
create or replace function transferencia_enviar(p_id uuid, p_usuario text default 'Sistema')
returns jsonb
language plpgsql security definer
set search_path = public
as $$
declare t transferencias; it record; v_saldo numeric; v_casa uuid := '00000000-0000-0000-0000-000000000001';
begin
    select * into t from transferencias where id = p_id for update;
    if not found then raise exception 'Transferencia no encontrada'; end if;
    if t.estado <> 'borrador' then raise exception 'Solo se envía una transferencia en borrador'; end if;
    for it in select * from transferencia_items where transferencia_id = p_id loop
        if stock_en(it.producto_codigo, t.origen_id) < it.cantidad then
            raise exception 'No hay suficiente stock de "%" en %', coalesce(it.descripcion, it.producto_codigo), coalesce(t.origen_nombre, 'el origen');
        end if;
        v_saldo := refrimar_mover_stock(it.producto_codigo, t.origen_id, -it.cantidad, it.descripcion);
        insert into kardex_movimientos (producto_codigo, producto_descripcion, fecha, tipo, cantidad, costo_unitario, costo_total, saldo_cantidad, saldo_costo_promedio, referencia, usuario_nombre, sucursal_id)
        values (it.producto_codigo, it.descripcion, current_date, 'salida_traslado', -it.cantidad, it.costo_unitario, it.cantidad * it.costo_unitario, v_saldo, it.costo_unitario,
                t.numero || ' → ' || coalesce(t.destino_nombre, '') || ' (en tránsito)', coalesce(p_usuario, 'Sistema'), case when t.origen_id = v_casa then null else t.origen_id end);
    end loop;
    update transferencias set estado = 'en_transito', enviada_at = now(), enviada_por = p_usuario, fecha_envio = coalesce(fecha_envio, current_date) where id = p_id;
    return jsonb_build_object('ok', true, 'estado', 'en_transito', 'numero', t.numero);
end;
$$;

-- 2) Recibir: el destino confirma lo que llegó. Las diferencias quedan anotadas.
create or replace function transferencia_recibir(p_id uuid, p_items jsonb, p_usuario text default 'Sistema')
returns jsonb
language plpgsql security definer
set search_path = public
as $$
declare t transferencias; it record; v_rec numeric; v_saldo numeric; v_dif jsonb := '[]'::jsonb; v_casa uuid := '00000000-0000-0000-0000-000000000001';
begin
    select * into t from transferencias where id = p_id for update;
    if not found then raise exception 'Transferencia no encontrada'; end if;
    if t.estado <> 'en_transito' then raise exception 'Esta transferencia no está en tránsito'; end if;
    for it in select * from transferencia_items where transferencia_id = p_id loop
        select coalesce(nullif(x->>'recibido', '')::numeric, it.cantidad) into v_rec
        from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) x where x->>'codigo' = it.producto_codigo limit 1;
        v_rec := coalesce(v_rec, it.cantidad);
        if v_rec < 0 then raise exception 'Cantidad recibida inválida en %', it.producto_codigo; end if;
        update transferencia_items set cantidad_recibida = v_rec where id = it.id;
        if v_rec > 0 then
            v_saldo := refrimar_mover_stock(it.producto_codigo, t.destino_id, v_rec, it.descripcion);
            insert into kardex_movimientos (producto_codigo, producto_descripcion, fecha, tipo, cantidad, costo_unitario, costo_total, saldo_cantidad, saldo_costo_promedio, referencia, usuario_nombre, sucursal_id)
            values (it.producto_codigo, it.descripcion, current_date, 'entrada_traslado', v_rec, it.costo_unitario, v_rec * it.costo_unitario, v_saldo, it.costo_unitario,
                    t.numero || ' ← ' || coalesce(t.origen_nombre, ''), coalesce(p_usuario, 'Sistema'), case when t.destino_id = v_casa then null else t.destino_id end);
        end if;
        if v_rec <> it.cantidad then
            v_dif := v_dif || jsonb_build_object('codigo', it.producto_codigo, 'descripcion', it.descripcion, 'enviado', it.cantidad, 'recibido', v_rec, 'diferencia', v_rec - it.cantidad,
                                                 'valor_usd', round((v_rec - it.cantidad) * it.costo_unitario, 2));
        end if;
    end loop;
    update transferencias set estado = case when jsonb_array_length(v_dif) = 0 then 'completada' else 'con_diferencias' end,
        recibida_at = now(), recibida_por = p_usuario, completada_at = now(), fecha_recepcion = current_date,
        diferencias = case when jsonb_array_length(v_dif) = 0 then null else v_dif end
    where id = p_id;
    return jsonb_build_object('ok', true, 'diferencias', v_dif);
end;
$$;
grant execute on function transferencia_enviar(uuid, text) to anon, authenticated;
grant execute on function transferencia_recibir(uuid, jsonb, text) to anon, authenticated;

-- ---------- 6. Seguridad (si ya corriste supabase-migration-seguridad.sql) ----------
do $$ begin
    if to_regclass('public.seguridad_rpc') is not null then
        insert into seguridad_rpc (nombre, nivel, permiso) values
            ('auditoria_listar', 'sesion', null),
            ('ajuste_inventario', 'permiso', 'editar_inventario'),
            ('ajuste_resolver', 'permiso', 'editar_inventario'),
            ('inventario_analisis', 'permiso', 'ver_inventario'),
            ('libro_ventas', 'permiso', 'ver_finanzas'),
            ('libro_compras', 'permiso', 'ver_finanzas'),
            ('compra_fiscal_guardar', 'permiso', 'gestionar_finanzas'),
            ('transferencia_enviar', 'permiso', 'gestionar_transferencias'),
            ('transferencia_recibir', 'permiso', 'recibir_transferencia')
        on conflict (nombre) do update set nivel = excluded.nivel, permiso = excluded.permiso;
    end if;
end $$;

notify pgrst, 'reload schema';
select 'Inventario, auditoría y libros fiscales listos' as resultado;
