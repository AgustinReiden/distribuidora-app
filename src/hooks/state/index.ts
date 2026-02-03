/**
 * Barrel export para hooks de estado especializados
 *
 * Estos hooks extraen partes específicas del estado de la aplicación
 * para mejorar la separación de concerns y reducir re-renders.
 */

// Modales
export { useModalsState } from './useModalsState';
export type {
  ModalName,
  ConfirmConfig,
  ModalsState,
  ModalAction,
  ModalApi,
  ConfirmModalApi,
  ModalesApi,
  UseModalsStateReturn
} from './useModalsState';

// Formulario de pedido
export { usePedidoFormState, calcularTotalPedido } from './usePedidoFormState';
export type { NuevoPedidoItem, NuevoPedidoState, UsePedidoFormStateReturn } from './usePedidoFormState';
