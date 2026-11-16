/**
 * La ficha del producto (#1596):
 *  - CAT-12: vaciar "Unidades por bulto/fardo" lo BORRA. Mandaba `undefined`, que
 *    `updateProducto` toma como "no tocar": decía "Producto actualizado" y la base
 *    conservaba el valor.
 *  - CAT-11: un producto cuyo rubro se desactivó lo sigue mostrando en la ficha.
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

const CON_FARDO = {
  id: '125',
  nombre: 'PLACER POMELO ROSADO 500 cc',
  precio: 7000,
  stock: 76,
  stock_minimo: 10,
  categoria: 'PLACER',
  porcentaje_iva: 21,
  condicion_iva: 'gravado',
  unidades_de_venta_por_fardo: 6,
  etiqueta_bulto: 'FARDO',
} as unknown as ProductoDB

function renderFicha(producto: ProductoDB | null, categorias: string[] = ['PLACER']) {
  const onSave = vi.fn()
  render(
    <ModalProducto
      producto={producto}
      categorias={categorias}
      proveedores={[]}
      onSave={onSave}
      onClose={vi.fn()}
      guardando={false}
      esAdmin
    />,
  )
  return { onSave }
}

const guardar = () => userEvent.click(screen.getByRole('button', { name: /Guardar/ }))

describe('ModalProducto — CAT-12: vaciar unidades por bulto/fardo', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    Element.prototype.scrollIntoView = vi.fn()
  })

  it('vaciarlo manda null (y la etiqueta vacía), no undefined', async () => {
    const { onSave } = renderFicha(CON_FARDO)
    await userEvent.clear(screen.getByPlaceholderText('ej. 2'))
    await guardar()
    expect(onSave).toHaveBeenCalledTimes(1)
    const enviado = onSave.mock.calls[0][0]
    expect(enviado.unidades_de_venta_por_fardo).toBeNull()
    expect(enviado.etiqueta_bulto).toBe('')
  })

  it('sin tocarlo no viaja', async () => {
    const { onSave } = renderFicha(CON_FARDO)
    await guardar()
    expect(onSave.mock.calls[0][0].unidades_de_venta_por_fardo).toBeUndefined()
    expect(onSave.mock.calls[0][0].etiqueta_bulto).toBeUndefined()
  })

  it('cambiarlo manda el número nuevo', async () => {
    const { onSave } = renderFicha(CON_FARDO)
    const campo = screen.getByPlaceholderText('ej. 2')
    await userEvent.clear(campo)
    await userEvent.type(campo, '12')
    await guardar()
    expect(onSave.mock.calls[0][0].unidades_de_venta_por_fardo).toBe(12)
  })

  it('vaciar sólo la etiqueta la borra', async () => {
    const { onSave } = renderFicha(CON_FARDO)
    await userEvent.clear(screen.getByPlaceholderText('FARDO'))
    await guardar()
    expect(onSave.mock.calls[0][0].etiqueta_bulto).toBe('')
    expect(onSave.mock.calls[0][0].unidades_de_venta_por_fardo).toBe(6)
  })
})

describe('ModalProducto — CAT-11: el rubro desactivado se sigue mostrando', () => {
  beforeEach(() => { Element.prototype.scrollIntoView = vi.fn() })

  it('el producto que ya tiene un rubro fuera de la lista lo conserva elegido', () => {
    renderFicha({ ...CON_FARDO, categoria: 'DESCONTINUADOS' } as unknown as ProductoDB, ['PLACER'])
    const select = screen.getByLabelText('Categoría') as HTMLSelectElement
    expect(select.value).toBe('DESCONTINUADOS')
    expect(screen.getByRole('option', { name: 'DESCONTINUADOS (desactivada)' })).toBeInTheDocument()
  })

  it('un rubro que nunca tuvo fila no se rotula como desactivado (L8, #1603)', () => {
    render(
      <ModalProducto
        producto={{ ...CON_FARDO, categoria: 'TEXTO SUELTO' } as unknown as ProductoDB}
        categorias={['PLACER']}
        rubrosDesactivados={['DESCONTINUADOS']}
        proveedores={[]}
        onSave={vi.fn()}
        onClose={vi.fn()}
        guardando={false}
        esAdmin
      />,
    )
    expect(screen.getByRole('option', { name: 'TEXTO SUELTO (no es un rubro de la lista)' })).toBeInTheDocument()
    expect(screen.queryByRole('option', { name: /desactivada/ })).toBeNull()
  })

  it('con la lista de desactivados, el desactivado sigue diciendo «desactivada»', () => {
    render(
      <ModalProducto
        producto={{ ...CON_FARDO, categoria: 'DESCONTINUADOS' } as unknown as ProductoDB}
        categorias={['PLACER']}
        rubrosDesactivados={['DESCONTINUADOS']}
        proveedores={[]}
        onSave={vi.fn()}
        onClose={vi.fn()}
        guardando={false}
        esAdmin
      />,
    )
    expect(screen.getByRole('option', { name: 'DESCONTINUADOS (desactivada)' })).toBeInTheDocument()
  })

  it('un producto con un rubro activo no suma ninguna opción de más', () => {
    renderFicha(CON_FARDO, ['PLACER'])
    expect(screen.queryByRole('option', { name: /desactivada/ })).toBeNull()
  })

  it('un producto nuevo no ve los rubros desactivados', () => {
    renderFicha(null, ['PLACER'])
    expect(screen.queryByRole('option', { name: /desactivada/ })).toBeNull()
  })
})
