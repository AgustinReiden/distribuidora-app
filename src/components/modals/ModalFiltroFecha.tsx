import { useState, memo } from 'react';
import ModalBase from './ModalBase';
import { Button } from '../ui/Button';

interface FiltrosFecha {
  fechaDesde: string | null;
  fechaHasta: string | null;
}

interface ModalFiltroFechaProps {
  filtros: FiltrosFecha;
  onApply: (filtros: FiltrosFecha) => void;
  onClose: () => void;
}

const ModalFiltroFecha = memo(function ModalFiltroFecha({ filtros, onApply, onClose }: ModalFiltroFechaProps) {
  const [fechaDesde, setFechaDesde] = useState(filtros.fechaDesde || '');
  const [fechaHasta, setFechaHasta] = useState(filtros.fechaHasta || '');

  return (
    <ModalBase title="Filtrar por Fecha" onClose={onClose}>
      <div className="p-4 space-y-4">
        <div><label className="block text-sm font-medium mb-1">Desde</label><input type="date" value={fechaDesde} onChange={e => setFechaDesde(e.target.value)} className="w-full px-3 py-2 border rounded-lg" /></div>
        <div><label className="block text-sm font-medium mb-1">Hasta</label><input type="date" value={fechaHasta} onChange={e => setFechaHasta(e.target.value)} className="w-full px-3 py-2 border rounded-lg" /></div>
      </div>
      <div className="flex justify-between p-4 border-t dark:border-gray-700 bg-gray-50 dark:bg-gray-800">
        <Button onClick={() => { onApply({ fechaDesde: null, fechaHasta: null }); onClose(); }} variant="ghost" size="md">Limpiar</Button>
        <Button onClick={() => { onApply({ fechaDesde: fechaDesde || null, fechaHasta: fechaHasta || null }); onClose(); }} variant="primary" size="md">Aplicar</Button>
      </div>
    </ModalBase>
  );
});

export default ModalFiltroFecha;
