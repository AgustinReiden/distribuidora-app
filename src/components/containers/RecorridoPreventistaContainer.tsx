/**
 * RecorridoPreventistaContainer
 *
 * Container para la optimización de recorridos de preventistas.
 * Usa el mismo webhook n8n que el recorrido de transportistas.
 */
import React, { lazy, Suspense, useCallback } from 'react'
import { Loader2 } from 'lucide-react'
import { useClientesQuery, usePreventistasQuery } from '../../hooks/queries'
import { useOptimizarRutaPreventista } from '../../hooks/useOptimizarRutaPreventista'
import type { ClienteDB } from '../../types'

const ModalOptimizarRutaPreventista = lazy(() => import('../modals/ModalOptimizarRutaPreventista'))

function LoadingState() {
  return (
    <div className="flex items-center justify-center py-20">
      <Loader2 className="w-8 h-8 animate-spin text-blue-600" />
    </div>
  )
}

export default function RecorridoPreventistaContainer(): React.ReactElement {
  const { data: clientes = [] } = useClientesQuery()
  const { data: preventistas = [] } = usePreventistasQuery()
  const { loading, rutaOptimizada, error, optimizarRuta, limpiarRuta } = useOptimizarRutaPreventista()

  const handleOptimizar = useCallback((preventistaId: string, clientesSeleccionados: ClienteDB[]) => {
    optimizarRuta(preventistaId, clientesSeleccionados)
  }, [optimizarRuta])

  const handleClose = useCallback(() => {
    limpiarRuta()
    window.history.back()
  }, [limpiarRuta])

  return (
    <Suspense fallback={<LoadingState />}>
      <ModalOptimizarRutaPreventista
        preventistas={preventistas}
        clientes={clientes}
        onOptimizar={handleOptimizar}
        onClose={handleClose}
        loading={loading}
        rutaOptimizada={rutaOptimizada}
        error={error}
      />
    </Suspense>
  )
}
