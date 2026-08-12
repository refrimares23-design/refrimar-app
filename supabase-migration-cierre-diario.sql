-- ============================================================
-- MIGRACIÓN: CIERRE DIARIO DE CAJA — REFRIMAR OS
-- ------------------------------------------------------------
-- Registro diario multi-moneda: Pago Móvil / Punto A / Punto B /
-- Venta Bs / Venta $ / Gastos Bs / Gastos $ / Descripción /
-- Logística y Caleta (LO/Q) / Reparto (Bs y $).
--
-- Corresponde EXACTO a las columnas del archivo "Libro 1" del
-- negocio (FECHA;PAGO MOVIL;PUNTO A;PUNTO B;VENTA BS;VENTA $;
-- GASTOS BS;GASTOS $;DESCRIPCION;LO/Q BS;LO/Q $;REPARTO BS;REPARTO $).
--
-- SEPARACIÓN POR SUCURSAL:
--   Un cierre por (fecha, sucursal). Casa Matriz usa el UUID fijo
--   00000000-0000-0000-0000-000000000001 (misma convención que
--   caja_movimientos).
--
-- Cómo aplicar:
-- 1. Entra a https://supabase.com/dashboard → tu proyecto
--    (hjecifftqidqeswcpvwt) → SQL Editor → New query
-- 2. Pega TODO este archivo y presiona "Run"
-- 3. Es seguro volver a correrlo (usa IF NOT EXISTS / OR REPLACE).
--
-- La app (anon key) queda SOLO con lectura; toda escritura pasa
-- por las funciones RPC SECURITY DEFINER (cierre_diario_guardar,
-- cierre_diario_eliminar, cierre_diario_importar).
-- ============================================================

-- ------------------------------------------------------------
-- 0. Helpers de normalización (números y fechas de cualquier CSV)
--    Reutilizan el mismo formato del resto de importaciones.
-- ------------------------------------------------------------
create or replace function numero_valido(p_val text) returns numeric
language plpgsql immutable
as $$
declare
    v text;
begin
    if p_val is null then return null; end if;
    v := trim(p_val);
    if v = '' or lower(v) in ('null', 'n/a', '-') then return null; end if;
    begin
        return v::numeric;
    exception when others then
        -- formato venezolano con coma decimal: "1.234,56" -> 1234.56
        v := regexp_replace(v, '\s', '', 'g');
        v := replace(v, '.', '');
        v := replace(v, ',', '.');
        v := regexp_replace(v, '[^0-9.\-]', '', 'g');
        begin
            return v::numeric;
        exception when others then
            return null;
        end;
    end;
end;
$$;

create or replace function fecha_valida(p_val text) returns date
language plpgsql immutable
as $$
begin
    if p_val is null then return null; end if;
    if trim(p_val) = '' or lower(trim(p_val)) = 'null' then return null; end if;
    begin
        return trim(p_val)::date;
    exception when others then
        return null;
    end;
end;
$$;

-- ------------------------------------------------------------
-- 1. Tabla cierre_diario
--    Numeric(14,2) para montos, Date para fecha, Text para la
--    descripción. Un solo cierre por día y sucursal.
-- ------------------------------------------------------------
create table if not exists cierre_diario (
    id uuid primary key default gen_random_uuid(),
    fecha date not null,
    pago_movil numeric(14,2) not null default 0,
    punto_a numeric(14,2) not null default 0,
    punto_b numeric(14,2) not null default 0,
    venta_bs numeric(14,2) not null default 0,
    venta_usd numeric(14,2) not null default 0,
    gastos_bs numeric(14,2) not null default 0,
    gastos_usd numeric(14,2) not null default 0,
    descripcion text not null default '',
    loq_bs numeric(14,2) not null default 0,
    loq_usd numeric(14,2) not null default 0,
    reparto_bs numeric(14,2) not null default 0,
    reparto_usd numeric(14,2) not null default 0,
    sucursal_id uuid not null default '00000000-0000-0000-0000-000000000001',
    usuario_nombre text not null default 'Sistema',
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    unique (fecha, sucursal_id)
);

create index if not exists idx_cierre_diario_fecha on cierre_diario(fecha, sucursal_id);

-- ------------------------------------------------------------
-- 2. RPC: GUARDAR / ACTUALIZAR un cierre (upsert por fecha+sucursal)
-- ------------------------------------------------------------
create or replace function cierre_diario_guardar(
    p_fecha date,
    p_sucursal_id uuid,
    p_pago_movil numeric default 0,
    p_punto_a numeric default 0,
    p_punto_b numeric default 0,
    p_venta_bs numeric default 0,
    p_venta_usd numeric default 0,
    p_gastos_bs numeric default 0,
    p_gastos_usd numeric default 0,
    p_descripcion text default '',
    p_loq_bs numeric default 0,
    p_loq_usd numeric default 0,
    p_reparto_bs numeric default 0,
    p_reparto_usd numeric default 0,
    p_usuario text default 'Sistema'
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_id uuid;
begin
    if p_fecha is null then
        raise exception 'La fecha es obligatoria';
    end if;
    if p_sucursal_id is null then
        p_sucursal_id := '00000000-0000-0000-0000-000000000001';
    end if;

    insert into cierre_diario (
        fecha, sucursal_id,
        pago_movil, punto_a, punto_b, venta_bs, venta_usd,
        gastos_bs, gastos_usd, descripcion,
        loq_bs, loq_usd, reparto_bs, reparto_usd,
        usuario_nombre, updated_at
    )
    values (
        p_fecha, p_sucursal_id,
        coalesce(p_pago_movil, 0), coalesce(p_punto_a, 0), coalesce(p_punto_b, 0),
        coalesce(p_venta_bs, 0), coalesce(p_venta_usd, 0),
        coalesce(p_gastos_bs, 0), coalesce(p_gastos_usd, 0),
        trim(coalesce(p_descripcion, '')),
        coalesce(p_loq_bs, 0), coalesce(p_loq_usd, 0),
        coalesce(p_reparto_bs, 0), coalesce(p_reparto_usd, 0),
        coalesce(p_usuario, 'Sistema'), now()
    )
    on conflict (fecha, sucursal_id) do update set
        pago_movil = excluded.pago_movil,
        punto_a = excluded.punto_a,
        punto_b = excluded.punto_b,
        venta_bs = excluded.venta_bs,
        venta_usd = excluded.venta_usd,
        gastos_bs = excluded.gastos_bs,
        gastos_usd = excluded.gastos_usd,
        descripcion = excluded.descripcion,
        loq_bs = excluded.loq_bs,
        loq_usd = excluded.loq_usd,
        reparto_bs = excluded.reparto_bs,
        reparto_usd = excluded.reparto_usd,
        usuario_nombre = excluded.usuario_nombre,
        updated_at = now()
    returning id into v_id;

    return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

-- ------------------------------------------------------------
-- 3. RPC: ELIMINAR un cierre
-- ------------------------------------------------------------
create or replace function cierre_diario_eliminar(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
    if p_id is null then
        raise exception 'Falta el cierre';
    end if;
    delete from cierre_diario where id = p_id;
    if not found then
        raise exception 'Cierre no encontrado';
    end if;
    return jsonb_build_object('ok', true);
end;
$$;

-- ------------------------------------------------------------
-- 4. RPC: IMPORTAR en masa (CSV precargado). Recibe un array JSON
--    con {fecha, pago_movil, punto_a, ..., descripcion, ...}.
--    Upsert por (fecha, sucursal): re-importar es seguro.
-- ------------------------------------------------------------
create or replace function cierre_diario_importar(
    p_rows jsonb,
    p_sucursal_id uuid default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_row jsonb;
    v_fecha date;
    v_sucursal uuid;
    v_nuevas int := 0;
    v_actualizadas int := 0;
    v_descartadas int := 0;
    v_ins record;
begin
    if p_rows is null or jsonb_typeof(p_rows) <> 'array' then
        return jsonb_build_object('ok', false, 'error', 'Debes enviar un array JSON');
    end if;

    if p_sucursal_id is null then
        v_sucursal := '00000000-0000-0000-0000-000000000001';
    else
        v_sucursal := p_sucursal_id;
    end if;

    for v_row in select value from jsonb_array_elements(p_rows)
    loop
        v_fecha := fecha_valida(v_row->>'fecha');
        if v_fecha is null then
            v_descartadas := v_descartadas + 1;
            continue;
        end if;

        with ins as (
            insert into cierre_diario (
                fecha, sucursal_id,
                pago_movil, punto_a, punto_b, venta_bs, venta_usd,
                gastos_bs, gastos_usd, descripcion,
                loq_bs, loq_usd, reparto_bs, reparto_usd,
                usuario_nombre, updated_at
            )
            values (
                v_fecha, v_sucursal,
                coalesce(numero_valido(v_row->>'pago_movil'), 0),
                coalesce(numero_valido(v_row->>'punto_a'), 0),
                coalesce(numero_valido(v_row->>'punto_b'), 0),
                coalesce(numero_valido(v_row->>'venta_bs'), 0),
                coalesce(numero_valido(v_row->>'venta_usd'), 0),
                coalesce(numero_valido(v_row->>'gastos_bs'), 0),
                coalesce(numero_valido(v_row->>'gastos_usd'), 0),
                trim(coalesce(v_row->>'descripcion', '')),
                coalesce(numero_valido(v_row->>'loq_bs'), 0),
                coalesce(numero_valido(v_row->>'loq_usd'), 0),
                coalesce(numero_valido(v_row->>'reparto_bs'), 0),
                coalesce(numero_valido(v_row->>'reparto_usd'), 0),
                coalesce(v_row->>'usuario', 'Importación CSV'), now()
            )
            on conflict (fecha, sucursal_id) do update set
                pago_movil = excluded.pago_movil,
                punto_a = excluded.punto_a,
                punto_b = excluded.punto_b,
                venta_bs = excluded.venta_bs,
                venta_usd = excluded.venta_usd,
                gastos_bs = excluded.gastos_bs,
                gastos_usd = excluded.gastos_usd,
                descripcion = excluded.descripcion,
                loq_bs = excluded.loq_bs,
                loq_usd = excluded.loq_usd,
                reparto_bs = excluded.reparto_bs,
                reparto_usd = excluded.reparto_usd,
                usuario_nombre = excluded.usuario_nombre,
                updated_at = now()
            returning (xmax = 0) as es_insert
        )
        select count(*) filter (where es_insert) as nuevas,
               count(*) filter (where not es_insert) as actualizadas
        into v_ins
        from ins;

        v_nuevas := v_nuevas + coalesce(v_ins.nuevas, 0)::int;
        v_actualizadas := v_actualizadas + coalesce(v_ins.actualizadas, 0)::int;
    end loop;

    return jsonb_build_object(
        'ok', true,
        'nuevas', v_nuevas,
        'actualizadas', v_actualizadas,
        'descartadas', v_descartadas,
        'total_procesadas', v_nuevas + v_actualizadas
    );
end;
$$;

-- ------------------------------------------------------------
-- 5. RLS: habilitar y dejar SOLO lectura a anon/authenticated.
--    Las funciones SECURITY DEFINER son las únicas que escriben.
-- ------------------------------------------------------------
alter table cierre_diario enable row level security;

drop policy if exists "cierre_diario_select" on cierre_diario;
create policy "cierre_diario_select" on cierre_diario for select using (true);

revoke insert, update, delete on cierre_diario from anon, authenticated;
grant select on cierre_diario to anon, authenticated;

grant execute on function cierre_diario_guardar(date, uuid, numeric, numeric, numeric, numeric, numeric, numeric, numeric, text, numeric, numeric, numeric, numeric, text) to anon, authenticated;
grant execute on function cierre_diario_eliminar(uuid) to anon, authenticated;
grant execute on function cierre_diario_importar(jsonb, uuid) to anon, authenticated;
