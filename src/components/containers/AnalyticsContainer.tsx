/**
 * AnalyticsContainer
 *
 * Container para el Centro de Análisis.
 * Maneja el estado de exportación y delega la UI a VistaAnalytics.
 */
import React, { lazy, Suspense, useState, useCallback } from 'react'
import { Loader2 } from 'lucide-react'
import { exportarBI } from '../../services/analyticsExport'

const VistaAnalytics = lazy(() => import('../vistas/VistaAnalytics'))

function LoadingState() {
  return (
    <div className="flex items-center justify-center py-20">
      <Loader2 className="w-8 h-8 animate-spin text-blue-600" />
    </div>
  )
}

export default function AnalyticsContainer(): React.ReactElement {
  const [exportando, setExportando] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [exito, setExito] = useState(false)

  const handleExportBI = useCallback(async (desde: string, hasta: string) => {
    setExportando(true)
    setError(null)
    setExito(false)
    try {
      await exportarBI(desde, hasta)
      setExito(true)
      setTimeout(() => setExito(false), 5000)
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Error desconocido al exportar')
    } finally {
      setExportando(false)
    }
  }, [])

  return (
    <Suspense fallback={<LoadingState />}>
      <VistaAnalytics
        onExportBI={handleExportBI}
        exportando={exportando}
        error={error}
        exito={exito}
      />
    </Suspense>
  )
}
