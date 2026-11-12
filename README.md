# Imobiliária 2.0 · Gestão comercial

Sistema de gestão da equipe de corretores: painel de BI e metas, vendas e comissões, cartão ponto com roleta, agenda, base de conhecimento, treinamentos, relatórios em PDF e controle de acesso por perfil (Master, Coordenador, Corretor).

- **Site:** pasta `gestao/` (sem build; publicado pela Vercel em `eaumbel.com.br/gestao`)
- **Banco, login e arquivos:** Supabase (projeto `hjzessepenqedsfgokmt`)
- **Segurança:** as permissões são conferidas no servidor (Row Level Security). Os usuários entram só com o login e a senha cadastrados no sistema.

## Estrutura

| Arquivo | O que é |
|---|---|
| `gestao/index.html` | O sistema completo |
| `gestao/config.js` | URL do Supabase e chave **anon public** |
| `vercel.json` | Redireciona `/` para `/gestao/` e cabeçalhos de segurança |
| `.vercelignore` | Não publica a pasta `supabase` nem este README |
| `supabase/migrations/20261111180000_inicial.sql` | Tabelas, permissões (RLS), armazenamento e tempo real |
| `supabase/functions/admin-usuarios/index.ts` | Função segura que cria e altera usuários (login, senha, perfil, status, permissões) |

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
Já preenchida em `gestao/config.js` (chave **anon public**, que é pública por natureza).

### 5. Publicar na Vercel
1. Vercel → **Add New → Project** → importe o repositório `eaumbel/imobiliaria2.0`.
2. **Framework Preset:** `Other`. Deixe Build Command e Output Directory vazios. Clique em **Deploy**.
3. No projeto: **Settings → Domains** → adicione `eaumbel.com.br` (e, se quiser, `www.eaumbel.com.br`).
4. A Vercel mostra os registros DNS a criar. No Registro.br (**Editar zona** do domínio), crie exatamente os que ela indicar — normalmente:
   - `A` · nome vazio (`eaumbel.com.br`) · `76.76.21.21`
   - `CNAME` · `www` · `cname.vercel-dns.com`
5. Quando o domínio aparecer como **Valid Configuration** na Vercel, o sistema abre em `https://eaumbel.com.br/gestao/`.

### 6. Primeiro acesso
Abra `https://eaumbel.com.br/gestao/` (ou o endereço `….vercel.app/gestao/` que a Vercel mostra, antes do domínio ficar pronto). Como não há usuários, aparece **Primeiro acesso**: crie o login do **Master**. Depois cadastre a equipe em **Usuários**.

## Esqueci a senha do Master
Outro Master pode redefinir em **Usuários → Editar**. Se não houver outro, rode no **SQL Editor** do Supabase (troque o login e a senha):

```sql
update auth.users
set encrypted_password = crypt('NovaSenha123', gen_salt('bf'))
where email = 'gestor@acesso.eaumbel.com.br';
```

## Diário de bordo (inteligência artificial)

A análise do dia é feita pela função `diario-ia`, que funciona com **Google Gemini** (plano gratuito) ou com **Claude** (Anthropic, pago por uso). Basta cadastrar um dos dois segredos; se os dois existirem, usa o Gemini.

1. **Banco:** rode no SQL Editor o arquivo `supabase/migrations/20261111220000_diario_de_bordo.sql`.
2. **Função:** Edge Functions → Deploy a new function → Via Editor → nome `diario-ia` → cole `supabase/functions/diario-ia/index.ts` → Deploy. Em **Settings**, desligue **Verify JWT**.
3. **Chave da IA (gratuita):** em https://aistudio.google.com → **Get API key** → **Create API key**. Cadastre em Supabase → Edge Functions → **Secrets** com o nome `GEMINI_API_KEY`.
   - No plano gratuito do Gemini, o Google pode usar os textos enviados para melhorar os produtos dele. Para evitar isso, ative o faturamento no Google Cloud (plano pago) ou use a Anthropic (`ANTHROPIC_API_KEY`).
4. Opcional: o segredo `MODELO_IA` troca o modelo (padrão `gemini-flash-latest` no Gemini, `claude-sonnet-5-5` na Anthropic).

O mantra da equipe (valores, deveres, virtudes) e as palavras-chave ficam em **Diário de bordo → Configurações** (só o Master).
