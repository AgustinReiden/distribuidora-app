/**
 * Los errores de `traerTodo` / `traerTodoVerificado` se normalizan (#1011).
 *
 * Antes armaban `new Error(\`Error cargando ${etiqueta}: ${error.message}\`)`:
 * la etiqueta se conservaba, pero se perdía el `code` y, sin servidor, el
 * mensaje era "Error cargando X: TypeError: Failed to fetch". Ahora pasan por
 * `errorDeSupabase`: con servidor el mensaje sigue siendo el de siempre (y
 * conserva `code`); sin servidor dice que no hubo conexión y NOMBRA la etiqueta.
 *
 * Las dos formas del error son las reales de supabase-js (ver
 * errorDeSupabase.test.ts). Los tests viejos de paginacion.test.ts no se tocan:
 * fijan el caso con servidor sin `code`.
 */
import { describe, it, expect } from 'vitest'
import { traerTodo, traerTodoVerificado } from './paginacion'
import { ErrorDeSupabase } from './errorDeSupabase'

const ERROR_DE_RED = { message: 'TypeError: Failed to fetch', details: '', hint: '', code: '' }
const ERROR_DE_SERVIDOR = { message: 'permission denied for table pedidos', details: '', hint: '', code: '42501' }

function tablaQueFalla(error: unknown) {
  return () => ({
    range: () => Promise.resolve({ data: null, error: error as { message: string } }),
  })
}

async function rechazo(p: Promise<unknown>): Promise<ErrorDeSupabase> {
  return (await p.catch((e: unknown) => e)) as ErrorDeSupabase
}

describe('traerTodo — errores normalizados', () => {
  it('sin servidor: mensaje de sin conexión que nombra qué se cargaba', async () => {
    const e = await rechazo(traerTodo(tablaQueFalla(ERROR_DE_RED), { etiqueta: 'cobranzas' }))

    expect(e).toBeInstanceOf(ErrorDeSupabase)
    expect(e.sinServidor).toBe(true)
    expect(e.message).toMatch(/^Sin conexión/)
    expect(e.message).toContain('cobranzas')
    expect(e.message).not.toMatch(/failed to fetch/i)
  })

  it('con servidor: conserva "Error cargando <etiqueta>: <mensaje>" y el code', async () => {
    const e = await rechazo(traerTodo(tablaQueFalla(ERROR_DE_SERVIDOR), { etiqueta: 'cobranzas' }))

    expect(e).toBeInstanceOf(ErrorDeSupabase)
    expect(e.sinServidor).toBe(false)
    expect(e.message).toBe('Error cargando cobranzas: permission denied for table pedidos')
    expect(e.code).toBe('42501')
  })
})

describe('traerTodoVerificado — error del conteo normalizado', () => {
  const opciones = (error: unknown) => ({
    etiqueta: 'pedidos',
    contar: () => Promise.resolve({ count: null, error: error as { message: string } }),
  })

  it('sin servidor: mensaje de sin conexión que nombra qué se contaba', async () => {
    const e = await rechazo(traerTodoVerificado(tablaQueFalla(null), opciones(ERROR_DE_RED)))

    expect(e).toBeInstanceOf(ErrorDeSupabase)
    expect(e.sinServidor).toBe(true)
    expect(e.message).toMatch(/^Sin conexión/)
    expect(e.message).toContain('pedidos')
    expect(e.message).not.toMatch(/failed to fetch/i)
  })

  it('con servidor: conserva "No se pudo contar <etiqueta>: <mensaje>" y el code', async () => {
    const e = await rechazo(traerTodoVerificado(tablaQueFalla(null), opciones(ERROR_DE_SERVIDOR)))

    expect(e).toBeInstanceOf(ErrorDeSupabase)
    expect(e.message).toBe('No se pudo contar pedidos: permission denied for table pedidos')
    expect(e.code).toBe('42501')
  })
})
