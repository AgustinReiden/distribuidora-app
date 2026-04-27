// Formatters comunes para presentar datos al usuario en mensajes del bot.
// Centralizados para que distintos tools/handlers no se peleen sobre cómo
// formatear pesos o fechas.

const ARS = new Intl.NumberFormat("es-AR", {
  style: "currency",
  currency: "ARS",
  maximumFractionDigits: 0,
});

const FECHA_CORTA = new Intl.DateTimeFormat("es-AR", {
  day: "2-digit",
  month: "2-digit",
  year: "2-digit",
});

const FECHA_LARGA = new Intl.DateTimeFormat("es-AR", {
  dateStyle: "medium",
  timeStyle: "short",
});

/**
 * Formatea un valor numérico (o string parseable) como pesos argentinos.
 * null/undefined/NaN → "$ 0".
 */
export function formatCurrency(n: number | string | null | undefined): string {
  const raw = typeof n === "string" ? parseFloat(n) : (n ?? 0);
  const v = Number.isFinite(raw) ? raw : 0;
  return ARS.format(v);
}

/**
 * Formatea una fecha como dd/mm/yy. null/undefined → "—".
 * Si la entrada es inválida (NaN), retorna "—" también.
 *
 * Acepta:
 *   - Date instance
 *   - ISO `YYYY-MM-DD` o `YYYY-MM-DDTHH:mm:ss(.sss)?Z?`
 *   - Strings ya formateados como `DD/MM/YY` o `DD/MM/YYYY` → se devuelven
 *     pasthrough (sin re-parsear) para que un caller que ya formateó no
 *     vea "—" si new Date() del Locale es inválido.
 */
export function formatFechaCorta(fecha: string | Date | null | undefined): string {
  if (fecha === null || fecha === undefined || fecha === "") return "—";
  if (typeof fecha === "string") {
    // Pasthrough si ya viene en formato DD/MM/YY o DD/MM/YYYY.
    if (/^\d{1,2}\/\d{1,2}\/\d{2}(\d{2})?$/.test(fecha)) return fecha;
  }
  const d = fecha instanceof Date ? fecha : new Date(fecha);
  if (Number.isNaN(d.getTime())) return "—";
  return FECHA_CORTA.format(d);
}

/**
 * Formatea fecha + hora con estilo medium. Útil para "último pedido", logs.
 */
export function formatFechaHora(fecha: string | Date | null | undefined): string {
  if (fecha === null || fecha === undefined || fecha === "") return "—";
  const d = fecha instanceof Date ? fecha : new Date(fecha);
  if (Number.isNaN(d.getTime())) return "—";
  return FECHA_LARGA.format(d);
}
