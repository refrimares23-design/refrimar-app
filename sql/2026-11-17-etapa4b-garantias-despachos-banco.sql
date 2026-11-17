-- ============================================================
-- REFRIMAR — Etapa 4, parte 2 (17-nov-2026): garantías, despachos, banco y preguntas
--
-- 1. Respaldo.
-- 2. Garantías: desde la factura, con seguimiento (recibida → en proveedor → lista → entregada).
-- 3. Despachos a domicilio u obra, con entregas por partes.
-- 4. Conciliación bancaria: los pagos móviles y transferencias del sistema para cruzarlos
--    con el Excel del banco (el cruce lo hace la pantalla).
-- 5. Consultas para el asistente de preguntas (solo lectura, según permisos).
-- 6. Alertas: despachos atrasados y garantías que llevan más de 15 días.
--
-- Supabase → SQL Editor → New query → pega TODO → Run. Se puede correr varias veces.
-- No borra nada.
-- ============================================================

-- 1. Respaldo
create schema if not exists respaldo_inventario;
revoke all on schema respaldo_inventario from anon, authenticated, public;
do $$
declare s text := to_char(now() at time zone 'America/Caracas', 'YYYYMMDD_HH24MISS');
begin
    if to_regclass('public.productos') is not null then
        execute format('create table if not exists respaldo_inventario.%I as table public.productos', 'productos_' || s);
    end if;
end $$;

-- ============================================================
-- 2. Garantías
-- ============================================================
alter table public.productos add column if not exists garantia_dias integer;
create sequence if not exists public.seq_garantia;
create table if not exists public.garantias (
    id uuid primary key default gen_random_uuid(),
    numero text not null unique,
    venta_id uuid references public.ventas(id),
    venta_numero text,
    fecha_venta timestamptz,
    cliente_nombre text,
    cliente_rif text,
    cliente_telefono text,
    producto_codigo text not null,
    descripcion text,
    cantidad numeric not null default 1,
    serial text,
    falla text not null,
    estado text not null default 'recibida' check (estado in ('recibida', 'en_proveedor', 'lista', 'entregada', 'rechazada')),
    resolucion text check (resolucion in ('reparado', 'cambiado', 'reembolso', 'sin_falla', 'rechazado')),
    proveedor text,
    vence date,
    dentro_garantia boolean,
    sucursal_id uuid,
    sucursal_nombre text,
    usuario_nombre text,
    historial jsonb not null default '[]'::jsonb,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);
create index if not exists garantias_estado_idx on public.garantias (estado, created_at);
alter table public.garantias enable row level security;
revoke all on table public.garantias from anon, authenticated, public;
-- Se lee con sesión (como las demás tablas); se escribe solo por funciones
do $$ begin
    if not exists (select 1 from pg_policies where tablename = 'garantias' and policyname = 'garantias_leer') then
        create policy garantias_leer on public.garantias for select to anon, authenticated using (refrimar_sesion_uid(30) is not null);
    end if;
end $$;
grant select on public.garantias to anon, authenticated;

-- p = { venta_id, producto_codigo, cantidad, serial, falla, telefono, sucursal_id, sucursal_nombre }
create or replace function public.garantia_registrar(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as
$$
declare
    v_uid uuid := refrimar_sesion_uid(30); v_usuario text;
    v_venta record; v_cod text := nullif(trim(coalesce(p->>'producto_codigo', '')), '');
    v_cant numeric := coalesce(nullif(p->>'cantidad', '')::numeric, 1);
    v_vendida numeric; v_desc text; v_dias int; v_vence date; v_dentro boolean; v_num text; v_id uuid;
    v_falla text := nullif(trim(coalesce(p->>'falla', '')), '');
begin
    if v_uid is null then raise exception 'Tu sesión venció. Vuelve a entrar.'; end if;
    if not (refrimar_tiene_permiso(v_uid, 'facturar') or refrimar_tiene_permiso(v_uid, 'devoluciones')) then raise exception 'Tu usuario no puede registrar garantías'; end if;
    select nombre into v_usuario from usuarios where id = v_uid;
    if v_falla is null then raise exception 'Describe la falla'; end if;
    select * into v_venta from ventas where id = nullif(p->>'venta_id', '')::uuid;
    if not found then raise exception 'Factura no encontrada'; end if;
    if v_venta.estado <> 'completada' then raise exception 'La factura está %', v_venta.estado; end if;
    select coalesce(sum(cantidad), 0), max(descripcion) into v_vendida, v_desc from detalle_venta where venta_id = v_venta.id and producto_codigo = v_cod;
    if v_vendida <= 0 then raise exception 'Ese producto no está en la factura'; end if;
    if v_cant <= 0 or v_cant > v_vendida then raise exception 'Cantidad inválida: en la factura hay %', v_vendida; end if;
    select garantia_dias into v_dias from productos where codigo = v_cod;
    if v_dias is not null and v_dias > 0 then
        v_vence := (v_venta.created_at at time zone 'America/Caracas')::date + v_dias;
        v_dentro := v_vence >= (now() at time zone 'America/Caracas')::date;
    end if;
    v_num := 'GAR-' || lpad(nextval('seq_garantia')::text, 6, '0');
    insert into garantias (numero, venta_id, venta_numero, fecha_venta, cliente_nombre, cliente_rif, cliente_telefono, producto_codigo, descripcion,
                           cantidad, serial, falla, vence, dentro_garantia, sucursal_id, sucursal_nombre, usuario_nombre, historial)
    values (v_num, v_venta.id, coalesce(v_venta.numero_doc, v_venta.numero), v_venta.created_at, v_venta.cliente_nombre, v_venta.cliente_rif,
            coalesce(nullif(trim(coalesce(p->>'telefono', '')), ''), v_venta.cliente_telefono), v_cod, v_desc, v_cant,
            nullif(trim(coalesce(p->>'serial', '')), ''), left(v_falla, 500), v_vence, v_dentro,
            coalesce(nullif(p->>'sucursal_id', '')::uuid, v_venta.sucursal_id), coalesce(nullif(p->>'sucursal_nombre', ''), v_venta.sucursal_nombre), v_usuario,
            jsonb_build_array(jsonb_build_object('fecha', now(), 'estado', 'recibida', 'nota', v_falla, 'usuario', v_usuario)))
    returning id into v_id;
    return jsonb_build_object('ok', true, 'id', v_id, 'numero', v_num, 'vence', v_vence, 'dentro_garantia', v_dentro);
end;
$$;
revoke execute on function public.garantia_registrar(jsonb) from public, anon;
grant execute on function public.garantia_registrar(jsonb) to anon, authenticated;

-- Cambia el estado. Si se resuelve "cambiado" con descontar = true, el producto nuevo sale del inventario (kardex).
create or replace function public.garantia_estado(p_id uuid, p_estado text, p_nota text default null, p_resolucion text default null,
                                                  p_proveedor text default null, p_descontar boolean default false)
returns jsonb language plpgsql security definer set search_path = public as
$$
declare v_uid uuid := refrimar_sesion_uid(30); v_usuario text; g record;
begin
    if v_uid is null then raise exception 'Tu sesión venció. Vuelve a entrar.'; end if;
    if not (refrimar_tiene_permiso(v_uid, 'facturar') or refrimar_tiene_permiso(v_uid, 'devoluciones')) then raise exception 'Tu usuario no puede cambiar garantías'; end if;
    select nombre into v_usuario from usuarios where id = v_uid;
    select * into g from garantias where id = p_id for update;
    if not found then raise exception 'Garantía no encontrada'; end if;
    if g.estado in ('entregada', 'rechazada') then raise exception 'La garantía % ya está cerrada', g.numero; end if;
    if p_estado not in ('recibida', 'en_proveedor', 'lista', 'entregada', 'rechazada') then raise exception 'Estado inválido'; end if;
    if p_resolucion is not null and p_resolucion not in ('reparado', 'cambiado', 'reembolso', 'sin_falla', 'rechazado') then raise exception 'Resolución inválida'; end if;
    if p_estado = 'lista' and coalesce(p_resolucion, g.resolucion) is null then raise exception 'Indica qué se hizo (reparado, cambiado…)'; end if;
    if p_descontar and coalesce(p_resolucion, g.resolucion) = 'cambiado' and p_estado in ('lista', 'entregada')
       and not exists (select 1 from jsonb_array_elements(g.historial) h where (h->>'descontado')::boolean) then
        perform kardex_ajuste(g.producto_codigo, 'salida', g.cantidad, null, 'Garantía ' || g.numero || ' · cambio al cliente', nullif(g.sucursal_id, '00000000-0000-0000-0000-000000000001'), coalesce(v_usuario, 'Sistema'));
    end if;
    update garantias set
        estado = p_estado,
        resolucion = coalesce(p_resolucion, resolucion, case when p_estado = 'rechazada' then 'rechazado' end),
        proveedor = coalesce(nullif(trim(coalesce(p_proveedor, '')), ''), proveedor),
        historial = historial || jsonb_build_object('fecha', now(), 'estado', p_estado, 'nota', nullif(trim(coalesce(p_nota, '')), ''),
                                                   'resolucion', p_resolucion, 'usuario', v_usuario,
                                                   'descontado', p_descontar and coalesce(p_resolucion, resolucion) = 'cambiado' and p_estado in ('lista', 'entregada')),
        updated_at = now()
    where id = p_id;
    return jsonb_build_object('ok', true);
end;
$$;
revoke execute on function public.garantia_estado(uuid, text, text, text, text, boolean) from public, anon;
grant execute on function public.garantia_estado(uuid, text, text, text, text, boolean) to anon, authenticated;

-- La garantía (días) se pone desde la ficha del producto o con cambios masivos (por categoría, marca…)
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
    if p_campo not in ('categoria', 'marca', 'proveedor', 'ubicacion', 'stock_minimo', 'garantia_dias') then raise exception 'Campo no permitido: %', p_campo; end if;
    if p_campo in ('proveedor') and v_val is null then raise exception 'Escribe el proveedor'; end if;
    if p_campo = 'stock_minimo' then
        v_num := nullif(replace(coalesce(v_val, ''), ',', '.'), '')::numeric;
        if v_num is null or v_num < 0 then raise exception 'El mínimo debe ser un número mayor o igual a 0'; end if;
    end if;
    if p_campo = 'garantia_dias' then
        v_num := nullif(replace(coalesce(v_val, ''), ',', '.'), '')::numeric;   -- vacío = sin garantía
        if v_num is not null and (v_num < 0 or v_num > 3650 or v_num <> trunc(v_num)) then raise exception 'La garantía va en días (0 a 3650)'; end if;
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
                                when 'garantia_dias' then to_jsonb(garantia_dias)
                                else to_jsonb(stock_minimo) end)), '[]')
        into v_antes
        from productos
        where codigo = any(p_codigos)
          and case p_campo when 'categoria' then categoria is distinct from v_val
                           when 'marca' then marca is distinct from v_val
                           when 'proveedor' then not (coalesce(proveedores, '{}') @> array[v_val])
                           when 'ubicacion' then ubicacion is distinct from v_val
                           when 'garantia_dias' then garantia_dias is distinct from v_num::int
                           else stock_minimo is distinct from v_num end;
        update productos set
            categoria = case when p_campo = 'categoria' then v_val else categoria end,
            marca = case when p_campo = 'marca' then v_val else marca end,
            proveedores = case when p_campo = 'proveedor' then array_append(coalesce(proveedores, '{}'), v_val) else proveedores end,
            ubicacion = case when p_campo = 'ubicacion' then v_val else ubicacion end,
            stock_minimo = case when p_campo = 'stock_minimo' then v_num else stock_minimo end,
            garantia_dias = case when p_campo = 'garantia_dias' then v_num::int else garantia_dias end,
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
        elsif c.campo = 'garantia_dias' then update productos set garantia_dias = (x->>'antes')::int where codigo = x->>'codigo' and garantia_dias is not distinct from c.valor::int;
        elsif c.campo = 'stock_minimo' then update productos set stock_minimo = (x->>'antes')::numeric where codigo = x->>'codigo' and stock_minimo = c.valor::numeric;
        end if;
        if found then v_n := v_n + 1; end if;
    end loop;
    update cambios_masivos set deshecho_at = now() where id = p_id;
    return jsonb_build_object('ok', true, 'restaurados', v_n);
end;
$$;

-- ============================================================
-- 3. Despachos (domicilio / obra), con entregas por partes
-- ============================================================
create sequence if not exists public.seq_despacho;
create table if not exists public.despachos (
    id uuid primary key default gen_random_uuid(),
    numero text not null unique,
    venta_id uuid references public.ventas(id),
    venta_numero text,
    cliente_nombre text,
    tipo text not null default 'domicilio' check (tipo in ('domicilio', 'obra', 'retiro')),
    direccion text,
    contacto text,
    telefono text,
    fecha_programada date,
    estado text not null default 'pendiente' check (estado in ('pendiente', 'en_ruta', 'parcial', 'entregado', 'cancelado')),
    chofer text,
    notas text,
    sucursal_id uuid,
    sucursal_nombre text,
    usuario_nombre text,
    entregado_at timestamptz,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);
create table if not exists public.despacho_detalle (
    id uuid primary key default gen_random_uuid(),
    despacho_id uuid not null references public.despachos(id) on delete cascade,
    producto_codigo text not null,
    descripcion text,
    cantidad numeric not null,
    entregada numeric not null default 0
);
create table if not exists public.despacho_entregas (
    id uuid primary key default gen_random_uuid(),
    despacho_id uuid not null references public.despachos(id) on delete cascade,
    items jsonb not null,
    recibio text,
    nota text,
    usuario_nombre text,
    created_at timestamptz not null default now()
);
create index if not exists despachos_estado_idx on public.despachos (estado, fecha_programada);
create index if not exists despacho_detalle_idx on public.despacho_detalle (despacho_id);
do $$
declare t text;
begin
    foreach t in array array['despachos', 'despacho_detalle', 'despacho_entregas'] loop
        execute format('alter table public.%I enable row level security', t);
        execute format('revoke all on table public.%I from anon, authenticated, public', t);
        if not exists (select 1 from pg_policies where tablename = t and policyname = t || '_leer') then
            execute format('create policy %I on public.%I for select to anon, authenticated using (refrimar_sesion_uid(30) is not null)', t || '_leer', t);
        end if;
        execute format('grant select on public.%I to anon, authenticated', t);
    end loop;
end $$;

-- p = { venta_id, tipo, direccion, contacto, telefono, fecha_programada, notas, sucursal_id, sucursal_nombre,
--       items: [{codigo, cantidad}] (si no viene: lo que falta por despachar de la factura) }
create or replace function public.despacho_crear(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as
$$
declare
    v_uid uuid := refrimar_sesion_uid(30); v_usuario text; v_venta record; v_id uuid; v_num text; r record; v_q numeric; v_n int := 0;
begin
    if v_uid is null then raise exception 'Tu sesión venció. Vuelve a entrar.'; end if;
    if not refrimar_tiene_permiso(v_uid, 'facturar') then raise exception 'Tu usuario no puede programar despachos'; end if;
    select nombre into v_usuario from usuarios where id = v_uid;
    select * into v_venta from ventas where id = nullif(p->>'venta_id', '')::uuid;
    if not found then raise exception 'Factura no encontrada'; end if;
    if v_venta.estado <> 'completada' then raise exception 'La factura está %', v_venta.estado; end if;
    if coalesce(p->>'tipo', 'domicilio') not in ('domicilio', 'obra', 'retiro') then raise exception 'Tipo de despacho inválido'; end if;
    if coalesce(p->>'tipo', 'domicilio') <> 'retiro' and nullif(trim(coalesce(p->>'direccion', '')), '') is null then raise exception 'Falta la dirección de entrega'; end if;
    v_num := 'DES-' || lpad(nextval('seq_despacho')::text, 6, '0');
    insert into despachos (numero, venta_id, venta_numero, cliente_nombre, tipo, direccion, contacto, telefono, fecha_programada, notas,
                           sucursal_id, sucursal_nombre, usuario_nombre)
    values (v_num, v_venta.id, coalesce(v_venta.numero_doc, v_venta.numero), v_venta.cliente_nombre, coalesce(p->>'tipo', 'domicilio'),
            nullif(trim(coalesce(p->>'direccion', '')), ''), nullif(trim(coalesce(p->>'contacto', '')), ''),
            coalesce(nullif(trim(coalesce(p->>'telefono', '')), ''), v_venta.cliente_telefono), nullif(p->>'fecha_programada', '')::date,
            nullif(trim(coalesce(p->>'notas', '')), ''), coalesce(nullif(p->>'sucursal_id', '')::uuid, v_venta.sucursal_id),
            coalesce(nullif(p->>'sucursal_nombre', ''), v_venta.sucursal_nombre), v_usuario)
    returning id into v_id;
    -- Lo que falta por despachar de cada producto (lo vendido − devuelto − lo que ya está en otros despachos activos)
    for r in
        select d.producto_codigo cod, max(d.descripcion) descr, sum(d.cantidad)
               - coalesce((select sum(nd.cantidad) from notas_credito_detalle nd join notas_credito n on n.id = nd.nota_id where n.venta_id = v_venta.id and nd.producto_codigo = d.producto_codigo), 0)
               - coalesce((select sum(dd.cantidad) from despacho_detalle dd join despachos de on de.id = dd.despacho_id where de.venta_id = v_venta.id and de.id <> v_id and de.estado <> 'cancelado' and dd.producto_codigo = d.producto_codigo), 0) pend
        from detalle_venta d join productos pr on pr.codigo = d.producto_codigo
        where d.venta_id = v_venta.id and coalesce(pr.tipo_producto, 'fisico') = 'fisico'
        group by d.producto_codigo
    loop
        if jsonb_typeof(p->'items') = 'array' then
            select sum(coalesce(nullif(x->>'cantidad', '')::numeric, 0)) into v_q from jsonb_array_elements(p->'items') x where x->>'codigo' = r.cod;
            if v_q is null or v_q <= 0 then continue; end if;
            if v_q > r.pend + 0.0005 then raise exception 'De "%" solo quedan % por despachar', r.descr, r.pend; end if;
        else
            v_q := r.pend;
            if v_q <= 0 then continue; end if;
        end if;
        insert into despacho_detalle (despacho_id, producto_codigo, descripcion, cantidad) values (v_id, r.cod, r.descr, v_q);
        v_n := v_n + 1;
    end loop;
    if v_n = 0 then raise exception 'No queda nada por despachar de esa factura'; end if;
    return jsonb_build_object('ok', true, 'id', v_id, 'numero', v_num, 'lineas', v_n);
end;
$$;
revoke execute on function public.despacho_crear(jsonb) from public, anon;
grant execute on function public.despacho_crear(jsonb) to anon, authenticated;

-- Registra lo que se entregó (p_items null = todo lo pendiente)
create or replace function public.despacho_entregar(p_id uuid, p_items jsonb default null, p_recibio text default null, p_nota text default null)
returns jsonb language plpgsql security definer set search_path = public as
$$
declare v_uid uuid := refrimar_sesion_uid(30); v_usuario text; d record; l record; v_q numeric; v_log jsonb := '[]'::jsonb; v_estado text;
begin
    if v_uid is null then raise exception 'Tu sesión venció. Vuelve a entrar.'; end if;
    if not refrimar_tiene_permiso(v_uid, 'facturar') then raise exception 'Tu usuario no puede registrar entregas'; end if;
    select nombre into v_usuario from usuarios where id = v_uid;
    select * into d from despachos where id = p_id for update;
    if not found then raise exception 'Despacho no encontrado'; end if;
    if d.estado in ('entregado', 'cancelado') then raise exception 'El despacho % ya está %', d.numero, d.estado; end if;
    for l in select * from despacho_detalle where despacho_id = p_id order by descripcion for update loop
        if p_items is null then v_q := l.cantidad - l.entregada;
        else select sum(coalesce(nullif(x->>'cantidad', '')::numeric, 0)) into v_q from jsonb_array_elements(p_items) x where x->>'codigo' = l.producto_codigo;
        end if;
        v_q := coalesce(v_q, 0);
        if v_q <= 0 then continue; end if;
        if v_q > l.cantidad - l.entregada + 0.0005 then raise exception 'De "%" solo faltan %', l.descripcion, l.cantidad - l.entregada; end if;
        update despacho_detalle set entregada = entregada + v_q where id = l.id;
        v_log := v_log || jsonb_build_object('codigo', l.producto_codigo, 'descripcion', l.descripcion, 'cantidad', v_q);
    end loop;
    if jsonb_array_length(v_log) = 0 then raise exception 'Indica qué se entregó'; end if;
    insert into despacho_entregas (despacho_id, items, recibio, nota, usuario_nombre)
    values (p_id, v_log, nullif(trim(coalesce(p_recibio, '')), ''), nullif(trim(coalesce(p_nota, '')), ''), v_usuario);
    v_estado := case when exists (select 1 from despacho_detalle where despacho_id = p_id and entregada < cantidad - 0.0005) then 'parcial' else 'entregado' end;
    update despachos set estado = v_estado, entregado_at = case when v_estado = 'entregado' then now() end, updated_at = now() where id = p_id;
    return jsonb_build_object('ok', true, 'estado', v_estado);
end;
$$;
revoke execute on function public.despacho_entregar(uuid, jsonb, text, text) from public, anon;
grant execute on function public.despacho_entregar(uuid, jsonb, text, text) to anon, authenticated;

create or replace function public.despacho_estado(p_id uuid, p_estado text, p_chofer text default null, p_fecha date default null, p_nota text default null)
returns jsonb language plpgsql security definer set search_path = public as
$$
declare v_uid uuid := refrimar_sesion_uid(30); d record;
begin
    if v_uid is null then raise exception 'Tu sesión venció. Vuelve a entrar.'; end if;
    if not refrimar_tiene_permiso(v_uid, 'facturar') then raise exception 'Tu usuario no puede cambiar despachos'; end if;
    select * into d from despachos where id = p_id for update;
    if not found then raise exception 'Despacho no encontrado'; end if;
    if d.estado in ('entregado', 'cancelado') then raise exception 'El despacho % ya está %', d.numero, d.estado; end if;
    if p_estado not in ('pendiente', 'en_ruta', 'cancelado') then raise exception 'Estado inválido'; end if;
    if p_estado = 'cancelado' and exists (select 1 from despacho_detalle where despacho_id = p_id and entregada > 0) then
        raise exception 'Ya se entregó parte: no se puede cancelar';
    end if;
    update despachos set
        estado = case when p_estado = 'pendiente' and d.estado = 'parcial' then 'parcial' else p_estado end,
        chofer = coalesce(nullif(trim(coalesce(p_chofer, '')), ''), chofer),
        fecha_programada = coalesce(p_fecha, fecha_programada),
        notas = case when nullif(trim(coalesce(p_nota, '')), '') is null then notas else concat_ws(E'\n', notas, trim(p_nota)) end,
        updated_at = now()
    where id = p_id;
    return jsonb_build_object('ok', true);
end;
$$;
revoke execute on function public.despacho_estado(uuid, text, text, date, text) from public, anon;
grant execute on function public.despacho_estado(uuid, text, text, date, text) to anon, authenticated;

-- ============================================================
-- 4. Conciliación bancaria: pagos del sistema que deben aparecer en el banco
-- ============================================================
create or replace function public.conciliacion_pagos(p_desde date, p_hasta date)
returns jsonb language plpgsql stable security definer set search_path = public as
$$
declare v_uid uuid := refrimar_sesion_uid(30);
begin
    if v_uid is null then raise exception 'Tu sesión venció. Vuelve a entrar.'; end if;
    if not refrimar_tiene_permiso(v_uid, 'ver_finanzas') then raise exception 'Tu usuario no puede ver las finanzas'; end if;
    if p_hasta - p_desde > 62 then raise exception 'Máximo dos meses por conciliación'; end if;
    return coalesce((select jsonb_agg(x order by x->>'fecha') from (
        -- Pagos de las ventas (pago móvil, transferencia en Bs y punto)
        select jsonb_build_object('origen', 'venta', 'id', v.id, 'numero', coalesce(v.numero_doc, v.numero), 'fecha', v.created_at,
                                  'metodo', pg->>'metodo', 'banco', pg->>'banco', 'referencia', pg->>'referencia',
                                  'monto_bs', round(coalesce(nullif(pg->>'monto_bs', '')::numeric, nullif(pg->>'monto', '')::numeric * v.tasa_bcv), 2),
                                  'cliente', v.cliente_nombre, 'usuario', v.usuario_nombre, 'tienda', coalesce(v.sucursal_nombre, 'Principal'),
                                  'anulada', v.estado <> 'completada') x
        from ventas v cross join lateral jsonb_array_elements(case when jsonb_typeof(v.pagos) = 'array' then v.pagos else '[]'::jsonb end) pg
        where (v.created_at at time zone 'America/Caracas')::date between p_desde - 1 and p_hasta + 1
          and pg->>'metodo' in ('pago_movil', 'transferencia', 'punto') and coalesce(pg->>'moneda', 'VES') = 'VES'
        union all
        -- Abonos y otros ingresos de caja por banco
        select jsonb_build_object('origen', 'caja', 'id', c.id, 'numero', c.concepto, 'fecha', c.fecha, 'metodo', c.metodo_pago, 'banco', null,
                                  'referencia', c.notas, 'monto_bs', round(coalesce(c.monto_bs, 0), 2), 'cliente', null, 'usuario', c.usuario_nombre,
                                  'tienda', coalesce((select nombre from sucursales s where s.id = c.sucursal_id), 'Principal'), 'anulada', false)
        from caja_movimientos c
        where c.tipo = 'ingreso' and c.metodo_pago in ('pago_movil', 'transferencia', 'punto')
          and (c.fecha at time zone 'America/Caracas')::date between p_desde - 1 and p_hasta + 1
    ) q), '[]'::jsonb);
end;
$$;
revoke execute on function public.conciliacion_pagos(date, date) from public, anon;
grant execute on function public.conciliacion_pagos(date, date) to anon, authenticated;

-- ============================================================
-- 5. Consultas del asistente (solo lectura). Cada consulta revisa el permiso del usuario.
-- ============================================================
create or replace function public.consulta_datos(p_tipo text, p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as
$$
declare
    CASA constant uuid := '00000000-0000-0000-0000-000000000001';
    v_uid uuid := refrimar_sesion_uid(30);
    v_hoy date := (now() at time zone 'America/Caracas')::date;
    v_desde date := coalesce(nullif(p->>'desde', '')::date, (now() at time zone 'America/Caracas')::date - 30);
    v_hasta date := coalesce(nullif(p->>'hasta', '')::date, (now() at time zone 'America/Caracas')::date);
    v_lim int := least(greatest(coalesce(nullif(p->>'limite', '')::int, 10), 1), 50);
    v_q text := nullif(trim(coalesce(p->>'q', '')), '');
    v_costos boolean;
begin
    if v_uid is null then raise exception 'Tu sesión venció. Vuelve a entrar.'; end if;
    v_costos := refrimar_tiene_permiso(v_uid, 'ver_costos');
    if v_hasta - v_desde > 400 then raise exception 'Rango muy largo (máximo 400 días)'; end if;

    if p_tipo = 'ventas_resumen' then
        if not (refrimar_tiene_permiso(v_uid, 'ver_reportes') or refrimar_tiene_permiso(v_uid, 'ver_dashboard')) then return jsonb_build_object('error', 'Sin permiso para ver ventas'); end if;
        return jsonb_build_object('desde', v_desde, 'hasta', v_hasta,
            'por_tienda', (select coalesce(jsonb_agg(jsonb_build_object('tienda', coalesce(sucursal_nombre, 'Principal'), 'ventas', n, 'total_usd', t, 'credito_usd', c)), '[]')
                           from (select sucursal_nombre, count(*) n, round(sum(total_usd), 2) t, round(sum(total_usd) filter (where metodo_pago = 'credito'), 2) c
                                 from ventas where estado = 'completada' and (created_at at time zone 'America/Caracas')::date between v_desde and v_hasta group by 1) x),
            'por_metodo', (select coalesce(jsonb_object_agg(coalesce(metodo_pago, '?'), t), '{}')
                           from (select metodo_pago, round(sum(total_usd), 2) t from ventas where estado = 'completada'
                                 and (created_at at time zone 'America/Caracas')::date between v_desde and v_hasta group by 1) x),
            'por_dia', (select coalesce(jsonb_agg(jsonb_build_object('dia', d, 'ventas', n, 'total_usd', t) order by d), '[]')
                        from (select (created_at at time zone 'America/Caracas')::date d, count(*) n, round(sum(total_usd), 2) t
                              from ventas where estado = 'completada' and (created_at at time zone 'America/Caracas')::date between v_desde and v_hasta
                              group by 1 order by 1 desc limit 62) x),
            'utilidad_usd', case when v_costos then (select round(sum(d.total - d.cantidad * coalesce(nullif(d.costo_unitario, 0), pr.costo, 0)), 2)
                                                    from detalle_venta d join ventas v on v.id = d.venta_id left join productos pr on pr.codigo = d.producto_codigo
                                                    where v.estado = 'completada' and (v.created_at at time zone 'America/Caracas')::date between v_desde and v_hasta) end);

    elsif p_tipo = 'productos_top' then
        if not (refrimar_tiene_permiso(v_uid, 'ver_reportes') or refrimar_tiene_permiso(v_uid, 'ver_inventario')) then return jsonb_build_object('error', 'Sin permiso'); end if;
        return jsonb_build_object('desde', v_desde, 'hasta', v_hasta, 'orden', coalesce(p->>'orden', 'monto'), 'productos', (
            select coalesce(jsonb_agg(x), '[]') from (
                select jsonb_build_object('codigo', d.producto_codigo, 'descripcion', max(d.descripcion), 'cantidad', sum(d.cantidad), 'monto_usd', round(sum(d.total), 2),
                                          'utilidad_usd', case when v_costos then round(sum(d.total - d.cantidad * coalesce(nullif(d.costo_unitario, 0), pr.costo, 0)), 2) end) x
                from detalle_venta d join ventas v on v.id = d.venta_id left join productos pr on pr.codigo = d.producto_codigo
                where v.estado = 'completada' and (v.created_at at time zone 'America/Caracas')::date between v_desde and v_hasta
                group by d.producto_codigo
                order by case when p->>'orden' = 'cantidad' then sum(d.cantidad) else sum(d.total) end desc
                limit v_lim) s));

    elsif p_tipo = 'producto_info' then
        if not (refrimar_tiene_permiso(v_uid, 'ver_inventario') or refrimar_tiene_permiso(v_uid, 'facturar')) then return jsonb_build_object('error', 'Sin permiso'); end if;
        if v_q is null then return jsonb_build_object('error', 'Falta el producto'); end if;
        return (select coalesce(jsonb_agg(x), '[]') from (
            select jsonb_build_object('codigo', pr.codigo, 'descripcion', pr.descripcion, 'marca', pr.marca, 'precio_usd', pr.precio,
                       'costo_usd', case when v_costos then pr.costo end, 'stock_principal', pr.stock, 'ubicacion', pr.ubicacion,
                       'stock_tiendas', (select coalesce(jsonb_object_agg(s.nombre, ss.stock), '{}') from sucursal_stock ss join sucursales s on s.id = ss.sucursal_id where ss.producto_codigo = pr.codigo),
                       'vendido_30_dias', (select coalesce(sum(d.cantidad), 0) from detalle_venta d join ventas v on v.id = d.venta_id where d.producto_codigo = pr.codigo and v.estado = 'completada' and v.created_at >= now() - interval '30 days'),
                       'ultima_venta', (select max(v.created_at) from detalle_venta d join ventas v on v.id = d.venta_id where d.producto_codigo = pr.codigo and v.estado = 'completada'),
                       'proveedores', pr.proveedores) x
            from productos pr
            where pr.codigo = v_q or pr.codigos_alternos @> array[v_q] or pr.descripcion ilike '%' || v_q || '%'
            order by (pr.codigo = v_q) desc, similarity(lower(pr.descripcion), lower(v_q)) desc
            limit 5) s);

    elsif p_tipo = 'clientes_deudas' then
        if not refrimar_tiene_permiso(v_uid, 'ver_cxc') then return jsonb_build_object('error', 'Sin permiso para ver cuentas por cobrar'); end if;
        return (select coalesce(jsonb_agg(x), '[]') from (
            select jsonb_build_object('cliente', max(cliente_nombre), 'rif', cliente_rif, 'facturas', count(*),
                                      'debe_usd', round(sum(total_usd - monto_abonado), 2),
                                      'vencido_usd', round(sum(total_usd - monto_abonado) filter (where (created_at at time zone 'America/Caracas')::date + coalesce(dias_credito, 30) < v_hoy), 2),
                                      'mas_vieja', min(created_at)) x
            from ventas
            where metodo_pago = 'credito' and estado = 'completada' and total_usd - monto_abonado > 0.005
              and (v_q is null or cliente_nombre ilike '%' || v_q || '%' or cliente_rif ilike '%' || v_q || '%')
            group by coalesce(nullif(cliente_rif, ''), cliente_nombre), cliente_rif
            order by sum(total_usd - monto_abonado) desc limit v_lim) s);

    elsif p_tipo = 'proveedores_deudas' then
        if not refrimar_tiene_permiso(v_uid, 'ver_cxp') then return jsonb_build_object('error', 'Sin permiso para ver cuentas por pagar'); end if;
        return (select coalesce(jsonb_agg(x), '[]') from (
            select jsonb_build_object('proveedor', proveedor, 'facturas', count(*), 'debe_usd', round(sum(saldo_pendiente), 2),
                                      'vencido_usd', round(sum(saldo_pendiente) filter (where fecha_vencimiento < v_hoy), 2), 'proximo_vencimiento', min(fecha_vencimiento) filter (where fecha_vencimiento >= v_hoy)) x
            from compras_proveedores
            where saldo_pendiente > 0.005 and lower(coalesce(estado, '')) not similar to '(pagad|anulad|cancelad)%'
              and (v_q is null or proveedor ilike '%' || v_q || '%')
            group by proveedor order by sum(saldo_pendiente) desc limit v_lim) s);

    elsif p_tipo = 'inventario_valor' then
        if not v_costos then return jsonb_build_object('error', 'Sin permiso para ver costos'); end if;
        return jsonb_build_object(
            'principal_costo_usd', (select round(sum(greatest(stock, 0) * costo), 2) from productos where coalesce(tipo_producto, 'fisico') = 'fisico'),
            'principal_venta_usd', (select round(sum(greatest(stock, 0) * precio), 2) from productos where coalesce(tipo_producto, 'fisico') = 'fisico'),
            'tiendas', (select coalesce(jsonb_agg(jsonb_build_object('tienda', s.nombre, 'costo_usd', c, 'venta_usd', v)), '[]')
                        from (select ss.sucursal_id, round(sum(greatest(ss.stock, 0) * pr.costo), 2) c, round(sum(greatest(ss.stock, 0) * pr.precio), 2) v
                              from sucursal_stock ss join productos pr on pr.codigo = ss.producto_codigo
                              where coalesce(pr.tipo_producto, 'fisico') = 'fisico' group by 1) x join sucursales s on s.id = x.sucursal_id),
            'por_categoria', (select coalesce(jsonb_agg(jsonb_build_object('categoria', coalesce(categoria, 'Sin categoría'), 'costo_usd', c) order by c desc), '[]')
                              from (select categoria, round(sum(greatest(stock, 0) * costo), 2) c from productos group by 1 order by 2 desc limit 15) x));

    elsif p_tipo = 'sin_movimiento' then
        if not refrimar_tiene_permiso(v_uid, 'ver_inventario') then return jsonb_build_object('error', 'Sin permiso'); end if;
        return (select coalesce(jsonb_agg(x), '[]') from (
            select jsonb_build_object('codigo', pr.codigo, 'descripcion', pr.descripcion, 'stock', pr.stock,
                                      'valor_costo_usd', case when v_costos then round(pr.stock * pr.costo, 2) end,
                                      'ultima_venta', (select max(v.created_at) from detalle_venta d join ventas v on v.id = d.venta_id where d.producto_codigo = pr.codigo and v.estado = 'completada')) x
            from productos pr
            where pr.stock > 0 and coalesce(pr.tipo_producto, 'fisico') = 'fisico' and pr.activo is not false
              and not exists (select 1 from detalle_venta d join ventas v on v.id = d.venta_id
                              where d.producto_codigo = pr.codigo and v.estado = 'completada'
                                and v.created_at >= now() - make_interval(days => least(greatest(coalesce(nullif(p->>'dias', '')::int, 90), 7), 730)))
            order by pr.stock * pr.costo desc limit v_lim) s);

    elsif p_tipo = 'gastos_resumen' then
        if not refrimar_tiene_permiso(v_uid, 'ver_finanzas') then return jsonb_build_object('error', 'Sin permiso para ver finanzas'); end if;
        return jsonb_build_object('desde', v_desde, 'hasta', v_hasta, 'total_usd', (select round(sum(monto_usd), 2) from gastos where fecha between v_desde and v_hasta),
            'por_categoria', (select coalesce(jsonb_object_agg(coalesce(categoria, 'Otros'), t), '{}')
                              from (select categoria, round(sum(monto_usd), 2) t from gastos where fecha between v_desde and v_hasta group by 1) x));
    end if;
    return jsonb_build_object('error', 'Consulta desconocida: ' || coalesce(p_tipo, ''));
end;
$$;
revoke execute on function public.consulta_datos(text, jsonb) from public, anon;
grant execute on function public.consulta_datos(text, jsonb) to anon, authenticated;

-- ============================================================
-- 6. Alertas (mismas de la etapa 3 + despachos atrasados y garantías estancadas)
-- ============================================================
create or replace function public.refrimar_alertas(p_uid uuid)
returns jsonb language plpgsql stable security definer set search_path = public as
$$
declare
    CASA constant uuid := '00000000-0000-0000-0000-000000000001';
    v_hoy date := (now() at time zone 'America/Caracas')::date;
    v_inv boolean := p_uid is null or refrimar_tiene_permiso(p_uid, 'ver_inventario');
    v_costos boolean := p_uid is null or refrimar_tiene_permiso(p_uid, 'ver_costos');
    v_cxc boolean := p_uid is null or refrimar_tiene_permiso(p_uid, 'ver_cxc');
    v_cxp boolean := p_uid is null or refrimar_tiene_permiso(p_uid, 'ver_cxp') or refrimar_tiene_permiso(p_uid, 'compras');
    v_cot boolean := p_uid is null or refrimar_tiene_permiso(p_uid, 'cotizar');
    v_caja boolean := p_uid is null or refrimar_tiene_permiso(p_uid, 'caja_admin');
    v_fact boolean := p_uid is null or refrimar_tiene_permiso(p_uid, 'facturar');
    v_fin boolean := p_uid is null or refrimar_tiene_permiso(p_uid, 'ver_finanzas');
    v_incl boolean := coalesce((select bool_or(coalesce(iva_incluido, false) or coalesce((opciones->>'iva_incluido')::boolean, false)) from configuracion), false);
    a jsonb := '[]'::jsonb;
    n int; m numeric; t text; v_d date;
begin
    if v_inv then
        -- Agotados que sí se venden (vendidos en los últimos 30 días en esa tienda)
        select count(*), string_agg(descripcion, ', ' order by vendido desc) filter (where rn <= 4) into n, t
        from (select p.descripcion, v.vendido, row_number() over (order by v.vendido desc) rn
              from (select coalesce(ve.sucursal_id, CASA) suc, d.producto_codigo cod, sum(d.cantidad) vendido
                    from detalle_venta d join ventas ve on ve.id = d.venta_id
                    where ve.estado = 'completada' and ve.created_at >= now() - interval '30 days'
                    group by 1, 2) v
              join productos p on p.codigo = v.cod
              where coalesce(p.tipo_producto, 'fisico') = 'fisico' and p.activo is not false and not coalesce(p.es_kit, false)
                and stock_en(v.cod, v.suc) <= 0) q;
        if n > 0 then a := a || jsonb_build_object('clave', 'agotados', 'nivel', 'alta', 'cantidad', n, 'href', 'inventario.html',
            'titulo', n || case when n = 1 then ' producto agotado que se vende' else ' productos agotados que se venden' end,
            'detalle', t || case when n > 4 then '…' else '' end); end if;

        -- Por debajo del mínimo (solo los que se vendieron en los últimos 60 días)
        select count(*), string_agg(descripcion, ', ') filter (where rn <= 4) into n, t
        from (select p.descripcion, row_number() over (order by p.descripcion) rn
              from (select distinct coalesce(ve.sucursal_id, CASA) suc, d.producto_codigo cod
                    from detalle_venta d join ventas ve on ve.id = d.venta_id
                    where ve.estado = 'completada' and ve.created_at >= now() - interval '60 days') v
              join productos p on p.codigo = v.cod
              where coalesce(p.tipo_producto, 'fisico') = 'fisico' and p.activo is not false and not coalesce(p.es_kit, false)
                and coalesce(p.stock_minimo, 0) > 0
                and stock_en(v.cod, v.suc) > 0 and stock_en(v.cod, v.suc) <= p.stock_minimo) q;
        if n > 0 then a := a || jsonb_build_object('clave', 'minimo', 'nivel', 'media', 'cantidad', n, 'href', 'oc-form.html',
            'titulo', n || case when n = 1 then ' producto por debajo del mínimo' else ' productos por debajo del mínimo' end,
            'detalle', t || case when n > 4 then '…' else '' end || ' · Haz el pedido'); end if;

        select (select count(*) from productos where stock < 0 and coalesce(tipo_producto, 'fisico') = 'fisico')
             + (select count(*) from sucursal_stock ss left join productos p on p.codigo = ss.producto_codigo
                where ss.stock < 0 and coalesce(p.tipo_producto, 'fisico') = 'fisico') into n;
        if n > 0 then a := a || jsonb_build_object('clave', 'negativo', 'nivel', 'media', 'cantidad', n, 'href', 'riesgos.html#negativo',
            'titulo', n || ' con existencia negativa', 'detalle', 'Se vendió más de lo que había en el sistema: cuéntalos'); end if;

        select count(*) into n from productos
        where activo is not false and coalesce(precio, 0) <= 0 and coalesce(tipo_producto, 'fisico') = 'fisico'
          and (stock > 0 or exists (select 1 from sucursal_stock ss where ss.producto_codigo = productos.codigo and ss.stock > 0));
        if n > 0 then a := a || jsonb_build_object('clave', 'sin_precio', 'nivel', 'media', 'cantidad', n, 'href', 'riesgos.html#sin_precio',
            'titulo', n || case when n = 1 then ' producto sin precio' else ' productos sin precio' end, 'detalle', 'Tienen existencia pero no se pueden vender'); end if;

        select count(*), coalesce(sum(costo_total), 0) into n, m from kardex_movimientos
        where tipo = 'devolucion_danada' and fecha >= v_hoy - 7;
        if n > 0 then a := a || jsonb_build_object('clave', 'danados', 'nivel', 'baja', 'cantidad', n, 'href', 'kardex.html',
            'titulo', 'Mercancía dañada devuelta (7 días)',
            'detalle', n || ' devolución(es)' || case when v_costos then ' · costo ' || refrimar_fmt(m) || ' $' else '' end || ' · Reclama al proveedor'); end if;
    end if;

    if v_costos then
        select count(*) into n from productos
        where activo is not false and precio > 0 and costo > 0
          and (case when v_incl then precio / (1 + coalesce(iva_tasa, 16) / 100) else precio end) < costo;
        if n > 0 then a := a || jsonb_build_object('clave', 'perdida', 'nivel', 'alta', 'cantidad', n, 'href', 'riesgos.html#perdida',
            'titulo', n || case when n = 1 then ' producto se vende a pérdida' else ' productos se venden a pérdida' end, 'detalle', 'El precio es menor que el costo'); end if;
    end if;

    if v_cxc then
        select count(*), coalesce(sum(coalesce(total_usd, 0) - coalesce(monto_abonado, 0)), 0) into n, m from ventas
        where metodo_pago = 'credito' and estado = 'completada' and coalesce(total_usd, 0) - coalesce(monto_abonado, 0) > 0.005
          and (created_at at time zone 'America/Caracas')::date + coalesce(dias_credito, 30) < v_hoy;
        if n > 0 then a := a || jsonb_build_object('clave', 'cxc_vencidas', 'nivel', 'alta', 'cantidad', n, 'monto', round(m, 2), 'href', 'cuentas_por_cobrar.html',
            'titulo', n || case when n = 1 then ' deuda de cliente vencida' else ' deudas de clientes vencidas' end, 'detalle', 'Por cobrar: ' || refrimar_fmt(m) || ' $'); end if;
    end if;

    if v_cxp then
        select count(*), coalesce(sum(saldo_pendiente), 0), min(fecha_vencimiento) into n, m, v_d from compras_proveedores
        where saldo_pendiente > 0.005 and fecha_vencimiento is not null and fecha_vencimiento <= v_hoy + 3
          and lower(coalesce(estado, '')) not similar to '(pagad|anulad|cancelad)%';
        if n > 0 then a := a || jsonb_build_object('clave', 'cxp', 'nivel', case when v_d < v_hoy then 'alta' else 'media' end, 'cantidad', n, 'monto', round(m, 2), 'href', 'cuentas_por_pagar.html',
            'titulo', n || case when n = 1 then ' factura de proveedor por pagar' else ' facturas de proveedor por pagar' end,
            'detalle', refrimar_fmt(m) || ' $ · ' || case when v_d < v_hoy then 'hay vencidas' else 'vencen en 3 días o menos' end); end if;

        select count(*) into n from compras_proveedores
        where jsonb_array_length(coalesce(diferencias, '[]'::jsonb)) > 0 and not coalesce(diferencias_revisadas, false) and fecha_emision >= v_hoy - 120;
        if n > 0 then a := a || jsonb_build_object('clave', 'diferencias', 'nivel', 'media', 'cantidad', n, 'href', 'riesgos.html#diferencia',
            'titulo', n || case when n = 1 then ' factura no coincide con su orden' else ' facturas no coinciden con su orden' end, 'detalle', 'Revisa precios y cantidades con el proveedor'); end if;
    end if;

    if v_cot then
        select count(*) into n from cotizaciones
        where estado = 'pendiente' and created_at + make_interval(days => coalesce(validez_dias, 7)) between now() and now() + interval '2 days';
        if n > 0 then a := a || jsonb_build_object('clave', 'cotizaciones', 'nivel', 'baja', 'cantidad', n, 'href', 'cotizaciones.html',
            'titulo', n || case when n = 1 then ' cotización vence pronto' else ' cotizaciones vencen pronto' end, 'detalle', 'Llama al cliente antes de que venzan'); end if;
    end if;

    if v_caja then
        select count(*), coalesce(sum(diferencia_usd), 0), string_agg(usuario_nombre || ' ' || refrimar_fmt(diferencia_usd) || ' $', ', ') into n, m, t from turnos
        where estado <> 'activo' and cerrado_at >= now() - interval '2 days' and abs(coalesce(diferencia_usd, 0)) >= 1;
        if n > 0 then a := a || jsonb_build_object('clave', 'caja', 'nivel', 'alta', 'cantidad', n, 'monto', round(m, 2), 'href', 'turnos.html',
            'titulo', n || case when n = 1 then ' cierre de caja con diferencia' else ' cierres de caja con diferencia' end, 'detalle', t); end if;
    end if;

    if v_fact then
        select (max(created_at) at time zone 'America/Caracas')::date into v_d from tasas_historial;
        n := case when extract(isodow from v_hoy) = 1 then 3 else 1 end;   -- el lunes cuenta desde el viernes
        if v_d is not null and extract(isodow from v_hoy) between 1 and 5 and v_d < v_hoy - n then
            a := a || jsonb_build_object('clave', 'tasa', 'nivel', 'media', 'cantidad', 1, 'href', 'monedas.html',
                'titulo', 'La tasa no se actualiza desde el ' || to_char(v_d, 'DD/MM'), 'detalle', 'Revisa la tasa del BCV antes de facturar');
        end if;
    end if;

    -- Etapa 4b: despachos atrasados y garantías estancadas
    if v_fact and to_regclass('public.despachos') is not null then
        select count(*), string_agg(numero || ' ' || coalesce(cliente_nombre, ''), ', ') filter (where true) into n, t
        from (select numero, cliente_nombre from despachos
              where estado in ('pendiente', 'en_ruta', 'parcial') and fecha_programada is not null and fecha_programada < v_hoy
              order by fecha_programada limit 50) q;
        if n > 0 then a := a || jsonb_build_object('clave', 'despachos', 'nivel', 'alta', 'cantidad', n, 'href', 'despachos.html',
            'titulo', n || case when n = 1 then ' despacho atrasado' else ' despachos atrasados' end, 'detalle', left(t, 160)); end if;
    end if;
    if v_fact and to_regclass('public.garantias') is not null then
        select count(*) into n from garantias where estado in ('recibida', 'en_proveedor') and created_at < now() - interval '15 days';
        if n > 0 then a := a || jsonb_build_object('clave', 'garantias', 'nivel', 'media', 'cantidad', n, 'href', 'garantias.html',
            'titulo', n || case when n = 1 then ' garantía lleva más de 15 días' else ' garantías llevan más de 15 días' end, 'detalle', 'El cliente está esperando: llama al proveedor'); end if;
    end if;

    return a;
end;
$$;
revoke execute on function public.refrimar_alertas(uuid) from public, anon, authenticated;

-- ============================================================
-- Seguridad y registro
-- ============================================================
insert into public.seguridad_rpc (nombre, nivel, permiso, gracia_dias)
select v.* from (values ('garantia_registrar', 'sesion', null, 0), ('garantia_estado', 'sesion', null, 0),
                        ('despacho_crear', 'sesion', null, 0), ('despacho_entregar', 'sesion', null, 0), ('despacho_estado', 'sesion', null, 0),
                        ('conciliacion_pagos', 'sesion', null, 0), ('consulta_datos', 'sesion', null, 0)) as v(nombre, nivel, permiso, gracia)
where not exists (select 1 from public.seguridad_rpc s where s.nombre = v.nombre);

insert into public.migraciones_aplicadas (nombre, descripcion, version_app)
values ('2026-11-17-etapa4b-garantias-despachos-banco', 'Garantías, despachos, conciliación bancaria y consultas del asistente', 'v3.9.27')
on conflict (nombre) do nothing;
notify pgrst, 'reload schema';

select 'Listo' as resultado;
