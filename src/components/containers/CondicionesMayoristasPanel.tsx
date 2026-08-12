/**
 * CondicionesMayoristasPanel
 *
 * Gestiona las condiciones mayoristas (grupos de precio) usando TanStack Query.
 *
 * No es un container de ruta: se monta como pestaña dentro de /productos. Las
 * condiciones son un atributo del catalogo —"este fardo de fideos sale tanto"—
 * y tenerlas en una seccion aparte del menu obligaba a saltar de pantalla para
 * algo que se decide mirando el producto.
 */
import React, { Suspense, useState, useCallback } from 'react'
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
import { lazyWithReload } from '../../utils/lazyWithReload'

const VistaGruposPrecio = lazyWithReload(() => import('../vistas/VistaGruposPrecio'))
const AsistenteConsolidacion = lazyWithReload(() => import('../productos/AsistenteConsolidacion'))
const ModalGrupoPrecio = lazyWithReload(() => import('../modals/ModalGrupoPrecio'))
const ModalConfirmacion = lazyWithReload(() => import('../modals/ModalConfirmacion'))

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

export default function CondicionesMayoristasPanel(): React.ReactElement {
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
  const [confirmConfig, setConfirmConfig] = useState<ConfirmConfig>({ visible: false })

  const handleNuevoGrupo = useCallback(() => {
    setGrupoEditando(null)
    setModalOpen(true)
  }, [])

  const handleEditarGrupo = useCallback((grupo: GrupoPrecioConDetalles) => {
    setGrupoEditando(grupo)
    setModalOpen(true)
  }, [])

  const handleEliminarGrupo = useCallback((id: string) => {
    const grupo = grupos.find(g => g.id === id)
    const nombre = grupo?.nombre || 'este grupo'
    setConfirmConfig({
      visible: true, tipo: 'danger', titulo: 'Eliminar grupo de precio',
      mensaje: `¿Eliminar el grupo "${nombre}"? Los productos no se verán afectados, solo se elimina la regla de precio mayorista.`,
      onConfirm: async () => {
        setConfirmConfig({ visible: false })
        try {
          await eliminarGrupo.mutateAsync(id)
          notify.success(`Grupo "${nombre}" eliminado`)
        } catch {
          notify.error('Error al eliminar grupo')
        }
      },
    })
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
    <div className="space-y-4">
      {/* Se muestra solo si hay algo que unir; si no, no renderiza nada. */}
      {grupos.length > 0 && (
        <Suspense fallback={null}>
          <AsistenteConsolidacion grupos={grupos} />
        </Suspense>
      )}

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
    </div>
  )
}
