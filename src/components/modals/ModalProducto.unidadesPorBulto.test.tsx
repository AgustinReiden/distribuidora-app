/**
 * La ficha de producto y `unidades_por_bulto` (mig XXX, #950): cuántas unidades
 * sueltas trae una unidad de stock. Lo usan las barras de regalo. Vacío viaja
 * como null (la columna exige > 0), y no es el campo de "unidades por
 * bulto/fardo" de la boleta.
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

const PLACER: ProductoDB = {
  id: '125',
  nombre: 'PLACER POMELO ROSADO 500 cc',
  precio: 7000,
  stock: 76,
  stock_minimo: 10,
  categoria: 'PLACER',
  porcentaje_iva: 21,
  condicion_iva: 'gravado',
  unidades_por_bulto: 12,
} as unknown as ProductoDB

function renderFicha(producto: ProductoDB | null) {
  const onSave = vi.fn()
  render(
    <ModalProducto
      producto={producto}
      categorias={['PLACER']}
      proveedores={[]}
      onSave={onSave}
      onClose={vi.fn()}
      guardando={false}
      esAdmin
    />,
  )
  return { onSave }
}

const campo = () => screen.getByLabelText('Unidades sueltas por unidad de stock') as HTMLInputElement
const guardar = () => userEvent.click(screen.getByRole('button', { name: /Guardar/ }))

describe('ModalProducto — unidades sueltas por unidad de stock (#950)', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    // Con un error de validación la ficha scrollea al mensaje; jsdom no lo implementa.
    Element.prototype.scrollIntoView = vi.fn()
  })

  it('muestra el valor cargado y lo manda al guardar', async () => {
    const { onSave } = renderFicha(PLACER)
    expect(campo().value).toBe('12')
    await guardar()
    expect(onSave).toHaveBeenCalledTimes(1)
    expect(onSave.mock.calls[0][0].unidades_por_bulto).toBe(12)
  })

  it('cambiarlo manda el número nuevo', async () => {
    const { onSave } = renderFicha(PLACER)
    await userEvent.clear(campo())
    await userEvent.type(campo(), '6')
    await guardar()
    expect(onSave.mock.calls[0][0].unidades_por_bulto).toBe(6)
  })

  it('vaciarlo manda null ("no cargado"), no 0', async () => {
    const { onSave } = renderFicha(PLACER)
    await userEvent.clear(campo())
    await guardar()
    expect(onSave).toHaveBeenCalledTimes(1)
    expect(onSave.mock.calls[0][0].unidades_por_bulto).toBeNull()
  })

  it('un producto sin el dato lo guarda como null', async () => {
    const { onSave } = renderFicha({ ...PLACER, unidades_por_bulto: null } as unknown as ProductoDB)
    expect(campo().value).toBe('')
    await guardar()
    expect(onSave.mock.calls[0][0].unidades_por_bulto).toBeNull()
  })

  it('no acepta un número con decimales', async () => {
    const { onSave } = renderFicha(PLACER)
    await userEvent.clear(campo())
    await userEvent.type(campo(), '1.5')
    await guardar()
    expect(onSave).not.toHaveBeenCalled()
    expect(screen.getByText('Debe ser un número entero')).toBeInTheDocument()
  })

  it('no se confunde con "unidades por bulto/fardo" de la boleta', () => {
    renderFicha(PLACER)
    expect(screen.getByText('Unidades por bulto/fardo')).toBeInTheDocument()
    expect(screen.getByText(/Manaos 3L = 6, Placer 500 = 12, papas = 1/)).toBeInTheDocument()
  })
})
