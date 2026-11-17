-- Etapa 5: productos solo por funciones, arreglos de permisos y unir duplicados.
do $$
declare r jsonb; v_id uuid; ok boolean;
begin
  if to_regprocedure('public.productos_fusionar(text,text)') is null then raise notice 'OMITIDA: falta la etapa 5'; return; end if;
  assert not has_table_privilege('anon', 'public.productos', 'update'), 'anon puede modificar productos';
  assert not has_table_privilege('anon', 'public.productos', 'insert'), 'anon puede crear productos';
  assert has_table_privilege('anon', 'public.productos', 'select'), 'anon ya no puede leer productos';
  assert not has_table_privilege('anon', 'public.sucursal_stock', 'truncate'), 'anon puede vaciar sucursal_stock';
  if to_regprocedure('public.cierre_diario_guardar(date,numeric,numeric,numeric,numeric,numeric,numeric,numeric,numeric,numeric,numeric,numeric,uuid,text,text)') is not null then
    assert (select prosecdef from pg_proc where oid = 'public.cierre_diario_guardar(date,numeric,numeric,numeric,numeric,numeric,numeric,numeric,numeric,numeric,numeric,numeric,uuid,text,text)'::regprocedure), 'cierre_diario_guardar sigue sin permisos del sistema';
  end if;

  -- Costo por tienda
  perform set_config('request.headers', '{"x-refrimar-sesion":"tok-admin"}', true);
  perform sucursal_stock_set_costo('00000000-0000-0000-0000-0000000000a2', 'C001', 3.5);
  assert (select costo from sucursal_stock where sucursal_id = '00000000-0000-0000-0000-0000000000a2' and producto_codigo = 'C001') = 3.5, 'costo por tienda';
  perform set_config('request.headers', '{"x-refrimar-sesion":"tok-cajera"}', true);
  ok := false; begin perform sucursal_stock_set_costo('00000000-0000-0000-0000-0000000000a2', 'C001', 1); exception when others then ok := true; end;
  assert ok, 'la cajera pudo cambiar costos';

  -- Unir duplicados
  perform set_config('request.headers', '{"x-refrimar-sesion":"tok-admin"}', true);
  insert into productos (codigo, descripcion, precio, costo, stock, codigos_alternos, empaques, proveedores) values
    ('Q1', 'TUBO PVC 1/2 PAVCO', 2, 1, 10, '{ALT-Q}', '[]', '{PAVCO}'),
    ('S1', 'TUBO PVC 1/2 PAVCO.', 2, 2, 10, '{ALT-S}', '[{"nombre":"Caja x 10","barra":"CJ-S","cantidad":10}]', '{FERCOVEN}');
  insert into sucursal_stock (sucursal_id, producto_codigo, producto_descripcion, stock, ubicacion) values
    ('00000000-0000-0000-0000-0000000000a2', 'S1', 'TUBO', 4, 'Pasillo 2');
  r := productos_fusionar('Q1', 'S1');
  v_id := (r->>'id')::uuid;
  assert (select stock from productos where codigo = 'Q1') = 20 and (select stock from productos where codigo = 'S1') = 0, 'existencia en la Principal';
  assert (select stock from sucursal_stock where producto_codigo = 'Q1' and sucursal_id = '00000000-0000-0000-0000-0000000000a2') = 4, 'existencia en la Sucursal';
  assert (select stock from sucursal_stock where producto_codigo = 'S1' and sucursal_id = '00000000-0000-0000-0000-0000000000a2') = 0, 'la Sucursal sigue con existencia del que sale';
  assert (select codigos_alternos @> array['S1', 'ALT-S', 'ALT-Q'] and empaques @> '[{"barra":"CJ-S"}]' and proveedores @> array['PAVCO', 'FERCOVEN'] from productos where codigo = 'Q1'), 'códigos, empaques o proveedores';
  assert (select costo from productos where codigo = 'Q1') = round((10 * 1 + 14 * 2)::numeric / 24, 6), 'costo promedio: ' || (select costo from productos where codigo = 'Q1');
  assert (select not activo and codigos_alternos = '{}' from productos where codigo = 'S1'), 'el que sale quedó activo o con códigos';
  assert (select count(*) from kardex_movimientos where referencia like 'Unión de duplicados: S1 → Q1%') = 4, 'kardex de la unión';
  ok := false; begin perform productos_fusionar('Q1', 'S1'); exception when others then ok := true; end;
  assert ok, 'dejó unir dos veces';
  assert jsonb_array_length(productos_fusiones_recientes()) >= 1, 'lista de uniones';
  r := productos_fusion_deshacer(v_id);
  assert (select stock from productos where codigo = 'Q1') = 10 and (select stock from productos where codigo = 'S1') = 10, 'deshacer: existencia';
  assert (select stock from sucursal_stock where producto_codigo = 'S1' and sucursal_id = '00000000-0000-0000-0000-0000000000a2') = 4, 'deshacer: Sucursal';
  assert (select activo and codigos_alternos = '{ALT-S}' from productos where codigo = 'S1'), 'deshacer: el que salió';
  assert (select codigos_alternos = '{ALT-Q}' and costo = 1 and empaques = '[]'::jsonb from productos where codigo = 'Q1'), 'deshacer: el que quedó';
  perform set_config('request.headers', '{"x-refrimar-sesion":"tok-cajera"}', true);
  ok := false; begin perform productos_fusionar('Q1', 'S1'); exception when others then ok := true; end;
  assert ok, 'la cajera pudo unir productos';
end $$;
