/**
 * Deriva un label legible del rango de fechas activo en el filtro de pedidos.
 *
 * Lo usa el header del panel de Pedidos para mostrar un título dinámico:
 *   "Pedidos del día" / "Pedidos del mes" / "Pedidos para entregar hoy" / etc.
 *
 * El estado tiene dos campos de fecha con semántica distinta:
 *   - `fechaDesde` / `fechaHasta`: rango por fecha de CREACIÓN del pedido
 *     (lo cambia el usuario desde el modal "Fechas").
 *   - `fechaEntregaProgramada`: filtro por fecha de ENTREGA prevista
 *     (lo cambia el usuario con los quick filters "Hoy" / "Mañana").
 *
 * Reglas de prioridad para el título:
 *   1. Si hay `fechaEntregaProgramada` (es el filtro más operativo), prevalece.
 *   2. Si no, se deriva del rango fechaDesde/fechaHasta.
 *   3. Si no hay nada, el título es solo "Pedidos".
 *
 * Las fechas vienen como strings 'YYYY-MM-DD' en zona horaria Argentina.
 */
import { fechaLocalISO, parseDateSafe } from './formatters';

function pad2(n: number): string {
  return String(n).padStart(2, '0');
}

const MESES_AR = [
  'enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio',
  'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre',
] as const;

export interface LabelPeriodoPedidos {
  /** Siempre 'Pedidos' por ahora. Reservado para extensión. */
  verbo: string;
  /** Período legible o null si no hay filtro activo. */
  periodo: string | null;
}

export interface LabelPeriodoInput {
  fechaDesde: string | null;
  fechaHasta: string | null;
  fechaEntregaProgramada?: string | null;
}

function formatFechaCorta(iso: string): string {
  const d = parseDateSafe(iso);
  return `${d.getDate()} de ${MESES_AR[d.getMonth()]}`;
}

function mismoMesYAnio(a: Date, b: Date): boolean {
  return a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth();
}

/** Primer día del mes (YYYY-MM-DD). Construye el ISO directo desde year+month
 *  para evitar que la TZ del runtime mueva el día al construir un Date local
 *  (bug que aparecía en CI corriendo en UTC: new Date(2026, 4, 1) en UTC se
 *  reinterpretaba como '2026-04-30' al pasarlo por fechaLocalISO en TZ AR). */
function primerDiaDelMesISO(d: Date): string {
  return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-01`;
}

/** Último día del mes (YYYY-MM-DD). Calcula el último día usando
 *  new Date(year, month+1, 0).getDate() — esto es TZ-safe porque getDate()
 *  extrae el día en la misma TZ con la que se construyó el Date, y el
 *  resultado (28-31) es independiente de TZ. */
function ultimoDiaDelMesISO(d: Date): string {
  const year = d.getFullYear();
  const month = d.getMonth();
  const lastDay = new Date(year, month + 1, 0).getDate();
  return `${year}-${pad2(month + 1)}-${pad2(lastDay)}`;
}

function isoOffsetDias(now: Date, offset: number): string {
  const d = new Date(now);
  d.setDate(d.getDate() + offset);
  return fechaLocalISO(d);
}

/**
 * Helper que genera el label cuando hay un filtro de fecha de ENTREGA activo.
 * "Pedidos para entregar hoy / mañana / ayer / el 14 de abril"
 */
function labelEntrega(fechaEntrega: string, now: Date): string {
  const hoyISO = fechaLocalISO(now);
  const ayerISO = isoOffsetDias(now, -1);
  const mananaISO = isoOffsetDias(now, +1);
  if (fechaEntrega === hoyISO) return 'para entregar hoy';
  if (fechaEntrega === ayerISO) return 'que entregamos ayer';
  if (fechaEntrega === mananaISO) return 'para entregar mañana';
  return `para entregar el ${formatFechaCorta(fechaEntrega)}`;
}

/**
 * Acepta tanto la firma vieja (string|null, string|null, Date?)
 * como la nueva con objeto, para que los call-sites se puedan migrar
 * gradualmente sin romper tests.
 */
export function labelPeriodoPedidos(
  fechaDesdeOrInput: string | null | LabelPeriodoInput,
  fechaHasta?: string | null,
  now?: Date,
): LabelPeriodoPedidos {
  // Normalizar inputs (firma nueva con objeto, firma vieja con args).
  const input: LabelPeriodoInput = typeof fechaDesdeOrInput === 'object' && fechaDesdeOrInput !== null
    ? fechaDesdeOrInput
    : { fechaDesde: fechaDesdeOrInput, fechaHasta: fechaHasta ?? null };
  const fd = input.fechaDesde ?? null;
  const fh = input.fechaHasta ?? null;
  const fe = input.fechaEntregaProgramada ?? null;
  const ref = now ?? new Date();

  // --- Prioridad 1: filtro de entrega activo ---
  if (fe) {
    return { verbo: 'Pedidos', periodo: labelEntrega(fe, ref) };
  }

  const hoyISO = fechaLocalISO(ref);
  const ayerISO = isoOffsetDias(ref, -1);
  const mananaISO = isoOffsetDias(ref, +1);

  // --- Sin filtros ---
  if (!fd && !fh) {
    return { verbo: 'Pedidos', periodo: null };
  }

  // --- Rango de un solo día (desde === hasta) ---
  if (fd && fh && fd === fh) {
    if (fd === hoyISO) return { verbo: 'Pedidos', periodo: 'del día' };
    if (fd === ayerISO) return { verbo: 'Pedidos', periodo: 'de ayer' };
    if (fd === mananaISO) return { verbo: 'Pedidos', periodo: 'de mañana' };
    return { verbo: 'Pedidos', periodo: `del ${formatFechaCorta(fd)}` };
  }

  // --- Mes completo ---
  if (fd) {
    const desdeDate = parseDateSafe(fd);
    const esPrimerDia = fd === primerDiaDelMesISO(desdeDate);
    const esMesCompleto = esPrimerDia && (
      !fh || fh === ultimoDiaDelMesISO(desdeDate)
    );
    if (esMesCompleto) {
      if (mismoMesYAnio(desdeDate, ref)) {
        return { verbo: 'Pedidos', periodo: 'del mes' };
      }
      const anio = desdeDate.getFullYear() === ref.getFullYear()
        ? ''
        : ` de ${desdeDate.getFullYear()}`;
      return { verbo: 'Pedidos', periodo: `de ${MESES_AR[desdeDate.getMonth()]}${anio}` };
    }
  }

  // --- Solo fechaDesde (sin fechaHasta y no era mes completo) ---
  if (fd && !fh) {
    return { verbo: 'Pedidos', periodo: `desde el ${formatFechaCorta(fd)}` };
  }

  // --- Solo fechaHasta ---
  if (!fd && fh) {
    return { verbo: 'Pedidos', periodo: `hasta el ${formatFechaCorta(fh)}` };
  }

  // --- Rango diferente ---
  if (fd && fh) {
    const desdeDate = parseDateSafe(fd);
    const hastaDate = parseDateSafe(fh);
    if (mismoMesYAnio(desdeDate, hastaDate)) {
      return {
        verbo: 'Pedidos',
        periodo: `del ${desdeDate.getDate()} al ${hastaDate.getDate()} de ${MESES_AR[desdeDate.getMonth()]}`,
      };
    }
    return {
      verbo: 'Pedidos',
      periodo: `del ${formatFechaCorta(fd)} al ${formatFechaCorta(fh)}`,
    };
  }

  return { verbo: 'Pedidos', periodo: null };
}
