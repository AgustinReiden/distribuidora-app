import { memo, useEffect, useId, useState } from 'react';
import { Trash2, AlertTriangle, Check } from 'lucide-react';

/** Tipos de modal de confirmación */
export type ModalConfirmacionTipo = 'danger' | 'warning' | 'success';

/**
 * Campo de fecha opcional dentro de la confirmación.
 *
 * Existe para el "marcar entregado" individual: sin esto la entrega se estampaba
 * SIEMPRE con la fecha de hoy, así que marcar el martes las entregas del lunes
 * dejaba la rendición del lunes vacía y la del martes inflada con mercadería que
 * no salió ese día. Las entregas masivas ya tenían su selector; la individual no.
 */
export interface ModalConfirmacionCampoFecha {
  /** Etiqueta visible del campo. */
  label: string;
  /** Valor inicial, `YYYY-MM-DD`. */
  valorInicial: string;
  /** Fecha máxima seleccionable, `YYYY-MM-DD`. */
  max?: string;
  /** Texto de ayuda debajo del input. */
  ayuda?: string;
}

/** Configuración del modal de confirmación */
export interface ModalConfirmacionConfig {
  /** Si el modal está visible */
  visible: boolean;
  /** Tipo de modal que determina colores e icono */
  tipo: ModalConfirmacionTipo;
  /** Título del modal */
  titulo: string;
  /** Mensaje descriptivo */
  mensaje: string;
  /** Campo de fecha opcional. Su valor llega como argumento de `onConfirm`. */
  campoFecha?: ModalConfirmacionCampoFecha;
  /** Callback ejecutado al confirmar. Recibe la fecha si hay `campoFecha`. */
  onConfirm: (fecha?: string) => void;
}

/** Props del componente ModalConfirmacion */
export interface ModalConfirmacionProps {
  /** Configuración del modal */
  config: ModalConfirmacionConfig | null;
  /** Callback ejecutado al cerrar o cancelar */
  onClose: () => void;
}

/**
 * Modal de confirmación reutilizable
 * Soporta tipos: danger (eliminar), warning (advertencia), success (éxito)
 */
const ModalConfirmacion = memo(function ModalConfirmacion({ config, onClose }: ModalConfirmacionProps) {
  const titleId = useId();
  const descId = useId();
  const fechaId = useId();
  const [fecha, setFecha] = useState<string>(config?.campoFecha?.valorInicial ?? '');

  // Cada apertura arranca con su propio valor inicial: el modal se reusa entre
  // confirmaciones distintas y sin esto la fecha de la anterior quedaba pegada.
  const valorInicial = config?.campoFecha?.valorInicial;
  useEffect(() => {
    if (valorInicial !== undefined) setFecha(valorInicial);
  }, [valorInicial, config?.visible]);

  if (!config?.visible) return null;

  const iconConfig = {
    danger: {
      bg: 'bg-red-100',
      icon: <Trash2 className="w-6 h-6 text-red-600" aria-hidden="true" />,
      btn: 'text-red-600 hover:bg-red-50'
    },
    warning: {
      bg: 'bg-yellow-100',
      icon: <AlertTriangle className="w-6 h-6 text-yellow-600" aria-hidden="true" />,
      btn: 'text-yellow-600 hover:bg-yellow-50'
    },
    success: {
      bg: 'bg-green-100',
      icon: <Check className="w-6 h-6 text-green-600" aria-hidden="true" />,
      btn: 'text-green-600 hover:bg-green-50'
    }
  };
  const { bg, icon, btn } = iconConfig[config.tipo] || iconConfig.success;

  return (
    <div
      className="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center p-4 z-50"
      role="dialog"
      aria-modal="true"
      aria-labelledby={titleId}
      aria-describedby={descId}
    >
      <div className="bg-white rounded-xl shadow-xl w-full max-w-sm">
        <div className="p-6">
          <div className={`flex items-center justify-center w-12 h-12 mx-auto mb-4 rounded-full ${bg}`}>
            {icon}
          </div>
          <h3 id={titleId} className="text-lg font-semibold text-center mb-2">
            {config.titulo}
          </h3>
          <p id={descId} className="text-center text-gray-600">
            {config.mensaje}
          </p>
          {config.campoFecha && (
            <div className="mt-4">
              <label htmlFor={fechaId} className="block text-sm font-medium text-gray-700 mb-1">
                {config.campoFecha.label}
              </label>
              <input
                id={fechaId}
                type="date"
                value={fecha}
                max={config.campoFecha.max}
                onChange={e => setFecha(e.target.value)}
                className="w-full px-3 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-green-500 focus:border-green-500"
              />
              {config.campoFecha.ayuda && (
                <p className="mt-1 text-xs text-gray-500">{config.campoFecha.ayuda}</p>
              )}
            </div>
          )}
        </div>
        <div className="flex border-t">
          <button
            type="button"
            onClick={onClose}
            className="flex-1 px-4 py-3 text-gray-700 hover:bg-gray-50 rounded-bl-xl transition-colors"
          >
            Cancelar
          </button>
          <button
            type="button"
            onClick={() => config.onConfirm(config.campoFecha ? fecha : undefined)}
            disabled={!!config.campoFecha && !fecha}
            className={`flex-1 px-4 py-3 border-l rounded-br-xl transition-colors disabled:opacity-50 disabled:cursor-not-allowed ${btn}`}
          >
            Confirmar
          </button>
        </div>
      </div>
    </div>
  );
});

export default ModalConfirmacion;
