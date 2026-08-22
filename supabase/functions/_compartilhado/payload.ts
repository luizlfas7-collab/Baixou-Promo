import {
  ehImagemOficial,
  ehLinkDeAfiliado,
  ehLinkDePrevia,
  extrairUrls,
} from "./afiliados.ts"

/** Exigencia legal: todo post precisa se identificar como publicidade. */
export const LINHA_DE_PUBLICIDADE = "PUBLICIDADE • LINK DE AFILIADO"

const LIMITE_BYTES = 32 * 1024
const LIMITE_TEXTO = 4096
const LIMITE_LEGENDA = 1024
const MAX_BOTOES = 100
const MAX_BOTOES_POR_LINHA = 8
const MAX_LINHAS_DE_BOTOES = 20

const CHAVES_PERMITIDAS = new Set([
  "text",
  "photo",
  "parse_mode",
  "link_preview_options",
  "reply_markup",
])

const PADROES_DE_SEGREDO: readonly RegExp[] = [
  /bearer\s+[a-z0-9._~+/-]{16,}/i,
  /(^|[^0-9])\d{5,16}:[A-Za-z0-9_-]{30,}/,
  /sk-[A-Za-z0-9_-]{16,}/,
  /sb_secret_[A-Za-z0-9_-]{16,}/,
  /gh[pousr]_[A-Za-z0-9]{16,}/,
  /eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\./,
  /-----BEGIN [A-Z ]*PRIVATE KEY-----/,
  /api[_-]?key=[A-Za-z0-9_-]{8,}/i,
  /(^|[^0-9])\d{3}\.\d{3}\.\d{3}-\d{2}([^0-9]|$)/,
]

export type Botao = { text: string; url: string }

export type PayloadTelegram = {
  text: string
  photo?: string
  parse_mode?: "HTML" | "MarkdownV2"
  link_preview_options?: { url?: string; is_disabled?: boolean }
  reply_markup?: { inline_keyboard: Botao[][] }
}

export type Resultado =
  | { ok: true; payload: PayloadTelegram }
  | { ok: false; erros: string[] }

/** Compara ignorando acento e caixa, como o leitor le. */
function normalizar(linha: string): string {
  return linha
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .trim()
    .toUpperCase()
}

const PUBLICIDADE_NORMALIZADA = normalizar(LINHA_DE_PUBLICIDADE)

function ehObjeto(valor: unknown): valor is Record<string, unknown> {
  return typeof valor === "object" && valor !== null && !Array.isArray(valor)
}

/** O botao COMPARTILHAR e a unica URL com query aninhada que aceitamos. */
function validaBotaoDeCompartilhar(url: string): string | null {
  let alvo: URL

  try {
    alvo = new URL(url)
  } catch {
    return "URL de compartilhamento invalida"
  }

  if (alvo.origin !== "https://t.me" || alvo.pathname !== "/share/url") {
    return "Compartilhamento so pode apontar para https://t.me/share/url"
  }

  const destino = alvo.searchParams.get("url")
  if (!destino || !ehLinkDeAfiliado(destino)) {
    return "O link compartilhado precisa ser de afiliado"
  }

  const texto = alvo.searchParams.get("text") ?? ""
  if (extrairUrls(texto).length > 0) {
    return "O texto do compartilhamento nao pode conter URL"
  }

  return null
}

/** Ultima barreira antes do envio. */
export function validarPayloadTelegram(entrada: unknown): Resultado {
  const erros: string[] = []

  if (!ehObjeto(entrada)) {
    return { ok: false, erros: ["O payload precisa ser um objeto"] }
  }

  for (const chave of Object.keys(entrada)) {
    if (!CHAVES_PERMITIDAS.has(chave)) {
      erros.push(`Chave nao permitida no payload: ${chave}`)
    }
  }

  const bytes = new TextEncoder().encode(JSON.stringify(entrada)).length
  if (bytes > LIMITE_BYTES) {
    erros.push(`Payload de ${bytes} bytes excede o limite de ${LIMITE_BYTES}`)
  }

  const texto = entrada.text
  if (typeof texto !== "string" || texto.trim() === "") {
    erros.push("O texto da mensagem nao pode ser vazio")
    return { ok: false, erros }
  }

  const temFoto = typeof entrada.photo === "string" && entrada.photo !== ""
  const limite = temFoto ? LIMITE_LEGENDA : LIMITE_TEXTO
  if (texto.length > limite) {
    erros.push(`Texto com ${texto.length} caracteres excede o limite de ${limite}`)
  }

  for (const padrao of PADROES_DE_SEGREDO) {
    if (padrao.test(texto)) {
      erros.push("O texto contem algo com formato de credencial ou documento")
      break
    }
  }

  const temPublicidade = texto
    .split("\n")
    .some((linha) => normalizar(linha) === PUBLICIDADE_NORMALIZADA)

  if (!temPublicidade) {
    erros.push(`Falta a linha obrigatoria "${LINHA_DE_PUBLICIDADE}"`)
  }

  for (const url of extrairUrls(texto)) {
    if (!ehLinkDeAfiliado(url)) {
      erros.push(`URL visivel no texto nao e link de afiliado: ${url}`)
    }
  }

  if (temFoto && !ehImagemOficial(entrada.photo as string)) {
    erros.push("A foto precisa vir de uma CDN oficial da loja")
  }

  const previa = entrada.link_preview_options
  if (previa !== undefined) {
    if (!ehObjeto(previa)) {
      erros.push("link_preview_options precisa ser um objeto")
    } else if (typeof previa.url === "string" && !ehLinkDePrevia(previa.url)) {
      erros.push(`Previa aponta para dominio nao permitido: ${previa.url}`)
    }
  }

  const marcacao = entrada.reply_markup
  if (marcacao !== undefined) {
    if (!ehObjeto(marcacao) || !Array.isArray(marcacao.inline_keyboard)) {
      erros.push("reply_markup precisa conter inline_keyboard")
    } else {
      const linhas = marcacao.inline_keyboard as unknown[]

      if (linhas.length > MAX_LINHAS_DE_BOTOES) {
        erros.push(`Teclado com ${linhas.length} linhas excede ${MAX_LINHAS_DE_BOTOES}`)
      }

      let total = 0

      for (const linha of linhas) {
        if (!Array.isArray(linha)) {
          erros.push("Cada linha do teclado precisa ser uma lista")
          continue
        }

        if (linha.length > MAX_BOTOES_POR_LINHA) {
          erros.push(`Linha com ${linha.length} botoes excede ${MAX_BOTOES_POR_LINHA}`)
        }

        total += linha.length

        for (const botao of linha) {
          if (!ehObjeto(botao) || typeof botao.text !== "string" || typeof botao.url !== "string") {
            erros.push("Cada botao precisa ter text e url")
            continue
          }

          const url = botao.url

          if (url.startsWith("https://t.me/share/url")) {
            const problema = validaBotaoDeCompartilhar(url)
            if (problema) erros.push(problema)
          } else if (!ehLinkDeAfiliado(url)) {
            erros.push(`Botao aponta para dominio nao permitido: ${url}`)
          }
        }
      }

      if (total > MAX_BOTOES) {
        erros.push(`Teclado com ${total} botoes excede ${MAX_BOTOES}`)
      }
    }
  }

  if (erros.length > 0) return { ok: false, erros }

  return { ok: true, payload: entrada as PayloadTelegram }
}
