/**
 * DashboardContainer
 *
 * Container que carga datos del dashboard bajo demanda usando TanStack Query.
 * Solo carga métricas cuando el usuario navega a esta vista.
 */
import React, { lazy, Suspense } from 'react'
import { Loader2 } from 'lucide-react'
import { useMetricasQuery, useClientesQuery } from '../../hooks/queries'
import { useAuthData } from '../../contexts/AuthDataContext'
import { useBackup } from '../../hooks/supabase'

const VistaDashboard = lazy(() => import('../vistas/VistaDashboard'))

function LoadingState() {
  return (
    <div className="flex items-center justify-center py-20">
      <Loader2 className="w-8 h-8 animate-spin text-blue-600" />
    </div>
  )
}

export default function DashboardContainer(): React.ReactElement {
  const { user, isAdmin, isPreventista } = useAuthData()

  // Determinar si debe filtrar por usuario
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
  } = useMetricasQuery(filtroPeriodo, usuarioFiltro, fechaDesde, fechaHasta)

  // Cargar clientes solo para el contador
  const { data: clientes = [] } = useClientesQuery()

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
          pedidosPeriodo: 0,
          productosMasVendidos: [],
          clientesMasActivos: [],
          pedidosPorEstado: { pendiente: 0, en_preparacion: 0, asignado: 0, entregado: 0 },
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
        totalClientes={clientes.length}
      />
    </Suspense>
  )
}
