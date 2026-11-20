/**
 * 1593-b1 (#1593; decisión del dueño del 19/11): el costo con IVA es el costo neto
 * (neto del producto + impuestos internos + cargos y flete netos) más el IVA de
 * cada componente. Desde la migración de la tarjeta C3 la compra lo guarda ya
 * compuesto en `costo_con_iva`: la ficha lo muestra tal cual y no le vuelve a
 * sumar los cargos (antes lo hacía, porque la compra guardaba neto + IVA + II
 * nominal, sin cargos). Si el admin corrige el neto en la ficha, lo que la compra
 * sumó por encima de neto + IVA + II se conserva, igual que en el costo real.
 *
 * Números: FC A de 10 × 100 al 21 % con un flete de 100 sin IVA. La compra deja
 * costo_sin_iva 100, costo_real 110 y costo_con_iva 131 (110 + 21).
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
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

const AGUA: ProductoDB = {
  id: '901',
  nombre: 'AGUA TESTIGO 2L',
  precio: 200,
  precio_sin_iva: 165.29,
  stock: 10,
  stock_minimo: 5,
  categoria: 'AGUAS',
  costo_sin_iva: 100,
  impuestos_internos: 0,
  costo_con_iva: 131,
  costo_real: 110,
  costo_promedio: 110,
  ultimo_tipo_compra: 'FC',
  porcentaje_iva: 21,
  condicion_iva: 'gravado',
} as unknown as ProductoDB

function renderFicha(producto: ProductoDB = AGUA) {
  const onSave = vi.fn()
  render(
    <ModalProducto
      producto={producto}
      categorias={['AGUAS']}
      proveedores={[]}
      onSave={onSave}
      onClose={vi.fn()}
      guardando={false}
      esAdmin
    />,
  )
  return { onSave }
}

function campo(textoLabel: RegExp): HTMLInputElement {
  const label = screen.getByText(textoLabel, { selector: 'label' })
  const input = label.parentElement?.querySelector('input')
  if (!input) throw new Error(`No hay input para el label ${textoLabel}`)
  return input as HTMLInputElement
}

const guardar = () => userEvent.click(screen.getByRole('button', { name: /Guardar/ }))

describe('ModalProducto — el costo con IVA ya compuesto por la compra (1593-b1)', () => {
  beforeEach(() => vi.clearAllMocks())

  it('muestra el costo con IVA que dejó la compra, sin volver a sumarle los cargos', () => {
    renderFicha()
    expect(campo(/^Costo total \(con IVA\)/).value).toBe('131')
  })

  it('el margen bruto se mide contra ese costo', () => {
    renderFicha()
    // 200 − 131.
    expect(screen.getByText('$69.00')).toBeInTheDocument()
  })

  it('cambiar el precio no le cambia el costo con IVA', async () => {
    const { onSave } = renderFicha()
    const precio = campo(/^Precio Final/)
    await userEvent.clear(precio)
    await userEvent.type(precio, '250')
    await guardar()

    const payload = onSave.mock.calls[0][0]
    // Sin cambios no viaja (undefined = no tocar); si viaja, es el mismo.
    if (payload.costo_con_iva !== undefined) expect(Number(payload.costo_con_iva)).toBe(131)
  })

  it('corregir el neto conserva lo que sumó la compra (el flete), también en el costo con IVA', async () => {
    const { onSave } = renderFicha()
    const neto = campo(/^Costo Neto$/)
    await userEvent.clear(neto)
    await userEvent.type(neto, '200')
    await guardar()

    const payload = onSave.mock.calls[0][0]
    // 200 + 10 de flete; con IVA: 200 × 1,21 + los 10 del flete = 252.
    expect(payload.costo_real).toBeCloseTo(210, 4)
    expect(Number(payload.costo_con_iva)).toBe(252)
  })

  it('en una ZZ el costo con IVA es lo pagado con los cargos: 130 se muestra 130', () => {
    renderFicha({
      ...AGUA,
      costo_sin_iva: 100,
      costo_real: 130,
      costo_con_iva: 130,
      ultimo_tipo_compra: 'ZZ',
    } as unknown as ProductoDB)
    expect(campo(/^Costo total \(lo pagado\)/).value).toBe('130')
  })
})
