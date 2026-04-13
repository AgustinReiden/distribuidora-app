import { useState, useMemo, memo } from 'react';
import type { ChangeEvent } from 'react';
import { FileDown, Package, Truck, Printer, Eye } from 'lucide-react';
import ModalBase from './ModalBase';
import { formatPrecio } from '../../utils/formatters';
import type { PedidoDB, PerfilDB } from '../../types';

// =============================================================================
// TIPOS
// =============================================================================

/** Tipo de exportacion */
type TipoExport = 'preparacion' | 'ruta' | 'comanda' | 'vista_actual';

/** Props del componente principal */
export interface ModalExportarPDFProps {
  pedidos: PedidoDB[];
  transportistas: PerfilDB[];
  onExportarOrdenPreparacion: (pedidos: PedidoDB[]) => void;
  onExportarHojaRuta: (transportista: PerfilDB | undefined, pedidos: PedidoDB[]) => void;
  onImprimirComandas?: (pedidos: PedidoDB[]) => void;
  onClose: () => void;
}

const ModalExportarPDF = memo(function ModalExportarPDF({
  pedidos,
  transportistas,
  onExportarOrdenPreparacion,
  onExportarHojaRuta,
  onImprimirComandas,
  onClose
}: ModalExportarPDFProps) {
  const [tipoExport, setTipoExport] = useState<TipoExport>('preparacion');
  const [transportistaSeleccionado, setTransportistaSeleccionado] = useState<string>('');
  const [pedidosSeleccionados, setPedidosSeleccionados] = useState<string[]>([]);
  const [seleccionarTodos, setSeleccionarTodos] = useState<boolean>(false);

  // Filtrar pedidos segun el tipo de exportacion
  const pedidosFiltrados = useMemo((): PedidoDB[] => {
    if (tipoExport === 'vista_actual') {
      // Muestra todos los pedidos tal como los paso el padre (respeta filtros existentes)
      return pedidos;
    } else if (tipoExport === 'preparacion') {
      return pedidos.filter(p => p.estado === 'pendiente' || p.estado === 'en_preparacion');
    } else if (tipoExport === 'comanda') {
      // Para comandas: todos los pedidos no entregados y no cancelados
      let resultado = pedidos.filter(p => p.estado !== 'entregado' && p.estado !== 'cancelado');
      // Filtrar por transportista si se selecciono uno
      if (transportistaSeleccionado) {
        resultado = resultado.filter(p => p.transportista_id === transportistaSeleccionado);
      }
      return resultado;
    } else {
      if (!transportistaSeleccionado) return [];
      return pedidos.filter(p =>
        p.transportista_id === transportistaSeleccionado &&
        (p.estado === 'asignado' || p.estado === 'en_preparacion')
      );
    }
  }, [pedidos, tipoExport, transportistaSeleccionado]);

  // Manejar seleccion de todos
  const handleSeleccionarTodos = (checked: boolean): void => {
    setSeleccionarTodos(checked);
    if (checked) {
      setPedidosSeleccionados(pedidosFiltrados.map(p => p.id));
    } else {
      setPedidosSeleccionados([]);
    }
  };

  // Manejar seleccion individual
  const handleTogglePedido = (pedidoId: string): void => {
    setPedidosSeleccionados(prev => {
      if (prev.includes(pedidoId)) {
        const nuevo = prev.filter(id => id !== pedidoId);
        setSeleccionarTodos(false);
        return nuevo;
      } else {
        const nuevo = [...prev, pedidoId];
        if (nuevo.length === pedidosFiltrados.length) {
          setSeleccionarTodos(true);
        }
        return nuevo;
      }
    });
  };

  // Resetear seleccion cuando cambia el tipo o transportista
  const handleTipoChange = (tipo: TipoExport): void => {
    setTipoExport(tipo);
    setPedidosSeleccionados([]);
    setSeleccionarTodos(false);
    if (tipo !== 'ruta' && tipo !== 'comanda') {
      setTransportistaSeleccionado('');
    }
  };

  const handleTransportistaChange = (id: string): void => {
    setTransportistaSeleccionado(id);
    setPedidosSeleccionados([]);
    setSeleccionarTodos(false);
  };

  // Exportar
  const handleExportar = (): void => {
    const pedidosAExportar = pedidos.filter(p => pedidosSeleccionados.includes(p.id));
    if (pedidosAExportar.length === 0) return;

    if (tipoExport === 'vista_actual') {
      onImprimirComandas?.(pedidosAExportar);
    } else if (tipoExport === 'preparacion') {
      onExportarOrdenPreparacion(pedidosAExportar);
    } else if (tipoExport === 'comanda') {
      onImprimirComandas?.(pedidosAExportar);
    } else {
      const transportista = transportistas.find(t => t.id === transportistaSeleccionado);
      onExportarHojaRuta(transportista, pedidosAExportar);
    }
    onClose();
  };

  const getEstadoLabel = (e: string): string => e === 'pendiente' ? 'Pendiente' : e === 'en_preparacion' ? 'En preparacion' : e === 'asignado' ? 'En camino' : 'Entregado';
  const getEstadoColor = (e: string): string => e === 'pendiente' ? 'bg-yellow-100 text-yellow-800' : e === 'en_preparacion' ? 'bg-orange-100 text-orange-800' : e === 'asignado' ? 'bg-blue-100 text-blue-800' : 'bg-green-100 text-green-800';

  return (
    <ModalBase title="Exportar Pedidos a PDF" onClose={onClose} maxWidth="max-w-2xl">
      <div className="p-4 space-y-4">
        {/* Selector de tipo de exportacion */}
        <div>
          <label className="block text-sm font-medium mb-2">Tipo de documento</label>
          <div className="grid grid-cols-2 sm:grid-cols-4 gap-3">
            <button
              onClick={() => handleTipoChange('preparacion')}
              className={`flex items-center justify-center space-x-2 p-4 rounded-lg border-2 transition-colors ${
                tipoExport === 'preparacion'
                  ? 'border-orange-500 bg-orange-50 text-orange-700 dark:bg-orange-900/20 dark:text-orange-400'
                  : 'border-gray-200 dark:border-gray-600 hover:border-gray-300 dark:hover:border-gray-500'
              }`}
            >
              <Package className="w-6 h-6" />
              <div className="text-left">
                <p className="font-medium">Orden de Preparacion</p>
                <p className="text-xs text-gray-500 dark:text-gray-400">Para el deposito</p>
              </div>
            </button>
            <button
              onClick={() => handleTipoChange('ruta')}
              className={`flex items-center justify-center space-x-2 p-4 rounded-lg border-2 transition-colors ${
                tipoExport === 'ruta'
                  ? 'border-blue-500 bg-blue-50 text-blue-700 dark:bg-blue-900/20 dark:text-blue-400'
                  : 'border-gray-200 dark:border-gray-600 hover:border-gray-300 dark:hover:border-gray-500'
              }`}
            >
              <Truck className="w-6 h-6" />
              <div className="text-left">
                <p className="font-medium">Hoja de Ruta</p>
                <p className="text-xs text-gray-500 dark:text-gray-400">Para el transportista</p>
              </div>
            </button>
            <button
              onClick={() => handleTipoChange('comanda')}
              className={`flex items-center justify-center space-x-2 p-4 rounded-lg border-2 transition-colors ${
                tipoExport === 'comanda'
                  ? 'border-purple-500 bg-purple-50 text-purple-700 dark:bg-purple-900/20 dark:text-purple-400'
                  : 'border-gray-200 dark:border-gray-600 hover:border-gray-300 dark:hover:border-gray-500'
              }`}
            >
              <Printer className="w-6 h-6" />
              <div className="text-left">
                <p className="font-medium">Imprimir Comandas</p>
                <p className="text-xs text-gray-500 dark:text-gray-400">Duplicado por pedido</p>
              </div>
            </button>
            <button
              onClick={() => handleTipoChange('vista_actual')}
              className={`flex items-center justify-center space-x-2 p-4 rounded-lg border-2 transition-colors ${
                tipoExport === 'vista_actual'
                  ? 'border-slate-500 bg-slate-50 text-slate-700 dark:bg-slate-900/20 dark:text-slate-400'
                  : 'border-gray-200 dark:border-gray-600 hover:border-gray-300 dark:hover:border-gray-500'
              }`}
            >
              <Eye className="w-6 h-6" />
              <div className="text-left">
                <p className="font-medium">Vista Actual</p>
                <p className="text-xs text-gray-500 dark:text-gray-400">Pedidos filtrados</p>
              </div>
            </button>
          </div>
        </div>

        {/* Selector de transportista (para hoja de ruta y comandas) */}
        {(tipoExport === 'ruta' || tipoExport === 'comanda') && (
          <div>
            <label className="block text-sm font-medium mb-1">
              {tipoExport === 'comanda' ? 'Filtrar por transportista (opcional)' : 'Transportista'}
            </label>
            <select
              value={transportistaSeleccionado}
              onChange={(e: ChangeEvent<HTMLSelectElement>) => handleTransportistaChange(e.target.value)}
              className="w-full px-3 py-2 border rounded-lg"
            >
              <option value="">{tipoExport === 'comanda' ? 'Todos los transportistas' : 'Seleccionar transportista...'}</option>
              {transportistas.map(t => {
                const pedidosTransportista = pedidos.filter(p =>
                  p.transportista_id === t.id &&
                  (p.estado === 'asignado' || p.estado === 'en_preparacion')
                ).length;
                return (
                  <option key={t.id} value={t.id}>
                    {t.nombre} ({pedidosTransportista} pedidos)
                  </option>
                );
              })}
            </select>
          </div>
        )}

        {/* Lista de pedidos */}
        <div>
          <div className="flex justify-between items-center mb-2">
            <label className="block text-sm font-medium">
              Pedidos a exportar ({pedidosSeleccionados.length} de {pedidosFiltrados.length})
            </label>
            {pedidosFiltrados.length > 0 && (
              <label className="flex items-center space-x-2 text-sm cursor-pointer">
                <input
                  type="checkbox"
                  checked={seleccionarTodos}
                  onChange={(e: ChangeEvent<HTMLInputElement>) => handleSeleccionarTodos(e.target.checked)}
                  className="w-4 h-4 rounded"
                />
                <span>Seleccionar todos</span>
              </label>
            )}
          </div>

          {pedidosFiltrados.length === 0 ? (
            <div className="text-center py-8 text-gray-500 bg-gray-50 rounded-lg">
              {tipoExport === 'ruta' && !transportistaSeleccionado ? (
                <>
                  <Truck className="w-10 h-10 mx-auto mb-2 opacity-50" />
                  <p>Selecciona un transportista para ver sus pedidos</p>
                </>
              ) : (
                <>
                  <Package className="w-10 h-10 mx-auto mb-2 opacity-50" />
                  <p>No hay pedidos disponibles para exportar</p>
                  <p className="text-xs mt-1">
                    {tipoExport === 'preparacion'
                      ? 'Solo se muestran pedidos pendientes o en preparacion'
                      : 'Solo se muestran pedidos asignados al transportista'
                    }
                  </p>
                </>
              )}
            </div>
          ) : (
            <div className="border rounded-lg max-h-64 overflow-y-auto">
              {pedidosFiltrados.map(pedido => (
                <div
                  key={pedido.id}
                  onClick={() => handleTogglePedido(pedido.id)}
                  className={`flex items-center p-3 border-b last:border-b-0 cursor-pointer transition-colors ${
                    pedidosSeleccionados.includes(pedido.id)
                      ? 'bg-blue-50'
                      : 'hover:bg-gray-50'
                  }`}
                >
                  <input
                    type="checkbox"
                    checked={pedidosSeleccionados.includes(pedido.id)}
                    onChange={() => {}}
                    className="w-4 h-4 mr-3"
                  />
                  <div className="flex-1">
                    <div className="flex items-center justify-between">
                      <p className="font-medium">#{pedido.id} - {pedido.cliente?.nombre_fantasia}</p>
                      <span className={`px-2 py-0.5 rounded-full text-xs ${getEstadoColor(pedido.estado)}`}>
                        {getEstadoLabel(pedido.estado)}
                      </span>
                    </div>
                    <p className="text-sm text-gray-500">{pedido.cliente?.direccion}</p>
                    <p className="text-sm font-medium text-blue-600">{formatPrecio(pedido.total)}</p>
                  </div>
                </div>
              ))}
            </div>
          )}
        </div>
      </div>

      <div className="flex justify-between items-center p-4 border-t bg-gray-50">
        <p className="text-sm text-gray-600">
          {pedidosSeleccionados.length > 0 && (
            <>
              Total: {formatPrecio(
                pedidos
                  .filter(p => pedidosSeleccionados.includes(p.id))
                  .reduce((sum, p) => sum + (p.total || 0), 0)
              )}
            </>
          )}
        </p>
        <div className="flex space-x-3">
          <button onClick={onClose} className="px-4 py-2 text-gray-700 hover:bg-gray-200 rounded-lg">
            Cancelar
          </button>
          <button
            onClick={handleExportar}
            disabled={pedidosSeleccionados.length === 0}
            className={`flex items-center space-x-2 px-4 py-2 text-white rounded-lg disabled:opacity-50 disabled:cursor-not-allowed ${
              tipoExport === 'comanda'
                ? 'bg-purple-600 hover:bg-purple-700'
                : 'bg-green-600 hover:bg-green-700'
            }`}
          >
            {tipoExport === 'comanda' ? <Printer className="w-4 h-4" /> : <FileDown className="w-4 h-4" />}
            <span>{tipoExport === 'comanda' ? 'Imprimir Comandas' : 'Exportar PDF'}</span>
          </button>
        </div>
      </div>
    </ModalBase>
  );
});

export default ModalExportarPDF;
