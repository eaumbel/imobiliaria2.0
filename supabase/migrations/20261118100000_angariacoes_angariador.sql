-- =====================================================================
-- Angariações: campo Angariador (usuário Corretor, Coordenador ou Master).
-- - angariadorId: Master e Coordenador escolhem no formulário (se vier vazio,
--   é quem cadastra). Para o Corretor é sempre ele mesmo, sem escolha.
-- - O servidor confere que o angariador existe (e está ativo ao ser
--   escolhido) e grava angariadorNome a partir do cadastro.
-- - O angariador passa a ver a angariação, mesmo cadastrada por outro.
-- - Quem cadastrou (corretorId/corretorNome/criadoTs) continua imutável.
-- - Angariações antigas: angariador = quem cadastrou.
-- =====================================================================

create or replace function public.angariacoes_guarda() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  d    jsonb := coalesce(new.data, '{}'::jsonb);
  ref  text  := btrim(coalesce(d ->> 'referencia', ''));
  dt   text  := coalesce(d ->> 'dataAngariacao', '');
  exc  text  := coalesce(d ->> 'exclusividade', '');
  dias text  := btrim(coalesce(d ->> 'dias', ''));
  ang  text  := btrim(coalesce(d ->> 'angariadorId', ''));
  ang_antes text := case when tg_op = 'UPDATE' then coalesce(nullif(old.data ->> 'angariadorId', ''), old.data ->> 'corretorId', '') else '' end;
  p    public.perfis;
  atual jsonb;
begin
  -- "Insere ou atualiza" (upsert) de um registro que já existe: o Postgres roda
  -- primeiro esta etapa de inserção sobre uma versão provisória. Ela só recebe
  -- os dados do registro atual (quem cadastrou, angariador); a validação
  -- completa acontece na etapa de edição, que conhece o registro antigo.
  if tg_op = 'INSERT' then
    select a.data into atual from public.angariacoes a where a.id = new.id;
    if atual is not null then
      new.data := d || jsonb_build_object('corretorId', atual -> 'corretorId', 'corretorNome', atual -> 'corretorNome', 'criadoTs', atual -> 'criadoTs',
        'angariadorId', coalesce(nullif(ang, ''), atual ->> 'angariadorId', atual ->> 'corretorId'));
      return new;
    end if;
  end if;

  if ref = '' then raise exception 'Informe a referência.' using errcode = '22023'; end if;
  if char_length(ref) > 60 then raise exception 'A referência pode ter até 60 caracteres.' using errcode = '22023'; end if;
  if dt !~ '^\d{4}-\d{2}-\d{2}$' then raise exception 'Informe a data da angariação.' using errcode = '22023'; end if;
  begin perform dt::date; exception when others then raise exception 'Data da angariação inválida.' using errcode = '22023'; end;
  if exc not in ('sim', 'nao') then raise exception 'Informe se há exclusividade (Sim ou Não).' using errcode = '22023'; end if;
  if exc = 'sim' then
    if dias !~ '^[0-9]{1,5}$' or dias::int < 1 then raise exception 'Informe os dias de exclusividade (de 1 a 99999).' using errcode = '22023'; end if;
  end if;

  -- Angariador: só quem lança para toda a equipe (Master/Coordenador) escolhe.
  -- Para o Corretor é sempre ele mesmo; numa edição, mantém o angariador atual.
  if not public.pode('operacaoTodos') then ang := ''; end if;
  if ang = '' then ang := case when tg_op = 'INSERT' then coalesce(auth.uid()::text, new.data ->> 'corretorId', '') else ang_antes end; end if;
  if ang !~ '^[0-9a-fA-F-]{36}$' then raise exception 'Escolha o angariador.' using errcode = '22023'; end if;
  select * into p from public.perfis where id = ang::uuid;
  if p.id is null then raise exception 'Angariador não encontrado.' using errcode = '22023'; end if;
  if not p.ativo and ang is distinct from ang_antes then raise exception 'O angariador escolhido está inativo.' using errcode = '22023'; end if;

  d := (d - 'corretorId' - 'corretorNome' - 'criadoTs' - 'dias' - 'angariadorId' - 'angariadorNome')
       || jsonb_build_object('referencia', ref, 'dataAngariacao', dt, 'exclusividade', exc, 'angariadorId', p.id::text, 'angariadorNome', p.nome)
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

-- O angariador também vê a angariação (além de quem cadastrou e de quem vê a equipe)
drop policy if exists angariacoes_ler on public.angariacoes;
create policy angariacoes_ler on public.angariacoes for select to authenticated
  using (public.ativo() and (public.pode('equipe') or public.pode('operacaoTodos')
         or public.meu(data, 'corretorId') or public.meu(data, 'angariadorId')));

-- Angariações já registradas: angariador = quem cadastrou
update public.angariacoes
   set data = data || jsonb_build_object('angariadorId', data -> 'corretorId')
 where coalesce(data ->> 'angariadorId', '') = ''
   and exists (select 1 from public.perfis pf where pf.id::text = data ->> 'corretorId');
