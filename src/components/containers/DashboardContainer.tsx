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

  // Cargar métricas bajo demanda
  const {
    data: metricas,
    isLoading: loadingMetricas,
    refetch: refetchMetricas
  } = useMetricasQuery('mes', usuarioFiltro)

  // Cargar clientes solo para el contador
  const { data: clientes = [] } = useClientesQuery()

  // Backup
  const { exportando, descargarJSON } = useBackup()

  // Estado local para el filtro de periodo
  const [filtroPeriodo, setFiltroPeriodo] = React.useState('mes')

  const handleCambiarPeriodo = (nuevoPeriodo: string) => {
    setFiltroPeriodo(nuevoPeriodo)
    // El hook se actualizará automáticamente
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
