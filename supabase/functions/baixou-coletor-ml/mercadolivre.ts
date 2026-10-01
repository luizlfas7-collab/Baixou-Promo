const ENDERECO_TOKEN = "https://api.mercadolibre.com/oauth/token"
const ENDERECO_API = "https://api.mercadolibre.com"
const TEMPO_LIMITE_MS = 12_000

/**
 * Retentativa com recuo, so para o que e transitorio.
 *
 * O que ela conserta: uma falha de rede ou um 429 perdia a leitura daquele
 * item e ele so voltava na revisita seguinte, ~1h depois. Com a watchlist em
 * 320 e ~300 leituras/h, cada leitura perdida e uma hora de cegueira naquele
 * produto — e queda relampago mora exatamente nesse intervalo.
 *
 * O que ela NAO faz: repetir 404, 401 ou 403. Esses sao definitivos; repetir
 * so gasta janela e bate mais na API de quem ja disse nao.
 *
 * O TETO E POR RODADA, e essa e a parte que importa. Sem teto, dois itens com
 * timeout de 12s consumiriam 3 tentativas cada e a rodada passaria dos 120s do
 * cron — a retentativa teria trocado "perde uma leitura" por "perde a rodada
 * inteira".
 *
 * E o orcamento conta o TEMPO DA TENTATIVA, nao so o sono. Contar so o sono
 * seria uma conta que nao fecha: o sono e de milissegundos e o timeout e de
 * 12 SEGUNDOS, entao o gasto real mora na tentativa. Por isso so se retenta
 * quando o PIOR CASO da proxima tentativa (sono + timeout) ainda cabe no que
 * sobrou. Pior caso da rodada inteira: ~7s de trabalho + ~13s de retentativa.
 */
const MAX_TENTATIVAS = 3
const ORCAMENTO_DE_ESPERA_MS = 20_000
const RECUO_BASE_MS = 400
const RECUO_BASE_LIMITE_DE_TAXA_MS = 1_000
/** Retry-After absurdo nao pode sequestrar a rodada. */
const ESPERA_MAXIMA_MS = 8_000

let orcamentoRestanteMs = 0

/**
 * Zera o orcamento no comeco de cada rodada.
 *
 * O isolate do Deno pode ser reaproveitado entre invocacoes, entao o estado de
 * modulo sobrevive: sem este reset a segunda rodada herdaria o orcamento gasto
 * pela primeira e nao retentaria nada.
 */
export function iniciarOrcamentoDeRetentativa(ms: number = ORCAMENTO_DE_ESPERA_MS): void {
  orcamentoRestanteMs = ms
}

/** Quanto ja se gastou esperando nesta rodada. Vai para os metadados. */
export function esperaGastaMs(): number {
  return Math.max(0, ORCAMENTO_DE_ESPERA_MS - orcamentoRestanteMs)
}

/**
 * Ha espaco para mais uma tentativa?
 *
 * Reserva o pior caso — o sono MAIS um timeout cheio — antes de autorizar.
 * Autorizar so pelo sono deixaria a tentativa seguinte estourar a janela.
 */
function cabeOutraTentativa(esperaMs: number): boolean {
  return esperaMs + TEMPO_LIMITE_MS <= orcamentoRestanteMs
}

/** Desconta o que a tentativa REALMENTE custou, sono incluido. */
function descontarDoOrcamento(ms: number): void {
  orcamentoRestanteMs = Math.max(0, orcamentoRestanteMs - ms)
}

function dormir(ms: number): Promise<void> {
  return new Promise((resolver) => setTimeout(resolver, ms))
}

/**
 * Recuo exponencial com tremor. O tremor evita que os 10 itens da rodada, ao
 * baterem no mesmo 429, voltem todos no mesmo milissegundo.
 */
function esperaDaTentativa(tentativa: number, erro: ErroMercadoLivre): number {
  if (erro.esperarSegundos !== null) {
    return Math.min(erro.esperarSegundos * 1000, ESPERA_MAXIMA_MS)
  }
  const base = erro.codigo === "limite_de_taxa"
    ? RECUO_BASE_LIMITE_DE_TAXA_MS
    : RECUO_BASE_MS
  const recuo = base * Math.pow(3, tentativa - 1)
  const tremor = recuo * (0.75 + Math.random() * 0.5)
  return Math.min(Math.round(tremor), ESPERA_MAXIMA_MS)
}

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
  /** Do cabecalho Retry-After, quando o ML diz quanto esperar. */
  readonly esperarSegundos: number | null

  constructor(
    mensagem: string,
    codigo: string,
    retentavel = false,
    esperarSegundos: number | null = null,
  ) {
    super(mensagem)
    this.name = "ErroMercadoLivre"
    this.codigo = codigo
    this.retentavel = retentavel
    this.esperarSegundos = esperarSegundos
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

/** Segundos do cabecalho Retry-After, quando vier em formato numerico. */
function lerRetryAfter(resposta: Response): number | null {
  const bruto = resposta.headers.get("retry-after")
  if (!bruto) return null
  const segundos = Number(bruto)
  return Number.isFinite(segundos) && segundos >= 0 ? segundos : null
}

async function buscarUmaVez(caminho: string, accessToken: string): Promise<unknown> {
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
    throw new ErroMercadoLivre(
      "Limite de taxa do Mercado Livre",
      "limite_de_taxa",
      true,
      lerRetryAfter(resposta),
    )
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

/**
 * Le a API do ML repetindo so o que e transitorio, dentro do orcamento da
 * rodada. Erro definitivo sobe na primeira tentativa, como antes.
 */
async function buscar(caminho: string, accessToken: string): Promise<unknown> {
  let ultimoErro: ErroMercadoLivre | null = null

  for (let tentativa = 1; tentativa <= MAX_TENTATIVAS; tentativa += 1) {
    // A primeira tentativa e a leitura normal e nao consome orcamento: o
    // orcamento paga o que a retentativa ACRESCENTA.
    const comecou = Date.now()

    try {
      const resultado = await buscarUmaVez(caminho, accessToken)
      if (tentativa > 1) descontarDoOrcamento(Date.now() - comecou)
      return resultado
    } catch (erro) {
      if (tentativa > 1) descontarDoOrcamento(Date.now() - comecou)
      if (!(erro instanceof ErroMercadoLivre) || !erro.retentavel) throw erro

      ultimoErro = erro
      if (tentativa === MAX_TENTATIVAS) break

      const espera = esperaDaTentativa(tentativa, erro)
      // Sem espaco para o pior caso da proxima: desistir agora e melhor que
      // estourar a rodada.
      if (!cabeOutraTentativa(espera)) break

      descontarDoOrcamento(espera)
      await dormir(espera)
    }
  }

  // O laco so chega aqui depois de pelo menos uma falha retentavel, entao
  // `ultimoErro` esta preenchido. A guarda existe para que um refactor futuro
  // que mexa no laco nao acabe lancando null — erro sem mensagem e pior que o
  // erro original.
  throw ultimoErro ??
    new ErroMercadoLivre(`Falha sem diagnostico em ${caminho}`, "sem_diagnostico", true)
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
