-- ═══════════════════════════════════════════════════════════════════
-- REFRIMAR OS — Tabla: cuentas_por_pagar (facturas por pagar)
-- Ejecutar en el SQL Editor de Supabase (https://supabase.com → SQL Editor)
-- ═══════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS public.cuentas_por_pagar (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  orden_compra_id uuid NULL,                    -- vínculo opcional con ordenes_compra.id
  sucursal_id uuid NULL,                        -- Casa Matriz usa el sentinel 00000000-...-0001
  sucursal_nombre text NULL,
  proveedor_id uuid NULL,
  proveedor_nombre text NULL,
  numero_factura text NULL,                     -- nº de factura del proveedor
  fecha date NULL,                              -- fecha de la factura/compra
  fecha_vencimiento date NULL,
  monto numeric(14,2) NOT NULL DEFAULT 0,       -- total de la factura
  saldo numeric(14,2) NOT NULL DEFAULT 0,       -- pendiente por pagar
  estado text NOT NULL DEFAULT 'pendiente',     -- 'pendiente' | 'parcial' | 'pagada'
  notas text NULL,
  creado_en timestamptz NOT NULL DEFAULT now(),
  pagina_uuid uuid NULL                         -- reservado para agrupar la página (no obligatorio)
);

-- Índices de consulta rápida
CREATE INDEX IF NOT EXISTS idx_cxp_sucursal ON public.cuentas_por_pagar (sucursal_id);
CREATE INDEX IF NOT EXISTS idx_cxp_estado ON public.cuentas_por_pagar (estado);
CREATE INDEX IF NOT EXISTS idx_cxp_vencimiento ON public.cuentas_por_pagar (fecha_vencimiento);
CREATE INDEX IF NOT EXISTS idx_cxp_proveedor ON public.cuentas_por_pagar (proveedor_id);

-- RLS: habilitado con mismo criterio que el resto del sistema
ALTER TABLE public.cuentas_por_pagar ENABLE ROW LEVEL SECURITY;

-- Política de lectura: cualquier usuario anónimo (manejado por el worker/servicio)
DROP POLICY IF EXISTS "cxp_select_anon" ON public.cuentas_por_pagar;
CREATE POLICY "cxp_select_anon" ON public.cuentas_por_pagar
  FOR SELECT USING (true);

DROP POLICY IF EXISTS "cxp_insert_anon" ON public.cuentas_por_pagar;
CREATE POLICY "cxp_insert_anon" ON public.cuentas_por_pagar
  FOR INSERT WITH CHECK (true);

DROP POLICY IF EXISTS "cxp_update_anon" ON public.cuentas_por_pagar;
CREATE POLICY "cxp_update_anon" ON public.cuentas_por_pagar
  FOR UPDATE USING (true);

DROP POLICY IF EXISTS "cxp_delete_anon" ON public.cuentas_por_pagar;
CREATE POLICY "cxp_delete_anon" ON public.cuentas_por_pagar
  FOR DELETE USING (true);
