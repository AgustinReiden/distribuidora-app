/**
 * PromocionesContainer
 *
 * Container que gestiona promociones usando TanStack Query.
 */
import React, { Suspense, useMemo, useState, useCallback } from 'react'
import { Loader2 } from 'lucide-react'
import {
  usePromocionesListQuery,
  useProductosQuery,
  useCrearPromocionMutation,
  useActualizarPromocionMutation,
  useEliminarPromocionMutation,
  useTogglePromocionActivaMutation,
  usePromoUnidadesEntregadasQuery,
  usePromoAcumuladoresMapQuery,
  contarReferenciasDePromocion,
} from '../../hooks/queries'
import type { PromocionConDetalles, PromocionFormInput } from '../../hooks/queries/usePromocionesQuery'
import { useNotification } from '../../contexts/NotificationContext'
import { lazyWithReload } from '../../utils/lazyWithReload'

const VistaPromociones = lazyWithReload(() => import('../vistas/VistaPromociones'))
const ModalPromocion = lazyWithReload(() => import('../modals/ModalPromocion'))
const ModalConfirmacion = lazyWithReload(() => import('../modals/ModalConfirmacion'))

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

  // Queries
  const { data: promociones = [], isLoading } = usePromocionesListQuery()
  const { data: productos = [] } = useProductosQuery()
  const { data: unidadesEntregadas } = usePromoUnidadesEntregadasQuery()
  const { data: acumuladoresPorPromo } = usePromoAcumuladoresMapQuery()

  const productoNombres = useMemo(() => {
    const m = new Map<string, string>()
    productos.forEach(p => m.set(String(p.id), p.nombre))
    return m
  }, [productos])

  // Mutations
  const crearPromocion = useCrearPromocionMutation()
  const actualizarPromocion = useActualizarPromocionMutation()
  const eliminarPromocion = useEliminarPromocionMutation()
  const toggleActivo = useTogglePromocionActivaMutation()

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

  // Borrar una promo con historial NO es inocente: a diferencia de clientes
  // (mig 200) las FKs de promociones no son RESTRICT -- pedido_items.promocion_id
  // es SET NULL y promo_ajustes es CASCADE -- asi que el DELETE nunca falla
  // solo, borra en silencio el historial de ajustes y desprende la promo de
  // los pedidos ya facturados. Se cuenta primero y se ofrece desactivar.
  const handleEliminarPromocion = useCallback(async (id: string) => {
    const promo = promociones.find(p => p.id === id)
    const nombre = promo?.nombre || 'esta promocion'

    let referencias: Awaited<ReturnType<typeof contarReferenciasDePromocion>>
    try {
      referencias = await contarReferenciasDePromocion(id)
    } catch {
      notify.error('No se pudo verificar si la promoción tiene pedidos o ajustes. No se eliminó nada.')
      return
    }

    if (referencias.tieneUso) {
      const detalle: string[] = []
      if (referencias.pedidos > 0) {
        detalle.push(`${referencias.pedidos} ${referencias.pedidos === 1 ? 'pedido' : 'pedidos'} facturados`)
      }
      if (referencias.ajustes > 0) {
        detalle.push(`${referencias.ajustes} ${referencias.ajustes === 1 ? 'ajuste' : 'ajustes'} de stock`)
      }
      const detalleTexto = detalle.join(' y ')

      if (!promo?.activo) {
        notify.error(
          `"${nombre}" tiene ${detalleTexto} y ya está desactivada. No se puede eliminar sin perder ese historial.`
        )
        return
      }

      setConfirmConfig({
        visible: true, tipo: 'warning', titulo: 'La promoción tiene historial',
        mensaje:
          `"${nombre}" tiene ${detalleTexto}. No se puede eliminar sin que los pedidos ya facturados ` +
          'pierdan con qué promo se vendieron y sin borrar el historial de ajustes de stock. ' +
          'Al confirmar se DESACTIVA: deja de aplicarse a pedidos nuevos, pero el historial queda intacto.',
        onConfirm: async () => {
          setConfirmConfig({ visible: false })
          try {
            await toggleActivo.mutateAsync({ id, activo: false })
            notify.success(`"${nombre}" quedó desactivada`)
          } catch {
            notify.error('Error al desactivar la promoción')
          }
        },
      })
      return
    }

    setConfirmConfig({
      visible: true, tipo: 'danger', titulo: 'Eliminar promoción',
      mensaje: `¿Eliminar la promoción "${nombre}"? Se eliminarán la promo, sus reglas, sus productos asignados y su historial de ajustes de stock.`,
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
  }, [eliminarPromocion, toggleActivo, notify, promociones])

  const handleToggleActivo = useCallback(async (promo: PromocionConDetalles) => {
    try {
      await toggleActivo.mutateAsync({ id: promo.id, activo: !promo.activo })
      notify.success(promo.activo ? 'Promocion desactivada' : 'Promocion activada')
    } catch {
      notify.error('Error al cambiar estado')
    }
  }, [toggleActivo, notify])

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
          productoNombres={productoNombres}
          unidadesEntregadas={unidadesEntregadas}
          acumuladoresPorPromo={acumuladoresPorPromo}
          loading={isLoading}
          onNuevaPromocion={handleNuevaPromocion}
          onEditarPromocion={handleEditarPromocion}
          onEliminarPromocion={handleEliminarPromocion}
          onToggleActivo={handleToggleActivo}
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
