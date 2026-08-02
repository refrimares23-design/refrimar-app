-- ============================================================
-- MIGRACIÓN: CUENTAS POR PAGAR (compras_proveedores) — REFRIMAR OS
-- ------------------------------------------------------------
-- Crea el módulo de cuentas por pagar en el proyecto NUEVO y las
-- funciones que permiten importar EN MASA los datos de la
-- plataforma anterior (facturas por pagar, abonos y ventas) sin
-- perder ningún registro.
--
-- SEPARACIÓN POR SUCURSAL:
-- Toda factura/abono se asigna a una sucursal (sucursal_id).
-- La importación recibe la sucursal destino y el frontend filtra
-- SIEMPRE por la sucursal de la sesión activa.
--
-- Cómo aplicar:
-- 1. Entra a https://supabase.com/dashboard → tu proyecto NUEVO
--    (hjecifftqidqeswcpvwt) → SQL Editor → New query
-- 2. Pega TODO este archivo y presiona "Run"
-- 3. Es seguro volver a correrlo (usa IF NOT EXISTS / OR REPLACE).
-- ============================================================

-- ------------------------------------------------------------
-- 0. Helpers de normalización (fechas y números de cualquier CSV)
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
-- 1. Tabla de compras a proveedores (cuentas por pagar)
--    Unique POR SUCURSAL: (sucursal_id, proveedor, numero)
-- ------------------------------------------------------------
create table if not exists compras_proveedores (
    id uuid primary key default gen_random_uuid(),
    proveedor text not null default '',
    rif text,
    numero text not null default '',
    fecha_emision date not null default current_date,
    fecha_vencimiento date,
    monto_usd numeric(14,2) not null default 0,
    monto_abonado numeric(14,2) not null default 0,
    saldo_pendiente numeric(14,2) not null default 0,
    estado text not null default 'Pendiente',
    notas text,
    foto_url text,
    fecha_pago date,
    factura_origen_id uuid,
    origen text not null default 'manual',
    sucursal_id uuid,
    sucursal_nombre text,
    creado_en timestamptz not null default now(),
    unique (sucursal_id, proveedor, numero)
);

-- ------------------------------------------------------------
-- 2. Tabla de abonos / pagos parciales
-- ------------------------------------------------------------
create table if not exists abonos_compras (
    id uuid primary key default gen_random_uuid(),
    compra_proveedor_id uuid not null references compras_proveedores(id) on delete cascade,
    monto numeric(14,2) not null default 0,
    fecha date not null default current_date,
    abono_origen_id uuid,
    sucursal_id uuid,
    creado_en timestamptz not null default now(),
    unique (abono_origen_id)
);

create index if not exists idx_compras_prov_estado on compras_proveedores(estado);
create index if not exists idx_compras_prov_proveedor on compras_proveedores(proveedor);
create index if not exists idx_compras_prov_vencimiento on compras_proveedores(fecha_vencimiento);
create index if not exists idx_compras_prov_sucursal on compras_proveedores(sucursal_id);
create index if not exists idx_abonos_compras_compra on abonos_compras(compra_proveedor_id);
create index if not exists idx_abonos_compras_sucursal on abonos_compras(sucursal_id);

-- ------------------------------------------------------------
-- 3. Row Level Security (mismo patrón que el resto de la app)
-- ------------------------------------------------------------
alter table compras_proveedores enable row level security;
alter table abonos_compras enable row level security;

drop policy if exists "compras_proveedores_select" on compras_proveedores;
create policy "compras_proveedores_select" on compras_proveedores for select using (true);
drop policy if exists "compras_proveedores_insert" on compras_proveedores;
create policy "compras_proveedores_insert" on compras_proveedores for insert with check (true);
drop policy if exists "compras_proveedores_update" on compras_proveedores;
create policy "compras_proveedores_update" on compras_proveedores for update using (true);
drop policy if exists "compras_proveedores_delete" on compras_proveedores;
create policy "compras_proveedores_delete" on compras_proveedores for delete using (true);

drop policy if exists "abonos_compras_select" on abonos_compras;
create policy "abonos_compras_select" on abonos_compras for select using (true);
drop policy if exists "abonos_compras_insert" on abonos_compras;
create policy "abonos_compras_insert" on abonos_compras for insert with check (true);
drop policy if exists "abonos_compras_delete" on abonos_compras;
create policy "abonos_compras_delete" on abonos_compras for delete using (true);

-- ------------------------------------------------------------
-- 4. IMPORTACIÓN MASIVA #1 — Facturas por pagar (CXP)
--    Recibe un JSON array + sucursal destino. Por cada línea hace
--    UPSERT por (sucursal_id, proveedor, numero).
-- ------------------------------------------------------------
create or replace function importar_cxp_masiva(p_rows jsonb, p_sucursal_id uuid default null, p_sucursal_nombre text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_row jsonb;
    v_proveedor text;
    v_numero text;
    v_estado text;
    v_monto numeric;
    v_saldo numeric;
    v_abonado numeric;
    v_sucursal uuid;
    v_sucursal_nombre text;
    v_nuevas int := 0;
    v_actualizadas int := 0;
    v_descartadas int := 0;
    v_ins record;
begin
    if p_rows is null or jsonb_typeof(p_rows) <> 'array' then
        return jsonb_build_object('ok', false, 'error', 'Debes enviar un array JSON');
    end if;

    for v_row in select value from jsonb_array_elements(p_rows)
    loop
        v_proveedor := upper(trim(coalesce(v_row->>'proveedor', '')));
        v_numero := trim(coalesce(v_row->>'numero', ''));
        if v_proveedor = '' or v_numero = '' then
            v_descartadas := v_descartadas + 1;
            continue;
        end if;

        -- Sucursal: prioridad fila > parámetro > Casa Matriz
        if v_row->>'sucursal_id' ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then
            v_sucursal := (v_row->>'sucursal_id')::uuid;
        else
            v_sucursal := coalesce(p_sucursal_id, '00000000-0000-0000-0000-000000000001');
        end if;
        v_sucursal_nombre := nullif(trim(coalesce(v_row->>'sucursal_nombre', p_sucursal_nombre, '')), '');
        if v_sucursal_nombre is null then
            v_sucursal_nombre := 'Casa Matriz';
        end if;

        v_estado := upper(trim(coalesce(v_row->>'estado', 'Pendiente')));
        if v_estado not in ('PENDIENTE', 'PAGADA', 'VENCIDA', 'ANULADA') then
            v_estado := 'PENDIENTE';
        end if;

        -- El CSV exportado de la plataforma anterior ya tiene el saldo
        -- CON los abonos aplicados. Por eso el monto_abonado se deduce:
        --   monto_abonado = monto - saldo  (nunca se resta 2 veces).
        v_monto := greatest(coalesce(numero_valido(v_row->>'monto_usd'),
                                     numero_valido(v_row->>'monto'), 0), 0);
        v_saldo := greatest(coalesce(numero_valido(v_row->>'saldo_pendiente'), 0), 0);
        v_abonado := greatest(coalesce(numero_valido(v_row->>'monto_abonado'), 0),
                              v_monto - v_saldo, 0);

        with ins as (
            insert into compras_proveedores
                (proveedor, rif, numero, fecha_emision, fecha_vencimiento,
                 monto_usd, monto_abonado, saldo_pendiente, estado, notas,
                 foto_url, fecha_pago, factura_origen_id, origen,
                 sucursal_id, sucursal_nombre)
            values
                (v_proveedor,
                 nullif(trim(coalesce(v_row->>'rif', '')), ''),
                 v_numero,
                 coalesce(fecha_valida(v_row->>'fecha_emision'),
                          fecha_valida(v_row->>'fecha'),
                          current_date),
                 coalesce(fecha_valida(v_row->>'fecha_vencimiento'),
                          fecha_valida(v_row->>'vencimiento')),
                 v_monto,
                 v_abonado,
                 v_saldo,
                 v_estado,
                 nullif(trim(coalesce(v_row->>'notas', '')), ''),
                 nullif(trim(coalesce(v_row->>'foto_url', '')), ''),
                 coalesce(fecha_valida(v_row->>'fecha_pago'),
                          fecha_valida(v_row->>'fecha_vencimiento')),
                 case when v_row->>'factura_origen_id' ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
                      then (v_row->>'factura_origen_id')::uuid
                      else null end,
                 'migracion',
                 v_sucursal,
                 v_sucursal_nombre)
            on conflict (sucursal_id, proveedor, numero) do update set
                rif = excluded.rif,
                fecha_emision = excluded.fecha_emision,
                fecha_vencimiento = excluded.fecha_vencimiento,
                monto_usd = excluded.monto_usd,
                monto_abonado = excluded.monto_abonado,
                saldo_pendiente = excluded.saldo_pendiente,
                estado = excluded.estado,
                notas = excluded.notas,
                foto_url = excluded.foto_url,
                fecha_pago = excluded.fecha_pago,
                sucursal_id = excluded.sucursal_id,
                sucursal_nombre = excluded.sucursal_nombre,
                origen = 'migracion'
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

grant execute on function importar_cxp_masiva(jsonb, uuid, text) to anon, authenticated;

-- ------------------------------------------------------------
-- 5. IMPORTACIÓN MASIVA #2 — Abonos (pagos parciales)
--    Cada fila: id, proveedor, factura_numero, monto, fecha.
--    IMPORTANTE: el saldo de compras_proveedores ya viene con los
--    abonos descontados (ver función #4), así que aquí SOLO se
--    registran los abonos como histórico para no duplicar la
--    rebaja de saldo. El id original evita duplicados.
--    Solo enlaza con facturas de la sucursal destino.
-- ------------------------------------------------------------
create or replace function importar_abonos_masiva(p_rows jsonb, p_sucursal_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_row jsonb;
    v_compra_id uuid;
    v_monto numeric;
    v_fecha date;
    v_aplicados int := 0;
    v_no_encontrados int := 0;
    v_duplicados int := 0;
    v_descartados int := 0;
begin
    if p_rows is null or jsonb_typeof(p_rows) <> 'array' then
        return jsonb_build_object('ok', false, 'error', 'Debes enviar un array JSON');
    end if;

    for v_row in select value from jsonb_array_elements(p_rows)
    loop
        v_monto := numero_valido(v_row->>'monto');
        if v_monto is null or v_monto <= 0 then
            v_descartados := v_descartados + 1;
            continue;
        end if;

        select id into v_compra_id
        from compras_proveedores
        where upper(proveedor) = upper(trim(coalesce(v_row->>'proveedor', '')))
          and numero = trim(coalesce(v_row->>'factura_numero', v_row->>'numero', ''))
          and (p_sucursal_id is null or sucursal_id = p_sucursal_id)
        limit 1;

        if v_compra_id is null then
            v_no_encontrados := v_no_encontrados + 1;
            continue;
        end if;

        v_fecha := coalesce(fecha_valida(v_row->>'fecha'), current_date);

        if v_row->>'id' is not null
           and v_row->>'id' ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
           and exists (select 1 from abonos_compras where abono_origen_id = (v_row->>'id')::uuid) then
            v_duplicados := v_duplicados + 1;
            continue;
        end if;

        insert into abonos_compras (compra_proveedor_id, monto, fecha, abono_origen_id, sucursal_id)
        select v_compra_id, v_monto, v_fecha,
               case when v_row->>'id' ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
                    then (v_row->>'id')::uuid
                    else null end,
               coalesce(sucursal_id, '00000000-0000-0000-0000-000000000001')
        from compras_proveedores
        where id = v_compra_id;

        v_aplicados := v_aplicados + 1;
    end loop;

    return jsonb_build_object(
        'ok', true,
        'aplicados', v_aplicados,
        'no_encontrados', v_no_encontrados,
        'duplicados', v_duplicados,
        'descartados', v_descartados
    );
end;
$$;

grant execute on function importar_abonos_masiva(jsonb, uuid) to anon, authenticated;

-- ------------------------------------------------------------
-- 6. IMPORTACIÓN MASIVA #3 — Facturas de VENTA históricas
--    Cada fila: numero, fecha, cliente, total. Se insertan como
--    ventas resumen (sin detalle ni descuento de stock, porque
--    ya ocurrió en la plataforma anterior). No duplica por numero.
--    Se asignan a la sucursal destino.
-- ------------------------------------------------------------
create or replace function importar_ventas_historicas(p_rows jsonb, p_sucursal_id uuid default null, p_sucursal_nombre text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_casa uuid := '00000000-0000-0000-0000-000000000001';
    v_sucursal uuid;
    v_sucursal_nombre text;
    v_row jsonb;
    v_numero text;
    v_total numeric;
    v_insertadas int := 0;
    v_duplicadas int := 0;
    v_descartadas int := 0;
begin
    if p_rows is null or jsonb_typeof(p_rows) <> 'array' then
        return jsonb_build_object('ok', false, 'error', 'Debes enviar un array JSON');
    end if;

    v_sucursal := coalesce(p_sucursal_id, v_casa);
    v_sucursal_nombre := nullif(coalesce(p_sucursal_nombre, ''), '');
    if v_sucursal_nombre is null then
        select coalesce(nombre, 'Casa Matriz') into v_sucursal_nombre
        from sucursales where id = v_sucursal;
        v_sucursal_nombre := coalesce(v_sucursal_nombre, 'Casa Matriz');
    end if;

    for v_row in select value from jsonb_array_elements(p_rows)
    loop
        v_numero := trim(coalesce(v_row->>'numero', ''));
        v_total := greatest(coalesce(numero_valido(v_row->>'total'), 0), 0);
        if v_numero = '' or v_total = 0 then
            v_descartadas := v_descartadas + 1;
            continue;
        end if;

        if exists (select 1 from ventas where numero = v_numero) then
            v_duplicadas := v_duplicadas + 1;
            continue;
        end if;

        insert into ventas
            (numero, cliente_nombre, cliente_rif, subtotal, iva, total_usd,
             tasa_bcv, total_bs, metodo_pago, estado, sucursal_id, sucursal_nombre,
             created_at)
        values
            (v_numero,
             case when coalesce(trim(coalesce(v_row->>'cliente', '')), '') = ''
                  then 'Consumidor Final'
                  else nullif(trim(coalesce(v_row->>'cliente', '')), '')
             end,
             null,
             v_total,
             0,
             v_total,
             0,
             0,
             'contado',
             'completada',
             v_sucursal,
             v_sucursal_nombre,
             coalesce(fecha_valida(v_row->>'fecha'), current_date)::timestamptz);

        v_insertadas := v_insertadas + 1;
    end loop;

    return jsonb_build_object(
        'ok', true,
        'insertadas', v_insertadas,
        'duplicadas', v_duplicadas,
        'descartadas', v_descartadas
    );
end;
$$;

grant execute on function importar_ventas_historicas(jsonb, uuid, text) to anon, authenticated;

-- ------------------------------------------------------------
-- 7. Abonar una compra desde el módulo (transacción atómica)
--    Si se pasa p_sucursal_id, valida que la factura pertenezca
--    a esa sucursal antes de aplicar el abono.
-- ------------------------------------------------------------
create or replace function aplicar_abono_cxp(p_compra_id uuid, p_monto numeric, p_fecha date, p_sucursal_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_id uuid;
    v_sucursal uuid;
    v_saldo numeric;
begin
    if p_monto is null or p_monto <= 0 then
        return jsonb_build_object('ok', false, 'error', 'El monto del abono debe ser mayor a 0');
    end if;

    select id, coalesce(sucursal_id, '00000000-0000-0000-0000-000000000001')
    into v_id, v_sucursal
    from compras_proveedores where id = p_compra_id for update;

    if v_id is null then
        return jsonb_build_object('ok', false, 'error', 'Factura no encontrada');
    end if;

    if p_sucursal_id is not null and v_sucursal <> p_sucursal_id then
        return jsonb_build_object('ok', false, 'error', 'La factura pertenece a otra sucursal');
    end if;

    insert into abonos_compras (compra_proveedor_id, monto, fecha, sucursal_id)
    values (p_compra_id, p_monto, coalesce(p_fecha, current_date), v_sucursal);

    select greatest(coalesce(monto_usd, 0) - (coalesce(monto_abonado, 0) + p_monto), 0)
    into v_saldo
    from compras_proveedores
    where id = p_compra_id;

    update compras_proveedores
    set monto_abonado = coalesce(monto_abonado, 0) + p_monto,
        saldo_pendiente = v_saldo,
        fecha_pago = case when v_saldo <= 0.005 then coalesce(fecha_pago, p_fecha) else fecha_pago end,
        estado = case when v_saldo <= 0.005 then 'Pagada' else 'Pendiente' end
    where id = p_compra_id;

    return jsonb_build_object('ok', true, 'saldo_pendiente', v_saldo);
end;
$$;

grant execute on function aplicar_abono_cxp(uuid, numeric, date, uuid) to anon, authenticated;
