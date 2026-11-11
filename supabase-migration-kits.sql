-- ============================================================
-- REFRIMAR — COMBOS / KITS y CANCELAR TRANSFERENCIAS EN TRÁNSITO
-- ------------------------------------------------------------
-- • Un combo (kit) es un producto que al venderse descuenta sus
--   componentes (ej. "Kit baño" = 1 llave + 2 conexiones + 1 teflón).
--   El combo no lleva inventario propio: alcanza para lo que alcancen
--   sus componentes. Si falta un componente, la venta no se hace.
-- • Anulaciones y notas de crédito devuelven los componentes.
-- • Una transferencia en tránsito se puede cancelar: vuelve al origen.
-- Se puede correr varias veces.
-- ============================================================

alter table productos add column if not exists es_kit boolean not null default false;

create table if not exists producto_componentes (
    kit_codigo text not null,
    componente_codigo text not null,
    cantidad numeric not null check (cantidad > 0),
    primary key (kit_codigo, componente_codigo)
);
create index if not exists idx_prod_comp_kit on producto_componentes(kit_codigo);
alter table producto_componentes enable row level security;
drop policy if exists "producto_componentes_select" on producto_componentes;
create policy "producto_componentes_select" on producto_componentes for select using (true);
revoke insert, update, delete on producto_componentes from anon, authenticated;
grant select on producto_componentes to anon, authenticated;

create or replace function kit_guardar(p_kit text, p_componentes jsonb)
returns jsonb
language plpgsql security definer
set search_path = public
as $$
declare c jsonb; v_cod text; v_cant numeric; n int := 0;
begin
    if not exists (select 1 from productos where codigo = p_kit) then raise exception 'Producto % no existe', p_kit; end if;
    delete from producto_componentes where kit_codigo = p_kit;
    for c in select value from jsonb_array_elements(coalesce(p_componentes, '[]'::jsonb)) loop
        v_cod := nullif(trim(coalesce(c->>'codigo', '')), '');
        v_cant := coalesce(nullif(c->>'cantidad', '')::numeric, 0);
        if v_cod is null or v_cant <= 0 then raise exception 'Componente o cantidad inválida'; end if;
        if v_cod = p_kit then raise exception 'Un combo no puede contenerse a sí mismo'; end if;
        if not exists (select 1 from productos where codigo = v_cod) then raise exception 'El componente % no existe', v_cod; end if;
        if exists (select 1 from productos where codigo = v_cod and (es_kit or coalesce(tipo_producto, 'fisico') = 'servicio')) then
            raise exception 'El componente % es un combo o un servicio: usa productos físicos', v_cod;
        end if;
        insert into producto_componentes (kit_codigo, componente_codigo, cantidad) values (p_kit, v_cod, v_cant)
        on conflict (kit_codigo, componente_codigo) do update set cantidad = producto_componentes.cantidad + excluded.cantidad;
        n := n + 1;
    end loop;
    update productos set es_kit = n > 0 where codigo = p_kit;
    -- El combo no lleva inventario propio (como los servicios): siempre "hay"; lo que manda es el stock de los componentes
    if n > 0 then perform servicio_stock_asegurar(p_kit); end if;
    return jsonb_build_object('ok', true, 'componentes', n);
end;
$$;
grant execute on function kit_guardar(text, jsonb) to anon, authenticated;

-- Mueve componentes de un combo en una tienda (signo -1 = vender, +1 = devolver)
create or replace function kit_mover_componentes(p_kit text, p_cantidad numeric, p_sucursal uuid, p_signo int, p_ref text, p_usuario text)
returns void
language plpgsql security definer
set search_path = public
as $$
declare c record; v_q numeric; v_stock numeric; v_suc uuid := case when p_sucursal = '00000000-0000-0000-0000-000000000001' then null else p_sucursal end;
begin
    for c in select pc.componente_codigo, pc.cantidad, p.descripcion, coalesce(p.costo, 0) as costo
             from producto_componentes pc join productos p on p.codigo = pc.componente_codigo where pc.kit_codigo = p_kit loop
        v_q := c.cantidad * p_cantidad;
        if v_suc is null then
            select coalesce(stock, 0) into v_stock from productos where codigo = c.componente_codigo for update;
            if p_signo < 0 and v_stock < v_q then raise exception 'Stock insuficiente de "%" (componente del combo %): disponible %', c.descripcion, p_kit, v_stock; end if;
            update productos set stock = coalesce(stock, 0) + p_signo * v_q where codigo = c.componente_codigo returning stock into v_stock;
        else
            select stock into v_stock from sucursal_stock where sucursal_id = v_suc and producto_codigo = c.componente_codigo for update;
            if p_signo < 0 and coalesce(v_stock, 0) < v_q then raise exception 'Stock insuficiente de "%" (componente del combo %) en la tienda: disponible %', c.descripcion, p_kit, coalesce(v_stock, 0); end if;
            insert into sucursal_stock (sucursal_id, producto_codigo, producto_descripcion, stock) values (v_suc, c.componente_codigo, c.descripcion, p_signo * v_q)
            on conflict (sucursal_id, producto_codigo) do update set stock = sucursal_stock.stock + p_signo * v_q, updated_at = now()
            returning stock into v_stock;
        end if;
        insert into kardex_movimientos (producto_codigo, producto_descripcion, fecha, tipo, cantidad, costo_unitario, costo_total, saldo_cantidad, saldo_costo_promedio, referencia, usuario_nombre, sucursal_id)
        values (c.componente_codigo, c.descripcion, current_date, case when p_signo < 0 then 'salida_venta' else 'entrada_devolucion' end, p_signo * v_q,
                c.costo, v_q * c.costo, v_stock, c.costo, p_ref || ' (combo ' || p_kit || ')', coalesce(p_usuario, 'Sistema'), v_suc);
    end loop;
end;
$$;
revoke execute on function kit_mover_componentes(text, numeric, uuid, int, text, text) from anon, authenticated, public;

-- Venta: descuenta componentes
create or replace function kit_trg_venta()
returns trigger
language plpgsql security definer
set search_path = public
as $$
declare v record;
begin
    if not exists (select 1 from productos where codigo = new.producto_codigo and es_kit) then return new; end if;
    select numero, sucursal_id, usuario_nombre into v from ventas where id = new.venta_id;
    perform kit_mover_componentes(new.producto_codigo, new.cantidad, v.sucursal_id, -1, 'Venta ' || coalesce(v.numero, ''), v.usuario_nombre);
    return new;
end;
$$;
drop trigger if exists trg_kit_venta on detalle_venta;
create trigger trg_kit_venta after insert on detalle_venta for each row execute function kit_trg_venta();

-- Anulación: devuelve componentes
create or replace function kit_trg_anulacion()
returns trigger
language plpgsql security definer
set search_path = public
as $$
declare d record;
begin
    if new.estado = 'anulada' and coalesce(old.estado, '') <> 'anulada' then
        for d in select dv.producto_codigo, dv.cantidad from detalle_venta dv join productos p on p.codigo = dv.producto_codigo and p.es_kit where dv.venta_id = new.id loop
            perform kit_mover_componentes(d.producto_codigo, d.cantidad, new.sucursal_id, 1, 'Anulación ' || coalesce(new.numero, ''), null);
        end loop;
    end if;
    return new;
end;
$$;
drop trigger if exists trg_kit_anulacion on ventas;
create trigger trg_kit_anulacion after update of estado on ventas for each row execute function kit_trg_anulacion();

-- Nota de crédito: devuelve componentes
do $$ begin
    if to_regclass('public.notas_credito_detalle') is not null then
        execute $f$
        create or replace function kit_trg_nc()
        returns trigger
        language plpgsql security definer
        set search_path = public
        as $b$
        declare n record;
        begin
            if not exists (select 1 from productos where codigo = new.producto_codigo and es_kit) then return new; end if;
            select numero, sucursal_id, usuario_nombre into n from notas_credito where id = new.nota_id;
            perform kit_mover_componentes(new.producto_codigo, new.cantidad, n.sucursal_id, 1, 'Nota de crédito ' || coalesce(n.numero, ''), n.usuario_nombre);
            return new;
        end;
        $b$;
        $f$;
        execute 'drop trigger if exists trg_kit_nc on notas_credito_detalle';
        execute 'create trigger trg_kit_nc after insert on notas_credito_detalle for each row execute function kit_trg_nc()';
    end if;
end $$;

-- ---------- Cancelar transferencias (borrador o en tránsito) ----------
create or replace function transferencia_cancelar(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare t record; it record; v_saldo numeric; v_casa uuid := '00000000-0000-0000-0000-000000000001';
begin
    select * into t from transferencias where id = p_id for update;
    if not found then raise exception 'Transferencia no encontrada'; end if;
    if t.estado = 'borrador' then
        update transferencias set estado = 'cancelada' where id = p_id;
        return jsonb_build_object('ok', true);
    end if;
    if t.estado <> 'en_transito' then raise exception 'Solo se cancela una transferencia en borrador o en tránsito'; end if;
    -- En tránsito: la mercancía vuelve a la tienda de origen
    for it in select * from transferencia_items where transferencia_id = p_id loop
        v_saldo := refrimar_mover_stock(it.producto_codigo, t.origen_id, it.cantidad, it.descripcion);
        insert into kardex_movimientos (producto_codigo, producto_descripcion, fecha, tipo, cantidad, costo_unitario, costo_total, saldo_cantidad, saldo_costo_promedio, referencia, usuario_nombre, sucursal_id)
        values (it.producto_codigo, it.descripcion, current_date, 'entrada_traslado', it.cantidad, it.costo_unitario, it.cantidad * it.costo_unitario, v_saldo, it.costo_unitario,
                t.numero || ' cancelada (vuelve a ' || coalesce(t.origen_nombre, 'origen') || ')', 'Sistema', case when t.origen_id = v_casa then null else t.origen_id end);
    end loop;
    update transferencias set estado = 'cancelada' where id = p_id;
    return jsonb_build_object('ok', true, 'devuelto', true);
end;
$$;
grant execute on function transferencia_cancelar(uuid) to anon, authenticated;

do $$ begin
    if to_regclass('public.seguridad_rpc') is not null then
        insert into seguridad_rpc (nombre, nivel, permiso) values ('kit_guardar', 'permiso', 'editar_inventario')
        on conflict (nombre) do update set nivel = excluded.nivel, permiso = excluded.permiso;
    end if;
end $$;

notify pgrst, 'reload schema';
select 'Combos y transferencias listos' as resultado;
