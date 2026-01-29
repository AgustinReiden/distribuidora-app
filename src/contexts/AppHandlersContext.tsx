/**
 * AppHandlersContext
 *
 * Contexto centralizado para todos los handlers de la aplicacion.
 * Evita prop drilling y permite acceso directo desde cualquier componente.
 */
import React, { createContext, useContext, ReactNode, useMemo } from 'react'
import type { UseAppHandlersReturn } from '../hooks/useAppHandlers'
import type { FiltrosPedidosState } from '../types'

// =============================================================================
// TYPES
// =============================================================================

export interface AppHandlersContextValue extends UseAppHandlersReturn {
  // Funciones de refetch
  refetchProductos: () => Promise<void>
  refetchPedidos: () => Promise<void>
  refetchMetricas: () => Promise<void>
  refetchMermas: () => Promise<void>
  refetchCompras: () => Promise<void>
  refetchProveedores: () => Promise<void>

  // Funciones de Dashboard
  calcularReportePreventistas: () => Promise<void>
  cambiarPeriodo: (periodo: string) => void

  // Funciones de Pedidos
  fetchHistorialPedido: (pedidoId: string) => Promise<unknown[]>
  fetchPedidosEliminados: () => Promise<unknown[]>
  setFiltros: (filtros: FiltrosPedidosState) => void
  actualizarItemsPedido: (pedidoId: string, items: unknown[]) => Promise<unknown>
  actualizarPreciosMasivo: (precios: unknown[]) => Promise<unknown>
  optimizarRuta: (pedidos: unknown[]) => Promise<unknown>

  // Funciones de Recorridos
  fetchRecorridosHoy: () => Promise<void>
  fetchRecorridosPorFecha: (fecha: string) => Promise<void>

  // Funciones de Backup
  descargarJSON: () => Promise<void>
  exportarPedidosExcel: (pedidos: unknown[], filtros: unknown, transportistas: unknown[]) => Promise<void>

  // Auth
  logout: () => Promise<void>

  // Offline
  sincronizarPedidos: () => Promise<{ sincronizados: number; errores: string[] }>
  sincronizarMermas: () => Promise<{ sincronizados: number; errores: string[] }>
}

// =============================================================================
// CONTEXT
// =============================================================================

const AppHandlersContext = createContext<AppHandlersContextValue | null>(null)

// =============================================================================
// PROVIDER
// =============================================================================

interface AppHandlersProviderProps {
  children: ReactNode
  value: AppHandlersContextValue
}

export function AppHandlersProvider({ children, value }: AppHandlersProviderProps): React.ReactElement {
  // Memoizar el valor para evitar re-renders innecesarios
  const memoizedValue = useMemo(() => value, [value])

  return (
    <AppHandlersContext.Provider value={memoizedValue}>
      {children}
    </AppHandlersContext.Provider>
  )
}

// =============================================================================
// HOOKS
// =============================================================================

/**
 * Hook para acceder a todos los handlers de la aplicacion
 */
// eslint-disable-next-line react-refresh/only-export-components
export function useAppHandlersContext(): AppHandlersContextValue {
  const context = useContext(AppHandlersContext)
  if (!context) {
    throw new Error('useAppHandlersContext debe usarse dentro de un AppHandlersProvider')
  }
  return context
}

/**
 * Hook para acceder a handlers de clientes
 */
// eslint-disable-next-line react-refresh/only-export-components
export function useClienteHandlersContext() {
  const handlers = useAppHandlersContext()
  return {
    handleGuardarCliente: handlers.handleGuardarCliente,
    handleEliminarCliente: handlers.handleEliminarCliente,
    handleVerFichaCliente: handlers.handleVerFichaCliente,
    handleAbrirRegistrarPago: handlers.handleAbrirRegistrarPago,
    handleRegistrarPago: handlers.handleRegistrarPago,
    handleGenerarReciboPago: handlers.handleGenerarReciboPago
  }
}

/**
 * Hook para acceder a handlers de productos
 */
// eslint-disable-next-line react-refresh/only-export-components
export function useProductoHandlersContext() {
  const handlers = useAppHandlersContext()
  return {
    handleGuardarProducto: handlers.handleGuardarProducto,
    handleEliminarProducto: handlers.handleEliminarProducto,
    handleAbrirMerma: handlers.handleAbrirMerma,
    handleRegistrarMerma: handlers.handleRegistrarMerma,
    handleVerHistorialMermas: handlers.handleVerHistorialMermas
  }
}

/**
 * Hook para acceder a handlers de pedidos
 */
// eslint-disable-next-line react-refresh/only-export-components
export function usePedidoHandlersContext() {
  const handlers = useAppHandlersContext()
  return {
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
  }
}

export default AppHandlersContext
