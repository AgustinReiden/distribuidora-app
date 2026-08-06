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

export interface ResumenCondicion {
  /** En cuántas condiciones está el producto. */
  cantidadCondiciones: number
  /** El precio mayorista más bajo que puede alcanzar. */
  precioDesde: number
  /** Cantidad mínima de la escala que da ese precio. */
  cantidadDesde: number
}

/**
 * productoId → resumen. Solo entran los grupos y escalas activos, con el mismo
 * criterio que `fetchPricingMap`: una condición desactivada no aplica precio,
 * así que mostrarla en la lista sería mentir.
 */
export function resumenCondicionesPorProducto(
  grupos: GrupoPrecioConDetalles[],
): Map<string, ResumenCondicion> {
  const acumulador = new Map<
    string,
    { condiciones: Set<string>; precioDesde: number; cantidadDesde: number }
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
        entrada = { condiciones: new Set<string>(), precioDesde: Infinity, cantidadDesde: 0 }
        acumulador.set(pid, entrada)
      }
      entrada.condiciones.add(String(grupo.id))

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
    salida.set(pid, {
      cantidadCondiciones: entrada.condiciones.size,
      precioDesde: entrada.precioDesde,
      cantidadDesde: entrada.cantidadDesde,
    })
  }
  return salida
}
