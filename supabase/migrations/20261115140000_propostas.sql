-- =====================================================================
-- Propostas de Compra (Modelos de Contrato)
-- Fluxo e status:
--   aguardando_assinaturas → proponente assina (no sistema)          → aguardando_aceite
--   aguardando_aceite      → proprietário aceita (link público)       → concluido
--   aguardando_aceite      → proprietário faz contra-proposta (link)  → contraproposta
--   contraproposta         → proponente aceita a contra-proposta (link) → concluido
--   (corretor pode cancelar → cancelada)
-- - Data/hora (Brasília) e IP de cada assinatura são carimbados pelo servidor.
-- - O link público usa um código aleatório e vale 5 dias úteis; deixa de valer
--   depois da assinatura, quando a proposta é cancelada ou quando um novo link é gerado.
-- - Assinaturas e arquivos só mudam pelas funções abaixo; nada pode ser alterado depois.
-- Pode ser rodada mais de uma vez sem efeito colateral.
-- =====================================================================

create table if not exists public.propostas (
  id            text primary key,
  data          jsonb not null default '{}'::jsonb,
  status        text not null default 'aguardando_assinaturas'
                check (status in ('aguardando_assinaturas','aguardando_aceite','contraproposta','concluido','cancelada')),
  token         text unique,
  token_expira  timestamptz,
  atualizado_em timestamptz not null default now(),
  atualizado_por uuid default auth.uid()
);
alter table public.propostas enable row level security;

-- ---------- Utilitários ----------
create or replace function public.ip_requisicao() returns text
language plpgsql stable as $$
declare h jsonb;
begin
  begin
    h := nullif(current_setting('request.headers', true), '')::jsonb;
  exception when others then
    h := null;
  end;
  return coalesce(
    nullif(trim(h ->> 'cf-connecting-ip'), ''),
    nullif(trim(split_part(coalesce(h ->> 'x-forwarded-for', ''), ',', 1)), ''),
    nullif(trim(h ->> 'x-real-ip'), ''));
end $$;

-- Carimbo do servidor: data/hora (Brasília) e IP
create or replace function public.carimbo_servidor() returns jsonb
language sql stable as $$
  select jsonb_build_object(
    'assinadoTs',    (extract(epoch from now()) * 1000)::bigint,
    'assinadoLocal', to_char(now() at time zone 'America/Sao_Paulo', 'YYYY-MM-DD"T"HH24:MI:SS'),
    'ip',            public.ip_requisicao());
$$;

-- Fim do 5º dia útil (seg a sex) a partir de hoje, 23:59:59 em Brasília
create or replace function public.fim_dias_uteis(n int) returns timestamptz
language plpgsql stable as $$
declare d date := (now() at time zone 'America/Sao_Paulo')::date; k int := 0;
begin
  while k < n loop
    d := d + 1;
    if extract(isodow from d) < 6 then k := k + 1; end if;
  end loop;
  return (d + time '23:59:59') at time zone 'America/Sao_Paulo';
end $$;

create or replace function public.novo_token() returns text
language sql volatile as $$
  select replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
$$;

-- ---------- Proteção da tabela (gravação direta só para rascunho) ----------
create or replace function public.propostas_guarda() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  protegidos text[] := array['proponenteAss','proprietarioAss','aceiteContraAss','arquivos','contra','acao','proprietario',
                             'corretorId','corretorNome','criadoTs'];
  k text;
begin
  -- Mudanças feitas pelas funções desta migração passam direto
  if coalesce(current_setting('app.proposta_rpc', true), '') = '1' then
    new.atualizado_em := now();
    return new;
  end if;
  new.data := coalesce(new.data, '{}'::jsonb);
  foreach k in array protegidos loop new.data := new.data - k; end loop;
  if tg_op = 'INSERT' then
    new.status := 'aguardando_assinaturas'; new.token := null; new.token_expira := null;
    new.data := new.data || jsonb_build_object(
      'corretorId',   auth.uid()::text,
      'corretorNome', coalesce((select nome from public.perfis where id = auth.uid()), ''),
      'criadoTs',     (extract(epoch from now()) * 1000)::bigint);
  else
    if old.status <> 'aguardando_assinaturas' or old.data ? 'proponenteAss' then
      raise exception 'Proposta assinada não pode ser alterada.' using errcode = '42501';
    end if;
    new.id := old.id; new.status := old.status; new.token := old.token; new.token_expira := old.token_expira;
    new.data := new.data || jsonb_build_object(
      'corretorId', old.data -> 'corretorId', 'corretorNome', old.data -> 'corretorNome', 'criadoTs', old.data -> 'criadoTs');
  end if;
  new.atualizado_em := now();
  new.atualizado_por := auth.uid();
  return new;
end $$;
drop trigger if exists propostas_guarda on public.propostas;
create trigger propostas_guarda before insert or update on public.propostas
  for each row execute function public.propostas_guarda();

-- ---------- Regras de segurança ----------
drop policy if exists propostas_ler on public.propostas;
drop policy if exists propostas_criar on public.propostas;
drop policy if exists propostas_editar on public.propostas;
drop policy if exists propostas_apagar on public.propostas;
create policy propostas_ler on public.propostas for select to authenticated
  using (public.ativo() and (public.pode('equipe') or public.meu(data, 'corretorId')));
create policy propostas_criar on public.propostas for insert to authenticated
  with check (public.pode('contratos') and public.meu(data, 'corretorId'));
create policy propostas_editar on public.propostas for update to authenticated
  using (public.pode('contratos') and public.meu(data, 'corretorId'))
  with check (public.pode('contratos') and public.meu(data, 'corretorId'));
create policy propostas_apagar on public.propostas for delete to authenticated
  using (public.e_master());

-- ---------- Funções do corretor (sistema) ----------
create or replace function public.proposta_minha(p_id text) returns public.propostas
language plpgsql security definer set search_path = public as $$
declare r public.propostas;
begin
  select * into r from public.propostas where id = p_id for update;
  if r.id is null or not (public.pode('contratos') and public.meu(r.data, 'corretorId')) then
    raise exception 'Proposta não encontrada.' using errcode = '42501';
  end if;
  return r;
end $$;

-- 1) Carimba a assinatura do proponente e reserva o código do link
create or replace function public.proposta_carimbar_proponente(p_id text, p_geo jsonb, p_identidade jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r public.propostas;
begin
  r := public.proposta_minha(p_id);
  if r.status <> 'aguardando_assinaturas' then raise exception 'Proposta já assinada.' using errcode = '42501'; end if;
  perform set_config('app.proposta_rpc', '1', true);
  update public.propostas
     set data = data || jsonb_build_object('proponenteAss', public.carimbo_servidor()
                 || jsonb_build_object('geo', p_geo, 'identidade', p_identidade)),
         token = coalesce(token, public.novo_token())
   where id = p_id returning * into r;
  return jsonb_build_object('id', r.id, 'data', r.data, 'token', r.token, 'status', r.status);
end $$;

-- 2) Depois de enviar os PDFs: libera o link para o proprietário (5 dias úteis)
create or replace function public.proposta_finalizar_proponente(p_id text, p_hash_pdf text, p_hash_dossie text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r public.propostas; base text; pdf text; dos text;
begin
  r := public.proposta_minha(p_id);
  if r.status <> 'aguardando_assinaturas' or not (r.data ? 'proponenteAss') or r.token is null then
    raise exception 'Assinatura do proponente não encontrada.' using errcode = '42501';
  end if;
  base := (r.data ->> 'corretorId') || '/propostas/' || r.id;
  pdf := base || '-' || r.token || '-proposta.pdf';
  dos := base || '-dossie-proponente.pdf';
  if not exists (select 1 from storage.objects where bucket_id = 'contratos' and name = pdf)
     or not exists (select 1 from storage.objects where bucket_id = 'contratos' and name = dos) then
    raise exception 'Arquivos da proposta não encontrados.' using errcode = '42501';
  end if;
  perform set_config('app.proposta_rpc', '1', true);
  update public.propostas
     set data = data || jsonb_build_object('arquivos', jsonb_build_object(
                  'proposta', pdf, 'dossieProponente', dos, 'atual', pdf,
                  'hashProposta', lower(p_hash_pdf), 'hashDossieProponente', lower(p_hash_dossie))),
         status = 'aguardando_aceite',
         token_expira = public.fim_dias_uteis(5)
   where id = p_id returning * into r;
  return jsonb_build_object('id', r.id, 'data', r.data, 'token', r.token, 'token_expira', r.token_expira, 'status', r.status);
end $$;

-- Gera um novo link (5 dias úteis) para a etapa atual; o anterior deixa de valer
create or replace function public.proposta_novo_link(p_id text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r public.propostas;
begin
  r := public.proposta_minha(p_id);
  if r.status not in ('aguardando_aceite', 'contraproposta') then
    raise exception 'Esta proposta não está aguardando assinatura.' using errcode = '42501';
  end if;
  perform set_config('app.proposta_rpc', '1', true);
  update public.propostas set token = public.novo_token(), token_expira = public.fim_dias_uteis(5)
   where id = p_id returning * into r;
  return jsonb_build_object('id', r.id, 'token', r.token, 'token_expira', r.token_expira, 'status', r.status);
end $$;

create or replace function public.proposta_cancelar(p_id text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r public.propostas;
begin
  r := public.proposta_minha(p_id);
  if r.status in ('concluido', 'cancelada') then
    raise exception 'Esta proposta já foi encerrada.' using errcode = '42501';
  end if;
  perform set_config('app.proposta_rpc', '1', true);
  update public.propostas set status = 'cancelada', token = null, token_expira = null
   where id = p_id returning * into r;
  return jsonb_build_object('id', r.id, 'status', r.status);
end $$;

-- ---------- Funções do link público (sem login) ----------
create or replace function public.proposta_por_token(p_token text) returns public.propostas
language plpgsql security definer set search_path = public as $$
declare r public.propostas;
begin
  if coalesce(length(p_token), 0) < 40 then return null; end if;
  select * into r from public.propostas where token = p_token for update;
  return r;
end $$;

create or replace function public.proposta_publica(p_token text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r public.propostas;
begin
  r := public.proposta_por_token(p_token);
  if r.id is null then return jsonb_build_object('erro', 'invalido'); end if;
  if r.status = 'concluido' then return jsonb_build_object('erro', 'concluido'); end if;
  if r.status = 'cancelada' then return jsonb_build_object('erro', 'cancelada'); end if;
  if r.status not in ('aguardando_aceite', 'contraproposta') then return jsonb_build_object('erro', 'invalido'); end if;
  if r.token_expira is null or r.token_expira < now() then return jsonb_build_object('erro', 'expirado'); end if;
  return jsonb_build_object(
    'id', r.id, 'status', r.status,
    'etapa', case when r.status = 'aguardando_aceite' then 'proprietario' else 'proponente' end,
    'expira', r.token_expira, 'corretorId', r.data ->> 'corretorId', 'corretorNome', r.data ->> 'corretorNome',
    'campos', r.data -> 'campos', 'contra', r.data -> 'contra', 'proprietario', r.data -> 'proprietario',
    'pdf', r.data -> 'arquivos' ->> 'atual',
    'proponenteAss', (r.data -> 'proponenteAss') - 'identidade',
    'proprietarioAss', (r.data -> 'proprietarioAss') - 'identidade');
end $$;

-- 1) Carimba a assinatura de quem está no link (proprietário ou proponente)
create or replace function public.proposta_publica_carimbar(p_token text, p_acao text, p_geo jsonb, p_identidade jsonb,
                                                           p_pessoa jsonb, p_contra jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r public.propostas; chave text; extra jsonb := '{}'::jsonb;
begin
  r := public.proposta_por_token(p_token);
  if r.id is null or r.status not in ('aguardando_aceite', 'contraproposta') or r.token_expira is null or r.token_expira < now() then
    raise exception 'Link inválido ou expirado.' using errcode = '42501';
  end if;
  if r.status = 'aguardando_aceite' and p_acao not in ('aceite', 'contraproposta') then
    raise exception 'Ação inválida.' using errcode = '42501'; end if;
  if r.status = 'contraproposta' and p_acao <> 'aceite_contra' then
    raise exception 'Ação inválida.' using errcode = '42501'; end if;
  chave := case when p_acao = 'aceite_contra' then 'aceiteContraAss' else 'proprietarioAss' end;
  if r.status = 'aguardando_aceite' then
    extra := jsonb_build_object('acao', p_acao, 'proprietario', jsonb_build_object(
      'nome', left(coalesce(p_pessoa ->> 'nome', ''), 120), 'cpf', left(coalesce(p_pessoa ->> 'cpf', ''), 30)));
    if p_acao = 'contraproposta' then
      extra := extra || jsonb_build_object('contra', jsonb_build_object(
        'valor_total_2',            left(coalesce(p_contra ->> 'valor_total_2', ''), 100),
        'condicoes_de_pagamento_2', left(coalesce(p_contra ->> 'condicoes_de_pagamento_2', ''), 1500),
        'condicoes_gerais_2',       left(coalesce(p_contra ->> 'condicoes_gerais_2', ''), 1500)));
    end if;
  end if;
  perform set_config('app.proposta_rpc', '1', true);
  update public.propostas
     set data = (case when r.status = 'aguardando_aceite' then data - 'contra' else data end) || extra
              || jsonb_build_object(chave, public.carimbo_servidor()
                 || jsonb_build_object('geo', p_geo, 'identidade', p_identidade, 'acao', p_acao,
                                       'nome', left(coalesce(p_pessoa ->> 'nome', ''), 120),
                                       'cpf', left(coalesce(p_pessoa ->> 'cpf', ''), 30)))
   where id = r.id returning * into r;
  -- devolve só o necessário para gerar os PDFs neste aparelho
  return jsonb_build_object('id', r.id, 'corretorId', r.data ->> 'corretorId', 'corretorNome', r.data ->> 'corretorNome',
    'campos', r.data -> 'campos', 'contra', r.data -> 'contra', 'acao', p_acao,
    'carimbo', (r.data -> chave) - 'identidade', 'pdf', r.data -> 'arquivos' ->> 'atual');
end $$;

-- 2) Depois de enviar os PDFs: conclui ou passa para o aceite da contra-proposta
create or replace function public.proposta_publica_finalizar(p_token text, p_hash_pdf text, p_hash_dossie text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r public.propostas; acao text; base text; pdf text; dos text; arq jsonb;
begin
  r := public.proposta_por_token(p_token);
  if r.id is null or r.status not in ('aguardando_aceite', 'contraproposta') or r.token_expira is null or r.token_expira < now() then
    raise exception 'Link inválido ou expirado.' using errcode = '42501';
  end if;
  acao := case when r.status = 'contraproposta' then r.data -> 'aceiteContraAss' ->> 'acao' else r.data -> 'proprietarioAss' ->> 'acao' end;
  if acao is null then raise exception 'Assinatura não encontrada.' using errcode = '42501'; end if;
  base := (r.data ->> 'corretorId') || '/propostas/' || r.id || '-' || p_token;
  pdf := base || case acao when 'contraproposta' then '-contraproposta.pdf' else '-final.pdf' end;
  dos := base || case acao when 'aceite_contra' then '-dossie-proponente-aceite.pdf' else '-dossie-proprietario.pdf' end;
  if not exists (select 1 from storage.objects where bucket_id = 'contratos' and name = pdf)
     or not exists (select 1 from storage.objects where bucket_id = 'contratos' and name = dos) then
    raise exception 'Arquivos não encontrados.' using errcode = '42501';
  end if;
  arq := coalesce(r.data -> 'arquivos', '{}'::jsonb) || jsonb_build_object('atual', pdf);
  if acao = 'contraproposta' then
    arq := arq || jsonb_build_object('contraproposta', pdf, 'hashContraproposta', lower(p_hash_pdf),
                                     'dossieProprietario', dos, 'hashDossieProprietario', lower(p_hash_dossie));
  elsif acao = 'aceite' then
    arq := arq || jsonb_build_object('final', pdf, 'hashFinal', lower(p_hash_pdf),
                                     'dossieProprietario', dos, 'hashDossieProprietario', lower(p_hash_dossie));
  else
    arq := arq || jsonb_build_object('final', pdf, 'hashFinal', lower(p_hash_pdf),
                                     'dossieProponenteAceite', dos, 'hashDossieProponenteAceite', lower(p_hash_dossie));
  end if;
  perform set_config('app.proposta_rpc', '1', true);
  if acao = 'contraproposta' then
    update public.propostas set data = data || jsonb_build_object('arquivos', arq),
           status = 'contraproposta', token = public.novo_token(), token_expira = public.fim_dias_uteis(5)
     where id = r.id returning * into r;
  else
    update public.propostas set data = data || jsonb_build_object('arquivos', arq),
           status = 'concluido', token = null, token_expira = null
     where id = r.id returning * into r;
  end if;
  return jsonb_build_object('status', r.status);
end $$;

grant execute on function public.proposta_carimbar_proponente(text, jsonb, jsonb),
                          public.proposta_finalizar_proponente(text, text, text),
                          public.proposta_novo_link(text), public.proposta_cancelar(text) to authenticated;
grant execute on function public.proposta_publica(text),
                          public.proposta_publica_carimbar(text, text, jsonb, jsonb, jsonb, jsonb),
                          public.proposta_publica_finalizar(text, text, text) to anon, authenticated;
revoke execute on function public.proposta_minha(text), public.proposta_por_token(text) from public, anon, authenticated;

-- ---------- Arquivos do link público (Storage, bucket privado "contratos") ----------
-- Quem tem o link pode: ler o PDF atual da proposta e enviar os PDFs da sua assinatura
-- (o nome do arquivo contém o código do link, que é aleatório).
-- Funções protegidas: o visitante sem login não enxerga a tabela de propostas.
create or replace function public.proposta_arquivo_publico(p_nome text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.propostas p
                  where p.status in ('aguardando_aceite', 'contraproposta') and p.token_expira > now()
                    and p.data -> 'arquivos' ->> 'atual' = p_nome);
$$;
create or replace function public.proposta_envio_publico(p_nome text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.propostas p
                  where p.status in ('aguardando_aceite', 'contraproposta') and p.token is not null and p.token_expira > now()
                    and p_nome like (p.data ->> 'corretorId') || '/propostas/' || p.id || '-' || p.token || '-%');
$$;
grant execute on function public.proposta_arquivo_publico(text), public.proposta_envio_publico(text) to anon, authenticated;

drop policy if exists propostas_publico_ler on storage.objects;
drop policy if exists propostas_publico_enviar on storage.objects;
create policy propostas_publico_ler on storage.objects for select to anon, authenticated
  using (bucket_id = 'contratos' and public.proposta_arquivo_publico(name));
create policy propostas_publico_enviar on storage.objects for insert to anon, authenticated
  with check (bucket_id = 'contratos' and public.proposta_envio_publico(name));

do $$
begin
  execute 'alter publication supabase_realtime add table public.propostas';
exception when duplicate_object then null;
end $$;
