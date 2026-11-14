-- =====================================================================
-- Modelos de Contrato: documentos assinados (tabela + arquivos PDF).
-- - A data/hora da assinatura e o corretor responsável são carimbados
--   pelo servidor (horário de Brasília), não pelo aparelho.
-- - Depois de assinado, o documento não pode ser alterado.
-- - Cada corretor vê os que gerou; quem vê a equipe vê todos.
-- - Só o Master exclui.
-- =====================================================================

create table if not exists public.contratos (
  id text primary key,
  data jsonb not null default '{}'::jsonb,
  atualizado_em timestamptz not null default now(),
  atualizado_por uuid default auth.uid()
);
alter table public.contratos enable row level security;

-- Carimbo do servidor. No INSERT grava corretor e horário; no UPDATE só
-- permite registrar o arquivo PDF (uma única vez) e mantém o resto intacto.
create or replace function public.contratos_carimbo() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  agora timestamptz := now();
begin
  if tg_op = 'INSERT' then
    new.data := (coalesce(new.data, '{}'::jsonb) - 'arquivo' - 'corretorId' - 'corretorNome' - 'assinadoTs' - 'assinadoLocal')
      || jsonb_build_object(
        'corretorId',    auth.uid()::text,
        'corretorNome',  coalesce((select nome from public.perfis where id = auth.uid()), ''),
        'assinadoTs',    (extract(epoch from agora) * 1000)::bigint,
        'assinadoLocal', to_char(agora at time zone 'America/Sao_Paulo', 'YYYY-MM-DD"T"HH24:MI:SS'));
  else
    if coalesce(old.data ->> 'arquivo', '') <> '' then
      raise exception 'Documento assinado não pode ser alterado.' using errcode = '42501';
    end if;
    new.id := old.id;
    new.data := old.data || jsonb_build_object('arquivo', (old.data ->> 'corretorId') || '/' || old.id || '.pdf');
  end if;
  new.atualizado_em := agora;
  new.atualizado_por := auth.uid();
  return new;
end $$;

drop trigger if exists carimbar on public.contratos;
drop trigger if exists contratos_carimbo on public.contratos;
create trigger contratos_carimbo before insert or update on public.contratos
  for each row execute function public.contratos_carimbo();

-- Inclui o menu "contratos" no padrão de Coordenador e Corretor
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
    return p in ('diario','relatorios','agenda','conhecimento','treinamentos','ponto','vendas','contratos','metas','equipe','conteudo','operacaoTodos');
  end if;
  return p in ('diario','relatorios','agenda','conhecimento','treinamentos','ponto','vendas','contratos');
end $$;

-- Regras de segurança
drop policy if exists contratos_ler on public.contratos;
drop policy if exists contratos_criar on public.contratos;
drop policy if exists contratos_arquivo on public.contratos;
drop policy if exists contratos_apagar on public.contratos;
create policy contratos_ler on public.contratos for select to authenticated
  using (public.ativo() and (public.pode('equipe') or public.meu(data, 'corretorId')));
create policy contratos_criar on public.contratos for insert to authenticated
  with check (public.pode('contratos') and public.meu(data, 'corretorId'));
create policy contratos_arquivo on public.contratos for update to authenticated
  using (public.pode('contratos') and public.meu(data, 'corretorId'))
  with check (public.pode('contratos') and public.meu(data, 'corretorId'));
create policy contratos_apagar on public.contratos for delete to authenticated
  using (public.e_master());

-- Arquivos PDF assinados (Storage, privado). Caminho: <corretorId>/<id>.pdf
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('contratos', 'contratos', false, 10485760, array['application/pdf'])
on conflict (id) do update set public = false, file_size_limit = 10485760, allowed_mime_types = array['application/pdf'];

drop policy if exists contratos_arquivos_ler on storage.objects;
drop policy if exists contratos_arquivos_enviar on storage.objects;
drop policy if exists contratos_arquivos_apagar on storage.objects;
create policy contratos_arquivos_ler on storage.objects for select to authenticated
  using (bucket_id = 'contratos' and public.ativo()
         and (public.pode('equipe') or (storage.foldername(name))[1] = auth.uid()::text));
create policy contratos_arquivos_enviar on storage.objects for insert to authenticated
  with check (bucket_id = 'contratos' and public.pode('contratos')
              and (storage.foldername(name))[1] = auth.uid()::text);
create policy contratos_arquivos_apagar on storage.objects for delete to authenticated
  using (bucket_id = 'contratos' and public.e_master());

do $$
begin
  execute 'alter publication supabase_realtime add table public.contratos';
exception when duplicate_object then null;
end $$;
