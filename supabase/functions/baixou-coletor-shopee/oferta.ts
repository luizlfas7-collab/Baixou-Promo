import { LINHA_DE_PUBLICIDADE, type PayloadTelegram } from "../_compartilhado/payload.ts"
import type { ProdutoShopee } from "./shopee.ts"

const LIMITE_LEGENDA = 1024
const LIMITE_TITULO = 120

/** Mesmo piso de evidencia do coletor do ML. */
const COBERTURA_MINIMA = 0.70

/** Desconto verificado onde a nota comeca e onde satura. */
const DESCONTO_PISO = 15
const DESCONTO_TETO = 30

/** Segunda porta: preco abaixo da propria referencia. Ver oferta.ts do ML. */
const FUNDO_PISO = 13
const FUNDO_TETO = 15

export type SinaisShopee = {
  produto: ProdutoShopee
  /** Desconto que o BANCO apurou contra o proprio historico. */
  descontoVerificado: number | null
  /** Competitividade apurada pelo banco (0 a 15). */
  competitividade: number | null
}

export type Pontuacao = {
  total: number
  cobertura: number
  componentes: Record<string, number>
  ausentes: string[]
  recusa: string | null
}

const dinheiro = new Intl.NumberFormat("pt-BR", { style: "currency", currency: "BRL" })

function entre(valor: number, minimo: number, maximo: number): number {
  return Math.min(Math.max(valor, minimo), maximo)
}

type Componente = { nome: string; peso: number; fracao: number; disponivel: boolean }

/**
 * Nota da oferta Shopee.
 *
 * A ARQUITETURA e a mesma do ML — denominador sobre os pesos disponiveis, para
 * que sinal que suma saia da conta em vez de virar zero permanente. Mas a
 * LISTA de componentes e outra, e isso e deliberado.
 *
 * Copiar a lista do ML seria um erro sutil e caro: 'frete' e 'condicao' nao
 * existem na resposta da Shopee. Copiados, ficariam permanentemente
 * indisponiveis, a cobertura viveria em 70% no melhor dia, e qualquer terceiro
 * sinal que falhasse derrubaria a rodada inteira por cobertura_insuficiente.
 * O coletor "funcionaria" publicando nada — exatamente a falha que a cobertura
 * foi criada para evitar.
 *
 * A cobertura serve para sinal que DESAPARECEU, nao para sinal que a fonte
 * nunca teve. O que a Shopee nao entrega nao entra na lista.
 *
 * Comissao tambem fica de fora, como no ML: dinheiro ordena a fila, nunca
 * pontua a oferta. Ver 20260902000000.
 */
export function pontuar(
  { produto, descontoVerificado, competitividade }: SinaisShopee,
): Pontuacao {
  const temDesconto = descontoVerificado !== null && descontoVerificado >= DESCONTO_PISO
  const temFundo = competitividade !== null && competitividade >= FUNDO_PISO

  if (!temDesconto && !temFundo) {
    return {
      total: 0,
      cobertura: 0,
      componentes: {},
      ausentes: ["vantagem_de_preco"],
      recusa: "sem_vantagem_de_preco",
    }
  }

  const fracaoDesconto = temDesconto
    ? entre((descontoVerificado! - DESCONTO_PISO) / (DESCONTO_TETO - DESCONTO_PISO), 0, 1)
    : 0

  const fracaoFundo = temFundo
    ? 0.7 + entre((competitividade! - FUNDO_PISO) / (FUNDO_TETO - FUNDO_PISO), 0, 1) * 0.3
    : 0

  const componentes: Componente[] = [
    {
      nome: "vantagem",
      peso: 35,
      // A melhor das duas portas, nao a soma: medem a mesma coisa.
      fracao: Math.max(fracaoDesconto, fracaoFundo),
      disponivel: true,
    },
    {
      nome: "avaliacao",
      peso: 25,
      // Faixa 4,5 a 5,0 e nao 4,0 a 5,0 como no ML: na Shopee quase tudo passa
      // de 4,5, entao a escala do ML amontoaria todo mundo no topo e a nota
      // deixaria de separar.
      fracao: produto.nota === null
        ? 0
        : entre((produto.nota - 4.5) / 0.5, 0, 1),
      disponivel: produto.nota !== null && (produto.vendas ?? 0) >= 10,
    },
    {
      nome: "tracao",
      peso: 20,
      // Mil vendas satura. No ML sao cem: la o catalogo e de ticket mais alto e
      // giro menor, aqui volume alto e o normal e nao a excecao.
      fracao: produto.vendas === null ? 0 : entre(produto.vendas / 1000, 0, 1),
      disponivel: produto.vendas !== null,
    },
    {
      nome: "loja",
      peso: 20,
      fracao: produto.lojaOficial ? 1 : 0,
      // Sempre disponivel: lista vazia em shopType nao e ausencia de dado, e a
      // propria Shopee dizendo que o vendedor nao tem selo.
      disponivel: true,
    },
  ]

  const disponiveis = componentes.filter((c) => c.disponivel)
  const pesoDisponivel = disponiveis.reduce((s, c) => s + c.peso, 0)
  const pesoTotal = componentes.reduce((s, c) => s + c.peso, 0)
  const cobertura = pesoDisponivel / pesoTotal

  const detalhe: Record<string, number> = {}
  for (const c of disponiveis) detalhe[c.nome] = Math.round(c.peso * c.fracao)

  const ausentes = componentes.filter((c) => !c.disponivel).map((c) => c.nome)

  if (cobertura < COBERTURA_MINIMA) {
    return { total: 0, cobertura, componentes: detalhe, ausentes, recusa: "cobertura_insuficiente" }
  }

  const ganho = disponiveis.reduce((s, c) => s + c.peso * c.fracao, 0)
  return {
    total: Math.round((ganho / pesoDisponivel) * 100),
    cobertura,
    componentes: detalhe,
    ausentes,
    recusa: null,
  }
}

function escaparHtml(texto: string): string {
  return texto.replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" })[c] as string)
}

function encurtarTitulo(titulo: string): string {
  const limpo = titulo.replace(/\s+/g, " ").trim()
  if (limpo.length <= LIMITE_TITULO) return limpo
  return `${limpo.slice(0, LIMITE_TITULO - 1).trimEnd()}…`
}

/** Nenhuma URL no texto: o link mora nos botoes, onde a allowlist confere. */
export function montarPayload(sinais: SinaisShopee): PayloadTelegram {
  const { produto, descontoVerificado, competitividade } = sinais
  const linhas: string[] = []

  linhas.push(`🔥 <b>${escaparHtml(encurtarTitulo(produto.titulo))}</b>`)
  linhas.push("")

  const temDesconto = descontoVerificado !== null && descontoVerificado >= DESCONTO_PISO
  const motivo = temDesconto
    ? `📉 ${descontoVerificado!.toFixed(0)}% abaixo do que já vimos`
    : competitividade !== null && competitividade >= FUNDO_TETO
      ? "📉 Menor preço que já vimos neste produto"
      : competitividade !== null && competitividade >= FUNDO_PISO
        ? "📉 Abaixo do preço de costume"
        : null

  // "A partir de" quando ha variacao: o preco anunciado e o da variacao mais
  // barata, e prometer esse valor para todas seria mentira no clique.
  linhas.push(
    produto.precoMaximo !== null
      ? `💰 A partir de <b>${dinheiro.format(produto.precoAtual)}</b>`
      : `💰 <b>${dinheiro.format(produto.precoAtual)}</b>`,
  )

  if (motivo) linhas.push(motivo)

  if (produto.nota !== null && (produto.vendas ?? 0) > 0) {
    const estrelas = produto.nota.toFixed(1).replace(".", ",")
    linhas.push(`⭐ ${estrelas} · ${produto.vendas!.toLocaleString("pt-BR")} vendidos`)
  }

  if (produto.lojaOficial) linhas.push("🏪 Loja oficial")

  linhas.push("")
  linhas.push(LINHA_DE_PUBLICIDADE)

  let texto = linhas.join("\n")

  if (texto.length > LIMITE_LEGENDA) {
    texto = `🔥 <b>${escaparHtml(encurtarTitulo(produto.titulo))}</b>\n\n` +
      `💰 <b>${dinheiro.format(produto.precoAtual)}</b>\n\n${LINHA_DE_PUBLICIDADE}`
  }

  const compartilhar = new URL("https://t.me/share/url")
  compartilhar.searchParams.set("url", produto.urlAfiliado)
  compartilhar.searchParams.set("text", "Achei essa oferta no Baixou")

  const payload: PayloadTelegram = {
    text: texto,
    parse_mode: "HTML",
    reply_markup: {
      inline_keyboard: [
        [{ text: "🛒 Ver oferta", url: produto.urlAfiliado }],
        [{ text: "↗️ Compartilhar", url: compartilhar.toString() }],
      ],
    },
  }

  if (produto.urlImagem) payload.photo = produto.urlImagem

  return payload
}
