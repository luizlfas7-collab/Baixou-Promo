import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2.112.3"

import {
  buscarProdutos,
  ErroShopee,
  gerarLinkCurto,
  temPrecoUnico,
  type Credenciais,
  type ProdutoShopee,
} from "./shopee.ts"

const FONTE = "shopee_open_api"
const PLATAFORMA = "shopee"
const FORMATO_URL_SUPABASE = /^https:\/\/[a-z0-9]{20}\.supabase\.co$/
const LIMITE_CORPO_BYTES = 2048

/**
 * Sub-ids carimbados no link. Batem com os destinos de `links_por_destino`,
 * para o numero do painel da Shopee poder ser cruzado com o que esta no banco.
 */
const SUBID_PADRAO = ["baixou", "telegram"]

type Configuracao = {
  palavras_chave?: unknown
  limite_por_palavra?: unknown
  nota_minima?: unknown
  vendas_minimas?: unknown
  comissao_minima?: unknown
  preco_minimo?: unknown
}

type Resumo = {
  palavras: number
  vistos: number
  descartados_por_faixa: number
  descartados_por_filtro: number
  observados: number
  novos_na_watchlist: number
  falhas: number
  detalhes: Array<Record<string, unknown>>
}

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

function listaDeTextos(valor: unknown, padrao: string[]): string[] {
  if (!Array.isArray(valor)) return padrao
  const limpos = valor.filter((v): v is string => typeof v === "string" && v.trim() !== "")
  return limpos.length > 0 ? limpos : padrao
}

function numeroOu(valor: unknown, padrao: number): number {
  return typeof valor === "number" && Number.isFinite(valor) ? valor : padrao
}

/**
 * Chave de observacao por hora.
 *
 * Igual a do coletor do ML: `registrar_oferta` e idempotente por esta chave, e
 * duas rodadas dentro da mesma hora nao podem virar duas amostras de preco. Na
 * Shopee isso importa mais ainda — a busca por palavra-chave devolve o mesmo
 * produto em palavras diferentes, e sem a chave o mesmo preco entraria duas
 * vezes na mesma rodada, inflando o historico contra o qual o desconto e
 * medido.
 */
function chaveObservacao(identidade: string, agora: Date): string {
  return `${FONTE}:${identidade}:${agora.toISOString().slice(0, 13)}`
}

/** Identidade estavel do produto na Shopee: loja + item. */
function identidadeDe(produto: ProdutoShopee): string {
  return `${produto.shopId}.${produto.itemId}`
}

/**
 * Filtros de porta de entrada, lidos de `fontes.configuracao`.
 *
 * Nao confundir com a pontuacao: aqui so se descarta o que nem vale observar,
 * para nao encher a watchlist de coisa que nunca viraria post. Quem decide se
 * vira post continua sendo o motor, contra o historico que ele mesmo formou.
 */
function passaNoFiltro(
  produto: ProdutoShopee,
  cfg: {
    notaMinima: number
    vendasMinimas: number
    comissaoMinima: number
    precoMinimo: number
  },
): boolean {
  if (produto.precoMin < cfg.precoMinimo) return false

  // Sinal ausente nao reprova: a Shopee nem sempre devolve nota e vendas, e
  // tratar ausencia como zero descartaria produto bom por falta de dado —
  // mesmo veneno que o denominador de pesos disponiveis evita na pontuacao.
  if (produto.nota !== null && produto.nota < cfg.notaMinima) return false
  if (produto.vendas !== null && produto.vendas < cfg.vendasMinimas) return false
  if (produto.comissaoPct !== null && produto.comissaoPct < cfg.comissaoMinima * 100) return false

  return true
}

async function registrar(
  supabase: SupabaseClient,
  credenciais: Credenciais,
  produto: ProdutoShopee,
  resumo: Resumo,
): Promise<void> {
  const identidade = identidadeDe(produto)
  const agora = new Date()

  // O link e gerado uma vez, quando o produto entra na watchlist, e guardado.
  // Gerar a cada rodada queimaria chamada de API sem necessidade e produziria
  // um shortlink diferente por rodada, o que estragaria a metrica por link.
  const { data: jaExiste } = await supabase
    .from("itens_ml")
    .select("id, url_afiliado")
    .eq("plataforma", PLATAFORMA)
    .eq("item_id", identidade)
    .maybeSingle()

  let urlAfiliado: string | null =
    (jaExiste as { url_afiliado?: string | null } | null)?.url_afiliado ?? null

  if (!urlAfiliado) {
    try {
      urlAfiliado = await gerarLinkCurto(credenciais, produto.urlProduto, SUBID_PADRAO)
    } catch (erro) {
      // Sem link o produto ainda vale a pena: ele observa, forma historico e
      // pontua igual. O link so faz falta na hora de publicar, e ha
      // `watchlist_prontos_para_link()` justamente para esse caso.
      resumo.detalhes.push({
        item: identidade,
        etapa: "link",
        erro: erro instanceof Error ? erro.message : String(erro),
      })
    }
  }

  const { data: cadastro, error: erroCadastro } = await supabase.rpc("watchlist_cadastrar", {
    p_plataforma: PLATAFORMA,
    p_item_id: identidade,
    p_url_afiliado: urlAfiliado,
    p_categoria: "Shopee",
    p_apelido: produto.titulo.slice(0, 120),
  })

  if (erroCadastro) {
    resumo.falhas += 1
    resumo.detalhes.push({ item: identidade, etapa: "watchlist", erro: erroCadastro.message })
    return
  }

  if (!jaExiste && (cadastro as { ok?: boolean } | null)?.ok) {
    resumo.novos_na_watchlist += 1
  }

  // O preco vai para o historico e o DESCONTO NAO VAI JUNTO.
  //
  // `priceDiscountRate` e o desconto que a loja declara, e este projeto nao
  // publica desconto declarado — publica queda que ele mesmo observou. Mandar
  // o numero da Shopee como `p_preco_original` faria o motor aprovar em cima
  // da palavra do vendedor, que e exatamente o que o Baixou se recusa a fazer.
  // Ele viaja como metadado, para dar para comparar depois o que a loja dizia
  // com o que de fato aconteceu.
  const { error: erroObservar } = await supabase.rpc("registrar_oferta", {
    p_fonte_slug: FONTE,
    p_id_externo: identidade,
    p_titulo: produto.titulo,
    p_url_canonica: produto.urlProduto,
    p_preco_atual: produto.precoMin,
    p_chave_observacao: chaveObservacao(identidade, agora),
    p_url_afiliado: urlAfiliado,
    p_url_imagem: produto.urlImagem,
    p_metadados: {
      loja: produto.shopId,
      item: produto.itemId,
      vendas: produto.vendas,
      nota: produto.nota,
      comissao_pct: produto.comissaoPct,
      desconto_declarado_pela_loja: produto.descontoDeclarado,
    },
  })

  if (erroObservar) {
    resumo.falhas += 1
    resumo.detalhes.push({ item: identidade, etapa: "observar", erro: erroObservar.message })
    return
  }

  resumo.observados += 1
}

Deno.serve(async (requisicao: Request): Promise<Response> => {
  if (requisicao.method !== "POST") {
    return responder(405, { erro: "Use POST" })
  }

  let urlSupabase: string
  let chaveServico: string

  try {
    urlSupabase = exigirVariavel("SUPABASE_URL")
    chaveServico = exigirVariavel("SUPABASE_SERVICE_ROLE_KEY")
  } catch (erro) {
    console.error(erro)
    return responder(500, { erro: "Ambiente incompleto" })
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

  const identificadorWorker = `coletor-shopee:${crypto.randomUUID().slice(0, 8)}`

  const resumo: Resumo = {
    palavras: 0,
    vistos: 0,
    descartados_por_faixa: 0,
    descartados_por_filtro: 0,
    observados: 0,
    novos_na_watchlist: 0,
    falhas: 0,
    detalhes: [],
  }

  let execucaoId: number | null = null
  let situacaoFinal = "falhou"
  let resumoErro: string | null = null

  const { data: idAberto, error: erroAbrir } = await supabase.rpc("execucao_abrir", {
    p_chave: `coleta:${identificadorWorker}:${new Date().toISOString()}`,
    p_tipo: "coleta",
    p_worker: identificadorWorker,
    p_fonte_slug: FONTE,
  })

  if (erroAbrir) {
    // Observabilidade nao e a missao: falhar aqui nao impede a coleta.
    console.error("[coletor-shopee] execucao_abrir:", erroAbrir.message)
  } else {
    execucaoId = typeof idAberto === "number" ? idAberto : null
  }

  try {
    const { data: configuracao, error: erroConfiguracao } = await supabase
      .from("configuracoes")
      .select("coleta_ativa")
      .eq("id", 1)
      .single()

    if (erroConfiguracao || !configuracao) {
      resumoErro = erroConfiguracao?.message ?? "configuracoes vazias"
      return responder(500, { erro: "Nao foi possivel ler as configuracoes" })
    }

    if (configuracao.coleta_ativa !== true) {
      situacaoFinal = "concluida"
      return responder(200, { situacao: "coleta_desativada" })
    }

    const { data: fonte, error: erroFonte } = await supabase
      .from("fontes")
      .select("habilitada, configuracao")
      .eq("slug", FONTE)
      .single()

    if (erroFonte || !fonte) {
      resumoErro = erroFonte?.message ?? "fonte ausente"
      return responder(500, { erro: "Fonte da Shopee nao encontrada" })
    }

    if (fonte.habilitada !== true) {
      // Fonte semeada e desabilitada e o estado normal ate alguem decidir
      // ligar. Nao e erro, e nao deve encher `erros` de ruido.
      situacaoFinal = "concluida"
      return responder(200, { situacao: "fonte_desabilitada" })
    }

    const { data: cred, error: erroCred } = await supabase.rpc("shopee_credenciais")

    if (erroCred) {
      resumoErro = erroCred.message
      return responder(500, { erro: "Nao foi possivel ler as credenciais" })
    }

    const credObj = cred as Record<string, unknown> | null

    if (!credObj || credObj.ok !== true) {
      situacaoFinal = "concluida"
      return responder(200, {
        situacao: "sem_credenciais",
        detalhe: credObj?.detalhe ?? null,
      })
    }

    const credenciais: Credenciais = {
      appId: String(credObj.app_id),
      appSecret: String(credObj.app_secret),
      urlBase: String(credObj.url_base),
    }

    const cfg = (fonte.configuracao ?? {}) as Configuracao
    const palavras = listaDeTextos(cfg.palavras_chave, ["fone de ouvido", "smartwatch"])
    const limitePorPalavra = Math.min(Math.max(numeroOu(cfg.limite_por_palavra, 10), 1), 50)
    const filtros = {
      notaMinima: numeroOu(cfg.nota_minima, 4.7),
      vendasMinimas: numeroOu(cfg.vendas_minimas, 100),
      comissaoMinima: numeroOu(cfg.comissao_minima, 0.05),
      precoMinimo: numeroOu(cfg.preco_minimo, 30),
    }

    // Um produto costuma aparecer em mais de uma palavra-chave. Sem isto ele
    // seria processado duas vezes na mesma rodada.
    const jaVistos = new Set<string>()

    for (const palavra of palavras) {
      let produtos: ProdutoShopee[]

      try {
        produtos = await buscarProdutos(credenciais, palavra, limitePorPalavra)
      } catch (erro) {
        resumo.falhas += 1
        resumo.detalhes.push({
          palavra,
          etapa: "buscar",
          erro: erro instanceof Error ? erro.message : String(erro),
          codigo: erro instanceof ErroShopee ? erro.codigo : null,
        })
        continue
      }

      resumo.palavras += 1

      for (const produto of produtos) {
        const identidade = identidadeDe(produto)
        if (jaVistos.has(identidade)) continue
        jaVistos.add(identidade)

        resumo.vistos += 1

        if (!temPrecoUnico(produto)) {
          resumo.descartados_por_faixa += 1
          continue
        }

        if (!passaNoFiltro(produto, filtros)) {
          resumo.descartados_por_filtro += 1
          continue
        }

        await registrar(supabase, credenciais, produto, resumo)
      }
    }

    await supabase.rpc("fonte_coletada", { p_slug: FONTE })

    situacaoFinal = "concluida"
    return responder(200, { situacao: "ok", ...resumo })
  } catch (erro) {
    resumoErro = erro instanceof Error ? erro.message : String(erro)
    console.error("[coletor-shopee]", resumoErro)

    await supabase.from("erros").insert({
      chave_idempotencia: `coletor-shopee:rodada:${Date.now()}`,
      gravidade: "critico",
      codigo: "coleta_shopee_falhou",
      mensagem: resumoErro.slice(0, 2000),
    })

    return responder(500, { erro: "Falha na coleta" })
  } finally {
    if (execucaoId !== null) {
      const { error: erroFechar } = await supabase.rpc("execucao_fechar", {
        p_id: execucaoId,
        p_situacao: situacaoFinal,
        p_vistos: resumo.vistos,
        p_inseridos: resumo.observados,
        // Faixa de preco e filtro sao recusas por motivos diferentes, mas a
        // coluna e uma so; o detalhe separado fica nos metadados.
        p_recusados: resumo.descartados_por_faixa + resumo.descartados_por_filtro,
        p_resumo_erro: resumoErro,
        p_metadados: {
          palavras: resumo.palavras,
          descartados_por_faixa: resumo.descartados_por_faixa,
          descartados_por_filtro: resumo.descartados_por_filtro,
          novos_na_watchlist: resumo.novos_na_watchlist,
          falhas: resumo.falhas,
        },
      })

      if (erroFechar) {
        console.error("[coletor-shopee] execucao_fechar:", erroFechar.message)
      }
    }
  }
})
