/**
 * Personal (entrega 3 de gastos): empleados, arreglos de sueldo y su cuenta corriente.
 *
 * No hay lectura ni escritura REST: todo va por RPC (`listar_personal`,
 * `obtener_cuenta_empleado`, `guardar_empleado`, etc.), que validan rol y sucursal.
 * Cualquier escritura invalida todo `['personal', sucursal]`: la lista, la cuenta
 * abierta y los selectores comparten el saldo. Entrega 4: liquidaciones (`previsualizar_liquidacion`,
 * `liquidar_empleado`, `anular_liquidacion`, `obtener_liquidacion`).
 */
import { useQuery, useMutation, useQueryClient, type QueryClient } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import { useSucursal } from '../../contexts/SucursalContext'
import { errorDeSupabase } from '../../utils/errorDeSupabase'
import { gastosKeys } from './useGastosQuery'
import { useRequestIdEstable } from '../useRequestIdEstable'
import { huellaDeAlta } from '../../utils/huellaDeAlta'
import { rendicionesDelDia, type FilaResumenRendicion } from '../../utils/personal'
import type {
  ComisionSinLiquidar,
  RendicionDelDia,
  Empleado,
  CuentaEmpleado,
  EmpleadoParaElegir,
  GuardarEmpleadoPayload,
  GuardarArregloPayload,
  MovimientoManualPayload,
  VistaPreviaLiquidacion,
  DetalleLiquidacion,
  LiquidarPayload,
} from '../../types/personal'

export const personalKeys = {
  all: (sucursalId: number | null) => ['personal', sucursalId] as const,
  lista: (sucursalId: number | null) => [...personalKeys.all(sucursalId), 'lista'] as const,
  cuenta: (sucursalId: number | null, empleadoId: number) =>
    [...personalKeys.all(sucursalId), 'cuenta', empleadoId] as const,
  paraElegir: (sucursalId: number | null) => [...personalKeys.all(sucursalId), 'para-elegir'] as const,
  admiteAdelanto: (sucursalId: number | null, clienteId: number) =>
    [...personalKeys.all(sucursalId), 'admite-adelanto', clienteId] as const,
  vistaPrevia: (sucursalId: number | null, empleadoId: number) =>
    [...personalKeys.all(sucursalId), 'vista-previa', empleadoId] as const,
  liquidacion: (sucursalId: number | null, liquidacionId: number) =>
    [...personalKeys.all(sucursalId), 'liquidacion', liquidacionId] as const,
  rendicionesDelDia: (sucursalId: number | null, fecha: string) =>
    [...personalKeys.all(sucursalId), 'rendiciones-del-dia', fecha] as const,
  comisionSinLiquidar: (sucursalId: number | null, empleadoId: number) =>
    [...personalKeys.all(sucursalId), 'comision-sin-liquidar', empleadoId] as const,
}

/**
 * Com-B3 (#1554): la huella de un pago o una liquidación, para pedir con `useRequestIdEstable` la
 * misma clave mientras no cambie. El reintento (la respuesta se perdió y se vuelve a tocar) manda lo
 * mismo: el server devuelve lo del primer intento. Otro monto, otra fecha u otra plata es otra
 * escritura, con otra clave.
 */
export function huellaDeEscrituraEmpleado(
  sucursalId: number | null,
  operacion: 'movimiento' | 'liquidacion',
  empleadoId: number,
  contenido: object,
): string {
  return `${sucursalId ?? ''}|${operacion}|${empleadoId}|${JSON.stringify(contenido)}`
}

/**
 * Un pago puede salir del efectivo de una rendición. `useRendiciones` guarda su lista en estado
 * local (no hay query que invalidar: la vista la vuelve a pedir al abrirse); lo único cacheado de
 * las rendiciones es qué días están cerrados, que vive bajo `gastosKeys`.
 */
function invalidarRendiciones(queryClient: QueryClient, sucursalId: number | null): void {
  queryClient.invalidateQueries({ queryKey: gastosKeys.all(sucursalId) })
}

export function usePersonalQuery() {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: personalKeys.lista(currentSucursalId),
    queryFn: async (): Promise<Empleado[]> => {
      const { data, error } = await supabase.rpc('listar_personal')
      if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo cargar el personal. Revisá la señal e intentá de nuevo.')
      return (data ?? []) as unknown as Empleado[]
    },
    enabled: currentSucursalId != null,
    staleTime: 30 * 1000,
  })
}

export function useCuentaEmpleadoQuery(empleadoId: number | null) {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: personalKeys.cuenta(currentSucursalId, empleadoId as number),
    queryFn: async (): Promise<CuentaEmpleado> => {
      const { data, error } = await supabase.rpc('obtener_cuenta_empleado', { p_empleado_id: empleadoId as number })
      if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo cargar la cuenta del empleado. Revisá la señal e intentá de nuevo.')
      return data as unknown as CuentaEmpleado
    },
    enabled: currentSucursalId != null && empleadoId != null,
    // Los pagos (ficha del cliente, rendición) mueven este saldo sin invalidar personalKeys:
    // al abrir la cuenta se pide siempre de nuevo, no se sirve el default global de 5 minutos.
    staleTime: 0,
  })
}

/** El período pendiente más viejo de un empleado, con las comisiones y el sueldo propuesto. `null` si no hay nada para liquidar. */
export function useVistaPreviaLiquidacionQuery(empleadoId: number | null) {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: personalKeys.vistaPrevia(currentSucursalId, empleadoId as number),
    queryFn: async (): Promise<VistaPreviaLiquidacion | null> => {
      const { data, error } = await supabase.rpc('previsualizar_liquidacion', { p_empleado_id: empleadoId as number })
      if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo cargar la liquidación. Revisá la señal e intentá de nuevo.')
      return (data ?? null) as unknown as VistaPreviaLiquidacion | null
    },
    enabled: currentSucursalId != null && empleadoId != null,
    // Como la cuenta: los pagos mueven el saldo sin invalidar, y confirmar con un número viejo lo rechaza el server.
    staleTime: 0,
  })
}

/**
 * Las rendiciones de un día en la sucursal activa (#1534 y m7 de #1392): quién tiene rendición, con la
 * regla del server (la grilla de rendiciones, `obtener_resumen_rendiciones`), y el efectivo que le
 * queda por entregar, que es el tope de un pago al personal con esa plata.
 */
export function useRendicionesDelDiaQuery(fecha: string | null) {
  const { currentSucursalId } = useSucursal()
  const dia = fecha && /^\d{4}-\d{2}-\d{2}$/.test(fecha) ? fecha : null
  return useQuery({
    queryKey: personalKeys.rendicionesDelDia(currentSucursalId, dia ?? ''),
    queryFn: async (): Promise<RendicionDelDia[]> => {
      const { data, error } = await supabase.rpc('obtener_resumen_rendiciones', {
        p_fecha_desde: dia as string, p_fecha_hasta: dia as string, p_transportista_id: null,
      })
      if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudieron cargar las rendiciones de ese día. Revisá la señal e intentá de nuevo.')
      return rendicionesDelDia(data as unknown as FilaResumenRendicion[] | null)
    },
    enabled: currentSucursalId != null && dia != null,
    // Un gasto o un cobro de la rendición mueve el efectivo sin invalidar personalKeys.
    staleTime: 0,
  })
}

/**
 * m4 (#1392): la comisión que todavía no se le liquidó, y el motivo con que guardar_empleado rechaza
 * cambiarlo de sucursal (`aviso` null: se puede mover). El motivo lo redacta el server: dice desde
 * cuándo se puede liquidar si lo pendiente entra en un período que todavía no empezó.
 */
export function useComisionSinLiquidarQuery(empleadoId: number | null, enabled = true) {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: personalKeys.comisionSinLiquidar(currentSucursalId, empleadoId as number),
    queryFn: async (): Promise<ComisionSinLiquidar> => {
      const { data, error } = await supabase.rpc('comision_sin_liquidar_empleado', { p_empleado_id: empleadoId as number })
      if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo saber si tiene comisión sin liquidar. Revisá la señal e intentá de nuevo.')
      const fila = (data ?? {}) as { monto?: number | string | null; aviso?: string | null }
      return { monto: Number(fila.monto) || 0, aviso: fila.aviso ?? null }
    },
    enabled: enabled && currentSucursalId != null && empleadoId != null,
    staleTime: 0,
  })
}

/** Lo congelado de una liquidación (no lo vivo): sueldo, pedidos y ajustes. */
export function useLiquidacionQuery(liquidacionId: number | null) {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: personalKeys.liquidacion(currentSucursalId, liquidacionId as number),
    queryFn: async (): Promise<DetalleLiquidacion> => {
      const { data, error } = await supabase.rpc('obtener_liquidacion', { p_liquidacion_id: liquidacionId as number })
      if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo cargar el detalle de la liquidación. Revisá la señal e intentá de nuevo.')
      return data as unknown as DetalleLiquidacion
    },
    enabled: currentSucursalId != null && liquidacionId != null,
    staleTime: 30 * 1000,
  })
}

export function useEmpleadosParaElegirQuery() {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: personalKeys.paraElegir(currentSucursalId),
    queryFn: async (): Promise<EmpleadoParaElegir[]> => {
      const { data, error } = await supabase.rpc('empleados_para_elegir')
      if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo cargar la lista de empleados. Revisá la señal e intentá de nuevo.')
      return (data ?? []) as unknown as EmpleadoParaElegir[]
    },
    enabled: currentSucursalId != null,
    staleTime: 5 * 60 * 1000,
  })
}

/** ¿Este cliente es la cuenta de un empleado (admite la forma de pago «adelanto de sueldo»)? */
export function useClienteAdmiteAdelantoQuery(clienteId: number | string | null) {
  const { currentSucursalId } = useSucursal()
  // Los ids llegan como string del select y son bigint en el server.
  const id = clienteId == null || clienteId === '' ? null : Number(clienteId)
  return useQuery({
    queryKey: personalKeys.admiteAdelanto(currentSucursalId, id as number),
    queryFn: async (): Promise<boolean> => {
      const { data, error } = await supabase.rpc('cliente_admite_adelanto_sueldo', { p_cliente_id: id as number })
      if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo saber si el cliente admite adelanto de sueldo. Revisá la señal e intentá de nuevo.')
      return data === true
    },
    enabled: currentSucursalId != null && id != null && Number.isFinite(id),
    staleTime: 60 * 1000,
  })
}

export function useGuardarEmpleadoMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()
  // reportes-R3 (tanda 6 de #1603): el alta lleva una clave estable por contenido. Si la
  // respuesta se perdió y se reintenta lo mismo, el server devuelve el empleado del primer
  // intento en vez de darlo de alta otra vez. La edición no la lleva.
  const claveAlta = useRequestIdEstable()
  return useMutation({
    mutationFn: async (payload: GuardarEmpleadoPayload): Promise<number> => {
      const huella = huellaDeAlta(currentSucursalId, payload)
      const enviado = huella ? { ...payload, clave: payload.clave ?? claveAlta(huella) } : payload
      const { data, error } = await supabase.rpc('guardar_empleado', { p_empleado: enviado })
      if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo guardar el empleado. Revisá la lista del personal antes de reintentar, puede haber quedado registrado.')
      // Salió bien: la próxima alta igual es otra, con otra clave.
      if (huella) claveAlta.olvidar([huella])
      return data as unknown as number
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: personalKeys.all(currentSucursalId) })
    },
  })
}

export function useGuardarArregloMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()
  return useMutation({
    mutationFn: async ({ empleadoId, arreglo }: { empleadoId: number; arreglo: GuardarArregloPayload }): Promise<void> => {
      const { error } = await supabase.rpc('guardar_arreglo_empleado', { p_empleado_id: empleadoId, p_arreglo: arreglo })
      if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo guardar el arreglo de sueldo. Revisá la ficha del empleado antes de reintentar.')
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: personalKeys.all(currentSucursalId) })
    },
  })
}

export function useDarDeBajaEmpleadoMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()
  return useMutation({
    mutationFn: async ({ empleadoId, fecha }: { empleadoId: number; fecha: string }): Promise<void> => {
      const { error } = await supabase.rpc('dar_de_baja_empleado', { p_empleado_id: empleadoId, p_fecha: fecha })
      if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo dar de baja al empleado. Revisá la lista del personal antes de reintentar.')
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: personalKeys.all(currentSucursalId) })
    },
  })
}

export function useReactivarEmpleadoMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()
  return useMutation({
    mutationFn: async (empleadoId: number): Promise<void> => {
      const { error } = await supabase.rpc('reactivar_empleado', { p_empleado_id: empleadoId })
      if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo reactivar al empleado. Revisá la lista del personal antes de reintentar.')
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: personalKeys.all(currentSucursalId) })
    },
  })
}

export function useRegistrarMovimientoEmpleadoMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()
  // Com-B3 (#1554): una clave estable por contenido. Si la respuesta se perdió y se reintenta lo
  // mismo, el server devuelve el movimiento del primer intento en vez de registrarlo dos veces.
  const clave = useRequestIdEstable()
  return useMutation({
    mutationFn: async ({ empleadoId, movimiento }: { empleadoId: number; movimiento: MovimientoManualPayload }): Promise<void> => {
      const huella = huellaDeEscrituraEmpleado(currentSucursalId, 'movimiento', empleadoId, movimiento)
      const { error } = await supabase.rpc('registrar_movimiento_empleado', {
        p_empleado_id: empleadoId, p_movimiento: movimiento, p_clave: clave(huella),
      })
      if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo registrar el movimiento. Revisá la cuenta del empleado antes de reintentar, puede haber quedado registrado.')
      // Salió bien: el próximo movimiento igual es otro, con otra clave.
      clave.olvidar([huella])
    },
    // onSettled, no onSuccess: si la respuesta se perdió, el movimiento pudo quedar registrado y la cuenta
    // tiene que volver a pedirse para que quien reintenta vea qué pasó.
    onSettled: (_data, _error, { movimiento }) => {
      queryClient.invalidateQueries({ queryKey: personalKeys.all(currentSucursalId) })
      if (movimiento.origen_pago === 'rendicion') invalidarRendiciones(queryClient, currentSucursalId)
    },
  })
}

export function useRevertirMovimientoEmpleadoMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()
  return useMutation({
    mutationFn: async ({ movimientoId, motivo }: { movimientoId: number; motivo: string }): Promise<void> => {
      const { error } = await supabase.rpc('revertir_movimiento_empleado', { p_movimiento_id: movimientoId, p_motivo: motivo })
      if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo revertir el movimiento. Revisá la cuenta del empleado antes de reintentar.')
    },
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: personalKeys.all(currentSucursalId) })
      // Lo que se revierte puede ser un pago que había salido de una rendición.
      invalidarRendiciones(queryClient, currentSucursalId)
    },
  })
}

export function useLiquidarEmpleadoMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()
  // Com-B3 (#1554): como el movimiento. El reintento de la misma liquidación devuelve la del primer
  // intento; sin clave chocaría con «ese período ya no es el próximo».
  const clave = useRequestIdEstable()
  return useMutation({
    mutationFn: async ({ empleadoId, liquidacion }: { empleadoId: number; liquidacion: LiquidarPayload }): Promise<number> => {
      const huella = huellaDeEscrituraEmpleado(currentSucursalId, 'liquidacion', empleadoId, liquidacion)
      const { data, error } = await supabase.rpc('liquidar_empleado', {
        p_empleado_id: empleadoId, p_liquidacion: liquidacion, p_clave: clave(huella),
      })
      if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo confirmar la liquidación. Revisá la cuenta del empleado antes de reintentar, puede haber quedado registrada.')
      clave.olvidar([huella])
      return data as unknown as number
    },
    onSettled: (_data, _error, { liquidacion }) => {
      queryClient.invalidateQueries({ queryKey: personalKeys.all(currentSucursalId) })
      if (liquidacion.origen_pago === 'rendicion') invalidarRendiciones(queryClient, currentSucursalId)
    },
  })
}

export function useAnularLiquidacionMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()
  return useMutation({
    mutationFn: async ({ liquidacionId, motivo }: { liquidacionId: number; motivo: string }): Promise<void> => {
      const { error } = await supabase.rpc('anular_liquidacion', { p_liquidacion_id: liquidacionId, p_motivo: motivo })
      if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo confirmar la anulación. Revisá la cuenta del empleado antes de reintentar.')
    },
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: personalKeys.all(currentSucursalId) })
      // Si el pago salió de una rendición pendiente, se revierte y el efectivo vuelve.
      invalidarRendiciones(queryClient, currentSucursalId)
    },
  })
}
