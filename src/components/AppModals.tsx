/**
 * Componente consolidado para todos los modales de la aplicación
 * Implementa lazy loading para optimización de bundle
 */
import { Suspense, lazy, type Dispatch, type SetStateAction, type ReactElement } from 'react';
import LoadingSpinner from './layout/LoadingSpinner';
import type { User } from '@supabase/supabase-js';
import type {
  ClienteDB,
  ClienteFormInput,
  ProductoDB,
  ProductoFormInput,
  PedidoDB,
  PerfilDB,
  ProveedorDBExtended,
  ProveedorFormInputExtended,
  MermaDBExtended,
  CompraDBExtended,
  FiltrosPedidosState,
  RutaOptimizada,
  RendicionDBExtended,
  RegistrarSalvedadInput,
  RegistrarSalvedadResult,
  RendicionAjusteInput,
  PagoDBWithUsuario
} from '../types/hooks';

// Importar tipos específicos de handlers
import type { DatosPagoInput } from '../hooks/handlers/useClienteHandlers';
import type { MermaDataInput } from '../hooks/handlers/useProductoHandlers';
import type { EdicionPedidoData, OrdenOptimizadoData, OrdenOptimizadoItem } from '../hooks/handlers/usePedidoHandlers';
import type { CompraDataInput } from '../hooks/handlers/useCompraHandlers';

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
const ModalRendicion = lazy(() => import('./modals/ModalRendicion'));
const ModalEntregaConSalvedad = lazy(() => import('./modals/ModalEntregaConSalvedad'));

// Lazy load de utilidades PDF (solo cuando se necesiten)
const loadPdfUtils = () => import('../lib/pdfExport');

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
  rendicion: ModalState;
  entregaConSalvedad: ModalState;
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
  setFiltros: Dispatch<SetStateAction<FiltrosPedidosState>>;
  // Estado para modal de rendición
  rendicionParaModal: RendicionDBExtended | null;
  setRendicionParaModal: (rendicion: RendicionDBExtended | null) => void;
  // Estado para modal de entrega con salvedad
  pedidoParaSalvedad: PedidoDB | null;
  setPedidoParaSalvedad: (pedido: PedidoDB | null) => void;
}

 
/** Event handlers for AppModals - strongly typed */
export interface AppModalsHandlers {
  // Filtros
  handleFiltrosChange: (
    nuevosFiltros: Partial<FiltrosPedidosState>,
    filtrosActuales: FiltrosPedidosState,
    setFiltros: Dispatch<SetStateAction<FiltrosPedidosState>>
  ) => void;

  // Cliente handlers
  handleGuardarCliente: (clienteData: ClienteFormInput & { id?: string }) => Promise<void>;
  handleAbrirRegistrarPago: (cliente: ClienteDB) => Promise<void>;
  handleRegistrarPago: (datosPago: DatosPagoInput) => Promise<PagoDBWithUsuario>;
  handleGenerarReciboPago: (pago: PagoDBWithUsuario, cliente: ClienteDB) => void;

  // Producto handlers
  handleGuardarProducto: (productoData: ProductoFormInput & { id?: string }) => Promise<void>;
  handleRegistrarMerma: (mermaData: MermaDataInput) => Promise<void>;

  // Pedido handlers - item management
  handleClienteChange: (clienteId: string) => void;
  agregarItemPedido: (productoId: string) => void;
  actualizarCantidadItem: (productoId: string, cantidad: number) => void;
  handleCrearClienteEnPedido: (clienteData: ClienteFormInput) => Promise<ClienteDB>;
  handleGuardarPedidoConOffline: () => Promise<void>;
  handleNotasChange: (notas: string) => void;
  handleFormaPagoChange: (formaPago: string) => void;
  handleEstadoPagoChange: (estadoPago: string) => void;
  handleMontoPagadoChange: (monto: number) => void;

  // Pedido handlers - editing and assignment
  handleAsignarTransportista: (transportistaId: string | null, marcarListo?: boolean) => Promise<void>;
  handleGuardarEdicionPedido: (pedidoData: EdicionPedidoData) => Promise<void>;

  // Pedido handlers - route optimization
  handleAplicarOrdenOptimizado: (data: OrdenOptimizadoData | OrdenOptimizadoItem[]) => Promise<void>;
  handleExportarHojaRutaOptimizada: (transportista: PerfilDB, pedidosOrdenados: PedidoDB[]) => void;
  handleCerrarModalOptimizar: () => void;

  // Usuario handlers
  handleGuardarUsuario: (usuarioData: PerfilDB) => Promise<void>;

  // Compra handlers
  handleRegistrarCompra: (compraData: CompraDataInput) => Promise<void>;
  handleAnularCompra: (compraId: string) => Promise<void>;

  // Proveedor handlers
  handleGuardarProveedor: (proveedorData: ProveedorFormInputExtended & { id?: string }) => Promise<void>;

  // Refetch functions
  refetchProductos?: () => Promise<void>;

  // Handlers para rendición
  handlePresentarRendicion?: (data: {
    rendicionId: string;
    montoRendido: number;
    justificacion?: string;
    ajustes: RendicionAjusteInput[];
  }) => Promise<{ success: boolean; diferencia: number }>;

  // Handlers para entrega con salvedad
  handleRegistrarSalvedades?: (salvedades: RegistrarSalvedadInput[]) => Promise<RegistrarSalvedadResult[]>;
  handleMarcarEntregadoConSalvedad?: (pedidoId: string) => Promise<void>;
}
 

/** Category type - can be string or object */
export type Categoria = string | { id: string; nombre: string; descripcion?: string };

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

  // Funciones de datos - flexible return types
   
  fetchPedidosEliminados: () => Promise<any[]>;
  actualizarItemsPedido: (...args: any[]) => Promise<any>;
  actualizarPreciosMasivo: (productos: Array<{ productoId: string; precioNeto?: number; impInternos?: number; precioFinal?: number }>) => Promise<{ success: boolean; actualizados: number; errores: string[] }>;
  optimizarRuta: (transportistaId: string, pedidos?: PedidoDB[]) => Promise<any>;
   

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
function ModalFallback(): ReactElement {
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
}: AppModalsProps): ReactElement {
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
  const handleExportarOrdenPreparacion = async (pedidosSeleccionados: PedidoDB[]): Promise<void> => {
    const { generarOrdenPreparacion } = await loadPdfUtils();
    return generarOrdenPreparacion(pedidosSeleccionados);
  };

  const handleExportarHojaRuta = async (transportista: PerfilDB, pedidosSeleccionados: PedidoDB[]): Promise<void> => {
    const { generarHojaRuta } = await loadPdfUtils();
    return generarHojaRuta(transportista, pedidosSeleccionados);
  };

  return (
    <Suspense fallback={null}>
      {/* Modal de Confirmación - siempre visible si hay config */}
      { }
      {modales.confirm.config?.visible && (
        <Suspense fallback={<ModalFallback />}>
          <ModalConfirmacion
            config={modales.confirm.config as any}
            onClose={() => modales.confirm.setConfig({ visible: false })}
          />
        </Suspense>
      )}

      {/* Modal de Filtro de Fecha */}
      {modales.filtroFecha.open && (
        <Suspense fallback={<ModalFallback />}>
          <ModalFiltroFecha
            filtros={filtros as any}
            onApply={(nuevosFiltros: any) => handlers.handleFiltrosChange(nuevosFiltros, filtros, setFiltros)}
            onClose={() => modales.filtroFecha.setOpen(false)}
          />
        </Suspense>
      )}
      { }

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
      { }
      {modales.producto.open && (
        <Suspense fallback={<ModalFallback />}>
          <ModalProducto
            producto={productoEditando}
            categorias={categorias as any}
            onSave={handlers.handleGuardarProducto as any}
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
            categorias={categorias as any}
            nuevoPedido={nuevoPedido}
            onClose={() => { modales.pedido.setOpen(false); appState.resetNuevoPedido(); }}
            onClienteChange={handlers.handleClienteChange}
            onAgregarItem={handlers.agregarItemPedido as any}
            onActualizarCantidad={handlers.actualizarCantidadItem}
            onCrearCliente={handlers.handleCrearClienteEnPedido as any}
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
      { }

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
      { }
      {modales.historial.open && (
        <Suspense fallback={<ModalFallback />}>
          <ModalHistorialPedido
            pedido={pedidoHistorial}
            historial={historialCambios as any}
            onClose={() => { modales.historial.setOpen(false); setPedidoHistorial(null); setHistorialCambios([]); setCargandoHistorial(false); }}
            loading={cargandoHistorial}
          />
        </Suspense>
      )}
      { }

      {/* Modal de Editar Pedido */}
      {modales.editarPedido.open && pedidoEditando && (
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
            onExportarHojaRuta={handleExportarHojaRuta as any}
            onClose={() => modales.exportarPDF.setOpen(false)}
          />
        </Suspense>
      )}

      {/* Modal de Gestión de Rutas */}
      { }
      {modales.optimizarRuta.open && (
        <Suspense fallback={<ModalFallback />}>
          <ModalGestionRutas
            transportistas={transportistas}
            pedidos={pedidos}
            onOptimizar={(transportistaId, pedidosData) => optimizarRuta(transportistaId, pedidosData)}
            onAplicarOrden={handlers.handleAplicarOrdenOptimizado as any}
            onExportarPDF={handlers.handleExportarHojaRutaOptimizada as any}
            onClose={handlers.handleCerrarModalOptimizar}
            loading={loadingOptimizacion}
            guardando={guardando}
            rutaOptimizada={rutaOptimizada as any}
            error={errorOptimizacion}
          />
        </Suspense>
      )}
      { }

      {/* Modal de Ficha de Cliente */}
      { }
      {modales.fichaCliente.open && clienteFicha && (
        <Suspense fallback={<ModalFallback />}>
          <ModalFichaCliente
            cliente={clienteFicha as any}
            onClose={() => { modales.fichaCliente.setOpen(false); setClienteFicha(null); }}
            onRegistrarPago={handlers.handleAbrirRegistrarPago as any}
          />
        </Suspense>
      )}

      {/* Modal de Registrar Pago */}
      {modales.registrarPago.open && clientePago && (
        <Suspense fallback={<ModalFallback />}>
          <ModalRegistrarPago
            cliente={clientePago as any}
            saldoPendiente={saldoPendienteCliente}
            pedidos={pedidos as any}
            onClose={() => { modales.registrarPago.setOpen(false); setClientePago(null); }}
            onConfirmar={handlers.handleRegistrarPago as any}
            onGenerarRecibo={handlers.handleGenerarReciboPago as any}
          />
        </Suspense>
      )}

      {/* Modal de Merma de Stock */}
      {modales.mermaStock.open && productoMerma && (
        <Suspense fallback={<ModalFallback />}>
          <ModalMermaStock
            producto={productoMerma as any}
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
            mermas={mermas as any}
            productos={productos as any}
            usuarios={usuarios as any}
            onClose={() => modales.historialMermas.setOpen(false)}
          />
        </Suspense>
      )}
      { }

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
      { }
      {modales.detalleCompra.open && compraDetalle && (
        <Suspense fallback={<ModalFallback />}>
          <ModalDetalleCompra
            compra={compraDetalle as any}
            onClose={() => { modales.detalleCompra.setOpen(false); setCompraDetalle(null); }}
            onAnular={handlers.handleAnularCompra}
          />
        </Suspense>
      )}

      {/* Modal de Proveedor */}
      {modales.proveedor.open && (
        <Suspense fallback={<ModalFallback />}>
          <ModalProveedor
            proveedor={proveedorEditando as any}
            onSave={handlers.handleGuardarProveedor as any}
            onClose={() => { modales.proveedor.setOpen(false); setProveedorEditando(null); }}
            guardando={guardando}
          />
        </Suspense>
      )}
      { }

      {/* Modal de Importar Precios */}
      {modales.importarPrecios.open && (
        <Suspense fallback={<ModalFallback />}>
          <ModalImportarPrecios
            productos={productos}
            onActualizarPrecios={actualizarPreciosMasivo as any}
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

      {/* Modal de Rendición */}
      {modales.rendicion.open && appState.rendicionParaModal && handlers.handlePresentarRendicion && (
        <Suspense fallback={<ModalFallback />}>
          <ModalRendicion
            rendicion={appState.rendicionParaModal}
            onPresentar={handlers.handlePresentarRendicion}
            onClose={() => {
              modales.rendicion.setOpen(false);
              appState.setRendicionParaModal(null);
            }}
          />
        </Suspense>
      )}

      {/* Modal de Entrega con Salvedad */}
      {modales.entregaConSalvedad.open && appState.pedidoParaSalvedad && handlers.handleRegistrarSalvedades && handlers.handleMarcarEntregadoConSalvedad && (
        <Suspense fallback={<ModalFallback />}>
          <ModalEntregaConSalvedad
            pedido={appState.pedidoParaSalvedad}
            onSave={handlers.handleRegistrarSalvedades}
            onMarcarEntregado={async () => {
              await handlers.handleMarcarEntregadoConSalvedad!(appState.pedidoParaSalvedad!.id);
            }}
            onClose={() => {
              modales.entregaConSalvedad.setOpen(false);
              appState.setPedidoParaSalvedad(null);
            }}
          />
        </Suspense>
      )}
    </Suspense>
  );
}
