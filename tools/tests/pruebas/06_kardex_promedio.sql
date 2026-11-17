-- kardex_ajuste promedia el costo con el stock de antes de la entrada.
do $$
declare r jsonb;
begin
  r := kardex_ajuste('A001', 'entrada', 10, 2, 'prueba', null, 'test');   -- 10 a 1 $ + 10 a 2 $
  assert round((r->>'costo_promedio')::numeric, 4) = 1.5, 'costo promedio ' || (r->>'costo_promedio') || ' (debía ser 1,5)';
  assert (r->>'stock')::numeric = 20, 'stock ' || (r->>'stock');
  begin perform kardex_ajuste('A001', 'salida', 999, 0, 'prueba', null, 'test'); assert false, 'dejó sacar más de lo que hay';
  exception when others then if sqlerrm not like '%insuficiente%' then raise; end if; end;
end $$;
