/**
 * Handlers para operaciones con pedidos
 *
 * Optimizado con useLatestRef para reducir dependencias en useCallback.
 */
import { useCallback, type Dispatch, type SetStateAction } from 'react'
import { useLatestRef } from '../useLatestRef'
import { calcularTotalPedido } from '../useAppState'
import { usePricingMapQuery } from '../queries/useGruposPrecioQuery'
import { resolverPreciosMayorista, aplicarPreciosMayorista } from '../../utils/precioMayorista'
import type { User } from '@supabase/supabase-js'
import type {
  ProductoDB,
  PedidoDB,
  ClienteDB,
  ClienteFormInput,
  PerfilDB,
  RutaOptimizada,
  PagoFormInput,
  PagoDBWithUsuario
} from '../../types'
import type { ModalControl, ConfirmModal, NotifyService } from './types'

// Re-exportar tipos compartidos para compatibilidad
export type { ModalControl, ConfirmModal, NotifyService } from './types'
export type { ConfirmModalConfig, NotifyOptions } from './types'

// =============================================================================
// TIPOS PARA NUEVOS PEDIDOS
// =============================================================================

export interface NuevoPedidoItem {
  productoId: string;
  cantidad: number;
  precioUnitario: number;
}

export interface NuevoPedidoState {
  clienteId: string;
  items: NuevoPedidoItem[];
  notas: string;
  formaPago?: string;
  estadoPago?: string;
  montoPagado?: number;
}

// =============================================================================
// TIPOS ESPECÍFICOS DE PEDIDO
// =============================================================================

export interface PedidoModales {
  pedido: ModalControl;
  asignar: ModalControl;
  historial: ModalControl;
  editarPedido: ModalControl;
  optimizarRuta: ModalControl;
  confirm: ConfirmModal;
}

// =============================================================================
// TIPOS PARA VALIDACION DE STOCK
// =============================================================================

export interface StockValidationError {
  productoId: string;
  mensaje: string;
}

export interface StockValidationResult {
  valido: boolean;
  errores: StockValidationError[];
}

// =============================================================================
// TIPOS PARA PEDIDO OFFLINE
// =============================================================================

export interface PedidoOfflineData {
  clienteId: number;
  items: NuevoPedidoItem[];
  total: number;
  usuarioId: string;
  notas?: string;
  formaPago?: string;
  estadoPago?: string;
  montoPagado?: number;
}

// =============================================================================
// TIPOS PARA ORDEN OPTIMIZADO
// =============================================================================

export interface OrdenOptimizadoItem {
  id: string;
  orden_entrega: number;
}

export interface OrdenOptimizadoData {
  ordenOptimizado?: OrdenOptimizadoItem[];
  transportistaId?: string | null;
  distancia?: number | null;
  duracion?: number | null;
}

// =============================================================================
// TIPOS PARA EDICION DE PEDIDO
// =============================================================================

export interface EdicionPedidoData {
  notas: string;
  formaPago: string;
  estadoPago: string;
  montoPagado?: number;
}

// =============================================================================
// TIPOS PARA HISTORIAL
// =============================================================================

export interface HistorialCambio {
  id: string;
  pedido_id: string;
  campo: string;
  valor_anterior?: string | null;
  valor_nuevo?: string | null;
  usuario_id?: string | null;
  created_at?: string;
}

// =============================================================================
// PROPS DEL HOOK
// =============================================================================

export interface UsePedidoHandlersProps {
  productos: ProductoDB[];
  crearPedido: (
    clienteId: number,
    items: NuevoPedidoItem[],
    total: number,
    usuarioId: string,
    descontarStock: (items: Array<{ productoId?: string; producto_id?: string; cantidad: number }>) => Promise<void>,
    notas?: string,
    formaPago?: string,
    estadoPago?: string
  ) => Promise<PedidoDB>;
  cambiarEstado: (pedidoId: string, nuevoEstado: string, usuarioId?: string) => Promise<void>;
  asignarTransportista: (pedidoId: string, transportistaId: string | null, marcarListo?: boolean) => Promise<void>;
  eliminarPedido: (
    pedidoId: string,
    restaurarStock: (items: Array<{ productoId?: string; producto_id?: string; cantidad: number }>) => Promise<void>,
    usuarioId?: string
  ) => Promise<void>;
  actualizarNotasPedido: (pedidoId: string, notas: string) => Promise<void>;
  actualizarEstadoPago: (pedidoId: string, estadoPago: string, montoPagado?: number) => Promise<void>;
  actualizarFormaPago: (pedidoId: string, formaPago: string) => Promise<void>;
  actualizarOrdenEntrega: (pedidosOrdenados: OrdenOptimizadoItem[]) => Promise<void>;
  actualizarItemsPedido?: (pedidoId: string, items: Array<{ producto_id: string; cantidad: number; precio_unitario: number }>, usuarioId?: string) => Promise<void>;
  fetchHistorialPedido: (pedidoId: string) => Promise<HistorialCambio[]>;
  validarStock: (items: NuevoPedidoItem[]) => StockValidationResult;
  descontarStock: (items: Array<{ productoId?: string; producto_id?: string; cantidad: number }>) => Promise<void>;
  restaurarStock: (items: Array<{ productoId?: string; producto_id?: string; cantidad: number }>) => Promise<void>;
  registrarPago: (pago: PagoFormInput) => Promise<PagoDBWithUsuario>;
  crearRecorrido: (transportistaId: string, pedidosOrdenados: OrdenOptimizadoItem[], distancia?: number | null, duracion?: number | null) => Promise<string>;
  limpiarRuta: () => void;
  agregarCliente: (cliente: ClienteFormInput) => Promise<ClienteDB>;
  modales: PedidoModales;
  setGuardando: (guardando: boolean) => void;
  setNuevoPedido: Dispatch<SetStateAction<NuevoPedidoState>>;
  resetNuevoPedido: () => void;
  nuevoPedido: NuevoPedidoState;
  setPedidoAsignando: (pedido: PedidoDB | null) => void;
  setPedidoHistorial: (pedido: PedidoDB | null) => void;
  setHistorialCambios: (historial: HistorialCambio[]) => void;
  setPedidoEditando: (pedido: PedidoDB | null) => void;
  setCargandoHistorial: (loading: boolean) => void;
  pedidoAsignando: PedidoDB | null;
  pedidoEditando: PedidoDB | null;
  refetchProductos: () => Promise<void>;
  refetchPedidos: () => Promise<void>;
  refetchMetricas: () => Promise<void>;
  notify: NotifyService;
  user: User | null;
  isOnline: boolean;
  guardarPedidoOffline: (pedido: PedidoOfflineData) => void;
  rutaOptimizada: RutaOptimizada | null;
}

// =============================================================================
// RETURN TYPE DEL HOOK
// =============================================================================

export interface UsePedidoHandlersReturn {
  // Item management
  agregarItemPedido: (productoId: string) => void;
  actualizarCantidadItem: (productoId: string, cantidad: number) => void;
  handleClienteChange: (clienteId: string) => void;
  handleNotasChange: (notas: string) => void;
  handleFormaPagoChange: (formaPago: string) => void;
  handleEstadoPagoChange: (estadoPago: string) => void;
  handleMontoPagadoChange: (montoPagado: number) => void;
  handleCrearClienteEnPedido: (nuevoCliente: ClienteFormInput) => Promise<ClienteDB>;
  handleGuardarPedidoConOffline: () => Promise<void>;
  // State changes
  handleMarcarEntregado: (pedido: PedidoDB) => void;
  handleDesmarcarEntregado: (pedido: PedidoDB) => void;
  handleMarcarEnPreparacion: (pedido: PedidoDB) => void;
  handleVolverAPendiente: (pedido: PedidoDB) => void;
  handleAsignarTransportista: (transportistaId: string | null, marcarListo?: boolean) => Promise<void>;
  handleEliminarPedido: (id: string) => void;
  // History and editing
  handleVerHistorial: (pedido: PedidoDB) => Promise<void>;
  handleEditarPedido: (pedido: PedidoDB) => void;
  handleGuardarEdicionPedido: (data: EdicionPedidoData) => Promise<void>;
  // Route optimization
  handleAplicarOrdenOptimizado: (data: OrdenOptimizadoData | OrdenOptimizadoItem[]) => Promise<void>;
  handleExportarHojaRutaOptimizada: (transportista: PerfilDB, pedidosOrdenados: PedidoDB[]) => void;
  handleCerrarModalOptimizar: () => void;
  // PDF exports (lazy loaded)
  generarOrdenPreparacion: (...args: unknown[]) => Promise<void>;
  generarHojaRuta: (...args: unknown[]) => Promise<void>;
}

export function usePedidoHandlers({
  productos,
  crearPedido,
  cambiarEstado,
  asignarTransportista,
  eliminarPedido,
  actualizarNotasPedido,
  actualizarEstadoPago,
  actualizarFormaPago,
  actualizarOrdenEntrega,
  actualizarItemsPedido: _actualizarItemsPedido, // Passed for potential future use
  fetchHistorialPedido,
  validarStock,
  descontarStock,
  restaurarStock,
  registrarPago,
  crearRecorrido,
  limpiarRuta,
  agregarCliente,
  modales,
  setGuardando,
  setNuevoPedido,
  resetNuevoPedido,
  nuevoPedido,
  setPedidoAsignando,
  setPedidoHistorial,
  setHistorialCambios,
  setPedidoEditando,
  setCargandoHistorial,
  pedidoAsignando,
  pedidoEditando,
  refetchProductos,
  refetchPedidos,
  refetchMetricas,
  notify,
  user,
  isOnline,
  guardarPedidoOffline,
  rutaOptimizada
}: UsePedidoHandlersProps): UsePedidoHandlersReturn {
  // ==========================================================================
  // REFS PARA VALORES QUE CAMBIAN FRECUENTEMENTE
  // Esto evita recrear los callbacks cuando estos valores cambian
  // ==========================================================================
  const productosRef = useLatestRef(productos)
  const nuevoPedidoRef = useLatestRef(nuevoPedido)
  const pedidoAsignandoRef = useLatestRef(pedidoAsignando)
  const pedidoEditandoRef = useLatestRef(pedidoEditando)
  const userRef = useLatestRef(user)
  const isOnlineRef = useLatestRef(isOnline)
  const rutaOptimizadaRef = useLatestRef(rutaOptimizada)

  // Pricing map for wholesale prices
  const { data: pricingMap } = usePricingMapQuery()
  const pricingMapRef = useLatestRef(pricingMap)

  // ==========================================================================
  // HANDLERS - Usan refs para valores frecuentes, deps estables para funciones
  // ==========================================================================

  // Item management - usa refs para evitar dependencias de valores cambiantes
  const agregarItemPedido = useCallback((productoId: string): void => {
    const nuevoPedido = nuevoPedidoRef.current
    const productos = productosRef.current
    const existe = nuevoPedido.items.find(i => i.productoId === productoId)
    const producto = productos.find(p => p.id === productoId)
    if (existe) {
      setNuevoPedido(prev => ({
        ...prev,
        items: prev.items.map(i => i.productoId === productoId ? { ...i, cantidad: i.cantidad + 1 } : i)
      }))
    } else {
      setNuevoPedido(prev => ({
        ...prev,
        items: [...prev.items, { productoId, cantidad: 1, precioUnitario: producto?.precio || 0 }]
      }))
    }
  }, [nuevoPedidoRef, productosRef, setNuevoPedido])

  const actualizarCantidadItem = useCallback((productoId: string, cantidad: number): void => {
    if (cantidad <= 0) {
      setNuevoPedido(prev => ({ ...prev, items: prev.items.filter(i => i.productoId !== productoId) }))
    } else {
      setNuevoPedido(prev => ({ ...prev, items: prev.items.map(i => i.productoId === productoId ? { ...i, cantidad } : i) }))
    }
  }, [setNuevoPedido])

  // Form field handlers
  const handleClienteChange = useCallback((clienteId: string): void => {
    setNuevoPedido(prev => ({ ...prev, clienteId }))
  }, [setNuevoPedido])

  const handleNotasChange = useCallback((notas: string): void => {
    setNuevoPedido(prev => ({ ...prev, notas }))
  }, [setNuevoPedido])

  const handleFormaPagoChange = useCallback((formaPago: string): void => {
    setNuevoPedido(prev => ({ ...prev, formaPago }))
  }, [setNuevoPedido])

  const handleEstadoPagoChange = useCallback((estadoPago: string): void => {
    setNuevoPedido(prev => ({ ...prev, estadoPago, montoPagado: estadoPago === 'parcial' ? prev.montoPagado : 0 }))
  }, [setNuevoPedido])

  const handleMontoPagadoChange = useCallback((montoPagado: number): void => {
    setNuevoPedido(prev => ({ ...prev, montoPagado }))
  }, [setNuevoPedido])

  const handleCrearClienteEnPedido = useCallback(async (nuevoCliente: ClienteFormInput): Promise<ClienteDB> => {
    const cliente = await agregarCliente(nuevoCliente)
    notify.success('Cliente creado correctamente')
    return cliente
  }, [agregarCliente, notify])

  // Main order creation - optimizado con refs para reducir deps de 15 a 9
  const handleGuardarPedidoConOffline = useCallback(async (): Promise<void> => {
    const nuevoPedido = nuevoPedidoRef.current
    const user = userRef.current
    const isOnline = isOnlineRef.current

    if (!nuevoPedido.clienteId || nuevoPedido.items.length === 0) {
      notify.warning('Seleccioná cliente y productos')
      return
    }
    const validacion = validarStock(nuevoPedido.items)
    if (!validacion.valido) {
      notify.error(`Stock insuficiente:\n${validacion.errores.map(e => e.mensaje).join('\n')}`, 5000)
      return
    }

    // Aplicar precios mayoristas si hay pricing map disponible
    const currentPricingMap = pricingMapRef.current
    let itemsFinales = nuevoPedido.items
    if (currentPricingMap && currentPricingMap.size > 0) {
      const preciosResueltos = resolverPreciosMayorista(nuevoPedido.items, currentPricingMap)
      itemsFinales = aplicarPreciosMayorista(nuevoPedido.items, preciosResueltos)
    }
    const totalFinal = calcularTotalPedido(itemsFinales)

    if (!isOnline) {
      guardarPedidoOffline({
        clienteId: parseInt(nuevoPedido.clienteId),
        items: itemsFinales,
        total: totalFinal,
        usuarioId: user?.id ?? '',
        notas: nuevoPedido.notas,
        formaPago: nuevoPedido.formaPago,
        estadoPago: nuevoPedido.estadoPago,
        montoPagado: nuevoPedido.montoPagado
      })
      resetNuevoPedido()
      modales.pedido.setOpen(false)
      notify.warning('Sin conexión. Pedido guardado localmente y se sincronizará automáticamente.')
      return
    }

    if (nuevoPedido.estadoPago === 'parcial' && (!nuevoPedido.montoPagado || nuevoPedido.montoPagado <= 0)) {
      notify.warning('Ingresá el monto del pago parcial')
      return
    }

    setGuardando(true)
    try {
      const pedidoCreado = await crearPedido(
        parseInt(nuevoPedido.clienteId),
        itemsFinales,
        totalFinal,
        user?.id ?? '',
        descontarStock,
        nuevoPedido.notas,
        nuevoPedido.formaPago,
        nuevoPedido.estadoPago
      )

      if (nuevoPedido.estadoPago === 'parcial' && nuevoPedido.montoPagado && nuevoPedido.montoPagado > 0 && pedidoCreado?.id) {
        await registrarPago({
          clienteId: nuevoPedido.clienteId,
          pedidoId: pedidoCreado.id,
          monto: nuevoPedido.montoPagado,
          formaPago: nuevoPedido.formaPago,
          notas: 'Pago parcial al crear pedido',
          usuarioId: user?.id ?? ''
        })
      }

      resetNuevoPedido()
      modales.pedido.setOpen(false)
      refetchProductos()
      refetchMetricas()
      notify.success('Pedido creado correctamente', { persist: true })
    } catch (e) {
      const error = e as Error
      notify.error('Error al crear pedido: ' + error.message)
    }
    setGuardando(false)
  }, [nuevoPedidoRef, userRef, isOnlineRef, pricingMapRef, validarStock, guardarPedidoOffline, resetNuevoPedido, modales.pedido, crearPedido, descontarStock, registrarPago, refetchProductos, refetchMetricas, notify, setGuardando])

  // State change handlers
  const handleMarcarEntregado = useCallback((pedido: PedidoDB): void => {
    modales.confirm.setConfig({
      visible: true,
      titulo: 'Confirmar entrega',
      mensaje: `¿Confirmar entrega del pedido #${pedido.id}?`,
      tipo: 'success',
      onConfirm: async () => {
        setGuardando(true)
        try {
          await cambiarEstado(pedido.id, 'entregado')
          refetchMetricas()
          notify.success(`Pedido #${pedido.id} marcado como entregado`, { persist: true })
        } catch (e) {
          const error = e as Error
          notify.error(error.message)
        } finally {
          setGuardando(false)
          modales.confirm.setConfig({ visible: false })
        }
      }
    })
  }, [cambiarEstado, refetchMetricas, notify, modales.confirm, setGuardando])

  const handleDesmarcarEntregado = useCallback((pedido: PedidoDB): void => {
    modales.confirm.setConfig({
      visible: true,
      titulo: 'Revertir entrega',
      mensaje: `¿Revertir entrega del pedido #${pedido.id}?`,
      tipo: 'warning',
      onConfirm: async () => {
        setGuardando(true)
        try {
          await cambiarEstado(pedido.id, pedido.transportista_id ? 'asignado' : 'pendiente')
          refetchMetricas()
          notify.warning(`Pedido #${pedido.id} revertido`)
        } catch (e) {
          const error = e as Error
          notify.error(error.message)
        } finally {
          setGuardando(false)
          modales.confirm.setConfig({ visible: false })
        }
      }
    })
  }, [cambiarEstado, refetchMetricas, notify, modales.confirm, setGuardando])

  const handleMarcarEnPreparacion = useCallback((pedido: PedidoDB): void => {
    modales.confirm.setConfig({
      visible: true,
      titulo: 'Marcar en preparación',
      mensaje: `¿Marcar pedido #${pedido.id} como "En preparación"?`,
      tipo: 'success',
      onConfirm: async () => {
        setGuardando(true)
        try {
          await cambiarEstado(pedido.id, 'en_preparacion')
          refetchMetricas()
          notify.success(`Pedido #${pedido.id} marcado como en preparación`)
        } catch (e) {
          const error = e as Error
          notify.error(error.message)
        } finally {
          setGuardando(false)
          modales.confirm.setConfig({ visible: false })
        }
      }
    })
  }, [cambiarEstado, refetchMetricas, notify, modales.confirm, setGuardando])

  const handleVolverAPendiente = useCallback((pedido: PedidoDB): void => {
    modales.confirm.setConfig({
      visible: true,
      titulo: 'Volver a pendiente',
      mensaje: `¿Volver el pedido #${pedido.id} a estado "Pendiente"? ${pedido.transportista_id ? 'Se quitará el transportista asignado.' : ''}`,
      tipo: 'warning',
      onConfirm: async () => {
        setGuardando(true)
        try {
          // Primero quitar transportista si tiene
          if (pedido.transportista_id) {
            await asignarTransportista(pedido.id, null, false)
          }
          // Luego cambiar estado a pendiente
          await cambiarEstado(pedido.id, 'pendiente')
          refetchMetricas()
          notify.warning(`Pedido #${pedido.id} vuelto a pendiente`)
        } catch (e) {
          const error = e as Error
          notify.error(error.message)
        } finally {
          setGuardando(false)
          modales.confirm.setConfig({ visible: false })
        }
      }
    })
  }, [asignarTransportista, cambiarEstado, refetchMetricas, notify, modales.confirm, setGuardando])

  const handleAsignarTransportista = useCallback(async (transportistaId: string | null, marcarListo: boolean = false): Promise<void> => {
    const pedidoAsignando = pedidoAsignandoRef.current
    if (!pedidoAsignando) return
    setGuardando(true)
    try {
      await asignarTransportista(pedidoAsignando.id, transportistaId || null, marcarListo)
      modales.asignar.setOpen(false)
      setPedidoAsignando(null)
      if (transportistaId) {
        notify.success(marcarListo ? 'Transportista asignado y pedido listo para entregar' : 'Transportista asignado (el pedido mantiene su estado actual)')
      } else {
        notify.success('Transportista desasignado')
      }
    } catch (e) {
      const error = e as Error
      notify.error('Error: ' + error.message)
    }
    setGuardando(false)
  }, [pedidoAsignandoRef, asignarTransportista, modales.asignar, setPedidoAsignando, notify, setGuardando])

  const handleEliminarPedido = useCallback((id: string): void => {
    modales.confirm.setConfig({
      visible: true,
      titulo: 'Eliminar pedido',
      mensaje: '¿Eliminar este pedido? El stock será restaurado y quedará registrado en el historial.',
      tipo: 'danger',
      onConfirm: async () => {
        setGuardando(true)
        try {
          await eliminarPedido(id, restaurarStock, userRef.current?.id)
          refetchProductos()
          refetchMetricas()
          notify.success('Pedido eliminado y registrado en historial')
        } catch (e) {
          const error = e as Error
          notify.error(error.message)
        } finally {
          setGuardando(false)
          modales.confirm.setConfig({ visible: false })
        }
      }
    })
  }, [eliminarPedido, restaurarStock, userRef, refetchProductos, refetchMetricas, notify, modales.confirm, setGuardando])

  // History and editing
  const handleVerHistorial = useCallback(async (pedido: PedidoDB): Promise<void> => {
    setPedidoHistorial(pedido)
    modales.historial.setOpen(true)
    setCargandoHistorial(true)
    try {
      const historial = await fetchHistorialPedido(pedido.id)
      setHistorialCambios(historial)
    } catch (e) {
      const error = e as Error
      notify.error('Error al cargar historial: ' + error.message)
      setHistorialCambios([])
    } finally {
      setCargandoHistorial(false)
    }
  }, [fetchHistorialPedido, setPedidoHistorial, modales.historial, setCargandoHistorial, setHistorialCambios, notify])

  const handleEditarPedido = useCallback((pedido: PedidoDB): void => {
    setPedidoEditando(pedido)
    modales.editarPedido.setOpen(true)
  }, [setPedidoEditando, modales.editarPedido])

  const handleGuardarEdicionPedido = useCallback(async ({ notas, formaPago, estadoPago, montoPagado }: EdicionPedidoData): Promise<void> => {
    const pedidoEditando = pedidoEditandoRef.current
    if (!pedidoEditando) return
    setGuardando(true)
    try {
      await actualizarNotasPedido(pedidoEditando.id, notas)
      await actualizarFormaPago(pedidoEditando.id, formaPago)
      await actualizarEstadoPago(pedidoEditando.id, estadoPago, montoPagado)
      modales.editarPedido.setOpen(false)
      setPedidoEditando(null)
      notify.success('Pedido actualizado correctamente')
    } catch (e) {
      const error = e as Error
      notify.error('Error al actualizar pedido: ' + error.message)
    }
    setGuardando(false)
  }, [pedidoEditandoRef, actualizarNotasPedido, actualizarFormaPago, actualizarEstadoPago, modales.editarPedido, setPedidoEditando, notify, setGuardando])

  // Route optimization
  const handleAplicarOrdenOptimizado = useCallback(async (data: OrdenOptimizadoData | OrdenOptimizadoItem[]): Promise<void> => {
    setGuardando(true)
    try {
      const ordenOptimizado = Array.isArray(data) ? data : data.ordenOptimizado
      const transportistaId = Array.isArray(data) ? null : (data.transportistaId || null)
      const distancia = Array.isArray(data) ? null : (data.distancia || null)
      const duracion = Array.isArray(data) ? null : (data.duracion || null)

      if (ordenOptimizado) {
        await actualizarOrdenEntrega(ordenOptimizado)
      }

      if (transportistaId && ordenOptimizado && ordenOptimizado.length > 0) {
        try {
          await crearRecorrido(transportistaId, ordenOptimizado, distancia, duracion)
          notify.success('Ruta optimizada y recorrido creado correctamente')
        } catch {
          notify.success('Orden de entrega actualizado (sin registro de recorrido)')
        }
      } else {
        notify.success('Orden de entrega actualizado correctamente')
      }

      modales.optimizarRuta.setOpen(false)
      limpiarRuta()
      refetchPedidos()
    } catch (e) {
      const error = e as Error
      notify.error('Error al actualizar orden: ' + error.message)
    }
    setGuardando(false)
  }, [actualizarOrdenEntrega, crearRecorrido, limpiarRuta, refetchPedidos, modales.optimizarRuta, notify, setGuardando])

  const handleExportarHojaRutaOptimizada = useCallback(async (transportista: PerfilDB, pedidosOrdenados: PedidoDB[]): Promise<void> => {
    try {
      const { generarHojaRutaOptimizada } = await import('../../lib/pdfExport')
      const rutaOptimizada = rutaOptimizadaRef.current
      generarHojaRutaOptimizada(transportista, pedidosOrdenados, (rutaOptimizada as { distanciaTotal?: number })?.distanciaTotal, (rutaOptimizada as { duracionTotal?: number })?.duracionTotal)
      notify.success('PDF generado correctamente')
    } catch (e) {
      const error = e as Error
      notify.error('Error al generar PDF: ' + error.message)
    }
  }, [rutaOptimizadaRef, notify])

  const handleCerrarModalOptimizar = useCallback((): void => {
    modales.optimizarRuta.setOpen(false)
    limpiarRuta()
  }, [modales.optimizarRuta, limpiarRuta])

  return {
    // Item management
    agregarItemPedido,
    actualizarCantidadItem,
    handleClienteChange,
    handleNotasChange,
    handleFormaPagoChange,
    handleEstadoPagoChange,
    handleMontoPagadoChange,
    handleCrearClienteEnPedido,
    handleGuardarPedidoConOffline,
    // State changes
    handleMarcarEntregado,
    handleDesmarcarEntregado,
    handleMarcarEnPreparacion,
    handleVolverAPendiente,
    handleAsignarTransportista,
    handleEliminarPedido,
    // History and editing
    handleVerHistorial,
    handleEditarPedido,
    handleGuardarEdicionPedido,
    // Route optimization
    handleAplicarOrdenOptimizado,
    handleExportarHojaRutaOptimizada,
    handleCerrarModalOptimizar,
    // PDF exports (lazy loaded)
    generarOrdenPreparacion: async (...args: unknown[]) => {
      const mod = await import('../../lib/pdfExport')
      return mod.generarOrdenPreparacion(...args as Parameters<typeof mod.generarOrdenPreparacion>)
    },
    generarHojaRuta: async (...args: unknown[]) => {
      const mod = await import('../../lib/pdfExport')
      return mod.generarHojaRuta(...args as Parameters<typeof mod.generarHojaRuta>)
    }
  }
}
