import { describe, it, expect, afterEach, vi } from 'vitest'
import {
  causaDeConsultaFallida,
  mensajeDeConsultaFallida,
  MENSAJES_DE_CONSULTA_FALLIDA,
} from './mensajeDeConsultaFallida'
import { ErrorDeSupabase } from './errorDeSupabase'

afterEach(() => {
  vi.restoreAllMocks()
})

describe('causaDeConsultaFallida (1563-b6)', () => {
  it('sin servidor (supabase-js arma un objeto plano con code vacío): sin conexión', () => {
    expect(causaDeConsultaFallida({ message: 'TypeError: Failed to fetch', code: '' })).toBe('sin_conexion')
    expect(causaDeConsultaFallida(new TypeError('Load failed'))).toBe('sin_conexion')
  })

  it('un error ya normalizado que marca "sin servidor": sin conexión', () => {
    expect(causaDeConsultaFallida(new ErrorDeSupabase('Sin conexión: revisá la señal', { code: '' }, true))).toBe('sin_conexion')
  })

  it('un timeout del cliente: sin conexión', () => {
    expect(causaDeConsultaFallida(new Error('La consulta timed out after 15000ms'))).toBe('sin_conexion')
  })

  it('el dispositivo sin señal: sin conexión, sea cual sea el error', () => {
    vi.spyOn(navigator, 'onLine', 'get').mockReturnValue(false)
    expect(causaDeConsultaFallida({ message: 'x', code: 'PGRST201' })).toBe('sin_conexion')
  })

  it('un permiso denegado (42501) no es un problema de conexión', () => {
    expect(causaDeConsultaFallida({ message: 'permission denied for table pagos', code: '42501' })).toBe('sin_permiso')
    expect(causaDeConsultaFallida({ message: 'x', status: 403 })).toBe('sin_permiso')
    expect(causaDeConsultaFallida(new Error('new row violates row-level security policy'))).toBe('sin_permiso')
  })

  it('un JWT vencido es sesión, no permiso ni conexión', () => {
    expect(causaDeConsultaFallida({ message: 'JWT expired', code: 'PGRST301' })).toBe('sesion_vencida')
    expect(causaDeConsultaFallida({ message: 'x', status: 401 })).toBe('sesion_vencida')
  })

  it('un embed roto (PGRST201) o cualquier error de la base: error del servidor', () => {
    expect(causaDeConsultaFallida({ message: 'Could not embed', code: 'PGRST201' })).toBe('error_del_servidor')
    expect(causaDeConsultaFallida({ message: 'statement timeout', code: '57014' })).toBe('error_del_servidor')
  })

  it('un gateway caído (HTTP_5xx) es del servidor, no de la señal del usuario', () => {
    expect(causaDeConsultaFallida({ message: 'Error del servidor (HTTP 502)', code: 'HTTP_502' })).toBe('error_del_servidor')
  })

  it('un error sin nada que lo identifique (un bug del queryFn): error del servidor', () => {
    expect(causaDeConsultaFallida(new Error('Cannot read properties of undefined'))).toBe('error_del_servidor')
    expect(causaDeConsultaFallida(undefined)).toBe('error_del_servidor')
  })
})

describe('mensajeDeConsultaFallida', () => {
  it('cada causa tiene su texto y los cuatro son distintos', () => {
    expect(new Set(Object.values(MENSAJES_DE_CONSULTA_FALLIDA)).size).toBe(4)
  })

  it('"Verificá tu conexión" sólo sale cuando es la conexión', () => {
    expect(mensajeDeConsultaFallida({ message: 'Failed to fetch', code: '' })).toMatch(/conexión/)
    expect(mensajeDeConsultaFallida({ message: 'x', code: '42501' })).not.toMatch(/conexión/)
    expect(mensajeDeConsultaFallida({ message: 'x', code: 'PGRST201' })).not.toMatch(/conexión/)
  })

  it('no muestra códigos ni el texto crudo del server', () => {
    const texto = mensajeDeConsultaFallida({ message: 'permission denied for table pagos', code: '42501' })
    expect(texto).not.toMatch(/42501|pagos|PGRST|permission denied/)
  })
})
