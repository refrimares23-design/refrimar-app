-- ============================================================
-- REFRIMAR OS — BOT DE VENTAS CON IA
-- Tabla de estado de conversaciones (escalado a humano)
-- ------------------------------------------------------------
-- Idempotente. Cópialo y ejecútalo en Supabase > SQL Editor.
-- ============================================================

create table if not exists public.chat_bot_estado (
  telefono text not null,
  canal text not null default 'whatsapp',
  escalado boolean not null default false,
  escalado_at timestamptz,
  updated_at timestamptz default now(),
  primary key (telefono, canal)
);

-- Devuelve el estado de una conversación (si está escalada y desde cuándo)
create or replace function public.chat_bot_estado_get(p_telefono text, p_canal text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare v json;
begin
  select json_build_object('escalado', coalesce(e.escalado, false), 'escalado_at', e.escalado_at)
  into v
  from public.chat_bot_estado e
  where e.telefono = p_telefono and e.canal = p_canal;
  return coalesce(v, '{"escalado": false, "escalado_at": null}'::json);
end;
$$;

-- Marca una conversación como "la atiende un humano" (el bot se calla 12h)
create or replace function public.chat_bot_estado_escalar(p_telefono text, p_canal text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.chat_bot_estado (telefono, canal, escalado, escalado_at, updated_at)
  values (p_telefono, p_canal, true, now(), now())
  on conflict (telefono, canal)
  do update set escalado = true, escalado_at = now(), updated_at = now();
end;
$$;

-- Vuelve a poner el bot en modo automático para esa conversación
-- (opcional: se puede llamar desde la app o manualmente).
create or replace function public.chat_bot_estado_limpiar(p_telefono text, p_canal text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.chat_bot_estado
  set escalado = false, updated_at = now()
  where telefono = p_telefono and canal = p_canal;
end;
$$;

grant execute on function public.chat_bot_estado_get(text, text) to anon, authenticated;
grant execute on function public.chat_bot_estado_escalar(text, text) to anon, authenticated;
grant execute on function public.chat_bot_estado_limpiar(text, text) to anon, authenticated;
