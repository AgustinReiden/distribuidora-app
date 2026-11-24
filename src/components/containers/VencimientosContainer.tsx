/**
 * VencimientosContainer
 *
 * Orquesta el panel de vencimientos (migs 223/224/225). Ver y sacar de
 * circulación son dos permisos distintos: depósito mira lo que se le vence,
 * administración decide qué se descarta y qué se devuelve. El gate real está en
 * las RPCs — esto es la UI que lo acompaña.
 */
import { Suspense, useCallback, useState } from 'react'
import { Loader2 } from 'lucide-react'
import {
  useVencimientosQuery,
  useDarDeBajaLoteMutation,
  useRegistrarNotaCreditoLoteMutation,
} from '../../hooks/queries/useLotesQuery'
import { useParametrosVencimientoQuery } from '../../hooks/queries/usePoliticasComercialesQuery'
import { useRestanteDevolucionCompraQuery } from '../../hooks/queries/useNotasCreditoQuery'
import { useAuth } from '../../hooks/supabase/useAuth'
import { useNotification } from '../../contexts/NotificationContext'
import { useSucursal } from '../../contexts/SucursalContext'
import { lazyWithReload } from '../../utils/lazyWithReload'
import { formatPrecio } from '../../utils/formatters'
import { PAGINA_SUPABASE } from '../../utils/paginacion'

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
  // Por RPC y no por la fila de la política: depósito no la lee (#999).
  const { diasAlertaVencimiento, diasCriticoVencimiento } = useParametrosVencimientoQuery()
  const darDeBaja = useDarDeBajaLoteMutation()
  const devolver = useRegistrarNotaCreditoLoteMutation()
  // 1590-c (#1590): la compra del lote cuya devolución está abierta, y lo que le
  // queda por acreditar si tiene tope (un ajuste vigente).
  const [compraDevolucion, setCompraDevolucion] = useState<number | null>(null)
  const { data: restanteCompra = null } = useRestanteDevolucionCompraQuery(compraDevolucion)

  // El horizonte es el umbral amarillo, no "todo": traer los lotes cargados a
  // dos años para mostrar los veinte que importan es tráfico puro. Lo ya
  // vencido entra igual — su cuenta de días es negativa.
  //
  // El `+ 1` deja pasar el lote que cae justo en el umbral: la RPC compara con
  // `<=` sobre la fecha del servidor, y si el navegador está un día adelantado
  // el lote del borde no vendría y el semáforo lo perdería.
  const horizonte = diasAlertaVencimiento + 1
  const { data: lotes = [], isLoading, isFetching, isError, refetch } = useVencimientosQuery(horizonte)

  // `motivo` llega sólo para un lote que todavía no venció (#1558, 1558-b6).
  const handleDarDeBaja = useCallback(async (loteId: number, cantidad: number, motivo?: string) => {
    try {
      const res = await darDeBaja.mutateAsync({ loteId, cantidad, observaciones: motivo })
      notify.success(
        motivo
          ? `${cantidad} u. dadas de baja (${motivo}). Stock del producto: ${res.stock}.`
          : `${cantidad} u. dadas de baja por vencimiento. Stock del producto: ${res.stock}.`
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

  // gestion-B1: PostgREST corta la respuesta en 1.000 filas sin avisar, y la RPC ordena por fecha
  // (lo más urgente primero), así que lo que se cae es lo que vence más tarde. Con 1.000 lotes
  // justos, la lista y sus contadores pueden estar cortos: se dice, en vez de mostrarlos como completos.
  const listaCortada = lotes.length >= PAGINA_SUPABASE

  return (
    <>
    {listaCortada && (
      <p role="alert" className="mb-3 rounded-lg border border-amber-300 bg-amber-50 p-3 text-sm text-amber-900 dark:border-amber-700 dark:bg-amber-900/20 dark:text-amber-200">
        La lista se corta en {PAGINA_SUPABASE.toLocaleString('es-AR')} lotes: se muestran los que vencen primero y
        puede haber más que vencen después. Los contadores del panel no los cuentan.
      </p>
    )}
    <Suspense fallback={<LoadingState />}>
      <VistaVencimientos
        lotes={lotes}
        cargando={isLoading}
        // El error sólo reemplaza al listado si no hay nada que mostrar: un
        // refetch fallido con los lotes en caché deja los lotes (#1517, FRT-3).
        error={isError && lotes.length === 0}
        refrescando={isFetching}
        diasAlerta={diasAlertaVencimiento}
        diasCritico={diasCriticoVencimiento}
        puedeDarDeBaja={isAdminOrEncargado}
        darDeBajaPendiente={darDeBaja.isPending}
        devolucionPendiente={devolver.isPending}
        onRefrescar={() => void refetch()}
        onDarDeBaja={handleDarDeBaja}
        onDevolverAlProveedor={handleDevolverAlProveedor}
        nombreSucursal={currentSucursalNombre}
        onCompraDevolucion={setCompraDevolucion}
        restanteCompra={restanteCompra}
      />
    </Suspense>
    </>
  )
}
