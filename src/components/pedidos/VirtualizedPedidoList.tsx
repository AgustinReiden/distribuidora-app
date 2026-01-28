/**
 * Lista virtualizada de pedidos
 *
 * Renderiza eficientemente listas grandes de pedidos usando react-window v2.
 * Recomendado para mas de 50 pedidos.
 *
 * Usa VirtualizedListContext para pasar datos a los componentes de fila
 * en lugar del anti-patrón de window global.
 */
import React, { memo, useRef, useEffect, useState, CSSProperties } from 'react'
import { List, useDynamicRowHeight, useListRef } from 'react-window'
import { ShoppingCart } from 'lucide-react'
import PedidoCard from './PedidoCard'
import {
  VirtualizedListProvider,
  useVirtualizedListSafe,
  type VirtualizedListHandlers,
  type VirtualizedListPermissions
} from '../../contexts/VirtualizedListContext'
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
  onVolverAPendiente?: (pedido: PedidoDB) => void;
  onAsignarTransportista?: (pedido: PedidoDB) => void;
  onMarcarEntregado?: (pedido: PedidoDB) => void;
  onMarcarEntregadoConSalvedad?: (pedido: PedidoDB) => void;
  onDesmarcarEntregado?: (pedido: PedidoDB) => void;
  onEliminarPedido?: (pedidoId: string) => void;
  height?: number;
}

interface PedidoRowProps {
  index: number;
  style: CSSProperties;
  ariaAttributes?: Record<string, string>;
}

// =============================================================================
// COMPONENTS
// =============================================================================

/**
 * Componente de fila individual para el virtualizado
 *
 * Usa el Context para acceder a los datos en lugar del window global.
 * Esto es compatible con SSR, testing y React DevTools.
 */
const PedidoRow = memo(function PedidoRow({ index, style, ariaAttributes }: PedidoRowProps): React.ReactElement | null {
  // Usar el Context en lugar del window global
  const contextData = useVirtualizedListSafe()

  if (!contextData) {
    return null
  }

  const { pedidos, handlers, permissions } = contextData

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
          onVolverAPendiente={handlers?.onVolverAPendiente}
          onAsignarTransportista={handlers?.onAsignarTransportista}
          onMarcarEntregado={handlers?.onMarcarEntregado}
          onMarcarEntregadoConSalvedad={handlers?.onMarcarEntregadoConSalvedad}
          onDesmarcarEntregado={handlers?.onDesmarcarEntregado}
          onEliminarPedido={handlers?.onEliminarPedido}
        />
      </div>
    </div>
  )
})

/**
 * Contenido interno de la lista virtualizada
 *
 * Separado para poder usar el Context Provider correctamente
 */
interface VirtualizedListContentProps {
  pedidos: PedidoDB[];
  containerHeight: number;
  containerRef: React.RefObject<HTMLDivElement | null>;
}

const VirtualizedListContent = memo(function VirtualizedListContent({
  pedidos,
  containerHeight,
  containerRef
}: VirtualizedListContentProps): React.ReactElement {
  const listRef = useListRef(null)

  // Hook para alturas dinamicas
  const dynamicRowHeight = useDynamicRowHeight({
    defaultRowHeight: DEFAULT_ROW_HEIGHT,
    key: pedidos.length // Reset cuando cambia la cantidad
  })

  // Cast to any to work around react-window v2 typing issues
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
  onVolverAPendiente,
  onAsignarTransportista,
  onMarcarEntregado,
  onMarcarEntregadoConSalvedad,
  onDesmarcarEntregado,
  onEliminarPedido,
  height: propHeight
}: VirtualizedPedidoListProps): React.ReactElement {
  const containerRef = useRef<HTMLDivElement>(null)
  const [containerHeight, setContainerHeight] = useState<number>(propHeight || MAX_CONTAINER_HEIGHT)

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

  // Preparar handlers para el Context
  const handlers: VirtualizedListHandlers = {
    onVerHistorial,
    onEditarPedido,
    onMarcarEnPreparacion,
    onVolverAPendiente,
    onAsignarTransportista,
    onMarcarEntregado,
    onMarcarEntregadoConSalvedad,
    onDesmarcarEntregado,
    onEliminarPedido
  }

  // Preparar permisos para el Context
  const permissions: VirtualizedListPermissions = {
    isAdmin,
    isPreventista,
    isTransportista
  }

  return (
    <VirtualizedListProvider
      pedidos={pedidos}
      handlers={handlers}
      permissions={permissions}
    >
      <VirtualizedListContent
        pedidos={pedidos}
        containerHeight={containerHeight}
        containerRef={containerRef}
      />
    </VirtualizedListProvider>
  )
}

export default memo(VirtualizedPedidoList)
