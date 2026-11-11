-- ============================================================
-- REGLAS DE LECTURA: las ventas vuelven a verse en Facturas, Tiendas en vivo y reportes
-- ------------------------------------------------------------
-- En tu base había reglas (policies) terminadas en "_auth" que solo dejan leer
-- a usuarios "authenticated" con una tienda dentro del token. El sistema no usa
-- ese tipo de token, así que esas tablas se veían vacías aunque los datos
-- estaban guardados (por ejemplo la venta F-5410011).
--
-- Este archivo:
--   1. Guarda una copia de cada regla en la tabla politicas_respaldo (se pueden restaurar).
--   2. Quita solo esas reglas "_auth".
--   3. Deja la lectura como la diseñó el sistema (igual que supabase-migration-rls-ventas.sql):
--      se puede LEER; escribir directo sigue bloqueado (todo pasa por las funciones del sistema).
-- No borra ni cambia ningún dato. Se puede correr varias veces.
-- ============================================================

create table if not exists politicas_respaldo (
    id bigserial primary key,
    tabla text not null,
    nombre text not null,
    comando text,
    roles text,
    usando text,
    chequeo text,
    respaldado_at timestamptz not null default now()
);
alter table politicas_respaldo enable row level security;
revoke all on politicas_respaldo from anon, authenticated;

do $$
declare p record; t text; v_tablas text[] := '{}';
begin
    for p in
        select tablename, policyname, cmd, roles::text as roles, qual, with_check
        from pg_policies
        where schemaname = 'public'
          and policyname ~ '_auth$'
          and (coalesce(qual, '') || ' ' || coalesce(with_check, '')) ~* '(auth\.role\(\)|request\.jwt)'
    loop
        insert into politicas_respaldo (tabla, nombre, comando, roles, usando, chequeo)
        values (p.tablename, p.policyname, p.cmd, p.roles, p.qual, p.with_check);
        execute format('drop policy %I on public.%I', p.policyname, p.tablename);
        if not (p.tablename = any (v_tablas)) then v_tablas := v_tablas || p.tablename; end if;
        raise notice 'Regla quitada: %.%', p.tablename, p.policyname;
    end loop;

    -- Cada tabla afectada queda con lectura abierta (como el resto del sistema) y sin escritura directa
    foreach t in array v_tablas loop
        if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = t and cmd in ('SELECT', 'ALL') and permissive = 'PERMISSIVE') then
            execute format('create policy %I on public.%I for select using (true)', t || '_select', t);
        end if;
        execute format('grant select on public.%I to anon, authenticated', t);
        raise notice 'Lectura restablecida en %', t;
    end loop;
end $$;

-- Las ventas y su detalle se escriben solo con las funciones del sistema
do $$ begin
    if to_regclass('public.ventas') is not null then
        execute 'revoke insert, update, delete on public.ventas from anon, authenticated';
        if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'ventas' and cmd in ('SELECT', 'ALL')) then
            execute 'create policy "ventas_select" on public.ventas for select using (true)';
        end if;
    end if;
    if to_regclass('public.detalle_venta') is not null then
        execute 'revoke insert, update, delete on public.detalle_venta from anon, authenticated';
        if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'detalle_venta' and cmd in ('SELECT', 'ALL')) then
            execute 'create policy "detalle_venta_select" on public.detalle_venta for select using (true)';
        end if;
    end if;
end $$;

-- Las empresas de la plataforma copian las reglas de public
do $$ begin
    if to_regprocedure('saas.sincronizar_todas()') is not null then perform saas.sincronizar_todas(); end if;
end $$;
notify pgrst, 'reload schema';

-- Resultado: qué reglas se quitaron
select coalesce(string_agg(distinct tabla, ', '), 'ninguna (ya estaba bien)') as tablas_corregidas,
       count(*) as reglas_quitadas
from politicas_respaldo where respaldado_at > now() - interval '1 minute';
