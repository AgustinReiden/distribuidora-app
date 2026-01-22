/**
 * Componente consolidado para todos los modales de la aplicación
 * Implementa lazy loading para optimización de bundle
 */
import React, { Suspense, lazy, ReactNode } from 'react';
import LoadingSpinner from './layout/LoadingSpinner';
import type { User } from '@supabase/supabase-js';
import type {
  ClienteDB,
  ProductoDB,
  PedidoDB,
  PerfilDB,
  ProveedorDBExtended,
  MermaDBExtended,
  CompraDBExtended,
  FiltrosPedidosState,
  RutaOptimizada
} from '../types/hooks';

// Modales cargados de forma lazy
const ModalConfirmacion = lazy(() => import('./modals/ModalConfirmacion'));
const ModalFiltroFecha = lazy(() => import('./modals/ModalFiltroFecha'));
const ModalCliente = lazy(() => import('./modals/ModalCliente'));
const ModalProducto = lazy(() => import('./modals/ModalProducto'));
const ModalUsuario = lazy(() => import('./modals/ModalUsuario'));
const ModalAsignarTransportista = lazy(() => import('./modals/ModalAsignarTransportista'));
const ModalPedido = lazy(() => import('./modals/ModalPedido'));
const ModalHistorialPedido = lazy(() => import('./modals/ModalHistorialPedido'));
const ModalEditarPedido = lazy(() => import('./modals/ModalEditarPedido'));
const ModalExportarPDF = lazy(() => import('./modals/ModalExportarPDF'));
const ModalGestionRutas = lazy(() => import('./modals/ModalGestionRutas'));
const ModalFichaCliente = lazy(() => import('./modals/ModalFichaCliente'));
const ModalRegistrarPago = lazy(() => import('./modals/ModalRegistrarPago'));
const ModalMermaStock = lazy(() => import('./modals/ModalMermaStock'));
const ModalHistorialMermas = lazy(() => import('./modals/ModalHistorialMermas'));
const ModalCompra = lazy(() => import('./modals/ModalCompra'));
const ModalDetalleCompra = lazy(() => import('./modals/ModalDetalleCompra'));
const ModalProveedor = lazy(() => import('./modals/ModalProveedor'));
const ModalImportarPrecios = lazy(() => import('./modals/ModalImportarPrecios'));
const ModalPedidosEliminados = lazy(() => import('./modals/ModalPedidosEliminados'));

// Lazy load de utilidades PDF (solo cuando se necesiten)
const loadPdfUtils = () => import('../lib/pdfExport.js');

// =============================================================================
// TYPES
// =============================================================================

/** Modal state with open/close controls */
export interface ModalState<T = unknown> {
  open: boolean;
  setOpen: (open: boolean) => void;
  data?: T;
}

/** Confirmation modal config */
export interface ConfirmConfig {
  visible: boolean;
  title?: string;
  message?: string;
  onConfirm?: () => void;
  variant?: 'danger' | 'warning' | 'info';
}

/** All modals state */
export interface ModalesState {
  confirm: { config: ConfirmConfig | null; setConfig: (config: ConfirmConfig) => void };
  filtroFecha: ModalState;
  cliente: ModalState;
  producto: ModalState;
  pedido: ModalState;
  usuario: ModalState;
  asignar: ModalState;
  historial: ModalState;
  editarPedido: ModalState;
  exportarPDF: ModalState;
  optimizarRuta: ModalState;
  fichaCliente: ModalState;
  registrarPago: ModalState;
  mermaStock: ModalState;
  historialMermas: ModalState;
  compra: ModalState;
  detalleCompra: ModalState;
  proveedor: ModalState;
  importarPrecios: ModalState;
  pedidosEliminados: ModalState;
}

/** Nuevo pedido form state */
export interface NuevoPedidoState {
  clienteId: string;
  items: Array<{ productoId: string; cantidad: number; precioUnitario: number }>;
  notas: string;
  formaPago?: string;
  estadoPago?: string;
  montoPagado?: number;
}

/** App state passed to AppModals */
export interface AppModalsAppState {
  modales: ModalesState;
  clienteEditando: ClienteDB | null;
  setClienteEditando: (cliente: ClienteDB | null) => void;
  productoEditando: ProductoDB | null;
  setProductoEditando: (producto: ProductoDB | null) => void;
  usuarioEditando: PerfilDB | null;
  setUsuarioEditando: (usuario: PerfilDB | null) => void;
  pedidoAsignando: PedidoDB | null;
  setPedidoAsignando: (pedido: PedidoDB | null) => void;
  pedidoHistorial: PedidoDB | null;
  setPedidoHistorial: (pedido: PedidoDB | null) => void;
  historialCambios: unknown[];
  setHistorialCambios: (historial: unknown[]) => void;
  pedidoEditando: PedidoDB | null;
  setPedidoEditando: (pedido: PedidoDB | null) => void;
  clienteFicha: ClienteDB | null;
  setClienteFicha: (cliente: ClienteDB | null) => void;
  clientePago: ClienteDB | null;
  setClientePago: (cliente: ClienteDB | null) => void;
  saldoPendienteCliente: number;
  productoMerma: ProductoDB | null;
  setProductoMerma: (producto: ProductoDB | null) => void;
  compraDetalle: CompraDBExtended | null;
  setCompraDetalle: (compra: CompraDBExtended | null) => void;
  proveedorEditando: ProveedorDBExtended | null;
  setProveedorEditando: (proveedor: ProveedorDBExtended | null) => void;
  nuevoPedido: NuevoPedidoState;
  resetNuevoPedido: () => void;
  setCargandoHistorial: (cargando: boolean) => void;
  filtros: FiltrosPedidosState;
  setFiltros: React.Dispatch<React.SetStateAction<FiltrosPedidosState>>;
}

/** Event handlers for AppModals */
export interface AppModalsHandlers {
  handleFiltrosChange: (nuevosFiltros: Partial<FiltrosPedidosState>, filtros: FiltrosPedidosState, setFiltros: React.Dispatch<React.SetStateAction<FiltrosPedidosState>>) => void;
  handleGuardarCliente: (clienteData: Partial<ClienteDB>) => Promise<void>;
  handleGuardarProducto: (productoData: Partial<ProductoDB>) => Promise<void>;
  handleClienteChange: (clienteId: string) => void;
  agregarItemPedido: (productoId: string, cantidad: number, precio: number) => void;
  actualizarCantidadItem: (productoId: string, cantidad: number) => void;
  handleCrearClienteEnPedido: (clienteData: Partial<ClienteDB>) => Promise<void>;
  handleGuardarPedidoConOffline: () => Promise<void>;
  handleNotasChange: (notas: string) => void;
  handleFormaPagoChange: (formaPago: string) => void;
  handleEstadoPagoChange: (estadoPago: string) => void;
  handleMontoPagadoChange: (monto: number) => void;
  handleGuardarUsuario: (usuarioData: Partial<PerfilDB>) => Promise<void>;
  handleAsignarTransportista: (transportistaId: string) => Promise<void>;
  handleGuardarEdicionPedido: (pedidoData: Partial<PedidoDB>) => Promise<void>;
  handleAplicarOrdenOptimizado: (pedidosOrdenados: Array<{ id: string; orden_entrega: number }>) => Promise<void>;
  handleExportarHojaRutaOptimizada: () => Promise<void>;
  handleCerrarModalOptimizar: () => void;
  handleAbrirRegistrarPago: (cliente: ClienteDB, saldo: number) => void;
  handleRegistrarPago: (monto: number, formaPago: string, notas?: string) => Promise<void>;
  handleGenerarReciboPago: () => Promise<void>;
  handleRegistrarMerma: (mermaData: { cantidad: number; motivo: string }) => Promise<void>;
  handleRegistrarCompra: (compraData: unknown) => Promise<void>;
  handleAnularCompra: (compraId: string) => Promise<void>;
  handleGuardarProveedor: (proveedorData: Partial<ProveedorDBExtended>) => Promise<void>;
  refetchProductos?: () => Promise<void>;
}

/** Category type */
export interface Categoria {
  id: string;
  nombre: string;
  descripcion?: string;
}

/** Props for AppModals component */
export interface AppModalsProps {
  // Estado de la app
  appState: AppModalsAppState;
  handlers: AppModalsHandlers;

  // Datos
  clientes: ClienteDB[];
  productos: ProductoDB[];
  pedidos: PedidoDB[];
  usuarios: PerfilDB[];
  transportistas: PerfilDB[];
  proveedores: ProveedorDBExtended[];
  mermas: MermaDBExtended[];
  categorias: Categoria[];

  // Funciones de datos
  fetchPedidosEliminados: () => Promise<PedidoDB[]>;
  actualizarItemsPedido: (pedidoId: string, items: Array<{ producto_id: string; cantidad: number; precio_unitario: number }>, usuarioId?: string) => Promise<void>;
  actualizarPreciosMasivo: (productos: Array<{ productoId: string; precioNeto?: number; impInternos?: number; precioFinal?: number }>) => Promise<{ success: boolean; actualizados: number; errores: string[] }>;
  optimizarRuta: (transportistaId: string, pedidos: PedidoDB[]) => Promise<RutaOptimizada | null>;

  // Estado de carga
  guardando: boolean;
  cargandoHistorial: boolean;
  loadingOptimizacion: boolean;
  rutaOptimizada: RutaOptimizada | null;
  errorOptimizacion: string | null;

  // Usuario y permisos
  user: User | null;
  isAdmin: boolean;
  isPreventista: boolean;
  isOnline: boolean;
}

// Fallback para loading de modales
function ModalFallback(): JSX.Element {
  return (
    <div className="fixed inset-0 bg-black/50 flex items-center justify-center z-50">
      <div className="bg-white dark:bg-gray-800 rounded-lg p-6">
        <LoadingSpinner />
      </div>
    </div>
  );
}

export default function AppModals({
  // Estado de la app
  appState,
  handlers,

  // Datos
  clientes,
  productos,
  pedidos,
  usuarios,
  transportistas,
  proveedores,
  mermas,
  categorias,

  // Funciones de datos
  fetchPedidosEliminados,
  actualizarItemsPedido,
  actualizarPreciosMasivo,
  optimizarRuta,

  // Estado de carga
  guardando,
  cargandoHistorial,
  loadingOptimizacion,
  rutaOptimizada,
  errorOptimizacion,

  // Usuario y permisos
  user,
  isAdmin,
  isPreventista,
  isOnline
}: AppModalsProps): JSX.Element {
  const {
    modales,
    clienteEditando,
    setClienteEditando,
    productoEditando,
    setProductoEditando,
    usuarioEditando,
    setUsuarioEditando,
    pedidoAsignando,
    setPedidoAsignando,
    pedidoHistorial,
    setPedidoHistorial,
    historialCambios,
    setHistorialCambios,
    pedidoEditando,
    setPedidoEditando,
    clienteFicha,
    setClienteFicha,
    clientePago,
    setClientePago,
    saldoPendienteCliente,
    productoMerma,
    setProductoMerma,
    compraDetalle,
    setCompraDetalle,
    proveedorEditando,
    setProveedorEditando,
    nuevoPedido,
    setCargandoHistorial,
    filtros,
    setFiltros
  } = appState;

  const zonasExistentes: string[] = [...new Set(clientes.map(c => c.zona).filter((z): z is string => Boolean(z)))];

  // Handlers para PDF con lazy loading
  const handleExportarOrdenPreparacion = async (...args: unknown[]): Promise<void> => {
    const { generarOrdenPreparacion } = await loadPdfUtils();
    return generarOrdenPreparacion(...args);
  };

  const handleExportarHojaRuta = async (...args: unknown[]): Promise<void> => {
    const { generarHojaRuta } = await loadPdfUtils();
    return generarHojaRuta(...args);
  };

  return (
    <Suspense fallback={null}>
      {/* Modal de Confirmación - siempre visible si hay config */}
      {modales.confirm.config?.visible && (
        <Suspense fallback={<ModalFallback />}>
          <ModalConfirmacion
            config={modales.confirm.config}
            onClose={() => modales.confirm.setConfig({ visible: false })}
          />
        </Suspense>
      )}

      {/* Modal de Filtro de Fecha */}
      {modales.filtroFecha.open && (
        <Suspense fallback={<ModalFallback />}>
          <ModalFiltroFecha
            filtros={filtros}
            onApply={(nuevosFiltros) => handlers.handleFiltrosChange(nuevosFiltros, filtros, setFiltros)}
            onClose={() => modales.filtroFecha.setOpen(false)}
          />
        </Suspense>
      )}

      {/* Modal de Cliente */}
      {modales.cliente.open && (
        <Suspense fallback={<ModalFallback />}>
          <ModalCliente
            cliente={clienteEditando}
            onSave={handlers.handleGuardarCliente}
            onClose={() => { modales.cliente.setOpen(false); setClienteEditando(null); }}
            guardando={guardando}
            isAdmin={isAdmin}
            zonasExistentes={zonasExistentes}
          />
        </Suspense>
      )}

      {/* Modal de Producto */}
      {modales.producto.open && (
        <Suspense fallback={<ModalFallback />}>
          <ModalProducto
            producto={productoEditando}
            categorias={categorias}
            onSave={handlers.handleGuardarProducto}
            onClose={() => { modales.producto.setOpen(false); setProductoEditando(null); }}
            guardando={guardando}
          />
        </Suspense>
      )}

      {/* Modal de Pedido */}
      {modales.pedido.open && (
        <Suspense fallback={<ModalFallback />}>
          <ModalPedido
            productos={productos}
            clientes={clientes}
            categorias={categorias}
            nuevoPedido={nuevoPedido}
            onClose={() => { modales.pedido.setOpen(false); appState.resetNuevoPedido(); }}
            onClienteChange={handlers.handleClienteChange}
            onAgregarItem={handlers.agregarItemPedido}
            onActualizarCantidad={handlers.actualizarCantidadItem}
            onCrearCliente={handlers.handleCrearClienteEnPedido}
            onGuardar={handlers.handleGuardarPedidoConOffline}
            isOffline={!isOnline}
            onNotasChange={handlers.handleNotasChange}
            onFormaPagoChange={handlers.handleFormaPagoChange}
            onEstadoPagoChange={handlers.handleEstadoPagoChange}
            onMontoPagadoChange={handlers.handleMontoPagadoChange}
            guardando={guardando}
            isAdmin={isAdmin}
            isPreventista={isPreventista}
          />
        </Suspense>
      )}

      {/* Modal de Usuario */}
      {modales.usuario.open && (
        <Suspense fallback={<ModalFallback />}>
          <ModalUsuario
            usuario={usuarioEditando}
            onSave={handlers.handleGuardarUsuario}
            onClose={() => { modales.usuario.setOpen(false); setUsuarioEditando(null); }}
            guardando={guardando}
          />
        </Suspense>
      )}

      {/* Modal de Asignar Transportista */}
      {modales.asignar.open && (
        <Suspense fallback={<ModalFallback />}>
          <ModalAsignarTransportista
            pedido={pedidoAsignando}
            transportistas={transportistas}
            onSave={handlers.handleAsignarTransportista}
            onClose={() => { modales.asignar.setOpen(false); setPedidoAsignando(null); }}
            guardando={guardando}
          />
        </Suspense>
      )}

      {/* Modal de Historial de Pedido */}
      {modales.historial.open && (
        <Suspense fallback={<ModalFallback />}>
          <ModalHistorialPedido
            pedido={pedidoHistorial}
            historial={historialCambios}
            onClose={() => { modales.historial.setOpen(false); setPedidoHistorial(null); setHistorialCambios([]); setCargandoHistorial(false); }}
            loading={cargandoHistorial}
          />
        </Suspense>
      )}

      {/* Modal de Editar Pedido */}
      {modales.editarPedido.open && (
        <Suspense fallback={<ModalFallback />}>
          <ModalEditarPedido
            pedido={pedidoEditando}
            productos={productos}
            isAdmin={isAdmin}
            onSave={handlers.handleGuardarEdicionPedido}
            onSaveItems={async (items) => {
              await actualizarItemsPedido(pedidoEditando.id, items, user?.id);
              handlers.refetchProductos?.();
            }}
            onClose={() => { modales.editarPedido.setOpen(false); setPedidoEditando(null); }}
            guardando={guardando}
          />
        </Suspense>
      )}

      {/* Modal de Exportar PDF */}
      {modales.exportarPDF.open && (
        <Suspense fallback={<ModalFallback />}>
          <ModalExportarPDF
            pedidos={pedidos}
            transportistas={transportistas}
            onExportarOrdenPreparacion={handleExportarOrdenPreparacion}
            onExportarHojaRuta={handleExportarHojaRuta}
            onClose={() => modales.exportarPDF.setOpen(false)}
          />
        </Suspense>
      )}

      {/* Modal de Gestión de Rutas */}
      {modales.optimizarRuta.open && (
        <Suspense fallback={<ModalFallback />}>
          <ModalGestionRutas
            transportistas={transportistas}
            pedidos={pedidos}
            onOptimizar={(transportistaId, pedidosData) => optimizarRuta(transportistaId, pedidosData)}
            onAplicarOrden={handlers.handleAplicarOrdenOptimizado}
            onExportarPDF={handlers.handleExportarHojaRutaOptimizada}
            onClose={handlers.handleCerrarModalOptimizar}
            loading={loadingOptimizacion}
            guardando={guardando}
            rutaOptimizada={rutaOptimizada}
            error={errorOptimizacion}
          />
        </Suspense>
      )}

      {/* Modal de Ficha de Cliente */}
      {modales.fichaCliente.open && clienteFicha && (
        <Suspense fallback={<ModalFallback />}>
          <ModalFichaCliente
            cliente={clienteFicha}
            onClose={() => { modales.fichaCliente.setOpen(false); setClienteFicha(null); }}
            onRegistrarPago={handlers.handleAbrirRegistrarPago}
          />
        </Suspense>
      )}

      {/* Modal de Registrar Pago */}
      {modales.registrarPago.open && clientePago && (
        <Suspense fallback={<ModalFallback />}>
          <ModalRegistrarPago
            cliente={clientePago}
            saldoPendiente={saldoPendienteCliente}
            pedidos={pedidos}
            onClose={() => { modales.registrarPago.setOpen(false); setClientePago(null); }}
            onConfirmar={handlers.handleRegistrarPago}
            onGenerarRecibo={handlers.handleGenerarReciboPago}
          />
        </Suspense>
      )}

      {/* Modal de Merma de Stock */}
      {modales.mermaStock.open && productoMerma && (
        <Suspense fallback={<ModalFallback />}>
          <ModalMermaStock
            producto={productoMerma}
            onSave={handlers.handleRegistrarMerma}
            onClose={() => { modales.mermaStock.setOpen(false); setProductoMerma(null); }}
            isOffline={!isOnline}
          />
        </Suspense>
      )}

      {/* Modal de Historial de Mermas */}
      {modales.historialMermas.open && (
        <Suspense fallback={<ModalFallback />}>
          <ModalHistorialMermas
            mermas={mermas}
            productos={productos}
            usuarios={usuarios}
            onClose={() => modales.historialMermas.setOpen(false)}
          />
        </Suspense>
      )}

      {/* Modal de Compra */}
      {modales.compra.open && (
        <Suspense fallback={<ModalFallback />}>
          <ModalCompra
            productos={productos}
            proveedores={proveedores}
            onSave={handlers.handleRegistrarCompra}
            onClose={() => modales.compra.setOpen(false)}
          />
        </Suspense>
      )}

      {/* Modal de Detalle de Compra */}
      {modales.detalleCompra.open && compraDetalle && (
        <Suspense fallback={<ModalFallback />}>
          <ModalDetalleCompra
            compra={compraDetalle}
            onClose={() => { modales.detalleCompra.setOpen(false); setCompraDetalle(null); }}
            onAnular={handlers.handleAnularCompra}
          />
        </Suspense>
      )}

      {/* Modal de Proveedor */}
      {modales.proveedor.open && (
        <Suspense fallback={<ModalFallback />}>
          <ModalProveedor
            proveedor={proveedorEditando}
            onSave={handlers.handleGuardarProveedor}
            onClose={() => { modales.proveedor.setOpen(false); setProveedorEditando(null); }}
            guardando={guardando}
          />
        </Suspense>
      )}

      {/* Modal de Importar Precios */}
      {modales.importarPrecios.open && (
        <Suspense fallback={<ModalFallback />}>
          <ModalImportarPrecios
            productos={productos}
            onActualizarPrecios={actualizarPreciosMasivo}
            onClose={() => modales.importarPrecios.setOpen(false)}
          />
        </Suspense>
      )}

      {/* Modal de Pedidos Eliminados */}
      {modales.pedidosEliminados.open && (
        <Suspense fallback={<ModalFallback />}>
          <ModalPedidosEliminados
            onFetch={fetchPedidosEliminados}
            onClose={() => modales.pedidosEliminados.setOpen(false)}
          />
        </Suspense>
      )}
    </Suspense>
  );
}
