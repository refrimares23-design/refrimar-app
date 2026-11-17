-- La vía vieja de la caja (sin revisar precios) ya no se puede llamar desde la página.
do $$
declare f regprocedure; n int := 0;
begin
  for f in select p.oid::regprocedure from pg_proc p join pg_namespace s on s.oid = p.pronamespace
           where s.nspname = 'public' and p.proname = 'registrar_venta' loop
    n := n + 1;
    assert not has_function_privilege('anon', f, 'execute'), format('anon puede llamar %s', f);
    assert not has_function_privilege('authenticated', f, 'execute'), format('authenticated puede llamar %s', f);
  end loop;
  if n = 0 then raise notice 'OMITIDA: no existe registrar_venta'; end if;
  assert has_function_privilege('anon', 'public.pos_facturar(jsonb)', 'execute'), 'la caja normal quedó cerrada';
end $$;
