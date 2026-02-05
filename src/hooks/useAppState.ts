/**
 * Hook consolidado para el estado de la aplicación
 * Usa useReducer para modales y estados de edición para evitar re-renders innecesarios
 */
import { useState, useReducer, useMemo, useCallback, Dispatch, SetStateAction } from 'react';
import { ITEMS_PER_PAGE } from '../utils/formatters';
import type {
  ClienteDB,
  ProductoDB,
  PedidoDB,
  PerfilDB,
  CompraDB,
  ProveedorDB,
  RendicionDBExtended
} from '../types';

// ============================================================================
// TYPES
// ============================================================================

export type ModalName =
  | 'cliente'
  | 'producto'
  | 'pedido'
  | 'usuario'
  | 'asignar'
  | 'filtroFecha'
  | 'historial'
  | 'editarPedido'
  | 'exportarPDF'
  | 'optimizarRuta'
  | 'fichaCliente'
  | 'registrarPago'
  | 'mermaStock'
  | 'historialMermas'
  | 'compra'
  | 'detalleCompra'
  | 'proveedor'
  | 'importarPrecios'
  | 'pedidosEliminados'
  | 'rendicion'
  | 'entregaConSalvedad';

export interface ConfirmConfig {
  visible: boolean;
  titulo?: string;
  mensaje?: string;
  tipo?: 'danger' | 'warning' | 'success' | 'info';
  onConfirm?: () => void | Promise<void>;
}

export interface ModalsState {
  cliente: boolean;
  producto: boolean;
  pedido: boolean;
  usuario: boolean;
  asignar: boolean;
  filtroFecha: boolean;
  historial: boolean;
  editarPedido: boolean;
  exportarPDF: boolean;
  optimizarRuta: boolean;
  fichaCliente: boolean;
  registrarPago: boolean;
  mermaStock: boolean;
  historialMermas: boolean;
  compra: boolean;
  detalleCompra: boolean;
  proveedor: boolean;
  importarPrecios: boolean;
  pedidosEliminados: boolean;
  rendicion: boolean;
  entregaConSalvedad: boolean;
  confirm: ConfirmConfig;
}

export type ModalAction =
  | { type: 'OPEN_MODAL'; modal: ModalName }
  | { type: 'CLOSE_MODAL'; modal: ModalName }
  | { type: 'SET_CONFIRM'; config: ConfirmConfig }
  | { type: 'CLOSE_ALL' };

export interface EditingState {
  cliente: ClienteDB | null;
  producto: ProductoDB | null;
  usuario: PerfilDB | null;
  pedidoAsignando: PedidoDB | null;
  pedidoHistorial: PedidoDB | null;
  historialCambios: unknown[];
  pedidoEditando: PedidoDB | null;
  clienteFicha: ClienteDB | null;
  clientePago: ClienteDB | null;
  saldoPendienteCliente: number;
  productoMerma: ProductoDB | null;
  compraDetalle: CompraDB | null;
  proveedor: ProveedorDB | null;
  rendicionParaModal: RendicionDBExtended | null;
  pedidoParaSalvedad: PedidoDB | null;
}

export type EditingEntityName = keyof EditingState;

export type EditingAction =
  | { type: 'SET_EDITING'; entity: EditingEntityName; data: EditingState[EditingEntityName] }
  | { type: 'CLEAR_EDITING'; entity: EditingEntityName }
  | { type: 'CLEAR_ALL' };

export interface NuevoPedidoItem {
  productoId: string;
  cantidad: number;
  precioUnitario: number;
}

export interface NuevoPedidoState {
  clienteId: string;
  items: NuevoPedidoItem[];
  notas: string;
  formaPago: string;
  estadoPago: string;
  montoPagado: number;
}

export interface ModalApi {
  open: boolean;
  setOpen: (value: boolean) => void;
}

export interface ConfirmModalApi {
  config: ConfirmConfig;
  setConfig: (config: ConfirmConfig) => void;
}

export interface ModalesApi {
  cliente: ModalApi;
  producto: ModalApi;
  pedido: ModalApi;
  usuario: ModalApi;
  asignar: ModalApi;
  filtroFecha: ModalApi;
  historial: ModalApi;
  editarPedido: ModalApi;
  exportarPDF: ModalApi;
  optimizarRuta: ModalApi;
  fichaCliente: ModalApi;
  registrarPago: ModalApi;
  mermaStock: ModalApi;
  historialMermas: ModalApi;
  compra: ModalApi;
  detalleCompra: ModalApi;
  proveedor: ModalApi;
  importarPrecios: ModalApi;
  pedidosEliminados: ModalApi;
  rendicion: ModalApi;
  entregaConSalvedad: ModalApi;
  confirm: ConfirmModalApi;
}

export interface UseAppStateReturn {
  // Vista
  vista: string;
  setVista: Dispatch<SetStateAction<string>>;

  // Recorridos
  fechaRecorridos: string;
  setFechaRecorridos: Dispatch<SetStateAction<string>>;
  estadisticasRecorridos: unknown;
  setEstadisticasRecorridos: Dispatch<SetStateAction<unknown>>;

  // Modales
  modales: ModalesApi;

  // Estados de edición
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
  setSaldoPendienteCliente: (saldo: number) => void;
  productoMerma: ProductoDB | null;
  setProductoMerma: (producto: ProductoDB | null) => void;
  compraDetalle: CompraDB | null;
  setCompraDetalle: (compra: CompraDB | null) => void;
  proveedorEditando: ProveedorDB | null;
  setProveedorEditando: (proveedor: ProveedorDB | null) => void;
  rendicionParaModal: RendicionDBExtended | null;
  setRendicionParaModal: (rendicion: RendicionDBExtended | null) => void;
  pedidoParaSalvedad: PedidoDB | null;
  setPedidoParaSalvedad: (pedido: PedidoDB | null) => void;

  // Formulario de pedido
  nuevoPedido: NuevoPedidoState;
  setNuevoPedido: Dispatch<SetStateAction<NuevoPedidoState>>;
  resetNuevoPedido: () => void;
  busqueda: string;
  setBusqueda: Dispatch<SetStateAction<string>>;
  guardando: boolean;
  setGuardando: Dispatch<SetStateAction<boolean>>;
  cargandoHistorial: boolean;
  setCargandoHistorial: Dispatch<SetStateAction<boolean>>;

  // Paginación
  paginaActual: number;
  setPaginaActual: Dispatch<SetStateAction<number>>;
}

export interface UseAppDerivedStateReturn {
  categorias: string[];
  pedidosParaMostrar: PedidoDB[];
  totalPaginas: number;
  pedidosPaginados: PedidoDB[];
}

// ============================================================================
// REDUCER PARA MODALES
// Un solo estado para todos los modales reduce re-renders significativamente
// ============================================================================

const MODAL_NAMES: ModalName[] = [
  'cliente', 'producto', 'pedido', 'usuario', 'asignar', 'filtroFecha',
  'historial', 'editarPedido', 'exportarPDF', 'optimizarRuta', 'fichaCliente',
  'registrarPago', 'mermaStock', 'historialMermas', 'compra', 'detalleCompra',
  'proveedor', 'importarPrecios', 'pedidosEliminados', 'rendicion', 'entregaConSalvedad'
];

const initialModalsState: ModalsState = {
  ...Object.fromEntries(MODAL_NAMES.map(name => [name, false])) as Record<ModalName, boolean>,
  confirm: { visible: false }
};

function modalsReducer(state: ModalsState, action: ModalAction): ModalsState {
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

const initialEditingState: EditingState = {
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
  proveedor: null,
  rendicionParaModal: null,
  pedidoParaSalvedad: null
};

function editingReducer(state: EditingState, action: EditingAction): EditingState {
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

export function useAppState(perfil: PerfilDB | null): UseAppStateReturn {
  // Vista activa
  const [vista, setVista] = useState<string>(perfil?.rol === 'admin' ? 'dashboard' : 'pedidos');

  // Estado para recorridos
  const [fechaRecorridos, setFechaRecorridos] = useState<string>(() => new Date().toISOString().split('T')[0]);
  const [estadisticasRecorridos, setEstadisticasRecorridos] = useState<unknown>(null);

  // Reducer para modales (un solo dispatch para todos)
  const [modalsState, dispatchModals] = useReducer(modalsReducer, initialModalsState);

  // Reducer para entidades en edición
  const [editingState, dispatchEditing] = useReducer(editingReducer, initialEditingState);

  // Estados del formulario de pedido
  const [nuevoPedido, setNuevoPedido] = useState<NuevoPedidoState>({
    clienteId: '',
    items: [],
    notas: '',
    formaPago: 'efectivo',
    estadoPago: 'pendiente',
    montoPagado: 0
  });

  // Estados de UI
  const [busqueda, setBusqueda] = useState<string>('');
  const [guardando, setGuardando] = useState<boolean>(false);
  const [cargandoHistorial, setCargandoHistorial] = useState<boolean>(false);
  const [paginaActual, setPaginaActual] = useState<number>(1);

  // Reset de nuevo pedido
  const resetNuevoPedido = useCallback((): void => {
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

  const modales = useMemo((): ModalesApi => {
    const createModalApi = (name: ModalName): ModalApi => ({
      open: modalsState[name] as boolean,
      setOpen: (value: boolean): void => {
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
      rendicion: createModalApi('rendicion'),
      entregaConSalvedad: createModalApi('entregaConSalvedad'),
      confirm: {
        config: modalsState.confirm,
        setConfig: (config: ConfirmConfig): void => dispatchModals({ type: 'SET_CONFIRM', config })
      }
    };
  }, [modalsState]);

  // ============================================================================
  // API DE EDICIÓN (mantiene compatibilidad con código existente)
  // ============================================================================

  // Helpers para crear setters
  const createSetter = useCallback(<T>(entity: EditingEntityName) => (data: T): void => {
    dispatchEditing({ type: 'SET_EDITING', entity, data: data as EditingState[EditingEntityName] });
  }, []);

  // createClearer removed - was unused. If needed in future, can be restored:
  // const createClearer = useCallback((entity: EditingEntityName) => (): void => {
  //   dispatchEditing({ type: 'CLEAR_EDITING', entity });
  // }, []);

  // Setters memoizados para evitar re-renders
  const setClienteEditando = useMemo(() => createSetter<ClienteDB | null>('cliente'), [createSetter]);
  const setProductoEditando = useMemo(() => createSetter<ProductoDB | null>('producto'), [createSetter]);
  const setUsuarioEditando = useMemo(() => createSetter<PerfilDB | null>('usuario'), [createSetter]);
  const setPedidoAsignando = useMemo(() => createSetter<PedidoDB | null>('pedidoAsignando'), [createSetter]);
  const setPedidoHistorial = useMemo(() => createSetter<PedidoDB | null>('pedidoHistorial'), [createSetter]);
  const setHistorialCambios = useMemo(() => createSetter<unknown[]>('historialCambios'), [createSetter]);
  const setPedidoEditando = useMemo(() => createSetter<PedidoDB | null>('pedidoEditando'), [createSetter]);
  const setClienteFicha = useMemo(() => createSetter<ClienteDB | null>('clienteFicha'), [createSetter]);
  const setClientePago = useMemo(() => createSetter<ClienteDB | null>('clientePago'), [createSetter]);
  const setSaldoPendienteCliente = useMemo(() => createSetter<number>('saldoPendienteCliente'), [createSetter]);
  const setProductoMerma = useMemo(() => createSetter<ProductoDB | null>('productoMerma'), [createSetter]);
  const setCompraDetalle = useMemo(() => createSetter<CompraDB | null>('compraDetalle'), [createSetter]);
  const setProveedorEditando = useMemo(() => createSetter<ProveedorDB | null>('proveedor'), [createSetter]);
  const setRendicionParaModal = useMemo(() => createSetter<RendicionDBExtended | null>('rendicionParaModal'), [createSetter]);
  const setPedidoParaSalvedad = useMemo(() => createSetter<PedidoDB | null>('pedidoParaSalvedad'), [createSetter]);

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
    rendicionParaModal: editingState.rendicionParaModal,
    setRendicionParaModal,
    pedidoParaSalvedad: editingState.pedidoParaSalvedad,
    setPedidoParaSalvedad,

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
export function useAppDerivedState(
  productos: ProductoDB[],
  pedidosFiltrados: () => PedidoDB[],
  busqueda: string,
  paginaActual: number
): UseAppDerivedStateReturn {
  // Categorías únicas
  const categorias = useMemo((): string[] => {
    const cats = productos.map(p => p.categoria).filter((c): c is string => Boolean(c));
    return [...new Set(cats)].sort();
  }, [productos]);

  // Filtrado y paginación de pedidos
  const pedidosParaMostrar = useMemo((): PedidoDB[] => {
    return pedidosFiltrados().filter(p =>
      !busqueda ||
      (p.cliente?.nombre_fantasia?.toLowerCase().includes(busqueda.toLowerCase())) ||
      (p.cliente?.direccion?.toLowerCase().includes(busqueda.toLowerCase())) ||
      p.id.toString().includes(busqueda)
    );
  }, [pedidosFiltrados, busqueda]);

  const totalPaginas = Math.ceil(pedidosParaMostrar.length / ITEMS_PER_PAGE);

  const pedidosPaginados = useMemo((): PedidoDB[] => {
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
export const calcularTotalPedido = (items: NuevoPedidoItem[]): number => {
  return items.reduce((t, i) => t + (i.precioUnitario * i.cantidad), 0);
};
