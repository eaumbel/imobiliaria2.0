// Imobiliária 2.0 · Gestão comercial — análise do Diário de bordo por IA.
// Lê o mantra da equipe (valores, deveres, virtudes) e as palavras-chave,
// analisa o dia descrito pelo corretor e devolve um relatório completo:
// diagnóstico, nota de execução (0–100) com confiança, pontos fortes e fracos,
// plano de ação, desafio, pergunta de reflexão, fatos/lacunas, oportunidades,
// pilares, técnicas, detalhes da nota e registros a lançar.
// Provedor de IA (cadastre UM destes segredos no Supabase):
//   OPENAI_API_KEY     → OpenAI (pago por uso; formato garantido e resposta em streaming, como no Lovable)
//   GEMINI_API_KEY     → Google Gemini (tem plano gratuito, sem cartão)
//   ANTHROPIC_API_KEY  → Claude, da Anthropic (pago por uso)
// Se houver mais de um, a ordem é OpenAI, Gemini, Claude; o segredo PROVEDOR_IA (openai | gemini | claude) escolhe.
// Opcionais: MODELO_OPENAI (padrão gpt-6-astra) e ESFORCO_IA (minimal | low | medium | high; padrão low) para a
// OpenAI; MODELO_IA para Gemini/Claude.
// Publicar com "Verify JWT" DESLIGADO (a função confere a sessão).
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const resp = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
const erro = (status: number, msg: string) => resp(status, { erro: msg });

const PADRAO = {
  valores: ["Ética e transparência com o cliente", "Foco em resultado", "Trabalho em equipe"],
  deveres: ["Responder os leads da roleta em até 5 minutos", "Registrar todas as visitas no sistema", "Fazer follow-up com cada cliente em até 24 horas", "Prospectar novos clientes todos os dias"],
  virtudes: ["Disciplina", "Persistência", "Empatia", "Organização"],
  palavras: [
    { termo: "vendi", acao: "venda" }, { termo: "fechei negócio", acao: "venda" }, { termo: "assinou contrato", acao: "venda" },
    { termo: "visitei", acao: "visita" }, { termo: "mostrei o imóvel", acao: "visita" },
    { termo: "agendei", acao: "agenda" }, { termo: "marquei visita", acao: "agenda" },
  ],
  instrucoes: "",
  prompt: "Você é um mentor comercial sênior, especialista em gestão de desempenho, comportamento profissional, negociação, persuasão ética, angariação de imóveis e venda de imóveis prontos.\n\nSua função é analisar os relatos diários dos corretores com rigor, sinceridade, objetividade e compromisso com a evolução profissional.\n\nVocê deve atuar como um mentor que respeita a pessoa, mas não protege comportamentos improdutivos de críticas necessárias.\n\nNão elogie por educação. Não critique por estilo. Fundamente suas conclusões em fatos relatados ou dados autorizados do CRM.\n\nSepare fatos, interpretações e recomendações. Não invente acontecimentos, números, intenções, emoções, resultados ou oportunidades.\n\nConsidere os princípios de reflexão pessoal, escuta ativa, construção de confiança, persuasão ética, diagnóstico, negociação tática, disciplina comercial e os pilares inegociáveis da operação.\n\nAvalie o processo, não apenas o resultado final. Um dia sem venda pode ter sido produtivo. Um dia com venda pode conter falhas que precisam ser corrigidas.",
  limite: 3,
};
const ACAO_TXT: Record<string, string> = {
  venda: "venda concluída (tipo 'venda')",
  visita: "visita já realizada (tipo 'visita')",
  agenda: "compromisso ou visita futura (tipo 'agenda')",
};

// Estrutura esperada da resposta (usada no prompt e na ferramenta do Claude)
const S = (type: string, extra: Record<string, unknown> = {}) => ({ type, ...extra });
const STR = S("string");
const LISTA_CURTA = S("array", { maxItems: 4, items: STR });
const ESQUEMA = {
  type: "object",
  properties: {
    nota: S(["integer", "null"] as unknown as string, { minimum: 0, maximum: 100, description: "Nota de execução 0–100. Use null se os dados forem insuficientes." }),
    confianca: S("string", { enum: ["alta", "media", "baixa"] }),
    nota_motivo: S("string", { description: "Frase curta explicando a nota ou por que não foi possível dar nota." }),
    diagnostico: S("object", {
      properties: {
        o_que_aconteceu: STR, produtividade: STR, principal_avanco: STR, principal_problema: STR, atencao_amanha: STR,
      },
      required: ["o_que_aconteceu", "produtividade", "principal_avanco", "principal_problema", "atencao_amanha"],
    }),
    pontos_fortes: S("array", { maxItems: 3, items: S("object", { properties: { titulo: STR, evidencia: STR, impacto: STR, como_repetir: STR }, required: ["titulo", "evidencia", "impacto", "como_repetir"] }) }),
    pontos_fracos: S("array", { maxItems: 3, items: S("object", { properties: { titulo: STR, evidencia: STR, impacto: STR, como_corrigir: STR }, required: ["titulo", "evidencia", "impacto", "como_corrigir"] }) }),
    plano_acao: S("array", { maxItems: 3, items: S("object", { properties: { prioridade: S("string", { enum: ["alta", "media", "baixa"] }), prazo: STR, acao: STR, meta: STR, conclusao: STR }, required: ["prioridade", "acao", "conclusao"] }) }),
    desafio: STR,
    pergunta_reflexao: STR,
    fatos: LISTA_CURTA, interpretacoes: LISTA_CURTA, lacunas: LISTA_CURTA,
    oportunidades_perdidas: LISTA_CURTA,
    pilares: S("array", { maxItems: 12, items: S("object", { properties: { item: STR, situacao: S("string", { enum: ["atendido", "parcial", "nao_atendido", "sem_evidencia"] }), avaliacao: STR }, required: ["item", "situacao", "avaliacao"] }) }),
    tecnicas: S("array", { maxItems: 3, items: S("object", { properties: { tecnica: STR, como_aplicar: STR }, required: ["tecnica", "como_aplicar"] }) }),
    nota_detalhes: S("array", { maxItems: 4, items: S("object", { properties: { criterio: STR, pontos: S("integer"), maximo: S("integer"), comentario: STR }, required: ["criterio", "pontos", "maximo", "comentario"] }) }),
    melhorar_diario: LISTA_CURTA,
    registros: S("array", {
      maxItems: 10,
      items: S("object", {
        properties: {
          tipo: S("string", { enum: ["venda", "visita", "agenda"] }), cliente: STR, valor: S("number"), imovel: STR, endereco: STR,
          data: STR, hora: STR, tipoVisita: S("string", { enum: ["Venda", "Locação", "Captação", "Avaliação", "Lançamento", "Retorno"] }), descricao: STR,
        },
        required: ["tipo"],
      }),
    }),
  },
  required: ["confianca", "nota_motivo", "diagnostico", "pontos_fortes", "pontos_fracos", "plano_acao", "desafio", "pergunta_reflexao",
    "fatos", "interpretacoes", "lacunas", "oportunidades_perdidas", "pilares", "tecnicas", "nota_detalhes", "melhorar_diario", "registros"],
};

const brl = (v: unknown) => (typeof v === "number" && isFinite(v) ? v.toLocaleString("pt-BR", { style: "currency", currency: "BRL" }) : "não informado");

Deno.serve(async (req) => {
  const inicio = Date.now();
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return erro(405, "Método não permitido.");

  const chaveGemini = Deno.env.get("GEMINI_API_KEY");
  const chaveClaude = Deno.env.get("ANTHROPIC_API_KEY");
  const chaveOpenAI = Deno.env.get("OPENAI_API_KEY");
  if (!chaveGemini && !chaveClaude && !chaveOpenAI) return erro(500, "A inteligência ainda não foi configurada: cadastre o segredo OPENAI_API_KEY ou GEMINI_API_KEY (gratuito) em Edge Functions → Secrets no Supabase.");
  const pref = (Deno.env.get("PROVEDOR_IA") ?? "").trim().toLowerCase();
  const provedor = pref === "openai" && chaveOpenAI ? "openai" : pref === "gemini" && chaveGemini ? "gemini" : pref === "claude" && chaveClaude ? "claude"
    : chaveOpenAI ? "openai" : chaveGemini ? "gemini" : "claude";

  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  const { data: ud } = await admin.auth.getUser(token);
  if (!ud?.user) return erro(401, "Sessão expirada. Entre novamente.");
  // Perfil, configuração e uso das últimas 24 h: consultas independentes, feitas ao mesmo tempo
  const desde = new Date(Date.now() - 24 * 3600 * 1000).toISOString();
  const [{ data: me }, { data: cfgRow }, { count: usadas }] = await Promise.all([
    admin.from("perfis").select("nome, perfil, ativo, especialidade").eq("id", ud.user.id).maybeSingle(),
    admin.from("config").select("data").eq("id", "diario").maybeSingle(),
    admin.from("uso_ia").select("id", { count: "exact", head: true }).eq("usuario", ud.user.id).gte("em", desde),
  ]);
  if (!me || !me.ativo) return erro(403, "Seu acesso está inativo.");

  let body: Record<string, any>;
  try { body = await req.json(); } catch { return erro(400, "Requisição inválida."); }
  const texto = String(body.texto ?? "").trim().slice(0, 8000);
  const dataDia = /^\d{4}-\d{2}-\d{2}$/.test(String(body.data ?? "")) ? String(body.data) : new Date().toISOString().slice(0, 10);
  if (texto.length < 15) return erro(400, "Descreva o seu dia com um pouco mais de detalhe.");
  const ctx = body.contexto ?? {};

  const c = { ...PADRAO, ...(cfgRow?.data ?? {}) } as typeof PADRAO;

  // Limite de análises por corretor a cada 24 horas
  const limite = Math.max(1, Math.min(50, Number(c.limite) || 3));
  if ((usadas ?? 0) >= limite) return erro(429, `Você já usou as ${limite} análises das últimas 24 horas. Tente de novo mais tarde.`);
  const lista = (a: string[]) => (Array.isArray(a) && a.length ? a.map((x) => "- " + x).join("\n") : "- (não definido)");
  const palavras = (Array.isArray(c.palavras) ? c.palavras : PADRAO.palavras).map((p) => `- "${p.termo}" → ${ACAO_TXT[p.acao] ?? p.acao}`).join("\n");
  const diaSemana = new Date(dataDia + "T12:00:00-03:00").toLocaleDateString("pt-BR", { weekday: "long", timeZone: "America/Sao_Paulo" });

  const numeros = [
    `VGV vendido no dia: ${brl(ctx.vgvDia)}`,
    `VGV acumulado no mês (individual): ${brl(ctx.vgvMes)}`,
    `Meta mensal individual: ${ctx.metaIndividual ? brl(ctx.metaIndividual) : "não definida"}`,
    ctx.metaEquipe !== undefined ? `Meta mensal da equipe: ${ctx.metaEquipe ? brl(ctx.metaEquipe) : "não definida"}` : "",
    ctx.vgvEquipeMes !== undefined ? `VGV acumulado da equipe no mês: ${brl(ctx.vgvEquipeMes)}` : "",
    ctx.totalCorretores ? `Corretores com meta definida: ${ctx.corretoresComMeta ?? 0} de ${ctx.totalCorretores}` : "",
  ].filter(Boolean).join("\n");

  const sistema = `${String(c.prompt || PADRAO.prompt).trim()}

REGRAS DO RELATÓRIO
- Analise o diário de bordo de um corretor da Imobiliária 2.0 e produza um relatório que o ajude a executar melhor e vender mais.
- Separe FATOS (o que está escrito), INTERPRETAÇÕES (o que você deduz) e LACUNAS (o que faltou informar).
- Use os números do sistema abaixo quando forem úteis; não suponha números que não existem.
- Se o relato for curto ou vago, diga isso, peça os dados que faltam em "melhorar_diario" e reduza a confiança. Com dados insuficientes, use "nota": null e "confianca": "baixa".

MANTRA DA EQUIPE (pilares da avaliação)
Valores:
${lista(c.valores)}
Deveres:
${lista(c.deveres)}
Virtudes:
${lista(c.virtudes)}
${c.instrucoes ? `\nInstruções do gestor:\n${c.instrucoes}\n` : ""}
NOTA DE EXECUÇÃO (0 a 100), somando estes critérios em "nota_detalhes":
- Produtividade e volume de atividades (0–30)
- Avanço no funil e resultado comercial (0–30)
- Alinhamento aos pilares do mantra (0–20)
- Qualidade do registro: clareza, números, próximos passos (0–20)

CONTEÚDO
SEJA DIRETO: frases curtas e objetivas, sem repetir a mesma informação em seções diferentes.
- diagnostico: o_que_aconteceu, produtividade, principal_avanco, principal_problema, atencao_amanha (1 a 2 frases cada).
- pontos_fortes e pontos_fracos: até 3 cada, só com evidência no relato; se não houver, devolva lista vazia. Cada campo em 1 frase.
- plano_acao: 2 a 3 ações para o próximo dia útil, cada uma com prioridade, prazo (AAAA-MM-DD), meta mensurável e critério de conclusão.
- fatos, interpretacoes, lacunas, oportunidades_perdidas e melhorar_diario: até 4 itens curtos cada.
- desafio: um desafio prático e curto para amanhã. pergunta_reflexao: uma pergunta que faça o corretor pensar.
- pilares: avalie cada valor, dever e virtude como atendido, parcial, nao_atendido ou sem_evidencia, com "avaliacao" de no máximo 15 palavras.
- tecnicas: até 3 técnicas comerciais aplicáveis ao caso (ex.: perguntas de diagnóstico, SPIN, ancoragem de preço, fechamento por alternativa, follow-up com prazo).

LANÇAMENTOS AUTOMÁTICOS ("registros")
Crie itens somente quando o texto descrever um fato que corresponda a estas palavras-chave (ou expressão de mesmo sentido, claramente):
${palavras}
Não invente dados. Venda só com valor informado ("300 mil" = 300000; "1,2 milhão" = 1200000). Datas AAAA-MM-DD a partir do dia do diário (${dataDia}, ${diaSemana}, horário de Brasília); "amanhã" = dia seguinte. Hora em 24 horas (HH:MM). Se nada corresponder, devolva lista vazia.

Escreva tudo em português do Brasil.`;

  const usuario = `Corretor: ${me.nome}${me.especialidade ? ` (especialidade: ${me.especialidade})` : ""}
Dia do diário: ${dataDia} (${diaSemana})

Números do sistema:
${numeros}

Relato do corretor:
"""
${texto}
"""`;

  // ---------- OpenAI (como no Diário do Lovable) ----------
  // Formato do relatório garantido pela própria OpenAI (json_schema estrito) e resposta recebida aos poucos
  // (streaming). O raciocínio fica em esforço "low" (mais rápido); ESFORCO_IA ajusta.
  if (provedor === "openai") {
    const modelo = Deno.env.get("MODELO_OPENAI") ?? "gpt-6-astra";
    const esforco = ["minimal", "low", "medium", "high"].includes(Deno.env.get("ESFORCO_IA") ?? "") ? Deno.env.get("ESFORCO_IA")! : "low";
    const limiteMs = Number(Deno.env.get("LIMITE_IA_MS")) || 110_000;
    const ctl = new AbortController(), timer = setTimeout(() => ctl.abort(), limiteMs);
    const chamar = (comRaciocinio: boolean) => fetch("https://api.openai.com/v1/responses", {
      method: "POST", signal: ctl.signal,
      headers: { "content-type": "application/json", authorization: `Bearer ${chaveOpenAI}` },
      body: JSON.stringify({
        model: modelo, instructions: sistema, input: usuario, stream: true, store: false, max_output_tokens: 16000,
        text: { format: { type: "json_schema", name: "relatorio_diario", strict: true, schema: esquemaEstrito(ESQUEMA) } },
        ...(comRaciocinio ? { reasoning: { effort: esforco } } : {}),
      }),
    });
    let o: Response, comRaciocinio = true, txt = "", fim: any = null, falha = "";
    try {
      o = await chamar(true);
      if (!o.ok) {
        const ej = await o.json().catch(() => ({}));
        const msg = ej?.error?.message ?? "";
        // modelo sem raciocínio configurável: repete sem a opção
        if (o.status === 400 && /reasoning/i.test(msg)) { comRaciocinio = false; o = await chamar(false); }
        else { clearTimeout(timer); return erroOpenAI(o.status, msg, ej?.error?.code, modelo); }
        if (!o.ok) { const e2 = await o.json().catch(() => ({})); clearTimeout(timer); return erroOpenAI(o.status, e2?.error?.message ?? "", e2?.error?.code, modelo); }
      }
      // Lê os eventos do streaming: junta os pedaços do texto e guarda o evento final
      const leitor = o.body!.pipeThrough(new TextDecoderStream()).getReader();
      let buf = "";
      for (;;) {
        const { value, done } = await leitor.read();
        if (done) break;
        buf += value;
        let i;
        while ((i = buf.indexOf("\n\n")) >= 0) {
          const bloco = buf.slice(0, i); buf = buf.slice(i + 2);
          const dados = bloco.split("\n").filter((l) => l.startsWith("data:")).map((l) => l.slice(5).trim()).join("");
          if (!dados || dados === "[DONE]") continue;
          let ev: any; try { ev = JSON.parse(dados); } catch { continue; }
          if (ev.type === "response.output_text.delta") txt += ev.delta ?? "";
          else if (ev.type === "response.completed" || ev.type === "response.incomplete") fim = ev.response;
          else if (ev.type === "response.failed" || ev.type === "error") falha = ev.response?.error?.message ?? ev.message ?? ev.error?.message ?? "falha";
        }
      }
    } catch (e) {
      clearTimeout(timer);
      if ((e as Error)?.name === "AbortError") return erro(504, `A inteligência (OpenAI · ${modelo}, raciocínio ${comRaciocinio ? esforco : "sem"}) demorou mais de ${Math.round(limiteMs / 1000)} s e a análise foi interrompida. Tente de novo; se continuar, peça ao administrador para baixar o esforço (segredo ESFORCO_IA = minimal) ou trocar o modelo (MODELO_OPENAI).`);
      return erro(502, "Não foi possível falar com o serviço de inteligência. Tente de novo em instantes.");
    }
    clearTimeout(timer);
    if (falha) return erro(502, "O serviço de inteligência recusou a análise: " + falha);
    if (fim?.status === "incomplete") return erro(502, `A análise saiu cortada (${fim?.incomplete_details?.reason === "max_output_tokens" ? "limite de tamanho" : fim?.incomplete_details?.reason ?? "incompleta"} no modelo ${modelo}). Tente de novo.`);
    const recusa = (fim?.output ?? []).flatMap((x: any) => x?.content ?? []).find((c: any) => c?.type === "refusal");
    if (recusa) return erro(502, "A inteligência se recusou a analisar este relato: " + (recusa.refusal ?? ""));
    let a: any;
    try { a = JSON.parse(txt); } catch { return erro(502, "A inteligência não devolveu uma análise válida. Tente de novo."); }
    await admin.from("uso_ia").insert({ usuario: ud.user.id });
    return resp(200, { ...normalizar(a), meta: { provedor: "openai", modelo, raciocinio: comRaciocinio ? esforco : "sem", ms: Date.now() - inicio } });
  }

  // ---------- Google Gemini ----------
  if (provedor === "gemini") {
    const formato = `\n\nResponda SOMENTE com um objeto JSON válido (sem texto fora dele) que siga exatamente este esquema JSON:\n${JSON.stringify(ESQUEMA)}`;
    // O modelo "pensa" antes de responder (raciocínio interno), o que é a maior parte da espera. Para preencher
    // um relatório com estrutura fixa isso não é necessário. Cada geração do Gemini aceita uma forma diferente
    // de reduzir o raciocínio; tentamos da mais rápida para a mais compatível (RACIOCINIO_IA=1 deixa o padrão).
    // No Gemini o raciocínio consome o mesmo limite de tokens da resposta: quando ele não pode ser desligado,
    // o limite sobe para o relatório não sair cortado.
    const modelo = Deno.env.get("MODELO_IA") ?? "gemini-flash-latest";
    const MODOS: { nome: string; cfg: Record<string, unknown>; max: number }[] = Deno.env.get("RACIOCINIO_IA") === "1"
      ? [{ nome: "padrao", cfg: {}, max: 16384 }]
      : [
          { nome: "desligado", cfg: { thinkingConfig: { thinkingBudget: 0 } }, max: 4096 },
          { nome: "minimo", cfg: { thinkingConfig: { thinkingLevel: "minimal" } }, max: 16384 },
          { nome: "baixo", cfg: { thinkingConfig: { thinkingLevel: "low" } }, max: 16384 },
          { nome: "padrao", cfg: {}, max: 16384 },
        ];
    const limiteMs = Number(Deno.env.get("LIMITE_IA_MS")) || 110_000; // o Supabase encerra a função em ~150 s; paramos antes, com mensagem clara
    const ate = Date.now() + limiteMs;
    let g: Response | null = null, gj: any = {}, modo = MODOS[0];
    try {
      for (const m of MODOS) {
        modo = m;
        const ctl = new AbortController(), t = setTimeout(() => ctl.abort(), Math.max(1000, ate - Date.now()));
        try {
          g = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${modelo}:generateContent`, {
            method: "POST", signal: ctl.signal,
            headers: { "content-type": "application/json", "x-goog-api-key": chaveGemini },
            body: JSON.stringify({
              systemInstruction: { parts: [{ text: sistema + formato }] },
              contents: [{ role: "user", parts: [{ text: usuario }] }],
              generationConfig: { responseMimeType: "application/json", temperature: 0.4, maxOutputTokens: m.max, ...m.cfg },
            }),
          });
          gj = await g.json().catch(() => ({}));
        } finally { clearTimeout(t); }
        // modelo não aceita esta forma de controlar o raciocínio: tenta a próxima
        if (!g.ok && g.status === 400 && /thinking/i.test(gj?.error?.message ?? "")) continue;
        break;
      }
    } catch (e) {
      if ((e as Error)?.name === "AbortError") return erro(504, `A inteligência (Gemini · ${modelo}) demorou mais de ${limiteMs / 1000} s e a análise foi interrompida. Tente de novo; se continuar, peça ao administrador para trocar o modelo (segredo MODELO_IA).`);
      return erro(502, "Não foi possível falar com o serviço de inteligência. Tente de novo em instantes.");
    }
    if (!g) return erro(502, "Não foi possível falar com o serviço de inteligência. Tente de novo em instantes.");
    if (!g.ok) {
      const msg = gj?.error?.message ?? "";
      if (g.status === 400 && /API key/i.test(msg)) return erro(500, "A chave GEMINI_API_KEY configurada no Supabase é inválida.");
      if (g.status === 403) return erro(500, "A chave GEMINI_API_KEY não tem permissão. Gere outra em aistudio.google.com.");
      if (g.status === 404) return erro(500, "Modelo de IA não encontrado. Ajuste o segredo MODELO_IA no Supabase.");
      if (g.status === 429) return erro(503, "Limite gratuito de análises atingido por agora. Tente de novo em alguns minutos.");
      if (g.status >= 500) return erro(503, "O serviço de inteligência está ocupado. Tente de novo em um minuto.");
      return erro(502, `O serviço de inteligência (Gemini · ${modelo}) recusou a análise: ` + msg);
    }
    const txt = (gj?.candidates?.[0]?.content?.parts ?? []).map((p: any) => p.text ?? "").join("").trim();
    let a: any;
    try { a = JSON.parse(txt.replace(/^```(?:json)?\s*|\s*```$/g, "")); } catch {
      if (gj?.candidates?.[0]?.finishReason === "MAX_TOKENS") return erro(502, `A análise saiu cortada (limite de tamanho atingido no modelo ${modelo}, raciocínio ${modo.nome}). Tente de novo.`);
      return erro(502, "A inteligência não devolveu uma análise válida. Tente de novo.");
    }
    await admin.from("uso_ia").insert({ usuario: ud.user.id });
    return resp(200, { ...normalizar(a), meta: { modelo, raciocinio: modo.nome, ms: Date.now() - inicio } });
  }

  // ---------- Claude (Anthropic) ----------
  let r: Response;
  const ctlC = new AbortController(), tC = setTimeout(() => ctlC.abort(), 110_000);
  try {
    r = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST", signal: ctlC.signal,
      headers: { "content-type": "application/json", "x-api-key": chaveClaude!, "anthropic-version": "2023-06-01" },
      body: JSON.stringify({
        model: Deno.env.get("MODELO_IA") ?? "claude-sonnet-5-5",
        max_tokens: 4096,
        system: sistema + "\n\nResponda chamando a ferramenta registrar_relatorio.",
        tools: [{ name: "registrar_relatorio", description: "Registra o relatório do dia do corretor.", input_schema: ESQUEMA }],
        tool_choice: { type: "tool", name: "registrar_relatorio" },
        messages: [{ role: "user", content: usuario }],
      }),
    });
  } catch (e) {
    clearTimeout(tC);
    if ((e as Error)?.name === "AbortError") return erro(504, "A inteligência (Claude) demorou mais de 110 s e a análise foi interrompida. Tente de novo; se continuar, peça ao administrador para trocar o modelo (segredo MODELO_IA).");
    return erro(502, "Não foi possível falar com o serviço de inteligência. Tente de novo em instantes.");
  }
  const j = await r.json().catch(() => ({}));
  clearTimeout(tC);
  if (!r.ok) {
    const msg = j?.error?.message ?? "";
    if (r.status === 401) return erro(500, "A chave ANTHROPIC_API_KEY configurada no Supabase é inválida.");
    if (/credit|billing|balance/i.test(msg)) return erro(402, "A conta da API da Anthropic está sem créditos.");
    if (r.status === 404 || /model/i.test(msg)) return erro(500, "Modelo de IA não encontrado. Ajuste o segredo MODELO_IA no Supabase.");
    if (r.status === 429 || r.status === 529) return erro(503, "O serviço de inteligência está ocupado. Tente de novo em um minuto.");
    return erro(502, "O serviço de inteligência recusou a análise: " + msg);
  }
  const uso = (j.content ?? []).find((b: any) => b.type === "tool_use");
  if (!uso?.input) return erro(502, "A inteligência não devolveu uma análise válida. Tente de novo.");
  await admin.from("uso_ia").insert({ usuario: ud.user.id });
  return resp(200, { ...normalizar(uso.input), meta: { modelo: Deno.env.get("MODELO_IA") ?? "claude-sonnet-5-5", ms: Date.now() - inicio } });
});

function normalizar(a: any) {
  const arr = (x: unknown) => (Array.isArray(x) ? x : []);
  const txt = (x: unknown) => (x == null ? "" : String(x));
  const strs = (x: unknown) => arr(x).map(txt).filter(Boolean);
  const notaNum = a.nota === null || a.nota === undefined || a.nota === "" ? null : Math.max(0, Math.min(100, Math.round(Number(a.nota))));
  const d = a.diagnostico ?? {};
  return {
    analise: {
      escala: 100,
      nota: Number.isFinite(notaNum as number) ? notaNum : null,
      confianca: ["alta", "media", "baixa"].includes(a.confianca) ? a.confianca : "media",
      nota_motivo: txt(a.nota_motivo),
      diagnostico: {
        o_que_aconteceu: txt(d.o_que_aconteceu), produtividade: txt(d.produtividade), principal_avanco: txt(d.principal_avanco),
        principal_problema: txt(d.principal_problema), atencao_amanha: txt(d.atencao_amanha),
      },
      pontos_fortes: arr(a.pontos_fortes).filter((x: any) => x?.titulo),
      pontos_fracos: arr(a.pontos_fracos).filter((x: any) => x?.titulo),
      plano_acao: arr(a.plano_acao).filter((x: any) => x?.acao),
      desafio: txt(a.desafio),
      pergunta_reflexao: txt(a.pergunta_reflexao),
      fatos: strs(a.fatos), interpretacoes: strs(a.interpretacoes), lacunas: strs(a.lacunas),
      oportunidades_perdidas: strs(a.oportunidades_perdidas),
      pilares: arr(a.pilares).filter((x: any) => x?.item),
      tecnicas: arr(a.tecnicas).filter((x: any) => x?.tecnica),
      nota_detalhes: arr(a.nota_detalhes).filter((x: any) => x?.criterio),
      melhorar_diario: strs(a.melhorar_diario),
    },
    registros: arr(a.registros).filter((r: any) => r && ["venda", "visita", "agenda"].includes(r.tipo)),
  };
}

// Esquema no formato "estrito" exigido pela OpenAI: todo objeto lista todas as propriedades em "required" e não
// aceita propriedades extras; o que era opcional passa a aceitar null. Remove limites que o modo estrito não usa.
function esquemaEstrito(no: any, opcional = false): any {
  if (!no || typeof no !== "object") return no;
  const out: any = {};
  for (const [k, v] of Object.entries(no)) if (!["minimum", "maximum", "maxItems", "minItems"].includes(k)) out[k] = v;
  if (out.type === "object" && out.properties) {
    const req = new Set<string>(Array.isArray(no.required) ? no.required : []);
    out.properties = Object.fromEntries(Object.entries(no.properties).map(([k, v]) => [k, esquemaEstrito(v, !req.has(k))]));
    out.required = Object.keys(out.properties);
    out.additionalProperties = false;
  }
  if (out.type === "array" && out.items) out.items = esquemaEstrito(out.items);
  if (opcional) {
    const t = Array.isArray(out.type) ? out.type : [out.type];
    if (!t.includes("null")) out.type = [...t, "null"];
    if (Array.isArray(out.enum) && !out.enum.includes(null)) out.enum = [...out.enum, null];
  }
  return out;
}

function erroOpenAI(status: number, msg: string, codigo: string | undefined, modelo: string) {
  if (status === 401) return erro(500, "A chave OPENAI_API_KEY configurada no Supabase é inválida.");
  if (codigo === "insufficient_quota" || /quota|billing|credit/i.test(msg)) return erro(402, "A conta da OpenAI está sem créditos. Avise o administrador.");
  if (status === 404 || codigo === "model_not_found") return erro(500, `Modelo de IA não encontrado (${modelo}). Ajuste o segredo MODELO_OPENAI no Supabase.`);
  if (status === 429) return erro(503, "Muitas solicitações no momento. Tente novamente em instantes.");
  if (status >= 500) return erro(503, "O serviço de inteligência está ocupado. Tente de novo em um minuto.");
  return erro(502, "O serviço de inteligência recusou a análise: " + msg);
}
