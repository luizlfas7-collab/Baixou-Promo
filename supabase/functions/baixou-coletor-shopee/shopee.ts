/**
 * Cliente da Open API de afiliados da Shopee.
 *
 * Tudo e GraphQL num endpoint so, sempre POST, autenticado por assinatura
 * SHA256 — nao ha OAuth nem token que expira, ao contrario do Mercado Livre.
 * Em compensacao ha uma armadilha que o ML nao tem, e ela esta em `assinar()`.
 */

const CAMINHO = "/graphql"

/** Diferenca tolerada entre o relogio local e o da Shopee, em segundos. */
const JANELA_DO_RELOGIO = 300

export class ErroShopee extends Error {
  readonly status: number | null
  readonly codigo: string | null

  constructor(mensagem: string, status: number | null = null, codigo: string | null = null) {
    super(mensagem)
    this.name = "ErroShopee"
    this.status = status
    this.codigo = codigo
  }
}

/**
 * A assinatura cobre o CORPO EXATO, byte a byte.
 *
 * `SHA256(app_id + timestamp + corpo + app_secret)`, em hex.
 *
 * O erro classico aqui — e o motivo de "Invalid Signature" ser a duvida mais
 * comum de quem integra esta API — e serializar duas vezes: assinar
 * `JSON.stringify(objeto)` e depois deixar o cliente HTTP serializar o objeto
 * de novo na hora de enviar. Basta a segunda serializacao diferir num espaco
 * ou na ordem das chaves para a assinatura deixar de bater, e a mensagem de
 * erro nao diz qual das duas mudou.
 *
 * Por isso aqui se serializa UMA vez, e a mesma string e o que se assina e o
 * que se envia. `enviar()` recebe a string pronta, nunca um objeto.
 */
async function assinar(
  appId: string,
  appSecret: string,
  corpo: string,
  timestamp: number,
): Promise<string> {
  const base = `${appId}${timestamp}${corpo}${appSecret}`
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(base))
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("")
}

export type Credenciais = {
  appId: string
  appSecret: string
  /** Base da regiao. No Brasil, https://open-api.affiliate.shopee.com.br */
  urlBase: string
}

type RespostaGraphQL<T> = {
  data?: T
  errors?: Array<{ message?: string; extensions?: { code?: string | number } }>
}

async function enviar<T>(
  credenciais: Credenciais,
  corpo: string,
): Promise<T> {
  const timestamp = Math.floor(Date.now() / 1000)
  const assinatura = await assinar(credenciais.appId, credenciais.appSecret, corpo, timestamp)

  let resposta: Response

  try {
    resposta = await fetch(`${credenciais.urlBase}${CAMINHO}`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        // A ordem dos campos do cabecalho nao entra na assinatura; so o corpo.
        "authorization":
          `SHA256 Credential=${credenciais.appId}, Timestamp=${timestamp}, Signature=${assinatura}`,
      },
      body: corpo,
    })
  } catch (erro) {
    throw new ErroShopee(`Falha de rede ao falar com a Shopee: ${erro}`)
  }

  const texto = await resposta.text()

  if (!resposta.ok) {
    throw new ErroShopee(
      `Shopee respondeu ${resposta.status}: ${texto.slice(0, 300)}`,
      resposta.status,
    )
  }

  let json: RespostaGraphQL<T>

  try {
    json = JSON.parse(texto) as RespostaGraphQL<T>
  } catch {
    throw new ErroShopee(`Resposta da Shopee nao e JSON: ${texto.slice(0, 200)}`, resposta.status)
  }

  // GraphQL responde 200 com erro dentro do corpo. Tratar so o status HTTP
  // faria falha de autenticacao passar por sucesso com dados vazios.
  if (json.errors && json.errors.length > 0) {
    const primeiro = json.errors[0]
    const mensagem = primeiro?.message ?? "erro sem mensagem"
    const codigo = primeiro?.extensions?.code
    throw new ErroShopee(
      `Shopee recusou a consulta: ${mensagem}`,
      resposta.status,
      codigo === undefined ? null : String(codigo),
    )
  }

  if (!json.data) {
    throw new ErroShopee("Shopee respondeu sem `data`", resposta.status)
  }

  return json.data
}

/** Monta o corpo uma vez so. Ver o comentario de `assinar()`. */
function corpoDe(query: string, variaveis?: Record<string, unknown>): string {
  return JSON.stringify(
    variaveis === undefined ? { query } : { query, variables: variaveis },
  )
}

// ---------------------------------------------------------------------------
// Produtos
// ---------------------------------------------------------------------------

/** O que a Shopee devolve por produto, so o que este projeto usa. */
export type ProdutoShopee = {
  itemId: string
  shopId: string
  titulo: string
  urlProduto: string
  urlImagem: string | null
  /** Menor preco entre as variacoes. */
  precoMin: number
  /** Maior preco entre as variacoes. Igual ao minimo quando nao ha variacao. */
  precoMax: number
  /**
   * O desconto que a LOJA diz estar dando. Guardado como metadado e nunca
   * usado como desconto — ver o comentario de `temPrecoUnico`.
   */
  descontoDeclarado: number | null
  vendas: number | null
  nota: number | null
  comissaoPct: number | null
  /** Link de afiliado que a propria API ja devolve. Ver `linkPublicavel`. */
  offerLink: string | null
}

type NoProdutoBruto = {
  itemId?: unknown
  shopId?: unknown
  productName?: unknown
  productLink?: unknown
  offerLink?: unknown
  imageUrl?: unknown
  priceMin?: unknown
  priceMax?: unknown
  priceDiscountRate?: unknown
  sales?: unknown
  ratingStar?: unknown
  commissionRate?: unknown
}

function numero(valor: unknown): number | null {
  if (typeof valor === "number" && Number.isFinite(valor)) return valor
  if (typeof valor === "string" && valor.trim() !== "") {
    const n = Number(valor)
    return Number.isFinite(n) ? n : null
  }
  return null
}

function texto(valor: unknown): string | null {
  if (typeof valor === "string" && valor.trim() !== "") return valor.trim()
  if (typeof valor === "number") return String(valor)
  return null
}

/**
 * A Shopee manda preco e comissao como string em varios campos, e a taxa de
 * comissao vem como fracao (0.12) e nao como porcentagem (12).
 */
function fracaoParaPorcentagem(valor: unknown): number | null {
  const n = numero(valor)
  if (n === null) return null
  // Acima de 1 ja veio em porcentagem; abaixo, veio como fracao.
  return n > 1 ? n : n * 100
}

function converter(no: NoProdutoBruto): ProdutoShopee | null {
  const itemId = texto(no.itemId)
  const shopId = texto(no.shopId)
  const titulo = texto(no.productName)
  const urlProduto = texto(no.productLink)
  const precoMin = numero(no.priceMin)
  const precoMax = numero(no.priceMax)

  // Sem identidade, sem titulo ou sem preco nao ha o que observar. Descartar
  // aqui e melhor do que deixar a linha entrar pela metade e falhar depois.
  if (!itemId || !shopId || !titulo || precoMin === null || precoMin <= 0) return null

  return {
    itemId,
    shopId,
    titulo,
    urlProduto: urlProduto ?? `https://shopee.com.br/product/${shopId}/${itemId}`,
    urlImagem: texto(no.imageUrl),
    precoMin,
    precoMax: precoMax ?? precoMin,
    descontoDeclarado: fracaoParaPorcentagem(no.priceDiscountRate),
    vendas: numero(no.sales),
    nota: numero(no.ratingStar),
    comissaoPct: fracaoParaPorcentagem(no.commissionRate),
    offerLink: texto(no.offerLink),
  }
}

/**
 * Produto com faixa de preco nao vira post.
 *
 * `priceMin` e `priceMax` diferentes significam variacoes — cores, tamanhos,
 * kits — com precos diferentes. Anunciar "R$ 99" quando so a variacao mais
 * barata custa isso e a que aparece na foto custa R$ 180 e a forma mais rapida
 * de perder a confianca de quem clica. O Baixou publica preco que o leitor
 * encontra, e com faixa nao da para prometer isso.
 */
export function temPrecoUnico(produto: ProdutoShopee): boolean {
  return Math.abs(produto.precoMax - produto.precoMin) < 0.01
}

const QUERY_PRODUTOS = `query produtos($keyword: String, $limit: Int, $page: Int) {
  productOfferV2(keyword: $keyword, limit: $limit, page: $page) {
    nodes {
      itemId
      shopId
      productName
      productLink
      offerLink
      imageUrl
      priceMin
      priceMax
      priceDiscountRate
      sales
      ratingStar
      commissionRate
    }
    pageInfo { page limit hasNextPage }
  }
}`

export async function buscarProdutos(
  credenciais: Credenciais,
  palavra: string,
  limite: number,
  pagina = 1,
): Promise<ProdutoShopee[]> {
  const dados = await enviar<{
    productOfferV2?: { nodes?: unknown }
  }>(credenciais, corpoDe(QUERY_PRODUTOS, { keyword: palavra, limit: limite, page: pagina }))

  const nos = dados.productOfferV2?.nodes
  if (!Array.isArray(nos)) return []

  const produtos: ProdutoShopee[] = []

  for (const no of nos) {
    if (typeof no !== "object" || no === null) continue
    const convertido = converter(no as NoProdutoBruto)
    if (convertido) produtos.push(convertido)
  }

  return produtos
}

// ---------------------------------------------------------------------------
// Link de afiliado
// ---------------------------------------------------------------------------

const MUTATION_SHORTLINK = `mutation encurtar($input: GenerateShortLinkInput!) {
  generateShortLink(input: $input) { shortLink }
}`

/**
 * Gera o encurtador oficial, com os sub-ids carimbados DENTRO dele.
 *
 * Existe em vez de simplesmente usar `offerLink` por dois motivos:
 *
 *   1. `offerLink` costuma vir como URL longa e com query. A allowlist do
 *      projeto (`ehLinkDeAfiliado`) exige encurtador oficial e query vazia, e
 *      afrouxar a allowlist para caber um link de rastreio abriria a porta
 *      exatamente para o que ela existe para barrar.
 *
 *   2. `subIds` e como a Shopee separa origem do clique. Carimbar na geracao
 *      da o numero por destino sem redirect proprio e sem mascarar nada.
 */
export async function gerarLinkCurto(
  credenciais: Credenciais,
  urlDoProduto: string,
  subIds: string[] = [],
): Promise<string> {
  const dados = await enviar<{
    generateShortLink?: { shortLink?: unknown }
  }>(
    credenciais,
    corpoDe(MUTATION_SHORTLINK, {
      input: {
        originUrl: urlDoProduto,
        // A Shopee aceita no maximo 5.
        subIds: subIds.slice(0, 5),
      },
    }),
  )

  const link = texto(dados.generateShortLink?.shortLink)
  if (!link) throw new ErroShopee("Shopee nao devolveu shortLink")

  return link
}

/** Exportado para o teste da assinatura, que e a parte sutil deste modulo. */
export const _internos = { assinar, corpoDe, converter, JANELA_DO_RELOGIO }
