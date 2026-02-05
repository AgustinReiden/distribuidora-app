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
  useAnularCompraMutation
} from '../../hooks/queries'
import { useProductosQuery } from '../../hooks/queries'
import { useAuthData } from '../../contexts/AuthDataContext'
import { useNotification } from '../../contexts/NotificationContext'
import type { CompraDBExtended, CompraFormInputExtended } from '../../types'

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
  const { isAdmin, user } = useAuthData()
  const notify = useNotification()

  // Queries
  const { data: compras = [], isLoading } = useComprasQuery()
  const { data: proveedores = [] } = useProveedoresQuery()
  const { data: productos = [] } = useProductosQuery()

  // Mutations
  const registrarCompra = useRegistrarCompraMutation()
  const anularCompra = useAnularCompraMutation()

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
      setModalCompraOpen(false)
      return { success: true }
    } catch {
      notify.error('Error al registrar compra')
      return { success: false, error: 'Error al registrar compra' }
    }
  }, [registrarCompra, notify])

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
            proveedores={proveedores as unknown as Parameters<typeof ModalCompra>[0]['proveedores']}
            onSave={handleGuardarCompra as unknown as Parameters<typeof ModalCompra>[0]['onSave']}
            onClose={() => setModalCompraOpen(false)}
          />
        </Suspense>
      )}

      {/* Modal Detalle Compra */}
      {modalDetalleOpen && compraDetalle && (
        <Suspense fallback={null}>
          <ModalDetalleCompra
            compra={compraDetalle as unknown as Parameters<typeof ModalDetalleCompra>[0]['compra']}
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
