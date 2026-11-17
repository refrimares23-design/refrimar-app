-- ============================================================
-- REFRIMAR — Etapa 1 (17-nov-2026): compras y ventas sin huecos
--
-- 1. Respaldo.
-- 2. Se cierra registrar_venta (vía vieja de la caja que no revisaba precios ni descuentos).
--    La caja usa pos_facturar, que sí los revisa.
-- 3. La factura del proveedor guarda el id del proveedor (además del nombre) y se rellena
--    en las facturas viejas por RIF o por nombre. No se borra nada.
-- 4. No se puede cargar dos veces la misma factura del mismo proveedor, aunque se escriba
--    distinto el nombre ("FERCOVEN" / "Fercoven, C.A.") o sea en la otra tienda.
-- 5. recepcion_registrar: la Carga IA guarda TODA la factura en un solo paso (si algo falla
--    no se guarda nada): suma stock con movimiento de kardex, promedia el costo, crea los
--    productos nuevos SIN precio (no se venden hasta que les pongas precio) y crea la
--    factura por pagar.
-- 6. riesgos_resumen: lista de stock negativo, productos a pérdida y facturas repetidas.
-- 7. kardex_ajuste: arreglo del costo promedio (se calculaba con el stock ya sumado), y el
--    costo de los productos pasa de 2 a 6 decimales.
--
-- Supabase → SQL Editor → New query → pega TODO → Run. Se puede correr varias veces.
-- ============================================================

-- 1. Respaldo
create schema if not exists respaldo_inventario;
revoke all on schema respaldo_inventario from anon, authenticated, public;
do $$ begin
    execute format('create table if not exists respaldo_inventario.%I as table public.productos',
                   'productos_' || to_char(now() at time zone 'America/Caracas', 'YYYYMMDD_HH24MISS'));
    execute format('create table if not exists respaldo_inventario.%I as table public.compras_proveedores',
                   'compras_proveedores_' || to_char(now() at time zone 'America/Caracas', 'YYYYMMDD_HH24MISS'));
end $$;

-- 2. registrar_venta cerrada (todas sus versiones)
do $$
declare f regprocedure;
begin
    for f in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             where n.nspname = 'public' and p.proname = 'registrar_venta' loop
        execute format('revoke execute on function %s from public, anon, authenticated', f);
    end loop;
end $$;

-- 3. Proveedor por ficha
create or replace function public.refrimar_norm(p text)
returns text language sql immutable as
$$ select regexp_replace(upper(translate(coalesce(p, ''), 'áéíóúÁÉÍÓÚñÑ', 'aeiouAEIOUnN')), '[^A-Z0-9]', '', 'g') $$;

-- Nombre sin "C.A.", "S.A.", "COMPAÑIA ANONIMA" para comparar proveedores
create or replace function public.refrimar_norm_proveedor(p text)
returns text language sql immutable as
$$ select regexp_replace(refrimar_norm(p), '(CA|SA|SRL|COMPANIAANONIMA)$', '') $$;

alter table public.compras_proveedores add column if not exists proveedor_id uuid;
do $$ begin
    if not exists (select 1 from pg_constraint where conname = 'compras_proveedores_proveedor_id_fkey') then
        alter table public.compras_proveedores
            add constraint compras_proveedores_proveedor_id_fkey foreign key (proveedor_id) references public.proveedores(id) on delete set null;
    end if;
end $$;
create index if not exists compras_proveedores_proveedor_id_idx on public.compras_proveedores (proveedor_id);
create index if not exists compras_proveedores_numero_norm_idx on public.compras_proveedores (refrimar_norm(numero));

-- Facturas viejas: primero por RIF, luego por nombre (solo si hay un único proveedor que coincida)
update public.compras_proveedores c set proveedor_id = p.id
from public.proveedores p
where c.proveedor_id is null and refrimar_norm(c.rif) <> '' and refrimar_norm(p.rif) = refrimar_norm(c.rif)
  and (select count(*) from public.proveedores p2 where refrimar_norm(p2.rif) = refrimar_norm(c.rif)) = 1;
update public.compras_proveedores c set proveedor_id = p.id
from public.proveedores p
where c.proveedor_id is null and refrimar_norm_proveedor(c.proveedor) <> '' and refrimar_norm_proveedor(p.nombre) = refrimar_norm_proveedor(c.proveedor)
  and (select count(*) from public.proveedores p2 where refrimar_norm_proveedor(p2.nombre) = refrimar_norm_proveedor(c.proveedor)) = 1;

-- 4. Factura repetida: mismo número y mismo proveedor (por id, RIF o nombre), en cualquier tienda
create or replace function public.factura_proveedor_existente(p_proveedor text, p_rif text, p_numero text, p_proveedor_id uuid default null, p_excluir uuid default null)
returns jsonb language sql stable security definer set search_path = public as
$$
    select jsonb_build_object('id', c.id, 'proveedor', c.proveedor, 'numero', c.numero, 'fecha', c.fecha_emision,
                              'monto_usd', c.monto_usd, 'tienda', coalesce(c.sucursal_nombre, 'Principal'))
    from compras_proveedores c
    where refrimar_norm(c.numero) = refrimar_norm(p_numero) and refrimar_norm(p_numero) <> ''
      and (p_excluir is null or c.id <> p_excluir)
      and ((p_proveedor_id is not null and c.proveedor_id = p_proveedor_id)
        or (refrimar_norm(p_rif) <> '' and refrimar_norm(c.rif) = refrimar_norm(p_rif))
        or (refrimar_norm_proveedor(p_proveedor) <> '' and refrimar_norm_proveedor(c.proveedor) = refrimar_norm_proveedor(p_proveedor)))
    order by c.creado_en
    limit 1
$$;
revoke execute on function public.factura_proveedor_existente(text, text, text, uuid, uuid) from public, anon;
grant execute on function public.factura_proveedor_existente(text, text, text, uuid, uuid) to authenticated, anon;

create or replace function public.refrimar_bloquear_factura_repetida(p_proveedor text, p_rif text, p_numero text, p_proveedor_id uuid default null, p_excluir uuid default null)
returns void language plpgsql stable security definer set search_path = public as
$$
declare v jsonb := factura_proveedor_existente(p_proveedor, p_rif, p_numero, p_proveedor_id, p_excluir);
begin
    if v is not null then
        raise exception 'La factura % de % ya está cargada (% · % · % $). Si es otra factura, revisa el número.',
            v->>'numero', v->>'proveedor', v->>'tienda', v->>'fecha', v->>'monto_usd'
            using errcode = 'P0001', hint = 'factura_repetida';
    end if;
end;
$$;
revoke execute on function public.refrimar_bloquear_factura_repetida(text, text, text, uuid, uuid) from public, anon, authenticated;

-- compra_proveedor_guardar: la misma de siempre + revisa repetidas al crear
create or replace function public.compra_proveedor_guardar(p_proveedor text, p_numero text, p_sucursal_id uuid, p_id uuid default null, p_rif text default null, p_fecha_emision date default current_date, p_fecha_vencimiento date default null, p_monto numeric default 0, p_estado text default 'Pendiente', p_notas text default null, p_sucursal_nombre text default null)
returns uuid language plpgsql security definer set search_path = public as
$$
declare
    v_id uuid;
    v_prov uuid;
begin
    if p_proveedor is null or trim(p_proveedor) = '' then
        raise exception 'El proveedor es obligatorio';
    end if;
    if p_numero is null or trim(p_numero) = '' then
        raise exception 'El número de factura es obligatorio';
    end if;
    select id into v_prov from proveedores
    where (refrimar_norm(p_rif) <> '' and refrimar_norm(rif) = refrimar_norm(p_rif))
       or refrimar_norm_proveedor(nombre) = refrimar_norm_proveedor(p_proveedor)
    order by (refrimar_norm(rif) = refrimar_norm(p_rif)) desc nulls last limit 1;

    if p_id is null then
        if p_monto is null or p_monto <= 0 then
            raise exception 'El monto debe ser mayor a 0';
        end if;
        perform refrimar_bloquear_factura_repetida(p_proveedor, p_rif, p_numero, v_prov, null);
        insert into compras_proveedores
            (proveedor, rif, numero, fecha_emision, fecha_vencimiento, monto_usd,
             monto_abonado, saldo_pendiente, estado, notas, sucursal_id, sucursal_nombre, proveedor_id)
        values
            (trim(p_proveedor), p_rif, trim(p_numero), coalesce(p_fecha_emision, current_date),
             p_fecha_vencimiento, p_monto, 0, p_monto, coalesce(p_estado, 'Pendiente'),
             p_notas, p_sucursal_id, p_sucursal_nombre, v_prov)
        returning id into v_id;
    else
        perform refrimar_bloquear_factura_repetida(p_proveedor, p_rif, p_numero, v_prov, p_id);
        update compras_proveedores
        set proveedor = trim(p_proveedor), rif = p_rif, numero = trim(p_numero),
            fecha_emision = coalesce(p_fecha_emision, fecha_emision),
            fecha_vencimiento = p_fecha_vencimiento,
            estado = coalesce(p_estado, estado), notas = p_notas,
            sucursal_id = p_sucursal_id, sucursal_nombre = p_sucursal_nombre,
            proveedor_id = coalesce(v_prov, proveedor_id)
        where id = p_id;
        v_id := p_id;
    end if;

    if v_id is null then
        raise exception 'No se pudo guardar la factura';
    end if;
    return v_id;
end;
$$;

-- 4a. El costo se guardaba con 2 decimales (una grapa de 0,0436 $ quedaba en 0,04 $). Pasa a 6 decimales.
do $$ begin
    if (select numeric_scale from information_schema.columns
        where table_schema = 'public' and table_name = 'productos' and column_name = 'costo') < 6 then
        alter table public.productos alter column costo type numeric(14,6);
    end if;
end $$;

-- 4b. kardex_ajuste: el costo promedio se calculaba con el stock YA sumado (pesaba de más el costo viejo).
--     Misma función, mismos parámetros; ahora promedia con el stock de antes y bloquea la fila mientras trabaja.
create or replace function public.kardex_ajuste(p_producto_codigo text, p_tipo text, p_cantidad numeric, p_costo_unitario numeric, p_concepto text, p_sucursal_id uuid, p_usuario text)
returns jsonb language plpgsql security definer set search_path = public as
$$
declare
    v_casa uuid := '00000000-0000-0000-0000-000000000001';
    v_desc text;
    v_stock_actual numeric;
    v_stock_base numeric;
    v_costo_actual numeric;
    v_nuevo_stock numeric;
    v_nuevo_costo numeric;
    v_kardex_tipo text;
begin
    if p_producto_codigo is null or p_producto_codigo = '' then
        raise exception 'Debe indicar un producto';
    end if;
    if p_cantidad is null or p_cantidad <= 0 then
        raise exception 'La cantidad debe ser mayor a cero';
    end if;
    if p_tipo not in ('entrada', 'salida') then
        raise exception 'Tipo debe ser entrada o salida';
    end if;

    select descripcion, coalesce(costo, 0), coalesce(stock, 0) into v_desc, v_costo_actual, v_stock_base
    from productos where codigo = p_producto_codigo for update;
    if not found then
        raise exception 'Producto % no existe', p_producto_codigo;
    end if;

    v_kardex_tipo := case when p_tipo = 'entrada' then 'entrada_ajuste' else 'salida_ajuste' end;

    if p_sucursal_id is null or p_sucursal_id = v_casa then
        v_stock_actual := v_stock_base;
        if p_tipo = 'salida' and v_stock_actual < p_cantidad then
            raise exception 'Stock insuficiente (actual: %)', v_stock_actual;
        end if;
        v_nuevo_stock := case when p_tipo = 'entrada' then v_stock_actual + p_cantidad else v_stock_actual - p_cantidad end;
        update productos set stock = v_nuevo_stock where codigo = p_producto_codigo;
    else
        select coalesce(stock, 0) into v_stock_actual from sucursal_stock
        where sucursal_id = p_sucursal_id and producto_codigo = p_producto_codigo for update;
        v_stock_actual := coalesce(v_stock_actual, 0);
        if p_tipo = 'salida' and v_stock_actual < p_cantidad then
            raise exception 'Stock insuficiente (actual: %)', v_stock_actual;
        end if;
        v_nuevo_stock := case when p_tipo = 'entrada' then v_stock_actual + p_cantidad else v_stock_actual - p_cantidad end;
        insert into sucursal_stock (sucursal_id, producto_codigo, producto_descripcion, stock)
        values (p_sucursal_id, p_producto_codigo, coalesce(v_desc, p_producto_codigo), v_nuevo_stock)
        on conflict (sucursal_id, producto_codigo)
        do update set stock = excluded.stock, producto_descripcion = excluded.producto_descripcion, updated_at = now();
    end if;

    -- Costo promedio ponderado: stock de ANTES de la entrada (el de la Principal, como siempre)
    if p_tipo = 'entrada' and coalesce(p_costo_unitario, 0) > 0 then
        if greatest(v_stock_base, 0) > 0 and v_costo_actual > 0 then
            v_nuevo_costo := (greatest(v_stock_base, 0) * v_costo_actual + p_cantidad * p_costo_unitario) / (greatest(v_stock_base, 0) + p_cantidad);
        else
            v_nuevo_costo := p_costo_unitario;
        end if;
        update productos set costo = v_nuevo_costo where codigo = p_producto_codigo;
        select coalesce(costo, 0) into v_nuevo_costo from productos where codigo = p_producto_codigo;   -- como queda guardado
    else
        v_nuevo_costo := v_costo_actual;
    end if;

    insert into kardex_movimientos (producto_codigo, producto_descripcion, fecha, tipo, cantidad, costo_unitario, costo_total, saldo_cantidad, saldo_costo_promedio, referencia, usuario_nombre, sucursal_id)
    values (p_producto_codigo, coalesce(v_desc, p_producto_codigo), current_date, v_kardex_tipo,
            case when p_tipo = 'entrada' then p_cantidad else -p_cantidad end,
            coalesce(p_costo_unitario, 0),
            case when p_tipo = 'entrada' then p_cantidad * coalesce(p_costo_unitario, 0) else p_cantidad * v_costo_actual end,
            v_nuevo_stock, v_nuevo_costo,
            coalesce(p_concepto, v_kardex_tipo), p_usuario, p_sucursal_id);

    return jsonb_build_object('ok', true, 'stock', v_nuevo_stock, 'costo_promedio', v_nuevo_costo);
end;
$$;

-- 5. Recepción de factura en un solo paso
create or replace function public.recepcion_registrar(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as
$$
declare
    v_casa constant uuid := '00000000-0000-0000-0000-000000000001';
    v_uid uuid := refrimar_sesion_uid(30);
    v_usuario text;
    v_suc uuid := nullif(p->>'sucursal_id', '')::uuid;
    v_suc_nombre text := nullif(trim(coalesce(p->>'sucursal_nombre', '')), '');
    v_prov_nombre text := nullif(trim(coalesce(p->>'proveedor', '')), '');
    v_rif text := nullif(trim(coalesce(p->>'rif', '')), '');
    v_numero text := nullif(trim(coalesce(p->>'numero', '')), '');
    v_fecha date := coalesce(nullif(p->>'fecha', '')::date, current_date);
    v_moneda text := upper(coalesce(nullif(p->>'moneda', ''), 'USD'));
    v_tasa numeric := nullif(p->>'tasa', '')::numeric;
    v_factor numeric := 1;
    v_prov uuid := nullif(p->>'proveedor_id', '')::uuid;
    v_crear_cxp boolean := coalesce((p->>'crear_cxp')::boolean, true);
    v_incl boolean := coalesce((select bool_or(coalesce(iva_incluido, false) or coalesce((opciones->>'iva_incluido')::boolean, false)) from configuracion), false);
    it jsonb; v_cod text; v_alt text; v_cant numeric; v_costo numeric; v_precio numeric;
    pr record; v_nuevos int := 0; v_actualizados int := 0; v_total numeric := 0;
    v_avisos jsonb := '[]'::jsonb; v_sin_precio jsonb := '[]'::jsonb; v_cxp uuid; v_ref text;
begin
    if v_uid is null then raise exception 'Tu sesión venció. Vuelve a entrar.' using errcode = 'P0001'; end if;
    if not refrimar_tiene_permiso(v_uid, 'editar_inventario') then
        raise exception 'Tu usuario no tiene permiso para cargar mercancía.';
    end if;
    select nombre into v_usuario from usuarios where id = v_uid;
    if jsonb_typeof(p->'items') <> 'array' or jsonb_array_length(p->'items') = 0 then
        raise exception 'La factura no tiene productos';
    end if;
    if jsonb_array_length(p->'items') > 2000 then raise exception 'Demasiadas líneas en una sola factura (máximo 2000)'; end if;
    if v_moneda not in ('USD', 'VES') then raise exception 'Moneda inválida: %', v_moneda; end if;
    if v_moneda = 'VES' then
        if v_tasa is null or v_tasa <= 0 then raise exception 'Falta la tasa para convertir la factura en bolívares'; end if;
        v_factor := 1 / v_tasa;
    end if;
    if v_suc = v_casa then v_suc := null; end if;
    if v_suc is not null and not exists (select 1 from sucursales where id = v_suc) then raise exception 'La tienda indicada no existe'; end if;

    if v_prov is null and (v_prov_nombre is not null or v_rif is not null) then
        select id into v_prov from proveedores
        where (refrimar_norm(v_rif) <> '' and refrimar_norm(rif) = refrimar_norm(v_rif))
           or (v_prov_nombre is not null and refrimar_norm_proveedor(nombre) = refrimar_norm_proveedor(v_prov_nombre))
        order by (refrimar_norm(rif) = refrimar_norm(v_rif)) desc nulls last limit 1;
    end if;
    if v_prov is not null and v_prov_nombre is null then select nombre into v_prov_nombre from proveedores where id = v_prov; end if;

    if v_crear_cxp then
        if v_prov_nombre is null then raise exception 'Falta el proveedor para crear la factura por pagar'; end if;
        if v_numero is null then raise exception 'Falta el número de factura'; end if;
        perform refrimar_bloquear_factura_repetida(v_prov_nombre, v_rif, v_numero, v_prov, null);
    end if;
    v_ref := 'Factura ' || coalesce(v_numero, 's/n') || coalesce(' · ' || v_prov_nombre, '');

    for it in select value from jsonb_array_elements(p->'items') loop
        v_cod := nullif(trim(coalesce(it->>'codigo', '')), '');
        v_alt := nullif(trim(coalesce(it->>'codigo_alterno', '')), '');
        v_cant := coalesce(nullif(it->>'cantidad', '')::numeric, 0);
        v_costo := round(coalesce(nullif(it->>'costo', '')::numeric, 0) * v_factor, 6);
        v_precio := nullif(it->>'precio', '')::numeric;
        if v_cod is null then raise exception 'Hay una línea sin código ("%")', coalesce(it->>'descripcion', '?'); end if;
        if v_cant <= 0 or v_cant > 1000000 then raise exception 'Cantidad inválida en "%"', coalesce(it->>'descripcion', v_cod); end if;
        if v_costo < 0 then raise exception 'Costo inválido en "%"', coalesce(it->>'descripcion', v_cod); end if;
        if v_precio is not null and v_precio < 0 then raise exception 'Precio inválido en "%"', coalesce(it->>'descripcion', v_cod); end if;

        select * into pr from productos where codigo = v_cod for update;
        if not found then
            if not coalesce((it->>'nuevo')::boolean, false) then
                raise exception 'El producto % no existe. Márcalo como nuevo o elige uno existente.', v_cod;
            end if;
            if nullif(trim(coalesce(it->>'descripcion', '')), '') is null then raise exception 'Falta la descripción del producto nuevo %', v_cod; end if;
            insert into productos (codigo, descripcion, costo, precio, stock, stock_minimo, unidad, categoria, marca, activo)
            values (v_cod, trim(it->>'descripcion'), v_costo, coalesce(v_precio, 0), 0,
                    coalesce(nullif(it->>'stock_minimo', '')::numeric, 0),
                    coalesce(nullif(it->>'unidad', ''), 'uds'), nullif(it->>'categoria', ''), nullif(it->>'marca', ''), true)
            returning * into pr;
            v_nuevos := v_nuevos + 1;
        else
            v_actualizados := v_actualizados + 1;
        end if;

        if v_alt is not null and refrimar_norm(v_alt) <> refrimar_norm(v_cod)
           and not (coalesce(pr.codigos_alternos, '{}') @> array[v_alt]) then
            update productos set codigos_alternos = array_append(coalesce(codigos_alternos, '{}'), v_alt) where codigo = v_cod;
        end if;
        if v_suc is not null then
            perform 1 from sucursal_stock where sucursal_id = v_suc and producto_codigo = v_cod for update;
        end if;

        -- Stock + kardex + costo promedio (la misma función que usan los ajustes)
        perform kardex_ajuste(v_cod, 'entrada', v_cant, v_costo, v_ref, v_suc, coalesce(v_usuario, 'Sistema'));
        if v_suc is not null and v_costo > 0 then
            update sucursal_stock set costo = v_costo where sucursal_id = v_suc and producto_codigo = v_cod;
        end if;

        if v_precio is not null and v_precio > 0 then
            update productos set precio = v_precio, updated_at = now() where codigo = v_cod;
        end if;
        select precio, costo, iva_tasa, descripcion into pr from productos where codigo = v_cod;
        if coalesce(pr.precio, 0) <= 0 then
            v_sin_precio := v_sin_precio || jsonb_build_object('codigo', v_cod, 'descripcion', pr.descripcion);
        elsif (case when v_incl then pr.precio / (1 + coalesce(pr.iva_tasa, 16) / 100) else pr.precio end) < coalesce(pr.costo, 0) then
            v_avisos := v_avisos || jsonb_build_object('codigo', v_cod, 'descripcion', pr.descripcion, 'costo', pr.costo, 'precio', pr.precio,
                                                       'aviso', 'Se vende por debajo del costo');
        end if;
        v_total := v_total + v_cant * v_costo;
    end loop;

    if v_crear_cxp and v_total > 0 then
        insert into compras_proveedores (proveedor, rif, numero, fecha_emision, fecha_vencimiento, monto_usd, monto_abonado,
                                         saldo_pendiente, estado, notas, origen, sucursal_id, sucursal_nombre, proveedor_id, tasa_bcv)
        values (v_prov_nombre, v_rif, v_numero, v_fecha, nullif(p->>'fecha_vencimiento', '')::date, round(v_total, 2), 0,
                round(v_total, 2), 'Pendiente', nullif(p->>'notas', ''), coalesce(nullif(p->>'origen', ''), 'carga_ia'),
                v_suc, coalesce(v_suc_nombre, case when v_suc is null then 'Principal' end), v_prov, v_tasa)
        returning id into v_cxp;
    end if;

    return jsonb_build_object('ok', true, 'nuevos', v_nuevos, 'actualizados', v_actualizados, 'total_usd', round(v_total, 2),
                              'factura_id', v_cxp, 'sin_precio', v_sin_precio, 'avisos', v_avisos);
end;
$$;
revoke execute on function public.recepcion_registrar(jsonb) from public, anon;
grant execute on function public.recepcion_registrar(jsonb) to anon, authenticated;

-- 6. Riesgos: stock negativo, productos a pérdida, facturas repetidas
create or replace function public.riesgos_resumen()
returns jsonb language plpgsql stable security definer set search_path = public as
$$
declare
    v_uid uuid := refrimar_sesion_uid(30);
    v_incl boolean := coalesce((select bool_or(coalesce(iva_incluido, false) or coalesce((opciones->>'iva_incluido')::boolean, false)) from configuracion), false);
begin
    if v_uid is null then raise exception 'Tu sesión venció. Vuelve a entrar.'; end if;
    if not refrimar_tiene_permiso(v_uid, 'ver_inventario') then raise exception 'Sin permiso para ver el inventario'; end if;
    return jsonb_build_object(
        'stock_negativo', coalesce((
            select jsonb_agg(x order by x->>'tienda', x->>'descripcion') from (
                select jsonb_build_object('codigo', codigo, 'descripcion', descripcion, 'tienda', 'Principal', 'stock', stock) x
                from productos where stock < 0 and coalesce(tipo_producto, 'fisico') = 'fisico'
                union all
                select jsonb_build_object('codigo', ss.producto_codigo, 'descripcion', coalesce(p.descripcion, ss.producto_descripcion), 'tienda', s.nombre, 'stock', ss.stock)
                from sucursal_stock ss join sucursales s on s.id = ss.sucursal_id left join productos p on p.codigo = ss.producto_codigo
                where ss.stock < 0 and coalesce(p.tipo_producto, 'fisico') = 'fisico'
                limit 500) q), '[]'::jsonb),
        'margen_negativo', coalesce((
            select jsonb_agg(jsonb_build_object('codigo', codigo, 'descripcion', descripcion, 'costo', costo, 'precio', precio,
                                                'precio_sin_iva', round(psi, 4)) order by descripcion)
            from (select codigo, descripcion, costo, precio,
                         case when v_incl then precio / (1 + coalesce(iva_tasa, 16) / 100) else precio end as psi
                  from productos where activo is not false and precio > 0 and costo > 0) q
            where psi < costo), '[]'::jsonb),
        'sin_precio', (select count(*) from productos where activo is not false and coalesce(precio, 0) <= 0 and coalesce(tipo_producto, 'fisico') = 'fisico'),
        'facturas_repetidas', coalesce((
            select jsonb_agg(jsonb_build_object('numero', numero, 'proveedor', proveedor, 'veces', n, 'monto_usd', total))
            from (select min(numero) numero, min(proveedor) proveedor, count(*) n, sum(monto_usd) total
                  from compras_proveedores where refrimar_norm(numero) <> ''
                  group by refrimar_norm(numero), coalesce(proveedor_id::text, refrimar_norm_proveedor(proveedor))
                  having count(*) > 1) q), '[]'::jsonb)
    );
end;
$$;
revoke execute on function public.riesgos_resumen() from public, anon;
grant execute on function public.riesgos_resumen() to anon, authenticated;

-- 7. Seguridad: quién puede llamar las funciones nuevas
insert into public.seguridad_rpc (nombre, nivel, permiso, gracia_dias)
select v.* from (values ('recepcion_registrar', 'permiso', 'editar_inventario', 0),
                        ('riesgos_resumen', 'permiso', 'ver_inventario', 0),
                        ('factura_proveedor_existente', 'sesion', null, 0)) as v(nombre, nivel, permiso, gracia)
where not exists (select 1 from public.seguridad_rpc s where s.nombre = v.nombre);

-- 8. Registro
insert into public.migraciones_aplicadas (nombre, descripcion, version_app)
values ('2026-11-17-etapa1-compras-seguras', 'registrar_venta cerrada, proveedor por id, factura repetida, recepcion_registrar, riesgos_resumen', 'v3.9.22')
on conflict (nombre) do nothing;

notify pgrst, 'reload schema';

select 'Listo' as resultado,
       (select count(*) from compras_proveedores where proveedor_id is not null) as facturas_con_proveedor,
       (select count(*) from compras_proveedores where proveedor_id is null) as facturas_sin_emparejar;
