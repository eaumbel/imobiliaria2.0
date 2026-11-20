-- =====================================================================
-- Kanban + notificações
--
-- kanban_cards: um card por linha (campos em data):
--   titulo, descricao, coluna (id da coluna), ordem, prioridade
--   (baixa | media | alta | urgente), prazo (AAAA-MM-DD), responsavelId,
--   participantes [ids], etiquetas [nomes], checklist [{id, texto, feito}],
--   arquivado. O servidor grava e protege: criadoPor/criadoNome/criadoTs,
--   comentarios (só pelas funções de comentário), historico, concluidoTs.
--
-- Configuração (tabela config, id = 'kanban', só o Master altera):
--   colunas [{id, nome, cor, limite, final, exige:{responsavel, prazo,
--   descricao, checklist}}], fluxo ('livre' | 'sequencial' | 'personalizado'),
--   voltar (sequencial: pode voltar a etapas anteriores), transicoes
--   {coluna: [colunas permitidas]}, gestorLivre (Master/Coordenador pulam
--   o passo a passo), etiquetas [{nome, cor}], notificar {tipo: true/false}.
--   O passo a passo, o limite por coluna e as exigências são conferidos
--   aqui no banco, não só na tela.
--
-- notificacoes: avisos para quem está envolvido no card (quem criou,
--   responsável e participantes). São criadas só pelo servidor; cada
--   usuário lê, marca como lida e apaga apenas as próprias.
--
-- Permissões novas: 'kanban' (menu; todos por padrão) e 'kanbanTodos'
--   (ver e mexer em todos os cards; Master e Coordenador por padrão).
--   Sem 'kanbanTodos', cada um vê os cards em que está envolvido.
-- =====================================================================

create table if not exists public.kanban_cards (
  id             text primary key,
  data           jsonb not null default '{}'::jsonb,
  atualizado_em  timestamptz not null default now(),
  atualizado_por uuid default auth.uid()
);
alter table public.kanban_cards enable row level security;
create index if not exists kanban_cards_coluna_idx on public.kanban_cards ((data ->> 'coluna'));

create table if not exists public.notificacoes (
  id         uuid primary key default gen_random_uuid(),
  usuario    uuid not null references public.perfis(id) on delete cascade,
  tipo       text not null,
  titulo     text not null,
  texto      text not null default '',
  card_id    text,
  ator       uuid,
  ator_nome  text,
  lida       boolean not null default false,
  criado_em  timestamptz not null default now()
);
alter table public.notificacoes enable row level security;
create index if not exists notificacoes_usuario_idx on public.notificacoes (usuario, criado_em desc);

-- ---------- Permissões: menu Kanban para todos; ver todos os cards para Master/Coordenador ----------
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
    return p in ('diario','relatorios','agenda','conhecimento','treinamentos','ponto','vendas','contratos','angariacoes','kanban','metas','equipe','conteudo','operacaoTodos','kanbanTodos');
  end if;
  return p in ('diario','relatorios','agenda','conhecimento','treinamentos','ponto','vendas','contratos','angariacoes','kanban');
end $$;

-- ---------- Configuração (com colunas padrão enquanto o Master não configurar) ----------
create or replace function public.kanban_cfg() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  c jsonb;
begin
  select data into c from public.config where id = 'kanban';
  c := coalesce(c, '{}'::jsonb);
  if jsonb_typeof(c -> 'colunas') is distinct from 'array' or jsonb_array_length(c -> 'colunas') = 0 then
    c := c || jsonb_build_object('colunas', jsonb_build_array(
      jsonb_build_object('id', 'afazer', 'nome', 'A fazer'),
      jsonb_build_object('id', 'andamento', 'nome', 'Em andamento'),
      jsonb_build_object('id', 'revisao', 'nome', 'Em revisão'),
      jsonb_build_object('id', 'concluido', 'nome', 'Concluído', 'final', true)));
  end if;
  return c;
end $$;

create or replace function public.kanban_coluna(cfg jsonb, col text) returns jsonb
language sql immutable as $$
  select x from jsonb_array_elements(cfg -> 'colunas') x where x ->> 'id' = col limit 1;
$$;

-- Quem está envolvido no card: quem criou, responsável e participantes
create or replace function public.kanban_envolvido(d jsonb) returns boolean
language sql stable as $$
  select auth.uid() is not null and (
    coalesce(d ->> 'criadoPor', '') = auth.uid()::text
    or coalesce(d ->> 'responsavelId', '') = auth.uid()::text
    or (jsonb_typeof(d -> 'participantes') = 'array' and (d -> 'participantes') ? auth.uid()::text));
$$;

create or replace function public.kanban_pessoas(d jsonb) returns text[]
language sql immutable as $$
  select coalesce(array_agg(distinct p), '{}') from (
    select d ->> 'criadoPor' as p
    union all select d ->> 'responsavelId'
    union all select x from jsonb_array_elements_text(case when jsonb_typeof(d -> 'participantes') = 'array' then d -> 'participantes' else '[]'::jsonb end) x
  ) s where coalesce(p, '') <> '';
$$;

-- Passo a passo: o card pode ir da coluna "de" para "para"?
create or replace function public.kanban_transicao_ok(cfg jsonb, de text, para text) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare
  i_de int; i_para int;
  fluxo text := coalesce(cfg ->> 'fluxo', 'livre');
begin
  if coalesce(de, '') = '' or de = para then return true; end if;
  if coalesce((cfg ->> 'gestorLivre')::boolean, false) and public.pode('kanbanTodos') then return true; end if;
  select i into i_de from jsonb_array_elements(cfg -> 'colunas') with ordinality t(x, i) where x ->> 'id' = de;
  select i into i_para from jsonb_array_elements(cfg -> 'colunas') with ordinality t(x, i) where x ->> 'id' = para;
  if i_de is null then return true; end if; -- a coluna de origem foi removida da configuração
  if fluxo = 'sequencial' then
    return i_para = i_de + 1 or (i_para < i_de and coalesce((cfg ->> 'voltar')::boolean, true));
  end if;
  if fluxo = 'personalizado' then
    return jsonb_typeof(cfg -> 'transicoes' -> de) = 'array' and (cfg -> 'transicoes' -> de) ? para;
  end if;
  return true;
end $$;

-- ---------- Validação e carimbo de cada card ----------
create or replace function public.kanban_guarda() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  d     jsonb := coalesce(new.data, '{}'::jsonb);
  o     jsonb := case when tg_op = 'UPDATE' then old.data else null end;
  cfg   jsonb := public.kanban_cfg();
  tit   text  := btrim(coalesce(d ->> 'titulo', ''));
  col   text  := coalesce(d ->> 'coluna', '');
  de    text  := case when tg_op = 'UPDATE' then coalesce(o ->> 'coluna', '') else null end;
  resp  text  := btrim(coalesce(d ->> 'responsavelId', ''));
  resp_antes text := case when tg_op = 'UPDATE' then coalesce(o ->> 'responsavelId', '') else '' end;
  arq   boolean := coalesce((d ->> 'arquivado')::boolean, false);
  arq_antes boolean := case when tg_op = 'UPDATE' then coalesce((o ->> 'arquivado')::boolean, false) else false end;
  agora bigint := (extract(epoch from now()) * 1000)::bigint;
  c jsonb; c_de jsonb; ex jsonb; lim int; n int; parts jsonb := '[]'::jsonb; p text; pr public.perfis; me public.perfis;
  hist jsonb; chk jsonb := '[]'::jsonb; it jsonb; etq jsonb := '[]'::jsonb; entrando boolean;
begin
  select * into me from public.perfis where id = auth.uid();

  if tit = '' then raise exception 'Informe o título do card.' using errcode = '22023'; end if;
  if char_length(tit) > 200 then raise exception 'O título pode ter até 200 caracteres.' using errcode = '22023'; end if;
  if char_length(coalesce(d ->> 'descricao', '')) > 10000 then raise exception 'A descrição pode ter até 10.000 caracteres.' using errcode = '22023'; end if;

  -- coluna
  if col = '' then col := cfg -> 'colunas' -> 0 ->> 'id'; end if;
  c := public.kanban_coluna(cfg, col);
  if c is null then raise exception 'A coluna escolhida não existe mais. Atualize a página.' using errcode = '22023'; end if;

  -- prioridade e prazo
  if coalesce(d ->> 'prioridade', '') not in ('baixa', 'media', 'alta', 'urgente') then d := d || '{"prioridade": "media"}'::jsonb; end if;
  if coalesce(d ->> 'prazo', '') <> '' then
    if d ->> 'prazo' !~ '^\d{4}-\d{2}-\d{2}$' then raise exception 'Prazo inválido.' using errcode = '22023'; end if;
    begin perform (d ->> 'prazo')::date; exception when others then raise exception 'Prazo inválido.' using errcode = '22023'; end;
  else d := d - 'prazo'; end if;

  -- responsável (precisa existir e estar ativo quando escolhido)
  if resp <> '' then
    if resp !~ '^[0-9a-fA-F-]{36}$' then raise exception 'Responsável inválido.' using errcode = '22023'; end if;
    select * into pr from public.perfis where id = resp::uuid;
    if pr.id is null then raise exception 'Responsável não encontrado.' using errcode = '22023'; end if;
    if not pr.ativo and resp is distinct from resp_antes then raise exception 'O responsável escolhido está inativo.' using errcode = '22023'; end if;
    d := d || jsonb_build_object('responsavelId', resp, 'responsavelNome', pr.nome);
  else
    d := d - 'responsavelId' - 'responsavelNome';
  end if;

  -- participantes (sem repetir e sem o responsável)
  if jsonb_typeof(d -> 'participantes') = 'array' then
    for p in select distinct x from jsonb_array_elements_text(d -> 'participantes') x loop
      if p ~ '^[0-9a-fA-F-]{36}$' and p <> resp
         and exists (select 1 from public.perfis f where f.id = p::uuid
                     and (f.ativo or (jsonb_typeof(o -> 'participantes') = 'array' and (o -> 'participantes') ? p))) then
        parts := parts || to_jsonb(p);
      end if;
    end loop;
  end if;
  if jsonb_array_length(parts) > 30 then raise exception 'Um card pode ter até 30 participantes.' using errcode = '22023'; end if;

  -- checklist e etiquetas
  if jsonb_typeof(d -> 'checklist') = 'array' then
    for it in select x from jsonb_array_elements(d -> 'checklist') x loop
      if jsonb_typeof(it) = 'object' and btrim(coalesce(it ->> 'texto', '')) <> '' then
        chk := chk || jsonb_build_object('id', coalesce(nullif(it ->> 'id', ''), md5(random()::text)), 'texto', left(btrim(it ->> 'texto'), 300),
                                         'feito', coalesce((it ->> 'feito')::boolean, false));
      end if;
    end loop;
  end if;
  if jsonb_array_length(chk) > 100 then raise exception 'O checklist pode ter até 100 itens.' using errcode = '22023'; end if;
  if jsonb_typeof(d -> 'etiquetas') = 'array' then
    select coalesce(jsonb_agg(distinct left(btrim(x), 40)), '[]'::jsonb) into etq from jsonb_array_elements_text(d -> 'etiquetas') x where btrim(x) <> '';
  end if;
  if jsonb_array_length(etq) > 15 then raise exception 'Um card pode ter até 15 etiquetas.' using errcode = '22023'; end if;

  d := d || jsonb_build_object('titulo', tit, 'coluna', col, 'participantes', parts, 'checklist', chk, 'etiquetas', etq, 'arquivado', arq);

  -- campos que só o servidor grava
  if tg_op = 'INSERT' then
    d := d || jsonb_build_object('criadoPor', coalesce(auth.uid()::text, d ->> 'criadoPor', ''), 'criadoNome', coalesce(me.nome, d ->> 'criadoNome', ''),
                                 'criadoTs', agora, 'comentarios', '[]'::jsonb);
    hist := jsonb_build_array(jsonb_build_object('ts', agora, 'autorId', auth.uid(), 'autorNome', me.nome, 'acao', 'criou', 'para', col, 'paraNome', c ->> 'nome'));
  else
    d := d || jsonb_build_object('criadoPor', o -> 'criadoPor', 'criadoNome', o -> 'criadoNome', 'criadoTs', o -> 'criadoTs');
    if coalesce(current_setting('kanban.comentarios', true), '') <> '1' then
      d := d || jsonb_build_object('comentarios', coalesce(o -> 'comentarios', '[]'::jsonb));
    end if;
    hist := case when jsonb_typeof(o -> 'historico') = 'array' then o -> 'historico' else '[]'::jsonb end;
  end if;

  -- passo a passo, limite por coluna e exigências para entrar na coluna
  entrando := tg_op = 'INSERT' or col is distinct from de or (arq_antes and not arq);
  if entrando and not arq then
    if tg_op = 'UPDATE' and col is distinct from de and not public.kanban_transicao_ok(cfg, de, col) then
      c_de := public.kanban_coluna(cfg, de);
      raise exception 'Pelo passo a passo configurado, o card não pode ir de "%" para "%".', coalesce(c_de ->> 'nome', de), c ->> 'nome' using errcode = '22023';
    end if;
    lim := coalesce(nullif(c ->> 'limite', '')::int, 0);
    if lim > 0 then
      select count(*) into n from public.kanban_cards k
       where k.data ->> 'coluna' = col and not coalesce((k.data ->> 'arquivado')::boolean, false) and k.id <> new.id;
      if n >= lim then raise exception 'A coluna "%" já está no limite de % card(s).', c ->> 'nome', lim using errcode = '22023'; end if;
    end if;
    ex := case when jsonb_typeof(c -> 'exige') = 'object' then c -> 'exige' else '{}'::jsonb end;
    if coalesce((ex ->> 'responsavel')::boolean, false) and resp = '' then
      raise exception 'Para entrar em "%", o card precisa ter um responsável.', c ->> 'nome' using errcode = '22023'; end if;
    if coalesce((ex ->> 'prazo')::boolean, false) and coalesce(d ->> 'prazo', '') = '' then
      raise exception 'Para entrar em "%", o card precisa ter um prazo.', c ->> 'nome' using errcode = '22023'; end if;
    if coalesce((ex ->> 'descricao')::boolean, false) and btrim(coalesce(d ->> 'descricao', '')) = '' then
      raise exception 'Para entrar em "%", o card precisa ter uma descrição.', c ->> 'nome' using errcode = '22023'; end if;
    if coalesce((ex ->> 'checklist')::boolean, false) and exists (select 1 from jsonb_array_elements(chk) x where not (x ->> 'feito')::boolean) then
      raise exception 'Para entrar em "%", todos os itens do checklist precisam estar concluídos.', c ->> 'nome' using errcode = '22023'; end if;
  end if;

  -- histórico
  if tg_op = 'UPDATE' then
    if col is distinct from de then
      c_de := public.kanban_coluna(cfg, de);
      hist := hist || jsonb_build_object('ts', agora, 'autorId', auth.uid(), 'autorNome', me.nome, 'acao', 'moveu', 'de', de, 'deNome', coalesce(c_de ->> 'nome', de), 'para', col, 'paraNome', c ->> 'nome');
    end if;
    if resp is distinct from resp_antes then
      hist := hist || jsonb_build_object('ts', agora, 'autorId', auth.uid(), 'autorNome', me.nome, 'acao', 'responsavel', 'paraNome', coalesce(pr.nome, ''));
    end if;
    if arq <> arq_antes then
      hist := hist || jsonb_build_object('ts', agora, 'autorId', auth.uid(), 'autorNome', me.nome, 'acao', case when arq then 'arquivou' else 'desarquivou' end);
    end if;
    if jsonb_array_length(hist) > 200 then
      select jsonb_agg(x order by i) into hist from jsonb_array_elements(hist) with ordinality t(x, i) where i > jsonb_array_length(hist) - 200;
    end if;
  end if;
  d := d || jsonb_build_object('historico', hist);

  -- data de conclusão: ao entrar numa coluna final
  if coalesce((c ->> 'final')::boolean, false) then
    if tg_op = 'INSERT' or col is distinct from de or not (o ? 'concluidoTs') then d := d || jsonb_build_object('concluidoTs', agora);
    else d := d || jsonb_build_object('concluidoTs', o -> 'concluidoTs'); end if;
  else
    d := d - 'concluidoTs';
  end if;

  new.data := d;
  new.atualizado_em := now();
  new.atualizado_por := auth.uid();
  return new;
end $$;

drop trigger if exists kanban_guarda on public.kanban_cards;
create trigger kanban_guarda before insert or update on public.kanban_cards
  for each row execute function public.kanban_guarda();

-- ---------- Notificações ----------
create or replace function public.kanban_avisar(us text[], p_tipo text, p_titulo text, p_texto text, p_card text) returns void
language plpgsql security definer set search_path = public as $$
declare
  ator uuid := auth.uid();
  ator_nome text := coalesce((select nome from public.perfis where id = auth.uid()), 'Sistema');
  u text;
begin
  if us is null then return; end if;
  for u in select distinct x from unnest(us) x loop
    if coalesce(u, '') = '' or u = coalesce(ator::text, '') then continue; end if;
    if not exists (select 1 from public.perfis where id::text = u and ativo) then continue; end if;
    insert into public.notificacoes (usuario, tipo, titulo, texto, card_id, ator, ator_nome)
      values (u::uuid, p_tipo, left(p_titulo, 200), left(coalesce(p_texto, ''), 500), p_card, ator, ator_nome);
    -- limpeza: avisos lidos com mais de 90 dias
    delete from public.notificacoes where usuario = u::uuid and lida and criado_em < now() - interval '90 days';
  end loop;
end $$;
revoke all on function public.kanban_avisar(text[], text, text, text, text) from public, anon, authenticated;

create or replace function public.kanban_notificar() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  d   jsonb := case when tg_op = 'DELETE' then old.data else new.data end;
  o   jsonb := case when tg_op = 'UPDATE' then old.data else null end;
  cid text  := case when tg_op = 'DELETE' then old.id else new.id end;
  cfg jsonb := public.kanban_cfg();
  nt  jsonb := case when jsonb_typeof(cfg -> 'notificar') = 'object' then cfg -> 'notificar' else '{}'::jsonb end;
  quem text := coalesce((select nome from public.perfis where id = auth.uid()), 'Alguém');
  tit text := '“' || coalesce(d ->> 'titulo', 'card') || '”';
  todos text[] := public.kanban_pessoas(d);
  antes text[]; novos text[]; saiu text[]; com jsonb; nc int; oc int;
  resp text := coalesce(d ->> 'responsavelId', ''); resp_antes text;
begin
  if tg_op = 'INSERT' then
    if coalesce((nt ->> 'atribuicao')::boolean, true) then
      if resp <> '' then perform public.kanban_avisar(array[resp], 'atribuicao', 'Você é o responsável por ' || tit, quem || ' criou o card e colocou você como responsável.', cid); end if;
      perform public.kanban_avisar(array(select jsonb_array_elements_text(coalesce(d -> 'participantes', '[]'::jsonb))), 'atribuicao',
        'Você foi incluído em ' || tit, quem || ' criou o card e incluiu você como participante.', cid);
    end if;
    return new;
  end if;

  if tg_op = 'DELETE' then
    if coalesce((nt ->> 'exclusao')::boolean, true) then
      perform public.kanban_avisar(todos, 'exclusao', 'Card excluído: ' || tit, quem || ' excluiu o card.', null);
    end if;
    return old;
  end if;

  -- UPDATE
  antes := public.kanban_pessoas(o);
  resp_antes := coalesce(o ->> 'responsavelId', '');
  if coalesce((nt ->> 'atribuicao')::boolean, true) then
    if resp <> '' and resp is distinct from resp_antes then
      perform public.kanban_avisar(array[resp], 'atribuicao', 'Você é o responsável por ' || tit, quem || ' colocou você como responsável pelo card.', cid);
    end if;
    novos := array(select x from jsonb_array_elements_text(coalesce(d -> 'participantes', '[]'::jsonb)) x
                   where not (coalesce(o -> 'participantes', '[]'::jsonb) ? x) and x <> resp_antes);
    perform public.kanban_avisar(novos, 'atribuicao', 'Você foi incluído em ' || tit, quem || ' incluiu você como participante do card.', cid);
    saiu := array(select x from unnest(antes) x where not (x = any(todos)));
    perform public.kanban_avisar(saiu, 'atribuicao', 'Você saiu de ' || tit, quem || ' tirou você do card.', cid);
  end if;
  if coalesce((nt ->> 'movimento')::boolean, true) and (d ->> 'coluna') is distinct from (o ->> 'coluna') then
    perform public.kanban_avisar(todos, 'movimento', tit || ' mudou de etapa',
      quem || ' moveu de “' || coalesce(public.kanban_coluna(cfg, o ->> 'coluna') ->> 'nome', o ->> 'coluna') || '” para “' || coalesce(public.kanban_coluna(cfg, d ->> 'coluna') ->> 'nome', d ->> 'coluna') || '”.', cid);
  end if;
  nc := coalesce(jsonb_array_length(case when jsonb_typeof(d -> 'comentarios') = 'array' then d -> 'comentarios' end), 0);
  oc := coalesce(jsonb_array_length(case when jsonb_typeof(o -> 'comentarios') = 'array' then o -> 'comentarios' end), 0);
  if coalesce((nt ->> 'comentario')::boolean, true) and nc > oc then
    com := d -> 'comentarios' -> (nc - 1);
    perform public.kanban_avisar(todos, 'comentario', quem || ' comentou em ' || tit, left(com ->> 'texto', 160), cid);
  end if;
  if coalesce((nt ->> 'prazo')::boolean, true) and coalesce(d ->> 'prazo', '') is distinct from coalesce(o ->> 'prazo', '') then
    perform public.kanban_avisar(todos, 'prazo', 'Prazo alterado em ' || tit,
      case when coalesce(d ->> 'prazo', '') = '' then quem || ' removeu o prazo.' else quem || ' mudou o prazo para ' || to_char((d ->> 'prazo')::date, 'DD/MM/YYYY') || '.' end, cid);
  end if;
  if coalesce((nt ->> 'movimento')::boolean, true) and coalesce((d ->> 'arquivado')::boolean, false) is distinct from coalesce((o ->> 'arquivado')::boolean, false) then
    perform public.kanban_avisar(todos, 'movimento', tit || case when (d ->> 'arquivado')::boolean then ' foi arquivado' else ' voltou ao quadro' end,
      quem || case when (d ->> 'arquivado')::boolean then ' arquivou o card.' else ' tirou o card do arquivo.' end, cid);
  end if;
  return new;
end $$;

drop trigger if exists kanban_notificar on public.kanban_cards;
create trigger kanban_notificar after insert or update or delete on public.kanban_cards
  for each row execute function public.kanban_notificar();

-- ---------- Ações atômicas: mover e comentar (sem sobrescrever edições de outras pessoas) ----------
create or replace function public.kanban_acesso(p_id text) returns public.kanban_cards
language plpgsql security definer set search_path = public as $$
declare k public.kanban_cards;
begin
  if not public.pode('kanban') then raise exception 'Seu acesso não permite esta ação.' using errcode = '42501'; end if;
  select * into k from public.kanban_cards where id = p_id for update;
  if k.id is null or not (public.pode('kanbanTodos') or public.kanban_envolvido(k.data)) then
    raise exception 'Card não encontrado.' using errcode = '22023';
  end if;
  return k;
end $$;
revoke all on function public.kanban_acesso(text) from public, anon, authenticated;

create or replace function public.kanban_mover(p_id text, p_coluna text, p_ordem double precision) returns jsonb
language plpgsql security definer set search_path = public as $$
declare k public.kanban_cards;
begin
  k := public.kanban_acesso(p_id);
  update public.kanban_cards set data = data || jsonb_build_object('coluna', p_coluna, 'ordem', p_ordem)
   where id = p_id returning * into k;
  return k.data;
end $$;

create or replace function public.kanban_comentar(p_id text, p_texto text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  k public.kanban_cards; me public.perfis; t text := btrim(coalesce(p_texto, '')); com jsonb;
begin
  if t = '' then raise exception 'Escreva o comentário.' using errcode = '22023'; end if;
  if char_length(t) > 4000 then raise exception 'O comentário pode ter até 4.000 caracteres.' using errcode = '22023'; end if;
  k := public.kanban_acesso(p_id);
  select * into me from public.perfis where id = auth.uid();
  com := jsonb_build_object('id', gen_random_uuid()::text, 'autorId', me.id::text, 'autorNome', me.nome, 'texto', t, 'ts', (extract(epoch from now()) * 1000)::bigint);
  perform set_config('kanban.comentarios', '1', true);
  update public.kanban_cards set data = jsonb_set(data, '{comentarios}', (case when jsonb_typeof(data -> 'comentarios') = 'array' then data -> 'comentarios' else '[]'::jsonb end) || com)
   where id = p_id;
  perform set_config('kanban.comentarios', '', true);
  return com;
end $$;

create or replace function public.kanban_comentario_excluir(p_id text, p_comentario text) returns void
language plpgsql security definer set search_path = public as $$
declare k public.kanban_cards; c jsonb;
begin
  k := public.kanban_acesso(p_id);
  select x into c from jsonb_array_elements(coalesce(k.data -> 'comentarios', '[]'::jsonb)) x where x ->> 'id' = p_comentario;
  if c is null then return; end if;
  if c ->> 'autorId' is distinct from auth.uid()::text and not public.pode('kanbanTodos') then
    raise exception 'Só quem escreveu pode excluir este comentário.' using errcode = '42501';
  end if;
  perform set_config('kanban.comentarios', '1', true);
  update public.kanban_cards set data = jsonb_set(data, '{comentarios}',
    coalesce((select jsonb_agg(x) from jsonb_array_elements(data -> 'comentarios') x where x ->> 'id' <> p_comentario), '[]'::jsonb))
   where id = p_id;
  perform set_config('kanban.comentarios', '', true);
end $$;

revoke all on function public.kanban_mover(text, text, double precision), public.kanban_comentar(text, text), public.kanban_comentario_excluir(text, text) from public, anon;
grant execute on function public.kanban_mover(text, text, double precision), public.kanban_comentar(text, text), public.kanban_comentario_excluir(text, text) to authenticated;

-- ---------- Regras de acesso ----------
drop policy if exists kanban_ler on public.kanban_cards;
drop policy if exists kanban_criar on public.kanban_cards;
drop policy if exists kanban_editar on public.kanban_cards;
drop policy if exists kanban_apagar on public.kanban_cards;
create policy kanban_ler on public.kanban_cards for select to authenticated
  using (public.ativo() and (public.pode('kanbanTodos') or public.kanban_envolvido(data)));
create policy kanban_criar on public.kanban_cards for insert to authenticated
  with check (public.pode('kanban'));
create policy kanban_editar on public.kanban_cards for update to authenticated
  using (public.pode('kanban') and (public.pode('kanbanTodos') or public.kanban_envolvido(data)))
  with check (public.pode('kanban'));
create policy kanban_apagar on public.kanban_cards for delete to authenticated
  using (public.pode('kanbanTodos') or (public.pode('kanban') and public.meu(data, 'criadoPor')));
revoke all on public.kanban_cards from anon;
grant select, insert, update, delete on public.kanban_cards to authenticated;

drop policy if exists notificacoes_ler on public.notificacoes;
drop policy if exists notificacoes_marcar on public.notificacoes;
drop policy if exists notificacoes_apagar on public.notificacoes;
create policy notificacoes_ler on public.notificacoes for select to authenticated using (usuario = auth.uid());
create policy notificacoes_marcar on public.notificacoes for update to authenticated using (usuario = auth.uid()) with check (usuario = auth.uid());
create policy notificacoes_apagar on public.notificacoes for delete to authenticated using (usuario = auth.uid());
-- quem usa o sistema só lê, marca como lida e apaga; quem cria é o servidor
revoke all on public.notificacoes from anon, authenticated;
grant select, delete on public.notificacoes to authenticated;
grant update (lida) on public.notificacoes to authenticated;

-- ---------- Tempo real ----------
do $$
begin
  execute 'alter publication supabase_realtime add table public.kanban_cards';
exception when duplicate_object then null;
end $$;
do $$
begin
  execute 'alter publication supabase_realtime add table public.notificacoes';
exception when duplicate_object then null;
end $$;
