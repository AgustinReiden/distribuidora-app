/**
 * 1599-b4: `fetchCostosAnteriores` traía todas las líneas con UN límite global
 * (25 por producto, hasta 1.000). Con el orden por fecha descendente, un producto
 * de mucho movimiento llenaba la ventana y otro con su última compra más vieja
 * quedaba sin «costo anterior».
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

type Fila = {
  producto_id: number
  compra_id: number
  costo_real_unitario: number
  costo_unitario: number
  bonificacion: number
  compra: { id: number; fecha_compra: string; created_at: string; numero_factura: string; tipo_factura: string; letra_comprobante: string; estado: string }
}

const fila = (productoId: number, compraId: number, fecha: string, costo: number): Fila => ({
  producto_id: productoId,
  compra_id: compraId,
  costo_real_unitario: costo,
  costo_unitario: costo,
  bonificacion: 0,
  compra: { id: compraId, fecha_compra: fecha, created_at: `${fecha}T12:00:00Z`, numero_factura: `A0001-${String(compraId).padStart(8, '0')}`, tipo_factura: 'FC', letra_comprobante: 'A', estado: 'recibida' },
})

// El producto 1 se compra todos los días (60 líneas); el 2 tiene una sola, vieja.
const DB: Fila[] = [
  ...Array.from({ length: 60 }, (_, i) => fila(1, 1000 + i, `2026-07-${String(30 - Math.floor(i / 2)).padStart(2, '0')}`, 100 + i)),
  fila(2, 5, '2026-01-10', 777),
]

const consultas: Array<{ ids: number[]; limite: number }> = []
let enVuelo = 0
let maximoEnVuelo = 0

function builder() {
  let ids: number[] = []
  let limite = Infinity
  const b: Record<string, unknown> = {}
  const cadena = () => b
  for (const m of ['select', 'not', 'neq', 'lte', 'eq', 'order']) b[m] = cadena
  b.in = (_col: string, valores: Array<string | number>) => { ids = valores.map(Number); return b }
  b.limit = (n: number) => { limite = n; return b }
  b.then = (resolve: (v: unknown) => unknown) => {
    consultas.push({ ids, limite })
    const data = DB
      .filter(f => ids.includes(f.producto_id))
      .sort((a, c) => c.compra.fecha_compra.localeCompare(a.compra.fecha_compra) || c.compra_id - a.compra_id)
      .slice(0, limite)
    enVuelo += 1
    maximoEnVuelo = Math.max(maximoEnVuelo, enVuelo)
    return new Promise(r => setTimeout(r, 3)).then(() => { enVuelo -= 1; return { data, error: null } }).then(resolve)
  }
  return b
}

vi.mock('../supabase/base', () => ({
  supabase: { from: () => builder(), rpc: vi.fn() },
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))

import { useCostosAnterioresQuery } from './useComprasQuery'

function setup(ids: string[]) {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  const wrapper = ({ children }: { children: React.ReactNode }) => (
    <QueryClientProvider client={qc}>{children}</QueryClientProvider>
  )
  return renderHook(
    () => useCostosAnterioresQuery(ids, { compraId: null, fechaCompra: '2026-08-15', numeroFactura: null }),
    { wrapper },
  )
}

describe('costos anteriores: el límite no deja a un producto sin su compra anterior', () => {
  beforeEach(() => {
    consultas.length = 0
    enVuelo = 0
    maximoEnVuelo = 0
  })

  it('un producto con una compra vieja la sigue teniendo aunque otro llene la ventana', async () => {
    const { result } = setup(['1', '2'])
    await waitFor(() => expect(result.current.data).toBeDefined())

    // La más nueva del 30/07 (dos del mismo día: gana la de id mayor).
    expect(result.current.data?.get('1')?.costoRealUnitario).toBe(101)
    expect(result.current.data?.get('2')?.costoRealUnitario).toBe(777)
  })

  it('si la ventana alcanza no hace consultas de más', async () => {
    const { result } = setup(['2'])
    await waitFor(() => expect(result.current.data).toBeDefined())

    expect(result.current.data?.get('2')?.costoRealUnitario).toBe(777)
    expect(consultas).toHaveLength(1)
  })

  it('los productos sin resolver se piden de a pocos a la vez, no todos juntos', async () => {
    // El producto 1 llena la ventana (275 = 25 x 11 productos); los otros diez no tienen ninguna compra.
    const extra = Array.from({ length: 300 }, (_, i) => fila(1, 5000 + i, '2026-06-01', 50))
    DB.push(...extra)
    try {
      const nuevos = Array.from({ length: 10 }, (_, i) => String(100 + i))
      const { result } = setup(['1', ...nuevos])
      await waitFor(() => expect(result.current.data).toBeDefined())

      expect(result.current.data?.get('1')).toBeDefined()
      // 1 consulta con la ventana + una por cada producto sin resolver...
      expect(consultas).toHaveLength(1 + nuevos.length)
      // ...pero nunca más de 4 en vuelo.
      expect(maximoEnVuelo).toBeLessThanOrEqual(4)
    } finally {
      DB.splice(DB.length - extra.length, extra.length)
    }
  })
})
