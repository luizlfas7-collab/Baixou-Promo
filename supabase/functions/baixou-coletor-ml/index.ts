import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2.112.3"

import { validarPayloadTelegram } from "../_compartilhado/payload.ts"
import {
  ErroMercadoLivre,
  lerAvaliacao,
  lerAnuncioDoCatalogo,
  lerReputacao,
  renovarTokens,
  type Credenciais,
  type ItemMl,
} from "./mercadolivre.ts"
import { montarPayload, pontuar } from "./oferta.ts"

const FONTE = "mercado_livre_api_oficial"
const FORMATO_URL_SUPABASE = /^https:\/\/[a-z0-9]{20}\.supabase\.co$/
const LIMITE_CORPO_BYTES = 2048

function exigirVariavel(nome: string): string {
  const valor = Deno.env.get(nome)
  if (!valor) throw new Error(`Variavel de ambiente ausente: ${nome}`)
  return valor
}

function responder(status: number, corpo: Record<string, unknown>): Response {
  return new Response(JSON.stringify(corpo), {
    status,
    headers: { "content-type": "application/json" },
  })
}

type ItemObservado = {
  id: number
  item_id: string | null
  url_afiliado: string
  categoria: string
  produto_catalogo: string
}

type Resumo = {
  vistos: number
  observados: number
  enfileirados: number
  recusados: number
  falhas: number
  detalhes: Array<Record<string, unknown>>
}

/** Chave estavel por item e por janela de coleta: repetir a rodada nao duplica. */
function chaveObservacao(itemId: string, agora: Date): string {
  const janela = Math.floor(agora.getTime() / 60_000)
  return `ml:${itemId}:${janela}`
}

async function garantirToken(
  supabase: SupabaseClient,
  credenciais: Credenciais,
): Promise<string> {
  if (!credenciais.precisa_renovar && credenciais.access_token) {
    return credenciais.access_token
  }

  const renovados = await renovarTokens(credenciais)

  const { error } = await supabase.rpc("oauth_ml_gravar_tokens", {
    p_access_token: renovados.accessToken,
    p_refresh_token: renovados.refreshToken,
    p_expires_in: renovados.expiresIn,
    p_escopos: renovados.escopos,
    p_primeira_conexao: false,
  })

  if (error) {
    // Renovou no ML mas nao guardou: o refresh antigo ja nao vale mais.
    throw new ErroMercadoLivre(
      `Tokens renovados mas nao gravados: ${error.message}`,
      "renovacao_nao_gravada",
    )
  }

  return renovados.accessToken
}

async function processarItem(
  supabase: SupabaseClient,
  observado: ItemObservado,
  item: ItemMl,
  accessToken: string,
  pontuacaoMinima: number,
  ensaio: boolean,
  resumo: Resumo,
): Promise<void> {
  const agora = new Date()
  // Identidade estavel: quando a linha segue o vencedor do catalogo, o
  // vendedor muda de uma rodada para outra. Amarrar o historico ao item da vez
  // fragmentaria a serie de precos justamente no caso em que ela mais importa.
  const identidade = observado.item_id ?? observado.produto_catalogo
  const chave = chaveObservacao(identidade, agora)

  // Primeira passada sem payload: o banco grava a observacao de preco e
  // devolve o desconto que ELE apurou contra o proprio historico. Sem isso a
  // pontuacao acreditaria no preco "de" que a loja informa.
  const { data: observacao, error: erroObservar } = await supabase.rpc("registrar_oferta", {
    p_fonte_slug: FONTE,
    p_id_externo: identidade,
    p_titulo: item.titulo,
    p_url_canonica: item.urlCanonica,
    p_preco_atual: item.precoAtual,
    p_chave_observacao: chave,
    p_url_afiliado: observado.url_afiliado,
    p_url_imagem: item.urlImagem,
    p_preco_original: item.precoOriginal,
    p_metadados: { categoria: observado.categoria, catalogo: observado.produto_catalogo },
  })

  if (erroObservar) {
    await supabase.rpc("ml_item_falhou", { p_id: observado.id, p_motivo: erroObservar.message })
    resumo.falhas += 1
    resumo.detalhes.push({ item: item.id, etapa: "observar", erro: erroObservar.message })
    return
  }

  resumo.observados += 1

  const situacao = (observacao as Record<string, unknown> | null)?.situacao
  if (situacao === "coleta_desligada" || situacao === "fonte_desligada") {
    resumo.detalhes.push({ item: item.id, situacao })
    return
  }

  const descontoBruto = Number((observacao as Record<string, unknown> | null)?.desconto)
  const descontoVerificado = Number.isFinite(descontoBruto) ? descontoBruto : null

  const [avaliacao, reputacao] = await Promise.all([
    lerAvaliacao(item.id, accessToken),
    item.vendedorId ? lerReputacao(item.vendedorId, accessToken) : Promise.resolve({ nivel: null, verde: false }),
  ])

  const sinais = { item, avaliacao, reputacao, descontoVerificado }
  const pontuacao = pontuar(sinais)

  await supabase.rpc("ml_item_observado", { p_id: observado.id })

  if (pontuacao.recusa !== null || pontuacao.total < pontuacaoMinima) {
    resumo.recusados += 1
    resumo.detalhes.push({
      item: item.id,
      situacao: pontuacao.recusa ?? "pontuacao_baixa",
      pontuacao: pontuacao.total,
      minima: pontuacaoMinima,
      cobertura: Number(pontuacao.cobertura.toFixed(2)),
      componentes: pontuacao.componentes,
      ausentes: pontuacao.ausentes,
    })
    return
  }

  const payload = montarPayload(sinais, observado.url_afiliado)
  const validacao = validarPayloadTelegram(payload)

  if (!validacao.ok) {
    // Barrar aqui evita ocupar a fila com algo que o publicador recusaria.
    resumo.recusados += 1
    resumo.detalhes.push({ item: item.id, situacao: "payload_invalido", erros: validacao.erros })
    return
  }

  if (ensaio) {
    resumo.detalhes.push({
      item: item.id,
      situacao: "ensaio_aprovaria",
      pontuacao: pontuacao.total,
      cobertura: Number(pontuacao.cobertura.toFixed(2)),
      componentes: pontuacao.componentes,
      ausentes: pontuacao.ausentes,
      desconto: descontoVerificado,
      previa: validacao.payload.text,
    })
    return
  }

  const { data: enfileiramento, error: erroEnfileirar } = await supabase.rpc("registrar_oferta", {
    p_fonte_slug: FONTE,
    p_id_externo: identidade,
    p_titulo: item.titulo,
    p_url_canonica: item.urlCanonica,
    p_preco_atual: item.precoAtual,
    p_chave_observacao: chave,
    p_url_afiliado: observado.url_afiliado,
    p_url_imagem: item.urlImagem,
    p_preco_original: item.precoOriginal,
    p_pontuacao: pontuacao.total,
    p_payload: validacao.payload,
    p_metadados: { categoria: observado.categoria, componentes: pontuacao.componentes },
  })

  if (erroEnfileirar) {
    resumo.falhas += 1
    resumo.detalhes.push({ item: item.id, etapa: "enfileirar", erro: erroEnfileirar.message })
    return
  }

  const desfecho = (enfileiramento as Record<string, unknown> | null)?.situacao

  if (desfecho === "enfileirada") {
    resumo.enfileirados += 1
  } else {
    resumo.recusados += 1
  }

  resumo.detalhes.push({
    item: item.id,
    situacao: desfecho,
    motivo: (enfileiramento as Record<string, unknown> | null)?.motivo ?? null,
    pontuacao: pontuacao.total,
  })
}

Deno.serve(async (requisicao: Request) => {
  if (requisicao.method !== "POST") {
    return responder(405, { erro: "Somente POST" })
  }

  let urlSupabase: string
  let chaveServico: string

  try {
    urlSupabase = exigirVariavel("SUPABASE_URL")
    chaveServico = exigirVariavel("SUPABASE_SERVICE_ROLE_KEY")
  } catch (erro) {
    console.error("configuracao incompleta:", erro instanceof Error ? erro.message : erro)
    return responder(500, { erro: "Funcao mal configurada" })
  }

  if (!FORMATO_URL_SUPABASE.test(urlSupabase)) {
    return responder(500, { erro: "SUPABASE_URL fora do formato oficial" })
  }

  const bruto = await requisicao.text()
  if (new TextEncoder().encode(bruto).length > LIMITE_CORPO_BYTES) {
    return responder(413, { erro: "Corpo grande demais" })
  }

  const supabase = createClient(urlSupabase, chaveServico, {
    auth: { persistSession: false, autoRefreshToken: false },
  })

  const recebido = requisicao.headers.get("x-cron-secret") ?? ""
  const { data: autorizado, error: erroSegredo } = await supabase.rpc("cron_secreto_confere", {
    p_segredo: recebido,
  })

  if (erroSegredo) {
    console.error("falha ao conferir o segredo:", erroSegredo.message)
    return responder(500, { erro: "Nao foi possivel conferir a autorizacao" })
  }

  if (autorizado !== true) {
    return responder(401, { erro: "Nao autorizado" })
  }

  const { data: configuracao, error: erroConfiguracao } = await supabase
    .from("configuracoes")
    .select("coleta_ativa, trava_emergencia, aprovacao_pontuacao_minima")
    .eq("id", 1)
    .single()

  if (erroConfiguracao || !configuracao) {
    return responder(500, { erro: "Nao foi possivel ler as configuracoes" })
  }

  // Ensaio observa, pontua e relata, mas nunca enfileira. Por isso pode rodar
  // com a trava de emergencia ligada: nao existe caminho daqui ate uma
  // publicacao. E o unico jeito de provar a coleta ponta a ponta sem soltar o
  // freio de mao.
  let ensaio = false
  if (bruto !== "") {
    try {
      const corpo = JSON.parse(bruto) as Record<string, unknown>
      ensaio = corpo.modo === "ensaio"
    } catch {
      return responder(400, { erro: "Corpo nao e JSON valido" })
    }
  }

  if (configuracao.trava_emergencia && !ensaio) {
    return responder(200, { situacao: "trava_de_emergencia" })
  }

  if (!configuracao.coleta_ativa) {
    return responder(200, { situacao: "coleta_desligada" })
  }

  // Credenciais e token valido.
  const { data: linhasCredenciais, error: erroCredenciais } = await supabase
    .rpc("ml_credenciais_para_uso")

  const credenciais = (Array.isArray(linhasCredenciais)
    ? linhasCredenciais[0]
    : linhasCredenciais) as Credenciais | undefined

  if (erroCredenciais || !credenciais?.client_id) {
    return responder(409, {
      erro: "Mercado Livre nao conectado",
      detalhe: erroCredenciais?.message ?? null,
    })
  }

  let accessToken: string
  try {
    accessToken = await garantirToken(supabase, credenciais)
  } catch (erro) {
    const codigo = erro instanceof ErroMercadoLivre ? erro.codigo : "renovacao_falhou"
    const mensagem = erro instanceof Error ? erro.message : String(erro)
    console.error("[coletor-ml] renovacao:", mensagem)
    await supabase.from("erros").insert({
      chave_idempotencia: `coletor:${codigo}:${Date.now()}`,
      gravidade: "critico",
      codigo,
      mensagem: mensagem.slice(0, 2000),
    })
    return responder(502, { erro: "Nao foi possivel obter token do Mercado Livre", codigo })
  }

  // Lote de itens vencidos. A funcao ja reagenda cada um.
  const { data: itens, error: erroItens } = await supabase.rpc("ml_itens_para_observar", {
    p_limite: 5,
  })

  if (erroItens) {
    return responder(500, { erro: "Nao foi possivel ler a watchlist", detalhe: erroItens.message })
  }

  const observados = (itens ?? []) as ItemObservado[]

  if (observados.length === 0) {
    return responder(200, { situacao: "nada_vencido" })
  }

  const resumo: Resumo = {
    vistos: observados.length,
    observados: 0,
    enfileirados: 0,
    recusados: 0,
    falhas: 0,
    detalhes: [],
  }

  const minima = Number(configuracao.aprovacao_pontuacao_minima) || 88

  // Sem leitura em lote: o /items?ids= esta fechado. Cada item exige duas
  // chamadas ao catalogo, entao o lote pequeno da watchlist ja e o teto.
  for (const observado of observados) {
    let lido: ItemMl

    try {
      lido = await lerAnuncioDoCatalogo(
        observado.produto_catalogo,
        observado.item_id,
        accessToken,
      )
    } catch (erro) {
      const mensagem = erro instanceof Error ? erro.message : String(erro)
      const retentavel = erro instanceof ErroMercadoLivre && erro.retentavel
      // Falha de rede nao e culpa do item: nao conta contra ele.
      if (!retentavel) {
        await supabase.rpc("ml_item_falhou", { p_id: observado.id, p_motivo: mensagem })
      }
      resumo.falhas += 1
      resumo.detalhes.push({ item: observado.item_id ?? observado.produto_catalogo, etapa: "ler", erro: mensagem })
      continue
    }

    if (!lido.disponivel) {
      await supabase.rpc("ml_item_falhou", { p_id: observado.id, p_motivo: "Produto inativo" })
      resumo.recusados += 1
      resumo.detalhes.push({ item: observado.item_id ?? observado.produto_catalogo, situacao: "indisponivel" })
      continue
    }

    try {
      await processarItem(supabase, observado, lido, accessToken, minima, ensaio, resumo)
    } catch (erro) {
      const mensagem = erro instanceof Error ? erro.message : String(erro)
      await supabase.rpc("ml_item_falhou", { p_id: observado.id, p_motivo: mensagem })
      resumo.falhas += 1
      resumo.detalhes.push({ item: observado.item_id ?? observado.produto_catalogo, etapa: "processar", erro: mensagem })
    }
  }

  console.log("[coletor-ml] rodada", JSON.stringify({
    vistos: resumo.vistos,
    enfileirados: resumo.enfileirados,
    recusados: resumo.recusados,
    falhas: resumo.falhas,
  }))

  return responder(200, resumo)
})
