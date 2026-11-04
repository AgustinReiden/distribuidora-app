/**
 * Clave de idempotencia de un cobro que sobrevive al modal y a una recarga (#1410).
 *
 * `useRequestIdEstable` guarda la clave en un `useRef`: cerrar el modal o
 * recargar la app la pierde, y el reintento viaja con otra. Si el primer intento
 * había entrado en el server, un cobro parcial vuelve a entrar y un FIFO a cuenta
 * se duplica entero. Acá la clave vive en `localStorage`, por huella, hasta que
 * el cobro sale bien o vence.
 *
 * El vencimiento no lo pone el server: el ledger (`pagos_solicitudes`, mig 167)
 * y el índice único de `pagos.client_request_id` no se purgan nunca, así que una
 * clave vieja se sigue reconociendo. Lo que acota es la intención: pasado el
 * plazo, la misma huella es otro cobro. Dos horas cubren un reparto sin señal y
 * el "registralo desde la ficha" del mismo turno; el día ya va en la huella.
 * El plazo corre desde el último intento, no desde el primero.
 *
 * Si `localStorage` tira (Safari privado, cuota), todo sigue en memoria: se
 * pierde la recarga, pero no cerrar y reabrir el modal.
 */
import { nuevoRequestId } from './idempotencia'
import { redondear } from './calculations'

export const VIGENCIA_REQUEST_ID_MS = 2 * 60 * 60 * 1000

const CLAVE_IDS = 'distribuidora:cobro-request-ids'
const CLAVE_SIN_CONFIRMAR = 'distribuidora:cobros-sin-confirmar'
// Tope de huellas guardadas, para no crecer sin fin si nadie cobra bien nunca.
const MAX_ENTRADAS = 200

interface Entrada {
  id: string
  t: number
}

let storageRoto = false
const memoria = new Map<string, Record<string, unknown>>()

function leer(clave: string): Record<string, unknown> {
  if (!storageRoto) {
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

function escribir(clave: string, valor: Record<string, unknown>): void {
  memoria.set(clave, valor)
  if (storageRoto) return
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

/** Las entradas vigentes de `clave`, las más nuevas primero y hasta el tope. */
function vigentes<T extends Entrada>(clave: string, ahora: number): Record<string, T> {
  const ordenadas = Object.entries(leer(clave))
    .filter((par): par is [string, T] => vigente(par[1], ahora))
    .sort((a, b) => b[1].t - a[1].t)
    .slice(0, MAX_ENTRADAS)
  return Object.fromEntries(ordenadas)
}

/**
 * La clave de esta huella: la misma mientras no venza ni se confirme el cobro,
 * aunque el modal se haya cerrado o la app se haya recargado.
 */
export function requestIdPersistente(huella: string, ahora: number = Date.now()): string {
  const mapa = vigentes<Entrada>(CLAVE_IDS, ahora)
  const id = mapa[huella]?.id ?? nuevoRequestId()
  mapa[huella] = { id, t: ahora }
  escribir(CLAVE_IDS, mapa)
  return id
}

/**
 * El cobro salió bien: sus huellas dejan de tener clave. Un cobro igual después
 * es otro cobro, no un reintento, y tiene que entrar.
 */
export function olvidarRequestIds(huellas: readonly string[], ahora: number = Date.now()): void {
  const mapa = vigentes<Entrada>(CLAVE_IDS, ahora)
  for (const h of huellas) delete mapa[h]
  escribir(CLAVE_IDS, mapa)
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
 * Un cobro de boleta que quedó sin confirmar en un camino que cierra el modal
 * solo (la entrega con pago, el cobro del alta). El modal de pago lo vuelve a
 * proponer tal cual y con su clave, así el reintento no lo duplica.
 */
export interface CobroSinConfirmar {
  pedidoId: string
  fechaPago: string
  observaciones?: string | null
  pagos: Array<{ formaPago: string; monto: number }>
  /** La clave con la que viajó: la primera es la del cobro entero (`registrarPagosBatch`). */
  clientRequestId: string
}

interface EntradaCobro extends Entrada {
  cobro: CobroSinConfirmar
}

export function guardarCobroSinConfirmar(cobro: CobroSinConfirmar, ahora: number = Date.now()): void {
  const mapa = vigentes<EntradaCobro>(CLAVE_SIN_CONFIRMAR, ahora)
  // Al centavo, como lo lee el modal (`parsePrecio`): si no, su huella no coincide.
  const pagos = cobro.pagos.map(p => ({ formaPago: p.formaPago, monto: redondear(p.monto, 2) }))
  mapa[cobro.pedidoId] = { id: cobro.clientRequestId, t: ahora, cobro: { ...cobro, pagos } }
  escribir(CLAVE_SIN_CONFIRMAR, mapa)
}

export function leerCobroSinConfirmar(pedidoId: string, ahora: number = Date.now()): CobroSinConfirmar | null {
  const e = vigentes<EntradaCobro>(CLAVE_SIN_CONFIRMAR, ahora)[pedidoId]
  if (!e?.cobro || !Array.isArray(e.cobro.pagos)) return null
  return { ...e.cobro, clientRequestId: e.id }
}

export function borrarCobroSinConfirmar(pedidoId: string, ahora: number = Date.now()): void {
  const mapa = vigentes<EntradaCobro>(CLAVE_SIN_CONFIRMAR, ahora)
  delete mapa[pedidoId]
  escribir(CLAVE_SIN_CONFIRMAR, mapa)
}

/**
 * Corre el cobro de una boleta y deja constancia de cómo terminó: si falla, queda
 * sin confirmar con su clave (la primera, que es la del cobro entero); si sale
 * bien, se borra. Lo usan los caminos de `PedidosContainer` que cobran una boleta.
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
    if (clientRequestId) {
      guardarCobroSinConfirmar({
        pedidoId: cobro.pedidoId,
        fechaPago: cobro.fechaPago,
        observaciones: cobro.observaciones,
        pagos: cobro.pagos,
        clientRequestId,
      })
    }
    throw e
  }
}
