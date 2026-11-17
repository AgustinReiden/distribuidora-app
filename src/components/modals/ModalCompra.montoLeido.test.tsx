/**
 * 1557-c5: en la compra no había `MontoLeido`: lo que la app leyó de un costo
 * tipeado recién se veía en el subtotal de la línea. En un campo de plata, quien
 * carga tiene que ver cómo lo leyó la app en el mismo campo, como en los cobros.
 * El test no depende de cómo se lee el punto tipeado (es de otra tarjeta): usa el
 * costo precargado de la ficha y una coma decimal.
 *
 * Datos sintéticos.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import type { ProductoDB, ProveedorDBExtended } from '../../types'

vi.mock('../../lib/supabase', () => ({
  supabase: { storage: { from: vi.fn() }, rpc: vi.fn(), from: vi.fn() },
  setSucursalHeader: vi.fn(),
  getSucursalHeader: vi.fn(() => null),
}))
vi.mock('../../hooks/queries/useComprasQuery', () => ({
  useCargosPlantillaProveedorQuery: () => ({ data: null, isSuccess: false }),
  useCostosAnterioresQuery: () => ({ data: undefined }),
  useComprasMismaFacturaQuery: () => ({ data: [] }),
}))
vi.mock('../../hooks/queries/useCargosCatalogoQuery', () => {
  const conceptos: unknown[] = [], medidas: unknown[] = [], ficha = {}
  return {
    useCargoConceptosQuery: () => ({ data: conceptos }),
    useCargoMedidasQuery: () => ({ data: medidas }),
    useProductoMedidasQuery: () => ({ data: ficha }),
  }
})
vi.mock('../../hooks/queries/useImpuestosInternosQuery', () => ({
  useCatalogoIIQuery: () => ({ data: { encuadres: [], alicuotas: [] } }),
}))
vi.mock('./ModalProveedor', () => ({ default: () => null }))
vi.mock('./ModalImportarCompra', () => ({ default: () => null }))

import ModalCompra from './ModalCompra'

const PRODUCTOS = [
  { id: 'p1', nombre: 'Aceite Girasol 900ml', codigo: 'ACE900', stock: 12, costo_sin_iva: 12375, impuestos_internos: 0, porcentaje_iva: 21, condicion_iva: 'gravado' },
] as unknown as ProductoDB[]
const PROVEEDORES = [{ id: 'prov-1', nombre: 'Manaos SA', cuit: null }] as unknown as ProveedorDBExtended[]

describe('ModalCompra · el costo de la línea muestra cómo lo leyó la app (1557-c5)', () => {
  beforeEach(() => {
    localStorage.clear()
  })

  it('«Se registra: $ …» debajo del campo de costo, y cambia al tipear otro', async () => {
    const user = userEvent.setup()
    render(<ModalCompra productos={PRODUCTOS} proveedores={PROVEEDORES} onSave={vi.fn()} onClose={vi.fn()} />)

    await user.click(screen.getByPlaceholderText('Buscar producto por nombre o codigo...'))
    await user.click(screen.getByRole('button', { name: /Aceite Girasol/ }))

    // El costo precargado de la ficha (12.375) ya se ve leído. La línea se dibuja
    // para mobile y para desktop: una leyenda por cada campo.
    const leidos = await screen.findAllByText(/Se registra:/)
    expect(leidos.length).toBeGreaterThanOrEqual(1)
    for (const l of leidos) expect(l).toHaveTextContent(/12\.375,00/)

    const campo = screen.getAllByDisplayValue(/12\.?375/)[0]
    await user.clear(campo)
    await user.type(campo, '12,5')
    for (const l of await screen.findAllByText(/Se registra:/)) expect(l).toHaveTextContent(/12,50/)
  })
})
