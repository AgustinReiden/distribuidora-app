import React, { Suspense, useCallback, useEffect, useState } from 'react'
import { Loader2 } from 'lucide-react'
import { useClienteQuery, useClientesQuery, useReportePreventistasQuery } from '../../hooks/queries'
import { useNotification } from '../../contexts/NotificationContext'
import type { ClienteDB } from '../../types'
import { lazyWithReload } from '../../utils/lazyWithReload'

const VistaReportes = lazyWithReload(() => import('../vistas/VistaReportes'))
const ModalFichaCliente = lazyWithReload(() => import('../modals/ModalFichaCliente'))

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

  // La ficha se resuelve por ID contra la base, NO buscando en `clientes`: esa
  // lista ya no trae inactivos, y un cliente desactivado con deuda sigue
  // apareciendo en el panel de deudores. Buscarlo en la lista devolvia null y
  // la ficha se abria vacia justo para el caso que mas importa mirar.
  const { data: clienteFicha } = useClienteQuery(clienteFichaId ?? '')

  useEffect(() => {
    if (error) {
      notify.error((error as Error).message || 'Error al cargar reportes')
    }
  }, [error, notify])

  const handleCalcularReporte = useCallback(async (fechaDesde: string | null, fechaHasta: string | null) => {
    setFiltros({ fechaDesde, fechaHasta })
    setReporteInicializado(true)
  }, [])

  // `clientes.id` es bigint: PostgREST lo devuelve como number en runtime aunque
  // ClienteDB lo tipe string, y el RPC de ventas también. Se guarda y se compara
  // siempre como string para que las dos fuentes coincidan.
  const handleVerFichaClienteId = useCallback((clienteId: string) => {
    setClienteFichaId(String(clienteId))
    setModalFichaOpen(true)
  }, [])

  const handleVerFichaCliente = useCallback((cliente: ClienteDB) => {
    handleVerFichaClienteId(String(cliente.id))
  }, [handleVerFichaClienteId])

  return (
    <>
      <Suspense fallback={<LoadingState />}>
        <VistaReportes
          reportePreventistas={reportePreventistas}
          reporteInicializado={reporteInicializado}
          loading={isLoading}
          onCalcularReporte={handleCalcularReporte}
          onVerFichaCliente={handleVerFichaCliente}
          onVerFichaClienteId={handleVerFichaClienteId}
        />
      </Suspense>

      {modalFichaOpen && clienteFichaId && (
        <Suspense fallback={null}>
          <ModalFichaCliente
            cliente={clienteFicha ?? clientes.find(cliente => String(cliente.id) === clienteFichaId) ?? null}
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
