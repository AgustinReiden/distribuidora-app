/**
 * Clave de idempotencia de un cobro que sobrevive al modal y a una recarga (#1410).
 *
 * `useRequestIdEstable` guarda la clave en un `useRef`: cerrar el modal o
 * recargar la app la pierde, y el reintento viaja con otra. Si el primer intento
 * había entrado en el server, un cobro parcial vuelve a entrar y un FIFO a cuenta
 * se duplica entero. Acá la clave vive en `localStorage`, por usuario y por
 * huella, hasta que el cobro sale bien o vence. Con el modal abierto manda la
 * memoria del modal (`useRequestIdPersistente`): el almacenamiento es para
 * reabrir y para recargar.
 *
 * El vencimiento no lo pone el server: el ledger (`pagos_solicitudes`, mig 167)
 * y el índice único de `pagos.client_request_id` no se purgan nunca, así que una
 * clave vieja se sigue reconociendo. Lo que acota es la intención: pasado el
 * plazo, la misma huella es otro cobro. Dos horas cubren un reparto sin señal y
 * el "registralo desde la ficha" del mismo turno; el día ya va en la huella.
 * El plazo corre desde el último intento, no desde el primero.
 *
 * Es por usuario: en un equipo compartido, la clave de otro haría que el server
 * le devuelva a uno el cobro del otro como si fuera suyo, y la plata de uno no
 * entraría. Sin usuario no se guarda nada en el dispositivo. El logout borra lo
 * del que sale (`olvidarRequestIdsDe`).
 *
 * Si `localStorage` tira (Safari privado, cuota), todo sigue en memoria: se
 * pierde la recarga, pero no cerrar y reabrir el modal.
 */
import { nuevoRequestId } from './idempotencia'
import { redondear } from './calculations'
import { ErrorDeSupabase, esErrorReintentable } from './errorDeSupabase'

export const VIGENCIA_REQUEST_ID_MS = 2 * 60 * 60 * 1000

const PREFIJO_IDS = 'distribuidora:cobro-request-ids'
const PREFIJO_SIN_CONFIRMAR = 'distribuidora:cobros-sin-confirmar'
// Tope de huellas guardadas, para no crecer sin fin si nadie cobra bien nunca.
const MAX_ENTRADAS = 200

interface Entrada {
  id: string
  t: number
}

let usuarioActual: string | null = null
let storageRoto = false
const memoria = new Map<string, Record<string, unknown>>()

/** Lo llama la sesión (`useAuth`) cada vez que cambia el usuario. */
export function fijarUsuarioRequestIds(usuarioId: string | null): void {
  usuarioActual = usuarioId
}

/** Borra las claves y los cobros sin confirmar de un usuario (logout). */
export function olvidarRequestIdsDe(usuarioId: string | null): void {
  if (!usuarioId) return
  for (const prefijo of [PREFIJO_IDS, PREFIJO_SIN_CONFIRMAR]) {
    const clave = `${prefijo}:${usuarioId}`
    memoria.delete(clave)
    try {
      localStorage.removeItem(clave)
    } catch {
      // Sin storage no hay nada guardado que borrar.
    }
  }
}

function claveDe(prefijo: string): string {
  return `${prefijo}:${usuarioActual ?? ''}`
}

function leer(prefijo: string): Record<string, unknown> {
  const clave = claveDe(prefijo)
  if (usuarioActual && !storageRoto) {
    try {
      const crudo = localStorage.getItem(clave)
      if (!crudo) return {}
      const valor: unknown = JSON.parse(crudo)
      return valor && typeof valor === 'object' && !Array.isArray(valor)
        ? (valor as Record<string, unknown>)
        : {}
    } catch {
      storageRoto = true
    }
  }
  return { ...(memoria.get(clave) ?? {}) }
}

function escribir(prefijo: string, valor: Record<string, unknown>): void {
  const clave = claveDe(prefijo)
  memoria.set(clave, valor)
  if (!usuarioActual || storageRoto) return
  try {
    localStorage.setItem(clave, JSON.stringify(valor))
  } catch {
    storageRoto = true
  }
}

function vigente(e: unknown, ahora: number): e is Entrada {
  if (!e || typeof e !== 'object') return false
  const { id, t } = e as Partial<Entrada>
  return typeof id === 'string' && id.length > 0 && typeof t === 'number' && ahora - t < VIGENCIA_REQUEST_ID_MS
}

/** Las entradas vigentes de `prefijo`, las más nuevas primero y hasta el tope. */
function vigentes<T extends Entrada>(prefijo: string, ahora: number): Record<string, T> {
  const ordenadas = Object.entries(leer(prefijo))
    .filter((par): par is [string, T] => vigente(par[1], ahora))
    .sort((a, b) => b[1].t - a[1].t)
    .slice(0, MAX_ENTRADAS)
  return Object.fromEntries(ordenadas)
}

/**
 * La clave de esta huella: la misma mientras no venza ni se confirme el cobro,
 * aunque el modal se haya cerrado o la app se haya recargado.
 *
 * `idEnMemoria` es la que ya tiene el modal abierto: manda sobre lo guardado,
 * que pudo vencer, pisarlo otra pestaña o caerse por el tope. Se vuelve a
 * guardar con ella, así reabrir el modal la encuentra.
 */
export function requestIdPersistente(
  huella: string,
  ahora: number = Date.now(),
  idEnMemoria?: string,
): string {
  const mapa = vigentes<Entrada>(PREFIJO_IDS, ahora)
  const id = idEnMemoria ?? mapa[huella]?.id ?? nuevoRequestId()
  mapa[huella] = { id, t: ahora }
  escribir(PREFIJO_IDS, mapa)
  return id
}

/**
 * El cobro salió bien: sus huellas dejan de tener clave. Un cobro igual después
 * es otro cobro, no un reintento, y tiene que entrar.
 */
export function olvidarRequestIds(huellas: readonly string[], ahora: number = Date.now()): void {
  const mapa = vigentes<Entrada>(PREFIJO_IDS, ahora)
  for (const h of huellas) delete mapa[h]
  escribir(PREFIJO_IDS, mapa)
}

/**
 * ¿El cobro puede haber entrado aunque falló? Sí si no hubo respuesta (red,
 * plazo vencido) o si la respuesta no dice nada del cobro: un 5xx de gateway o
 * una transacción abortada que pide reintentar (40001, deadlock). Un rechazo del
 * server (excede lo que falta, fecha, boleta ajena) dice que no entró: esa clave
 * no tiene nada que proteger.
 */
export function cobroPudoHaberEntrado(error: unknown): boolean {
  if (error instanceof ErrorDeSupabase && error.sinServidor) return true
  return esErrorReintentable(error)
}

/** Huella del cobro de una boleta: todo lo que lo hace "este cobro y no otro". */
export function huellaCobroPedido(c: {
  pedidoId: string
  fechaPago: string
  observaciones?: string | null
  pagos: ReadonlyArray<{ formaPago: string; monto: number }>
}): string {
  return [
    'pedido', c.pedidoId, c.fechaPago, (c.observaciones ?? '').trim(),
    c.pagos.map(p => `${p.monto}@${p.formaPago}`).join(','),
  ].join('|')
}

/**
 * Un cobro de boleta que quedó sin confirmar. Lo guardan los tres caminos de
 * `PedidosContainer` que cobran una boleta: el cobro del modal de pago, la
 * entrega con pago y el cobro del alta. Los dos últimos cierran el modal solos.
 * El modal de pago lo vuelve a proponer tal cual y con su clave, así el
 * reintento no lo duplica.
 */
export interface CobroSinConfirmar {
  pedidoId: string
  fechaPago: string
  observaciones?: string | null
  pagos: Array<{ formaPago: string; monto: number }>
  /**
   * La clave con la que viajó. Es una para todo el cobro: `registrarPagosBatch`
   * manda una sola llamada con la primera clave de las líneas.
   */
  clientRequestId: string
  /**
   * Lo pagado de la boleta antes de intentarlo. Con eso se sabe al reabrir si el
   * cobro no entró (igual), si entró (igual más el cobro) o si la boleta se
   * movió por otro camino (otra cosa), y en los dos últimos casos no se propone.
   */
  pagadoAntes: number
}

interface EntradaCobro extends Entrada {
  cobro: CobroSinConfirmar
}

export function guardarCobroSinConfirmar(cobro: CobroSinConfirmar, ahora: number = Date.now()): void {
  const mapa = vigentes<EntradaCobro>(PREFIJO_SIN_CONFIRMAR, ahora)
  // Al centavo, como lo lee el modal (`parsePrecio`): si no, su huella no coincide.
  const pagos = cobro.pagos.map(p => ({ formaPago: p.formaPago, monto: redondear(p.monto, 2) }))
  mapa[cobro.pedidoId] = { id: cobro.clientRequestId, t: ahora, cobro: { ...cobro, pagos } }
  escribir(PREFIJO_SIN_CONFIRMAR, mapa)
}

export function leerCobroSinConfirmar(pedidoId: string, ahora: number = Date.now()): CobroSinConfirmar | null {
  const e = vigentes<EntradaCobro>(PREFIJO_SIN_CONFIRMAR, ahora)[pedidoId]
  if (!e?.cobro || !Array.isArray(e.cobro.pagos) || typeof e.cobro.pagadoAntes !== 'number') return null
  return { ...e.cobro, clientRequestId: e.id }
}

export function borrarCobroSinConfirmar(pedidoId: string, ahora: number = Date.now()): void {
  const mapa = vigentes<EntradaCobro>(PREFIJO_SIN_CONFIRMAR, ahora)
  delete mapa[pedidoId]
  escribir(PREFIJO_SIN_CONFIRMAR, mapa)
}

/**
 * Qué pasó con un cobro sin confirmar, mirando lo pagado de la boleta hoy:
 * - `'no_entro'`: está igual que antes del intento. Se propone, con su clave.
 * - `'entro'`: subió exactamente lo del cobro. Ya está: no hay que reintentar.
 * - `'cambio'`: se movió por otro camino. Proponerlo invitaría a cobrar dos veces.
 */
export function estadoCobroSinConfirmar(
  cobro: CobroSinConfirmar,
  pagadoAhora: number,
): 'no_entro' | 'entro' | 'cambio' {
  const total = cobro.pagos.reduce((s, p) => s + p.monto, 0)
  if (Math.abs(pagadoAhora - cobro.pagadoAntes) < 0.01) return 'no_entro'
  if (Math.abs(pagadoAhora - (cobro.pagadoAntes + total)) < 0.01) return 'entro'
  return 'cambio'
}

/**
 * Corre el cobro de una boleta y deja constancia de cómo terminó. Si falla de un
 * modo que puede haber entrado (`cobroPudoHaberEntrado`), queda sin confirmar con
 * su clave. Si sale bien, se borra el que hubiera. Si el server lo rechaza, no
 * entró y no hay nada que guardar.
 */
export async function cobrarRecordandoSinConfirmar<T>(
  cobro: Omit<CobroSinConfirmar, 'clientRequestId'> & { clientRequestIds?: string[] },
  cobrar: () => Promise<T>,
): Promise<T> {
  try {
    const resultado = await cobrar()
    borrarCobroSinConfirmar(cobro.pedidoId)
    return resultado
  } catch (e) {
    const clientRequestId = cobro.clientRequestIds?.find(Boolean)
    if (clientRequestId && cobroPudoHaberEntrado(e)) {
      guardarCobroSinConfirmar({
        pedidoId: cobro.pedidoId,
        fechaPago: cobro.fechaPago,
        observaciones: cobro.observaciones,
        pagos: cobro.pagos,
        clientRequestId,
        pagadoAntes: cobro.pagadoAntes,
      })
    }
    throw e
  }
}
