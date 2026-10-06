import type { PayloadTelegram } from "../_compartilhado/payload.ts"
import type { Repasse } from "../_compartilhado/whatsapp.ts"

export type ResultadoEnvio =
  | { tipo: "enviado"; idMensagem: string; permalink: string | null }
  | { tipo: "falha"; codigo: string; mensagem: string; retentavel: boolean; esperarSegundos?: number }
  | { tipo: "desconhecido"; codigo: string; mensagem: string }

/** Conferir um canal jamais devolve "enviado". */
export type ProblemaTelegram = Extract<ResultadoEnvio, { tipo: "falha" | "desconhecido" }>

export type ClienteTelegram = {
  conferirCanal: (destino: string) => Promise<ProblemaTelegram | null>
  publicar: (destino: string, payload: PayloadTelegram) => Promise<ResultadoEnvio>
  /** Manda o post ja formatado para o operador colar no canal do WhatsApp. */
  repassar: (destino: string, repasse: Repasse) => Promise<ProblemaTelegram | null>
}

type Opcoes = {
  token: string
  buscar?: typeof fetch
  tempoLimiteMs?: number
}

const FORMATO_DO_TOKEN = /^\d{5,}:[A-Za-z0-9_-]{30,}$/

function permalinkDe(destino: string, idMensagem: string): string | null {
  if (!destino.startsWith("@")) return null
  return `https://t.me/${destino.slice(1)}/${idMensagem}`
}

export function criarClienteTelegram({
  token,
  buscar = fetch,
  tempoLimiteMs = 15_000,
}: Opcoes): ClienteTelegram {
  if (!FORMATO_DO_TOKEN.test(token)) {
    throw new Error("TELEGRAM_BOT_TOKEN fora do formato esperado")
  }

  const base = `https://api.telegram.org/bot${token}`

  /** `podeRepetir`: consulta e sempre segura de retentar; envio nao e. */
  async function chamar(
    metodo: string,
    corpo: Record<string, unknown>,
    podeRepetir: boolean,
  ): Promise<{ ok: true; resultado: Record<string, unknown> } | ProblemaTelegram> {
    const cancelamento = new AbortController()
    const alarme = setTimeout(() => cancelamento.abort(), tempoLimiteMs)

    let resposta: Response

    try {
      resposta = await buscar(`${base}/${metodo}`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(corpo),
        signal: cancelamento.signal,
        redirect: "error",
      })
    } catch (erro) {
      const mensagem = erro instanceof Error ? erro.message : String(erro)

      return podeRepetir
        ? { tipo: "falha", codigo: "rede", mensagem, retentavel: true }
        : { tipo: "desconhecido", codigo: "rede_apos_envio", mensagem }
    } finally {
      clearTimeout(alarme)
    }

    let corpoResposta: Record<string, unknown>

    try {
      corpoResposta = (await resposta.json()) as Record<string, unknown>
    } catch {
      return podeRepetir
        ? { tipo: "falha", codigo: "resposta_ilegivel", mensagem: `HTTP ${resposta.status}`, retentavel: true }
        : { tipo: "desconhecido", codigo: "resposta_ilegivel", mensagem: `HTTP ${resposta.status}` }
    }

    if (resposta.ok && corpoResposta.ok === true) {
      return { ok: true, resultado: (corpoResposta.result ?? {}) as Record<string, unknown> }
    }

    const descricao = String(corpoResposta.description ?? `HTTP ${resposta.status}`)
    const parametros = (corpoResposta.parameters ?? {}) as { retry_after?: number }

    if (resposta.status === 429) {
      return {
        tipo: "falha",
        codigo: "limite_de_taxa",
        mensagem: descricao,
        retentavel: true,
        esperarSegundos: parametros.retry_after,
      }
    }

    if (resposta.status >= 500) {
      return podeRepetir
        ? { tipo: "falha", codigo: "servidor_telegram", mensagem: descricao, retentavel: true }
        : { tipo: "desconhecido", codigo: "servidor_telegram", mensagem: descricao }
    }

    return { tipo: "falha", codigo: `telegram_${resposta.status}`, mensagem: descricao, retentavel: false }
  }

  return {
    /** Confere que o bot e administrador e pode postar. */
    async conferirCanal(destino) {
      const eu = await chamar("getMe", {}, true)
      if (!("ok" in eu)) return eu

      const chat = await chamar("getChat", { chat_id: destino }, true)
      if (!("ok" in chat)) return chat

      const idBot = eu.resultado.id
      const membro = await chamar("getChatMember", { chat_id: destino, user_id: idBot }, true)
      if (!("ok" in membro)) return membro

      const situacao = String(membro.resultado.status ?? "")
      if (situacao !== "administrator" && situacao !== "creator") {
        return {
          tipo: "falha",
          codigo: "bot_nao_e_admin",
          mensagem: `O bot esta como "${situacao}" em ${destino}; precisa ser administrador`,
          retentavel: false,
        }
      }

      if (situacao === "administrator" && membro.resultado.can_post_messages === false) {
        return {
          tipo: "falha",
          codigo: "bot_sem_permissao_de_post",
          mensagem: `O bot e admin em ${destino} mas nao pode publicar`,
          retentavel: false,
        }
      }

      return null
    },

    async publicar(destino, payload) {
      const comFoto = typeof payload.photo === "string" && payload.photo !== ""
      const metodo = comFoto ? "sendPhoto" : "sendMessage"

      const corpo: Record<string, unknown> = comFoto
        ? { chat_id: destino, photo: payload.photo, caption: payload.text }
        : { chat_id: destino, text: payload.text }

      if (payload.parse_mode) corpo.parse_mode = payload.parse_mode
      if (payload.reply_markup) corpo.reply_markup = payload.reply_markup
      if (!comFoto && payload.link_preview_options) {
        corpo.link_preview_options = payload.link_preview_options
      }

      const envio = await chamar(metodo, corpo, false)
      if (!("ok" in envio)) return envio

      const idMensagem = String(envio.resultado.message_id ?? "")

      if (idMensagem === "") {
        return {
          tipo: "desconhecido",
          codigo: "sem_id_de_mensagem",
          mensagem: "O Telegram respondeu ok mas nao devolveu message_id",
        }
      }

      return { tipo: "enviado", idMensagem, permalink: permalinkDe(destino, idMensagem) }
    },

    /**
     * Entrega o repasse no privado do operador.
     *
     * Vai SEM parse_mode de proposito: o texto carrega a marcacao do WhatsApp
     * (`*` e `~`), e interpretar isso como formatacao do Telegram devolveria a
     * mensagem bonita na tela e inutil para colar — os caracteres sumiriam
     * justamente onde precisam aparecer.
     *
     * Devolve o problema em vez de lancar: repasse que falha nao pode virar
     * publicacao que falha.
     */
    async repassar(destino, repasse) {
      const comFoto = typeof repasse.urlImagem === "string" && repasse.urlImagem !== ""

      const corpo: Record<string, unknown> = comFoto
        ? { chat_id: destino, photo: repasse.urlImagem, caption: repasse.texto }
        : {
          chat_id: destino,
          text: repasse.texto,
          // Previa aqui so atrapalha quem veio copiar texto.
          link_preview_options: { is_disabled: true },
        }

      const envio = await chamar(comFoto ? "sendPhoto" : "sendMessage", corpo, false)

      return "ok" in envio ? null : envio
    },
  }
}
