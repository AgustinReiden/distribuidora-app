/**
 * Hook consolidado para los handlers de la aplicación
 *
 * Este archivo compone todos los handlers específicos por dominio:
 * - useClienteHandlers: Operaciones con clientes
 * - useProductoHandlers: Operaciones con productos y mermas
 * - usePedidoHandlers: Operaciones con pedidos
 * - useCompraHandlers: Operaciones con compras
 * - useProveedorHandlers: Operaciones con proveedores
 * - useUsuarioHandlers: Operaciones con usuarios
 *
 * Refactorizado de 766 líneas a ~200 líneas usando composición modular.
 */
import { useCallback } from 'react'
import {
  useClienteHandlers,
  useProductoHandlers,
  usePedidoHandlers,
  useCompraHandlers,
  useProveedorHandlers,
  useUsuarioHandlers
} from './handlers'

export function useAppHandlers({
  // Hooks de datos
  productos,
  proveedores,

  // Funciones CRUD
  agregarCliente,
  actualizarCliente,
  eliminarCliente,
  agregarProducto,
  actualizarProducto,
  eliminarProducto,
  validarStock,
  descontarStock,
  restaurarStock,
  crearPedido,
  cambiarEstado,
  asignarTransportista,
  eliminarPedido,
  actualizarNotasPedido,
  actualizarEstadoPago,
  actualizarFormaPago,
  actualizarOrdenEntrega,
  actualizarItemsPedido,
  fetchHistorialPedido,
  actualizarUsuario,
  registrarPago,
  obtenerResumenCuenta,
  registrarMerma,
  registrarCompra,
  anularCompra,
  agregarProveedor,
  actualizarProveedor,
  crearRecorrido,
  limpiarRuta,

  // Funciones de refetch
  refetchProductos,
  refetchPedidos,
  refetchMetricas,
  refetchMermas,
  refetchCompras,
  refetchProveedores,

  // Estado de la app
  appState,

  // Notificaciones
  notify,

  // Usuario actual
  user,

  // Ruta optimizada
  rutaOptimizada,

  // Offline sync
  isOnline,
  guardarPedidoOffline,
  guardarMermaOffline
}) {
  const {
    setGuardando,
    setNuevoPedido,
    resetNuevoPedido,
    nuevoPedido,
    setBusqueda,
    setPaginaActual,
    modales,
    setClienteEditando,
    setProductoEditando,
    setUsuarioEditando,
    setPedidoAsignando,
    setPedidoHistorial,
    setHistorialCambios,
    setPedidoEditando,
    setClienteFicha,
    setClientePago,
    setSaldoPendienteCliente,
    setProductoMerma,
    setCompraDetalle,
    setProveedorEditando,
    setCargandoHistorial,
    pedidoAsignando,
    pedidoEditando
  } = appState

  // Handlers de búsqueda y filtros
  const handleBusquedaChange = useCallback((value) => {
    setBusqueda(value)
    setPaginaActual(1)
  }, [setBusqueda, setPaginaActual])

  const handleFiltrosChange = useCallback((nuevosFiltros, filtros, setFiltros) => {
    setFiltros({ ...filtros, ...nuevosFiltros })
    setPaginaActual(1)
  }, [setPaginaActual])

  // Componer handlers por dominio
  const clienteHandlers = useClienteHandlers({
    agregarCliente,
    actualizarCliente,
    eliminarCliente,
    registrarPago,
    obtenerResumenCuenta,
    modales,
    setGuardando,
    setClienteEditando,
    setClienteFicha,
    setClientePago,
    setSaldoPendienteCliente,
    notify,
    user
  })

  const productoHandlers = useProductoHandlers({
    agregarProducto,
    actualizarProducto,
    eliminarProducto,
    registrarMerma,
    modales,
    setGuardando,
    setProductoEditando,
    setProductoMerma,
    refetchProductos,
    refetchMermas,
    notify,
    user,
    isOnline,
    guardarMermaOffline
  })

  const pedidoHandlers = usePedidoHandlers({
    productos,
    crearPedido,
    cambiarEstado,
    asignarTransportista,
    eliminarPedido,
    actualizarNotasPedido,
    actualizarEstadoPago,
    actualizarFormaPago,
    actualizarOrdenEntrega,
    actualizarItemsPedido,
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
  })

  const compraHandlers = useCompraHandlers({
    registrarCompra,
    anularCompra,
    modales,
    setGuardando,
    setCompraDetalle,
    refetchProductos,
    refetchCompras,
    notify,
    user
  })

  const proveedorHandlers = useProveedorHandlers({
    proveedores,
    agregarProveedor,
    actualizarProveedor,
    modales,
    setGuardando,
    setProveedorEditando,
    refetchProveedores,
    notify
  })

  const usuarioHandlers = useUsuarioHandlers({
    actualizarUsuario,
    modales,
    setGuardando,
    setUsuarioEditando,
    notify
  })

  return {
    // Búsqueda y filtros
    handleBusquedaChange,
    handleFiltrosChange,

    // Clientes
    ...clienteHandlers,

    // Productos
    ...productoHandlers,

    // Usuarios
    ...usuarioHandlers,

    // Pedidos
    ...pedidoHandlers,

    // Compras
    ...compraHandlers,

    // Proveedores
    ...proveedorHandlers
  }
}
