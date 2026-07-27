/**
 * MovimientosContainer — panel de movimientos entre sucursales (con aprobación).
 * Reemplaza el flujo viejo de transferencias (un solo lado, inmediato).
 */
import React, { lazy, Suspense, useState, useCallback } from 'react'
import { Loader2 } from 'lucide-react'
import {
  useMovimientosQuery,
  useMovimientoItemsQuery,
  useSucursalesQuery,
  useProductosQuery,
  useCrearMovimientoMutation,
  useAceptarMovimientoMutation,
  useDenegarMovimientoMutation,
  useCancelarMovimientoMutation,
  useEditarMovimientoMutation,
} from '../../hooks/queries'
import type { MovimientoSucursalDB, EstadoMovimiento, ResolucionItem } from '../../hooks/queries'
import { useAuthData } from '../../contexts/AuthDataContext'
import { useSucursal } from '../../contexts/SucursalContext'
import { useNotification } from '../../contexts/NotificationContext'
import { useResetOnSucursalChange } from '../../hooks/useResetOnSucursalChange'

const VistaMovimientos = lazy(() => import('../vistas/VistaMovimientos'))
const ModalCrearMovimiento = lazy(() => import('../modals/ModalCrearMovimiento'))
const ModalAceptarMovimiento = lazy(() => import('../modals/ModalAceptarMovimiento'))
const ModalDetalleMovimiento = lazy(() => import('../modals/ModalDetalleMovimiento'))
const ModalCancelarMovimiento = lazy(() => import('../modals/ModalCancelarMovimiento'))

type TabEstado = EstadoMovimiento | 'todos'

function LoadingState() {
  return <div className="flex items-center justify-center py-20"><Loader2 className="w-8 h-8 animate-spin text-blue-600" /></div>
}

export default function MovimientosContainer(): React.ReactElement {
  const { isAdminOrEncargado } = useAuthData()
  // El rol POR SUCURSAL, no el global: un admin global puede ser encargado acá.
  const { currentSucursalId, currentSucursalRol } = useSucursal()
  const notify = useNotification()

  const [estado, setEstado] = useState<TabEstado>('pendiente')
  const [crearOpen, setCrearOpen] = useState(false)
  const [aceptarMov, setAceptarMov] = useState<MovimientoSucursalDB | null>(null)
  const [aceptarModo, setAceptarModo] = useState<'aceptar' | 'denegar'>('aceptar')
  const [detalleMov, setDetalleMov] = useState<MovimientoSucursalDB | null>(null)
  const [editarMov, setEditarMov] = useState<MovimientoSucursalDB | null>(null)
  const [cancelarMov, setCancelarMov] = useState<MovimientoSucursalDB | null>(null)

  const { data: movimientos = [], isLoading } = useMovimientosQuery({ estado })
  const { data: sucursales = [] } = useSucursalesQuery()
  const { data: productos = [] } = useProductosQuery()
  const { data: itemsAceptar = [], isLoading: loadingItems } = useMovimientoItemsQuery(aceptarMov ? String(aceptarMov.id) : null)
  const { data: itemsDetalle = [], isLoading: loadingItemsDetalle } = useMovimientoItemsQuery(detalleMov ? String(detalleMov.id) : null)
  const { data: itemsEditar = [], isLoading: loadingItemsEditar } = useMovimientoItemsQuery(editarMov ? String(editarMov.id) : null)

  const crear = useCrearMovimientoMutation()
  const aceptar = useAceptarMovimientoMutation()
  const denegar = useDenegarMovimientoMutation()
  const cancelar = useCancelarMovimientoMutation()
  const editar = useEditarMovimientoMutation()
  const guardando = crear.isPending || aceptar.isPending || denegar.isPending
    || cancelar.isPending || editar.isPending

  useResetOnSucursalChange(() => {
    setCrearOpen(false)
    setAceptarMov(null)
    setDetalleMov(null)
    setEditarMov(null)
    setCancelarMov(null)
    setEstado('pendiente')
  })

  // Sucursales destino: las activas distintas de la actual.
  const sucursalesDestino = sucursales.filter(s => Number(s.id) !== currentSucursalId)

  const handleCrear = useCallback(async (payload: {
    sucursalDestinoId: number; notas?: string; items: Array<{ producto_id: number; cantidad: number }>
  }) => {
    await crear.mutateAsync(payload)
    setCrearOpen(false)
    notify.success('Salida creada. El stock ya se descontó de esta sucursal.')
  }, [crear, notify])

  const handleAceptar = useCallback(async (resoluciones: ResolucionItem[]) => {
    if (!aceptarMov) return
    await aceptar.mutateAsync({ movimientoId: aceptarMov.id, resoluciones })
    setAceptarMov(null)
    notify.success('Movimiento aceptado. Stock ingresado en esta sucursal.')
  }, [aceptar, aceptarMov, notify])

  const handleDenegar = useCallback(async (motivo: string) => {
    if (!aceptarMov) return
    await denegar.mutateAsync({ movimientoId: aceptarMov.id, motivo })
    setAceptarMov(null)
    notify.warning('Movimiento denegado. Se le devolvió el stock al origen.')
  }, [denegar, aceptarMov, notify])

  const handleEditar = useCallback(async (payload: {
    notas?: string; items: Array<{ producto_id: number; cantidad: number }>
  }) => {
    if (!editarMov) return
    await editar.mutateAsync({ movimientoId: editarMov.id, notas: payload.notas, items: payload.items })
    setEditarMov(null)
    notify.success('Envío actualizado. Se ajustó el stock de esta sucursal.')
  }, [editar, editarMov, notify])

  const handleCancelar = useCallback(async (motivo: string) => {
    if (!cancelarMov) return
    await cancelar.mutateAsync({ movimientoId: cancelarMov.id, motivo })
    setCancelarMov(null)
    notify.warning('Envío cancelado. El stock volvió a esta sucursal.')
  }, [cancelar, cancelarMov, notify])

  return (
    <>
      <Suspense fallback={<LoadingState />}>
        <VistaMovimientos
          movimientos={movimientos}
          loading={isLoading}
          currentSucursalId={currentSucursalId}
          canResolver={isAdminOrEncargado}
          canEditar={currentSucursalRol === 'admin'}
          estado={estado}
          onEstadoChange={setEstado}
          onNuevaSalida={() => setCrearOpen(true)}
          onAceptar={(m) => { setAceptarModo('aceptar'); setAceptarMov(m) }}
          onDenegar={(m) => { setAceptarModo('denegar'); setAceptarMov(m) }}
          onVerDetalle={setDetalleMov}
          onEditar={setEditarMov}
          onCancelar={setCancelarMov}
        />
      </Suspense>

      {crearOpen && (
        <Suspense fallback={null}>
          <ModalCrearMovimiento
            sucursales={sucursalesDestino}
            productos={productos}
            guardando={guardando}
            onClose={() => setCrearOpen(false)}
            onConfirmar={handleCrear}
          />
        </Suspense>
      )}

      {editarMov && (
        <Suspense fallback={null}>
          <ModalCrearMovimiento
            modo="editar"
            movimiento={editarMov}
            itemsIniciales={itemsEditar}
            loadingItems={loadingItemsEditar}
            sucursales={sucursales}
            productos={productos}
            guardando={guardando}
            onClose={() => setEditarMov(null)}
            onGuardarEdicion={handleEditar}
          />
        </Suspense>
      )}

      {cancelarMov && (
        <Suspense fallback={null}>
          <ModalCancelarMovimiento
            movimiento={cancelarMov}
            guardando={guardando}
            onConfirmar={handleCancelar}
            onClose={() => setCancelarMov(null)}
          />
        </Suspense>
      )}

      {aceptarMov && (
        <Suspense fallback={null}>
          <ModalAceptarMovimiento
            movimiento={aceptarMov}
            items={itemsAceptar}
            loadingItems={loadingItems}
            productosDestino={productos}
            guardando={guardando}
            modoDenegarInicial={aceptarModo === 'denegar'}
            onConfirmar={handleAceptar}
            onDenegar={handleDenegar}
            onClose={() => setAceptarMov(null)}
          />
        </Suspense>
      )}

      {detalleMov && (
        <Suspense fallback={null}>
          <ModalDetalleMovimiento
            movimiento={detalleMov}
            items={itemsDetalle}
            loadingItems={loadingItemsDetalle}
            productos={productos}
            onClose={() => setDetalleMov(null)}
          />
        </Suspense>
      )}
    </>
  )
}
