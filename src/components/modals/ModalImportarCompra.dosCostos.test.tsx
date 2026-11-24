/**
 * gestion-B11 (tanda 6, #1603): un archivo con dos columnas que pueden ser el costo («Costo con
 * IVA» antes que «Costo neto») cargaba la primera sin avisar. Ahora avisa cuál tomó.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import type { ProductoDB } from '../../types'

const hoisted = vi.hoisted(() => ({ filas: [] as Record<string, unknown>[] }))

vi.mock('../../utils/excel', () => ({
  readExcelFile: () => Promise.resolve(hoisted.filas),
}))

import ModalImportarCompra from './ModalImportarCompra'

const PRODUCTOS = [
  { id: '1', nombre: 'Producto A', codigo: 'A', stock: 0, condicion_iva: 'gravado', porcentaje_iva: 21 },
] as unknown as ProductoDB[]

async function subir(filas: Record<string, unknown>[]) {
  hoisted.filas = filas
  const onImportar = vi.fn()
  const user = userEvent.setup()
  const { container } = render(<ModalImportarCompra productos={PRODUCTOS} onImportar={onImportar} onClose={vi.fn()} />)
  const archivo = new File(['x'.repeat(200)], 'compra.xlsx', {
    type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  })
  await user.upload(container.querySelector('input[type="file"]') as HTMLInputElement, archivo)
  return { onImportar, user }
}

describe('ModalImportarCompra · dos columnas candidatas a costo (gestion-B11)', () => {
  beforeEach(() => { hoisted.filas = [] })

  it('avisa que hay dos y cuál tomó, y deja importar', async () => {
    const { onImportar, user } = await subir([
      { Codigo: 'A', Cantidad: 5, 'Costo con IVA': 121, 'Costo neto': 100 },
    ])

    const aviso = await screen.findByText(/Hay más de una columna que parece de costo/)
    expect(aviso.textContent).toContain('"Costo con IVA"')
    expect(aviso.textContent).toContain('"Costo neto"')
    expect(aviso.textContent).toMatch(/Se tomó "Costo con IVA"/)

    await user.click(await screen.findByRole('button', { name: /Importar 1 item/ }))
    await waitFor(() => expect(onImportar).toHaveBeenCalledTimes(1))
  })

  it('con una sola columna de costo no avisa nada', async () => {
    await subir([{ Codigo: 'A', Cantidad: 5, 'Costo neto': 100, 'Precio de venta': 150 }])
    await screen.findByRole('button', { name: /Importar 1 item/ })
    expect(screen.queryByText(/Hay más de una columna que parece de costo/)).not.toBeInTheDocument()
  })
})
