import { memo } from 'react';
import { CalendarDays } from 'lucide-react';
import { DIAS_LUN_SAB, DIAS_LUN_VIE, DIAS_TODOS } from '../../utils/parseHorarioLibre';

export interface DiasAtencionSelectorProps {
  /** Bitmask "1111110" (Lunes→Domingo) o null = sin especificar. */
  valor: string | null;
  onChange: (valor: string | null) => void;
}

/** Etiqueta corta de cada día, en orden Lunes→Domingo (índice del bitmask). */
const DIAS = [
  { corta: 'L', larga: 'Lunes' },
  { corta: 'M', larga: 'Martes' },
  { corta: 'M', larga: 'Miércoles' },
  { corta: 'J', larga: 'Jueves' },
  { corta: 'V', larga: 'Viernes' },
  { corta: 'S', larga: 'Sábado' },
  { corta: 'D', larga: 'Domingo' },
];

/** Atajos: "lunes a sábado" es el patrón dominante en los datos reales. */
const ATAJOS: Array<{ label: string; valor: string }> = [
  { label: 'Lun a Sáb', valor: DIAS_LUN_SAB },
  { label: 'Lun a Vie', valor: DIAS_LUN_VIE },
  { label: 'Todos', valor: DIAS_TODOS },
];

const esBitmaskValido = (v: string | null): v is string => !!v && /^[01]{7}$/.test(v);

/**
 * Selector de días de atención del cliente.
 *
 * Reemplaza el "Lunes a sábado" que antes iba embebido en el texto libre del
 * horario. El ruteo lo usa para no mandar al chofer a un local que ese día no
 * abre: hay clientes de lunes a viernes que, ruteados un sábado, eran rechazo
 * seguro.
 *
 * Sin días marcados (null) el ruteo asume que abre todos los días, que es el
 * comportamiento previo: ante la falta de dato es preferible visitar de más
 * que saltear una entrega.
 */
const DiasAtencionSelector = memo(function DiasAtencionSelector({
  valor,
  onChange,
}: DiasAtencionSelectorProps) {
  const bits = esBitmaskValido(valor) ? valor.split('') : null;

  const toggleDia = (indice: number): void => {
    const base = bits ?? '1111111'.split('');
    const next = [...base];
    next[indice] = next[indice] === '1' ? '0' : '1';
    const str = next.join('');
    // Ningún día marcado no tiene sentido: equivale a "sin especificar".
    onChange(str === '0000000' ? null : str);
  };

  return (
    <div>
      <label className="block text-sm font-medium mb-1 dark:text-gray-200 flex items-center gap-1">
        <CalendarDays className="w-4 h-4" />
        Días que abre
      </label>

      <div className="flex items-center gap-1.5 flex-wrap">
        {DIAS.map((dia, i) => {
          const activo = bits ? bits[i] === '1' : false;
          return (
            <button
              key={`${dia.larga}-${i}`}
              type="button"
              onClick={() => toggleDia(i)}
              aria-pressed={activo}
              aria-label={dia.larga}
              title={dia.larga}
              className={
                'w-9 h-9 rounded-lg text-sm font-semibold transition-colors border ' +
                (activo
                  ? 'bg-blue-600 text-white border-blue-600'
                  : 'bg-white dark:bg-gray-700 text-stone-600 dark:text-gray-300 border-stone-200 dark:border-gray-600 hover:bg-stone-50 dark:hover:bg-gray-600')
              }
            >
              {dia.corta}
            </button>
          );
        })}
      </div>

      <div className="flex items-center gap-2 mt-2 flex-wrap">
        {ATAJOS.map(a => (
          <button
            key={a.label}
            type="button"
            onClick={() => onChange(a.valor)}
            className="px-2.5 py-1 rounded-full text-xs font-medium bg-stone-100 dark:bg-gray-700 text-stone-700 dark:text-gray-300 hover:bg-stone-200 dark:hover:bg-gray-600 transition-colors"
          >
            {a.label}
          </button>
        ))}
        {bits && (
          <button
            type="button"
            onClick={() => onChange(null)}
            className="px-2.5 py-1 rounded-full text-xs font-medium text-stone-500 dark:text-gray-400 hover:text-stone-700 dark:hover:text-gray-200 transition-colors"
          >
            Limpiar
          </button>
        )}
      </div>

      {!bits && (
        <p className="text-xs text-gray-500 dark:text-gray-400 mt-1">
          Sin marcar: se asume que abre todos los días.
        </p>
      )}
    </div>
  );
});

export default DiasAtencionSelector;
