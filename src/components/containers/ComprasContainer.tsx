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
  useCrearProveedorMutation,
  useNotasCreditoByCompraQuery,
  useNotasCreditoResumenQuery,
  useRegistrarNotaCreditoMutation,
} from '../../hooks/queries'
import { useAuthData } from '../../contexts/AuthDataContext'
import { useNotification } from '../../contexts/NotificationContext'
import type { CompraDBExtended, CompraFormInputExtended, ProveedorFormInputExtended, NotaCreditoFormInput } from '../../types'

// Lazy load de componentes
const VistaCompras = lazy(() => import('../vistas/VistaCompras'))
const ModalCompra = lazy(() => import('../modals/ModalCompra'))
const ModalDetalleCompra = lazy(() => import('../modals/ModalDetalleCompra'))
const ModalNotaCredito = lazy(() => import('../modals/ModalNotaCredito'))
const ModalConfirmacion = lazy(() => import('../modals/ModalConfirmacion'))

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
  const crearProducto = useCrearProductoMutation()
  const crearProveedor = useCrearProveedorMutation()
  const registrarNC = useRegistrarNotaCreditoMutation()

  // Estado de modales
  const [modalCompraOpen, setModalCompraOpen] = useState(false)
  const [modalDetalleOpen, setModalDetalleOpen] = useState(false)
  const [modalNotaCreditoOpen, setModalNotaCreditoOpen] = useState(false)

  // Estado de detalle
  const [compraDetalle, setCompraDetalle] = useState<CompraDBExtended | null>(null)
  const [compraParaNC, setCompraParaNC] = useState<CompraDBExtended | null>(null)
  const [confirmConfig, setConfirmConfig] = useState<ConfirmConfig>({ visible: false })

  // NC resumen for badges in list
  const { data: ncResumen = [] } = useNotasCreditoResumenQuery()

  // Query notas de credito for selected compra (detail or NC modal)
  const compraConNCId = compraParaNC?.id || compraDetalle?.id
  const notasCreditoQuery = useNotasCreditoByCompraQuery(compraConNCId, !!compraConNCId)

  // Handlers
  const handleNuevaCompra = useCallback(() => {
    setModalCompraOpen(true)
  }, [])

  const handleVerDetalle = useCallback((compra: CompraDBExtended) => {
    setCompraDetalle(compra)
    setModalDetalleOpen(true)
  }, [])

  const handleAnularCompra = useCallback((compraId: string) => {
    setConfirmConfig({
      visible: true, tipo: 'danger', titulo: 'Anular compra',
      mensaje: '¿Anular esta compra? Se revertirá el stock de los productos.',
      onConfirm: async () => {
        setConfirmConfig({ visible: false })
        try {
          await anularCompra.mutateAsync(compraId)
          notify.success('Compra anulada')
        } catch {
          notify.error('Error al anular compra')
        }
      },
    })
  }, [anularCompra, notify])

  const handleGuardarCompra = useCallback(async (data: CompraFormInputExtended) => {
    try {
      await registrarCompra.mutateAsync({ ...data, usuarioId: user?.id ?? null })
      notify.success('Compra registrada')
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Error al registrar compra'
      notify.error(msg)
      throw err
    }
  }, [registrarCompra, notify, user])

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

  const handleNotaCredito = useCallback((compra: CompraDBExtended) => {
    setCompraParaNC(compra)
    setModalNotaCreditoOpen(true)
  }, [])

  const handleGuardarNC = useCallback(async (data: NotaCreditoFormInput) => {
    try {
      await registrarNC.mutateAsync(data)
      notify.success('Nota de credito registrada')
      setModalNotaCreditoOpen(false)
      setCompraParaNC(null)
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Error al registrar nota de credito'
      notify.error(msg)
      throw err
    }
  }, [registrarNC, notify])

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
          onNotaCredito={handleNotaCredito}
          ncResumen={ncResumen}
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
            onAnular={handleAnularCompra}
            onNotaCredito={(c) => handleNotaCredito(c as CompraDBExtended)}
            notasCredito={notasCreditoQuery.data as any}
          />
        </Suspense>
      )}

      {/* Modal Nota de Credito */}
      {modalNotaCreditoOpen && compraParaNC && (
        <Suspense fallback={null}>
          <ModalNotaCredito
            compra={compraParaNC as Parameters<typeof ModalNotaCredito>[0]['compra']}
            notasExistentes={notasCreditoQuery.data || []}
            onSave={handleGuardarNC}
            onClose={() => {
              setModalNotaCreditoOpen(false)
              setCompraParaNC(null)
            }}
          />
        </Suspense>
      )}

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
