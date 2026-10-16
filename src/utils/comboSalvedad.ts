/**
 * Lo que una salvedad le hace a los combos del pedido (#1192).
 *
 * Cuando el cliente rechaza (`cliente_rechaza`) parte de un combo, el combo se
 * rompe y lo que se queda vuelve a su precio sin combo: el total puede SUBIR
 * (excepción a las migs 165-168, decidida por el dueño). Con cualquier otro
 * motivo —los nuestros y los dudosos— lo que se queda mantiene el precio de
 * combo. La cuenta la hace el servidor (`simular_salvedades_combo_impacto`, la
 * misma regla que aplica `registrar_salvedad`); acá sólo se resume para
 * mostrarla al chofer antes de confirmar.
 */

/** Un producto del combo en la simulación: cuántas unidades quedan fuera del combo antes y después. */
export interface ProductoComboSimulado {
  producto_id: number
  nombre: string | null
  fuera_antes: number
  fuera_despues: number
  precio_combo: number | null
  precio_sin_combo: number | null
}

/** Un combo del pedido que tocan las salvedades simuladas. */
export interface ComboImpactoSalvedad {
  combo_id: number
  nombre: string | null
  combos_antes: number
  combos_despues: number
  /**
   * Cuánto sube el total por rehacer el combo, aparte de lo rechazado al precio
   * de su línea. Negativo si algo que había salido de un combo roto vuelve a él.
   */
  recargo: number
  productos: ProductoComboSimulado[]
}

/** La línea va en un combo, o salió de uno que rompió el cliente. */
export function esLineaDeCombo(item: { combo_id?: string | number | null; combo_roto_id?: string | number | null }): boolean {
  return item.combo_id != null || item.combo_roto_id != null
}

/** El único motivo que rompe el combo: los demás mantienen el precio de combo. */
export function motivoRompeCombo(motivo: string | null | undefined): boolean {
  return motivo === 'cliente_rechaza'
}

const centavos = (n: number): number => Math.round(n * 100) / 100

/** El recargo de todos los combos, en centavos exactos. */
export function recargoTotal(impactos: readonly ComboImpactoSalvedad[]): number {
  return centavos(impactos.reduce((suma, c) => suma + (Number(c.recargo) || 0), 0))
}

/** Los combos que la salvedad rompe (quedan menos que antes). */
export function combosRotos(impactos: readonly ComboImpactoSalvedad[]): ComboImpactoSalvedad[] {
  return impactos.filter(c => c.combos_despues < c.combos_antes)
}

/** Lo que sale del combo (pasa a su precio sin combo), con cuántas unidades. */
export function productosQueSalen(combo: ComboImpactoSalvedad): Array<ProductoComboSimulado & { unidades: number }> {
  return combo.productos
    .filter(p => p.fuera_despues > p.fuera_antes)
    .map(p => ({ ...p, unidades: p.fuera_despues - p.fuera_antes }))
}

/** Lo que vuelve al combo (lo que había salido de un combo roto y se rearma). */
export function productosQueVuelven(combo: ComboImpactoSalvedad): Array<ProductoComboSimulado & { unidades: number }> {
  return combo.productos
    .filter(p => p.fuera_despues < p.fuera_antes)
    .map(p => ({ ...p, unidades: p.fuera_antes - p.fuera_despues }))
}

/** Cuánto cambia el total del pedido: el recargo menos lo rechazado. Positivo = sube. */
export function cambioDelTotal(montoRechazado: number, recargo: number): number {
  return centavos(recargo - montoRechazado)
}

/** Normaliza lo que devuelve la RPC (jsonb) a números. */
export function normalizarImpactoCombos(data: unknown): ComboImpactoSalvedad[] {
  if (!Array.isArray(data)) return []
  const num = (v: unknown): number | null => (v == null || v === '' ? null : Number(v))
  return data.map((c: Record<string, unknown>) => ({
    combo_id: Number(c.combo_id),
    nombre: (c.nombre as string | null) ?? null,
    combos_antes: Number(c.combos_antes) || 0,
    combos_despues: Number(c.combos_despues) || 0,
    recargo: Number(c.recargo) || 0,
    productos: Array.isArray(c.productos)
      ? (c.productos as Record<string, unknown>[]).map(p => ({
          producto_id: Number(p.producto_id),
          nombre: (p.nombre as string | null) ?? null,
          fuera_antes: Number(p.fuera_antes) || 0,
          fuera_despues: Number(p.fuera_despues) || 0,
          precio_combo: num(p.precio_combo),
          precio_sin_combo: num(p.precio_sin_combo),
        }))
      : [],
  }))
}
