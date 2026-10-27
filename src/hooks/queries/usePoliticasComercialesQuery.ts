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
import { useEffect, useMemo, useState } from 'react'
import { supabase } from '../supabase/base'
import { errorDeSupabase } from '../../utils/errorDeSupabase'
import { useSucursal } from '../../contexts/SucursalContext'
import { cacheData, getCachedData } from '../../lib/offlineDb'
import { REGLA_MINIMO_POR_DEFECTO, reglaMinimoDe, ventaDePedido, type ModoMinimoPedido, type ReglaMinimoPedido } from '../../utils/montoMinimo'

export interface PoliticasComerciales {
  /** Monto mínimo en $ que debe alcanzar un pedido. 0 = sin política. */
  montoMinimoPedido: number
  /**
   * Qué pasa con el pedido bajo el mínimo (mig 389, #1220): se rechaza
   * ('bloquear'), entra con cargo de envío ('cargo') o ambas cosas según el
   * tramo ('escalas').
   */
  modoMinimoPedido: ModoMinimoPedido
  /** Solo en 'escalas': desde este total no hay cargo de envío. */
  montoEnvioGratis: number
  /** Cargo de envío en $ de los modos 'cargo' y 'escalas'. */
  cargoEnvioPedido: number
  /** % por defecto de quien tiene rol preventista (mig 207). */
  comisionPctPreventista: number
  /** % por defecto de quien NO es preventista: admin, encargado (mig 207). */
  comisionPctOtros: number
  /** Días de anticipación del aviso amarillo de vencimiento (mig 223). */
  diasAlertaVencimiento: number
  /** Días de anticipación del aviso rojo. Siempre <= el amarillo (mig 223). */
  diasCriticoVencimiento: number
  /**
   * Si al tomar un pedido se listan los productos sin stock (deshabilitados).
   * Apagado, no se ofrecen en la app ni en el bot. Default true: es lo que
   * hacía la app antes de que existiera la política.
   */
  mostrarSinStock: boolean
  /**
   * Horas después de un cambio de lista durante las que quien no es admin
   * todavía puede vender al precio anterior (0 a 168, default 24). La usa
   * `precio_fuera_de_politica` (mig 363) para el piso y el techo: sirve al
   * replay offline, pero vale también para quien tiene señal. Sólo la edita el
   * admin (#1157).
   */
  ventanaPrecioAnteriorHoras: number
  /**
   * Alertas de combos (#1194, mig 384): margen mínimo del combo, en % sobre la
   * venta sin IVA. Avisa, no bloquea. Sólo lo edita el admin.
   */
  comboMargenMinimoPct: number
  /** Alertas de combos: descuento máximo contra la suma de precios sin combo, en %. */
  comboDescuentoMaximoPct: number
}

const CACHE_KEY = 'politicas_comerciales'

export const politicasComercialesKeys = {
  all: (sucursalId: number | null) => ['politicas-comerciales', sucursalId] as const,
}

// Los valores de arranque de la mig 207, que son los que rigen si todavía no
// llegó la fila del servidor. No inventan nada: son el default de las columnas.
export const POLITICAS_POR_DEFECTO: PoliticasComerciales = {
  montoMinimoPedido: 0,
  modoMinimoPedido: 'bloquear',
  montoEnvioGratis: 0,
  cargoEnvioPedido: 0,
  comisionPctPreventista: 2,
  comisionPctOtros: 0,
  diasAlertaVencimiento: 60,
  diasCriticoVencimiento: 15,
  mostrarSinStock: true,
  ventanaPrecioAnteriorHoras: 24,
  comboMargenMinimoPct: 10,
  comboDescuentoMaximoPct: 30,
}

function modoValido(modo: unknown): ModoMinimoPedido {
  return modo === 'cargo' || modo === 'escalas' ? modo : 'bloquear'
}

async function fetchPoliticas(sucursalId: number | null): Promise<PoliticasComerciales> {
  const { data, error } = await supabase
    .from('politicas_comerciales')
    .select('monto_minimo_pedido, modo_minimo_pedido, monto_envio_gratis, cargo_envio_pedido, comision_pct_preventista, comision_pct_otros, dias_alerta_vencimiento, dias_critico_vencimiento, mostrar_sin_stock, ventana_precio_anterior_horas, combo_margen_minimo_pct, combo_descuento_maximo_pct')
    .maybeSingle()

  if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo cargar la política comercial. Revisá la señal e intentá de nuevo.')

  // Sin fila = sin política. La mig 204 siembra una por sucursal, pero una
  // sucursal creada después todavía no la tendría, y eso no es un error.
  const politicas: PoliticasComerciales = {
    montoMinimoPedido: Number(data?.monto_minimo_pedido ?? 0) || 0,
    modoMinimoPedido: modoValido(data?.modo_minimo_pedido),
    montoEnvioGratis: Number(data?.monto_envio_gratis ?? 0) || 0,
    cargoEnvioPedido: Number(data?.cargo_envio_pedido ?? 0) || 0,
    // `?? 2` y no `|| 2`: un 0 configurado a mano es un valor, no un hueco.
    comisionPctPreventista: Number(data?.comision_pct_preventista ?? 2),
    comisionPctOtros: Number(data?.comision_pct_otros ?? 0),
    // Mismo criterio que las comisiones: `??` y no `||`, porque 0 días es una
    // configuración válida ("avisame solo lo ya vencido"), no un hueco.
    diasAlertaVencimiento: Number(data?.dias_alerta_vencimiento ?? 60),
    diasCriticoVencimiento: Number(data?.dias_critico_vencimiento ?? 15),
    // `?? true` y no `||`: false configurado a mano es un valor, no un hueco.
    mostrarSinStock: data?.mostrar_sin_stock ?? true,
    // `??` y no `||`: 0 horas es una configuración válida (sin tolerancia).
    ventanaPrecioAnteriorHoras: Number(data?.ventana_precio_anterior_horas ?? 24),
    // `??`: 0 es un tope válido.
    comboMargenMinimoPct: Number(data?.combo_margen_minimo_pct ?? 10),
    comboDescuentoMaximoPct: Number(data?.combo_descuento_maximo_pct ?? 30),
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

  const fuente = query.data ?? cacheado
  const politicas = useMemo(
    () => ({ ...POLITICAS_POR_DEFECTO, ...(fuente ?? {}) }),
    [fuente],
  )

  return {
    ...query,
    /**
     * Siempre devuelve algo usable: lo del servidor, si no lo cacheado, si no
     * "sin política". Nunca undefined — quien valida un pedido no puede quedar
     * esperando.
     */
    // Se mergea con los defaults: un caché de Dexie escrito antes de que
    // existiera un campo no lo trae, y `undefined` no puede llegar a la UI.
    politicas,
  }
}

/**
 * Los días de alerta de vencimiento, por la RPC `parametros_vencimiento()`
 * (#999), sin el resto de la política. Depósito no lee `politicas_comerciales`
 * (trae el monto mínimo y las comisiones) y /vencimientos es su pantalla; la
 * RPC le devuelve a cualquier sesión de la sucursal sólo estos dos números.
 *
 * Cuelga de `politicasComercialesKeys.all`: lo que invalida la política al
 * editarla en /configuracion refresca también esto. Sin señal, mientras la RPC
 * no contesta, usa los días de la última política que este teléfono cacheó
 * (la que guarda usePoliticasComercialesQuery), como hacía antes la pantalla.
 */
export function useParametrosVencimientoQuery() {
  const { currentSucursalId } = useSucursal()
  const [cacheado, setCacheado] = useState<PoliticasComerciales | null>(null)

  useEffect(() => {
    let vigente = true
    getCachedData<PoliticasComerciales>(CACHE_KEY, currentSucursalId)
      .then(valor => { if (vigente && valor) setCacheado(valor) })
      .catch(() => { /* sin caché se usan los defaults */ })
    return () => { vigente = false }
  }, [currentSucursalId])

  const query = useQuery({
    queryKey: [...politicasComercialesKeys.all(currentSucursalId), 'vencimiento'] as const,
    queryFn: async () => {
      const { data, error } = await supabase.rpc('parametros_vencimiento')
      if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudieron cargar los días de alerta de vencimiento. Revisá la señal e intentá de nuevo.')
      const fila = (Array.isArray(data) ? data[0] : data) as
        | { dias_alerta_vencimiento?: number | null; dias_critico_vencimiento?: number | null }
        | null
        | undefined
      return {
        // `??` y no `||`: 0 días es una configuración válida (mismo criterio que fetchPoliticas).
        diasAlertaVencimiento: Number(fila?.dias_alerta_vencimiento ?? POLITICAS_POR_DEFECTO.diasAlertaVencimiento),
        diasCriticoVencimiento: Number(fila?.dias_critico_vencimiento ?? POLITICAS_POR_DEFECTO.diasCriticoVencimiento),
      }
    },
    staleTime: 5 * 60 * 1000,
  })
  return {
    ...query,
    diasAlertaVencimiento: query.data?.diasAlertaVencimiento
      ?? cacheado?.diasAlertaVencimiento ?? POLITICAS_POR_DEFECTO.diasAlertaVencimiento,
    diasCriticoVencimiento: query.data?.diasCriticoVencimiento
      ?? cacheado?.diasCriticoVencimiento ?? POLITICAS_POR_DEFECTO.diasCriticoVencimiento,
  }
}

/** Lectura puntual desde Dexie, para los caminos que no son React (encolar offline). */
export async function leerMontoMinimoCacheado(sucursalId: number | null): Promise<number> {
  const valor = await getCachedData<PoliticasComerciales>(CACHE_KEY, sucursalId).catch(() => null)
  return Number(valor?.montoMinimoPedido ?? 0) || 0
}

/** Lectura puntual de la regla completa del mínimo desde Dexie (encolar offline). */
export async function leerReglaMinimoCacheada(sucursalId: number | null): Promise<ReglaMinimoPedido> {
  const valor = await getCachedData<PoliticasComerciales>(CACHE_KEY, sucursalId).catch(() => null)
  if (!valor) return REGLA_MINIMO_POR_DEFECTO
  return reglaMinimoDe({ ...POLITICAS_POR_DEFECTO, ...valor })
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
      if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo confirmar que el monto mínimo se haya guardado. Revisá antes de reintentar.')
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
 * Fija la política del mínimo completa (mig 389, #1220): el modo, el mínimo, el
 * tope del envío gratis y el cargo. Viajan juntos: son una sola decisión y la
 * base valida las cuatro a la vez (en escalas, el tope tiene que superar al
 * mínimo). Por RPC por lo mismo que las demás: `actualizado_por` lo sella el
 * servidor.
 */
export function useActualizarPoliticaMinimoMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()

  return useMutation({
    mutationFn: async (regla: ReglaMinimoPedido) => {
      const { error } = await supabase.rpc('actualizar_politica_minimo_pedido', {
        p_modo: regla.modo,
        p_monto_minimo: regla.montoMinimo,
        p_monto_envio_gratis: regla.montoEnvioGratis,
        p_cargo_envio: regla.cargoEnvio,
      })
      if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo confirmar que la compra mínima se haya guardado. Revisá antes de reintentar.')

      // Mismo motivo que el monto mínimo: el caché de Dexie se refresca en el
      // acto, o un teléfono que queda sin señal valida contra la regla vieja.
      const previo = await getCachedData<PoliticasComerciales>(CACHE_KEY, currentSucursalId).catch(() => null)
      await cacheData(
        CACHE_KEY,
        {
          ...POLITICAS_POR_DEFECTO,
          ...(previo ?? {}),
          modoMinimoPedido: regla.modo,
          montoMinimoPedido: regla.montoMinimo,
          montoEnvioGratis: regla.montoEnvioGratis,
          cargoEnvioPedido: regla.cargoEnvio,
        },
        undefined,
        currentSucursalId,
      ).catch(() => {})

      return regla
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
      if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo confirmar que las comisiones se hayan guardado. Revisá antes de reintentar.')

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
 * contarlos inflaría el impacto con pedidos que ni siquiera existen ya. Los
 * anulados, por lo mismo (#1080).
 *
 * Se excluyen también los vales blancos (tipo_factura = 'VB'): el mínimo de pedido no
 * rige para ellos (N6), así que no son pedidos que el mínimo pudiera frenar. `tipo_factura`
 * es nullable: el `or` conserva los NULL (un `neq` pelado los descartaría).
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
        .select('total, cargo_envio')
        .neq('estado', 'cancelado')
        .neq('estado', 'anulado')
        .or('tipo_factura.is.null,tipo_factura.neq.VB')
        .gte('fecha', desde.toISOString().slice(0, 10))
      if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo cargar el impacto del mínimo. Revisá la señal e intentá de nuevo.')
      const filas = data ?? []
      return {
        total: filas.length,
        bloqueados: filas.filter(p => ventaDePedido({ total: Number(p.total) || 0, cargo_envio: Number(p.cargo_envio) || 0 }) < montoPropuesto).length,
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
      if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo confirmar que las alertas de vencimiento se hayan guardado. Revisá antes de reintentar.')

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

/**
 * Prende o apaga la lista de productos sin stock al tomar pedidos (sucursal
 * activa). Por RPC por lo mismo que las demás: `actualizado_por` lo sella el
 * servidor. Sólo admin/encargado (lo hace cumplir la RPC).
 */
export function useActualizarMostrarSinStockMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()

  return useMutation({
    mutationFn: async (mostrar: boolean) => {
      const { data, error } = await supabase.rpc('actualizar_mostrar_sin_stock', {
        p_mostrar: mostrar,
      })
      if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo confirmar que el ajuste se haya guardado. Revisá antes de reintentar.')

      const previo = await getCachedData<PoliticasComerciales>(CACHE_KEY, currentSucursalId).catch(() => null)
      await cacheData(
        CACHE_KEY,
        { ...POLITICAS_POR_DEFECTO, ...(previo ?? {}), mostrarSinStock: mostrar },
        undefined,
        currentSucursalId,
      ).catch(() => {})

      return typeof data === 'boolean' ? data : mostrar
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: politicasComercialesKeys.all(currentSucursalId) })
    },
  })
}

/**
 * Fija la ventana de precio anterior de la sucursal activa (#1157). Por RPC por
 * lo mismo que las demás: `actualizado_por` lo sella el servidor. Sólo admin:
 * la ventana afloja el piso y el techo de precio que rigen para el encargado
 * (lo hace cumplir la RPC).
 */
export function useActualizarVentanaPrecioAnteriorMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()

  return useMutation({
    mutationFn: async (horas: number) => {
      const { data, error } = await supabase.rpc('actualizar_ventana_precio_anterior', {
        p_horas: horas,
      })
      if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo confirmar que la ventana se haya guardado. Revisá antes de reintentar.')

      const previo = await getCachedData<PoliticasComerciales>(CACHE_KEY, currentSucursalId).catch(() => null)
      await cacheData(
        CACHE_KEY,
        { ...POLITICAS_POR_DEFECTO, ...(previo ?? {}), ventanaPrecioAnteriorHoras: horas },
        undefined,
        currentSucursalId,
      ).catch(() => {})

      return typeof data === 'number' ? data : horas
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: politicasComercialesKeys.all(currentSucursalId) })
    },
  })
}

/**
 * Fija los dos topes de las alertas de combos de la sucursal activa (#1194).
 * Viajan juntos: son una sola decisión ("cuándo un combo me preocupa"). Por
 * RPC, como las demás: `actualizado_por` lo sella el servidor. Sólo admin, como
 * la ventana de precio anterior (lo hace cumplir la RPC).
 */
export function useActualizarAlertasCombosMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()

  return useMutation({
    mutationFn: async (input: { margenMinimoPct: number; descuentoMaximoPct: number }) => {
      const { error } = await supabase.rpc('actualizar_alertas_combos', {
        p_margen_minimo_pct: input.margenMinimoPct,
        p_descuento_maximo_pct: input.descuentoMaximoPct,
      })
      if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo confirmar que las alertas de combos se hayan guardado. Revisá antes de reintentar.')

      const previo = await getCachedData<PoliticasComerciales>(CACHE_KEY, currentSucursalId).catch(() => null)
      await cacheData(
        CACHE_KEY,
        {
          ...POLITICAS_POR_DEFECTO,
          ...(previo ?? {}),
          comboMargenMinimoPct: input.margenMinimoPct,
          comboDescuentoMaximoPct: input.descuentoMaximoPct,
        },
        undefined,
        currentSucursalId,
      ).catch(() => {})

      return input
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: politicasComercialesKeys.all(currentSucursalId) })
    },
  })
}
