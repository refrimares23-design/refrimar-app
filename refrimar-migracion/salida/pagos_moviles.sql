-- ═══════════════════════════════════════════════════════════════════
-- REFRIMAR OS — Tabla: pagos_moviles (cobros recibidos por Pago Móvil)
-- Ejecutar en el SQL Editor de Supabase (https://supabase.com → SQL Editor)
-- ═══════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS public.pagos_moviles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  banco text NULL,                              -- banco desde donde pagó el cliente (ej: Banesco)
  monto numeric(14,2) NOT NULL DEFAULT 0,       -- monto del pago recibido
  fecha date NULL,                              -- día en que se hizo el pago
  sucursal_id uuid NULL,                        -- sucursal que recibió el pago (opcional)
  sucursal_nombre text NULL,                    -- Casa Matriz usa 'Casa Matriz'
  referencia text NULL,                         -- nº de referencia/operación (opcional)
  quien_pago text NULL,                         -- nombre de quien hizo el pago (opcional)
  creado_en timestamptz NOT NULL DEFAULT now()
);

-- Índices de consulta rápida
CREATE INDEX IF NOT EXISTS idx_pm_fecha ON public.pagos_moviles (fecha);
CREATE INDEX IF NOT EXISTS idx_pm_banco ON public.pagos_moviles (banco);
CREATE INDEX IF NOT EXISTS idx_pm_sucursal ON public.pagos_moviles (sucursal_id);

-- RLS: habilitado con mismo criterio que el resto del sistema
ALTER TABLE public.pagos_moviles ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "pm_select_anon" ON public.pagos_moviles;
CREATE POLICY "pm_select_anon" ON public.pagos_moviles
  FOR SELECT USING (true);

DROP POLICY IF EXISTS "pm_insert_anon" ON public.pagos_moviles;
CREATE POLICY "pm_insert_anon" ON public.pagos_moviles
  FOR INSERT WITH CHECK (true);

DROP POLICY IF EXISTS "pm_update_anon" ON public.pagos_moviles;
CREATE POLICY "pm_update_anon" ON public.pagos_moviles
  FOR UPDATE USING (true);

DROP POLICY IF EXISTS "pm_delete_anon" ON public.pagos_moviles;
CREATE POLICY "pm_delete_anon" ON public.pagos_moviles
  FOR DELETE USING (true);
