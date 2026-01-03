import React, { memo } from 'react';
import { X } from 'lucide-react';

// Modal base reutilizable
const ModalBase = memo(function ModalBase({ children, onClose, title, maxWidth = 'max-w-md' }) {
  return (
    <div className="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center p-4 z-50">
      <div className={`bg-white rounded-xl shadow-xl w-full ${maxWidth}`}>
        <div className="flex justify-between items-center p-4 border-b">
          <h2 className="text-xl font-semibold">{title}</h2>
          <button onClick={onClose}><X className="w-6 h-6 text-gray-500" /></button>
        </div>
        {children}
      </div>
    </div>
  );
});

export default ModalBase;
