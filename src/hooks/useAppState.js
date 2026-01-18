/**
 * Hook consolidado para el estado de la aplicación
 * Usa useReducer para modales y estados de edición para evitar re-renders innecesarios
 */
import { useState, useReducer, useMemo, useCallback } from 'react';
import { ITEMS_PER_PAGE } from '../utils/formatters';

// ============================================================================
// REDUCER PARA MODALES
// Un solo estado para todos los modales reduce re-renders significativamente
// ============================================================================

const MODAL_NAMES = [
  'cliente', 'producto', 'pedido', 'usuario', 'asignar', 'filtroFecha',
  'historial', 'editarPedido', 'exportarPDF', 'optimizarRuta', 'fichaCliente',
  'registrarPago', 'mermaStock', 'historialMermas', 'compra', 'detalleCompra',
  'proveedor', 'importarPrecios', 'pedidosEliminados'
];

const initialModalsState = {
  ...Object.fromEntries(MODAL_NAMES.map(name => [name, false])),
  confirm: { visible: false }
};

function modalsReducer(state, action) {
  switch (action.type) {
    case 'OPEN_MODAL':
      return { ...state, [action.modal]: true };
    case 'CLOSE_MODAL':
      return { ...state, [action.modal]: false };
    case 'SET_CONFIRM':
      return { ...state, confirm: action.config };
    case 'CLOSE_ALL':
      return initialModalsState;
    default:
      return state;
  }
}

// ============================================================================
// REDUCER PARA ENTIDADES EN EDICIÓN
// Consolida todos los estados de "editando" en un solo objeto
// ============================================================================

const initialEditingState = {
  cliente: null,
  producto: null,
  usuario: null,
  pedidoAsignando: null,
  pedidoHistorial: null,
  historialCambios: [],
  pedidoEditando: null,
  clienteFicha: null,
  clientePago: null,
  saldoPendienteCliente: 0,
  productoMerma: null,
  compraDetalle: null,
  proveedor: null
};

function editingReducer(state, action) {
  switch (action.type) {
    case 'SET_EDITING':
      return { ...state, [action.entity]: action.data };
    case 'CLEAR_EDITING':
      return { ...state, [action.entity]: action.entity === 'historialCambios' ? [] : null };
    case 'CLEAR_ALL':
      return initialEditingState;
    default:
      return state;
  }
}

// ============================================================================
// HOOK PRINCIPAL
// ============================================================================

export function useAppState(perfil) {
  // Vista activa
  const [vista, setVista] = useState(perfil?.rol === 'admin' ? 'dashboard' : 'pedidos');

  // Estado para recorridos
  const [fechaRecorridos, setFechaRecorridos] = useState(() => new Date().toISOString().split('T')[0]);
  const [estadisticasRecorridos, setEstadisticasRecorridos] = useState(null);

  // Reducer para modales (un solo dispatch para todos)
  const [modalsState, dispatchModals] = useReducer(modalsReducer, initialModalsState);

  // Reducer para entidades en edición
  const [editingState, dispatchEditing] = useReducer(editingReducer, initialEditingState);

  // Estados del formulario de pedido
  const [nuevoPedido, setNuevoPedido] = useState({
    clienteId: '',
    items: [],
    notas: '',
    formaPago: 'efectivo',
    estadoPago: 'pendiente',
    montoPagado: 0
  });

  // Estados de UI
  const [busqueda, setBusqueda] = useState('');
  const [guardando, setGuardando] = useState(false);
  const [cargandoHistorial, setCargandoHistorial] = useState(false);
  const [paginaActual, setPaginaActual] = useState(1);

  // Reset de nuevo pedido
  const resetNuevoPedido = useCallback(() => {
    setNuevoPedido({
      clienteId: '',
      items: [],
      notas: '',
      formaPago: 'efectivo',
      estadoPago: 'pendiente',
      montoPagado: 0
    });
  }, []);

  // ============================================================================
  // API DE MODALES (mantiene compatibilidad con código existente)
  // ============================================================================

  const modales = useMemo(() => {
    const createModalApi = (name) => ({
      open: modalsState[name],
      setOpen: (value) => {
        if (value) {
          dispatchModals({ type: 'OPEN_MODAL', modal: name });
        } else {
          dispatchModals({ type: 'CLOSE_MODAL', modal: name });
        }
      }
    });

    return {
      cliente: createModalApi('cliente'),
      producto: createModalApi('producto'),
      pedido: createModalApi('pedido'),
      usuario: createModalApi('usuario'),
      asignar: createModalApi('asignar'),
      filtroFecha: createModalApi('filtroFecha'),
      historial: createModalApi('historial'),
      editarPedido: createModalApi('editarPedido'),
      exportarPDF: createModalApi('exportarPDF'),
      optimizarRuta: createModalApi('optimizarRuta'),
      fichaCliente: createModalApi('fichaCliente'),
      registrarPago: createModalApi('registrarPago'),
      mermaStock: createModalApi('mermaStock'),
      historialMermas: createModalApi('historialMermas'),
      compra: createModalApi('compra'),
      detalleCompra: createModalApi('detalleCompra'),
      proveedor: createModalApi('proveedor'),
      importarPrecios: createModalApi('importarPrecios'),
      pedidosEliminados: createModalApi('pedidosEliminados'),
      confirm: {
        config: modalsState.confirm,
        setConfig: (config) => dispatchModals({ type: 'SET_CONFIRM', config })
      }
    };
  }, [modalsState]);

  // ============================================================================
  // API DE EDICIÓN (mantiene compatibilidad con código existente)
  // ============================================================================

  // Helpers para crear setters
  const createSetter = useCallback((entity) => (data) => {
    dispatchEditing({ type: 'SET_EDITING', entity, data });
  }, []);

  const createClearer = useCallback((entity) => () => {
    dispatchEditing({ type: 'CLEAR_EDITING', entity });
  }, []);

  // Setters memoizados para evitar re-renders
  const setClienteEditando = useMemo(() => createSetter('cliente'), [createSetter]);
  const setProductoEditando = useMemo(() => createSetter('producto'), [createSetter]);
  const setUsuarioEditando = useMemo(() => createSetter('usuario'), [createSetter]);
  const setPedidoAsignando = useMemo(() => createSetter('pedidoAsignando'), [createSetter]);
  const setPedidoHistorial = useMemo(() => createSetter('pedidoHistorial'), [createSetter]);
  const setHistorialCambios = useMemo(() => createSetter('historialCambios'), [createSetter]);
  const setPedidoEditando = useMemo(() => createSetter('pedidoEditando'), [createSetter]);
  const setClienteFicha = useMemo(() => createSetter('clienteFicha'), [createSetter]);
  const setClientePago = useMemo(() => createSetter('clientePago'), [createSetter]);
  const setSaldoPendienteCliente = useMemo(() => createSetter('saldoPendienteCliente'), [createSetter]);
  const setProductoMerma = useMemo(() => createSetter('productoMerma'), [createSetter]);
  const setCompraDetalle = useMemo(() => createSetter('compraDetalle'), [createSetter]);
  const setProveedorEditando = useMemo(() => createSetter('proveedor'), [createSetter]);

  return {
    // Vista
    vista,
    setVista,

    // Recorridos
    fechaRecorridos,
    setFechaRecorridos,
    estadisticasRecorridos,
    setEstadisticasRecorridos,

    // Modales (API compatible con código existente)
    modales,

    // Estados de edición (valores del reducer)
    clienteEditando: editingState.cliente,
    setClienteEditando,
    productoEditando: editingState.producto,
    setProductoEditando,
    usuarioEditando: editingState.usuario,
    setUsuarioEditando,
    pedidoAsignando: editingState.pedidoAsignando,
    setPedidoAsignando,
    pedidoHistorial: editingState.pedidoHistorial,
    setPedidoHistorial,
    historialCambios: editingState.historialCambios,
    setHistorialCambios,
    pedidoEditando: editingState.pedidoEditando,
    setPedidoEditando,
    clienteFicha: editingState.clienteFicha,
    setClienteFicha,
    clientePago: editingState.clientePago,
    setClientePago,
    saldoPendienteCliente: editingState.saldoPendienteCliente,
    setSaldoPendienteCliente,
    productoMerma: editingState.productoMerma,
    setProductoMerma,
    compraDetalle: editingState.compraDetalle,
    setCompraDetalle,
    proveedorEditando: editingState.proveedor,
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
