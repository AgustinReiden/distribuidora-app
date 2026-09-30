/**
 * Las acciones de un pedido para quien lo mira, y cuál de ellas va afuera del
 * menú ⋮ como la acción principal de la tarjeta (#768, WP-43).
 *
 * `construirAccionesPedido` es el armado del menú que antes vivía en el
 * `useMemo` de `AccionesDropdown` (PedidoActions.tsx), movido tal cual: mismas
 * condiciones, mismo orden, mismas etiquetas. Vive acá y no en el .tsx del menú
 * porque `react-refresh/only-export-components` no deja que un archivo que
 * exporta un componente exporte también una función. Lo consumen el menú y la
 * tarjeta, así que la acción de afuera es por construcción un ítem que el menú
 * YA ofrece: no hay un segundo lugar donde se decidan permisos.
 *
 * `elegirAccionPrincipal` sólo ELIGE entre esos ítems; nunca agrega uno.
 */
import {
  AlertCircle,
  AlertTriangle,
  Check,
  DollarSign,
  Edit2,
  FileMinus,
  History,
  Package,
  Printer,
  RotateCcw,
  XCircle,
  type LucideIcon,
} from 'lucide-react';
import type { PedidoDB } from '../types';
import { preventistaPuedeEditar } from './permisosPedido';

/**
 * Identificador estable de cada acción. La etiqueta puede cambiar (las tres de
 * pago comparten handler); el id dice cuál de las variantes salió.
 */
export type AccionPedidoId =
  | 'historial'
  | 'imprimir_comanda'
  | 'editar'
  | 'editar_pedido'
  | 'editar_observaciones'
  | 'registrar_pago'
  | 'ver_editar_pagos'
  | 'ver_anular_pagos'
  | 'preparar'
  | 'volver_a_pendiente'
  | 'entregado'
  | 'entrega_con_salvedad'
  | 'revertir_entrega'
  | 'nota_credito_venta'
  | 'cancelar';

export interface AccionItem {
  id: AccionPedidoId;
  label: string;
  icon: LucideIcon;
  /** Ya cierra sobre el pedido: llama al handler con el mismo objeto. */
  onClick: () => void;
  className: string;
  divider?: boolean;
}

/** Quién mira el pedido. Mismos flags que recibe `AccionesDropdown`. */
export interface ContextoAccionesPedido {
  isAdmin?: boolean;
  isPreventista?: boolean;
  isTransportista?: boolean;
  isEncargado?: boolean;
  currentUserId?: string;
}

/** Los handlers de `AccionesDropdown`. Una acción sin handler no se ofrece. */
export interface HandlersAccionesPedido {
  onHistorial?: (pedido: PedidoDB) => void;
  onEditar?: (pedido: PedidoDB) => void;
  onEditarNotas?: (pedido: PedidoDB) => void;
  onPreparar?: (pedido: PedidoDB) => void;
  onVolverAPendiente?: (pedido: PedidoDB) => void;
  onEntregado?: (pedido: PedidoDB) => void;
  onEntregadoConSalvedad?: (pedido: PedidoDB) => void;
  onRevertir?: (pedido: PedidoDB) => void;
  onCancelarPedido?: (pedido: PedidoDB) => void;
  onRegistrarPago?: (pedido: PedidoDB) => void;
  onImprimirComanda?: (pedido: PedidoDB) => void;
  /** Nota de crédito de venta sobre un pedido entregado (#833). */
  onNotaCreditoVenta?: (pedido: PedidoDB) => void;
}

/**
 * Las acciones que el menú ⋮ ofrece para este pedido y este usuario, en el
 * orden en que se muestran.
 */
export function construirAccionesPedido(
  pedido: PedidoDB,
  { isAdmin, isPreventista, isTransportista, isEncargado, currentUserId }: ContextoAccionesPedido,
  {
    onHistorial,
    onEditar,
    onEditarNotas,
    onPreparar,
    onVolverAPendiente,
    onEntregado,
    onEntregadoConSalvedad,
    onRevertir,
    onCancelarPedido,
    onRegistrarPago,
    onImprimirComanda,
    onNotaCreditoVenta,
  }: HandlersAccionesPedido,
): AccionItem[] {
  const items: AccionItem[] = [];

  // Siempre visible
  if (onHistorial) {
    items.push({
      id: 'historial',
      label: 'Ver Historial',
      icon: History,
      onClick: () => onHistorial(pedido),
      className: 'text-gray-700 dark:text-gray-300'
    });
  }

  // Imprimir comanda (ticket 75mm) de un pedido individual. Admin o encargado,
  // en cualquier estado y estado de pago.
  if ((isAdmin || isEncargado) && onImprimirComanda) {
    items.push({
      id: 'imprimir_comanda',
      label: 'Imprimir Comanda',
      icon: Printer,
      onClick: () => onImprimirComanda(pedido),
      className: 'text-purple-700 dark:text-purple-400'
    });
  }

  // Admin o encargado pueden editar completamente. Un pedido cancelado no:
  // ya tiene el stock devuelto y el total en 0, y editarlo lo devolvía por
  // segunda vez (la mig 181 lo rechaza en la RPC; acá se saca el botón).
  const cancelado = pedido.estado === 'cancelado';
  if ((isAdmin || isEncargado) && onEditar && !cancelado) {
    items.push({
      id: 'editar',
      label: 'Editar',
      icon: Edit2,
      onClick: () => onEditar(pedido),
      className: 'text-blue-700 dark:text-blue-400'
    });
  } else if (
    isPreventista && !isAdmin && !isEncargado &&
    onEditar && preventistaPuedeEditar(pedido, currentUserId)
  ) {
    // Preventista creador: edicion limitada del pedido (items, fechas) hasta 15:30 ARG
    items.push({
      id: 'editar_pedido',
      label: 'Editar Pedido',
      icon: Edit2,
      onClick: () => onEditar(pedido),
      className: 'text-blue-700 dark:text-blue-400'
    });
  } else if (isPreventista && !isAdmin && !isEncargado && onEditarNotas) {
    // Preventista fuera de ventana: solo observaciones
    items.push({
      id: 'editar_observaciones',
      label: 'Editar Observaciones',
      icon: Edit2,
      onClick: () => onEditarNotas(pedido),
      className: 'text-blue-700 dark:text-blue-400'
    });
  }

  // Registrar pago / ver-editar pagos (admin o encargado).
  // Cuando estado_pago === 'pagado', el modal abre en modo solo-lectura + edicion de
  // forma de pago de pagos previos (con bloqueo SQL si la rendicion esta cerrada).
  //
  // Un pedido CANCELADO no se puede cobrar, pero si le quedaron pagos hay que
  // poder verlos y anularlos. Antes la condicion los excluia por completo y el
  // unico camino era SQL. Se ofrece solo si efectivamente tiene plata cargada.
  const tienePagos = Number(pedido.monto_pagado ?? 0) > 0;
  if (
    (isAdmin || isEncargado) &&
    (!cancelado || tienePagos) &&
    onRegistrarPago
  ) {
    const pagado = pedido.estado_pago === 'pagado';
    items.push({
      id: cancelado ? 'ver_anular_pagos' : pagado ? 'ver_editar_pagos' : 'registrar_pago',
      label: cancelado
        ? 'Ver/Anular Pagos'
        : pagado ? 'Ver/Editar Pagos' : 'Registrar Pago',
      icon: DollarSign,
      onClick: () => onRegistrarPago(pedido),
      className: cancelado
        ? 'text-amber-700 dark:text-amber-400'
        : 'text-green-700 dark:text-green-400'
    });
  }

  // Admin o encargado puede preparar si esta pendiente
  if ((isAdmin || isEncargado) && pedido.estado === 'pendiente' && onPreparar) {
    items.push({
      id: 'preparar',
      label: 'Marcar en Preparacion',
      icon: Package,
      onClick: () => onPreparar(pedido),
      className: 'text-orange-700 dark:text-orange-400'
    });
  }

  // Admin o encargado puede volver a pendiente si esta en preparacion o asignado
  if ((isAdmin || isEncargado) && (pedido.estado === 'en_preparacion' || pedido.estado === 'asignado') && onVolverAPendiente) {
    items.push({
      id: 'volver_a_pendiente',
      label: 'Volver a Pendiente',
      icon: RotateCcw,
      onClick: () => onVolverAPendiente(pedido),
      className: 'text-gray-700 dark:text-gray-400'
    });
  }

  // Marcar entregado:
  // - Transportista: solo pedidos ruteados (estado 'asignado').
  // - Admin/encargado: cualquier estado activo (no entregado/cancelado), para
  //   poder cerrar entregas sueltas sin tener que armar una ruta.
  //
  // El transportista solo puede cerrar SUS paradas. Antes alcanzaba con el
  // rol, y con el multi-rol (mig 155) eso se volvía peligroso: el preventista
  // que también reparte ve en la lista todos los pedidos que cargó él, así
  // que le habrían aparecido botones de entrega sobre pedidos que lleva otro
  // chofer. Además, "Entrega con Salvedad" habría fallado del lado del
  // servidor (registrar_salvedad valida la pertenencia) con un error confuso.
  const esSuParada = !!currentUserId && pedido.transportista_id === currentUserId;
  const puedeEntregarStaff = (isAdmin || isEncargado)
    && pedido.estado !== 'entregado' && pedido.estado !== 'cancelado';
  const puedeEntregarTransportista = isTransportista && esSuParada && pedido.estado === 'asignado';
  if ((puedeEntregarStaff || puedeEntregarTransportista) && onEntregado) {
    items.push({
      id: 'entregado',
      label: 'Marcar Entregado',
      icon: Check,
      onClick: () => onEntregado(pedido),
      className: 'text-green-700 dark:text-green-400'
    });
  }

  // Admin/encargado sobre cualquier parada; el transportista solo sobre la suya.
  if ((isAdmin || isEncargado || (isTransportista && esSuParada)) && pedido.estado === 'asignado' && onEntregadoConSalvedad && pedido.items && pedido.items.length > 0) {
    items.push({
      id: 'entrega_con_salvedad',
      label: 'Entrega con Salvedad',
      icon: AlertCircle,
      onClick: () => onEntregadoConSalvedad(pedido),
      className: 'text-amber-700 dark:text-amber-400'
    });
  }

  // Admin o encargado puede revertir si esta entregado
  if ((isAdmin || isEncargado) && pedido.estado === 'entregado' && onRevertir) {
    items.push({
      id: 'revertir_entrega',
      label: 'Revertir Entrega',
      icon: AlertTriangle,
      onClick: () => onRevertir(pedido),
      className: 'text-yellow-700 dark:text-yellow-400'
    });
  }

  // Nota de crédito de venta (#833): el cliente aceptó el pedido y después
  // reclamó vencidos. Admin o encargado, espejo de puedeCrearNotaCreditoVenta y
  // del gate de crear_nota_credito_venta (mig 276). Solo sobre entregados, que es
  // lo que la RPC exige; no toca el pedido, así que no compite con "Revertir".
  if ((isAdmin || isEncargado) && pedido.estado === 'entregado' && onNotaCreditoVenta) {
    items.push({
      id: 'nota_credito_venta',
      label: 'Nota de crédito (vencidos)',
      icon: FileMinus,
      onClick: () => onNotaCreditoVenta(pedido),
      className: 'text-teal-700 dark:text-teal-400'
    });
  }

  // Solo admin puede cancelar pedidos (encargado bloqueado por defensa en profundidad
  // en cancelar_pedido_con_stock; ver migracion 039).
  if (isAdmin && pedido.estado !== 'entregado' && pedido.estado !== 'cancelado' && onCancelarPedido) {
    items.push({
      id: 'cancelar',
      label: 'Cancelar Pedido',
      icon: XCircle,
      onClick: () => onCancelarPedido(pedido),
      className: 'text-red-600 dark:text-red-400',
      divider: true
    });
  }

  return items;
}

/**
 * Qué acción del menú va además como botón en la tarjeta. Decisión del dueño
 * (22/09, #768): UNA por estado, la que ese estado está esperando, y sólo si el
 * menú ya se la ofrece a este usuario —acá no se decide ningún permiso—:
 *
 *  - asignado:  "Marcar Entregado" (el chofer de la parada, o el staff).
 *  - entregado: "Registrar Pago", sólo con esa etiqueta, o sea sin pagar del
 *               todo. "Ver/Editar Pagos" (ya pagado) no es lo que espera.
 *  - pendiente: "Marcar en Preparacion" (staff); si no la tiene, "Editar
 *               Pedido" (el preventista dueño, dentro de su ventana).
 *  - cualquier otro estado, o si el menú no tiene la acción: ninguna.
 *
 * Genérica en el ítem para no atarse a su forma: sólo mira el `id`.
 */
export function elegirAccionPrincipal<T extends { id: AccionPedidoId }>(
  estado: PedidoDB['estado'] | string | null | undefined,
  acciones: readonly T[],
): T | null {
  const buscar = (id: AccionPedidoId): T | null => acciones.find(a => a.id === id) ?? null;
  switch (estado) {
    case 'asignado':
      return buscar('entregado');
    case 'entregado':
      return buscar('registrar_pago');
    case 'pendiente':
      return buscar('preparar') ?? buscar('editar_pedido');
    default:
      return null;
  }
}
