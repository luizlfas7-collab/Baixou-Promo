import { createClient } from "npm:@supabase/supabase-js@2.112.3"

const ENDERECO_AUTORIZACAO = "https://auth.mercadolivre.com.br/authorization"
const ENDERECO_TOKEN = "https://api.mercadolibre.com/oauth/token"
const TEMPO_LIMITE_MS = 15_000

function exigirVariavel(nome: string): string {
  const valor = Deno.env.get(nome)
  if (!valor) throw new Error(`Variavel de ambiente ausente: ${nome}`)
  return valor
}

/** Pagina simples, sem recurso externo: o navegador so precisa ler isto. */
function pagina(titulo: string, mensagem: string, detalhe = ""): string {
  const escapar = (texto: string) =>
    texto.replace(/[&<>"']/g, (c) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c] as string
    )

  return `<!doctype html>
<html lang="pt-BR"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${escapar(titulo)} — Baixou</title>
<style>
  :root { color-scheme: light dark; }
  body { font: 16px/1.6 system-ui, sans-serif; max-width: 34rem;
         margin: 4rem auto; padding: 0 1.5rem; }
  h1 { font-size: 1.4rem; margin-bottom: .5rem; }
  p { margin: .5rem 0; }
  code { background: rgba(128,128,128,.18); padding: .1rem .35rem; border-radius: .25rem; }
</style></head>
<body><h1>${escapar(titulo)}</h1><p>${escapar(mensagem)}</p>
${detalhe ? `<p><code>${escapar(detalhe)}</code></p>` : ""}
</body></html>`
}

function responderHtml(status: number, titulo: string, mensagem: string, detalhe = ""): Response {
  return new Response(pagina(titulo, mensagem, detalhe), {
    status,
    headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" },
  })
}

Deno.serve(async (requisicao: Request) => {
  if (requisicao.method !== "GET") {
    return responderHtml(405, "Metodo nao permitido", "Este endereco responde apenas a GET.")
  }

  let supabase
  try {
    supabase = createClient(
      exigirVariavel("SUPABASE_URL"),
      exigirVariavel("SUPABASE_SERVICE_ROLE_KEY"),
      { auth: { persistSession: false, autoRefreshToken: false } },
    )
  } catch (erro) {
    console.error("configuracao incompleta:", erro instanceof Error ? erro.message : erro)
    return responderHtml(500, "Funcao mal configurada", "Faltam variaveis de ambiente.")
  }

  const url = new URL(requisicao.url)
  const codigo = url.searchParams.get("code")
  const estado = url.searchParams.get("state")
  const erroMl = url.searchParams.get("error")

  // ---------------------------------------------------------------------
  // Consulta de estado. Nao devolve segredo nenhum.
  // ---------------------------------------------------------------------
  if (url.searchParams.get("acao") === "estado") {
    const { data, error } = await supabase.rpc("ml_conexao_estado")
    if (error) {
      return responderHtml(500, "Nao foi possivel ler o estado", error.message)
    }
    return new Response(JSON.stringify(data, null, 2), {
      status: 200,
      headers: { "content-type": "application/json", "cache-control": "no-store" },
    })
  }

  // ---------------------------------------------------------------------
  // O Mercado Livre recusou a autorizacao.
  // ---------------------------------------------------------------------
  if (erroMl) {
    const descricao = url.searchParams.get("error_description") ?? ""
    return responderHtml(
      400,
      "Autorizacao recusada",
      "O Mercado Livre nao concluiu a autorizacao. Comece de novo abrindo este mesmo endereco sem parametros.",
      `${erroMl}${descricao ? `: ${descricao}` : ""}`,
    )
  }

  // ---------------------------------------------------------------------
  // Inicio do fluxo: cria state + PKCE e manda para o Mercado Livre.
  // ---------------------------------------------------------------------
  if (!codigo) {
    const { data, error } = await supabase.rpc("oauth_ml_iniciar")

    if (error) {
      return responderHtml(
        409,
        "Aplicacao ainda nao configurada",
        "Grave o client_id e o client_secret antes de conectar.",
        error.message,
      )
    }

    const inicio = (Array.isArray(data) ? data[0] : data) as {
      estado: string
      desafio: string
      client_id: string
      redirect_uri: string
    } | undefined

    if (!inicio?.estado) {
      return responderHtml(500, "Falha ao iniciar", "O banco nao devolveu o par de autorizacao.")
    }

    const destino = new URL(ENDERECO_AUTORIZACAO)
    destino.searchParams.set("response_type", "code")
    destino.searchParams.set("client_id", inicio.client_id)
    destino.searchParams.set("redirect_uri", inicio.redirect_uri)
    destino.searchParams.set("state", inicio.estado)
    destino.searchParams.set("code_challenge", inicio.desafio)
    destino.searchParams.set("code_challenge_method", "S256")

    return new Response(null, {
      status: 302,
      headers: { location: destino.toString(), "cache-control": "no-store" },
    })
  }

  // ---------------------------------------------------------------------
  // Volta do Mercado Livre: troca o codigo pelos tokens.
  // ---------------------------------------------------------------------
  if (!estado) {
    return responderHtml(400, "Retorno incompleto", "O Mercado Livre voltou sem o state.")
  }

  const { data: verificador, error: erroEstado } = await supabase.rpc("oauth_ml_resgatar", {
    p_estado: estado,
  })

  if (erroEstado || typeof verificador !== "string") {
    // Consumir o state apaga a pendencia: repetir o mesmo callback cai aqui.
    return responderHtml(
      400,
      "State invalido ou ja usado",
      "Esta autorizacao venceu ou ja foi concluida. Abra este endereco sem parametros para comecar de novo.",
    )
  }

  const { data: credenciais, error: erroCredenciais } = await supabase.rpc("ml_credenciais_para_uso")

  const credencial = (Array.isArray(credenciais) ? credenciais[0] : credenciais) as {
    client_id: string
    client_secret: string | null
    redirect_uri: string
  } | undefined

  if (erroCredenciais || !credencial?.client_id || !credencial.client_secret) {
    return responderHtml(
      409,
      "Credenciais incompletas",
      "O client_secret nao esta no cofre. Grave-o antes de concluir a conexao.",
      erroCredenciais?.message ?? "",
    )
  }

  const corpo = new URLSearchParams({
    grant_type: "authorization_code",
    client_id: credencial.client_id,
    client_secret: credencial.client_secret,
    code: codigo,
    redirect_uri: credencial.redirect_uri,
    code_verifier: verificador,
  })

  const cancelamento = new AbortController()
  const alarme = setTimeout(() => cancelamento.abort(), TEMPO_LIMITE_MS)

  let resposta: Response
  try {
    resposta = await fetch(ENDERECO_TOKEN, {
      method: "POST",
      headers: {
        "content-type": "application/x-www-form-urlencoded",
        accept: "application/json",
      },
      body: corpo,
      signal: cancelamento.signal,
      redirect: "error",
    })
  } catch (erro) {
    return responderHtml(
      502,
      "Falha de rede",
      "Nao foi possivel falar com o Mercado Livre. Tente de novo.",
      erro instanceof Error ? erro.message : String(erro),
    )
  } finally {
    clearTimeout(alarme)
  }

  let dados: Record<string, unknown>
  try {
    dados = await resposta.json()
  } catch {
    return responderHtml(502, "Resposta ilegivel", `O Mercado Livre respondeu HTTP ${resposta.status}.`)
  }

  if (!resposta.ok) {
    // A mensagem do provedor ajuda, e aqui ela nao contem segredo.
    const detalhe = String(dados.error_description ?? dados.message ?? dados.error ?? resposta.status)
    return responderHtml(
      resposta.status === 400 ? 400 : 502,
      "O Mercado Livre recusou a troca",
      "O codigo de autorizacao nao virou token.",
      detalhe,
    )
  }

  const accessToken = typeof dados.access_token === "string" ? dados.access_token : ""
  const refreshToken = typeof dados.refresh_token === "string" ? dados.refresh_token : ""
  const expiresIn = Number(dados.expires_in)

  if (!accessToken) {
    return responderHtml(502, "Resposta sem access_token", "O Mercado Livre nao devolveu o token.")
  }

  // Sem offline_access nao vem refresh, e a automacao morreria em 6 horas.
  // Melhor recusar agora, alto e claro, do que descobrir na madrugada.
  if (!refreshToken) {
    return responderHtml(
      409,
      "Falta o escopo offline_access",
      "O Mercado Livre autorizou mas nao devolveu refresh_token. Habilite o escopo offline_access na aplicacao e conecte de novo.",
    )
  }

  const { error: erroGravar } = await supabase.rpc("oauth_ml_gravar_tokens", {
    p_access_token: accessToken,
    p_refresh_token: refreshToken,
    p_expires_in: Number.isFinite(expiresIn) ? expiresIn : 21600,
    p_usuario_id: dados.user_id != null ? String(dados.user_id) : null,
    p_escopos: typeof dados.scope === "string" ? dados.scope : null,
    p_primeira_conexao: true,
  })

  if (erroGravar) {
    console.error("falha ao gravar tokens:", erroGravar.message)
    return responderHtml(500, "Conectou, mas nao guardou", "Os tokens nao foram para o cofre.", erroGravar.message)
  }

  return responderHtml(
    200,
    "Mercado Livre conectado",
    "Os tokens estao no cofre do banco e a renovacao passa a ser automatica. Pode fechar esta aba.",
    typeof dados.scope === "string" ? `escopos: ${dados.scope}` : "",
  )
})
