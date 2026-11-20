-- =====================================================================
-- Gateway de e-mail (SMTP) e templates de e-mail
--
-- email_gateway: UMA configuração (id = 'principal'): servidor, porta,
--   segurança, login, senha e remetente. Só o Master vê e altera.
--   A SENHA nunca volta para a tela: só a função enviar-email (servidor)
--   consegue lê-la. A tela só sabe se há senha cadastrada (tem_senha).
--   Gravação apenas pela função email_gateway_salvar (senha em branco =
--   mantém a atual).
-- email_templates: mensagens prontas (nome, chave, assunto, corpo,
--   formato texto/html). A "chave" é o nome usado pelas rotinas
--   automáticas para escolher o template. Só o Master gerencia.
-- email_envios: registro de cada envio (para quem, assunto, template,
--   ok/erro). Gravado só pelo servidor; o Master consulta.
-- =====================================================================

create table if not exists public.email_gateway (
  id               text primary key default 'principal' check (id = 'principal'),
  provedor         text not null default 'gmail',
  host             text not null default 'smtp.gmail.com',
  porta            int  not null default 465 check (porta between 1 and 65535),
  seguranca        text not null default 'ssl' check (seguranca in ('ssl', 'starttls', 'nenhuma')),
  usuario          text not null default '',
  senha            text,
  tem_senha        boolean generated always as (coalesce(senha, '') <> '') stored,
  remetente_nome   text not null default '',
  remetente_email  text not null default '',
  responder_para   text not null default '',
  ativo            boolean not null default false,
  atualizado_em    timestamptz not null default now(),
  atualizado_por   uuid default auth.uid()
);
alter table public.email_gateway enable row level security;

drop policy if exists email_gateway_ler on public.email_gateway;
create policy email_gateway_ler on public.email_gateway for select to authenticated using (public.e_master());
-- a senha não sai do banco para a tela: só as demais colunas podem ser lidas
revoke all on public.email_gateway from anon, authenticated;
grant select (id, provedor, host, porta, seguranca, usuario, tem_senha, remetente_nome, remetente_email, responder_para, ativo, atualizado_em)
  on public.email_gateway to authenticated;

create or replace function public.email_gateway_salvar(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_host  text := lower(btrim(coalesce(p ->> 'host', '')));
  v_porta int;
  v_seg   text := coalesce(p ->> 'seguranca', 'ssl');
  v_user  text := btrim(coalesce(p ->> 'usuario', ''));
  v_rem   text := lower(btrim(coalesce(p ->> 'remetente_email', '')));
  v_resp  text := lower(btrim(coalesce(p ->> 'responder_para', '')));
  v_senha text := coalesce(p ->> 'senha', '');
  r public.email_gateway;
begin
  if not public.e_master() then raise exception 'Somente o Master altera o servidor de e-mail.' using errcode = '42501'; end if;
  if v_host !~ '^[a-z0-9.-]+\.[a-z]{2,}$' then raise exception 'Informe o servidor SMTP (ex.: smtp.gmail.com).' using errcode = '22023'; end if;
  begin v_porta := (p ->> 'porta')::int; exception when others then v_porta := null; end;
  if v_porta is null or v_porta < 1 or v_porta > 65535 then raise exception 'Porta inválida.' using errcode = '22023'; end if;
  if v_seg not in ('ssl', 'starttls', 'nenhuma') then raise exception 'Segurança inválida.' using errcode = '22023'; end if;
  if v_user = '' then raise exception 'Informe o login (usuário) do e-mail.' using errcode = '22023'; end if;
  if v_rem = '' then v_rem := lower(v_user); end if;
  if v_rem !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Confira o e-mail do remetente.' using errcode = '22023'; end if;
  if v_resp <> '' and v_resp !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Confira o e-mail de resposta.' using errcode = '22023'; end if;

  insert into public.email_gateway (id) values ('principal') on conflict (id) do nothing;
  update public.email_gateway set
    provedor        = left(coalesce(p ->> 'provedor', 'outro'), 20),
    host            = left(v_host, 200),
    porta           = v_porta,
    seguranca       = v_seg,
    usuario         = left(v_user, 200),
    -- senha em branco mantém a atual; "remover_senha" apaga
    senha           = case when coalesce((p ->> 'remover_senha')::boolean, false) then null
                           when v_senha <> '' then left(v_senha, 300) else senha end,
    remetente_nome  = left(btrim(coalesce(p ->> 'remetente_nome', '')), 120),
    remetente_email = left(v_rem, 200),
    responder_para  = left(v_resp, 200),
    ativo           = coalesce((p ->> 'ativo')::boolean, false),
    atualizado_em   = now(),
    atualizado_por  = auth.uid()
  where id = 'principal'
  returning * into r;
  return jsonb_build_object('host', r.host, 'porta', r.porta, 'seguranca', r.seguranca, 'usuario', r.usuario, 'tem_senha', r.tem_senha,
    'remetente_nome', r.remetente_nome, 'remetente_email', r.remetente_email, 'responder_para', r.responder_para, 'ativo', r.ativo, 'provedor', r.provedor);
end $$;
revoke all on function public.email_gateway_salvar(jsonb) from public, anon;
grant execute on function public.email_gateway_salvar(jsonb) to authenticated;

-- ---------- Templates ----------
create table if not exists public.email_templates (
  id             text primary key,
  data           jsonb not null default '{}'::jsonb,
  atualizado_em  timestamptz not null default now(),
  atualizado_por uuid default auth.uid()
);
alter table public.email_templates enable row level security;
create unique index if not exists email_templates_chave_idx on public.email_templates (lower(data ->> 'chave'));

create or replace function public.email_templates_guarda() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  d jsonb := coalesce(new.data, '{}'::jsonb);
  nome text := btrim(coalesce(d ->> 'nome', ''));
  chave text := lower(btrim(coalesce(d ->> 'chave', '')));
  assunto text := btrim(coalesce(d ->> 'assunto', ''));
begin
  if nome = '' then raise exception 'Informe o nome do template.' using errcode = '22023'; end if;
  if chave !~ '^[a-z0-9][a-z0-9_-]{1,59}$' then raise exception 'A chave deve ter de 2 a 60 letras minúsculas, números, - ou _ (ex.: boas-vindas).' using errcode = '22023'; end if;
  if assunto = '' then raise exception 'Informe o assunto do e-mail.' using errcode = '22023'; end if;
  if btrim(coalesce(d ->> 'corpo', '')) = '' then raise exception 'Escreva a mensagem do e-mail.' using errcode = '22023'; end if;
  if char_length(d ->> 'corpo') > 100000 then raise exception 'A mensagem é grande demais.' using errcode = '22023'; end if;
  if exists (select 1 from public.email_templates t where lower(t.data ->> 'chave') = chave and t.id <> new.id) then
    raise exception 'Já existe um template com a chave "%".', chave using errcode = '23505';
  end if;
  new.data := d || jsonb_build_object('nome', left(nome, 120), 'chave', chave, 'assunto', left(assunto, 300),
    'formato', case when d ->> 'formato' = 'html' then 'html' else 'texto' end,
    'ativo', coalesce((d ->> 'ativo')::boolean, true));
  new.atualizado_em := now();
  new.atualizado_por := auth.uid();
  return new;
end $$;
drop trigger if exists email_templates_guarda on public.email_templates;
create trigger email_templates_guarda before insert or update on public.email_templates
  for each row execute function public.email_templates_guarda();

drop policy if exists email_templates_master on public.email_templates;
create policy email_templates_master on public.email_templates for all to authenticated
  using (public.e_master()) with check (public.e_master());
revoke all on public.email_templates from anon;
grant select, insert, update, delete on public.email_templates to authenticated;

-- ---------- Registro de envios ----------
create table if not exists public.email_envios (
  id        uuid primary key default gen_random_uuid(),
  criado_em timestamptz not null default now(),
  para      text not null,
  assunto   text not null default '',
  template  text,
  origem    text not null default 'tela',
  status    text not null check (status in ('ok', 'erro')),
  erro      text,
  por       uuid
);
alter table public.email_envios enable row level security;
create index if not exists email_envios_criado_idx on public.email_envios (criado_em desc);
drop policy if exists email_envios_ler on public.email_envios;
create policy email_envios_ler on public.email_envios for select to authenticated using (public.e_master());
revoke all on public.email_envios from anon, authenticated;
grant select on public.email_envios to authenticated;
