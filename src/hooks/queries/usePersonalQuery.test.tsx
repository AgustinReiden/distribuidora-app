/**
 * Contrato de los hooks de Personal (entrega 3 de gastos) con el servidor.
 *
 * Todo va por RPC (no hay lectura ni escritura REST de empleados). Los mocks de
 * supabase siguen la forma real: el error es un objeto plano.
 */
import React from 'react'
import { describe, it, expect, vi, beforeAll, afterAll, beforeEach } from 'vitest'
import { renderHook, waitFor, configure, getConfig } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

// 1587-t3: con la máquina cargada (varias sesiones corriendo vitest, o la suite entera en el CI) los
// `waitFor` de este archivo se quedaban sin sus 5 s del setup y «llama empleados_para_elegir…» fallaba
// sin que nada estuviera roto. Margen propio, sólo para este archivo: cuando la consulta contesta, el
// `waitFor` vuelve en el acto, así que no alarga las corridas buenas.
const ESPERA_DEL_SETUP = getConfig().asyncUtilTimeout
beforeAll(() => configure({ asyncUtilTimeout: 20000 }))
afterAll(() => configure({ asyncUtilTimeout: ESPERA_DEL_SETUP }))

type ErrorDeSupabase = { message: string; details?: string; hint?: string; code: string }

const rpcCalls: Array<{ fn: string; args: Record<string, unknown> | undefined }> = []
let rpcResult: { data: unknown; error: ErrorDeSupabase | null } = { data: null, error: null }

vi.mock('../supabase/base', () => ({
  supabase: {
    rpc: (fn: string, args?: Record<string, unknown>) => {
      rpcCalls.push({ fn, args })
      return Promise.resolve(rpcResult)
    },
    auth: { getUser: vi.fn() },
  },
}))

let sucursalActual: number | null = 1
vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: sucursalActual }),
}))

import {
  personalKeys,
  usePersonalQuery,
  useCuentaEmpleadoQuery,
  useEmpleadosParaElegirQuery,
  useClienteAdmiteAdelantoQuery,
  useGuardarEmpleadoMutation,
  useGuardarArregloMutation,
  useDarDeBajaEmpleadoMutation,
  useReactivarEmpleadoMutation,
  useRegistrarMovimientoEmpleadoMutation,
  useRevertirMovimientoEmpleadoMutation,
  useVistaPreviaLiquidacionQuery,
  useLiquidacionQuery,
  useLiquidarEmpleadoMutation,
  useAnularLiquidacionMutation,
  useRendicionesDelDiaQuery,
  useComisionSinLiquidarQuery,
} from './usePersonalQuery'
import type {
  Empleado,
  CuentaEmpleado,
  EmpleadoParaElegir,
  GuardarEmpleadoPayload,
  GuardarArregloPayload,
  MovimientoManualPayload,
  LiquidarPayload,
  VistaPreviaLiquidacion,
  DetalleLiquidacion,
} from '../../types/personal'

function makeWrapper(qc: QueryClient) {
  return function Wrapper({ children }: { children: React.ReactNode }) {
    return <QueryClientProvider client={qc}>{children}</QueryClientProvider>
  }
}

function nuevoCliente() {
  return new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })
}

const ERROR_DE_RED: ErrorDeSupabase = { message: 'TypeError: Failed to fetch', code: '' }
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

const EMPLEADO: Empleado = {
  id: 7,
  nombre: 'Ana Pérez',
  puesto: 'ayudante',
  sucursal_id: 1,
  de_las_dos: false,
  cuil: null,
  fecha_ingreso: '2026-01-05',
  telefono: null,
  activo: true,
  fecha_baja: null,
  usuario: null,
  cliente: null,
  vehiculo: null,
  arreglo: { id: 3, vigente_desde: '2026-01-05', vigente_hasta: null, sueldo: 900000, frecuencia: 'mensual', comisiona: false },
  arranque: '2026-01-05',
  saldo: -15000,
  es_propio: false,
  periodo: null,
}

const ARREGLO: GuardarArregloPayload = {
  vigente_desde: '2026-11-01',
  sueldo: 950000,
  frecuencia: 'mensual',
  comisiona: false,
}

const MOVIMIENTO: MovimientoManualPayload = {
  tipo: 'adelanto',
  monto: 20000,
  fecha: '2026-10-28',
  observacion: null,
}

beforeEach(() => {
  rpcCalls.length = 0
  rpcResult = { data: null, error: null }
  sucursalActual = 1
})

describe('personalKeys', () => {
  it('arma las claves anidadas bajo ["personal", sucursal]', () => {
    expect(personalKeys.all(1)).toEqual(['personal', 1])
    expect(personalKeys.lista(1)).toEqual(['personal', 1, 'lista'])
    expect(personalKeys.cuenta(1, 7)).toEqual(['personal', 1, 'cuenta', 7])
    expect(personalKeys.paraElegir(1)).toEqual(['personal', 1, 'para-elegir'])
    expect(personalKeys.admiteAdelanto(1, 376)).toEqual(['personal', 1, 'admite-adelanto', 376])
    expect(personalKeys.vistaPrevia(1, 7)).toEqual(['personal', 1, 'vista-previa', 7])
    expect(personalKeys.liquidacion(1, 12)).toEqual(['personal', 1, 'liquidacion', 12])
  })
})

describe('usePersonalQuery', () => {
  it('llama listar_personal sin argumentos y devuelve el array', async () => {
    rpcResult = { data: [EMPLEADO], error: null }
    const { result } = renderHook(() => usePersonalQuery(), { wrapper: makeWrapper(nuevoCliente()) })

    await waitFor(() => expect(result.current.isSuccess).toBe(true))

    expect(result.current.data).toEqual([EMPLEADO])
    expect(rpcCalls).toHaveLength(1)
    expect(rpcCalls[0].fn).toBe('listar_personal')
    expect(rpcCalls[0].args ?? {}).toEqual({})
  })

  it('un jsonb nulo es una lista vacía', async () => {
    rpcResult = { data: null, error: null }
    const { result } = renderHook(() => usePersonalQuery(), { wrapper: makeWrapper(nuevoCliente()) })

    await waitFor(() => expect(result.current.isSuccess).toBe(true))

    expect(result.current.data).toEqual([])
  })

  it('sin sucursal no consulta', () => {
    sucursalActual = null
    renderHook(() => usePersonalQuery(), { wrapper: makeWrapper(nuevoCliente()) })
    expect(rpcCalls).toEqual([])
  })

  it('un error de red da el mensaje "Sin conexión"', async () => {
    rpcResult = { data: null, error: ERROR_DE_RED }
    const { result } = renderHook(() => usePersonalQuery(), { wrapper: makeWrapper(nuevoCliente()) })

    await waitFor(() => expect(result.current.isError).toBe(true))

    expect(result.current.error).toBeInstanceOf(Error)
    expect(result.current.error?.message).toContain('Sin conexión')
    expect(result.current.error?.message).toContain('cargar el personal')
  })

  it('el rechazo del server llega con su mensaje', async () => {
    rpcResult = { data: null, error: { message: 'No tenés permiso', code: '42501' } }
    const { result } = renderHook(() => usePersonalQuery(), { wrapper: makeWrapper(nuevoCliente()) })

    await waitFor(() => expect(result.current.isError).toBe(true))

    expect(result.current.error?.message).toBe('No tenés permiso')
  })
})

describe('useCuentaEmpleadoQuery', () => {
  it('manda p_empleado_id y devuelve la cuenta', async () => {
    const cuenta: CuentaEmpleado = { empleado: EMPLEADO, arreglos: [], movimientos: [], liquidaciones: [] }
    rpcResult = { data: cuenta, error: null }
    const { result } = renderHook(() => useCuentaEmpleadoQuery(7), { wrapper: makeWrapper(nuevoCliente()) })

    await waitFor(() => expect(result.current.isSuccess).toBe(true))

    expect(result.current.data).toEqual(cuenta)
    expect(rpcCalls).toEqual([{ fn: 'obtener_cuenta_empleado', args: { p_empleado_id: 7 } }])
  })

  it('la cuenta nunca se sirve de caché: al reabrirla vuelve a pedirla (los pagos no invalidan personalKeys)', async () => {
    const cuenta: CuentaEmpleado = { empleado: EMPLEADO, arreglos: [], movimientos: [], liquidaciones: [] }
    rpcResult = { data: cuenta, error: null }
    // El default global es de 5 minutos: la cuenta tiene que ignorarlo.
    const qc = new QueryClient({ defaultOptions: { queries: { retry: false, staleTime: 5 * 60 * 1000 } } })
    const primera = renderHook(() => useCuentaEmpleadoQuery(7), { wrapper: makeWrapper(qc) })
    await waitFor(() => expect(primera.result.current.isSuccess).toBe(true))
    primera.unmount()
    expect(rpcCalls).toHaveLength(1)

    const segunda = renderHook(() => useCuentaEmpleadoQuery(7), { wrapper: makeWrapper(qc) })
    await waitFor(() => expect(rpcCalls).toHaveLength(2))
    await waitFor(() => expect(segunda.result.current.isFetching).toBe(false))
  })

  it('sin empleado (null) no llama nada', () => {
    renderHook(() => useCuentaEmpleadoQuery(null), { wrapper: makeWrapper(nuevoCliente()) })
    expect(rpcCalls).toEqual([])
  })

  it('un error de red da el mensaje "Sin conexión"', async () => {
    rpcResult = { data: null, error: ERROR_DE_RED }
    const { result } = renderHook(() => useCuentaEmpleadoQuery(7), { wrapper: makeWrapper(nuevoCliente()) })

    await waitFor(() => expect(result.current.isError).toBe(true))

    expect(result.current.error?.message).toContain('Sin conexión')
  })
})

describe('useEmpleadosParaElegirQuery', () => {
  it('llama empleados_para_elegir sin argumentos y devuelve el array', async () => {
    const lista: EmpleadoParaElegir[] = [
      { id: 7, nombre: 'Ana Pérez', usuario_id: null, vehiculo_id: null, activo: true },
    ]
    rpcResult = { data: lista, error: null }
    const { result } = renderHook(() => useEmpleadosParaElegirQuery(), { wrapper: makeWrapper(nuevoCliente()) })

    await waitFor(() => expect(result.current.isSuccess).toBe(true))

    expect(result.current.data).toEqual(lista)
    expect(rpcCalls).toHaveLength(1)
    expect(rpcCalls[0].fn).toBe('empleados_para_elegir')
    expect(rpcCalls[0].args ?? {}).toEqual({})
  })

  it('sin sucursal no consulta', () => {
    sucursalActual = null
    renderHook(() => useEmpleadosParaElegirQuery(), { wrapper: makeWrapper(nuevoCliente()) })
    expect(rpcCalls).toEqual([])
  })
})

describe('useClienteAdmiteAdelantoQuery', () => {
  it("con '376' manda p_cliente_id numérico y devuelve el booleano", async () => {
    rpcResult = { data: true, error: null }
    const { result } = renderHook(() => useClienteAdmiteAdelantoQuery('376'), { wrapper: makeWrapper(nuevoCliente()) })

    await waitFor(() => expect(result.current.isSuccess).toBe(true))

    expect(result.current.data).toBe(true)
    expect(rpcCalls).toEqual([{ fn: 'cliente_admite_adelanto_sueldo', args: { p_cliente_id: 376 } }])
  })

  it('devuelve false si el server dice false', async () => {
    rpcResult = { data: false, error: null }
    const { result } = renderHook(() => useClienteAdmiteAdelantoQuery(376), { wrapper: makeWrapper(nuevoCliente()) })

    await waitFor(() => expect(result.current.isSuccess).toBe(true))

    expect(result.current.data).toBe(false)
  })

  it('sin cliente (null o vacío) no llama nada', () => {
    renderHook(() => useClienteAdmiteAdelantoQuery(null), { wrapper: makeWrapper(nuevoCliente()) })
    renderHook(() => useClienteAdmiteAdelantoQuery(''), { wrapper: makeWrapper(nuevoCliente()) })
    expect(rpcCalls).toEqual([])
  })
})

describe('useGuardarEmpleadoMutation', () => {
  it('manda p_empleado, devuelve el id e invalida el personal de la sucursal', async () => {
    rpcResult = { data: 12, error: null }
    const qc = nuevoCliente()
    const invalidar = vi.spyOn(qc, 'invalidateQueries')
    const { result } = renderHook(() => useGuardarEmpleadoMutation(), { wrapper: makeWrapper(qc) })
    const payload: GuardarEmpleadoPayload = {
      nombre: 'Ana Pérez',
      puesto: 'ayudante',
      sucursal_id: 1,
      de_las_dos: false,
      cuil: null,
      fecha_ingreso: '2026-01-05',
      telefono: null,
      usuario_id: null,
      cliente_id: null,
      vehiculo_id: null,
      arreglo: ARREGLO,
      saldo_inicial: null,
    }

    const id = await result.current.mutateAsync(payload)

    expect(id).toBe(12)
    // reportes-R3 (tanda 6 de #1603): cambió de regla. El alta lleva la clave del alta (un uuid).
    expect(rpcCalls).toEqual([{ fn: 'guardar_empleado', args: { p_empleado: { ...payload, clave: expect.stringMatching(UUID) } } }])
    await waitFor(() => expect(invalidar).toHaveBeenCalled())
    const keys = invalidar.mock.calls.map(c => (c[0] as { queryKey: unknown[] }).queryKey)
    expect(keys).toContainEqual(['personal', 1])
  })

  // reportes-R3 (tanda 6 de #1603): un reintento del mismo alta no duplica el empleado.
  it('el reintento del mismo alta después de un error manda la misma clave; la edición no lleva clave', async () => {
    rpcResult = { data: null, error: ERROR_DE_RED }
    const { result } = renderHook(() => useGuardarEmpleadoMutation(), { wrapper: makeWrapper(nuevoCliente()) })
    const alta = { nombre: 'Ana Pérez', puesto: 'ayudante', arreglo: ARREGLO } as GuardarEmpleadoPayload

    await result.current.mutateAsync(alta).catch(() => undefined)
    rpcResult = { data: 12, error: null }
    await result.current.mutateAsync({ ...alta })
    await result.current.mutateAsync({ ...alta })
    await result.current.mutateAsync({ ...alta, id: 12 })

    const claves = rpcCalls.map(c => (c.args?.p_empleado as { clave?: string }).clave)
    expect(claves[0]).toMatch(UUID)
    expect(claves[1]).toBe(claves[0])
    // Salió bien: otra alta igual es otra, con otra clave.
    expect(claves[2]).toMatch(UUID)
    expect(claves[2]).not.toBe(claves[0])
    expect(rpcCalls[3].args?.p_empleado).not.toHaveProperty('clave')
  })

  it('un error de red da el mensaje "Sin conexión"', async () => {
    rpcResult = { data: null, error: ERROR_DE_RED }
    const { result } = renderHook(() => useGuardarEmpleadoMutation(), { wrapper: makeWrapper(nuevoCliente()) })

    const error = await result.current
      .mutateAsync({ nombre: 'X' } as GuardarEmpleadoPayload)
      .catch((e: unknown) => e)

    expect((error as Error).message).toContain('Sin conexión')
    expect((error as Error).message).toContain('guardar el empleado')
  })
})

describe('useGuardarArregloMutation', () => {
  it('manda { p_empleado_id, p_arreglo } e invalida ["personal", 1]', async () => {
    const qc = nuevoCliente()
    const invalidar = vi.spyOn(qc, 'invalidateQueries')
    const { result } = renderHook(() => useGuardarArregloMutation(), { wrapper: makeWrapper(qc) })

    await result.current.mutateAsync({ empleadoId: 7, arreglo: ARREGLO })

    expect(rpcCalls).toEqual([
      { fn: 'guardar_arreglo_empleado', args: { p_empleado_id: 7, p_arreglo: ARREGLO } },
    ])
    await waitFor(() => expect(invalidar).toHaveBeenCalled())
    const keys = invalidar.mock.calls.map(c => (c[0] as { queryKey: unknown[] }).queryKey)
    expect(keys).toContainEqual(['personal', 1])
  })

  it('el rechazo del server llega como Error con su mensaje', async () => {
    rpcResult = { data: null, error: { message: 'El arreglo se superpone', code: 'P0001' } }
    const { result } = renderHook(() => useGuardarArregloMutation(), { wrapper: makeWrapper(nuevoCliente()) })

    const error = await result.current.mutateAsync({ empleadoId: 7, arreglo: ARREGLO }).catch((e: unknown) => e)

    expect((error as Error).message).toBe('El arreglo se superpone')
  })
})

describe('useDarDeBajaEmpleadoMutation', () => {
  it('manda { p_empleado_id, p_fecha } e invalida el personal', async () => {
    const qc = nuevoCliente()
    const invalidar = vi.spyOn(qc, 'invalidateQueries')
    const { result } = renderHook(() => useDarDeBajaEmpleadoMutation(), { wrapper: makeWrapper(qc) })

    await result.current.mutateAsync({ empleadoId: 7, fecha: '2026-10-31' })

    expect(rpcCalls).toEqual([
      { fn: 'dar_de_baja_empleado', args: { p_empleado_id: 7, p_fecha: '2026-10-31' } },
    ])
    await waitFor(() => expect(invalidar).toHaveBeenCalled())
    const keys = invalidar.mock.calls.map(c => (c[0] as { queryKey: unknown[] }).queryKey)
    expect(keys).toContainEqual(['personal', 1])
  })
})

describe('useReactivarEmpleadoMutation', () => {
  it('manda { p_empleado_id } e invalida el personal', async () => {
    const qc = nuevoCliente()
    const invalidar = vi.spyOn(qc, 'invalidateQueries')
    const { result } = renderHook(() => useReactivarEmpleadoMutation(), { wrapper: makeWrapper(qc) })

    await result.current.mutateAsync(7)

    expect(rpcCalls).toEqual([{ fn: 'reactivar_empleado', args: { p_empleado_id: 7 } }])
    await waitFor(() => expect(invalidar).toHaveBeenCalled())
    const keys = invalidar.mock.calls.map(c => (c[0] as { queryKey: unknown[] }).queryKey)
    expect(keys).toContainEqual(['personal', 1])
  })
})

describe('useRegistrarMovimientoEmpleadoMutation', () => {
  it('manda { p_empleado_id, p_movimiento } e invalida el personal', async () => {
    const qc = nuevoCliente()
    const invalidar = vi.spyOn(qc, 'invalidateQueries')
    const { result } = renderHook(() => useRegistrarMovimientoEmpleadoMutation(), { wrapper: makeWrapper(qc) })

    await result.current.mutateAsync({ empleadoId: 7, movimiento: MOVIMIENTO })

    expect(rpcCalls).toEqual([
      // Com-B3 (#1554): cambió de regla. Lleva la clave del intento (un uuid).
      { fn: 'registrar_movimiento_empleado', args: { p_empleado_id: 7, p_movimiento: MOVIMIENTO, p_clave: expect.stringMatching(UUID) } },
    ])
    await waitFor(() => expect(invalidar).toHaveBeenCalled())
    const keys = invalidar.mock.calls.map(c => (c[0] as { queryKey: unknown[] }).queryKey)
    expect(keys).toContainEqual(['personal', 1])
  })

  // Com-B3 (#1554): el doble toque (la respuesta se perdió y se vuelve a mandar lo mismo) no duplica.
  it('el reintento del mismo movimiento después de un error manda la misma clave; otro movimiento, otra', async () => {
    rpcResult = { data: null, error: ERROR_DE_RED }
    const { result } = renderHook(() => useRegistrarMovimientoEmpleadoMutation(), { wrapper: makeWrapper(nuevoCliente()) })

    await result.current.mutateAsync({ empleadoId: 7, movimiento: MOVIMIENTO }).catch(() => undefined)
    rpcResult = { data: 55, error: null }
    await result.current.mutateAsync({ empleadoId: 7, movimiento: { ...MOVIMIENTO } })
    // Salió bien: el mismo contenido otra vez es otro movimiento.
    await result.current.mutateAsync({ empleadoId: 7, movimiento: { ...MOVIMIENTO } })
    // Otro monto u otro empleado, otra clave.
    await result.current.mutateAsync({ empleadoId: 7, movimiento: { ...MOVIMIENTO, monto: 20001 } })
    await result.current.mutateAsync({ empleadoId: 8, movimiento: { ...MOVIMIENTO } })

    const claves = rpcCalls.map(c => c.args?.p_clave as string)
    expect(claves[0]).toMatch(UUID)
    expect(claves[1]).toBe(claves[0])
    expect(new Set(claves.slice(1)).size).toBe(4)
  })

  it('un error de red da el mensaje "Sin conexión" de registrar el movimiento', async () => {
    rpcResult = { data: null, error: ERROR_DE_RED }
    const { result } = renderHook(() => useRegistrarMovimientoEmpleadoMutation(), { wrapper: makeWrapper(nuevoCliente()) })

    const error = await result.current.mutateAsync({ empleadoId: 7, movimiento: MOVIMIENTO }).catch((e: unknown) => e)

    expect((error as Error).message).toContain('Sin conexión')
    expect((error as Error).message).toContain('registrar el movimiento')
  })
})

describe('useRevertirMovimientoEmpleadoMutation', () => {
  it('manda { p_movimiento_id, p_motivo } e invalida el personal', async () => {
    const qc = nuevoCliente()
    const invalidar = vi.spyOn(qc, 'invalidateQueries')
    const { result } = renderHook(() => useRevertirMovimientoEmpleadoMutation(), { wrapper: makeWrapper(qc) })

    await result.current.mutateAsync({ movimientoId: 55, motivo: 'Cargado dos veces' })

    expect(rpcCalls).toEqual([
      { fn: 'revertir_movimiento_empleado', args: { p_movimiento_id: 55, p_motivo: 'Cargado dos veces' } },
    ])
    await waitFor(() => expect(invalidar).toHaveBeenCalled())
    const keys = invalidar.mock.calls.map(c => (c[0] as { queryKey: unknown[] }).queryKey)
    expect(keys).toContainEqual(['personal', 1])
  })
})

const LIQUIDACION: LiquidarPayload = {
  desde: '2026-10-26',
  hasta: '2026-11-01',
  sueldo: 650000,
  motivo_sueldo: null,
  pago: 400000,
  fecha_pago: '2026-10-30',
  a_pagar_esperado: 994560,
  origen_pago: 'oficina',
  rendicion_transportista_id: null,
  rendicion_fecha: null,
}

const clavesInvalidadas = (invalidar: { mock: { calls: unknown[][] } }) =>
  invalidar.mock.calls.map(c => (c[0] as { queryKey: unknown[] }).queryKey)

describe('useVistaPreviaLiquidacionQuery', () => {
  it('sin empleado (null) no llama nada', () => {
    renderHook(() => useVistaPreviaLiquidacionQuery(null), { wrapper: makeWrapper(nuevoCliente()) })
    expect(rpcCalls).toHaveLength(0)
  })

  it('con id llama previsualizar_liquidacion con p_empleado_id y devuelve la vista', async () => {
    const vista = { a_pagar: 994560 } as unknown as VistaPreviaLiquidacion
    rpcResult = { data: vista, error: null }
    const { result } = renderHook(() => useVistaPreviaLiquidacionQuery(7), { wrapper: makeWrapper(nuevoCliente()) })

    await waitFor(() => expect(result.current.isSuccess).toBe(true))

    expect(result.current.data).toEqual(vista)
    expect(rpcCalls).toEqual([{ fn: 'previsualizar_liquidacion', args: { p_empleado_id: 7 } }])
  })

  it('un empleado sin nada para liquidar (null) es un dato, no un error', async () => {
    rpcResult = { data: null, error: null }
    const { result } = renderHook(() => useVistaPreviaLiquidacionQuery(7), { wrapper: makeWrapper(nuevoCliente()) })

    await waitFor(() => expect(result.current.isSuccess).toBe(true))

    expect(result.current.data).toBeNull()
  })

  it('nunca se sirve de caché: los pagos mueven el saldo sin invalidar', async () => {
    rpcResult = { data: null, error: null }
    const qc = new QueryClient({ defaultOptions: { queries: { retry: false, staleTime: 5 * 60 * 1000 } } })
    const primera = renderHook(() => useVistaPreviaLiquidacionQuery(7), { wrapper: makeWrapper(qc) })
    await waitFor(() => expect(primera.result.current.isSuccess).toBe(true))
    primera.unmount()
    renderHook(() => useVistaPreviaLiquidacionQuery(7), { wrapper: makeWrapper(qc) })
    await waitFor(() => expect(rpcCalls).toHaveLength(2))
  })

  it('un error de red da el mensaje "Sin conexión"', async () => {
    rpcResult = { data: null, error: ERROR_DE_RED }
    const { result } = renderHook(() => useVistaPreviaLiquidacionQuery(7), { wrapper: makeWrapper(nuevoCliente()) })

    await waitFor(() => expect(result.current.isError).toBe(true))

    expect(result.current.error?.message).toContain('Sin conexión')
  })
})

describe('useLiquidacionQuery', () => {
  it('sin liquidación (null) no llama nada', () => {
    renderHook(() => useLiquidacionQuery(null), { wrapper: makeWrapper(nuevoCliente()) })
    expect(rpcCalls).toHaveLength(0)
  })

  it('con id llama obtener_liquidacion con p_liquidacion_id', async () => {
    const detalle = { id: 12 } as unknown as DetalleLiquidacion
    rpcResult = { data: detalle, error: null }
    const { result } = renderHook(() => useLiquidacionQuery(12), { wrapper: makeWrapper(nuevoCliente()) })

    await waitFor(() => expect(result.current.isSuccess).toBe(true))

    expect(result.current.data).toEqual(detalle)
    expect(rpcCalls).toEqual([{ fn: 'obtener_liquidacion', args: { p_liquidacion_id: 12 } }])
  })

  it('un error de red da el mensaje "Sin conexión"', async () => {
    rpcResult = { data: null, error: ERROR_DE_RED }
    const { result } = renderHook(() => useLiquidacionQuery(12), { wrapper: makeWrapper(nuevoCliente()) })

    await waitFor(() => expect(result.current.isError).toBe(true))

    expect(result.current.error?.message).toContain('Sin conexión')
  })
})

describe('useLiquidarEmpleadoMutation', () => {
  it('manda { p_empleado_id, p_liquidacion }, devuelve el id e invalida el personal', async () => {
    rpcResult = { data: 31, error: null }
    const qc = nuevoCliente()
    const invalidar = vi.spyOn(qc, 'invalidateQueries')
    const { result } = renderHook(() => useLiquidarEmpleadoMutation(), { wrapper: makeWrapper(qc) })

    const id = await result.current.mutateAsync({ empleadoId: 7, liquidacion: LIQUIDACION })

    expect(id).toBe(31)
    expect(rpcCalls).toEqual([
      // Com-B3 (#1554): cambió de regla. Lleva la clave del intento (un uuid).
      { fn: 'liquidar_empleado', args: { p_empleado_id: 7, p_liquidacion: LIQUIDACION, p_clave: expect.stringMatching(UUID) } },
    ])
    await waitFor(() => expect(invalidar).toHaveBeenCalled())
    expect(clavesInvalidadas(invalidar)).toContainEqual(['personal', 1])
  })

  // Com-B3 (#1554): la misma liquidación reintentada lleva la misma clave; el server devuelve la del primero.
  it('el reintento de la misma liquidación después de un error manda la misma clave', async () => {
    rpcResult = { data: null, error: ERROR_DE_RED }
    const { result } = renderHook(() => useLiquidarEmpleadoMutation(), { wrapper: makeWrapper(nuevoCliente()) })

    await result.current.mutateAsync({ empleadoId: 7, liquidacion: LIQUIDACION }).catch(() => undefined)
    rpcResult = { data: 31, error: null }
    await result.current.mutateAsync({ empleadoId: 7, liquidacion: { ...LIQUIDACION } })
    await result.current.mutateAsync({ empleadoId: 7, liquidacion: { ...LIQUIDACION, pago: LIQUIDACION.pago - 1 } })

    const claves = rpcCalls.map(c => c.args?.p_clave as string)
    expect(claves[0]).toMatch(UUID)
    expect(claves[1]).toBe(claves[0])
    expect(claves[2]).toMatch(UUID)
    expect(claves[2]).not.toBe(claves[0])
  })

  it('con la plata de la oficina no toca las rendiciones', async () => {
    rpcResult = { data: 31, error: null }
    const qc = nuevoCliente()
    const invalidar = vi.spyOn(qc, 'invalidateQueries')
    const { result } = renderHook(() => useLiquidarEmpleadoMutation(), { wrapper: makeWrapper(qc) })

    await result.current.mutateAsync({ empleadoId: 7, liquidacion: LIQUIDACION })

    await waitFor(() => expect(invalidar).toHaveBeenCalled())
    expect(clavesInvalidadas(invalidar)).not.toContainEqual(['gastos', 1])
  })

  it('un pago de rendición invalida también las rendiciones', async () => {
    rpcResult = { data: 31, error: null }
    const qc = nuevoCliente()
    const invalidar = vi.spyOn(qc, 'invalidateQueries')
    const { result } = renderHook(() => useLiquidarEmpleadoMutation(), { wrapper: makeWrapper(qc) })

    await result.current.mutateAsync({
      empleadoId: 7,
      liquidacion: { ...LIQUIDACION, origen_pago: 'rendicion', rendicion_transportista_id: 'u-9', rendicion_fecha: '2026-10-30' },
    })

    await waitFor(() => expect(invalidar).toHaveBeenCalled())
    const keys = clavesInvalidadas(invalidar)
    expect(keys).toContainEqual(['personal', 1])
    expect(keys).toContainEqual(['gastos', 1])
  })

  it('un error de red da el mensaje "Sin conexión" de la liquidación', async () => {
    rpcResult = { data: null, error: ERROR_DE_RED }
    const { result } = renderHook(() => useLiquidarEmpleadoMutation(), { wrapper: makeWrapper(nuevoCliente()) })

    const error = await result.current.mutateAsync({ empleadoId: 7, liquidacion: LIQUIDACION }).catch((e: unknown) => e)

    expect((error as Error).message).toBe(
      'Sin conexión: no se pudo confirmar la liquidación. Revisá la cuenta del empleado antes de reintentar, puede haber quedado registrada.',
    )
  })

  it('el rechazo del server llega con su mensaje', async () => {
    rpcResult = { data: null, error: { message: 'Algo cambió desde que abriste la liquidación: revisá los números antes de confirmar', code: 'P0001' } }
    const { result } = renderHook(() => useLiquidarEmpleadoMutation(), { wrapper: makeWrapper(nuevoCliente()) })

    const error = await result.current.mutateAsync({ empleadoId: 7, liquidacion: LIQUIDACION }).catch((e: unknown) => e)

    expect((error as Error).message).toContain('Algo cambió')
  })
})

describe('useAnularLiquidacionMutation', () => {
  it('manda { p_liquidacion_id, p_motivo } e invalida el personal y las rendiciones', async () => {
    rpcResult = { data: null, error: null }
    const qc = nuevoCliente()
    const invalidar = vi.spyOn(qc, 'invalidateQueries')
    const { result } = renderHook(() => useAnularLiquidacionMutation(), { wrapper: makeWrapper(qc) })

    await result.current.mutateAsync({ liquidacionId: 31, motivo: 'Faltó una boleta' })

    expect(rpcCalls).toEqual([
      { fn: 'anular_liquidacion', args: { p_liquidacion_id: 31, p_motivo: 'Faltó una boleta' } },
    ])
    await waitFor(() => expect(invalidar).toHaveBeenCalled())
    const keys = clavesInvalidadas(invalidar)
    expect(keys).toContainEqual(['personal', 1])
    expect(keys).toContainEqual(['gastos', 1])
  })

  it('un error de red da el mensaje "Sin conexión" de la anulación', async () => {
    rpcResult = { data: null, error: ERROR_DE_RED }
    const { result } = renderHook(() => useAnularLiquidacionMutation(), { wrapper: makeWrapper(nuevoCliente()) })

    const error = await result.current.mutateAsync({ liquidacionId: 31, motivo: 'x' }).catch((e: unknown) => e)

    expect((error as Error).message).toContain('Sin conexión')
    expect((error as Error).message).toContain('la anulación')
  })
})

describe('registrar y revertir un movimiento con plata de una rendición', () => {
  it('un pago de rendición invalida también las rendiciones', async () => {
    const qc = nuevoCliente()
    const invalidar = vi.spyOn(qc, 'invalidateQueries')
    const { result } = renderHook(() => useRegistrarMovimientoEmpleadoMutation(), { wrapper: makeWrapper(qc) })

    await result.current.mutateAsync({
      empleadoId: 7,
      movimiento: {
        tipo: 'pago', monto: 50000, fecha: '2026-10-30', observacion: null,
        origen_pago: 'rendicion', rendicion_transportista_id: 'u-9', rendicion_fecha: '2026-10-30',
      },
    })

    await waitFor(() => expect(invalidar).toHaveBeenCalled())
    expect(clavesInvalidadas(invalidar)).toContainEqual(['gastos', 1])
  })

  it('revertir un pago también las invalida (puede haber salido de una rendición)', async () => {
    const qc = nuevoCliente()
    const invalidar = vi.spyOn(qc, 'invalidateQueries')
    const { result } = renderHook(() => useRevertirMovimientoEmpleadoMutation(), { wrapper: makeWrapper(qc) })

    await result.current.mutateAsync({ movimientoId: 55, motivo: 'Cargado dos veces' })

    await waitFor(() => expect(invalidar).toHaveBeenCalled())
    expect(clavesInvalidadas(invalidar)).toContainEqual(['gastos', 1])
  })
})

describe('las mutations de plata invalidan también cuando fallan', () => {
  // El mensaje de error manda a "revisar la cuenta antes de reintentar": si nada la vuelve a pedir,
  // quien reintenta lo hace a ciegas (y un pago suelto se duplica).
  const claves = (invalidar: { mock: { calls: unknown[][] } }) =>
    invalidar.mock.calls.map(c => (c[0] as { queryKey: unknown[] }).queryKey)

  const PAGO_RENDICION: MovimientoManualPayload = {
    tipo: 'pago', monto: 50000, fecha: '2026-10-30', observacion: null,
    origen_pago: 'rendicion', rendicion_transportista_id: 'u-9', rendicion_fecha: '2026-10-30',
  }

  it('registrar un movimiento (con la rendición si el pago salía de una)', async () => {
    rpcResult = { data: null, error: ERROR_DE_RED }
    const qc = nuevoCliente()
    const invalidar = vi.spyOn(qc, 'invalidateQueries')
    const { result } = renderHook(() => useRegistrarMovimientoEmpleadoMutation(), { wrapper: makeWrapper(qc) })

    await result.current.mutateAsync({ empleadoId: 7, movimiento: PAGO_RENDICION }).catch(() => undefined)

    await waitFor(() => expect(invalidar).toHaveBeenCalled())
    expect(claves(invalidar)).toContainEqual(['personal', 1])
    expect(claves(invalidar)).toContainEqual(['gastos', 1])
  })

  it('registrar un adelanto no toca las rendiciones, falle o no', async () => {
    rpcResult = { data: null, error: ERROR_DE_RED }
    const qc = nuevoCliente()
    const invalidar = vi.spyOn(qc, 'invalidateQueries')
    const { result } = renderHook(() => useRegistrarMovimientoEmpleadoMutation(), { wrapper: makeWrapper(qc) })

    await result.current.mutateAsync({ empleadoId: 7, movimiento: MOVIMIENTO }).catch(() => undefined)

    await waitFor(() => expect(invalidar).toHaveBeenCalled())
    expect(claves(invalidar)).toContainEqual(['personal', 1])
    expect(claves(invalidar)).not.toContainEqual(['gastos', 1])
  })

  it('revertir un movimiento', async () => {
    rpcResult = { data: null, error: ERROR_DE_RED }
    const qc = nuevoCliente()
    const invalidar = vi.spyOn(qc, 'invalidateQueries')
    const { result } = renderHook(() => useRevertirMovimientoEmpleadoMutation(), { wrapper: makeWrapper(qc) })

    await result.current.mutateAsync({ movimientoId: 55, motivo: 'x' }).catch(() => undefined)

    await waitFor(() => expect(invalidar).toHaveBeenCalled())
    expect(claves(invalidar)).toContainEqual(['personal', 1])
    expect(claves(invalidar)).toContainEqual(['gastos', 1])
  })

  it('liquidar (con la rendición si el pago salía de una)', async () => {
    rpcResult = { data: null, error: ERROR_DE_RED }
    const qc = nuevoCliente()
    const invalidar = vi.spyOn(qc, 'invalidateQueries')
    const { result } = renderHook(() => useLiquidarEmpleadoMutation(), { wrapper: makeWrapper(qc) })

    await result.current.mutateAsync({
      empleadoId: 7,
      liquidacion: { ...LIQUIDACION, origen_pago: 'rendicion', rendicion_transportista_id: 'u-9', rendicion_fecha: '2026-10-30' },
    }).catch(() => undefined)

    await waitFor(() => expect(invalidar).toHaveBeenCalled())
    expect(claves(invalidar)).toContainEqual(['personal', 1])
    expect(claves(invalidar)).toContainEqual(['gastos', 1])
  })

  it('liquidar con la plata de la oficina no toca las rendiciones', async () => {
    rpcResult = { data: null, error: ERROR_DE_RED }
    const qc = nuevoCliente()
    const invalidar = vi.spyOn(qc, 'invalidateQueries')
    const { result } = renderHook(() => useLiquidarEmpleadoMutation(), { wrapper: makeWrapper(qc) })

    await result.current.mutateAsync({ empleadoId: 7, liquidacion: LIQUIDACION }).catch(() => undefined)

    await waitFor(() => expect(invalidar).toHaveBeenCalled())
    expect(claves(invalidar)).toContainEqual(['personal', 1])
    expect(claves(invalidar)).not.toContainEqual(['gastos', 1])
  })

  it('anular una liquidación', async () => {
    rpcResult = { data: null, error: ERROR_DE_RED }
    const qc = nuevoCliente()
    const invalidar = vi.spyOn(qc, 'invalidateQueries')
    const { result } = renderHook(() => useAnularLiquidacionMutation(), { wrapper: makeWrapper(qc) })

    await result.current.mutateAsync({ liquidacionId: 31, motivo: 'x' }).catch(() => undefined)

    await waitFor(() => expect(invalidar).toHaveBeenCalled())
    expect(claves(invalidar)).toContainEqual(['personal', 1])
    expect(claves(invalidar)).toContainEqual(['gastos', 1])
  })
})

// #1534 y m7 (#1392): las rendiciones de un día, con el efectivo que les queda (la cuenta de la grilla).
describe('useRendicionesDelDiaQuery', () => {
  it('pide obtener_resumen_rendiciones de ese día y calcula el efectivo a entregar', async () => {
    rpcResult = {
      data: [{
        fecha: '2026-10-30', transportista_id: 'u-enc', transportista_nombre: 'Encargada Ana', total_efectivo: 8000,
        total_gastos: 1000, total_pagos_personal: 2000, total_faltantes_empleados: 0, estado: 'pendiente',
      }],
      error: null,
    }
    const { result } = renderHook(() => useRendicionesDelDiaQuery('2026-10-30'), { wrapper: makeWrapper(nuevoCliente()) })

    await waitFor(() => expect(result.current.isSuccess).toBe(true))

    expect(rpcCalls).toEqual([{
      fn: 'obtener_resumen_rendiciones',
      args: { p_fecha_desde: '2026-10-30', p_fecha_hasta: '2026-10-30', p_transportista_id: null },
    }])
    expect(result.current.data).toEqual([
      { transportista_id: 'u-enc', transportista_nombre: 'Encargada Ana', efectivo_a_entregar: 5000, cerrada: false },
    ])
  })

  it('sin día no pide nada', () => {
    renderHook(() => useRendicionesDelDiaQuery(null), { wrapper: makeWrapper(nuevoCliente()) })
    expect(rpcCalls).toHaveLength(0)
  })
})

// m4 (#1392): la comisión sin liquidar de una ficha, para avisar antes de cambiarla de sucursal.
describe('useComisionSinLiquidarQuery', () => {
  it('pide comision_sin_liquidar_empleado sólo cuando se lo habilita', async () => {
    const aviso = 'Tiene $ 2.000,00 de comisión sin liquidar en Tucuman: liquidalo antes de pasarlo de sucursal'
    rpcResult = { data: { monto: '2000.00', aviso }, error: null }
    const qc = nuevoCliente()
    renderHook(() => useComisionSinLiquidarQuery(7, false), { wrapper: makeWrapper(qc) })
    expect(rpcCalls).toHaveLength(0)

    const { result } = renderHook(() => useComisionSinLiquidarQuery(7, true), { wrapper: makeWrapper(qc) })
    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(result.current.data).toEqual({ monto: 2000, aviso })
    expect(rpcCalls).toEqual([{ fn: 'comision_sin_liquidar_empleado', args: { p_empleado_id: 7 } }])
  })
})
