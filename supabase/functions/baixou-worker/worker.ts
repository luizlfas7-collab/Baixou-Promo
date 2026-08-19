import { validarPayloadTelegram } from "../_compartilhado/payload.ts"
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

export type Desfecho =
  | { tipo: "nada_a_fazer" }
  | { tipo: "publicado"; filaId: number; idMensagem: string }
  | { tipo: "falhou"; filaId: number; codigo: string }
  | { tipo: "quarentena"; filaId: number; codigo: string }

export type Dependencias = {
  repositorio: Repositorio
  telegram: ClienteTelegram
  identificadorWorker: string
  destinoPermitido: string
  canalPermitido?: string
  gerarChaveDespacho?: () => string
}

/** Processa no maximo um item. O ritmo e decidido pelo banco. */
export async function processarUmItem({
  repositorio,
  telegram,
  identificadorWorker,
  destinoPermitido,
  canalPermitido = "telegram",
  gerarChaveDespacho = () => crypto.randomUUID(),
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
    return { tipo: "publicado", filaId: item.fila_id, idMensagem: envio.idMensagem }
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
