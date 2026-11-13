/**
 * #1560: el costo promedio tiene 4 decimales en la base. Precargado con punto, «125.125» se leía
 * con la regla de la plata tipeada (el punto seguido de tres dígitos es de miles) como 125.125
 * pesos multiplicado por mil. Va con coma.
 */
import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import ModalProducto from './ModalProducto'
import type { ProductoDB } from '../../types'

vi.mock('../../hooks/queries', () => ({
  useMarcasQuery: () => ({ data: [] }),
  useCatalogoIIQuery: () => ({ data: { encuadres: [], alicuotas: [] } }),
}))
vi.mock('../productos/ProductoCondicionesMayoristas', () => ({ default: () => null }))
vi.mock('../productos/ProductoLotes', () => ({ default: () => null }))
vi.mock('../productos/ProductoMedidas', () => ({ default: () => null }))
vi.mock('../productos/ProductoUltimaCompra', () => ({ default: () => null }))

const PRODUCTO = {
  id: '901',
  nombre: 'PRODUCTO TESTIGO',
  precio: 300,
  precio_sin_iva: 247.93,
  stock: 10,
  stock_minimo: 5,
  categoria: 'GASEOSAS',
  costo_sin_iva: 120,
  costo_con_iva: 145.2,
  costo_real: 145.2,
  costo_promedio: 125.125,
  porcentaje_iva: 21,
  condicion_iva: 'gravado',
} as unknown as ProductoDB

describe('ModalProducto — el costo promedio con tres decimales', () => {
  it('se muestra 125,13, no 125.125 mil', () => {
    render(
      <ModalProducto
        producto={PRODUCTO}
        categorias={['GASEOSAS']}
        proveedores={[]}
        onSave={vi.fn()}
        onClose={vi.fn()}
        guardando={false}
        esAdmin
      />,
    )
    const label = screen.getByText(/^Costo promedio \(valuación\)/, { selector: 'label' })
    const input = label.parentElement?.querySelector('input') as HTMLInputElement
    expect(input.value).toBe('125,13')
  })
})
