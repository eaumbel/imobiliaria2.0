---
description: Volta o Gestão 2.0 para o layout anterior ao Tema CRM (menu lateral clássico)
---

O usuário pediu para voltar ao layout anterior ao **Tema CRM** (ponto de backup `TEMA_CRM`).

Contexto:
- O tag git `TEMA_CRM` marca a última versão antes do Tema CRM (menu lateral escuro, fundo cinza claro, tema seguindo o aparelho).
- O Tema CRM (menu no alto em "dock", fundo off-white, escuro em tons de cinza, botão de lua/sol) convive com o layout clássico no mesmo arquivo `gestao/index.html`. A escolha fica em `config` → id `aparencia` → `{"layout": "crm" | "classico"}`; sem registro, vale `crm`.

Faça nesta ordem e explique ao usuário em português, sem termos técnicos:

1. **Volta imediata, sem publicar nada** (diga isto primeiro): o Master entra em **Configurações → Aparência → Clássico (versão anterior)**. Vale para todos na hora. Alternativa pelo Supabase (SQL Editor):
   ```sql
   insert into public.config (id, data) values ('aparencia', '{"layout": "classico"}'::jsonb)
   on conflict (id) do update set data = excluded.data;
   ```
2. **Se o usuário quiser que o clássico seja o padrão no código** (por exemplo, para novos navegadores nem piscarem o Tema CRM): em `gestao/index.html`, troque o padrão para `classico` em `layoutAtual()` (`=== 'crm' ? 'crm' : 'classico'`) e no script do `<head>` (adicionar a classe `tema-crm` só quando `localStorage['imob20-layout'] === 'crm'`). Rode os testes do navegador, faça commit no branch de trabalho, envie e pergunte se pode abrir a PR.
3. **Se o usuário pedir para apagar o Tema CRM do código**: confira `git log TEMA_CRM..HEAD -- gestao/index.html`. Se não houver outras mudanças além do Tema CRM, restaure com `git checkout TEMA_CRM -- gestao/index.html`. Se houver outras funcionalidades depois do tag, NÃO restaure o arquivo inteiro: remova só as partes do tema (CSS "TEMA CRM", `<header class="crm-top">`, script do `<head>`, funções `aplicarLayout/renderDock/renderCrm/crmMenu*`, ações `crm-*`/`ap-layout`, aba Aparência) e mantenha o resto. Mostre ao usuário o que sai antes de fazer commit.

Nunca force push, nunca mexa no `main` diretamente; abra PR só com o ok do usuário.
