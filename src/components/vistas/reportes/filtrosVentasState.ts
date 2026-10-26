/**
 * Estado de los filtros de las pestañas de ventas ("Por Cliente" y "Por Zona").
 *
 * Vive en su propio módulo y no dentro de `FiltrosVentas.tsx` porque el fast
 * refresh de React sólo funciona si un archivo de componentes exporta
 * únicamente componentes.
 */
import { presetsVentas } from '../../../utils/periodosReporte';

/**
 * Qué hacer con las líneas de combo en las estadísticas por producto (#1193):
 * incluirlas (default), excluirlas o ver sólo combos.
 */
export type FiltroCombos = 'incluir' | 'excluir' | 'solo';

export const FILTROS_COMBOS: { id: FiltroCombos; label: string }[] = [
  { id: 'incluir', label: 'Incluir combos' },
  { id: 'excluir', label: 'Excluir combos' },
  { id: 'solo', label: 'Sólo combos' }
];

export interface FiltrosVentasValue {
  desde: string;
  hasta: string;
  preventistaId: string | null;
  /** id de un preset de `presetsVentas`, o 'custom'. */
  presetId: string;
}

/** Estado inicial: el año en curso, todos los preventistas. */
export function filtrosVentasIniciales(hoy: Date = new Date()): FiltrosVentasValue {
  const [anio] = presetsVentas(hoy);
  return { desde: anio.desde, hasta: anio.hasta, preventistaId: null, presetId: anio.id };
}
