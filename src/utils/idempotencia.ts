/**
 * UUIDs de idempotencia para escrituras que no se pueden duplicar (pagos).
 *
 * El servidor (mig 167) deduplica por `client_request_id`: si ya vio ese UUID,
 * devuelve el resultado de la primera vez en lugar de volver a escribir. Para
 * que eso sirva, el UUID tiene que ser el MISMO en todos los reintentos del
 * mismo pago y DISTINTO si el usuario cambia el monto o la forma de pago —
 * de eso se encarga `useRequestIdEstable`.
 */
import { esRechazoDeNegocio, esRechazoDeOtraSucursal } from './rechazoDeNegocio'
import { esGatewayCaido } from './falloDeRed'

/**
 * `crypto.randomUUID` necesita contexto seguro y no existe en iOS Safari < 15.4.
 * La app corre en el reparto, en teléfonos viejos, así que hay fallback sobre
 * `getRandomValues` (v4 armado a mano) antes de caer en algo no criptográfico.
 */
export function nuevoRequestId(): string {
  if (typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function') {
    return crypto.randomUUID()
  }

  if (typeof crypto !== 'undefined' && typeof crypto.getRandomValues === 'function') {
    const bytes = crypto.getRandomValues(new Uint8Array(16))
    bytes[6] = (bytes[6] & 0x0f) | 0x40 // versión 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80 // variante RFC 4122
    const hex = Array.from(bytes, b => b.toString(16).padStart(2, '0')).join('')
    return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`
  }

  // Último recurso: no hay crypto. Peor un UUID débil que ninguno — igual solo
  // tiene que ser único dentro de la ventana de reintentos de un pago.
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, c => {
    const r = (Math.random() * 16) | 0
    return (c === 'x' ? r : (r & 0x3) | 0x8).toString(16)
  })
}

/** La clave de un alta de pedido y la huella del contenido con el que se acuñó. */
export interface ClaveDeAlta {
  id: string
  huella: string
  /**
   * El servidor puede tener un pedido con esta clave (#1543): un intento se mandó
   * y no se sabe si hizo COMMIT. Mientras sea así no se acuña otra sin preguntar.
   */
  enDuda?: boolean
}

/**
 * La clave de idempotencia del ALTA de un pedido (`pedidos.offline_id`, mig 071).
 *
 * Mientras la huella del contenido no cambie, un reintento reusa la clave: el
 * servidor lo reconoce y no crea el pedido dos veces aunque se haya perdido la
 * respuesta. Si el usuario edita el carrito (o el cliente, la fecha, las notas)
 * entre un intento y el siguiente, ya no es el mismo pedido: con la clave vieja,
 * un primer intento que SÍ había entrado devolvía el pedido de antes como si fuera
 * éste y la edición se perdía en silencio. Un contenido distinto acuña otra clave.
 *
 * `previa` es la que quedó del intento anterior (null si no hubo, o si el
 * formulario se limpió). Esta función no mira `enDuda`: el alta pasa por
 * `pasoDeAlta`, que no deja acuñar sobre una clave en duda.
 */
export function claveDeAlta(previa: ClaveDeAlta | null, huella: string): ClaveDeAlta {
  return previa && previa.huella === huella ? previa : { id: nuevoRequestId(), huella }
}

/**
 * Qué hacer antes de mandar un alta (#1543).
 *
 * El principio: nunca se acuña una clave nueva mientras no se sepa qué pasó con
 * la anterior. Con el contenido igual se reusa (el servidor contesta idempotente
 * si había entrado); con el contenido distinto y la anterior en duda, primero se
 * le pregunta al servidor si la anterior entró. Sin esto, un intento perdido
 * después del COMMIT seguido de una edición —o de un refetch de precios, que
 * también cambia la huella— creaba un segundo pedido.
 */
export type PasoDeAlta =
  | { paso: 'enviar'; clave: ClaveDeAlta }
  | { paso: 'verificar'; anterior: ClaveDeAlta }

export function pasoDeAlta(previa: ClaveDeAlta | null, huella: string): PasoDeAlta {
  if (previa && previa.huella !== huella && previa.enDuda) {
    return { paso: 'verificar', anterior: previa }
  }
  return { paso: 'enviar', clave: claveDeAlta(previa, huella) }
}

/**
 * Lo que contestó el servidor al preguntarle por `pedidos.offline_id`.
 * `sin_respuesta` es todo lo que no es una respuesta limpia: sin red, plazo
 * vencido o un error (con un error no se puede decir que no entró).
 */
export type VerificacionDeAlta =
  | { resultado: 'entro'; pedidoId: string }
  | { resultado: 'no_entro' }
  | { resultado: 'sin_respuesta' }

export type DecisionTrasVerificar =
  | { paso: 'enviar'; clave: ClaveDeAlta }
  | { paso: 'ya_entro'; pedidoId: string }
  | { paso: 'esperar_senal' }

/**
 * Con la respuesta del servidor sobre la clave anterior:
 * - entró → no se crea otro pedido: lo que cambió no está en él, se edita desde la lista;
 * - no entró → el contenido nuevo es otro pedido, con otra clave;
 * - no se pudo preguntar → no se crea ni se encola nada: con otra clave podría
 *   duplicar, y con la misma (contenido distinto) la edición se perdería sin aviso
 *   si la anterior había entrado. Se espera a tener señal.
 */
export function decidirTrasVerificar(verificacion: VerificacionDeAlta, huella: string): DecisionTrasVerificar {
  switch (verificacion.resultado) {
    case 'entro':
      return { paso: 'ya_entro', pedidoId: verificacion.pedidoId }
    case 'no_entro':
      return { paso: 'enviar', clave: { id: nuevoRequestId(), huella } }
    default:
      return { paso: 'esperar_senal' }
  }
}

/**
 * ¿El servidor contestó (con un código de la base o de PostgREST)? Entonces la
 * transacción de ESE intento no hizo COMMIT. Un 5xx de gateway no cuenta: el
 * gateway contestó, pero la base pudo haber terminado (#1373).
 */
function contestoElServidor(error: unknown): boolean {
  const e = error as { code?: unknown; sinServidor?: unknown } | null | undefined
  if (e?.sinServidor === true || esGatewayCaido(error)) return false
  const code = e?.code
  return (typeof code === 'string' && code !== '') || typeof code === 'number'
}

/**
 * Si la clave queda en duda después de que un intento con ella falló.
 *
 * - Rechazo de negocio (`success: false`): no. `crear_pedido_idempotente` busca
 *   la clave ANTES de validar nada (mig 235) y, si la tuviera, contestaría el
 *   pedido de antes; un rechazo prueba que ningún intento con esta clave entró.
 * - "Ya se sincronizó en otra sucursal": sí. Es lo que contesta sobre el pedido
 *   PROPIO con el JWT vencido (#1304): la clave está en la tabla.
 * - Error con código del servidor (42501, P0001, PGRST…, 40001): este intento
 *   no entró, pero no prueba nada de uno anterior: queda como estaba.
 * - Todo lo demás (red, plazo, 5xx de gateway, un Error sin código): sí.
 */
export function enDudaTrasFallo(enDudaAntes: boolean, error: unknown): boolean {
  if (esRechazoDeOtraSucursal(error)) return true
  if (esRechazoDeNegocio(error)) return false
  if (contestoElServidor(error)) return enDudaAntes
  return true
}

/** El aviso cuando la clave anterior sí había entrado: lo cambiado no está en ese pedido. */
export function mensajeAltaQueYaHabiaEntrado(pedidoId: string, declaraCobro: boolean): string {
  return `El pedido #${pedidoId} sí se había guardado en el intento anterior, aunque la pantalla mostró un error. ` +
    'Lo que cambiaste después NO está en ese pedido y no se cargó otro: si hace falta, editalo desde la lista.' +
    (declaraCobro ? ' El cobro no quedó registrado: registralo desde la ficha del pedido.' : '')
}

/**
 * Qué hacer con la clave de un alta que quedó en duda antes de recargar la app
 * (INF-6, #1563), según lo que contesta el servidor:
 * - entró → se avisa (el pedido existe: no hay que cargarlo de nuevo) y se olvida;
 * - no entró → se olvida: la próxima alta es otra, con otra clave;
 * - no se pudo preguntar → se conserva: la próxima alta pasa por `pasoDeAlta`, que
 *   la reusa si el contenido es el mismo y pregunta antes de acuñar otra si no.
 */
export type DecisionAltaRecuperada =
  | { paso: 'avisar'; pedidoId: string }
  | { paso: 'olvidar' }
  | { paso: 'conservar' }

export function decidirAltaRecuperada(verificacion: VerificacionDeAlta): DecisionAltaRecuperada {
  switch (verificacion.resultado) {
    case 'entro':
      return { paso: 'avisar', pedidoId: verificacion.pedidoId }
    case 'no_entro':
      return { paso: 'olvidar' }
    default:
      return { paso: 'conservar' }
  }
}

/** El aviso cuando el alta que quedó en duda antes de recargar sí había entrado. */
export function mensajeAltaRecuperada(pedidoId: string): string {
  return `El pedido #${pedidoId}, que quedó sin confirmar antes de que se cerrara la app, sí se guardó: ` +
    'no lo cargues de nuevo. Si tenía un cobro, registralo desde la ficha del pedido.'
}

/** El aviso cuando no se pudo preguntar por la clave anterior. */
export const MENSAJE_ALTA_SIN_VERIFICAR =
  'No se pudo confirmar si el pedido del intento anterior quedó guardado, y como lo cambiaste no se volvió a ' +
  'cargar para no duplicarlo. Esperá a tener señal y tocá Confirmar de nuevo: primero se fija si el anterior entró.'

/**
 * Identidad de ESTA instalación del PWA. Sobrevive recargas y cierres de la
 * app, y es distinta en cada teléfono.
 *
 * Existe para las operaciones que ya estaban encoladas en IndexedDB antes de
 * que la cola acuñara un UUID propio: su única identidad es `op.id`, el
 * autoincrement de Dexie, que **arranca en 1 en cada instalación**. Sin un
 * prefijo por dispositivo, el primer pedido offline de dos teléfonos distintos
 * comparte la clave `op_1`, y `crear_pedido_idempotente` (mig 071) —que busca
 * `offline_id` en TODA la tabla `pedidos`— le devuelve al segundo el pedido del
 * primero como si fuera suyo.
 */
const CLAVE_INSTALACION = 'distribuidora:instalacion-id'
let idInstalacionEnMemoria: string | null = null

export function idDeInstalacion(): string {
  if (idInstalacionEnMemoria) return idInstalacionEnMemoria

  try {
    const guardado = localStorage.getItem(CLAVE_INSTALACION)
    if (guardado) {
      idInstalacionEnMemoria = guardado
      return guardado
    }
  } catch {
    // Safari en modo privado tira al leer storage. Se sigue con uno nuevo, que
    // al menos queda estable en memoria mientras dure la sesión — que es la
    // ventana en la que importa (los reintentos de una misma operación).
  }

  const nuevo = nuevoRequestId()
  try {
    localStorage.setItem(CLAVE_INSTALACION, nuevo)
  } catch {
    // Idem: sin persistencia, el valor en memoria alcanza para esta sesión.
  }
  idInstalacionEnMemoria = nuevo
  return nuevo
}
