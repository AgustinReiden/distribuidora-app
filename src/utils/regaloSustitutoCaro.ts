/**
 * H1 de la revisión de C2 (#1592, decisión del dueño del 19/11): «No deja guardar así: o
 * vuelve al regalo original (R) o el pedido queda como está. Este bloqueo no es silencioso
 * sino que se avisa».
 *
 * Un admin cambió el regalo de una promo por un producto de OTRO rubro (R×10 → X×1). Si
 * después quien no es admin edita el pedido y baja lo que da la promo (menos venta: R×1), el
 * sustituto ya no puede valer más, a precio de lista, que ese regalo nuevo. El server lo
 * rechaza en `actualizar_pedido_items` (`_regalo_tope_de_cadena`, código
 * `regalo_sustituto_sobre_tope`); esto es el aviso que la pantalla da antes, con lo que sabe.
 *
 * Es conservador: sólo avisa cuando la cuenta es segura (un regalo por línea, sin el factor
 * de una barra). Si no puede saberlo, no avisa y el rechazo del server muestra el mismo aviso.
 * El mismo rubro no entra (igual o menor cantidad es legal), ni el admin (sin tope), ni una
 * edición que no baja lo que da la promo («lo que armó un admin se conserva y no crece»).
 */
import { esRegaloCompatible, type ProductoRegalo } from './regaloCompatible'
import { topeSustitutoRegalo } from './regaloOtroEmpaque'

export interface RegaloSustitutoCaroArgs {
  esAdmin: boolean
  /** El regalo de la promo (la raíz de la cadena), con su precio de lista. */
  regalo: (ProductoRegalo & { precio?: number | string | null }) | null | undefined
  /** El producto que quedaría en la línea (el final de la cadena), con su precio. */
  sustituto: (ProductoRegalo & { precio?: number | string | null }) | null | undefined
  /** Lo que da la promo con esta edición, en la unidad del regalo (el corte que se manda). */
  corteNuevo: number
  /** El corte de la línea guardada. */
  corteGuardado: number | null | undefined
  /** Las unidades del sustituto que quedarían (la cadena aplicada al corte nuevo). */
  cantidadSustituto: number
  /** El regalo de la promo mueve stock por línea (sin barra de fracción). */
  porLinea: boolean
}

/** ¿El sustituto de otro rubro pasa a valer más que lo que da la promo ahora? */
export function regaloSustitutoCaro(args: RegaloSustitutoCaroArgs): boolean {
  const { esAdmin, regalo, sustituto, corteNuevo, corteGuardado, cantidadSustituto, porLinea } = args
  if (esAdmin || !porLinea || !regalo || !sustituto) return false
  if (String(regalo.id) === String(sustituto.id)) return false
  if (corteGuardado == null || !(corteNuevo < corteGuardado)) return false
  if (esRegaloCompatible(regalo, sustituto)) return false
  // Sin los dos precios de lista no se sabe: avisa el server.
  if (!(Number(regalo.precio) > 0) || !(Number(sustituto.precio) > 0)) return false
  const tope = topeSustitutoRegalo({
    corte: corteNuevo,
    precioRegalo: regalo.precio,
    factorRegalo: 1,
    precioSustituto: sustituto.precio,
    factorSustituto: 1,
    mismoRubro: false,
  })
  return cantidadSustituto > tope
}

/** El código con que el server rechaza un sustituto que vale más que lo que da la promo. */
export const CODIGO_REGALO_SUSTITUTO_SOBRE_TOPE = 'regalo_sustituto_sobre_tope'
