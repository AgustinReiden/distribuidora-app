/**
 * Vista principal de pedidos
 *
 * Recibe datos ya paginados server-side desde PedidosContainer.
 * Renderiza lista + controles de paginación.
 */
import { ShoppingCart } from 'lucide-react';
import LoadingSpinner from '../layout/LoadingSpinner';
import Paginacion from '../layout/Paginacion';
import { PedidoCard, PedidoFilters, PedidoStats } from '../pedidos';
import RutaActivaTransportista from '../rutaActiva/RutaActivaTransportista';
import PedidosViewHeader from '../pedidos/PedidosViewHeader';
import PedidoToolbar from '../pedidos/PedidoToolbar';
import type {
  PedidoDB,
  ClienteDB,
  ProductoDB,
  PerfilDB,
  FiltrosPedidosState,
  MotivoSalvedad,
  RegistrarSalvedadResult
} from '../../types';
import type { PedidoStatsSummary } from '../../hooks/queries';

// =============================================================================
// INTERFACES DE PROPS
// =============================================================================

export interface VistaPedidosProps {
  /** Pedidos de la página actual (ya paginados server-side) */
  pedidos: PedidoDB[];
  /** Total de pedidos que coinciden con los filtros (para paginación) */
  totalCount: number;
  /** Totales por estado/pago sobre todos los pedidos filtrados (no sólo la página) */
  statsSummary: PedidoStatsSummary;
  paginaActual: number;
  totalPaginas: number;
  busqueda: string;
  filtros: FiltrosPedidosState;
  isAdmin: boolean;
  isPreventista: boolean;
  isTransportista: boolean;
  isEncargado?: boolean;
  isPreventistaTaco?: boolean;
  userId: string;
  clientes: ClienteDB[];
  productos: ProductoDB[];
  transportistas?: PerfilDB[];
  usuarios?: PerfilDB[];
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
  onMarcarEntregado: (pedido: PedidoDB) => void;
  onMarcarEntregadoConSalvedad?: (pedido: PedidoDB) => void;
  onDesmarcarEntregado: (pedido: PedidoDB) => void;
  onCancelarPedido?: (pedido: PedidoDB) => void;
  onEntregasMasivas?: () => void;
  onPagosMasivos?: () => void;
  /** Abre el modal para que el preventista marque una visita a un cliente. */
  onMarcarVisita?: () => void;
  /** Abre el modal con el timeline de visitas del día del preventista logueado. */
  onVerVisitasHoy?: () => void;
  /** Handler para registrar una salvedad individual desde la vista transportista. */
  onRegistrarSalvedad?: (data: {
    pedidoId: string;
    pedidoItemId: string;
    cantidadAfectada: number;
    motivo: MotivoSalvedad;
    descripcion?: string;
    fotoUrl?: string;
    devolverStock: boolean;
  }) => Promise<RegistrarSalvedadResult>;
  /** Handler legacy para registrar un pago desde la vista transportista (modal cliente). */
  onRegistrarPago?: (data: {
    clienteId: string;
    pedidoId: string | null;
    monto: number;
    formaPago: string;
    referencia: string;
    notas: string;
    fecha: string;
  }) => Promise<unknown>;
  /** Handler para abrir ModalPagoPedido desde el dropdown del PedidoCard. */
  onAbrirPagoPedido?: (pedido: PedidoDB) => void;
  /**
   * Handler para que el transportista entregue a cuenta corriente (sin cobrar):
   * marca el pedido como entregado sin registrar pago, dejando el saldo pendiente.
   */
  onEntregarSinCobrar?: (pedido: PedidoDB) => void | Promise<void>;
}

export default function VistaPedidos({
  pedidos,
  totalCount,
  statsSummary,
  paginaActual,
  totalPaginas,
  busqueda,
  filtros,
  isAdmin,
  isPreventista,
  isTransportista,
  isEncargado,
  isPreventistaTaco,
  userId,
  transportistas = [],
  usuarios = [],
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
  onMarcarEntregado,
  onMarcarEntregadoConSalvedad,
  onDesmarcarEntregado,
  onCancelarPedido,
  onEntregasMasivas,
  onPagosMasivos,
  onMarcarVisita,
  onVerVisitasHoy,
  onRegistrarSalvedad,
  onRegistrarPago,
  onAbrirPagoPedido,
  onEntregarSinCobrar,
}: VistaPedidosProps) {
  // Si es transportista, mostrar la pantalla map-first "Ruta Activa"
  // (reemplaza a VistaRutaTransportista; el flujo de entrega es el mismo).
  if (isTransportista && !isAdmin && !isPreventista) {
    return (
      <RutaActivaTransportista
        onMarcarEntregado={onMarcarEntregado}
        userId={userId}
        onRegistrarSalvedad={onRegistrarSalvedad}
        onRegistrarPago={onRegistrarPago}
        onEntregarSinCobrar={onEntregarSinCobrar}
      />
    );
  }

  return (
    <div className="space-y-4">
      {/* Header con título dinámico + toolbar */}
      <PedidosViewHeader
        filtros={filtros}
        totalCount={totalCount}
        loading={loading}
        actions={
          <PedidoToolbar
            isAdmin={isAdmin}
            isEncargado={isEncargado}
            isPreventista={isPreventista}
            exportando={exportando}
            totalCount={totalCount}
            onNuevoPedido={onNuevoPedido}
            onOptimizarRuta={onOptimizarRuta}
            onExportarPDF={onExportarPDF}
            onExportarExcel={onExportarExcel}
            onEntregasMasivas={onEntregasMasivas}
            onPagosMasivos={onPagosMasivos}
            onMarcarVisita={onMarcarVisita}
            onVerVisitasHoy={onVerVisitasHoy}
          />
        }
      />

      {/* Filtros */}
      <PedidoFilters
        busqueda={busqueda}
        filtros={filtros}
        transportistas={transportistas as import('../../types').Usuario[]}
        usuarios={usuarios as import('../../types').Usuario[]}
        isAdmin={isAdmin}
        onBusquedaChange={onBusquedaChange}
        onFiltrosChange={onFiltrosChange}
        onModalFiltroFecha={onModalFiltroFecha}
      />

      {/* Resumen de estados (totales sobre todos los pedidos filtrados) */}
      <PedidoStats summary={statsSummary} isEncargado={isEncargado} isPreventistaTaco={isPreventistaTaco} />

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
            {pedidos.map((pedido, idx) => (
              <div
                key={pedido.id}
                style={{
                  // Stagger fade-in: cada card entra 40ms después de la anterior,
                  // cap a 12 items para que no se sienta lento en páginas largas.
                  animation: 'card-in 0.32s cubic-bezier(0.22, 1, 0.36, 1) both',
                  animationDelay: `${Math.min(idx, 12) * 40}ms`,
                }}
              >
                <PedidoCard
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
                  onMarcarEntregado={onMarcarEntregado}
                  onMarcarEntregadoConSalvedad={onMarcarEntregadoConSalvedad}
                  onDesmarcarEntregado={onDesmarcarEntregado}
                  onCancelarPedido={onCancelarPedido}
                  onRegistrarPago={onAbrirPagoPedido}
                />
              </div>
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

