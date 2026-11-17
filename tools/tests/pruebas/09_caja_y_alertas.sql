-- Etapa 3: ubicación, cotización → caja, devolución dañada, abonos en caja, alertas y resumen diario.
do $$
declare r jsonb; v_id uuid; v_venta uuid; n numeric; t text; ok boolean;
begin
  if to_regprocedure('public.caja_cobrar_abono(jsonb)') is null then raise notice 'OMITIDA: falta la etapa 3'; return; end if;

  -- ---------- Ubicación ----------
  perform set_config('request.headers', '{"x-refrimar-sesion":"tok-admin"}', true);
  r := producto_ubicacion_guardar('A001', null, '  Pasillo 3 · estante B ');
  assert (select ubicacion from productos where codigo = 'A001') = 'Pasillo 3 · estante B', 'no guardó la ubicación en la Principal';
  r := producto_ubicacion_guardar('B001', '00000000-0000-0000-0000-0000000000a2', 'Mostrador');
  assert (select ubicacion from sucursal_stock where producto_codigo = 'B001' and sucursal_id = '00000000-0000-0000-0000-0000000000a2') = 'Mostrador', 'no guardó la ubicación en la Sucursal';
  assert (select ubicacion from productos where codigo = 'B001') is null, 'la ubicación de la Sucursal pisó la de la Principal';
  perform set_config('request.headers', '{"x-refrimar-sesion":"tok-cajera"}', true);
  ok := false; begin perform producto_ubicacion_guardar('A001', null, 'X'); exception when others then ok := true; end;
  assert ok, 'la cajera (sin editar inventario) pudo cambiar la ubicación';

  -- ---------- Cotización → caja ----------
  perform set_config('request.headers', '{"x-refrimar-sesion":"tok-admin"}', true);
  v_id := cotizacion_guardar('COT-T1', '[{"producto_codigo":"A001","descripcion":"PRODUCTO A","cantidad":2,"precio_unitario":2,"total":4}]'::jsonb, 'CLIENTE X');
  perform set_config('request.headers', '{"x-refrimar-sesion":"tok-cajera"}', true);
  r := cotizacion_convertir(v_id, 'F-123');
  assert (select estado = 'convertida' and venta_numero = 'F-123' and convertida_at is not null from cotizaciones where id = v_id), 'la cotización no quedó convertida';
  r := cotizacion_convertir(v_id, 'F-999');
  assert (r->>'ya_estaba')::boolean and (select venta_numero from cotizaciones where id = v_id) = 'F-123', 'convertir dos veces cambió la factura';

  -- ---------- Devolución con producto dañado ----------
  insert into ventas (numero, subtotal, iva, total_usd, tasa_bcv, total_bs, metodo_pago, sucursal_id, sucursal_nombre)
  values ('T-NC1', 10, 0, 10, 40, 400, 'efectivo', '00000000-0000-0000-0000-000000000001', 'Principal') returning id into v_venta;
  insert into detalle_venta (venta_id, producto_codigo, descripcion, cantidad, precio_unitario, total) values
    (v_venta, 'A001', 'PRODUCTO A', 3, 2, 6), (v_venta, 'B001', 'PRODUCTO B', 1, 4, 4);
  update productos set stock = 10 where codigo = 'A001';
  update productos set stock = 3 where codigo = 'B001';
  r := nota_credito_registrar(v_venta, '[{"codigo":"A001","cantidad":2,"danado":true},{"codigo":"B001","cantidad":1}]'::jsonb, 'prueba', 'CAJERA PRUEBA');
  assert (select stock from productos where codigo = 'A001') = 10, 'el producto dañado volvió al inventario';
  assert (select stock from productos where codigo = 'B001') = 4, 'el producto bueno no volvió al inventario';
  assert (select danado from notas_credito_detalle d join notas_credito c on c.id = d.nota_id where c.venta_id = v_venta and d.producto_codigo = 'A001'), 'no quedó marcado como dañado';
  select costo_total into n from kardex_movimientos where tipo = 'devolucion_danada' and producto_codigo = 'A001' order by created_at desc limit 1;
  assert n = 2, 'el kardex no anotó el costo de lo dañado: ' || coalesce(n::text, 'null');
  assert (select sum(cantidad) from kardex_movimientos where tipo = 'devolucion_danada') = 0, 'lo dañado movió el saldo del kardex';
  assert (r->>'total_usd')::numeric = 8, 'el reembolso debe incluir lo dañado: ' || (r->>'total_usd');
  -- No se puede devolver más de lo vendido contando lo dañado
  ok := false; begin perform nota_credito_registrar(v_venta, '[{"codigo":"A001","cantidad":2,"danado":true}]'::jsonb, null, 'X'); exception when others then ok := true; end;
  assert ok, 'dejó devolver más de lo vendido';

  -- ---------- Abonos desde la caja ----------
  insert into clientes (nombre, rif, saldo_pendiente) values ('CLIENTE CREDITO', 'J-11112222', 30);
  insert into ventas (numero, cliente_nombre, cliente_rif, subtotal, iva, total_usd, tasa_bcv, total_bs, metodo_pago, created_at, dias_credito)
  values ('T-CR1', 'CLIENTE CREDITO', 'J-11112222', 10, 0, 10, 40, 400, 'credito', now() - interval '5 days', 1),
         ('T-CR2', 'CLIENTE CREDITO', 'J-11112222', 20, 0, 20, 40, 800, 'credito', now(), 30);
  perform set_config('request.headers', '{"x-refrimar-sesion":"tok-cajera"}', true);
  r := caja_deudas_buscar('j-1111');
  assert jsonb_array_length(r) = 1 and (r->0->>'saldo')::numeric = 30 and (r->0->>'vencidas')::int = 1, 'el buscador de deudas falló: ' || r::text;
  t := r->0->>'clave';
  assert jsonb_array_length(caja_deudas_buscar('T-CR2')) = 1, 'no encuentra por número de factura';
  r := caja_cobrar_abono(jsonb_build_object('clave', t, 'monto_usd', 15, 'metodo', 'pago_movil', 'tasa', 40, 'sucursal_id', '00000000-0000-0000-0000-000000000001', 'referencia', '1234'));
  assert (select monto_abonado from ventas where numero = 'T-CR1') = 10, 'no saldó primero la deuda más vieja';
  assert (select monto_abonado from ventas where numero = 'T-CR2') = 5, 'no pasó el resto a la siguiente deuda';
  assert jsonb_array_length(r->'saldadas') = 1 and r->'saldadas'->>0 = (select coalesce(numero_doc, numero) from ventas where numero = 'T-CR1') and (r->>'saldo_restante')::numeric = 15, 'respuesta del abono: ' || r::text;
  assert (select saldo_pendiente from clientes where rif = 'J-11112222') = 15, 'no rebajó el saldo del cliente';
  assert exists (select 1 from caja_movimientos where tipo = 'ingreso' and metodo_pago = 'pago_movil' and monto_usd = 15 and monto_bs = 600
                 and usuario_nombre = 'CAJERA PRUEBA' and concepto like 'Abono de cliente CLIENTE CREDITO%'), 'el abono no entró a la caja en Bs con el usuario de la sesión';
  assert (select count(*) from abonos_ventas where usuario_nombre = 'CAJERA PRUEBA') = 2, 'debían quedar dos abonos';
  ok := false; begin perform caja_cobrar_abono(jsonb_build_object('clave', t, 'monto_usd', 16, 'metodo', 'efectivo', 'tasa', 40)); exception when others then ok := true; end;
  assert ok, 'dejó cobrar más de lo que debe';
  ok := false; begin perform caja_cobrar_abono(jsonb_build_object('clave', t, 'monto_usd', 1, 'metodo', 'credito', 'tasa', 40)); exception when others then ok := true; end;
  assert ok, 'aceptó un método de pago inválido';
  r := caja_cobrar_abono(jsonb_build_object('clave', t, 'monto_usd', 15, 'metodo', 'divisa', 'tasa', 40));
  assert (select monto_abonado from ventas where numero = 'T-CR2') = 20, 'no saldó la segunda deuda';
  assert jsonb_array_length(caja_deudas_buscar('J-11112222')) = 0, 'el cliente sigue apareciendo con deuda';
  perform set_config('request.headers', '{}', true);
  ok := false; begin perform caja_cobrar_abono(jsonb_build_object('clave', t, 'monto_usd', 1, 'metodo', 'efectivo')); exception when others then ok := true; end;
  assert ok, 'cobró un abono sin sesión';

  -- ---------- Alertas ----------
  insert into ventas (numero, cliente_nombre, subtotal, iva, total_usd, tasa_bcv, total_bs, metodo_pago, created_at, dias_credito)
  values ('T-CR3', 'OTRO', 5, 0, 5, 40, 200, 'credito', now() - interval '10 days', 2) returning id into v_venta;
  insert into detalle_venta (venta_id, producto_codigo, descripcion, cantidad, precio_unitario, total) values (v_venta, 'C001', 'PRODUCTO C', 1, 5, 5);
  perform set_config('request.headers', '{"x-refrimar-sesion":"tok-cajera"}', true);
  r := alertas_resumen();
  assert r @> '[{"clave":"negativo"}]' and r @> '[{"clave":"agotados"}]', 'la cajera no ve las alertas de inventario: ' || r::text;
  assert not (r @> '[{"clave":"perdida"}]') and not (r @> '[{"clave":"cxc_vencidas"}]'), 'la cajera ve costos o deudas: ' || r::text;
  perform set_config('request.headers', '{"x-refrimar-sesion":"tok-admin"}', true);
  r := alertas_resumen();
  assert r @> '[{"clave":"perdida"}]' and r @> '[{"clave":"cxc_vencidas","cantidad":1}]' and r @> '[{"clave":"danados"}]', 'al admin le faltan alertas: ' || r::text;

  -- ---------- Resumen diario ----------
  r := resumen_diario();
  assert r->>'texto' like '📊 REFRIMAR — Resumen del %' and r->>'texto' like '%Para revisar:%', 'resumen: ' || coalesce(r->>'texto', 'null');
  assert r->>'texto' like '%Abonos cobrados: 30,00 $%', 'el resumen no trae los abonos: ' || (r->>'texto');
  perform set_config('request.headers', '{"x-refrimar-sesion":"tok-cajera"}', true);
  ok := false; begin perform resumen_diario(); exception when others then ok := true; end;
  assert ok, 'la cajera pudo ver el resumen del día';
  perform set_config('request.headers', '{}', true);
  ok := false; begin perform resumen_diario(); exception when others then ok := true; end;
  assert ok, 'el resumen se pudo ver sin sesión ni token de servicio';
  update seguridad_config set servicio_token_hash = refrimar_hash('srv-prueba') where id = 1;
  perform set_config('request.headers', '{"x-refrimar-servicio":"srv-prueba"}', true);
  r := resumen_diario();
  assert r ? 'texto', 'el Worker (token de servicio) no pudo pedir el resumen';
  assert refrimar_fmt(1234.5) = '1.234,50', 'formato de montos: ' || refrimar_fmt(1234.5);
end $$;
