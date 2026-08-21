const ENDERECO_TOKEN = "https://api.mercadolibre.com/oauth/token"
const ENDERECO_API = "https://api.mercadolibre.com"
const TEMPO_LIMITE_MS = 12_000

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
  /** null quando a fonte nao informa. Nao confundir com zero vendas. */
  vendidos: number | null
  freteGratis: boolean
  lojaOficial: boolean
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

async function comTempoLimite(entrada: string, init: RequestInit): Promise<Response> {
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

async function buscar(caminho: string, accessToken: string): Promise<unknown> {
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

  if (resposta.status === 404) {
    throw new ErroMercadoLivre(`Nao encontrado: ${caminho}`, "nao_encontrado")
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
function imagemGrande(bruta: string | null): string | null {
  if (!bruta || !bruta.startsWith("https://http2.mlstatic.com/")) return null
  return bruta.replace(/-[A-Z]\.(webp|jpg|jpeg|png)$/i, "-O.$1")
}

/**
 * Le um anuncio pela porta do catalogo.
 *
 * O /items/{id} de anuncio de terceiro responde 403 nesta aplicacao, com ou
 * sem escopo — testado a exaustao. Ja /products/{catalogo}/items devolve
 * todos os anuncios que disputam aquele produto, com preco e preco original.
 * O titulo e a foto vem de /products/{catalogo}, que a lista nao traz.
 *
 * Duas chamadas por item, portanto. E o preco que o conjunto paga por ter
 * fechado o endpoint direto.
 */
export async function lerAnuncioDoCatalogo(
  produtoCatalogo: string,
  itemId: string | null,
  accessToken: string,
): Promise<ItemMl> {
  const [catalogo, lista] = await Promise.all([
    buscar(`/products/${produtoCatalogo}`, accessToken) as Promise<Record<string, unknown>>,
    buscar(`/products/${produtoCatalogo}/items`, accessToken) as Promise<Record<string, unknown>>,
  ])

  const anuncios = (Array.isArray(lista.results) ? lista.results : []) as Record<string, unknown>[]

  let nosso: Record<string, unknown> | undefined

  if (itemId) {
    // Link preso a um anuncio: seguir outro vendedor mudaria o que o leitor
    // encontra ao clicar.
    nosso = anuncios.find((a) => a.item_id === itemId)

    if (!nosso) {
      throw new ErroMercadoLivre(
        `Anuncio ${itemId} nao esta mais no catalogo ${produtoCatalogo}`,
        "anuncio_fora_do_catalogo",
      )
    }
  } else {
    // Link para a pagina do catalogo: quem clica compra de quem estiver
    // ganhando a vitrine. O menor preco e a melhor aproximacao disso, e e o
    // numero que o leitor vai ver.
    nosso = anuncios
      .filter((a) => numeroOuNulo(a.price) !== null)
      .sort((a, b) => Number(a.price) - Number(b.price))[0]

    if (!nosso) {
      throw new ErroMercadoLivre(
        `Catalogo ${produtoCatalogo} sem anuncio com preco`,
        "catalogo_sem_anuncio",
      )
    }
  }

  const preco = numeroOuNulo(nosso.price)
  if (preco === null) {
    throw new ErroMercadoLivre("Anuncio sem preco", "sem_preco")
  }

  const titulo = typeof catalogo.name === "string" ? catalogo.name : ""
  const fotos = Array.isArray(catalogo.pictures) ? catalogo.pictures : []
  const primeira = fotos[0] as Record<string, unknown> | undefined
  const urlFoto = typeof primeira?.url === "string"
    ? primeira.url
    : typeof primeira?.secure_url === "string"
      ? primeira.secure_url
      : null

  const frete = nosso.shipping as Record<string, unknown> | undefined

  return {
    id: String(nosso.item_id ?? itemId ?? produtoCatalogo),
    titulo,
    precoAtual: preco,
    precoOriginal: numeroOuNulo(nosso.original_price),
    // O catalogo devolve permalink vazio; a URL canonica do produto e estavel.
    urlCanonica: `https://www.mercadolivre.com.br/p/${produtoCatalogo}`,
    urlImagem: imagemGrande(urlFoto),
    disponivel: catalogo.status === "active",
    novo: nosso.condition === "new",
    // Esta resposta nao informa quantidade vendida. null, e nao zero: zerar
    // seria afirmar que ninguem comprou, o que nao sabemos.
    vendidos: null,
    freteGratis: frete?.free_shipping === true,
    lojaOficial: nosso.official_store_id != null,
    vendedorId: Number(nosso.seller_id) || null,
  }
}

/** Avaliacao do produto. Ausencia nao e erro: muitos itens nao tem review. */
export async function lerAvaliacao(itemId: string, accessToken: string): Promise<AvaliacaoMl> {
  try {
    const bruto = await buscar(`/reviews/item/${itemId}`, accessToken) as Record<string, unknown>
    const avaliacao = bruto.rating_average ?? (bruto.paging as Record<string, unknown> | undefined)?.rating_average
    const nota = Number(avaliacao)
    const paginacao = bruto.paging as Record<string, unknown> | undefined
    const total = Number(bruto.total_reviews ?? paginacao?.total)
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
