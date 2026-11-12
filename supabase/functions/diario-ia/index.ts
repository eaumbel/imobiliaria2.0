// Imobiliária 2.0 · Gestão comercial — análise do Diário de bordo por IA.
// Lê o mantra da equipe (valores, deveres, virtudes) e as palavras-chave,
// analisa o dia descrito pelo corretor e devolve um relatório completo:
// diagnóstico, nota de execução (0–100) com confiança, pontos fortes e fracos,
// plano de ação, desafio, pergunta de reflexão, fatos/lacunas, oportunidades,
// pilares, técnicas, detalhes da nota e registros a lançar.
// Provedor de IA (cadastre UM destes segredos no Supabase):
//   GEMINI_API_KEY     → Google Gemini (tem plano gratuito, sem cartão)
//   ANTHROPIC_API_KEY  → Claude, da Anthropic (pago por uso)
// Opcional: MODELO_IA para trocar o modelo do provedor escolhido.
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
const LISTA_STR = S("array", { items: STR });
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
    pontos_fortes: S("array", { maxItems: 4, items: S("object", { properties: { titulo: STR, evidencia: STR, impacto: STR, como_repetir: STR }, required: ["titulo", "evidencia", "impacto", "como_repetir"] }) }),
    pontos_fracos: S("array", { maxItems: 4, items: S("object", { properties: { titulo: STR, evidencia: STR, impacto: STR, como_corrigir: STR }, required: ["titulo", "evidencia", "impacto", "como_corrigir"] }) }),
    plano_acao: S("array", { maxItems: 4, items: S("object", { properties: { prioridade: S("string", { enum: ["alta", "media", "baixa"] }), prazo: STR, acao: STR, meta: STR, conclusao: STR }, required: ["prioridade", "acao", "conclusao"] }) }),
    desafio: STR,
    pergunta_reflexao: STR,
    fatos: LISTA_STR, interpretacoes: LISTA_STR, lacunas: LISTA_STR,
    oportunidades_perdidas: LISTA_STR,
    pilares: S("array", { maxItems: 12, items: S("object", { properties: { item: STR, situacao: S("string", { enum: ["atendido", "parcial", "nao_atendido", "sem_evidencia"] }), avaliacao: STR }, required: ["item", "situacao", "avaliacao"] }) }),
    tecnicas: S("array", { maxItems: 4, items: S("object", { properties: { tecnica: STR, como_aplicar: STR }, required: ["tecnica", "como_aplicar"] }) }),
    nota_detalhes: S("array", { maxItems: 5, items: S("object", { properties: { criterio: STR, pontos: S("integer"), maximo: S("integer"), comentario: STR }, required: ["criterio", "pontos", "maximo", "comentario"] }) }),
    melhorar_diario: LISTA_STR,
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
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return erro(405, "Método não permitido.");

  const chaveGemini = Deno.env.get("GEMINI_API_KEY");
  const chaveClaude = Deno.env.get("ANTHROPIC_API_KEY");
  if (!chaveGemini && !chaveClaude) return erro(500, "A inteligência ainda não foi configurada: cadastre o segredo GEMINI_API_KEY (gratuito) em Edge Functions → Secrets no Supabase.");

  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  const { data: ud } = await admin.auth.getUser(token);
  if (!ud?.user) return erro(401, "Sessão expirada. Entre novamente.");
  const { data: me } = await admin.from("perfis").select("nome, perfil, ativo, especialidade").eq("id", ud.user.id).maybeSingle();
  if (!me || !me.ativo) return erro(403, "Seu acesso está inativo.");

  let body: Record<string, any>;
  try { body = await req.json(); } catch { return erro(400, "Requisição inválida."); }
  const texto = String(body.texto ?? "").trim().slice(0, 8000);
  const dataDia = /^\d{4}-\d{2}-\d{2}$/.test(String(body.data ?? "")) ? String(body.data) : new Date().toISOString().slice(0, 10);
  if (texto.length < 15) return erro(400, "Descreva o seu dia com um pouco mais de detalhe.");
  const ctx = body.contexto ?? {};

  const { data: cfgRow } = await admin.from("config").select("data").eq("id", "diario").maybeSingle();
  const c = { ...PADRAO, ...(cfgRow?.data ?? {}) } as typeof PADRAO;

  // Limite de análises por corretor a cada 24 horas
  const limite = Math.max(1, Math.min(50, Number(c.limite) || 3));
  const desde = new Date(Date.now() - 24 * 3600 * 1000).toISOString();
  const { count: usadas } = await admin.from("uso_ia").select("id", { count: "exact", head: true }).eq("usuario", ud.user.id).gte("em", desde);
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
- diagnostico: o_que_aconteceu, produtividade, principal_avanco, principal_problema, atencao_amanha (2 a 4 frases cada).
- pontos_fortes e pontos_fracos: só com evidência no relato; se não houver, devolva lista vazia.
- plano_acao: 2 a 4 ações para o próximo dia útil, cada uma com prioridade, prazo (AAAA-MM-DD), meta mensurável e critério de conclusão.
- desafio: um desafio prático e curto para amanhã. pergunta_reflexao: uma pergunta que faça o corretor pensar.
- pilares: avalie cada valor, dever e virtude como atendido, parcial, nao_atendido ou sem_evidencia.
- tecnicas: técnicas comerciais aplicáveis ao caso (ex.: perguntas de diagnóstico, SPIN, ancoragem de preço, fechamento por alternativa, follow-up com prazo).

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

  // ---------- Google Gemini ----------
  if (chaveGemini) {
    const formato = `\n\nResponda SOMENTE com um objeto JSON válido (sem texto fora dele) que siga exatamente este esquema JSON:\n${JSON.stringify(ESQUEMA)}`;
    let g: Response;
    try {
      g = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${Deno.env.get("MODELO_IA") ?? "gemini-flash-latest"}:generateContent`, {
        method: "POST",
        headers: { "content-type": "application/json", "x-goog-api-key": chaveGemini },
        body: JSON.stringify({
          systemInstruction: { parts: [{ text: sistema + formato }] },
          contents: [{ role: "user", parts: [{ text: usuario }] }],
          generationConfig: { responseMimeType: "application/json", temperature: 0.4, maxOutputTokens: 8192 },
        }),
      });
    } catch {
      return erro(502, "Não foi possível falar com o serviço de inteligência. Tente de novo em instantes.");
    }
    const gj = await g.json().catch(() => ({}));
    if (!g.ok) {
      const msg = gj?.error?.message ?? "";
      if (g.status === 400 && /API key/i.test(msg)) return erro(500, "A chave GEMINI_API_KEY configurada no Supabase é inválida.");
      if (g.status === 403) return erro(500, "A chave GEMINI_API_KEY não tem permissão. Gere outra em aistudio.google.com.");
      if (g.status === 404) return erro(500, "Modelo de IA não encontrado. Ajuste o segredo MODELO_IA no Supabase.");
      if (g.status === 429) return erro(503, "Limite gratuito de análises atingido por agora. Tente de novo em alguns minutos.");
      if (g.status >= 500) return erro(503, "O serviço de inteligência está ocupado. Tente de novo em um minuto.");
      return erro(502, "O serviço de inteligência recusou a análise: " + msg);
    }
    const txt = (gj?.candidates?.[0]?.content?.parts ?? []).map((p: any) => p.text ?? "").join("").trim();
    let a: any;
    try { a = JSON.parse(txt.replace(/^```(?:json)?\s*|\s*```$/g, "")); } catch { return erro(502, "A inteligência não devolveu uma análise válida. Tente de novo."); }
    await admin.from("uso_ia").insert({ usuario: ud.user.id });
    return resp(200, normalizar(a));
  }

  // ---------- Claude (Anthropic) ----------
  let r: Response;
  try {
    r = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: { "content-type": "application/json", "x-api-key": chaveClaude!, "anthropic-version": "2023-06-01" },
      body: JSON.stringify({
        model: Deno.env.get("MODELO_IA") ?? "claude-sonnet-5-5",
        max_tokens: 6000,
        system: sistema + "\n\nResponda chamando a ferramenta registrar_relatorio.",
        tools: [{ name: "registrar_relatorio", description: "Registra o relatório do dia do corretor.", input_schema: ESQUEMA }],
        tool_choice: { type: "tool", name: "registrar_relatorio" },
        messages: [{ role: "user", content: usuario }],
      }),
    });
  } catch {
    return erro(502, "Não foi possível falar com o serviço de inteligência. Tente de novo em instantes.");
  }
  const j = await r.json().catch(() => ({}));
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
  return resp(200, normalizar(uso.input));
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
