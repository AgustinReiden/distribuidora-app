/**
 * Hook especializado para el manejo de modales
 *
 * Extraído de useAppState para mejor separación de concerns.
 * Usa useReducer para optimizar re-renders.
 */
import { useReducer, useMemo, useCallback } from 'react';

// =============================================================================
// TYPES
// =============================================================================

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

export interface UseModalsStateReturn {
  modales: ModalesApi;
  closeAllModals: () => void;
}

// =============================================================================
// CONSTANTS
// =============================================================================

const MODAL_NAMES: ModalName[] = [
  'cliente',
  'producto',
  'pedido',
  'usuario',
  'asignar',
  'filtroFecha',
  'historial',
  'editarPedido',
  'exportarPDF',
  'optimizarRuta',
  'fichaCliente',
  'registrarPago',
  'mermaStock',
  'historialMermas',
  'compra',
  'detalleCompra',
  'proveedor',
  'importarPrecios',
  'pedidosEliminados',
  'rendicion',
  'entregaConSalvedad'
];

const initialModalsState: ModalsState = {
  ...(Object.fromEntries(MODAL_NAMES.map((name) => [name, false])) as Record<ModalName, boolean>),
  confirm: { visible: false }
};

// =============================================================================
// REDUCER
// =============================================================================

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

// =============================================================================
// HOOK
// =============================================================================

/**
 * Hook para manejar el estado de todos los modales de la aplicación
 *
 * @example
 * ```tsx
 * const { modales } = useModalsState();
 *
 * // Abrir modal de cliente
 * modales.cliente.setOpen(true);
 *
 * // Verificar si está abierto
 * if (modales.cliente.open) { ... }
 *
 * // Mostrar confirmación
 * modales.confirm.setConfig({
 *   visible: true,
 *   titulo: 'Confirmar',
 *   mensaje: '¿Estás seguro?',
 *   tipo: 'warning',
 *   onConfirm: async () => { ... }
 * });
 * ```
 */
export function useModalsState(): UseModalsStateReturn {
  const [modalsState, dispatchModals] = useReducer(modalsReducer, initialModalsState);

  const closeAllModals = useCallback((): void => {
    dispatchModals({ type: 'CLOSE_ALL' });
  }, []);

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

  return { modales, closeAllModals };
}
