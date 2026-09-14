import React, { Suspense, useCallback, useEffect, useState } from 'react'
import { Loader2 } from 'lucide-react'
import { fechaLocalISO } from '../../utils/formatters'
import { useRecorridos } from '../../hooks/supabase'
import { useAuthData } from '../../contexts/AuthDataContext'
import { useNotification } from '../../contexts/NotificationContext'
import { supabase } from '../../lib/supabase'
import type { EstadisticasRecorridos } from '../../types'
import { lazyWithReload } from '../../utils/lazyWithReload'

const VistaRecorridos = lazyWithReload(() => import('../vistas/VistaRecorridos'))

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
  const { isAdmin } = useAuthData()
  const notify = useNotification()
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

  // Reparar una ruta vieja. Hasta la mig 234 el trigger de entrega no miraba
  // `pedidos.total`, asi que toda ruta con una salvedad quedo con
  // `total_facturado` inflado y "Pendiente" mintiendo. El RPC recalcula los
  // cuatro contadores desde las paradas y es idempotente.
  const handleRecalcular = useCallback(async (recorridoId: string) => {
    const { data, error } = await supabase.rpc('recalcular_recorrido', {
      p_recorrido_id: parseInt(recorridoId, 10),
    })

    if (error || !(data as { success?: boolean } | null)?.success) {
      notify.error(error?.message || 'No se pudo recalcular el recorrido')
      return
    }

    notify.success('Totales del recorrido recalculados')
    await cargarRecorridos(fechaSeleccionada)
  }, [cargarRecorridos, fechaSeleccionada, notify])

  return (
    <Suspense fallback={<LoadingState />}>
      <VistaRecorridos
        recorridos={recorridos}
        loading={loading || loadingStats}
        fechaSeleccionada={fechaSeleccionada}
        estadisticas={estadisticas}
        onRefresh={handleRefresh}
        onFechaChange={handleFechaChange}
        onRecalcular={isAdmin ? handleRecalcular : undefined}
      />
    </Suspense>
  )
}
