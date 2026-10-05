/**
 * Pesos manuales que quedaron viejos al EDITAR una compra guardada.
 *
 * Al hidratar una compra todos los pesos de todos los cargos son manuales: son
 * lo que se guardó, y recalcularlos solos cambiaría el costo sin que nadie lo
 * pida (utils/hidratarCompra). Pero si después se cambia la cantidad de una
 * línea, el peso de un cargo con base 'cantidad' ya no dice lo mismo: en la
 * compra 304 el flete pesa 2 pallets sobre 240 u., y si la línea pasa a 480 u.
 * esos 2 pallets deberían ser 4.
 *
 * No se pisa solo —puede ser que el peso tipeado no dependa de la cantidad— y
 * tampoco se calla: la grilla lo marca y ofrece "recalcular" con un click.
 *
 * Sólo la base 'cantidad'. 'unidades' es "partes iguales" (peso 1 en todas las
 * líneas, mig 192): no depende de la cantidad. 'monto' sí depende del costo y
 * de la cantidad, pero el pedido de esta entrega es la cantidad, y un peso por
 * monto mal llevado se ve igual en "Le toca".
 *
 * El recálculo es PROPORCIONAL —peso × cantidad nueva / cantidad de referencia—
 * y no el pre-llenado de la base: el pre-llenado de 'cantidad' es la cantidad
 * misma (480), y meterlo en un vector de pallets (2, 8, 1...) mezclaría
 * unidades distintas en el mismo reparto. Cuando el peso guardado ERA la
 * cantidad, la proporción da exactamente la cantidad nueva, así que no se
 * pierde nada.
 *
 * Puro: lo testea `pesosDesactualizados.test.ts`.
 */
import { redondearSQL } from './calculations'
import type { CargoCompraForm, CompraItemForm } from '../components/modals/ModalCompra.reducer'

/** Un peso desactualizado: la línea, el peso que tiene y el que tendría. */
export interface PesoDesactualizado {
  lineaId: number
  peso: number
  cantidadReferencia: number
  cantidadActual: number
  pesoRecalculado: number
}

/** peso × nueva / referencia, a 4 decimales (la precisión de `compra_cargo_repartos.peso`). */
export function pesoProporcional(peso: number, cantidadReferencia: number, cantidadActual: number): number {
  if (!(cantidadReferencia > 0)) return peso
  return redondearSQL(peso * cantidadActual / cantidadReferencia, 4)
}

/**
 * Las líneas de este cargo cuyo peso manual quedó viejo.
 *
 * Un 0 nunca está desactualizado: es la exclusión de la línea, y una exclusión
 * no escala con la cantidad.
 */
export function pesosDesactualizados(cargo: CargoCompraForm, items: CompraItemForm[]): PesoDesactualizado[] {
  const referencia = cargo.cantidadesReferencia
  // 'medida' (mig 278) también: un peso en pallets escala con la cantidad igual
  // que uno en unidades.
  if (!referencia || (cargo.baseProrrateo !== 'cantidad' && cargo.baseProrrateo !== 'medida')) return []
  const salida: PesoDesactualizado[] = []
  for (const item of items) {
    const id = item.lineaId
    if (id === undefined || !cargo.pesosManuales[id]) continue
    const cantidadReferencia = referencia[id]
    const peso = cargo.pesos[id]
    if (cantidadReferencia === undefined || peso === undefined || !(peso > 0)) continue
    const cantidadActual = Number(item.cantidad) || 0
    if (!(cantidadActual > 0) || cantidadActual === cantidadReferencia) continue
    salida.push({
      lineaId: id,
      peso,
      cantidadReferencia,
      cantidadActual,
      pesoRecalculado: pesoProporcional(peso, cantidadReferencia, cantidadActual),
    })
  }
  return salida
}

/**
 * El cargo con sus pesos desactualizados llevados a la cantidad actual. Siguen
 * siendo manuales —lo que se hizo fue escalar un dato tipeado, no volver al
 * pre-llenado— y la referencia pasa a la cantidad de ahora.
 */
export function recalcularPesosDesactualizados(cargo: CargoCompraForm, items: CompraItemForm[]): CargoCompraForm {
  const viejos = pesosDesactualizados(cargo, items)
  if (viejos.length === 0) return cargo
  const pesos = { ...cargo.pesos }
  const cantidadesReferencia = { ...cargo.cantidadesReferencia }
  for (const v of viejos) {
    pesos[v.lineaId] = v.pesoRecalculado
    cantidadesReferencia[v.lineaId] = v.cantidadActual
  }
  return { ...cargo, pesos, cantidadesReferencia }
}
