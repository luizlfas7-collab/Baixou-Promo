/**
 * Regra que atravessa todo o publicador: o link que aparece para o leitor so
 * pode ser um encurtador oficial de afiliado, sem URL aninhada na query.
 */

/** Encurtadores oficiais. Podem aparecer no texto e nos botoes. */
const DOMINIOS_DE_AFILIADO = new Set([
  "meli.la",
  "s.shopee.com.br",
  "tidd.ly",
  "amzn.to",
])

/** Paginas oficiais de produto. Valem apenas para a previa. */
const DOMINIOS_DE_PREVIA = new Set([
  "mercadolivre.com.br",
  "www.mercadolivre.com.br",
  "produto.mercadolivre.com.br",
  "www.kabum.com.br",
  "www.amazon.com.br",
])

/** CDNs oficiais de imagem, para o envio com foto. */
const DOMINIOS_DE_IMAGEM = new Set([
  "cf.shopee.com.br",
  "down-br.img.susercontent.com",
  "http2.mlstatic.com",
  "images-na.ssl-images-amazon.com",
  "m.media-amazon.com",
  "images.kabum.com.br",
])

const QUERY_TOLERADA_NA_PREVIA = /^pdp_filters=item_id:MLB\d{6,20}$/

function analisar(url: string): URL | null {
  let alvo: URL

  try {
    alvo = new URL(url)
  } catch {
    return null
  }

  if (alvo.protocol !== "https:") return null
  if (alvo.username !== "" || alvo.password !== "") return null
  if (alvo.port !== "") return null

  return alvo
}

/** Uma URL dentro da query de outra e o padrao classico de link mascarado. */
function temUrlAninhada(alvo: URL): boolean {
  const suspeito = decodeURIComponent(alvo.search + alvo.hash).toLowerCase()
  return suspeito.includes("http://") || suspeito.includes("https://")
}

export function ehLinkDeAfiliado(url: string): boolean {
  const alvo = analisar(url)
  if (!alvo) return false
  if (!DOMINIOS_DE_AFILIADO.has(alvo.hostname)) return false
  if (temUrlAninhada(alvo)) return false
  return alvo.search === ""
}

export function ehLinkDePrevia(url: string): boolean {
  const alvo = analisar(url)
  if (!alvo) return false
  if (!DOMINIOS_DE_PREVIA.has(alvo.hostname)) return false
  if (temUrlAninhada(alvo)) return false
  if (alvo.search === "") return true
  return QUERY_TOLERADA_NA_PREVIA.test(alvo.search.slice(1))
}

export function ehImagemOficial(url: string): boolean {
  const alvo = analisar(url)
  if (!alvo) return false
  return DOMINIOS_DE_IMAGEM.has(alvo.hostname) && !temUrlAninhada(alvo)
}

/** Toda URL visivel no texto da mensagem. */
export function extrairUrls(texto: string): string[] {
  return texto.match(/https?:\/\/[^\s<>"'()[\]]+/gi) ?? []
}
