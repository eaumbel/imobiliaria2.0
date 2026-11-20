-- =====================================================================
-- Novo tipo de usuário: Diretor
-- - Tem os mesmos acessos do Coordenador.
-- - Na tela de permissões ele ganha uma coluna própria. Enquanto o Master não
--   mexer nela, o Diretor segue exatamente o que estiver configurado para o
--   Coordenador.
-- Pode ser rodada mais de uma vez sem efeito colateral.
-- =====================================================================

-- Aceita "diretor" no cadastro
do $$
declare c text;
begin
  for c in select conname from pg_constraint
            where conrelid = 'public.perfis'::regclass and contype = 'c' and pg_get_constraintdef(oid) ilike '%perfil%'
  loop
    execute format('alter table public.perfis drop constraint %I', c);
  end loop;
  alter table public.perfis add constraint perfis_perfil_check check (perfil in ('master', 'diretor', 'coordenador', 'corretor'));
end $$;

-- Permissões: o Diretor usa a configuração própria; sem ela, a do Coordenador; sem ela, o padrão do Coordenador
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
  if me.perfil = 'diretor' then
    select c.data -> 'coordenador' -> p into v from public.config c where c.id = 'permissoes';
    if v is not null and jsonb_typeof(v) = 'boolean' then return (v #>> '{}')::boolean; end if;
  end if;
  if me.perfil in ('coordenador', 'diretor') then
    return p in ('diario','relatorios','agenda','conhecimento','treinamentos','ponto','vendas','contratos','angariacoes','kanban','metas','equipe','conteudo','operacaoTodos','kanbanTodos','comunicacao');
  end if;
  return p in ('diario','relatorios','agenda','conhecimento','treinamentos','ponto','vendas','contratos','angariacoes','kanban');
end $$;

-- Nome do tipo na tela Authentication → Users do Supabase
create or replace function public.sincronizar_usuario_auth() returns trigger
language plpgsql security definer set search_path = public, auth as $$
declare
  tipo text := case new.perfil when 'master' then 'Master' when 'diretor' then 'Diretor' when 'coordenador' then 'Coordenador' else 'Corretor' end;
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
