/**
 * GruposPrecioContainer
 *
 * Container que gestiona grupos de precio mayorista usando TanStack Query.
 */
import React, { lazy, Suspense, useState, useCallback } from 'react'
import { Loader2 } from 'lucide-react'
import {
  useGruposPrecioQuery,
  useProductosQuery,
  useCrearGrupoPrecioMutation,
  useActualizarGrupoPrecioMutation,
  useEliminarGrupoPrecioMutation,
  useToggleGrupoPrecioActivoMutation,
} from '../../hooks/queries'
import { useNotification } from '../../contexts/NotificationContext'
import type { GrupoPrecioConDetalles, GrupoPrecioFormInput } from '../../types'

const VistaGruposPrecio = lazy(() => import('../vistas/VistaGruposPrecio'))
const ModalGrupoPrecio = lazy(() => import('../modals/ModalGrupoPrecio'))

function LoadingState() {
  return (
    <div className="flex items-center justify-center py-20">
      <Loader2 className="w-8 h-8 animate-spin text-blue-600" />
    </div>
  )
}

export default function GruposPrecioContainer(): React.ReactElement {
  const notify = useNotification()

  // Queries
  const { data: grupos = [], isLoading } = useGruposPrecioQuery()
  const { data: productos = [] } = useProductosQuery()

  // Mutations
  const crearGrupo = useCrearGrupoPrecioMutation()
  const actualizarGrupo = useActualizarGrupoPrecioMutation()
  const eliminarGrupo = useEliminarGrupoPrecioMutation()
  const toggleActivo = useToggleGrupoPrecioActivoMutation()

  // Estado modal
  const [modalOpen, setModalOpen] = useState(false)
  const [grupoEditando, setGrupoEditando] = useState<GrupoPrecioConDetalles | null>(null)

  const handleNuevoGrupo = useCallback(() => {
    setGrupoEditando(null)
    setModalOpen(true)
  }, [])

  const handleEditarGrupo = useCallback((grupo: GrupoPrecioConDetalles) => {
    setGrupoEditando(grupo)
    setModalOpen(true)
  }, [])

  const handleEliminarGrupo = useCallback(async (id: string) => {
    const grupo = grupos.find(g => g.id === id)
    const nombre = grupo?.nombre || 'este grupo'
    if (!window.confirm(`¿Eliminar el grupo "${nombre}"?\n\nLos productos no se verán afectados, solo se elimina la regla de precio mayorista.`)) return
    try {
      await eliminarGrupo.mutateAsync(id)
      notify.success(`Grupo "${nombre}" eliminado`)
    } catch {
      notify.error('Error al eliminar grupo')
    }
  }, [eliminarGrupo, notify, grupos])

  const handleToggleActivo = useCallback(async (grupo: GrupoPrecioConDetalles) => {
    try {
      await toggleActivo.mutateAsync({ id: grupo.id, activo: !grupo.activo })
      notify.success(grupo.activo ? 'Grupo desactivado' : 'Grupo activado')
    } catch {
      notify.error('Error al cambiar estado')
    }
  }, [toggleActivo, notify])

  const handleGuardarGrupo = useCallback(async (data: GrupoPrecioFormInput) => {
    try {
      if (grupoEditando) {
        await actualizarGrupo.mutateAsync({ id: grupoEditando.id, data })
        notify.success('Grupo actualizado')
      } else {
        await crearGrupo.mutateAsync(data)
        notify.success('Grupo creado')
      }
      setModalOpen(false)
      setGrupoEditando(null)
      return { success: true }
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Error al guardar'
      notify.error(msg)
      return { success: false, error: msg }
    }
  }, [grupoEditando, actualizarGrupo, crearGrupo, notify])

  return (
    <>
      <Suspense fallback={<LoadingState />}>
        <VistaGruposPrecio
          grupos={grupos}
          productos={productos}
          loading={isLoading}
          onNuevoGrupo={handleNuevoGrupo}
          onEditarGrupo={handleEditarGrupo}
          onEliminarGrupo={handleEliminarGrupo}
          onToggleActivo={handleToggleActivo}
        />
      </Suspense>

      {modalOpen && (
        <Suspense fallback={null}>
          <ModalGrupoPrecio
            grupo={grupoEditando}
            productos={productos}
            onSave={handleGuardarGrupo}
            onClose={() => {
              setModalOpen(false)
              setGrupoEditando(null)
            }}
          />
        </Suspense>
      )}
    </>
  )
}
