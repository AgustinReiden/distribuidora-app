/**
 * PromocionesContainer
 *
 * Container que gestiona promociones usando TanStack Query.
 */
import React, { lazy, Suspense, useState, useCallback } from 'react'
import { Loader2 } from 'lucide-react'
import {
  usePromocionesListQuery,
  useProductosQuery,
  useCrearPromocionMutation,
  useActualizarPromocionMutation,
  useEliminarPromocionMutation,
  useTogglePromocionActivaMutation,
  useAjustarStockPromoMutation,
} from '../../hooks/queries'
import type { PromocionConDetalles, PromocionFormInput } from '../../hooks/queries/usePromocionesQuery'
import { useNotification } from '../../contexts/NotificationContext'
import { useAuthData } from '../../contexts/AuthDataContext'

const VistaPromociones = lazy(() => import('../vistas/VistaPromociones'))
const ModalPromocion = lazy(() => import('../modals/ModalPromocion'))
const ModalConfirmacion = lazy(() => import('../modals/ModalConfirmacion'))

function LoadingState() {
  return (
    <div className="flex items-center justify-center py-20">
      <Loader2 className="w-8 h-8 animate-spin text-purple-600" />
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

export default function PromocionesContainer(): React.ReactElement {
  const notify = useNotification()
  const { user } = useAuthData()

  // Queries
  const { data: promociones = [], isLoading } = usePromocionesListQuery()
  const { data: productos = [] } = useProductosQuery()

  // Mutations
  const crearPromocion = useCrearPromocionMutation()
  const actualizarPromocion = useActualizarPromocionMutation()
  const eliminarPromocion = useEliminarPromocionMutation()
  const toggleActivo = useTogglePromocionActivaMutation()
  const ajustarStock = useAjustarStockPromoMutation()

  // Estado modal
  const [modalOpen, setModalOpen] = useState(false)
  const [promoEditando, setPromoEditando] = useState<PromocionConDetalles | null>(null)
  const [confirmConfig, setConfirmConfig] = useState<ConfirmConfig>({ visible: false })

  const handleNuevaPromocion = useCallback(() => {
    setPromoEditando(null)
    setModalOpen(true)
  }, [])

  const handleEditarPromocion = useCallback((promo: PromocionConDetalles) => {
    setPromoEditando(promo)
    setModalOpen(true)
  }, [])

  const handleEliminarPromocion = useCallback((id: string) => {
    const promo = promociones.find(p => p.id === id)
    const nombre = promo?.nombre || 'esta promocion'
    setConfirmConfig({
      visible: true, tipo: 'danger', titulo: 'Eliminar promoción',
      mensaje: `¿Eliminar la promoción "${nombre}"? Se eliminarán la promo y sus reglas.`,
      onConfirm: async () => {
        setConfirmConfig({ visible: false })
        try {
          await eliminarPromocion.mutateAsync(id)
          notify.success(`Promoción "${nombre}" eliminada`)
        } catch {
          notify.error('Error al eliminar promoción')
        }
      },
    })
  }, [eliminarPromocion, notify, promociones])

  const handleToggleActivo = useCallback(async (promo: PromocionConDetalles) => {
    try {
      await toggleActivo.mutateAsync({ id: promo.id, activo: !promo.activo })
      notify.success(promo.activo ? 'Promocion desactivada' : 'Promocion activada')
    } catch {
      notify.error('Error al cambiar estado')
    }
  }, [toggleActivo, notify])

  const handleAjustarStock = useCallback(async (
    promo: PromocionConDetalles,
    payload: { productoRegaloId: string; cantidadStock: number; usosAjustados: number; observaciones: string },
  ) => {
    try {
      await ajustarStock.mutateAsync({
        promocionId: promo.id,
        productoRegaloId: payload.productoRegaloId,
        cantidadStock: payload.cantidadStock,
        usosAjustados: payload.usosAjustados,
        usuarioId: user?.id ?? '',
        observaciones: payload.observaciones || undefined,
      })
      notify.success(`Stock ajustado: -${payload.cantidadStock} unidades (${payload.usosAjustados} usos resueltos)`)
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Error al ajustar stock'
      notify.error(msg)
    }
  }, [ajustarStock, notify, user])

  const handleGuardarPromocion = useCallback(async (data: PromocionFormInput) => {
    try {
      if (promoEditando) {
        await actualizarPromocion.mutateAsync({ id: promoEditando.id, data })
        notify.success('Promocion actualizada')
      } else {
        await crearPromocion.mutateAsync(data)
        notify.success('Promocion creada')
      }
      setModalOpen(false)
      setPromoEditando(null)
      return { success: true }
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Error al guardar'
      notify.error(msg)
      return { success: false, error: msg }
    }
  }, [promoEditando, actualizarPromocion, crearPromocion, notify])

  return (
    <>
      <Suspense fallback={<LoadingState />}>
        <VistaPromociones
          promociones={promociones}
          productos={productos}
          loading={isLoading}
          onNuevaPromocion={handleNuevaPromocion}
          onEditarPromocion={handleEditarPromocion}
          onEliminarPromocion={handleEliminarPromocion}
          onToggleActivo={handleToggleActivo}
          onAjustarStock={handleAjustarStock}
        />
      </Suspense>

      {modalOpen && (
        <Suspense fallback={null}>
          <ModalPromocion
            promocion={promoEditando}
            productos={productos}
            onSave={handleGuardarPromocion}
            onClose={() => {
              setModalOpen(false)
              setPromoEditando(null)
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
