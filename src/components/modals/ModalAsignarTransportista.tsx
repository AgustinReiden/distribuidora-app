import { useState, memo } from 'react';
import { Loader2 } from 'lucide-react';
import ModalBase from './ModalBase';
import type { PedidoDB, PerfilDB } from '../../types';

/** Props del componente ModalAsignarTransportista */
export interface ModalAsignarTransportistaProps {
  /** Pedido a asignar */
  pedido: PedidoDB | null;
  /** Lista de transportistas disponibles */
  transportistas: PerfilDB[];
  /** Callback al guardar */
  onSave: (transportistaId: string, marcarListo: boolean) => void | Promise<void>;
  /** Callback al cerrar */
  onClose: () => void;
  /** Indica si está guardando */
  guardando: boolean;
}

const ModalAsignarTransportista = memo(function ModalAsignarTransportista({ pedido, transportistas, onSave, onClose, guardando }: ModalAsignarTransportistaProps) {
  const [sel, setSel] = useState<string>(pedido?.transportista_id || '');
  const [marcarListo, setMarcarListo] = useState<boolean>(false);

  // Verificar si el pedido ya esta en estado 'asignado'
  const yaEstaAsignado = pedido?.estado === 'asignado';

  return (
    <ModalBase title="Asignar Transportista" onClose={onClose}>
      <div className="p-4 space-y-4">
        <div className="bg-gray-50 rounded-lg p-3">
          <p className="text-sm text-gray-600">Pedido #{pedido?.id}</p>
          <p className="font-medium">{pedido?.cliente?.nombre_fantasia}</p>
          <p className="text-sm text-gray-500">{pedido?.cliente?.direccion}</p>
          <div className="mt-2">
            <span className={`px-2 py-1 rounded-full text-xs font-medium ${
              pedido?.estado === 'pendiente' ? 'bg-yellow-100 text-yellow-800' :
              pedido?.estado === 'en_preparacion' ? 'bg-orange-100 text-orange-800' :
              pedido?.estado === 'asignado' ? 'bg-blue-100 text-blue-800' :
              'bg-green-100 text-green-800'
            }`}>
              {pedido?.estado === 'pendiente' ? 'Pendiente de preparar' :
               pedido?.estado === 'en_preparacion' ? 'En preparacion' :
               pedido?.estado === 'asignado' ? 'Listo para entregar' : 'Entregado'}
            </span>
          </div>
        </div>

        <div>
          <label className="block text-sm font-medium mb-1">Transportista</label>
          <select value={sel} onChange={e => setSel(e.target.value)} className="w-full px-3 py-2 border rounded-lg">
            <option value="">Sin asignar</option>
            {transportistas.map(t => <option key={t.id} value={t.id}>{t.nombre}</option>)}
          </select>
        </div>

        {/* Opcion para marcar como listo (solo si hay transportista y no esta ya asignado) */}
        {sel && !yaEstaAsignado && (
          <div className="bg-blue-50 border border-blue-200 rounded-lg p-3">
            <label className="flex items-start space-x-3 cursor-pointer">
              <input
                type="checkbox"
                checked={marcarListo}
                onChange={e => setMarcarListo(e.target.checked)}
                className="w-5 h-5 mt-0.5 rounded border-blue-300"
              />
              <div>
                <span className="font-medium text-blue-800">Marcar como listo para entregar</span>
                <p className="text-sm text-blue-600 mt-1">
                  Si NO marcas esta opcion, el pedido mantendra su estado actual
                  {pedido?.estado === 'pendiente' && ' (pendiente de preparar)'}.
                  El transportista podra verlo pero sabra que aun no esta listo.
                </p>
              </div>
            </label>
          </div>
        )}

        {!sel && pedido?.transportista_id && (
          <div className="bg-yellow-50 border border-yellow-200 rounded-lg p-3">
            <p className="text-sm text-yellow-800">
              Al desasignar el transportista, el pedido mantendra su estado actual.
            </p>
          </div>
        )}
      </div>
      <div className="flex justify-end space-x-3 p-4 border-t bg-gray-50">
        <button onClick={onClose} className="px-4 py-2 text-gray-700 hover:bg-gray-200 rounded-lg">Cancelar</button>
        <button onClick={() => onSave(sel, marcarListo)} disabled={guardando} className="px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 flex items-center">
          {guardando && <Loader2 className="w-4 h-4 mr-2 animate-spin" />}Guardar
        </button>
      </div>
    </ModalBase>
  );
});

export default ModalAsignarTransportista;
