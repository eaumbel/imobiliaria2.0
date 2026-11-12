-- Diário de bordo: tabela, permissão "diario" e regras de segurança.
create table if not exists public.diario (
  id text primary key,
  data jsonb not null default '{}'::jsonb,
  atualizado_em timestamptz not null default now(),
  atualizado_por uuid default auth.uid()
);
alter table public.diario enable row level security;
drop trigger if exists carimbar on public.diario;
create trigger carimbar before insert or update on public.diario for each row execute function public.carimbar();

-- Inclui o menu "diario" no padrão de Coordenador e Corretor
create or replace function public.pode(p text) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare
  me public.perfis;
  v  jsonb;
begin
  select * into me from public.perfis where id = auth.uid();
  if me.id is null or not me.ativo then return false; end if;
  if me.perfil = 'master' then return true; end if;
  v := me.permissoes -> p;
  if v is not null and jsonb_typeof(v) = 'boolean' then return (v #>> '{}')::boolean; end if;
  select c.data -> me.perfil -> p into v from public.config c where c.id = 'permissoes';
  if v is not null and jsonb_typeof(v) = 'boolean' then return (v #>> '{}')::boolean; end if;
  if me.perfil = 'coordenador' then
    return p in ('diario','relatorios','agenda','conhecimento','treinamentos','ponto','vendas','metas','equipe','conteudo','operacaoTodos');
  end if;
  return p in ('diario','relatorios','agenda','conhecimento','treinamentos','ponto','vendas');
end $$;

-- Cada um lê e escreve o próprio diário; quem vê a equipe lê o de todos.
drop policy if exists diario_ler on public.diario;
drop policy if exists diario_gravar on public.diario;
create policy diario_ler on public.diario for select to authenticated
  using (public.ativo() and (public.pode('equipe') or public.meu(data, 'corretorId')));
create policy diario_gravar on public.diario for all to authenticated
  using (public.pode('diario') and public.meu(data, 'corretorId'))
  with check (public.pode('diario') and public.meu(data, 'corretorId'));

do $$
begin
  execute 'alter publication supabase_realtime add table public.diario';
exception when duplicate_object then null;
end $$;
