-- Los respaldos no se ven desde la app.
do $$ begin
  if to_regnamespace('respaldo_inventario') is null then raise notice 'OMITIDA: no hay esquema de respaldos'; return; end if;
  assert not has_schema_privilege('anon', 'respaldo_inventario', 'usage'), 'anon entra a los respaldos';
  assert not has_schema_privilege('authenticated', 'respaldo_inventario', 'usage'), 'authenticated entra a los respaldos';
end $$;
