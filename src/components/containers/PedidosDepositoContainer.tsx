/**
 * /pedidos de depósito (#782). App.tsx monta este container en vez de
 * PedidosContainer cuando el rol es depósito: así no dispara ninguna de las
 * queries de pedidos, que traen `total` y que la RLS igual le devuelve vacías.
 * Todo sale de `hojas_de_ruta_deposito` (mig 305), que no trae plata.
 */
import { useCallback, useState, type ReactElement } from 'react'
import VistaPedidosDeposito from '../vistas/VistaPedidosDeposito'
import { useHojasDeRutaDepositoQuery } from '../../hooks/queries/useHojasDeRutaDepositoQuery'
import { useNotification } from '../../contexts/NotificationContext'
import { importConRecarga } from '../../utils/lazyWithReload'
import type { PedidoDB, PerfilDB } from '../../types/hooks'
import type { PedidoDeposito, RutaDeposito } from '../../utils/hojasDeRutaDeposito'

export default function PedidosDepositoContainer(): ReactElement {
  // null = la próxima ruta armada, que la elige el servidor en hora argentina.
  const [fecha, setFecha] = useState<string | null>(null)
  const { data, isLoading, error, refetch } = useHojasDeRutaDepositoQuery(fecha)
  const notify = useNotification()

  const descargarManifiesto = useCallback(async (ruta: RutaDeposito, pedidos: PedidoDeposito[]) => {
    try {
      const { generarManifiestoCarga } = await importConRecarga(() => import('../../lib/pdfExport'))
      const transportista = { id: ruta.transportista.id ?? '', nombre: ruta.transportista.nombre, email: '' } as PerfilDB
      // El manifiesto sólo lee ítems, canal y cambio (consolidarCarga) y la
      // cantidad de paradas; su encabezado sin resumen no toca `total`. Por eso
      // le alcanzan los pedidos sin plata de depósito.
      generarManifiestoCarga(transportista, pedidos as unknown as PedidoDB[], { fecha: data?.fecha ?? undefined }, {
        nombresSubrubro: data?.subrubros,
      })
    } catch (e) {
      notify.error((e as Error).message)
    }
  }, [data, notify])

  return (
    <VistaPedidosDeposito
      datos={data}
      cargando={isLoading}
      error={error as Error | null}
      onCambiarFecha={setFecha}
      onDescargarManifiesto={descargarManifiesto}
      onReintentar={() => { void refetch() }}
    />
  )
}
