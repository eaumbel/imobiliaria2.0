# Imobiliária 2.0 · Gestão comercial

Sistema de gestão da equipe de corretores: painel de BI e metas, vendas e comissões, cartão ponto com roleta, agenda, base de conhecimento, treinamentos, relatórios em PDF e controle de acesso por perfil (Master, Coordenador, Corretor).

- **Site:** `index.html` + `config.js` (sem build; publicado pelo GitHub Pages em `gestao.eaumbel.com.br`)
- **Banco, login e arquivos:** Supabase (projeto `hjzessepenqedsfgokmt`)
- **Segurança:** as permissões são conferidas no servidor (Row Level Security). Os usuários entram só com o login e a senha cadastrados no sistema.

## Estrutura

| Arquivo | O que é |
|---|---|
| `index.html` | O sistema completo |
| `config.js` | URL do Supabase e chave **anon public** |
| `supabase/migrations/20261111180000_inicial.sql` | Tabelas, permissões (RLS), armazenamento e tempo real |
| `supabase/functions/admin-usuarios/index.ts` | Função segura que cria e altera usuários (login, senha, perfil, status, permissões) |
| `CNAME` | Domínio do GitHub Pages |

## Configuração (uma vez)

### 1. Banco de dados
Com a integração GitHub ↔ Supabase ativa e apontando para a pasta `supabase`, a migração roda ao enviar para a branch principal.
Se preferir fazer à mão: Supabase → **SQL Editor** → cole o conteúdo de `supabase/migrations/20261111180000_inicial.sql` → **Run**.

### 2. Função `admin-usuarios`
Supabase → **Edge Functions** → **Deploy a new function** → **Via Editor**:
1. Nome: `admin-usuarios`
2. Cole o conteúdo de `supabase/functions/admin-usuarios/index.ts`
3. Em **Settings** da função, **desligue "Verify JWT"** (a função confere a sessão por conta própria; sem isso a tela de primeiro acesso não funciona).

Pela linha de comando, o equivalente é:
`supabase functions deploy admin-usuarios --no-verify-jwt`

### 3. Login
Supabase → **Authentication → Sign In / Providers → Email**:
- Desligue **Allow new users to sign up** (só o Master cria usuários, pela função).
- **Confirm email** pode ficar como estiver: os usuários são criados já confirmados.

### 4. Chave do site
Em `config.js`, troque `COLE_AQUI_A_CHAVE_ANON_PUBLIC` pela chave **anon public** (Project Settings → API).

### 5. Publicar no GitHub Pages
1. Repositório → **Settings → Pages** → Source: **Deploy from a branch** → branch `main`, pasta `/ (root)`.
2. Em **Custom domain**, confirme `gestao.eaumbel.com.br` e marque **Enforce HTTPS** quando liberar.
3. No painel DNS do domínio `eaumbel.com.br`, crie:
   `gestao  CNAME  eaumbel.github.io.`

> No plano gratuito do GitHub, o Pages exige repositório **público**. Não há segredo no código: a chave anon é pública e a proteção dos dados está nas regras do banco. Se preferir repositório privado, publique pela Vercel ou Netlify apontando para este repositório (sem build, pasta raiz).

### 6. Primeiro acesso
Abra `https://gestao.eaumbel.com.br`. Como não há usuários, aparece **Primeiro acesso**: crie o login do **Master**. Depois cadastre a equipe em **Usuários**.

## Esqueci a senha do Master
Outro Master pode redefinir em **Usuários → Editar**. Se não houver outro, rode no **SQL Editor** do Supabase (troque o login e a senha):

```sql
update auth.users
set encrypted_password = crypt('NovaSenha123', gen_salt('bf'))
where email = 'gestor@acesso.eaumbel.com.br';
```
