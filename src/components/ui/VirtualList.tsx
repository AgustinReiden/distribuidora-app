/* eslint-disable react-refresh/only-export-components */
/**
 * Componente de lista virtualizada generico
 *
 * Usa react-window para renderizar eficientemente listas grandes.
 * Solo renderiza los elementos visibles en el viewport.
 *
 * Beneficios:
 * - Mejora el rendimiento con listas de 100+ elementos
 * - Reduce el uso de memoria
 * - Scroll suave incluso con miles de elementos
 */
import React, { memo, useCallback, useRef, useEffect, useState, CSSProperties, ComponentType, RefObject } from 'react'
import { FixedSizeList, VariableSizeList, ListChildComponentProps } from 'react-window'

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
  containerRef: RefObject<HTMLDivElement>;
  height: number;
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
  const listRef = useRef<FixedSizeList<T[]> | null>(null)

  // Resetear scroll cuando cambian los items
  useEffect(() => {
    if (listRef.current) {
      listRef.current.scrollToItem(0)
    }
  }, [items.length])

  // useCallback debe estar antes de cualquier return condicional
  const Row = useCallback(({ index, style }: ListChildComponentProps<T[]>): React.ReactElement => {
    const item = items[index]
    return (
      <div style={style}>
        {renderItem(item, index)}
      </div>
    )
  }, [items, renderItem])

  if (items.length === 0) {
    if (EmptyComponent) return <EmptyComponent />
    return (
      <div className="text-center py-12 text-gray-500">
        <p>{emptyMessage}</p>
      </div>
    )
  }

  return (
    <FixedSizeList
      ref={listRef}
      height={height}
      width={width}
      itemCount={items.length}
      itemSize={itemHeight}
      overscanCount={overscanCount}
      className={className}
    >
      {Row}
    </FixedSizeList>
  )
}) as <T>(props: VirtualFixedListProps<T>) => React.ReactElement | null

/**
 * Lista virtualizada de tamano variable
 * Usar cuando los items tienen diferentes alturas
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
  const listRef = useRef<VariableSizeList<T[]> | null>(null)
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
    if (listRef.current) {
      listRef.current.resetAfterIndex(0)
      listRef.current.scrollToItem(0)
    }
  }, [items])

  // useCallback debe estar antes de cualquier return condicional
  const Row = useCallback(({ index, style }: ListChildComponentProps<T[]>): React.ReactElement => {
    const item = items[index]
    return (
      <div style={style}>
        {renderItem(item, index)}
      </div>
    )
  }, [items, renderItem])

  if (items.length === 0) {
    if (EmptyComponent) return <EmptyComponent />
    return (
      <div className="text-center py-12 text-gray-500">
        <p>{emptyMessage}</p>
      </div>
    )
  }

  return (
    <VariableSizeList
      ref={listRef}
      height={height}
      width={width}
      itemCount={items.length}
      itemSize={getSizeForIndex}
      estimatedItemSize={estimatedItemSize}
      overscanCount={overscanCount}
      className={className}
    >
      {Row}
    </VariableSizeList>
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
