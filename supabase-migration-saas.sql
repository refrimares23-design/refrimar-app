-- ============================================================
-- MULTIEMPRESA (SaaS) — cada empresa con su propio espacio de datos
-- ------------------------------------------------------------
-- Cómo funciona:
--  • REFRIMAR sigue en el esquema "public" tal como está: es la empresa n.º 1.
--    No se mueve ni se borra ningún dato.
--  • Cada empresa nueva recibe su propio esquema (e_<nombre>) con TODAS las
--    tablas, funciones, disparadores, permisos y reglas de seguridad, copiados
--    de public. Sus datos nunca se mezclan con los de otra empresa.
--  • La página indica la empresa con la cabecera estándar de PostgREST
--    (Accept-Profile / Content-Profile). Antes de cada petición la base revisa
--    la suscripción (prueba, activa, vencida, bloqueada) y el token de sesión.
--  • Después de cualquier actualización futura del sistema (que se corre sobre
--    public) basta con:  select saas.sincronizar_todas();
--  • Antes de tocar nada se hace un respaldo de public en el esquema respaldo_AAAAMMDD_HHMI.
-- Se puede correr varias veces.
-- ============================================================

-- ---------- 0. Respaldo de los datos actuales ----------
do $$
declare t record; v_esq text := 'respaldo_' || to_char(now() at time zone 'America/Caracas', 'YYYYMMDD');
begin
    if exists (select 1 from pg_namespace where nspname = v_esq) then return; end if;
    execute format('create schema %I', v_esq);
    for t in select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
             where n.nspname = 'public' and c.relkind in ('r', 'p') loop
        execute format('create table %I.%I as table public.%I', v_esq, t.relname, t.relname);
    end loop;
    execute format('revoke all on schema %I from public', v_esq);
    begin execute format('revoke all on schema %I from anon, authenticated', v_esq); exception when others then null; end;
    raise notice 'Respaldo creado en el esquema %', v_esq;
end $$;

-- ---------- 1. Datos de la plataforma (esquema saas, no expuesto a internet) ----------
create schema if not exists saas;
revoke all on schema saas from public;
do $$ begin execute 'revoke all on schema saas from anon, authenticated'; exception when others then null; end $$;

create table if not exists saas.config (
    id int primary key default 1 check (id = 1),
    producto_nombre text not null default 'Cuadra',
    producto_lema text not null default 'Factura, controla el inventario y cuadra la caja',
    dias_prueba int not null default 14,
    dias_gracia int not null default 5,
    whatsapp text,
    correo_soporte text,
    dominio text,
    registro_abierto boolean not null default true,
    actualizado_at timestamptz not null default now()
);
insert into saas.config (id) values (1) on conflict (id) do nothing;

create table if not exists saas.planes (
    id text primary key,
    nombre text not null,
    descripcion text,
    precio_usd_mes numeric,          -- null = "Consultar" en la página pública
    precio_usd_anual numeric,
    max_sucursales int,              -- null = sin límite (sin contar la principal)
    max_usuarios int,
    max_productos int,
    modulos jsonb not null default '[]'::jsonb,
    publico boolean not null default true,
    activo boolean not null default true,
    orden int not null default 0
);
insert into saas.planes (id, nombre, descripcion, max_sucursales, max_usuarios, max_productos, publico, orden) values
    ('basico',  'Básico',  'Una tienda: caja, inventario y clientes.', 0, 3, 3000, true, 1),
    ('negocio', 'Negocio', 'Hasta 3 tiendas con transferencias y reportes.', 2, 10, 20000, true, 2),
    ('empresa', 'Empresa', 'Tiendas y usuarios sin límite.', null, null, null, true, 3),
    ('interno', 'Interno', 'Uso propio, sin límites ni cobro.', null, null, null, false, 99)
on conflict (id) do nothing;

create table if not exists saas.empresas (
    id uuid primary key default gen_random_uuid(),
    slug text not null unique check (slug ~ '^[a-z0-9][a-z0-9-]{1,38}$'),
    esquema text not null unique,
    nombre text not null,
    razon_social text,
    rif text,
    correo text,
    telefono text,
    rubro text,
    plan_id text not null references saas.planes(id) default 'basico',
    estado text not null default 'prueba' check (estado in ('prueba', 'activa', 'vencida', 'bloqueada', 'cancelada')),
    prueba_hasta date,
    pagado_hasta date,
    dueno_nombre text,
    dueno_email text,
    notas text,
    creada_at timestamptz not null default now(),
    actualizada_at timestamptz not null default now()
);
create index if not exists idx_saas_empresas_estado on saas.empresas(estado);

-- REFRIMAR = empresa n.º 1, en public, plan interno, nunca se bloquea
insert into saas.empresas (id, slug, esquema, nombre, razon_social, rif, correo, plan_id, estado, dueno_nombre)
values ('00000000-0000-0000-0000-00000000e001', 'refrimar', 'public', 'REFRIMAR', 'Comercial Refrimar 2023, C.A.', 'J-50357586-7',
        'refrimar.es23@gmail.com', 'interno', 'activa', 'Jose')
on conflict (id) do nothing;

create table if not exists saas.pagos (
    id uuid primary key default gen_random_uuid(),
    empresa_id uuid not null references saas.empresas(id) on delete cascade,
    fecha date not null default current_date,
    monto_usd numeric not null check (monto_usd >= 0),
    metodo text,
    referencia text,
    periodo_desde date,
    periodo_hasta date,
    notas text,
    registrado_por text,
    creado_at timestamptz not null default now()
);
create index if not exists idx_saas_pagos_empresa on saas.pagos(empresa_id, fecha desc);

create table if not exists saas.superadmins (
    email text primary key check (email = lower(email)),
    nombre text,
    creado_at timestamptz not null default now()
);
insert into saas.superadmins (email, nombre) values
    ('refrimar.es23@gmail.com', 'Jose'),
    ('josedavidacosta129@gmail.com', 'Jose')
on conflict (email) do nothing;

-- Correo → empresas donde ese correo es colaborador (para entrar con Google)
create table if not exists saas.directorio (
    email text not null,
    esquema text not null,
    usuario_id uuid not null,
    nombre text,
    activo boolean not null default true,
    primary key (esquema, usuario_id)
);
create index if not exists idx_saas_directorio_email on saas.directorio(email);

create table if not exists saas.eventos (
    id bigserial primary key,
    fecha timestamptz not null default now(),
    empresa_id uuid,
    actor text,
    accion text not null,
    detalle jsonb
);
create index if not exists idx_saas_eventos_fecha on saas.eventos(fecha desc);

create table if not exists saas.registro_intentos (
    id bigserial primary key,
    ip text,
    fecha timestamptz not null default now()
);
create index if not exists idx_saas_registro_ip on saas.registro_intentos(ip, fecha);

-- ---------- 2. Utilidades ----------
-- RIF venezolano: letra, 8 dígitos y dígito verificador (módulo 11)
create or replace function saas.rif_normalizar(p text)
returns text language sql immutable as $$
    select case when d ~ '^[VEJPGC][0-9]{9}$' then substr(d, 1, 1) || '-' || substr(d, 2, 8) || '-' || substr(d, 10, 1) end
    from (select upper(regexp_replace(coalesce(p, ''), '[^A-Za-z0-9]', '', 'g')) d) x
$$;
create or replace function saas.rif_valido(p text)
returns boolean language plpgsql immutable as $$
declare d text := replace(saas.rif_normalizar(p), '-', ''); s int; pesos int[] := array[3, 2, 7, 6, 5, 4, 3, 2]; i int; v int;
begin
    if d is null then return false; end if;
    s := 4 * (case substr(d, 1, 1) when 'V' then 1 when 'E' then 2 when 'J' then 3 when 'P' then 4 when 'G' then 5 when 'C' then 3 end);
    for i in 1..8 loop s := s + substr(d, i + 1, 1)::int * pesos[i]; end loop;
    v := 11 - (s % 11);
    if v >= 10 then v := 0; end if;
    return v = substr(d, 10, 1)::int;
end;
$$;

create or replace function saas.header(p text)
returns text language plpgsql stable as $$
begin
    return nullif(coalesce(nullif(current_setting('request.headers', true), ''), '{}')::json ->> p, '');
exception when others then return null;
end;
$$;

-- Estado real (la prueba o el pago pueden haber vencido)
create or replace function saas.estado_efectivo(e saas.empresas)
returns text language sql stable as $$
    select case
        when e.esquema = 'public' then 'activa'
        when e.estado in ('bloqueada', 'cancelada', 'vencida') then e.estado
        when e.estado = 'prueba' and e.prueba_hasta is not null and e.prueba_hasta < current_date then 'vencida'
        when e.estado = 'activa' and e.pagado_hasta is not null
             and e.pagado_hasta + (select dias_gracia from saas.config where id = 1) < current_date then 'vencida'
        else e.estado end
$$;

create or replace function saas.es_superadmin()
returns boolean language sql stable security definer set search_path = pg_catalog, saas as $$
    select exists (select 1 from saas.superadmins where email = lower(coalesce(auth.jwt() ->> 'email', '')))
           and coalesce(auth.jwt() ->> 'role', '') = 'authenticated'
$$;

create or replace function saas.registrar_evento(p_empresa uuid, p_accion text, p_detalle jsonb)
returns void language sql security definer set search_path = pg_catalog, saas as $$
    insert into saas.eventos (empresa_id, actor, accion, detalle)
    values (p_empresa, coalesce(nullif(auth.jwt() ->> 'email', ''), 'sistema'), p_accion, p_detalle)
$$;

-- ---------- 3. Copiar la estructura de public a otra empresa (y mantenerla al día) ----------
-- Reemplaza referencias a public.* por el esquema de la empresa
create or replace function saas.q(p_sql text, p_esq text)
returns text language sql immutable as $$
    select regexp_replace(p_sql, '(^|[^A-Za-z0-9_."])public\.', '\1' || quote_ident(p_esq) || '.', 'g')
$$;

create or replace function saas.sincronizar(p_esq text)
returns jsonb
language plpgsql security definer
set search_path = pg_catalog
as $$
declare
    t record; c record; f record; i record; k record; g record; v_def text; v_sql text; v_seq text;
    n_tab int := 0; n_col int := 0; n_fun int := 0; n_trg int := 0; n_err int := 0; v_errores jsonb := '[]'::jsonb;
    v_principal text;
begin
    if p_esq is null or p_esq = 'public' or p_esq !~ '^e_[a-z0-9_]{2,40}$' then raise exception 'Esquema de empresa inválido: %', p_esq; end if;
    perform set_config('check_function_bodies', 'off', true);
    execute format('create schema if not exists %I', p_esq);
    execute format('grant usage on schema %I to anon, authenticated', p_esq);
    begin execute format('grant usage on schema %I to service_role', p_esq); exception when others then null; end;
    -- Nombre de la tienda principal de esta empresa (en public se llama "Casa Matriz")
    begin
        execute format('select nullif(opciones->>''nombre_principal'', '''') from %I.configuracion limit 1', p_esq) into v_principal;
    exception when others then v_principal := null; end;
    v_principal := coalesce(v_principal, 'Principal');

    -- 3.1 Tablas y columnas
    for t in select cl.oid, cl.relname from pg_class cl join pg_namespace n on n.oid = cl.relnamespace
             where n.nspname = 'public' and cl.relkind = 'r' order by cl.relname loop
        if to_regclass(quote_ident(p_esq) || '.' || quote_ident(t.relname)) is null then
            execute format('create table %I.%I (like public.%I including all excluding indexes)', p_esq, t.relname, t.relname);
            n_tab := n_tab + 1;
        else
            for c in select a.attname, format_type(a.atttypid, a.atttypmod) as tipo, pg_get_expr(d.adbin, d.adrelid) as def, a.attnotnull
                     from pg_attribute a left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
                     where a.attrelid = t.oid and a.attnum > 0 and not a.attisdropped
                       and not exists (select 1 from pg_attribute b where b.attrelid = to_regclass(quote_ident(p_esq) || '.' || quote_ident(t.relname))
                                       and b.attname = a.attname and not b.attisdropped) loop
                v_sql := format('alter table %I.%I add column %I %s', p_esq, t.relname, c.attname, c.tipo);
                if c.def is not null and c.def not like 'nextval(%' then v_sql := v_sql || ' default ' || saas.q(c.def, p_esq); end if;
                if c.attnotnull and c.def is not null and c.def not like 'nextval(%' then v_sql := v_sql || ' not null'; end if;
                execute v_sql;
                n_col := n_col + 1;
            end loop;
        end if;
        -- Secuencias propias (las columnas serial apuntaban a la secuencia de public)
        for c in select a.attname, pg_get_expr(d.adbin, d.adrelid) as def
                 from pg_attrdef d join pg_attribute a on a.attrelid = d.adrelid and a.attnum = d.adnum
                 where d.adrelid = t.oid and pg_get_expr(d.adbin, d.adrelid) like 'nextval(%' loop
            v_seq := substring(c.def from 'nextval\(''(?:public\.)?"?([^''"]+)"?''');
            if v_seq is not null then
                execute format('create sequence if not exists %I.%I', p_esq, v_seq);
                execute format('alter table %I.%I alter column %I set default nextval(%L)', p_esq, t.relname, c.attname, quote_ident(p_esq) || '.' || quote_ident(v_seq));
                execute format('alter sequence %I.%I owned by %I.%I.%I', p_esq, v_seq, p_esq, t.relname, c.attname);
            end if;
        end loop;
        -- Llave primaria, únicas y chequeos que falten (por nombre)
        for k in select con.conname, pg_get_constraintdef(con.oid) as def from pg_constraint con
                 where con.conrelid = t.oid and con.contype in ('p', 'u', 'x', 'c')
                   and not exists (select 1 from pg_constraint x where x.conrelid = to_regclass(quote_ident(p_esq) || '.' || quote_ident(t.relname)) and x.conname = con.conname)
                 order by case con.contype when 'p' then 0 else 1 end loop
            begin
                execute format('alter table %I.%I add constraint %I %s', p_esq, t.relname, k.conname, saas.q(k.def, p_esq));
            exception when others then n_err := n_err + 1; v_errores := v_errores || jsonb_build_object('restriccion', k.conname, 'error', sqlerrm);
            end;
        end loop;
        -- Índices que falten (por nombre)
        for i in select ic.relname as nombre, pg_get_indexdef(ix.indexrelid) as def
                 from pg_index ix join pg_class ic on ic.oid = ix.indexrelid
                 where ix.indrelid = t.oid
                   and not exists (select 1 from pg_class x join pg_namespace xn on xn.oid = x.relnamespace where xn.nspname = p_esq and x.relname = ic.relname) loop
            begin
                execute saas.q(i.def, p_esq);
            exception when others then n_err := n_err + 1; v_errores := v_errores || jsonb_build_object('indice', i.nombre, 'error', sqlerrm);
            end;
        end loop;
        -- Seguridad por filas (RLS): mismas reglas que public
        execute format('alter table %I.%I %s row level security', p_esq, t.relname,
                       case when (select relrowsecurity from pg_class where oid = t.oid) then 'enable' else 'disable' end);
        for k in select polname from pg_policy where polrelid = to_regclass(quote_ident(p_esq) || '.' || quote_ident(t.relname)) loop
            execute format('drop policy %I on %I.%I', k.polname, p_esq, t.relname);
        end loop;
        for k in select p.polname, p.polpermissive, p.polcmd, pg_get_expr(p.polqual, p.polrelid) as usando, pg_get_expr(p.polwithcheck, p.polrelid) as chequeo,
                        (select string_agg(case when r = 0 then 'public' else quote_ident(pg_get_userbyid(r)) end, ', ') from unnest(p.polroles) r) as roles
                 from pg_policy p where p.polrelid = t.oid loop
            v_sql := format('create policy %I on %I.%I as %s for %s to %s', k.polname, p_esq, t.relname,
                            case when k.polpermissive then 'permissive' else 'restrictive' end,
                            case k.polcmd when 'r' then 'select' when 'a' then 'insert' when 'w' then 'update' when 'd' then 'delete' else 'all' end,
                            coalesce(k.roles, 'public'));
            if k.usando is not null then v_sql := v_sql || ' using (' || saas.q(k.usando, p_esq) || ')'; end if;
            if k.chequeo is not null then v_sql := v_sql || ' with check (' || saas.q(k.chequeo, p_esq) || ')'; end if;
            execute v_sql;
        end loop;
        -- Permisos de tabla y de columna (ej.: el PIN de usuarios no se puede leer)
        execute format('revoke all on %I.%I from public, anon, authenticated', p_esq, t.relname);
        for g in select a.grantee, a.privilege_type from pg_class cl, aclexplode(cl.relacl) a
                 where cl.oid = t.oid and a.grantee <> cl.relowner loop
            execute format('grant %s on %I.%I to %s', g.privilege_type, p_esq, t.relname,
                           case when g.grantee = 0 then 'public' else quote_ident(pg_get_userbyid(g.grantee)) end);
        end loop;
        for g in select at.attname, a.grantee, a.privilege_type from pg_attribute at, aclexplode(at.attacl) a
                 where at.attrelid = t.oid and at.attacl is not null and at.attnum > 0 loop
            execute format('grant %s (%I) on %I.%I to %s', g.privilege_type, g.attname, p_esq, t.relname,
                           case when g.grantee = 0 then 'public' else quote_ident(pg_get_userbyid(g.grantee)) end);
        end loop;
    end loop;

    -- 3.2 Secuencias sueltas que usan las funciones para numerar (seq_turno, seq_odc…): empiezan en 1
    for k in select cl.relname, s.seqincrement, s.seqmin, s.seqmax, s.seqstart from pg_class cl join pg_namespace n on n.oid = cl.relnamespace
             join pg_sequence s on s.seqrelid = cl.oid
             where n.nspname = 'public' and cl.relkind = 'S'
               and not exists (select 1 from pg_depend d where d.objid = cl.oid and d.deptype in ('a', 'i')) loop
        execute format('create sequence if not exists %I.%I increment %s minvalue %s maxvalue %s start %s', p_esq, k.relname, k.seqincrement, k.seqmin, k.seqmax, k.seqstart);
    end loop;

    -- 3.3 Llaves foráneas (después de tener todas las tablas)
    for k in select con.conname, cl.relname, pg_get_constraintdef(con.oid) as def
             from pg_constraint con join pg_class cl on cl.oid = con.conrelid join pg_namespace n on n.oid = cl.relnamespace
             where n.nspname = 'public' and con.contype = 'f'
               and not exists (select 1 from pg_constraint x join pg_class xc on xc.oid = x.conrelid join pg_namespace xn on xn.oid = xc.relnamespace
                               where xn.nspname = p_esq and xc.relname = cl.relname and x.conname = con.conname) loop
        begin
            execute format('alter table %I.%I add constraint %I %s', p_esq, k.relname, k.conname, saas.q(k.def, p_esq));
        exception when others then n_err := n_err + 1; v_errores := v_errores || jsonb_build_object('llave', k.conname, 'error', sqlerrm);
        end;
    end loop;
    execute format('grant usage, select on all sequences in schema %I to anon, authenticated', p_esq);

    -- 3.4 Vistas
    for k in select cl.relname, pg_get_viewdef(cl.oid) as def from pg_class cl join pg_namespace n on n.oid = cl.relnamespace
             where n.nspname = 'public' and cl.relkind = 'v' loop
        begin
            execute format('create or replace view %I.%I as %s', p_esq, k.relname, saas.q(k.def, p_esq));
        exception when others then n_err := n_err + 1; v_errores := v_errores || jsonb_build_object('vista', k.relname, 'error', sqlerrm);
        end;
    end loop;

    -- 3.5 Funciones (todas las del sistema, menos las de la plataforma saas_* y las de extensiones)
    for f in select p.oid, p.proname, p.proacl, pg_get_function_identity_arguments(p.oid) as args
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             where n.nspname = 'public' and p.prokind in ('f', 'p') and p.proname !~ '^saas_'
               and not exists (select 1 from pg_depend dp where dp.objid = p.oid and dp.deptype = 'e')
             order by p.proname loop
        v_def := pg_get_functiondef(f.oid);
        v_def := saas.q(v_def, p_esq);
        -- Nunca puede caer en public: el search_path de cada función es el de su empresa
        if v_def ~ '\n\s*SET search_path TO [^\n]*' then
            v_def := regexp_replace(v_def, '\n(\s*)SET search_path TO [^\n]*', E'\n\\1SET search_path TO ' || quote_ident(p_esq) || ', extensions, pg_temp');
        else
            v_def := regexp_replace(v_def, '\nAS ', E'\n SET search_path TO ' || quote_ident(p_esq) || E', extensions, pg_temp\nAS ');
        end if;
        v_def := replace(v_def, 'Casa Matriz', v_principal);
        begin
            execute v_def;
        exception when others then
            begin
                execute format('drop function if exists %I.%I(%s) cascade', p_esq, f.proname, f.args);
                execute v_def;
            exception when others then n_err := n_err + 1; v_errores := v_errores || jsonb_build_object('funcion', f.proname, 'error', sqlerrm); continue;
            end;
        end;
        -- Mismos permisos de ejecución que en public
        execute format('revoke all on function %I.%I(%s) from public, anon, authenticated', p_esq, f.proname, f.args);
        if f.proacl is null then
            execute format('grant execute on function %I.%I(%s) to public', p_esq, f.proname, f.args);
        else
            for g in select a.grantee from aclexplode(f.proacl) a where a.privilege_type = 'EXECUTE' and a.grantee <> (select proowner from pg_proc where oid = f.oid) loop
                execute format('grant execute on function %I.%I(%s) to %s', p_esq, f.proname, f.args,
                               case when g.grantee = 0 then 'public' else quote_ident(pg_get_userbyid(g.grantee)) end);
            end loop;
        end if;
        n_fun := n_fun + 1;
    end loop;

    -- 3.6 Catálogos del sistema (permisos de cada función y árbol de permisos): se agregan los nuevos
    if to_regclass('public.seguridad_rpc') is not null then
        execute format('insert into %I.seguridad_rpc select * from public.seguridad_rpc on conflict (nombre) do update set nivel = excluded.nivel, permiso = excluded.permiso, gracia_dias = excluded.gracia_dias', p_esq);
    end if;
    if to_regclass('public.permisos_mapa') is not null then
        execute format('insert into %I.permisos_mapa select * from public.permisos_mapa on conflict do nothing', p_esq);
    end if;

    -- 3.7 Disparadores (se rehacen todos)
    for k in select tg.tgname, cl.relname from pg_trigger tg join pg_class cl on cl.oid = tg.tgrelid join pg_namespace n on n.oid = cl.relnamespace
             where n.nspname = p_esq and not tg.tgisinternal loop
        execute format('drop trigger if exists %I on %I.%I', k.tgname, p_esq, k.relname);
    end loop;
    for k in select tg.tgname, pg_get_triggerdef(tg.oid) as def from pg_trigger tg join pg_class cl on cl.oid = tg.tgrelid join pg_namespace n on n.oid = cl.relnamespace
             where n.nspname = 'public' and not tg.tgisinternal loop
        begin
            execute saas.q(k.def, p_esq);
            n_trg := n_trg + 1;
        exception when others then n_err := n_err + 1; v_errores := v_errores || jsonb_build_object('disparador', k.tgname, 'error', sqlerrm);
        end;
    end loop;

    return jsonb_build_object('ok', n_err = 0, 'esquema', p_esq, 'tablas_nuevas', n_tab, 'columnas_nuevas', n_col,
                              'funciones', n_fun, 'disparadores', n_trg, 'errores', v_errores);
end;
$$;

-- Lista de esquemas que PostgREST deja usar (public + cada empresa)
create or replace function saas.exponer_esquemas()
returns text
language plpgsql security definer
set search_path = pg_catalog, saas
as $$
declare v_actual text; v_base text[]; v_lista text;
begin
    select (select substr(s, length('pgrst.db_schemas=') + 1) from unnest(r.rolconfig) s where s like 'pgrst.db_schemas=%' limit 1)
      into v_actual from pg_roles r where r.rolname = 'authenticator';
    -- Se conservan los esquemas que ya estaban expuestos (graphql_public, etc.), sin los de empresas
    select coalesce(array_agg(x), '{}') into v_base
    from (select trim(x) x from unnest(string_to_array(coalesce(v_actual, 'public, graphql_public'), ',')) x) y
    where x <> '' and x !~ '^e_';
    if not ('public' = any (v_base)) then v_base := array['public'] || v_base; end if;
    select array_to_string(v_base || coalesce(array_agg(esquema order by creada_at), '{}'), ', ') into v_lista
    from saas.empresas where esquema <> 'public' and estado <> 'cancelada';
    execute format('alter role authenticator set pgrst.db_schemas = %L', v_lista);
    perform pg_notify('pgrst', 'reload config');
    perform pg_notify('pgrst', 'reload schema');
    return v_lista;
end;
$$;

-- Después de actualizar public con un SQL nuevo, deja todas las empresas al día
create or replace function saas.sincronizar_todas()
returns jsonb
language plpgsql security definer
set search_path = pg_catalog, saas
as $$
declare e record; r jsonb; v_out jsonb := '[]'::jsonb;
begin
    for e in select esquema, nombre from saas.empresas where esquema <> 'public' and estado <> 'cancelada' order by creada_at loop
        r := saas.sincronizar(e.esquema);
        v_out := v_out || jsonb_build_object('empresa', e.nombre, 'ok', r->'ok', 'errores', r->'errores');
    end loop;
    perform saas.exponer_esquemas();
    return v_out;
end;
$$;

-- ---------- 4. Directorio de correos (para entrar con Google) ----------
create or replace function saas.directorio_trg()
returns trigger
language plpgsql security definer
set search_path = pg_catalog, saas
as $$
declare v_mail text;
begin
    if tg_op = 'DELETE' then
        delete from saas.directorio where esquema = tg_table_schema and usuario_id = old.id;
        return old;
    end if;
    v_mail := lower(nullif(trim(coalesce(to_jsonb(new) ->> 'email', '')), ''));
    if v_mail is null then
        delete from saas.directorio where esquema = tg_table_schema and usuario_id = new.id;
    else
        insert into saas.directorio (email, esquema, usuario_id, nombre, activo)
        values (v_mail, tg_table_schema, new.id, to_jsonb(new) ->> 'nombre', coalesce((to_jsonb(new) ->> 'activo')::boolean, true))
        on conflict (esquema, usuario_id) do update set email = excluded.email, nombre = excluded.nombre, activo = excluded.activo;
    end if;
    return new;
end;
$$;
drop trigger if exists trg_saas_directorio on public.usuarios;
create trigger trg_saas_directorio after insert or update or delete on public.usuarios
    for each row execute function saas.directorio_trg();
insert into saas.directorio (email, esquema, usuario_id, nombre, activo)
select lower(trim(email)), 'public', id, nombre, coalesce(activo, true) from public.usuarios
where nullif(trim(coalesce(email, '')), '') is not null
on conflict (esquema, usuario_id) do update set email = excluded.email, nombre = excluded.nombre, activo = excluded.activo;

-- ---------- 5. Límites del plan (usuarios, tiendas, productos) ----------
create or replace function saas.limite_trg()
returns trigger
language plpgsql security definer
set search_path = pg_catalog, saas
as $$
declare e record; v_max int; v_n int; v_que text;
begin
    if tg_table_schema = 'public' then return new; end if;
    select p.max_usuarios, p.max_sucursales, p.max_productos, p.nombre into e
    from saas.empresas em join saas.planes p on p.id = em.plan_id where em.esquema = tg_table_schema;
    if not found then return new; end if;
    v_max := case tg_table_name when 'usuarios' then e.max_usuarios when 'sucursales' then e.max_sucursales when 'productos' then e.max_productos end;
    if v_max is null then return new; end if;
    -- Cuenta solo hasta el límite (rápido aunque haya muchos registros)
    execute format('select count(*) from (select 1 from %I.%I limit %s) x', tg_table_schema, tg_table_name, v_max + 1) into v_n;
    if v_n > v_max then
        v_que := case tg_table_name when 'usuarios' then 'colaboradores' when 'sucursales' then 'tiendas adicionales' else 'productos' end;
        if v_max = 0 and tg_table_name = 'sucursales' then
            raise exception 'Tu plan % incluye solo la tienda principal. Para agregar más tiendas, cambia de plan en Configuración → Mi plan.', e.nombre using errcode = 'P0001';
        end if;
        raise exception 'Tu plan % permite hasta % %. Para agregar más, cambia de plan en Configuración → Mi plan.', e.nombre, v_max, v_que
            using errcode = 'P0001';
    end if;
    return new;
end;
$$;
do $$ declare t text; begin
    foreach t in array array['usuarios', 'sucursales', 'productos'] loop
        if to_regclass('public.' || t) is not null then
            execute format('drop trigger if exists trg_saas_limite on public.%I', t);
            execute format('create trigger trg_saas_limite after insert on public.%I for each row execute function saas.limite_trg()', t);
        end if;
    end loop;
end $$;

-- ---------- 6. Revisión antes de cada petición: empresa + suscripción + sesión ----------
create or replace function public.saas_pre_request()
returns void
language plpgsql security definer
set search_path = pg_catalog, saas
as $$
declare
    v_met text := upper(coalesce(current_setting('request.method', true), 'GET'));
    v_path text := coalesce(current_setting('request.path', true), '');
    v_esq text; e saas.empresas; v_estado text; v_rpc text;
begin
    v_esq := lower(coalesce(saas.header(case when v_met in ('GET', 'HEAD') then 'accept-profile' else 'content-profile' end), 'public'));
    if v_esq = 'public' then
        perform public.refrimar_pre_request();
        return;
    end if;
    select * into e from saas.empresas where esquema = v_esq;
    if not found then return; end if;          -- PostgREST ya rechaza esquemas que no existen
    v_estado := saas.estado_efectivo(e);
    v_rpc := case when v_path like '/rpc/%' then lower(split_part(substr(v_path, 6), '?', 1)) end;
    if v_estado in ('bloqueada', 'cancelada') and coalesce(v_rpc, '') not in ('sesion_cerrar') then
        raise exception using errcode = 'PT402', message = 'El acceso de ' || e.nombre || ' está suspendido. Escríbenos para reactivarlo.';
    end if;
    if v_estado = 'vencida' and v_met not in ('GET', 'HEAD')
       and coalesce(v_rpc, '') not in ('sesion_iniciar_pin', 'sesion_iniciar_google', 'sesion_validar', 'sesion_cerrar', 'login_usuario', 'login_google') then
        raise exception using errcode = 'PT402', message = 'La suscripción de ' || e.nombre || ' venció: puedes consultar pero no registrar operaciones. Renueva para seguir vendiendo.';
    end if;
    execute format('select %I.refrimar_pre_request()', v_esq);
end;
$$;
grant execute on function public.saas_pre_request() to anon, authenticated;

-- ---------- 7. Crear una empresa nueva ----------
create or replace function saas.crear_empresa(p jsonb, p_origen text default 'registro')
returns jsonb
language plpgsql security definer
set search_path = pg_catalog, saas
as $$
declare
    v_nombre text := nullif(trim(coalesce(p ->> 'nombre', '')), '');
    v_rif text := saas.rif_normalizar(p ->> 'rif');
    v_correo text := lower(nullif(trim(coalesce(p ->> 'correo', '')), ''));
    v_dueno text := nullif(trim(coalesce(p ->> 'dueno_nombre', '')), '');
    v_pin text := coalesce(p ->> 'pin', '');
    v_plan text := coalesce(nullif(p ->> 'plan', ''), 'basico');
    v_rubro text := coalesce(nullif(p ->> 'rubro', ''), 'generico');
    v_slug text; v_esq text; v_id uuid; v_n int := 0; r jsonb; v_uid uuid := gen_random_uuid(); cfg record;
begin
    select * into cfg from saas.config where id = 1;
    if v_nombre is null or length(v_nombre) < 2 then raise exception 'Escribe el nombre de la empresa'; end if;
    if v_rif is null or not saas.rif_valido(v_rif) then raise exception 'El RIF no es válido. Escríbelo así: J-12345678-9'; end if;
    if v_correo is null or v_correo !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Escribe un correo válido'; end if;
    if v_dueno is null then raise exception 'Escribe tu nombre'; end if;
    if v_pin !~ '^[0-9]{4}$' then raise exception 'El PIN debe tener 4 números'; end if;
    if not exists (select 1 from saas.planes where id = v_plan and activo) then raise exception 'Plan no disponible'; end if;
    if exists (select 1 from saas.empresas where rif = v_rif and estado <> 'cancelada') then
        raise exception 'Ya hay una empresa registrada con el RIF %. Si es tuya, entra con tu correo o escríbenos.', v_rif;
    end if;

    -- Identificador corto: nombre sin acentos ni espacios
    v_slug := left(trim(both '-' from regexp_replace(lower(translate(v_nombre, 'áéíóúüñÁÉÍÓÚÜÑ', 'aeiouunaeiouun')), '[^a-z0-9]+', '-', 'g')), 30);
    if length(v_slug) < 2 then v_slug := 'empresa'; end if;
    while exists (select 1 from saas.empresas where slug = v_slug || case when v_n = 0 then '' else '-' || v_n end) loop v_n := v_n + 1; end loop;
    if v_n > 0 then v_slug := v_slug || '-' || v_n; end if;
    v_esq := 'e_' || replace(v_slug, '-', '_');

    insert into saas.empresas (slug, esquema, nombre, razon_social, rif, correo, telefono, rubro, plan_id, estado, prueba_hasta, dueno_nombre, dueno_email)
    values (v_slug, v_esq, v_nombre, coalesce(nullif(trim(p ->> 'razon_social'), ''), v_nombre), v_rif, v_correo, nullif(trim(coalesce(p ->> 'telefono', '')), ''),
            v_rubro, v_plan, 'prueba', current_date + cfg.dias_prueba, v_dueno, v_correo)
    returning id into v_id;

    -- Estructura completa del sistema
    r := saas.sincronizar(v_esq);
    if not (r ->> 'ok')::boolean then raise exception 'No se pudo preparar el espacio de la empresa: %', r -> 'errores'; end if;

    -- Datos iniciales: catálogos del sistema (permisos, seguridad, categorías de gasto)
    execute format('insert into %I.permisos_mapa select * from public.permisos_mapa on conflict do nothing', v_esq);
    execute format('insert into %I.seguridad_rpc select * from public.seguridad_rpc on conflict do nothing', v_esq);
    execute format('insert into %I.seguridad_config select * from public.seguridad_config on conflict do nothing', v_esq);
    execute format('update %I.seguridad_config set modo = ''estricto'', actualizado_at = now()', v_esq);
    if to_regclass('public.gasto_categorias') is not null then
        execute format('insert into %I.gasto_categorias select * from public.gasto_categorias on conflict do nothing', v_esq);
    end if;
    -- Configuración de la empresa (una sola fila, como en public)
    execute format('insert into %I.configuracion (nombre_negocio, rif, telefono, email, mensaje_agradecimiento, tasa_bcv_manual, iva_incluido, rubro, opciones)
                    values ($1, $2, $3, $4, ''¡Gracias por su compra!'', (select tasa_bcv_manual from public.configuracion limit 1), false, $5, $6)', v_esq)
    using coalesce(nullif(trim(p ->> 'razon_social'), ''), v_nombre), v_rif, nullif(trim(coalesce(p ->> 'telefono', '')), ''), v_correo, v_rubro,
          jsonb_build_object('nombre_comercial', v_nombre, 'nombre_principal', 'Principal', 'asistente', jsonb_build_object('paso', 0, 'hechos', '[]'::jsonb), 'igtf', false);
    -- El dueño
    execute format('insert into %I.usuarios (id, nombre, rol, pin, activo, permisos, email, estado) values ($1, $2, ''admin'', $3, true, ''[]''::jsonb, $4, ''activo'')', v_esq)
    using v_uid, v_dueno, encode(sha256(convert_to(v_pin, 'UTF8')), 'hex'), v_correo;   -- el PIN se guarda cifrado, igual que en el login

    perform saas.exponer_esquemas();
    perform saas.registrar_evento(v_id, 'empresa_creada', jsonb_build_object('origen', p_origen, 'plan', v_plan, 'rubro', v_rubro));
    return jsonb_build_object('ok', true, 'empresa_id', v_id, 'slug', v_slug, 'esquema', v_esq, 'usuario', v_dueno,
                              'prueba_hasta', current_date + cfg.dias_prueba);
end;
$$;

-- Registro público (formulario de la página). Lo llama el Worker después de revisar Turnstile,
-- o la página directamente si no hay Turnstile configurado. Máximo 3 por conexión al día.
create or replace function public.saas_registrar_empresa(p_datos jsonb)
returns jsonb
language plpgsql security definer
set search_path = pg_catalog, saas
as $$
declare v_ip text; v_servicio boolean := false; r jsonb;
begin
    -- Si llega por el Worker (con la clave de servicio), la IP real del visitante viene en x-cliente-ip
    begin
        v_servicio := saas.header('x-refrimar-servicio') is not null and exists (select 1 from public.seguridad_config
                      where servicio_token_hash is not null and servicio_token_hash = public.refrimar_hash(saas.header('x-refrimar-servicio')));
    exception when others then v_servicio := false; end;
    v_ip := coalesce(case when v_servicio then saas.header('x-cliente-ip') end, nullif(trim(split_part(coalesce(saas.header('x-forwarded-for'), ''), ',', 1)), ''),
                     saas.header('cf-connecting-ip'), 'sin-ip');
    if not (select registro_abierto from saas.config where id = 1) then raise exception 'El registro de empresas nuevas está cerrado por ahora. Escríbenos.'; end if;
    if coalesce(p_datos ->> 'web', '') <> '' then raise exception 'No se pudo registrar'; end if;   -- trampa anti-robots
    if (select count(*) from saas.registro_intentos where ip = v_ip and fecha > now() - interval '1 day') >= 3
       or (select count(*) from saas.registro_intentos where fecha > now() - interval '1 hour') >= 30 then
        raise exception 'Demasiados registros desde esta conexión. Intenta mañana o escríbenos.';
    end if;
    insert into saas.registro_intentos (ip) values (v_ip);
    r := saas.crear_empresa(p_datos, 'registro');
    return r;
end;
$$;
grant execute on function public.saas_registrar_empresa(jsonb) to anon, authenticated;

-- ---------- 8. Consultas públicas para el login y la página ----------
create or replace function public.saas_producto()
returns jsonb language sql stable security definer set search_path = pg_catalog, saas as $$
    select jsonb_build_object('nombre', producto_nombre, 'lema', producto_lema, 'dias_prueba', dias_prueba, 'whatsapp', whatsapp,
                              'correo', correo_soporte, 'registro_abierto', registro_abierto,
                              'planes', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'nombre', nombre, 'descripcion', descripcion,
                                         'precio_usd_mes', precio_usd_mes, 'precio_usd_anual', precio_usd_anual, 'max_sucursales', max_sucursales,
                                         'max_usuarios', max_usuarios, 'max_productos', max_productos, 'modulos', modulos) order by orden), '[]'::jsonb)
                                         from saas.planes where publico and activo))
    from saas.config where id = 1
$$;
grant execute on function public.saas_producto() to anon, authenticated;

-- Empresa por su identificador corto (para el login)
create or replace function public.saas_empresa(p_slug text)
returns jsonb
language plpgsql stable security definer
set search_path = pg_catalog, saas
as $$
declare e saas.empresas; v_logo text; v_nombre text;
begin
    select * into e from saas.empresas where slug = lower(trim(coalesce(p_slug, ''))) or esquema = lower(trim(coalesce(p_slug, '')));
    if not found or e.estado = 'cancelada' then return jsonb_build_object('ok', false, 'error', 'No encontramos esa empresa. Revisa el código.'); end if;
    begin
        execute format('select coalesce(opciones->>''nombre_comercial'', nombre_negocio), opciones->>''logo'' from %I.configuracion limit 1', e.esquema)
        into v_nombre, v_logo;
    exception when others then null; end;
    return jsonb_build_object('ok', true, 'slug', e.slug, 'esquema', e.esquema, 'nombre', coalesce(v_nombre, e.nombre), 'logo', v_logo,
                              'estado', saas.estado_efectivo(e));
end;
$$;
grant execute on function public.saas_empresa(text) to anon, authenticated;

-- Empresas del correo con el que se entró con Google
create or replace function public.saas_mis_empresas()
returns jsonb
language sql stable security definer
set search_path = pg_catalog, saas
as $$
    select coalesce(jsonb_agg(jsonb_build_object('slug', e.slug, 'esquema', e.esquema, 'nombre', e.nombre, 'estado', saas.estado_efectivo(e)) order by e.creada_at), '[]'::jsonb)
    from saas.directorio d join saas.empresas e on e.esquema = d.esquema
    where d.email = lower(coalesce(auth.jwt() ->> 'email', '')) and d.activo and e.estado <> 'cancelada'
$$;
grant execute on function public.saas_mis_empresas() to anon, authenticated;

-- Suscripción de mi empresa (la ve el dueño dentro del sistema)
create or replace function public.saas_mi_suscripcion(p_esquema text)
returns jsonb
language plpgsql stable security definer
set search_path = pg_catalog, saas
as $$
declare e saas.empresas; pl saas.planes; v_uid uuid; v_tok text := saas.header('x-refrimar-sesion'); n_u int; n_s int; n_p int;
begin
    select * into e from saas.empresas where esquema = coalesce(nullif(p_esquema, ''), 'public');
    if not found then return jsonb_build_object('ok', false); end if;
    execute format('select usuario_id from %I.sesiones where token_hash = %I.refrimar_hash($1) and not revocada and expira_at > now()', e.esquema, e.esquema)
    into v_uid using v_tok;
    if v_uid is null then return jsonb_build_object('ok', false, 'error', 'Vuelve a entrar'); end if;
    select * into pl from saas.planes where id = e.plan_id;
    execute format('select (select count(*) from %1$I.usuarios where activo is not false), (select count(*) from %1$I.sucursales), (select count(*) from %1$I.productos)', e.esquema)
    into n_u, n_s, n_p;
    return jsonb_build_object('ok', true, 'empresa', e.nombre, 'slug', e.slug, 'plan', pl.nombre, 'plan_id', pl.id, 'estado', saas.estado_efectivo(e),
        'prueba_hasta', e.prueba_hasta, 'pagado_hasta', e.pagado_hasta,
        'limites', jsonb_build_object('usuarios', pl.max_usuarios, 'sucursales', pl.max_sucursales, 'productos', pl.max_productos),
        'uso', jsonb_build_object('usuarios', n_u, 'sucursales', n_s, 'productos', n_p),
        'producto', (select producto_nombre from saas.config where id = 1), 'whatsapp', (select whatsapp from saas.config where id = 1));
end;
$$;
grant execute on function public.saas_mi_suscripcion(text) to anon, authenticated;

-- Empresas que trabajan hoy (para las tareas automáticas del Worker, ej. precios programados)
create or replace function public.saas_esquemas_activos()
returns jsonb language sql stable security definer set search_path = pg_catalog, saas as $$
    select coalesce(jsonb_agg(e.esquema order by e.creada_at), '[]'::jsonb) from saas.empresas e
    where e.esquema <> 'public' and saas.estado_efectivo(e) in ('activa', 'prueba')
$$;
grant execute on function public.saas_esquemas_activos() to anon, authenticated;

-- ---------- 9. Panel del superadministrador (solo correos en saas.superadmins, entrando con Google) ----------
create or replace function public.saas_admin_resumen()
returns jsonb
language plpgsql stable security definer
set search_path = pg_catalog, saas
as $$
begin
    if not saas.es_superadmin() then raise exception 'Solo el administrador de la plataforma' using errcode = 'PT403'; end if;
    return jsonb_build_object(
        'ok', true,
        'config', (select to_jsonb(c) from saas.config c where id = 1),
        'planes', (select coalesce(jsonb_agg(to_jsonb(p) order by orden), '[]'::jsonb) from saas.planes p),
        'empresas', (select coalesce(jsonb_agg(to_jsonb(e) || jsonb_build_object('estado_efectivo', saas.estado_efectivo(e),
                        'ultimo_pago', (select to_jsonb(x) from (select fecha, monto_usd, periodo_hasta from saas.pagos where empresa_id = e.id order by fecha desc, creado_at desc limit 1) x))
                        order by e.creada_at desc), '[]'::jsonb) from saas.empresas e),
        'pagos', (select coalesce(jsonb_agg(to_jsonb(p) || jsonb_build_object('empresa', e.nombre) order by p.fecha desc, p.creado_at desc), '[]'::jsonb)
                  from (select * from saas.pagos order by fecha desc, creado_at desc limit 200) p join saas.empresas e on e.id = p.empresa_id),
        'eventos', (select coalesce(jsonb_agg(to_jsonb(v) order by v.fecha desc), '[]'::jsonb) from (select * from saas.eventos order by fecha desc limit 100) v)
    );
end;
$$;

create or replace function public.saas_admin_empresa_guardar(p_id uuid, p jsonb)
returns jsonb
language plpgsql security definer
set search_path = pg_catalog, saas
as $$
declare e saas.empresas;
begin
    if not saas.es_superadmin() then raise exception 'Solo el administrador de la plataforma' using errcode = 'PT403'; end if;
    select * into e from saas.empresas where id = p_id for update;
    if not found then raise exception 'Empresa no encontrada'; end if;
    if e.esquema = 'public' and coalesce(p ->> 'estado', 'activa') not in ('activa') then raise exception 'La empresa principal no se puede bloquear'; end if;
    if p ? 'plan_id' and not exists (select 1 from saas.planes where id = p ->> 'plan_id') then raise exception 'Plan no existe'; end if;
    update saas.empresas set
        nombre = coalesce(nullif(trim(p ->> 'nombre'), ''), nombre),
        plan_id = coalesce(nullif(p ->> 'plan_id', ''), plan_id),
        estado = coalesce(nullif(p ->> 'estado', ''), estado),
        prueba_hasta = case when p ? 'prueba_hasta' then nullif(p ->> 'prueba_hasta', '')::date else prueba_hasta end,
        pagado_hasta = case when p ? 'pagado_hasta' then nullif(p ->> 'pagado_hasta', '')::date else pagado_hasta end,
        notas = case when p ? 'notas' then p ->> 'notas' else notas end,
        actualizada_at = now()
    where id = p_id;
    perform saas.registrar_evento(p_id, 'empresa_actualizada', p);
    if p ? 'estado' then perform saas.exponer_esquemas(); end if;
    return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.saas_admin_pago(p_empresa uuid, p jsonb)
returns jsonb
language plpgsql security definer
set search_path = pg_catalog, saas
as $$
declare e saas.empresas; v_desde date; v_hasta date; v_meses int := greatest(1, coalesce(nullif(p ->> 'meses', '')::int, 1));
begin
    if not saas.es_superadmin() then raise exception 'Solo el administrador de la plataforma' using errcode = 'PT403'; end if;
    select * into e from saas.empresas where id = p_empresa for update;
    if not found then raise exception 'Empresa no encontrada'; end if;
    -- El período nuevo empieza donde terminó el pagado (o hoy si ya venció)
    v_desde := greatest(current_date, coalesce(e.pagado_hasta + 1, current_date));
    v_hasta := coalesce(nullif(p ->> 'hasta', '')::date, (v_desde + make_interval(months => v_meses))::date - 1);
    insert into saas.pagos (empresa_id, fecha, monto_usd, metodo, referencia, periodo_desde, periodo_hasta, notas, registrado_por)
    values (p_empresa, coalesce(nullif(p ->> 'fecha', '')::date, current_date), coalesce(nullif(p ->> 'monto_usd', '')::numeric, 0),
            nullif(p ->> 'metodo', ''), nullif(p ->> 'referencia', ''), v_desde, v_hasta, nullif(p ->> 'notas', ''), auth.jwt() ->> 'email');
    update saas.empresas set estado = 'activa', pagado_hasta = v_hasta, actualizada_at = now() where id = p_empresa;
    perform saas.registrar_evento(p_empresa, 'pago_registrado', p || jsonb_build_object('hasta', v_hasta));
    perform saas.exponer_esquemas();
    return jsonb_build_object('ok', true, 'pagado_hasta', v_hasta);
end;
$$;

create or replace function public.saas_admin_plan_guardar(p jsonb)
returns jsonb
language plpgsql security definer
set search_path = pg_catalog, saas
as $$
declare v_id text := lower(nullif(trim(coalesce(p ->> 'id', '')), ''));
begin
    if not saas.es_superadmin() then raise exception 'Solo el administrador de la plataforma' using errcode = 'PT403'; end if;
    if v_id is null or v_id !~ '^[a-z0-9_-]{2,30}$' then raise exception 'Código de plan inválido'; end if;
    insert into saas.planes (id, nombre, descripcion, precio_usd_mes, precio_usd_anual, max_sucursales, max_usuarios, max_productos, modulos, publico, activo, orden)
    values (v_id, coalesce(nullif(trim(p ->> 'nombre'), ''), v_id), p ->> 'descripcion', nullif(p ->> 'precio_usd_mes', '')::numeric, nullif(p ->> 'precio_usd_anual', '')::numeric,
            nullif(p ->> 'max_sucursales', '')::int, nullif(p ->> 'max_usuarios', '')::int, nullif(p ->> 'max_productos', '')::int,
            coalesce(p -> 'modulos', '[]'::jsonb), coalesce((p ->> 'publico')::boolean, true), coalesce((p ->> 'activo')::boolean, true), coalesce(nullif(p ->> 'orden', '')::int, 0))
    on conflict (id) do update set nombre = excluded.nombre, descripcion = excluded.descripcion, precio_usd_mes = excluded.precio_usd_mes,
        precio_usd_anual = excluded.precio_usd_anual, max_sucursales = excluded.max_sucursales, max_usuarios = excluded.max_usuarios,
        max_productos = excluded.max_productos, modulos = excluded.modulos, publico = excluded.publico, activo = excluded.activo, orden = excluded.orden;
    perform saas.registrar_evento(null, 'plan_guardado', p);
    return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.saas_admin_config_guardar(p jsonb)
returns jsonb
language plpgsql security definer
set search_path = pg_catalog, saas
as $$
begin
    if not saas.es_superadmin() then raise exception 'Solo el administrador de la plataforma' using errcode = 'PT403'; end if;
    update saas.config set
        producto_nombre = coalesce(nullif(trim(p ->> 'producto_nombre'), ''), producto_nombre),
        producto_lema = coalesce(nullif(trim(p ->> 'producto_lema'), ''), producto_lema),
        dias_prueba = coalesce(nullif(p ->> 'dias_prueba', '')::int, dias_prueba),
        dias_gracia = coalesce(nullif(p ->> 'dias_gracia', '')::int, dias_gracia),
        whatsapp = case when p ? 'whatsapp' then nullif(trim(p ->> 'whatsapp'), '') else whatsapp end,
        correo_soporte = case when p ? 'correo_soporte' then nullif(trim(p ->> 'correo_soporte'), '') else correo_soporte end,
        dominio = case when p ? 'dominio' then nullif(trim(p ->> 'dominio'), '') else dominio end,
        registro_abierto = coalesce((p ->> 'registro_abierto')::boolean, registro_abierto),
        actualizado_at = now()
    where id = 1;
    perform saas.registrar_evento(null, 'config_guardada', p);
    return jsonb_build_object('ok', true);
end;
$$;

-- Crear una empresa a mano desde el panel (ej. un cliente que pagó por adelantado)
create or replace function public.saas_admin_crear_empresa(p jsonb)
returns jsonb
language plpgsql security definer
set search_path = pg_catalog, saas
as $$
begin
    if not saas.es_superadmin() then raise exception 'Solo el administrador de la plataforma' using errcode = 'PT403'; end if;
    return saas.crear_empresa(p, 'superadmin');
end;
$$;

-- Dejar todas las empresas al día después de una actualización
create or replace function public.saas_admin_sincronizar()
returns jsonb
language plpgsql security definer
set search_path = pg_catalog, saas
as $$
begin
    if not saas.es_superadmin() then raise exception 'Solo el administrador de la plataforma' using errcode = 'PT403'; end if;
    return jsonb_build_object('ok', true, 'empresas', saas.sincronizar_todas());
end;
$$;

grant execute on function public.saas_admin_resumen() to authenticated;
grant execute on function public.saas_admin_empresa_guardar(uuid, jsonb) to authenticated;
grant execute on function public.saas_admin_pago(uuid, jsonb) to authenticated;
grant execute on function public.saas_admin_plan_guardar(jsonb) to authenticated;
grant execute on function public.saas_admin_config_guardar(jsonb) to authenticated;
grant execute on function public.saas_admin_crear_empresa(jsonb) to authenticated;
grant execute on function public.saas_admin_sincronizar() to authenticated;
revoke execute on function public.saas_admin_resumen(), public.saas_admin_empresa_guardar(uuid, jsonb), public.saas_admin_pago(uuid, jsonb),
    public.saas_admin_plan_guardar(jsonb), public.saas_admin_config_guardar(jsonb), public.saas_admin_crear_empresa(jsonb), public.saas_admin_sincronizar() from anon, public;

-- Las funciones de la plataforma hacen su propia revisión: el filtro de sesión de REFRIMAR las deja pasar
do $$ begin
    if to_regclass('public.seguridad_rpc') is not null then
        insert into public.seguridad_rpc (nombre, nivel, permiso)
        select x, 'publico', null from unnest(array['saas_producto', 'saas_empresa', 'saas_mis_empresas', 'saas_mi_suscripcion',
            'saas_admin_resumen', 'saas_admin_empresa_guardar', 'saas_admin_pago', 'saas_admin_plan_guardar', 'saas_admin_config_guardar',
            'saas_admin_crear_empresa', 'saas_admin_sincronizar']) x
        on conflict (nombre) do update set nivel = excluded.nivel, permiso = excluded.permiso;
        -- Registro: si configuraste la clave de servicio, solo entra por el Worker (que revisa Turnstile)
        insert into public.seguridad_rpc (nombre, nivel, permiso) values ('saas_registrar_empresa', 'servicio', null), ('saas_esquemas_activos', 'servicio', null)
        on conflict (nombre) do update set nivel = excluded.nivel, permiso = excluded.permiso;
    end if;
end $$;

-- ---------- 10. Prueba: crear una empresa de ensayo con la estructura REAL de tu base y borrarla ----------
alter table saas.config add column if not exists prueba_clonado jsonb;
create or replace function saas.probar_clonado()
returns jsonb
language plpgsql security definer
set search_path = pg_catalog, saas
as $$
declare r jsonb;
begin
    begin
        r := saas.sincronizar('e_zz_prueba_clonado');
    exception when others then
        r := jsonb_build_object('ok', false, 'errores', jsonb_build_array(jsonb_build_object('error', sqlerrm)));
    end;
    execute 'drop schema if exists e_zz_prueba_clonado cascade';
    r := r || jsonb_build_object('fecha', now());
    update saas.config set prueba_clonado = r where id = 1;
    return r;
end;
$$;
select saas.probar_clonado() ->> 'ok' as prueba_crear_empresa_ok;

-- ---------- 11. Activar ----------
alter role authenticator set pgrst.db_pre_request = 'public.saas_pre_request';
select saas.sincronizar_todas();      -- empresas ya creadas (si las hay) quedan al día
select saas.exponer_esquemas();
notify pgrst, 'reload config';
notify pgrst, 'reload schema';
select 'Multiempresa listo' as resultado;
