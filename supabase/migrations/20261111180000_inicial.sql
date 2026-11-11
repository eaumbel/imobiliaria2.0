-- =====================================================================
-- Imobiliária 2.0 · Gestão comercial — estrutura do banco (Supabase)
-- Tabelas, funções de permissão, regras de segurança (RLS),
-- armazenamento dos arquivos de treinamento e tempo real.
-- =====================================================================

-- ---------- Perfis dos usuários (ligados ao login do Supabase Auth) ----------
create table if not exists public.perfis (
  id            uuid primary key references auth.users(id) on delete cascade,
  login         text not null unique,
  nome          text not null,
  email         text,
  telefone      text,
  creci         text,
  especialidade text,
  perfil        text not null default 'corretor' check (perfil in ('master','coordenador','corretor')),
  participa     boolean,
  ativo         boolean not null default true,
  permissoes    jsonb not null default '{}'::jsonb,
  criado_em     timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);
alter table public.perfis enable row level security;

-- ---------- Tabelas de dados (documentos JSON) ----------
do $$
declare t text;
begin
  foreach t in array array['metas','agenda','conhecimento','treinamentos','ponto','visitas','vendas','config'] loop
    execute format('create table if not exists public.%I (
      id text primary key,
      data jsonb not null default ''{}''::jsonb,
      atualizado_em timestamptz not null default now(),
      atualizado_por uuid default auth.uid()
    )', t);
    execute format('alter table public.%I enable row level security', t);
  end loop;
end $$;

create or replace function public.carimbar() returns trigger language plpgsql as $$
begin
  new.atualizado_em := now();
  new.atualizado_por := auth.uid();
  return new;
end $$;

do $$
declare t text;
begin
  foreach t in array array['metas','agenda','conhecimento','treinamentos','ponto','visitas','vendas','config'] loop
    execute format('drop trigger if exists carimbar on public.%I', t);
    execute format('create trigger carimbar before insert or update on public.%I for each row execute function public.carimbar()', t);
  end loop;
end $$;

-- ---------- Funções de permissão (mesma regra usada na tela) ----------
create or replace function public.ativo() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.perfis where id = auth.uid() and ativo);
$$;

create or replace function public.e_master() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.perfis where id = auth.uid() and ativo and perfil = 'master');
$$;

-- pode('chave'): Master sempre; depois exceção do usuário; depois configuração do perfil; depois padrão.
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
    return p in ('relatorios','agenda','conhecimento','treinamentos','ponto','vendas','metas','equipe','conteudo','operacaoTodos');
  end if;
  return p in ('relatorios','agenda','conhecimento','treinamentos','ponto','vendas');
end $$;

create or replace function public.meu(d jsonb, campo text) returns boolean
language sql stable as $$
  select coalesce(d ->> campo, '') = auth.uid()::text;
$$;

grant execute on function public.ativo(), public.e_master(), public.pode(text), public.meu(jsonb, text) to authenticated;

-- ---------- Regras de segurança (RLS) ----------
-- Perfis: qualquer usuário ativo lê a equipe; alterações só pela função admin-usuarios.
drop policy if exists perfis_ler on public.perfis;
create policy perfis_ler on public.perfis for select to authenticated using (public.ativo());

-- Metas
drop policy if exists metas_ler on public.metas;
drop policy if exists metas_gravar on public.metas;
create policy metas_ler on public.metas for select to authenticated using (public.ativo());
create policy metas_gravar on public.metas for all to authenticated
  using (public.pode('metasEdit')) with check (public.pode('metasEdit'));

-- Configuração (permissões por perfil): só o Master altera
drop policy if exists config_ler on public.config;
drop policy if exists config_gravar on public.config;
create policy config_ler on public.config for select to authenticated using (public.ativo());
create policy config_gravar on public.config for all to authenticated
  using (public.e_master()) with check (public.e_master());

-- Base de conhecimento e treinamentos
drop policy if exists conhecimento_ler on public.conhecimento;
drop policy if exists conhecimento_gravar on public.conhecimento;
create policy conhecimento_ler on public.conhecimento for select to authenticated
  using (public.pode('conhecimento') or public.pode('conteudo'));
create policy conhecimento_gravar on public.conhecimento for all to authenticated
  using (public.pode('conteudo')) with check (public.pode('conteudo'));

drop policy if exists treinamentos_ler on public.treinamentos;
drop policy if exists treinamentos_gravar on public.treinamentos;
create policy treinamentos_ler on public.treinamentos for select to authenticated
  using (public.pode('treinamentos') or public.pode('conteudo'));
create policy treinamentos_gravar on public.treinamentos for all to authenticated
  using (public.pode('conteudo')) with check (public.pode('conteudo'));

-- Agenda: vê os gerais, os próprios, ou todos se tiver acesso à equipe
drop policy if exists agenda_ler on public.agenda;
drop policy if exists agenda_gravar on public.agenda;
create policy agenda_ler on public.agenda for select to authenticated
  using (public.ativo() and (public.pode('operacaoTodos') or public.pode('equipe')
         or coalesce(data ->> 'corretorId', '') = '' or public.meu(data, 'corretorId')));
create policy agenda_gravar on public.agenda for all to authenticated
  using (public.pode('agenda') and (public.pode('operacaoTodos') or public.meu(data, 'corretorId')))
  with check (public.pode('agenda') and (public.pode('operacaoTodos') or public.meu(data, 'corretorId')));

-- Visitas
drop policy if exists visitas_ler on public.visitas;
drop policy if exists visitas_gravar on public.visitas;
create policy visitas_ler on public.visitas for select to authenticated
  using (public.ativo() and (public.pode('operacaoTodos') or public.pode('equipe') or public.meu(data, 'corretorId')));
create policy visitas_gravar on public.visitas for all to authenticated
  using (public.pode('ponto') and (public.pode('operacaoTodos') or public.meu(data, 'corretorId')))
  with check (public.pode('ponto') and (public.pode('operacaoTodos') or public.meu(data, 'corretorId')));

-- Cartão ponto: todos veem a lista do dia; cada um grava a própria linha (ou todos, se permitido)
drop policy if exists ponto_ler on public.ponto;
drop policy if exists ponto_gravar on public.ponto;
create policy ponto_ler on public.ponto for select to authenticated using (public.ativo());
create policy ponto_gravar on public.ponto for all to authenticated
  using (public.pode('ponto') and (public.pode('operacaoTodos') or public.meu(data, 'corretorId')))
  with check (public.pode('ponto') and (public.pode('operacaoTodos') or public.meu(data, 'corretorId')));

-- Vendas: vê as que participou (vendedor ou angariador) ou todas, se permitido
drop policy if exists vendas_ler on public.vendas;
drop policy if exists vendas_gravar on public.vendas;
create policy vendas_ler on public.vendas for select to authenticated
  using (public.ativo() and (public.pode('operacaoTodos') or public.pode('equipe')
         or public.meu(data, 'vendedorId') or public.meu(data, 'angariadorId')));
create policy vendas_gravar on public.vendas for all to authenticated
  using (public.pode('vendas') and (public.pode('operacaoTodos') or public.meu(data, 'vendedorId')))
  with check (public.pode('vendas') and (public.pode('operacaoTodos') or public.meu(data, 'vendedorId')));

-- ---------- Arquivos dos treinamentos (Storage, privado) ----------
insert into storage.buckets (id, name, public, file_size_limit)
values ('treinamentos', 'treinamentos', false, 52428800)
on conflict (id) do update set public = false, file_size_limit = 52428800;

drop policy if exists treinamentos_arquivos_ler on storage.objects;
drop policy if exists treinamentos_arquivos_enviar on storage.objects;
drop policy if exists treinamentos_arquivos_apagar on storage.objects;
create policy treinamentos_arquivos_ler on storage.objects for select to authenticated
  using (bucket_id = 'treinamentos' and public.ativo());
create policy treinamentos_arquivos_enviar on storage.objects for insert to authenticated
  with check (bucket_id = 'treinamentos' and public.pode('conteudo'));
create policy treinamentos_arquivos_apagar on storage.objects for delete to authenticated
  using (bucket_id = 'treinamentos' and public.pode('conteudo'));

-- ---------- Tempo real (atualiza as telas de todos na hora) ----------
do $$
declare t text;
begin
  foreach t in array array['perfis','metas','agenda','conhecimento','treinamentos','ponto','visitas','vendas','config'] loop
    begin
      execute format('alter publication supabase_realtime add table public.%I', t);
    exception when duplicate_object then null;
    end;
  end loop;
end $$;
