/**
 * ProveedoresContainer
 *
 * Container que carga proveedores bajo demanda usando TanStack Query.
 */
import React, { lazy, Suspense, useState, useCallback } from 'react'
import { Loader2 } from 'lucide-react'
import {
  useProveedoresQuery,
  useComprasQuery,
  useCrearProveedorMutation,
  useActualizarProveedorMutation,
  useToggleProveedorActivoMutation,
  useEliminarProveedorMutation
} from '../../hooks/queries'
import { useAuthData } from '../../contexts/AuthDataContext'
import { useNotification } from '../../contexts/NotificationContext'
import type { ProveedorDBExtended, ProveedorFormInputExtended } from '../../types'

// Lazy load de componentes
const VistaProveedores = lazy(() => import('../vistas/VistaProveedores'))
const ModalProveedor = lazy(() => import('../modals/ModalProveedor'))
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

export default function ProveedoresContainer(): React.ReactElement {
  const { isAdmin } = useAuthData()
  const notify = useNotification()

  // Queries
  const { data: proveedores = [], isLoading } = useProveedoresQuery()
  const { data: compras = [] } = useComprasQuery()

  // Mutations
  const crearProveedor = useCrearProveedorMutation()
  const actualizarProveedor = useActualizarProveedorMutation()
  const toggleActivo = useToggleProveedorActivoMutation()
  const eliminarProveedor = useEliminarProveedorMutation()

  // Estado de modales
  const [modalProveedorOpen, setModalProveedorOpen] = useState(false)

  // Estado de edición
  const [proveedorEditando, setProveedorEditando] = useState<ProveedorDBExtended | null>(null)
  const [confirmConfig, setConfirmConfig] = useState<ConfirmConfig>({ visible: false })

  // Handlers
  const handleNuevoProveedor = useCallback(() => {
    setProveedorEditando(null)
    setModalProveedorOpen(true)
  }, [])

  const handleEditarProveedor = useCallback((proveedor: ProveedorDBExtended) => {
    setProveedorEditando(proveedor)
    setModalProveedorOpen(true)
  }, [])

  const handleEliminarProveedor = useCallback((id: string) => {
    const proveedor = proveedores.find(p => p.id === id)
    const nombre = proveedor?.nombre || 'este proveedor'
    setConfirmConfig({
      visible: true, tipo: 'danger', titulo: 'Eliminar proveedor',
      mensaje: `¿Eliminar permanentemente al proveedor "${nombre}"? Las compras asociadas conservarán el nombre del proveedor.`,
      onConfirm: async () => {
        setConfirmConfig({ visible: false })
        try {
          await eliminarProveedor.mutateAsync(id)
          notify.success(`Proveedor "${nombre}" eliminado`)
        } catch {
          notify.error('Error al eliminar proveedor')
        }
      },
    })
  }, [eliminarProveedor, notify, proveedores])

  const handleToggleActivo = useCallback(async (proveedor: ProveedorDBExtended) => {
    try {
      await toggleActivo.mutateAsync({ id: proveedor.id, activo: !proveedor.activo })
      notify.success(proveedor.activo ? 'Proveedor desactivado' : 'Proveedor activado')
    } catch {
      notify.error('Error al cambiar estado')
    }
  }, [toggleActivo, notify])

  const handleGuardarProveedor = useCallback(async (data: ProveedorFormInputExtended) => {
    try {
      if (proveedorEditando) {
        await actualizarProveedor.mutateAsync({ id: proveedorEditando.id, data })
        notify.success('Proveedor actualizado')
      } else {
        await crearProveedor.mutateAsync(data)
        notify.success('Proveedor creado')
      }
      setModalProveedorOpen(false)
      setProveedorEditando(null)
      return { success: true }
    } catch {
      notify.error('Error al guardar proveedor')
      return { success: false, error: 'Error al guardar' }
    }
  }, [proveedorEditando, actualizarProveedor, crearProveedor, notify])

  return (
    <>
      <Suspense fallback={<LoadingState />}>
        <VistaProveedores
          proveedores={proveedores as Parameters<typeof VistaProveedores>[0]['proveedores']}
          compras={compras as Parameters<typeof VistaProveedores>[0]['compras']}
          loading={isLoading}
          isAdmin={isAdmin}
          onNuevoProveedor={handleNuevoProveedor}
          onEditarProveedor={handleEditarProveedor as Parameters<typeof VistaProveedores>[0]['onEditarProveedor']}
          onEliminarProveedor={handleEliminarProveedor}
          onToggleActivo={handleToggleActivo}
        />
      </Suspense>

      {/* Modal Proveedor */}
      {modalProveedorOpen && (
        <Suspense fallback={null}>
          <ModalProveedor
            proveedor={proveedorEditando as Parameters<typeof ModalProveedor>[0]['proveedor']}
            onSave={handleGuardarProveedor as unknown as Parameters<typeof ModalProveedor>[0]['onSave']}
            onClose={() => {
              setModalProveedorOpen(false)
              setProveedorEditando(null)
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
