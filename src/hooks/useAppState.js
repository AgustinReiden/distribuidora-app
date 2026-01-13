/**
 * Hook consolidado para el estado de la aplicación
 * Extrae todos los useState de App.jsx para mejor organización
 */
import { useState, useMemo } from 'react';
import { ITEMS_PER_PAGE } from '../utils/formatters';

export function useAppState(perfil) {
  // Vista activa
  const [vista, setVista] = useState(perfil?.rol === 'admin' ? 'dashboard' : 'pedidos');

  // Estado para recorridos
  const [fechaRecorridos, setFechaRecorridos] = useState(() => new Date().toISOString().split('T')[0]);
  const [estadisticasRecorridos, setEstadisticasRecorridos] = useState(null);

  // Estados de modales
  const [modalCliente, setModalCliente] = useState(false);
  const [modalProducto, setModalProducto] = useState(false);
  const [modalPedido, setModalPedido] = useState(false);
  const [modalUsuario, setModalUsuario] = useState(false);
  const [modalAsignar, setModalAsignar] = useState(false);
  const [modalConfirm, setModalConfirm] = useState({ visible: false });
  const [modalFiltroFecha, setModalFiltroFecha] = useState(false);
  const [modalHistorial, setModalHistorial] = useState(false);
  const [modalEditarPedido, setModalEditarPedido] = useState(false);
  const [modalExportarPDF, setModalExportarPDF] = useState(false);
  const [modalOptimizarRuta, setModalOptimizarRuta] = useState(false);
  const [modalFichaCliente, setModalFichaCliente] = useState(false);
  const [modalRegistrarPago, setModalRegistrarPago] = useState(false);
  const [modalMermaStock, setModalMermaStock] = useState(false);
  const [modalHistorialMermas, setModalHistorialMermas] = useState(false);
  const [productoMerma, setProductoMerma] = useState(null);
  const [modalCompra, setModalCompra] = useState(false);
  const [modalDetalleCompra, setModalDetalleCompra] = useState(false);
  const [compraDetalle, setCompraDetalle] = useState(null);
  const [modalProveedor, setModalProveedor] = useState(false);
  const [proveedorEditando, setProveedorEditando] = useState(null);
  const [modalImportarPrecios, setModalImportarPrecios] = useState(false);
  const [modalPedidosEliminados, setModalPedidosEliminados] = useState(false);

  // Estados de edición
  const [clienteEditando, setClienteEditando] = useState(null);
  const [productoEditando, setProductoEditando] = useState(null);
  const [usuarioEditando, setUsuarioEditando] = useState(null);
  const [pedidoAsignando, setPedidoAsignando] = useState(null);
  const [pedidoHistorial, setPedidoHistorial] = useState(null);
  const [historialCambios, setHistorialCambios] = useState([]);
  const [pedidoEditando, setPedidoEditando] = useState(null);
  const [clienteFicha, setClienteFicha] = useState(null);
  const [clientePago, setClientePago] = useState(null);
  const [saldoPendienteCliente, setSaldoPendienteCliente] = useState(0);

  // Estados del formulario de pedido
  const [nuevoPedido, setNuevoPedido] = useState({
    clienteId: '',
    items: [],
    notas: '',
    formaPago: 'efectivo',
    estadoPago: 'pendiente',
    montoPagado: 0
  });
  const [busqueda, setBusqueda] = useState('');
  const [guardando, setGuardando] = useState(false);
  const [cargandoHistorial, setCargandoHistorial] = useState(false);

  // Paginación
  const [paginaActual, setPaginaActual] = useState(1);

  // Reset de nuevo pedido
  const resetNuevoPedido = () => {
    setNuevoPedido({
      clienteId: '',
      items: [],
      notas: '',
      formaPago: 'efectivo',
      estadoPago: 'pendiente',
      montoPagado: 0
    });
  };

  return {
    // Vista
    vista,
    setVista,

    // Recorridos
    fechaRecorridos,
    setFechaRecorridos,
    estadisticasRecorridos,
    setEstadisticasRecorridos,

    // Modales
    modales: {
      cliente: { open: modalCliente, setOpen: setModalCliente },
      producto: { open: modalProducto, setOpen: setModalProducto },
      pedido: { open: modalPedido, setOpen: setModalPedido },
      usuario: { open: modalUsuario, setOpen: setModalUsuario },
      asignar: { open: modalAsignar, setOpen: setModalAsignar },
      confirm: { config: modalConfirm, setConfig: setModalConfirm },
      filtroFecha: { open: modalFiltroFecha, setOpen: setModalFiltroFecha },
      historial: { open: modalHistorial, setOpen: setModalHistorial },
      editarPedido: { open: modalEditarPedido, setOpen: setModalEditarPedido },
      exportarPDF: { open: modalExportarPDF, setOpen: setModalExportarPDF },
      optimizarRuta: { open: modalOptimizarRuta, setOpen: setModalOptimizarRuta },
      fichaCliente: { open: modalFichaCliente, setOpen: setModalFichaCliente },
      registrarPago: { open: modalRegistrarPago, setOpen: setModalRegistrarPago },
      mermaStock: { open: modalMermaStock, setOpen: setModalMermaStock },
      historialMermas: { open: modalHistorialMermas, setOpen: setModalHistorialMermas },
      compra: { open: modalCompra, setOpen: setModalCompra },
      detalleCompra: { open: modalDetalleCompra, setOpen: setModalDetalleCompra },
      proveedor: { open: modalProveedor, setOpen: setModalProveedor },
      importarPrecios: { open: modalImportarPrecios, setOpen: setModalImportarPrecios },
      pedidosEliminados: { open: modalPedidosEliminados, setOpen: setModalPedidosEliminados }
    },

    // Estados de edición
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
    setSaldoPendienteCliente,
    productoMerma,
    setProductoMerma,
    compraDetalle,
    setCompraDetalle,
    proveedorEditando,
    setProveedorEditando,

    // Formulario de pedido
    nuevoPedido,
    setNuevoPedido,
    resetNuevoPedido,
    busqueda,
    setBusqueda,
    guardando,
    setGuardando,
    cargandoHistorial,
    setCargandoHistorial,

    // Paginación
    paginaActual,
    setPaginaActual
  };
}

/**
 * Hook para calcular datos derivados
 */
export function useAppDerivedState(productos, pedidosFiltrados, busqueda, paginaActual) {
  // Categorías únicas
  const categorias = useMemo(() => {
    const cats = productos.map(p => p.categoria).filter(Boolean);
    return [...new Set(cats)].sort();
  }, [productos]);

  // Filtrado y paginación de pedidos
  const pedidosParaMostrar = useMemo(() => {
    return pedidosFiltrados().filter(p =>
      !busqueda ||
      p.cliente?.nombre_fantasia?.toLowerCase().includes(busqueda.toLowerCase()) ||
      p.cliente?.direccion?.toLowerCase().includes(busqueda.toLowerCase()) ||
      p.id.toString().includes(busqueda)
    );
  }, [pedidosFiltrados, busqueda]);

  const totalPaginas = Math.ceil(pedidosParaMostrar.length / ITEMS_PER_PAGE);

  const pedidosPaginados = useMemo(() => {
    const inicio = (paginaActual - 1) * ITEMS_PER_PAGE;
    return pedidosParaMostrar.slice(inicio, inicio + ITEMS_PER_PAGE);
  }, [pedidosParaMostrar, paginaActual]);

  return {
    categorias,
    pedidosParaMostrar,
    totalPaginas,
    pedidosPaginados
  };
}

/**
 * Helper para calcular total del pedido
 */
export const calcularTotalPedido = (items) => {
  return items.reduce((t, i) => t + (i.precioUnitario * i.cantidad), 0);
};
