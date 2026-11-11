-- ============================================================
-- CORRECCIONES (octubre 2026)
-- transferir_stock_sucursal: el id del movimiento se guarda como texto,
-- así funciona sea uuid o número en tu tabla sucursal_movimientos.
-- Solo cambia esa línea de la función que ya tienes. Se puede correr varias veces.
-- ============================================================
do $$
declare v_def text;
begin
    if to_regprocedure('public.transferir_stock_sucursal(text,numeric,numeric,uuid,uuid,text)') is null then return; end if;
    v_def := pg_get_functiondef('public.transferir_stock_sucursal(text,numeric,numeric,uuid,uuid,text)'::regprocedure);
    if v_def ~ 'v_movimiento_id\s+uuid;' then
        execute regexp_replace(v_def, 'v_movimiento_id\s+uuid;', 'v_movimiento_id text;');
    end if;
end $$;

do $$ begin
    if to_regprocedure('saas.sincronizar_todas()') is not null then perform saas.sincronizar_todas(); end if;
end $$;
notify pgrst, 'reload schema';
select 'Correcciones listas' as resultado;
