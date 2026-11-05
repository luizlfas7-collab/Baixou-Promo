/**
 * Cliente da Open API de afiliados da Shopee.
 *
 * Uma chamada GraphQL por palavra-chave, assinada com o par App ID + Secret.
 */

const ENDPOINT = "https://open-api.affiliate.shopee.com.br/graphql"
const TEMPO_LIMITE_MS = 12_000

export class ErroShopee extends Error {
  constructor(readonly codigo: string, mensagem: string) {
    super(mensagem)
    this.name = "ErroShopee"
  }
}

export type ProdutoShopee = {
  itemId: string
  titulo: string
  /** priceMin: o menor preco entre as variacoes. E o que o anuncio mostra. */
  precoAtual: number
  /** priceMax quando difere de priceMin: o produto tem variacao de preco. */
  precoMaximo: number | null
  vendas: number | null
  nota: number | null
  /** 0 a 1, nao percentual. A API devolve "0.13" para 13%. */
  comissao: number | null
  urlImagem: string | null
  /** Link curto de afiliado (s.shopee.com.br). E o unico que pode ir ao ar. */
  urlAfiliado: string
  urlCanonica: string
  loja: string | null
  lojaOficial: boolean
  /**
   * Desconto que a PROPRIA SHOPEE afirma. Entra so nos metadados, nunca na
   * pontuacao: o projeto inteiro e construido sobre desconto apurado contra o
   * historico que nos mesmos observamos. Preco "de" de loja e marketing.
   */
  descontoAlegado: number | null
}

/**
 * A assinatura e SHA256(app_id + timestamp + corpo + secret), em hex.
 *
 * ARMADILHA, ja paga uma vez: o `corpo` aqui tem que ser BYTE A BYTE o mesmo
 * texto enviado na requisicao. Assinar um objeto e deixar o cliente HTTP
 * serializar de novo devolve "error [10020]: Invalid Signature", porque a
 * segunda serializacao muda espaco ou ordem de chave. Por isso o corpo e
 * montado como string UMA vez e essa mesma string e assinada e enviada.
 */
async function assinar(
  appId: string,
  secret: string,
  timestamp: number,
  corpo: string,
): Promise<string> {
  const bytes = new TextEncoder().encode(`${appId}${timestamp}${corpo}${secret}`)
  const digest = await crypto.subtle.digest("SHA-256", bytes)
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("")
}

/** Aspas e barras invertidas quebrariam a query GraphQL montada como texto. */
function limparPalavra(palavra: string): string {
  return palavra.replace(/["\\\n\r]/g, " ").trim().slice(0, 60)
}

function numeroOuNulo(valor: unknown): number | null {
  if (valor === null || valor === undefined || valor === "") return null
  const n = Number(valor)
  return Number.isFinite(n) ? n : null
}

export async function buscarPorPalavra(
  appId: string,
  secret: string,
  palavra: string,
  limite: number,
): Promise<ProdutoShopee[]> {
  const termo = limparPalavra(palavra)
  if (termo === "") return []

  const query = `{ productOfferV2(keyword: "${termo}", sortType: 2, page: 1, limit: ${limite}) ` +
    `{ nodes { itemId productName priceMin priceMax sales ratingStar imageUrl ` +
    `offerLink productLink commissionRate shopName shopType priceDiscountRate } } }`

  // Uma string so, assinada e enviada. Ver o comentario em assinar().
  const corpo = JSON.stringify({ query })
  const timestamp = Math.floor(Date.now() / 1000)
  const assinatura = await assinar(appId, secret, timestamp, corpo)

  const cancelamento = AbortSignal.timeout(TEMPO_LIMITE_MS)
  let resposta: Response

  try {
    resposta = await fetch(ENDPOINT, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "Authorization":
          `SHA256 Credential=${appId}, Timestamp=${timestamp}, Signature=${assinatura}`,
      },
      body: corpo,
      signal: cancelamento,
    })
  } catch (erro) {
    const motivo = erro instanceof Error ? erro.message : String(erro)
    throw new ErroShopee("rede", `Falha ao falar com a Shopee: ${motivo}`)
  }

  const texto = await resposta.text()

  if (!resposta.ok) {
    throw new ErroShopee("http", `HTTP ${resposta.status} da Shopee`)
  }

  let json: Record<string, unknown>
  try {
    json = JSON.parse(texto)
  } catch {
    throw new ErroShopee("resposta", "Resposta da Shopee nao e JSON")
  }

  // A Shopee devolve 200 com erro no corpo. Sem este ramo, chave invalida
  // pareceria "nenhum produto encontrado" e a coleta ficaria muda sem motivo
  // aparente — a mesma cegueira de 62h que ja aconteceu com o ML.
  const erros = json.errors as Array<Record<string, unknown>> | undefined
  if (Array.isArray(erros) && erros.length > 0) {
    const primeiro = erros[0]
    const ext = primeiro.extensions as Record<string, unknown> | undefined
    const codigo = ext?.code === undefined ? "graphql" : `shopee_${ext.code}`
    throw new ErroShopee(codigo, String(primeiro.message ?? "Erro sem mensagem"))
  }

  const dados = json.data as Record<string, unknown> | undefined
  const oferta = dados?.productOfferV2 as Record<string, unknown> | undefined
  const nos = oferta?.nodes

  if (!Array.isArray(nos)) {
    throw new ErroShopee("formato", "productOfferV2.nodes ausente na resposta")
  }

  const produtos: ProdutoShopee[] = []

  for (const bruto of nos as Array<Record<string, unknown>>) {
    const precoMin = numeroOuNulo(bruto.priceMin)
    const urlAfiliado = typeof bruto.offerLink === "string" ? bruto.offerLink : ""
    const itemId = bruto.itemId === undefined || bruto.itemId === null
      ? ""
      : String(bruto.itemId)

    // Sem preco, sem id ou sem link de afiliado nao ha o que observar nem o que
    // publicar. Descartar aqui poupa uma ida ao banco por item.
    if (precoMin === null || precoMin <= 0 || itemId === "" || urlAfiliado === "") continue

    const precoMax = numeroOuNulo(bruto.priceMax)
    const tipoLoja = bruto.shopType

    produtos.push({
      itemId,
      titulo: String(bruto.productName ?? "").trim(),
      precoAtual: precoMin,
      precoMaximo: precoMax !== null && precoMax > precoMin ? precoMax : null,
      vendas: numeroOuNulo(bruto.sales),
      nota: numeroOuNulo(bruto.ratingStar),
      comissao: numeroOuNulo(bruto.commissionRate),
      urlImagem: typeof bruto.imageUrl === "string" ? bruto.imageUrl : null,
      urlAfiliado,
      urlCanonica: typeof bruto.productLink === "string" ? bruto.productLink : "",
      loja: typeof bruto.shopName === "string" ? bruto.shopName : null,
      // shopType vem como lista de marcadores; vazia e vendedor comum.
      lojaOficial: Array.isArray(tipoLoja) && tipoLoja.length > 0,
      descontoAlegado: numeroOuNulo(bruto.priceDiscountRate),
    })
  }

  return produtos
}
