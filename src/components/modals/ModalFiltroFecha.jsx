import React, { useState, memo } from 'react';
import ModalBase from './ModalBase';

const ModalFiltroFecha = memo(function ModalFiltroFecha({ filtros, onApply, onClose }) {
  const [fechaDesde, setFechaDesde] = useState(filtros.fechaDesde || '');
  const [fechaHasta, setFechaHasta] = useState(filtros.fechaHasta || '');

  return (
    <ModalBase title="Filtrar por Fecha" onClose={onClose}>
      <div className="p-4 space-y-4">
        <div><label className="block text-sm font-medium mb-1">Desde</label><input type="date" value={fechaDesde} onChange={e => setFechaDesde(e.target.value)} className="w-full px-3 py-2 border rounded-lg" /></div>
        <div><label className="block text-sm font-medium mb-1">Hasta</label><input type="date" value={fechaHasta} onChange={e => setFechaHasta(e.target.value)} className="w-full px-3 py-2 border rounded-lg" /></div>
      </div>
      <div className="flex justify-between p-4 border-t bg-gray-50">
        <button onClick={() => { onApply({ fechaDesde: null, fechaHasta: null }); onClose(); }} className="px-4 py-2 text-gray-700 hover:bg-gray-200 rounded-lg">Limpiar</button>
        <button onClick={() => { onApply({ fechaDesde: fechaDesde || null, fechaHasta: fechaHasta || null }); onClose(); }} className="px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700">Aplicar</button>
      </div>
    </ModalBase>
  );
});

export default ModalFiltroFecha;
