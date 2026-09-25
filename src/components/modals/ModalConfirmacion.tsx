import { memo, useEffect, useId, useRef, useState } from 'react';
import { Trash2, AlertTriangle, Check } from 'lucide-react';
import { Dialog, DialogContent, DialogTitle, DialogDescription } from '../ui/Dialog';

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
  /** Callback ejecutado al cerrar o cancelar (también con Escape) */
  onClose: () => void;
}

/**
 * Modal de confirmación reutilizable
 * Soporta tipos: danger (eliminar), warning (advertencia), success (éxito)
 *
 * Es un Dialog de Radix armado con los primitivos de `ui/Dialog` y no con
 * `ModalBase`: `ModalBase` pone siempre un header con el título a la izquierda y
 * la X de cerrar, y la confirmación no tiene X (ícono y textos centrados, la
 * salida explícita es "Cancelar"). Overlay, caja, portal, focus trap y Escape
 * son los mismos que los de `ModalBase`.
 *
 * Se renderiza en 15 lugares: 8 adentro de un `ModalBase` y 7 como hermano en un
 * container. Anidada, Radix la apila como la capa de arriba: Escape cierra sólo
 * la confirmación, no el modal de abajo.
 */
const ModalConfirmacion = memo(function ModalConfirmacion({ config, onClose }: ModalConfirmacionProps) {
  const fechaId = useId();
  const cancelarRef = useRef<HTMLButtonElement>(null);
  const [fecha, setFecha] = useState<string>(config?.campoFecha?.valorInicial ?? '');

  // Cada apertura arranca con su propio valor inicial: el modal se reusa entre
  // confirmaciones distintas y sin esto la fecha de la anterior quedaba pegada.
  const valorInicial = config?.campoFecha?.valorInicial;
  useEffect(() => {
    if (valorInicial !== undefined) setFecha(valorInicial);
  }, [valorInicial, config?.visible]);

  // Cerrado no monta nada, ni siquiera el Root de Radix: cada apertura monta un
  // Dialog nuevo. El componente (y su estado) sí sigue montado entre aperturas,
  // que es lo que el efecto de arriba necesita para resetear la fecha.
  if (!config?.visible) return null;

  const iconConfig = {
    danger: {
      bg: 'bg-red-100 dark:bg-red-900/30',
      icon: <Trash2 className="w-6 h-6 text-red-600 dark:text-red-400" aria-hidden="true" />,
      btn: 'text-red-600 dark:text-red-400 hover:bg-red-50 dark:hover:bg-red-900/30'
    },
    warning: {
      bg: 'bg-yellow-100 dark:bg-yellow-900/30',
      icon: <AlertTriangle className="w-6 h-6 text-yellow-600 dark:text-yellow-400" aria-hidden="true" />,
      btn: 'text-yellow-600 dark:text-yellow-400 hover:bg-yellow-50 dark:hover:bg-yellow-900/30'
    },
    success: {
      bg: 'bg-green-100 dark:bg-green-900/30',
      icon: <Check className="w-6 h-6 text-green-600 dark:text-green-400" aria-hidden="true" />,
      btn: 'text-green-600 dark:text-green-400 hover:bg-green-50 dark:hover:bg-green-900/30'
    }
  };
  const { bg, icon, btn } = iconConfig[config.tipo] || iconConfig.success;

  return (
    <Dialog open={config.visible} onOpenChange={(open) => { if (!open) onClose(); }}>
      <DialogContent
        // Radix 1.1 no pone `aria-modal` (esconde el resto con `aria-hidden`);
        // el contrato del diálogo lo exige, así que va explícito.
        aria-modal="true"
        // `w-[calc(100%-2rem)]` conserva el margen de 16px a cada lado que en
        // el celular le daba el `p-4` del overlay hecho a mano.
        //
        // Sin animación de apertura, como la caja hecha a mano. La del
        // primitivo anima `transform` y, mientras dura, pisa el translate que
        // centra la caja: aparecía corrida y a los 200 ms saltaba al centro
        // (#800; ModalBase lo sufre igual). Va con `!` porque tailwind-merge no
        // conoce las animaciones propias y no la reemplaza; al ser `none`, no
        // hay movimiento que la preferencia de reducirlo tenga que frenar.
        className="max-w-sm w-[calc(100%-2rem)] data-[state=open]:!animate-none"
        // Clic afuera NO cierra, igual que antes: el overlay a mano no tenía
        // onClick. La salida es Cancelar o Escape.
        onInteractOutside={(e) => e.preventDefault()}
        // Foco inicial en Cancelar, la opción que no hace nada (como el
        // AlertDialog de Radix): un Enter apurado nunca confirma. Sin esto Radix
        // enfoca el primer tabulable, que con `campoFecha` es el input de fecha.
        onOpenAutoFocus={(e) => {
          e.preventDefault();
          cancelarRef.current?.focus();
        }}
      >
        {/* La caja del primitivo tiene `max-h-[90vh] overflow-hidden`: si el
            contenido no entra (celular apaisado, mensaje largo + campo de fecha),
            scrollea el cuerpo y el pie con Cancelar/Confirmar queda siempre a la
            vista, en vez de quedar recortado abajo y sin poder tocarse. */}
        <div className="p-6 min-h-0 overflow-y-auto overscroll-contain">
          <div className={`flex items-center justify-center w-12 h-12 mx-auto mb-4 rounded-full ${bg}`}>
            {icon}
          </div>
          <DialogTitle className="text-lg text-center mb-2">
            {config.titulo}
          </DialogTitle>
          <DialogDescription className="text-base text-center text-gray-600 dark:text-gray-300">
            {config.mensaje}
          </DialogDescription>
          {config.campoFecha && (
            <div className="mt-4">
              <label htmlFor={fechaId} className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                {config.campoFecha.label}
              </label>
              <input
                id={fechaId}
                type="date"
                value={fecha}
                max={config.campoFecha.max}
                onChange={e => setFecha(e.target.value)}
                className="w-full px-3 py-2 border border-gray-300 dark:border-gray-600 dark:bg-gray-700 dark:text-white rounded-lg focus:ring-2 focus:ring-green-500 focus:border-green-500"
              />
              {config.campoFecha.ayuda && (
                <p className="mt-1 text-xs text-gray-500 dark:text-gray-400">{config.campoFecha.ayuda}</p>
              )}
            </div>
          )}
        </div>
        <div className="flex flex-shrink-0 border-t dark:border-gray-700">
          <button
            ref={cancelarRef}
            type="button"
            onClick={onClose}
            className="flex-1 px-4 py-3 text-gray-700 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-700/50 rounded-bl-xl transition-colors"
          >
            Cancelar
          </button>
          <button
            type="button"
            onClick={() => config.onConfirm(config.campoFecha ? fecha : undefined)}
            disabled={!!config.campoFecha && !fecha}
            className={`flex-1 px-4 py-3 border-l dark:border-gray-700 rounded-br-xl transition-colors disabled:opacity-50 disabled:cursor-not-allowed ${btn}`}
          >
            Confirmar
          </button>
        </div>
      </DialogContent>
    </Dialog>
  );
});

export default ModalConfirmacion;
