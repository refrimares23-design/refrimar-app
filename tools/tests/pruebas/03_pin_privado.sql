-- Nadie puede leer el PIN con la clave pública; los demás datos del usuario sí se leen (login, equipo).
do $$ begin
  if to_regclass('public.usuarios') is null then raise notice 'OMITIDA: falta la tabla usuarios'; return; end if;
  assert not has_column_privilege('anon', 'public.usuarios', 'pin', 'select'), 'anon puede leer el PIN';
  assert not has_column_privilege('authenticated', 'public.usuarios', 'pin', 'select'), 'authenticated puede leer el PIN';
  assert has_column_privilege('anon', 'public.usuarios', 'nombre', 'select'), 'el login ya no puede leer los nombres';
  assert not has_table_privilege('anon', 'public.usuarios', 'update'), 'anon puede modificar usuarios';
end $$;
do $$ begin
  if to_regprocedure('public.login_usuario(text,text)') is null then raise notice 'OMITIDA: no existe login_usuario'; return; end if;
  assert not has_function_privilege('anon', 'public.login_usuario(text,text)', 'execute'), 'login_usuario (sin límite de intentos) sigue abierto';
  assert has_function_privilege('anon', 'public.sesion_iniciar_pin(text,text,text)', 'execute'), 'el login normal quedó cerrado';
end $$;
