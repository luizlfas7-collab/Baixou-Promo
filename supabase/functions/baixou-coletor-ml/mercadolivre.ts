const ENDERECO_TOKEN = "https://api.mercadolibre.com/oauth/token"
const ENDERECO_API = "https://api.mercadolibre.com"
const TEMPO_LIMITE_MS = 12_000

/** O ML aceita ate 20 ids por chamada de /items. */
export const MAXIMO_POR_LOTE = 20

export type Credenciais = {
  client_id: string
  client_secret: string
  access_token: string | null
  refresh_token: string | null
  precisa_renovar: boolean
}

export type TokensRenovados = {
  accessToken: string
  refreshToken: string
  expiresIn: number
  escopos: string | null
}

export type ItemMl = {
  id: string
  titulo: string
  precoAtual: number
  precoOriginal: number | null
  urlCanonica: string
  urlImagem: string | null
  disponivel: boolean
  novo: boolean
  vendidos: number
  freteGratis: boolean
  vendedorId: number | null
}

export type AvaliacaoMl = {
  nota: number | null
  total: number
}

export type ReputacaoVendedor = {
  nivel: string | null
  verde: boolean
}

export class ErroMercadoLivre extends Error {
  readonly codigo: string
  readonly retentavel: boolean

  constructor(mensagem: string, codigo: string, retentavel = false) {
    super(mensagem)
    this.name = "ErroMercadoLivre"
    this.codigo = codigo
    this.retentavel = retentavel
  }
}

async function comTempoLimite(
  entrada: string,
  init: RequestInit,
): Promise<Response> {
  const cancelamento = new AbortController()
  const alarme = setTimeout(() => cancelamento.abort(), TEMPO_LIMITE_MS)
  try {
    return await fetch(entrada, { ...init, signal: cancelamento.signal, redirect: "error" })
  } catch (erro) {
    const mensagem = erro instanceof Error ? erro.message : String(erro)
    throw new ErroMercadoLivre(`Falha de rede: ${mensagem}`, "rede", true)
  } finally {
    clearTimeout(alarme)
  }
}

/**
 * Troca o refresh por um par novo. O Mercado Livre rotaciona o refresh a cada
 * renovacao: guardar o novo nao e opcional, e perder o novo custa a conexao
 * inteira.
 */
export async function renovarTokens(credenciais: Credenciais): Promise<TokensRenovados> {
  if (!credenciais.refresh_token) {
    throw new ErroMercadoLivre("Sem refresh_token no cofre", "sem_refresh")
  }

  const corpo = new URLSearchParams({
    grant_type: "refresh_token",
    client_id: credenciais.client_id,
    client_secret: credenciais.client_secret,
    refresh_token: credenciais.refresh_token,
  })

  const resposta = await comTempoLimite(ENDERECO_TOKEN, {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded",
      accept: "application/json",
    },
    body: corpo,
  })

  let dados: Record<string, unknown>
  try {
    dados = await resposta.json()
  } catch {
    throw new ErroMercadoLivre(`Resposta ilegivel (HTTP ${resposta.status})`, "renovacao_ilegivel", true)
  }

  if (!resposta.ok) {
    const detalhe = String(dados.error_description ?? dados.message ?? dados.error ?? resposta.status)
    // 400 aqui costuma ser refresh revogado: repetir nao adianta.
    throw new ErroMercadoLivre(
      `Renovacao recusada: ${detalhe}`,
      "renovacao_recusada",
      resposta.status >= 500,
    )
  }

  const accessToken = typeof dados.access_token === "string" ? dados.access_token : ""
  const refreshToken = typeof dados.refresh_token === "string" ? dados.refresh_token : ""
  const expiresIn = Number(dados.expires_in)

  if (!accessToken || !refreshToken) {
    throw new ErroMercadoLivre("Renovacao veio incompleta", "renovacao_incompleta")
  }

  return {
    accessToken,
    refreshToken,
    expiresIn: Number.isFinite(expiresIn) ? expiresIn : 21600,
    escopos: typeof dados.scope === "string" ? dados.scope : null,
  }
}

async function buscar(
  caminho: string,
  accessToken: string,
): Promise<unknown> {
  const resposta = await comTempoLimite(`${ENDERECO_API}${caminho}`, {
    method: "GET",
    headers: {
      authorization: `Bearer ${accessToken}`,
      accept: "application/json",
    },
  })

  if (resposta.status === 401 || resposta.status === 403) {
    throw new ErroMercadoLivre(
      `Acesso negado em ${caminho} (HTTP ${resposta.status})`,
      "acesso_negado",
    )
  }

  if (resposta.status === 429) {
    throw new ErroMercadoLivre("Limite de taxa do Mercado Livre", "limite_de_taxa", true)
  }

  if (resposta.status >= 500) {
    throw new ErroMercadoLivre(`Servidor do ML respondeu ${resposta.status}`, "servidor_ml", true)
  }

  if (!resposta.ok) {
    throw new ErroMercadoLivre(`HTTP ${resposta.status} em ${caminho}`, `ml_${resposta.status}`)
  }

  try {
    return await resposta.json()
  } catch {
    throw new ErroMercadoLivre(`Resposta ilegivel em ${caminho}`, "resposta_ilegivel", true)
  }
}

function numeroOuNulo(valor: unknown): number | null {
  const numero = Number(valor)
  return Number.isFinite(numero) && numero > 0 ? numero : null
}

/**
 * Imagem em resolucao boa para o Telegram. O ML entrega miniatura por padrao;
 * o sufixo -O e a versao grande, e e a unica que rende no post.
 */
function imagemGrande(item: Record<string, unknown>): string | null {
  const pictures = Array.isArray(item.pictures) ? item.pictures : []
  const primeira = pictures[0] as Record<string, unknown> | undefined
  const bruta = typeof primeira?.secure_url === "string"
    ? primeira.secure_url
    : typeof item.secure_thumbnail === "string"
      ? item.secure_thumbnail
      : null

  if (!bruta || !bruta.startsWith("https://http2.mlstatic.com/")) return null

  return bruta.replace(/-[A-Z]\.(webp|jpg|jpeg|png)$/i, "-O.$1")
}

/** Le ate 20 itens numa chamada so. Item ausente vira erro daquele item. */
export async function lerItens(
  ids: readonly string[],
  accessToken: string,
): Promise<Map<string, ItemMl | ErroMercadoLivre>> {
  const resultado = new Map<string, ItemMl | ErroMercadoLivre>()
  if (ids.length === 0) return resultado

  const bruto = await buscar(
    `/items?ids=${ids.join(",")}&attributes=id,title,price,original_price,permalink,pictures,secure_thumbnail,status,available_quantity,condition,sold_quantity,shipping,seller_id`,
    accessToken,
  )

  const linhas = Array.isArray(bruto) ? bruto : []

  for (const linha of linhas) {
    const envelope = linha as Record<string, unknown>
    const corpo = envelope.body as Record<string, unknown> | undefined
    const codigo = Number(envelope.code)
    const id = typeof corpo?.id === "string" ? corpo.id : String(envelope.id ?? "")

    if (!id) continue

    if (codigo !== 200 || !corpo) {
      resultado.set(id, new ErroMercadoLivre(`Item devolveu codigo ${codigo}`, `item_${codigo}`))
      continue
    }

    const preco = numeroOuNulo(corpo.price)
    const permalink = typeof corpo.permalink === "string" ? corpo.permalink : ""

    if (preco === null || !permalink.startsWith("https://")) {
      resultado.set(id, new ErroMercadoLivre("Item sem preco ou sem link canonico", "item_incompleto"))
      continue
    }

    const frete = corpo.shipping as Record<string, unknown> | undefined

    resultado.set(id, {
      id,
      titulo: typeof corpo.title === "string" ? corpo.title : "",
      precoAtual: preco,
      precoOriginal: numeroOuNulo(corpo.original_price),
      urlCanonica: permalink,
      urlImagem: imagemGrande(corpo),
      disponivel: corpo.status === "active" && Number(corpo.available_quantity ?? 0) > 0,
      novo: corpo.condition === "new",
      vendidos: Number(corpo.sold_quantity ?? 0) || 0,
      freteGratis: frete?.free_shipping === true,
      vendedorId: Number(corpo.seller_id) || null,
    })
  }

  for (const id of ids) {
    if (!resultado.has(id)) {
      resultado.set(id, new ErroMercadoLivre("Item nao veio na resposta", "item_ausente"))
    }
  }

  return resultado
}

/** Avaliacao do produto. Ausencia nao e erro: muitos itens nao tem review. */
export async function lerAvaliacao(
  itemId: string,
  accessToken: string,
): Promise<AvaliacaoMl> {
  try {
    const bruto = await buscar(`/reviews/item/${itemId}`, accessToken) as Record<string, unknown>
    const nota = Number(bruto.rating_average)
    const total = Number(bruto.total_reviews)
    return {
      nota: Number.isFinite(nota) && nota > 0 ? nota : null,
      total: Number.isFinite(total) ? total : 0,
    }
  } catch (erro) {
    if (erro instanceof ErroMercadoLivre && erro.retentavel) throw erro
    return { nota: null, total: 0 }
  }
}

/** Reputacao do vendedor. Verde e o piso para publicar. */
export async function lerReputacao(
  vendedorId: number,
  accessToken: string,
): Promise<ReputacaoVendedor> {
  try {
    const bruto = await buscar(`/users/${vendedorId}`, accessToken) as Record<string, unknown>
    const reputacao = bruto.seller_reputation as Record<string, unknown> | undefined
    const nivel = typeof reputacao?.level_id === "string" ? reputacao.level_id : null
    return {
      nivel,
      verde: nivel === "5_green" || nivel === "4_light_green",
    }
  } catch (erro) {
    if (erro instanceof ErroMercadoLivre && erro.retentavel) throw erro
    return { nivel: null, verde: false }
  }
}
