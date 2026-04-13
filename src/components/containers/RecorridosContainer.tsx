import React, { lazy, Suspense, useCallback, useEffect, useState } from 'react'
import { Loader2 } from 'lucide-react'
import { fechaLocalISO } from '../../utils/formatters'
import { useRecorridos } from '../../hooks/supabase'
import type { EstadisticasRecorridos } from '../../types'

const VistaRecorridos = lazy(() => import('../vistas/VistaRecorridos'))

function LoadingState(): React.ReactElement {
  return (
    <div className="flex items-center justify-center py-20">
      <Loader2 className="w-8 h-8 animate-spin text-blue-600" />
    </div>
  )
}

function getToday(): string {
  return fechaLocalISO()
}

export default function RecorridosContainer(): React.ReactElement {
  const {
    recorridos,
    loading,
    fetchRecorridosHoy,
    fetchRecorridosPorFecha,
    getEstadisticasRecorridos
  } = useRecorridos()

  const [fechaSeleccionada, setFechaSeleccionada] = useState(getToday)
  const [estadisticas, setEstadisticas] = useState<EstadisticasRecorridos | null>(null)
  const [loadingStats, setLoadingStats] = useState(false)

  const cargarRecorridos = useCallback(async (fecha: string) => {
    const hoy = getToday()
    setLoadingStats(true)

    try {
      if (fecha === hoy) {
        await fetchRecorridosHoy()
      } else {
        await fetchRecorridosPorFecha(fecha)
      }

      const nextStats = await getEstadisticasRecorridos(fecha, fecha)
      setEstadisticas(nextStats)
    } finally {
      setLoadingStats(false)
    }
  }, [fetchRecorridosHoy, fetchRecorridosPorFecha, getEstadisticasRecorridos])

  useEffect(() => {
    void cargarRecorridos(fechaSeleccionada)
  }, [cargarRecorridos, fechaSeleccionada])

  const handleRefresh = useCallback(async () => {
    await cargarRecorridos(fechaSeleccionada)
  }, [cargarRecorridos, fechaSeleccionada])

  const handleFechaChange = useCallback(async (fecha: string) => {
    setFechaSeleccionada(fecha)
  }, [])

  return (
    <Suspense fallback={<LoadingState />}>
      <VistaRecorridos
        recorridos={recorridos}
        loading={loading || loadingStats}
        fechaSeleccionada={fechaSeleccionada}
        estadisticas={estadisticas}
        onRefresh={handleRefresh}
        onFechaChange={handleFechaChange}
      />
    </Suspense>
  )
}
