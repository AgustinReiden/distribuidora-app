/**
 * ConfiguracionContainer
 *
 * Pantalla de políticas comerciales por sucursal (mig 204). Solo admin/encargado
 * — el gate real está en el RPC y en la RLS; esto es la UI que lo acompaña.
 */
import { Suspense, useState, useCallback } from 'react'
import { Loader2 } from 'lucide-react'
import {
  usePoliticasComercialesQuery,
  useActualizarMontoMinimoMutation,
  useImpactoMinimoQuery,
} from '../../hooks/queries/usePoliticasComercialesQuery'
import { useNotification } from '../../contexts/NotificationContext'
import { useSucursal } from '../../contexts/SucursalContext'
import { lazyWithReload } from '../../utils/lazyWithReload'

const VistaConfiguracion = lazyWithReload(() => import('../vistas/VistaConfiguracion'))

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
  const { politicas, isLoading } = usePoliticasComercialesQuery()
  const actualizar = useActualizarMontoMinimoMutation()

  // Lo que el usuario está tipeando, para poder mostrarle el impacto ANTES de
  // guardar. Arranca en el valor vigente.
  const [montoTipeado, setMontoTipeado] = useState<number>(politicas.montoMinimoPedido)
  const { data: impacto, isFetching: impactoCargando } = useImpactoMinimoQuery(montoTipeado)

  const handleGuardar = useCallback(async (monto: number) => {
    try {
      await actualizar.mutateAsync(monto)
      notify.success(
        monto > 0
          ? `Compra mínima fijada en $${monto.toLocaleString('es-AR')}`
          : 'Compra mínima desactivada'
      )
    } catch (err) {
      notify.error(err instanceof Error ? err.message : 'No se pudo guardar la compra mínima')
    }
  }, [actualizar, notify])

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
      />
    </Suspense>
  )
}
