-- =====================================================================
-- Angariações: a mesma referência não pode ser cadastrada duas vezes.
-- A comparação ignora maiúsculas/minúsculas, espaços e pontuação
-- ("AP-1042", "ap 1042" e "AP1042" são a mesma referência).
--
-- 1) angariacao_referencia(ref, ignorar_id): consulta usada pelo botão
--    "Salvar angariação". Procura em TODAS as angariações (o corretor só
--    enxerga as próprias na tela) e devolve apenas quem cadastrou e quando.
-- 2) Gatilho angariacoes_referencia_unica: garantia final no banco, inclusive
--    quando duas pessoas salvam a mesma referência ao mesmo tempo.
-- =====================================================================

create or replace function public.ref_normalizada(t text) returns text
language sql immutable as $$
  select upper(regexp_replace(coalesce(t, ''), '[^[:alnum:]]', '', 'g'));
$$;

create index if not exists angariacoes_ref_norm_idx
  on public.angariacoes (public.ref_normalizada(data ->> 'referencia'));

-- Consulta para a tela: devolve só o necessário para o aviso
create or replace function public.angariacao_referencia(p_ref text, p_ignorar_id text default null)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  r public.angariacoes;
begin
  if not public.ativo() then raise exception 'Acesso inativo.' using errcode = '42501'; end if;
  if public.ref_normalizada(p_ref) = '' then return null; end if;
  select * into r from public.angariacoes a
   where public.ref_normalizada(a.data ->> 'referencia') = public.ref_normalizada(p_ref)
     and a.id is distinct from p_ignorar_id
   order by (a.data ->> 'criadoTs')::bigint nulls last
   limit 1;
  if r.id is null then return null; end if;
  return jsonb_build_object(
    'referencia',     r.data ->> 'referencia',
    'dataAngariacao', r.data ->> 'dataAngariacao',
    'criadoTs',       r.data -> 'criadoTs',
    'corretorNome',   coalesce((select nome from public.perfis where id::text = r.data ->> 'corretorId'), r.data ->> 'corretorNome', ''));
end $$;

revoke all on function public.angariacao_referencia(text, text) from public, anon;
grant execute on function public.angariacao_referencia(text, text) to authenticated;

-- Garantia no banco
create or replace function public.angariacoes_referencia_unica() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  n   text := public.ref_normalizada(new.data ->> 'referencia');
  r   public.angariacoes;
  quando text;
begin
  if n = '' then return new; end if;
  -- etapa de inserção de um "insere ou atualiza" sobre registro existente: é edição dele mesmo
  if tg_op = 'INSERT' and exists (select 1 from public.angariacoes where id = new.id) then return new; end if;
  -- numa edição que não mudou a referência, nada a conferir
  if tg_op = 'UPDATE' and public.ref_normalizada(old.data ->> 'referencia') = n then return new; end if;
  -- serializa cadastros simultâneos da mesma referência
  perform pg_advisory_xact_lock(hashtext('angariacao-ref:' || n));
  select * into r from public.angariacoes a
   where public.ref_normalizada(a.data ->> 'referencia') = n and a.id <> new.id
   order by (a.data ->> 'criadoTs')::bigint nulls last limit 1;
  if r.id is not null then
    quando := case when r.data ? 'criadoTs'
      then to_char(to_timestamp((r.data ->> 'criadoTs')::bigint / 1000.0) at time zone 'America/Sao_Paulo', 'DD/MM/YYYY "às" HH24:MI')
      else 'data não registrada' end;
    raise exception 'A referência % já foi cadastrada em % por %.', r.data ->> 'referencia', quando,
      coalesce((select nome from public.perfis where id::text = r.data ->> 'corretorId'), r.data ->> 'corretorNome', 'outro usuário')
      using errcode = '23505';
  end if;
  return new;
end $$;

drop trigger if exists angariacoes_referencia_unica on public.angariacoes;
create trigger angariacoes_referencia_unica before insert or update on public.angariacoes
  for each row execute function public.angariacoes_referencia_unica();
