/**
 * Vista principal de pedidos
 *
 * Recibe datos ya paginados server-side desde PedidosContainer.
 * Renderiza lista + controles de paginación.
 */
import { ShoppingCart, Plus, Route, FileDown, Trash2 } from 'lucide-react';
import LoadingSpinner from '../layout/LoadingSpinner';
import Paginacion from '../layout/Paginacion';
import { PedidoCard, PedidoFilters, PedidoStats, VistaRutaTransportista } from '../pedidos';
import type {
  PedidoDB,
  ClienteDB,
  ProductoDB,
  PerfilDB,
  FiltrosPedidosState
} from '../../types';

// =============================================================================
// INTERFACES DE PROPS
// =============================================================================

export interface VistaPedidosProps {
  /** Pedidos de la página actual (ya paginados server-side) */
  pedidos: PedidoDB[];
  /** Total de pedidos que coinciden con los filtros (para paginación) */
  totalCount: number;
  paginaActual: number;
  totalPaginas: number;
  busqueda: string;
  filtros: FiltrosPedidosState;
  isAdmin: boolean;
  isPreventista: boolean;
  isTransportista: boolean;
  userId: string;
  clientes: ClienteDB[];
  productos: ProductoDB[];
  transportistas?: PerfilDB[];
  loading: boolean;
  exportando: boolean;
  onBusquedaChange: (busqueda: string) => void;
  onFiltrosChange: (filtros: Partial<FiltrosPedidosState>) => void;
  onPageChange: (page: number) => void;
  onNuevoPedido: () => void;
  onOptimizarRuta: () => void;
  onExportarPDF: () => void;
  onExportarExcel: () => void;
  onModalFiltroFecha: () => void;
  onVerHistorial: (pedido: PedidoDB) => void;
  onEditarPedido: (pedido: PedidoDB) => void;
  onMarcarEnPreparacion: (pedido: PedidoDB) => void;
  onVolverAPendiente: (pedido: PedidoDB) => void;
  onAsignarTransportista: (pedido: PedidoDB) => void;
  onMarcarEntregado: (pedido: PedidoDB) => void;
  onMarcarEntregadoConSalvedad?: (pedido: PedidoDB) => void;
  onDesmarcarEntregado: (pedido: PedidoDB) => void;
  onEliminarPedido: (pedido: PedidoDB) => void;
  onVerPedidosEliminados?: () => void;
}

export default function VistaPedidos({
  pedidos,
  totalCount,
  paginaActual,
  totalPaginas,
  busqueda,
  filtros,
  isAdmin,
  isPreventista,
  isTransportista,
  userId,
  clientes,
  productos,
  transportistas = [],
  loading,
  exportando,
  onBusquedaChange,
  onFiltrosChange,
  onPageChange,
  onNuevoPedido,
  onOptimizarRuta,
  onExportarPDF,
  onExportarExcel,
  onModalFiltroFecha,
  onVerHistorial,
  onEditarPedido,
  onMarcarEnPreparacion,
  onVolverAPendiente,
  onAsignarTransportista,
  onMarcarEntregado,
  onMarcarEntregadoConSalvedad,
  onDesmarcarEntregado,
  onEliminarPedido,
  onVerPedidosEliminados
}: VistaPedidosProps) {
  // Si es transportista, mostrar vista especial de ruta
  if (isTransportista && !isAdmin && !isPreventista) {
    return (
      <VistaRutaTransportista
        pedidos={pedidos}
        onMarcarEntregado={onMarcarEntregado}
        userId={userId}
        clientes={clientes}
        productos={productos}
      />
    );
  }

  return (
    <div className="space-y-4">
      {/* Header */}
      <div className="flex flex-col sm:flex-row justify-between items-start sm:items-center gap-4">
        <h1 className="text-2xl font-bold text-gray-800 dark:text-white">Pedidos</h1>
        <div className="flex flex-wrap gap-2">
          {isAdmin && (
            <button
              onClick={onOptimizarRuta}
              className="flex items-center space-x-2 px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 transition-colors"
            >
              <Route className="w-5 h-5" />
              <span>Optimizar Ruta</span>
            </button>
          )}
          {isAdmin && (
            <button
              onClick={onExportarPDF}
              className="flex items-center space-x-2 px-4 py-2 bg-purple-600 text-white rounded-lg hover:bg-purple-700 transition-colors"
            >
              <FileDown className="w-5 h-5" />
              <span>Exportar PDF</span>
            </button>
          )}
          {isAdmin && (
            <button
              onClick={onExportarExcel}
              disabled={exportando}
              className="flex items-center space-x-2 px-4 py-2 bg-green-700 text-white rounded-lg hover:bg-green-800 transition-colors"
            >
              <FileDown className="w-5 h-5" />
              <span>Excel</span>
            </button>
          )}
          {isAdmin && onVerPedidosEliminados && (
            <button
              onClick={onVerPedidosEliminados}
              className="flex items-center space-x-2 px-4 py-2 bg-red-600 text-white rounded-lg hover:bg-red-700 transition-colors"
              aria-label="Ver historial de pedidos eliminados"
            >
              <Trash2 className="w-5 h-5" aria-hidden="true" />
              <span className="hidden sm:inline">Eliminados</span>
            </button>
          )}
          {(isAdmin || isPreventista) && (
            <button
              onClick={onNuevoPedido}
              className="flex items-center space-x-2 px-4 py-2 bg-green-600 text-white rounded-lg hover:bg-green-700 transition-colors"
            >
              <Plus className="w-5 h-5" />
              <span>Nuevo</span>
            </button>
          )}
        </div>
      </div>

      {/* Filtros */}
      <PedidoFilters
        busqueda={busqueda}
        filtros={filtros}
        transportistas={transportistas as import('../../types').Usuario[]}
        isAdmin={isAdmin}
        onBusquedaChange={onBusquedaChange}
        onFiltrosChange={onFiltrosChange}
        onModalFiltroFecha={onModalFiltroFecha}
      />

      {/* Resumen de estados */}
      <PedidoStats pedidosParaMostrar={pedidos} />

      {/* Lista de pedidos */}
      {loading ? (
        <LoadingSpinner />
      ) : pedidos.length === 0 ? (
        <div className="text-center py-12 text-gray-500">
          <ShoppingCart className="w-12 h-12 mx-auto mb-3 opacity-50" />
          <p>No hay pedidos</p>
        </div>
      ) : (
        <>
          <div className="space-y-3">
            {pedidos.map(pedido => (
              <PedidoCard
                key={pedido.id}
                pedido={pedido}
                isAdmin={isAdmin}
                isPreventista={isPreventista}
                isTransportista={isTransportista}
                onVerHistorial={onVerHistorial}
                onEditarPedido={onEditarPedido}
                onMarcarEnPreparacion={onMarcarEnPreparacion}
                onVolverAPendiente={onVolverAPendiente}
                onAsignarTransportista={onAsignarTransportista}
                onMarcarEntregado={onMarcarEntregado}
                onMarcarEntregadoConSalvedad={onMarcarEntregadoConSalvedad}
                onDesmarcarEntregado={onDesmarcarEntregado}
                onEliminarPedido={(pedidoId: string) => {
                  const p = pedidos.find(x => x.id === pedidoId);
                  if (p) onEliminarPedido(p);
                }}
              />
            ))}
          </div>

          <Paginacion
            paginaActual={paginaActual}
            totalPaginas={totalPaginas}
            onPageChange={onPageChange}
            totalItems={totalCount}
            itemsLabel="pedidos"
          />
        </>
      )}
    </div>
  );
}
