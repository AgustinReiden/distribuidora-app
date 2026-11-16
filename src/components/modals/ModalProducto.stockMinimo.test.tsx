/**
 * L3 (#1603): desde CAT-13 un stock mínimo de 0 apaga la alerta del producto, y
 * vacío usa 10. El campo confirmaba 0 al vaciarlo (`emptyValue={0}`, con el
 * placeholder «10»): el admin que borraba el número para «dejar el de siempre»
 * apagaba la alerta sin saberlo. Vaciar guarda vacío (null).
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import ModalProducto from './ModalProducto'
import { stockBajo } from '../../utils/stockMinimo'
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
  porcentaje_iva: 21, condicion_iva: 'gravado', unidades_de_venta_por_fardo: 6, etiqueta_bulto: 'FARDO',
} as unknown as ProductoDB

async function guardarConStockMinimo(texto: string, producto: ProductoDB = P) {
  const onSave = vi.fn()
  render(<ModalProducto producto={producto} categorias={['JUGOS']} proveedores={[]} onSave={onSave} onClose={vi.fn()} guardando={false} esAdmin />)
  const campo = screen.getByPlaceholderText('10')
  await userEvent.clear(campo)
  if (texto) await userEvent.type(campo, texto)
  await userEvent.click(screen.getByRole('button', { name: /Guardar/ }))
  expect(onSave).toHaveBeenCalledTimes(1)
  return onSave.mock.calls[0][0] as { stock_minimo?: number | null }
}

describe('ModalProducto: el stock mínimo vacío no es 0', () => {
  beforeEach(() => { Element.prototype.scrollIntoView = vi.fn() })

  it('vaciar el campo guarda vacío (null), que alerta con el mínimo de siempre', async () => {
    const guardado = await guardarConStockMinimo('')
    expect(guardado.stock_minimo).toBeNull()
    expect(stockBajo(3, guardado.stock_minimo)).toBe(true)
  })

  it('un 0 tipeado se guarda como 0: sin alerta', async () => {
    const guardado = await guardarConStockMinimo('0')
    expect(guardado.stock_minimo).toBe(0)
    expect(stockBajo(3, guardado.stock_minimo)).toBe(false)
  })

  it('un número se guarda como número', async () => {
    const guardado = await guardarConStockMinimo('40')
    expect(guardado.stock_minimo).toBe(40)
  })

  it('un producto sin mínimo cargado abre con el campo vacío y, sin tocarlo, no lo manda', async () => {
    const onSave = vi.fn()
    render(<ModalProducto producto={{ ...P, stock_minimo: null } as unknown as ProductoDB} categorias={['JUGOS']} proveedores={[]} onSave={onSave} onClose={vi.fn()} guardando={false} esAdmin />)
    expect((screen.getByPlaceholderText('10') as HTMLInputElement).value).toBe('')
    await userEvent.click(screen.getByRole('button', { name: /Guardar/ }))
    expect(onSave).toHaveBeenCalledTimes(1)
    expect(onSave.mock.calls[0][0].stock_minimo).toBeUndefined()
  })
})
