/**
 * 1598-b5: `replaceCategoriaDiscounts` borraba TODOS los descuentos por categoría del cliente y
 * después insertaba los nuevos, en dos llamadas sin transacción. Si la segunda fallaba (red, un
 * CHECK), el cliente quedaba sin ningún descuento: se perdía un dato comercial entero por editar
 * una sola categoría. La tabla no tiene UPDATE (ni grant ni policy), así que no hay upsert: ahora
 * se toca sólo lo que cambió, y lo que hay que borrar y re-insertar (un valor distinto) se
 * restituye si el insert falla.
 *
 * La tabla falsa respeta el UNIQUE (cliente_id, categoria), como la real.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'

interface Fila { cliente_id: string; categoria: string; descuento_porcentaje: number }

let filas: Fila[] = []
/** Número (desde 1) del insert que falla, uno solo (null = ninguno falla). */
let fallaElInsert: number | null = null
let inserts = 0
const log: string[] = []

vi.mock('../supabase/base', () => ({
  supabase: {
    from: (tabla: string) => {
      if (tabla !== 'cliente_descuentos_categoria') throw new Error(`tabla inesperada ${tabla}`)
      let op: 'select' | 'delete' | null = null
      let clienteId = ''
      let categorias: string[] | null = null
      const resolver = () => {
        if (op === 'select') {
          return { data: filas.filter(f => f.cliente_id === clienteId).map(f => ({ categoria: f.categoria, descuento_porcentaje: f.descuento_porcentaje })), error: null }
        }
        // delete
        filas = filas.filter(f => !(f.cliente_id === clienteId && (categorias === null || categorias.includes(f.categoria))))
        log.push(`delete:${categorias === null ? '*' : categorias.join('|')}`)
        return { error: null }
      }
      const builder: Record<string, unknown> = {
        select: () => { op = 'select'; return builder },
        delete: () => { op = 'delete'; return builder },
        eq: (_c: string, v: string) => { clienteId = v; return builder },
        in: (_c: string, v: string[]) => { categorias = v; return builder },
        then: (ok: (r: unknown) => unknown) => ok(resolver()),
        insert: (nuevas: Fila[]) => {
          inserts++
          if (fallaElInsert !== null && inserts === fallaElInsert) {
            return Promise.resolve({ error: { message: 'Failed to fetch', code: '' } })
          }
          for (const n of nuevas) {
            if (filas.some(f => f.cliente_id === n.cliente_id && f.categoria === n.categoria)) {
              return Promise.resolve({ error: { message: 'duplicate key', code: '23505' } })
            }
          }
          filas.push(...nuevas)
          log.push(`insert:${nuevas.map(n => n.categoria).join('|')}`)
          return Promise.resolve({ error: null })
        },
      }
      return builder
    },
  },
}))

vi.mock('../../contexts/SucursalContext', () => ({ useSucursal: () => ({ currentSucursalId: 1 }) }))
vi.mock('../../contexts/AuthDataContext', () => ({ useAuthData: () => ({}) }))

import { replaceCategoriaDiscounts } from './useClientesQuery'

const d = (categoria: string, descuento_porcentaje: number) => ({ categoria, descuento_porcentaje })
const de = (cliente_id = '5'): Array<[string, number]> =>
  filas.filter(f => f.cliente_id === cliente_id).map(f => [f.categoria, f.descuento_porcentaje] as [string, number]).sort()

beforeEach(() => {
  filas = [
    { cliente_id: '5', categoria: 'Bebidas', descuento_porcentaje: 5 },
    { cliente_id: '5', categoria: 'Almacén', descuento_porcentaje: 10 },
    { cliente_id: '9', categoria: 'Bebidas', descuento_porcentaje: 1 },
  ]
  fallaElInsert = null
  inserts = 0
  log.length = 0
})

describe('replaceCategoriaDiscounts (1598-b5)', () => {
  it('deja la lista como la pidieron, sin tocar a otro cliente', async () => {
    await replaceCategoriaDiscounts('5', [d('Bebidas', 7), d('Limpieza', 3)])
    expect(de('5')).toEqual([['Bebidas', 7], ['Limpieza', 3]])
    expect(de('9')).toEqual([['Bebidas', 1]])
  })

  it('no borra ni inserta lo que no cambió', async () => {
    await replaceCategoriaDiscounts('5', [d('Bebidas', 5), d('Almacén', 10)])
    expect(log).toEqual([])
    expect(de('5')).toEqual([['Almacén', 10], ['Bebidas', 5]])
  })

  it('si el insert de lo nuevo falla, no se borró nada', async () => {
    fallaElInsert = 1
    await expect(replaceCategoriaDiscounts('5', [d('Bebidas', 5), d('Limpieza', 3)])).rejects.toThrow()
    expect(de('5')).toEqual([['Almacén', 10], ['Bebidas', 5]])
  })

  it('si falla el insert del valor cambiado, el valor anterior se restituye', async () => {
    // Insert 1 (categoría nueva) pasa; el 2 (Bebidas con el valor nuevo, ya borrada la vieja) falla;
    // el 3 es la restitución.
    fallaElInsert = 2
    await expect(replaceCategoriaDiscounts('5', [d('Bebidas', 7), d('Limpieza', 3), d('Almacén', 10)])).rejects.toThrow()
    // Bebidas vuelve a 5 (no queda el cliente sin ese descuento) y Almacén no se tocó.
    expect(de('5')).toContainEqual(['Bebidas', 5])
    expect(de('5')).toContainEqual(['Almacén', 10])
  })

  it('una lista vacía quita lo que había, y sólo de ese cliente', async () => {
    await replaceCategoriaDiscounts('5', [])
    expect(de('5')).toEqual([])
    expect(de('9')).toEqual([['Bebidas', 1]])
  })

  it('dedup por categoría normalizada (la última gana) y descarta filas sin categoría', async () => {
    await replaceCategoriaDiscounts('5', [d('Limpieza', 2), d(' limpieza ', 4), d('', 9), d('Almacén', 10)])
    expect(de('5')).toEqual([['Almacén', 10], ['limpieza', 4]])
  })

  it('reintentar el mismo cambio después de un fallo lo completa (es idempotente)', async () => {
    fallaElInsert = 1
    await expect(replaceCategoriaDiscounts('5', [d('Bebidas', 7)])).rejects.toThrow()
    fallaElInsert = null
    await replaceCategoriaDiscounts('5', [d('Bebidas', 7)])
    expect(de('5')).toEqual([['Bebidas', 7]])
  })
})
