/**
 * Componente AccionesDropdown para pedidos
 * Menu desplegable accesible con acciones disponibles para un pedido
 *
 * Caracteristicas de accesibilidad:
 * - Navegacion por teclado (flechas arriba/abajo, Enter, Escape)
 * - role="menu" y role="menuitem" automaticos
 * - aria-expanded en el trigger
 * - Focus visible en items
 */
import React, { memo, useMemo } from 'react';
import { MoreVertical, History, Edit2, Package, User, Check, AlertTriangle, RotateCcw, AlertCircle, XCircle, LucideIcon } from 'lucide-react';
import {
  DropdownMenu,
  DropdownMenuTrigger,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator
} from '../ui/DropdownMenu';
import type { PedidoDB } from '../../types';

// =============================================================================
// PROPS INTERFACES
// =============================================================================

export interface AccionesDropdownProps {
  pedido: PedidoDB;
  isAdmin?: boolean;
  isPreventista?: boolean;
  isTransportista?: boolean;
  isEncargado?: boolean;
  onHistorial?: (pedido: PedidoDB) => void;
  onEditar?: (pedido: PedidoDB) => void;
  onEditarNotas?: (pedido: PedidoDB) => void;
  onPreparar?: (pedido: PedidoDB) => void;
  onVolverAPendiente?: (pedido: PedidoDB) => void;
  onAsignar?: (pedido: PedidoDB) => void;
  onEntregado?: (pedido: PedidoDB) => void;
  onEntregadoConSalvedad?: (pedido: PedidoDB) => void;
  onRevertir?: (pedido: PedidoDB) => void;
  onCancelarPedido?: (pedido: PedidoDB) => void;
}

interface AccionItem {
  label: string;
  icon: LucideIcon;
  onClick: () => void;
  className: string;
  divider?: boolean;
}

// =============================================================================
// COMPONENT
// =============================================================================

function AccionesDropdown({
  pedido,
  isAdmin,
  isPreventista,
  isTransportista,
  isEncargado,
  onHistorial,
  onEditar,
  onEditarNotas,
  onPreparar,
  onVolverAPendiente,
  onAsignar,
  onEntregado,
  onEntregadoConSalvedad,
  onRevertir,
  onCancelarPedido,
}: AccionesDropdownProps): React.ReactElement {
  // Memoizar acciones para evitar recalculos innecesarios
  const acciones = useMemo((): AccionItem[] => {
    const items: AccionItem[] = [];

    // Siempre visible
    if (onHistorial) {
      items.push({
        label: 'Ver Historial',
        icon: History,
        onClick: () => onHistorial(pedido),
        className: 'text-gray-700 dark:text-gray-300'
      });
    }

    // Admin o encargado pueden editar completamente
    if ((isAdmin || isEncargado) && onEditar) {
      items.push({
        label: 'Editar',
        icon: Edit2,
        onClick: () => onEditar(pedido),
        className: 'text-blue-700 dark:text-blue-400'
      });
    }

    // Preventista solo puede editar observaciones
    if (isPreventista && !isAdmin && !isEncargado && onEditarNotas) {
      items.push({
        label: 'Editar Observaciones',
        icon: Edit2,
        onClick: () => onEditarNotas(pedido),
        className: 'text-blue-700 dark:text-blue-400'
      });
    }

    // Admin o encargado puede preparar si esta pendiente
    if ((isAdmin || isEncargado) && pedido.estado === 'pendiente' && onPreparar) {
      items.push({
        label: 'Marcar en Preparacion',
        icon: Package,
        onClick: () => onPreparar(pedido),
        className: 'text-orange-700 dark:text-orange-400'
      });
    }

    // Admin o encargado puede volver a pendiente si esta en preparacion o asignado
    if ((isAdmin || isEncargado) && (pedido.estado === 'en_preparacion' || pedido.estado === 'asignado') && onVolverAPendiente) {
      items.push({
        label: 'Volver a Pendiente',
        icon: RotateCcw,
        onClick: () => onVolverAPendiente(pedido),
        className: 'text-gray-700 dark:text-gray-400'
      });
    }

    // Admin o encargado puede asignar si no esta entregado
    if ((isAdmin || isEncargado) && pedido.estado !== 'entregado' && onAsignar) {
      items.push({
        label: pedido.transportista ? 'Reasignar Transportista' : 'Asignar Transportista',
        icon: User,
        onClick: () => onAsignar(pedido),
        className: 'text-orange-700 dark:text-orange-400'
      });
    }

    // Transportista, admin o encargado pueden marcar entregado
    if ((isTransportista || isAdmin || isEncargado) && pedido.estado === 'asignado' && onEntregado) {
      items.push({
        label: 'Marcar Entregado',
        icon: Check,
        onClick: () => onEntregado(pedido),
        className: 'text-green-700 dark:text-green-400'
      });
    }

    // Transportista, admin o encargado pueden marcar entregado con salvedad
    if ((isTransportista || isAdmin || isEncargado) && pedido.estado === 'asignado' && onEntregadoConSalvedad && pedido.items && pedido.items.length > 0) {
      items.push({
        label: 'Entrega con Salvedad',
        icon: AlertCircle,
        onClick: () => onEntregadoConSalvedad(pedido),
        className: 'text-amber-700 dark:text-amber-400'
      });
    }

    // Admin o encargado puede revertir si esta entregado
    if ((isAdmin || isEncargado) && pedido.estado === 'entregado' && onRevertir) {
      items.push({
        label: 'Revertir Entrega',
        icon: AlertTriangle,
        onClick: () => onRevertir(pedido),
        className: 'text-yellow-700 dark:text-yellow-400'
      });
    }

    // Admin o encargado puede cancelar si no esta entregado ni cancelado
    if ((isAdmin || isEncargado) && pedido.estado !== 'entregado' && pedido.estado !== 'cancelado' && onCancelarPedido) {
      items.push({
        label: 'Cancelar Pedido',
        icon: XCircle,
        onClick: () => onCancelarPedido(pedido),
        className: 'text-red-600 dark:text-red-400',
        divider: true
      });
    }

    return items;
  }, [pedido, isAdmin, isPreventista, isTransportista, isEncargado, onHistorial, onEditar, onEditarNotas, onPreparar, onVolverAPendiente, onAsignar, onEntregado, onEntregadoConSalvedad, onRevertir, onCancelarPedido]);

  return (
    <DropdownMenu>
      <DropdownMenuTrigger asChild>
        <button
          className="p-2 hover:bg-gray-100 dark:hover:bg-gray-700 rounded-lg transition-colors focus:outline-none focus:ring-2 focus:ring-blue-500 focus:ring-offset-2 dark:focus:ring-offset-gray-800"
          aria-label="Mas acciones"
        >
          <MoreVertical className="w-5 h-5 text-gray-600 dark:text-gray-300" />
        </button>
      </DropdownMenuTrigger>

      <DropdownMenuContent align="end" className="w-56">
        {acciones.map((accion, idx) => {
          const IconComponent = accion.icon;
          return (
            <React.Fragment key={idx}>
              {accion.divider && <DropdownMenuSeparator />}
              <DropdownMenuItem
                onClick={accion.onClick}
                className={accion.className}
              >
                <IconComponent className="w-4 h-4" />
                <span>{accion.label}</span>
              </DropdownMenuItem>
            </React.Fragment>
          );
        })}
      </DropdownMenuContent>
    </DropdownMenu>
  );
}

export default memo(AccionesDropdown);
