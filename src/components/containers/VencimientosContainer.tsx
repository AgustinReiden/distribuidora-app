/**
 * VencimientosContainer
 *
 * Orquesta el panel de vencimientos (migs 223/224/225). Ver y dar de baja son
 * dos permisos distintos: depósito mira lo que se le vence, administración
 * decide qué se descarta. El gate real está en las RPCs — esto es la UI que lo
 * acompaña.
 */
import { Suspense, useCallback } from 'react'
import { Loader2 } from 'lucide-react'
import { useVencimientosQuery, useDarDeBajaLoteMutation } from '../../hooks/queries/useLotesQuery'
import { usePoliticasComercialesQuery } from '../../hooks/queries/usePoliticasComercialesQuery'
import { useAuth } from '../../hooks/supabase/useAuth'
import { useNotification } from '../../contexts/NotificationContext'
import { useSucursal } from '../../contexts/SucursalContext'
import { lazyWithReload } from '../../utils/lazyWithReload'

const VistaVencimientos = lazyWithReload(() => import('../vistas/VistaVencimientos'))

function LoadingState() {
  return (
    <div className="flex justify-center py-12">
      <Loader2 className="w-6 h-6 animate-spin text-stone-400" />
    </div>
  )
}

export default function VencimientosContainer() {
  const notify = useNotification()
  const { currentSucursalNombre } = useSucursal()
  const { isAdminOrEncargado } = useAuth()
  const { politicas } = usePoliticasComercialesQuery()
  const darDeBaja = useDarDeBajaLoteMutation()

  // El horizonte es el umbral amarillo, no "todo": traer los lotes cargados a
  // dos años para mostrar los veinte que importan es tráfico puro. Lo ya
  // vencido entra igual — su cuenta de días es negativa.
  //
  // El `+ 1` deja pasar el lote que cae justo en el umbral: la RPC compara con
  // `<=` sobre la fecha del servidor, y si el navegador está un día adelantado
  // el lote del borde no vendría y el semáforo lo perdería.
  const horizonte = politicas.diasAlertaVencimiento + 1
  const { data: lotes = [], isLoading, isFetching, refetch } = useVencimientosQuery(horizonte)

  const handleDarDeBaja = useCallback(async (loteId: number, cantidad: number) => {
    try {
      const res = await darDeBaja.mutateAsync({ loteId, cantidad })
      notify.success(
        `${cantidad} u. dadas de baja por vencimiento. Stock del producto: ${res.stock}.`
      )
    } catch (err) {
      notify.error(err instanceof Error ? err.message : 'No se pudo dar de baja el lote')
    }
  }, [darDeBaja, notify])

  return (
    <Suspense fallback={<LoadingState />}>
      <VistaVencimientos
        lotes={lotes}
        cargando={isLoading}
        refrescando={isFetching}
        diasAlerta={politicas.diasAlertaVencimiento}
        diasCritico={politicas.diasCriticoVencimiento}
        puedeDarDeBaja={isAdminOrEncargado}
        darDeBajaPendiente={darDeBaja.isPending}
        onRefrescar={() => void refetch()}
        onDarDeBaja={handleDarDeBaja}
        nombreSucursal={currentSucursalNombre}
      />
    </Suspense>
  )
}
