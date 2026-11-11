-- ============================================================
-- HORARIOS Y ASISTENCIA DEL PERSONAL
-- ------------------------------------------------------------
-- • Horario semanal de cada colaborador por tienda (entrada, salida y almuerzo).
--   Si alguien rota (semana A / semana B) se guardan las dos semanas.
-- • Asistencia: cada quien marca con su PIN entrada, salida a almorzar,
--   regreso y salida (desde cualquier computadora o teléfono de la tienda).
-- • Reporte: horas trabajadas, llegadas tarde y ausencias.
-- Horas en hora de Venezuela. No toca datos existentes. Se puede correr varias veces.
-- ============================================================

create table if not exists horario_personas (
    usuario_id uuid primary key,
    usuario_nombre text,
    sucursal_id uuid,                         -- tienda donde trabaja normalmente
    rota boolean not null default false,      -- true = alterna semana A y semana B
    semana_base date,                         -- un lunes que es "semana A"
    tolerancia_min int not null default 10,   -- minutos de gracia para la llegada
    actualizado_at timestamptz not null default now()
);

create table if not exists horarios_personal (
    id uuid primary key default gen_random_uuid(),
    usuario_id uuid not null,
    semana char(1) not null default 'A' check (semana in ('A', 'B')),
    dia smallint not null check (dia between 0 and 6),   -- 0 = domingo … 6 = sábado
    entrada time not null,
    salida time not null,
    almuerzo_ini time,
    almuerzo_fin time,
    sucursal_id uuid,
    unique (usuario_id, semana, dia)
);

create table if not exists asistencias (
    id uuid primary key default gen_random_uuid(),
    usuario_id uuid not null,
    usuario_nombre text,
    sucursal_id uuid,
    sucursal_nombre text,
    fecha date not null,
    entrada_at timestamptz,
    almuerzo_ini_at timestamptz,
    almuerzo_fin_at timestamptz,
    salida_at timestamptz,
    notas text,
    editado_por text,
    editado_at timestamptz,
    creado_at timestamptz not null default now(),
    unique (usuario_id, fecha)
);
create index if not exists idx_asistencias_fecha on asistencias (fecha desc);

do $$ declare t text; begin
    foreach t in array array['horario_personas', 'horarios_personal', 'asistencias'] loop
        execute format('alter table %I enable row level security', t);
        execute format('drop policy if exists %I on %I', t || '_select', t);
        execute format('create policy %I on %I for select using (true)', t || '_select', t);
        execute format('revoke insert, update, delete on %I from anon, authenticated', t);
        execute format('grant select on %I to anon, authenticated', t);
    end loop;
end $$;

-- Semana A o B que le toca a una persona en una fecha
create or replace function horario_semana(p_usuario uuid, p_fecha date)
returns char(1) language sql stable security definer set search_path = public as $$
    select case when hp.rota and hp.semana_base is not null
                     and (((p_fecha - date_trunc('week', hp.semana_base)::date) / 7) % 2) <> 0
                then 'B' else 'A' end
    from (select 1) x left join horario_personas hp on hp.usuario_id = p_usuario
$$;

-- Guarda el horario completo de una persona (reemplaza el anterior)
-- p_filas: [{semana:'A', dia:1, entrada:'08:00', salida:'17:00', almuerzo_ini:'12:00', almuerzo_fin:'13:00', sucursal_id:null}, …]
create or replace function horario_guardar(p_usuario_id uuid, p_sucursal_id uuid, p_rota boolean, p_semana_base date, p_tolerancia int, p_filas jsonb)
returns jsonb
language plpgsql security definer
set search_path = public
as $$
declare u record; f jsonb; n int := 0; v_ent time; v_sal time;
begin
    select id, nombre into u from usuarios where id = p_usuario_id;
    if not found then raise exception 'Ese colaborador no existe.'; end if;
    if jsonb_typeof(coalesce(p_filas, '[]'::jsonb)) <> 'array' then raise exception 'Horario inválido'; end if;
    insert into horario_personas (usuario_id, usuario_nombre, sucursal_id, rota, semana_base, tolerancia_min, actualizado_at)
    values (u.id, u.nombre, p_sucursal_id, coalesce(p_rota, false), p_semana_base, greatest(0, least(coalesce(p_tolerancia, 10), 120)), now())
    on conflict (usuario_id) do update set usuario_nombre = excluded.usuario_nombre, sucursal_id = excluded.sucursal_id, rota = excluded.rota,
        semana_base = excluded.semana_base, tolerancia_min = excluded.tolerancia_min, actualizado_at = now();
    delete from horarios_personal where usuario_id = u.id;
    for f in select value from jsonb_array_elements(coalesce(p_filas, '[]'::jsonb)) loop
        v_ent := nullif(f ->> 'entrada', '')::time; v_sal := nullif(f ->> 'salida', '')::time;
        if v_ent is null or v_sal is null then continue; end if;   -- día libre
        if v_sal <= v_ent then raise exception 'La salida (%) debe ser después de la entrada (%).', to_char(v_sal, 'HH12:MI AM'), to_char(v_ent, 'HH12:MI AM'); end if;
        insert into horarios_personal (usuario_id, semana, dia, entrada, salida, almuerzo_ini, almuerzo_fin, sucursal_id)
        values (u.id, case when coalesce(p_rota, false) and f ->> 'semana' = 'B' then 'B' else 'A' end, (f ->> 'dia')::smallint, v_ent, v_sal,
                nullif(f ->> 'almuerzo_ini', '')::time, nullif(f ->> 'almuerzo_fin', '')::time, nullif(f ->> 'sucursal_id', '')::uuid)
        on conflict (usuario_id, semana, dia) do update set entrada = excluded.entrada, salida = excluded.salida,
            almuerzo_ini = excluded.almuerzo_ini, almuerzo_fin = excluded.almuerzo_fin, sucursal_id = excluded.sucursal_id;
        n := n + 1;
    end loop;
    return jsonb_build_object('ok', true, 'dias', n);
end;
$$;

-- Marcar asistencia con PIN (sirve en la computadora de la tienda sin entrar al sistema)
-- p_pin: el PIN cifrado igual que en el inicio de sesión. p_tipo: entrada | almuerzo | regreso | salida | auto
create or replace function asistencia_marcar(p_nombre text, p_pin text, p_tipo text, p_sucursal_id uuid default null)
returns jsonb
language plpgsql security definer
set search_path = public
as $$
declare
    v_clave text := 'asis:' || lower(trim(coalesce(p_nombre, '')));
    li login_intentos; u record; a asistencias; v_hoy date := (now() at time zone 'America/Caracas')::date;
    v_tipo text := lower(coalesce(p_tipo, 'auto')); v_suc uuid; v_suc_nombre text; v_hora text;
begin
    select * into li from login_intentos where clave = v_clave;
    if found and li.bloqueado_hasta is not null and li.bloqueado_hasta > now() then
        return jsonb_build_object('ok', false, 'error', 'Demasiados intentos. Espera unos minutos.');
    end if;
    select * into u from usuarios where nombre = p_nombre and activo is not false limit 1;
    if not found or u.pin is null or u.pin <> coalesce(p_pin, '') then
        insert into login_intentos (clave, fallos, actualizado_at) values (v_clave, 1, now())
        on conflict (clave) do update set
            fallos = case when login_intentos.actualizado_at < now() - interval '30 minutes' then 1 else login_intentos.fallos + 1 end,
            actualizado_at = now()
        returning * into li;
        if li.fallos >= 5 and li.fallos % 5 = 0 then
            update login_intentos set bloqueado_hasta = now() + interval '5 minutes' where clave = v_clave;
        end if;
        return jsonb_build_object('ok', false, 'error', 'PIN incorrecto');
    end if;
    delete from login_intentos where clave = v_clave;

    v_suc := coalesce(p_sucursal_id, (select sucursal_id from horario_personas where usuario_id = u.id), '00000000-0000-0000-0000-000000000001');
    v_suc_nombre := case when v_suc = '00000000-0000-0000-0000-000000000001' then 'Casa Matriz' else (select nombre from sucursales where id = v_suc) end;

    select * into a from asistencias where usuario_id = u.id and fecha = v_hoy;
    if v_tipo = 'auto' then
        v_tipo := case when a.id is null or a.entrada_at is null then 'entrada'
                       when a.salida_at is not null then 'ya'
                       when a.almuerzo_ini_at is null then 'almuerzo'
                       when a.almuerzo_fin_at is null then 'regreso'
                       else 'salida' end;
    end if;
    if v_tipo = 'ya' then
        return jsonb_build_object('ok', false, 'error', u.nombre || ', ya marcaste tu salida de hoy a las ' || to_char(a.salida_at at time zone 'America/Caracas', 'HH12:MI AM') || '.');
    end if;

    if a.id is null then
        if v_tipo <> 'entrada' then return jsonb_build_object('ok', false, 'error', 'Primero marca tu entrada.'); end if;
        insert into asistencias (usuario_id, usuario_nombre, sucursal_id, sucursal_nombre, fecha, entrada_at)
        values (u.id, u.nombre, v_suc, v_suc_nombre, v_hoy, now()) returning * into a;
    else
        if v_tipo = 'entrada' then
            if a.entrada_at is not null then return jsonb_build_object('ok', false, 'error', 'Ya marcaste tu entrada hoy a las ' || to_char(a.entrada_at at time zone 'America/Caracas', 'HH12:MI AM') || '.'); end if;
            update asistencias set entrada_at = now() where id = a.id returning * into a;
        elsif v_tipo = 'almuerzo' then
            if a.almuerzo_ini_at is not null then return jsonb_build_object('ok', false, 'error', 'Ya marcaste tu salida a almorzar.'); end if;
            if a.salida_at is not null then return jsonb_build_object('ok', false, 'error', 'Ya marcaste tu salida de hoy.'); end if;
            update asistencias set almuerzo_ini_at = now() where id = a.id returning * into a;
        elsif v_tipo = 'regreso' then
            if a.almuerzo_ini_at is null then return jsonb_build_object('ok', false, 'error', 'No has marcado la salida a almorzar.'); end if;
            if a.almuerzo_fin_at is not null then return jsonb_build_object('ok', false, 'error', 'Ya marcaste tu regreso del almuerzo.'); end if;
            update asistencias set almuerzo_fin_at = now() where id = a.id returning * into a;
        elsif v_tipo = 'salida' then
            if a.salida_at is not null then return jsonb_build_object('ok', false, 'error', 'Ya marcaste tu salida de hoy.'); end if;
            update asistencias set salida_at = now(), almuerzo_fin_at = case when almuerzo_ini_at is not null and almuerzo_fin_at is null then now() else almuerzo_fin_at end
            where id = a.id returning * into a;
        else
            raise exception 'Tipo de marca inválido';
        end if;
    end if;
    v_hora := to_char(now() at time zone 'America/Caracas', 'HH12:MI AM');
    return jsonb_build_object('ok', true, 'nombre', u.nombre, 'tipo', v_tipo, 'hora', v_hora, 'tienda', v_suc_nombre,
        'mensaje', case v_tipo when 'entrada' then '¡Buen día, ' || u.nombre || '! Entrada a las ' || v_hora
                               when 'almuerzo' then 'Buen provecho, ' || u.nombre || '. Salida a almorzar a las ' || v_hora
                               when 'regreso' then 'Bienvenido de vuelta, ' || u.nombre || '. Regreso a las ' || v_hora
                               else 'Hasta mañana, ' || u.nombre || '. Salida a las ' || v_hora end);
end;
$$;

-- Corregir una marca (olvidó marcar, marcó mal…). p_datos: {entrada:'08:05', almuerzo_ini, almuerzo_fin, salida, notas} en hora de Venezuela
create or replace function asistencia_ajustar(p_usuario_id uuid, p_fecha date, p_datos jsonb, p_editor text default null)
returns jsonb
language plpgsql security definer
set search_path = public
as $$
declare u record; v_id uuid;
begin
    select id, nombre into u from usuarios where id = p_usuario_id;
    if not found then raise exception 'Ese colaborador no existe.'; end if;
    insert into asistencias (usuario_id, usuario_nombre, fecha, sucursal_id, sucursal_nombre)
    values (u.id, u.nombre, p_fecha, coalesce((select sucursal_id from horario_personas where usuario_id = u.id), '00000000-0000-0000-0000-000000000001'), null)
    on conflict (usuario_id, fecha) do nothing;
    update asistencias set
        entrada_at      = case when p_datos ? 'entrada'      then (p_fecha + nullif(p_datos ->> 'entrada', '')::time) at time zone 'America/Caracas' else entrada_at end,
        almuerzo_ini_at = case when p_datos ? 'almuerzo_ini' then (p_fecha + nullif(p_datos ->> 'almuerzo_ini', '')::time) at time zone 'America/Caracas' else almuerzo_ini_at end,
        almuerzo_fin_at = case when p_datos ? 'almuerzo_fin' then (p_fecha + nullif(p_datos ->> 'almuerzo_fin', '')::time) at time zone 'America/Caracas' else almuerzo_fin_at end,
        salida_at       = case when p_datos ? 'salida'       then (p_fecha + nullif(p_datos ->> 'salida', '')::time) at time zone 'America/Caracas' else salida_at end,
        notas           = case when p_datos ? 'notas'        then nullif(trim(p_datos ->> 'notas'), '') else notas end,
        sucursal_nombre = coalesce(sucursal_nombre, case when sucursal_id = '00000000-0000-0000-0000-000000000001' then 'Casa Matriz' else (select nombre from sucursales where id = sucursal_id) end),
        editado_por = p_editor, editado_at = now()
    where usuario_id = u.id and fecha = p_fecha returning id into v_id;
    return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

-- Resumen por persona y día (horario esperado vs. lo marcado)
create or replace function asistencia_resumen(p_desde date, p_hasta date)
returns table (usuario_id uuid, usuario_nombre text, fecha date, semana char(1), sucursal_id uuid,
               entrada_esperada time, salida_esperada time, almuerzo_ini time, almuerzo_fin time,
               entrada_at timestamptz, almuerzo_ini_at timestamptz, almuerzo_fin_at timestamptz, salida_at timestamptz,
               minutos_tarde int, horas_trabajadas numeric, estado text, notas text)
language sql stable security definer
set search_path = public
as $$
    with dias as (select d::date as fecha from generate_series(p_desde, least(p_hasta, p_desde + 92), interval '1 day') d),
    gente as (
        select u.id, u.nombre from usuarios u
        where u.activo is not false and (exists (select 1 from horarios_personal h where h.usuario_id = u.id)
                                         or exists (select 1 from asistencias a where a.usuario_id = u.id and a.fecha between p_desde and p_hasta))
    ),
    base as (
        select g.id, g.nombre, d.fecha, horario_semana(g.id, d.fecha) as semana
        from gente g cross join dias d
    )
    select b.id, b.nombre, b.fecha, b.semana, coalesce(h.sucursal_id, hp.sucursal_id, a.sucursal_id),
           h.entrada, h.salida, h.almuerzo_ini, h.almuerzo_fin,
           a.entrada_at, a.almuerzo_ini_at, a.almuerzo_fin_at, a.salida_at,
           case when h.entrada is not null and a.entrada_at is not null
                then greatest(0, floor(extract(epoch from ((a.entrada_at at time zone 'America/Caracas')::time - h.entrada)) / 60)::int
                                 - coalesce(hp.tolerancia_min, 10))::int end as minutos_tarde,
           case when a.entrada_at is not null and a.salida_at is not null
                then round((extract(epoch from (a.salida_at - a.entrada_at))
                            - coalesce(extract(epoch from (a.almuerzo_fin_at - a.almuerzo_ini_at)), 0)) / 3600.0, 2) end as horas_trabajadas,
           case when a.entrada_at is not null and a.salida_at is null and b.fecha < (now() at time zone 'America/Caracas')::date then 'sin_salida'
                when a.entrada_at is not null then 'asistio'
                when h.entrada is null then 'libre'
                when b.fecha > (now() at time zone 'America/Caracas')::date then 'pendiente'
                when b.fecha = (now() at time zone 'America/Caracas')::date and (now() at time zone 'America/Caracas')::time < h.entrada then 'pendiente'
                else 'ausente' end as estado,
           a.notas
    from base b
    left join horario_personas hp on hp.usuario_id = b.id
    left join horarios_personal h on h.usuario_id = b.id and h.semana = b.semana and h.dia = extract(dow from b.fecha)::int
    left join asistencias a on a.usuario_id = b.id and a.fecha = b.fecha
    order by b.fecha desc, b.nombre
$$;

grant execute on function horario_semana(uuid, date) to anon, authenticated;
grant execute on function horario_guardar(uuid, uuid, boolean, date, int, jsonb) to anon, authenticated;
grant execute on function asistencia_marcar(text, text, text, uuid) to anon, authenticated;
grant execute on function asistencia_ajustar(uuid, date, jsonb, text) to anon, authenticated;
grant execute on function asistencia_resumen(date, date) to anon, authenticated;

do $$ begin
    if to_regclass('public.seguridad_rpc') is not null then
        insert into seguridad_rpc (nombre, nivel, permiso) values
            ('horario_guardar', 'permiso', 'ver_equipo'),
            ('asistencia_ajustar', 'permiso', 'ver_equipo'),
            ('asistencia_resumen', 'sesion', null),
            ('horario_semana', 'publico', null),
            ('asistencia_marcar', 'publico', null)       -- se valida con el PIN de la persona
        on conflict (nombre) do update set nivel = excluded.nivel, permiso = excluded.permiso;
    end if;
end $$;

do $$ begin
    if to_regprocedure('saas.sincronizar_todas()') is not null then perform saas.sincronizar_todas(); end if;
end $$;
notify pgrst, 'reload schema';
select 'Horarios y asistencia listos' as resultado;
