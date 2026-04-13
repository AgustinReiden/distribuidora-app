/**
 * Vista principal de pedidos
 *
 * Recibe datos ya paginados server-side desde PedidosContainer.
 * Renderiza lista + controles de paginación.
 */
import { useState, useRef, useEffect } from 'react';
import { ShoppingCart, Plus, Route, FileDown, PackageCheck, Banknote, ChevronDown, Truck } from 'lucide-react';
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
  isEncargado?: boolean;
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
  onExportarExcel: (modo: 'pagina' | 'filtro') => void;
  onModalFiltroFecha: () => void;
  onVerHistorial: (pedido: PedidoDB) => void;
  onEditarPedido: (pedido: PedidoDB) => void;
  onEditarNotas?: (pedido: PedidoDB) => void;
  onMarcarEnPreparacion: (pedido: PedidoDB) => void;
  onVolverAPendiente: (pedido: PedidoDB) => void;
  onAsignarTransportista: (pedido: PedidoDB) => void;
  onMarcarEntregado: (pedido: PedidoDB) => void;
  onMarcarEntregadoConSalvedad?: (pedido: PedidoDB) => void;
  onDesmarcarEntregado: (pedido: PedidoDB) => void;
  onCancelarPedido?: (pedido: PedidoDB) => void;
  onEntregasMasivas?: () => void;
  onPagosMasivos?: () => void;
  onAsignarTransportistaMasivo?: () => void;
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
  isEncargado,
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
  onEditarNotas,
  onMarcarEnPreparacion,
  onVolverAPendiente,
  onAsignarTransportista,
  onMarcarEntregado,
  onMarcarEntregadoConSalvedad,
  onDesmarcarEntregado,
  onCancelarPedido,
  onEntregasMasivas,
  onPagosMasivos,
  onAsignarTransportistaMasivo,
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
          {(isAdmin || isEncargado) && (
            <button
              onClick={onOptimizarRuta}
              className="flex items-center space-x-2 px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 transition-colors"
            >
              <Route className="w-5 h-5" />
              <span>Optimizar Ruta</span>
            </button>
          )}
          {(isAdmin || isEncargado) && (
            <button
              onClick={onExportarPDF}
              className="flex items-center space-x-2 px-4 py-2 bg-purple-600 text-white rounded-lg hover:bg-purple-700 transition-colors"
            >
              <FileDown className="w-5 h-5" />
              <span>Exportar PDF</span>
            </button>
          )}
          {(isAdmin || isEncargado) && (
            <ExcelExportDropdown exportando={exportando} onExportarExcel={onExportarExcel} totalCount={totalCount} />
          )}
          {(isAdmin || isEncargado) && onEntregasMasivas && (
            <button
              onClick={onEntregasMasivas}
              className="flex items-center space-x-2 px-4 py-2 bg-teal-600 text-white rounded-lg hover:bg-teal-700 transition-colors"
            >
              <PackageCheck className="w-5 h-5" />
              <span className="hidden sm:inline">Entregas Masivas</span>
            </button>
          )}
          {(isAdmin || isEncargado) && onAsignarTransportistaMasivo && (
            <button
              onClick={onAsignarTransportistaMasivo}
              className="flex items-center space-x-2 px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 transition-colors"
            >
              <Truck className="w-5 h-5" />
              <span className="hidden sm:inline">Asignar Transportista</span>
            </button>
          )}
          {(isAdmin || isEncargado) && onPagosMasivos && (
            <button
              onClick={onPagosMasivos}
              className="flex items-center space-x-2 px-4 py-2 bg-green-600 text-white rounded-lg hover:bg-green-700 transition-colors"
            >
              <Banknote className="w-5 h-5" />
              <span className="hidden sm:inline">Pagos Masivos</span>
            </button>
          )}
          {(isAdmin || isEncargado || isPreventista) && (
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
                isEncargado={isEncargado}
                onVerHistorial={onVerHistorial}
                onEditarPedido={onEditarPedido}
                onEditarNotas={onEditarNotas}
                onMarcarEnPreparacion={onMarcarEnPreparacion}
                onVolverAPendiente={onVolverAPendiente}
                onAsignarTransportista={onAsignarTransportista}
                onMarcarEntregado={onMarcarEntregado}
                onMarcarEntregadoConSalvedad={onMarcarEntregadoConSalvedad}
                onDesmarcarEntregado={onDesmarcarEntregado}
                onCancelarPedido={onCancelarPedido}
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

// =============================================================================
// EXCEL EXPORT DROPDOWN
// =============================================================================

function ExcelExportDropdown({
  exportando,
  onExportarExcel,
  totalCount
}: {
  exportando: boolean;
  onExportarExcel: (modo: 'pagina' | 'filtro') => void;
  totalCount: number;
}) {
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);

  useEffect(() => {
    function handleClickOutside(e: MouseEvent) {
      if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false);
    }
    if (open) document.addEventListener('mousedown', handleClickOutside);
    return () => document.removeEventListener('mousedown', handleClickOutside);
  }, [open]);

  return (
    <div className="relative" ref={ref}>
      <button
        onClick={() => setOpen(!open)}
        disabled={exportando}
        className="flex items-center space-x-2 px-4 py-2 bg-green-700 text-white rounded-lg hover:bg-green-800 transition-colors disabled:opacity-50"
      >
        <FileDown className="w-5 h-5" />
        <span>{exportando ? 'Exportando...' : 'Excel'}</span>
        <ChevronDown className="w-4 h-4" />
      </button>
      {open && !exportando && (
        <div className="absolute right-0 mt-1 w-56 bg-white dark:bg-gray-800 rounded-lg shadow-lg border dark:border-gray-700 z-50 overflow-hidden">
          <button
            onClick={() => { onExportarExcel('pagina'); setOpen(false); }}
            className="w-full px-4 py-3 text-left text-sm hover:bg-gray-50 dark:hover:bg-gray-700 dark:text-white border-b dark:border-gray-700"
          >
            <p className="font-medium">Página actual</p>
            <p className="text-xs text-gray-500 dark:text-gray-400">Solo los pedidos visibles en pantalla</p>
          </button>
          <button
            onClick={() => { onExportarExcel('filtro'); setOpen(false); }}
            className="w-full px-4 py-3 text-left text-sm hover:bg-gray-50 dark:hover:bg-gray-700 dark:text-white"
          >
            <p className="font-medium">Filtro actual ({totalCount} pedidos)</p>
            <p className="text-xs text-gray-500 dark:text-gray-400">Todos los pedidos que coinciden con el filtro</p>
          </button>
        </div>
      )}
    </div>
  );
}
