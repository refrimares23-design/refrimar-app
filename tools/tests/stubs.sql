-- Lo mínimo de Supabase para que la estructura exportada cargue en un Postgres normal.
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then create role service_role nologin bypassrls; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticator') then create role authenticator nologin; end if;
end $$;
create schema if not exists auth;
create schema if not exists extensions;
create schema if not exists storage;
create or replace function auth.jwt() returns jsonb language sql stable as
  $$ select coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb $$;
create or replace function auth.uid() returns uuid language sql stable as
  $$ select nullif(auth.jwt() ->> 'sub', '')::uuid $$;
create or replace function auth.role() returns text language sql stable as
  $$ select coalesce(auth.jwt() ->> 'role', 'anon') $$;
grant usage on schema auth, extensions to anon, authenticated, service_role;

-- Multiempresa (esquema saas): en la copia de prueba no limita nada.
create schema if not exists saas;
create or replace function saas.limite_trg() returns trigger language plpgsql as $$ begin return coalesce(new, old); end $$;
create or replace function saas.directorio_trg() returns trigger language plpgsql as $$ begin return coalesce(new, old); end $$;
create or replace function saas.header(p text) returns text language sql stable as $$ select null::text $$;
create or replace function saas.es_superadmin() returns boolean language sql stable as $$ select false $$;
grant usage on schema saas to anon, authenticated, service_role;
