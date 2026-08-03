import { memo } from 'react';
import { Target } from 'lucide-react';
import BarraProgresoMeta from '../metas/BarraProgresoMeta';
import type { AvanceMetasResultado } from '../../hooks/queries';

export interface PanelMisMetasProps {
  avance: AvanceMetasResultado;
}

const MESES = [
  'enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio',
  'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre',
];

/** "2026-08-01" → "agosto". Se parsea a mano: `new Date('2026-08-01')` es UTC
 *  y en Argentina devuelve julio. */
function nombreMes(periodo: string): string {
  const mes = Number(periodo.slice(5, 7));
  return MESES[mes - 1] ?? '';
}

/**
 * Objetivos del mes del preventista, en su dashboard.
 *
 * OJO con dos cosas que confunden si no se dicen:
 *  - Las metas son SIEMPRE mensuales. El panel no reacciona a los chips de
 *    período del dashboard (hoy/semana/año), por eso lleva el mes escrito: si
 *    no, con el filtro en "Hoy" se lee "35%" y se entiende "35% de hoy".
 *  - La base es "pedidos entregados", distinta de la de "Mis métricas" (que
 *    cuenta todo lo no cancelado). Los números no coinciden y hay que decirlo,
 *    o el preventista desconfía de los dos.
 */
const PanelMisMetas = memo(function PanelMisMetas({ avance }: PanelMisMetasProps) {
  if (!avance?.metas?.length) return null;

  const { resumen, metas, dias_transcurridos, dias_periodo } = avance;

  return (
    <section className="rounded-xl border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-800 p-4">
      <div className="flex flex-wrap items-baseline justify-between gap-2 mb-1">
        <h2 className="font-semibold dark:text-white flex items-center gap-1.5">
          <Target className="w-4 h-4 text-blue-600" />
          Mis objetivos de {nombreMes(avance.periodo)}
        </h2>
        <span className="text-sm text-gray-600 dark:text-gray-400">
          {resumen.cumplidas} de {resumen.total} cumplid{resumen.total === 1 ? 'o' : 'os'}
          {' · '}día {dias_transcurridos} de {dias_periodo}
        </span>
      </div>

      <p className="text-xs text-gray-500 dark:text-gray-400 mb-3">
        Se cuentan los pedidos entregados del mes, sin bonificaciones.
      </p>

      <div className="divide-y dark:divide-gray-700">
        {metas.map(meta => (
          <BarraProgresoMeta key={meta.id} meta={meta} />
        ))}
      </div>

      {avance.productos_sin_marca > 0 && (
        <p className="mt-3 text-xs px-3 py-2 rounded-lg bg-amber-50 dark:bg-amber-900/20 text-amber-800 dark:text-amber-300">
          Hay {avance.productos_sin_marca} productos sin marca cargada: los objetivos por
          marca todavía no los cuentan.
        </p>
      )}
    </section>
  );
});

export default PanelMisMetas;
