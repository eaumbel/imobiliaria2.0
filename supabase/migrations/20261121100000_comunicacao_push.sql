-- =====================================================================
-- Comunicação (avisos rápidos para a equipe) + notificações push
--
-- comunicados: avisos de até 75 caracteres. Quem tem a permissão
--   'comunicacao' (Master e Coordenador por padrão) envia pela função
--   comunicar(); o aviso vira uma notificação (sininho + push) para todos
--   os usuários ativos.
--
-- push_inscricoes: um aparelho/navegador por linha (o endereço de push).
--   Cada aparelho fica ligado ao usuário que entrou por último nele.
--   Gravado só pelas funções push_inscrever() e push_cancelar().
--
-- push_config: segredo interno, chaves VAPID (geradas pela função
--   enviar-push na primeira vez) e o endereço da função. Ninguém do
--   sistema lê esta tabela; só o servidor.
--
-- Disparo: toda notificação nova (Kanban ou comunicado) chama a função
--   enviar-push pelo pg_net, que manda o push para os aparelhos da pessoa.
-- =====================================================================

create extension if not exists pg_net with schema extensions;

-- ---------- Permissão nova 'comunicacao' (Master sempre; Coordenador por padrão) ----------
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
    return p in ('diario','relatorios','agenda','conhecimento','treinamentos','ponto','vendas','contratos','angariacoes','kanban','metas','equipe','conteudo','operacaoTodos','kanbanTodos','comunicacao');
  end if;
  return p in ('diario','relatorios','agenda','conhecimento','treinamentos','ponto','vendas','contratos','angariacoes','kanban');
end $$;

-- ---------- Comunicados ----------
create table if not exists public.comunicados (
  id             uuid primary key default gen_random_uuid(),
  texto          text not null check (char_length(texto) between 1 and 75),
  autor          uuid references public.perfis(id) on delete set null,
  autor_nome     text not null default '',
  destinatarios  int not null default 0,
  criado_em      timestamptz not null default now()
);
alter table public.comunicados enable row level security;
create index if not exists comunicados_criado_idx on public.comunicados (criado_em desc);

drop policy if exists comunicados_ler on public.comunicados;
create policy comunicados_ler on public.comunicados for select to authenticated using (public.pode('comunicacao'));
revoke all on public.comunicados from anon, authenticated;
grant select on public.comunicados to authenticated;

create or replace function public.comunicar(p_texto text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me public.perfis;
  t  text := btrim(regexp_replace(coalesce(p_texto, ''), '\s+', ' ', 'g'));
  cid uuid; n int;
begin
  if not public.pode('comunicacao') then raise exception 'Seu acesso não permite enviar comunicados.' using errcode = '42501'; end if;
  if t = '' then raise exception 'Escreva o comunicado.' using errcode = '22023'; end if;
  if char_length(t) > 75 then raise exception 'O comunicado pode ter até 75 caracteres.' using errcode = '22023'; end if;
  select * into me from public.perfis where id = auth.uid();
  -- evita envio repetido por clique duplo
  if exists (select 1 from public.comunicados where autor = me.id and texto = t and criado_em > now() - interval '30 seconds') then
    raise exception 'Este comunicado acabou de ser enviado.' using errcode = '22023';
  end if;

  insert into public.comunicados (texto, autor, autor_nome) values (t, me.id, coalesce(me.nome, '')) returning id into cid;
  insert into public.notificacoes (usuario, tipo, titulo, texto, ator, ator_nome)
    select f.id, 'comunicado', t, '', me.id, coalesce(me.nome, '')
      from public.perfis f where f.ativo and f.id <> me.id;
  get diagnostics n = row_count;
  update public.comunicados set destinatarios = n where id = cid;
  return jsonb_build_object('id', cid, 'destinatarios', n);
end $$;
revoke all on function public.comunicar(text) from public, anon;
grant execute on function public.comunicar(text) to authenticated;

-- ---------- Aparelhos inscritos para push ----------
create table if not exists public.push_inscricoes (
  endpoint   text primary key,
  usuario    uuid not null references public.perfis(id) on delete cascade,
  p256dh     text not null,
  auth       text not null,
  agente     text not null default '',
  criado_em  timestamptz not null default now(),
  usado_em   timestamptz
);
alter table public.push_inscricoes enable row level security;
create index if not exists push_inscricoes_usuario_idx on public.push_inscricoes (usuario);
revoke all on public.push_inscricoes from anon, authenticated;

create or replace function public.push_inscrever(p_endpoint text, p_p256dh text, p_auth text, p_agente text default '') returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.ativo() then raise exception 'Seu acesso está inativo.' using errcode = '42501'; end if;
  if coalesce(p_endpoint, '') !~ '^https://' or char_length(p_endpoint) > 1000 then raise exception 'Inscrição inválida.' using errcode = '22023'; end if;
  if coalesce(p_p256dh, '') !~ '^[A-Za-z0-9_=-]{80,100}$' or coalesce(p_auth, '') !~ '^[A-Za-z0-9_=-]{16,30}$' then raise exception 'Inscrição inválida.' using errcode = '22023'; end if;
  -- o aparelho passa a ser de quem entrou nele por último
  insert into public.push_inscricoes (endpoint, usuario, p256dh, auth, agente)
    values (p_endpoint, auth.uid(), p_p256dh, p_auth, left(coalesce(p_agente, ''), 300))
  on conflict (endpoint) do update set usuario = excluded.usuario, p256dh = excluded.p256dh, auth = excluded.auth, agente = excluded.agente;
  -- no máximo 10 aparelhos por pessoa (ficam os mais recentes)
  delete from public.push_inscricoes where usuario = auth.uid() and endpoint in (
    select endpoint from public.push_inscricoes where usuario = auth.uid() order by criado_em desc offset 10);
end $$;

create or replace function public.push_cancelar(p_endpoint text) returns void
language plpgsql security definer set search_path = public as $$
begin
  delete from public.push_inscricoes where endpoint = p_endpoint and usuario = auth.uid();
end $$;
revoke all on function public.push_inscrever(text, text, text, text), public.push_cancelar(text) from public, anon;
grant execute on function public.push_inscrever(text, text, text, text), public.push_cancelar(text) to authenticated;

-- ---------- Configuração interna do push (só o servidor lê) ----------
create table if not exists public.push_config (
  id            int primary key default 1 check (id = 1),
  segredo       text not null default replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''),
  funcao_url    text not null default 'https://hjzessepenqedsfgokmt.supabase.co/functions/v1/enviar-push',
  vapid_publica text,
  vapid_privada text
);
alter table public.push_config enable row level security;
revoke all on public.push_config from anon, authenticated;
insert into public.push_config (id) values (1) on conflict (id) do nothing;

-- ---------- Disparo: cada lote de notificações novas chama a função enviar-push ----------
create or replace function public.push_disparar() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
declare
  ids jsonb; cfg public.push_config;
begin
  select coalesce(jsonb_agg(id), '[]'::jsonb) into ids from novas where not lida;
  if jsonb_array_length(ids) = 0 then return null; end if;
  select * into cfg from public.push_config where id = 1;
  if cfg.id is null then return null; end if;
  begin
    perform net.http_post(
      url := cfg.funcao_url,
      body := jsonb_build_object('ids', ids),
      headers := jsonb_build_object('Content-Type', 'application/json', 'x-push-segredo', cfg.segredo),
      timeout_milliseconds := 15000);
  exception when others then
    -- o push nunca impede a notificação de ser gravada
    raise warning 'push não disparado: %', sqlerrm;
  end;
  return null;
end $$;
revoke all on function public.push_disparar() from public, anon, authenticated;

drop trigger if exists push_disparar on public.notificacoes;
create trigger push_disparar after insert on public.notificacoes
  referencing new table as novas
  for each statement execute function public.push_disparar();
