import { memo } from 'react';
import { formatPrecio } from '../../utils/formatters';
import type { AvanceMeta } from '../../hooks/queries';

export interface BarraProgresoMetaProps {
  meta: AvanceMeta;
  /** Compacta la fila (para las tablas del admin). */
  densa?: boolean;
}

/** Etiqueta legible del objetivo: "Facturación MANAOS", "Clientes nuevos". */
function etiquetaMeta(meta: AvanceMeta): string {
  const base =
    meta.tipo_meta === 'facturacion' ? 'Facturación' :
    meta.tipo_meta === 'unidades' ? 'Unidades' :
    meta.tipo_meta === 'cobertura' ? 'Clientes visitados' :
    'Clientes nuevos';
  return meta.alcance.nombre ? `${base} ${meta.alcance.nombre}` : base;
}

/** Formatea un valor según la unidad de la meta. */
function formatValorMeta(valor: number, unidad: string): string {
  if (unidad === '$') return formatPrecio(valor);
  const n = Math.round(valor * 100) / 100;
  return unidad === 'u' ? `${n} u` : `${n}`;
}

const COLOR_BARRA: Record<string, string> = {
  cumplida: 'bg-green-600',
  adelantado: 'bg-blue-600',
  en_curso: 'bg-amber-500',
  en_riesgo: 'bg-rose-500',
};

const COLOR_TEXTO: Record<string, string> = {
  cumplida: 'text-green-700 dark:text-green-400',
  adelantado: 'text-blue-700 dark:text-blue-400',
  en_curso: 'text-amber-700 dark:text-amber-400',
  en_riesgo: 'text-rose-700 dark:text-rose-400',
};

const LABEL_ESTADO: Record<string, string> = {
  cumplida: 'Cumplida',
  adelantado: 'Adelantado',
  en_curso: 'En curso',
  en_riesgo: 'Atrasado',
};

/**
 * Barra de avance de un objetivo, con el marcador del ritmo esperado.
 *
 * La marca gris es `objetivo_prorrateado`: lo que habría que llevar a esta
 * altura del mes. Sin ella un 40% al día 10 y un 40% al día 28 se ven igual, y
 * son cosas opuestas. El valor lo calcula el RPC, no este componente: si lo
 * recalculara acá, el semáforo del preventista y el del gerente podrían
 * discrepar por un redondeo.
 */
const BarraProgresoMeta = memo(function BarraProgresoMeta({ meta, densa = false }: BarraProgresoMetaProps) {
  const pctBarra = Math.min(100, Math.max(0, meta.pct));
  const pctRitmo = meta.objetivo > 0
    ? Math.min(100, Math.max(0, (meta.objetivo_prorrateado / meta.objetivo) * 100))
    : 0;

  return (
    <div className={densa ? 'py-1' : 'py-2'}>
      <div className="flex items-baseline justify-between gap-2 mb-1">
        <span
          className={`font-medium truncate dark:text-white ${densa ? 'text-sm' : ''}`}
          // Con varios productos la etiqueta dice "N productos"; el detalle va
          // en el tooltip, porque la lista entera no entra en una barra.
          title={meta.alcance.productos?.length
            ? meta.alcance.productos.map(p => p.nombre).join('\n')
            : undefined}
        >
          {etiquetaMeta(meta)}
        </span>
        <span className={`shrink-0 text-sm font-semibold tabular-nums ${COLOR_TEXTO[meta.estado]}`}>
          {Math.round(meta.pct)}%
        </span>
      </div>

      <div className="relative h-2.5 rounded-full bg-gray-200 dark:bg-gray-700 overflow-hidden">
        <div
          className={`h-full rounded-full transition-all ${COLOR_BARRA[meta.estado]}`}
          style={{ width: `${pctBarra}%` }}
        />
        {/* Ritmo esperado a esta altura del mes. */}
        {pctRitmo > 0 && pctRitmo < 100 && (
          <div
            className="absolute top-0 h-full w-0.5 bg-gray-500 dark:bg-gray-300"
            style={{ left: `${pctRitmo}%` }}
            title="Ritmo esperado a esta altura del mes"
          />
        )}
      </div>

      <div className="flex items-baseline justify-between gap-2 mt-1 text-xs text-gray-600 dark:text-gray-400">
        <span className="tabular-nums">
          {formatValorMeta(meta.logrado, meta.unidad)} de {formatValorMeta(meta.objetivo, meta.unidad)}
        </span>
        <span className={COLOR_TEXTO[meta.estado]}>{LABEL_ESTADO[meta.estado]}</span>
      </div>
    </div>
  );
});

export default BarraProgresoMeta;
