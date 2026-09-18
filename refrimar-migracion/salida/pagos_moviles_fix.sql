-- ═══════════════════════════════════════════════════════════════════
-- REFRIMAR OS — Corregir tabla pagos_moviles
-- Ejecutar en el SQL Editor de Supabase (https://supabase.com → SQL Editor)
-- Agrega las columnas que faltan por si la tabla ya existía sin ellas.
-- (ALTER TABLE ... ADD COLUMN IF NOT EXISTS es seguro de repetir)
-- ═══════════════════════════════════════════════════════════════════

ALTER TABLE public.pagos_moviles ALTER COLUMN remitente DROP NOT NULL;

ALTER TABLE public.pagos_moviles ADD COLUMN IF NOT EXISTS banco text NULL;
ALTER TABLE public.pagos_moviles ADD COLUMN IF NOT EXISTS monto numeric(14,2) NOT NULL DEFAULT 0;
ALTER TABLE public.pagos_moviles ADD COLUMN IF NOT EXISTS fecha date NULL;
ALTER TABLE public.pagos_moviles ADD COLUMN IF NOT EXISTS sucursal_id uuid NULL;
ALTER TABLE public.pagos_moviles ADD COLUMN IF NOT EXISTS sucursal_nombre text NULL;
ALTER TABLE public.pagos_moviles ADD COLUMN IF NOT EXISTS referencia text NULL;
ALTER TABLE public.pagos_moviles ADD COLUMN IF NOT EXISTS quien_pago text NULL;
ALTER TABLE public.pagos_moviles ADD COLUMN IF NOT EXISTS creado_en timestamptz NOT NULL DEFAULT now();

-- Asegurar RLS (por si no estaba habilitado)
ALTER TABLE public.pagos_moviles ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "pm_select_anon" ON public.pagos_moviles;
CREATE POLICY "pm_select_anon" ON public.pagos_moviles FOR SELECT USING (true);

DROP POLICY IF EXISTS "pm_insert_anon" ON public.pagos_moviles;
CREATE POLICY "pm_insert_anon" ON public.pagos_moviles FOR INSERT WITH CHECK (true);
