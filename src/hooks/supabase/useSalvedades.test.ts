/**
 * #1008 — la pantalla de Salvedades no cargaba en prod (PGRST200).
 *
 * Las FKs de `salvedades_items` hacia `productos` y `pedidos` son COMPUESTAS
 * (`(producto_id, sucursal_id)`, `(pedido_id, sucursal_id)`: el aislamiento por
 * sucursal), y PostgREST no encuentra una FK compuesta por el nombre de UNA
 * columna: `productos!producto_id` responde 400 PGRST200 y la consulta ENTERA
 * falla. El `select` es un string, así que ni `tsc` ni estos tests (que mockean
 * supabase) lo ven; por eso este test fija el string y el gate
 * `scripts/check-embeds.mjs` lo prueba contra prod.
 *
 * `pedidos` además tiene DOS FKs desde `salvedades_items` (`pedido_id` y
 * `pedido_reprogramado_id`): sin hint es PGRST201, así que el hint se queda,
 * pero con el NOMBRE DEL CONSTRAINT.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, act } from '@testing-library/react'

const selects: string[] = []
// Lo que devuelven las consultas en los tests de #1072 (por defecto, vacío).
const respuestas: {
  salvedades: unknown[]
  perfiles: { data: unknown[] | null; error: unknown }
  perfilesIds: string[][]
} = { salvedades: [], perfiles: { data: [], error: null }, perfilesIds: [] }

vi.mock('./base', () => {
  const builder = () => {
    const b: Record<string, unknown> = {}
    b.order = () => b
    b.range = (desde: number) =>
      Promise.resolve({ data: desde === 0 ? respuestas.salvedades : [], error: null })
    return b
  }
  return {
    supabase: {
      from: (tabla: string) => ({
        select: (s: string) => {
          selects.push(s)
          if (tabla === 'perfiles') {
            return {
              in: (_col: string, ids: string[]) => {
                respuestas.perfilesIds.push(ids)
                return Promise.resolve(respuestas.perfiles)
              },
            }
          }
          return builder()
        },
      }),
    },
    notifyError: vi.fn(),
  }
})

import { useSalvedades } from './useSalvedades'
import { notifyError } from './base'

async function selectDeFetch(): Promise<string> {
  const { result } = renderHook(() => useSalvedades())
  await act(async () => {
    await result.current.fetchTodasSalvedades()
  })
  expect(selects).toHaveLength(1)
  return selects[0].replace(/\s+/g, '')
}

function reiniciar() {
  selects.length = 0
  respuestas.salvedades = []
  respuestas.perfiles = { data: [], error: null }
  respuestas.perfilesIds = []
  vi.mocked(notifyError).mockClear()
}

describe('useSalvedades — select de salvedades_items', () => {
  beforeEach(reiniciar)

  it('embebe productos y pedidos por el NOMBRE DEL CONSTRAINT (FKs compuestas)', async () => {
    const select = await selectDeFetch()
    expect(select).toContain('productos!salvedades_items_producto_id_fkey(')
    expect(select).toContain('pedidos!salvedades_items_pedido_id_fkey(')
  })

  it('no usa hints por nombre de columna sobre FKs compuestas', async () => {
    const select = await selectDeFetch()
    expect(select).not.toMatch(/productos!producto_id/)
    expect(select).not.toMatch(/pedidos!pedido_id/)
    expect(select).not.toMatch(/clientes!cliente_id/)
  })

  it('sigue pidiendo los campos que arma transformarSalvedad', async () => {
    const select = await selectDeFetch()
    for (const campo of ['nombre_fantasia', 'transportista_id', 'estado', 'total', 'codigo']) {
      expect(select).toContain(campo)
    }
    expect(select).toContain('perfiles!reportado_por(')
    expect(select).toContain('perfiles!resuelto_por(')
  })
})

/**
 * #1072 — el transportista salía siempre '-': `transformarSalvedad` armaba el
 * id pero nunca el nombre. `pedidos` no tiene FK a `perfiles` (un embed sería
 * PGRST200), así que el nombre sale de una segunda consulta plana a perfiles.
 */
describe('useSalvedades — nombre del transportista (#1072)', () => {
  beforeEach(reiniciar)

  const salvedad = (id: number, transportista_id: string | null) => ({
    id,
    pedido: { id: 100 + id, total: 1000, estado: 'entregado', transportista_id, cliente: { id: 1, nombre_fantasia: 'Kiosco' } },
  })

  async function cargar() {
    const { result } = renderHook(() => useSalvedades())
    let lista: Awaited<ReturnType<typeof result.current.fetchTodasSalvedades>> = []
    await act(async () => {
      lista = await result.current.fetchTodasSalvedades()
    })
    return lista
  }

  it('arma transportista_nombre con los perfiles de los transportistas distintos', async () => {
    respuestas.salvedades = [salvedad(1, 'uuid-t1'), salvedad(2, 'uuid-t1'), salvedad(3, 'uuid-t2')]
    respuestas.perfiles = { data: [{ id: 'uuid-t1', nombre: 'Juan' }, { id: 'uuid-t2', nombre: 'Pedro' }], error: null }

    const lista = await cargar()

    expect(respuestas.perfilesIds).toEqual([['uuid-t1', 'uuid-t2']])
    expect(selects[1].replace(/\s+/g, '')).toBe('id,nombre')
    expect(lista.map(s => s.transportista_nombre)).toEqual(['Juan', 'Juan', 'Pedro'])
    expect(notifyError).not.toHaveBeenCalled()
  })

  it('sin transportistas no hace la segunda consulta', async () => {
    respuestas.salvedades = [salvedad(1, null)]

    const lista = await cargar()

    expect(selects).toHaveLength(1)
    expect(respuestas.perfilesIds).toEqual([])
    expect(lista[0].transportista_nombre).toBeUndefined()
  })

  it('si falla perfiles, la lista carga igual, sin nombre, y avisa con mensaje normalizado', async () => {
    respuestas.salvedades = [salvedad(1, 'uuid-t1'), salvedad(2, null)]
    respuestas.perfiles = {
      data: null,
      error: { message: 'TypeError: Failed to fetch', details: '', hint: '', code: '' },
    }

    const lista = await cargar()

    expect(lista).toHaveLength(2)
    expect(lista[0].transportista_nombre).toBeUndefined()
    expect(notifyError).toHaveBeenCalledTimes(1)
    const aviso = vi.mocked(notifyError).mock.calls[0][0] as string
    expect(aviso).not.toMatch(/Failed to fetch/)
    expect(aviso).toMatch(/Sin conexión/)
  })
})
