-- =====================================================================
-- Modelos de Contrato: comprovação de identidade.
-- - Grava o IP do aparelho, capturado pelo servidor no momento da assinatura.
-- - Permite registrar (uma única vez) o dossiê de comprovação
--   (documento com foto + selfie com documento) e as impressões digitais
--   (SHA-256) do contrato e do dossiê.
-- Pode ser rodada mais de uma vez sem efeito colateral.
-- =====================================================================

create or replace function public.contratos_carimbo() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  agora timestamptz := now();
  h     jsonb;
  ip    text;
  hc    text;
  hd    text;
begin
  if tg_op = 'INSERT' then
    -- IP do aparelho, pelos cabeçalhos da requisição (não vem do navegador)
    begin
      h := nullif(current_setting('request.headers', true), '')::jsonb;
    exception when others then
      h := null;
    end;
    ip := coalesce(
      nullif(trim(h ->> 'cf-connecting-ip'), ''),
      nullif(trim(split_part(coalesce(h ->> 'x-forwarded-for', ''), ',', 1)), ''),
      nullif(trim(h ->> 'x-real-ip'), ''));
    new.data := (coalesce(new.data, '{}'::jsonb)
                 - 'arquivo' - 'dossie' - 'hashContrato' - 'hashDossie' - 'ip'
                 - 'corretorId' - 'corretorNome' - 'assinadoTs' - 'assinadoLocal')
      || jsonb_build_object(
        'corretorId',    auth.uid()::text,
        'corretorNome',  coalesce((select nome from public.perfis where id = auth.uid()), ''),
        'assinadoTs',    (extract(epoch from agora) * 1000)::bigint,
        'assinadoLocal', to_char(agora at time zone 'America/Sao_Paulo', 'YYYY-MM-DD"T"HH24:MI:SS'),
        'ip',            ip);
  else
    if coalesce(old.data ->> 'arquivo', '') <> '' then
      raise exception 'Documento assinado não pode ser alterado.' using errcode = '42501';
    end if;
    hc := lower(coalesce(new.data ->> 'hashContrato', ''));
    hd := lower(coalesce(new.data ->> 'hashDossie', ''));
    new.id := old.id;
    new.data := old.data
      || jsonb_build_object('arquivo', (old.data ->> 'corretorId') || '/' || old.id || '.pdf')
      || case when coalesce(new.data ->> 'dossie', '') in ('true', '1')
              then jsonb_build_object('dossie', (old.data ->> 'corretorId') || '/' || old.id || '-dossie.pdf')
              else '{}'::jsonb end
      || case when hc ~ '^[0-9a-f]{64}$' then jsonb_build_object('hashContrato', hc) else '{}'::jsonb end
      || case when hd ~ '^[0-9a-f]{64}$' then jsonb_build_object('hashDossie', hd) else '{}'::jsonb end;
  end if;
  new.atualizado_em := agora;
  new.atualizado_por := auth.uid();
  return new;
end $$;

drop trigger if exists contratos_carimbo on public.contratos;
create trigger contratos_carimbo before insert or update on public.contratos
  for each row execute function public.contratos_carimbo();
