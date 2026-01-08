import React, { useState, memo, useEffect } from 'react';
import { Loader2, DollarSign, AlertCircle } from 'lucide-react';
import ModalBase from './ModalBase';
import { formatPrecio } from '../../utils/formatters';

const ModalEditarPedido = memo(function ModalEditarPedido({ pedido, onSave, onClose, guardando }) {
  const [notas, setNotas] = useState(pedido?.notas || "");
  const [formaPago, setFormaPago] = useState(pedido?.forma_pago || "efectivo");
  const [estadoPago, setEstadoPago] = useState(pedido?.estado_pago || "pendiente");
  const [montoPagado, setMontoPagado] = useState(pedido?.monto_pagado || 0);

  const total = pedido?.total || 0;
  const saldoPendiente = total - montoPagado;

  // Cuando cambia el estado de pago, ajustar el monto
  useEffect(() => {
    if (estadoPago === 'pagado') {
      setMontoPagado(total);
    } else if (estadoPago === 'pendiente') {
      setMontoPagado(0);
    }
  }, [estadoPago, total]);

  // Cuando cambia el monto, actualizar el estado automáticamente
  const handleMontoPagadoChange = (valor) => {
    const monto = parseFloat(valor) || 0;
    setMontoPagado(monto);

    // Actualizar estado automáticamente
    if (monto >= total) {
      setEstadoPago('pagado');
    } else if (monto > 0) {
      setEstadoPago('parcial');
    } else {
      setEstadoPago('pendiente');
    }
  };

  // Botones de porcentaje rápido
  const aplicarPorcentaje = (porcentaje) => {
    const monto = (total * porcentaje) / 100;
    handleMontoPagadoChange(monto);
  };

  const handleGuardar = () => {
    onSave({ notas, formaPago, estadoPago, montoPagado: parseFloat(montoPagado) || 0 });
  };

  return (
    <ModalBase title={`Editar Pedido #${pedido?.id}`} onClose={onClose} maxWidth="max-w-lg">
      <div className="p-4 space-y-4">
        {/* Info del cliente */}
        <div className="bg-gray-50 dark:bg-gray-700 rounded-lg p-3 border dark:border-gray-600">
          <p className="text-sm text-gray-600 dark:text-gray-400">Cliente</p>
          <p className="font-medium dark:text-white">{pedido?.cliente?.nombre_fantasia}</p>
          <p className="text-sm text-gray-500 dark:text-gray-400">{pedido?.cliente?.direccion}</p>
        </div>

        {/* Total del pedido */}
        <div className="bg-blue-50 dark:bg-blue-900/30 rounded-lg p-4 border border-blue-200 dark:border-blue-800">
          <div className="flex justify-between items-center">
            <span className="text-blue-700 dark:text-blue-300 font-medium">Total del Pedido</span>
            <span className="text-2xl font-bold text-blue-600 dark:text-blue-400">{formatPrecio(total)}</span>
          </div>
        </div>

        {/* Notas */}
        <div>
          <label className="block text-sm font-medium mb-1 dark:text-gray-200">Notas / Observaciones</label>
          <textarea
            value={notas}
            onChange={e => setNotas(e.target.value)}
            className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white"
            placeholder="Observaciones importantes para la preparación del pedido..."
            rows={2}
          />
        </div>

        {/* Forma de Pago */}
        <div>
          <label className="block text-sm font-medium mb-1 dark:text-gray-200">Forma de Pago</label>
          <select
            value={formaPago}
            onChange={e => setFormaPago(e.target.value)}
            className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white"
          >
            <option value="efectivo">Efectivo</option>
            <option value="transferencia">Transferencia</option>
            <option value="cheque">Cheque</option>
            <option value="cuenta_corriente">Cuenta Corriente</option>
            <option value="tarjeta">Tarjeta</option>
          </select>
        </div>

        {/* Sección de pago mejorada */}
        <div className="border dark:border-gray-600 rounded-lg p-4 space-y-4">
          <div className="flex items-center gap-2">
            <DollarSign className="w-5 h-5 text-green-600" />
            <span className="font-medium dark:text-gray-200">Estado de Pago</span>
          </div>

          {/* Estado de pago */}
          <div className="grid grid-cols-3 gap-2">
            <button
              type="button"
              onClick={() => setEstadoPago('pendiente')}
              className={`py-2 px-3 rounded-lg text-sm font-medium transition-colors ${
                estadoPago === 'pendiente'
                  ? 'bg-red-100 text-red-700 border-2 border-red-500 dark:bg-red-900/30 dark:text-red-400 dark:border-red-600'
                  : 'bg-gray-100 text-gray-600 border border-gray-300 hover:bg-gray-200 dark:bg-gray-700 dark:text-gray-400 dark:border-gray-600'
              }`}
            >
              Pendiente
            </button>
            <button
              type="button"
              onClick={() => setEstadoPago('parcial')}
              className={`py-2 px-3 rounded-lg text-sm font-medium transition-colors ${
                estadoPago === 'parcial'
                  ? 'bg-yellow-100 text-yellow-700 border-2 border-yellow-500 dark:bg-yellow-900/30 dark:text-yellow-400 dark:border-yellow-600'
                  : 'bg-gray-100 text-gray-600 border border-gray-300 hover:bg-gray-200 dark:bg-gray-700 dark:text-gray-400 dark:border-gray-600'
              }`}
            >
              Parcial
            </button>
            <button
              type="button"
              onClick={() => setEstadoPago('pagado')}
              className={`py-2 px-3 rounded-lg text-sm font-medium transition-colors ${
                estadoPago === 'pagado'
                  ? 'bg-green-100 text-green-700 border-2 border-green-500 dark:bg-green-900/30 dark:text-green-400 dark:border-green-600'
                  : 'bg-gray-100 text-gray-600 border border-gray-300 hover:bg-gray-200 dark:bg-gray-700 dark:text-gray-400 dark:border-gray-600'
              }`}
            >
              Pagado
            </button>
          </div>

          {/* Monto pagado - visible cuando es parcial o para editar */}
          <div>
            <label className="block text-sm font-medium mb-1 dark:text-gray-200">
              Monto Pagado
            </label>
            <div className="relative">
              <span className="absolute left-3 top-1/2 -translate-y-1/2 text-gray-500">$</span>
              <input
                type="number"
                min="0"
                max={total}
                step="0.01"
                value={montoPagado}
                onChange={e => handleMontoPagadoChange(e.target.value)}
                className="w-full pl-8 pr-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white"
                placeholder="0.00"
              />
            </div>

            {/* Botones de porcentaje rápido */}
            <div className="flex gap-2 mt-2">
              {[25, 50, 75, 100].map(pct => (
                <button
                  key={pct}
                  type="button"
                  onClick={() => aplicarPorcentaje(pct)}
                  className="flex-1 py-1 text-xs bg-gray-100 hover:bg-gray-200 dark:bg-gray-700 dark:hover:bg-gray-600 rounded transition-colors dark:text-gray-300"
                >
                  {pct}%
                </button>
              ))}
            </div>
          </div>

          {/* Resumen de pagos */}
          {estadoPago === 'parcial' && saldoPendiente > 0 && (
            <div className="bg-yellow-50 dark:bg-yellow-900/20 border border-yellow-200 dark:border-yellow-800 rounded-lg p-3">
              <div className="flex items-start gap-2">
                <AlertCircle className="w-5 h-5 text-yellow-600 flex-shrink-0 mt-0.5" />
                <div className="text-sm">
                  <p className="font-medium text-yellow-800 dark:text-yellow-300">Pago Parcial</p>
                  <div className="mt-1 space-y-1 text-yellow-700 dark:text-yellow-400">
                    <p>Pagado: <span className="font-semibold">{formatPrecio(montoPagado)}</span></p>
                    <p>Pendiente: <span className="font-semibold text-red-600 dark:text-red-400">{formatPrecio(saldoPendiente)}</span></p>
                  </div>
                </div>
              </div>
            </div>
          )}
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

export default ModalEditarPedido;
