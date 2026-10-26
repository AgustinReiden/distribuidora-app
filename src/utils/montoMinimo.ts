/**
 * Compra mínima en $ por pedido.
 *
 * Espejo EXACTO de `pedido_incumple_minimo` (mig 205). La regla vive en la base
 * para que valga en todos los caminos de alta, pero tiene que estar también acá:
 * si sólo viviera en SQL, un pedido cargado sin señal se aceptaría en el
 * teléfono, el preventista se iría del comercio, y el rechazo llegaría horas
 * después al sincronizar — quedando como una operación fallida en IndexedDB que
 * nadie mira. Es el mismo criterio que ya se usa para el mínimo por producto
 * (mig 147): validar en la base Y avisar antes de confirmar.
 *
 * Si cambiás esta regla, cambiá también `pedido_incumple_minimo`.
 */
import { formatCurrency } from './formatters'

/** Un pedido que da exactamente el mínimo pasa. */
export function cumpleMontoMinimo(total: number, minimo: number): boolean {
  if (!Number.isFinite(minimo) || minimo <= 0) return true // 0 = sin política
  return (Number.isFinite(total) ? total : 0) >= minimo
}

/**
 * Motivo del rechazo, o null si el pedido está bien.
 *
 * Devuelve el texto ya armado (con los dos montos) porque sale por caminos
 * donde nadie va a ir a buscar cuál era el mínimo.
 */
export function motivoMontoMinimo(total: number, minimo: number): string | null {
  if (cumpleMontoMinimo(total, minimo)) return null
  const faltante = minimo - (Number.isFinite(total) ? total : 0)
  return (
    `El pedido no alcanza la compra mínima de ${formatCurrency(minimo)}. ` +
    `Faltan ${formatCurrency(faltante)}.`
  )
}

/**
 * Compra mínima con cargo de envío (mig 389, #1220).
 *
 * Tres modos, que se eligen en /configuracion:
 *   - 'bloquear': bajo `montoMinimo` el pedido se rechaza (lo de la mig 205).
 *   - 'cargo':    bajo `montoMinimo` el pedido entra y paga `cargoEnvio`.
 *   - 'escalas':  bajo `montoMinimo` se rechaza; desde ahí y hasta
 *                 `montoEnvioGratis` entra y paga `cargoEnvio`; desde
 *                 `montoEnvioGratis`, ni se rechaza ni se cobra.
 *
 * Espejo de `pedido_incumple_minimo` y `pedido_cargo_envio`. Si cambiás una
 * regla, cambiá la otra. El `total` que reciben es la suma de los ítems, SIN el
 * cargo: el servidor decide el cargo y lo suma al guardar.
 */
export type ModoMinimoPedido = 'bloquear' | 'cargo' | 'escalas'

export interface ReglaMinimoPedido {
  modo: ModoMinimoPedido
  montoMinimo: number
  montoEnvioGratis: number
  cargoEnvio: number
}

export const REGLA_MINIMO_POR_DEFECTO: ReglaMinimoPedido = {
  modo: 'bloquear',
  montoMinimo: 0,
  montoEnvioGratis: 0,
  cargoEnvio: 0,
}

/** La regla a partir de los campos de la política comercial de la sucursal. */
export function reglaMinimoDe(politicas: {
  montoMinimoPedido: number
  modoMinimoPedido: ModoMinimoPedido
  montoEnvioGratis: number
  cargoEnvioPedido: number
}): ReglaMinimoPedido {
  return {
    modo: politicas.modoMinimoPedido,
    montoMinimo: politicas.montoMinimoPedido,
    montoEnvioGratis: politicas.montoEnvioGratis,
    cargoEnvio: politicas.cargoEnvioPedido,
  }
}

/** Motivo del rechazo según el modo, o null si el pedido puede cargarse. */
export function motivoRechazoMinimo(total: number, regla: ReglaMinimoPedido): string | null {
  if (regla.modo === 'cargo') return null
  return motivoMontoMinimo(total, regla.montoMinimo)
}

/** Cargo de envío que le toca a un pedido nuevo (0 si ninguno). */
export function cargoEnvioPedido(total: number, regla: ReglaMinimoPedido): number {
  const t = Number.isFinite(total) ? total : 0
  if (t <= 0) return 0 // sin productos no hay envío que cobrar
  if (!(regla.cargoEnvio > 0)) return 0
  if (regla.modo === 'cargo') {
    return regla.montoMinimo > 0 && t < regla.montoMinimo ? regla.cargoEnvio : 0
  }
  if (regla.modo === 'escalas') {
    return t >= regla.montoMinimo && t < regla.montoEnvioGratis ? regla.cargoEnvio : 0
  }
  return 0
}

/** Cuánto falta para no pagar envío, o null si el pedido no lo paga. */
export function faltanteParaEnvioGratis(total: number, regla: ReglaMinimoPedido): number | null {
  if (cargoEnvioPedido(total, regla) <= 0) return null
  const umbral = regla.modo === 'cargo' ? regla.montoMinimo : regla.montoEnvioGratis
  return Math.max(umbral - (Number.isFinite(total) ? total : 0), 0)
}

/*
 * Edición, desglose y venta sin cargo.
 *
 * Espejo de las funciones SQL `cargo_*` de `NNN_cargo_1_base` (gate:
 * `cargoEnvio.espejo.json`, que corren este archivo y el SQL con los mismos
 * casos). Si cambiás una, cambiá la otra y sumá el caso.
 */
export type CargoEnvioEstado = 'no_aplica' | 'cobrado' | 'gratis' | 'bonificado'
export type DecisionEnvio = 'cobrar' | 'no_cobrar'

/** Desde qué total no se paga envío: el mínimo en `cargo`, el "gratis" en `escalas`. */
export function umbralEnvioGratis(regla: ReglaMinimoPedido): number {
  if (regla.modo === 'cargo') return regla.montoMinimo
  if (regla.modo === 'escalas') return regla.montoEnvioGratis
  return 0
}

/** ¿La política de la sucursal cobra envío en algún caso? */
export function politicaCobraCargo(regla: ReglaMinimoPedido): boolean {
  return (
    (regla.modo === 'cargo' || regla.modo === 'escalas') &&
    regla.cargoEnvio > 0 &&
    umbralEnvioGratis(regla) > 0
  )
}

/** `debajo` ⇔ 0 < total < umbral. El total 0 (sin productos) cuenta como `arriba`. */
export function franjaCargo(total: number, regla: ReglaMinimoPedido): 'debajo' | 'arriba' {
  const t = Number.isFinite(total) ? total : 0
  return t > 0 && t < umbralEnvioGratis(regla) ? 'debajo' : 'arriba'
}

/**
 * El cargo de un pedido tras editarle los ítems.
 *
 * Sólo se reconsidera si el total cruza la franja: sin cruce, el pedido conserva
 * lo que ya tenía (aunque el costo del envío haya cambiado desde entonces). Con
 * cruce, el preventista no decide: debajo cobra el costo vigente, arriba queda
 * gratis. Admin y encargado deciden; sin decisión el pedido queda como está y
 * se pide una (`requiereDecision`).
 *
 * `totalViejo` y `totalNuevo` son totales de PRODUCTOS, sin el cargo: para el
 * pedido guardado, `ventaDePedido(pedido)`. Un pedido que queda sin productos
 * (`totalNuevo <= 0`) nunca paga envío: queda `gratis` con cargo 0, sea quien
 * sea el que edita y haya o no decisión (spec §9); sólo lo frenan antes un
 * `no_aplica` o una política que no cobra.
 */
export function cargoTrasEdicion(a: {
  estado: CargoEnvioEstado
  cargoActual: number
  totalViejo: number
  totalNuevo: number
  regla: ReglaMinimoPedido
  esPreventista: boolean
  decision: DecisionEnvio | null
}): { cargo: number; estado: CargoEnvioEstado; requiereDecision: boolean } {
  const igual = { cargo: a.cargoActual, estado: a.estado, requiereDecision: false }
  if (a.estado === 'no_aplica' || !politicaCobraCargo(a.regla)) return igual

  if (!(a.totalNuevo > 0)) return { cargo: 0, estado: 'gratis', requiereDecision: false }

  const nueva = franjaCargo(a.totalNuevo, a.regla)
  if (franjaCargo(a.totalViejo, a.regla) === nueva) return igual

  const cobrado = { cargo: a.regla.cargoEnvio, estado: 'cobrado' as const, requiereDecision: false }
  const sinCobro = {
    cargo: 0,
    estado: nueva === 'debajo' ? ('bonificado' as const) : ('gratis' as const),
    requiereDecision: false,
  }
  // Para el preventista, arriba es `gratis` (sinCobro ya lo es) y su decisión no cuenta.
  if (a.esPreventista) return nueva === 'debajo' ? cobrado : sinCobro
  if (a.decision === 'cobrar') return cobrado
  if (a.decision === 'no_cobrar') return sinCobro
  return { ...igual, requiereDecision: true }
}

const redondear2 = (n: number): number => Math.round((n + Number.EPSILON) * 100) / 100

/**
 * Neto e IVA de un cargo de envío. El cargo es precio final: en FC el IVA es el
 * 21 % incluido; en ZZ todo es neto; el vale blanco (VB) no lleva nada.
 */
export function cargoDesglose(
  cargo: number,
  tipoFactura: string | null | undefined,
): { neto: number; iva: number } {
  if (!(cargo > 0) || tipoFactura === 'VB') return { neto: 0, iva: 0 }
  if (tipoFactura !== 'FC') return { neto: redondear2(cargo), iva: 0 }
  const neto = redondear2(cargo / 1.21)
  return { neto, iva: redondear2(cargo - neto) }
}

/** Lo vendido en productos: el total sin el cargo de envío. */
export function ventaDePedido(p: { total: number; cargo_envio?: number | null }): number {
  return Math.max(p.total - (p.cargo_envio ?? 0), 0)
}
