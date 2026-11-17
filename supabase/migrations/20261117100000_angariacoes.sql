-- =====================================================================
-- Angariações: registro de imóveis angariados pela equipe.
-- Campos (em data): referencia, dataAngariacao (AAAA-MM-DD),
-- exclusividade ('sim' | 'nao') e dias (1 a 99999, só quando 'sim').
-- O servidor grava quem cadastrou (corretorId/corretorNome) e quando
-- (criadoTs); esses campos não podem ser alterados pelo navegador.
-- Corretor vê e edita só as próprias; quem vê a equipe vê todas.
-- =====================================================================

create table if not exists public.angariacoes (
  id             text primary key,
  data           jsonb not null default '{}'::jsonb,
  atualizado_em  timestamptz not null default now(),
  atualizado_por uuid default auth.uid()
);
alter table public.angariacoes enable row level security;

-- Carimbo e validação no servidor
create or replace function public.angariacoes_guarda() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  d    jsonb := coalesce(new.data, '{}'::jsonb);
  ref  text  := btrim(coalesce(d ->> 'referencia', ''));
  dt   text  := coalesce(d ->> 'dataAngariacao', '');
  exc  text  := coalesce(d ->> 'exclusividade', '');
  dias text  := btrim(coalesce(d ->> 'dias', ''));
begin
  if ref = '' then raise exception 'Informe a referência.' using errcode = '22023'; end if;
  if char_length(ref) > 60 then raise exception 'A referência pode ter até 60 caracteres.' using errcode = '22023'; end if;
  if dt !~ '^\d{4}-\d{2}-\d{2}$' then raise exception 'Informe a data da angariação.' using errcode = '22023'; end if;
  begin perform dt::date; exception when others then raise exception 'Data da angariação inválida.' using errcode = '22023'; end;
  if exc not in ('sim', 'nao') then raise exception 'Informe se há exclusividade (Sim ou Não).' using errcode = '22023'; end if;
  if exc = 'sim' then
    if dias !~ '^[0-9]{1,5}$' or dias::int < 1 then raise exception 'Informe os dias de exclusividade (de 1 a 99999).' using errcode = '22023'; end if;
  end if;

  d := (d - 'corretorId' - 'corretorNome' - 'criadoTs' - 'dias')
       || jsonb_build_object('referencia', ref, 'dataAngariacao', dt, 'exclusividade', exc)
       || case when exc = 'sim' then jsonb_build_object('dias', dias::int) else '{}'::jsonb end;

  if tg_op = 'INSERT' then
    d := d || jsonb_build_object(
      'corretorId',   coalesce(auth.uid()::text, new.data ->> 'corretorId', ''),
      'corretorNome', coalesce((select nome from public.perfis where id = auth.uid()), new.data ->> 'corretorNome', ''),
      'criadoTs',     (extract(epoch from now()) * 1000)::bigint);
  else
    d := d || jsonb_build_object(
      'corretorId',   old.data -> 'corretorId',
      'corretorNome', old.data -> 'corretorNome',
      'criadoTs',     old.data -> 'criadoTs');
  end if;

  new.data := d;
  new.atualizado_em := now();
  new.atualizado_por := auth.uid();
  return new;
end $$;

drop trigger if exists angariacoes_guarda on public.angariacoes;
create trigger angariacoes_guarda before insert or update on public.angariacoes
  for each row execute function public.angariacoes_guarda();

-- Inclui o menu "angariacoes" no padrão de Coordenador e Corretor
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
    return p in ('diario','relatorios','agenda','conhecimento','treinamentos','ponto','vendas','contratos','angariacoes','metas','equipe','conteudo','operacaoTodos');
  end if;
  return p in ('diario','relatorios','agenda','conhecimento','treinamentos','ponto','vendas','contratos','angariacoes');
end $$;

-- Regras de acesso
drop policy if exists angariacoes_ler on public.angariacoes;
drop policy if exists angariacoes_criar on public.angariacoes;
drop policy if exists angariacoes_editar on public.angariacoes;
drop policy if exists angariacoes_apagar on public.angariacoes;
create policy angariacoes_ler on public.angariacoes for select to authenticated
  using (public.ativo() and (public.pode('equipe') or public.pode('operacaoTodos') or public.meu(data, 'corretorId')));
create policy angariacoes_criar on public.angariacoes for insert to authenticated
  with check (public.pode('angariacoes'));
create policy angariacoes_editar on public.angariacoes for update to authenticated
  using (public.pode('angariacoes') and (public.pode('operacaoTodos') or public.meu(data, 'corretorId')))
  with check (public.pode('angariacoes') and (public.pode('operacaoTodos') or public.meu(data, 'corretorId')));
create policy angariacoes_apagar on public.angariacoes for delete to authenticated
  using (public.pode('angariacoes') and (public.pode('operacaoTodos') or public.meu(data, 'corretorId')));

grant select, insert, update, delete on public.angariacoes to authenticated;

-- Tempo real
do $$
begin
  execute 'alter publication supabase_realtime add table public.angariacoes';
exception when duplicate_object then null;
end $$;
