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
  useEliminarProductoMutation,
} from '../../hooks/queries'
import { useMermasQuery, useRegistrarMermaMutation } from '../../hooks/queries'
import { useProveedoresActivosQuery } from '../../hooks/queries'
import { useClientesQuery } from '../../hooks/queries'
import { useRegistrarCambioProductoMutation, type RegistrarCambioInput } from '../../hooks/queries'
import { useCategoriasQuery } from '../../hooks/queries'
import { useAuthData } from '../../contexts/AuthDataContext'
import { useNotification } from '../../contexts/NotificationContext'
import { puedeControlarStock as puedeControlarStockRol } from '../../lib/permisos'
import { useResetOnSucursalChange } from '../../hooks/useResetOnSucursalChange'
import { formatPrecio } from '../../utils/formatters'
import type { ProductoDB, ProductoFormInput, MermaFormInputExtended } from '../../types'

// Lazy load de componentes
const VistaProductos = lazy(() => import('../vistas/VistaProductos'))
const ModalProducto = lazy(() => import('../modals/ModalProducto'))
const ModalMermaStock = lazy(() => import('../modals/ModalMermaStock'))
const ModalHistorialMermas = lazy(() => import('../modals/ModalHistorialMermas'))
const ModalActualizacionMasivaPrecios = lazy(() => import('../modals/ModalActualizacionMasivaPrecios'))
const ModalConfirmacion = lazy(() => import('../modals/ModalConfirmacion'))
const ModalCategorias = lazy(() => import('../modals/ModalCategorias'))
const ModalCambioProducto = lazy(() => import('../modals/ModalCambioProducto'))
const ModalStockBajo = lazy(() => import('../modals/ModalStockBajo'))

function LoadingState() {
  return (
    <div className="flex items-center justify-center py-20">
      <Loader2 className="w-8 h-8 animate-spin text-blue-600" />
    </div>
  )
}

interface ConfirmConfig {
  visible: boolean
  tipo?: 'danger' | 'warning' | 'success'
  titulo?: string
  mensaje?: string
  onConfirm?: () => void
}

export default function ProductosContainer(): React.ReactElement {
  const { isAdmin, perfil } = useAuthData()
  const puedeCambiarProductos = isAdmin
  // Stock bajo + control de stock (Excel): admin y encargado.
  const puedeControlarStock = puedeControlarStockRol(perfil?.rol)
  const notify = useNotification()

  // Queries
  const { data: productos = [], isLoading } = useProductosQuery()
  const { data: mermas = [] } = useMermasQuery()
  const { data: proveedores = [] } = useProveedoresActivosQuery()
  const { data: clientes = [] } = useClientesQuery()
  const { data: categoriasTabla = [] } = useCategoriasQuery()

  // Mutations
  const crearProducto = useCrearProductoMutation()
  const actualizarProducto = useActualizarProductoMutation()
  const eliminarProducto = useEliminarProductoMutation()
  const registrarMerma = useRegistrarMermaMutation()
  const registrarCambioProducto = useRegistrarCambioProductoMutation()

  // Estado de modales
  const [modalProductoOpen, setModalProductoOpen] = useState(false)
  const [modalMermaOpen, setModalMermaOpen] = useState(false)
  const [modalHistorialOpen, setModalHistorialOpen] = useState(false)
  const [modalActualizacionMasivaOpen, setModalActualizacionMasivaOpen] = useState(false)
  const [modalCategoriasOpen, setModalCategoriasOpen] = useState(false)
  const [modalCambioOpen, setModalCambioOpen] = useState(false)
  const [modalStockBajoOpen, setModalStockBajoOpen] = useState(false)

  // Estado de edición
  const [productoEditando, setProductoEditando] = useState<ProductoDB | null>(null)
  const [productoMerma, setProductoMerma] = useState<ProductoDB | null>(null)

  // Confirm modal state
  const [confirmConfig, setConfirmConfig] = useState<ConfirmConfig>({ visible: false })

  // Cerrar modales al cambiar de sucursal: los productos viven por sucursal,
  // dejar un modal abierto con un producto de otra sucursal seria misleading.
  useResetOnSucursalChange(() => {
    setModalProductoOpen(false)
    setModalMermaOpen(false)
    setModalHistorialOpen(false)
    setModalActualizacionMasivaOpen(false)
    setModalCategoriasOpen(false)
    setModalCambioOpen(false)
    setModalStockBajoOpen(false)
    setProductoEditando(null)
    setProductoMerma(null)
    setConfirmConfig({ visible: false })
  })

  // Categorías para el selector del modal: une la tabla `categorias` (solo
  // activas) con las categorías derivadas de productos (strings heredados que
  // todavía no se migraron a la tabla). Sin esto, una categoría recién creada
  // no aparece hasta que se le asigna a algún producto.
  const categorias = useMemo(() => {
    const set = new Set<string>()
    categoriasTabla.forEach(c => {
      if (c.activa !== false) set.add(c.nombre)
    })
    productos.forEach(p => {
      if (p.categoria) set.add(p.categoria)
    })
    return Array.from(set).sort((a, b) => a.localeCompare(b))
  }, [categoriasTabla, productos])

  // Handlers
  const handleNuevoProducto = useCallback(() => {
    setProductoEditando(null)
    setModalProductoOpen(true)
  }, [])

  const handleEditarProducto = useCallback((producto: ProductoDB) => {
    setProductoEditando(producto)
    setModalProductoOpen(true)
  }, [])

  const handleEliminarProducto = useCallback((productoId: string) => {
    const producto = productos.find(p => p.id === productoId)
    if (!producto) return
    setConfirmConfig({
      visible: true, tipo: 'danger', titulo: 'Eliminar producto',
      mensaje: `¿Eliminar "${producto.nombre}"?`,
      onConfirm: async () => {
        setConfirmConfig({ visible: false })
        try {
          await eliminarProducto.mutateAsync(productoId)
          notify.success('Producto eliminado')
        } catch {
          notify.error('Error al eliminar producto')
        }
      },
    })
  }, [productos, eliminarProducto, notify])

  const handleBajaStock = useCallback((producto: ProductoDB) => {
    setProductoMerma(producto)
    setModalMermaOpen(true)
  }, [])

  const handleVerHistorialMermas = useCallback(() => {
    setModalHistorialOpen(true)
  }, [])

  const handleAbrirActualizacionMasiva = useCallback(() => {
    setModalActualizacionMasivaOpen(true)
  }, [])

  const handleGestionarCategorias = useCallback(() => {
    setModalCategoriasOpen(true)
  }, [])

  const handleAbrirCambioProducto = useCallback(() => {
    setModalCambioOpen(true)
  }, [])

  const handleAbrirStockBajo = useCallback(() => {
    setModalStockBajoOpen(true)
  }, [])

  // Control de stock: descarga Excel con el inventario actual.
  // Antes vivía inline en VistaProductos; movido al container para que la
  // toolbar pueda recibirlo como handler simple.
  const handleControlStock = useCallback(async () => {
    try {
      const { exportControlStock } = await import('../../utils/excel')
      await exportControlStock(productos)
    } catch {
      notify.error('Error al exportar el control de stock')
    }
  }, [productos, notify])

  // Productos con stock bajo: una sola fuente de verdad. El toolbar usa
  // el count y el modal usa la lista. La fórmula respeta exactamente la
  // que estaba en VistaProductos: stock < (stock_minimo || 10).
  const productosStockBajo = useMemo(() => {
    return productos.filter(p => p.stock < (p.stock_minimo || 10))
  }, [productos])

  // Handler de "Editar" desde el modal de stock bajo: cierra el modal
  // y abre el modal de edición del producto.
  const handleEditarDesdeStockBajo = useCallback((producto: ProductoDB) => {
    setModalStockBajoOpen(false)
    setProductoEditando(producto)
    setModalProductoOpen(true)
  }, [])

  const handleGuardarCambioProducto = useCallback(async (data: RegistrarCambioInput) => {
    try {
      await registrarCambioProducto.mutateAsync(data)
      const productoDevuelto = productos.find(p => p.id === data.productoDevueltoId)
      const productoEntregado = productos.find(p => p.id === data.productoEntregadoId)
      const diferencia = (productoEntregado?.precio || 0) * data.cantidadEntregada
                       - (productoDevuelto?.precio || 0) * data.cantidadDevuelta
      const detalle = diferencia === 0
        ? 'sin diferencia de precio'
        : diferencia > 0
        ? `el cliente debe ${formatPrecio(diferencia)}`
        : `saldo a favor del cliente por ${formatPrecio(Math.abs(diferencia))}`
      notify.success(`Cambio registrado · ${detalle}`)
      setModalCambioOpen(false)
    } catch (err) {
      const mensaje = err instanceof Error ? err.message : 'Error al registrar el cambio'
      notify.error(mensaje)
      throw err
    }
  }, [registrarCambioProducto, productos, notify])

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

  return (
    <>
      <Suspense fallback={<LoadingState />}>
        <VistaProductos
          productos={productos}
          productosStockBajo={productosStockBajo}
          proveedores={proveedores}
          loading={isLoading}
          isAdmin={isAdmin}
          puedeControlarStock={puedeControlarStock}
          onNuevoProducto={handleNuevoProducto}
          onEditarProducto={handleEditarProducto}
          onEliminarProducto={handleEliminarProducto}
          onBajaStock={handleBajaStock}
          onVerHistorialMermas={handleVerHistorialMermas}
          onActualizacionMasivaPrecios={handleAbrirActualizacionMasiva}
          onGestionarCategorias={handleGestionarCategorias}
          onCambioProducto={puedeCambiarProductos ? handleAbrirCambioProducto : undefined}
          onControlStock={puedeControlarStock ? handleControlStock : undefined}
          onAbrirStockBajo={puedeControlarStock ? handleAbrirStockBajo : undefined}
        />
      </Suspense>

      {/* Modal Producto */}
      {modalProductoOpen && (
        <Suspense fallback={null}>
          <ModalProducto
            producto={productoEditando}
            categorias={categorias}
            proveedores={proveedores}
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
            producto={productoMerma as unknown as Parameters<typeof ModalMermaStock>[0]['producto']}
            onSave={handleGuardarMerma as unknown as Parameters<typeof ModalMermaStock>[0]['onSave']}
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
            productos={productos as unknown as Parameters<typeof ModalHistorialMermas>[0]['productos']}
            onClose={() => setModalHistorialOpen(false)}
          />
        </Suspense>
      )}

      {/* Modal Actualización masiva de precios */}
      {modalActualizacionMasivaOpen && (
        <Suspense fallback={null}>
          <ModalActualizacionMasivaPrecios
            productos={productos}
            proveedores={proveedores}
            categorias={categorias}
            onClose={() => setModalActualizacionMasivaOpen(false)}
          />
        </Suspense>
      )}

      {/* Modal Categorías */}
      {modalCategoriasOpen && (
        <Suspense fallback={null}>
          <ModalCategorias
            productos={productos}
            onClose={() => setModalCategoriasOpen(false)}
          />
        </Suspense>
      )}

      {/* Modal Cambio de productos */}
      {modalCambioOpen && (
        <Suspense fallback={null}>
          <ModalCambioProducto
            clientes={clientes}
            productos={productos}
            onSave={handleGuardarCambioProducto}
            onClose={() => setModalCambioOpen(false)}
          />
        </Suspense>
      )}

      {/* Modal Stock bajo */}
      {modalStockBajoOpen && (
        <Suspense fallback={null}>
          <ModalStockBajo
            productos={productosStockBajo}
            onEditarProducto={isAdmin ? handleEditarDesdeStockBajo : undefined}
            onClose={() => setModalStockBajoOpen(false)}
          />
        </Suspense>
      )}

      {/* Modal Confirmación */}
      {confirmConfig.visible && (
        <Suspense fallback={null}>
          <ModalConfirmacion
            config={{
              visible: true,
              tipo: confirmConfig.tipo || 'warning',
              titulo: confirmConfig.titulo || '',
              mensaje: confirmConfig.mensaje || '',
              onConfirm: confirmConfig.onConfirm || (() => {}),
            }}
            onClose={() => setConfirmConfig({ visible: false })}
          />
        </Suspense>
      )}
    </>
  )
}
