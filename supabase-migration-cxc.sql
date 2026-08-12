-- ============================================================
-- MIGRACIÓN: CUENTAS POR COBRAR (CXC) — REFRIMAR OS
-- ------------------------------------------------------------
-- QUÉ HACE
--   1. Agrega a `ventas` las columnas de cobro: monto_abonado,
--      dias_credito y notas. Así las ventas hechas a CRÉDITO desde
--      Facturación se convierten automáticamente en deudas de
--      clientes (una sola fuente de la verdad).
--   2. Crea la tabla `abonos_ventas` (historial de pagos por deuda).
--   3. Crea las RPCs transaccionales (SECURITY DEFINER):
--        - deuda_venta_crear          → deuda manual desde la app
--        - deuda_venta_abonar         → abono parcial / total
--        - deuda_venta_pago_completo  → paga el saldo completo de golpe
--      Cada abono descuenta el saldo de la venta Y el saldo global
--      del cliente, y registra el ingreso en caja, todo en UNA sola
--      transacción.
--
-- CÓMO APLICAR (OBLIGATORIO ANTES DE DESPLEGAR)
--   1. Supabase → SQL Editor → New query
--   2. Pega TODO este archivo y presiona "Run"
--   3. Solo DESPUÉS despliega la app (npx wrangler deploy).
--
--   Es seguro correrlo varias veces (IF NOT EXISTS / OR REPLACE).
-- ============================================================

-- ------------------------------------------------------------
-- 1. Columnas nuevas en ventas
-- ------------------------------------------------------------
alter table ventas add column if not exists monto_abonado numeric(14,2) not null default 0;
alter table ventas add column if not exists dias_credito int not null default 30;
alter table ventas add column if not exists notas text;

-- ------------------------------------------------------------
-- 2. Tabla de abonos de deudas (ventas a crédito)
-- ------------------------------------------------------------
create table if not exists abonos_ventas (
    id uuid primary key default gen_random_uuid(),
    venta_id uuid not null references ventas(id) on delete cascade,
    monto numeric(14,2) not null,
    fecha date not null default current_date,
    metodo text default 'efectivo',
    usuario_nombre text,
    sucursal_id uuid,
    notas text,
    abono_origen_id uuid,
    created_at timestamptz default now()
);

create index if not exists idx_abonos_ventas_venta on abonos_ventas(venta_id);

-- ------------------------------------------------------------
-- 3. RPC: CREAR DEUDA MANUAL (venta a crédito sin artículos)
-- ------------------------------------------------------------
create or replace function deuda_venta_crear(
    p_cliente_id uuid,
    p_numero text default null,
    p_monto_usd numeric default 0,
    p_dias_credito int default 30,
    p_notas text default null,
    p_sucursal_id uuid default null,
    p_sucursal_nombre text default null,
    p_usuario text default 'Sistema'
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_nombre text;
    v_rif text;
    v_saldo numeric;
    v_limite numeric;
    v_venta_id uuid;
    v_numero text;
begin
    if p_cliente_id is null then
        raise exception 'Debes seleccionar un cliente';
    end if;
    if p_monto_usd is null or p_monto_usd <= 0 then
        raise exception 'El monto de la deuda debe ser mayor a 0';
    end if;
    if p_dias_credito is null or p_dias_credito < 1 then
        p_dias_credito := 30;
    end if;

    select nombre, rif, coalesce(saldo_pendiente, 0), coalesce(limite_credito, 0)
    into v_nombre, v_rif, v_saldo, v_limite
    from clientes where id = p_cliente_id for update;

    if not found then
        raise exception 'Cliente no encontrado';
    end if;

    if v_limite > 0 and v_saldo + p_monto_usd > v_limite then
        raise exception 'La deuda excede el límite de crédito del cliente (saldo: %, límite: %)',
            v_saldo, v_limite;
    end if;

    v_numero := nullif(trim(coalesce(p_numero, '')), '');
    if v_numero is null then
        v_numero := 'D-' || to_char(now(), 'YYYYMMDD') || '-' ||
                    lpad(floor(random() * 999999)::text, 6, '0');
    end if;

    insert into ventas (numero, cliente_nombre, cliente_rif, subtotal, iva, total_usd,
                        tasa_bcv, total_bs, metodo_pago, estado, sucursal_id, sucursal_nombre,
                        monto_abonado, dias_credito, notas)
    values (v_numero, v_nombre, v_rif, 0, 0, p_monto_usd, 0, 0, 'credito', 'completada',
            p_sucursal_id, p_sucursal_nombre, 0, p_dias_credito, p_notas)
    returning id into v_venta_id;

    update clientes set saldo_pendiente = v_saldo + p_monto_usd where id = p_cliente_id;

    return jsonb_build_object('ok', true, 'venta_id', v_venta_id, 'numero', v_numero);
end;
$$;

-- ------------------------------------------------------------
-- 4. RPC: ABONAR UNA DEUDA (descuenta saldo de venta + cliente,
--    y registra el ingreso de caja en una sola transacción)
-- ------------------------------------------------------------
create or replace function deuda_venta_abonar(
    p_venta_id uuid,
    p_monto numeric,
    p_fecha date default null,
    p_metodo text default 'efectivo',
    p_notas text default null,
    p_sucursal_id uuid default null,
    p_usuario text default 'Sistema'
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_cliente_rif text;
    v_cliente_nombre text;
    v_numero text;
    v_total numeric;
    v_abonado numeric;
    v_saldo numeric;
begin
    if p_monto is null or p_monto <= 0 then
        raise exception 'El monto del abono debe ser mayor a 0';
    end if;

    select cliente_rif, cliente_nombre, numero, coalesce(total_usd, 0), coalesce(monto_abonado, 0)
    into v_cliente_rif, v_cliente_nombre, v_numero, v_total, v_abonado
    from ventas
    where id = p_venta_id and metodo_pago = 'credito' and estado = 'completada'
    for update;

    if not found then
        raise exception 'Deuda no encontrada';
    end if;

    v_saldo := greatest(v_total - v_abonado, 0);
    if p_monto > v_saldo + 0.005 then
        raise exception 'El abono supera el saldo pendiente de la deuda (saldo: %)', v_saldo;
    end if;

    insert into abonos_ventas (venta_id, monto, fecha, metodo, usuario_nombre, sucursal_id, notas)
    values (p_venta_id, p_monto, coalesce(p_fecha, current_date),
            coalesce(p_metodo, 'efectivo'), coalesce(p_usuario, 'Sistema'),
            p_sucursal_id, p_notas);

    update ventas set monto_abonado = v_abonado + p_monto where id = p_venta_id;

    -- Reflejar el pago en el saldo global del cliente (por RIF).
    if v_cliente_rif is not null and v_cliente_rif <> '' then
        update clientes
        set saldo_pendiente = greatest(coalesce(saldo_pendiente, 0) - p_monto, 0)
        where rif = v_cliente_rif;
    end if;

    -- Ingreso de caja.
    insert into caja_movimientos (tipo, concepto, monto_usd, monto_bs,
        sucursal_id, usuario_nombre, metodo_pago)
    values ('ingreso',
            'Abono de cliente ' || coalesce(v_cliente_nombre, '') ||
            ' (deuda ' || coalesce(v_numero, '') || ')',
            p_monto, null, p_sucursal_id, coalesce(p_usuario, 'Sistema'),
            coalesce(p_metodo, 'efectivo'));

    return jsonb_build_object('ok', true, 'saldo_pendiente', greatest(v_saldo - p_monto, 0));
end;
$$;

-- ------------------------------------------------------------
-- 5. RPC: PAGO COMPLETO (abona el saldo restante de una sola vez)
-- ------------------------------------------------------------
create or replace function deuda_venta_pago_completo(
    p_venta_id uuid,
    p_fecha date default null,
    p_metodo text default 'efectivo',
    p_notas text default null,
    p_sucursal_id uuid default null,
    p_usuario text default 'Sistema'
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_monto numeric;
begin
    select greatest(coalesce(total_usd, 0) - coalesce(monto_abonado, 0), 0)
    into v_monto
    from ventas
    where id = p_venta_id and metodo_pago = 'credito' and estado = 'completada';

    if v_monto is null then
        raise exception 'Deuda no encontrada';
    end if;
    if v_monto <= 0.005 then
        return jsonb_build_object('ok', true, 'saldo_pendiente', 0, 'mensaje', 'La deuda ya está saldada');
    end if;

    return deuda_venta_abonar(p_venta_id, v_monto, p_fecha, p_metodo, p_notas,
                              p_sucursal_id, p_usuario);
end;
$$;

-- ------------------------------------------------------------
-- 6. RLS: abonos_ventas solo lectura para la app (escrituras por RPC)
-- ------------------------------------------------------------
alter table abonos_ventas enable row level security;

drop policy if exists "abonos_ventas_select" on abonos_ventas;
create policy "abonos_ventas_select" on abonos_ventas
    for select using (true);

revoke insert, update, delete on abonos_ventas from anon, authenticated;
grant select on abonos_ventas to anon, authenticated;

-- ------------------------------------------------------------
-- 7. Permitir ejecutar las RPCs a anon (las usa el navegador)
-- ------------------------------------------------------------
grant execute on function deuda_venta_crear(uuid, text, numeric, int, text, uuid, text, text) to anon, authenticated;
grant execute on function deuda_venta_abonar(uuid, numeric, date, text, text, uuid, text) to anon, authenticated;
grant execute on function deuda_venta_pago_completo(uuid, date, text, text, uuid, text) to anon, authenticated;
