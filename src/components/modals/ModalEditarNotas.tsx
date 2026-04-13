import { useState, memo } from 'react';
import { Loader2 } from 'lucide-react';
import ModalBase from './ModalBase';
import type { PedidoDB } from '../../types';

export interface ModalEditarNotasProps {
  pedido: PedidoDB | null;
  onSave: (notas: string) => Promise<void>;
  onClose: () => void;
  guardando: boolean;
}

const ModalEditarNotas = memo(function ModalEditarNotas({
  pedido,
  onSave,
  onClose,
  guardando
}: ModalEditarNotasProps) {
  const [notas, setNotas] = useState<string>(pedido?.notas || '');

  const handleGuardar = async () => {
    await onSave(notas);
  };

  return (
    <ModalBase
      title={`Observaciones - Pedido #${pedido?.id}`}
      description="Editar las observaciones del pedido"
      onClose={onClose}
      maxWidth="max-w-lg"
    >
      <div className="p-4 space-y-4">
        {/* Info del cliente */}
        <div className="bg-gray-50 dark:bg-gray-700 rounded-lg p-3 border dark:border-gray-600">
          <p className="text-sm text-gray-600 dark:text-gray-400">Cliente</p>
          <p className="font-medium dark:text-white">{pedido?.cliente?.nombre_fantasia}</p>
        </div>

        {/* Notas */}
        <div>
          <label className="block text-sm font-medium mb-1 dark:text-gray-200">
            Observaciones
          </label>
          <textarea
            value={notas}
            onChange={e => setNotas(e.target.value)}
            className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white"
            placeholder="Observaciones del pedido..."
            rows={4}
            autoFocus
          />
        </div>
      </div>

      <div className="flex justify-end space-x-3 p-4 border-t bg-gray-50 dark:bg-gray-800">
        <button
          onClick={onClose}
          className="px-4 py-2 text-gray-700 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-700 rounded-lg"
        >
          Cancelar
        </button>
        <button
          onClick={handleGuardar}
          disabled={guardando}
          className="px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 flex items-center disabled:opacity-50"
        >
          {guardando && <Loader2 className="w-4 h-4 mr-2 animate-spin" />}
          Guardar
        </button>
      </div>
    </ModalBase>
  );
});

export default ModalEditarNotas;
