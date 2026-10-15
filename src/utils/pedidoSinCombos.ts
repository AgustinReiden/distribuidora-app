/**
 * "Sincronizar sin los combos" (#1191): el payload de un alta encolada con sus
 * líneas de combo pasadas a precio sin combo.
 *
 * Cuando el replay offline recibe el rechazo `combo_fuera_de_regla` (el combo
 * llegó a su tope, se apagó o cambió mientras el pedido esperaba en el
 * teléfono), el preventista puede decidir mandarlo sin los combos. El server no
 * dice qué combo falló, así que se sacan TODOS: el texto del botón lo avisa.
 *
 * Cada línea de combo queda como una venta suelta a su `precioSinCombo` —lo
 * que la unidad costaba sin el combo, el mismo precio que el server ya validó
 * como referencia—, y el total se recalcula: el cliente paga más que con el
 * combo. Las líneas sueltas no se tocan: sin las exclusiones de un combo
 * excluyente su escala sólo puede mejorar, así que su precio sigue adentro de
 * la política. El desglose fiscal por unidad se escala con el precio (el server
 * lo recalcula igual). No se toca `offlineUuid`, como en `quitarRegalosDelPayload`.
 */
export function quitarCombosDelPayload(payload: Record<string, unknown>): Record<string, unknown> | null {
  const items = Array.isArray(payload.items) ? (payload.items as Array<Record<string, unknown>>) : []
  if (!items.some(item => item?.comboId != null)) return null

  const redondear = (n: number) => Math.round(n * 100) / 100
  let total = 0
  let totalNeto = 0
  let totalIva = 0
  const sinCombos = items.map(item => {
    let linea = item
    if (item?.comboId != null) {
      const { comboId: _combo, precioSinCombo, precioSinEscala: _sinEscala, ...resto } = item
      const precio = Number(item.precioUnitario) || 0
      const nuevo = Number(precioSinCombo) || precio
      const escala = precio > 0 ? nuevo / precio : 1
      const escalar = (v: unknown) => (typeof v === 'number' ? redondear(v * escala) : v)
      linea = {
        ...resto,
        precioUnitario: nuevo,
        neto_unitario: escalar(item.neto_unitario),
        iva_unitario: escalar(item.iva_unitario),
        impuestos_internos_unitario: escalar(item.impuestos_internos_unitario),
      }
    }
    if (linea.esBonificacion !== true) {
      const cantidad = Number(linea.cantidad) || 0
      total += (Number(linea.precioUnitario) || 0) * cantidad
      totalNeto += (Number(linea.neto_unitario) || 0) * cantidad
      totalIva += (Number(linea.iva_unitario) || 0) * cantidad
    }
    return linea
  })

  return {
    ...payload,
    items: sinCombos,
    total: redondear(total),
    ...(payload.totalNeto !== undefined ? { totalNeto: redondear(totalNeto) } : {}),
    ...(payload.totalIva !== undefined ? { totalIva: redondear(totalIva) } : {}),
    combosQuitados: true,
  }
}
