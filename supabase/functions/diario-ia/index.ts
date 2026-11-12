// Imobiliária 2.0 · Gestão comercial — análise do Diário de bordo por IA.
// Lê o mantra da equipe (valores, deveres, virtudes) e as palavras-chave,
// analisa o dia descrito pelo corretor com o Claude (API da Anthropic) e
// devolve feedback, pontos fortes e fracos, melhorias e registros a lançar.
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
};
const ACAO_TXT: Record<string, string> = {
  venda: "venda concluída (tipo 'venda')",
  visita: "visita já realizada (tipo 'visita')",
  agenda: "compromisso ou visita futura (tipo 'agenda')",
};

const FERRAMENTA = {
  name: "registrar_analise",
  description: "Registra a análise do dia do corretor e os lançamentos identificados no texto.",
  input_schema: {
    type: "object",
    properties: {
      nota: { type: "integer", minimum: 0, maximum: 10, description: "Nota do dia de 0 a 10, com critério exigente." },
      feedback: { type: "string", description: "Feedback sincero e direto, de 4 a 8 frases, citando o que foi descrito." },
      pontos_fortes: { type: "array", items: { type: "string" }, maxItems: 5 },
      pontos_fracos: { type: "array", items: { type: "string" }, maxItems: 5 },
      melhorias: { type: "array", items: { type: "string" }, maxItems: 6, description: "Mudanças concretas para o próximo dia, focadas em gerar vendas." },
      mantra: {
        type: "array", maxItems: 8,
        items: { type: "object", properties: { item: { type: "string" }, avaliacao: { type: "string" } }, required: ["item", "avaliacao"] },
        description: "Valores, deveres ou virtudes do mantra com evidência (positiva ou negativa) no texto.",
      },
      registros: {
        type: "array", maxItems: 10,
        items: {
          type: "object",
          properties: {
            tipo: { type: "string", enum: ["venda", "visita", "agenda"] },
            cliente: { type: "string" },
            valor: { type: "number", description: "Valor em reais, só para venda. Ex.: 300 mil = 300000." },
            imovel: { type: "string", description: "Imóvel, edifício ou referência citada." },
            endereco: { type: "string" },
            data: { type: "string", description: "AAAA-MM-DD" },
            hora: { type: "string", description: "HH:MM em 24 horas" },
            tipoVisita: { type: "string", enum: ["Venda", "Locação", "Captação", "Avaliação", "Lançamento", "Retorno"] },
            descricao: { type: "string", description: "Resumo curto do registro." },
          },
          required: ["tipo"],
        },
      },
    },
    required: ["nota", "feedback", "pontos_fortes", "pontos_fracos", "melhorias", "mantra", "registros"],
  },
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return erro(405, "Método não permitido.");

  const chaveGemini = Deno.env.get("GEMINI_API_KEY");
  const chave = Deno.env.get("ANTHROPIC_API_KEY");
  if (!chaveGemini && !chave) return erro(500, "A inteligência ainda não foi configurada: cadastre o segredo GEMINI_API_KEY (gratuito) em Edge Functions → Secrets no Supabase.");

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
  if (texto.length < 30) return erro(400, "Descreva o seu dia com um pouco mais de detalhe.");

  const { data: cfgRow } = await admin.from("config").select("data").eq("id", "diario").maybeSingle();
  const c = { ...PADRAO, ...(cfgRow?.data ?? {}) } as typeof PADRAO;
  const lista = (a: string[]) => (Array.isArray(a) && a.length ? a.map((x) => "- " + x).join("\n") : "- (não definido)");
  const palavras = (Array.isArray(c.palavras) ? c.palavras : PADRAO.palavras)
    .map((p) => `- "${p.termo}" → ${ACAO_TXT[p.acao] ?? p.acao}`).join("\n");
  const diaSemana = new Date(dataDia + "T12:00:00-03:00").toLocaleDateString("pt-BR", { weekday: "long", timeZone: "America/Sao_Paulo" });

  const sistema = `Você é um coach comercial sênior de uma imobiliária brasileira (Imobiliária 2.0). Sua função é analisar o diário de bordo de um corretor e ajudá-lo a vender mais.

Seja sincero, específico e respeitoso. Não elogie por elogiar: aponte com clareza o que foi bem e o que faltou, citando o que o corretor escreveu. Se o dia foi fraco, diga isso. Se o texto for vago, cobre detalhes (quantos contatos, quais clientes, próximos passos).

MANTRA DA EQUIPE (régua da avaliação)
Valores:
${lista(c.valores)}
Deveres:
${lista(c.deveres)}
Virtudes:
${lista(c.virtudes)}
${c.instrucoes ? `\nInstruções do gestor:\n${c.instrucoes}\n` : ""}
CRITÉRIO DA NOTA (0 a 10): 9–10 dia excepcional, com resultado e disciplina; 7–8 bom, com pontos claros a ajustar; 5–6 mediano; abaixo de 5, dia improdutivo ou fora do mantra.

MELHORIAS: ações concretas e verificáveis para o próximo dia, voltadas a gerar vendas (prospecção, follow-up, qualificação, agendamento, negociação, pós-venda).

LANÇAMENTOS AUTOMÁTICOS
Crie itens em "registros" somente quando o texto descrever um fato que corresponda a uma destas palavras-chave (ou a uma expressão de mesmo sentido, claramente):
${palavras}
Regras: não invente dados. Venda só com valor informado. Converta valores por extenso ("300 mil" = 300000; "1,2 milhão" = 1200000). Datas no formato AAAA-MM-DD, calculadas a partir do dia do diário (${dataDia}, ${diaSemana}, fuso de Brasília); "amanhã" = dia seguinte. Hora em 24 horas (HH:MM). Se nada corresponder, devolva "registros" vazio.

Responda sempre chamando a ferramenta registrar_analise, em português do Brasil.`;

  const usuario = `Corretor: ${me.nome}${me.especialidade ? ` (especialidade: ${me.especialidade})` : ""}
Dia do diário: ${dataDia} (${diaSemana})

O que o corretor escreveu:
"""
${texto}
"""`;

  if (chaveGemini) {
    const formato = `
Responda SOMENTE com um objeto JSON válido, sem texto antes ou depois, neste formato:
{"nota": inteiro 0-10, "feedback": "texto", "pontos_fortes": ["..."], "pontos_fracos": ["..."], "melhorias": ["..."],
 "mantra": [{"item": "...", "avaliacao": "..."}],
 "registros": [{"tipo": "venda|visita|agenda", "cliente": "...", "valor": número, "imovel": "...", "endereco": "...", "data": "AAAA-MM-DD", "hora": "HH:MM", "tipoVisita": "Venda|Locação|Captação|Avaliação|Lançamento|Retorno", "descricao": "..."}]}
Em "registros", omita os campos que não aparecem no texto.`;
    let g: Response;
    try {
      g = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${Deno.env.get("MODELO_IA") ?? "gemini-flash-latest"}:generateContent`, {
        method: "POST",
        headers: { "content-type": "application/json", "x-goog-api-key": chaveGemini },
        body: JSON.stringify({
          systemInstruction: { parts: [{ text: sistema.replace("Responda sempre chamando a ferramenta registrar_analise, em português do Brasil.", "Responda em português do Brasil.") + formato }] },
          contents: [{ role: "user", parts: [{ text: usuario }] }],
          generationConfig: { responseMimeType: "application/json", temperature: 0.4, maxOutputTokens: 4096 },
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
    return resp(200, normalizar(a));
  }

  let r: Response;
  try {
    r = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: { "content-type": "application/json", "x-api-key": chave, "anthropic-version": "2023-06-01" },
      body: JSON.stringify({
        model: Deno.env.get("MODELO_IA") ?? "claude-sonnet-5-5",
        max_tokens: 2500,
        system: sistema,
        tools: [FERRAMENTA],
        tool_choice: { type: "tool", name: "registrar_analise" },
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
    if (/credit|billing|balance/i.test(msg)) return erro(402, "A conta da API da Anthropic está sem créditos. Recarregue em console.anthropic.com.");
    if (r.status === 404 || /model/i.test(msg)) return erro(500, "Modelo de IA não encontrado. Ajuste o segredo MODELO_IA no Supabase.");
    if (r.status === 429 || r.status === 529) return erro(503, "O serviço de inteligência está ocupado. Tente de novo em um minuto.");
    return erro(502, "O serviço de inteligência recusou a análise: " + msg);
  }
  const uso = (j.content ?? []).find((b: any) => b.type === "tool_use");
  if (!uso?.input) return erro(502, "A inteligência não devolveu uma análise válida. Tente de novo.");
  return resp(200, normalizar(uso.input));
});

function normalizar(a: any) {
  const arr = (x: unknown) => (Array.isArray(x) ? x : []);
  return {
    analise: {
      nota: Math.max(0, Math.min(10, Math.round(Number(a.nota) || 0))),
      feedback: String(a.feedback ?? ""),
      pontos_fortes: arr(a.pontos_fortes).map(String),
      pontos_fracos: arr(a.pontos_fracos).map(String),
      melhorias: arr(a.melhorias).map(String),
      mantra: arr(a.mantra).filter((m: any) => m && m.item),
    },
    registros: arr(a.registros).filter((r: any) => r && ["venda", "visita", "agenda"].includes(r.tipo)),
  };
}
