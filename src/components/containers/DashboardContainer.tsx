/**
 * DashboardContainer
 *
 * Container que carga datos del dashboard bajo demanda usando TanStack Query.
 * Solo carga métricas cuando el usuario navega a esta vista.
 */
import React, { Suspense } from 'react'
import { Loader2 } from 'lucide-react'
import { useMetricasQuery, useClientesQuery, useAvanceMetasQuery, periodoMensual } from '../../hooks/queries'
import { useAuthData } from '../../contexts/AuthDataContext'
import { useBackup } from '../../hooks/supabase'
import { lazyWithReload } from '../../utils/lazyWithReload'

const VistaDashboard = lazyWithReload(() => import('../vistas/VistaDashboard'))

function LoadingState() {
  return (
    <div className="flex items-center justify-center py-20">
      <Loader2 className="w-8 h-8 animate-spin text-blue-600" />
    </div>
  )
}

export default function DashboardContainer(): React.ReactElement {
  const { user, isAdmin, isPreventista, isEncargado, authReady } = useAuthData()

  // Determinar si debe filtrar por usuario (el preventista solo ve sus
  // propios datos)
  const usuarioFiltro = isPreventista && !isAdmin ? user?.id : null

  // Estado local para el filtro de periodo y fechas personalizadas
  const [filtroPeriodo, setFiltroPeriodo] = React.useState('mes')
  const [fechaDesde, setFechaDesde] = React.useState<string | null>(null)
  const [fechaHasta, setFechaHasta] = React.useState<string | null>(null)

  // Cargar métricas bajo demanda - ahora usa filtroPeriodo del estado
  const {
    data: metricas,
    isLoading: loadingMetricas,
    refetch: refetchMetricas
  } = useMetricasQuery(filtroPeriodo, usuarioFiltro, fechaDesde, fechaHasta, authReady)

  // Cargar clientes solo para el contador
  const { data: clientes = [] } = useClientesQuery()

  // Objetivos del mes (migs 159-161). Siempre del mes corriente: las metas son
  // mensuales y NO siguen al chip de período del dashboard. Se pide sin id, así
  // el RPC devuelve los del usuario logueado.
  const { data: avanceMetas } = useAvanceMetasQuery(
    undefined,
    periodoMensual(),
    authReady && (isPreventista || isAdmin),
  )

  // Backup
  const { exportando, descargarJSON } = useBackup()

  const handleCambiarPeriodo = (nuevoPeriodo: string, nuevaFechaDesde?: string | null, nuevaFechaHasta?: string | null) => {
    setFiltroPeriodo(nuevoPeriodo)
    if (nuevoPeriodo === 'personalizado') {
      setFechaDesde(nuevaFechaDesde || null)
      setFechaHasta(nuevaFechaHasta || null)
    } else {
      setFechaDesde(null)
      setFechaHasta(null)
    }
  }

  return (
    <Suspense fallback={<LoadingState />}>
      <VistaDashboard
        metricas={metricas || {
          ventasPeriodo: 0,
          ventasEnCurso: 0,
          pedidosPeriodo: 0,
          pedidosEntregados: 0,
          pedidosEnCurso: 0,
          productosMasVendidos: [],
          clientesMasActivos: [],
          pedidosPorEstado: { pendiente: 0, asignado: 0, entregado: 0 },
          ventasPorDia: []
        }}
        loading={loadingMetricas}
        filtroPeriodo={filtroPeriodo}
        onCambiarPeriodo={handleCambiarPeriodo}
        onRefetch={refetchMetricas}
        onDescargarBackup={descargarJSON}
        exportando={exportando}
        isAdmin={isAdmin}
        isPreventista={isPreventista}
        isEncargado={isEncargado}
        totalClientes={clientes.length}
        avanceMetas={avanceMetas}
      />
    </Suspense>
  )
}
