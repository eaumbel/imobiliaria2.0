-- =====================================================================
-- SMS pelo Twilio: configuração, templates e registro de envios
--
-- sms_gateway: UMA configuração (id = 'principal'): Account SID, Auth Token,
--   remetente (número do Twilio em formato +55..., +1... ou um Messaging
--   Service SID "MG..."). Só o Master vê e altera. O AUTH TOKEN nunca volta
--   para a tela: só a função enviar-sms (servidor) consegue lê-lo; a tela só
--   sabe se há token cadastrado (tem_token). Gravação apenas pela função
--   sms_gateway_salvar (token em branco = mantém o atual).
-- sms_templates: mensagens prontas (nome, chave usada pelas rotinas, texto,
--   remover acentos). Só o Master gerencia.
-- sms_envios: registro de cada envio (para, texto, template, status do
--   Twilio, SID da mensagem, erro). Gravado só pelo servidor.
-- =====================================================================

create table if not exists public.sms_gateway (
  id            text primary key default 'principal' check (id = 'principal'),
  account_sid   text not null default '',
  auth_token    text,
  tem_token     boolean generated always as (coalesce(auth_token, '') <> '') stored,
  remetente     text not null default '',
  ativo         boolean not null default false,
  atualizado_em timestamptz not null default now(),
  atualizado_por uuid default auth.uid()
);
alter table public.sms_gateway enable row level security;
drop policy if exists sms_gateway_ler on public.sms_gateway;
create policy sms_gateway_ler on public.sms_gateway for select to authenticated using (public.e_master());
-- o token não sai do banco para a tela
revoke all on public.sms_gateway from anon, authenticated;
grant select (id, account_sid, tem_token, remetente, ativo, atualizado_em) on public.sms_gateway to authenticated;

create or replace function public.sms_gateway_salvar(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_sid   text := btrim(coalesce(p ->> 'account_sid', ''));
  v_tok   text := btrim(coalesce(p ->> 'auth_token', ''));
  v_rem   text := regexp_replace(btrim(coalesce(p ->> 'remetente', '')), '[\s().-]', '', 'g');
  r public.sms_gateway;
begin
  if not public.e_master() then raise exception 'Somente o Master altera a configuração de SMS.' using errcode = '42501'; end if;
  if v_sid !~ '^AC[0-9a-fA-F]{32}$' then raise exception 'Account SID inválido: começa com AC e tem 34 caracteres (Twilio Console → Account Info).' using errcode = '22023'; end if;
  if v_tok <> '' and v_tok !~ '^[0-9a-zA-Z]{32}$' then raise exception 'Auth Token inválido: tem 32 caracteres (Twilio Console → Account Info).' using errcode = '22023'; end if;
  if v_rem !~ '^(\+[1-9][0-9]{7,14}|MG[0-9a-fA-F]{32})$' then
    raise exception 'Remetente inválido: use o número do Twilio com + e código do país (ex.: +15551234567) ou um Messaging Service SID (MG...).' using errcode = '22023';
  end if;
  insert into public.sms_gateway (id) values ('principal') on conflict (id) do nothing;
  update public.sms_gateway set
    account_sid = v_sid,
    auth_token  = case when coalesce((p ->> 'remover_token')::boolean, false) then null when v_tok <> '' then v_tok else auth_token end,
    remetente   = v_rem,
    ativo       = coalesce((p ->> 'ativo')::boolean, false),
    atualizado_em = now(), atualizado_por = auth.uid()
  where id = 'principal' returning * into r;
  return jsonb_build_object('account_sid', r.account_sid, 'tem_token', r.tem_token, 'remetente', r.remetente, 'ativo', r.ativo);
end $$;
revoke all on function public.sms_gateway_salvar(jsonb) from public, anon;
grant execute on function public.sms_gateway_salvar(jsonb) to authenticated;

-- ---------- Templates ----------
create table if not exists public.sms_templates (
  id             text primary key,
  data           jsonb not null default '{}'::jsonb,
  atualizado_em  timestamptz not null default now(),
  atualizado_por uuid default auth.uid()
);
alter table public.sms_templates enable row level security;
create unique index if not exists sms_templates_chave_idx on public.sms_templates (lower(data ->> 'chave'));

create or replace function public.sms_templates_guarda() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  d jsonb := coalesce(new.data, '{}'::jsonb);
  nome text := btrim(coalesce(d ->> 'nome', ''));
  chave text := lower(btrim(coalesce(d ->> 'chave', '')));
  texto text := btrim(coalesce(d ->> 'texto', ''));
begin
  if nome = '' then raise exception 'Informe o nome do template.' using errcode = '22023'; end if;
  if chave !~ '^[a-z0-9][a-z0-9_-]{1,59}$' then raise exception 'A chave deve ter de 2 a 60 letras minúsculas, números, - ou _ (ex.: lembrete-visita).' using errcode = '22023'; end if;
  if texto = '' then raise exception 'Escreva a mensagem.' using errcode = '22023'; end if;
  if char_length(texto) > 1000 then raise exception 'A mensagem pode ter até 1.000 caracteres.' using errcode = '22023'; end if;
  if exists (select 1 from public.sms_templates t where lower(t.data ->> 'chave') = chave and t.id <> new.id) then
    raise exception 'Já existe um template com a chave "%".', chave using errcode = '23505';
  end if;
  new.data := d || jsonb_build_object('nome', left(nome, 120), 'chave', chave, 'texto', texto,
    'semAcentos', coalesce((d ->> 'semAcentos')::boolean, true), 'ativo', coalesce((d ->> 'ativo')::boolean, true));
  new.atualizado_em := now();
  new.atualizado_por := auth.uid();
  return new;
end $$;
drop trigger if exists sms_templates_guarda on public.sms_templates;
create trigger sms_templates_guarda before insert or update on public.sms_templates
  for each row execute function public.sms_templates_guarda();

drop policy if exists sms_templates_master on public.sms_templates;
create policy sms_templates_master on public.sms_templates for all to authenticated
  using (public.e_master()) with check (public.e_master());
revoke all on public.sms_templates from anon;
grant select, insert, update, delete on public.sms_templates to authenticated;

-- ---------- Registro de envios ----------
create table if not exists public.sms_envios (
  id         uuid primary key default gen_random_uuid(),
  criado_em  timestamptz not null default now(),
  para       text not null,
  texto      text not null default '',
  template   text,
  origem     text not null default 'tela',
  status     text not null,
  sid        text,
  segmentos  int,
  erro       text,
  por        uuid
);
alter table public.sms_envios enable row level security;
create index if not exists sms_envios_criado_idx on public.sms_envios (criado_em desc);
drop policy if exists sms_envios_ler on public.sms_envios;
create policy sms_envios_ler on public.sms_envios for select to authenticated using (public.e_master());
revoke all on public.sms_envios from anon, authenticated;
grant select on public.sms_envios to authenticated;
