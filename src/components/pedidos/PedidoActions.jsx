/**
 * Componente AccionesDropdown para pedidos
 * Menú desplegable accesible con acciones disponibles para un pedido
 *
 * Características de accesibilidad:
 * - Navegación por teclado (flechas arriba/abajo, Enter, Escape)
 * - role="menu" y role="menuitem" automáticos
 * - aria-expanded en el trigger
 * - Focus visible en items
 */
import React, { memo, useMemo } from 'react';
import { MoreVertical, History, Edit2, Package, User, Check, AlertTriangle, Trash2 } from 'lucide-react';
import {
  DropdownMenu,
  DropdownMenuTrigger,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator
} from '../ui/DropdownMenu';

function AccionesDropdown({
  pedido,
  isAdmin,
  isPreventista,
  isTransportista,
  onHistorial,
  onEditar,
  onPreparar,
  onAsignar,
  onEntregado,
  onRevertir,
  onEliminar
}) {
  // Memoizar acciones para evitar recálculos innecesarios
  const acciones = useMemo(() => {
    const items = [];

    // Siempre visible
    items.push({
      label: 'Ver Historial',
      icon: History,
      onClick: () => onHistorial(pedido),
      className: 'text-gray-700 dark:text-gray-300'
    });

    // Admin o preventista pueden editar
    if (isAdmin || isPreventista) {
      items.push({
        label: 'Editar',
        icon: Edit2,
        onClick: () => onEditar(pedido),
        className: 'text-blue-700 dark:text-blue-400'
      });
    }

    // Admin puede preparar si está pendiente
    if (isAdmin && pedido.estado === 'pendiente') {
      items.push({
        label: 'Marcar en Preparación',
        icon: Package,
        onClick: () => onPreparar(pedido),
        className: 'text-orange-700 dark:text-orange-400'
      });
    }

    // Admin puede asignar si no está entregado
    if (isAdmin && pedido.estado !== 'entregado') {
      items.push({
        label: pedido.transportista ? 'Reasignar Transportista' : 'Asignar Transportista',
        icon: User,
        onClick: () => onAsignar(pedido),
        className: 'text-orange-700 dark:text-orange-400'
      });
    }

    // Transportista o admin pueden marcar entregado
    if ((isTransportista || isAdmin) && pedido.estado === 'asignado') {
      items.push({
        label: 'Marcar Entregado',
        icon: Check,
        onClick: () => onEntregado(pedido),
        className: 'text-green-700 dark:text-green-400'
      });
    }

    // Admin puede revertir si está entregado
    if (isAdmin && pedido.estado === 'entregado') {
      items.push({
        label: 'Revertir Entrega',
        icon: AlertTriangle,
        onClick: () => onRevertir(pedido),
        className: 'text-yellow-700 dark:text-yellow-400'
      });
    }

    // Admin puede eliminar (con separador)
    if (isAdmin) {
      items.push({
        label: 'Eliminar',
        icon: Trash2,
        onClick: () => onEliminar(pedido.id),
        className: 'text-red-600 dark:text-red-400',
        divider: true
      });
    }

    return items;
  }, [pedido, isAdmin, isPreventista, isTransportista, onHistorial, onEditar, onPreparar, onAsignar, onEntregado, onRevertir, onEliminar]);

  return (
    <DropdownMenu>
      <DropdownMenuTrigger asChild>
        <button
          className="p-2 hover:bg-gray-100 dark:hover:bg-gray-700 rounded-lg transition-colors focus:outline-none focus:ring-2 focus:ring-blue-500 focus:ring-offset-2 dark:focus:ring-offset-gray-800"
          aria-label="Más acciones"
        >
          <MoreVertical className="w-5 h-5 text-gray-600 dark:text-gray-300" />
        </button>
      </DropdownMenuTrigger>

      <DropdownMenuContent align="end" className="w-56">
        {acciones.map((accion, idx) => (
          <React.Fragment key={idx}>
            {accion.divider && <DropdownMenuSeparator />}
            <DropdownMenuItem
              onClick={accion.onClick}
              className={accion.className}
            >
              <accion.icon className="w-4 h-4" />
              <span>{accion.label}</span>
            </DropdownMenuItem>
          </React.Fragment>
        ))}
      </DropdownMenuContent>
    </DropdownMenu>
  );
}

export default memo(AccionesDropdown);
