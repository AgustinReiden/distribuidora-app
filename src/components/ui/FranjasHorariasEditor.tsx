import { memo, useMemo } from 'react';
import { Clock, Plus, Trash2 } from 'lucide-react';
import {
  generarOpcionesHora,
  horaAMinutos,
  validarFranjas,
} from '../../utils/horariosCliente';
import type { FranjaHoraria } from '../../utils/horariosCliente';

export interface FranjasHorariasEditorProps {
  /** Franjas actuales (fuente de verdad en el padre). */
  franjas: FranjaHoraria[];
  /** Se llama con el array completo de franjas tras cada edición. */
  onChange: (franjas: FranjaHoraria[]) => void;
}

/**
 * Editor de horarios de atención como lista de franjas Apertura–Cierre.
 *
 * Componente presentacional compartido entre "Editar cliente" (ModalCliente) y la
 * creación rápida de clientes (ModalPedido). No persiste ni serializa: emite el array
 * de franjas vía `onChange` y el padre decide cómo guardarlo (serializarFranjas) y si
 * conserva texto libre legacy. La validación (apertura < cierre, sin solapes) se calcula
 * acá sólo para pintar los errores; el padre vuelve a validar con `validarFranjas` antes
 * de guardar.
 */
const FranjasHorariasEditor = memo(function FranjasHorariasEditor({
  franjas,
  onChange,
}: FranjasHorariasEditorProps) {
  const opcionesApertura = useMemo(() => generarOpcionesHora(false), []);
  const opcionesCierre = useMemo(() => generarOpcionesHora(true), []);
  const validacion = useMemo(() => validarFranjas(franjas), [franjas]);

  const agregarFranja = (): void =>
    onChange([...franjas, { apertura: '', cierre: '' }]);

  const quitarFranja = (index: number): void =>
    onChange(franjas.filter((_, i) => i !== index));

  const actualizarFranja = (index: number, campo: keyof FranjaHoraria, valor: string): void =>
    onChange(
      franjas.map((f, i) => {
        if (i !== index) return f;
        const next = { ...f, [campo]: valor };
        // Al cambiar la apertura, si el cierre quedó vacío o <= apertura, lo limpiamos.
        if (campo === 'apertura' && next.cierre &&
            (!valor || horaAMinutos(next.cierre) <= horaAMinutos(valor))) {
          next.cierre = '';
        }
        return next;
      }),
    );

  return (
    <div>
      <label className="block text-sm font-medium mb-1 dark:text-gray-200 flex items-center gap-1">
        <Clock className="w-4 h-4" />
        Horarios de Atención
      </label>
      <p className="text-xs text-gray-500 dark:text-gray-400 mb-2">
        Cargá apertura y cierre. Si el horario es cortado (ej: mañana y tarde), agregá otra franja.
      </p>
      {franjas.length > 0 && (
        <div className="space-y-2 mb-2">
          {franjas.map((f, index) => {
            const tieneError = Boolean(validacion.erroresPorFila[index]);
            const selectClass = `flex-1 px-3 py-2 border rounded-lg dark:bg-gray-700 dark:text-white text-sm ${
              tieneError ? 'border-red-500 bg-red-50 dark:bg-red-900/20' : 'dark:border-gray-600'
            }`;
            return (
              <div key={index}>
                <div className="flex items-center gap-2">
                  <select
                    value={f.apertura}
                    onChange={e => actualizarFranja(index, 'apertura', e.target.value)}
                    aria-label="Hora de apertura"
                    className={selectClass}
                  >
                    <option value="">Apertura</option>
                    {opcionesApertura.map(h => <option key={h} value={h}>{h}</option>)}
                  </select>
                  <span className="text-gray-400 text-sm">a</span>
                  <select
                    value={f.cierre}
                    onChange={e => actualizarFranja(index, 'cierre', e.target.value)}
                    aria-label="Hora de cierre"
                    className={selectClass}
                  >
                    <option value="">Cierre</option>
                    {opcionesCierre
                      .filter(h => !f.apertura || horaAMinutos(h) > horaAMinutos(f.apertura))
                      .map(h => <option key={h} value={h}>{h}</option>)}
                  </select>
                  <button
                    type="button"
                    onClick={() => quitarFranja(index)}
                    className="p-2 text-rose-600 hover:bg-rose-50 dark:hover:bg-rose-900/20 rounded-lg"
                    aria-label="Quitar franja horaria"
                  >
                    <Trash2 className="w-4 h-4" />
                  </button>
                </div>
                {tieneError && (
                  <p className="text-red-500 text-xs mt-1">{validacion.erroresPorFila[index]}</p>
                )}
              </div>
            );
          })}
        </div>
      )}
      {validacion.errorSolapamiento && (
        <p className="text-red-500 text-xs mb-2">{validacion.errorSolapamiento}</p>
      )}
      <button
        type="button"
        onClick={agregarFranja}
        className="inline-flex items-center gap-1.5 px-3 py-2 text-sm font-medium text-blue-600 hover:bg-blue-50 dark:hover:bg-blue-900/20 rounded-lg"
      >
        <Plus className="w-4 h-4" />
        Agregar franja
      </button>
    </div>
  );
});

export default FranjasHorariasEditor;
