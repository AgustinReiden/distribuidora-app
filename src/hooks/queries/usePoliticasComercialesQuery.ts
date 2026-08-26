/**
 * Política comercial de la sucursal activa (mig 204).
 *
 * Hoy tiene un solo campo, el monto mínimo de pedido, pero la tabla existe para
 * ser el lugar donde vive la política comercial: sumar una es una columna más
 * acá y un campo más en la pantalla de configuración.
 *
 * EL PUNTO IMPORTANTE ES EL CACHÉ OFFLINE
 * ---------------------------------------
 * El mínimo se valida en la base (mig 205), pero un pedido cargado sin señal no
 * llega a la base hasta que se sincroniza. Si el teléfono no conoce la regla, el
 * pedido se acepta ahí mismo, el preventista se va del comercio, y el rechazo
 * aparece horas después como una operación fallida en IndexedDB.
 *
 * Por eso el último valor conocido se persiste en Dexie y se usa como
 * `initialData`: un teléfono sin señal arranca sabiendo cuál era el mínimo la
 * última vez que hubo conexión. Es lo mejor que se puede saber offline, y es
 * muchísimo mejor que no saber nada.
 */
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useState } from 'react'
import { supabase } from '../supabase/base'
import { useSucursal } from '../../contexts/SucursalContext'
import { cacheData, getCachedData } from '../../lib/offlineDb'

export interface PoliticasComerciales {
  /** Monto mínimo en $ que debe alcanzar un pedido. 0 = sin política. */
  montoMinimoPedido: number
}

const CACHE_KEY = 'politicas_comerciales'

export const politicasComercialesKeys = {
  all: (sucursalId: number | null) => ['politicas-comerciales', sucursalId] as const,
}

export const POLITICAS_POR_DEFECTO: PoliticasComerciales = { montoMinimoPedido: 0 }

async function fetchPoliticas(sucursalId: number | null): Promise<PoliticasComerciales> {
  const { data, error } = await supabase
    .from('politicas_comerciales')
    .select('monto_minimo_pedido')
    .maybeSingle()

  if (error) throw error

  // Sin fila = sin política. La mig 204 siembra una por sucursal, pero una
  // sucursal creada después todavía no la tendría, y eso no es un error.
  const politicas: PoliticasComerciales = {
    montoMinimoPedido: Number(data?.monto_minimo_pedido ?? 0) || 0,
  }

  // Sin expiración a propósito: un valor viejo es infinitamente mejor que
  // ninguno cuando no hay señal, y en cuanto haya conexión se pisa.
  await cacheData(CACHE_KEY, politicas, undefined, sucursalId).catch(() => {
    // Que falle el caché no puede romper la carga de un pedido.
  })

  return politicas
}

export function usePoliticasComercialesQuery() {
  const { currentSucursalId } = useSucursal()
  const [cacheado, setCacheado] = useState<PoliticasComerciales | null>(null)

  useEffect(() => {
    let vigente = true
    getCachedData<PoliticasComerciales>(CACHE_KEY, currentSucursalId)
      .then(valor => { if (vigente && valor) setCacheado(valor) })
      .catch(() => { /* sin caché se usa el default */ })
    return () => { vigente = false }
  }, [currentSucursalId])

  const query = useQuery({
    queryKey: politicasComercialesKeys.all(currentSucursalId),
    queryFn: () => fetchPoliticas(currentSucursalId),
    staleTime: 5 * 60 * 1000,
  })

  return {
    ...query,
    /**
     * Siempre devuelve algo usable: lo del servidor, si no lo cacheado, si no
     * "sin política". Nunca undefined — quien valida un pedido no puede quedar
     * esperando.
     */
    politicas: query.data ?? cacheado ?? POLITICAS_POR_DEFECTO,
  }
}

/** Lectura puntual desde Dexie, para los caminos que no son React (encolar offline). */
export async function leerMontoMinimoCacheado(sucursalId: number | null): Promise<number> {
  const valor = await getCachedData<PoliticasComerciales>(CACHE_KEY, sucursalId).catch(() => null)
  return Number(valor?.montoMinimoPedido ?? 0) || 0
}

/**
 * Fija el monto mínimo de la sucursal activa.
 *
 * Va por RPC y no por UPDATE directo para que `actualizado_por` lo selle el
 * servidor con auth.uid(): si lo mandara el cliente sería un dato que el cliente
 * elige, y la auditoría no auditaría nada (mig 204).
 */
export function useActualizarMontoMinimoMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()

  return useMutation({
    mutationFn: async (monto: number) => {
      const { data, error } = await supabase.rpc('actualizar_monto_minimo_pedido', {
        p_monto: monto,
      })
      if (error) throw error
      // Se refresca el caché de Dexie en el acto: si no, un teléfono que queda
      // sin señal justo después seguiría validando contra el mínimo viejo.
      await cacheData(CACHE_KEY, { montoMinimoPedido: monto }, undefined, currentSucursalId).catch(() => {})
      return Number(data ?? monto)
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: politicasComercialesKeys.all(currentSucursalId) })
    },
  })
}

export interface ImpactoMinimo {
  /** Pedidos considerados (no cancelados) en la ventana mirada. */
  total: number
  /** Cuántos de esos no habrían podido cargarse con el mínimo propuesto. */
  bloqueados: number
}

/**
 * Cuántos de los últimos pedidos no habrían entrado con un mínimo dado.
 *
 * Existe para que nadie elija el número a ciegas: en los datos de prod, un
 * mínimo de $20.000 habría frenado 736 de 2051 pedidos de una sucursal en 90
 * días. Ver ese número antes de guardar es la diferencia entre fijar una
 * política y cortar la operación sin querer.
 *
 * Se excluyen los cancelados porque cancelar pone `total = 0` (mig 175) y
 * contarlos inflaría el impacto con pedidos que ni siquiera existen ya.
 */
export function useImpactoMinimoQuery(montoPropuesto: number) {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: ['politicas-comerciales', currentSucursalId, 'impacto', montoPropuesto],
    enabled: montoPropuesto > 0,
    staleTime: 5 * 60 * 1000,
    queryFn: async (): Promise<ImpactoMinimo> => {
      const desde = new Date()
      desde.setDate(desde.getDate() - 90)
      const { data, error } = await supabase
        .from('pedidos')
        .select('total')
        .neq('estado', 'cancelado')
        .gte('fecha', desde.toISOString().slice(0, 10))
      if (error) throw error
      const filas = data ?? []
      return {
        total: filas.length,
        bloqueados: filas.filter(p => (Number(p.total) || 0) < montoPropuesto).length,
      }
    },
  })
}
