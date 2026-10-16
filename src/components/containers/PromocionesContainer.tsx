/**
 * PromocionesContainer
 *
 * Container que gestiona promociones usando TanStack Query.
 */
import React, { Suspense, useMemo, useState, useCallback } from 'react'
import { Loader2, Gift, Boxes } from 'lucide-react'
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
import {
  useCombosAdminQuery,
  useGuardarComboMutation,
  type ComboAdmin,
  type ComboFormInput,
} from '../../hooks/queries/useCombosQuery'
import { Tabs, type TabItem } from '../ui/Tabs'
import { useNotification } from '../../contexts/NotificationContext'
import { lazyWithReload } from '../../utils/lazyWithReload'
import { usePoliticasComercialesQuery } from '../../hooks/queries/usePoliticasComercialesQuery'
import { useAuthData } from '../../contexts/AuthDataContext'
import { puedeVerCostoProducto } from '../../lib/permisos'
import type { ProductoParaAlertas } from '../../utils/comboAlertas'

const VistaPromociones = lazyWithReload(() => import('../vistas/VistaPromociones'))
const ModalPromocion = lazyWithReload(() => import('../modals/ModalPromocion'))
const VistaCombos = lazyWithReload(() => import('../vistas/VistaCombos'))
const ModalCombo = lazyWithReload(() => import('../modals/ModalCombo'))
const ModalConfirmacion = lazyWithReload(() => import('../modals/ModalConfirmacion'))

type Pestana = 'regalos' | 'combos'

const PESTANAS: readonly TabItem<Pestana>[] = [
  { value: 'regalos', label: 'Regalos', icon: Gift },
  { value: 'combos', label: 'Combos', icon: Boxes },
]

/** Un combo tal cual está, para reenviarlo a `guardar_combo` con otro `activo`. */
function inputDesdeCombo(combo: ComboAdmin): ComboFormInput {
  return {
    id: combo.id,
    nombre: combo.nombre,
    precio: combo.precio,
    fechaInicio: combo.fechaInicio,
    fechaFin: combo.fechaFin,
    activo: combo.activo,
    combinaEscalas: combo.combinaEscalas,
    prioridad: combo.prioridad,
    topeCombos: combo.topeCombos,
    productoAMoverId: combo.productoAMoverId,
    componentes: combo.componentes.map(c => ({ cantidad: c.cantidad, productos: [...c.productos] })),
  }
}

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
  // Unidades sueltas por unidad de stock (#950): el N de cada barra de regalo.
  const unidadesPorBulto = useMemo(() => {
    const m = new Map<string, number>()
    productos.forEach(p => { if (p.unidades_por_bulto) m.set(String(p.id), p.unidades_por_bulto) })
    return m
  }, [productos])

  const { data: combos = [], isLoading: cargandoCombos } = useCombosAdminQuery()

  // Alertas de combos (#1194): margen y descuento contra los topes de la
  // sucursal. Los costos llegan pegados a los productos sólo a admin y
  // encargado (costos_productos()); al resto no se le calcula margen.
  const { politicas } = usePoliticasComercialesQuery()
  const { perfil } = useAuthData()
  const verCostos = puedeVerCostoProducto(perfil?.rol)
  const productosParaAlertas = useMemo(
    () => new Map<string, ProductoParaAlertas>(productos.map(p => [String(p.id), p as ProductoParaAlertas])),
    [productos],
  )
  const umbralesCombos = useMemo(
    () => ({ margenMinimoPct: politicas.comboMargenMinimoPct, descuentoMaximoPct: politicas.comboDescuentoMaximoPct }),
    [politicas.comboMargenMinimoPct, politicas.comboDescuentoMaximoPct],
  )

  // Mutations
  const guardarCombo = useGuardarComboMutation()
  const crearPromocion = useCrearPromocionMutation()
  const actualizarPromocion = useActualizarPromocionMutation()
  const eliminarPromocion = useEliminarPromocionMutation()
  const toggleActivo = useTogglePromocionActivaMutation()

  // Estado modal
  const [modalOpen, setModalOpen] = useState(false)
  const [promoEditando, setPromoEditando] = useState<PromocionConDetalles | null>(null)
  const [confirmConfig, setConfirmConfig] = useState<ConfirmConfig>({ visible: false })
  const [pestana, setPestana] = useState<Pestana>('regalos')
  const [comboModalOpen, setComboModalOpen] = useState(false)
  const [comboEditando, setComboEditando] = useState<ComboAdmin | null>(null)

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

  const handleNuevoCombo = useCallback(() => {
    setComboEditando(null)
    setComboModalOpen(true)
  }, [])

  const handleEditarCombo = useCallback((combo: ComboAdmin) => {
    setComboEditando(combo)
    setComboModalOpen(true)
  }, [])

  // Un combo no se borra (un pedido viejo pudo venderlo): se desactiva. Se manda
  // el combo entero con `activo` cambiado, que es lo que `guardar_combo` espera.
  const handleToggleCombo = useCallback(async (combo: ComboAdmin) => {
    try {
      await guardarCombo.mutateAsync({ ...inputDesdeCombo(combo), activo: !combo.activo })
      notify.success(combo.activo ? 'Combo desactivado' : 'Combo activado')
    } catch (err) {
      notify.error(err instanceof Error ? err.message : 'Error al cambiar estado')
    }
  }, [guardarCombo, notify])

  // Si falla, la promesa se rechaza y el modal muestra el mensaje del server
  // (precio fuera de rango, producto repetido...) y queda abierto para corregir.
  const handleGuardarCombo = useCallback(async (input: ComboFormInput) => {
    await guardarCombo.mutateAsync(input)
    notify.success(input.id ? 'Combo actualizado' : 'Combo creado')
    setComboModalOpen(false)
    setComboEditando(null)
  }, [guardarCombo, notify])

  return (
    <>
      <Tabs value={pestana} onValueChange={setPestana} tabs={PESTANAS} etiqueta="Tipo de promoción">
        {pestana === 'regalos' ? (
          <Suspense fallback={<LoadingState />}>
            <VistaPromociones
              promociones={promociones}
              productoNombres={productoNombres}
              unidadesPorBulto={unidadesPorBulto}
              unidadesEntregadas={unidadesEntregadas}
              acumuladoresPorPromo={acumuladoresPorPromo}
              loading={isLoading}
              onNuevaPromocion={handleNuevaPromocion}
              onEditarPromocion={handleEditarPromocion}
              onEliminarPromocion={handleEliminarPromocion}
              onToggleActivo={handleToggleActivo}
            />
          </Suspense>
        ) : (
          <Suspense fallback={<LoadingState />}>
            <VistaCombos
              combos={combos}
              productoNombres={productoNombres}
              loading={cargandoCombos}
              onNuevoCombo={handleNuevoCombo}
              onEditarCombo={handleEditarCombo}
              onToggleActivo={handleToggleCombo}
              productos={productosParaAlertas}
              umbrales={umbralesCombos}
              verCostos={verCostos}
            />
          </Suspense>
        )}
      </Tabs>

      {comboModalOpen && (
        <Suspense fallback={null}>
          <ModalCombo
            combo={comboEditando}
            productos={productos}
            umbrales={umbralesCombos}
            verCostos={verCostos}
            onSave={handleGuardarCombo}
            guardando={guardarCombo.isPending}
            onClose={() => {
              setComboModalOpen(false)
              setComboEditando(null)
            }}
          />
        </Suspense>
      )}

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
