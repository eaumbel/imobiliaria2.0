-- Controle do limite de análises de IA por corretor (usado só pela função diario-ia).
create table if not exists public.uso_ia (
  id      bigserial primary key,
  usuario uuid not null references auth.users(id) on delete cascade,
  em      timestamptz not null default now()
);
create index if not exists uso_ia_usuario_em on public.uso_ia (usuario, em desc);
alter table public.uso_ia enable row level security;
-- Sem políticas: só a função (service_role) lê e grava.
