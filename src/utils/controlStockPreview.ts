/**
 * Preview de la carga de una planilla de control de stock (#1254).
 *
 * El conteo se aplica como DIFERENCIA contra el stock que traía la planilla
 * ("Stock Sistema"), sobre el stock de ahora: es lo mismo que hace la RPC
 * `aplicar_control_stock`. Pisar con el número contado devolvía lo vendido
 * entre el conteo y la carga (planilla 12, se cuentan 10, se venden 3: pisar
 * dejaba 10 con 7 en la góndola). Lo que se movió entre la DESCARGA y el
 * conteo, en cambio, queda adentro de la diferencia: por eso se marca cada
 * producto cuyo stock cambió desde la descarga, para que se vea antes de
 * aplicar.
 *
 * El stock "de ahora" es el de la pantalla; la RPC vuelve a leerlo bloqueado y
 * es la que decide (un conteo que dejaría el stock negativo vuelve en
 * `rechazados`).
 */
import type { ControlStockRow } from './excel'

export interface ProductoControlStock {
  id: string | number
  codigo?: string | null
  nombre?: string | null
  stock: number
}

export interface ItemControlStock<P> {
  producto: P
  stockPlanilla: number
  stockReal: number
  /** contado − planilla: lo que se aplica. */
  diferencia: number
  stockActual: number
  stockNuevo: number
  /** El stock cambió desde la descarga: se aplica la diferencia, no el número contado. */
  movido: boolean
  /** Con lo que se movió después, quedaría negativo: la RPC no lo aplica. */
  quedaNegativo: boolean
}

export interface PreviewControlStock<P> {
  /** Productos con diferencia ≠ 0. */
  cambios: ItemControlStock<P>[]
  /** Productos contados que coinciden con la planilla: no hay nada que aplicar. */
  sinCambio: number
  sinAsociar: ControlStockRow[]
  /**
   * Productos que aparecen en más de una fila. Con la diferencia, cada fila se
   * aplicaría por separado: no se aplica nada hasta corregir la planilla.
   */
  repetidos: { producto: P; filas: number }[]
}

/** El producto de una fila: primero por código, después por nombre exacto. */
export function buscarProductoControlStock<P extends ProductoControlStock>(
  row: ControlStockRow,
  productos: P[],
): P | undefined {
  if (row.codigo) {
    const porCodigo = productos.find(p => (p.codigo || '').trim() === row.codigo)
    if (porCodigo) return porCodigo
  }
  if (row.nombre) {
    const n = row.nombre.trim().toLowerCase()
    return productos.find(p => (p.nombre || '').trim().toLowerCase() === n)
  }
  return undefined
}

export function armarPreviewControlStock<P extends ProductoControlStock>(
  filas: ControlStockRow[],
  productos: P[],
): PreviewControlStock<P> {
  const porProducto = new Map<string, { producto: P; filas: ControlStockRow[] }>()
  const sinAsociar: ControlStockRow[] = []
  for (const row of filas) {
    const producto = buscarProductoControlStock(row, productos)
    if (!producto) {
      sinAsociar.push(row)
      continue
    }
    const clave = String(producto.id)
    const grupo = porProducto.get(clave)
    if (grupo) grupo.filas.push(row)
    else porProducto.set(clave, { producto, filas: [row] })
  }

  const cambios: ItemControlStock<P>[] = []
  const repetidos: { producto: P; filas: number }[] = []
  let sinCambio = 0
  for (const { producto, filas: suyas } of porProducto.values()) {
    if (suyas.length > 1) {
      repetidos.push({ producto, filas: suyas.length })
      continue
    }
    const { stockReal, stockPlanilla } = suyas[0]
    const diferencia = stockReal - stockPlanilla
    if (diferencia === 0) {
      sinCambio++
      continue
    }
    const stockActual = producto.stock
    const stockNuevo = stockActual + diferencia
    cambios.push({
      producto,
      stockPlanilla,
      stockReal,
      diferencia,
      stockActual,
      stockNuevo,
      movido: stockActual !== stockPlanilla,
      quedaNegativo: stockNuevo < 0,
    })
  }
  return { cambios, sinCambio, sinAsociar, repetidos }
}
