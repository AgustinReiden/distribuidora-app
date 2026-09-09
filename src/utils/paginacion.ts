/**
 * Traer TODAS las filas de una consulta, sin depender del volumen de datos.
 *
 * EL PROBLEMA QUE RESUELVE
 * ------------------------
 * PostgREST corta las respuestas en 1.000 filas y devuelve un 200. No hay
 * error, no hay aviso: la consulta parece haber traído todo. Una pantalla que
 * suma esas filas muestra un número mal y nadie se entera hasta que alguien lo
 * cruza contra otra fuente.
 *
 * Eso ya pasó tres veces en este repo: en "Ventas por cliente" (por eso se
 * movió a un RPC, mig 197), en la valuación de inventario (mig 131) y en
 * Cuentas por Cobrar, que llegó a leer el 19% de los pagos.
 *
 * UNA CONSULTA SIN `limit` NO DICE "TRAEME TODO"
 * ----------------------------------------------
 * Dice "traeme lo que entre y no me avises". Por eso el criterio acá no es
 * "hoy son pocas filas" —eso describe los datos, no el código, y cambia solo
 * con el tiempo— sino que la consulta sea correcta para cualquier volumen.
 *
 * HACE FALTA UN ORDEN ESTABLE
 * ---------------------------
 * Paginar con `range()` sobre una consulta SIN `order()` puede repetir filas y
 * saltear otras: sin ORDER BY, Postgres no garantiza el mismo orden entre dos
 * requests. Toda consulta que se pagine con esto tiene que traer un `.order()`
 * por una columna única, o un desempate por `id`. No se puede verificar desde
 * acá, así que es responsabilidad del que llama.
 *
 * CUÁNDO NO USAR ESTO
 * -------------------
 * Cuando lo que se necesita es una agregación y no las filas. Bajar 5.000
 * pedidos al navegador para sumarlos es peor que un RPC que devuelva la suma,
 * como hacen `reporte_ventas_por_cliente` (mig 197) y
 * `reporte_valuacion_inventario` (mig 131). Esto es la salida buena y barata,
 * no la mejor.
 */

/** El tope de PostgREST: pedir de a más no sirve, corta igual. */
export const PAGINA_SUPABASE = 1000

/**
 * Freno de mano. No es un límite de negocio: es para que un filtro mal armado
 * no se traiga la base entera de a 1.000 y cuelgue el navegador. Da margen
 * para muchos años — hoy la tabla más grande que se pagina son ~5.500 pedidos.
 */
export const TOPE_SEGURIDAD = 100_000

/** Lo mínimo que se necesita de un builder de supabase-js. */
interface ConRange<T> {
  range(desde: number, hasta: number): PromiseLike<{ data: T[] | null; error: { message: string } | null }>
}

export interface OpcionesPaginado {
  /** Filas por request. Sólo se toca en los tests. */
  pagina?: number
  /** Freno de mano; superarlo TIRA, no devuelve una lista corta. */
  tope?: number
  /** Qué se estaba trayendo, para que el error del tope diga algo útil. */
  etiqueta?: string
}

/**
 * @param hacerQuery - Devuelve un builder NUEVO en cada llamada. Tiene que ser
 *   una factory y no un builder ya armado: los de supabase-js son de un solo
 *   uso, se consumen al await-earlos.
 *
 * @example
 *   const pedidos = await traerTodo<PedidoDB>(
 *     () => supabase.from('pedidos').select('*').order('id'),
 *     { etiqueta: 'pedidos' },
 *   )
 */
export async function traerTodo<T>(
  hacerQuery: () => ConRange<T>,
  opciones: OpcionesPaginado = {},
): Promise<T[]> {
  const pagina = opciones.pagina ?? PAGINA_SUPABASE
  const tope = opciones.tope ?? TOPE_SEGURIDAD
  const etiqueta = opciones.etiqueta ?? 'la consulta'

  const filas: T[] = []

  for (let desde = 0; desde < tope; desde += pagina) {
    const { data, error } = await hacerQuery().range(desde, desde + pagina - 1)
    // El error lleva la etiqueta: un "Database error" pelado no dice cuál de
    // las siete consultas de un export fue la que falló.
    if (error) throw new Error(`Error cargando ${etiqueta}: ${error.message}`)

    const lote = data ?? []
    filas.push(...lote)

    // Una página incompleta es la señal de que no hay más. Con un múltiplo
    // exacto del tamaño de página hace falta una request más, que vuelve
    // vacía: es el precio de no pedir un `count` extra en cada llamada.
    if (lote.length < pagina) return filas
  }

  // Devolver lo que se juntó sería el mismo bug que esto viene a arreglar,
  // sólo que con otro número. Mejor romper y que alguien lo mire.
  throw new Error(
    `Se superó el tope de ${tope} filas trayendo ${etiqueta}. ` +
    `Es un freno de seguridad: revisá el filtro de la consulta, o pasá a un RPC que agregue en la base.`,
  )
}

/** Lo mínimo que se necesita de una consulta de conteo (`head: true`). */
interface ConCount {
  count: number | null
  error: { message: string } | null
}

export interface OpcionesVerificado extends OpcionesPaginado {
  /**
   * Pide el `count` exacto a la base. TIENE que mirar el mismo universo que
   * `hacerQuery` —los mismos filtros, la misma tabla—: si el conteo y las
   * páginas no ven lo mismo, la comparación no prueba nada. Por eso conviene
   * armar los filtros en una sola función y usarla para las dos cosas.
   */
  contar: () => PromiseLike<ConCount>
}

/**
 * Como `traerTodo`, pero además DEMUESTRA que trajo todo.
 *
 * Paginar arregla el truncado mientras nada falle. Para un archivo que se
 * guarda —un backup, un export— eso no alcanza: si alguna página vuelve corta,
 * el resultado sigue siendo un archivo con cara de completo, y de eso nadie se
 * entera hasta el día que hay que usarlo. El backup llegó a guardar 1.000 de
 * 5.555 pedidos así (#523).
 *
 * Entonces se pide el `count` exacto y se compara. Si no coinciden, tira: el
 * que llama NO tiene que generar el archivo.
 *
 * Nota sobre la carrera: entre el conteo y la última página alguien puede
 * insertar una fila, y entonces esto falla aunque no haya ningún bug. Es a
 * propósito. Un backup que se rehace es barato; uno incompleto que nadie
 * cuestionó, no.
 */
export async function traerTodoVerificado<T>(
  hacerQuery: () => ConRange<T>,
  opciones: OpcionesVerificado,
): Promise<T[]> {
  const etiqueta = opciones.etiqueta ?? 'la consulta'

  const { count, error } = await opciones.contar()
  if (error) throw new Error(`No se pudo contar ${etiqueta}: ${error.message}`)

  const filas = await traerTodo<T>(hacerQuery, opciones)

  if (count != null && filas.length !== count) {
    throw new Error(
      `No se generó el archivo: ${etiqueta} quedó incompleto, ` +
      `se bajaron ${filas.length} de ${count} filas. ` +
      `Un archivo que dice estar completo y trae una parte es peor que ninguno, porque nadie lo revisa.`,
    )
  }

  return filas
}
