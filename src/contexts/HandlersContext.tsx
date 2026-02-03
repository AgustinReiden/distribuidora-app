/**
 * Contextos para handlers de la aplicación
 *
 * Estos contextos eliminan el props drilling excesivo permitiendo que los
 * componentes accedan a los handlers directamente sin necesidad de pasar
 * 20+ props a través de múltiples niveles.
 *
 * USO:
 * 1. Envolver la app con HandlersProvider en App.tsx
 * 2. Usar hooks usePedidoActions(), useClienteActions(), etc. en componentes
 */
import React, { createContext, useContext, useMemo, ReactNode } from 'react';
import type {
  PedidoDB,
  ClienteDB,
  ProductoDB,
  PerfilDB,
  ClienteFormInput,
  ProductoFormInput,
  MermaFormInput,
  CompraFormInput,
  ProveedorFormInput,
  CompraDBExtended,
  ProveedorDB
} from '../types';

// =============================================================================
// TIPOS PARA PEDIDO HANDLERS
// =============================================================================

export interface PedidoActionsContext {
  // Creación de pedidos
  agregarItemPedido: (productoId: string, cantidad?: number, precio?: number) => void;
  actualizarCantidadItem: (productoId: string, cantidad: number) => void;
  handleClienteChange: (clienteId: string) => void;
  handleNotasChange: (notas: string) => void;
  handleFormaPagoChange: (formaPago: string) => void;
  handleEstadoPagoChange: (estadoPago: string) => void;
  handleMontoPagadoChange: (montoPagado: number) => void;
  handleCrearClienteEnPedido: (nuevoCliente: ClienteFormInput) => Promise<ClienteDB>;
  handleGuardarPedidoConOffline: () => Promise<void>;

  // Estado de pedidos
  handleMarcarEntregado: (pedido: PedidoDB) => void;
  handleDesmarcarEntregado: (pedido: PedidoDB) => void;
  handleMarcarEnPreparacion: (pedido: PedidoDB) => void;
  handleVolverAPendiente: (pedido: PedidoDB) => void;
  handleAsignarTransportista: (transportistaId: string | null, marcarListo?: boolean) => Promise<void>;
  handleEliminarPedido: (id: string) => void;

  // Historial y edición
  handleVerHistorial: (pedido: PedidoDB) => Promise<void>;
  handleEditarPedido: (pedido: PedidoDB) => void;
  handleGuardarEdicionPedido: (datos: {
    notas: string;
    formaPago: string;
    estadoPago: string;
    montoPagado?: number;
  }) => Promise<void>;

  // Optimización de rutas
  handleAplicarOrdenOptimizado: (
    data:
      | {
          ordenOptimizado?: Array<{ id: string; orden_entrega: number }>;
          transportistaId?: string | null;
          distancia?: number | null;
          duracion?: number | null;
        }
      | Array<{ id: string; orden_entrega: number }>
  ) => Promise<void>;
  handleExportarHojaRutaOptimizada: (transportista: PerfilDB, pedidosOrdenados: PedidoDB[]) => void;
  handleCerrarModalOptimizar: () => void;

  // PDF
  generarOrdenPreparacion: (pedido: PedidoDB) => void;
  generarHojaRuta: (transportista: PerfilDB, pedidos: PedidoDB[]) => void;
}

// =============================================================================
// TIPOS PARA CLIENTE HANDLERS
// =============================================================================

export interface ClienteActionsContext {
  handleGuardarCliente: (cliente: ClienteFormInput) => Promise<void>;
  handleEliminarCliente: (id: string) => void;
  handleVerFichaCliente: (cliente: ClienteDB) => Promise<void>;
  handleAbrirRegistrarPago: (cliente: ClienteDB, saldo?: number) => Promise<void>;
  handleRegistrarPago: (pago: {
    clienteId: string;
    monto: number;
    formaPago: string;
    notas?: string;
  }) => Promise<void>;
  handleGenerarReciboPago: (pago: { clienteId: string; monto: number; fecha: string }) => void;
}

// =============================================================================
// TIPOS PARA PRODUCTO HANDLERS
// =============================================================================

export interface ProductoActionsContext {
  handleGuardarProducto: (producto: ProductoFormInput) => Promise<void>;
  handleEliminarProducto: (id: string) => void;
  handleAbrirMerma: (producto: ProductoDB) => void;
  handleRegistrarMerma: (merma: MermaFormInput) => Promise<void>;
  handleVerHistorialMermas: () => void;
}

// =============================================================================
// TIPOS PARA COMPRA HANDLERS
// =============================================================================

export interface CompraActionsContext {
  handleNuevaCompra: () => void;
  handleRegistrarCompra: (compraData: CompraFormInput) => Promise<void>;
  handleVerDetalleCompra: (compra: CompraDBExtended) => void;
  handleAnularCompra: (compraId: string) => void;
}

// =============================================================================
// TIPOS PARA PROVEEDOR HANDLERS
// =============================================================================

export interface ProveedorActionsContext {
  handleNuevoProveedor: () => void;
  handleEditarProveedor: (proveedor: ProveedorDB) => void;
  handleGuardarProveedor: (proveedor: ProveedorFormInput) => Promise<void>;
  handleToggleActivoProveedor: (proveedor: ProveedorDB) => Promise<void>;
  handleEliminarProveedor: (id: string) => void;
}

// =============================================================================
// TIPOS PARA USUARIO HANDLERS
// =============================================================================

export interface UsuarioActionsContext {
  handleGuardarUsuario: (usuario: Partial<PerfilDB>) => Promise<void>;
}

// =============================================================================
// CONTEXTO COMBINADO
// =============================================================================

export interface AllHandlersContext {
  pedido: PedidoActionsContext | null;
  cliente: ClienteActionsContext | null;
  producto: ProductoActionsContext | null;
  compra: CompraActionsContext | null;
  proveedor: ProveedorActionsContext | null;
  usuario: UsuarioActionsContext | null;
}

// =============================================================================
// CREAR CONTEXTOS
// =============================================================================

const PedidoActionsCtx = createContext<PedidoActionsContext | null>(null);
const ClienteActionsCtx = createContext<ClienteActionsContext | null>(null);
const ProductoActionsCtx = createContext<ProductoActionsContext | null>(null);
const CompraActionsCtx = createContext<CompraActionsContext | null>(null);
const ProveedorActionsCtx = createContext<ProveedorActionsContext | null>(null);
const UsuarioActionsCtx = createContext<UsuarioActionsContext | null>(null);

// =============================================================================
// HOOKS PARA CONSUMIR LOS CONTEXTOS
// =============================================================================

/**
 * Hook para acceder a las acciones de pedidos
 * @throws Error si se usa fuera de HandlersProvider
 */
export function usePedidoActions(): PedidoActionsContext {
  const context = useContext(PedidoActionsCtx);
  if (!context) {
    throw new Error('usePedidoActions debe usarse dentro de HandlersProvider');
  }
  return context;
}

/**
 * Hook para acceder a las acciones de clientes
 * @throws Error si se usa fuera de HandlersProvider
 */
export function useClienteActions(): ClienteActionsContext {
  const context = useContext(ClienteActionsCtx);
  if (!context) {
    throw new Error('useClienteActions debe usarse dentro de HandlersProvider');
  }
  return context;
}

/**
 * Hook para acceder a las acciones de productos
 * @throws Error si se usa fuera de HandlersProvider
 */
export function useProductoActions(): ProductoActionsContext {
  const context = useContext(ProductoActionsCtx);
  if (!context) {
    throw new Error('useProductoActions debe usarse dentro de HandlersProvider');
  }
  return context;
}

/**
 * Hook para acceder a las acciones de compras
 * @throws Error si se usa fuera de HandlersProvider
 */
export function useCompraActions(): CompraActionsContext {
  const context = useContext(CompraActionsCtx);
  if (!context) {
    throw new Error('useCompraActions debe usarse dentro de HandlersProvider');
  }
  return context;
}

/**
 * Hook para acceder a las acciones de proveedores
 * @throws Error si se usa fuera de HandlersProvider
 */
export function useProveedorActions(): ProveedorActionsContext {
  const context = useContext(ProveedorActionsCtx);
  if (!context) {
    throw new Error('useProveedorActions debe usarse dentro de HandlersProvider');
  }
  return context;
}

/**
 * Hook para acceder a las acciones de usuarios
 * @throws Error si se usa fuera de HandlersProvider
 */
export function useUsuarioActions(): UsuarioActionsContext {
  const context = useContext(UsuarioActionsCtx);
  if (!context) {
    throw new Error('useUsuarioActions debe usarse dentro de HandlersProvider');
  }
  return context;
}

// =============================================================================
// PROVIDER
// =============================================================================

interface HandlersProviderProps {
  children: ReactNode;
  handlers: {
    // Pedidos
    agregarItemPedido: PedidoActionsContext['agregarItemPedido'];
    actualizarCantidadItem: PedidoActionsContext['actualizarCantidadItem'];
    handleClienteChange: PedidoActionsContext['handleClienteChange'];
    handleNotasChange: PedidoActionsContext['handleNotasChange'];
    handleFormaPagoChange: PedidoActionsContext['handleFormaPagoChange'];
    handleEstadoPagoChange: PedidoActionsContext['handleEstadoPagoChange'];
    handleMontoPagadoChange: PedidoActionsContext['handleMontoPagadoChange'];
    handleCrearClienteEnPedido: PedidoActionsContext['handleCrearClienteEnPedido'];
    handleGuardarPedidoConOffline: PedidoActionsContext['handleGuardarPedidoConOffline'];
    handleMarcarEntregado: PedidoActionsContext['handleMarcarEntregado'];
    handleDesmarcarEntregado: PedidoActionsContext['handleDesmarcarEntregado'];
    handleMarcarEnPreparacion: PedidoActionsContext['handleMarcarEnPreparacion'];
    handleVolverAPendiente: PedidoActionsContext['handleVolverAPendiente'];
    handleAsignarTransportista: PedidoActionsContext['handleAsignarTransportista'];
    handleEliminarPedido: PedidoActionsContext['handleEliminarPedido'];
    handleVerHistorial: PedidoActionsContext['handleVerHistorial'];
    handleEditarPedido: PedidoActionsContext['handleEditarPedido'];
    handleGuardarEdicionPedido: PedidoActionsContext['handleGuardarEdicionPedido'];
    handleAplicarOrdenOptimizado: PedidoActionsContext['handleAplicarOrdenOptimizado'];
    handleExportarHojaRutaOptimizada: PedidoActionsContext['handleExportarHojaRutaOptimizada'];
    handleCerrarModalOptimizar: PedidoActionsContext['handleCerrarModalOptimizar'];
    generarOrdenPreparacion: PedidoActionsContext['generarOrdenPreparacion'];
    generarHojaRuta: PedidoActionsContext['generarHojaRuta'];
    // Clientes
    handleGuardarCliente: ClienteActionsContext['handleGuardarCliente'];
    handleEliminarCliente: ClienteActionsContext['handleEliminarCliente'];
    handleVerFichaCliente: ClienteActionsContext['handleVerFichaCliente'];
    handleAbrirRegistrarPago: ClienteActionsContext['handleAbrirRegistrarPago'];
    handleRegistrarPago: ClienteActionsContext['handleRegistrarPago'];
    handleGenerarReciboPago: ClienteActionsContext['handleGenerarReciboPago'];
    // Productos
    handleGuardarProducto: ProductoActionsContext['handleGuardarProducto'];
    handleEliminarProducto: ProductoActionsContext['handleEliminarProducto'];
    handleAbrirMerma: ProductoActionsContext['handleAbrirMerma'];
    handleRegistrarMerma: ProductoActionsContext['handleRegistrarMerma'];
    handleVerHistorialMermas: ProductoActionsContext['handleVerHistorialMermas'];
    // Compras
    handleNuevaCompra: CompraActionsContext['handleNuevaCompra'];
    handleRegistrarCompra: CompraActionsContext['handleRegistrarCompra'];
    handleVerDetalleCompra: CompraActionsContext['handleVerDetalleCompra'];
    handleAnularCompra: CompraActionsContext['handleAnularCompra'];
    // Proveedores
    handleNuevoProveedor: ProveedorActionsContext['handleNuevoProveedor'];
    handleEditarProveedor: ProveedorActionsContext['handleEditarProveedor'];
    handleGuardarProveedor: ProveedorActionsContext['handleGuardarProveedor'];
    handleToggleActivoProveedor: ProveedorActionsContext['handleToggleActivoProveedor'];
    handleEliminarProveedor: ProveedorActionsContext['handleEliminarProveedor'];
    // Usuarios
    handleGuardarUsuario: UsuarioActionsContext['handleGuardarUsuario'];
  };
}

/**
 * Provider que envuelve la aplicación para proveer handlers a todos los componentes
 *
 * @example
 * ```tsx
 * // En App.tsx
 * <HandlersProvider handlers={appHandlers}>
 *   <AppContent />
 * </HandlersProvider>
 *
 * // En cualquier componente hijo
 * function PedidoCard({ pedido }) {
 *   const { handleMarcarEntregado, handleEliminarPedido } = usePedidoActions();
 *   return (
 *     <button onClick={() => handleMarcarEntregado(pedido)}>
 *       Marcar entregado
 *     </button>
 *   );
 * }
 * ```
 */
export function HandlersProvider({ children, handlers }: HandlersProviderProps): React.ReactElement {
  // Memoizar cada contexto para evitar re-renders innecesarios
  const pedidoActions = useMemo<PedidoActionsContext>(
    () => ({
      agregarItemPedido: handlers.agregarItemPedido,
      actualizarCantidadItem: handlers.actualizarCantidadItem,
      handleClienteChange: handlers.handleClienteChange,
      handleNotasChange: handlers.handleNotasChange,
      handleFormaPagoChange: handlers.handleFormaPagoChange,
      handleEstadoPagoChange: handlers.handleEstadoPagoChange,
      handleMontoPagadoChange: handlers.handleMontoPagadoChange,
      handleCrearClienteEnPedido: handlers.handleCrearClienteEnPedido,
      handleGuardarPedidoConOffline: handlers.handleGuardarPedidoConOffline,
      handleMarcarEntregado: handlers.handleMarcarEntregado,
      handleDesmarcarEntregado: handlers.handleDesmarcarEntregado,
      handleMarcarEnPreparacion: handlers.handleMarcarEnPreparacion,
      handleVolverAPendiente: handlers.handleVolverAPendiente,
      handleAsignarTransportista: handlers.handleAsignarTransportista,
      handleEliminarPedido: handlers.handleEliminarPedido,
      handleVerHistorial: handlers.handleVerHistorial,
      handleEditarPedido: handlers.handleEditarPedido,
      handleGuardarEdicionPedido: handlers.handleGuardarEdicionPedido,
      handleAplicarOrdenOptimizado: handlers.handleAplicarOrdenOptimizado,
      handleExportarHojaRutaOptimizada: handlers.handleExportarHojaRutaOptimizada,
      handleCerrarModalOptimizar: handlers.handleCerrarModalOptimizar,
      generarOrdenPreparacion: handlers.generarOrdenPreparacion,
      generarHojaRuta: handlers.generarHojaRuta
    }),
    [
      handlers.agregarItemPedido,
      handlers.actualizarCantidadItem,
      handlers.handleClienteChange,
      handlers.handleNotasChange,
      handlers.handleFormaPagoChange,
      handlers.handleEstadoPagoChange,
      handlers.handleMontoPagadoChange,
      handlers.handleCrearClienteEnPedido,
      handlers.handleGuardarPedidoConOffline,
      handlers.handleMarcarEntregado,
      handlers.handleDesmarcarEntregado,
      handlers.handleMarcarEnPreparacion,
      handlers.handleVolverAPendiente,
      handlers.handleAsignarTransportista,
      handlers.handleEliminarPedido,
      handlers.handleVerHistorial,
      handlers.handleEditarPedido,
      handlers.handleGuardarEdicionPedido,
      handlers.handleAplicarOrdenOptimizado,
      handlers.handleExportarHojaRutaOptimizada,
      handlers.handleCerrarModalOptimizar,
      handlers.generarOrdenPreparacion,
      handlers.generarHojaRuta
    ]
  );

  const clienteActions = useMemo<ClienteActionsContext>(
    () => ({
      handleGuardarCliente: handlers.handleGuardarCliente,
      handleEliminarCliente: handlers.handleEliminarCliente,
      handleVerFichaCliente: handlers.handleVerFichaCliente,
      handleAbrirRegistrarPago: handlers.handleAbrirRegistrarPago,
      handleRegistrarPago: handlers.handleRegistrarPago,
      handleGenerarReciboPago: handlers.handleGenerarReciboPago
    }),
    [
      handlers.handleGuardarCliente,
      handlers.handleEliminarCliente,
      handlers.handleVerFichaCliente,
      handlers.handleAbrirRegistrarPago,
      handlers.handleRegistrarPago,
      handlers.handleGenerarReciboPago
    ]
  );

  const productoActions = useMemo<ProductoActionsContext>(
    () => ({
      handleGuardarProducto: handlers.handleGuardarProducto,
      handleEliminarProducto: handlers.handleEliminarProducto,
      handleAbrirMerma: handlers.handleAbrirMerma,
      handleRegistrarMerma: handlers.handleRegistrarMerma,
      handleVerHistorialMermas: handlers.handleVerHistorialMermas
    }),
    [
      handlers.handleGuardarProducto,
      handlers.handleEliminarProducto,
      handlers.handleAbrirMerma,
      handlers.handleRegistrarMerma,
      handlers.handleVerHistorialMermas
    ]
  );

  const compraActions = useMemo<CompraActionsContext>(
    () => ({
      handleNuevaCompra: handlers.handleNuevaCompra,
      handleRegistrarCompra: handlers.handleRegistrarCompra,
      handleVerDetalleCompra: handlers.handleVerDetalleCompra,
      handleAnularCompra: handlers.handleAnularCompra
    }),
    [handlers.handleNuevaCompra, handlers.handleRegistrarCompra, handlers.handleVerDetalleCompra, handlers.handleAnularCompra]
  );

  const proveedorActions = useMemo<ProveedorActionsContext>(
    () => ({
      handleNuevoProveedor: handlers.handleNuevoProveedor,
      handleEditarProveedor: handlers.handleEditarProveedor,
      handleGuardarProveedor: handlers.handleGuardarProveedor,
      handleToggleActivoProveedor: handlers.handleToggleActivoProveedor,
      handleEliminarProveedor: handlers.handleEliminarProveedor
    }),
    [
      handlers.handleNuevoProveedor,
      handlers.handleEditarProveedor,
      handlers.handleGuardarProveedor,
      handlers.handleToggleActivoProveedor,
      handlers.handleEliminarProveedor
    ]
  );

  const usuarioActions = useMemo<UsuarioActionsContext>(
    () => ({
      handleGuardarUsuario: handlers.handleGuardarUsuario
    }),
    [handlers.handleGuardarUsuario]
  );

  return (
    <PedidoActionsCtx.Provider value={pedidoActions}>
      <ClienteActionsCtx.Provider value={clienteActions}>
        <ProductoActionsCtx.Provider value={productoActions}>
          <CompraActionsCtx.Provider value={compraActions}>
            <ProveedorActionsCtx.Provider value={proveedorActions}>
              <UsuarioActionsCtx.Provider value={usuarioActions}>{children}</UsuarioActionsCtx.Provider>
            </ProveedorActionsCtx.Provider>
          </CompraActionsCtx.Provider>
        </ProductoActionsCtx.Provider>
      </ClienteActionsCtx.Provider>
    </PedidoActionsCtx.Provider>
  );
}

// Re-exportar nombres de contextos para testing
export {
  PedidoActionsCtx,
  ClienteActionsCtx,
  ProductoActionsCtx,
  CompraActionsCtx,
  ProveedorActionsCtx,
  UsuarioActionsCtx
};
