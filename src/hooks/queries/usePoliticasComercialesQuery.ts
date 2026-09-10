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
  /** % por defecto de quien tiene rol preventista (mig 207). */
  comisionPctPreventista: number
  /** % por defecto de quien NO es preventista: admin, encargado (mig 207). */
  comisionPctOtros: number
  /** Días de anticipación del aviso amarillo de vencimiento (mig 223). */
  diasAlertaVencimiento: number
  /** Días de anticipación del aviso rojo. Siempre <= el amarillo (mig 223). */
  diasCriticoVencimiento: number
}

const CACHE_KEY = 'politicas_comerciales'

export const politicasComercialesKeys = {
  all: (sucursalId: number | null) => ['politicas-comerciales', sucursalId] as const,
}

// Los valores de arranque de la mig 207, que son los que rigen si todavía no
// llegó la fila del servidor. No inventan nada: son el default de las columnas.
export const POLITICAS_POR_DEFECTO: PoliticasComerciales = {
  montoMinimoPedido: 0,
  comisionPctPreventista: 2,
  comisionPctOtros: 0,
  diasAlertaVencimiento: 60,
  diasCriticoVencimiento: 15,
}

async function fetchPoliticas(sucursalId: number | null): Promise<PoliticasComerciales> {
  const { data, error } = await supabase
    .from('politicas_comerciales')
    .select('monto_minimo_pedido, comision_pct_preventista, comision_pct_otros, dias_alerta_vencimiento, dias_critico_vencimiento')
    .maybeSingle()

  if (error) throw error

  // Sin fila = sin política. La mig 204 siembra una por sucursal, pero una
  // sucursal creada después todavía no la tendría, y eso no es un error.
  const politicas: PoliticasComerciales = {
    montoMinimoPedido: Number(data?.monto_minimo_pedido ?? 0) || 0,
    // `?? 2` y no `|| 2`: un 0 configurado a mano es un valor, no un hueco.
    comisionPctPreventista: Number(data?.comision_pct_preventista ?? 2),
    comisionPctOtros: Number(data?.comision_pct_otros ?? 0),
    // Mismo criterio que las comisiones: `??` y no `||`, porque 0 días es una
    // configuración válida ("avisame solo lo ya vencido"), no un hueco.
    diasAlertaVencimiento: Number(data?.dias_alerta_vencimiento ?? 60),
    diasCriticoVencimiento: Number(data?.dias_critico_vencimiento ?? 15),
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
      // Se preserva el resto de la política: pisar el caché con un objeto de un
      // solo campo dejaría los porcentajes en undefined hasta la próxima lectura.
      const previo = await getCachedData<PoliticasComerciales>(CACHE_KEY, currentSucursalId).catch(() => null)
      await cacheData(
        CACHE_KEY,
        { ...(previo ?? POLITICAS_POR_DEFECTO), montoMinimoPedido: monto },
        undefined,
        currentSucursalId,
      ).catch(() => {})
      return Number(data ?? monto)
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: politicasComercialesKeys.all(currentSucursalId) })
    },
  })
}

/**
 * Fija los dos % de comisión por defecto de la sucursal activa.
 *
 * Va por RPC por lo mismo que el monto mínimo: `actualizado_por` lo sella el
 * servidor con auth.uid(). Los dos porcentajes viajan juntos porque son una
 * sola decisión —"cuánto cobra cada tipo de vendedor"— y mandarlos por separado
 * dejaría un estado intermedio raro entre las dos escrituras.
 */
export function useActualizarComisionesDefaultMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()

  return useMutation({
    mutationFn: async (input: { pctPreventista: number; pctOtros: number }) => {
      const { error } = await supabase.rpc('actualizar_comisiones_default', {
        p_pct_preventista: input.pctPreventista,
        p_pct_otros: input.pctOtros,
      })
      if (error) throw error

      const previo = await getCachedData<PoliticasComerciales>(CACHE_KEY, currentSucursalId).catch(() => null)
      await cacheData(
        CACHE_KEY,
        {
          ...(previo ?? POLITICAS_POR_DEFECTO),
          comisionPctPreventista: input.pctPreventista,
          comisionPctOtros: input.pctOtros,
        },
        undefined,
        currentSucursalId,
      ).catch(() => {})

      return input
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: politicasComercialesKeys.all(currentSucursalId) })
      // El cálculo de comisiones cambia de resultado: su caché queda viejo.
      queryClient.invalidateQueries({ queryKey: ['comisiones'] })
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

/**
 * Fija los dos umbrales de aviso de vencimiento de la sucursal activa.
 *
 * Viajan juntos por lo mismo que los dos porcentajes de comisión: son una sola
 * decisión —"cuándo me preocupo y cuándo me alarmo"— y mandarlos por separado
 * dejaría un estado intermedio donde el rojo queda después del amarillo, que la
 * base rechaza con un CHECK.
 */
export function useActualizarAlertasVencimientoMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()

  return useMutation({
    mutationFn: async (input: { diasAlerta: number; diasCritico: number }) => {
      const { error } = await supabase.rpc('actualizar_alertas_vencimiento', {
        p_dias_alerta: input.diasAlerta,
        p_dias_critico: input.diasCritico,
      })
      if (error) throw error

      const previo = await getCachedData<PoliticasComerciales>(CACHE_KEY, currentSucursalId).catch(() => null)
      await cacheData(
        CACHE_KEY,
        {
          ...(previo ?? POLITICAS_POR_DEFECTO),
          diasAlertaVencimiento: input.diasAlerta,
          diasCriticoVencimiento: input.diasCritico,
        },
        undefined,
        currentSucursalId,
      ).catch(() => {})

      return input
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: politicasComercialesKeys.all(currentSucursalId) })
      // El semáforo del panel y de la ficha se pinta con estos umbrales.
      queryClient.invalidateQueries({ queryKey: ['lotes'] })
    },
  })
}
