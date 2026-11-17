-- El registro de migraciones existe y no se ve desde la app (anon / authenticated).
\set ON_ERROR_STOP 1
do $$ begin
  if to_regclass('public.migraciones_aplicadas') is null then
    raise notice 'OMITIDA: falta correr el SQL de la etapa 0'; return;
  end if;
  assert exists (select 1 from migraciones_aplicadas where nombre = '2026-11-16-etapa0-estructura'), 'no quedó anotada la etapa 0';
  assert not has_table_privilege('anon', 'public.migraciones_aplicadas', 'select'), 'anon puede leer el registro';
  assert not has_table_privilege('authenticated', 'public.migraciones_aplicadas', 'select'), 'authenticated puede leer el registro';
end $$;
