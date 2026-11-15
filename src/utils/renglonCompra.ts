/**
 * Cuándo dos renglones del mismo producto de una compra son EL MISMO renglón.
 *
 * Decisión del dueño (FRG2-1, #1599): al importar o escanear una factura, dos
 * filas del mismo producto sólo se suman si traen el mismo costo y la misma
 * bonificación. Si difieren en alguna de las dos, quedan como dos líneas: sumar
 * las cantidades y dejar el costo y la bonificación de la primera tiraba la
 * plata de la segunda (100 pagas + 10 al 100 % de bonificación quedaban como 110
 * pagas). El server admite dos líneas del mismo producto en una compra.
 *
 * Es una sola regla para el reducer (items ya armados) y para la pantalla de
 * revisión del escaneo (líneas impresas): las dos llaman a esta función.
 */
import { redondearSQL } from './calculations'

export interface CostoYBonificacion {
  costoUnitario: number
  bonificacion?: number | null
}

/** `compra_items.costo_unitario` es numeric(12,2): se compara al centavo. */
export function mismoCostoYBonificacion(a: CostoYBonificacion, b: CostoYBonificacion): boolean {
  return redondearSQL(a.costoUnitario || 0, 2) === redondearSQL(b.costoUnitario || 0, 2)
    && redondearSQL(a.bonificacion || 0, 4) === redondearSQL(b.bonificacion || 0, 4)
}
