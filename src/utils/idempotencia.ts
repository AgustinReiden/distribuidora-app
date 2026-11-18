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
import { esFalloDeRed, esGatewayCaido } from './falloDeRed'

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
  /**
   * El cliente del pedido con el que se acuñó (L2, #1603). Un alta de otro
   * cliente no puede ser un duplicado de ésta, así que no la espera. Una clave
   * sin cliente (guardada antes de esto) toma el de su huella (`clienteDeLaHuella`);
   * si tampoco ahí lo tiene, se trata como si pudiera ser de cualquiera.
   */
  clienteId?: string
  /**
   * Cuándo salió o terminó (lo último) el último intento con esta clave, en ms
   * (M5, #1603). Mientras no pase `MARGEN_INTENTO_EN_VUELO_MS`, un «no entró» del
   * servidor no prueba nada: ver `verificacionConfiable`.
   */
  intentoEn?: number
}

/**
 * El cliente de un alta según su huella (`huellaDeAlta`): `[nuevoPedido, líneas]`.
 * Sirve para las claves guardadas antes de que la clave llevara su cliente (L2,
 * #1603): sin esto, una sola de ésas hacía esperar a las altas de TODOS los
 * clientes hasta resolverse o vencer (24 h). Si la huella no se puede leer, no
 * hay cliente: se sigue tratando como de cualquiera, que es lo seguro.
 */
export function clienteDeLaHuella(huella: string): string | undefined {
  try {
    const valor: unknown = JSON.parse(huella)
    const pedido = Array.isArray(valor) ? valor[0] : null
    const cliente = (pedido as { clienteId?: unknown } | null)?.clienteId
    if ((typeof cliente === 'string' && cliente !== '') || (typeof cliente === 'number' && Number.isFinite(cliente))) {
      return String(cliente)
    }
  } catch {
    // Una huella que no es JSON: no se puede decir de quién es.
  }
  return undefined
}

/**
 * Lo que identifica a ESTE pedido para su clave de alta: el formulario y las
 * líneas finales (con promos, regalos y combos ya resueltos). Un cambio en
 * cualquiera de las dos es otro pedido (ver `claveDeAlta`).
 */
export function huellaDeAlta(
  formulario: unknown,
  lineas: ReadonlyArray<{ productoId: unknown; cantidad: unknown; precioUnitario: unknown; esBonificacion?: unknown }>,
): string {
  return JSON.stringify([
    formulario,
    lineas.map(i => [i.productoId, i.cantidad, i.precioUnitario, i.esBonificacion ?? false]),
  ])
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
export function claveDeAlta(previa: ClaveDeAlta | null, huella: string, clienteId?: string): ClaveDeAlta {
  return previa && previa.huella === huella ? previa : { id: nuevoRequestId(), huella, clienteId }
}

/**
 * ¿Un alta para `clienteId` puede ser el mismo pedido que esta clave? Sólo si es
 * del mismo cliente (L2, #1603). Sin cliente de un lado o del otro, sí: no se
 * puede descartar.
 */
export function puedeSerElMismoPedido(clave: ClaveDeAlta, clienteId: string | undefined): boolean {
  return clave.clienteId == null || clienteId == null || clave.clienteId === clienteId
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

/**
 * `previa` es la clave del formulario; `apartadas`, las que quedaron en duda de
 * altas que se cerraron sin saber si entraron (o que se recuperaron al recargar),
 * a lo sumo una por cliente (L2, #1603):
 * - mismo contenido que una de ellas → se reusa esa clave;
 * - una en duda que puede ser este pedido (`puedeSerElMismoPedido`) → primero se
 *   le pregunta al servidor por ella;
 * - si no → clave nueva. La en duda de otro cliente no se pierde: el llamador la
 *   aparta (`apartadasTrasEnviar`) y se sigue resolviendo cuando vuelve la señal.
 */
export function pasoDeAlta(
  previa: ClaveDeAlta | null,
  huella: string,
  clienteId?: string,
  apartadas: readonly ClaveDeAlta[] = [],
): PasoDeAlta {
  const candidatas = [previa, ...apartadas].filter((c): c is ClaveDeAlta => c != null)
  const igual = candidatas.find(c => c.huella === huella)
  if (igual) return { paso: 'enviar', clave: igual }
  const enDuda = candidatas.find(c => c.enDuda && puedeSerElMismoPedido(c, clienteId))
  if (enDuda) return { paso: 'verificar', anterior: enDuda }
  return { paso: 'enviar', clave: claveDeAlta(null, huella, clienteId) }
}

/**
 * Las claves apartadas después de que el formulario pasa a usar `usada` (o se
 * limpia, sin `usada`): sale la que se usa, y la del formulario, si quedó en duda
 * y es otra, se aparta en vez de perderse.
 */
export function apartadasTrasEnviar(
  previa: ClaveDeAlta | null,
  apartadas: readonly ClaveDeAlta[],
  usada?: ClaveDeAlta | null,
): ClaveDeAlta[] {
  const resto = apartadas.filter(a => a.id !== usada?.id)
  if (previa?.enDuda && previa.id !== usada?.id && !resto.some(a => a.id === previa.id)) {
    resto.push(previa)
  }
  return resto
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
export function decidirTrasVerificar(
  verificacion: VerificacionDeAlta,
  huella: string,
  clienteId?: string,
): DecisionTrasVerificar {
  switch (verificacion.resultado) {
    case 'entro':
      return { paso: 'ya_entro', pedidoId: verificacion.pedidoId }
    case 'no_entro':
      return { paso: 'enviar', clave: { id: nuevoRequestId(), huella, clienteId } }
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

/**
 * Cuánto después del último intento con una clave un «no entró» del servidor
 * empieza a valer (M5, #1603). Un intento que el teléfono dio por perdido (sin
 * señal, plazo) puede seguir corriendo en el servidor: la consulta por
 * `offline_id` no ve una fila que todavía no hizo COMMIT, y contesta «no entró»
 * de un pedido que está por entrar. Con eso se olvidaba la clave y la próxima
 * alta del mismo cliente acuñaba otra: dos pedidos. La base corta una sentencia
 * a los 8 s (`statement_timeout` de `authenticated`, y el alta es una sola
 * llamada); medio minuto cubre además la espera de una conexión en PostgREST y
 * el viaje.
 */
export const MARGEN_INTENTO_EN_VUELO_MS = 30_000

/**
 * Plazo del alta directa (H3 de la revisión de B12a). Con señal que no pasa datos
 * el `fetch` queda colgado sin fallar, y sin plazo la oferta de la cola (D56) no
 * aparecía. 20 s, como cada intento del replay (`PLAZO_INTENTO_REPLAY_MS`): sobra
 * para una respuesta real, porque la base corta el alta a los 8 s.
 *
 * Relación con `MARGEN_INTENTO_EN_VUELO_MS`: el corte vuelve a fechar `intentoEn`
 * (la clave queda en duda en ese momento), así que el margen de 30 s corre DESPUÉS
 * del corte, no desde el envío. Un intento cortado a los 20 s que todavía estuviera
 * en el servidor terminó (8 s de sentencia más la espera de conexión) mucho antes
 * de que un «no entró» vuelva a valer, a los 50 s del envío.
 */
export const PLAZO_ALTA_DIRECTA_MS = 20_000

/**
 * La respuesta del servidor sobre `clave`, tal como se la puede creer: un «no
 * entró» dentro del margen del último intento vale como «sin respuesta» (no se
 * olvida la clave ni se acuña otra). «Entró» vale siempre.
 */
export function verificacionConfiable(
  verificacion: VerificacionDeAlta,
  clave: Pick<ClaveDeAlta, 'intentoEn'>,
  ahora: number = Date.now(),
): VerificacionDeAlta {
  if (verificacion.resultado !== 'no_entro' || clave.intentoEn == null) return verificacion
  // H6 (revisión de B12a): una diferencia negativa es un reloj que volvió atrás
  // (lo corrigió la red), no un intento en vuelo: vale como margen vencido. Sin
  // esto, la clave quedaba «sin respuesta» hasta que el reloj la alcanzaba.
  const transcurrido = ahora - clave.intentoEn
  return transcurrido >= 0 && transcurrido < MARGEN_INTENTO_EN_VUELO_MS ? { resultado: 'sin_respuesta' } : verificacion
}

/**
 * La huella con la que se compara la oferta de la cola (H4 de la revisión de
 * B12a): la del alta sin el estado ni el monto del cobro, que la cola descarta (el
 * pedido encolado nunca declara cobro). Si quien carga pasa el pago a «pendiente»
 * después del fallo, sigue siendo el mismo pedido y la oferta no se va. La clave
 * del alta se sigue acuñando con `huellaDeAlta` entera.
 */
export function huellaDeOfertaCola(
  formulario: Record<string, unknown> | object,
  lineas: Parameters<typeof huellaDeAlta>[1],
): string {
  return huellaDeAlta({ ...formulario, estadoPago: undefined, montoPagado: undefined }, lineas)
}

/**
 * D56 (decisión del dueño, 1563-b7 de #1563): ¿se ofrece guardar en la cola el
 * alta que acaba de fallar? Sí cuando falló por la red —la señal está pero no
 * pasa datos, con `navigator.onLine` en true— y su clave quedó en duda. No se
 * encola sola: la pantalla lo ofrece y decide quien carga.
 *
 * Se encola con la MISMA clave (`offline_id`), así que no duplica: si el intento
 * de recién sí había entrado, el replay recibe ese pedido de la rama idempotente
 * de `crear_pedido_idempotente` (que además toma un lock por la clave, así que
 * tampoco duplica si el intento todavía está corriendo) y `verificarRespuestaIdempotente`
 * comprueba que sea el mismo cliente y el mismo total. Un rechazo del servidor
 * no se ofrece: el pedido no entró y encolarlo lo haría rechazar de nuevo.
 */
export function ofrecerColaTrasFallo(error: unknown, clave: ClaveDeAlta | null): boolean {
  return clave?.enDuda === true && esFalloDeRed(error)
}

/** Lo que se le dice a quien carga cuando el alta en duda quedó en la cola (D56). */
export const MENSAJE_ALTA_EN_DUDA_ENCOLADA =
  'La señal no alcanzó para confirmar el pedido: quedó guardado en el teléfono y se manda solo cuando haya señal. ' +
  'Si el intento anterior sí había entrado, no se duplica: se reconoce por su clave. ' +
  'El cobro no se guarda con el pedido: cuando vuelva la señal, cargalo a mano desde la ficha del pedido.'

/** Lo mismo para un vale blanco, que no lleva cobro y lo precia el servidor. */
export const MENSAJE_VB_EN_DUDA_ENCOLADO =
  'La señal no alcanzó para confirmar el vale blanco: quedó guardado en el teléfono y se manda solo cuando haya señal. ' +
  'Si el intento anterior sí había entrado, no se duplica: se reconoce por su clave. ' +
  'El total a costo lo calcula el servidor al sincronizar.'

/** El aviso cuando el alta que quedó en duda antes de recargar sí había entrado. */
export function mensajeAltaRecuperada(pedidoId: string): string {
  return `El pedido #${pedidoId}, que quedó sin confirmar antes de que se cerrara la app, sí se guardó: ` +
    'no lo cargues de nuevo. Si tenía un cobro, registralo desde la ficha del pedido.'
}

/**
 * El aviso cuando se cerró el alta después de un error y el intento sí había
 * entrado (VTA-1, #1543): sin él, el pedido se cargaba de nuevo desde cero.
 */
export function mensajeAltaCerradaQueEntro(pedidoId: string): string {
  return `El pedido #${pedidoId} sí se guardó en el intento que mostró un error: no lo cargues de nuevo. ` +
    'Si tenía un cobro, registralo desde la ficha del pedido.'
}

/**
 * El aviso cuando no se pudo preguntar por la clave anterior. Sólo pasa con un
 * pedido del mismo cliente (L2, #1603): el de otro cliente sigue su camino.
 */
export const MENSAJE_ALTA_SIN_VERIFICAR =
  'No se pudo confirmar si el pedido anterior de este cliente quedó guardado, y como este es distinto no se ' +
  'cargó, para no duplicarlo. Esperá a tener señal y tocá Confirmar de nuevo: primero se fija si el anterior entró. ' +
  'Los pedidos de otros clientes se pueden cargar igual.'

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
