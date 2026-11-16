/**
 * #1602: el GPS se registra con el diagnóstico del equipo, y si el servidor
 * todavía no tiene la firma nueva (PGRST202) se registra igual, sin él.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'

const { rpc, llamadas } = vi.hoisted(() => {
  const llamadas: Array<{ nombre: string; params: Record<string, unknown>; headers: Record<string, string> }> = []
  const respuestas: Array<{ data: unknown; error: unknown }> = []
  const rpc = Object.assign(
    vi.fn((nombre: string, params: Record<string, unknown>) => {
      const llamada = { nombre, params, headers: {} as Record<string, string> }
      llamadas.push(llamada)
      const builder = {
        setHeader(k: string, v: string) { llamada.headers[k] = v; return builder },
        then(res: (v: unknown) => unknown, rej?: (e: unknown) => unknown) {
          return Promise.resolve(respuestas.shift() ?? { data: { success: true }, error: null }).then(res, rej)
        },
      }
      return builder
    }),
    { respuestas },
  )
  return { rpc, llamadas }
})

vi.mock('./supabase/base', () => ({ supabase: { rpc } }))
vi.mock('../utils/logger', () => ({ logger: { warn: vi.fn(), info: vi.fn(), error: vi.fn() } }))

import { registrarGeolocalizacionPedido } from './useRegistrarGeolocalizacionPedido'

const diagnostico = { permiso: 'denied', error: 1, instalada: true, navegador: 'chrome 131', so: 'android 10' } as const

beforeEach(() => {
  llamadas.length = 0
  rpc.respuestas.length = 0
  rpc.mockClear()
})

describe('registrarGeolocalizacionPedido', () => {
  it('manda el motivo y el diagnóstico de una captura denegada', async () => {
    await registrarGeolocalizacionPedido('600', { status: 'denied', diagnostico }, '  no me deja  ')
    expect(llamadas).toHaveLength(1)
    expect(llamadas[0].nombre).toBe('registrar_geolocalizacion_pedido')
    expect(llamadas[0].params).toEqual({
      p_pedido_id: 600, p_status: 'denied', p_motivo_omision: 'no me deja', p_diagnostico: diagnostico,
    })
    expect(llamadas[0].headers).toEqual({})
  })

  it('el replay le pone la sucursal de la operación al request', async () => {
    await registrarGeolocalizacionPedido(601, { status: 'timeout' }, null, { sucursalId: 4 })
    expect(llamadas[0].headers).toEqual({ 'X-Sucursal-ID': '4' })
    expect(llamadas[0].params).not.toHaveProperty('p_diagnostico')
  })

  it('sin la migración aplicada (PGRST202) repite sin el diagnóstico, con la misma sucursal', async () => {
    rpc.respuestas.push({ data: null, error: { code: 'PGRST202', message: 'Could not find the function' } })
    await registrarGeolocalizacionPedido(602, {
      status: 'ok', lat: -26.8, lng: -65.2, accuracy: 9, capturadoAt: '2026-11-15T12:00:00.000Z', diagnostico,
    }, undefined, { sucursalId: 3 })
    expect(llamadas).toHaveLength(2)
    expect(llamadas[1].params).toEqual({
      p_pedido_id: 602, p_status: 'ok', p_lat: -26.8, p_lng: -65.2, p_accuracy: 9, p_capturado_at: '2026-11-15T12:00:00.000Z',
    })
    expect(llamadas[1].headers).toEqual({ 'X-Sucursal-ID': '3' })
  })

  it('otro error no se repite, y nunca lanza', async () => {
    rpc.respuestas.push({ data: null, error: { code: '23514', message: 'check' } })
    await expect(registrarGeolocalizacionPedido(603, { status: 'denied', diagnostico })).resolves.toBeUndefined()
    expect(llamadas).toHaveLength(1)
  })
})
