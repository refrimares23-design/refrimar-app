-- ============================================================
-- MIGRACIÓN: AVISOS WHATSAPP DE CUENTAS POR COBRAR (CXC)
-- ------------------------------------------------------------
-- QUÉ HACE
--   1. Agrega a `ventas` la columna `ultimo_aviso` (fecha del último
--      recordatorio enviado por WhatsApp), para no spamear al dueño.
--   2. Crea la RPC `deudas_por_avisar(p_dias)` que devuelve las
--      facturas a crédito por vencer (dentro de p_dias) o vencidas,
--      con saldo pendiente y que aún NO han sido avisadas (o hace
--      más de 2 días). La usa el Cloudflare Worker (cron diario)
--      para mandar el recordatorio.
--   3. Crea la RPC `deuda_marcar_avisada(p_venta_id)` que el Worker
--      llama DESPUÉS de enviar el WhatsApp, para no repetir el aviso.
--
-- CÓMO APLICAR (OBLIGATORIO ANTES DE DESPLEGAR)
--   1. Supabase → SQL Editor → New query
--   2. Pega TODO este archivo y presiona "Run"
--   3. Solo DESPUÉS despliega la app (npx wrangler deploy).
--
--   Es seguro correrlo varias veces (IF NOT EXISTS / OR REPLACE).
-- ============================================================

-- ------------------------------------------------------------
-- 1. Columna de último aviso en ventas
-- ------------------------------------------------------------
alter table ventas add column if not exists ultimo_aviso date;

-- ------------------------------------------------------------
-- 2. RPC: LISTAR DEUDAS QUE NECESITAN AVISO
--    Devuelve facturas a crédito con saldo pendiente cuyo
--    vencimiento está a <= p_dias (o ya venció) y que no han
--    sido avisadas hoy (ni en los últimos 2 días).
-- ------------------------------------------------------------
create or replace function deudas_por_avisar(p_dias int default 3)
returns jsonb
language sql
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(t order by t.vence), '[]'::jsonb)
  from (
    select
      id as venta_id,
      numero,
      cliente_nombre,
      cliente_rif,
      total_usd,
      monto_abonado,
      (created_at::date + coalesce(dias_credito, 30)) as vence,
      greatest(coalesce(total_usd, 0) - coalesce(monto_abonado, 0), 0) as saldo,
      sucursal_nombre
    from ventas
    where metodo_pago = 'credito'
      and estado = 'completada'
      and greatest(coalesce(total_usd, 0) - coalesce(monto_abonado, 0), 0) > 0.005
      and (created_at::date + coalesce(dias_credito, 30)) <= current_date + coalesce(p_dias, 3)
      and (ultimo_aviso is null or ultimo_aviso < current_date - 2)
  ) t;
$$;

-- ------------------------------------------------------------
-- 3. RPC: MARCAR UNA DEUDA COMO AVISADA (se llama tras enviar)
-- ------------------------------------------------------------
create or replace function deuda_marcar_avisada(p_venta_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  update ventas set ultimo_aviso = current_date where id = p_venta_id;
  return jsonb_build_object('ok', true);
end;
$$;

-- ------------------------------------------------------------
-- 4. Permitir ejecutar las RPCs a anon (las usa el Worker/browser)
-- ------------------------------------------------------------
grant execute on function deudas_por_avisar(int) to anon, authenticated;
grant execute on function deuda_marcar_avisada(uuid) to anon, authenticated;
