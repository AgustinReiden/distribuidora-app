/**
 * TransferenciasContainer
 *
 * Container que carga transferencias, sucursales y productos bajo demanda usando TanStack Query.
 * Soporta salidas e ingresos entre sucursales.
 */
import React, { lazy, Suspense, useState, useCallback } from 'react'
import { Loader2 } from 'lucide-react'
import {
  useTransferenciasQuery,
  useSucursalesQuery,
  useRegistrarTransferenciaMutation,
  useRegistrarIngresoMutation,
  useCrearSucursalMutation,
  useProductosQuery,
} from '../../hooks/queries'
import { useAuthData } from '../../contexts/AuthDataContext'
import { useNotification } from '../../contexts/NotificationContext'
import type { TransferenciaFormInput, TransferenciaDB, TipoTransferencia } from '../../types'

// Lazy load de componentes
const VistaTransferencias = lazy(() => import('../vistas/VistaTransferencias'))
const ModalTransferencia = lazy(() => import('../modals/ModalTransferencia'))
const ModalDetalleTransferencia = lazy(() => import('../modals/ModalDetalleTransferencia'))

function LoadingState() {
  return (
    <div className="flex items-center justify-center py-20">
      <Loader2 className="w-8 h-8 animate-spin text-blue-600" />
    </div>
  )
}

export default function TransferenciasContainer(): React.ReactElement {
  const { user } = useAuthData()
  const notify = useNotification()

  // Queries
  const { data: transferencias = [], isLoading } = useTransferenciasQuery()
  const { data: sucursales = [] } = useSucursalesQuery()
  const { data: productos = [] } = useProductosQuery()

  // Mutations
  const registrarTransferencia = useRegistrarTransferenciaMutation()
  const registrarIngreso = useRegistrarIngresoMutation()
  const crearSucursal = useCrearSucursalMutation()

  // Estado de modales
  const [modalTipo, setModalTipo] = useState<TipoTransferencia | null>(null)
  const [detalleTransferencia, setDetalleTransferencia] = useState<TransferenciaDB | null>(null)

  // Handlers
  const handleNuevaSalida = useCallback(() => {
    setModalTipo('salida')
  }, [])

  const handleNuevoIngreso = useCallback(() => {
    setModalTipo('ingreso')
  }, [])

  const handleVerDetalle = useCallback((transferencia: TransferenciaDB) => {
    setDetalleTransferencia(transferencia)
  }, [])

  const handleGuardarTransferencia = useCallback(async (data: TransferenciaFormInput) => {
    try {
      if (data.tipo === 'ingreso') {
        await registrarIngreso.mutateAsync({
          ...data,
          usuarioId: user?.id || null,
        })
        notify.success('Ingreso registrado correctamente')
      } else {
        await registrarTransferencia.mutateAsync({
          ...data,
          usuarioId: user?.id || null,
        })
        notify.success('Salida registrada correctamente')
      }
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Error al registrar movimiento'
      notify.error(msg)
      throw err
    }
  }, [registrarTransferencia, registrarIngreso, notify, user])

  const handleCrearSucursal = useCallback(async (data: { nombre: string; direccion?: string }) => {
    const nueva = await crearSucursal.mutateAsync(data)
    notify.success(`Sucursal "${data.nombre}" creada`)
    return nueva
  }, [crearSucursal, notify])

  return (
    <>
      <Suspense fallback={<LoadingState />}>
        <VistaTransferencias
          transferencias={transferencias}
          loading={isLoading}
          onNuevaSalida={handleNuevaSalida}
          onNuevoIngreso={handleNuevoIngreso}
          onVerDetalle={handleVerDetalle}
        />
      </Suspense>

      {/* Modal Nueva Salida / Nuevo Ingreso */}
      {modalTipo && (
        <Suspense fallback={null}>
          <ModalTransferencia
            tipo={modalTipo}
            productos={productos}
            sucursales={sucursales}
            onSave={handleGuardarTransferencia}
            onCrearSucursal={handleCrearSucursal}
            onClose={() => setModalTipo(null)}
          />
        </Suspense>
      )}

      {/* Modal Detalle */}
      {detalleTransferencia && (
        <Suspense fallback={null}>
          <ModalDetalleTransferencia
            transferencia={detalleTransferencia}
            onClose={() => setDetalleTransferencia(null)}
          />
        </Suspense>
      )}
    </>
  )
}
