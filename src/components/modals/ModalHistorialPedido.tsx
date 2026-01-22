import React, { memo } from 'react';
import { Loader2, History } from 'lucide-react';
import ModalBase from './ModalBase';
import { formatFecha } from './utils';
import { formatPrecio } from '../../utils/formatters';

const ModalHistorialPedido = memo(function ModalHistorialPedido({ pedido, historial, onClose, loading }) {
  const formatearCampo = (campo) => {
    const mapeo = {
      estado: "Estado",
      transportista_id: "Transportista",
      notas: "Notas",
      forma_pago: "Forma de pago",
      estado_pago: "Estado de pago",
      total: "Total",
      creacion: "Creacion"
    };
    return mapeo[campo] || campo;
  };

  const formatearValor = (campo, valor) => {
    if (campo === "total") return formatPrecio(parseFloat(valor));
    if (campo === "estado") {
      const estados = { pendiente: "Pendiente", en_preparacion: "En preparacion", asignado: "En camino", entregado: "Entregado" };
      return estados[valor] || valor;
    }
    if (campo === "estado_pago") {
      const estados = { pendiente: "Pendiente", pagado: "Pagado", parcial: "Parcial" };
      return estados[valor] || valor;
    }
    if (campo === "forma_pago") {
      const formas = {
        efectivo: "Efectivo",
        transferencia: "Transferencia",
        cheque: "Cheque",
        cuenta_corriente: "Cuenta Corriente",
        tarjeta: "Tarjeta"
      };
      return formas[valor] || valor;
    }
    return valor;
  };

  return (
    <ModalBase title={`Historial de cambios - Pedido #${pedido?.id}`} onClose={onClose} maxWidth="max-w-2xl">
      <div className="p-4">
        {loading ? (
          <div className="flex justify-center py-8">
            <Loader2 className="w-8 h-8 animate-spin text-blue-600" />
          </div>
        ) : historial.length === 0 ? (
          <div className="text-center py-8 text-gray-500">
            <History className="w-12 h-12 mx-auto mb-3 opacity-50" />
            <p>No hay cambios registrados para este pedido</p>
          </div>
        ) : (
          <div className="space-y-3 max-h-96 overflow-y-auto">
            {historial.map((cambio, index) => (
              <div key={cambio.id || index} className="border rounded-lg p-3 bg-gray-50">
                <div className="flex justify-between items-start mb-2">
                  <div>
                    <p className="font-medium text-gray-900">
                      {formatearCampo(cambio.campo_modificado)}
                    </p>
                    <p className="text-sm text-gray-600">
                      {cambio.usuario?.nombre || "Usuario desconocido"}
                    </p>
                  </div>
                  <p className="text-xs text-gray-500">{formatFecha(cambio.created_at)}</p>
                </div>
                {cambio.campo_modificado === "creacion" ? (
                  <p className="text-sm text-green-600 font-medium">{cambio.valor_nuevo}</p>
                ) : (
                  <div className="flex items-center space-x-2 text-sm">
                    <span className="px-2 py-1 bg-red-100 text-red-700 rounded">
                      {formatearValor(cambio.campo_modificado, cambio.valor_anterior)}
                    </span>
                    <span className="text-gray-400">→</span>
                    <span className="px-2 py-1 bg-green-100 text-green-700 rounded">
                      {formatearValor(cambio.campo_modificado, cambio.valor_nuevo)}
                    </span>
                  </div>
                )}
              </div>
            ))}
          </div>
        )}
      </div>
      <div className="flex justify-end p-4 border-t bg-gray-50">
        <button onClick={onClose} className="px-4 py-2 bg-gray-600 text-white rounded-lg hover:bg-gray-700">
          Cerrar
        </button>
      </div>
    </ModalBase>
  );
});

export default ModalHistorialPedido;
