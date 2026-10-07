// Línea "🕒 Datos al <corte>" al pie de la respuesta del bot (#971).
//
// La agrega el código, no el modelo: cuando era una regla del prompt, Gemini
// la inventaba también para tools que no devuelven el campo (ej:
// ventas_por_preventista terminó con "Datos al 2026-07-23 15:00:00", un corte
// que no existía). Ahora el valor sale sólo del resultado real de una tool del
// turno, y cualquier línea "Datos al" que escriba el modelo se borra.

/** Campo que una tool de reporte devuelve con el instante de la consulta. */
export const CAMPO_CORTE = "consulta_realizada_at";

/**
 * Devuelve `consulta_realizada_at` del data de una tool si es un string no
 * vacío; si no, undefined.
 */
export function extraerCorte(data: unknown): string | undefined {
  if (typeof data !== "object" || data === null) return undefined;
  const valor = (data as Record<string, unknown>)[CAMPO_CORTE];
  return typeof valor === "string" && valor.trim().length > 0 ? valor.trim() : undefined;
}

// Una línea que empieza (tras espacios o emoji de reloj) con "Datos al".
const LINEA_CORTE = /^[ \t]*(?:🕒|🕐|⏱️?|⏰)?[ \t]*Datos al\b.*$/gimu;

/**
 * Quita las líneas "Datos al ..." que haya escrito el modelo y, si hay un
 * corte real, agrega "🕒 Datos al <corte>" al final.
 */
export function aplicarCorteDatos(texto: string, corte: string | undefined): string {
  const limpio = texto.replace(LINEA_CORTE, "").replace(/\n{3,}/g, "\n\n").trimEnd();
  if (!corte) return limpio;
  return `${limpio}\n\n🕒 Datos al ${corte}`;
}
