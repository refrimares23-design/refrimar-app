-- riesgos_resumen ve stock negativo, productos a pérdida y facturas repetidas; la factura manual repetida se rechaza.
do $$
declare r jsonb; v_err text;
begin
  if to_regprocedure('public.riesgos_resumen()') is null then raise notice 'OMITIDA: falta riesgos_resumen'; return; end if;
  perform set_config('request.headers', '{"x-refrimar-sesion":"tok-admin"}', true);
  r := riesgos_resumen();
  assert r->'stock_negativo' @> '[{"codigo":"C001"}]', 'no vio el stock negativo de C001';
  assert r->'margen_negativo' @> '[{"codigo":"B001"}]', 'no vio que B001 se vende a pérdida';
  assert not (r->'margen_negativo' @> '[{"codigo":"A001"}]'), 'A001 no se vende a pérdida';
  -- La cajera ve stock negativo pero no costos
  perform set_config('request.headers', '{"x-refrimar-sesion":"tok-cajera"}', true);
  r := riesgos_resumen();
  assert r->'stock_negativo' @> '[{"codigo":"C001"}]', 'la cajera no ve el stock negativo';
  assert jsonb_array_length(r->'margen_negativo') = 0, 'la cajera ve costos';
  perform set_config('request.headers', '{"x-refrimar-sesion":"tok-admin"}', true);

  perform compra_proveedor_guardar('FERCOVEN, C.A.', 'B-777', null, null, 'J-12345678-9', current_date, null, 50);
  begin
    perform compra_proveedor_guardar('Fercoven', 'B777', '00000000-0000-0000-0000-0000000000a2', null, null, current_date, null, 50);
    v_err := null;
  exception when others then v_err := sqlerrm; end;
  assert v_err like '%ya está cargada%', 'la factura manual repetida debía rechazarse: ' || coalesce(v_err, 'pasó');
end $$;
