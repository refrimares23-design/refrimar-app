-- Etapa 6: guardián de la API sin fallas abiertas, proveedores por funciones y mínimos según ventas.
do $$
declare r jsonb; ok boolean; v_id uuid; v_estado text;
begin
  if to_regprocedure('public.productos_minimos_aplicar(jsonb)') is null then raise notice 'OMITIDA: falta la etapa 6'; return; end if;

  -- ---------- Guardián ----------
  insert into seguridad_rpc (nombre, nivel, permiso, gracia_dias) values ('prueba_servicio', 'servicio', null, 0) on conflict do nothing;
  update seguridad_config set modo = 'estricto', servicio_token_hash = null where id = 1;
  perform set_config('request.path', '/rpc/prueba_servicio', true);
  perform set_config('request.method', 'POST', true);
  perform set_config('request.headers', '{}', true);
  v_estado := null; begin perform refrimar_pre_request(); exception when others then v_estado := sqlstate; end;
  assert v_estado = 'PT401', 'sin token de servicio configurado, una función de servicio quedaba abierta: ' || coalesce(v_estado, 'pasó');
  update seguridad_config set servicio_token_hash = refrimar_hash('srv-ok') where id = 1;
  perform set_config('request.headers', '{"x-refrimar-servicio":"srv-ok"}', true);
  perform refrimar_pre_request();   -- con el token correcto pasa
  perform set_config('request.headers', '{"x-refrimar-servicio":"malo"}', true);
  v_estado := null; begin perform refrimar_pre_request(); exception when others then v_estado := sqlstate; end;
  assert v_estado = 'PT401', 'token de servicio equivocado pasó';
  perform set_config('request.headers', '{"x-refrimar-sesion":"tok-admin"}', true);
  perform refrimar_pre_request();   -- un administrador con sesión sí puede
  -- Falla inesperada dentro del guardián: en modo estricto se bloquea
  perform set_config('request.path', '/rpc/otra_cosa', true);
  execute 'alter table public.usuarios rename to usuarios_tmp_prueba';
  v_estado := null; begin perform refrimar_pre_request(); exception when others then v_estado := sqlstate; end;
  execute 'alter table public.usuarios_tmp_prueba rename to usuarios';
  assert v_estado = 'PT503', 'una falla inesperada dejó pasar la petición: ' || coalesce(v_estado, 'pasó');
  perform set_config('request.path', '', true);

  -- ---------- Proveedores y categorías ----------
  assert not has_table_privilege('anon', 'public.proveedores', 'insert') and not has_table_privilege('anon', 'public.proveedores', 'delete'), 'proveedores se pueden cambiar por fuera';
  assert has_table_privilege('anon', 'public.proveedores', 'select'), 'proveedores ya no se pueden leer';
  perform set_config('request.headers', '{"x-refrimar-sesion":"tok-admin"}', true);
  r := proveedor_guardar('{"nombre":"  TUBOS DEL CENTRO ","rif":"j-30111222-3","telefono":"0212"}');
  v_id := (r->>'id')::uuid;
  assert r->>'nombre' = 'TUBOS DEL CENTRO' and r->>'rif' = 'J-30111222-3', 'proveedor_guardar: ' || r::text;
  ok := false; begin perform proveedor_guardar('{"nombre":"OTRO","rif":"J301112223"}'); exception when others then ok := true; end;
  assert ok, 'dejó repetir el RIF';
  r := proveedor_guardar(jsonb_build_object('id', v_id, 'nombre', 'TUBOS DEL CENTRO CA', 'rif', 'J-30111222-3'));
  assert (select nombre from proveedores where id = v_id) = 'TUBOS DEL CENTRO CA', 'editar proveedor';
  r := proveedor_eliminar(v_id);
  assert not exists (select 1 from proveedores where id = v_id), 'eliminar proveedor';
  r := gasto_categoria_guardar('Fletes');
  r := gasto_categoria_guardar('fletes');
  assert (select count(*) from gasto_categorias where lower(nombre) = 'fletes') = 1, 'categoría repetida';
  r := gasto_categoria_eliminar((r->>'id')::uuid);
  perform set_config('request.headers', '{"x-refrimar-sesion":"tok-cajera"}', true);
  ok := false; begin perform proveedor_guardar('{"nombre":"X"}'); exception when others then ok := true; end;
  assert ok, 'la cajera pudo crear proveedores';

  -- ---------- Mínimos según ventas ----------
  perform set_config('request.headers', '{"x-refrimar-sesion":"tok-admin"}', true);
  insert into ventas (numero, subtotal, iva, total_usd, tasa_bcv, total_bs, metodo_pago, created_at)
  select 'T-MIN' || g, 1, 0, 1, 40, 40, 'efectivo', now() - make_interval(days => g) from generate_series(1, 6) g;
  insert into detalle_venta (venta_id, producto_codigo, descripcion, cantidad, precio_unitario, total)
  select id, 'B001', 'PRODUCTO B', 10, 4, 40 from ventas where numero like 'T-MIN%';
  update productos set stock_minimo = 5 where codigo in ('A001', 'B001');
  r := productos_minimos_sugeridos(60, 7);
  -- B001: 60 unidades en 60 días = 1 por día → 7 para una semana
  assert (select (x->>'sugerido')::numeric from jsonb_array_elements(r) x where x->>'codigo' = 'B001') = 7, 'mínimo sugerido de B001: ' || r::text;
  r := productos_minimos_aplicar('[{"codigo":"A001","minimo":0},{"codigo":"B001","minimo":7}]');
  assert (r->>'cambiados')::int = 2 and (select stock_minimo from productos where codigo = 'B001') = 7 and (select stock_minimo from productos where codigo = 'A001') = 0, 'aplicar mínimos';
  r := productos_cambio_deshacer((r->>'id')::uuid);
  assert (select count(*) from productos where codigo in ('A001', 'B001') and stock_minimo = 5) = 2, 'deshacer mínimos';
  perform set_config('request.headers', '{"x-refrimar-sesion":"tok-cajera"}', true);
  ok := false; begin perform productos_minimos_aplicar('[{"codigo":"A001","minimo":1}]'); exception when others then ok := true; end;
  assert ok, 'la cajera pudo cambiar mínimos';
end $$;
