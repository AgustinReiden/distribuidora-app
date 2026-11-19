/**
 * 1598-b5: `replaceCategoriaDiscounts` borraba y después insertaba los descuentos por categoría
 * del cliente, en varias llamadas REST sin transacción (#1637 lo achicó a «inserta lo nuevo, borra
 * lo que sobra, re-inserta lo que cambió y restituye si falla», con una ventana si fallaban el
 * paso y la restitución). Ahora es UNA RPC (`guardar_descuentos_categoria`, C4b de #1603) que deja
 * la lista en una transacción: el front no escribe la tabla por REST. La normalización (una fila
 * por categoría sin mirar mayúsculas ni bordes, la última gana, sin categoría no cuenta) la hace la
 * RPC, y la prueba su ensayo (scripts/test-guardados-atomicos-ola2-1603.sql, D1 y D2).
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'

const estado = vi.hoisted(() => ({
  escrituras: [] as string[],
  rpcs: [] as Array<{ fn: string; args: Record<string, unknown> }>,
  error: null as null | { code: string; message: string },
}))

vi.mock('../supabase/base', () => ({
  supabase: {
    from: (tabla: string) => {
      const b: Record<string, unknown> = {}
      for (const op of ['insert', 'delete', 'update', 'upsert']) b[op] = () => { estado.escrituras.push(`${tabla}.${op}`); return b }
      for (const op of ['select', 'eq', 'in']) b[op] = () => b
      b.then = (ok: (r: unknown) => unknown) => ok({ data: [], error: null })
      return b
    },
    rpc: (fn: string, args: Record<string, unknown>) => {
      estado.rpcs.push({ fn, args })
      return Promise.resolve({ data: estado.error ? null : { descuentos: [] }, error: estado.error })
    },
  },
}))

vi.mock('../../contexts/SucursalContext', () => ({ useSucursal: () => ({ currentSucursalId: 1 }) }))
vi.mock('../../contexts/AuthDataContext', () => ({ useAuthData: () => ({}) }))

import { replaceCategoriaDiscounts } from './useClientesQuery'

const d = (categoria: string, descuento_porcentaje: number) => ({ categoria, descuento_porcentaje })

beforeEach(() => {
  estado.escrituras = []
  estado.rpcs = []
  estado.error = null
})

describe('replaceCategoriaDiscounts (1598-b5, C4b)', () => {
  it('es una sola llamada a guardar_descuentos_categoria con la lista, sin escrituras REST', async () => {
    await replaceCategoriaDiscounts('5', [d('Bebidas', 7), d('Limpieza', 3)])

    expect(estado.escrituras).toEqual([])
    expect(estado.rpcs).toEqual([{
      fn: 'guardar_descuentos_categoria',
      args: { p_cliente_id: 5, p_descuentos: [d('Bebidas', 7), d('Limpieza', 3)] },
    }])
  })

  it('la lista vacía también va (borra los que hay)', async () => {
    await replaceCategoriaDiscounts('5', [])

    expect(estado.rpcs[0].args).toEqual({ p_cliente_id: 5, p_descuentos: [] })
  })

  it('un rechazo del server llega con su motivo', async () => {
    estado.error = { code: '22023', message: 'El descuento de «Bebidas» tiene que ser un número de 0 a 100.' }

    await expect(replaceCategoriaDiscounts('5', [d('Bebidas', 150)])).rejects.toThrow('El descuento de «Bebidas» tiene que ser un número de 0 a 100.')
  })

  it('sin respuesta, dice que se puede volver a guardar (deja la lista como se cargó)', async () => {
    estado.error = { code: '', message: 'TypeError: Failed to fetch' }

    await expect(replaceCategoriaDiscounts('5', [d('Bebidas', 7)])).rejects.toThrow(/Podés volver a guardar/)
  })
})
