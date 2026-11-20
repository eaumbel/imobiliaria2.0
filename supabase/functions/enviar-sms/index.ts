// Imobiliária 2.0 · Gestão comercial — envio de SMS pelo Twilio (Configurações → SMS).
//
// Quem pode chamar:
//   - o Master, pela tela (testar a conta, enviar teste, atualizar status);
//   - rotinas automáticas do servidor, com a chave service_role no cabeçalho Authorization.
//
// Ações (POST JSON):
//   { "acao": "testar" }                                     → confere Account SID e Auth Token no Twilio
//   { "acao": "enviar", "para": "(43) 99999-0000" | [...],    → envia usando um template salvo
//     "template": "chave-do-template", "dados": { "nome": "Maria", ... } }
//   { "acao": "enviar", "para": ..., "texto": "...", "semAcentos": true, "dados": {...} }
//                                                             → envia um texto avulso (ex.: teste)
//   { "acao": "status" }                                     → atualiza o status dos envios recentes
//
// Números do Brasil podem vir como (43) 99999-0000; viram +5543999990000. Outros países: com + e código.
// Variáveis no texto: {{nome}}, {{empresa}}, {{data}}, {{hora}} e qualquer outra enviada em "dados".
// Publicar com "Verify JWT" DESLIGADO (a função confere quem chama).
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const VERSAO_FUNCAO = "2026-11-22.1";
const LIMITE_DIA = Number(Deno.env.get("SMS_LIMITE_DIA")) || 200;
const MAX_DESTINOS = 50;
const API = "https://api.twilio.com/2010-04-01";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const resp = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
const erro = (status: number, msg: string) => resp(status, { erro: msg });

// ---------- Texto (a tela usa a mesma regra para a pré-visualização) ----------
export const semAcento = (s: string) => s.normalize("NFD").replace(/[̀-ͯ]/g, "").replace(/[“”]/g, '"').replace(/[‘’]/g, "'").replace(/[–—]/g, "-").replace(/…/g, "...");
export function montarSms(texto: string, dados: Record<string, unknown>, empresa: string, tirarAcentos: boolean) {
  const agora = new Date();
  const vars: Record<string, unknown> = {
    empresa,
    data: agora.toLocaleDateString("pt-BR", { timeZone: "America/Sao_Paulo" }),
    hora: agora.toLocaleTimeString("pt-BR", { timeZone: "America/Sao_Paulo", hour: "2-digit", minute: "2-digit" }),
    ...dados,
  };
  const t = texto.replace(/\{\{\s*([\w.-]+)\s*\}\}/g, (_, k) => (vars[k] == null ? "" : String(vars[k]))).replace(/[ \t]+\n/g, "\n").trim();
  return tirarAcentos ? semAcento(t) : t;
}
// GSM-7: 160 caracteres (153 por parte); com acentos/emoji: 70 (67 por parte)
const GSM = "@£$¥èéùìòÇ\nØø\rÅåΔ_ΦΓΛΩΠΨΣΘΞÆæßÉ !\"#¤%&'()*+,-./0123456789:;<=>?¡ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÑÜ§¿abcdefghijklmnopqrstuvwxyzäöñüà^{}\\[~]|€";
export function segmentos(t: string) {
  const gsm = [...t].every((c) => GSM.includes(c));
  const n = gsm ? [...t].reduce((a, c) => a + ("^{}\\[~]|€".includes(c) ? 2 : 1), 0) : [...t].length;
  const partes = gsm ? (n <= 160 ? 1 : Math.ceil(n / 153)) : (n <= 70 ? 1 : Math.ceil(n / 67));
  return { gsm, caracteres: n, partes };
}
export function telefoneE164(s: string) {
  const bruto = String(s ?? "").trim();
  const dig = bruto.replace(/\D/g, "");
  if (bruto.startsWith("+")) return /^[1-9]\d{7,14}$/.test(dig) ? "+" + dig : null;
  if (/^0?\d{10,11}$/.test(dig)) return "+55" + dig.replace(/^0/, ""); // Brasil: DDD + número
  if (/^55\d{10,11}$/.test(dig)) return "+" + dig;
  return null;
}

// ---------- Erros do Twilio em português ----------
function erroTwilio(status: number, j: any) {
  const c = Number(j?.code), m = String(j?.message || "");
  const M: Record<number, string> = {
    20003: "O Twilio recusou o Account SID ou o Auth Token. Confira os dois em Twilio Console → Account Info.",
    20404: "Conta ou recurso não encontrado no Twilio. Confira o Account SID.",
    21211: "Número de destino inválido.",
    21212: "O remetente (From) é inválido. Use o número comprado no Twilio, com + e código do país.",
    21606: "O remetente não pode enviar SMS: confira se o número do Twilio tem SMS habilitado.",
    21659: "O remetente não pertence a esta conta do Twilio.",
    21408: "A conta do Twilio não tem permissão para enviar SMS para este país. Libere o Brasil em Messaging → Settings → Geo permissions.",
    21608: "Conta de teste (trial) do Twilio: só envia para números verificados. Verifique o número em Phone Numbers → Verified Caller IDs ou ative a conta.",
    21610: "Este número pediu para não receber mensagens (respondeu STOP).",
    21614: "O número de destino não é um celular válido.",
    21617: "A mensagem é longa demais.",
    20429: "Muitas mensagens em pouco tempo: o Twilio pediu para esperar. Tente de novo em instantes.",
    30007: "A operadora bloqueou a mensagem (filtro de spam).",
  };
  if (M[c]) return `${M[c]} (código ${c})`;
  if (status === 401) return M[20003];
  return `O Twilio recusou a operação${c ? ` (código ${c})` : ` (HTTP ${status})`}: ${m.slice(0, 200) || "erro desconhecido"}`;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return erro(405, "Método não permitido.");
  const chaveServico = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const admin = createClient(Deno.env.get("SUPABASE_URL")!, chaveServico, { auth: { persistSession: false, autoRefreshToken: false } });

  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  const sistema = !!token && token === chaveServico;
  let usuario: string | null = null;
  if (!sistema) {
    const { data: ud } = await admin.auth.getUser(token);
    if (!ud?.user) return erro(401, "Sessão expirada. Entre novamente.");
    const { data: me } = await admin.from("perfis").select("perfil, ativo").eq("id", ud.user.id).maybeSingle();
    if (!me || !me.ativo || me.perfil !== "master") return erro(403, "Somente o Master pode usar o envio de SMS pela tela.");
    usuario = ud.user.id;
  }

  let body: Record<string, any>;
  try { body = await req.json(); } catch { return erro(400, "Requisição inválida."); }

  const { data: gw } = await admin.from("sms_gateway").select("*").eq("id", "principal").maybeSingle();
  if (!gw || !gw.account_sid || !gw.auth_token || !gw.remetente) return erro(400, "O SMS ainda não foi configurado. Vá em Configurações → SMS, preencha Account SID, Auth Token e remetente e salve.");
  const auth = "Basic " + btoa(`${gw.account_sid}:${gw.auth_token}`);
  const twilio = async (caminho: string, form?: Record<string, string>) => {
    const ctl = new AbortController(), t = setTimeout(() => ctl.abort(), 20_000);
    try {
      const r = await fetch(`${API}/Accounts/${gw.account_sid}${caminho}`, {
        method: form ? "POST" : "GET", signal: ctl.signal,
        headers: { authorization: auth, ...(form ? { "content-type": "application/x-www-form-urlencoded" } : {}) },
        body: form ? new URLSearchParams(form).toString() : undefined,
      });
      return { ok: r.ok, status: r.status, j: await r.json().catch(() => ({})) };
    } catch (e) {
      return { ok: false, status: 0, j: { message: (e as Error)?.name === "AbortError" ? "O Twilio não respondeu em 20 s." : "Não foi possível falar com o Twilio." } };
    } finally { clearTimeout(t); }
  };

  if (body.acao === "testar") {
    const t0 = Date.now(), r = await twilio(".json");
    if (!r.ok) return resp(200, { ok: false, ms: Date.now() - t0, versao: VERSAO_FUNCAO, msg: r.status ? erroTwilio(r.status, r.j) : r.j.message });
    return resp(200, { ok: true, ms: Date.now() - t0, versao: VERSAO_FUNCAO, conta: r.j.friendly_name || "", situacao: r.j.status || "", tipo: r.j.type || "" });
  }

  if (body.acao === "status") {
    const desde = new Date(Date.now() - 3 * 24 * 3600 * 1000).toISOString();
    const { data: pend } = await admin.from("sms_envios").select("id, sid").in("status", ["queued", "accepted", "sending", "sent", "scheduled"])
      .not("sid", "is", null).gte("criado_em", desde).limit(20);
    let atualizados = 0;
    for (const e of pend ?? []) {
      const r = await twilio(`/Messages/${e.sid}.json`);
      if (!r.ok) continue;
      await admin.from("sms_envios").update({ status: r.j.status, erro: r.j.error_code ? erroTwilio(400, { code: r.j.error_code, message: r.j.error_message }) : null }).eq("id", e.id);
      atualizados++;
    }
    return resp(200, { ok: true, atualizados });
  }

  if (body.acao !== "enviar") return erro(400, "Ação desconhecida.");
  if (!gw.ativo && !body.teste) return erro(400, "O envio de SMS está desligado. Ligue em Configurações → SMS.");

  const brutos = Array.isArray(body.para) ? body.para : String(body.para ?? "").split(/[,;]+/);
  const para = brutos.map((s: unknown) => String(s).trim()).filter(Boolean);
  if (!para.length) return erro(400, "Informe o celular de destino.");
  if (para.length > MAX_DESTINOS) return erro(400, `Envie para no máximo ${MAX_DESTINOS} números por vez.`);
  const numeros: string[] = [];
  for (const p of para) { const n = telefoneE164(p); if (!n) return erro(400, `Celular inválido: ${p}. Use DDD + número, ex.: (43) 99999-0000.`); numeros.push(n); }

  let texto: string, tirar: boolean, chave: string | null = null;
  if (body.template) {
    chave = String(body.template).toLowerCase();
    const { data: row } = await admin.from("sms_templates").select("data").eq("data->>chave", chave).maybeSingle();
    if (!row) return erro(404, `Template "${chave}" não encontrado.`);
    if (row.data.ativo === false && !body.teste) return erro(400, `O template "${chave}" está desativado.`);
    texto = row.data.texto; tirar = row.data.semAcentos !== false;
  } else {
    texto = String(body.texto ?? ""); tirar = body.semAcentos !== false;
    if (!texto.trim()) return erro(400, "Escreva a mensagem.");
  }
  const dados = body.dados && typeof body.dados === "object" ? body.dados : {};
  // nome da empresa: o mesmo do remetente de e-mail (Configurações → E-mail), se houver
  const { data: eg } = await admin.from("email_gateway").select("remetente_nome").eq("id", "principal").maybeSingle();
  const msg = montarSms(texto, dados, eg?.remetente_nome || "Imobiliária 2.0", tirar);
  if (!msg) return erro(400, "A mensagem ficou vazia depois de preencher as variáveis.");
  if ([...msg].length > 1600) return erro(400, "A mensagem ficou longa demais (máx. 1.600 caracteres).");
  const seg = segmentos(msg);

  const desde = new Date(Date.now() - 24 * 3600 * 1000).toISOString();
  const { count } = await admin.from("sms_envios").select("id", { count: "exact", head: true }).neq("status", "erro").gte("criado_em", desde);
  if ((count ?? 0) + numeros.length > LIMITE_DIA) return erro(429, `Limite de ${LIMITE_DIA} SMS em 24 horas atingido (segredo SMS_LIMITE_DIA). Tente mais tarde.`);

  const origem = sistema ? "rotina" : body.teste ? "teste" : "tela";
  const remetente = gw.remetente.startsWith("MG") ? { MessagingServiceSid: gw.remetente } : { From: gw.remetente };
  const resultados: { para: string; ok: boolean; sid?: string; status?: string; erro?: string }[] = [];
  for (const n of numeros) {
    const r = await twilio("/Messages.json", { To: n, Body: msg, ...remetente });
    const falha = r.ok ? null : (r.status ? erroTwilio(r.status, r.j) : r.j.message);
    await admin.from("sms_envios").insert({ para: n, texto: msg, template: chave, origem, status: r.ok ? (r.j.status || "queued") : "erro",
      sid: r.j.sid ?? null, segmentos: Number(r.j.num_segments) || seg.partes, erro: falha, por: usuario });
    resultados.push(r.ok ? { para: n, ok: true, sid: r.j.sid, status: r.j.status } : { para: n, ok: false, erro: falha! });
  }
  const falhas = resultados.filter((r) => !r.ok);
  if (falhas.length === resultados.length) return erro(502, falhas[0].erro!);
  return resp(200, { ok: true, enviados: resultados.length - falhas.length, falhas: falhas.length, resultados, texto: msg, partes: seg.partes });
});
