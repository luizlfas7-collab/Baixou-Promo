import { validarPayloadTelegram, type PayloadTelegram } from "../_compartilhado/payload.ts"
import { montarRepasseWhatsapp } from "../_compartilhado/whatsapp.ts"
import type { ClienteTelegram } from "./telegram.ts"

export type ItemReservado = {
  fila_id: number
  canal: string
  destino: string
  payload: unknown
  token_reserva: string
  raia: string
  tentativas: number
}

export type Repositorio = {
  reservarItem: (worker: string) => Promise<ItemReservado | null>
  marcarDespachoIniciado: (filaId: number, token: string, chave: string) => Promise<boolean>
  marcarConcluida: (
    filaId: number,
    token: string,
    idMensagem: string,
    permalink: string | null,
  ) => Promise<void>
  marcarFalha: (
    filaId: number,
    token: string,
    codigo: string,
    mensagem: string,
    retentavel: boolean,
    esperarSegundos?: number,
  ) => Promise<void>
  registrarErro: (codigo: string, mensagem: string, filaId: number | null) => Promise<void>
}

/**
 * Como foi o repasse para o WhatsApp. Nunca muda o desfecho da publicacao:
 * entra como informacao ao lado dela, para que "publicou mas nao repassou"
 * seja visivel em vez de silencioso.
 */
export type DesfechoDoRepasse =
  | { situacao: "desligado" }
  | { situacao: "enviado" }
  | { situacao: "recusado"; motivo: string }
  | { situacao: "falhou"; codigo: string }

export type Desfecho =
  | { tipo: "nada_a_fazer" }
  | { tipo: "publicado"; filaId: number; idMensagem: string; repasse: DesfechoDoRepasse }
  | { tipo: "falhou"; filaId: number; codigo: string }
  | { tipo: "quarentena"; filaId: number; codigo: string }

export type Dependencias = {
  repositorio: Repositorio
  telegram: ClienteTelegram
  identificadorWorker: string
  destinoPermitido: string
  canalPermitido?: string
  gerarChaveDespacho?: () => string
  /**
   * Conversa privada que recebe o post formatado para o WhatsApp. Ausente
   * desliga o repasse por inteiro — e o estado padrao ate o operador ligar.
   */
  destinoDoRepasse?: string | null
}

/**
 * Manda o post formatado para o privado do operador.
 *
 * Blindado de ponta a ponta: nenhuma saida daqui lanca. O post ja foi
 * publicado quando esta funcao roda, entao qualquer excecao que subisse viraria
 * uma rodada "falhou" em cima de uma publicacao que deu certo — e o worker
 * poderia tentar publicar o mesmo item de novo.
 *
 * Falha de repasse tambem nao vira erro critico: a audiencia do Telegram foi
 * atendida. Fica registrado para aparecer, nao para acordar ninguem.
 */
async function repassarParaWhatsapp(
  deps: Pick<Dependencias, "repositorio" | "telegram" | "destinoDoRepasse">,
  filaId: number,
  payload: PayloadTelegram,
): Promise<DesfechoDoRepasse> {
  const { repositorio, telegram, destinoDoRepasse } = deps

  if (!destinoDoRepasse) return { situacao: "desligado" }

  try {
    const montagem = montarRepasseWhatsapp(payload)

    if (!montagem.ok) {
      await repositorio.registrarErro(
        `repasse_recusado:${montagem.motivo}`,
        `Post ${filaId} publicado, mas nao virou repasse de WhatsApp: ${montagem.motivo}`,
        filaId,
      )
      return { situacao: "recusado", motivo: montagem.motivo }
    }

    const problema = await telegram.repassar(destinoDoRepasse, montagem.repasse)

    if (problema) {
      await repositorio.registrarErro(
        `repasse_${problema.codigo}`,
        `Post ${filaId} publicado, mas o repasse nao chegou: ${problema.mensagem}`,
        filaId,
      )
      return { situacao: "falhou", codigo: problema.codigo }
    }

    return { situacao: "enviado" }
  } catch (erro) {
    const mensagem = erro instanceof Error ? erro.message : String(erro)

    // registrarErro tambem pode falhar. Engolir aqui e deliberado: o console e
    // a ultima rede, e nada disso pode derrubar a publicacao ja concluida.
    try {
      await repositorio.registrarErro("repasse_excecao", mensagem, filaId)
    } catch {
      console.error("[worker] repasse falhou e nao deu nem para registrar:", mensagem)
    }

    return { situacao: "falhou", codigo: "repasse_excecao" }
  }
}

/** Processa no maximo um item. O ritmo e decidido pelo banco. */
export async function processarUmItem({
  repositorio,
  telegram,
  identificadorWorker,
  destinoPermitido,
  canalPermitido = "telegram",
  gerarChaveDespacho = () => crypto.randomUUID(),
  destinoDoRepasse = null,
}: Dependencias): Promise<Desfecho> {
  const item = await repositorio.reservarItem(identificadorWorker)

  if (!item) return { tipo: "nada_a_fazer" }

  const recusar = async (codigo: string, mensagem: string) => {
    await repositorio.marcarFalha(item.fila_id, item.token_reserva, codigo, mensagem, false)
    await repositorio.registrarErro(codigo, mensagem, item.fila_id)
    return { tipo: "falhou" as const, filaId: item.fila_id, codigo }
  }

  if (item.canal !== canalPermitido) {
    return recusar("canal_nao_permitido", `Canal "${item.canal}" nao e atendido por este worker`)
  }

  if (item.destino !== destinoPermitido) {
    return recusar("destino_nao_permitido", `Destino "${item.destino}" nao e o configurado`)
  }

  const validacao = validarPayloadTelegram(item.payload)

  if (!validacao.ok) {
    return recusar("payload_invalido", validacao.erros.join("; "))
  }

  const preflight = await telegram.conferirCanal(item.destino)

  if (preflight) {
    if (preflight.tipo === "falha") {
      await repositorio.marcarFalha(
        item.fila_id,
        item.token_reserva,
        preflight.codigo,
        preflight.mensagem,
        preflight.retentavel,
        preflight.esperarSegundos,
      )
      await repositorio.registrarErro(preflight.codigo, preflight.mensagem, item.fila_id)
      return { tipo: "falhou", filaId: item.fila_id, codigo: preflight.codigo }
    }

    await repositorio.marcarFalha(
      item.fila_id,
      item.token_reserva,
      preflight.codigo,
      preflight.mensagem,
      true,
    )
    return { tipo: "falhou", filaId: item.fila_id, codigo: preflight.codigo }
  }

  // Ponto de nao retorno: o banco refaz todas as checagens aqui dentro.
  const chaveDespacho = gerarChaveDespacho()
  const liberado = await repositorio.marcarDespachoIniciado(
    item.fila_id,
    item.token_reserva,
    chaveDespacho,
  )

  if (!liberado) {
    return { tipo: "falhou", filaId: item.fila_id, codigo: "despacho_negado" }
  }

  const envio = await telegram.publicar(item.destino, validacao.payload)

  if (envio.tipo === "enviado") {
    await repositorio.marcarConcluida(
      item.fila_id,
      item.token_reserva,
      envio.idMensagem,
      envio.permalink,
    )

    // O repasse acontece DEPOIS da publicacao estar gravada, e o que der errado
    // daqui para baixo nao volta atras: o post ja esta no canal, e desfazer o
    // registro por causa do repasse transformaria uma conveniencia em risco de
    // publicar duas vezes.
    const repasse = await repassarParaWhatsapp(
      { repositorio, telegram, destinoDoRepasse },
      item.fila_id,
      validacao.payload,
    )

    return { tipo: "publicado", filaId: item.fila_id, idMensagem: envio.idMensagem, repasse }
  }

  if (envio.tipo === "desconhecido") {
    // retentavel=false apos o despacho poe o canal em quarentena.
    await repositorio.marcarFalha(
      item.fila_id,
      item.token_reserva,
      envio.codigo,
      envio.mensagem,
      false,
    )
    await repositorio.registrarErro(envio.codigo, envio.mensagem, item.fila_id)
    return { tipo: "quarentena", filaId: item.fila_id, codigo: envio.codigo }
  }

  await repositorio.marcarFalha(
    item.fila_id,
    item.token_reserva,
    envio.codigo,
    envio.mensagem,
    envio.retentavel,
    envio.esperarSegundos,
  )
  await repositorio.registrarErro(envio.codigo, envio.mensagem, item.fila_id)
  return { tipo: "falhou", filaId: item.fila_id, codigo: envio.codigo }
}
