import { useState } from 'react';
import { X, Loader2, AlertTriangle } from 'lucide-react';
import { MOTIVOS_NO_ENTREGA, type MotivoNoEntrega } from '../../constants/motivosNoEntrega';

export interface ModalNoEntregaProps {
  abierto: boolean;
  clienteNombre: string;
  guardando?: boolean;
  error?: string | null;
  onCancelar: () => void;
  onConfirmar: (motivo: MotivoNoEntrega, nota: string) => void;
}

/**
 * El chofer marca que no pudo entregar.
 *
 * Se usa en la calle, parado al lado del camión y con una mano, así que los
 * motivos son botones grandes de un toque en vez de un select. El pedido no se
 * cancela: vuelve al pool para re-repartir, y al preventista le llega el motivo.
 */
export default function ModalNoEntrega({
  abierto,
  clienteNombre,
  guardando = false,
  error = null,
  onCancelar,
  onConfirmar,
}: ModalNoEntregaProps) {
  const [motivo, setMotivo] = useState<MotivoNoEntrega | null>(null);
  const [nota, setNota] = useState('');

  if (!abierto) return null;

  // "Otro" sin explicación es el motivo que después nadie entiende: se exige nota.
  const faltaNota = motivo === 'otro' && nota.trim().length < 3;
  const puedeConfirmar = motivo !== null && !faltaNota && !guardando;

  return (
    <div className="fixed inset-0 z-[60] flex items-end sm:items-center justify-center bg-black/50 p-0 sm:p-4">
      <div className="bg-white dark:bg-gray-800 w-full sm:max-w-md rounded-t-2xl sm:rounded-2xl max-h-[92vh] overflow-y-auto">
        <div className="sticky top-0 bg-white dark:bg-gray-800 flex items-center justify-between px-4 py-3 border-b dark:border-gray-700">
          <div className="min-w-0">
            <h3 className="font-semibold text-stone-800 dark:text-white">No se pudo entregar</h3>
            <p className="text-sm text-stone-500 dark:text-gray-400 truncate">{clienteNombre}</p>
          </div>
          <button
            type="button"
            onClick={onCancelar}
            className="p-2 rounded-lg hover:bg-stone-100 dark:hover:bg-gray-700 shrink-0"
            aria-label="Cerrar"
          >
            <X className="w-5 h-5 text-stone-500 dark:text-gray-400" />
          </button>
        </div>

        <div className="p-4 space-y-3">
          <p className="text-sm text-stone-600 dark:text-gray-300">¿Qué pasó?</p>

          <div className="grid grid-cols-1 gap-2">
            {MOTIVOS_NO_ENTREGA.map(m => (
              <button
                key={m.valor}
                type="button"
                onClick={() => setMotivo(m.valor)}
                aria-pressed={motivo === m.valor}
                className={
                  'w-full text-left px-4 py-3 rounded-xl border-2 transition-colors ' +
                  (motivo === m.valor
                    ? 'border-rose-500 bg-rose-50 dark:bg-rose-900/25'
                    : 'border-stone-200 dark:border-gray-600 hover:bg-stone-50 dark:hover:bg-gray-700')
                }
              >
                <span className="block font-semibold text-stone-800 dark:text-white">{m.label}</span>
                <span className="block text-xs text-stone-500 dark:text-gray-400">{m.descripcion}</span>
              </button>
            ))}
          </div>

          {motivo && (
            <div>
              <label htmlFor="nota-no-entrega" className="block text-sm font-medium mb-1 dark:text-gray-200">
                {motivo === 'otro' ? 'Contá qué pasó' : 'Aclaración (opcional)'}
              </label>
              <textarea
                id="nota-no-entrega"
                value={nota}
                onChange={e => setNota(e.target.value)}
                rows={2}
                className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white"
                placeholder={motivo === 'otro' ? 'Ej: el camión no entraba por la calle' : ''}
              />
            </div>
          )}

          <div className="flex items-start gap-2 p-3 rounded-lg bg-blue-50 dark:bg-blue-900/20 border border-blue-200 dark:border-blue-800/50">
            <AlertTriangle className="w-4 h-4 text-blue-600 dark:text-blue-400 mt-0.5 shrink-0" />
            <p className="text-xs text-blue-800 dark:text-blue-200">
              El pedido no se cancela: vuelve a la lista para repartirlo otro día, y el
              preventista recibe el aviso con el motivo.
            </p>
          </div>

          {error && (
            <p role="alert" className="text-sm text-rose-700 bg-rose-50 dark:bg-rose-900/25 dark:text-rose-300 px-3 py-2 rounded-lg">
              {error}
            </p>
          )}
        </div>

        <div className="sticky bottom-0 bg-white dark:bg-gray-800 flex gap-2 px-4 py-3 border-t dark:border-gray-700">
          <button
            type="button"
            onClick={onCancelar}
            disabled={guardando}
            className="flex-1 py-3 rounded-xl border border-stone-300 dark:border-gray-600 text-stone-700 dark:text-gray-200 font-medium disabled:opacity-50"
          >
            Volver
          </button>
          <button
            type="button"
            onClick={() => motivo && onConfirmar(motivo, nota.trim())}
            disabled={!puedeConfirmar}
            className="flex-1 py-3 rounded-xl bg-rose-600 text-white font-semibold hover:bg-rose-700 disabled:opacity-50 flex items-center justify-center gap-2"
          >
            {guardando ? <Loader2 className="w-4 h-4 animate-spin" /> : 'Confirmar'}
          </button>
        </div>
      </div>
    </div>
  );
}
