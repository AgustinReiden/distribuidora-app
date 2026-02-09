/**
 * ProductosContainer
 *
 * Container que carga productos bajo demanda usando TanStack Query.
 * Maneja estado de modales y operaciones CRUD.
 */
import React, { lazy, Suspense, useState, useCallback, useMemo } from 'react'
import { Loader2 } from 'lucide-react'
import {
  useProductosQuery,
  useCrearProductoMutation,
  useActualizarProductoMutation,
  useEliminarProductoMutation
} from '../../hooks/queries'
import { useMermasQuery, useRegistrarMermaMutation } from '../../hooks/queries'
import { useAuthData } from '../../contexts/AuthDataContext'
import { useNotification } from '../../contexts/NotificationContext'
import type { ProductoDB, ProductoFormInput, MermaFormInputExtended } from '../../types'

// Lazy load de componentes
const VistaProductos = lazy(() => import('../vistas/VistaProductos'))
const ModalProducto = lazy(() => import('../modals/ModalProducto'))
const ModalMermaStock = lazy(() => import('../modals/ModalMermaStock'))
const ModalHistorialMermas = lazy(() => import('../modals/ModalHistorialMermas'))
const ModalImportarPrecios = lazy(() => import('../modals/ModalImportarPrecios'))

function LoadingState() {
  return (
    <div className="flex items-center justify-center py-20">
      <Loader2 className="w-8 h-8 animate-spin text-blue-600" />
    </div>
  )
}

export default function ProductosContainer(): React.ReactElement {
  const { isAdmin } = useAuthData()
  const notify = useNotification()

  // Queries
  const { data: productos = [], isLoading } = useProductosQuery()
  const { data: mermas = [] } = useMermasQuery()

  // Mutations
  const crearProducto = useCrearProductoMutation()
  const actualizarProducto = useActualizarProductoMutation()
  const eliminarProducto = useEliminarProductoMutation()
  const registrarMerma = useRegistrarMermaMutation()

  // Estado de modales
  const [modalProductoOpen, setModalProductoOpen] = useState(false)
  const [modalMermaOpen, setModalMermaOpen] = useState(false)
  const [modalHistorialOpen, setModalHistorialOpen] = useState(false)
  const [modalImportarOpen, setModalImportarOpen] = useState(false)

  // Estado de edición
  const [productoEditando, setProductoEditando] = useState<ProductoDB | null>(null)
  const [productoMerma, setProductoMerma] = useState<ProductoDB | null>(null)

  // Categorías derivadas
  const categorias = useMemo(() => {
    const cats = new Set<string>()
    productos.forEach(p => {
      if (p.categoria) cats.add(p.categoria)
    })
    return Array.from(cats).sort()
  }, [productos])

  // Handlers
  const handleNuevoProducto = useCallback(() => {
    setProductoEditando(null)
    setModalProductoOpen(true)
  }, [])

  const handleEditarProducto = useCallback((producto: ProductoDB) => {
    setProductoEditando(producto)
    setModalProductoOpen(true)
  }, [])

  const handleEliminarProducto = useCallback(async (productoId: string) => {
    const producto = productos.find(p => p.id === productoId)
    if (!producto) return
    if (!window.confirm(`¿Eliminar "${producto.nombre}"?`)) return
    try {
      await eliminarProducto.mutateAsync(productoId)
      notify.success('Producto eliminado')
    } catch {
      notify.error('Error al eliminar producto')
    }
  }, [productos, eliminarProducto, notify])

  const handleBajaStock = useCallback((producto: ProductoDB) => {
    setProductoMerma(producto)
    setModalMermaOpen(true)
  }, [])

  const handleVerHistorialMermas = useCallback(() => {
    setModalHistorialOpen(true)
  }, [])

  const handleImportarPrecios = useCallback(() => {
    setModalImportarOpen(true)
  }, [])

  const handleGuardarProducto = useCallback(async (data: ProductoFormInput) => {
    try {
      if (productoEditando) {
        await actualizarProducto.mutateAsync({ id: productoEditando.id, data })
        notify.success('Producto actualizado')
      } else {
        await crearProducto.mutateAsync(data)
        notify.success('Producto creado')
      }
      setModalProductoOpen(false)
      setProductoEditando(null)
    } catch (error) {
      notify.error('Error al guardar producto')
      throw error
    }
  }, [productoEditando, actualizarProducto, crearProducto, notify])

  const handleGuardarMerma = useCallback(async (data: MermaFormInputExtended) => {
    try {
      await registrarMerma.mutateAsync(data)
      notify.success('Merma registrada')
      setModalMermaOpen(false)
      setProductoMerma(null)
      return { success: true }
    } catch {
      notify.error('Error al registrar merma')
      return { success: false, error: 'Error al registrar merma' }
    }
  }, [registrarMerma, notify])

  const handleActualizarPreciosMasivo = useCallback(async (items: Array<{ productoId: string | null; precioFinal: number }>) => {
    try {
      const updates = items
        .filter(item => item.productoId)
        .map(item => actualizarProducto.mutateAsync({
          id: item.productoId!,
          data: { precio: item.precioFinal } as ProductoFormInput
        }))
      await Promise.all(updates)
      return { success: true, actualizados: items.length }
    } catch {
      return { success: false, error: 'Error al actualizar precios' }
    }
  }, [actualizarProducto])

  return (
    <>
      <Suspense fallback={<LoadingState />}>
        <VistaProductos
          productos={productos}
          loading={isLoading}
          isAdmin={isAdmin}
          onNuevoProducto={handleNuevoProducto}
          onEditarProducto={handleEditarProducto}
          onEliminarProducto={handleEliminarProducto}
          onBajaStock={handleBajaStock}
          onVerHistorialMermas={handleVerHistorialMermas}
          onImportarPrecios={handleImportarPrecios}
        />
      </Suspense>

      {/* Modal Producto */}
      {modalProductoOpen && (
        <Suspense fallback={null}>
          <ModalProducto
            producto={productoEditando}
            categorias={categorias}
            onSave={handleGuardarProducto as Parameters<typeof ModalProducto>[0]['onSave']}
            onClose={() => {
              setModalProductoOpen(false)
              setProductoEditando(null)
            }}
            guardando={crearProducto.isPending || actualizarProducto.isPending}
          />
        </Suspense>
      )}

      {/* Modal Merma */}
      {modalMermaOpen && productoMerma && (
        <Suspense fallback={null}>
          <ModalMermaStock
            producto={productoMerma as Parameters<typeof ModalMermaStock>[0]['producto']}
            onSave={handleGuardarMerma as Parameters<typeof ModalMermaStock>[0]['onSave']}
            onClose={() => {
              setModalMermaOpen(false)
              setProductoMerma(null)
            }}
          />
        </Suspense>
      )}

      {/* Modal Historial Mermas */}
      {modalHistorialOpen && (
        <Suspense fallback={null}>
          <ModalHistorialMermas
            mermas={mermas as Parameters<typeof ModalHistorialMermas>[0]['mermas']}
            productos={productos as Parameters<typeof ModalHistorialMermas>[0]['productos']}
            onClose={() => setModalHistorialOpen(false)}
          />
        </Suspense>
      )}

      {/* Modal Importar Precios */}
      {modalImportarOpen && (
        <Suspense fallback={null}>
          <ModalImportarPrecios
            productos={productos}
            onActualizarPrecios={handleActualizarPreciosMasivo}
            onClose={() => setModalImportarOpen(false)}
          />
        </Suspense>
      )}
    </>
  )
}
