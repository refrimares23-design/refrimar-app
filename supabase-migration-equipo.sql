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
