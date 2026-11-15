/**
 * FRV-1 / FRV-2 (#1559): lo que hace falta para PRECIAR un pedido antes de confirmarlo.
 *
 * El precio de una línea sale de varias consultas: las promos, las escalas mayoristas
 * (el mapa de precios), los mínimos de venta y los combos. Si una no cargó, la cuenta no
 * falla: sale con lo que haya. Doce unidades con una escala de $90 salían a $100 de lista
 * con la consulta de escalas caída, y el server lo acepta (el techo es la lista de hoy).
 * Mismo defecto que VTA-2 (#1543) en la edición, ahora en el alta y en el cambio de cliente.
 *
 * Esto es lógica pura: dice qué consultas faltan y por qué; la pantalla bloquea Confirmar y
 * muestra el motivo con «Reintentar».
 */

/** Una consulta de la que depende el precio, tal como la dejó react-query. */
export interface EntradaDatoDePrecio {
  /** Cómo se llama para el usuario: «las escalas mayoristas». */
  nombre: string
  /** Hay un dato (cargado alguna vez para esta clave, o de la caché). */
  hayDato: boolean
  /** Está pidiéndose por primera vez. */
  cargando: boolean
  /** Falló. */
  fallo: boolean
  /** Sin dato y sin pedirse porque no hay señal (react-query la deja pausada, no en loading). */
  sinSenal: boolean
}

export interface DatosDePrecio {
  /** Las que todavía se están pidiendo. */
  cargando: string[]
  /** Las que fallaron. */
  fallaron: string[]
  /** Las que no se pidieron por falta de señal. */
  sinSenal: string[]
}

/** Lo que de una consulta de react-query hace falta para armar su entrada. */
export interface ConsultaParaEntrada {
  data?: unknown
  isLoading?: boolean
  isError?: boolean
  isPaused?: boolean
}

/**
 * La entrada de una consulta de react-query. `fallaConDato`: un error cuenta aunque haya un
 * dato viejo (las promos, como VTA-2). Para el resto, con un dato de hace unos minutos la
 * cuenta sigue siendo la de la lista que vio el usuario, y sólo bloquea la falta de dato.
 */
export function entradaDeConsulta(nombre: string, q: ConsultaParaEntrada, fallaConDato = false): EntradaDatoDePrecio {
  const hayDato = q.data !== undefined && q.data !== null
  return {
    nombre,
    hayDato,
    cargando: q.isLoading === true,
    fallo: q.isError === true && (fallaConDato || !hayDato),
    sinSenal: !hayDato && q.isPaused === true,
  }
}

/** Resume qué falta. Una consulta con dato y sin error no figura en ninguna lista. */
export function resumirDatosDePrecio(entradas: readonly EntradaDatoDePrecio[]): DatosDePrecio {
  const resumen: DatosDePrecio = { cargando: [], fallaron: [], sinSenal: [] }
  for (const e of entradas) {
    if (e.fallo) resumen.fallaron.push(e.nombre)
    else if (e.cargando) resumen.cargando.push(e.nombre)
    else if (!e.hayDato) {
      if (e.sinSenal) resumen.sinSenal.push(e.nombre)
      else resumen.cargando.push(e.nombre)
    }
  }
  return resumen
}

function lista(nombres: readonly string[]): string {
  if (nombres.length <= 1) return nombres[0] ?? ''
  return `${nombres.slice(0, -1).join(', ')} y ${nombres[nombres.length - 1]}`
}

export interface OpcionesMotivo {
  /**
   * El alta sin señal se puede encolar: viaja con el precio que calculó el teléfono y el
   * server sólo valida piso y techo, no lo recalcula. Por eso no se bloquea por una consulta
   * que no se pudo pedir. La edición y el cambio de cliente son online.
   */
  bloqueaSinSenal: boolean
}

/**
 * El motivo por el que no se puede confirmar, o `null` si se puede. Una falla manda sobre una
 * carga en curso: lo que hay que hacer es reintentar.
 */
export function motivoDatosDePrecio(resumen: DatosDePrecio, { bloqueaSinSenal }: OpcionesMotivo): string | null {
  if (resumen.fallaron.length > 0) {
    return `No se pudieron cargar ${lista(resumen.fallaron)}, y sin eso el precio del pedido puede salir mal. Reintentá la carga antes de confirmar.`
  }
  if (resumen.cargando.length > 0) {
    return `Todavía se están cargando ${lista(resumen.cargando)}. Esperá un momento antes de confirmar.`
  }
  if (bloqueaSinSenal && resumen.sinSenal.length > 0) {
    return `Sin conexión: no se pudieron cargar ${lista(resumen.sinSenal)}. Reintentá cuando vuelva la señal.`
  }
  return null
}

/** ¿Se puede ofrecer «Reintentar»? Sólo si algo falló o quedó sin pedirse; una carga en curso se espera. */
export function sePuedeReintentarDatos(resumen: DatosDePrecio, { bloqueaSinSenal }: OpcionesMotivo): boolean {
  return resumen.fallaron.length > 0 || (bloqueaSinSenal && resumen.sinSenal.length > 0)
}
