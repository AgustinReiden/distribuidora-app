/* eslint-disable react-refresh/only-export-components */
/**
 * Componente de lista virtualizada generico
 *
 * Usa react-window v2 para renderizar eficientemente listas grandes.
 * Solo renderiza los elementos visibles en el viewport.
 *
 * Beneficios:
 * - Mejora el rendimiento con listas de 100+ elementos
 * - Reduce el uso de memoria
 * - Scroll suave incluso con miles de elementos
 */
import React, { memo, useCallback, useRef, useEffect, useState, CSSProperties, ComponentType, RefObject } from 'react'
import { List, useListRef } from 'react-window'

// =============================================================================
// PROPS INTERFACES
// =============================================================================

export interface VirtualFixedListProps<T> {
  items: T[];
  itemHeight: number;
  height?: number;
  width?: number | string;
  overscanCount?: number;
  renderItem: (item: T, index: number) => React.ReactNode;
  className?: string;
  emptyMessage?: string;
  EmptyComponent?: ComponentType | null;
}

export interface VirtualVariableListProps<T> {
  items: T[];
  getItemSize?: (item: T, index: number) => number;
  estimatedItemSize?: number;
  height?: number;
  width?: number | string;
  overscanCount?: number;
  renderItem: (item: T, index: number) => React.ReactNode;
  className?: string;
  emptyMessage?: string;
  EmptyComponent?: ComponentType | null;
}

export interface UseContainerHeightReturn {
  containerRef: RefObject<HTMLDivElement | null>;
  height: number;
}

// Extend global Window interface for virtual list data
declare global {
  interface Window {
    __virtualFixedListItems?: unknown[];
    __virtualFixedListRenderItem?: (item: unknown, index: number) => React.ReactNode;
    __virtualVariableListItems?: unknown[];
    __virtualVariableListRenderItem?: (item: unknown, index: number) => React.ReactNode;
  }
}

// =============================================================================
// COMPONENTS
// =============================================================================

/**
 * Lista virtualizada de tamano fijo
 * Usar cuando todos los items tienen la misma altura
 */
export const VirtualFixedList = memo(function VirtualFixedList<T>({
  items,
  itemHeight,
  height = 600,
  width = '100%',
  overscanCount = 5,
  renderItem,
  className = '',
  emptyMessage = 'No hay elementos',
  EmptyComponent = null
}: VirtualFixedListProps<T>): React.ReactElement | null {
  const listRef = useListRef(null)

  // Store items in window for row component access (react-window v2 pattern)
  useEffect(() => {
    window.__virtualFixedListItems = items as unknown[];
    window.__virtualFixedListRenderItem = renderItem as (item: unknown, index: number) => React.ReactNode;
    return () => {
      delete window.__virtualFixedListItems;
      delete window.__virtualFixedListRenderItem;
    }
  }, [items, renderItem])

  // Row component for react-window v2
  const Row = useCallback(({ index, style }: { index: number; style: CSSProperties }): React.ReactElement => {
    const currentItems = window.__virtualFixedListItems as T[];
    const currentRenderItem = window.__virtualFixedListRenderItem as (item: T, index: number) => React.ReactNode;
    const item = currentItems[index];
    return (
      <div style={style}>
        {currentRenderItem(item, index)}
      </div>
    )
  }, [])

  if (items.length === 0) {
    if (EmptyComponent) return <EmptyComponent />
    return (
      <div className="text-center py-12 text-gray-500">
        <p>{emptyMessage}</p>
      </div>
    )
  }

   
  const TypedList = List as any;
  return (
    <TypedList
      listRef={listRef}
      defaultHeight={height}
      rowCount={items.length}
      rowHeight={itemHeight}
      rowComponent={Row}
      rowProps={{}}
      overscanCount={overscanCount}
      className={className}
      style={{ width, maxHeight: height }}
    />
  )
}) as <T>(props: VirtualFixedListProps<T>) => React.ReactElement | null

/**
 * Lista virtualizada de tamano variable
 * Usar cuando los items tienen diferentes alturas
 * Note: react-window v2 uses dynamic row height via useDynamicRowHeight hook
 */
export const VirtualVariableList = memo(function VirtualVariableList<T>({
  items,
  getItemSize,
  estimatedItemSize = 150,
  height = 600,
  width = '100%',
  overscanCount = 5,
  renderItem,
  className = '',
  emptyMessage = 'No hay elementos',
  EmptyComponent = null
}: VirtualVariableListProps<T>): React.ReactElement | null {
  const listRef = useListRef(null)
  const sizeMap = useRef<Record<number, number>>({})

  // Funcion para obtener el tamano de un item
  const getSizeForIndex = useCallback((index: number): number => {
    if (sizeMap.current[index] !== undefined) {
      return sizeMap.current[index]
    }
    if (getItemSize) {
      const size = getItemSize(items[index], index)
      sizeMap.current[index] = size
      return size
    }
    return estimatedItemSize
  }, [items, getItemSize, estimatedItemSize])

  // Resetear cache cuando cambian los items
  useEffect(() => {
    sizeMap.current = {}
  }, [items])

  // Store items in window for row component access (react-window v2 pattern)
  useEffect(() => {
    window.__virtualVariableListItems = items as unknown[];
    window.__virtualVariableListRenderItem = renderItem as (item: unknown, index: number) => React.ReactNode;
    return () => {
      delete window.__virtualVariableListItems;
      delete window.__virtualVariableListRenderItem;
    }
  }, [items, renderItem])

  // Row component for react-window v2
  const Row = useCallback(({ index, style }: { index: number; style: CSSProperties }): React.ReactElement => {
    const currentItems = window.__virtualVariableListItems as T[];
    const currentRenderItem = window.__virtualVariableListRenderItem as (item: T, index: number) => React.ReactNode;
    const item = currentItems[index];
    return (
      <div style={style}>
        {currentRenderItem(item, index)}
      </div>
    )
  }, [])

  if (items.length === 0) {
    if (EmptyComponent) return <EmptyComponent />
    return (
      <div className="text-center py-12 text-gray-500">
        <p>{emptyMessage}</p>
      </div>
    )
  }

   
  const TypedList = List as any;
  return (
    <TypedList
      listRef={listRef}
      defaultHeight={height}
      rowCount={items.length}
      rowHeight={getSizeForIndex}
      rowComponent={Row}
      rowProps={{}}
      overscanCount={overscanCount}
      className={className}
      style={{ width, maxHeight: height }}
    />
  )
}) as <T>(props: VirtualVariableListProps<T>) => React.ReactElement | null

/**
 * Hook para auto-calcular altura del contenedor
 */
export function useContainerHeight(defaultHeight: number = 600): UseContainerHeightReturn {
  const containerRef = useRef<HTMLDivElement>(null)
  const [height, setHeight] = useState<number>(defaultHeight)

  useEffect(() => {
    const updateHeight = (): void => {
      if (containerRef.current) {
        const rect = containerRef.current.getBoundingClientRect()
        const windowHeight = window.innerHeight
        const availableHeight = windowHeight - rect.top - 100 // 100px para padding/footer
        setHeight(Math.max(300, availableHeight))
      }
    }

    updateHeight()
    window.addEventListener('resize', updateHeight)
    return () => window.removeEventListener('resize', updateHeight)
  }, [])

  return { containerRef, height }
}

export default VirtualFixedList
