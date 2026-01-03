import React, { memo } from 'react';
import { Trash2, AlertTriangle, Check } from 'lucide-react';

const ModalConfirmacion = memo(function ModalConfirmacion({ config, onClose }) {
  if (!config?.visible) return null;

  const iconConfig = {
    danger: { bg: 'bg-red-100', icon: <Trash2 className="w-6 h-6 text-red-600" />, btn: 'text-red-600 hover:bg-red-50' },
    warning: { bg: 'bg-yellow-100', icon: <AlertTriangle className="w-6 h-6 text-yellow-600" />, btn: 'text-yellow-600 hover:bg-yellow-50' },
    success: { bg: 'bg-green-100', icon: <Check className="w-6 h-6 text-green-600" />, btn: 'text-green-600 hover:bg-green-50' }
  };
  const { bg, icon, btn } = iconConfig[config.tipo] || iconConfig.success;

  return (
    <div className="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center p-4 z-50">
      <div className="bg-white rounded-xl shadow-xl w-full max-w-sm">
        <div className="p-6">
          <div className={`flex items-center justify-center w-12 h-12 mx-auto mb-4 rounded-full ${bg}`}>{icon}</div>
          <h3 className="text-lg font-semibold text-center mb-2">{config.titulo}</h3>
          <p className="text-center text-gray-600">{config.mensaje}</p>
        </div>
        <div className="flex border-t">
          <button onClick={onClose} className="flex-1 px-4 py-3 text-gray-700 hover:bg-gray-50 rounded-bl-xl">Cancelar</button>
          <button onClick={config.onConfirm} className={`flex-1 px-4 py-3 border-l rounded-br-xl ${btn}`}>Confirmar</button>
        </div>
      </div>
    </div>
  );
});

export default ModalConfirmacion;
