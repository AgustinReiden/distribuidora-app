import React, { useState, memo } from 'react';
import { Loader2 } from 'lucide-react';
import ModalBase from './ModalBase';

const ModalEditarPedido = memo(function ModalEditarPedido({ pedido, onSave, onClose, guardando }) {
  const [notas, setNotas] = useState(pedido?.notas || "");
  const [formaPago, setFormaPago] = useState(pedido?.forma_pago || "efectivo");
  const [estadoPago, setEstadoPago] = useState(pedido?.estado_pago || "pendiente");

  const handleGuardar = () => {
    onSave({ notas, formaPago, estadoPago });
  };

  return (
    <ModalBase title={`Editar Pedido #${pedido?.id}`} onClose={onClose}>
      <div className="p-4 space-y-4">
        <div className="bg-gray-50 rounded-lg p-3 border">
          <p className="text-sm text-gray-600">Cliente</p>
          <p className="font-medium">{pedido?.cliente?.nombre_fantasia}</p>
          <p className="text-sm text-gray-500">{pedido?.cliente?.direccion}</p>
        </div>

        <div>
          <label className="block text-sm font-medium mb-1">Notas / Observaciones</label>
          <textarea
            value={notas}
            onChange={e => setNotas(e.target.value)}
            className="w-full px-3 py-2 border rounded-lg"
            placeholder="Observaciones importantes para la preparacion del pedido..."
            rows={3}
          />
        </div>

        <div className="grid grid-cols-2 gap-4">
          <div>
            <label className="block text-sm font-medium mb-1">Forma de Pago</label>
            <select
              value={formaPago}
              onChange={e => setFormaPago(e.target.value)}
              className="w-full px-3 py-2 border rounded-lg"
            >
              <option value="efectivo">Efectivo</option>
              <option value="transferencia">Transferencia</option>
              <option value="cheque">Cheque</option>
              <option value="cuenta_corriente">Cuenta Corriente</option>
              <option value="tarjeta">Tarjeta</option>
            </select>
          </div>
          <div>
            <label className="block text-sm font-medium mb-1">Estado de Pago</label>
            <select
              value={estadoPago}
              onChange={e => setEstadoPago(e.target.value)}
              className="w-full px-3 py-2 border rounded-lg"
            >
              <option value="pendiente">Pendiente</option>
              <option value="pagado">Pagado</option>
              <option value="parcial">Parcial</option>
            </select>
          </div>
        </div>
      </div>
      <div className="flex justify-end space-x-3 p-4 border-t bg-gray-50">
        <button onClick={onClose} className="px-4 py-2 text-gray-700 hover:bg-gray-200 rounded-lg">
          Cancelar
        </button>
        <button onClick={handleGuardar} disabled={guardando} className="px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 flex items-center">
          {guardando && <Loader2 className="w-4 h-4 mr-2 animate-spin" />}Guardar
        </button>
      </div>
    </ModalBase>
  );
});

export default ModalEditarPedido;
