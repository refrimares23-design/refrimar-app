-- ============================================================
-- REFRIMAR — URGENTE (16-nov-2026): el PIN de los usuarios no se puede leer desde internet
--
-- Problema: la tabla "usuarios" se podía leer COMPLETA con la clave pública de la página,
-- incluida la columna "pin". Con eso alguien podría adivinar el PIN de un administrador.
-- (Un archivo viejo, supabase-migration-rls-lote1.sql, volvió a abrir la tabla entera.)
--
-- Arreglo: se quita el permiso de leer la tabla completa y se da columna por columna,
-- todas menos "pin". La página nunca lee el PIN (el login lo revisa dentro de la base),
-- así que nada deja de funcionar. También se cierra la función vieja login_usuario,
-- que dejaba probar PINs sin límite de intentos.
--
-- Supabase → SQL Editor → New query → pega TODO → Run. Se puede correr varias veces.
-- Para deshacerlo: grant select on public.usuarios to anon, authenticated;  (NO recomendado)
-- ============================================================

-- 1. Respaldo
create schema if not exists respaldo_inventario;
revoke all on schema respaldo_inventario from anon, authenticated, public;
do $$ begin
    if to_regclass('public.productos') is null then return; end if;
    execute format('create table if not exists respaldo_inventario.%I as table public.productos',
                   'productos_' || to_char(now() at time zone 'America/Caracas', 'YYYYMMDD_HH24MISS'));
end $$;

-- 2. Lectura de usuarios sin el PIN
do $$
declare v_cols text;
begin
    select string_agg(quote_ident(column_name), ', ' order by ordinal_position) into v_cols
    from information_schema.columns
    where table_schema = 'public' and table_name = 'usuarios' and column_name <> 'pin';
    execute 'revoke select on public.usuarios from anon, authenticated';
    execute format('grant select (%s) on public.usuarios to anon, authenticated', v_cols);
    -- Tampoco se puede vaciar ni modificar la tabla desde la página (todo va por funciones)
    execute 'revoke insert, update, delete, truncate, references, trigger on public.usuarios from anon, authenticated';
end $$;

-- 3. La función vieja login_usuario no tiene límite de intentos: se cierra.
--    El login usa sesion_iniciar_pin (que sí bloquea tras varios intentos fallidos).
do $$ begin
    if to_regprocedure('public.login_usuario(text,text)') is not null then
        execute 'revoke execute on function public.login_usuario(text, text) from public, anon, authenticated';
    end if;
end $$;

-- 4. Registro
create table if not exists public.migraciones_aplicadas (
    id bigserial primary key, nombre text not null unique, descripcion text, version_app text,
    aplicada_en timestamptz not null default now(), aplicada_por text not null default current_user
);
insert into public.migraciones_aplicadas (nombre, descripcion, version_app)
values ('2026-11-16-seguridad-pin', 'El PIN de usuarios deja de ser legible con la clave pública', 'v3.9.21')
on conflict (nombre) do nothing;

-- 5. Comprobación: deben salir false, false, true, false
select has_column_privilege('anon', 'public.usuarios', 'pin', 'select')          as anon_lee_pin,
       has_column_privilege('authenticated', 'public.usuarios', 'pin', 'select') as sesion_lee_pin,
       has_column_privilege('anon', 'public.usuarios', 'nombre', 'select')       as anon_lee_nombre,
       coalesce(has_function_privilege('anon', to_regprocedure('public.login_usuario(text,text)'), 'execute'), false) as login_viejo_abierto;
