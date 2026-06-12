/**
 * useEntregaParada — orquestación del flujo de entrega de una parada.
 *
 * Extraído de VistaRutaTransportista para compartirlo con la pantalla nueva
 * Ruta Activa (map-first). Maneja:
 *  - "Marcar entregado": si el pedido no está pagado y hay handler de pago,
 *    abre el modal de cobranza; si está pagado, marca directo.
 *  - Confirmación de pago → marca entregado al cerrar.
 *  - "Entregar sin cobrar" (cuenta corriente).
 *  - Reporte de salvedad por item.
 *
 * Los modales (ModalRegistrarPago, ModalSalvedadItem) los renderiza cada
 * pantalla con el estado que devuelve este hook.
 */
import { useRef, useState } from 'react';
import type {
  PedidoDB,
  ClienteDB,
  PedidoItemDB,
  ProductoDB,
  MotivoSalvedad,
  RegistrarSalvedadResult,
  Pago,
} from '../../types';

export interface PedidoConCliente extends PedidoDB {
  cliente?: ClienteDB;
  items: Array<PedidoItemDB & { producto?: ProductoDB }>;
}

export interface DatosPago {
  clienteId: string;
  pedidoId: string | null;
  monto: number;
  formaPago: string;
  referencia: string;
  notas: string;
  fecha: string;
}

export interface DatosSalvedad {
  pedidoId: string;
  pedidoItemId: string;
  cantidadAfectada: number;
  motivo: MotivoSalvedad;
  descripcion?: string;
  fotoUrl?: string;
  devolverStock: boolean;
}

export interface UseEntregaParadaArgs {
  onMarcarEntregado: (pedido: PedidoDB) => void;
  onRegistrarPago?: (data: DatosPago) => Promise<unknown>;
  onEntregarSinCobrar?: (pedido: PedidoDB) => void | Promise<void>;
  onRegistrarSalvedad?: (data: DatosSalvedad) => Promise<RegistrarSalvedadResult>;
}

export interface UseEntregaParadaReturn {
  /** Pedido con el modal de cobranza abierto (null = cerrado) */
  pedidoParaCobrar: PedidoConCliente | null;
  /** Item con el modal de salvedad abierto (null = cerrado) */
  salvedadModal: { pedidoId: string; item: PedidoItemDB & { producto?: ProductoDB } } | null;
  /** Punto de entrada: decide entre cobrar primero o marcar directo */
  marcarEntregado: (pedido: PedidoConCliente) => void;
  confirmarPago: (data: DatosPago) => Promise<Pago & { monto: number }>;
  cerrarModalPago: () => void;
  entregarSinCobrar: () => Promise<void>;
  abrirSalvedad: (pedidoId: string, item: PedidoItemDB & { producto?: ProductoDB }) => void;
  guardarSalvedad: (data: DatosSalvedad) => Promise<RegistrarSalvedadResult>;
  cerrarSalvedad: () => void;
}

export function useEntregaParada({
  onMarcarEntregado,
  onRegistrarPago,
  onEntregarSinCobrar,
  onRegistrarSalvedad,
}: UseEntregaParadaArgs): UseEntregaParadaReturn {
  const [pedidoParaCobrar, setPedidoParaCobrar] = useState<PedidoConCliente | null>(null);
  const [salvedadModal, setSalvedadModal] = useState<{
    pedidoId: string;
    item: PedidoItemDB & { producto?: ProductoDB };
  } | null>(null);
  // Si el pago del modal fue exitoso, al cerrarse se marca entregado.
  const pagoExitosoRef = useRef(false);

  const marcarEntregado = (pedido: PedidoConCliente): void => {
    if (onRegistrarPago && pedido.estado_pago !== 'pagado' && pedido.cliente) {
      pagoExitosoRef.current = false;
      setPedidoParaCobrar(pedido);
      return;
    }
    onMarcarEntregado(pedido as PedidoDB);
  };

  const confirmarPago = async (data: DatosPago): Promise<Pago & { monto: number }> => {
    if (!onRegistrarPago) throw new Error('Handler de pago no disponible');
    const pago = await onRegistrarPago(data);
    pagoExitosoRef.current = true;
    return pago as Pago & { monto: number };
  };

  const cerrarModalPago = (): void => {
    const pedido = pedidoParaCobrar;
    setPedidoParaCobrar(null);
    if (pagoExitosoRef.current && pedido) {
      onMarcarEntregado(pedido as PedidoDB);
    }
    pagoExitosoRef.current = false;
  };

  // Entregar a cuenta corriente (sin cobrar). Si falla, propaga para que el
  // modal quede abierto y se pueda reintentar.
  const entregarSinCobrar = async (): Promise<void> => {
    const pedido = pedidoParaCobrar;
    if (!pedido || !onEntregarSinCobrar) return;
    pagoExitosoRef.current = false;
    await onEntregarSinCobrar(pedido as PedidoDB);
    setPedidoParaCobrar(null);
  };

  const abrirSalvedad = (pedidoId: string, item: PedidoItemDB & { producto?: ProductoDB }): void => {
    setSalvedadModal({ pedidoId, item });
  };

  const guardarSalvedad = async (data: DatosSalvedad): Promise<RegistrarSalvedadResult> => {
    if (!onRegistrarSalvedad) {
      return { success: false, error: 'Funcion no disponible' };
    }
    const result = await onRegistrarSalvedad(data);
    if (result.success) {
      setSalvedadModal(null);
    }
    return result;
  };

  const cerrarSalvedad = (): void => setSalvedadModal(null);

  return {
    pedidoParaCobrar,
    salvedadModal,
    marcarEntregado,
    confirmarPago,
    cerrarModalPago,
    entregarSinCobrar,
    abrirSalvedad,
    guardarSalvedad,
    cerrarSalvedad,
  };
}
