import React, { lazy, Suspense, useCallback, useEffect, useState } from 'react'
import { Loader2 } from 'lucide-react'
import { fechaLocalISO } from '../../utils/formatters'
import { useReportePreventistasQuery } from '../../hooks/queries'
import { useNotification } from '../../contexts/NotificationContext'

const VistaComisiones = lazy(() => import('../vistas/VistaComisiones'))

function LoadingState(): React.ReactElement {
  return (
    <div className="flex items-center justify-center py-20">
      <Loader2 className="w-8 h-8 animate-spin text-blue-600" />
    </div>
  )
}

function getPrimerDiaMes(): string {
  const d = new Date()
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-01`
}

function getHoy(): string {
  return fechaLocalISO()
}

export default function ComisionesContainer(): React.ReactElement {
  const notify = useNotification()
  const [fechaDesde, setFechaDesde] = useState(getPrimerDiaMes)
  const [fechaHasta, setFechaHasta] = useState(getHoy)

  const {
    data: reporte = [],
    isLoading,
    error,
  } = useReportePreventistasQuery(fechaDesde, fechaHasta, true)

  useEffect(() => {
    if (error) {
      notify.error((error as Error).message || 'Error al cargar comisiones')
    }
  }, [error, notify])

  const handleFiltrar = useCallback((desde: string, hasta: string) => {
    setFechaDesde(desde)
    setFechaHasta(hasta)
  }, [])

  return (
    <Suspense fallback={<LoadingState />}>
      <VistaComisiones
        reporte={reporte}
        loading={isLoading}
        fechaDesde={fechaDesde}
        fechaHasta={fechaHasta}
        onFiltrar={handleFiltrar}
      />
    </Suspense>
  )
}
