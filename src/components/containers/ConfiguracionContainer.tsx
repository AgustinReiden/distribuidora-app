/**
 * ConfiguracionContainer
 *
 * Pantalla de políticas comerciales por sucursal (mig 204). Solo admin/encargado
 * — el gate real está en el RPC y en la RLS; esto es la UI que lo acompaña.
 */
import { Suspense, useState, useEffect, useCallback } from 'react'
import { Loader2 } from 'lucide-react'
import {
  usePoliticasComercialesQuery,
  useActualizarMontoMinimoMutation,
  useActualizarComisionesDefaultMutation,
  useActualizarAlertasVencimientoMutation,
  useActualizarMostrarSinStockMutation,
  useActualizarVentanaPrecioAnteriorMutation,
  useActualizarAlertasCombosMutation,
  useImpactoMinimoQuery,
} from '../../hooks/queries/usePoliticasComercialesQuery'
import { useNotification } from '../../contexts/NotificationContext'
import { useSucursal } from '../../contexts/SucursalContext'
import { useAuthData } from '../../contexts/AuthDataContext'
import { lazyWithReload } from '../../utils/lazyWithReload'
import { formatPrecio } from '../../utils/formatters'

const VistaConfiguracion = lazyWithReload(() => import('../vistas/VistaConfiguracion'))
const PanelImpuestosInternos = lazyWithReload(() => import('../vistas/configuracion/PanelImpuestosInternos'))

function LoadingState() {
  return (
    <div className="flex justify-center py-12">
      <Loader2 className="w-6 h-6 animate-spin text-stone-400" />
    </div>
  )
}

export default function ConfiguracionContainer() {
  const notify = useNotification()
  const { currentSucursalNombre } = useSucursal()
  const { isAdmin } = useAuthData()
  const { politicas, isLoading } = usePoliticasComercialesQuery()
  const actualizar = useActualizarMontoMinimoMutation()
  const actualizarComisiones = useActualizarComisionesDefaultMutation()
  const actualizarAlertas = useActualizarAlertasVencimientoMutation()
  const actualizarMostrarSinStock = useActualizarMostrarSinStockMutation()
  const actualizarVentana = useActualizarVentanaPrecioAnteriorMutation()
  const actualizarAlertasCombos = useActualizarAlertasCombosMutation()

  // Lo que el usuario está tipeando, para poder mostrarle el impacto ANTES de
  // guardar. Arranca en el valor vigente.
  const [montoTipeado, setMontoTipeado] = useState<number>(politicas.montoMinimoPedido)
  const { data: impacto, isFetching: impactoCargando } = useImpactoMinimoQuery(montoTipeado)

  // El mínimo vigente llega después del primer render (y cambia al cambiar de
  // sucursal): sin esto el impacto se calcula con el valor de la sucursal
  // anterior, o no se calcula si arrancó en 0.
  useEffect(() => {
    setMontoTipeado(politicas.montoMinimoPedido)
  }, [politicas.montoMinimoPedido])

  const handleGuardar = useCallback(async (monto: number) => {
    try {
      await actualizar.mutateAsync(monto)
      notify.success(
        monto > 0
          ? `Compra mínima fijada en ${formatPrecio(monto)}`
          : 'Compra mínima desactivada'
      )
    } catch (err) {
      notify.error(err instanceof Error ? err.message : 'No se pudo guardar la compra mínima')
    }
  }, [actualizar, notify])

  const handleGuardarComisiones = useCallback(async (pctPreventista: number, pctOtros: number) => {
    try {
      await actualizarComisiones.mutateAsync({ pctPreventista, pctOtros })
      notify.success(`Comisión por defecto: ${pctPreventista}% preventistas, ${pctOtros}% el resto`)
    } catch (err) {
      notify.error(err instanceof Error ? err.message : 'No se pudieron guardar las comisiones')
    }
  }, [actualizarComisiones, notify])

  const handleGuardarAlertas = useCallback(async (diasAlerta: number, diasCritico: number) => {
    try {
      await actualizarAlertas.mutateAsync({ diasAlerta, diasCritico })
      notify.success(
        diasAlerta === 0 && diasCritico === 0
          ? 'Solo se van a avisar los lotes ya vencidos'
          : `Aviso de vencimiento: amarillo a ${diasAlerta} dias, rojo a ${diasCritico}`
      )
    } catch (err) {
      notify.error(err instanceof Error ? err.message : 'No se pudieron guardar los avisos')
    }
  }, [actualizarAlertas, notify])

  const handleGuardarMostrarSinStock = useCallback(async (mostrar: boolean) => {
    try {
      await actualizarMostrarSinStock.mutateAsync(mostrar)
      notify.success(
        mostrar
          ? 'Los productos sin stock se muestran (sin poder agregarlos)'
          : 'Los productos sin stock ya no se ofrecen al tomar pedidos'
      )
    } catch (err) {
      notify.error(err instanceof Error ? err.message : 'No se pudo guardar la configuración')
    }
  }, [actualizarMostrarSinStock, notify])

  const handleGuardarVentana = useCallback(async (horas: number) => {
    try {
      await actualizarVentana.mutateAsync(horas)
      notify.success(
        horas === 0
          ? 'Sin tolerancia: un pedido cargado sin señal antes de un cambio de precio se rechaza'
          : `Ventana de precio anterior: ${horas} h`
      )
    } catch (err) {
      notify.error(err instanceof Error ? err.message : 'No se pudo guardar la configuración')
    }
  }, [actualizarVentana, notify])

  const handleGuardarAlertasCombos = useCallback(async (margenMinimoPct: number, descuentoMaximoPct: number) => {
    try {
      await actualizarAlertasCombos.mutateAsync({ margenMinimoPct, descuentoMaximoPct })
      notify.success(`Alertas de combos: margen mínimo ${margenMinimoPct}%, descuento máximo ${descuentoMaximoPct}%`)
    } catch (err) {
      notify.error(err instanceof Error ? err.message : 'No se pudo guardar la configuración')
    }
  }, [actualizarAlertasCombos, notify])

  return (
    <Suspense fallback={<LoadingState />}>
      <VistaConfiguracion
        montoMinimoActual={politicas.montoMinimoPedido}
        cargando={isLoading}
        guardando={actualizar.isPending}
        impacto={impacto}
        impactoCargando={impactoCargando}
        onMontoTipeado={setMontoTipeado}
        onGuardar={handleGuardar}
        nombreSucursal={currentSucursalNombre}
        comisionPctPreventista={politicas.comisionPctPreventista}
        comisionPctOtros={politicas.comisionPctOtros}
        guardandoComisiones={actualizarComisiones.isPending}
        onGuardarComisiones={handleGuardarComisiones}
        diasAlertaVencimiento={politicas.diasAlertaVencimiento}
        diasCriticoVencimiento={politicas.diasCriticoVencimiento}
        guardandoAlertas={actualizarAlertas.isPending}
        onGuardarAlertas={handleGuardarAlertas}
        mostrarSinStock={politicas.mostrarSinStock}
        guardandoMostrarSinStock={actualizarMostrarSinStock.isPending}
        onGuardarMostrarSinStock={handleGuardarMostrarSinStock}
        ventanaPrecioAnteriorHoras={politicas.ventanaPrecioAnteriorHoras}
        puedeEditarVentana={isAdmin}
        guardandoVentana={actualizarVentana.isPending}
        onGuardarVentana={handleGuardarVentana}
        comboMargenMinimoPct={politicas.comboMargenMinimoPct}
        comboDescuentoMaximoPct={politicas.comboDescuentoMaximoPct}
        puedeEditarAlertasCombos={isAdmin}
        guardandoAlertasCombos={actualizarAlertasCombos.isPending}
        onGuardarAlertasCombos={handleGuardarAlertasCombos}
        extra={(
          <Suspense fallback={<LoadingState />}>
            <PanelImpuestosInternos esAdmin={isAdmin} />
          </Suspense>
        )}
      />
    </Suspense>
  )
}
