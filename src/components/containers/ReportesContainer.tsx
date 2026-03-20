import React, { lazy, Suspense, useCallback, useEffect, useState } from 'react'
import { Loader2 } from 'lucide-react'
import { useClientesQuery, useReportePreventistasQuery } from '../../hooks/queries'
import { useNotification } from '../../contexts/NotificationContext'
import type { ClienteDB } from '../../types'

const VistaReportes = lazy(() => import('../vistas/VistaReportes'))
const ModalFichaCliente = lazy(() => import('../modals/ModalFichaCliente'))

function LoadingState(): React.ReactElement {
  return (
    <div className="flex items-center justify-center py-20">
      <Loader2 className="w-8 h-8 animate-spin text-blue-600" />
    </div>
  )
}

interface ReportesFiltros {
  fechaDesde: string | null;
  fechaHasta: string | null;
}

export default function ReportesContainer(): React.ReactElement {
  const notify = useNotification()
  const [filtros, setFiltros] = useState<ReportesFiltros>({
    fechaDesde: null,
    fechaHasta: null
  })
  const [reporteInicializado, setReporteInicializado] = useState(false)
  const [clienteFichaId, setClienteFichaId] = useState<string | null>(null)
  const [modalFichaOpen, setModalFichaOpen] = useState(false)

  const {
    data: reportePreventistas = [],
    isLoading,
    error
  } = useReportePreventistasQuery(filtros.fechaDesde, filtros.fechaHasta, reporteInicializado)

  const { data: clientes = [] } = useClientesQuery()

  useEffect(() => {
    if (error) {
      notify.error((error as Error).message || 'Error al cargar reportes')
    }
  }, [error, notify])

  const handleCalcularReporte = useCallback(async (fechaDesde: string | null, fechaHasta: string | null) => {
    setFiltros({ fechaDesde, fechaHasta })
    setReporteInicializado(true)
  }, [])

  const handleVerFichaCliente = useCallback((cliente: ClienteDB) => {
    setClienteFichaId(cliente.id)
    setModalFichaOpen(true)
  }, [])

  return (
    <>
      <Suspense fallback={<LoadingState />}>
        <VistaReportes
          reportePreventistas={reportePreventistas}
          reporteInicializado={reporteInicializado}
          loading={isLoading}
          onCalcularReporte={handleCalcularReporte}
          onVerFichaCliente={handleVerFichaCliente}
        />
      </Suspense>

      {modalFichaOpen && clienteFichaId && (
        <Suspense fallback={null}>
          <ModalFichaCliente
            cliente={clientes.find(cliente => cliente.id === clienteFichaId) || null}
            onClose={() => {
              setModalFichaOpen(false)
              setClienteFichaId(null)
            }}
          />
        </Suspense>
      )}
    </>
  )
}
