/**
 * catalogo-B4 (tanda 6, #1603): la ficha de producto no ponía tope máximo. La base tiene
 * `precio numeric(10,2)`, `stock integer` y `codigo varchar(50)`: un exceso llegaba como
 * `22003` / `22001` crudo. Ahora queda en rojo con el límite y el botón Guardar no guarda.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import ModalProducto, { modalProductoSchema } from './ModalProducto'
import type { ProductoDB } from '../../types'

vi.mock('../../hooks/queries', () => ({
  useMarcasQuery: () => ({ data: [] }),
  useCatalogoIIQuery: () => ({ data: { encuadres: [], alicuotas: [] } }),
}))
vi.mock('../productos/ProductoCondicionesMayoristas', () => ({ default: () => null }))
vi.mock('../productos/ProductoLotes', () => ({ default: () => null }))
vi.mock('../productos/ProductoMedidas', () => ({ default: () => null }))
vi.mock('../productos/ProductoUltimaCompra', () => ({ default: () => null }))

const P = {
  id: '125', nombre: 'Jugo de prueba 500 cc', precio: 7000, stock: 76, stock_minimo: 25, categoria: 'JUGOS',
  porcentaje_iva: 21, condicion_iva: 'gravado', codigo: 'J-500',
} as unknown as ProductoDB

const base = { nombre: 'Aceite 900ml', stock: 1, precio: 100 }
const mensajes = (datos: Record<string, unknown>) => {
  const r = modalProductoSchema.safeParse({ ...base, ...datos })
  return r.success ? [] : r.error.issues.map(i => `${i.path.join('.')}: ${i.message}`)
}

describe('modalProductoSchema · topes de las columnas', () => {
  it('el tope exacto pasa; uno más se rechaza con su motivo', () => {
    expect(mensajes({ precio: 99999999.99, stock: 2147483647, stock_minimo: 2147483647 })).toEqual([])
    expect(mensajes({ precio: 100000000 })).toEqual(['precio: El precio no puede superar $ 99.999.999,99.'])
    expect(mensajes({ stock: 2147483648 })).toEqual(['stock: El stock no puede superar 2.147.483.647 unidades.'])
    expect(mensajes({ stock_minimo: 2147483648 })).toEqual(['stock_minimo: El stock mínimo no puede superar 2.147.483.647 unidades.'])
  })

  it('el código de 50 caracteres pasa; de 51 se rechaza (sin contar los espacios de los bordes)', () => {
    expect(mensajes({ codigo: 'X'.repeat(50) })).toEqual([])
    expect(mensajes({ codigo: `  ${'X'.repeat(50)}  ` })).toEqual([])
    expect(mensajes({ codigo: 'X'.repeat(51) })).toEqual(['codigo: El código no puede tener más de 50 caracteres.'])
  })
})

describe('ModalProducto · los topes en la pantalla', () => {
  beforeEach(() => { Element.prototype.scrollIntoView = vi.fn() })

  function abrir() {
    const onSave = vi.fn()
    render(<ModalProducto producto={P} categorias={['JUGOS']} proveedores={[]} onSave={onSave} onClose={vi.fn()} guardando={false} esAdmin />)
    return onSave
  }

  it('un código de 51 caracteres queda en rojo con su motivo y no se guarda', async () => {
    const onSave = abrir()
    const campo = screen.getByPlaceholderText('SKU o codigo interno')
    await userEvent.clear(campo)
    await userEvent.type(campo, 'X'.repeat(51))
    await userEvent.click(screen.getByRole('button', { name: /Guardar/ }))
    expect(await screen.findByText('El código no puede tener más de 50 caracteres.')).toBeInTheDocument()
    expect(onSave).not.toHaveBeenCalled()
  })

  it('un precio por encima del tope queda en rojo con el límite y Guardar no guarda', async () => {
    const onSave = abrir()
    const campo = screen.getByDisplayValue('7.000')
    await userEvent.clear(campo)
    await userEvent.type(campo, '100000000')
    await userEvent.tab()
    expect(await screen.findByText('El precio no puede superar $ 99.999.999,99.')).toBeInTheDocument()
    await userEvent.click(screen.getByRole('button', { name: /Guardar/ }))
    expect(onSave).not.toHaveBeenCalled()
  })

  it('un stock por encima del tope queda en rojo con el límite y Guardar no guarda', async () => {
    const onSave = abrir()
    const campo = screen.getByDisplayValue('76')
    await userEvent.clear(campo)
    await userEvent.type(campo, '2147483648')
    await userEvent.tab()
    expect(await screen.findByText('El stock no puede superar 2.147.483.647 unidades.')).toBeInTheDocument()
    await userEvent.click(screen.getByRole('button', { name: /Guardar/ }))
    expect(onSave).not.toHaveBeenCalled()
  })
})
