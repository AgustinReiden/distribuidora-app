/**
 * Lista virtualizada de pedidos
 *
 * Renderiza eficientemente listas grandes de pedidos usando react-window v2.
 * Recomendado para mas de 50 pedidos.
 */
import React, { memo, useRef, useEffect, useState, CSSProperties } from 'react'
import { List, useDynamicRowHeight, useListRef } from 'react-window'
import { ShoppingCart } from 'lucide-react'
import PedidoCard from './PedidoCard'
import type { PedidoDB } from '../../types'

// =============================================================================
// CONSTANTS
// =============================================================================

// Altura estimada de cada PedidoCard (colapsada)
const DEFAULT_ROW_HEIGHT = 180

// Altura minima del contenedor
const MIN_CONTAINER_HEIGHT = 400

// Altura maxima del contenedor
const MAX_CONTAINER_HEIGHT = 800

// =============================================================================
// TYPES
// =============================================================================

export interface VirtualizedPedidoListProps {
  pedidos: PedidoDB[];
  isAdmin?: boolean;
  isPreventista?: boolean;
  isTransportista?: boolean;
  onVerHistorial?: (pedido: PedidoDB) => void;
  onEditarPedido?: (pedido: PedidoDB) => void;
  onMarcarEnPreparacion?: (pedido: PedidoDB) => void;
  onAsignarTransportista?: (pedido: PedidoDB) => void;
  onMarcarEntregado?: (pedido: PedidoDB) => void;
  onDesmarcarEntregado?: (pedido: PedidoDB) => void;
  onEliminarPedido?: (pedidoId: string) => void;
  height?: number;
}

interface PedidoRowProps {
  index: number;
  style: CSSProperties;
  ariaAttributes?: Record<string, string>;
}

interface VirtualizedPedidoListData {
  pedidos: PedidoDB[];
  handlers: {
    onVerHistorial?: (pedido: PedidoDB) => void;
    onEditarPedido?: (pedido: PedidoDB) => void;
    onMarcarEnPreparacion?: (pedido: PedidoDB) => void;
    onAsignarTransportista?: (pedido: PedidoDB) => void;
    onMarcarEntregado?: (pedido: PedidoDB) => void;
    onDesmarcarEntregado?: (pedido: PedidoDB) => void;
    onEliminarPedido?: (pedidoId: string) => void;
  };
  permissions: {
    isAdmin?: boolean;
    isPreventista?: boolean;
    isTransportista?: boolean;
  };
}

// Extend Window interface for global data storage
declare global {
  interface Window {
    __virtualizedPedidoListData?: VirtualizedPedidoListData;
  }
}

// =============================================================================
// COMPONENTS
// =============================================================================

/**
 * Componente de fila individual para el virtualizado
 * react-window v2 usa una API diferente para los row components
 */
const PedidoRow = memo(function PedidoRow({ index, style, ariaAttributes }: PedidoRowProps): React.ReactElement | null {
  // Los handlers y permisos se pasan via contexto global
  // En v2, no hay itemData - usamos un store global
  const { pedidos, handlers, permissions } = window.__virtualizedPedidoListData || {}

  if (!pedidos || !pedidos[index]) {
    return null
  }

  const pedido = pedidos[index]

  return (
    <div style={style} {...ariaAttributes}>
      <div className="pb-3">
        <PedidoCard
          pedido={pedido}
          isAdmin={permissions?.isAdmin}
          isPreventista={permissions?.isPreventista}
          isTransportista={permissions?.isTransportista}
          onVerHistorial={handlers?.onVerHistorial}
          onEditarPedido={handlers?.onEditarPedido}
          onMarcarEnPreparacion={handlers?.onMarcarEnPreparacion}
          onAsignarTransportista={handlers?.onAsignarTransportista}
          onMarcarEntregado={handlers?.onMarcarEntregado}
          onDesmarcarEntregado={handlers?.onDesmarcarEntregado}
          onEliminarPedido={handlers?.onEliminarPedido}
        />
      </div>
    </div>
  )
})

/**
 * Lista virtualizada de pedidos
 */
function VirtualizedPedidoList({
  pedidos,
  isAdmin,
  isPreventista,
  isTransportista,
  onVerHistorial,
  onEditarPedido,
  onMarcarEnPreparacion,
  onAsignarTransportista,
  onMarcarEntregado,
  onDesmarcarEntregado,
  onEliminarPedido,
  height: propHeight
}: VirtualizedPedidoListProps): React.ReactElement {
  const listRef = useListRef(null)
  const containerRef = useRef<HTMLDivElement>(null)
  const [containerHeight, setContainerHeight] = useState<number>(propHeight || MAX_CONTAINER_HEIGHT)

  // Hook para alturas dinamicas
  const dynamicRowHeight = useDynamicRowHeight({
    defaultRowHeight: DEFAULT_ROW_HEIGHT,
    key: pedidos.length // Reset cuando cambia la cantidad
  })

  // Almacenar datos en window para que PedidoRow pueda acceder
  // (react-window v2 no tiene itemData como v1)
  useEffect(() => {
    window.__virtualizedPedidoListData = {
      pedidos,
      handlers: {
        onVerHistorial,
        onEditarPedido,
        onMarcarEnPreparacion,
        onAsignarTransportista,
        onMarcarEntregado,
        onDesmarcarEntregado,
        onEliminarPedido
      },
      permissions: {
        isAdmin,
        isPreventista,
        isTransportista
      }
    }

    return () => {
      delete window.__virtualizedPedidoListData
    }
  }, [
    pedidos,
    isAdmin,
    isPreventista,
    isTransportista,
    onVerHistorial,
    onEditarPedido,
    onMarcarEnPreparacion,
    onAsignarTransportista,
    onMarcarEntregado,
    onDesmarcarEntregado,
    onEliminarPedido
  ])

  // Calcular altura del contenedor basada en el viewport
  useEffect(() => {
    if (propHeight) {
      setContainerHeight(propHeight)
      return
    }

    const updateHeight = (): void => {
      if (containerRef.current) {
        const rect = containerRef.current.getBoundingClientRect()
        const viewportHeight = window.innerHeight
        const availableHeight = viewportHeight - rect.top - 120
        const clampedHeight = Math.max(MIN_CONTAINER_HEIGHT, Math.min(MAX_CONTAINER_HEIGHT, availableHeight))
        setContainerHeight(clampedHeight)
      }
    }

    updateHeight()
    window.addEventListener('resize', updateHeight)
    return () => window.removeEventListener('resize', updateHeight)
  }, [propHeight])

  if (pedidos.length === 0) {
    return (
      <div className="text-center py-12 text-gray-500">
        <ShoppingCart className="w-12 h-12 mx-auto mb-3 opacity-50" />
        <p>No hay pedidos</p>
      </div>
    )
  }

   
  const TypedList = List as any;
  return (
    <div ref={containerRef} className="virtualized-pedido-list">
      <TypedList
        listRef={listRef}
        defaultHeight={containerHeight}
        rowCount={pedidos.length}
        rowHeight={dynamicRowHeight}
        rowComponent={PedidoRow}
        rowProps={{}}
        overscanCount={3}
        className="scrollbar-thin scrollbar-thumb-gray-300 dark:scrollbar-thumb-gray-600"
        style={{ maxHeight: containerHeight }}
      />
      <style>{`
        .virtualized-pedido-list > div {
          scrollbar-width: thin;
        }
        .virtualized-pedido-list > div::-webkit-scrollbar {
          width: 8px;
        }
        .virtualized-pedido-list > div::-webkit-scrollbar-thumb {
          background-color: #d1d5db;
          border-radius: 4px;
        }
        .virtualized-pedido-list > div::-webkit-scrollbar-track {
          background-color: transparent;
        }
        .dark .virtualized-pedido-list > div::-webkit-scrollbar-thumb {
          background-color: #4b5563;
        }
      `}</style>
    </div>
  )
}

export default memo(VirtualizedPedidoList)
