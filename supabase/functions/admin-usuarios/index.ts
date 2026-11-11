// Imobiliária 2.0 · Gestão comercial — função de administração de usuários.
// Cria o primeiro Master, cadastra e altera usuários (login, senha, perfil,
// status e permissões). Roda no servidor com a chave service_role, que nunca
// vai para o navegador. Publicar com "Verify JWT" DESLIGADO: a função confere
// a sessão por conta própria.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const EMAIL_DOM = Deno.env.get("EMAIL_DOMINIO") ?? "acesso.eaumbel.com.br";
const PERFIS = ["master", "coordenador", "corretor"];

const resp = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
const erro = (status: number, msg: string) => resp(status, { erro: msg });
const limpa = (s: unknown, max = 200) => String(s ?? "").trim().slice(0, max);
const loginOk = (l: string) => /^[a-z0-9._-]{3,40}$/.test(l);
const emailDe = (login: string) => `${login}@${EMAIL_DOM}`;
function traduz(m: string) {
  if (/already|registered|exists/i.test(m)) return "Este login já está em uso.";
  if (/password/i.test(m)) return "Senha não aceita pelo servidor. Use pelo menos 6 caracteres.";
  return "Erro no servidor: " + m;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return erro(405, "Método não permitido.");

  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  let body: Record<string, any>;
  try { body = await req.json(); } catch { return erro(400, "Requisição inválida."); }
  const acao = body.acao;

  const { count } = await admin.from("perfis").select("id", { count: "exact", head: true });
  const configurado = (count ?? 0) > 0;

  // Sem login: só consultar se o sistema já tem usuários e criar o primeiro Master.
  if (acao === "status") return resp(200, { configurado });
  if (acao === "bootstrap") {
    if (configurado) return erro(403, "O sistema já foi configurado.");
    const d = body.dados ?? {};
    const login = limpa(d.login, 40).toLowerCase();
    const senha = String(body.senha ?? "");
    if (!limpa(d.nome) || !loginOk(login)) return erro(400, "Informe o nome e um login de 3 a 40 caracteres (letras, números, ponto ou hífen).");
    if (senha.length < 6) return erro(400, "A senha precisa ter pelo menos 6 caracteres.");
    const { data: cu, error } = await admin.auth.admin.createUser({ email: emailDe(login), password: senha, email_confirm: true });
    if (error || !cu?.user) return erro(400, traduz(error?.message ?? ""));
    const { error: e2 } = await admin.from("perfis").insert({
      id: cu.user.id, login, nome: limpa(d.nome), email: limpa(d.email),
      especialidade: "Gestão de vendas", perfil: "master", participa: false, ativo: true,
    });
    if (e2) { await admin.auth.admin.deleteUser(cu.user.id); return erro(500, "Não foi possível criar o perfil."); }
    return resp(200, { id: cu.user.id });
  }

  // A partir daqui, só com sessão válida.
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  const { data: ud } = await admin.auth.getUser(token);
  if (!ud?.user) return erro(401, "Sessão expirada. Entre novamente.");
  const { data: me } = await admin.from("perfis").select("*").eq("id", ud.user.id).maybeSingle();
  if (!me || !me.ativo) return erro(403, "Seu acesso está inativo.");

  const master = me.perfil === "master";
  let podeUsuarios = master;
  if (!master) {
    const ov = me.permissoes?.usuarios;
    if (typeof ov === "boolean") podeUsuarios = ov;
    else {
      const { data: cfg } = await admin.from("config").select("data").eq("id", "permissoes").maybeSingle();
      const v = cfg?.data?.[me.perfil]?.usuarios;
      podeUsuarios = typeof v === "boolean" ? v : false;
    }
  }

  if (acao !== "salvar") return erro(400, "Ação desconhecida.");
  if (!podeUsuarios) return erro(403, "Seu acesso não permite gerenciar usuários.");

  const d = body.dados ?? {};
  const senha = body.senha ? String(body.senha) : "";
  const perfil = PERFIS.includes(d.perfil) ? d.perfil : "corretor";
  const login = limpa(d.login, 40).toLowerCase();
  if (!limpa(d.nome) || !loginOk(login)) return erro(400, "Informe o nome e um login de 3 a 40 caracteres (letras, números, ponto ou hífen).");
  if (senha && senha.length < 6) return erro(400, "A senha precisa ter pelo menos 6 caracteres.");

  const alvoId = body.id ?? null;
  const { data: alvo } = alvoId
    ? await admin.from("perfis").select("*").eq("id", alvoId).maybeSingle()
    : { data: null as any };
  const { data: dup } = await admin.from("perfis").select("id").eq("login", login).maybeSingle();
  if (dup && dup.id !== alvo?.id) return erro(409, "Este login já está em uso.");
  if (!master && (perfil === "master" || alvo?.perfil === "master")) return erro(403, "Somente o Master gerencia usuários Master.");

  const permissoes = d.permissoes && typeof d.permissoes === "object" ? d.permissoes : {};
  if (!master && JSON.stringify(permissoes) !== JSON.stringify(alvo?.permissoes ?? {})) return erro(403, "Somente o Master altera permissões.");

  const ativo = d.ativo !== false;
  if (alvo && alvo.id === me.id && !ativo) return erro(400, "Você não pode desativar o seu próprio acesso.");
  if (alvo?.perfil === "master" && alvo.ativo && (perfil !== "master" || !ativo)) {
    const { count: n } = await admin.from("perfis").select("id", { count: "exact", head: true })
      .eq("perfil", "master").eq("ativo", true).neq("id", alvo.id);
    if (!n) return erro(400, "É preciso manter pelo menos um usuário Master ativo.");
  }

  const linha = {
    login, nome: limpa(d.nome), email: limpa(d.email), telefone: limpa(d.telefone, 30),
    creci: limpa(d.creci, 30), especialidade: limpa(d.especialidade, 80), perfil,
    participa: typeof d.participa === "boolean" ? d.participa : perfil !== "master",
    ativo, permissoes, atualizado_em: new Date().toISOString(),
  };

  if (!alvo) {
    if (senha.length < 6) return erro(400, "Defina uma senha com pelo menos 6 caracteres.");
    const { data: cu, error } = await admin.auth.admin.createUser({ email: emailDe(login), password: senha, email_confirm: true });
    if (error || !cu?.user) return erro(400, traduz(error?.message ?? ""));
    const { error: e2 } = await admin.from("perfis").insert({ id: cu.user.id, ...linha });
    if (e2) { await admin.auth.admin.deleteUser(cu.user.id); return erro(500, "Não foi possível salvar o usuário."); }
    return resp(200, { id: cu.user.id });
  }

  const upd: Record<string, unknown> = {};
  if (login !== alvo.login) { upd.email = emailDe(login); upd.email_confirm = true; }
  if (senha) upd.password = senha;
  if (ativo !== alvo.ativo) upd.ban_duration = ativo ? "none" : "876000h";
  if (Object.keys(upd).length) {
    const { error } = await admin.auth.admin.updateUserById(alvo.id, upd);
    if (error) return erro(400, traduz(error.message));
  }
  const { error: e3 } = await admin.from("perfis").update(linha).eq("id", alvo.id);
  if (e3) return erro(500, "Não foi possível salvar o usuário.");
  return resp(200, { id: alvo.id });
});
