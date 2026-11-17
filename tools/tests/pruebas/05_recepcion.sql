-- Recepción de factura (Carga IA): todo o nada, stock + kardex + costo promedio + factura por pagar, sin repetidas.
do $$
declare r jsonb; v_err text; p record; n int;
begin
  if to_regprocedure('public.recepcion_registrar(jsonb)') is null then raise notice 'OMITIDA: falta recepcion_registrar'; return; end if;

  -- Sin sesión: no deja
  begin perform recepcion_registrar('{"items":[{"codigo":"A001","cantidad":1,"costo":1}]}'); v_err := null;
  exception when others then v_err := sqlerrm; end;
  assert v_err like '%sesión%', 'sin sesión debía fallar: ' || coalesce(v_err, 'pasó');

  -- Cajera sin permiso de inventario: no deja
  perform set_config('request.headers', '{"x-refrimar-sesion":"tok-cajera"}', true);
  begin perform recepcion_registrar('{"items":[{"codigo":"A001","cantidad":1,"costo":1}],"crear_cxp":false}'); v_err := null;
  exception when others then v_err := sqlerrm; end;
  assert v_err like '%permiso%', 'cajera sin permiso debía fallar: ' || coalesce(v_err, 'pasó');

  perform set_config('request.headers', '{"x-refrimar-sesion":"tok-admin"}', true);

  -- Factura normal en la Principal: A001 existe (10 a 1 $), llega 10 a 2 $; N001 es nuevo sin precio
  r := recepcion_registrar(jsonb_build_object(
        'proveedor', 'Fercoven', 'rif', 'J12345678-9', 'numero', 'B003694', 'fecha', '2026-11-10',
        'items', jsonb_build_array(
            jsonb_build_object('codigo', 'A001', 'cantidad', 10, 'costo', 2, 'codigo_alterno', '2040112597'),
            jsonb_build_object('codigo', 'N001', 'descripcion', 'NUEVO SIN PRECIO', 'cantidad', 5, 'costo', 0.1965, 'nuevo', true))));
  assert (r->>'nuevos')::int = 1 and (r->>'actualizados')::int = 1, 'conteo de nuevos/actualizados: ' || r;
  select * into p from productos where codigo = 'A001';
  assert p.stock = 20, 'stock de A001 debía ser 20, es ' || p.stock;
  assert round(p.costo, 4) = 1.5, 'costo promedio de A001 debía ser 1,5, es ' || p.costo;
  assert p.codigos_alternos @> array['2040112597'], 'no guardó el código del proveedor como alterno';
  select * into p from productos where codigo = 'N001';
  assert p.precio = 0 and p.stock = 5, 'el nuevo debía quedar sin precio y con 5: ' || p.precio || ' / ' || p.stock;
  assert round(p.costo, 4) = 0.1965, 'el costo del nuevo perdió decimales: ' || p.costo;
  assert jsonb_array_length(r->'sin_precio') = 1, 'debía avisar 1 producto sin precio';
  select count(*) into n from kardex_movimientos where producto_codigo in ('A001', 'N001') and referencia like 'Factura B003694%';
  assert n = 2, 'debía haber 2 movimientos de kardex, hay ' || n;
  select count(*) into n from compras_proveedores where numero = 'B003694' and monto_usd = 20.98 and proveedor_id = '00000000-0000-0000-0000-0000000f0001';
  assert n = 1, 'no se creó bien la factura por pagar';

  -- La misma factura otra vez, con el nombre escrito distinto y en la otra tienda: se rechaza
  begin
    perform recepcion_registrar(jsonb_build_object('proveedor', 'FERCOVEN C A', 'numero', 'b-003694',
            'sucursal_id', '00000000-0000-0000-0000-0000000000a2', 'items', jsonb_build_array(jsonb_build_object('codigo', 'A001', 'cantidad', 1, 'costo', 2))));
    v_err := null;
  exception when others then v_err := sqlerrm; end;
  assert v_err like '%ya está cargada%', 'la factura repetida debía rechazarse: ' || coalesce(v_err, 'pasó');
  select stock into n from productos where codigo = 'A001';
  assert n = 20, 'la factura rechazada movió stock';

  -- Todo o nada: una línea mala anula toda la factura
  begin
    perform recepcion_registrar(jsonb_build_object('proveedor', 'MAXCAM', 'numero', 'M-1',
            'items', jsonb_build_array(jsonb_build_object('codigo', 'A001', 'cantidad', 3, 'costo', 2),
                                       jsonb_build_object('codigo', 'NOEXISTE', 'cantidad', 1, 'costo', 1))));
    v_err := null;
  exception when others then v_err := sqlerrm; end;
  assert v_err like '%no existe%', 'la línea mala debía fallar: ' || coalesce(v_err, 'pasó');
  select stock into n from productos where codigo = 'A001';
  assert n = 20, 'quedó media factura guardada (stock ' || n || ')';
  assert not exists (select 1 from compras_proveedores where numero = 'M-1'), 'quedó la factura por pagar de una carga fallida';

  -- Factura en bolívares: 900 Bs a tasa 900 = 1 $; entra en la Sucursal (la Principal no cambia)
  r := recepcion_registrar(jsonb_build_object('proveedor', 'MAXCAM', 'numero', 'M-2', 'moneda', 'VES', 'tasa', 900,
        'sucursal_id', '00000000-0000-0000-0000-0000000000a2', 'sucursal_nombre', 'Sucursal',
        'items', jsonb_build_array(jsonb_build_object('codigo', 'B001', 'cantidad', 4, 'costo', 900))));
  assert (r->>'total_usd')::numeric = 4, 'la conversión de Bs dio ' || (r->>'total_usd');
  select stock into n from sucursal_stock where sucursal_id = '00000000-0000-0000-0000-0000000000a2' and producto_codigo = 'B001';
  assert n = 4, 'stock de la Sucursal debía ser 4, es ' || coalesce(n::text, 'nada');
  select stock into n from productos where codigo = 'B001';
  assert n = 3, 'la Principal no debía cambiar (es ' || n || ')';
  -- Precio por debajo del costo: guarda, pero avisa
  r := recepcion_registrar(jsonb_build_object('proveedor', 'MAXCAM', 'numero', 'M-4',
        'items', jsonb_build_array(jsonb_build_object('codigo', 'A001', 'cantidad', 1, 'costo', 3, 'precio', 1))));
  assert r->'avisos' @> '[{"codigo":"A001"}]', 'A001 quedó a pérdida y no avisó: ' || r;

  -- Falta la tasa en una factura en Bs
  begin
    perform recepcion_registrar('{"proveedor":"MAXCAM","numero":"M-3","moneda":"VES","items":[{"codigo":"B001","cantidad":1,"costo":900}]}');
    v_err := null;
  exception when others then v_err := sqlerrm; end;
  assert v_err like '%tasa%', 'sin tasa debía fallar';
end $$;
