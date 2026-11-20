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
| `gestao/modelos/autorizacao-venda.pdf` | Modelo do contrato Autorização de Venda (PDF com campos preenchíveis) |
| `supabase/migrations/20261114120000_contratos.sql` | Contratos assinados: tabela, carimbo de data/hora do servidor, arquivos PDF e permissões |
| `supabase/migrations/20261115100000_contratos_identidade.sql` | Contratos: IP pelo servidor, dossiê de comprovação e impressões digitais (SHA-256) |
| `gestao/modelos/proposta-compra.pdf` | Modelo da Proposta de Compra (PDF com campos preenchíveis) |
| `supabase/migrations/20261115140000_propostas.sql` | Propostas de compra: tabela, status, link público (5 dias úteis) e funções de assinatura |
| `supabase/migrations/20261121100000_comunicacao_push.sql` | Comunicados, aparelhos inscritos para push e disparo automático das notificações |
| `supabase/functions/enviar-push/index.ts` | Função que envia as notificações push (Web Push) |
| `gestao/sw.js`, `gestao/manifest.webmanifest`, ícones | Recebe o push no aparelho e permite instalar o sistema na tela de início |

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

## Modelos de Contrato

Menu **Modelos de Contrato**: o corretor abre o modelo (hoje, **Autorização de Venda**), preenche os campos (nenhum é obrigatório) e toca em **Assinar**. A assinatura segue **3 passos obrigatórios, nessa ordem**:

1. **Documento com foto** do(a) proprietário(a) (CNH, RG ou outro): frente e verso, tirando a foto ou anexando o arquivo. Há a opção "documento sem verso".
2. **Selfie segurando o documento**, tirada pela câmera na hora (não aceita arquivo anexado).
3. **Assinatura** na tela com o dedo, a caneta ou o mouse, e a marcação de **"Li e autorizo a assinatura eletrônica…"**.

A **localização é obrigatória**: sem a permissão de localização no aparelho, não dá para passar do passo 2.

- A **data e a hora** vêm do **servidor**, no horário de Brasília, e preenchem o dia, o mês e o ano do contrato. O **IP do aparelho** também é capturado pelo servidor.
- O nome e o CRECI do **corretor** que está usando o sistema são preenchidos na linha CORRETOR(A).
- O contrato tem a **Cláusula de assinatura eletrônica**, em que o(a) proprietário(a) autoriza a assinatura eletrônica (art. 10, § 2º, da MP 2.200-2/2001) e o registro dos dados (LGPD). Ela aparece no formulário e no PDF.
- São gerados **dois PDFs**:
  - **Contrato:** o próprio modelo preenchido, com a assinatura, a cláusula e o bloco **Registro da assinatura eletrônica** (data e hora, IP, local, coordenadas, corretor, código e a impressão digital SHA-256 do dossiê). É o que vai por WhatsApp ou e-mail; **não contém** a foto do documento.
  - **Dossiê de comprovação** (interno): registro completo, frente e verso do documento, selfie com o documento e assinatura. Fica guardado no sistema, só aparece em **Visualizar → Dossiê de comprovação** e não é enviado por WhatsApp ou e-mail.
- A impressão digital SHA-256 do contrato e do dossiê fica gravada no banco: qualquer alteração posterior no arquivo muda esse código. Depois de assinado, o documento **não pode ser alterado**.
- **Exportar** baixa o PDF; **Imprimir** abre a janela de impressão do aparelho; **WhatsApp** e **E-mail** no celular/tablet abrem a tela de compartilhar com o PDF anexado (WhatsApp, WhatsApp Business, Mail, Gmail…). No computador, o PDF é baixado e abre o **WhatsApp Web** ou o **aplicativo de e-mail padrão**, com um link do documento válido por 7 dias.
- **Todos os Documentos Assinados** lista cliente, data de assinatura e corretor, com **Visualizar** e **Download**. Cada corretor vê os que gerou; quem tem "Ver números de toda a equipe" vê todos. Só o Master exclui (contrato e dossiê).
- O endereço é obtido no serviço gratuito do OpenStreetMap (Nominatim), que recebe as coordenadas.

**Configuração (uma vez):** rode no SQL Editor do Supabase, nesta ordem:
1. `supabase/migrations/20261114120000_contratos.sql`: tabela `contratos`, armazenamento privado `contratos` e a permissão do menu (ligada por padrão para todos os perfis; dá para mudar em **Usuários → Permissões**).
2. `supabase/migrations/20261115100000_contratos_identidade.sql`: IP pelo servidor, dossiê de comprovação e impressões digitais.

### Proposta de Compra

Segundo modelo do menu **Modelos de Contrato**, com as mesmas regras de assinatura (documento com foto, selfie com o documento, assinatura na tela, localização obrigatória, IP e data/hora do servidor, cláusula de assinatura eletrônica e dossiê de comprovação de cada parte).

1. O corretor preenche a **página 1** (proposta do comprador). A proposta é **salva automaticamente** e aparece em **Propostas realizadas** com o status 🔴 **Aguardando assinaturas**.
2. O **proponente** assina no aparelho do corretor → status 🟡 **Aguardando aceite**. O sistema gera um **link público** (WhatsApp, e-mail ou copiar), válido por **5 dias úteis**.
3. O **proprietário** abre o link, sem login. A página 1 aparece só para leitura e a página 2 fica livre. Ele escolhe:
   - **Aceitar a proposta**: assina em Aceitação da proposta → 🟢 **Concluído**.
   - **Fazer contra-proposta**: preenche e assina a contra-proposta → 🟠 **Contra-proposta recebida**, e o sistema gera um novo link para o proponente.
4. O **proponente** abre o novo link e aceita a contra-proposta, assinando na linha PROPONENTE da Aceitação → 🟢 **Concluído**.

O corretor pode **gerar um novo link** (o anterior deixa de valer) ou **cancelar** a proposta. Cada etapa guarda o seu PDF e o dossiê de quem assinou, com impressão digital SHA-256; a versão assinada só pelo proponente fica guardada para provar que a página 1 não mudou. O link só dá acesso ao PDF atual daquela proposta, nunca aos dossiês.

**Configuração (uma vez):** rode no SQL Editor do Supabase `supabase/migrations/20261115140000_propostas.sql`.

**Novos modelos:** coloque o PDF preenchível em `gestao/modelos/` e cadastre os campos em `MODELOS`, no `gestao/index.html`.

## Diário de bordo (inteligência artificial)

A análise do dia é feita pela função `diario-ia`, que funciona com **OpenAI** (pago por uso, igual ao Diário feito no Lovable), **Google Gemini** (plano gratuito) ou **Claude** (Anthropic, pago por uso). Basta cadastrar o segredo de um deles.

**Principal e reserva:** com mais de uma chave cadastrada, o **Gemini é a principal** e as outras ficam de **reserva**: se o Gemini não responder (demora, sobrecarga, limite de uso, erro ou resposta cortada), a análise segue automaticamente na OpenAI (e depois no Claude). O Gemini tem metade do tempo (~55 s) e a reserva usa o restante; com reserva, o Gemini sobrecarregado é tentado só uma vez a mais antes de passar adiante. O corretor vê no aviso quando a reserva foi usada, e o **Teste da inteligência** (Diário de bordo → Configurações) testa cada uma numa linha. O segredo `PROVEDOR_IA` (`gemini`, `openai` ou `claude`) muda qual vem primeiro.

**OpenAI:** crie a chave em https://platform.openai.com/api-keys e cadastre no Supabase (Edge Functions → **Secrets**) com o nome `OPENAI_API_KEY`. A conta precisa ter créditos. O formato do relatório é garantido pela própria OpenAI e a resposta chega aos poucos (streaming). Opcionais:
- `MODELO_OPENAI`: o modelo (padrão `gpt-6-astra`, o mesmo do projeto no Lovable). Se aparecer "Modelo de IA não encontrado", cadastre aqui o nome do modelo como aparece na sua conta da OpenAI.
- `ESFORCO_IA`: quanto o modelo "pensa" antes de responder: `minimal` (mais rápido), `low` (padrão), `medium` (como no Lovable) ou `high`.

1. **Banco:** rode no SQL Editor os arquivos `supabase/migrations/20261111220000_diario_de_bordo.sql` e `supabase/migrations/20261112010000_uso_ia.sql`.
2. **Função:** Edge Functions → Deploy a new function → Via Editor → nome `diario-ia` → cole `supabase/functions/diario-ia/index.ts` → Deploy. Em **Settings**, desligue **Verify JWT**.
3. **Chave da IA (gratuita):** em https://aistudio.google.com → **Get API key** → **Create API key**. Cadastre em Supabase → Edge Functions → **Secrets** com o nome `GEMINI_API_KEY`.
   - No plano gratuito do Gemini, o Google pode usar os textos enviados para melhorar os produtos dele. Para evitar isso, ative o faturamento no Google Cloud (plano pago) ou use a Anthropic (`ANTHROPIC_API_KEY`).
4. Opcional: o segredo `MODELO_IA` troca o modelo (padrão `gemini-flash-latest` no Gemini, `claude-sonnet-5-5` na Anthropic).
5. Opcional: o segredo `RACIOCINIO_IA` com valor `1` religa o "raciocínio" prévio do Gemini. Por padrão ele fica desligado, porque é a maior parte da espera e não é necessário para preencher o relatório.

**Atualizar a função:** publicar o site não atualiza a função. Quando `supabase/functions/diario-ia/index.ts` mudar, abra Edge Functions → `diario-ia` → **Code**, cole o arquivo novo e clique em **Deploy**.

O prompt do mentor (com versão), o limite de análises por corretor a cada 24h, os **pilares inegociáveis da operação**, o mantra da equipe (valores, deveres, virtudes) e as palavras-chave ficam em **Diário de bordo → Configurações** (só o Master). O prompt, os pilares, a base de conhecimento (Ponto de Reflexão, Manual de Persuasão do FBI, Cialdini, Chris Voss) e os critérios da nota vêm do Diário Águia (projeto no Lovable), que foi incorporado ao Gestão 2.0.

## Kanban e notificações

Menu **Kanban** (grupo Gestão): quadro de cards em etapas (colunas). Cada card tem título, descrição, etapa, prioridade, prazo, responsável, participantes, etiquetas, checklist, comentários e histórico. Os cards mudam de etapa arrastando (no computador) ou pelo campo **Etapa** dentro do card (no celular). Cards concluídos podem ser **arquivados** (somem do quadro e ficam em "Arquivados").

- **Quem vê:** cada pessoa vê os cards em que está envolvida (criou, é responsável ou participante). Master e Coordenador veem todos (permissão "Ver e organizar todos os cards do Kanban", ajustável em Usuários).
- **Notificações (sininho no alto, à direita):** quem está no card é avisado quando é colocado como responsável, incluído ou retirado, quando o card muda de etapa, recebe comentário, tem o prazo alterado ou é excluído. Os avisos chegam em tempo real; o sininho também lista os prazos vencidos, de hoje e próximos. Opcional: "Avisar também pelo navegador" (aviso do sistema com a aba em segundo plano).
- **Configurações (menu novo, só Master):** etapas (nome, cor, ordem, limite de cards, etapa final e exigências para entrar: responsável, prazo, descrição ou checklist concluído), **passo a passo** (Livre, Passo a passo — uma etapa por vez, com opção de voltar — ou Personalizado, escolhendo os caminhos permitidos), etiquetas e quais notificações são enviadas.
- O passo a passo, os limites e as exigências são conferidos também no banco; as notificações são criadas pelo próprio banco (ninguém consegue forjar).

**Banco:** rode no Supabase (SQL Editor) `supabase/migrations/20261120100000_kanban.sql`.

## Comunicação e notificações push

- **Aba "Comunicação"** (vertical, na lateral direita): quem tem a permissão **"Enviar comunicados para a equipe"** (Master e Coordenador por padrão; ajustável em **Usuários → Permissões**) escreve um aviso de até **75 caracteres** e envia para **todos os usuários ativos**. O aviso chega como **notificação push** e aparece no **sininho**. A aba mostra os últimos comunicados enviados.
- **Push do Kanban:** todo aviso de card que já ia para o sininho (mudança de etapa, responsável, participante, comentário, prazo, arquivamento, exclusão) também vai por push para quem está vinculado ao card.
- **Clicar na notificação** (no sininho ou no push do celular/computador) abre o sistema direto no card. Comunicados abrem o sininho.
- **Ativar em cada aparelho:** sininho → **Ativar notificações neste aparelho** → permitir. Depois disso aparece **Testar**.
  - **iPhone/iPad (iOS 16.4 ou mais novo):** no Safari, abra o sistema → **Compartilhar → Adicionar à Tela de Início** → abra pelo ícone **Gestão 2.0** e ative pelo sininho. No Safari comum (fora do ícone), a Apple não permite push.
  - **Android, Windows e Mac:** funciona direto no Chrome, Edge, Firefox ou Safari.
- Cada aparelho fica ligado a quem entrou por último nele; ao **Sair**, o aparelho para de receber os avisos dessa pessoa.

**Configuração (uma vez):**
1. **Banco:** rode no SQL Editor `supabase/migrations/20261121100000_comunicacao_push.sql` (precisa do `20261120100000_kanban.sql` antes). Ele liga a extensão **pg_net**, que o banco usa para chamar a função de envio.
2. **Função:** Edge Functions → Deploy a new function → Via Editor → nome **`enviar-push`** → cole `supabase/functions/enviar-push/index.ts` → Deploy. Em **Settings**, **desligue "Verify JWT"**.
   Linha de comando: `supabase functions deploy enviar-push --no-verify-jwt`
3. Nada mais: as chaves do push (VAPID) são geradas e guardadas no banco sozinhas, na primeira vez que alguém ativa as notificações. Opcional: o segredo `PUSH_CONTATO` (ex.: `mailto:voce@eaumbel.com.br`) troca o contato informado aos serviços de push.

Se a função ficar com outro endereço, ajuste a coluna `funcao_url` da tabela `push_config`.

## Aparência: Tema CRM e layout clássico

O sistema abre no **Tema CRM**:
- menu no alto, com ícones que crescem e mostram o nome ao passar o mouse;
- fundo off-white no tema claro e tons de cinza no escuro;
- botões vermelhos;
- à direita: sininho, tela cheia, atualizar, lua/sol (claro/escuro, vale só no aparelho de cada pessoa) e o menu ☰ (Meus dados, Minha senha, Sair; no celular também lista todas as telas).

**Voltar ao layout anterior (ponto de backup `TEMA_CRM`):**
- **Na hora, sem publicar nada:** o Master entra em **Configurações → Aparência → Clássico (versão anterior)**. Vale para todos.
- **No código:** o branch `TEMA_CRM` no GitHub guarda a versão anterior ao tema (não apague). No Claude Code, o comando `/TEMA_CRM` (arquivo `.claude/commands/TEMA_CRM.md`) faz a volta passo a passo.

## E-mail (gateway SMTP e templates)

Em **Configurações → E-mail** (só o Master):
- **Servidor de e-mail (SMTP):**
  - padrão Gmail: `smtp.gmail.com`, porta **465**, SSL/TLS;
  - login, senha, nome e e-mail do remetente e "responder para";
  - botões **Testar conexão** e **Enviar teste**;
  - chave **Envio de e-mails ligado**.
- **Templates de e-mail:**
  - cada template tem nome, **chave** (o nome que a rotina usa), assunto e mensagem (texto simples ou HTML);
  - variáveis `{{nome}}`, `{{email}}`, `{{empresa}}`, `{{corretor}}`, `{{link}}`, `{{data}}`, `{{hora}}` ou qualquer outra enviada pela rotina;
  - pré-visualização ao lado e envio de teste antes de salvar.
- **Últimos envios:** registro de cada e-mail (ok ou motivo da falha).

**Gmail:** a conta precisa da verificação em duas etapas e de uma **senha de app** (myaccount.google.com/apppasswords). A senha normal não funciona. O Gmail aceita cerca de 500 e-mails por dia; o sistema para em 450 (segredo opcional `EMAIL_LIMITE_DIA`). O Supabase bloqueia as portas 25 e 587, então use a 465.

**Segurança:** a senha fica só no banco e só a função `enviar-email` a lê. Nem a tela do Master recebe a senha de volta.

**Publicar:**
1. Supabase → SQL Editor: rodar `supabase/migrations/20261121100000_email.sql`.
2. Supabase → Edge Functions → **Deploy a new function** → nome `enviar-email` → colar `supabase/functions/enviar-email/index.ts` → Deploy, com **Verify JWT desligado** (a função confere quem chama).

**Rotinas automáticas:** chamam `POST /functions/v1/enviar-email` com `Authorization: Bearer <service_role>` e o corpo `{"acao": "enviar", "para": "...", "template": "chave", "dados": {...}}`.

## SMS (Twilio)

Em **Configurações → SMS** (só o Master):
- **Conta do Twilio:**
  - Account SID, Auth Token e remetente (número do Twilio com `+` e código do país, ou um Messaging Service SID `MG…`);
  - chave **Envio de SMS ligado**;
  - botões **Testar conta** e **Enviar teste**.
- **Templates de SMS:**
  - cada template tem nome, **chave** (o nome que a rotina usa) e texto com variáveis `{{nome}}`, `{{empresa}}`, `{{corretor}}`, `{{data}}`, `{{hora}}`, `{{link}}` ou qualquer outra que a rotina enviar;
  - opção **remover acentos** (ligada por padrão): sem acento cabem 160 caracteres por SMS, com acento só 70;
  - contador de caracteres e de SMS, e pré-visualização "no celular".
- **Últimos envios:** status do Twilio (na fila, enviado, entregue, não entregue) e motivo das falhas. O botão **Atualizar status** consulta o Twilio.

**No Twilio:**
- Account SID e Auth Token ficam em Console → Account Info.
- Compre um número com SMS.
- Libere o Brasil em Messaging → Settings → Geo permissions.
- Conta trial só envia para números verificados.

Os números do Brasil podem ser digitados como `(43) 99999-0000`; o sistema converte para `+5543999990000`. O limite é de 200 SMS por dia (segredo opcional `SMS_LIMITE_DIA`).

**Segurança:** o Auth Token fica só no banco e só a função `enviar-sms` o lê.

**Publicar:**
1. Supabase → SQL Editor: rodar `supabase/migrations/20261122100000_sms.sql`.
2. Supabase → Edge Functions → **Deploy a new function** → nome `enviar-sms` → colar `supabase/functions/enviar-sms/index.ts` → Deploy, com **Verify JWT desligado**.

**Rotinas automáticas:** chamam `POST /functions/v1/enviar-sms` com `Authorization: Bearer <service_role>` e o corpo `{"acao": "enviar", "para": "(43) 99999-0000", "template": "chave", "dados": {...}}`.
