/**
 * Hook especializado para el estado del formulario de nuevo pedido
 *
 * Maneja:
 * - Cliente seleccionado
 * - Items del pedido
 * - Notas
 * - Forma de pago
 * - Estado de pago
 * - Monto pagado
 */
import { useState, useCallback, useMemo, type Dispatch, type SetStateAction } from 'react';

// =============================================================================
// TYPES
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
  formaPago: string;
  estadoPago: string;
  montoPagado: number;
}

export interface UsePedidoFormStateReturn {
  // Estado
  nuevoPedido: NuevoPedidoState;
  total: number;

  // Setters
  setClienteId: (clienteId: string) => void;
  setNotas: (notas: string) => void;
  setFormaPago: (formaPago: string) => void;
  setEstadoPago: (estadoPago: string) => void;
  setMontoPagado: (montoPagado: number) => void;

  // Items
  agregarItem: (productoId: string, cantidad: number, precioUnitario: number) => void;
  actualizarCantidadItem: (productoId: string, cantidad: number) => void;
  eliminarItem: (productoId: string) => void;

  // Utilidades
  reset: () => void;
  isValid: boolean;
  setNuevoPedido: Dispatch<SetStateAction<NuevoPedidoState>>;
}

// =============================================================================
// CONSTANTS
// =============================================================================

const INITIAL_STATE: NuevoPedidoState = {
  clienteId: '',
  items: [],
  notas: '',
  formaPago: 'efectivo',
  estadoPago: 'pendiente',
  montoPagado: 0
};

// =============================================================================
// HOOK
// =============================================================================

/**
 * Hook para manejar el estado del formulario de nuevo pedido
 *
 * @example
 * ```tsx
 * const {
 *   nuevoPedido,
 *   total,
 *   setClienteId,
 *   agregarItem,
 *   actualizarCantidadItem,
 *   reset,
 *   isValid
 * } = usePedidoFormState();
 *
 * // Agregar item
 * agregarItem('producto-123', 2, 1500);
 *
 * // Verificar si el pedido es válido
 * if (isValid) {
 *   await crearPedido(nuevoPedido);
 * }
 * ```
 */
export function usePedidoFormState(): UsePedidoFormStateReturn {
  const [nuevoPedido, setNuevoPedido] = useState<NuevoPedidoState>(INITIAL_STATE);

  // Calcular total
  const total = useMemo((): number => {
    return nuevoPedido.items.reduce((acc, item) => acc + item.precioUnitario * item.cantidad, 0);
  }, [nuevoPedido.items]);

  // Validación
  const isValid = useMemo((): boolean => {
    return nuevoPedido.clienteId !== '' && nuevoPedido.items.length > 0;
  }, [nuevoPedido.clienteId, nuevoPedido.items.length]);

  // Setters simples
  const setClienteId = useCallback((clienteId: string): void => {
    setNuevoPedido((prev) => ({ ...prev, clienteId }));
  }, []);

  const setNotas = useCallback((notas: string): void => {
    setNuevoPedido((prev) => ({ ...prev, notas }));
  }, []);

  const setFormaPago = useCallback((formaPago: string): void => {
    setNuevoPedido((prev) => ({ ...prev, formaPago }));
  }, []);

  const setEstadoPago = useCallback((estadoPago: string): void => {
    setNuevoPedido((prev) => ({
      ...prev,
      estadoPago,
      montoPagado: estadoPago === 'parcial' ? prev.montoPagado : 0
    }));
  }, []);

  const setMontoPagado = useCallback((montoPagado: number): void => {
    setNuevoPedido((prev) => ({ ...prev, montoPagado }));
  }, []);

  // Manejo de items
  const agregarItem = useCallback((productoId: string, cantidad: number, precioUnitario: number): void => {
    setNuevoPedido((prev) => {
      const existente = prev.items.find((i) => i.productoId === productoId);
      if (existente) {
        return {
          ...prev,
          items: prev.items.map((i) => (i.productoId === productoId ? { ...i, cantidad: i.cantidad + cantidad } : i))
        };
      }
      return {
        ...prev,
        items: [...prev.items, { productoId, cantidad, precioUnitario }]
      };
    });
  }, []);

  const actualizarCantidadItem = useCallback((productoId: string, cantidad: number): void => {
    setNuevoPedido((prev) => {
      if (cantidad <= 0) {
        return { ...prev, items: prev.items.filter((i) => i.productoId !== productoId) };
      }
      return {
        ...prev,
        items: prev.items.map((i) => (i.productoId === productoId ? { ...i, cantidad } : i))
      };
    });
  }, []);

  const eliminarItem = useCallback((productoId: string): void => {
    setNuevoPedido((prev) => ({
      ...prev,
      items: prev.items.filter((i) => i.productoId !== productoId)
    }));
  }, []);

  // Reset
  const reset = useCallback((): void => {
    setNuevoPedido(INITIAL_STATE);
  }, []);

  return {
    nuevoPedido,
    total,
    setClienteId,
    setNotas,
    setFormaPago,
    setEstadoPago,
    setMontoPagado,
    agregarItem,
    actualizarCantidadItem,
    eliminarItem,
    reset,
    isValid,
    setNuevoPedido
  };
}

/**
 * Helper para calcular el total del pedido
 */
export const calcularTotalPedido = (items: NuevoPedidoItem[]): number => {
  return items.reduce((t, i) => t + i.precioUnitario * i.cantidad, 0);
};
