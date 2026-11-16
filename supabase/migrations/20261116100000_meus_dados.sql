-- =====================================================================
-- Meus dados: cada usuário logado (Master, Coordenador ou Corretor)
-- edita o PRÓPRIO cadastro, apenas os campos pessoais.
-- Login, tipo de acesso, status, participação e permissões continuam
-- exclusivos de quem gerencia usuários (função admin-usuarios).
-- =====================================================================

create or replace function public.salvar_meus_dados(
  p_nome text,
  p_telefone text,
  p_email text,
  p_creci text,
  p_especialidade text
) returns public.perfis
language plpgsql security definer set search_path = public as $$
declare
  me   public.perfis;
  v_nome text := btrim(coalesce(p_nome, ''));
  v_tel  text := btrim(coalesce(p_telefone, ''));
  v_mail text := lower(btrim(coalesce(p_email, '')));
  v_cre  text := btrim(coalesce(p_creci, ''));
  v_esp  text := btrim(coalesce(p_especialidade, ''));
begin
  select * into me from public.perfis where id = auth.uid();
  if me.id is null then raise exception 'Usuário não encontrado.' using errcode = '42501'; end if;
  if not me.ativo then raise exception 'Seu acesso está inativo.' using errcode = '42501'; end if;

  if char_length(v_nome) < 3 then raise exception 'Informe o nome completo.' using errcode = '22023'; end if;
  if char_length(regexp_replace(v_tel, '\D', '', 'g')) < 10 then raise exception 'Informe um telefone com DDD.' using errcode = '22023'; end if;
  if v_mail !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Confira o e-mail informado.' using errcode = '22023'; end if;
  if me.perfil <> 'master' and v_cre = '' then raise exception 'Informe o seu CRECI.' using errcode = '22023'; end if;

  update public.perfis
     set nome          = left(v_nome, 200),
         telefone      = left(v_tel, 30),
         email         = left(v_mail, 200),
         creci         = left(v_cre, 30),
         especialidade = left(v_esp, 80),
         atualizado_em = now()
   where id = me.id
  returning * into me;
  return me;
end $$;

revoke all on function public.salvar_meus_dados(text, text, text, text, text) from public, anon;
grant execute on function public.salvar_meus_dados(text, text, text, text, text) to authenticated;
