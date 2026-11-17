/**
 * Matching de productos entre sucursales (al aceptar un movimiento).
 *
 * Mismo criterio estricto que el escaneo de facturas (ModalCompra): match solo
 * por código exacto o nombre exacto (normalizado). Cualquier coincidencia
 * parcial queda fuera para que el usuario decida.
 *
 * Un producto desactivado en el destino no se sugiere solo (#1558, decisión del
 * dueño D7): se lista aparte y, si se elige, se confirma que se lo reactiva al
 * recibir. El server reactiva sólo con esa marca (`reactivar`) y, sin ella,
 * rechaza el envío.
 */
import type { ProductoDB } from '../types'
import type { ResolucionItem } from '../hooks/queries'

export function normalizarTexto(s: string | null | undefined): string {
  return (s ?? '').trim().toLowerCase().replace(/\s+/g, ' ')
}

/** Desactivado en esta sucursal (baja lógica). Sin el dato, cuenta como activo. */
export function estaDesactivado(p: Pick<ProductoDB, 'activo'>): boolean {
  return p.activo === false
}

export function sugerirMatchProducto(
  ref: { codigo?: string | null; nombre?: string | null },
  productos: ProductoDB[],
): ProductoDB | null {
  const activos = productos.filter(p => !estaDesactivado(p))
  const cod = normalizarTexto(ref.codigo)
  if (cod) {
    const porCodigo = activos.find(p => normalizarTexto(p.codigo) === cod)
    if (porCodigo) return porCodigo
  }
  const nom = normalizarTexto(ref.nombre)
  if (nom) {
    const porNombre = activos.find(p => normalizarTexto(p.nombre) === nom)
    if (porNombre) return porNombre
  }
  return null
}

/** Los productos del selector: primero los activos y aparte los desactivados. */
export function separarPorActivo<T extends Pick<ProductoDB, 'activo'>>(productos: T[]): { activos: T[]; desactivados: T[] } {
  const activos: T[] = []
  const desactivados: T[] = []
  for (const p of productos) (estaDesactivado(p) ? desactivados : activos).push(p)
  return { activos, desactivados }
}

/**
 * Lo que viaja a `aceptar_movimiento_sucursal`. `seleccion` es el producto
 * elegido por item (su id, o `nuevo` para crear uno); `reactivar`, los items
 * cuyo producto desactivado se confirmó reactivar.
 */
export function armarResoluciones(
  itemIds: number[],
  seleccion: Record<number, string>,
  reactivar: Record<number, boolean>,
  nuevo: string,
): ResolucionItem[] {
  return itemIds.map(id => {
    const v = seleccion[id] ?? nuevo
    if (v === nuevo) return { item_id: id, accion: 'crear_nuevo' }
    const r: ResolucionItem = { item_id: id, accion: 'match_existente', producto_destino_id: Number(v) }
    if (reactivar[id]) r.reactivar = true
    return r
  })
}

/** El aviso al aceptar, con los productos que se reactivaron. */
export function avisoAceptacion(reactivados: Array<number | string>, productos: Pick<ProductoDB, 'id' | 'nombre'>[]): string {
  const base = 'Movimiento aceptado. Stock ingresado en esta sucursal.'
  if (reactivados.length === 0) return base
  const nombres = reactivados.map(id => productos.find(p => String(p.id) === String(id))?.nombre ?? `#${id}`)
  return `${base} ${nombres.length === 1 ? 'Se reactivó' : 'Se reactivaron'}: ${nombres.join(', ')}.`
}
