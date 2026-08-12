import React, { Suspense, useEffect, useState } from 'react'
import { Loader2 } from 'lucide-react'
import {
  useRendimientoPreventistasQuery,
  useDesactivarMetaPreventistaMutation,
  periodoMensual,
} from '../../hooks/queries'
import type { AvanceMeta } from '../../hooks/queries'
import { useAuthData } from '../../contexts/AuthDataContext'
import { useNotification } from '../../contexts/NotificationContext'
import { useResetOnSucursalChange } from '../../hooks/useResetOnSucursalChange'
import { lazyWithReload } from '../../utils/lazyWithReload'

const VistaMetasPreventistas = lazyWithReload(() => import('../vistas/VistaMetasPreventistas'))
const ModalMetasPreventista = lazyWithReload(() => import('../modals/ModalMetasPreventista'))

function LoadingState(): React.ReactElement {
  return (
    <div className="flex items-center justify-center py-20">
      <Loader2 className="w-8 h-8 animate-spin text-blue-600" />
    </div>
  )
}

/** Meta que se está editando: el avance + a quién pertenece. */
export interface MetaEnEdicion {
  meta: AvanceMeta
  preventistaId: string
}

export default function MetasContainer(): React.ReactElement {
  const notify = useNotification()
  const { isAdmin } = useAuthData()
  const [periodo, setPeriodo] = useState(periodoMensual)
  const [modalOpen, setModalOpen] = useState(false)
  const [enEdicion, setEnEdicion] = useState<MetaEnEdicion | null>(null)

  const { data: resultado, isLoading, error } = useRendimientoPreventistasQuery(periodo, isAdmin)
  const bajaMut = useDesactivarMetaPreventistaMutation()

  useResetOnSucursalChange(() => {
    setModalOpen(false)
    setEnEdicion(null)
  })

  useEffect(() => {
    if (error) notify.error((error as Error).message || 'Error al cargar el rendimiento')
  }, [error, notify])

  const handleEditar = (meta: AvanceMeta, preventistaId: string): void => {
    setEnEdicion({ meta, preventistaId })
    setModalOpen(true)
  }

  const handleEliminar = async (meta: AvanceMeta): Promise<void> => {
    try {
      await bajaMut.mutateAsync(meta.id)
      notify.success('Objetivo eliminado')
    } catch (e) {
      notify.error((e as Error).message || 'No se pudo eliminar el objetivo')
    }
  }

  const cerrarModal = (): void => {
    setModalOpen(false)
    setEnEdicion(null)
  }

  return (
    <>
      <Suspense fallback={<LoadingState />}>
        <VistaMetasPreventistas
          resultado={resultado}
          loading={isLoading}
          periodo={periodo}
          onCambiarPeriodo={setPeriodo}
          onAbrirObjetivos={() => { setEnEdicion(null); setModalOpen(true) }}
          onEditarMeta={handleEditar}
          onEliminarMeta={handleEliminar}
          eliminando={bajaMut.isPending}
        />
      </Suspense>

      {modalOpen && (
        <Suspense fallback={null}>
          <ModalMetasPreventista
            periodo={periodo}
            edicion={enEdicion}
            onClose={cerrarModal}
          />
        </Suspense>
      )}
    </>
  )
}
