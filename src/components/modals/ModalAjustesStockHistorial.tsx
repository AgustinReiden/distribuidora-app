/**
 * ModalAjustesStockHistorial
 *
 * Histórico de ajustes de control de stock, agrupado por carga de planilla
 * (sesión). Cada sesión muestra fecha, usuario y totales (+altas/-bajas) y se
 * expande para ver el detalle producto por producto. Lo ven admin y encargado.
 */
import { useMemo, useState, memo } from 'react';
import { Loader2, History, ChevronDown, ChevronRight, TrendingUp, TrendingDown } from 'lucide-react';
import ModalBase from './ModalBase';
import { formatFecha } from './utils';
import { useControlStockSesionesQuery, useControlStockDetalleQuery } from '../../hooks/queries/useControlStockQuery';
import type { ProductoDB } from '../../types';

export interface ModalAjustesStockHistorialProps {
  productos: ProductoDB[];
  onClose: () => void;
}

function DetalleSesion({ sesionId, productosMap }: { sesionId: number; productosMap: Map<string, string> }) {
  const { data: detalle = [], isLoading } = useControlStockDetalleQuery(sesionId);

  if (isLoading) {
    return (
      <div className="flex justify-center py-3">
        <Loader2 className="w-5 h-5 animate-spin text-blue-600" />
      </div>
    );
  }
  if (detalle.length === 0) {
    return <p className="px-3 py-2 text-sm text-gray-500">Sin detalle.</p>;
  }
  return (
    <div className="divide-y dark:divide-gray-700">
      {detalle.map(d => {
        const dif = d.diferencia ?? (d.stock_nuevo - d.stock_anterior);
        return (
          <div key={d.id} className="flex items-center justify-between gap-2 px-3 py-1.5 text-sm">
            <span className="truncate dark:text-gray-200">{productosMap.get(String(d.producto_id)) || `Producto #${d.producto_id}`}</span>
            <span className="flex items-center gap-2 shrink-0">
              <span className="text-gray-400">{d.stock_anterior}</span>
              <span className="text-gray-400">→</span>
              <span className="font-medium dark:text-gray-100">{d.stock_nuevo}</span>
              <span className={`w-12 text-right font-semibold ${dif > 0 ? 'text-emerald-600' : 'text-rose-600'}`}>
                {dif > 0 ? '+' : ''}{dif}
              </span>
            </span>
          </div>
        );
      })}
    </div>
  );
}

const ModalAjustesStockHistorial = memo(function ModalAjustesStockHistorial({ productos, onClose }: ModalAjustesStockHistorialProps) {
  const { data: sesiones = [], isLoading } = useControlStockSesionesQuery();
  const [expandida, setExpandida] = useState<number | null>(null);

  const productosMap = useMemo(
    () => new Map(productos.map(p => [String(p.id), p.nombre])),
    [productos]
  );

  return (
    <ModalBase title="Ajustes de stock" onClose={onClose} maxWidth="max-w-2xl">
      <div className="p-4">
        {isLoading ? (
          <div className="flex justify-center py-8">
            <Loader2 className="w-8 h-8 animate-spin text-blue-600" />
          </div>
        ) : sesiones.length === 0 ? (
          <div className="text-center py-8 text-gray-500">
            <History className="w-12 h-12 mx-auto mb-3 opacity-50" />
            <p>Todavía no se cargaron planillas de control de stock.</p>
          </div>
        ) : (
          <div className="space-y-2 max-h-[60vh] overflow-y-auto">
            {sesiones.map(s => {
              const abierta = expandida === s.id;
              return (
                <div key={s.id} className="border rounded-lg dark:border-gray-700 overflow-hidden">
                  <button
                    type="button"
                    onClick={() => setExpandida(abierta ? null : s.id)}
                    className="w-full flex items-center justify-between gap-2 px-3 py-2.5 text-left hover:bg-gray-50 dark:hover:bg-gray-700/40"
                  >
                    <div className="min-w-0">
                      <p className="font-medium text-sm text-gray-900 dark:text-gray-100">{formatFecha(s.fecha)}</p>
                      <p className="text-xs text-gray-500">
                        {s.usuario?.nombre || 'Sistema'} · {s.total_items} ítem{s.total_items === 1 ? '' : 's'}
                      </p>
                    </div>
                    <div className="flex items-center gap-3 shrink-0">
                      <span className="inline-flex items-center gap-1 text-xs text-emerald-600 font-medium">
                        <TrendingUp className="w-3.5 h-3.5" />+{s.total_altas}
                      </span>
                      <span className="inline-flex items-center gap-1 text-xs text-rose-600 font-medium">
                        <TrendingDown className="w-3.5 h-3.5" />-{s.total_bajas}
                      </span>
                      {abierta ? <ChevronDown className="w-4 h-4 text-gray-400" /> : <ChevronRight className="w-4 h-4 text-gray-400" />}
                    </div>
                  </button>
                  {abierta && (
                    <div className="border-t dark:border-gray-700 bg-gray-50/60 dark:bg-gray-800/40">
                      <DetalleSesion sesionId={s.id} productosMap={productosMap} />
                    </div>
                  )}
                </div>
              );
            })}
          </div>
        )}
      </div>
      <div className="flex justify-end p-4 border-t bg-gray-50 dark:bg-gray-800 dark:border-gray-700">
        <button onClick={onClose} className="px-4 py-2 bg-gray-600 text-white rounded-lg hover:bg-gray-700">Cerrar</button>
      </div>
    </ModalBase>
  );
});

export default ModalAjustesStockHistorial;
