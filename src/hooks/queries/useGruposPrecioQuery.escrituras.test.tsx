/**
 * Alta y edición de una condición mayorista: varias escrituras REST sin transacción
 * (#1561, 1561-b12). Sin poder crear una RPC desde el front, lo que se cierra es:
 *
 *  - un alta que falla a medias se deshace (se borra la condición recién creada), o avisa
 *    que quedó a medias si ni eso se pudo;
 *  - una edición que falla a medias lo dice, y los mínimos por producto ya no se borran
 *    enteros antes de reinsertarlos: se escriben (upsert) y después se borran los que sobran.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const estado = vi.hoisted(() => ({
  log: [] as string[],
  /** `tabla.operacion` -> respuesta; lo que no está responde bien y vacío. */
  respuestas: {} as Record<string, { data?: unknown; error?: { code: string; message: string } | null }>,
}))

vi.mock('../supabase/base', () => ({
  supabase: {
    from: (tabla: string) => {
      let op = 'select'
      let filtros = ''
      const responder = () => {
        estado.log.push(`${tabla}.${op}${filtros}`)
        const r = estado.respuestas[`${tabla}.${op}`]
        return Promise.resolve({ data: r?.data ?? [], error: r?.error ?? null })
      }
      const b: Record<string, unknown> = {}
      for (const nombre of ['insert', 'update', 'delete', 'upsert', 'select']) {
        b[nombre] = (..._args: unknown[]) => {
          // `select` después de insert/update sólo pide la fila de vuelta: no cambia la operación.
          if (nombre !== 'select') op = nombre
          return b
        }
      }
      for (const nombre of ['eq', 'in', 'order']) {
        b[nombre] = (col: string) => { filtros += `[${nombre}:${col}]`; return b }
      }
      b.single = () => responder().then(r => ({ ...r, data: Array.isArray(r.data) ? (r.data[0] ?? { id: '1' }) : r.data }))
      b.then = (ok: (v: unknown) => unknown, ko?: (e: unknown) => unknown) => responder().then(ok, ko)
      return b
    },
  },
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))

import { useCrearGrupoPrecioMutation, useActualizarGrupoPrecioMutation } from './useGruposPrecioQuery'

function wrapper() {
  const qc = new QueryClient({ defaultOptions: { mutations: { retry: false } } })
  return ({ children }: { children: React.ReactNode }) => (
    <QueryClientProvider client={qc}>{children}</QueryClientProvider>
  )
}

const entrada = {
  nombre: 'Almacén',
  descripcion: '',
  productoIds: ['10', '11'],
  escalas: [{ cantidadMinima: 10, precioUnitario: 900, minimosPorProducto: {} }],
}

beforeEach(() => {
  estado.log = []
  estado.respuestas = {
    'grupos_precio.insert': { data: [{ id: '9', nombre: 'Almacén' }] },
    'grupos_precio.update': { data: [{ id: '9', nombre: 'Almacén' }] },
  }
})

describe('crear una condición (1561-b12)', () => {
  it('si fallan los productos, borra la condición recién creada y dice que no se creó nada', async () => {
    estado.respuestas['grupo_precio_productos.insert'] = { error: { code: 'P0001', message: 'producto de otra sucursal' } }
    const { result } = renderHook(() => useCrearGrupoPrecioMutation(), { wrapper: wrapper() })

    const error = await result.current.mutateAsync(entrada as never).catch(e => e as Error)

    expect((error as Error).message).toMatch(/producto de otra sucursal.*No se creó nada/)
    expect(estado.log).toContain('grupos_precio.delete[eq:id]')
  })

  it('si ni borrarla se pudo, avisa que quedó a medias', async () => {
    estado.respuestas['grupo_precio_escalas.insert'] = { error: { code: 'P0001', message: 'escala repetida' } }
    estado.respuestas['grupos_precio.delete'] = { error: { code: 'P0001', message: 'no' } }
    const { result } = renderHook(() => useCrearGrupoPrecioMutation(), { wrapper: wrapper() })

    const error = await result.current.mutateAsync(entrada as never).catch(e => e as Error)

    expect((error as Error).message).toMatch(/escala repetida.*quedó creada a medias/)
  })

  it('si todo sale bien no borra nada', async () => {
    const { result } = renderHook(() => useCrearGrupoPrecioMutation(), { wrapper: wrapper() })

    await result.current.mutateAsync(entrada as never)

    expect(estado.log.some(l => l.startsWith('grupos_precio.delete'))).toBe(false)
  })
})

describe('editar una condición (1561-b12)', () => {
  const edicion = {
    id: '9',
    data: {
      ...entrada,
      escalas: [{ cantidadMinima: 10, precioUnitario: 900, minimosPorProducto: { '10': { cantidad: 2, precioOverride: null } } }],
    },
  }

  beforeEach(() => {
    estado.respuestas['grupo_precio_productos.select'] = { data: [{ id: 'a', producto_id: '10' }, { id: 'b', producto_id: '11' }] }
    estado.respuestas['grupo_precio_escalas.select'] = { data: [{ id: '5', cantidad_minima: 10 }] }
    estado.respuestas['grupo_precio_escalas.update'] = { data: [{ id: '5', cantidad_minima: 10 }] }
    estado.respuestas['grupo_precio_escala_minimos.select'] = {
      data: [{ escala_id: '5', producto_id: '10' }, { escala_id: '5', producto_id: '12' }],
    }
  })

  it('escribe los mínimos vigentes antes de borrar los que sobran, y no los borra todos', async () => {
    const { result } = renderHook(() => useActualizarGrupoPrecioMutation(), { wrapper: wrapper() })

    await result.current.mutateAsync(edicion as never)

    const minimos = estado.log.filter(l => l.startsWith('grupo_precio_escala_minimos.'))
    const iUpsert = minimos.findIndex(l => l.startsWith('grupo_precio_escala_minimos.upsert'))
    const iDelete = minimos.findIndex(l => l.startsWith('grupo_precio_escala_minimos.delete'))
    expect(iUpsert).toBeGreaterThanOrEqual(0)
    expect(iDelete).toBeGreaterThan(iUpsert)
    // El borrado es de un producto puntual (el 12), no de toda la escala.
    expect(minimos[iDelete]).toContain('[in:producto_id]')
  })

  it('si falla un paso a mitad, el error dice que la condición quedó a medias', async () => {
    estado.respuestas['grupo_precio_escala_minimos.upsert'] = { error: { code: 'P0001', message: 'mínimo inválido' } }
    const { result } = renderHook(() => useActualizarGrupoPrecioMutation(), { wrapper: wrapper() })

    const error = await result.current.mutateAsync(edicion as never).catch(e => e as Error)

    expect((error as Error).message).toMatch(/mínimo inválido.*quedó guardada a medias/)
    // No llegó a borrar nada: los mínimos viejos siguen ahí.
    expect(estado.log.some(l => l.startsWith('grupo_precio_escala_minimos.delete'))).toBe(false)
  })

  it('si falla el primer paso (el nombre), no dice «a medias»: no se escribió nada', async () => {
    estado.respuestas['grupos_precio.update'] = { error: { code: 'P0001', message: 'nombre repetido' } }
    const { result } = renderHook(() => useActualizarGrupoPrecioMutation(), { wrapper: wrapper() })

    const error = await result.current.mutateAsync(edicion as never).catch(e => e as Error)

    expect((error as Error).message).toBe('nombre repetido')
  })
})
