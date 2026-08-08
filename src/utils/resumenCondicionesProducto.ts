/**
 * Resumen por producto de sus condiciones mayoristas, para la lista.
 *
 * En la lista de productos no se veía cuáles tienen precio por cantidad — son
 * 75 de 240 — así que había que abrir la ficha de a uno para saber si un sabor
 * ya estaba configurado o quedaba pendiente.
 *
 * Se deriva de los grupos que ya están en cache (`useGruposPrecioQuery`), sin
 * pedir nada nuevo a la base.
 */
import type { GrupoPrecioConDetalles } from '../types'

export interface CondicionDelProducto {
  grupoId: string
  nombre: string
  /** Los OTROS productos que suman en esta condición (sin el propio). */
  combinaCon: string[]
}

export interface ResumenCondicion {
  /** En cuántas condiciones está el producto. */
  cantidadCondiciones: number
  /** El precio mayorista más bajo que puede alcanzar. */
  precioDesde: number
  /** Cantidad mínima de la escala que da ese precio. */
  cantidadDesde: number
  /** Con qué condiciones y con qué sabores suma, para verlo sin abrir la ficha. */
  condiciones: CondicionDelProducto[]
  /** Cuántos otros productos suman con este, contando todas sus condiciones. */
  totalCombinaCon: number
}

/**
 * productoId → resumen. Solo entran los grupos y escalas activos, con el mismo
 * criterio que `fetchPricingMap`: una condición desactivada no aplica precio,
 * así que mostrarla en la lista sería mentir.
 */
export function resumenCondicionesPorProducto(
  grupos: GrupoPrecioConDetalles[],
  /** productoId → nombre. Sin esto, `combinaCon` viene vacío. */
  nombresProductos?: Map<string, string>,
): Map<string, ResumenCondicion> {
  const acumulador = new Map<
    string,
    { condiciones: CondicionDelProducto[]; precioDesde: number; cantidadDesde: number }
  >()

  for (const grupo of grupos) {
    if (grupo.activo === false) continue

    const escalasActivas = grupo.escalas.filter(e => e.activo !== false)
    if (escalasActivas.length === 0) continue

    const minimosPorEscala = grupo.escalaMinimos ?? {}

    for (const fila of grupo.productos) {
      const pid = String(fila.producto_id)

      let entrada = acumulador.get(pid)
      if (!entrada) {
        entrada = { condiciones: [], precioDesde: Infinity, cantidadDesde: 0 }
        acumulador.set(pid, entrada)
      }
      if (!entrada.condiciones.some(c => c.grupoId === String(grupo.id))) {
        entrada.condiciones.push({
          grupoId: String(grupo.id),
          nombre: grupo.nombre,
          // Los otros sabores del fardo: es lo que había que ir a buscar al
          // panel de condiciones para saber con qué suma este producto.
          combinaCon: grupo.productos
            .map(p => String(p.producto_id))
            .filter(otro => otro !== pid)
            .map(otro => nombresProductos?.get(otro) ?? `#${otro}`),
        })
      }

      for (const escala of escalasActivas) {
        // El override de la escala manda sobre el precio del grupo: es lo que
        // este producto termina costando cuando la escala aplica.
        const override = (minimosPorEscala[String(escala.id)] ?? [])
          .find(m => String(m.producto_id) === pid)?.precio_unitario_override
        const precio = override != null && Number(override) > 0
          ? Number(override)
          : Number(escala.precio_unitario)

        if (!(precio > 0) || precio >= entrada.precioDesde) continue
        entrada.precioDesde = precio
        entrada.cantidadDesde = Number(escala.cantidad_minima)
      }
    }
  }

  const salida = new Map<string, ResumenCondicion>()
  for (const [pid, entrada] of acumulador) {
    // Sin ninguna escala con precio usable no hay nada que mostrar.
    if (!Number.isFinite(entrada.precioDesde)) continue

    // Un sabor puede repetirse entre condiciones; se cuenta una sola vez.
    const otros = new Set(entrada.condiciones.flatMap(c => c.combinaCon))

    salida.set(pid, {
      cantidadCondiciones: entrada.condiciones.length,
      precioDesde: entrada.precioDesde,
      cantidadDesde: entrada.cantidadDesde,
      condiciones: entrada.condiciones,
      totalCombinaCon: otros.size,
    })
  }
  return salida
}
