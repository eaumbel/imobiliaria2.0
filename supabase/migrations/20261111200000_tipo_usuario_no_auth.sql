-- Mostra o tipo de usuário na tela Authentication → Users do Supabase.
-- Sempre que um perfil é criado ou muda (nome, tipo de acesso ou status),
-- o "Display name" do login passa a ser "Nome · Master/Coordenador/Corretor".
create or replace function public.sincronizar_usuario_auth() returns trigger
language plpgsql security definer set search_path = public, auth as $$
declare
  tipo text := case new.perfil when 'master' then 'Master' when 'coordenador' then 'Coordenador' else 'Corretor' end;
begin
  update auth.users
  set raw_user_meta_data = coalesce(raw_user_meta_data, '{}'::jsonb) || jsonb_build_object(
        'display_name', new.nome || ' · ' || tipo || case when new.ativo then '' else ' (inativo)' end,
        'nome', new.nome,
        'perfil', new.perfil),
      raw_app_meta_data = coalesce(raw_app_meta_data, '{}'::jsonb) || jsonb_build_object('perfil', new.perfil)
  where id = new.id;
  return new;
end $$;

drop trigger if exists sincronizar_usuario_auth on public.perfis;
create trigger sincronizar_usuario_auth
  after insert or update of nome, perfil, ativo on public.perfis
  for each row execute function public.sincronizar_usuario_auth();

-- Atualiza os usuários que já existem
update public.perfis set nome = nome;
