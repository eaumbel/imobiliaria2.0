// Imobiliária 2.0 · Gestão comercial — envio de e-mail pelo servidor SMTP configurado
// (Configurações → E-mail). Padrão: Gmail (smtp.gmail.com, porta 465, SSL) com "senha de app".
//
// Quem pode chamar:
//   - o Master, pela tela (testar conexão, enviar teste);
//   - rotinas automáticas do servidor, com a chave service_role no cabeçalho Authorization.
//
// Ações (POST JSON):
//   { "acao": "testar" }                                  → confere login e conexão com o servidor
//   { "acao": "enviar", "para": "a@b.com" | ["a@b.com"],  → envia usando um template salvo
//     "template": "chave-do-template", "dados": { "nome": "Maria", ... } }
//   { "acao": "enviar", "para": ..., "assunto": "...", "corpo": "...", "formato": "texto" | "html", "dados": {...} }
//                                                          → envia um texto avulso (ex.: teste de template não salvo)
//
// Variáveis no assunto e na mensagem: {{nome}}, {{email}}, {{empresa}}, {{data}}, {{hora}} e qualquer
// outra enviada em "dados". Na mensagem em texto: **negrito**, [texto](https://link) e o botão
// [[Texto do botão|https://link]].
// Atenção: o Supabase bloqueia as portas 25 e 587; use a porta 465 (SSL).
// Publicar com "Verify JWT" DESLIGADO (a função confere quem chama).
import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import nodemailer from "npm:nodemailer@6.9.16";

const VERSAO_FUNCAO = "2026-11-21.1";
const LIMITE_DIA = Number(Deno.env.get("EMAIL_LIMITE_DIA")) || 450; // o Gmail aceita cerca de 500 por dia
const MAX_DESTINOS = 50;

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const resp = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
const erro = (status: number, msg: string) => resp(status, { erro: msg });

// ---------- Montagem da mensagem (a tela usa a mesma regra para a pré-visualização) ----------
const escHtml = (s: unknown) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));
const urlOk = (u: string) => /^(https?:\/\/|mailto:)/i.test(u.replace(/&amp;/g, "&"));
function variaveis(dados: Record<string, unknown>, empresa: string) {
  const agora = new Date();
  return {
    empresa,
    data: agora.toLocaleDateString("pt-BR", { timeZone: "America/Sao_Paulo" }),
    hora: agora.toLocaleTimeString("pt-BR", { timeZone: "America/Sao_Paulo", hour: "2-digit", minute: "2-digit" }),
    ...dados,
  } as Record<string, unknown>;
}
const trocar = (txt: string, vars: Record<string, unknown>, esc: boolean) =>
  txt.replace(/\{\{\s*([\w.-]+)\s*\}\}/g, (_, k) => { const v = vars[k]; const s = v == null ? "" : String(v); return esc ? escHtml(s) : s; });
function textoParaHtml(corpo: string, vars: Record<string, unknown>) {
  let h = trocar(escHtml(corpo), vars, true);
  h = h.replace(/\[\[([^|\]\n]+)\|([^\]\s]+)\]\]/g, (m, t, u) => urlOk(u)
    ? `<table role="presentation" cellpadding="0" cellspacing="0" style="margin:18px 0"><tr><td style="background:#b5121b;border-radius:8px"><a href="${u}" style="display:inline-block;padding:12px 22px;color:#ffffff;text-decoration:none;font-weight:bold">${t.trim()}</a></td></tr></table>` : m);
  h = h.replace(/\[([^\]\n]+)\]\(([^)\s]+)\)/g, (m, t, u) => urlOk(u) ? `<a href="${u}" style="color:#b5121b">${t}</a>` : m);
  h = h.replace(/\*\*([^*\n]+)\*\*/g, "<b>$1</b>");
  return h.split(/\n\s*\n/).map((p) => p.trim()).filter(Boolean)
    .map((p) => p.startsWith("<table") ? p : `<p style="margin:0 0 14px">${p.replace(/\n/g, "<br>")}</p>`).join("\n");
}
function moldura(conteudo: string, empresa: string) {
  return `<!doctype html><html lang="pt-BR"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width"></head>
<body style="margin:0;padding:0;background:#f5f2ec;font-family:Arial,Helvetica,sans-serif;color:#1d1b18">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f5f2ec;padding:24px 12px"><tr><td align="center">
<table role="presentation" width="600" cellpadding="0" cellspacing="0" style="max-width:600px;width:100%;background:#ffffff;border:1px solid #e7e1d8;border-radius:12px;overflow:hidden">
<tr><td style="background:#1f1f1f;padding:18px 28px;color:#ffffff;font-size:18px;font-weight:bold">${escHtml(empresa)}</td></tr>
<tr><td style="height:4px;line-height:4px;font-size:0;background:#b5121b">&nbsp;</td></tr>
<tr><td style="padding:28px;font-size:15px;line-height:1.6">${conteudo}</td></tr>
<tr><td style="padding:14px 28px;background:#f8f5f0;color:#6b665f;font-size:12px">Mensagem enviada por ${escHtml(empresa)}.</td></tr>
</table></td></tr></table></body></html>`;
}
export function montarEmail(t: { assunto: string; corpo: string; formato?: string; moldura?: boolean }, dados: Record<string, unknown>, empresa: string) {
  const vars = variaveis(dados, empresa);
  const assunto = trocar(t.assunto, vars, false).replace(/[\r\n]+/g, " ").trim();
  const conteudo = t.formato === "html" ? trocar(t.corpo, vars, true) : textoParaHtml(t.corpo, vars);
  const html = t.moldura === false ? conteudo : moldura(conteudo, empresa);
  const texto = conteudo.replace(/<br\s*\/?>/gi, "\n").replace(/<\/p>/gi, "\n\n").replace(/<a [^>]*href="([^"]+)"[^>]*>([^<]*)<\/a>/gi, "$2 ($1)")
    .replace(/<[^>]+>/g, "").replace(/&nbsp;/g, " ").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&amp;/g, "&")
    .replace(/\n{3,}/g, "\n\n").trim();
  return { assunto, html, texto };
}

// ---------- Erros do servidor de e-mail em português ----------
function erroSmtp(e: any, host: string, porta: number) {
  const code = String(e?.code || ""), msg = String(e?.response || e?.message || "");
  if (code === "EAUTH" || /535|534|Username and Password not accepted|BadCredentials|Invalid login/i.test(msg))
    return `O servidor recusou o login ou a senha. No Gmail, use uma "senha de app" (16 letras), criada em myaccount.google.com/apppasswords com a verificação em duas etapas ligada — a senha normal da conta não funciona. Detalhe: ${msg.slice(0, 160)}`;
  if (code === "ETIMEDOUT" || code === "ECONNECTION" || code === "ESOCKET" || code === "ECONNREFUSED" || /timeout|ENOTFOUND|ECONNREFUSED/i.test(msg))
    return `Não foi possível conectar a ${host}:${porta}. Confira o servidor e a porta.${porta === 587 || porta === 25 ? " O Supabase bloqueia as portas 25 e 587: use a porta 465 com SSL." : ""} Detalhe: ${(msg || code).slice(0, 160)}`;
  if (/certificate|self.signed|wrong version number|SSL routines/i.test(msg))
    return `Falha na conexão segura com ${host}:${porta}. Confira a segurança: porta 465 usa SSL; porta 587 usa STARTTLS. Detalhe: ${msg.slice(0, 160)}`;
  if (/550|553|554|Daily user sending limit/i.test(msg)) return `O servidor recusou a mensagem: ${msg.slice(0, 200)}`;
  return `O servidor de e-mail recusou a operação: ${(msg || code || "erro desconhecido").slice(0, 200)}`;
}
const emailOk = (s: string) => /^[^@\s<>,;]+@[^@\s<>,;]+\.[^@\s<>,;]+$/.test(s);

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return erro(405, "Método não permitido.");
  const chaveServico = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const admin = createClient(Deno.env.get("SUPABASE_URL")!, chaveServico, { auth: { persistSession: false, autoRefreshToken: false } });

  // Quem chama: rotina do servidor (chave service_role) ou o Master logado
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  const sistema = !!token && token === chaveServico;
  let usuario: string | null = null;
  if (!sistema) {
    const { data: ud } = await admin.auth.getUser(token);
    if (!ud?.user) return erro(401, "Sessão expirada. Entre novamente.");
    const { data: me } = await admin.from("perfis").select("perfil, ativo").eq("id", ud.user.id).maybeSingle();
    if (!me || !me.ativo || me.perfil !== "master") return erro(403, "Somente o Master pode usar o envio de e-mails pela tela.");
    usuario = ud.user.id;
  }

  let body: Record<string, any>;
  try { body = await req.json(); } catch { return erro(400, "Requisição inválida."); }

  const { data: gw } = await admin.from("email_gateway").select("*").eq("id", "principal").maybeSingle();
  if (!gw || !gw.host || !gw.usuario || !gw.senha) return erro(400, "O servidor de e-mail ainda não foi configurado. Vá em Configurações → E-mail, preencha o servidor, o login e a senha e salve.");
  if (body.acao === "enviar" && !gw.ativo && !body.teste) return erro(400, "O envio de e-mails está desligado. Ligue em Configurações → E-mail.");

  const transporte = nodemailer.createTransport({
    host: gw.host, port: gw.porta, secure: gw.seguranca === "ssl", requireTLS: gw.seguranca === "starttls", ignoreTLS: gw.seguranca === "nenhuma",
    auth: { user: gw.usuario, pass: gw.senha },
    connectionTimeout: 15_000, greetingTimeout: 15_000, socketTimeout: 30_000,
  });
  const empresa = gw.remetente_nome || "Imobiliária 2.0";

  if (body.acao === "testar") {
    const t0 = Date.now();
    try { await transporte.verify(); return resp(200, { ok: true, ms: Date.now() - t0, versao: VERSAO_FUNCAO, servidor: `${gw.host}:${gw.porta}` }); }
    catch (e) { return resp(200, { ok: false, ms: Date.now() - t0, versao: VERSAO_FUNCAO, msg: erroSmtp(e, gw.host, gw.porta) }); }
    finally { try { transporte.close(); } catch { /* */ } }
  }
  if (body.acao !== "enviar") return erro(400, "Ação desconhecida.");

  // Destinatários
  const para = (Array.isArray(body.para) ? body.para : String(body.para ?? "").split(/[,;\s]+/)).map((s: unknown) => String(s).trim().toLowerCase()).filter(Boolean);
  if (!para.length) return erro(400, "Informe o e-mail de destino.");
  if (para.length > MAX_DESTINOS) return erro(400, `Envie para no máximo ${MAX_DESTINOS} endereços por vez.`);
  const ruim = para.find((p: string) => !emailOk(p)); if (ruim) return erro(400, `E-mail inválido: ${ruim}`);

  // Mensagem: template salvo (pela chave) ou texto avulso
  let t: { assunto: string; corpo: string; formato?: string; moldura?: boolean }, chave: string | null = null;
  if (body.template) {
    chave = String(body.template).toLowerCase();
    const { data: row } = await admin.from("email_templates").select("data").eq("data->>chave", chave).maybeSingle();
    if (!row) return erro(404, `Template "${chave}" não encontrado.`);
    if (row.data.ativo === false && !body.teste) return erro(400, `O template "${chave}" está desativado.`);
    t = row.data;
  } else {
    if (!String(body.assunto ?? "").trim() || !String(body.corpo ?? "").trim()) return erro(400, "Informe o assunto e a mensagem.");
    t = { assunto: String(body.assunto), corpo: String(body.corpo), formato: body.formato, moldura: body.moldura };
  }
  const dados = body.dados && typeof body.dados === "object" ? body.dados : {};
  const m = montarEmail(t, { email: para[0], ...dados }, empresa);
  if (body.teste) m.assunto = "[TESTE] " + m.assunto;

  // Limite diário (o Gmail bloqueia a conta por 24 h se passar de ~500)
  const desde = new Date(Date.now() - 24 * 3600 * 1000).toISOString();
  const { count } = await admin.from("email_envios").select("id", { count: "exact", head: true }).eq("status", "ok").gte("criado_em", desde);
  if ((count ?? 0) + para.length > LIMITE_DIA) return erro(429, `Limite de ${LIMITE_DIA} e-mails em 24 horas atingido (o Gmail bloqueia a conta acima de ~500). Tente mais tarde.`);

  const remetente = { name: empresa, address: gw.remetente_email || gw.usuario };
  const registro = (status: "ok" | "erro", msgErro?: string) => admin.from("email_envios").insert(
    { para: para.join(", "), assunto: m.assunto.slice(0, 300), template: chave, origem: sistema ? "rotina" : body.teste ? "teste" : "tela", status, erro: msgErro ?? null, por: usuario });
  try {
    const info = await transporte.sendMail({ from: remetente, to: para, replyTo: gw.responder_para || undefined, subject: m.assunto, html: m.html, text: m.texto });
    await registro("ok");
    return resp(200, { ok: true, id: info?.messageId ?? null, para });
  } catch (e) {
    const msg = erroSmtp(e, gw.host, gw.porta);
    await registro("erro", msg);
    return erro(502, msg);
  } finally { try { transporte.close(); } catch { /* */ } }
});
