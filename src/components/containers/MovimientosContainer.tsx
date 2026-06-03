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
} from '../../hooks/queries'
import type { MovimientoSucursalDB, EstadoMovimiento, ResolucionItem } from '../../hooks/queries'
import { useAuthData } from '../../contexts/AuthDataContext'
import { useSucursal } from '../../contexts/SucursalContext'
import { useNotification } from '../../contexts/NotificationContext'
import { useResetOnSucursalChange } from '../../hooks/useResetOnSucursalChange'

const VistaMovimientos = lazy(() => import('../vistas/VistaMovimientos'))
const ModalCrearMovimiento = lazy(() => import('../modals/ModalCrearMovimiento'))
const ModalAceptarMovimiento = lazy(() => import('../modals/ModalAceptarMovimiento'))

type TabEstado = EstadoMovimiento | 'todos'

function LoadingState() {
  return <div className="flex items-center justify-center py-20"><Loader2 className="w-8 h-8 animate-spin text-blue-600" /></div>
}

export default function MovimientosContainer(): React.ReactElement {
  const { isAdminOrEncargado } = useAuthData()
  const { currentSucursalId } = useSucursal()
  const notify = useNotification()

  const [estado, setEstado] = useState<TabEstado>('pendiente')
  const [crearOpen, setCrearOpen] = useState(false)
  const [aceptarMov, setAceptarMov] = useState<MovimientoSucursalDB | null>(null)

  const { data: movimientos = [], isLoading } = useMovimientosQuery({ estado })
  const { data: sucursales = [] } = useSucursalesQuery()
  const { data: productos = [] } = useProductosQuery()
  const { data: itemsAceptar = [], isLoading: loadingItems } = useMovimientoItemsQuery(aceptarMov ? String(aceptarMov.id) : null)

  const crear = useCrearMovimientoMutation()
  const aceptar = useAceptarMovimientoMutation()
  const denegar = useDenegarMovimientoMutation()
  const guardando = crear.isPending || aceptar.isPending || denegar.isPending

  useResetOnSucursalChange(() => {
    setCrearOpen(false)
    setAceptarMov(null)
    setEstado('pendiente')
  })

  // Sucursales destino: las activas distintas de la actual.
  const sucursalesDestino = sucursales.filter(s => Number(s.id) !== currentSucursalId)

  const handleCrear = useCallback(async (payload: {
    sucursalDestinoId: number; notas?: string; items: Array<{ producto_id: number; cantidad: number }>
  }) => {
    await crear.mutateAsync(payload)
    setCrearOpen(false)
    notify.success('Salida creada. Queda pendiente de aprobación.')
  }, [crear, notify])

  const handleAceptar = useCallback(async (resoluciones: ResolucionItem[]) => {
    if (!aceptarMov) return
    await aceptar.mutateAsync({ movimientoId: aceptarMov.id, resoluciones })
    setAceptarMov(null)
    notify.success('Movimiento aceptado. Stock actualizado.')
  }, [aceptar, aceptarMov, notify])

  const handleDenegar = useCallback(async (motivo: string) => {
    if (!aceptarMov) return
    await denegar.mutateAsync({ movimientoId: aceptarMov.id, motivo })
    setAceptarMov(null)
    notify.warning('Movimiento denegado.')
  }, [denegar, aceptarMov, notify])

  return (
    <>
      <Suspense fallback={<LoadingState />}>
        <VistaMovimientos
          movimientos={movimientos}
          loading={isLoading}
          currentSucursalId={currentSucursalId}
          canResolver={isAdminOrEncargado}
          estado={estado}
          onEstadoChange={setEstado}
          onNuevaSalida={() => setCrearOpen(true)}
          onAceptar={setAceptarMov}
          onDenegar={setAceptarMov}
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

      {aceptarMov && (
        <Suspense fallback={null}>
          <ModalAceptarMovimiento
            movimiento={aceptarMov}
            items={itemsAceptar}
            loadingItems={loadingItems}
            productosDestino={productos}
            guardando={guardando}
            onConfirmar={handleAceptar}
            onDenegar={handleDenegar}
            onClose={() => setAceptarMov(null)}
          />
        </Suspense>
      )}
    </>
  )
}
