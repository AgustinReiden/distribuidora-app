import React, { memo, useId } from 'react';
import PropTypes from 'prop-types';
import { Trash2, AlertTriangle, Check } from 'lucide-react';

/**
 * Modal de confirmación reutilizable
 * Soporta tipos: danger (eliminar), warning (advertencia), success (éxito)
 *
 * @param {Object} props
 * @param {Object} props.config - Configuración del modal
 * @param {boolean} props.config.visible - Si el modal está visible
 * @param {string} props.config.tipo - Tipo de modal: 'danger' | 'warning' | 'success'
 * @param {string} props.config.titulo - Título del modal
 * @param {string} props.config.mensaje - Mensaje descriptivo
 * @param {Function} props.config.onConfirm - Callback al confirmar
 * @param {Function} props.onClose - Callback al cerrar/cancelar
 */
const ModalConfirmacion = memo(function ModalConfirmacion({ config, onClose }) {
  const titleId = useId();
  const descId = useId();

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
            onClick={config.onConfirm}
            className={`flex-1 px-4 py-3 border-l rounded-br-xl transition-colors ${btn}`}
          >
            Confirmar
          </button>
        </div>
      </div>
    </div>
  );
});

ModalConfirmacion.propTypes = {
  /** Configuración del modal */
  config: PropTypes.shape({
    /** Si el modal está visible */
    visible: PropTypes.bool,
    /** Tipo de modal que determina colores e icono */
    tipo: PropTypes.oneOf(['danger', 'warning', 'success']),
    /** Título del modal */
    titulo: PropTypes.string,
    /** Mensaje descriptivo */
    mensaje: PropTypes.string,
    /** Callback ejecutado al confirmar */
    onConfirm: PropTypes.func
  }),
  /** Callback ejecutado al cerrar o cancelar */
  onClose: PropTypes.func.isRequired
};

export default ModalConfirmacion;
