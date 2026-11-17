-- ============================================================
-- REFRIMAR — Etapa 4, parte 1 (17-nov-2026): ordenar el inventario
--
-- 1. Respaldo.
-- 2. Cajas → unidades al recibir: si la factura trae "caja de 100", entran 100 unidades
--    al costo de una. El código de la caja se recuerda para la próxima factura.
-- 3. Cambios masivos (categoría, marca, proveedor, ubicación, mínimo) con DESHACER.
-- 4. Posibles productos duplicados (nombres casi iguales con las mismas medidas).
-- 5. Buscador general (Ctrl + K): productos, clientes, facturas, proveedores y cotizaciones.
--
-- Supabase → SQL Editor → New query → pega TODO → Run. Se puede correr varias veces.
-- No borra nada.
-- ============================================================

-- 1. Respaldo
create schema if not exists respaldo_inventario;
revoke all on schema respaldo_inventario from anon, authenticated, public;
do $$
declare t text; s text := to_char(now() at time zone 'America/Caracas', 'YYYYMMDD_HH24MISS');
begin
    foreach t in array array['productos', 'sucursal_stock'] loop
        if to_regclass('public.' || t) is not null then
            execute format('create table if not exists respaldo_inventario.%I as table public.%I', t || '_' || s, t);
        end if;
    end loop;
end $$;

-- ============================================================
-- 2. Recepción con unidades por caja (misma función de la etapa 2 + "unidades_por_caja")
-- ============================================================
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
    v_oc_id uuid := nullif(p->>'orden_compra_id', '')::uuid;
    v_oc record; v_det record; v_oc_num text;
    v_crear_cxp boolean := coalesce((p->>'crear_cxp')::boolean, true);
    v_incl boolean := coalesce((select bool_or(coalesce(iva_incluido, false) or coalesce((opciones->>'iva_incluido')::boolean, false)) from configuracion), false);
    it jsonb; v_cod text; v_alt text; v_cant numeric; v_costo numeric; v_precio numeric; v_pend numeric; v_emp numeric;
    pr record; v_nuevos int := 0; v_actualizados int := 0; v_total numeric := 0;
    v_avisos jsonb := '[]'::jsonb; v_sin_precio jsonb := '[]'::jsonb; v_dif jsonb := '[]'::jsonb;
    v_cxp uuid; v_ref text; v_vistos text[] := '{}';
begin
    if v_uid is null then raise exception 'Tu sesión venció. Vuelve a entrar.' using errcode = 'P0001'; end if;
    if not (refrimar_tiene_permiso(v_uid, 'editar_inventario') or refrimar_tiene_permiso(v_uid, 'compras')) then
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

    if v_oc_id is not null then
        select * into v_oc from ordenes_compra where id = v_oc_id for update;
        if not found then raise exception 'La orden de compra no existe'; end if;
        if v_oc.estado not in ('ordenada', 'parcial', 'borrador') then
            raise exception 'La orden % está % y no puede recibir mercancía', v_oc.numero, v_oc.estado;
        end if;
        v_oc_num := v_oc.numero;
        v_suc := coalesce(v_suc, v_oc.sucursal_id);
        v_suc_nombre := coalesce(v_suc_nombre, v_oc.sucursal_nombre);
        v_prov := coalesce(v_prov, v_oc.proveedor_id);
        v_prov_nombre := coalesce(v_prov_nombre, v_oc.proveedor_nombre);
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
    if v_prov is not null and v_rif is null then select nullif(rif, '') into v_rif from proveedores where id = v_prov; end if;

    if v_crear_cxp then
        if v_prov_nombre is null then raise exception 'Falta el proveedor para crear la factura por pagar'; end if;
        if v_numero is null then raise exception 'Falta el número de factura'; end if;
        perform refrimar_bloquear_factura_repetida(v_prov_nombre, v_rif, v_numero, v_prov, null);
    end if;
    v_ref := 'Factura ' || coalesce(v_numero, 's/n') || coalesce(' · ' || v_oc_num, '') || coalesce(' · ' || v_prov_nombre, '');

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
        -- Viene por caja/bulto: se convierte a unidades (cantidad × unidades por caja, costo ÷ unidades por caja)
        v_emp := coalesce(nullif(it->>'unidades_por_caja', '')::numeric, 1);
        if v_emp < 1 or v_emp > 100000 then raise exception 'Unidades por caja inválidas en "%"', coalesce(it->>'descripcion', v_cod); end if;
        if v_emp > 1 then
            v_cant := v_cant * v_emp;
            v_costo := round(v_costo / v_emp, 6);
        end if;

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

        -- Contra la orden de compra: cantidad y precio
        if v_oc_id is not null then
            select * into v_det from compra_detalles where compra_id = v_oc_id and producto_codigo = v_cod for update;
            if not found then
                v_dif := v_dif || jsonb_build_object('codigo', v_cod, 'descripcion', pr.descripcion, 'tipo', 'no_pedido',
                                                     'detalle', 'No estaba en la orden', 'facturado', v_cant, 'monto', round(v_cant * v_costo, 2));
            else
                v_vistos := array_append(v_vistos, v_cod);
                v_pend := v_det.cantidad - v_det.cantidad_recibida;
                if v_cant > v_pend + 0.0005 then
                    v_dif := v_dif || jsonb_build_object('codigo', v_cod, 'descripcion', pr.descripcion, 'tipo', 'de_mas',
                                                         'detalle', 'Llegó más de lo pedido', 'pedido', v_pend, 'facturado', v_cant,
                                                         'monto', round((v_cant - v_pend) * v_costo, 2));
                end if;
                if v_det.costo_unitario > 0 and abs(v_costo - v_det.costo_unitario) > greatest(0.01, v_det.costo_unitario * 0.01) then
                    v_dif := v_dif || jsonb_build_object('codigo', v_cod, 'descripcion', pr.descripcion, 'tipo', 'precio',
                                                         'detalle', case when v_costo > v_det.costo_unitario then 'Cobraron más caro que en la orden' else 'Cobraron más barato que en la orden' end,
                                                         'costo_orden', v_det.costo_unitario, 'costo_factura', v_costo,
                                                         'monto', round((v_costo - v_det.costo_unitario) * v_cant, 2));
                end if;
                update compra_detalles set cantidad_recibida = cantidad_recibida + v_cant where id = v_det.id;
            end if;
        end if;

        -- El código de la caja se recuerda como empaque (la próxima factura ya trae las unidades por caja)
        if v_alt is not null and v_emp > 1 and refrimar_norm(v_alt) <> refrimar_norm(v_cod) then
            update productos set empaques = coalesce(empaques, '[]'::jsonb) || jsonb_build_object('nombre', 'Caja x ' || trim(to_char(v_emp, 'FM9999990.###')), 'barra', v_alt, 'cantidad', v_emp)
            where codigo = v_cod
              and not exists (select 1 from jsonb_array_elements(coalesce(empaques, '[]'::jsonb)) e where lower(e->>'barra') = lower(v_alt));
            v_alt := null;
        end if;
        if v_alt is not null and refrimar_norm(v_alt) <> refrimar_norm(v_cod)
           and not (coalesce(pr.codigos_alternos, '{}') @> array[v_alt]) then
            update productos set codigos_alternos = array_append(coalesce(codigos_alternos, '{}'), v_alt) where codigo = v_cod;
        end if;
        if v_suc is not null then
            perform 1 from sucursal_stock where sucursal_id = v_suc and producto_codigo = v_cod for update;
        end if;

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

    if v_oc_id is not null then
        -- Lo que faltó por llegar (normal en entregas parciales; queda anotado)
        select v_dif || coalesce(jsonb_agg(jsonb_build_object('codigo', d.producto_codigo, 'descripcion', d.descripcion, 'tipo', 'falta',
                                   'detalle', 'Falta por llegar', 'pedido', d.cantidad, 'recibido', d.cantidad_recibida,
                                   'monto', round((d.cantidad - d.cantidad_recibida) * d.costo_unitario, 2))), '[]'::jsonb)
        into v_dif
        from compra_detalles d where d.compra_id = v_oc_id and d.cantidad_recibida < d.cantidad - 0.0005;
        update ordenes_compra set
            estado = case when exists (select 1 from compra_detalles where compra_id = v_oc_id and cantidad_recibida < cantidad - 0.0005) then 'parcial' else 'recibida' end,
            recibida_at = now()
        where id = v_oc_id;
    end if;

    if v_crear_cxp and v_total > 0 then
        insert into compras_proveedores (proveedor, rif, numero, fecha_emision, fecha_vencimiento, monto_usd, monto_abonado,
                                         saldo_pendiente, estado, notas, origen, sucursal_id, sucursal_nombre, proveedor_id, tasa_bcv,
                                         orden_compra_id, diferencias)
        values (v_prov_nombre, v_rif, v_numero, v_fecha, nullif(p->>'fecha_vencimiento', '')::date, round(v_total, 2), 0,
                round(v_total, 2), 'Pendiente', nullif(p->>'notas', ''), coalesce(nullif(p->>'origen', ''), 'carga_ia'),
                v_suc, coalesce(v_suc_nombre, case when v_suc is null then 'Principal' end), v_prov, v_tasa,
                v_oc_id, (select coalesce(jsonb_agg(d), '[]'::jsonb) from jsonb_array_elements(v_dif) d where d->>'tipo' <> 'falta'))
        returning id into v_cxp;
    end if;

    return jsonb_build_object('ok', true, 'nuevos', v_nuevos, 'actualizados', v_actualizados, 'total_usd', round(v_total, 2),
                              'factura_id', v_cxp, 'sin_precio', v_sin_precio, 'avisos', v_avisos, 'diferencias', v_dif,
                              'orden_estado', (select estado from ordenes_compra where id = v_oc_id));
end;
$$;

revoke execute on function public.recepcion_registrar(jsonb) from public, anon;
grant execute on function public.recepcion_registrar(jsonb) to anon, authenticated;

-- ============================================================
-- 3. Cambios masivos con deshacer
-- ============================================================
create table if not exists public.cambios_masivos (
    id uuid primary key default gen_random_uuid(),
    campo text not null,
    valor text,
    sucursal_id uuid,
    cantidad int not null default 0,
    antes jsonb not null default '[]'::jsonb,       -- [{codigo, valor_anterior}] para deshacer
    usuario_nombre text,
    deshecho_at timestamptz,
    created_at timestamptz not null default now()
);
alter table public.cambios_masivos enable row level security;
revoke all on table public.cambios_masivos from anon, authenticated, public;

-- p_campo: categoria | marca | proveedor (se agrega a la lista) | ubicacion (de la tienda) | stock_minimo
create or replace function public.productos_cambio_masivo(p_codigos text[], p_campo text, p_valor text, p_sucursal_id uuid default null)
returns jsonb language plpgsql security definer set search_path = public as
$$
declare
    v_uid uuid := refrimar_sesion_uid(30);
    v_usuario text;
    v_val text := nullif(trim(coalesce(p_valor, '')), '');
    v_num numeric;
    v_suc uuid := nullif(p_sucursal_id, '00000000-0000-0000-0000-000000000001');
    v_antes jsonb;
    v_n int := 0;
    v_id uuid;
begin
    if v_uid is null then raise exception 'Tu sesión venció. Vuelve a entrar.'; end if;
    if not refrimar_tiene_permiso(v_uid, 'editar_inventario') then raise exception 'Tu usuario no puede editar productos'; end if;
    select nombre into v_usuario from usuarios where id = v_uid;
    if p_codigos is null or cardinality(p_codigos) = 0 then raise exception 'Marca al menos un producto'; end if;
    if cardinality(p_codigos) > 3000 then raise exception 'Máximo 3000 productos por cambio'; end if;
    if p_campo not in ('categoria', 'marca', 'proveedor', 'ubicacion', 'stock_minimo') then raise exception 'Campo no permitido: %', p_campo; end if;
    if p_campo in ('proveedor') and v_val is null then raise exception 'Escribe el proveedor'; end if;
    if p_campo = 'stock_minimo' then
        v_num := nullif(replace(coalesce(v_val, ''), ',', '.'), '')::numeric;
        if v_num is null or v_num < 0 then raise exception 'El mínimo debe ser un número mayor o igual a 0'; end if;
    end if;
    if v_val is not null then v_val := left(v_val, 80); end if;

    if p_campo = 'ubicacion' and v_suc is not null then
        select coalesce(jsonb_agg(jsonb_build_object('codigo', p.codigo, 'antes', ss.ubicacion, 'fila', ss.producto_codigo is not null)), '[]')
        into v_antes
        from productos p left join sucursal_stock ss on ss.producto_codigo = p.codigo and ss.sucursal_id = v_suc
        where p.codigo = any(p_codigos) and ss.ubicacion is distinct from v_val;
        insert into sucursal_stock (sucursal_id, producto_codigo, producto_descripcion, stock, ubicacion)
        select v_suc, codigo, descripcion, 0, v_val from productos where codigo = any(p_codigos)
        on conflict (sucursal_id, producto_codigo) do update set ubicacion = excluded.ubicacion
        where sucursal_stock.ubicacion is distinct from excluded.ubicacion;
    else
        select coalesce(jsonb_agg(jsonb_build_object('codigo', codigo, 'antes',
                   case p_campo when 'categoria' then to_jsonb(categoria) when 'marca' then to_jsonb(marca)
                                when 'proveedor' then to_jsonb(proveedores) when 'ubicacion' then to_jsonb(ubicacion)
                                else to_jsonb(stock_minimo) end)), '[]')
        into v_antes
        from productos
        where codigo = any(p_codigos)
          and case p_campo when 'categoria' then categoria is distinct from v_val
                           when 'marca' then marca is distinct from v_val
                           when 'proveedor' then not (coalesce(proveedores, '{}') @> array[v_val])
                           when 'ubicacion' then ubicacion is distinct from v_val
                           else stock_minimo is distinct from v_num end;
        update productos set
            categoria = case when p_campo = 'categoria' then v_val else categoria end,
            marca = case when p_campo = 'marca' then v_val else marca end,
            proveedores = case when p_campo = 'proveedor' then array_append(coalesce(proveedores, '{}'), v_val) else proveedores end,
            ubicacion = case when p_campo = 'ubicacion' then v_val else ubicacion end,
            stock_minimo = case when p_campo = 'stock_minimo' then v_num else stock_minimo end,
            updated_at = now()
        where codigo in (select x->>'codigo' from jsonb_array_elements(v_antes) x);
    end if;
    v_n := jsonb_array_length(v_antes);
    if v_n > 0 then
        insert into cambios_masivos (campo, valor, sucursal_id, cantidad, antes, usuario_nombre)
        values (p_campo, coalesce(v_val, v_num::text), case when p_campo = 'ubicacion' then v_suc end, v_n, v_antes, v_usuario)
        returning id into v_id;
    end if;
    return jsonb_build_object('ok', true, 'cambiados', v_n, 'id', v_id);
end;
$$;
revoke execute on function public.productos_cambio_masivo(text[], text, text, uuid) from public, anon;
grant execute on function public.productos_cambio_masivo(text[], text, text, uuid) to anon, authenticated;

create or replace function public.productos_cambios_recientes()
returns jsonb language plpgsql stable security definer set search_path = public as
$$
declare v_uid uuid := refrimar_sesion_uid(30);
begin
    if v_uid is null then raise exception 'Tu sesión venció. Vuelve a entrar.'; end if;
    if not refrimar_tiene_permiso(v_uid, 'editar_inventario') then raise exception 'Tu usuario no puede editar productos'; end if;
    return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'campo', campo, 'valor', valor, 'cantidad', cantidad, 'usuario', usuario_nombre,
                                                         'fecha', created_at, 'deshecho', deshecho_at is not null) order by created_at desc)
                     from (select * from cambios_masivos order by created_at desc limit 15) c), '[]'::jsonb);
end;
$$;
revoke execute on function public.productos_cambios_recientes() from public, anon;
grant execute on function public.productos_cambios_recientes() to anon, authenticated;

-- Deshace un cambio masivo: devuelve cada producto a como estaba (si nadie lo cambió después)
create or replace function public.productos_cambio_deshacer(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as
$$
declare v_uid uuid := refrimar_sesion_uid(30); c record; x jsonb; v_n int := 0;
begin
    if v_uid is null then raise exception 'Tu sesión venció. Vuelve a entrar.'; end if;
    if not refrimar_tiene_permiso(v_uid, 'editar_inventario') then raise exception 'Tu usuario no puede editar productos'; end if;
    select * into c from cambios_masivos where id = p_id for update;
    if not found then raise exception 'Ese cambio no existe'; end if;
    if c.deshecho_at is not null then raise exception 'Ese cambio ya se deshizo'; end if;
    for x in select value from jsonb_array_elements(c.antes) loop
        if c.campo = 'ubicacion' and c.sucursal_id is not null then
            update sucursal_stock set ubicacion = x->>'antes'
            where sucursal_id = c.sucursal_id and producto_codigo = x->>'codigo' and ubicacion is not distinct from c.valor;
        elsif c.campo = 'categoria' then update productos set categoria = x->>'antes' where codigo = x->>'codigo' and categoria is not distinct from c.valor;
        elsif c.campo = 'marca' then update productos set marca = x->>'antes' where codigo = x->>'codigo' and marca is not distinct from c.valor;
        elsif c.campo = 'ubicacion' then update productos set ubicacion = x->>'antes' where codigo = x->>'codigo' and ubicacion is not distinct from c.valor;
        elsif c.campo = 'proveedor' then update productos set proveedores = array_remove(proveedores, c.valor) where codigo = x->>'codigo';
        elsif c.campo = 'stock_minimo' then update productos set stock_minimo = (x->>'antes')::numeric where codigo = x->>'codigo' and stock_minimo = c.valor::numeric;
        end if;
        if found then v_n := v_n + 1; end if;
    end loop;
    update cambios_masivos set deshecho_at = now() where id = p_id;
    return jsonb_build_object('ok', true, 'restaurados', v_n);
end;
$$;
revoke execute on function public.productos_cambio_deshacer(uuid) from public, anon;
grant execute on function public.productos_cambio_deshacer(uuid) to anon, authenticated;

-- ============================================================
-- 4. Posibles duplicados
-- ============================================================
create table if not exists public.duplicados_descartados (
    codigo_a text not null,
    codigo_b text not null,
    usuario_nombre text,
    created_at timestamptz not null default now(),
    primary key (codigo_a, codigo_b)
);
alter table public.duplicados_descartados enable row level security;
revoke all on table public.duplicados_descartados from anon, authenticated, public;

-- Las medidas y números de un nombre ("1/2", "3/4", "100", "2.5"): si no son iguales, no es el mismo producto
create or replace function public.refrimar_medidas(p text)
returns text language sql immutable as
$$ select coalesce(string_agg(m[1], ' ' order by m[1]), '')
   from regexp_matches(replace(lower(coalesce(p, '')), ',', '.'), '([0-9]+(?:[./][0-9]+)*)', 'g') as m $$;

create or replace function public.productos_duplicados(p_umbral numeric default 0.55)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as
$$
declare v_uid uuid := refrimar_sesion_uid(30);
begin
    if v_uid is null then raise exception 'Tu sesión venció. Vuelve a entrar.'; end if;
    if not refrimar_tiene_permiso(v_uid, 'ver_inventario') then raise exception 'Tu usuario no puede ver el inventario'; end if;
    return coalesce((
        select jsonb_agg(jsonb_build_object(
            'similitud', round(sim::numeric, 2),
            'a', jsonb_build_object('codigo', a_cod, 'descripcion', a_desc, 'marca', a_marca, 'precio', a_precio, 'stock', a_stock),
            'b', jsonb_build_object('codigo', b_cod, 'descripcion', b_desc, 'marca', b_marca, 'precio', b_precio, 'stock', b_stock)) order by sim desc)
        from (
            with p as (
                select codigo, descripcion, lower(descripcion) d, marca, precio, stock, refrimar_medidas(descripcion) med,
                       coalesce(nullif(variante_grupo, ''), codigo) grupo
                from productos where activo is not false and trim(coalesce(descripcion, '')) <> '')
            select a.codigo a_cod, a.descripcion a_desc, a.marca a_marca, a.precio a_precio, a.stock a_stock,
                   b.codigo b_cod, b.descripcion b_desc, b.marca b_marca, b.precio b_precio, b.stock b_stock,
                   similarity(a.d, b.d) sim
            from p a
            join p b on a.med = b.med and a.codigo < b.codigo     -- mismas medidas (1/2 no es 3/4)
            where a.grupo <> b.grupo
              and similarity(a.d, b.d) >= greatest(p_umbral, 0.4)
              and (coalesce(a.marca, '') = '' or coalesce(b.marca, '') = '' or lower(a.marca) = lower(b.marca))
              and not exists (select 1 from duplicados_descartados x where x.codigo_a = a.codigo and x.codigo_b = b.codigo)
            order by sim desc
            limit 150
        ) q), '[]'::jsonb);
end;
$$;
revoke execute on function public.productos_duplicados(numeric) from public, anon;
grant execute on function public.productos_duplicados(numeric) to anon, authenticated;

create or replace function public.productos_duplicado_descartar(p_a text, p_b text)
returns jsonb language plpgsql security definer set search_path = public as
$$
declare v_uid uuid := refrimar_sesion_uid(30);
begin
    if v_uid is null then raise exception 'Tu sesión venció. Vuelve a entrar.'; end if;
    if not refrimar_tiene_permiso(v_uid, 'editar_inventario') then raise exception 'Tu usuario no puede editar productos'; end if;
    insert into duplicados_descartados (codigo_a, codigo_b, usuario_nombre)
    values (least(p_a, p_b), greatest(p_a, p_b), (select nombre from usuarios where id = v_uid))
    on conflict do nothing;
    return jsonb_build_object('ok', true);
end;
$$;
revoke execute on function public.productos_duplicado_descartar(text, text) from public, anon;
grant execute on function public.productos_duplicado_descartar(text, text) to anon, authenticated;

-- ============================================================
-- 5. Buscador general (Ctrl + K). Cada parte sale solo si el usuario tiene permiso.
-- ============================================================
create or replace function public.buscar_global(p_q text)
returns jsonb language plpgsql stable security definer set search_path = public as
$$
declare
    v_uid uuid := refrimar_sesion_uid(30);
    v_q text := trim(coalesce(p_q, ''));
    v_n text := refrimar_norm(p_q);
    v_like text;
    r jsonb := '{}'::jsonb;
begin
    if v_uid is null then raise exception 'Tu sesión venció. Vuelve a entrar.'; end if;
    if length(v_q) < 2 then return r; end if;
    v_like := '%' || replace(replace(v_q, '%', ''), '_', '') || '%';

    if refrimar_tiene_permiso(v_uid, 'ver_inventario') or refrimar_tiene_permiso(v_uid, 'facturar') then
        r := r || jsonb_build_object('productos', coalesce((select jsonb_agg(x) from (
            select jsonb_build_object('codigo', codigo, 'descripcion', descripcion, 'precio', precio, 'stock', stock, 'ubicacion', ubicacion, 'marca', marca) x
            from productos
            where activo is not false
              and (descripcion ilike v_like or codigo ilike v_like or marca ilike v_like or codigos_alternos @> array[v_q]
                   or (v_n <> '' and refrimar_norm(descripcion) like '%' || v_n || '%'))
            order by (codigo = v_q or codigos_alternos @> array[v_q]) desc, (descripcion ilike v_q || '%') desc, descripcion
            limit 8) s), '[]'::jsonb));
    end if;
    if refrimar_tiene_permiso(v_uid, 'clientes') or refrimar_tiene_permiso(v_uid, 'facturar') or refrimar_tiene_permiso(v_uid, 'ver_cxc') then
        r := r || jsonb_build_object('clientes', coalesce((select jsonb_agg(x) from (
            select jsonb_build_object('id', id, 'nombre', nombre, 'rif', rif, 'telefono', telefono, 'saldo', saldo_pendiente) x
            from clientes
            where nombre ilike v_like or (v_n <> '' and refrimar_norm(rif) like '%' || v_n || '%') or telefono ilike v_like
            order by nombre limit 5) s), '[]'::jsonb));
    end if;
    if refrimar_tiene_permiso(v_uid, 'facturar') or refrimar_tiene_permiso(v_uid, 'ver_reportes') or refrimar_tiene_permiso(v_uid, 'ver_cxc') then
        r := r || jsonb_build_object('facturas', coalesce((select jsonb_agg(x) from (
            select jsonb_build_object('id', id, 'numero', coalesce(numero_doc, numero), 'cliente', cliente_nombre, 'total', total_usd,
                                      'fecha', created_at, 'estado', estado, 'metodo', metodo_pago) x
            from ventas
            where (v_n <> '' and (refrimar_norm(numero) like '%' || v_n || '%' or refrimar_norm(numero_doc) like '%' || v_n || '%'))
               or cliente_nombre ilike v_like
            order by created_at desc limit 5) s), '[]'::jsonb));
    end if;
    if refrimar_tiene_permiso(v_uid, 'proveedores') or refrimar_tiene_permiso(v_uid, 'compras') or refrimar_tiene_permiso(v_uid, 'ver_compras') then
        r := r || jsonb_build_object('proveedores', coalesce((select jsonb_agg(x) from (
            select jsonb_build_object('id', id, 'nombre', nombre, 'rif', rif, 'telefono', telefono) x
            from proveedores
            where nombre ilike v_like or (v_n <> '' and refrimar_norm(rif) like '%' || v_n || '%')
            order by nombre limit 4) s), '[]'::jsonb));
    end if;
    if refrimar_tiene_permiso(v_uid, 'cotizar') then
        r := r || jsonb_build_object('cotizaciones', coalesce((select jsonb_agg(x) from (
            select jsonb_build_object('id', id, 'numero', numero, 'cliente', cliente_nombre, 'total', total_usd, 'estado', estado, 'fecha', created_at) x
            from cotizaciones
            where numero ilike v_like or cliente_nombre ilike v_like
            order by created_at desc limit 4) s), '[]'::jsonb));
    end if;
    return r;
end;
$$;
revoke execute on function public.buscar_global(text) from public, anon;
grant execute on function public.buscar_global(text) to anon, authenticated;

-- ============================================================
-- Seguridad y registro
-- ============================================================
insert into public.seguridad_rpc (nombre, nivel, permiso, gracia_dias)
select v.* from (values ('productos_cambio_masivo', 'sesion', null, 0), ('productos_cambios_recientes', 'sesion', null, 0),
                        ('productos_cambio_deshacer', 'sesion', null, 0), ('productos_duplicados', 'sesion', null, 0),
                        ('productos_duplicado_descartar', 'sesion', null, 0), ('buscar_global', 'sesion', null, 0)) as v(nombre, nivel, permiso, gracia)
where not exists (select 1 from public.seguridad_rpc s where s.nombre = v.nombre);

insert into public.migraciones_aplicadas (nombre, descripcion, version_app)
values ('2026-11-17-etapa4a-ordenar-inventario', 'Cajas→unidades, cambios masivos con deshacer, duplicados y buscador general', 'v3.9.26')
on conflict (nombre) do nothing;
notify pgrst, 'reload schema';

select 'Listo' as resultado;
