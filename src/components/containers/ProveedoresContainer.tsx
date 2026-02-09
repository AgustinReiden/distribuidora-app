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
  useToggleProveedorActivoMutation
} from '../../hooks/queries'
import { useAuthData } from '../../contexts/AuthDataContext'
import { useNotification } from '../../contexts/NotificationContext'
import type { ProveedorDBExtended, ProveedorFormInputExtended } from '../../types'

// Lazy load de componentes
const VistaProveedores = lazy(() => import('../vistas/VistaProveedores'))
const ModalProveedor = lazy(() => import('../modals/ModalProveedor'))

function LoadingState() {
  return (
    <div className="flex items-center justify-center py-20">
      <Loader2 className="w-8 h-8 animate-spin text-blue-600" />
    </div>
  )
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

  // Estado de modales
  const [modalProveedorOpen, setModalProveedorOpen] = useState(false)

  // Estado de edición
  const [proveedorEditando, setProveedorEditando] = useState<ProveedorDBExtended | null>(null)

  // Handlers
  const handleNuevoProveedor = useCallback(() => {
    setProveedorEditando(null)
    setModalProveedorOpen(true)
  }, [])

  const handleEditarProveedor = useCallback((proveedor: ProveedorDBExtended) => {
    setProveedorEditando(proveedor)
    setModalProveedorOpen(true)
  }, [])

  const handleEliminarProveedor = useCallback(async (proveedor: ProveedorDBExtended) => {
    // En realidad no eliminamos, solo desactivamos
    if (!window.confirm(`¿Desactivar proveedor "${proveedor.nombre}"?`)) return
    try {
      await toggleActivo.mutateAsync({ id: proveedor.id, activo: false })
      notify.success('Proveedor desactivado')
    } catch {
      notify.error('Error al desactivar proveedor')
    }
  }, [toggleActivo, notify])

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
          onEliminarProveedor={handleEliminarProveedor as Parameters<typeof VistaProveedores>[0]['onEliminarProveedor']}
          onToggleActivo={handleToggleActivo}
        />
      </Suspense>

      {/* Modal Proveedor */}
      {modalProveedorOpen && (
        <Suspense fallback={null}>
          <ModalProveedor
            proveedor={proveedorEditando as Parameters<typeof ModalProveedor>[0]['proveedor']}
            onSave={handleGuardarProveedor as Parameters<typeof ModalProveedor>[0]['onSave']}
            onClose={() => {
              setModalProveedorOpen(false)
              setProveedorEditando(null)
            }}
          />
        </Suspense>
      )}
    </>
  )
}
