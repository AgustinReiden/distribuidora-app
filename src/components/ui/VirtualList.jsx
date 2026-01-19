/**
 * Componente de lista virtualizada genérico
 *
 * Usa react-window para renderizar eficientemente listas grandes.
 * Solo renderiza los elementos visibles en el viewport.
 *
 * Beneficios:
 * - Mejora el rendimiento con listas de 100+ elementos
 * - Reduce el uso de memoria
 * - Scroll suave incluso con miles de elementos
 */
import React, { memo, useCallback, useRef, useEffect } from 'react'
import { FixedSizeList, VariableSizeList } from 'react-window'

/**
 * Lista virtualizada de tamaño fijo
 * Usar cuando todos los items tienen la misma altura
 */
export const VirtualFixedList = memo(function VirtualFixedList({
  items,
  itemHeight,
  height = 600,
  width = '100%',
  overscanCount = 5,
  renderItem,
  className = '',
  emptyMessage = 'No hay elementos',
  EmptyComponent = null
}) {
  const listRef = useRef(null)

  // Resetear scroll cuando cambian los items
  useEffect(() => {
    if (listRef.current) {
      listRef.current.scrollToItem(0)
    }
  }, [items.length])

  if (items.length === 0) {
    if (EmptyComponent) return <EmptyComponent />
    return (
      <div className="text-center py-12 text-gray-500">
        <p>{emptyMessage}</p>
      </div>
    )
  }

  const Row = useCallback(({ index, style }) => {
    const item = items[index]
    return (
      <div style={style}>
        {renderItem(item, index)}
      </div>
    )
  }, [items, renderItem])

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
})

/**
 * Lista virtualizada de tamaño variable
 * Usar cuando los items tienen diferentes alturas
 */
export const VirtualVariableList = memo(function VirtualVariableList({
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
}) {
  const listRef = useRef(null)
  const sizeMap = useRef({})

  // Función para obtener el tamaño de un item
  const getSizeForIndex = useCallback((index) => {
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

  if (items.length === 0) {
    if (EmptyComponent) return <EmptyComponent />
    return (
      <div className="text-center py-12 text-gray-500">
        <p>{emptyMessage}</p>
      </div>
    )
  }

  const Row = useCallback(({ index, style }) => {
    const item = items[index]
    return (
      <div style={style}>
        {renderItem(item, index)}
      </div>
    )
  }, [items, renderItem])

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
})

/**
 * Hook para auto-calcular altura del contenedor
 */
export function useContainerHeight(defaultHeight = 600) {
  const containerRef = useRef(null)
  const [height, setHeight] = React.useState(defaultHeight)

  useEffect(() => {
    const updateHeight = () => {
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
