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
  useActualizarCompraMutation,
  useAnularCompraMutation,
  useCambiarProveedorCompraMutation,
  useProductosQuery,
  useCrearProductoMutation,
  useCrearProveedorMutation,
  useNotasCreditoByCompraQuery,
  useNotasCreditoResumenQuery,
  useRegistrarNotaCreditoMutation,
  useActualizarProductoMutation,
} from '../../hooks/queries'
import type { ActualizarCompraItemsInput } from '../../hooks/queries'
import type { CambiarProveedorPayload } from '../modals/ModalCambiarProveedor'
import { useAuthData } from '../../contexts/AuthDataContext'
import { useNotification } from '../../contexts/NotificationContext'
import { useResetOnSucursalChange } from '../../hooks/useResetOnSucursalChange'
import type { CompraDBExtended, CompraFormInputExtended, ProveedorFormInputExtended, NotaCreditoFormInput } from '../../types'

// Lazy load de componentes
const VistaCompras = lazy(() => import('../vistas/VistaCompras'))
const ModalCompra = lazy(() => import('../modals/ModalCompra'))
const ModalDetalleCompra = lazy(() => import('../modals/ModalDetalleCompra'))
const ModalNotaCredito = lazy(() => import('../modals/ModalNotaCredito'))
const ModalEditarCompra = lazy(() => import('../modals/ModalEditarCompra'))
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
  const actualizarCompra = useActualizarCompraMutation()
  const anularCompra = useAnularCompraMutation()
  const crearProducto = useCrearProductoMutation()
  const actualizarProducto = useActualizarProductoMutation()
  const crearProveedor = useCrearProveedorMutation()
  const registrarNC = useRegistrarNotaCreditoMutation()
  const cambiarProveedorMut = useCambiarProveedorCompraMutation()

  // Estado de modales
  const [modalCompraOpen, setModalCompraOpen] = useState(false)
  const [modalDetalleOpen, setModalDetalleOpen] = useState(false)
  const [modalNotaCreditoOpen, setModalNotaCreditoOpen] = useState(false)
  const [modalEditarOpen, setModalEditarOpen] = useState(false)

  // Estado de detalle
  const [compraDetalle, setCompraDetalle] = useState<CompraDBExtended | null>(null)
  const [compraParaNC, setCompraParaNC] = useState<CompraDBExtended | null>(null)
  const [compraParaEditar, setCompraParaEditar] = useState<CompraDBExtended | null>(null)
  const [confirmConfig, setConfirmConfig] = useState<ConfirmConfig>({ visible: false })

  // Cerrar modales al cambiar de sucursal: las compras son por sucursal.
  useResetOnSucursalChange(() => {
    setModalCompraOpen(false)
    setModalDetalleOpen(false)
    setModalNotaCreditoOpen(false)
    setModalEditarOpen(false)
    setCompraDetalle(null)
    setCompraParaNC(null)
    setCompraParaEditar(null)
    setConfirmConfig({ visible: false })
  })

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

    // Propagar alícuotas de II editadas en la factura al maestro de productos
    // (la alícuota pudo cambiar; el costo de ESTA compra ya usó la de la línea).
    const cambios = data.cambiosImpuestosInternos ?? []
    if (cambios.length > 0) {
      const fallidos: string[] = []
      for (const c of cambios) {
        try {
          await actualizarProducto.mutateAsync({
            id: c.productoId,
            data: { impuestos_internos: c.impuestosInternos },
          })
        } catch {
          fallidos.push(c.nombre)
        }
      }
      const ok = cambios.length - fallidos.length
      if (ok > 0) notify.success(`Alícuota de imp. internos actualizada en ${ok} producto${ok === 1 ? '' : 's'}`)
      if (fallidos.length > 0) notify.error(`No se pudo actualizar la alícuota de: ${fallidos.join(', ')}`)
    }
  }, [registrarCompra, actualizarProducto, notify, user])

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

  const handleEditarCompra = useCallback((compra: CompraDBExtended) => {
    setCompraParaEditar(compra)
    setModalEditarOpen(true)
  }, [])

  const handleGuardarEdicionCompra = useCallback(async (input: ActualizarCompraItemsInput) => {
    try {
      await actualizarCompra.mutateAsync(input)
      notify.success('Compra actualizada')
      setModalEditarOpen(false)
      setCompraParaEditar(null)
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Error al actualizar compra'
      notify.error(msg)
      throw err
    }
  }, [actualizarCompra, notify])

  // Cambiar proveedor: anula la compra vieja y crea una nueva idéntica con el
  // proveedor correcto (RPC atómico, no mueve stock/costos). Ver mig 125.
  const handleCambiarProveedorCompra = useCallback(async (payload: CambiarProveedorPayload) => {
    if (!compraParaEditar) return
    try {
      const { nuevaCompraId } = await cambiarProveedorMut.mutateAsync({
        compraId: compraParaEditar.id,
        nuevoProveedorId: payload.nuevoProveedorId,
        nuevoProveedorNombre: payload.nuevoProveedorNombre,
        usuarioId: user?.id ?? null,
        motivo: payload.motivo,
      })
      notify.success(`Proveedor cambiado: se creó la compra #${nuevaCompraId} y se anuló la anterior`, { persist: true })
      setModalEditarOpen(false)
      setCompraParaEditar(null)
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Error al cambiar el proveedor'
      notify.error(msg)
      throw err
    }
  }, [cambiarProveedorMut, compraParaEditar, notify, user])

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
          onEditarCompra={handleEditarCompra}
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

      {/* Modal Editar Compra (admin, 7 dias) */}
      {modalEditarOpen && compraParaEditar && (
        <Suspense fallback={null}>
          <ModalEditarCompra
            compra={compraParaEditar}
            usuarioId={user?.id ?? null}
            onGuardar={handleGuardarEdicionCompra}
            onClose={() => {
              setModalEditarOpen(false)
              setCompraParaEditar(null)
            }}
            guardando={actualizarCompra.isPending}
            canCambiarProveedor={isAdmin}
            proveedores={proveedores}
            onCambiarProveedor={handleCambiarProveedorCompra}
            onCrearProveedor={handleCrearProveedorDesdeCompra}
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
