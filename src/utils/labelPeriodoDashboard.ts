/**
 * Deriva un label legible del período activo en el panel Dashboard.
 *
 * Lo usa el header del Dashboard para mostrar un título dinámico:
 *   "Resumen del día" / "Resumen del mes" / "Resumen del 14 al 23 de mayo" / etc.
 *
 * Paralelo a `labelPeriodoPedidos` y `labelCategoriaProductos`.
 */
import { parseDateSafe } from './formatters';

export type FiltroPeriodoDashboard =
  | 'hoy'
  | 'semana'
  | 'mes'
  | 'anio'
  | 'historico'
  | 'personalizado'
  | string;

export interface LabelPeriodoDashboardInput {
  /** Identificador del período activo. */
  filtroPeriodo: FiltroPeriodoDashboard;
  /** Si es 'personalizado', fecha de inicio del rango. */
  fechaDesde?: string | null;
  /** Si es 'personalizado', fecha de fin del rango. */
  fechaHasta?: string | null;
}

export interface LabelPeriodoDashboard {
  /** "Resumen" o "Mis métricas" según rol. Pasarlo desde el header. */
  verbo: string;
  /** Período legible o null si es histórico (sin filtro). */
  periodo: string | null;
}

const MESES_AR = [
  'enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio',
  'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre',
] as const;

function formatFechaCorta(iso: string): string {
  const d = parseDateSafe(iso);
  return `${d.getDate()} de ${MESES_AR[d.getMonth()]}`;
}

function mismoMesYAnio(a: Date, b: Date): boolean {
  return a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth();
}

/**
 * @param input    Filtro de período + fechas (si personalizado)
 * @param verbo    "Resumen" (admin/encargado) o "Mis métricas" (preventista). Default "Resumen".
 */
export function labelPeriodoDashboard(
  input: LabelPeriodoDashboardInput,
  verbo: string = 'Resumen',
): LabelPeriodoDashboard {
  switch (input.filtroPeriodo) {
    case 'hoy':
      return { verbo, periodo: 'del día' };
    case 'semana':
      return { verbo, periodo: 'de la semana' };
    case 'mes':
      return { verbo, periodo: 'del mes' };
    case 'anio':
      return { verbo, periodo: 'del año' };
    case 'historico':
      return { verbo, periodo: null };
    case 'personalizado': {
      const fd = input.fechaDesde ?? null;
      const fh = input.fechaHasta ?? null;
      if (!fd && !fh) return { verbo, periodo: 'personalizado' };
      if (fd && fh) {
        if (fd === fh) {
          return { verbo, periodo: `del ${formatFechaCorta(fd)}` };
        }
        const dFrom = parseDateSafe(fd);
        const dTo = parseDateSafe(fh);
        if (mismoMesYAnio(dFrom, dTo)) {
          return {
            verbo,
            periodo: `del ${dFrom.getDate()} al ${dTo.getDate()} de ${MESES_AR[dFrom.getMonth()]}`,
          };
        }
        return { verbo, periodo: `del ${formatFechaCorta(fd)} al ${formatFechaCorta(fh)}` };
      }
      if (fd && !fh) return { verbo, periodo: `desde el ${formatFechaCorta(fd)}` };
      if (!fd && fh) return { verbo, periodo: `hasta el ${formatFechaCorta(fh)}` };
      return { verbo, periodo: 'personalizado' };
    }
    default:
      return { verbo, periodo: null };
  }
}
