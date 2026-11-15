/**
 * La actualización masiva de precios, en lotes y con las escalas mayoristas (#1561).
 *
 * CAT-6 · Todo iba en una llamada y una transacción: 30.000 productos se cortaban
 * contra el statement_timeout de 8 s de `authenticated`. Ahora se manda de a
 * `LOTE_PRECIOS_MASIVO` (en la base local, 500 tardan 1,7 s; el server rechaza
 * más de `TOPE_LOTE_SERVIDOR`).
 *
 * CAT-7 · Decisión del dueño (12/11): el aumento avisa cuántas escalas tienen los
 * productos elegidos y ofrece aplicarles el mismo porcentaje. Una escala es de una
 * condición (grupo de precio), no de un producto: su precio vale para todos los
 * productos de la condición. Por eso se ofrece sólo la de una condición con TODOS
 * sus productos elegidos (la de una condición elegida a medias se cuenta aparte,
 * para avisar que no se toca), y viaja en el mismo lote que todos esos productos:
 * el server la cambia sólo si los cambió a todos en esa misma llamada.
 */
import { MULTIPLO_REDONDEO_PRECIO, redondearPrecio } from './precios'

/** Productos por llamada. */
export const LOTE_PRECIOS_MASIVO = 500
/** Lo que acepta `actualizar_precios_masivo` en una llamada. */
export const TOPE_LOTE_SERVIDOR = 1000

export interface ItemPrecioMasivo {
  producto_id: string
  precio_neto: number | null
  imp_internos: number | null
  precio_final: number | null
}

/** Lo que viaja en `p_escalas`. */
export interface EscalaPrecioMasivo {
  escala_id: string
  precio_unitario: number
  minimos: Array<{ producto_id: string; precio_unitario_override: number }>
}

/** Una escala con lo que hace falta para armar los lotes y para avisar. */
export interface EscalaDeCondicion {
  escala: EscalaPrecioMasivo
  grupo: string
  cantidadMinima: number
  precioAnterior: number
  /** Todos los productos de su condición. */
  productoIds: string[]
}

/** Lo mínimo de una condición mayorista (`GrupoPrecioConDetalles`). */
export interface CondicionParaMasivo {
  id: string | number
  nombre: string
  productos: Array<{ producto_id: string | number }>
  escalas: Array<{ id: string | number; cantidad_minima: number; precio_unitario: number }>
  escalaMinimos?: Record<string, Array<{ producto_id: string | number; precio_unitario_override?: number | null }>>
}

export interface EscalasDeSeleccion {
  /** Las de condiciones con todos sus productos elegidos, con su precio nuevo. */
  aplicables: EscalaDeCondicion[]
  /** Escalas de condiciones con algunos productos elegidos y otros no: no se tocan. */
  parciales: number
  /** Las condiciones de esas escalas, para nombrarlas. */
  condicionesParciales: string[]
}

/**
 * Las escalas que tocan los productos elegidos, con el precio nuevo (el mismo
 * porcentaje y el mismo redondeo que la lista, y los precios por producto igual).
 */
export function escalasDeSeleccion(
  condiciones: CondicionParaMasivo[],
  seleccionados: ReadonlySet<string>,
  porcentajePct: number,
  multiplo = MULTIPLO_REDONDEO_PRECIO,
): EscalasDeSeleccion {
  const factor = 1 + porcentajePct / 100
  const aplicables: EscalaDeCondicion[] = []
  let parciales = 0
  const condicionesParciales: string[] = []
  for (const c of condiciones) {
    if (c.escalas.length === 0) continue
    const ids = c.productos.map(p => String(p.producto_id))
    const elegidos = ids.filter(id => seleccionados.has(id)).length
    if (elegidos === 0) continue
    if (elegidos < ids.length) {
      parciales += c.escalas.length
      condicionesParciales.push(c.nombre)
      continue
    }
    for (const e of c.escalas) {
      const precio = Number(e.precio_unitario)
      const minimos = (c.escalaMinimos?.[String(e.id)] ?? [])
        .filter(m => m.precio_unitario_override != null && Number(m.precio_unitario_override) > 0)
        .map(m => {
          const anterior = Number(m.precio_unitario_override)
          return { producto_id: String(m.producto_id), precio_unitario_override: redondearPrecio(anterior, anterior * factor, multiplo) }
        })
      aplicables.push({
        escala: { escala_id: String(e.id), precio_unitario: redondearPrecio(precio, precio * factor, multiplo), minimos },
        grupo: c.nombre,
        cantidadMinima: e.cantidad_minima,
        precioAnterior: precio,
        productoIds: ids,
      })
    }
  }
  return { aplicables, parciales, condicionesParciales }
}

export interface LotePreciosMasivo {
  items: ItemPrecioMasivo[]
  escalas: EscalaPrecioMasivo[]
}

export interface LotesPreciosMasivo {
  lotes: LotePreciosMasivo[]
  /** Escalas de una condición tan grande que no entra en un lote: no se mandan. */
  descartadas: EscalaDeCondicion[]
}

/**
 * Arma los lotes. Los productos que comparten una escala (los de una condición, y
 * los de dos condiciones que comparten un producto) van juntos, con sus escalas. Un
 * bloque así que no entra en el lote que se está llenando abre uno nuevo; si pasa el
 * tope del server va solo y sin sus escalas (se devuelven en `descartadas`).
 */
export function armarLotesPreciosMasivo(
  items: ItemPrecioMasivo[],
  escalas: EscalaDeCondicion[],
  tamanio = LOTE_PRECIOS_MASIVO,
  tope = TOPE_LOTE_SERVIDOR,
): LotesPreciosMasivo {
  const enLote = new Set(items.map(i => String(i.producto_id)))
  // Una escala viaja sólo si todos sus productos están en la lista (si no, el server la rechaza).
  const validas = escalas.filter(e => e.productoIds.every(id => enLote.has(id)))

  // Unión de productos por escala.
  const padre = new Map<string, string>()
  const raiz = (x: string): string => {
    let r = x
    while (padre.get(r) !== r) r = padre.get(r) as string
    let y = x
    while (padre.get(y) !== r) { const s = padre.get(y) as string; padre.set(y, r); y = s }
    return r
  }
  for (const id of enLote) padre.set(id, id)
  for (const e of validas) {
    const [primero, ...resto] = e.productoIds
    if (primero === undefined) continue
    for (const id of resto) {
      const a = raiz(primero), b = raiz(id)
      if (a !== b) padre.set(b, a)
    }
  }

  const bloques = new Map<string, LotePreciosMasivo>()
  for (const it of items) {
    const r = raiz(String(it.producto_id))
    const b = bloques.get(r) ?? { items: [], escalas: [] }
    b.items.push(it)
    bloques.set(r, b)
  }
  const descartadas: EscalaDeCondicion[] = []
  for (const e of validas) {
    const r = raiz(e.productoIds[0] ?? '')
    const b = bloques.get(r)
    if (!b) continue
    if (b.items.length > tope) descartadas.push(e)
    else b.escalas.push(e.escala)
  }

  const lotes: LotePreciosMasivo[] = []
  let actual: LotePreciosMasivo = { items: [], escalas: [] }
  const cerrar = () => { if (actual.items.length > 0 || actual.escalas.length > 0) lotes.push(actual); actual = { items: [], escalas: [] } }
  for (const b of bloques.values()) {
    if (b.items.length > tope) {
      // Una condición más grande que el tope: va partida y sin sus escalas.
      cerrar()
      for (let i = 0; i < b.items.length; i += tamanio) lotes.push({ items: b.items.slice(i, i + tamanio), escalas: [] })
      continue
    }
    if (b.items.length > 1 && actual.items.length + b.items.length > tamanio) cerrar()
    actual.items.push(...b.items)
    actual.escalas.push(...b.escalas)
    if (actual.items.length >= tamanio) cerrar()
  }
  cerrar()
  return { lotes, descartadas }
}

/**
 * Si un error de `actualizar_precios_masivo` es de una escala y no de un producto. El server
 * (mig 494) los escribe «Escala ID n: …»; los de producto, «Producto ID n …», «Error en
 * producto ID n: …» o con el nombre del trabado. Una escala que no se cambió no deja ningún
 * producto sin aumentar.
 */
export function esErrorDeEscala(error: string): boolean {
  return error.startsWith('Escala ID ')
}

/** Lo que trae el error de una corrida que no entró entera (`ErrorPreciosMasivo`). */
export interface ErrorDeCorridaMasiva {
  trabados?: Array<{ producto_id: string | number }>
  /** Los de las tandas que no se llegaron a mandar: no cambiaron. */
  pendientes?: string[]
  /** Los de la tanda que falló sin respuesta: pueden haber cambiado o no. */
  sinConfirmar?: string[]
  /** Los productos que sí cambiaron. */
  actualizados?: number
}

export interface SalidaDeCorridaMasiva {
  /** Los productos que quedan seleccionados, o null si nada cambió y la selección queda como estaba. */
  seleccionar: string[] | null
  nivel: 'warning' | 'error'
}

/**
 * Qué queda seleccionado después de una corrida que falló (#1561). Si algo pudo haber
 * cambiado, quedan sólo los que se pueden volver a mandar sin aumentarlos dos veces: los
 * trabados y los de las tandas que no se mandaron. Los que cambiaron y los que no se pudieron
 * confirmar salen de la selección, para que otro «Aplicar» no les vuelva a sumar el
 * porcentaje. Sólo si no cambió nada queda la selección entera, con el error.
 */
export function seleccionTrasErrorMasivo(error: ErrorDeCorridaMasiva | null | undefined): SalidaDeCorridaMasiva {
  const reintentar = [
    ...(error?.trabados ?? []).map(t => String(t.producto_id)),
    ...(error?.pendientes ?? []),
  ]
  const pudoCambiar = (error?.actualizados ?? 0) > 0 || (error?.sinConfirmar?.length ?? 0) > 0 || reintentar.length > 0
  return pudoCambiar ? { seleccionar: reintentar, nivel: 'warning' } : { seleccionar: null, nivel: 'error' }
}
