import { LINHA_DE_PUBLICIDADE, type PayloadTelegram } from "../_compartilhado/payload.ts"
import type { AvaliacaoMl, ItemMl, ReputacaoVendedor } from "./mercadolivre.ts"

/** Legenda do Telegram com foto. Sobra folga para o titulo nao estourar. */
const LIMITE_LEGENDA = 1024
const LIMITE_TITULO = 120

/**
 * Piso de evidencia. Abaixo disso a nota nao significa nada, porque foi
 * calculada sobre poucos sinais.
 */
const COBERTURA_MINIMA = 0.70

/** Desconto verificado onde a nota comeca e onde satura. */
const DESCONTO_PISO = 15
const DESCONTO_TETO = 30

/**
 * Segunda porta, trazida do Radar Rota: preco abaixo da propria referencia.
 *
 * 13 = 10% abaixo da mediana das medianas diarias. 15 = abaixo do melhor dia
 * ja visto. Abaixo de 13 nao e vantagem, e preco normal.
 *
 * Existe porque queda lenta e queda igual: produto que desceu de a pouco e
 * pouco ate o fundo nunca acumula 15% entre duas leituras, e com porta unica
 * jamais viraria post.
 */
const FUNDO_PISO = 13
const FUNDO_TETO = 15

export type Sinais = {
  item: ItemMl
  avaliacao: AvaliacaoMl
  reputacao: ReputacaoVendedor
  /** Desconto que o BANCO apurou contra o proprio historico, nao o que a loja diz. */
  descontoVerificado: number | null
  /** Competitividade apurada pelo banco (0 a 15). null quando nao deu para medir. */
  competitividade: number | null
}

export type Pontuacao = {
  total: number
  cobertura: number
  componentes: Record<string, number>
  ausentes: string[]
  recusa: string | null
}

const dinheiro = new Intl.NumberFormat("pt-BR", {
  style: "currency",
  currency: "BRL",
})

function entre(valor: number, minimo: number, maximo: number): number {
  return Math.min(Math.max(valor, minimo), maximo)
}

type Componente = {
  nome: string
  peso: number
  /** 0 a 1. So e lido quando o sinal esta disponivel. */
  fracao: number
  disponivel: boolean
}

/**
 * Nota sobre o que deu para observar, e nao sobre uma lista fixa.
 *
 * O motor de referencia somava componentes de peso fixo e dava zero no que
 * faltava. O efeito colateral e traicoeiro: no dia em que um endpoint do
 * fornecedor muda, aquele componente vira zero permanente, a nota nunca mais
 * alcanca o corte, e a coleta "funciona" publicando nada. Foi assim que o
 * Radar Rota passou 34 dias vivo sem publicar.
 *
 * Aqui o denominador e a soma dos pesos DISPONIVEIS. Sinal que sumiu sai da
 * conta e aparece em `ausentes`; se sumir sinal demais, a rodada recusa por
 * cobertura baixa, alto e claro, em vez de silenciosamente nunca aprovar.
 */
export function pontuar(
  { item, avaliacao, reputacao, descontoVerificado, competitividade }: Sinais,
): Pontuacao {
  // Vantagem de preco e a propria tese do post: sem ela nao existe oferta,
  // existe so um produto. Mas ela tem DUAS portas, e basta uma.
  //
  //   1. Queda verificada de 15% contra o proprio historico (movimento).
  //   2. Preco 10% abaixo da referencia diaria (patamar).
  //
  // A segunda veio do Radar Rota. Sem ela, produto que desceu devagar ate o
  // fundo nunca acumula 15% entre duas leituras e nunca vira post — e queda
  // lenta e queda igual.
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

  // 13 vale 0,7 e 15 vale 1,0: patamar bom conta, mas nao tanto quanto queda
  // observada, que e o sinal mais forte.
  const fracaoFundo = temFundo
    ? 0.7 + entre((competitividade! - FUNDO_PISO) / (FUNDO_TETO - FUNDO_PISO), 0, 1) * 0.3
    : 0

  const componentes: Componente[] = [
    {
      nome: "vantagem",
      peso: 30,
      // A melhor das duas portas, nao a soma: sao duas medidas da mesma coisa,
      // e somar pagaria duas vezes pelo mesmo fato.
      fracao: Math.max(fracaoDesconto, fracaoFundo),
      disponivel: true,
    },
    {
      nome: "reputacao",
      // Loja oficial vale tanto quanto vendedor verde: sao duas formas de a
      // propria plataforma dizer que a contraparte e confiavel.
      peso: 18,
      fracao: reputacao.verde || item.lojaOficial ? 1 : 0,
      disponivel: reputacao.nivel !== null || item.lojaOficial,
    },
    {
      nome: "avaliacao",
      peso: 22,
      // Nota alta sozinha nao basta: precisa de gente suficiente avaliando.
      fracao: avaliacao.nota === null
        ? 0
        : entre((avaliacao.nota - 4.0) / 1.0, 0, 1) * 0.7 +
          entre(avaliacao.total / 50, 0, 1) * 0.3,
      disponivel: avaliacao.nota !== null && avaliacao.total >= 10,
    },
    {
      nome: "condicao",
      peso: 12,
      fracao: (item.novo ? 0.6 : 0) + (item.disponivel ? 0.4 : 0),
      disponivel: true,
    },
    {
      nome: "tracao",
      peso: 10,
      // A leitura pelo catalogo nao informa quantidade vendida. Sai da conta
      // em vez de valer zero: zero afirmaria que ninguem comprou.
      fracao: item.vendidos === null ? 0 : entre(item.vendidos / 100, 0, 1),
      disponivel: item.vendidos !== null,
    },
    {
      nome: "frete",
      peso: 8,
      fracao: item.freteGratis ? 1 : 0,
      disponivel: true,
    },
  ]

  const disponiveis = componentes.filter((c) => c.disponivel)
  const pesoDisponivel = disponiveis.reduce((soma, c) => soma + c.peso, 0)
  const pesoTotal = componentes.reduce((soma, c) => soma + c.peso, 0)
  const cobertura = pesoDisponivel / pesoTotal

  const detalhe: Record<string, number> = {}
  for (const c of disponiveis) {
    detalhe[c.nome] = Math.round(c.peso * c.fracao)
  }

  const ausentes = componentes.filter((c) => !c.disponivel).map((c) => c.nome)

  if (cobertura < COBERTURA_MINIMA) {
    return {
      total: 0,
      cobertura,
      componentes: detalhe,
      ausentes,
      recusa: "cobertura_insuficiente",
    }
  }

  const ganho = disponiveis.reduce((soma, c) => soma + c.peso * c.fracao, 0)
  const total = Math.round((ganho / pesoDisponivel) * 100)

  return { total, cobertura, componentes: detalhe, ausentes, recusa: null }
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
  const { item, avaliacao, descontoVerificado, competitividade } = sinais

  const linhas: string[] = []

  linhas.push(`🔥 <b>${escaparHtml(encurtarTitulo(item.titulo))}</b>`)
  linhas.push("")

  // A frase precisa dizer qual porta abriu. Escrever "X% abaixo" num post
  // aprovado por patamar seria inventar um numero que ninguem observou; dizer
  // so o preco num post aprovado por queda esconderia o que interessa.
  const temDesconto = descontoVerificado !== null && descontoVerificado >= DESCONTO_PISO
  const motivo = temDesconto
    ? `📉 ${descontoVerificado!.toFixed(0)}% abaixo do que já vimos`
    : competitividade !== null && competitividade >= FUNDO_TETO
      ? "📉 Menor preço que já vimos neste produto"
      : competitividade !== null && competitividade >= FUNDO_PISO
        ? "📉 Abaixo do preço de costume"
        : null

  if (temDesconto && item.precoOriginal && item.precoOriginal > item.precoAtual) {
    linhas.push(
      `<s>${dinheiro.format(item.precoOriginal)}</s>  →  <b>${dinheiro.format(item.precoAtual)}</b>`,
    )
  } else {
    linhas.push(`💰 <b>${dinheiro.format(item.precoAtual)}</b>`)
  }

  if (motivo) linhas.push(motivo)

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
