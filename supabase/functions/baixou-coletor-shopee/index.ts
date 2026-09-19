import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2.112.3"

import { validarPayloadTelegram } from "../_compartilhado/payload.ts"
import { buscarPorPalavra, ErroShopee, type ProdutoShopee } from "./shopee.ts"
import { montarPayload, pontuar } from "./oferta.ts"

const FONTE = "shopee_open_api"
const FORMATO_URL_SUPABASE = /^https:\/\/[a-z0-9]{20}\.supabase\.co$/
const LIMITE_CORPO_BYTES = 2048

/** Teto por rodada. A busca devolve muito; a fila e que e estreita. */
const MAX_PALAVRAS_POR_RODADA = 6

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

type Resumo = {
  vistos: number
  observados: number
  enfileirados: number
  recusados: number
  falhas: number
  detalhes: Array<Record<string, unknown>>
}

type Filtros = {
  notaMinima: number
  vendasMinimas: number
  precoMinimo: number
  ganhoMinimo: number
  limitePorPalavra: number
  palavras: string[]
}

/**
 * Chave estavel por item e por minuto: rodada repetida nao duplica observacao.
 * Prefixo por fonte porque id da Shopee e do ML podem colidir por acaso.
 */
function chaveObservacao(itemId: string, agora: Date): string {
  return `shopee:${itemId}:${Math.floor(agora.getTime() / 60_000)}`
}

function lerFiltros(configuracao: Record<string, unknown> | null): Filtros {
  const cfg = configuracao ?? {}
  const palavras = Array.isArray(cfg.palavras_chave)
    ? (cfg.palavras_chave as unknown[]).filter((p): p is string => typeof p === "string")
    : []

  return {
    notaMinima: Number(cfg.nota_minima ?? 0),
    vendasMinimas: Number(cfg.vendas_minimas ?? 0),
    precoMinimo: Number(cfg.preco_minimo ?? 0),
    // ganho_minimo substituiu comissao_minima em 20260916234500: o que ordena
    // e preco x comissao, nunca a taxa isolada.
    ganhoMinimo: Number(cfg.ganho_minimo ?? 0),
    limitePorPalavra: Math.max(1, Math.min(Number(cfg.limite_por_palavra ?? 10), 50)),
    palavras: palavras.slice(0, MAX_PALAVRAS_POR_RODADA),
  }
}

/**
 * Porteira barata, antes de qualquer ida ao banco.
 *
 * Devolve o motivo em vez de um booleano: quando a rodada inteira for recusada,
 * o dono precisa saber se foi preco, nota ou ganho — "0 aprovados" nao diz nada
 * sobre qual numero apertar.
 */
function recusaPorFiltro(p: ProdutoShopee, f: Filtros): string | null {
  if (p.precoAtual < f.precoMinimo) return "preco_abaixo_do_minimo"
  if (f.notaMinima > 0 && (p.nota === null || p.nota < f.notaMinima)) return "nota_abaixo_do_minimo"
  if (f.vendasMinimas > 0 && (p.vendas === null || p.vendas < f.vendasMinimas)) {
    return "vendas_abaixo_do_minimo"
  }
  if (f.ganhoMinimo > 0) {
    if (p.comissao === null) return "sem_comissao_informada"
    if (p.precoAtual * p.comissao < f.ganhoMinimo) return "ganho_abaixo_do_minimo"
  }
  return null
}

async function processarProduto(
  supabase: SupabaseClient,
  produto: ProdutoShopee,
  palavra: string,
  pontuacaoMinima: number,
  ensaio: boolean,
  resumo: Resumo,
): Promise<void> {
  const agora = new Date()
  const chave = chaveObservacao(produto.itemId, agora)

  // Primeira passada sem payload: o banco grava a observacao e devolve o
  // desconto que ELE apurou. priceDiscountRate da Shopee nao entra nisso —
  // preco "de" de loja e marketing, nao observacao.
  const { data: observacao, error: erroObservar } = await supabase.rpc("registrar_oferta", {
    p_fonte_slug: FONTE,
    p_id_externo: produto.itemId,
    p_titulo: produto.titulo,
    p_url_canonica: produto.urlCanonica,
    p_preco_atual: produto.precoAtual,
    p_chave_observacao: chave,
    p_url_afiliado: produto.urlAfiliado,
    p_url_imagem: produto.urlImagem,
    p_metadados: {
      palavra,
      loja: produto.loja,
      loja_oficial: produto.lojaOficial,
      comissao: produto.comissao,
      vendas: produto.vendas,
      nota: produto.nota,
      desconto_alegado: produto.descontoAlegado,
      preco_maximo: produto.precoMaximo,
    },
  })

  if (erroObservar) {
    resumo.falhas += 1
    resumo.detalhes.push({ item: produto.itemId, etapa: "observar", erro: erroObservar.message })
    return
  }

  resumo.observados += 1

  const situacao = (observacao as Record<string, unknown> | null)?.situacao
  if (situacao === "coleta_desligada" || situacao === "fonte_desligada") {
    resumo.detalhes.push({ item: produto.itemId, situacao })
    return
  }

  const descontoBruto = Number((observacao as Record<string, unknown> | null)?.desconto)
  const descontoVerificado = Number.isFinite(descontoBruto) ? descontoBruto : null

  const ofertaId = Number((observacao as Record<string, unknown> | null)?.oferta_id)
  let competitividade: number | null = null

  if (Number.isFinite(ofertaId)) {
    const { data: vantagem, error: erroVantagem } = await supabase.rpc("vantagem_de_preco", {
      p_oferta_id: ofertaId,
    })
    if (!erroVantagem) {
      const bruto = Number((vantagem as Record<string, unknown> | null)?.competitividade)
      competitividade = Number.isFinite(bruto) ? bruto : null
    }
  }

  const sinais = { produto, descontoVerificado, competitividade }
  const pontuacao = pontuar(sinais)

  if (pontuacao.recusa !== null || pontuacao.total < pontuacaoMinima) {
    resumo.recusados += 1
    resumo.detalhes.push({
      item: produto.itemId,
      situacao: "nao_aprovada",
      motivo: pontuacao.recusa ?? "pontuacao_abaixo_do_minimo",
      pontuacao: pontuacao.total,
    })
    return
  }

  const payload = montarPayload(sinais)
  const validacao = validarPayloadTelegram(payload)

  if (!validacao.ok) {
    resumo.recusados += 1
    resumo.detalhes.push({ item: produto.itemId, situacao: "payload_invalido", erros: validacao.erros })
    return
  }

  if (ensaio) {
    resumo.detalhes.push({
      item: produto.itemId,
      situacao: "ensaio_aprovaria",
      pontuacao: pontuacao.total,
      cobertura: Number(pontuacao.cobertura.toFixed(2)),
      componentes: pontuacao.componentes,
      desconto: descontoVerificado,
      previa: validacao.payload.text,
    })
    return
  }

  const { data: enfileiramento, error: erroEnfileirar } = await supabase.rpc("registrar_oferta", {
    p_fonte_slug: FONTE,
    p_id_externo: produto.itemId,
    p_titulo: produto.titulo,
    p_url_canonica: produto.urlCanonica,
    p_preco_atual: produto.precoAtual,
    p_chave_observacao: chave,
    p_url_afiliado: produto.urlAfiliado,
    p_url_imagem: produto.urlImagem,
    p_pontuacao: pontuacao.total,
    p_payload: validacao.payload,
    p_metadados: { palavra, componentes: pontuacao.componentes, comissao: produto.comissao },
  })

  if (erroEnfileirar) {
    resumo.falhas += 1
    resumo.detalhes.push({ item: produto.itemId, etapa: "enfileirar", erro: erroEnfileirar.message })
    return
  }

  const desfecho = (enfileiramento as Record<string, unknown> | null)?.situacao
  if (desfecho === "enfileirada") resumo.enfileirados += 1
  else resumo.recusados += 1

  resumo.detalhes.push({
    item: produto.itemId,
    situacao: desfecho,
    motivo: (enfileiramento as Record<string, unknown> | null)?.motivo ?? null,
    pontuacao: pontuacao.total,
  })
}

Deno.serve(async (requisicao: Request) => {
  if (requisicao.method !== "POST") return responder(405, { erro: "Somente POST" })

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

  let ensaio = false
  if (bruto.trim() !== "") {
    try {
      ensaio = (JSON.parse(bruto) as Record<string, unknown>).ensaio === true
    } catch {
      return responder(400, { erro: "Corpo nao e JSON" })
    }
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
  if (autorizado !== true) return responder(401, { erro: "Nao autorizado" })

  const identificadorWorker = `coletor-shopee:${crypto.randomUUID().slice(0, 8)}`

  const resumo: Resumo = {
    vistos: 0,
    observados: 0,
    enfileirados: 0,
    recusados: 0,
    falhas: 0,
    detalhes: [],
  }

  let execucaoId: number | null = null
  let situacaoFinal = "falhou"
  let resumoErro: string | null = null
  const metadadosFinais: Record<string, unknown> = {}

  const { data: idAberto, error: erroAbrir } = await supabase.rpc("execucao_abrir", {
    p_chave: `coleta:${identificadorWorker}:${new Date().toISOString()}`,
    p_tipo: "coleta",
    p_worker: identificadorWorker,
    p_fonte_slug: FONTE,
  })

  if (erroAbrir) console.error("[coletor-shopee] execucao_abrir:", erroAbrir.message)
  else execucaoId = typeof idAberto === "number" ? idAberto : null

  try {
    const { data: fonte, error: erroFonte } = await supabase
      .from("fontes")
      .select("habilitada, configuracao")
      .eq("slug", FONTE)
      .maybeSingle()

    if (erroFonte) throw new Error(`Nao foi possivel ler a fonte: ${erroFonte.message}`)
    if (!fonte) throw new Error(`Fonte ${FONTE} nao existe`)

    if (fonte.habilitada !== true) {
      situacaoFinal = "concluida"
      metadadosFinais.motivo = "fonte_desligada"
      return responder(200, { ...resumo, situacao: "fonte_desligada" })
    }

    const { data: credencial, error: erroCredencial } = await supabase
      .rpc("shopee_credenciais_ler")

    if (erroCredencial) throw new Error(`Credencial: ${erroCredencial.message}`)

    const cred = credencial as Record<string, unknown> | null
    if (cred?.situacao !== "pronta") {
      // Nao e excecao: e estado conhecido, e o registro precisa dizer QUAL.
      situacaoFinal = "falhou"
      resumoErro = String(cred?.motivo ?? "Credencial indisponivel")
      metadadosFinais.motivo = cred?.situacao ?? "sem_credencial"
      return responder(200, { ...resumo, situacao: cred?.situacao ?? "sem_credencial" })
    }

    const appId = String(cred.app_id)
    const secret = String(cred.secret)

    const { data: configuracao } = await supabase
      .from("configuracoes")
      .select("coleta_ativa, aprovacao_pontuacao_minima")
      .eq("id", 1)
      .maybeSingle()

    if (configuracao?.coleta_ativa === false) {
      situacaoFinal = "concluida"
      metadadosFinais.motivo = "coleta_desligada"
      return responder(200, { ...resumo, situacao: "coleta_desligada" })
    }

    const pontuacaoMinima = Number(configuracao?.aprovacao_pontuacao_minima ?? 70)
    const filtros = lerFiltros(fonte.configuracao as Record<string, unknown> | null)

    if (filtros.palavras.length === 0) {
      throw new Error("A fonte nao tem palavras_chave configuradas")
    }

    const recusasPorFiltro: Record<string, number> = {}

    for (const palavra of filtros.palavras) {
      let produtos: ProdutoShopee[]

      try {
        produtos = await buscarPorPalavra(appId, secret, palavra, filtros.limitePorPalavra)
      } catch (erro) {
        const codigo = erro instanceof ErroShopee ? erro.codigo : "desconhecido"
        const mensagem = erro instanceof Error ? erro.message : String(erro)
        resumo.falhas += 1
        resumo.detalhes.push({ palavra, etapa: "buscar", codigo, erro: mensagem })
        continue
      }

      for (const produto of produtos) {
        resumo.vistos += 1

        const recusa = recusaPorFiltro(produto, filtros)
        if (recusa !== null) {
          resumo.recusados += 1
          recusasPorFiltro[recusa] = (recusasPorFiltro[recusa] ?? 0) + 1
          continue
        }

        try {
          await processarProduto(supabase, produto, palavra, pontuacaoMinima, ensaio, resumo)
        } catch (erro) {
          const mensagem = erro instanceof Error ? erro.message : String(erro)
          resumo.falhas += 1
          resumo.detalhes.push({ item: produto.itemId, etapa: "processar", erro: mensagem })
        }
      }
    }

    metadadosFinais.recusas_por_filtro = recusasPorFiltro
    metadadosFinais.palavras = filtros.palavras.length

    // Buscar e nao ler nada e o formato de silencio que este registro expoe:
    // a rodada aconteceu, a API respondeu, e mesmo assim nada entrou.
    if (resumo.falhas === 0) {
      situacaoFinal = "concluida"
    } else if (resumo.observados === 0) {
      situacaoFinal = "falhou"
      resumoErro = `Nenhum produto observado em ${resumo.vistos} vistos.`
    } else {
      situacaoFinal = "parcial"
      resumoErro = `${resumo.falhas} falhas em ${filtros.palavras.length} palavras.`
    }

    console.log("[coletor-shopee] rodada", JSON.stringify({
      ensaio,
      vistos: resumo.vistos,
      observados: resumo.observados,
      enfileirados: resumo.enfileirados,
      recusados: resumo.recusados,
      falhas: resumo.falhas,
      recusas: recusasPorFiltro,
    }))

    return responder(200, { ...resumo, ensaio, recusas_por_filtro: recusasPorFiltro })
  } catch (erro) {
    resumoErro = erro instanceof Error ? erro.message : String(erro)
    console.error("[coletor-shopee] rodada abortada:", resumoErro)
    return responder(500, { erro: "Rodada abortada" })
  } finally {
    if (execucaoId !== null) {
      const { error: erroFechar } = await supabase.rpc("execucao_fechar", {
        p_id: execucaoId,
        p_situacao: situacaoFinal,
        p_vistos: resumo.vistos,
        p_inseridos: resumo.observados,
        p_recusados: resumo.recusados,
        p_enfileirados: resumo.enfileirados,
        p_resumo_erro: resumoErro,
        p_metadados: metadadosFinais,
      })
      if (erroFechar) console.error("[coletor-shopee] execucao_fechar:", erroFechar.message)
    }
  }
})
