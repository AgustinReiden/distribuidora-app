/**
 * Devuelve una aclaración entre paréntesis indicando cuántos fardos representa
 * la cantidad vendida, basado en `unidadesPorFardo` configurado en el producto.
 *
 * Reglas:
 * - 0.5 fardo → "(MEDIO FARDO)" / "(MEDIA CAJA)" (femenino para CAJA)
 * - N entero → "(N FARDO)" o "(N FARDOS)" (plural si N>=2)
 * - N.5 con N>=1 → "(N FARDO Y MEDIO)" o "(N FARDOS Y MEDIO)"
 * - Fracciones distintas (1/3, 2/3, etc.) → null
 * - cantidad o unidadesPorFardo inválidos/0 → null
 */
export function formatAclaracionBulto(
  cantidad: number,
  unidadesPorFardo: number | null | undefined,
  etiqueta: string | null | undefined,
): string | null {
  if (!cantidad || !Number.isFinite(cantidad) || cantidad <= 0) return null;
  if (!unidadesPorFardo || !Number.isFinite(unidadesPorFardo) || unidadesPorFardo <= 0) return null;

  const ratio = cantidad / unidadesPorFardo;
  const label = (etiqueta && etiqueta.trim()) ? etiqueta.trim().toUpperCase() : 'FARDO';

  // Heurística de género: termina en 'A' → femenino (CAJA → MEDIA, FARDO → MEDIO)
  const isFem = label.endsWith('A');
  const medio = isFem ? 'MEDIA' : 'MEDIO';
  const labelPlural = `${label}S`;

  if (ratio === 0.5) return `(${medio} ${label})`;

  if (Number.isInteger(ratio)) {
    return ratio === 1 ? `(1 ${label})` : `(${ratio} ${labelPlural})`;
  }

  const entero = Math.floor(ratio);
  const fraccion = ratio - entero;
  if (fraccion === 0.5 && entero >= 1) {
    const palabra = entero === 1 ? label : labelPlural;
    return `(${entero} ${palabra} Y MEDIO)`;
  }

  return null;
}
