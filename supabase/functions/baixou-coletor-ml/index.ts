import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2.112.3"

import { validarPayloadTelegram } from "../_compartilhado/payload.ts"
import {
  ErroMercadoLivre,
  lerAvaliacao,
  lerAnuncioDoCatalogo,
  lerReputacao,
  renovarTokens,
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
  /** null quando a linha entrou so para observar preco, sem link de afiliado. */
  url_afiliado: string | null
  categoria: string
  produto_catalogo: string
}

type Resumo = {
  vistos: number
  observados: number
  enfileirados: number
  /** Pontuou acima do corte mas nao tem link de afiliado. Nao e recusa. */
  aguardando: number
  recusados: number
  falhas: number
  detalhes: Array<Record<string, unknown>>
}

/** Chave estavel por item e por janela de coleta: repetir a rodada nao duplica. */
function chaveObservacao(itemId: string, agora: Date): string {
  const janela = Math.floor(agora.getTime() / 60_000)
  return `ml:${itemId}:${janela}`
}

type Aquisicao = {
  situacao: string
  motivo: string | null
  client_id: string | null
  client_secret: string | null
  access_token: string | null
  refresh_token: string | null
  precisa_renovar: boolean
  lock_token: string | null
  geracao: number | null
}

/**
 * Rodada que nao pode seguir, mas tambem nao e falha: outra ja esta renovando,
 * ou a conexao esta em recuo, ou precisa de reautorizacao humana. Encerrar
 * quieto e o comportamento certo — insistir so queima cota.
 */
class RodadaSemToken extends Error {
  constructor(readonly situacao: string, readonly motivo: string) {
    super(motivo)
    this.name = "RodadaSemToken"
  }
}

/**
 * Unica porta para o token.
 *
 * O refresh do Mercado Livre e rotativo: cada renovacao invalida a anterior.
 * Duas rodadas renovando ao mesmo tempo rotacionam duas vezes, e a ultima a
 * gravar guarda um refresh ja morto — a conexao cai em silencio. Por isso a
 * renovacao acontece sob lease: quem pega renova, quem nao pega volta depois.
 */
async function obterToken(
  supabase: SupabaseClient,
  worker: string,
): Promise<string> {
  const { data, error } = await supabase.rpc("ml_token_adquirir", {
    p_worker: worker,
    p_ttl_segundos: 120,
  })

  if (error) {
    throw new ErroMercadoLivre(`ml_token_adquirir: ${error.message}`, "aquisicao_falhou", true)
  }

  const aq = (Array.isArray(data) ? data[0] : data) as Aquisicao | undefined

  if (!aq) {
    throw new ErroMercadoLivre("Banco nao devolveu credenciais", "aquisicao_vazia")
  }

  if (!aq.precisa_renovar) {
    if (!aq.access_token) {
      throw new RodadaSemToken(aq.situacao, aq.motivo ?? "sem_token")
    }
    return aq.access_token
  }

  // Precisa renovar mas nao ganhou o lease: outra rodada esta cuidando disso,
  // ou a conexao esta em espera de retentativa.
  if (!aq.lock_token) {
    throw new RodadaSemToken(aq.situacao, aq.motivo ?? "sem_lease")
  }

  try {
    const renovados = await renovarTokens({
      client_id: aq.client_id ?? "",
      client_secret: aq.client_secret ?? "",
      access_token: aq.access_token,
      refresh_token: aq.refresh_token,
      precisa_renovar: true,
    })

    const { error: erroGravar } = await supabase.rpc("ml_token_renovado", {
      p_lock_token: aq.lock_token,
      p_access_token: renovados.accessToken,
      p_refresh_token: renovados.refreshToken,
      p_expires_in: renovados.expiresIn,
      p_escopos: renovados.escopos,
    })

    if (erroGravar) {
      // Renovou no ML mas nao guardou: o refresh antigo ja nao vale mais, e o
      // novo se perdeu. So reautorizacao resolve.
      await supabase.rpc("ml_token_falhou", {
        p_lock_token: aq.lock_token,
        p_codigo: "renovacao_nao_gravada",
        p_permanente: true,
      })
      throw new ErroMercadoLivre(
        `Tokens renovados mas nao gravados: ${erroGravar.message}`,
        "renovacao_nao_gravada",
      )
    }

    console.log("[coletor-ml] token renovado", JSON.stringify({ geracao: (aq.geracao ?? 0) + 1 }))
    return renovados.accessToken
  } catch (erro) {
    if (erro instanceof ErroMercadoLivre && erro.codigo === "renovacao_nao_gravada") throw erro

    const codigo = erro instanceof ErroMercadoLivre ? erro.codigo : "renovacao_falhou"
    // Refresh revogado nao melhora com insistencia: marca para reautorizacao
    // em vez de bater no ML a cada cinco minutos para sempre.
    const permanente = erro instanceof ErroMercadoLivre ? !erro.retentavel : false

    await supabase.rpc("ml_token_falhou", {
      p_lock_token: aq.lock_token,
      p_codigo: codigo,
      p_permanente: permanente,
    })

    throw erro
  }
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
    // O vendedor entra na observacao para que ml_vantagem_de_preco consiga
    // separar queda de preco de troca de anunciante. Sem isso, a diferenca
    // entre dois vendedores do mesmo catalogo passaria por desconto.
    p_metadados: {
      categoria: observado.categoria,
      catalogo: observado.produto_catalogo,
      vendedor: item.vendedorId === null ? null : String(item.vendedorId),
    },
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

  // Segunda porta: patamar de preco contra a referencia diaria. Quem calcula e
  // o banco, que tem o historico inteiro — o coletor so enxerga a rodada atual
  // e nao teria como julgar patamar.
  const ofertaId = Number((observacao as Record<string, unknown> | null)?.oferta_id)
  let competitividade: number | null = null
  let referencia: number | null = null

  if (Number.isFinite(ofertaId)) {
    const { data: vantagem, error: erroVantagem } = await supabase.rpc("ml_vantagem_de_preco", {
      p_oferta_id: ofertaId,
    })
    if (erroVantagem) {
      // Nao derruba a rodada: sem competitividade sobra a porta do desconto.
      console.error("[coletor-ml] ml_vantagem_de_preco:", erroVantagem.message)
    } else {
      const dados = vantagem as Record<string, unknown> | null
      const bruto = Number(dados?.competitividade)
      competitividade = Number.isFinite(bruto) ? bruto : null
      const ref = Number(dados?.referencia)
      referencia = Number.isFinite(ref) && ref > 0 ? ref : null
    }
  }

  // Quanto este preco esta abaixo do normal, em porcentagem.
  //
  // Pela porta do desconto e o proprio desconto observado. Pela porta do
  // patamar nao existe desconto entre duas leituras, entao a distancia ate a
  // referencia diaria e o numero honesto — e e ele que o operador olha para
  // decidir se vale gerar link.
  const vantagemPct = descontoVerificado ??
    (referencia !== null
      ? Math.round(((referencia - item.precoAtual) / referencia) * 10_000) / 100
      : 0)

  const [avaliacao, reputacao] = await Promise.all([
    lerAvaliacao(item.id, accessToken),
    item.vendedorId ? lerReputacao(item.vendedorId, accessToken) : Promise.resolve({ nivel: null, verde: false }),
  ])

  const sinais = { item, avaliacao, reputacao, descontoVerificado, competitividade }
  const pontuacao = pontuar(sinais)

  await supabase.rpc("ml_item_observado", { p_id: observado.id })

  if (pontuacao.recusa !== null || pontuacao.total < pontuacaoMinima) {
    // Perdeu a vantagem: o carimbo de "pronto para link" tem de sair junto.
    // Sem isso ml_prontos_para_link() vira lista de fantasmas, e gerar link
    // para um deles publicaria oferta que ja acabou.
    if (!observado.url_afiliado) {
      await supabase.rpc("ml_item_sem_vantagem", { p_id: observado.id })
    }
    resumo.recusados += 1
    resumo.detalhes.push({
      item: item.id,
      situacao: pontuacao.recusa ?? "pontuacao_baixa",
      pontuacao: pontuacao.total,
      minima: pontuacaoMinima,
      cobertura: Number(pontuacao.cobertura.toFixed(2)),
      componentes: pontuacao.componentes,
      ausentes: pontuacao.ausentes,
      competitividade,
    })
    return
  }

  // Linha sem link de afiliado: observa, pontua e para aqui.
  //
  // Barrar neste ponto e a primeira de duas defesas. A segunda e a validacao
  // de payload, que recusaria a URL por estar fora da allowlist de afiliados.
  // Uma sozinha bastaria; duas porque publicar link errado no canal e pior do
  // que nao publicar.
  //
  // Nao conta como recusa: a oferta e boa, so falta a decisao comercial de
  // associar o produto ao perfil de afiliado. Some em `aguardando`, e
  // ml_prontos_para_link() lista o que ja provou que vale o link.
  if (!observado.url_afiliado) {
    await supabase.rpc("ml_item_pronto_para_link", {
      p_id: observado.id,
      p_pontuacao: pontuacao.total,
      p_desconto: vantagemPct,
    })
    resumo.aguardando += 1
    resumo.detalhes.push({
      item: item.id,
      situacao: "aguardando_link",
      catalogo: observado.produto_catalogo,
      pontuacao: pontuacao.total,
      desconto: descontoVerificado,
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

  const identificadorWorker = `coletor:${crypto.randomUUID().slice(0, 8)}`

  // Registro da rodada.
  //
  // A tabela execucoes existia desde o primeiro dia e nunca recebeu uma linha:
  // o coletor trabalhava sem deixar rastro. Um dia em que ele parasse ficaria
  // identico a um dia sem queda de preco — foi exatamente assim que o Radar
  // Rota passou 34 dias mudo sem ninguem notar.
  //
  // Abre aqui e fecha no finally. Sao sete saidas diferentes daqui para baixo;
  // fechar em cada uma seria questao de tempo ate esquecer uma, e rodada nao
  // registrada equivale a rodada que nao aconteceu para quem esta olhando.
  const resumo: Resumo = {
    vistos: 0,
    observados: 0,
    enfileirados: 0,
    aguardando: 0,
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

  if (erroAbrir) {
    // Registro e observabilidade, nao a missao: falhar aqui nao pode impedir a
    // coleta de acontecer.
    console.error("[coletor-ml] execucao_abrir:", erroAbrir.message)
  } else {
    execucaoId = typeof idAberto === "number" ? idAberto : null
  }

  try {
    const { data: configuracao, error: erroConfiguracao } = await supabase
      .from("configuracoes")
      .select("coleta_ativa, trava_emergencia, aprovacao_pontuacao_minima")
      .eq("id", 1)
      .single()

    if (erroConfiguracao || !configuracao) {
      resumoErro = erroConfiguracao?.message ?? "configuracoes vazias"
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
        situacaoFinal = "ignorada"
        metadadosFinais.motivo = "corpo_invalido"
        return responder(400, { erro: "Corpo nao e JSON valido" })
      }
    }

    // A trava de emergencia e freio de PUBLICACAO, nao de observacao.
    //
    // Sair aqui era o mesmo defeito que deixou o Radar Rota 34 dias mudo: o
    // cron reportava sucesso e nada acontecia. Pior ainda, impedia justamente o
    // que precisa acontecer sob trava — formar o historico de preco, sem o qual
    // nenhuma oferta e aprovada quando o freio for solto.
    //
    // Com a trava ligada o coletor observa, pontua e relata; nao enfileira. Nao
    // enfileirar e deliberado: fila crescendo com o freio puxado viraria
    // enxurrada no canal no instante em que ele fosse solto.
    const travada = configuracao.trava_emergencia === true
    if (travada) ensaio = true

    metadadosFinais.ensaio = ensaio
    metadadosFinais.travada = travada

    if (!configuracao.coleta_ativa) {
      situacaoFinal = "ignorada"
      metadadosFinais.motivo = "coleta_desligada"
      return responder(200, { situacao: "coleta_desligada" })
    }

    let accessToken: string
    try {
      accessToken = await obterToken(supabase, identificadorWorker)
    } catch (erro) {
      if (erro instanceof RodadaSemToken) {
        // Nao e falha: e a conexao pedindo espaco — outra rodada renovando, ou
        // recuo apos erro, ou reautorizacao pendente. Responder 200 evita
        // encher o log de alarme por algo que se resolve sozinho, ou que so
        // uma pessoa resolve.
        console.log("[coletor-ml] rodada encerrada", JSON.stringify({
          situacao: erro.situacao,
          motivo: erro.motivo,
        }))
        situacaoFinal = "ignorada"
        metadadosFinais.motivo = erro.situacao
        metadadosFinais.detalhe = erro.motivo
        return responder(200, { situacao: erro.situacao, motivo: erro.motivo })
      }

      const codigo = erro instanceof ErroMercadoLivre ? erro.codigo : "renovacao_falhou"
      const mensagem = erro instanceof Error ? erro.message : String(erro)
      console.error("[coletor-ml] token:", mensagem)
      await supabase.from("erros").insert({
        chave_idempotencia: `coletor:${codigo}:${Date.now()}`,
        gravidade: "critico",
        codigo,
        mensagem: mensagem.slice(0, 2000),
      })
      resumoErro = `${codigo}: ${mensagem}`
      return responder(502, { erro: "Nao foi possivel obter token do Mercado Livre", codigo })
    }

    // Lote de itens vencidos. A funcao ja reagenda cada um.
    //
    // 10 por rodada, a cada 2 min, da 300 leituras por hora. E o que define o
    // tempo de revisita: watchlist / leituras por hora. Com 345 itens, cada um
    // e olhado uma vez a cada ~1h10.
    //
    // Este numero e o denominador: crescer a watchlist sem crescer a vazao
    // estica a revisita, e queda relampago passa batido — o item volta a ser
    // lido depois que o preco ja subiu. Quem vigia isso e `revisita_horas` em
    // saude_da_coleta(); nao mexa em um lado sem olhar o outro.
    const { data: itens, error: erroItens } = await supabase.rpc("ml_itens_para_observar", {
      p_limite: 10,
    })

    if (erroItens) {
      resumoErro = `watchlist: ${erroItens.message}`
      return responder(500, { erro: "Nao foi possivel ler a watchlist", detalhe: erroItens.message })
    }

    const observados = (itens ?? []) as ItemObservado[]

    if (observados.length === 0) {
      situacaoFinal = "ignorada"
      metadadosFinais.motivo = "nada_vencido"
      return responder(200, { situacao: "nada_vencido" })
    }

    resumo.vistos = observados.length

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

    // Rodada que viu itens e nao conseguiu ler nenhum e falha, mesmo sem
    // excecao — e o formato de silencio que este registro existe para expor.
    if (resumo.falhas === 0) {
      situacaoFinal = "concluida"
    } else if (resumo.observados === 0) {
      situacaoFinal = "falhou"
      resumoErro = `Nenhum item lido em ${resumo.vistos} tentativas.`
    } else {
      situacaoFinal = "parcial"
      resumoErro = `${resumo.falhas} de ${resumo.vistos} itens falharam.`
    }

    metadadosFinais.aguardando_link = resumo.aguardando

    console.log("[coletor-ml] rodada", JSON.stringify({
      ensaio,
      travada,
      vistos: resumo.vistos,
      enfileirados: resumo.enfileirados,
      aguardando: resumo.aguardando,
      recusados: resumo.recusados,
      falhas: resumo.falhas,
    }))

    return responder(200, { ...resumo, ensaio, travada })
  } catch (erro) {
    // Excecao nao prevista ainda precisa fechar o registro com a verdade.
    resumoErro = erro instanceof Error ? erro.message : String(erro)
    console.error("[coletor-ml] rodada abortada:", resumoErro)
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
      if (erroFechar) console.error("[coletor-ml] execucao_fechar:", erroFechar.message)
    }
  }
})
