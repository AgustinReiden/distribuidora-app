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
import { MoreVertical } from 'lucide-react';
import {
  DropdownMenu,
  DropdownMenuTrigger,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator
} from '../ui/DropdownMenu';
import { Button } from '../ui/Button';
import type { PedidoDB } from '../../types';
import { construirAccionesPedido, type AccionItem } from '../../utils/accionPrincipalPedido';

// =============================================================================
// PROPS INTERFACES
// =============================================================================

export interface AccionesDropdownProps {
  pedido: PedidoDB;
  isAdmin?: boolean;
  isPreventista?: boolean;
  isTransportista?: boolean;
  isEncargado?: boolean;
  currentUserId?: string;
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
  onNotaCreditoVenta?: (pedido: PedidoDB) => void;
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
  currentUserId,
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
}: AccionesDropdownProps): React.ReactElement {
  // El armado vive en utils/accionPrincipalPedido.ts: la tarjeta lo usa para
  // elegir su accion principal, y asi la de afuera es siempre un item de aca.
  const acciones = useMemo(
    (): AccionItem[] => construirAccionesPedido(
      pedido,
      { isAdmin, isPreventista, isTransportista, isEncargado, currentUserId },
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
      },
    ),
    [pedido, isAdmin, isPreventista, isTransportista, isEncargado, currentUserId, onHistorial, onEditar, onEditarNotas, onPreparar, onVolverAPendiente, onEntregado, onEntregadoConSalvedad, onRevertir, onCancelarPedido, onRegistrarPago, onImprimirComanda, onNotaCreditoVenta],
  );

  return (
    <DropdownMenu>
      <DropdownMenuTrigger asChild>
        <Button variant="ghost" size="icon" aria-label="Mas acciones">
          <MoreVertical className="w-5 h-5 text-gray-600 dark:text-gray-300" />
        </Button>
      </DropdownMenuTrigger>

      <DropdownMenuContent align="end" className="w-56">
        {acciones.map((accion) => {
          const IconComponent = accion.icon;
          return (
            <React.Fragment key={accion.id}>
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
