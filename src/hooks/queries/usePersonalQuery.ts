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
import type {
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
  return useMutation({
    mutationFn: async (payload: GuardarEmpleadoPayload): Promise<number> => {
      const { data, error } = await supabase.rpc('guardar_empleado', { p_empleado: payload })
      if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo guardar el empleado. Revisá la lista del personal antes de reintentar, puede haber quedado registrado.')
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
  return useMutation({
    mutationFn: async ({ empleadoId, movimiento }: { empleadoId: number; movimiento: MovimientoManualPayload }): Promise<void> => {
      const { error } = await supabase.rpc('registrar_movimiento_empleado', { p_empleado_id: empleadoId, p_movimiento: movimiento })
      // No es idempotente: si la respuesta se perdió, reintentar a ciegas duplica el movimiento.
      if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo registrar el movimiento. Revisá la cuenta del empleado antes de reintentar, puede haber quedado registrado.')
    },
    onSuccess: (_data, { movimiento }) => {
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
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: personalKeys.all(currentSucursalId) })
      // Lo que se revierte puede ser un pago que había salido de una rendición.
      invalidarRendiciones(queryClient, currentSucursalId)
    },
  })
}

export function useLiquidarEmpleadoMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()
  return useMutation({
    mutationFn: async ({ empleadoId, liquidacion }: { empleadoId: number; liquidacion: LiquidarPayload }): Promise<number> => {
      const { data, error } = await supabase.rpc('liquidar_empleado', { p_empleado_id: empleadoId, p_liquidacion: liquidacion })
      // No es idempotente en la red: si la respuesta se perdió, el período ya pudo quedar liquidado.
      if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo confirmar la liquidación. Revisá la cuenta del empleado antes de reintentar, puede haber quedado registrada.')
      return data as unknown as number
    },
    onSuccess: (_data, { liquidacion }) => {
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
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: personalKeys.all(currentSucursalId) })
      // Si el pago salió de una rendición pendiente, se revierte y el efectivo vuelve.
      invalidarRendiciones(queryClient, currentSucursalId)
    },
  })
}
