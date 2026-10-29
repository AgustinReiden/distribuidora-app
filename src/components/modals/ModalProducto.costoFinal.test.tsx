/**
 * La ficha y el costo final que deja la compra (flete y cargos adentro).
 *
 * La compra guarda en `costo_real` el costo unitario de su motor: neto + imp.
 * interno + los cargos prorrateados (flete, pallets). La ficha lo mostraba
 * recalculado como neto + II, sin los cargos, y al guardar —por cualquier
 * motivo: un precio, un subrubro— grababa ese número encima. El costo de
 * reposición perdía el flete sin que nadie lo tocara.
 *
 * Números sintéticos: neto 4.000, II 8,6957 %, y una compra que dejó 5.200 de
 * costo final (852,17 por unidad de flete y cargos por encima de neto + II).
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

const GASEOSA: ProductoDB = {
  id: '900',
  nombre: 'GASEOSA TESTIGO 3L',
  precio: 7500,
  precio_sin_iva: 6198.35,
  stock: 10,
  stock_minimo: 5,
  categoria: 'GASEOSAS',
  costo_sin_iva: 4000,
  impuestos_internos: 8.6957,
  costo_con_iva: 5187.83,
  costo_real: 5200,
  costo_promedio: 5100,
  ultimo_tipo_compra: 'FC',
  porcentaje_iva: 21,
  condicion_iva: 'gravado',
} as unknown as ProductoDB

function renderFicha(producto: ProductoDB = GASEOSA) {
  const onSave = vi.fn()
  render(
    <ModalProducto
      producto={producto}
      categorias={['GASEOSAS']}
      proveedores={[]}
      onSave={onSave}
      onClose={vi.fn()}
      guardando={false}
      esAdmin
    />,
  )
  return { onSave }
}

/** Los labels de la ficha no tienen `htmlFor`: se baja al input del mismo bloque. */
function campo(textoLabel: RegExp): HTMLInputElement {
  const label = screen.getByText(textoLabel, { selector: 'label' })
  const input = label.parentElement?.querySelector('input')
  if (!input) throw new Error(`No hay input para el label ${textoLabel}`)
  return input as HTMLInputElement
}

const guardar = () => userEvent.click(screen.getByRole('button', { name: /Guardar/ }))

describe('ModalProducto — costo final con los cargos de la compra', () => {
  beforeEach(() => vi.clearAllMocks())

  it('muestra como costo final el que dejó la compra, con el flete adentro', () => {
    renderFicha()
    expect(campo(/^Costo final \(reposición\)/).value).toBe('5200.00')
    expect(screen.getByText(/por unidad que sumó la última compra/)).toBeInTheDocument()
  })

  it('cambiar el precio no reescribe el costo de reposición', async () => {
    const { onSave } = renderFicha()

    const precio = campo(/^Precio Final/)
    await userEvent.clear(precio)
    await userEvent.type(precio, '8000')
    await guardar()

    expect(onSave).toHaveBeenCalledTimes(1)
    const payload = onSave.mock.calls[0][0]
    expect(Number(payload.precio)).toBe(8000)
    expect(payload).not.toHaveProperty('costo_real')
  })

  it('cambiar el nombre tampoco', async () => {
    const { onSave } = renderFicha()

    await userEvent.type(campo(/^Nombre \*$/), ' X6')
    await guardar()

    expect(onSave.mock.calls[0][0]).not.toHaveProperty('costo_real')
  })

  it('corregir el neto recalcula el costo y conserva lo que sumó la compra', async () => {
    const { onSave } = renderFicha()

    const neto = campo(/^Costo Neto$/)
    await userEvent.clear(neto)
    await userEvent.type(neto, '5000')
    await guardar()

    // 5.000 × 1,086957 = 5.434,785 + los 852,172 de flete y cargos.
    expect(onSave.mock.calls[0][0].costo_real).toBeCloseTo(6286.957, 3)
  })

  it('un producto sin costo de reposición guardado lo completa con neto + II', async () => {
    const { onSave } = renderFicha({ ...GASEOSA, costo_real: null } as unknown as ProductoDB)

    const precio = campo(/^Precio Final/)
    await userEvent.clear(precio)
    await userEvent.type(precio, '8000')
    await guardar()

    expect(onSave.mock.calls[0][0].costo_real).toBeCloseTo(4347.828, 3)
  })

  it('una factura B cuesta lo pagado: corregir el costo no le suma el IVA encima (#1253)', async () => {
    // La B se pagó 1.210 con el IVA adentro y no es crédito: la compra deja
    // neto = con IVA = 1.210 y el producto queda 'FC B'. Con la fórmula de una A,
    // corregir el costo a 1.300 guardaba 1.300 × 1,21 = 1.573 de costo total.
    const { onSave } = renderFicha({
      ...GASEOSA,
      impuestos_internos: 0,
      costo_sin_iva: 1210,
      costo_con_iva: 1210,
      costo_real: 1210,
      ultimo_tipo_compra: 'FC B',
    } as unknown as ProductoDB)

    const neto = campo(/^Costo Neto$/)
    await userEvent.clear(neto)
    await userEvent.type(neto, '1300')
    await guardar()

    expect(Number(onSave.mock.calls[0][0].costo_con_iva)).toBe(1300)
  })

  it('los dos márgenes se miden contra el costo con los cargos', () => {
    renderFicha()
    // Neto: 6.198,35 − 5.200 de costo final.
    expect(screen.getByText('$998.35')).toBeInTheDocument()
    // Bruto: 7.500 − (5.187,83 de factura con IVA + 852,17 de cargos).
    expect(screen.getByText('$1460.00')).toBeInTheDocument()
  })
})
