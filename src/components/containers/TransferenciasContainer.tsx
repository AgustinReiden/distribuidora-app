/**
 * TransferenciasContainer
 *
 * Container que carga transferencias, sucursales y productos bajo demanda usando TanStack Query.
 * Soporta salidas e ingresos entre sucursales.
 */
import React, { lazy, Suspense, useState, useCallback, useMemo } from 'react'
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
import { useSucursal } from '../../contexts/SucursalContext'
import { useNotification } from '../../contexts/NotificationContext'
import { useResetOnSucursalChange } from '../../hooks/useResetOnSucursalChange'
import { fechaHaceDias, fechaLocalISO } from '../../utils/formatters'
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
  const { currentSucursalId } = useSucursal()
  const notify = useNotification()

  // Filtros de fecha + paginacion. Defaults: ultimos 60 dias, pagina 1.
  const [desde, setDesde] = useState<string>(() => fechaHaceDias(60))
  const [hasta, setHasta] = useState<string>(() => fechaLocalISO())
  const [pagina, setPagina] = useState<number>(1)
  const filtros = useMemo(() => ({ desde, hasta, pagina }), [desde, hasta, pagina])

  // Queries
  const { data: transferencias = [], isLoading, error: queryError } = useTransferenciasQuery(filtros)
  const { data: sucursales = [] } = useSucursalesQuery()
  const { data: productos = [] } = useProductosQuery()

  // Mutations
  const registrarTransferencia = useRegistrarTransferenciaMutation()
  const registrarIngreso = useRegistrarIngresoMutation()
  const crearSucursal = useCrearSucursalMutation()

  // Estado de modales
  const [modalTipo, setModalTipo] = useState<TipoTransferencia | null>(null)
  const [detalleTransferencia, setDetalleTransferencia] = useState<TransferenciaDB | null>(null)

  // Cerrar modales y volver a pagina 1 al cambiar sucursal.
  useResetOnSucursalChange(() => {
    setModalTipo(null)
    setDetalleTransferencia(null)
    setPagina(1)
  })

  // Handlers de filtros
  const handleFechaDesde = useCallback((v: string) => {
    setDesde(v)
    setPagina(1)
  }, [])
  const handleFechaHasta = useCallback((v: string) => {
    setHasta(v)
    setPagina(1)
  }, [])
  const handlePaginaCambio = useCallback((p: number) => setPagina(p), [])

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

  // Banner defensivo: si la sucursal activa quedo null (ej. localStorage stale
  // apuntando a una sucursal a la que el usuario perdio acceso),
  // current_sucursal_id() en la DB devuelve NULL y la RLS oculta todos los
  // movimientos, incluso los que el mismo usuario creo. Avisamos en vez de
  // mostrar "No hay movimientos" silenciosamente.
  const sucursalInvalida = !currentSucursalId

  return (
    <>
      {sucursalInvalida && (
        <div className="mb-4 rounded-lg border border-amber-300 bg-amber-50 dark:bg-amber-900/20 dark:border-amber-800 px-4 py-3 text-sm text-amber-800 dark:text-amber-200">
          <p className="font-medium">No se detecta una sucursal activa.</p>
          <p className="mt-1 text-xs">
            Es probable que tu sesion haya quedado apuntando a una sucursal vieja. Cerra
            sesion y volve a entrar, o cambia de sucursal desde el menu superior.
            Mientras tanto, el panel mostrara vacio porque la base oculta los movimientos
            que no pueda asociar a una sucursal autorizada.
          </p>
        </div>
      )}
      {queryError && !sucursalInvalida && (
        <div className="mb-4 rounded-lg border border-rose-300 bg-rose-50 dark:bg-rose-900/20 dark:border-rose-800 px-4 py-3 text-sm text-rose-800 dark:text-rose-200">
          <p className="font-medium">No se pudieron cargar los movimientos.</p>
          <p className="mt-1 text-xs font-mono break-all">
            {queryError instanceof Error ? queryError.message : String(queryError)}
          </p>
        </div>
      )}
      <Suspense fallback={<LoadingState />}>
        <VistaTransferencias
          transferencias={transferencias}
          loading={isLoading}
          desde={desde}
          hasta={hasta}
          pagina={pagina}
          onCambiarDesde={handleFechaDesde}
          onCambiarHasta={handleFechaHasta}
          onCambiarPagina={handlePaginaCambio}
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
