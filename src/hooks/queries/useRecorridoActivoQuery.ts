/**
 * Recorrido vigente (en_curso) de hoy del transportista logueado, CON sus
 * paradas. Es la "ruta del día" que arma el admin: el transportista lee de
 * acá, NO de "todos sus pedidos asignados" (que colaba entregados-no-marcados
 * de días previos).
 *
 * El embedding PostgREST funciona con las RLS existentes: el transportista ve
 * su recorrido (transportista_id = auth.uid()), sus recorrido_pedidos (vía el
 * recorrido propio), sus pedidos (transportista_id = auth.uid()), los items de
 * esos pedidos y los clientes/productos de su sucursal. Sin RPC.
 */
import { useEffect, useMemo } from 'react'
import { useQuery } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import { useSucursal } from '../../contexts/SucursalContext'
import { fechaLocalISO } from '../../utils/formatters'
import { guardarRuta, leerRuta, type RutaCacheada } from '../../lib/rutaOfflineCache'
import type { PedidoConCliente } from '../../components/rutaActiva/useEntregaParada'

export interface RecorridoActivo {
  id: string
  polylines: string[] | null
  /** Paradas de la ruta del día, ordenadas por orden_entrega, enriquecidas. */
  paradas: PedidoConCliente[]
  /** Fecha de la ruta (YYYY-MM-DD). Puede ser la de ayer: ver `fechaDeRuta`. */
  fecha: string
  /**
   * Epoch ms de la última vez que estos datos vinieron del servidor. Si salieron
   * del cache local, es viejo — la pantalla lo rotula en vez de hacer pasar por
   * vivo algo que no lo es.
   */
  obtenidoEn: number
}

export const recorridoActivoKeys = {
  all: (sucursalId: number | null, transportistaId: string | null) =>
    ['recorrido-activo', sucursalId, transportistaId] as const,
}

// Embedding: recorrido → paradas (recorrido_pedidos) → pedido → cliente/items.
const RECORRIDO_ACTIVO_SELECT = `id, polylines, fecha,
  recorrido_pedidos(
    orden_entrega, estado_entrega, hora_entrega,
    pedido:pedidos(
      *,
      cliente:clientes(id, nombre_fantasia, razon_social, direccion, aclaracion_direccion, telefono, contacto, latitud, longitud, horarios_atencion, dias_atencion),
      items:pedido_items(*, producto:productos(id, nombre, codigo, etiqueta_bulto, unidades_de_venta_por_fardo)),
      cambio:recorrido_cambios(producto_devuelto_nombre, cantidad_devuelta, producto_entregado_nombre, cantidad_entregada, observaciones, aplicado_at)
    )
  )`

interface RecorridoPedidoRaw {
  orden_entrega: number | null
  estado_entrega: string | null
  pedido: (Record<string, unknown> & { orden_entrega?: number | null }) | null
}

/** Hasta esta hora local, una ruta de ayer todavía puede estar en curso. */
const HORA_CORTE_RUTA_DE_AYER = 6

/**
 * Fechas de recorrido que le pueden corresponder al chofer.
 *
 * Antes esto era un `.eq('fecha', fechaLocalISO())` a secas y dejaba sin ruta a
 * quien cruza la medianoche terminando el reparto: a las 00:05 la ruta que está
 * haciendo pasa a ser "de ayer" y la pantalla le decía que el administrador
 * todavía no armó la suya, con el camión cargado.
 *
 * Pero aceptar la de ayer SIEMPRE es peor que el bug original. En producción hay
 * decenas de recorridos que quedaron `en_curso` de días pasados porque nada los
 * cierra, así que un chofer sin ruta hoy vería la de ayer —con paradas ya
 * entregadas— a las diez de la mañana. Por eso la ventana: sólo en la madrugada,
 * que es cuando "ayer" de verdad significa "el turno que todavía no terminé".
 * Pasada esa hora, no tener ruta es la respuesta correcta.
 *
 * La causa de fondo (recorridos que nunca se cierran) se ataca aparte.
 */
export function fechaDeRuta(
  hoy = fechaLocalISO(),
  horaLocal = new Date().getHours(),
): { hoy: string; ayer: string | null } {
  if (horaLocal >= HORA_CORTE_RUTA_DE_AYER) return { hoy, ayer: null }
  const d = new Date(`${hoy}T12:00:00`)
  d.setDate(d.getDate() - 1)
  return { hoy, ayer: fechaLocalISO(d) }
}

async function fetchRecorridoActivo(transportistaId: string): Promise<RecorridoActivo | null> {
  const { hoy, ayer } = fechaDeRuta()
  const fechas = ayer ? [hoy, ayer] : [hoy]
  const { data, error } = await supabase
    .from('recorridos')
    .select(RECORRIDO_ACTIVO_SELECT)
    .eq('transportista_id', transportistaId)
    .in('fecha', fechas)
    .eq('estado', 'en_curso')
    // La de hoy gana; la de ayer es el fallback de la madrugada.
    .order('fecha', { ascending: false })
    .order('created_at', { ascending: false })
    .limit(1)
    .maybeSingle()

  if (error) throw error
  if (!data) return null

  const rps = ((data.recorrido_pedidos as unknown as RecorridoPedidoRaw[]) || [])
    .filter(rp => rp.pedido != null)
    // Un pedido cancelado no es una parada. La mig 180 hace que cancelar baje la
    // fila de `recorrido_pedidos`, pero este filtro cubre el hueco entre que se
    // cancela y que la query refetchea, y cualquier fila vieja que haya quedado.
    // Sin esto el cancelado seguía como pin numerado en el mapa y además
    // inflaba el contador de "completadas" del header, porque no está en
    // `pendientes` (estado !== 'asignado') pero sí cuenta en el total.
    .filter(rp => !['cancelado', 'anulado'].includes(String((rp.pedido as { estado?: string })?.estado ?? '')))
    // El orden de entrega del recorrido es la fuente de verdad
    .sort((a, b) => (a.orden_entrega ?? 999) - (b.orden_entrega ?? 999))

  const paradas = rps.map(rp => {
    const pedido = rp.pedido as Record<string, unknown> & { orden_entrega?: number | null; cambio?: unknown }
    // recorrido_cambios viene como objeto (FK única) o array según PostgREST:
    // lo normalizamos a objeto | null.
    const cambioRaw = pedido?.cambio
    const cambio = Array.isArray(cambioRaw) ? (cambioRaw[0] ?? null) : (cambioRaw ?? null)
    return {
      ...pedido,
      cambio,
      orden_entrega: rp.orden_entrega ?? pedido?.orden_entrega ?? null,
    }
  }) as unknown as PedidoConCliente[]

  return {
    id: String(data.id),
    polylines: (data.polylines as string[] | null) ?? null,
    paradas,
    fecha: String((data as { fecha?: string }).fecha ?? hoy),
    obtenidoEn: Date.now(),
  }
}

/**
 * Ruta del día del chofer, con respaldo local.
 *
 * `initialData` siembra desde localStorage: si la app se reabre sin señal (iOS
 * descarta la PWA en segundo plano y el cache de react-query vive solo en
 * memoria), el chofer ve sus paradas, direcciones, teléfonos y totales en vez
 * de una pantalla vacía. `initialDataUpdatedAt` con el sello del guardado hace
 * que react-query trate esos datos como VIEJOS y dispare un refetch apenas haya
 * red — no se queda pegado al cache.
 */
export function useRecorridoActivoQuery(transportistaId: string | null | undefined) {
  const { currentSucursalId } = useSucursal()
  const { hoy } = fechaDeRuta()

  // Memoizado por (sucursal, chofer, día) y NO por montaje. La diferencia
  // importa: leer una sola vez al montar dejaba el valor pegado al primer
  // render, así que al cambiar de sucursal la query nueva —clave nueva, sin
  // datos— se sembraba con `initialData` de la sucursal ANTERIOR. Con las deps
  // correctas, cambiar de sucursal relee el cache de la que corresponde.
  // Releer localStorage es idempotente y barato; el riesgo no era el costo.
  const cacheada = useMemo<RutaCacheada<RecorridoActivo> | null>(
    () => (transportistaId ? leerRuta<RecorridoActivo>(currentSucursalId, transportistaId, hoy) : null),
    [currentSucursalId, transportistaId, hoy],
  )

  const query = useQuery({
    queryKey: recorridoActivoKeys.all(currentSucursalId, transportistaId ?? null),
    queryFn: () => fetchRecorridoActivo(transportistaId as string),
    enabled: !!transportistaId,
    staleTime: 60 * 1000,
    ...(cacheada
      ? { initialData: cacheada.datos, initialDataUpdatedAt: cacheada.guardadoEn }
      : {}),
  })

  // Persistir lo que SÍ vino del servidor. `isFetched`/`isSuccess` no alcanzan:
  // con `initialData` la query arranca en success sin haber ido a la red, y
  // reescribir el cache con lo que acabamos de leer solo renueva su fecha de
  // vencimiento y lo hace parecer fresco.
  const { data, dataUpdatedAt, isFetching } = query
  useEffect(() => {
    if (!transportistaId || !data || isFetching) return
    if (cacheada && dataUpdatedAt === cacheada.guardadoEn) return
    guardarRuta(currentSucursalId, transportistaId, data.fecha, data)
  }, [transportistaId, currentSucursalId, data, dataUpdatedAt, isFetching, cacheada])

  return {
    ...query,
    /** true cuando lo que se está mostrando salió del cache, no de la red. */
    desdeCache: !!cacheada && query.dataUpdatedAt === cacheada.guardadoEn,
    /** Epoch ms de los datos en pantalla (para "actualizado hace X"). */
    datosDe: query.data?.obtenidoEn ?? cacheada?.guardadoEn ?? null,
  }
}
