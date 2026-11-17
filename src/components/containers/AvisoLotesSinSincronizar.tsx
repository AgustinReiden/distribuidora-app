/**
 * Aviso de una edición de compra cuyos vencimientos no se sincronizaron (STK-13,
 * #1542).
 *
 * Editar la compra y sincronizar sus lotes son dos llamadas. Si la segunda falla
 * con la compra ya guardada (y quizá bajada), un lote puede quedar con más
 * unidades que la compra: el stock cierra, pero los vencimientos no. Mientras no
 * haya una RPC que haga las dos cosas juntas, esto deja la falla a la vista y
 * permite repetir sólo la segunda llamada, sin volver a editar la compra.
 *
 * Es un componente aparte, y no está en el container, porque usa el cliente de
 * queries: sólo se monta cuando hay algo pendiente.
 */
import React, { useState } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { AlertTriangle } from 'lucide-react'
import { Button } from '../ui/Button'
import { reintentarSincronizarLotes } from '../../hooks/queries/useComprasQuery'
import type { LotesSinSincronizar } from '../../hooks/queries/useComprasQuery'
import { useNotification } from '../../contexts/NotificationContext'
import { useSucursal } from '../../contexts/SucursalContext'

interface AvisoLotesSinSincronizarProps {
  pendiente: LotesSinSincronizar
  /** Se sincronizó (o el usuario lo descartó): ya no hay nada pendiente. */
  onTerminar: () => void
}

export default function AvisoLotesSinSincronizar({ pendiente, onTerminar }: AvisoLotesSinSincronizarProps): React.ReactElement {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()
  const notify = useNotification()
  const [reintentando, setReintentando] = useState(false)
  const [falla, setFalla] = useState<string | null>(null)

  const reintentar = async () => {
    setReintentando(true)
    setFalla(null)
    try {
      const aviso = await reintentarSincronizarLotes(queryClient, currentSucursalId, pendiente)
      notify.success('Vencimientos sincronizados con la compra')
      if (aviso) notify.warning(aviso, { persist: true })
      onTerminar()
    } catch (err) {
      setFalla(err instanceof Error && err.message ? err.message : 'No se pudo sincronizar')
    } finally {
      setReintentando(false)
    }
  }

  return (
    <div
      role="alert"
      className="mx-4 mt-4 flex flex-col gap-2 rounded-lg border border-amber-300 bg-amber-50 p-3 text-sm text-amber-900 dark:border-amber-700 dark:bg-amber-900/20 dark:text-amber-200 sm:flex-row sm:items-center"
    >
      <AlertTriangle className="h-5 w-5 shrink-0" aria-hidden="true" />
      <div className="flex-1">
        <p className="font-medium">Los vencimientos de la compra #{pendiente.compraId} quedaron sin sincronizar.</p>
        <p>
          La compra se editó, pero sus lotes siguen como estaban: alguno puede tener más unidades que la compra.
          {falla ? ` Último intento: ${falla}` : ''}
        </p>
      </div>
      <div className="flex gap-2">
        <Button type="button" variant="primary" size="sm" onClick={reintentar} disabled={reintentando}>
          {reintentando ? 'Sincronizando...' : 'Reintentar'}
        </Button>
        <Button type="button" variant="secondary" size="sm" onClick={onTerminar} disabled={reintentando}>
          Descartar
        </Button>
      </div>
    </div>
  )
}
