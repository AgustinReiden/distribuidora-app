/**
 * Aritmética de fechas en componentes locales (getFullYear/getMonth/getDate),
 * no toISOString(): eso corre la fecha un día para atrás en Argentina
 * (UTC-3) durante las primeras horas del día.
 *
 * Compartido por periodosReporte.ts (atajos de "Ventas por cliente/zona") y
 * ReportesGerencialesContainer.tsx (atajos del reporte gerencial): las dos
 * pantallas arman sus propios presets con etiquetas distintas, pero la
 * aritmética de fin de mes / restar N meses / formatear YYYY-MM-DD es la
 * misma.
 */

/** 'YYYY-MM-DD' a partir de componentes locales (mes0: 0-11). */
export function ymdLocal(anio: number, mes0: number, dia: number): string {
  return `${anio}-${String(mes0 + 1).padStart(2, '0')}-${String(dia).padStart(2, '0')}`
}

/** 'YYYY-MM-DD' de un Date, leyendo sus componentes locales. */
export function ymdLocalDate(d: Date): string {
  return ymdLocal(d.getFullYear(), d.getMonth(), d.getDate())
}

/** Último día del mes `mes0` (0-11) de `anio`. */
export function ultimoDiaDelMes(anio: number, mes0: number): number {
  // El día 0 del mes siguiente es el último del actual, y el constructor
  // normaliza mes0 = 12 al enero del año siguiente.
  return new Date(anio, mes0 + 1, 0).getDate()
}

/** Primer día del mes que está `atras` meses antes del de `base` (0 = el mes de `base`). */
export function primerDiaMesAtras(base: Date, atras: number): Date {
  return new Date(base.getFullYear(), base.getMonth() - atras, 1)
}
