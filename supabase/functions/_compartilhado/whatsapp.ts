import { ehLinkDeAfiliado } from "./afiliados.ts"
import { LINHA_DE_PUBLICIDADE, type Botao, type PayloadTelegram } from "./payload.ts"

/**
 * Converte o post do Telegram na versao que se cola num canal do WhatsApp.
 *
 * Existe porque o WhatsApp nao tem API de canal. A Meta nao expoe Canais no
 * Cloud API, e as bibliotecas que fazem isso falam o protocolo do WhatsApp Web
 * por engenharia reversa: funcionam ate o numero ser banido, sem aviso e sem
 * recurso, levando a audiencia junto. Entao a publicacao continua na mao, e o
 * que da para automatizar e tirar o trabalho de montar o post.
 *
 * Duas diferencas de formato mandam no codigo daqui:
 *
 *   1. O WhatsApp nao entende HTML. Negrito e `*texto*`, riscado e `~texto~`.
 *   2. O WhatsApp nao tem botao. No Telegram o link mora no botao, e por isso
 *      payload.ts proibe URL visivel no texto. Aqui a URL TEM que ir no corpo.
 *      Por isso ela passa de novo pela allowlist de afiliado antes de entrar:
 *      a barreira que protege a comissao vale nos dois canais.
 */

/** Legenda de imagem no WhatsApp. O mesmo teto do Telegram, por coincidencia. */
const LIMITE_LEGENDA = 1024

/**
 * Caracteres que o WhatsApp le como formatacao.
 *
 * Titulo de produto vem do fornecedor e ja chegou com asterisco. Se ele passar
 * inteiro, o `*` do anunciante fecha o negrito no meio da frase e o resto do
 * post sai torto. Some pelo mesmo motivo que o Telegram escapa `<`: dado de
 * terceiro nao manda na formatacao.
 */
const CONTROLES_DO_WHATSAPP = /[*_~`]/g

export type Repasse = {
  texto: string
  urlImagem: string | null
  urlAfiliado: string
}

export type ResultadoRepasse =
  | { ok: true; repasse: Repasse }
  | { ok: false; motivo: string }

/**
 * O link que vai para o leitor.
 *
 * Procura pelo dominio, nao pelo rotulo do botao: rotulo e texto de interface e
 * muda quando alguem mexe na copy; dominio e a regra. O botao de compartilhar
 * aponta para t.me e cai fora sozinho por nao ser link de afiliado.
 */
function acharLinkDeAfiliado(payload: PayloadTelegram): string | null {
  const teclado = payload.reply_markup?.inline_keyboard ?? []

  for (const linha of teclado) {
    for (const botao of linha as Botao[]) {
      if (typeof botao?.url === "string" && ehLinkDeAfiliado(botao.url)) {
        return botao.url
      }
    }
  }

  return null
}

/**
 * HTML do Telegram para marcacao do WhatsApp.
 *
 * A ORDEM IMPORTA. As tags viram marcacao primeiro e as entidades sao
 * desescapadas depois. Ao contrario, um titulo que contenha `&lt;b&gt;`
 * escrito pelo anunciante viraria `<b>` e seria tratado como tag nossa — dado
 * de terceiro virando formatacao, que e exatamente o que o escape evita.
 */
function converterFormatacao(html: string): string {
  let saida = ""
  let posicao = 0

  // <b>...</b> e <s>...</s> sao as unicas tags que montarPayload emite.
  const tags = /<(b|s)>([\s\S]*?)<\/\1>/g
  let achado: RegExpExecArray | null

  while ((achado = tags.exec(html)) !== null) {
    const marcador = achado[1] === "b" ? "*" : "~"
    const antes = html.slice(posicao, achado.index)
    const dentro = achado[2] ?? ""

    saida += antes.replace(CONTROLES_DO_WHATSAPP, "")

    const conteudo = dentro.replace(CONTROLES_DO_WHATSAPP, "").trim()
    // Marcador colado em espaco nao renderiza no WhatsApp, e sobra como lixo
    // visivel. Trecho vazio nao ganha marcador nenhum.
    saida += conteudo === "" ? "" : `${marcador}${conteudo}${marcador}`

    posicao = achado.index + achado[0].length
  }

  saida += html.slice(posicao).replace(CONTROLES_DO_WHATSAPP, "")

  // Defesa: qualquer tag que tenha escapado do laco sai como tag, nao como
  // texto solto com sinal de menor no meio do post.
  saida = saida.replace(/<\/?[a-z][^>]*>/gi, "")

  return saida
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&amp;/g, "&")
}

/**
 * Monta o texto pronto para colar.
 *
 * Recusa em vez de improvisar: post sem link de afiliado no WhatsApp e leitor
 * clicando de graca, e a instrucao permanente do dono e que todo disparo saia
 * em cima do link dele. Melhor nao repassar nada do que repassar sem link.
 */
export function montarRepasseWhatsapp(payload: PayloadTelegram): ResultadoRepasse {
  if (typeof payload?.text !== "string" || payload.text.trim() === "") {
    return { ok: false, motivo: "payload_sem_texto" }
  }

  const urlAfiliado = acharLinkDeAfiliado(payload)

  if (!urlAfiliado) {
    return { ok: false, motivo: "sem_link_de_afiliado" }
  }

  const corpo = converterFormatacao(payload.text)

  // A linha de publicidade e exigencia legal e vale nos dois canais. Ela ja
  // vem no texto do Telegram; o link entra ANTES dela para que o aviso continue
  // sendo a ultima coisa que o leitor ve.
  const linhas = corpo.split("\n")
  const ondeEstaOAviso = linhas.findIndex((l) => l.trim() === LINHA_DE_PUBLICIDADE)

  if (ondeEstaOAviso === -1) {
    return { ok: false, motivo: "sem_linha_de_publicidade" }
  }

  linhas.splice(ondeEstaOAviso, 0, `🛒 ${urlAfiliado}`, "")

  const texto = linhas.join("\n").replace(/\n{3,}/g, "\n\n").trim()

  // Nao trunca calado: legenda estourada vira envio sem foto, e o operador
  // precisa saber por que a imagem nao veio junto.
  const cabeNaLegenda = texto.length <= LIMITE_LEGENDA

  return {
    ok: true,
    repasse: {
      texto,
      urlImagem: cabeNaLegenda ? (payload.photo ?? null) : null,
      urlAfiliado,
    },
  }
}
