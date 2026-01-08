import React, { memo, useEffect } from 'react';
import { X } from 'lucide-react';

// Modal base reutilizable
const ModalBase = memo(function ModalBase({ children, onClose, title, maxWidth = 'max-w-md' }) {
  // Bloquear scroll del body cuando el modal está abierto
  useEffect(() => {
    const originalStyle = window.getComputedStyle(document.body).overflow;
    document.body.style.overflow = 'hidden';
    return () => {
      document.body.style.overflow = originalStyle;
    };
  }, []);

  // Prevenir scroll del fondo en móviles
  const handleTouchMove = (e) => {
    e.stopPropagation();
  };

  return (
    <div
      className="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center p-4 z-50 overflow-hidden"
      onTouchMove={handleTouchMove}
    >
      <div
        className={`bg-white dark:bg-gray-800 rounded-xl shadow-xl w-full ${maxWidth} max-h-[90vh] flex flex-col overflow-hidden`}
        style={{ overscrollBehavior: 'contain' }}
      >
        <div className="flex justify-between items-center p-4 border-b dark:border-gray-700 flex-shrink-0">
          <h2 className="text-xl font-semibold dark:text-white">{title}</h2>
          <button onClick={onClose} className="p-1 hover:bg-gray-100 dark:hover:bg-gray-700 rounded-lg">
            <X className="w-6 h-6 text-gray-500 dark:text-gray-400" />
          </button>
        </div>
        <div className="flex-1 overflow-y-auto overscroll-contain">
          {children}
        </div>
      </div>
    </div>
  );
});

export default ModalBase;
