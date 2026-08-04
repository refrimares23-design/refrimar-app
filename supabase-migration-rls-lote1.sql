-- ============================================================
-- RLS LOTES 1 — REFRIMAR OS
-- Cierra la escritura directa (anon key) en las tablas de
-- acceso y dinero: usuarios, configuracion, clientes,
-- caja_movimientos, pagos_moviles.
-- ------------------------------------------------------------
-- Toda escritura pasa por funciones RPC SECURITY DEFINER que:
--   - validan los datos (nunca aceptan valores basura),
--   - ejecutan como el dueño de la BD (saltan RLS),
--   - dejan la anon key SOLO con lectura (SELECT).
-- Si un tercero extrae la anon key del código fuente, NO podrá
-- borrar clientes, cambiar roles/PINs, forjar movimientos de
-- caja ni alterar la configuración directamente.
--
-- Cómo aplicar:
-- 1. Supabase → SQL Editor → New query
-- 2. Pega TODO este archivo y presiona "Run"
-- 3. Es seguro volver a correrlo (usa DROP POLICY IF EXISTS y
--    CREATE OR REPLACE FUNCTION).
-- ============================================================

-- ============================================================
-- 1. USUARIOS (acceso y permisos del sistema)
-- ============================================================

create or replace function usuario_guardar(
    p_nombre text,
    p_id uuid default null,
    p_pin text default null,
    p_rol text default null,
    p_activo boolean default true,
    p_permisos jsonb default '[]'
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
    v_id uuid;
begin
    if p_nombre is null or trim(p_nombre) = '' then
        raise exception 'El nombre es obligatorio';
    end if;
    if p_rol is null or trim(p_rol) = '' then
        p_rol := 'cajero';
    end if;
    if p_permisos is null then
        p_permisos := '[]';
    end if;

    if p_id is null then
        -- Crear: el PIN es obligatorio
        if p_pin is null or length(trim(p_pin)) = 0 then
            raise exception 'El PIN es obligatorio para nuevos usuarios';
        end if;
        insert into usuarios (nombre, pin, rol, activo, permisos)
        values (trim(p_nombre), p_pin, p_rol, p_activo, p_permisos)
        returning id into v_id;
    else
        -- Editar: el PIN es opcional (si viene, se actualiza)
        if p_pin is not null and length(trim(p_pin)) > 0 then
            update usuarios
            set nombre = trim(p_nombre), pin = p_pin, rol = p_rol,
                activo = p_activo, permisos = p_permisos
            where id = p_id;
        else
            update usuarios
            set nombre = trim(p_nombre), rol = p_rol,
                activo = p_activo, permisos = p_permisos
            where id = p_id;
        end if;
        v_id := p_id;
    end if;

    if v_id is null then
        raise exception 'No se pudo guardar el usuario';
    end if;
    return v_id;
end;
$$;

create or replace function usuario_cambiar_estado(p_id uuid, p_activo boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
    if p_id is null then
        raise exception 'Falta el usuario';
    end if;
    update usuarios set activo = coalesce(p_activo, true) where id = p_id;
end;
$$;

create or replace function usuario_eliminar(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
    if p_id is null then
        raise exception 'Falta el usuario';
    end if;
    delete from usuarios where id = p_id;
end;
$$;

-- ============================================================
-- 2. CONFIGURACION (datos del negocio y tasa BCV)
-- ============================================================

create or replace function config_guardar(
    p_nombre_negocio text,
    p_rif text default null,
    p_direccion text default null,
    p_telefono text default null,
    p_email text default null,
    p_mensaje text default null,
    p_tasa_bcv_manual numeric default 36.50,
    p_iva_incluido boolean default false
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
    v_id uuid;
begin
    if p_nombre_negocio is null or trim(p_nombre_negocio) = '' then
        raise exception 'El nombre del negocio es obligatorio';
    end if;
    -- La configuración es una sola fila: si existe se actualiza,
    -- si no, se crea.
    select id into v_id from configuracion limit 1;

    if v_id is null then
        insert into configuracion (nombre_negocio, rif, direccion, telefono, email,
            mensaje_agradecimiento, tasa_bcv_manual, iva_incluido, updated_at)
        values (p_nombre_negocio, p_rif, p_direccion, p_telefono, p_email,
            p_mensaje, p_tasa_bcv_manual, p_iva_incluido, now())
        returning id into v_id;
    else
        update configuracion
        set nombre_negocio = p_nombre_negocio, rif = p_rif, direccion = p_direccion,
            telefono = p_telefono, email = p_email, mensaje_agradecimiento = p_mensaje,
            tasa_bcv_manual = p_tasa_bcv_manual, iva_incluido = p_iva_incluido,
            updated_at = now()
        where id = v_id;
    end if;

    if v_id is null then
        raise exception 'No se pudo guardar la configuración';
    end if;
    return v_id;
end;
$$;

create or replace function config_actualizar_tasa(p_tasa numeric)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
    v_id uuid;
begin
    if p_tasa is null or p_tasa <= 0 then
        raise exception 'Tasa inválida';
    end if;
    select id into v_id from configuracion limit 1;
    if v_id is null then
        insert into configuracion (nombre_negocio, tasa_bcv_manual, iva_incluido, updated_at)
        values ('REFRIMAR', p_tasa, false, now());
    else
        update configuracion set tasa_bcv_manual = p_tasa, updated_at = now() where id = v_id;
    end if;
end;
$$;

-- ============================================================
-- 3. CLIENTES (cuentas por cobrar)
-- ============================================================

create or replace function cliente_guardar(
    p_nombre text,
    p_id uuid default null,
    p_rif text default null,
    p_telefono text default null,
    p_email text default null,
    p_direccion text default null,
    p_tipo text default 'final',
    p_limite_credito numeric default 0,
    p_notas text default null
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
            limite_credito, notas)
        values (trim(p_nombre), p_rif, p_telefono, p_email, p_direccion,
            coalesce(p_tipo, 'final'), p_limite_credito, p_notas)
        returning id into v_id;
    else
        update clientes
        set nombre = trim(p_nombre), rif = p_rif, telefono = p_telefono,
            email = p_email, direccion = p_direccion, tipo = coalesce(p_tipo, 'final'),
            limite_credito = p_limite_credito, notas = p_notas
        where id = p_id;
        v_id := p_id;
    end if;

    if v_id is null then
        raise exception 'No se pudo guardar el cliente';
    end if;
    return v_id;
end;
$$;

create or replace function cliente_eliminar(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
    if p_id is null then
        raise exception 'Falta el cliente';
    end if;
    delete from clientes where id = p_id;
end;
$$;

-- Abono de un cliente: descuenta el saldo Y registra el ingreso de
-- caja en UNA SOLA transacción (antes eran 2 llamadas sueltas que
-- podían quedar a medias si fallaba la red).
create or replace function cliente_registrar_abono(
    p_cliente_id uuid,
    p_monto numeric,
    p_sucursal_id uuid,
    p_usuario text
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
    v_saldo numeric;
    v_nombre text;
begin
    if p_cliente_id is null or p_monto is null or p_monto <= 0 then
        raise exception 'Faltan datos del abono';
    end if;

    select saldo_pendiente, nombre into v_saldo, v_nombre
    from clientes where id = p_cliente_id for update;

    if not found then
        raise exception 'Cliente no encontrado';
    end if;

    v_saldo := coalesce(v_saldo, 0) - p_monto;
    if v_saldo < 0 then v_saldo := 0; end if;

    update clientes set saldo_pendiente = v_saldo where id = p_cliente_id;

    insert into caja_movimientos (tipo, concepto, monto_usd, monto_bs,
        sucursal_id, usuario_nombre, metodo_pago)
    values ('ingreso', 'Abono de cliente ' || coalesce(v_nombre, '') || ' (saldo $' ||
            to_char(p_monto, 'FM999999999999990.00') || ')',
            p_monto, null, p_sucursal_id, coalesce(p_usuario, 'Sistema'), 'efectivo');
end;
$$;

-- ============================================================
-- 4. CAJA (movimientos manuales y cierre)
-- ============================================================

create or replace function caja_registrar_movimiento(
    p_tipo text,
    p_concepto text,
    p_sucursal_id uuid,
    p_monto_usd numeric default 0,
    p_monto_bs numeric default 0,
    p_usuario text default 'Sistema',
    p_notas text default null,
    p_metodo_pago text default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
    if p_tipo is null or trim(p_tipo) = '' then
        raise exception 'Falta el tipo de movimiento';
    end if;
    if p_concepto is null or trim(p_concepto) = '' then
        raise exception 'El concepto es obligatorio';
    end if;
    if p_monto_usd is null then p_monto_usd := 0; end if;
    if p_monto_bs is null then p_monto_bs := 0; end if;
    if p_monto_usd = 0 and p_monto_bs = 0 then
        raise exception 'Ingresa al menos un monto';
    end if;

    insert into caja_movimientos (tipo, concepto, monto_usd, monto_bs,
        sucursal_id, usuario_nombre, notas, metodo_pago)
    values (trim(p_tipo), trim(p_concepto), p_monto_usd, p_monto_bs,
        p_sucursal_id, coalesce(p_usuario, 'Sistema'), p_notas, p_metodo_pago);
end;
$$;

-- ============================================================
-- 5. PAGOS MOVILES (registro de pagos recibidos)
-- ============================================================

create or replace function pago_movil_registrar(
    p_banco text,
    p_remitente text,
    p_monto numeric,
    p_sucursal_id uuid,
    p_referencia text default null,
    p_usuario text default 'Sistema'
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
    if p_banco is null or trim(p_banco) = '' then
        raise exception 'El banco es obligatorio';
    end if;
    if p_remitente is null or trim(p_remitente) = '' then
        raise exception 'El remitente es obligatorio';
    end if;
    if p_monto is null or p_monto <= 0 then
        raise exception 'El monto debe ser mayor a 0';
    end if;

    insert into pagos_moviles (banco, remitente, monto, referencia,
        sucursal_id, usuario_nombre)
    values (trim(p_banco), trim(p_remitente), p_monto, p_referencia,
        p_sucursal_id, coalesce(p_usuario, 'Sistema'));
end;
$$;

-- ============================================================
-- 6. RLS: habilitar y dejar SOLO lectura a anon/authenticated
-- ============================================================

alter table usuarios enable row level security;
alter table configuracion enable row level security;
alter table clientes enable row level security;
alter table caja_movimientos enable row level security;
alter table pagos_moviles enable row level security;

drop policy if exists "usuarios_select" on usuarios;
create policy "usuarios_select" on usuarios for select using (true);

drop policy if exists "configuracion_select" on configuracion;
create policy "configuracion_select" on configuracion for select using (true);

drop policy if exists "clientes_select" on clientes;
create policy "clientes_select" on clientes for select using (true);

drop policy if exists "caja_movimientos_select" on caja_movimientos;
create policy "caja_movimientos_select" on caja_movimientos for select using (true);

drop policy if exists "pagos_moviles_select" on pagos_moviles;
create policy "pagos_moviles_select" on pagos_moviles for select using (true);

-- Revoca escritura directa a los roles que usa la app (anon).
-- Las funciones SECURITY DEFINER siguen escribiendo porque su rol
-- ejecutor es el dueño de las tablas (postgres).
revoke insert, update, delete on usuarios from anon, authenticated;
revoke insert, update, delete on configuracion from anon, authenticated;
revoke insert, update, delete on clientes from anon, authenticated;
revoke insert, update, delete on caja_movimientos from anon, authenticated;
revoke insert, update, delete on pagos_moviles from anon, authenticated;

grant select on usuarios, configuracion, clientes, caja_movimientos, pagos_moviles to anon, authenticated;

-- ============================================================
-- 7. Permitir ejecutar las RPCs a anon (la usa el navegador)
-- ============================================================

grant execute on function usuario_guardar(text, uuid, text, text, boolean, jsonb) to anon, authenticated;
grant execute on function usuario_cambiar_estado(uuid, boolean) to anon, authenticated;
grant execute on function usuario_eliminar(uuid) to anon, authenticated;
grant execute on function config_guardar(text, text, text, text, text, text, numeric, boolean) to anon, authenticated;
grant execute on function config_actualizar_tasa(numeric) to anon, authenticated;
grant execute on function cliente_guardar(text, uuid, text, text, text, text, text, numeric, text) to anon, authenticated;
grant execute on function cliente_eliminar(uuid) to anon, authenticated;
grant execute on function cliente_registrar_abono(uuid, numeric, uuid, text) to anon, authenticated;
grant execute on function caja_registrar_movimiento(text, text, uuid, numeric, numeric, text, text, text) to anon, authenticated;
grant execute on function pago_movil_registrar(text, text, numeric, uuid, text, text) to anon, authenticated;
