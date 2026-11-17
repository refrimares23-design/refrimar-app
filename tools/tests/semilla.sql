-- Datos de prueba mínimos (inventados). Se cargan en la copia después de la estructura.
insert into seguridad_config (id, modo) values (1, 'estricto') on conflict do nothing;
insert into configuracion (nombre_negocio, iva_incluido) select 'PRUEBA', false where not exists (select 1 from configuracion);
insert into sucursales (id, nombre) values
  ('00000000-0000-0000-0000-000000000001', 'Principal'),
  ('00000000-0000-0000-0000-0000000000a2', 'Sucursal')
on conflict do nothing;
insert into usuarios (id, nombre, pin, rol, permisos) values
  ('00000000-0000-0000-0000-00000000ad01', 'ADMIN PRUEBA', 'x', 'admin', '["v2"]'),
  ('00000000-0000-0000-0000-00000000ca01', 'CAJERA PRUEBA', 'x', 'cajero', '["v2", "facturar", "ver_inventario"]')
on conflict do nothing;
insert into sesiones (token_hash, usuario_id, rol, metodo, expira_at) values
  (refrimar_hash('tok-admin'), '00000000-0000-0000-0000-00000000ad01', 'admin', 'pin', now() + interval '1 day'),
  (refrimar_hash('tok-cajera'), '00000000-0000-0000-0000-00000000ca01', 'cajero', 'pin', now() + interval '1 day');
insert into proveedores (id, nombre, rif) values
  ('00000000-0000-0000-0000-0000000f0001', 'FERCOVEN, C.A.', 'J-12345678-9'),
  ('00000000-0000-0000-0000-0000000f0002', 'MAXCAM', 'J-98765432-1')
on conflict do nothing;
insert into productos (codigo, descripcion, costo, precio, stock, stock_minimo) values
  ('A001', 'PRODUCTO A', 1, 2, 10, 2),
  ('B001', 'PRODUCTO B', 5, 4, 3, 1),
  ('C001', 'PRODUCTO C', 1, 1.5, -2, 1)
on conflict do nothing;
