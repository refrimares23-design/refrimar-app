-- ============================================================
-- REFRIMAR — SEGURIDAD DE SESIÓN Y PERMISOS EN EL SERVIDOR
-- ------------------------------------------------------------
-- Pega TODO en Supabase → SQL Editor → New query → Run.
-- Se puede correr varias veces sin dañar nada.
--
-- Qué arregla:
--   1. El PIN (cifrado) de los colaboradores ya NO se puede leer
--      desde internet con la clave pública.
--   2. Login con PIN con límite de intentos (5 fallos → espera).
--   3. Token de sesión: cada colaborador que entra recibe un token.
--      La base de datos revisa ese token y el permiso de su rol
--      ANTES de dejar facturar, ajustar inventario, cambiar precios, etc.
--   4. Modo "aviso" (por defecto): no bloquea nada todavía, solo anota
--      en una bitácora lo que se habría bloqueado. Cuando en
--      Configuración → Estado del sistema ya no salgan avisos, pásalo a
--      "estricto" (desde esa misma página o con:
--         select seguridad_modo('estricto');  -- como dueño, ver abajo)
--
-- BOTÓN DE EMERGENCIA (si algo deja de funcionar):
--   alter role authenticator reset pgrst.db_pre_request;
--   notify pgrst, 'reload config';
-- ============================================================

-- ---------- 1. Tablas ----------
create table if not exists seguridad_config (
    id int primary key default 1 check (id = 1),
    modo text not null default 'aviso' check (modo in ('aviso', 'estricto')),
    servicio_token_hash text,           -- hash del token del Worker (cron / bot)
    actualizado_at timestamptz not null default now()
);
insert into seguridad_config (id) values (1) on conflict (id) do nothing;

create table if not exists sesiones (
    token_hash text primary key,
    usuario_id uuid not null,
    rol text,
    metodo text,
    dispositivo text,
    creada_at timestamptz not null default now(),
    expira_at timestamptz not null,
    ultimo_uso_at timestamptz not null default now(),
    revocada boolean not null default false
);
create index if not exists idx_sesiones_usuario on sesiones(usuario_id);
create index if not exists idx_sesiones_expira on sesiones(expira_at);

create table if not exists login_intentos (
    clave text primary key,
    fallos int not null default 0,
    bloqueado_hasta timestamptz,
    actualizado_at timestamptz not null default now()
);

create table if not exists seguridad_eventos (
    id bigserial primary key,
    fecha timestamptz not null default now(),
    ruta text,
    metodo text,
    motivo text,
    usuario_id uuid,
    usuario_nombre text
);
create index if not exists idx_seg_eventos_fecha on seguridad_eventos(fecha desc);
create index if not exists idx_seg_eventos_ruta on seguridad_eventos(ruta, fecha desc);

-- Qué pide cada función: publico | servicio | compat | permiso (+ permiso interno)
create table if not exists seguridad_rpc (
    nombre text primary key,
    nivel text not null check (nivel in ('publico', 'servicio', 'compat', 'sesion', 'permiso')),
    permiso text,
    gracia_dias int not null default 0      -- ventas sin internet: el token vencido se acepta N días
);

-- Qué claves del árbol de permisos (pantalla Gestión de equipo) dan cada permiso interno
create table if not exists permisos_mapa (
    interno text not null,
    clave text not null,
    primary key (interno, clave)
);

-- Nadie las lee ni escribe desde internet: solo las funciones de abajo
alter table seguridad_config enable row level security;
alter table sesiones enable row level security;
alter table login_intentos enable row level security;
alter table seguridad_eventos enable row level security;
alter table seguridad_rpc enable row level security;
alter table permisos_mapa enable row level security;
revoke all on seguridad_config, sesiones, login_intentos, seguridad_eventos, seguridad_rpc, permisos_mapa from anon, authenticated;

insert into permisos_mapa (interno, clave) values
    ('ver_equipo','gestion.ver'),
    ('usuarios','gestion.ver'),
    ('ver_equipo','gestion.invitar'),
    ('invitar_usuario','gestion.invitar'),
    ('ver_equipo','gestion.permisos'),
    ('modificar_permisos','gestion.permisos'),
    ('ver_equipo','gestion.suspender'),
    ('suspender_usuario','gestion.suspender'),
    ('ver_equipo','gestion.cancelar'),
    ('cancelar_invitacion','gestion.cancelar'),
    ('actualizar_tasa','gestion.tasa'),
    ('ver_equipo','gestion.crear'),
    ('invitar_usuario','gestion.crear'),
    ('ver_inventario','productos.ver'),
    ('inventario','productos.ver'),
    ('ver_inventario','productos.gestionar'),
    ('inventario','productos.gestionar'),
    ('editar_inventario','productos.gestionar'),
    ('ver_costos','productos.gestionar'),
    ('ver_inventario','productos.datos'),
    ('inventario','productos.datos'),
    ('editar_inventario','productos.datos'),
    ('ver_inventario','productos.importar'),
    ('inventario','productos.importar'),
    ('importar_productos','productos.importar'),
    ('carga-ia','productos.importar'),
    ('ver_inventario','productos.sucursal'),
    ('inventario','productos.sucursal'),
    ('editar_inventario','productos.sucursal'),
    ('ver_inventario','productos.empaques'),
    ('inventario','productos.empaques'),
    ('editar_inventario','productos.empaques'),
    ('ver_inventario','inventario.ver'),
    ('inventario','inventario.ver'),
    ('ver_inventario','inventario.ajustar'),
    ('inventario','inventario.ajustar'),
    ('editar_inventario','inventario.ajustar'),
    ('ver_costos','inventario.ajustar'),
    ('kardex','inventario.ajustar'),
    ('ver_inventario','inventario.contar'),
    ('inventario','inventario.contar'),
    ('contar_inventario','inventario.contar'),
    ('ver_inventario','inventario.planificar'),
    ('inventario','inventario.planificar'),
    ('contar_inventario','inventario.planificar'),
    ('planificar_conteo','inventario.planificar'),
    ('ver_transferencias','transferencias.ver'),
    ('inventario','transferencias.ver'),
    ('ver_transferencias','transferencias.gestionar'),
    ('inventario','transferencias.gestionar'),
    ('gestionar_transferencias','transferencias.gestionar'),
    ('ver_transferencias','transferencias.modificar'),
    ('inventario','transferencias.modificar'),
    ('gestionar_transferencias','transferencias.modificar'),
    ('ver_transferencias','transferencias.recibir'),
    ('inventario','transferencias.recibir'),
    ('recibir_transferencia','transferencias.recibir'),
    ('ver_transferencias','transferencias.cancelar'),
    ('inventario','transferencias.cancelar'),
    ('cancelar_transferencia','transferencias.cancelar'),
    ('ver_compras','compras.ver'),
    ('compras_mod','compras.ver'),
    ('ver_compras','compras.gestionar'),
    ('compras_mod','compras.gestionar'),
    ('compras','compras.gestionar'),
    ('ver_compras','compras.modificar'),
    ('compras_mod','compras.modificar'),
    ('compras','compras.modificar'),
    ('ver_compras','compras.recibir'),
    ('compras_mod','compras.recibir'),
    ('compras','compras.recibir'),
    ('recibir_compra','compras.recibir'),
    ('ver_compras','compras.cancelar'),
    ('compras_mod','compras.cancelar'),
    ('cancelar_compra','compras.cancelar'),
    ('ver_compras','compras.validar'),
    ('compras_mod','compras.validar'),
    ('validar_compra','compras.validar'),
    ('proveedores','compras.proveedores'),
    ('compras_mod','compras.proveedores'),
    ('facturar','pos.ver'),
    ('facturacion','pos.ver'),
    ('facturar','pos.cajas'),
    ('facturacion','pos.cajas'),
    ('caja_admin','pos.cajas'),
    ('caja','pos.cajas'),
    ('facturar','pos.turnos'),
    ('facturacion','pos.turnos'),
    ('ver_mi_caja','pos.turnos'),
    ('facturar','pos.facturas'),
    ('facturacion','pos.facturas'),
    ('facturar','pos.modificar_facturas'),
    ('facturacion','pos.modificar_facturas'),
    ('devoluciones','pos.modificar_facturas'),
    ('facturar','pos.descargar'),
    ('facturacion','pos.descargar'),
    ('facturar','pos.catalogos_ver'),
    ('facturacion','pos.catalogos_ver'),
    ('facturar','pos.catalogos_gestionar'),
    ('facturacion','pos.catalogos_gestionar'),
    ('gestionar_catalogos','pos.catalogos_gestionar'),
    ('ver_tiendas','tienda.ver'),
    ('sucursales','tienda.ver'),
    ('ver_tiendas','tienda.gestionar'),
    ('sucursales','tienda.gestionar'),
    ('gestionar_sucursales','tienda.gestionar'),
    ('todas_sucursales','tienda.gestionar'),
    ('ver_finanzas','finanzas.ver'),
    ('ver_cxc','finanzas.ver'),
    ('ver_cxp','finanzas.ver'),
    ('cxc','finanzas.ver'),
    ('cxp','finanzas.ver'),
    ('ver_costos','finanzas.ver'),
    ('ver_utilidades','finanzas.ver'),
    ('ver_finanzas','finanzas.gestionar'),
    ('gestionar_finanzas','finanzas.gestionar'),
    ('ver_cxc','finanzas.gestionar'),
    ('ver_cxp','finanzas.gestionar'),
    ('cxc','finanzas.gestionar'),
    ('cxp','finanzas.gestionar'),
    ('caja_admin','finanzas.gestionar'),
    ('caja','finanzas.gestionar'),
    ('gastos','finanzas.gestionar'),
    ('cierre_diario','finanzas.gestionar'),
    ('cierre','finanzas.gestionar'),
    ('ver_costos','finanzas.gestionar'),
    ('ver_utilidades','finanzas.gestionar'),
    ('ver_marketing','marketing.ver'),
    ('ver_marketing','marketing.campana'),
    ('gestionar_campanas','marketing.campana'),
    ('ver_marketing','marketing.editar'),
    ('gestionar_campanas','marketing.editar'),
    ('registrar_clientes','marketing.clientes'),
    ('clientes','marketing.clientes'),
    ('cotizar','marketing.clientes'),
    ('cotizaciones','marketing.clientes'),
    ('ver_analitica','analitica.ver'),
    ('reportes','analitica.ver'),
    ('ver_analitica','analitica.reportes'),
    ('ver_reportes','analitica.reportes'),
    ('reportes','analitica.reportes'),
    ('facturar','app.emitir'),
    ('facturacion','app.emitir'),
    ('app_modificar_productos','app.modificar_productos'),
    ('app_formas_pago','app.formas_pago'),
    ('app_reiniciar','app.reiniciar'),
    ('facturar','app.buscar_facturas'),
    ('devoluciones','app.nota_credito'),
    ('app_reimprimir','app.reimprimir'),
    ('app_fiscalizar','app.fiscalizar'),
    ('facturar','app.buscar_turnos'),
    ('ver_mi_caja','app.cerrar_turnos'),
    ('app_fiscal','app.disp_fiscales'),
    ('app_impresoras','app.impresoras'),
    ('app_reporte_x','app.reporte_x'),
    ('app_reporte_z','app.reporte_z'),
    ('app_descuento','app.descuento'),
    ('app_preferencias','app.preferencias'),
    ('app_cambiar_precio','app.cambiar_precio'),
    ('app_gaveta','app.gaveta'),
    ('app_eliminar','app.eliminar'),
    ('app_pesados','app.pesados'),
    ('actualizar_precios','masivas.precios'),
    ('inventario','masivas.precios'),
    ('ver_fiscal','fiscal.ver'),
    ('ver_fiscal','fiscal.gestionar'),
    ('configuracion','fiscal.gestionar')
on conflict do nothing;

insert into seguridad_rpc (nombre, nivel, permiso, gracia_dias) values
    ('login_usuario','publico',null,0),
    ('sesion_iniciar_pin','publico',null,0),
    ('sesion_iniciar_google','publico',null,0),
    ('sesion_cerrar','publico',null,0),
    ('login_google','publico',null,0),
    ('invitacion_info','publico',null,0),
    ('invitacion_aceptar','publico',null,0),
    ('precios_programados_aplicar','publico',null,0),
    ('sistema_diagnostico','publico',null,0),
    ('terminal_ping','publico',null,0),
    ('deudas_por_avisar','servicio',null,0),
    ('deuda_marcar_avisada','servicio',null,0),
    ('chat_bot_estado_get','servicio',null,0),
    ('chat_bot_estado_escalar','servicio',null,0),
    ('pos_facturar','permiso','facturar',30),
    ('registrar_venta','permiso','facturar',30),
    ('pos_fiscal_registrar','permiso','facturar',30),
    ('pos_borrador_guardar','permiso','facturar',0),
    ('pos_borrador_eliminar','permiso','facturar',0),
    ('turno_abrir','permiso','facturar',0),
    ('turno_cerrar','permiso','facturar',0),
    ('turno_resumen','permiso','facturar',0),
    ('pos_turno_cerrar','permiso','facturar',0),
    ('terminal_registrar','permiso','facturar',0),
    ('terminal_estado','permiso','facturar',0),
    ('anular_venta','permiso','devoluciones',0),
    ('nota_credito_registrar','permiso','devoluciones',0),
    ('pos_nota_credito','permiso','devoluciones',0),
    ('cotizacion_guardar','permiso','cotizar',0),
    ('config_guardar','permiso','configuracion',0),
    ('colaborador_guardar','permiso','modificar_permisos',0),
    ('colaborador_estado','permiso','suspender_usuario',0),
    ('colaborador_pin_restablecer','permiso','modificar_permisos',0),
    ('invitacion_enlace','permiso','invitar_usuario',0),
    ('cliente_guardar','permiso','registrar_clientes',0),
    ('cliente_ficha_guardar','permiso','registrar_clientes',0),
    ('cliente_eliminar','permiso','registrar_clientes',0),
    ('producto_guardar','permiso','editar_inventario',0),
    ('producto_ficha_guardar','permiso','editar_inventario',0),
    ('producto_extra_guardar','permiso','editar_inventario',0),
    ('producto_imagenes_guardar','permiso','editar_inventario',0),
    ('producto_stock_maximo','permiso','editar_inventario',0),
    ('sucursal_stock_set_costo','permiso','editar_inventario',0),
    ('kardex_ajuste','permiso','editar_inventario',0),
    ('sucursal_movimiento_registrar','permiso','editar_inventario',0),
    ('sucursal_movimiento_eliminar','permiso','editar_inventario',0),
    ('productos_importar','permiso','importar_productos',0),
    ('productos_importar_ficha','permiso','importar_productos',0),
    ('productos_importar_extra','permiso','importar_productos',0),
    ('importacion_registrar','permiso','importar_productos',0),
    ('precios_actualizar','permiso','actualizar_precios',0),
    ('precios_revertir','permiso','actualizar_precios',0),
    ('precios_actualizacion_crear','permiso','actualizar_precios',0),
    ('precio_programada_cancelar','permiso','actualizar_precios',0),
    ('compra_registrar','permiso','compras',0),
    ('compra_proveedor_guardar','permiso','compras',0),
    ('oc_guardar','permiso','compras',0),
    ('oc_extra_guardar','permiso','compras',0),
    ('oc_estado','permiso','compras',0),
    ('oc_recibir','permiso','compras',0),
    ('aplicar_abono_cxp','permiso','cxp',0),
    ('gasto_registrar','permiso','gastos',0),
    ('gasto_eliminar','permiso','gastos',0),
    ('cuenta_guardar','permiso','gestionar_finanzas',0),
    ('cuenta_movimiento','permiso','gestionar_finanzas',0),
    ('cuenta_transferir','permiso','gestionar_finanzas',0),
    ('cierre_diario_guardar','permiso','cierre_diario',0),
    ('cierre_diario_eliminar','permiso','cierre_diario',0),
    ('cierre_diario_importar','permiso','cierre_diario',0),
    ('conteo_crear_lista','permiso','planificar_conteo',0),
    ('conteo_guardar','permiso','contar_inventario',0),
    ('conteo_estado','permiso','contar_inventario',0),
    ('conteo_cerrar','permiso','contar_inventario',0),
    ('transferencia_guardar','permiso','ver_transferencias',0),
    ('transferencia_cancelar','permiso','cancelar_transferencia',0),
    ('transferir_stock_sucursal','permiso','ver_transferencias',0),
    ('revertir_traspaso_sucursal','permiso','ver_transferencias',0),
    ('sucursal_guardar','permiso','gestionar_sucursales',0)
on conflict (nombre) do update set nivel = excluded.nivel, permiso = excluded.permiso, gracia_dias = excluded.gracia_dias;
-- login_usuario (el login viejo, sin límite de intentos) se apaga en modo estricto
update seguridad_rpc set nivel = 'compat' where nombre = 'login_usuario';
-- Las funciones nuevas de esta migración
insert into seguridad_rpc (nombre, nivel, permiso) values
    ('sesion_validar', 'publico', null),
    ('seguridad_estado', 'sesion', null),
    ('seguridad_modo', 'sesion', null),
    ('sesiones_revocar_usuario', 'permiso', 'suspender_usuario')
on conflict (nombre) do nothing;

-- ---------- 2. El PIN no se puede leer desde internet ----------
-- Se quita el permiso de leer la tabla completa y se da columna por columna, menos "pin".
do $$
declare v_cols text;
begin
    select string_agg(quote_ident(column_name), ', ' order by ordinal_position) into v_cols
    from information_schema.columns
    where table_schema = 'public' and table_name = 'usuarios' and column_name <> 'pin';
    execute 'revoke select on public.usuarios from anon, authenticated';
    execute format('grant select (%s) on public.usuarios to anon, authenticated', v_cols);
end $$;

-- ---------- 3. Funciones de apoyo ----------
create or replace function refrimar_hash(p text)
returns text language sql immutable as $$
    select encode(sha256(convert_to(coalesce(p, ''), 'UTF8')), 'hex')
$$;

create or replace function refrimar_header(p text)
returns text language plpgsql stable as $$
begin
    return nullif(coalesce(nullif(current_setting('request.headers', true), ''), '{}')::json ->> p, '');
exception when others then return null;
end;
$$;

-- Usuario dueño del token que vino en la petición (o null)
create or replace function refrimar_sesion_uid(p_gracia_dias int default 0)
returns uuid
language plpgsql stable security definer
set search_path = public
as $$
declare v_tok text := refrimar_header('x-refrimar-sesion'); v_uid uuid;
begin
    if v_tok is null then return null; end if;
    select s.usuario_id into v_uid from sesiones s
    where s.token_hash = refrimar_hash(v_tok) and not s.revocada
      and s.expira_at + make_interval(days => greatest(coalesce(p_gracia_dias, 0), 0)) > now();
    return v_uid;
end;
$$;

create or replace function refrimar_modo()
returns text language sql stable security definer set search_path = public as $$
    select coalesce((select modo from seguridad_config where id = 1), 'aviso')
$$;

-- ¿El colaborador tiene ese permiso interno? (dueño = todo)
create or replace function refrimar_tiene_permiso(p_uid uuid, p_permiso text)
returns boolean
language plpgsql stable security definer
set search_path = public
as $$
declare u record; v_lista jsonb;
begin
    select * into u from usuarios where id = p_uid;
    if not found or u.activo is false then return false; end if;
    if u.rol = 'admin' then return true; end if;
    if p_permiso is null then return true; end if;
    v_lista := coalesce(to_jsonb(u.permisos), '[]'::jsonb);
    if jsonb_typeof(v_lista) <> 'array' then v_lista := '[]'::jsonb; end if;
    -- Permisos viejos (antes de "Gestión de equipo"): lista fija del empleado
    if not (v_lista ? 'v2') and v_lista = '[]'::jsonb then
        return p_permiso = any (array['facturar', 'ver_mi_caja', 'registrar_clientes', 'ver_inventario', 'cotizar', 'ver_dashboard']);
    end if;
    if v_lista ? p_permiso then return true; end if;
    return exists (select 1 from permisos_mapa m where m.interno = p_permiso and v_lista ? m.clave);
end;
$$;

create or replace function refrimar_es_admin(p_uid uuid)
returns boolean language sql stable security definer set search_path = public as $$
    select exists (select 1 from usuarios where id = p_uid and rol = 'admin' and activo is not false)
$$;

create or replace function refrimar_evento(p_ruta text, p_metodo text, p_motivo text, p_uid uuid)
returns void
language plpgsql security definer
set search_path = public
as $$
begin
    -- Máximo un aviso por ruta y motivo cada 5 minutos (para no llenar la tabla)
    if exists (select 1 from seguridad_eventos where ruta = p_ruta and motivo = p_motivo and fecha > now() - interval '5 minutes') then return; end if;
    insert into seguridad_eventos (ruta, metodo, motivo, usuario_id, usuario_nombre)
    values (left(p_ruta, 200), p_metodo, left(p_motivo, 200), p_uid, (select nombre from usuarios where id = p_uid));
exception when others then null;   -- en lecturas (solo lectura) no se puede escribir: se ignora
end;
$$;

-- ---------- 4. Revisión ANTES de cada petición (PostgREST db_pre_request) ----------
create or replace function refrimar_pre_request()
returns void
language plpgsql security definer
set search_path = public
as $$
declare
    v_path text := coalesce(current_setting('request.path', true), '');
    v_met text := upper(coalesce(current_setting('request.method', true), 'GET'));
    v_rpc text; v_tabla text; v_nivel text; v_perm text; v_gracia int := 0;
    v_uid uuid; v_motivo text; v_modo text;
begin
    if v_path like '/rpc/%' then
        v_rpc := lower(split_part(substr(v_path, 6), '?', 1));
        select nivel, permiso, gracia_dias into v_nivel, v_perm, v_gracia from seguridad_rpc where nombre = v_rpc;
        if v_nivel = 'publico' then return; end if;
        if v_nivel = 'compat' then
            if refrimar_modo() = 'estricto' then
                raise exception using errcode = 'PT403', message = 'Actualiza la página: el acceso cambió por seguridad.';
            end if;
            return;
        end if;
        if v_nivel = 'servicio' then
            if exists (select 1 from seguridad_config where id = 1 and (servicio_token_hash is null or servicio_token_hash = refrimar_hash(refrimar_header('x-refrimar-servicio')))) then return; end if;
        end if;
    else
        v_tabla := lower(split_part(ltrim(v_path, '/'), '?', 1));
        -- Lecturas que necesita la página ANTES de entrar (login, tienda, bot de WhatsApp)
        if v_met in ('GET', 'HEAD') and v_tabla in ('sucursales', 'usuarios', 'configuracion', 'productos', 'producto_imagenes', 'sucursal_stock', 'tasas_historial') then return; end if;
        if v_tabla = '' then return; end if;   -- esquema OpenAPI
    end if;

    v_uid := refrimar_sesion_uid(coalesce(v_gracia, 0));
    if v_uid is null then
        v_motivo := 'sin_sesion';
    elsif v_perm is not null and not refrimar_tiene_permiso(v_uid, v_perm) then
        v_motivo := 'sin_permiso:' || v_perm;
    elsif not exists (select 1 from usuarios where id = v_uid and activo is not false) then
        v_motivo := 'usuario_inactivo';
    end if;
    if v_motivo is null then return; end if;

    perform refrimar_evento(v_path, v_met, v_motivo, v_uid);
    v_modo := refrimar_modo();
    if v_modo = 'estricto' then
        if v_motivo = 'sin_sesion' then
            raise exception using errcode = 'PT401', message = 'Tu sesión venció. Vuelve a entrar.';
        end if;
        raise exception using errcode = 'PT403', message = 'Tu usuario no tiene permiso para esta operación.';
    end if;
exception
    when others then
        if SQLSTATE in ('PT401', 'PT403') then raise; end if;
        return;   -- cualquier falla inesperada aquí NO tumba el sistema
end;
$$;

-- Activar la revisión en PostgREST
alter role authenticator set pgrst.db_pre_request = 'public.refrimar_pre_request';
notify pgrst, 'reload config';

-- ---------- 5. Entrar / salir ----------
create or replace function refrimar_crear_sesion(p_uid uuid, p_metodo text, p_dispositivo text)
returns text
language plpgsql security definer
set search_path = public
as $$
declare v_tok text := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
begin
    insert into sesiones (token_hash, usuario_id, rol, metodo, dispositivo, expira_at)
    values (refrimar_hash(v_tok), p_uid, (select rol from usuarios where id = p_uid), p_metodo, left(coalesce(p_dispositivo, 'web'), 40),
            now() + case when coalesce(p_dispositivo, '') = 'pos' then interval '7 days' else interval '24 hours' end);
    -- Limpieza de sesiones viejas
    delete from sesiones where expira_at < now() - interval '45 days';
    return v_tok;
end;
$$;

create or replace function sesion_iniciar_pin(p_nombre text, p_pin text, p_dispositivo text default 'web')
returns jsonb
language plpgsql security definer
set search_path = public
as $$
declare
    v_clave text := 'pin:' || lower(trim(coalesce(p_nombre, '')));
    li login_intentos; u record; v_tok text;
begin
    select * into li from login_intentos where clave = v_clave;
    if found and li.bloqueado_hasta is not null and li.bloqueado_hasta > now() then
        return jsonb_build_object('success', false, 'bloqueado', true,
            'error', 'Demasiados intentos. Espera ' || greatest(1, ceil(extract(epoch from (li.bloqueado_hasta - now())) / 60))::int || ' min y vuelve a intentar.');
    end if;

    select * into u from usuarios where nombre = p_nombre and activo = true limit 1;
    if not found or u.pin is null or u.pin <> coalesce(p_pin, '') then
        insert into login_intentos (clave, fallos, actualizado_at) values (v_clave, 1, now())
        on conflict (clave) do update set
            fallos = case when login_intentos.actualizado_at < now() - interval '30 minutes' then 1 else login_intentos.fallos + 1 end,
            actualizado_at = now()
        returning * into li;
        if li.fallos >= 5 and li.fallos % 5 = 0 then
            update login_intentos set bloqueado_hasta = now() + case when li.fallos >= 10 then interval '15 minutes' else interval '2 minutes' end
            where clave = v_clave;
        end if;
        return jsonb_build_object('success', false, 'error', 'PIN incorrecto');
    end if;

    delete from login_intentos where clave = v_clave;
    v_tok := refrimar_crear_sesion(u.id, 'pin', p_dispositivo);
    return jsonb_build_object('success', true, 'token', v_tok, 'id', u.id, 'nombre', u.nombre, 'rol', u.rol,
        'permisos', coalesce(to_jsonb(u.permisos), '[]'::jsonb), 'sucursal_id', u.sucursal_id,
        'sucursales', coalesce(to_jsonb(u.sucursales), '[]'::jsonb), 'email', u.email, 'avatar_url', u.avatar_url);
end;
$$;

-- Google: usa login_google() (ya existe) y le agrega el token
create or replace function sesion_iniciar_google(p_dispositivo text default 'web')
returns jsonb
language plpgsql security definer
set search_path = public
as $$
declare r jsonb;
begin
    r := login_google();
    if coalesce((r ->> 'success')::boolean, false) then
        r := r || jsonb_build_object('token', refrimar_crear_sesion((r ->> 'id')::uuid, 'google', p_dispositivo));
        r := r || jsonb_build_object('sucursales', coalesce((select to_jsonb(sucursales) from usuarios where id = (r ->> 'id')::uuid), '[]'::jsonb),
                                     'avatar_url', (select avatar_url from usuarios where id = (r ->> 'id')::uuid));
    end if;
    return r;
end;
$$;

create or replace function sesion_cerrar(p_token text default null)
returns jsonb
language plpgsql security definer
set search_path = public
as $$
begin
    update sesiones set revocada = true
    where token_hash = refrimar_hash(coalesce(nullif(p_token, ''), refrimar_header('x-refrimar-sesion')));
    return jsonb_build_object('ok', true);
end;
$$;

create or replace function sesion_validar()
returns jsonb
language plpgsql stable security definer
set search_path = public
as $$
declare v_uid uuid := refrimar_sesion_uid(0);
begin
    return jsonb_build_object('ok', v_uid is not null, 'usuario_id', v_uid, 'modo', refrimar_modo());
end;
$$;

-- Al inactivar a un colaborador, sus sesiones dejan de servir
create or replace function sesiones_revocar_usuario(p_usuario_id uuid)
returns jsonb
language plpgsql security definer
set search_path = public
as $$
begin
    update sesiones set revocada = true where usuario_id = p_usuario_id and not revocada;
    return jsonb_build_object('ok', true);
end;
$$;

-- ---------- 6. Panel para Estado del sistema ----------
create or replace function seguridad_estado()
returns jsonb
language plpgsql stable security definer
set search_path = public
as $$
declare v_uid uuid := refrimar_sesion_uid(0);
begin
    if v_uid is null or not refrimar_es_admin(v_uid) then
        return jsonb_build_object('ok', false, 'error', 'Solo el dueño puede ver esto (vuelve a entrar si acabas de correr la migración).');
    end if;
    return jsonb_build_object(
        'ok', true,
        'modo', refrimar_modo(),
        'pre_request', coalesce((select (select setting from unnest(r.rolconfig) as setting where setting like 'pgrst.db_pre_request=%' limit 1)
                                 from pg_roles r where r.rolname = 'authenticator'), ''),
        'sesiones_activas', (select count(*) from sesiones where not revocada and expira_at > now()),
        'eventos_7d', (select count(*) from seguridad_eventos where fecha > now() - interval '7 days'),
        'ultimos', coalesce((select jsonb_agg(e order by e.fecha desc) from (
            select fecha, ruta, motivo, usuario_nombre from seguridad_eventos where fecha > now() - interval '7 days' order by fecha desc limit 40) e), '[]'::jsonb)
    );
end;
$$;

create or replace function seguridad_modo(p_modo text)
returns jsonb
language plpgsql security definer
set search_path = public
as $$
declare v_uid uuid := refrimar_sesion_uid(0);
begin
    if v_uid is null or not refrimar_es_admin(v_uid) then raise exception 'Solo el dueño puede cambiar el modo de seguridad'; end if;
    if p_modo not in ('aviso', 'estricto') then raise exception 'Modo inválido'; end if;
    update seguridad_config set modo = p_modo, actualizado_at = now() where id = 1;
    return jsonb_build_object('ok', true, 'modo', p_modo);
end;
$$;

-- Token del Worker (cron, bot): guarda solo el hash. Úsalo así (como dueño, en SQL Editor):
--   select seguridad_token_servicio('UNA-CLAVE-LARGA-ALEATORIA');
-- y en el Worker:  npx wrangler secret put REFRIMAR_SERVICE_TOKEN   (la misma clave)
create or replace function seguridad_token_servicio(p_token text)
returns jsonb
language plpgsql security definer
set search_path = public
as $$
begin
    if length(coalesce(p_token, '')) < 24 then raise exception 'Usa una clave de al menos 24 caracteres'; end if;
    update seguridad_config set servicio_token_hash = refrimar_hash(p_token), actualizado_at = now() where id = 1;
    return jsonb_build_object('ok', true);
end;
$$;
revoke execute on function seguridad_token_servicio(text) from anon, authenticated, public;

-- ---------- 7. Cambios de PIN y perfil: solo el propio colaborador (o el dueño) ----------
create or replace function usuario_cambiar_pin(p_id uuid, p_actual text, p_nuevo text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_pin text; v_uid uuid := refrimar_sesion_uid(0);
begin
    if (v_uid is not null or refrimar_modo() = 'estricto') and coalesce(v_uid = p_id, false) = false and not refrimar_es_admin(v_uid) then
        raise exception 'Solo puedes cambiar tu propio PIN';
    end if;
    if p_nuevo is null or length(p_nuevo) < 32 then raise exception 'PIN nuevo inválido'; end if;
    select pin into v_pin from usuarios where id = p_id;
    if not found then raise exception 'Usuario no encontrado'; end if;
    if v_pin is not null and v_pin <> coalesce(p_actual, '') then raise exception 'El PIN actual no es correcto'; end if;
    update usuarios set pin = p_nuevo where id = p_id;
    return jsonb_build_object('ok', true);
end;
$$;

create or replace function usuario_perfil_guardar(p_id uuid, p_nombres text, p_apellido text, p_telefono text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_nombre text; v_uid uuid := refrimar_sesion_uid(0);
begin
    if (v_uid is not null or refrimar_modo() = 'estricto') and coalesce(v_uid = p_id, false) = false and not refrimar_es_admin(v_uid) then
        raise exception 'Solo puedes editar tu propio perfil';
    end if;
    if nullif(trim(coalesce(p_nombres, '')), '') is null then raise exception 'Escribe tu nombre'; end if;
    v_nombre := trim(trim(p_nombres) || ' ' || coalesce(trim(p_apellido), ''));
    if exists (select 1 from usuarios where lower(nombre) = lower(v_nombre) and id <> p_id) then
        raise exception 'Ya existe un colaborador llamado %', v_nombre;
    end if;
    update usuarios set nombres = trim(p_nombres), apellido = nullif(trim(coalesce(p_apellido, '')), ''),
        nombre = v_nombre, telefono = nullif(trim(coalesce(p_telefono, '')), '')
    where id = p_id;
    if not found then raise exception 'Usuario no encontrado'; end if;
    return jsonb_build_object('ok', true, 'nombre', v_nombre);
end;
$$;

-- ---------- 8. Permisos de ejecución ----------
grant execute on function sesion_iniciar_pin(text, text, text) to anon, authenticated;
grant execute on function sesion_iniciar_google(text) to authenticated;
revoke execute on function sesion_iniciar_google(text) from anon;
grant execute on function sesion_cerrar(text) to anon, authenticated;
grant execute on function sesion_validar() to anon, authenticated;
grant execute on function seguridad_estado() to anon, authenticated;
grant execute on function seguridad_modo(text) to anon, authenticated;
grant execute on function sesiones_revocar_usuario(uuid) to anon, authenticated;
grant execute on function usuario_cambiar_pin(uuid, text, text) to anon, authenticated;
grant execute on function usuario_perfil_guardar(uuid, text, text, text) to anon, authenticated;
-- Funciones internas: no se llaman desde internet
revoke execute on function refrimar_crear_sesion(uuid, text, text) from anon, authenticated, public;
revoke execute on function refrimar_tiene_permiso(uuid, text) from anon, authenticated, public;
revoke execute on function refrimar_evento(text, text, text, uuid) from anon, authenticated, public;
grant execute on function refrimar_pre_request() to anon, authenticated;

-- Listo. Comprueba con:  select sesion_validar();
