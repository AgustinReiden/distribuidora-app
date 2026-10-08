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

vi.mock('./base', () => {
  const builder = () => {
    const b: Record<string, unknown> = {}
    b.order = () => b
    b.range = () => Promise.resolve({ data: [], error: null })
    return b
  }
  return {
    supabase: {
      from: () => ({
        select: (s: string) => {
          selects.push(s)
          return builder()
        },
      }),
    },
    notifyError: vi.fn(),
  }
})

import { useSalvedades } from './useSalvedades'

async function selectDeFetch(): Promise<string> {
  const { result } = renderHook(() => useSalvedades())
  await act(async () => {
    await result.current.fetchTodasSalvedades()
  })
  expect(selects).toHaveLength(1)
  return selects[0].replace(/\s+/g, '')
}

describe('useSalvedades — select de salvedades_items', () => {
  beforeEach(() => {
    selects.length = 0
  })

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
