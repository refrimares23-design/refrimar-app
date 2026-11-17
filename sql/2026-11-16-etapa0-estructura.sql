-- ============================================================
-- REFRIMAR — Etapa 0 (16-nov-2026): foto de la estructura real de la base
--
-- Qué hace:
--   1. Respaldo de productos (como siempre, antes de tocar nada).
--   2. Crea la tabla migraciones_aplicadas: desde hoy, cada SQL que se corra
--      queda anotado ahí (nombre, fecha). Así se sabe qué versión está viva.
--   3. Muestra la ESTRUCTURA completa de la base (sin datos de clientes ni ventas):
--      tablas, columnas, reglas, índices, funciones, triggers, permisos y políticas.
--
-- Cómo usarlo:
--   Supabase → SQL Editor → New query → pega TODO → Run.
--   Abajo sale una tabla larga. Toca "Export" (o "Download CSV") y mándale ese
--   archivo CSV a Claude. NO trae datos de ventas, clientes ni contraseñas.
--
-- No borra ni cambia nada de lo que ya existe. Se puede correr varias veces.
-- ============================================================

-- 1. Respaldo
create schema if not exists respaldo_inventario;
revoke all on schema respaldo_inventario from anon, authenticated, public;
do $$ begin
    if to_regclass('public.productos') is null then return; end if;
    execute format('create table if not exists respaldo_inventario.%I as table public.productos',
                   'productos_' || to_char(now() at time zone 'America/Caracas', 'YYYYMMDD_HH24MISS'));
end $$;

-- 2. Registro de migraciones
create table if not exists public.migraciones_aplicadas (
    id bigserial primary key,
    nombre text not null unique,
    descripcion text,
    version_app text,
    aplicada_en timestamptz not null default now(),
    aplicada_por text not null default current_user
);
alter table public.migraciones_aplicadas enable row level security;
revoke all on table public.migraciones_aplicadas from anon, authenticated, public;
revoke all on sequence public.migraciones_aplicadas_id_seq from anon, authenticated, public;

insert into public.migraciones_aplicadas (nombre, descripcion, version_app)
values ('2026-11-16-etapa0-estructura', 'Registro de migraciones + foto de la estructura', 'v3.9.20')
on conflict (nombre) do nothing;

-- 3. Estructura (una fila por objeto; orden = orden para recrearla)
with
ext as (
    select 10 as orden, 'extension' as tipo, e.extname::text as nombre,
           format('create extension if not exists %I with schema %I;', e.extname, n.nspname) as ddl
    from pg_extension e join pg_namespace n on n.oid = e.extnamespace
    where e.extname <> 'plpgsql'
),
esquemas as (
    select 15, 'schema', n.nspname::text, format('create schema if not exists %I;', n.nspname)
    from pg_namespace n
    where n.nspname not in ('public', 'information_schema', 'pg_catalog', 'pg_toast')
      and n.nspname not like 'pg\_%' and n.nspname not like 'pg_temp%'
),
tipos as (
    select 20, 'enum', t.typname::text,
           format('create type %I.%I as enum (%s);', n.nspname, t.typname,
                  (select string_agg(quote_literal(e.enumlabel), ', ' order by e.enumsortorder) from pg_enum e where e.enumtypid = t.oid))
    from pg_type t join pg_namespace n on n.oid = t.typnamespace
    where t.typtype = 'e' and n.nspname = 'public'
),
secuencias as (
    select 30, 'sequence', c.relname::text, format('create sequence if not exists public.%I;', c.relname)
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where c.relkind = 'S' and n.nspname = 'public'
),
tablas as (
    select 40, 'table', c.relname::text,
           format(E'create table if not exists public.%I (\n%s\n);', c.relname,
                  (select string_agg(format('    %I %s%s%s', a.attname, format_type(a.atttypid, a.atttypmod),
                                            case when a.attnotnull then ' not null' else '' end,
                                            case when d.adbin is not null then ' default ' || pg_get_expr(d.adbin, d.adrelid) else '' end),
                                     E',\n' order by a.attnum)
                   from pg_attribute a left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
                   where a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped))
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where c.relkind in ('r', 'p') and n.nspname = 'public'
),
restricciones as (
    select case when con.contype = 'f' then 60 else 50 end, 'constraint', c.relname || '.' || con.conname,
           format('alter table public.%I add constraint %I %s;', c.relname, con.conname, pg_get_constraintdef(con.oid))
    from pg_constraint con join pg_class c on c.oid = con.conrelid join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and con.contype in ('p', 'u', 'c', 'f', 'x')
),
indices as (
    select 70, 'index', i.indexname::text, i.indexdef || ';'
    from pg_indexes i
    where i.schemaname = 'public'
      and not exists (select 1 from pg_constraint con where con.conname = i.indexname)
),
vistas as (
    select 80, 'view', c.relname::text, format(E'create or replace view public.%I as\n%s', c.relname, pg_get_viewdef(c.oid, true))
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where c.relkind in ('v', 'm') and n.nspname = 'public'
),
funciones as (
    select 90, 'function', p.oid::regprocedure::text, pg_get_functiondef(p.oid) || ';'
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prokind in ('f', 'p')
      and not exists (select 1 from pg_depend dp where dp.objid = p.oid and dp.deptype = 'e')
),
disparadores as (
    select 100, 'trigger', c.relname || '.' || t.tgname, pg_get_triggerdef(t.oid) || ';'
    from pg_trigger t join pg_class c on c.oid = t.tgrelid join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and not t.tgisinternal
),
rls as (
    select 110, 'rls', c.relname::text,
           format('alter table public.%I enable row level security;', c.relname)
           || case when c.relforcerowsecurity then format(' alter table public.%I force row level security;', c.relname) else '' end
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind in ('r', 'p') and c.relrowsecurity
),
politicas as (
    select 120, 'policy', p.tablename || '.' || p.policyname,
           format('create policy %I on public.%I as %s for %s to %s%s%s;', p.policyname, p.tablename, p.permissive, p.cmd,
                  array_to_string(p.roles, ', '),
                  case when p.qual is not null then ' using (' || p.qual || ')' else '' end,
                  case when p.with_check is not null then ' with check (' || p.with_check || ')' else '' end)
    from pg_policies p where p.schemaname = 'public'
),
permisos_tablas as (
    select 130, 'grant_table', g.table_name || ' → ' || g.grantee,
           format('grant %s on public.%I to %I;', string_agg(g.privilege_type, ', ' order by g.privilege_type), g.table_name, g.grantee)
    from information_schema.role_table_grants g
    where g.table_schema = 'public' and g.grantee in ('anon', 'authenticated', 'service_role')
    group by g.table_name, g.grantee
),
permisos_funciones as (
    select 140, 'grant_function', p.oid::regprocedure::text || ' → ' || coalesce(r.rolname, 'public'),
           format('grant execute on function %s to %s;', p.oid::regprocedure, coalesce(quote_ident(r.rolname), 'public'))
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
    left join pg_roles r on r.oid = a.grantee
    where n.nspname = 'public' and a.privilege_type = 'EXECUTE' and (a.grantee = 0 or r.rolname in ('anon', 'authenticated'))
      and not exists (select 1 from pg_depend dp where dp.objid = p.oid and dp.deptype = 'e')
),
tamanos as (
    select 900, 'filas_aprox', c.relname::text, format('-- %s: unas %s filas', c.relname, greatest(c.reltuples, 0)::bigint)
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where c.relkind in ('r', 'p') and n.nspname = 'public'
)
select orden, tipo, nombre, ddl from (
    select * from ext union all select * from esquemas union all select * from tipos union all
    select * from secuencias union all select * from tablas union all select * from restricciones union all
    select * from indices union all select * from vistas union all select * from funciones union all
    select * from disparadores union all select * from rls union all select * from politicas union all
    select * from permisos_tablas union all select * from permisos_funciones union all select * from tamanos
) x
order by orden, nombre;
