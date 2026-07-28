import React, { lazy, Suspense, useCallback } from 'react'
import { Loader2 } from 'lucide-react'
import {
  useRevisionHorariosQuery,
  useGuardarHorariosMasivoMutation,
  type HorarioMasivoItem,
} from '../../hooks/queries/useRevisionHorariosQuery'
import { useNotification } from '../../contexts/NotificationContext'

const VistaRevisionHorarios = lazy(() => import('../vistas/VistaRevisionHorarios'))

function LoadingState(): React.ReactElement {
  return (
    <div className="flex items-center justify-center py-20">
      <Loader2 className="w-8 h-8 animate-spin text-blue-600" />
    </div>
  )
}

export default function RevisionHorariosContainer(): React.ReactElement {
  const notify = useNotification()
  const { pendientes, isLoading } = useRevisionHorariosQuery()
  const guardar = useGuardarHorariosMasivoMutation()

  const onGuardar = useCallback(async (items: HorarioMasivoItem[]) => {
    try {
      const n = await guardar.mutateAsync(items)
      notify.success(
        n === 1 ? '1 horario normalizado' : `${n} horarios normalizados`,
      )
    } catch (e) {
      notify.error((e as Error).message || 'No se pudieron guardar los horarios')
    }
  }, [guardar, notify])

  return (
    <Suspense fallback={<LoadingState />}>
      <VistaRevisionHorarios
        pendientes={pendientes}
        loading={isLoading}
        guardando={guardar.isPending}
        onGuardar={onGuardar}
      />
    </Suspense>
  )
}
