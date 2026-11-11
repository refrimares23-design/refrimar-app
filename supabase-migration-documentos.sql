-- ============================================================
-- DOCUMENTOS FISCALES (Providencias SNAT/2011/00071 y SNAT/2024/000102)
-- ------------------------------------------------------------
-- • Número de control para facturas en forma libre: se asigna en orden,
--   sin saltos, dentro del rango que entregó la imprenta autorizada.
-- • Notas de débito (cargos posteriores a una factura).
-- • El Libro de Ventas incluye número de control y notas de débito.
-- La máquina fiscal pone su propio número; la factura digital lo recibe
-- de la imprenta digital contratada.
-- Se puede correr varias veces.
-- ============================================================

alter table ventas add column if not exists numero_control text;
alter table ventas add column if not exists serie text;
alter table ventas add column if not exists control_asignado_at timestamptz;
do $$ begin
    if to_regclass('public.notas_credito') is not null then
        alter table notas_credito add column if not exists numero_control text;
    end if;
end $$;

create sequence if not exists seq_nota_debito;
create table if not exists notas_debito (
    id uuid primary key default gen_random_uuid(),
    numero text not null unique,
    venta_id uuid,
    factura_numero text not null,
    factura_fecha timestamptz,
    factura_control text,
    numero_control text,
    fecha timestamptz not null default now(),
    cliente_nombre text,
    cliente_rif text,
    motivo text not null,
    iva_pct numeric not null default 16,
    subtotal_usd numeric not null default 0,
    iva_usd numeric not null default 0,
    total_usd numeric not null default 0,
    tasa_bcv numeric,
    total_bs numeric,
    sucursal_id uuid,
    usuario_nombre text,
    estado text not null default 'emitida' check (estado in ('emitida', 'anulada'))
);
create index if not exists idx_notas_debito_fecha on notas_debito(fecha);
alter table notas_debito enable row level security;
drop policy if exists "notas_debito_select" on notas_debito;
create policy "notas_debito_select" on notas_debito for select using (true);
revoke insert, update, delete on notas_debito from anon, authenticated;
grant select on notas_debito to anon, authenticated;

-- Próximo número de control (forma libre). p_tipo: factura | nota_credito | nota_debito
create or replace function documento_control_asignar(p_tipo text, p_numero text)
returns jsonb
language plpgsql security definer
set search_path = public
as $$
declare
    c record; f jsonb; v_actual text; v_pref text; v_seq bigint; v_hasta bigint; v_ancho int; v_ctl text; v_rest bigint;
begin
    -- Si el documento ya tiene número de control, se devuelve el mismo (reimpresión)
    if p_tipo = 'factura' then select numero_control into v_actual from ventas where numero = p_numero;
    elsif p_tipo = 'nota_credito' then execute 'select numero_control from notas_credito where numero = $1' into v_actual using p_numero;
    elsif p_tipo = 'nota_debito' then select numero_control into v_actual from notas_debito where numero = p_numero;
    else raise exception 'Tipo de documento inválido'; end if;
    if v_actual is not null then return jsonb_build_object('ok', true, 'numero_control', v_actual, 'nuevo', false); end if;

    select * into c from configuracion limit 1 for update;
    f := coalesce(c.opciones -> 'facturacion', '{}'::jsonb);
    if coalesce(f ->> 'modo', '') <> 'forma_libre' then
        return jsonb_build_object('ok', false, 'error', 'El negocio no factura en forma libre');
    end if;
    -- Formato "00-00000001": identificador de 2 dígitos + secuencial de hasta 8 (Providencia 0071, art. 44)
    v_actual := coalesce(nullif(f ->> 'proximo_control', ''), nullif(f ->> 'control_desde', ''));
    if v_actual is null or v_actual !~ '^\s*[0-9]{1,2}\s*-\s*[0-9]{1,8}\s*$' then
        raise exception 'Configura el rango de números de control (ej. 00-00000001 hasta 00-00005000) en Primeros pasos → Facturas';
    end if;
    v_pref := lpad(trim(split_part(v_actual, '-', 1)), 2, '0');
    v_seq := trim(split_part(v_actual, '-', 2))::bigint;
    v_ancho := greatest(8, length(trim(split_part(v_actual, '-', 2))));
    if coalesce(f ->> 'control_hasta', '') ~ '^\s*[0-9]{1,2}\s*-\s*[0-9]{1,8}\s*$' then
        v_hasta := trim(split_part(f ->> 'control_hasta', '-', 2))::bigint;
        if v_seq > v_hasta then raise exception 'Se acabaron los números de control (último: %). Pide formatos nuevos a la imprenta y actualiza el rango.', f ->> 'control_hasta'; end if;
        v_rest := v_hasta - v_seq;
    end if;
    v_ctl := v_pref || '-' || lpad(v_seq::text, v_ancho, '0');

    if p_tipo = 'factura' then update ventas set numero_control = v_ctl, serie = nullif(f ->> 'serie', ''), control_asignado_at = now() where numero = p_numero;
    elsif p_tipo = 'nota_credito' then execute 'update notas_credito set numero_control = $1 where numero = $2' using v_ctl, p_numero;
    else update notas_debito set numero_control = v_ctl where numero = p_numero; end if;
    if not found then raise exception 'Documento % no encontrado', p_numero; end if;

    update configuracion set opciones = jsonb_set(coalesce(opciones, '{}'::jsonb), '{facturacion,proximo_control}',
        to_jsonb(v_pref || '-' || lpad((v_seq + 1)::text, v_ancho, '0')), true)
    where id = c.id;
    return jsonb_build_object('ok', true, 'numero_control', v_ctl, 'nuevo', true, 'restantes', v_rest,
        'desde', f ->> 'control_desde', 'hasta', f ->> 'control_hasta');
end;
$$;
grant execute on function documento_control_asignar(text, text) to anon, authenticated;

-- Nota de débito sobre una factura (intereses, fletes, diferencia de precio…)
create or replace function nota_debito_crear(p_factura text, p_motivo text, p_monto_usd numeric, p_iva_pct numeric default 16, p_usuario text default null)
returns jsonb
language plpgsql security definer
set search_path = public
as $$
declare v record; v_num text; v_tasa numeric; v_sub numeric; v_iva numeric; nd notas_debito;
begin
    select * into v from ventas where numero = p_factura;
    if not found then raise exception 'No existe la factura %', p_factura; end if;
    if v.estado = 'anulada' then raise exception 'La factura % está anulada', p_factura; end if;
    if nullif(trim(coalesce(p_motivo, '')), '') is null then raise exception 'Escribe el motivo de la nota de débito'; end if;
    if coalesce(p_monto_usd, 0) <= 0 then raise exception 'El monto debe ser mayor que cero'; end if;
    if coalesce(p_iva_pct, 16) not in (0, 8, 16, 31) then raise exception 'Alícuota inválida'; end if;
    select coalesce(nullif(tasa_bcv_manual, 0), v.tasa_bcv) into v_tasa from configuracion limit 1;
    v_sub := round(p_monto_usd, 2);
    v_iva := round(v_sub * coalesce(p_iva_pct, 16) / 100, 2);
    v_num := 'ND-' || lpad(nextval('seq_nota_debito')::text, 6, '0');
    insert into notas_debito (numero, venta_id, factura_numero, factura_fecha, factura_control, cliente_nombre, cliente_rif, motivo, iva_pct,
        subtotal_usd, iva_usd, total_usd, tasa_bcv, total_bs, sucursal_id, usuario_nombre)
    values (v_num, v.id, v.numero, v.created_at, v.numero_control, v.cliente_nombre, v.cliente_rif, trim(p_motivo), coalesce(p_iva_pct, 16),
        v_sub, v_iva, v_sub + v_iva, v_tasa, round((v_sub + v_iva) * coalesce(v_tasa, 0), 2), v.sucursal_id, coalesce(p_usuario, 'Sistema'))
    returning * into nd;
    return to_jsonb(nd);
end;
$$;
grant execute on function nota_debito_crear(text, text, numeric, numeric, text) to anon, authenticated;

create or replace function nota_debito_anular(p_numero text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
    update notas_debito set estado = 'anulada' where numero = p_numero and estado = 'emitida';
    if not found then raise exception 'Nota de débito no encontrada o ya anulada'; end if;
    return jsonb_build_object('ok', true);
end;
$$;
grant execute on function nota_debito_anular(text) to anon, authenticated;

-- Libro de ventas: con número de control y notas de débito
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
            'tipo', 'FACT', 'fecha', v.created_at, 'numero', v.numero, 'numero_control', v.numero_control, 'numero_fiscal', v.numero_fiscal, 'serial_fiscal', v.serial_fiscal,
            'cliente_rif', v.cliente_rif, 'cliente_nombre', v.cliente_nombre, 'estado', v.estado, 'tasa', v.ts,
            'total_bs', round(coalesce(v.total_bs, v.total_usd * v.ts), 2),
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
            'tipo', 'N/C', 'fecha', n.created_at, 'numero', n.numero, 'numero_control', to_jsonb(n) ->> 'numero_control', 'factura_afectada', n.venta_numero,
            'cliente_rif', n.cliente_rif, 'cliente_nombre', n.cliente_nombre, 'estado', 'nota_credito',
            'total_bs', -round(n.total_bs, 2), 'exento_bs', 0, 'base16_bs', -round(n.total_bs / 1.16, 2), 'base8_bs', 0,
            'iva_bs', -round(n.total_bs - n.total_bs / 1.16, 2), 'igtf_bs', 0)
        from notas_credito n
        where n.created_at >= p_desde and n.created_at < p_hasta + 1
          and (p_sucursal_id is null or n.sucursal_id = p_sucursal_id
               or (p_sucursal_id = '00000000-0000-0000-0000-000000000001' and n.sucursal_id is null))
        union all
        select jsonb_build_object(
            'tipo', 'N/D', 'fecha', d.fecha, 'numero', d.numero, 'numero_control', d.numero_control, 'factura_afectada', d.factura_numero,
            'cliente_rif', d.cliente_rif, 'cliente_nombre', d.cliente_nombre, 'estado', d.estado,
            'total_bs', case when d.estado = 'anulada' then 0 else round(d.total_bs, 2) end,
            'exento_bs', case when d.estado = 'anulada' or d.iva_pct <> 0 then 0 else round(d.subtotal_usd * d.tasa_bcv, 2) end,
            'base16_bs', case when d.estado = 'anulada' or d.iva_pct <> 16 then 0 else round(d.subtotal_usd * d.tasa_bcv, 2) end,
            'base8_bs', case when d.estado = 'anulada' or d.iva_pct <> 8 then 0 else round(d.subtotal_usd * d.tasa_bcv, 2) end,
            'iva_bs', case when d.estado = 'anulada' then 0 else round(d.iva_usd * d.tasa_bcv, 2) end, 'igtf_bs', 0)
        from notas_debito d
        where d.fecha >= p_desde and d.fecha < p_hasta + 1
          and (p_sucursal_id is null or d.sucursal_id = p_sucursal_id
               or (p_sucursal_id = '00000000-0000-0000-0000-000000000001' and d.sucursal_id is null))
    ) q
$$;

do $$ begin
    if to_regclass('public.seguridad_rpc') is not null then
        insert into seguridad_rpc (nombre, nivel, permiso) values
            ('documento_control_asignar', 'permiso', 'facturar'),
            ('nota_debito_crear', 'permiso', 'facturar'),
            ('nota_debito_anular', 'permiso', 'devoluciones')
        on conflict (nombre) do update set nivel = excluded.nivel, permiso = excluded.permiso;
    end if;
end $$;

do $$ begin
    if to_regprocedure('saas.sincronizar_todas()') is not null then perform saas.sincronizar_todas(); end if;
end $$;
notify pgrst, 'reload schema';
select 'Documentos fiscales listos' as resultado;
