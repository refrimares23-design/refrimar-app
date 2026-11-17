-- Recibir contra una orden de compra: diferencias de precio, de más, no pedido y faltante; estado de la orden.
do $$
declare r jsonb; v_oc uuid; v_dif jsonb; n numeric; v_est text;
begin
  if to_regprocedure('public.orden_sugerida(uuid,uuid,integer,integer)') is null then raise notice 'OMITIDA: falta la etapa 2'; return; end if;
  perform set_config('request.headers', '{"x-refrimar-sesion":"tok-admin"}', true);
  r := oc_guardar(null, '00000000-0000-0000-0000-0000000f0002', 'MAXCAM', null, null, null, null, 'test', 'ordenada',
                  '[{"codigo":"A001","cantidad":10,"costo_unitario":2},{"codigo":"B001","cantidad":5,"costo_unitario":4}]'::jsonb);
  v_oc := (r->>'id')::uuid;

  -- Llega A001 más caro y un producto que no se pidió; B001 no llega
  r := recepcion_registrar(jsonb_build_object('orden_compra_id', v_oc, 'numero', 'MX-100',
        'items', jsonb_build_array(jsonb_build_object('codigo', 'A001', 'cantidad', 10, 'costo', 2.5),
                                   jsonb_build_object('codigo', 'X001', 'descripcion', 'NO PEDIDO', 'cantidad', 1, 'costo', 1, 'nuevo', true))));
  assert r->>'orden_estado' = 'parcial', 'la orden debía quedar parcial: ' || coalesce(r->>'orden_estado', 'null');
  assert r->'diferencias' @> '[{"codigo":"A001","tipo":"precio"}]', 'no marcó la diferencia de precio';
  assert r->'diferencias' @> '[{"codigo":"X001","tipo":"no_pedido"}]', 'no marcó el producto no pedido';
  assert r->'diferencias' @> '[{"codigo":"B001","tipo":"falta"}]', 'no marcó lo que falta';
  select diferencias into v_dif from compras_proveedores where id = (r->>'factura_id')::uuid;
  assert v_dif @> '[{"tipo":"precio"}]' and not (v_dif @> '[{"tipo":"falta"}]'), 'la factura guardó mal las diferencias: ' || v_dif;
  assert exists (select 1 from compras_proveedores where id = (r->>'factura_id')::uuid and orden_compra_id = v_oc and proveedor = 'MAXCAM'), 'la factura no quedó unida a la orden';
  select cantidad_recibida into n from compra_detalles where compra_id = v_oc and producto_codigo = 'A001';
  assert n = 10, 'cantidad recibida de A001: ' || n;

  -- Llega el resto: la orden queda recibida y sin diferencias
  r := recepcion_registrar(jsonb_build_object('orden_compra_id', v_oc, 'numero', 'MX-101',
        'items', jsonb_build_array(jsonb_build_object('codigo', 'B001', 'cantidad', 5, 'costo', 4))));
  assert r->>'orden_estado' = 'recibida', 'la orden debía quedar recibida';
  assert jsonb_array_length(r->'diferencias') = 0, 'no debía haber diferencias: ' || (r->'diferencias');

  -- Ya recibida: no deja recibir otra vez
  begin perform recepcion_registrar(jsonb_build_object('orden_compra_id', v_oc, 'numero', 'MX-102', 'items', '[{"codigo":"B001","cantidad":1,"costo":4}]'::jsonb));
        assert false, 'dejó recibir una orden ya recibida';
  exception when others then if sqlerrm not like '%no puede recibir%' then raise; end if; end;
end $$;

-- Recepción directa en la Principal: suma al stock de la Principal y crea la deuda en Cuentas por pagar
do $$
declare r jsonb; n numeric;
begin
  if to_regprocedure('public.orden_sugerida(uuid,uuid,integer,integer)') is null then raise notice 'OMITIDA: falta la etapa 2'; return; end if;
  perform set_config('request.headers', '{"x-refrimar-sesion":"tok-admin"}', true);
  select stock into n from productos where codigo = 'C001';
  r := compra_registrar('00000000-0000-0000-0000-0000000f0001', 'FERCOVEN, C.A.', current_date, null, null, 'Casa Matriz', 'test',
                        '[{"codigo":"C001","cantidad":6,"costo_unitario":1}]');
  assert (select stock from productos where codigo = 'C001') = n + 6, 'la recepción directa no sumó en la Principal';
  assert exists (select 1 from compras_proveedores where id = (r->>'factura_id')::uuid and origen = 'recepcion_directa' and monto_usd = 6), 'no creó la deuda';
end $$;

-- Pedido sugerido: lo vendido en 30 días cubre 15 días
do $$
declare r jsonb; v uuid;
begin
  if to_regprocedure('public.orden_sugerida(uuid,uuid,integer,integer)') is null then raise notice 'OMITIDA: falta la etapa 2'; return; end if;
  perform set_config('request.headers', '{"x-refrimar-sesion":"tok-admin"}', true);
  insert into productos (codigo, descripcion, costo, precio, stock, stock_minimo, proveedores) values ('V001', 'SE VENDE MUCHO', 1, 2, 3, 0, array['MAXCAM']);
  insert into ventas (numero, subtotal, iva, total_usd, tasa_bcv, total_bs, estado) values ('T-1', 60, 0, 60, 1, 60, 'completada') returning id into v;
  insert into detalle_venta (venta_id, producto_codigo, descripcion, cantidad, precio_unitario, total) values (v, 'V001', 'SE VENDE MUCHO', 60, 1, 60);
  r := orden_sugerida('00000000-0000-0000-0000-0000000f0002', null, 30, 15);
  -- 60 en 30 días = 2 por día; 15 días = 30; hay 3 → pedir 27
  assert r @> '[{"codigo":"V001","sugerido":27}]', 'sugerido de V001: ' || coalesce((select x::text from jsonb_array_elements(r) x where x->>'codigo' = 'V001'), 'no salió');
end $$;

-- Riesgos muestra la factura con diferencias hasta que se marca revisada
do $$
declare r jsonb; v_id uuid;
begin
  if to_regprocedure('public.factura_diferencias_revisar(uuid,text)') is null then raise notice 'OMITIDA: falta la etapa 2'; return; end if;
  perform set_config('request.headers', '{"x-refrimar-sesion":"tok-admin"}', true);
  insert into compras_proveedores (proveedor, numero, monto_usd, saldo_pendiente, diferencias)
  values ('MAXCAM', 'DIF-1', 10, 10, '[{"codigo":"A001","tipo":"precio","detalle":"Cobraron más caro que en la orden","monto":2}]') returning id into v_id;
  r := riesgos_resumen();
  assert r->'facturas_diferencias' @> jsonb_build_array(jsonb_build_object('id', v_id)), 'Riesgos no muestra la factura con diferencias';
  perform factura_diferencias_revisar(v_id, 'reclamado');
  r := riesgos_resumen();
  assert not (r->'facturas_diferencias' @> jsonb_build_array(jsonb_build_object('id', v_id))), 'sigue saliendo después de revisarla';
  assert (select notas from compras_proveedores where id = v_id) like '%revisadas por ADMIN PRUEBA%reclamado%', 'no anotó quién la revisó';
end $$;
