-- Etapa 4b: garantías, despachos, conciliación y consultas del asistente.
do $$
declare r jsonb; v_venta uuid; v_g uuid; v_d uuid; ok boolean; n numeric;
begin
  if to_regprocedure('public.despacho_crear(jsonb)') is null then raise notice 'OMITIDA: falta la etapa 4b'; return; end if;
  update productos set stock = 10, costo = 1, garantia_dias = 90 where codigo = 'A001';
  insert into ventas (numero, cliente_nombre, cliente_telefono, subtotal, iva, total_usd, tasa_bcv, total_bs, metodo_pago, sucursal_id, pagos, created_at)
  values ('T-G1', 'MARIA OBRA', '0414-1', 10, 0, 10, 40, 400, 'pago_movil', '00000000-0000-0000-0000-000000000001',
          '[{"metodo":"pago_movil","moneda":"VES","banco":"Banesco","referencia":"00123456","monto":400,"monto_bs":400,"monto_usd":10}]', now() - interval '1 day')
  returning id into v_venta;
  insert into detalle_venta (venta_id, producto_codigo, descripcion, cantidad, precio_unitario, total) values
    (v_venta, 'A001', 'PRODUCTO A', 3, 2, 6), (v_venta, 'B001', 'PRODUCTO B', 1, 4, 4);

  -- ---------- Garantías ----------
  perform set_config('request.headers', '{"x-refrimar-sesion":"tok-cajera"}', true);
  r := garantia_registrar(jsonb_build_object('venta_id', v_venta, 'producto_codigo', 'A001', 'cantidad', 1, 'falla', 'No enciende', 'serial', 'SN1'));
  v_g := (r->>'id')::uuid;
  assert r->>'numero' like 'GAR-%' and (r->>'dentro_garantia')::boolean, 'garantía: ' || r::text;
  assert (select vence from garantias where id = v_g) = (now() at time zone 'America/Caracas')::date - 1 + 90, 'vencimiento de la garantía';
  ok := false; begin perform garantia_registrar(jsonb_build_object('venta_id', v_venta, 'producto_codigo', 'C001', 'falla', 'x')); exception when others then ok := true; end;
  assert ok, 'registró garantía de un producto que no está en la factura';
  ok := false; begin perform garantia_registrar(jsonb_build_object('venta_id', v_venta, 'producto_codigo', 'A001', 'cantidad', 5, 'falla', 'x')); exception when others then ok := true; end;
  assert ok, 'registró más unidades de las vendidas';
  ok := false; begin perform garantia_estado(v_g, 'lista'); exception when others then ok := true; end;
  assert ok, 'dejó marcar lista sin decir qué se hizo';
  r := garantia_estado(v_g, 'en_proveedor', 'Enviada a MAXCAM', null, 'MAXCAM');
  r := garantia_estado(v_g, 'lista', 'Se cambió', 'cambiado', null, true);
  assert (select stock from productos where codigo = 'A001') = 9, 'el cambio no descontó la unidad nueva del inventario';
  r := garantia_estado(v_g, 'entregada', null, null, null, true);
  assert (select stock from productos where codigo = 'A001') = 9, 'descontó dos veces el cambio';
  assert (select jsonb_array_length(historial) = 4 and proveedor = 'MAXCAM' and resolucion = 'cambiado' from garantias where id = v_g), 'historial de la garantía';
  ok := false; begin perform garantia_estado(v_g, 'recibida'); exception when others then ok := true; end;
  assert ok, 'dejó cambiar una garantía cerrada';

  -- ---------- Despachos ----------
  r := despacho_crear(jsonb_build_object('venta_id', v_venta, 'tipo', 'obra', 'direccion', 'Obra La Trinidad', 'fecha_programada', current_date - 1,
                                         'items', jsonb_build_array(jsonb_build_object('codigo', 'A001', 'cantidad', 2))));
  v_d := (r->>'id')::uuid;
  assert (r->>'lineas')::int = 1, 'despacho con una línea';
  r := despacho_crear(jsonb_build_object('venta_id', v_venta, 'tipo', 'domicilio', 'direccion', 'Casa'));
  assert (select sum(cantidad) from despacho_detalle where despacho_id = (r->>'id')::uuid) = 2, 'el segundo despacho debía llevar lo que faltaba (1 A001 + 1 B001)';
  ok := false; begin perform despacho_crear(jsonb_build_object('venta_id', v_venta, 'direccion', 'X')); exception when others then ok := true; end;
  assert ok, 'dejó despachar más de lo vendido';
  ok := false; begin perform despacho_crear(jsonb_build_object('venta_id', v_venta, 'tipo', 'obra')); exception when others then ok := true; end;
  assert ok, 'despacho a obra sin dirección';
  r := despacho_estado(v_d, 'en_ruta', 'PEDRO');
  r := despacho_entregar(v_d, '[{"codigo":"A001","cantidad":1}]'::jsonb, 'Maestro de obra', null);
  assert r->>'estado' = 'parcial', 'entrega parcial';
  ok := false; begin perform despacho_entregar(v_d, '[{"codigo":"A001","cantidad":5}]'::jsonb); exception when others then ok := true; end;
  assert ok, 'dejó entregar de más';
  ok := false; begin perform despacho_estado(v_d, 'cancelado'); exception when others then ok := true; end;
  assert ok, 'dejó cancelar un despacho ya entregado en parte';
  r := despacho_entregar(v_d, null, 'Maestro', null);
  assert r->>'estado' = 'entregado' and (select entregado_at is not null and chofer = 'PEDRO' from despachos where id = v_d), 'entrega final';
  assert (select count(*) from despacho_entregas where despacho_id = v_d) = 2, 'registro de entregas';

  -- ---------- Alertas: despacho atrasado ----------
  perform set_config('request.headers', '{"x-refrimar-sesion":"tok-admin"}', true);
  update despachos set fecha_programada = current_date - 3 where id <> v_d;
  assert alertas_resumen() @> '[{"clave":"despachos"}]', 'no avisa el despacho atrasado';

  -- ---------- Conciliación ----------
  r := conciliacion_pagos(current_date - 3, current_date);
  assert r @> '[{"origen":"venta","referencia":"00123456","monto_bs":400}]', 'conciliación no trae el pago móvil: ' || r::text;
  perform set_config('request.headers', '{"x-refrimar-sesion":"tok-cajera"}', true);
  ok := false; begin perform conciliacion_pagos(current_date - 3, current_date); exception when others then ok := true; end;
  assert ok, 'la cajera pudo ver la conciliación';

  -- ---------- Consultas del asistente ----------
  r := consulta_datos('producto_info', '{"q":"PRODUCTO A"}');
  assert r->0->>'codigo' = 'A001' and r->0->'costo_usd' = 'null'::jsonb, 'producto_info para la cajera (sin costo): ' || r::text;
  r := consulta_datos('ventas_resumen', '{}');
  assert r ? 'error', 'la cajera vio el resumen de ventas';
  perform set_config('request.headers', '{"x-refrimar-sesion":"tok-admin"}', true);
  r := consulta_datos('ventas_resumen', jsonb_build_object('desde', current_date - 3, 'hasta', current_date));
  assert (r->'por_tienda'->0->>'total_usd')::numeric >= 10 and r ? 'utilidad_usd', 'ventas_resumen: ' || r::text;
  r := consulta_datos('productos_top', jsonb_build_object('desde', current_date - 3, 'orden', 'cantidad'));
  assert r->'productos'->0->>'codigo' = 'A001', 'productos_top: ' || r::text;
  assert jsonb_typeof(consulta_datos('clientes_deudas', '{}')) = 'array', 'clientes_deudas';
  assert consulta_datos('inventario_valor', '{}') ? 'principal_costo_usd', 'inventario_valor';
  assert jsonb_typeof(consulta_datos('sin_movimiento', '{"dias":30}')) = 'array', 'sin_movimiento';
  assert consulta_datos('borrar_todo', '{}') ? 'error', 'consulta desconocida';
end $$;
do $$
declare r jsonb;
begin
  if to_regprocedure('public.despacho_crear(jsonb)') is null then return; end if;
  perform set_config('request.headers', '{"x-refrimar-sesion":"tok-admin"}', true);
  update productos set garantia_dias = null where codigo in ('A001', 'B001');
  r := productos_cambio_masivo(array['A001', 'B001'], 'garantia_dias', '180', null);
  assert (select count(*) from productos where garantia_dias = 180) = 2, 'garantía masiva';
  r := productos_cambio_deshacer((r->>'id')::uuid);
  assert (select count(*) from productos where garantia_dias is null and codigo in ('A001', 'B001')) = 2, 'deshacer garantía';
  r := productos_cambio_masivo(array['A001'], 'garantia_dias', '30', null);
  r := productos_cambio_masivo(array['A001'], 'garantia_dias', null, null);
  assert (select garantia_dias from productos where codigo = 'A001') is null, 'quitar garantía';
end $$;
