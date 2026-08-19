import { createClient } from "npm:@supabase/supabase-js@2.112.3"

import { criarClienteTelegram } from "./telegram.ts"
import { processarUmItem, type ItemReservado, type Repositorio } from "./worker.ts"

const FORMATO_URL_SUPABASE = /^https:\/\/[a-z0-9]{20}\.supabase\.co$/
const LIMITE_CORPO_BYTES = 2048
const CHAVES_DO_CORPO = new Set(["trigger", "requested_at"])

function exigirVariavel(nome: string): string {
  const valor = Deno.env.get(nome)
  if (!valor) throw new Error(`Variavel de ambiente ausente: ${nome}`)
  return valor
}

function responder(status: number, corpo: Record<string, unknown>): Response {
  return new Response(JSON.stringify(corpo), {
    status,
    headers: { "content-type": "application/json" },
  })
}

Deno.serve(async (requisicao: Request) => {
  if (requisicao.method !== "POST") {
    return responder(405, { erro: "Somente POST" })
  }

  let urlSupabase: string
  let chaveServico: string
  let tokenBot: string

  try {
    urlSupabase = exigirVariavel("SUPABASE_URL")
    chaveServico = exigirVariavel("SUPABASE_SERVICE_ROLE_KEY")
    tokenBot = exigirVariavel("TELEGRAM_BOT_TOKEN")
  } catch (erro) {
    console.error("configuracao incompleta:", erro instanceof Error ? erro.message : erro)
    return responder(500, { erro: "Funcao mal configurada" })
  }

  if (!FORMATO_URL_SUPABASE.test(urlSupabase)) {
    return responder(500, { erro: "SUPABASE_URL fora do formato oficial" })
  }

  // Corpo e conferido antes de tocar no banco.
  const bruto = await requisicao.text()

  if (new TextEncoder().encode(bruto).length > LIMITE_CORPO_BYTES) {
    return responder(413, { erro: "Corpo grande demais" })
  }

  if (bruto !== "") {
    try {
      const corpo = JSON.parse(bruto) as Record<string, unknown>
      const invalida = Object.keys(corpo).find((c) => !CHAVES_DO_CORPO.has(c))
      if (invalida) return responder(400, { erro: `Chave nao permitida: ${invalida}` })
    } catch {
      return responder(400, { erro: "Corpo nao e JSON valido" })
    }
  }

  const supabase = createClient(urlSupabase, chaveServico, {
    auth: { persistSession: false, autoRefreshToken: false },
  })

  // O segredo do cron mora no cofre do banco, e so la. Nao existe copia em
  // variavel de ambiente para sair de sincronia.
  const recebido = requisicao.headers.get("x-cron-secret") ?? ""
  const { data: autorizado, error: erroSegredo } = await supabase.rpc("cron_secreto_confere", {
    p_segredo: recebido,
  })

  if (erroSegredo) {
    console.error("falha ao conferir o segredo:", erroSegredo.message)
    return responder(500, { erro: "Nao foi possivel conferir a autorizacao" })
  }

  if (autorizado !== true) {
    return responder(401, { erro: "Nao autorizado" })
  }

  const { data: configuracao, error: erroConfiguracao } = await supabase
    .from("configuracoes")
    .select("canal_padrao, destino_padrao")
    .eq("id", 1)
    .single()

  if (erroConfiguracao || !configuracao) {
    return responder(500, { erro: "Nao foi possivel ler as configuracoes" })
  }

  if (!configuracao.destino_padrao) {
    return responder(409, { erro: "Canal de destino nao configurado" })
  }

  const identificadorWorker =
    Deno.env.get("BAIXOU_WORKER_ID") ?? `baixou-worker:${crypto.randomUUID()}`

  const repositorio: Repositorio = {
    async reservarItem(worker) {
      const { data, error } = await supabase.rpc("reservar_item_da_fila", {
        p_worker: worker,
        p_lote: 1,
      })
      if (error) throw new Error(`reservar_item_da_fila: ${error.message}`)
      const linhas = (data ?? []) as ItemReservado[]
      return linhas[0] ?? null
    },

    async marcarDespachoIniciado(filaId, token, chave) {
      const { data, error } = await supabase.rpc("marcar_despacho_iniciado", {
        p_fila_id: filaId,
        p_token_reserva: token,
        p_chave_despacho: chave,
      })
      if (error) throw new Error(`marcar_despacho_iniciado: ${error.message}`)
      return data === true
    },

    async marcarConcluida(filaId, token, idMensagem, permalink) {
      const { error } = await supabase.rpc("marcar_publicacao_concluida", {
        p_fila_id: filaId,
        p_token_reserva: token,
        p_id_mensagem_externa: idMensagem,
        p_permalink: permalink,
      })
      if (error) throw new Error(`marcar_publicacao_concluida: ${error.message}`)
    },

    async marcarFalha(filaId, token, codigo, mensagem, retentavel, esperarSegundos) {
      const { error } = await supabase.rpc("marcar_publicacao_falha", {
        p_fila_id: filaId,
        p_token_reserva: token,
        p_codigo: codigo,
        p_mensagem: mensagem,
        p_retentavel: retentavel,
        p_esperar_segundos: esperarSegundos ?? null,
      })
      if (error) throw new Error(`marcar_publicacao_falha: ${error.message}`)
    },

    async registrarErro(codigo, mensagem, filaId) {
      const { error } = await supabase.from("erros").insert({
        chave_idempotencia: `worker:${codigo}:${filaId ?? "sem-item"}:${Date.now()}`,
        gravidade: "erro",
        codigo,
        mensagem: mensagem.slice(0, 2000),
        fila_id: filaId,
      })
      if (error) console.error("nao foi possivel registrar o erro:", error.message)
    },
  }

  try {
    const desfecho = await processarUmItem({
      repositorio,
      telegram: criarClienteTelegram({ token: tokenBot }),
      identificadorWorker,
      destinoPermitido: configuracao.destino_padrao,
      canalPermitido: configuracao.canal_padrao,
    })

    return responder(200, desfecho)
  } catch (erro) {
    const mensagem = erro instanceof Error ? erro.message : String(erro)
    console.error("falha na rodada do worker:", mensagem)
    return responder(500, { erro: "Falha na rodada do worker" })
  }
})
