/**
 * VencimientosContainer
 *
 * Orquesta el panel de vencimientos (migs 223/224/225). Ver y sacar de
 * circulación son dos permisos distintos: depósito mira lo que se le vence,
 * administración decide qué se descarta y qué se devuelve. El gate real está en
 * las RPCs — esto es la UI que lo acompaña.
 */
import { Suspense, useCallback } from 'react'
import { Loader2 } from 'lucide-react'
import {
  useVencimientosQuery,
  useDarDeBajaLoteMutation,
  useRegistrarNotaCreditoLoteMutation,
} from '../../hooks/queries/useLotesQuery'
import { usePoliticasComercialesQuery } from '../../hooks/queries/usePoliticasComercialesQuery'
import { useAuth } from '../../hooks/supabase/useAuth'
import { useNotification } from '../../contexts/NotificationContext'
import { useSucursal } from '../../contexts/SucursalContext'
import { lazyWithReload } from '../../utils/lazyWithReload'
import { formatPrecio } from '../../utils/formatters'

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
  const devolver = useRegistrarNotaCreditoLoteMutation()

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

  // Espejo de handleDarDeBaja, y a propósito por una RPC distinta: la
  // devolución acredita contra la factura de compra y NO escribe en
  // `mermas_stock` — contar como merma lo que el proveedor paga ensucia la
  // valorización (issue #564).
  const handleDevolverAlProveedor = useCallback(async (
    loteId: number,
    cantidad: number,
    numeroNota: string,
    motivo: string,
  ) => {
    try {
      const res = await devolver.mutateAsync({ loteId, cantidad, numeroNota, motivo })
      notify.success(
        `${cantidad} u. devueltas al proveedor. Nota de crédito por ${formatPrecio(res.total)}. ` +
        `Stock del producto: ${res.stock}.`
      )
    } catch (err) {
      notify.error(err instanceof Error ? err.message : 'No se pudo registrar la nota de crédito')
    }
  }, [devolver, notify])

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
        devolucionPendiente={devolver.isPending}
        onRefrescar={() => void refetch()}
        onDarDeBaja={handleDarDeBaja}
        onDevolverAlProveedor={handleDevolverAlProveedor}
        nombreSucursal={currentSucursalNombre}
      />
    </Suspense>
  )
}
