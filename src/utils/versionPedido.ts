/**
 * La versión (`pedidos.updated_at`) contra la que guarda la edición de un pedido
 * (#1323), después de un cambio que hizo el mismo usuario desde adentro de la
 * edición: sustituir o repartir un regalo (#1376).
 *
 * Esas RPCs mueven el `updated_at` y devuelven el de antes y el nuevo. La edición
 * adopta el nuevo sólo si estaba parada en el de antes. Si no, otro guardó en el
 * medio, y el rechazo por "editado por otro" tiene que llegar igual: adoptar el
 * nuevo lo taparía.
 */
export interface CambioDeVersion {
  anterior: string
  nueva: string
}

/** Mismo instante, aunque el texto venga con otro formato (`Z` o `+00:00`). */
function mismaVersion(a: string, b: string): boolean {
  if (a === b) return true
  const ta = Date.parse(a)
  const tb = Date.parse(b)
  return !Number.isNaN(ta) && ta === tb
}

export function versionTrasCambioPropio(
  actual: string | null,
  cambio: CambioDeVersion | null | undefined,
): string | null {
  // Sin versión la edición no compara (#1323): no hay nada que adoptar.
  if (!actual || !cambio) return actual
  return mismaVersion(actual, cambio.anterior) ? cambio.nueva : actual
}
