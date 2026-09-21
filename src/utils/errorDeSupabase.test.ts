/**
 * Tests de `errorDeSupabase`.
 *
 * Las formas que se prueban NO son inventadas: son las dos que arma
 * `PostgrestBuilder` de supabase-js cuando no se usa `.throwOnError()`. Un test
 * que mockee el error como `new Error(...)` —que es lo que hacía el del modal—
 * pasa en verde con el bug puesto, porque `instanceof Error` sólo da false con
 * el objeto plano de verdad.
 */
import { describe, it, expect, afterEach, vi } from 'vitest'
import { errorDeSupabase } from './errorDeSupabase'

const SIN_CONEXION = 'Sin conexión: la baja NO se registró.'

function fingirOnLine(valor: boolean) {
  vi.spyOn(navigator, 'onLine', 'get').mockReturnValue(valor)
}

afterEach(() => {
  vi.restoreAllMocks()
})

describe('errorDeSupabase', () => {
  it('convierte el objeto plano de PostgREST en un Error de verdad', () => {
    fingirOnLine(true)
    const e = errorDeSupabase(
      {
        message: 'El stock del producto es 3 y la baja es de 5: dejaria stock negativo',
        details: null,
        hint: null,
        code: 'P0001',
      },
      SIN_CONEXION,
    )

    // Las dos mitades importan: si no es `instanceof Error`, la UI muestra su
    // fallback aunque el mensaje esté bien.
    expect(e).toBeInstanceOf(Error)
    expect(e.message).toMatch(/el stock del producto es 3/i)
  })

  it('conserva el mensaje de permisos del servidor', () => {
    fingirOnLine(true)
    const e = errorDeSupabase(
      { message: 'Acceso denegado: se requiere rol admin', details: '', hint: '', code: '42501' },
      SIN_CONEXION,
    )

    expect(e.message).toBe('Acceso denegado: se requiere rol admin')
  })

  it('traduce el fallo de red a un mensaje que se entiende', () => {
    fingirOnLine(true)
    const e = errorDeSupabase(
      {
        message: 'TypeError: Failed to fetch',
        details: 'TypeError: Failed to fetch',
        hint: '',
        code: '',
      },
      SIN_CONEXION,
    )

    expect(e).toBeInstanceOf(Error)
    expect(e.message).toBe(SIN_CONEXION)
    // "Failed to fetch" en pantalla, en un depósito, no es información.
    expect(e.message).not.toMatch(/failed to fetch/i)
  })

  it('trata el "Load failed" de WebKit igual que el de Chrome', () => {
    fingirOnLine(true)
    const e = errorDeSupabase(
      { message: 'TypeError: Load failed', details: '', hint: '', code: '' },
      SIN_CONEXION,
    )

    expect(e.message).toBe(SIN_CONEXION)
  })

  it('con el equipo offline avisa de la conexión aunque el mensaje no diga nada', () => {
    fingirOnLine(false)
    const e = errorDeSupabase({ message: '', details: '', hint: '', code: '' }, SIN_CONEXION)

    expect(e.message).toBe(SIN_CONEXION)
  })

  it('NO tapa el mensaje del servidor cuando navigator.onLine miente', () => {
    // Un celular con 4G de una barra reporta `onLine: false` con la request ya
    // contestada. El `code` es el discriminante: hubo servidor, hubo respuesta.
    fingirOnLine(false)
    const e = errorDeSupabase(
      { message: 'Acceso denegado: se requiere rol admin', details: '', hint: '', code: '42501' },
      SIN_CONEXION,
    )

    expect(e.message).toBe('Acceso denegado: se requiere rol admin')
  })

  it('deja pasar un Error de verdad sin cambiarle el mensaje', () => {
    fingirOnLine(true)
    const e = errorDeSupabase(new Error('No hay sucursal activa'), SIN_CONEXION)

    expect(e.message).toBe('No hay sucursal activa')
  })
})
