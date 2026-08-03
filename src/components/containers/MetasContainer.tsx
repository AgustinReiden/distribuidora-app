import React, { lazy, Suspense, useEffect, useState } from 'react'
import { Loader2 } from 'lucide-react'
import { useRendimientoPreventistasQuery, periodoMensual } from '../../hooks/queries'
import { useAuthData } from '../../contexts/AuthDataContext'
import { useNotification } from '../../contexts/NotificationContext'
import { useResetOnSucursalChange } from '../../hooks/useResetOnSucursalChange'

const VistaMetasPreventistas = lazy(() => import('../vistas/VistaMetasPreventistas'))
const ModalMetasPreventista = lazy(() => import('../modals/ModalMetasPreventista'))

function LoadingState(): React.ReactElement {
  return (
    <div className="flex items-center justify-center py-20">
      <Loader2 className="w-8 h-8 animate-spin text-blue-600" />
    </div>
  )
}

export default function MetasContainer(): React.ReactElement {
  const notify = useNotification()
  const { isAdmin } = useAuthData()
  const [periodo, setPeriodo] = useState(periodoMensual)
  const [modalOpen, setModalOpen] = useState(false)

  const { data: resultado, isLoading, error } = useRendimientoPreventistasQuery(periodo, isAdmin)

  useResetOnSucursalChange(() => {
    setModalOpen(false)
  })

  useEffect(() => {
    if (error) notify.error((error as Error).message || 'Error al cargar el rendimiento')
  }, [error, notify])

  return (
    <>
      <Suspense fallback={<LoadingState />}>
        <VistaMetasPreventistas
          resultado={resultado}
          loading={isLoading}
          periodo={periodo}
          onCambiarPeriodo={setPeriodo}
          onAbrirObjetivos={() => setModalOpen(true)}
        />
      </Suspense>

      {modalOpen && (
        <Suspense fallback={null}>
          <ModalMetasPreventista periodo={periodo} onClose={() => setModalOpen(false)} />
        </Suspense>
      )}
    </>
  )
}
