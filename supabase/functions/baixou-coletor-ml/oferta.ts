import { LINHA_DE_PUBLICIDADE, type PayloadTelegram } from "../_compartilhado/payload.ts"
import type { AvaliacaoMl, ItemMl, ReputacaoVendedor } from "./mercadolivre.ts"

/** Legenda do Telegram com foto. Sobra folga para o titulo nao estourar. */
const LIMITE_LEGENDA = 1024
const LIMITE_TITULO = 120

export type Sinais = {
  item: ItemMl
  avaliacao: AvaliacaoMl
  reputacao: ReputacaoVendedor
  /** Desconto que o BANCO apurou contra o proprio historico, nao o que a loja diz. */
  descontoVerificado: number | null
}

export type Pontuacao = {
  total: number
  componentes: Record<string, number>
  faltando: string[]
}

const dinheiro = new Intl.NumberFormat("pt-BR", {
  style: "currency",
  currency: "BRL",
})

/**
 * Cem pontos divididos entre o que da para provar. O peso maior fica no
 * desconto verificado de proposito: e o unico sinal que nasce do nosso
 * proprio historico, e nao do que o vendedor afirma.
 *
 * A regua de corte mora no banco (aprovacao_pontuacao_minima, hoje 88), o que
 * exige quase tudo alto ao mesmo tempo. E deliberado: publicar pouco e bom e
 * melhor do que publicar muito e mediano.
 */
export function pontuar({ item, avaliacao, reputacao, descontoVerificado }: Sinais): Pontuacao {
  const componentes: Record<string, number> = {}
  const faltando: string[] = []

  // Desconto verificado: 0 em 15%, cheio em 40%.
  if (descontoVerificado === null) {
    componentes.desconto = 0
    faltando.push("desconto_verificado")
  } else {
    const faixa = Math.min(Math.max(descontoVerificado - 15, 0), 25)
    componentes.desconto = Math.round((faixa / 25) * 40)
  }

  componentes.reputacao = reputacao.verde ? 15 : 0
  if (!reputacao.nivel) faltando.push("reputacao_vendedor")

  // Avaliacao: precisa de nota alta E de gente suficiente avaliando.
  if (avaliacao.nota === null || avaliacao.total < 10) {
    componentes.avaliacao = 0
    faltando.push("avaliacao_produto")
  } else {
    const porNota = Math.min(Math.max((avaliacao.nota - 4.0) / 1.0, 0), 1) * 14
    const porVolume = Math.min(avaliacao.total / 50, 1) * 6
    componentes.avaliacao = Math.round(porNota + porVolume)
  }

  componentes.condicao = (item.novo ? 6 : 0) + (item.disponivel ? 4 : 0)
  componentes.tracao = Math.round(Math.min(item.vendidos / 100, 1) * 10)
  componentes.frete = item.freteGratis ? 5 : 0

  const total = Object.values(componentes).reduce((soma, valor) => soma + valor, 0)

  return { total: Math.min(total, 100), componentes, faltando }
}

function escaparHtml(texto: string): string {
  return texto.replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" })[c] as string)
}

function encurtarTitulo(titulo: string): string {
  const limpo = titulo.replace(/\s+/g, " ").trim()
  if (limpo.length <= LIMITE_TITULO) return limpo
  return `${limpo.slice(0, LIMITE_TITULO - 1).trimEnd()}…`
}

/**
 * Monta o post. Nenhuma URL vai no texto: o link mora nos botoes, onde a
 * allowlist de afiliados consegue conferir dominio por dominio.
 */
export function montarPayload(
  sinais: Sinais,
  urlAfiliado: string,
): PayloadTelegram {
  const { item, avaliacao, descontoVerificado } = sinais

  const linhas: string[] = []

  linhas.push(`🔥 <b>${escaparHtml(encurtarTitulo(item.titulo))}</b>`)
  linhas.push("")

  if (descontoVerificado !== null && item.precoOriginal && item.precoOriginal > item.precoAtual) {
    linhas.push(
      `<s>${dinheiro.format(item.precoOriginal)}</s>  →  <b>${dinheiro.format(item.precoAtual)}</b>`,
    )
    linhas.push(`📉 ${descontoVerificado.toFixed(0)}% abaixo do que já vimos`)
  } else {
    linhas.push(`💰 <b>${dinheiro.format(item.precoAtual)}</b>`)
    if (descontoVerificado !== null) {
      linhas.push(`📉 ${descontoVerificado.toFixed(0)}% abaixo do que já vimos`)
    }
  }

  if (avaliacao.nota !== null && avaliacao.total > 0) {
    const estrelas = avaliacao.nota.toFixed(1).replace(".", ",")
    linhas.push(`⭐ ${estrelas} · ${avaliacao.total} avaliações`)
  }

  if (item.freteGratis) linhas.push("🚚 Frete grátis")

  linhas.push("")
  linhas.push(LINHA_DE_PUBLICIDADE)

  let texto = linhas.join("\n")

  // Ultima defesa: legenda com foto nao pode passar de 1024.
  if (texto.length > LIMITE_LEGENDA) {
    texto = `🔥 <b>${escaparHtml(encurtarTitulo(item.titulo))}</b>\n\n` +
      `💰 <b>${dinheiro.format(item.precoAtual)}</b>\n\n${LINHA_DE_PUBLICIDADE}`
  }

  const compartilhar = new URL("https://t.me/share/url")
  compartilhar.searchParams.set("url", urlAfiliado)
  compartilhar.searchParams.set("text", "Achei essa oferta no Baixou")

  const payload: PayloadTelegram = {
    text: texto,
    parse_mode: "HTML",
    reply_markup: {
      inline_keyboard: [
        [{ text: "🛒 Ver oferta", url: urlAfiliado }],
        [{ text: "↗️ Compartilhar", url: compartilhar.toString() }],
      ],
    },
  }

  if (item.urlImagem) payload.photo = item.urlImagem

  return payload
}
