-- =====================================================================
-- Kanban: anexos nos cards (com visualização)
-- - Arquivos no armazenamento privado "kanban", em <id do card>/<arquivo>.
--   Até 20 MB cada; imagens, PDF, Word, Excel, PowerPoint, texto e CSV.
-- - Só quem pode ver o card (envolvidos ou quem vê todos os cards) abre os
--   arquivos; quem pode mexer no card anexa.
-- - A lista de anexos do card (data.anexos) só muda pelas funções abaixo:
--   o servidor confere o arquivo, grava quem anexou e quando, e avisa os
--   envolvidos no sininho ("anexou um arquivo").
-- - Remove o anexo: quem anexou, quem criou o card ou quem vê todos os cards.
-- Pode ser rodada mais de uma vez sem efeito colateral.
-- =====================================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('kanban', 'kanban', false, 20971520, array[
  'image/jpeg', 'image/png', 'image/gif', 'image/webp', 'image/heic', 'image/heif',
  'application/pdf', 'text/plain', 'text/csv',
  'application/msword', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'application/vnd.ms-excel', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'application/vnd.ms-powerpoint', 'application/vnd.openxmlformats-officedocument.presentationml.presentation'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

-- Quem pode abrir / anexar arquivos do card
create or replace function public.kanban_ve_card(p_card text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.kanban_cards k where k.id = p_card
                 and public.ativo() and (public.pode('kanbanTodos') or public.kanban_envolvido(k.data)));
$$;
create or replace function public.kanban_criador_card(p_card text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.kanban_cards k where k.id = p_card and k.data ->> 'criadoPor' = auth.uid()::text);
$$;
grant execute on function public.kanban_ve_card(text), public.kanban_criador_card(text) to authenticated;

drop policy if exists kanban_anexos_ler on storage.objects;
drop policy if exists kanban_anexos_enviar on storage.objects;
drop policy if exists kanban_anexos_apagar on storage.objects;
create policy kanban_anexos_ler on storage.objects for select to authenticated
  using (bucket_id = 'kanban' and public.kanban_ve_card((storage.foldername(name))[1]));
create policy kanban_anexos_enviar on storage.objects for insert to authenticated
  with check (bucket_id = 'kanban' and public.pode('kanban') and public.kanban_ve_card((storage.foldername(name))[1]));
create policy kanban_anexos_apagar on storage.objects for delete to authenticated
  using (bucket_id = 'kanban' and (owner = auth.uid() or public.pode('kanbanTodos') or public.kanban_criador_card((storage.foldername(name))[1])));

-- ---------- Cards: a lista de anexos passa a ser protegida ----------
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
                                 'criadoTs', agora, 'comentarios', '[]'::jsonb, 'anexos', '[]'::jsonb);
    hist := jsonb_build_array(jsonb_build_object('ts', agora, 'autorId', auth.uid(), 'autorNome', me.nome, 'acao', 'criou', 'para', col, 'paraNome', c ->> 'nome'));
  else
    d := d || jsonb_build_object('criadoPor', o -> 'criadoPor', 'criadoNome', o -> 'criadoNome', 'criadoTs', o -> 'criadoTs');
    if coalesce(current_setting('kanban.comentarios', true), '') <> '1' then
      d := d || jsonb_build_object('comentarios', coalesce(o -> 'comentarios', '[]'::jsonb));
    end if;
    -- anexos só mudam pelas funções kanban_anexo_registrar / kanban_anexo_remover
    if coalesce(current_setting('kanban.anexos', true), '') <> '1' then
      d := d || jsonb_build_object('anexos', coalesce(o -> 'anexos', '[]'::jsonb));
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
  antes text[]; novos text[]; saiu text[]; com jsonb; nc int; oc int; na int; oa int;
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
  na := coalesce(jsonb_array_length(case when jsonb_typeof(d -> 'anexos') = 'array' then d -> 'anexos' end), 0);
  oa := coalesce(jsonb_array_length(case when jsonb_typeof(o -> 'anexos') = 'array' then o -> 'anexos' end), 0);
  if coalesce((nt ->> 'anexo')::boolean, true) and na > oa then
    perform public.kanban_avisar(todos, 'anexo', quem || ' anexou um arquivo em ' || tit, d -> 'anexos' -> (na - 1) ->> 'nome', cid);
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

-- ---------- Registrar e remover anexos ----------
create or replace function public.kanban_anexo_registrar(p_id text, p_anexo jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  k public.kanban_cards; me public.perfis; a jsonb;
  caminho text := coalesce(p_anexo ->> 'path', '');
  nome text := btrim(coalesce(p_anexo ->> 'nome', ''));
begin
  k := public.kanban_acesso(p_id);
  if caminho not like p_id || '/%' or caminho like '%..%' then raise exception 'Arquivo inválido.' using errcode = '22023'; end if;
  if not exists (select 1 from storage.objects where bucket_id = 'kanban' and name = caminho) then
    raise exception 'O arquivo não chegou ao servidor. Tente anexar de novo.' using errcode = '22023';
  end if;
  if jsonb_array_length(case when jsonb_typeof(k.data -> 'anexos') = 'array' then k.data -> 'anexos' else '[]'::jsonb end) >= 30 then
    raise exception 'Um card pode ter até 30 anexos.' using errcode = '22023';
  end if;
  if nome = '' then nome := regexp_replace(caminho, '^.*/', ''); end if;
  select * into me from public.perfis where id = auth.uid();
  a := jsonb_build_object('id', gen_random_uuid()::text, 'nome', left(nome, 160), 'path', caminho,
    'tipo', left(coalesce(p_anexo ->> 'tipo', ''), 120), 'tamanho', coalesce((p_anexo ->> 'tamanho')::bigint, 0),
    'porId', auth.uid()::text, 'porNome', me.nome, 'ts', (extract(epoch from now()) * 1000)::bigint);
  perform set_config('kanban.anexos', '1', true);
  update public.kanban_cards set data = jsonb_set(data, '{anexos}', (case when jsonb_typeof(data -> 'anexos') = 'array' then data -> 'anexos' else '[]'::jsonb end) || a)
   where id = p_id;
  perform set_config('kanban.anexos', '', true);
  return a;
end $$;

create or replace function public.kanban_anexo_remover(p_id text, p_anexo text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare k public.kanban_cards; a jsonb;
begin
  k := public.kanban_acesso(p_id);
  select x into a from jsonb_array_elements(case when jsonb_typeof(k.data -> 'anexos') = 'array' then k.data -> 'anexos' else '[]'::jsonb end) x where x ->> 'id' = p_anexo;
  if a is null then return null; end if;
  if a ->> 'porId' is distinct from auth.uid()::text and k.data ->> 'criadoPor' is distinct from auth.uid()::text and not public.pode('kanbanTodos') then
    raise exception 'Só quem anexou ou quem criou o card pode remover este arquivo.' using errcode = '42501';
  end if;
  perform set_config('kanban.anexos', '1', true);
  update public.kanban_cards set data = jsonb_set(data, '{anexos}',
    coalesce((select jsonb_agg(x) from jsonb_array_elements(data -> 'anexos') x where x ->> 'id' <> p_anexo), '[]'::jsonb))
   where id = p_id;
  perform set_config('kanban.anexos', '', true);
  return a; -- a tela apaga o arquivo do armazenamento com o "path" devolvido
end $$;

revoke all on function public.kanban_anexo_registrar(text, jsonb), public.kanban_anexo_remover(text, text) from public, anon;
grant execute on function public.kanban_anexo_registrar(text, jsonb), public.kanban_anexo_remover(text, text) to authenticated;
