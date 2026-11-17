-- Etapa 4a: cajas → unidades, cambios masivos con deshacer, duplicados y buscador general.
do $$
declare r jsonb; v_id uuid; ok boolean; n numeric;
begin
  if to_regprocedure('public.buscar_global(text)') is null then raise notice 'OMITIDA: falta la etapa 4a'; return; end if;
  perform set_config('request.headers', '{"x-refrimar-sesion":"tok-admin"}', true);

  -- ---------- Cajas → unidades ----------
  update productos set stock = 10, costo = 1 where codigo = 'A001';
  r := recepcion_registrar(jsonb_build_object('crear_cxp', false, 'items', jsonb_build_array(
         jsonb_build_object('codigo', 'A001', 'cantidad', 2, 'costo', 12, 'unidades_por_caja', 12, 'codigo_alterno', 'CAJA-A001'))));
  assert (select stock from productos where codigo = 'A001') = 34, 'no convirtió 2 cajas de 12 en 24 unidades: ' || (select stock from productos where codigo = 'A001');
  assert (select costo from productos where codigo = 'A001') = 1, 'el costo por unidad debía quedar en 1 (12 $ la caja / 12)';
  assert (select empaques @> '[{"barra":"CAJA-A001","cantidad":12}]' from productos where codigo = 'A001'), 'no recordó el código de la caja como empaque';
  assert not (select coalesce(codigos_alternos, '{}') @> array['CAJA-A001'] from productos where codigo = 'A001'), 'el código de la caja quedó como código alterno de la unidad';
  r := recepcion_registrar(jsonb_build_object('crear_cxp', false, 'items', jsonb_build_array(
         jsonb_build_object('codigo', 'A001', 'cantidad', 1, 'costo', 12, 'unidades_por_caja', 12, 'codigo_alterno', 'CAJA-A001'))));
  assert (select jsonb_array_length(empaques) from productos where codigo = 'A001') = 1, 'repitió el empaque';
  ok := false; begin perform recepcion_registrar(jsonb_build_object('crear_cxp', false, 'items', jsonb_build_array(
         jsonb_build_object('codigo', 'A001', 'cantidad', 1, 'costo', 1, 'unidades_por_caja', 0.5)))); exception when others then ok := true; end;
  assert ok, 'aceptó unidades por caja menores a 1';

  -- ---------- Cambios masivos + deshacer ----------
  update productos set categoria = 'VIEJA' where codigo = 'A001';
  update productos set categoria = null where codigo = 'B001';
  r := productos_cambio_masivo(array['A001', 'B001'], 'categoria', 'PLOMERIA', null);
  assert (r->>'cambiados')::int = 2 and (select count(*) from productos where categoria = 'PLOMERIA') = 2, 'cambio de categoría: ' || r::text;
  v_id := (r->>'id')::uuid;
  r := productos_cambio_masivo(array['A001', 'B001'], 'categoria', 'PLOMERIA', null);
  assert (r->>'cambiados')::int = 0, 'contó como cambiados los que ya tenían ese valor';
  r := productos_cambio_deshacer(v_id);
  assert (select categoria from productos where codigo = 'A001') = 'VIEJA' and (select categoria from productos where codigo = 'B001') is null, 'deshacer no devolvió las categorías';
  ok := false; begin perform productos_cambio_deshacer(v_id); exception when others then ok := true; end;
  assert ok, 'dejó deshacer dos veces';
  r := productos_cambio_masivo(array['A001'], 'stock_minimo', '7,5', null);
  assert (select stock_minimo from productos where codigo = 'A001') = 7.5, 'stock mínimo con coma';
  r := productos_cambio_masivo(array['A001', 'B001'], 'proveedor', 'FERCOVEN', null);
  assert (select proveedores @> array['FERCOVEN'] from productos where codigo = 'B001'), 'no agregó el proveedor';
  r := productos_cambio_masivo(array['A001', 'B001'], 'proveedor', 'FERCOVEN', null);
  assert (select cardinality(array_positions(proveedores, 'FERCOVEN')) from productos where codigo = 'B001') = 1, 'repitió el proveedor';
  r := productos_cambio_masivo(array['A001', 'B001'], 'ubicacion', 'Pasillo 9', '00000000-0000-0000-0000-0000000000a2');
  assert (select count(*) from sucursal_stock where sucursal_id = '00000000-0000-0000-0000-0000000000a2' and ubicacion = 'Pasillo 9') = 2, 'ubicación masiva en la Sucursal';
  r := productos_cambio_deshacer((r->>'id')::uuid);
  assert (select count(*) from sucursal_stock where sucursal_id = '00000000-0000-0000-0000-0000000000a2' and ubicacion = 'Pasillo 9') = 0, 'deshacer ubicación en la Sucursal';
  ok := false; begin perform productos_cambio_masivo(array['A001'], 'precio', '1', null); exception when others then ok := true; end;
  assert ok, 'dejó cambiar el precio por esta vía';
  assert jsonb_array_length(productos_cambios_recientes()) >= 4, 'no lista los cambios recientes';
  perform set_config('request.headers', '{"x-refrimar-sesion":"tok-cajera"}', true);
  ok := false; begin perform productos_cambio_masivo(array['A001'], 'marca', 'X', null); exception when others then ok := true; end;
  assert ok, 'la cajera pudo hacer un cambio masivo';

  -- ---------- Duplicados ----------
  perform set_config('request.headers', '{"x-refrimar-sesion":"tok-admin"}', true);
  insert into productos (codigo, descripcion, precio, stock) values
    ('D1', 'TUBO PVC AGUAS BLANCAS 1/2', 2, 1), ('D2', 'TUBO PVC AGUA BLANCA 1/2', 2, 1), ('D3', 'TUBO PVC AGUAS BLANCAS 3/4', 3, 1);
  r := productos_duplicados(0.5);
  assert r @> '[{"a":{"codigo":"D1"},"b":{"codigo":"D2"}}]', 'no detectó D1/D2: ' || r::text;
  assert not (r @> '[{"a":{"codigo":"D1"},"b":{"codigo":"D3"}}]') and not (r @> '[{"a":{"codigo":"D2"},"b":{"codigo":"D3"}}]'), '1/2 y 3/4 salieron como duplicados';
  r := productos_duplicado_descartar('D2', 'D1');
  assert not (productos_duplicados(0.5) @> '[{"a":{"codigo":"D1"},"b":{"codigo":"D2"}}]'), 'el par descartado sigue saliendo';
  assert refrimar_medidas('Codo 1/2 x 90°') = '1/2 90', 'medidas: ' || refrimar_medidas('Codo 1/2 x 90°');

  -- ---------- Buscador ----------
  r := buscar_global('tubo pvc');
  assert jsonb_array_length(r->'productos') >= 3, 'el buscador no trae productos: ' || r::text;
  r := buscar_global('CAJA-A001');
  assert r->'productos' is not null, 'buscador por código';
  perform set_config('request.headers', '{"x-refrimar-sesion":"tok-cajera"}', true);
  r := buscar_global('fercoven');
  assert not (r ? 'proveedores') and not (r ? 'cotizaciones'), 'la cajera ve proveedores o cotizaciones: ' || r::text;
  perform set_config('request.headers', '{}', true);
  ok := false; begin perform buscar_global('tubo'); exception when others then ok := true; end;
  assert ok, 'el buscador funciona sin sesión';
end $$;
