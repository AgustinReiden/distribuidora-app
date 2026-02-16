/**
 * ComprasContainer
 *
 * Container que carga compras y proveedores bajo demanda usando TanStack Query.
 */
import React, { lazy, Suspense, useState, useCallback } from 'react'
import { Loader2 } from 'lucide-react'
import {
  useComprasQuery,
  useProveedoresQuery,
  useRegistrarCompraMutation,
  useAnularCompraMutation,
  useProductosQuery,
  useCrearProductoMutation,
  useCrearProveedorMutation
} from '../../hooks/queries'
import { useAuthData } from '../../contexts/AuthDataContext'
import { useNotification } from '../../contexts/NotificationContext'
import type { CompraDBExtended, CompraFormInputExtended, ProveedorFormInputExtended } from '../../types'

// Lazy load de componentes
const VistaCompras = lazy(() => import('../vistas/VistaCompras'))
const ModalCompra = lazy(() => import('../modals/ModalCompra'))
const ModalDetalleCompra = lazy(() => import('../modals/ModalDetalleCompra'))

function LoadingState() {
  return (
    <div className="flex items-center justify-center py-20">
      <Loader2 className="w-8 h-8 animate-spin text-blue-600" />
    </div>
  )
}

export default function ComprasContainer(): React.ReactElement {
  const { isAdmin } = useAuthData()
  const notify = useNotification()

  // Queries
  const { data: compras = [], isLoading } = useComprasQuery()
  const { data: proveedores = [] } = useProveedoresQuery()
  const { data: productos = [] } = useProductosQuery()

  // Mutations
  const registrarCompra = useRegistrarCompraMutation()
  const anularCompra = useAnularCompraMutation()
  const crearProducto = useCrearProductoMutation()
  const crearProveedor = useCrearProveedorMutation()

  // Estado de modales
  const [modalCompraOpen, setModalCompraOpen] = useState(false)
  const [modalDetalleOpen, setModalDetalleOpen] = useState(false)

  // Estado de detalle
  const [compraDetalle, setCompraDetalle] = useState<CompraDBExtended | null>(null)

  // Handlers
  const handleNuevaCompra = useCallback(() => {
    setModalCompraOpen(true)
  }, [])

  const handleVerDetalle = useCallback((compra: CompraDBExtended) => {
    setCompraDetalle(compra)
    setModalDetalleOpen(true)
  }, [])

  const handleAnularCompra = useCallback(async (compraId: string) => {
    if (!window.confirm('¿Anular esta compra? Se revertirá el stock de los productos.')) return
    try {
      await anularCompra.mutateAsync(compraId)
      notify.success('Compra anulada')
    } catch {
      notify.error('Error al anular compra')
    }
  }, [anularCompra, notify])

  const handleGuardarCompra = useCallback(async (data: CompraFormInputExtended) => {
    try {
      await registrarCompra.mutateAsync(data)
      notify.success('Compra registrada')
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Error al registrar compra'
      notify.error(msg)
      throw err
    }
  }, [registrarCompra, notify])

  const handleCrearProductoRapido = useCallback(async (data: { nombre: string; codigo: string; costoSinIva: number }) => {
    const producto = await crearProducto.mutateAsync({
      nombre: data.nombre,
      codigo: data.codigo || undefined,
      precio: data.costoSinIva * 1.21,
      stock: 0,
      costo_sin_iva: data.costoSinIva
    })
    notify.success(`Producto "${data.nombre}" creado`)
    return producto
  }, [crearProducto, notify])

  const handleCrearProveedorDesdeCompra = useCallback(async (data: ProveedorFormInputExtended) => {
    const proveedor = await crearProveedor.mutateAsync(data)
    notify.success(`Proveedor "${data.nombre}" creado`)
    return proveedor
  }, [crearProveedor, notify])

  return (
    <>
      <Suspense fallback={<LoadingState />}>
        <VistaCompras
          compras={compras as any}
          proveedores={proveedores as any}
          loading={isLoading}
          isAdmin={isAdmin}
          onNuevaCompra={handleNuevaCompra}
          onVerDetalle={handleVerDetalle}
          onAnularCompra={handleAnularCompra}
        />
      </Suspense>

      {/* Modal Nueva Compra */}
      {modalCompraOpen && (
        <Suspense fallback={null}>
          <ModalCompra
            productos={productos}
            proveedores={proveedores as Parameters<typeof ModalCompra>[0]['proveedores']}
            onSave={handleGuardarCompra as unknown as Parameters<typeof ModalCompra>[0]['onSave']}
            onClose={() => setModalCompraOpen(false)}
            onCrearProductoRapido={handleCrearProductoRapido}
            onCrearProveedor={handleCrearProveedorDesdeCompra as unknown as Parameters<typeof ModalCompra>[0]['onCrearProveedor']}
          />
        </Suspense>
      )}

      {/* Modal Detalle Compra */}
      {modalDetalleOpen && compraDetalle && (
        <Suspense fallback={null}>
          <ModalDetalleCompra
            compra={compraDetalle as Parameters<typeof ModalDetalleCompra>[0]['compra']}
            onClose={() => {
              setModalDetalleOpen(false)
              setCompraDetalle(null)
            }}
          />
        </Suspense>
      )}
    </>
  )
}
