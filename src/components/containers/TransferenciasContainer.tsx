/**
 * TransferenciasContainer
 *
 * Container que carga transferencias, sucursales y productos bajo demanda usando TanStack Query.
 */
import React, { lazy, Suspense, useState, useCallback } from 'react'
import { Loader2 } from 'lucide-react'
import {
  useTransferenciasQuery,
  useSucursalesQuery,
  useRegistrarTransferenciaMutation,
  useCrearSucursalMutation,
  useProductosQuery,
} from '../../hooks/queries'
import { useAuthData } from '../../contexts/AuthDataContext'
import { useNotification } from '../../contexts/NotificationContext'
import type { TransferenciaFormInput } from '../../types'

// Lazy load de componentes
const VistaTransferencias = lazy(() => import('../vistas/VistaTransferencias'))
const ModalTransferencia = lazy(() => import('../modals/ModalTransferencia'))

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
  const crearSucursal = useCrearSucursalMutation()

  // Estado de modal
  const [modalOpen, setModalOpen] = useState(false)

  // Handlers
  const handleNuevaTransferencia = useCallback(() => {
    setModalOpen(true)
  }, [])

  const handleGuardarTransferencia = useCallback(async (data: TransferenciaFormInput) => {
    try {
      await registrarTransferencia.mutateAsync({
        ...data,
        usuarioId: user?.id || null,
      })
      notify.success('Envio registrado correctamente')
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Error al registrar envio'
      notify.error(msg)
      throw err
    }
  }, [registrarTransferencia, notify, user])

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
          onNuevaTransferencia={handleNuevaTransferencia}
        />
      </Suspense>

      {/* Modal Nueva Transferencia */}
      {modalOpen && (
        <Suspense fallback={null}>
          <ModalTransferencia
            productos={productos}
            sucursales={sucursales}
            onSave={handleGuardarTransferencia}
            onCrearSucursal={handleCrearSucursal}
            onClose={() => setModalOpen(false)}
          />
        </Suspense>
      )}
    </>
  )
}
