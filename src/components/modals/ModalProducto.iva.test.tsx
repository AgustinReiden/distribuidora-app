/**
 * #1380 — la alícuota de la ficha sale de la condición, no de `porcentaje_iva ?? 21`.
 * Un exento con `porcentaje_iva` NULL (una importación; el CHECK de productos lo
 * permite) calculaba el margen de la ficha y de las escalas como si llevara 21.
 */
import { describe, it, expect, vi } from 'vitest'
import { render, waitFor } from '@testing-library/react'
import ModalProducto from './ModalProducto'
import type { ProductoDB } from '../../types'

const m = vi.hoisted(() => ({ porcentajeIva: [] as number[] }))

vi.mock('../../hooks/queries', () => ({
  useMarcasQuery: () => ({ data: [] }),
  useCatalogoIIQuery: () => ({ data: { encuadres: [], alicuotas: [] } }),
}))
vi.mock('../productos/ProductoCondicionesMayoristas', () => ({
  default: (p: { porcentajeIva: number }) => { m.porcentajeIva.push(p.porcentajeIva); return null },
}))
vi.mock('../productos/ProductoLotes', () => ({ default: () => null }))
vi.mock('../productos/ProductoMedidas', () => ({ default: () => null }))
vi.mock('../productos/ProductoUltimaCompra', () => ({ default: () => null }))

async function montar(extra: Record<string, unknown>) {
  m.porcentajeIva = []
  const producto = {
    id: '1', nombre: 'Producto', precio: 1000, stock: 5, stock_minimo: 1, categoria: 'X', costo_sin_iva: 500,
    ...extra,
  } as unknown as ProductoDB
  render(
    <ModalProducto
      producto={producto}
      categorias={['X']}
      proveedores={[]}
      onSave={vi.fn()}
      onClose={vi.fn()}
      guardando={false}
      esAdmin
    />,
  )
  // El bloque de escalas es lazy: se espera a que se monte.
  await waitFor(() => expect(m.porcentajeIva.length).toBeGreaterThan(0))
  return m.porcentajeIva
}

describe('ModalProducto — alícuota de la ficha (#1380)', () => {
  it('un exento sin porcentaje va a las escalas con IVA 0, no 21', async () => {
    const vistos = await montar({ condicion_iva: 'exento', porcentaje_iva: null })
    expect(new Set(vistos)).toEqual(new Set([0]))
  })

  it('un no gravado sin porcentaje tampoco lleva 21', async () => {
    expect(new Set(await montar({ condicion_iva: 'no_gravado', porcentaje_iva: null }))).toEqual(new Set([0]))
  })

  it('un gravado al 10,5 conserva su porcentaje', async () => {
    expect(new Set(await montar({ condicion_iva: 'gravado', porcentaje_iva: 10.5 }))).toEqual(new Set([10.5]))
  })

  it('un gravado sin porcentaje sigue en 21', async () => {
    expect(new Set(await montar({ condicion_iva: 'gravado', porcentaje_iva: null }))).toEqual(new Set([21]))
  })
})
