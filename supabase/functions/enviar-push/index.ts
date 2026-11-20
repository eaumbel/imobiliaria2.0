// Imobiliária 2.0 · Gestão comercial — envio de notificações push (Web Push).
//
// Chamada de três jeitos:
//  1. Pelo banco (gatilho em "notificacoes", via pg_net), com o cabeçalho
//     x-push-segredo: manda o push de cada notificação nova para os aparelhos
//     da pessoa.
//  2. Pelo sistema, { acao: "chave" }: devolve a chave pública VAPID (gerada
//     e guardada no banco na primeira vez; não precisa cadastrar nada).
//  3. Pelo sistema, { acao: "teste" } com a sessão do usuário: manda um push
//     de teste para os aparelhos de quem pediu.
//
// Publicar com "Verify JWT" DESLIGADO (o banco chama sem sessão; a função
// confere o segredo ou a sessão por conta própria).
// A criptografia (RFC 8291, aes128gcm) e a assinatura VAPID (RFC 8292) são
// feitas com WebCrypto, sem bibliotecas externas.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const resp = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
const erro = (status: number, msg: string) => resp(status, { erro: msg });
const CONTATO = Deno.env.get("PUSH_CONTATO") ?? "https://eaumbel.com.br";

// ---------- base64url ----------
export function b64u(bytes: Uint8Array): string {
  let s = "";
  for (let i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
export function deB64u(s: string): Uint8Array {
  s = s.replace(/-/g, "+").replace(/_/g, "/").replace(/=+$/, "");
  const bin = atob(s + "===".slice((s.length + 3) % 4));
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}
const junta = (...partes: Uint8Array[]) => {
  const out = new Uint8Array(partes.reduce((n, p) => n + p.length, 0));
  let o = 0; for (const p of partes) { out.set(p, o); o += p.length; }
  return out;
};
const txt = (s: string) => new TextEncoder().encode(s);

// ---------- Chaves VAPID ----------
export async function gerarVapid(): Promise<{ publica: string; privada: string }> {
  const par = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]) as CryptoKeyPair;
  const pub = new Uint8Array(await crypto.subtle.exportKey("raw", par.publicKey));
  const jwk = await crypto.subtle.exportKey("jwk", par.privateKey);
  return { publica: b64u(pub), privada: JSON.stringify({ kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y, d: jwk.d }) };
}

async function vapidCabecalho(endpoint: string, publica: string, privadaJwk: string): Promise<string> {
  const aud = new URL(endpoint).origin;
  const cab = b64u(txt(JSON.stringify({ typ: "JWT", alg: "ES256" })));
  const corpo = b64u(txt(JSON.stringify({ aud, exp: Math.floor(Date.now() / 1000) + 12 * 3600, sub: CONTATO })));
  const chave = await crypto.subtle.importKey("jwk", JSON.parse(privadaJwk), { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const ass = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, chave, txt(cab + "." + corpo)));
  return `vapid t=${cab}.${corpo}.${b64u(ass)}, k=${publica}`;
}

// ---------- Criptografia do conteúdo (RFC 8291 / aes128gcm) ----------
async function hkdf(salt: Uint8Array, ikm: Uint8Array, info: Uint8Array, bytes: number): Promise<Uint8Array> {
  const k = await crypto.subtle.importKey("raw", ikm, "HKDF", false, ["deriveBits"]);
  return new Uint8Array(await crypto.subtle.deriveBits({ name: "HKDF", hash: "SHA-256", salt, info }, k, bytes * 8));
}

export async function cifrar(conteudo: Uint8Array, p256dh: string, authSecret: string): Promise<Uint8Array> {
  const uaPub = deB64u(p256dh), auth = deB64u(authSecret);
  const local = await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits"]) as CryptoKeyPair;
  const asPub = new Uint8Array(await crypto.subtle.exportKey("raw", local.publicKey));
  const uaChave = await crypto.subtle.importKey("raw", uaPub, { name: "ECDH", namedCurve: "P-256" }, false, []);
  const segredo = new Uint8Array(await crypto.subtle.deriveBits({ name: "ECDH", public: uaChave }, local.privateKey, 256));
  const ikm = await hkdf(auth, segredo, junta(txt("WebPush: info\0"), uaPub, asPub), 32);
  const salt = crypto.getRandomValues(new Uint8Array(16));
  const cek = await hkdf(salt, ikm, txt("Content-Encoding: aes128gcm\0"), 16);
  const nonce = await hkdf(salt, ikm, txt("Content-Encoding: nonce\0"), 12);
  const chave = await crypto.subtle.importKey("raw", cek, "AES-GCM", false, ["encrypt"]);
  const cifrado = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce }, chave, junta(conteudo, new Uint8Array([2]))));
  const rs = new Uint8Array([0, 0, 0x10, 0]); // 4096
  return junta(salt, rs, new Uint8Array([asPub.length]), asPub, cifrado);
}

type Inscricao = { endpoint: string; usuario: string; p256dh: string; auth: string };
async function enviar(sub: Inscricao, dados: unknown, vapid: { publica: string; privada: string }, urgente = true): Promise<number> {
  const corpo = await cifrar(txt(JSON.stringify(dados)), sub.p256dh, sub.auth);
  const r = await fetch(sub.endpoint, {
    method: "POST",
    headers: {
      Authorization: await vapidCabecalho(sub.endpoint, vapid.publica, vapid.privada),
      "Content-Encoding": "aes128gcm",
      "Content-Type": "application/octet-stream",
      TTL: "86400",
      Urgency: urgente ? "high" : "normal",
    },
    body: corpo,
    signal: AbortSignal.timeout(10000),
  });
  try { await r.body?.cancel(); } catch { /* nada */ }
  return r.status;
}

// ---------- Servidor ----------
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return erro(405, "Método não permitido.");

  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  let body: Record<string, any>;
  try { body = await req.json(); } catch { return erro(400, "Requisição inválida."); }

  const { data: cfg, error: eCfg } = await admin.from("push_config").select("*").eq("id", 1).maybeSingle();
  if (eCfg || !cfg) return erro(500, "Push não configurado: rode a migração 20261121100000_comunicacao_push.sql.");

  // Chaves VAPID: geradas uma vez e guardadas no banco
  let vapid = { publica: cfg.vapid_publica as string | null, privada: cfg.vapid_privada as string | null };
  if (!vapid.publica || !vapid.privada) {
    const nova = await gerarVapid();
    const { data: gravou } = await admin.from("push_config").update({ vapid_publica: nova.publica, vapid_privada: nova.privada })
      .eq("id", 1).is("vapid_publica", null).select("vapid_publica, vapid_privada").maybeSingle();
    if (gravou) vapid = { publica: gravou.vapid_publica, privada: gravou.vapid_privada };
    else { // outra chamada gerou ao mesmo tempo: usa a dela
      const { data: c2 } = await admin.from("push_config").select("vapid_publica, vapid_privada").eq("id", 1).single();
      vapid = { publica: c2!.vapid_publica, privada: c2!.vapid_privada };
    }
  }
  const chaves = vapid as { publica: string; privada: string };

  const envia = async (subs: Inscricao[], dadosDe: (s: Inscricao) => unknown) => {
    let ok = 0; const mortas: string[] = [], usadas: string[] = [];
    await Promise.all(subs.map(async (s) => {
      try {
        const st = await enviar(s, dadosDe(s), chaves);
        if (st === 404 || st === 410) mortas.push(s.endpoint); // aparelho desinscrito ou expirado
        else if (st >= 200 && st < 300) { ok++; usadas.push(s.endpoint); }
        else console.warn("push recusado", st, new URL(s.endpoint).host);
      } catch (e) { console.warn("push falhou", String(e)); }
    }));
    if (mortas.length) await admin.from("push_inscricoes").delete().in("endpoint", mortas);
    if (usadas.length) await admin.from("push_inscricoes").update({ usado_em: new Date().toISOString() }).in("endpoint", usadas);
    return ok;
  };

  // 1. Chamado pelo banco
  const seg = req.headers.get("x-push-segredo");
  if (seg) {
    if (seg !== cfg.segredo) return erro(403, "Segredo inválido.");
    const ids = (Array.isArray(body.ids) ? body.ids : []).filter((x: unknown) => typeof x === "string").slice(0, 2000);
    if (!ids.length) return resp(200, { enviados: 0 });
    const { data: ns } = await admin.from("notificacoes").select("id, usuario, tipo, titulo, texto, card_id, ator_nome").in("id", ids).eq("lida", false);
    if (!ns?.length) return resp(200, { enviados: 0 });
    const usuarios = [...new Set(ns.map((n) => n.usuario))];
    const { data: subs } = await admin.from("push_inscricoes").select("endpoint, usuario, p256dh, auth").in("usuario", usuarios);
    if (!subs?.length) return resp(200, { enviados: 0 });
    // contador de não lidas (número no ícone do app)
    const naoLidas: Record<string, number> = {};
    await Promise.all(usuarios.map(async (u) => {
      const { count } = await admin.from("notificacoes").select("id", { count: "exact", head: true }).eq("usuario", u).eq("lida", false);
      naoLidas[u] = count ?? 0;
    }));
    const totais = await Promise.all(ns.map((n) => {
      const dados = n.tipo === "comunicado"
        ? { titulo: "Comunicado" + (n.ator_nome ? " · " + n.ator_nome : ""), texto: n.titulo, nt: n.id, tag: "imob20-" + n.id }
        : { titulo: n.titulo, texto: n.texto || "", nt: n.id, card: n.card_id || "", tag: n.card_id ? "imob20-card-" + n.card_id : "imob20-" + n.id };
      return envia(subs.filter((s) => s.usuario === n.usuario), (s) => ({ ...dados, naoLidas: naoLidas[s.usuario] ?? 0 }));
    }));
    return resp(200, { enviados: totais.reduce((a, b) => a + b, 0) });
  }

  // 2. Chave pública (não é segredo)
  if (body.acao === "chave") return resp(200, { chave: chaves.publica });

  // 3. Teste, com a sessão de quem pediu
  if (body.acao === "teste") {
    const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
    const { data: ud } = await admin.auth.getUser(token);
    if (!ud?.user) return erro(401, "Sessão expirada. Entre novamente.");
    const { data: subs } = await admin.from("push_inscricoes").select("endpoint, usuario, p256dh, auth").eq("usuario", ud.user.id);
    if (!subs?.length) return erro(400, "Nenhum aparelho seu está inscrito para receber notificações.");
    const ok = await envia(subs, () => ({ titulo: "Notificações ativas", texto: "Tudo certo: este aparelho recebe os avisos do Gestão 2.0.", tag: "imob20-teste" }));
    if (!ok) return erro(502, "O serviço de notificações do aparelho recusou o envio. Desative e ative de novo.");
    return resp(200, { enviados: ok, aparelhos: subs.length });
  }

  return erro(400, "Ação desconhecida.");
});
