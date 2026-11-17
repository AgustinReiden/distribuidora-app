/**
 * 1557-b11: el import elegía la columna por `includes`, y «Precio de venta»
 * (sin «Costo») se tomaba como el costo de la compra. Un precio de venta no es
 * un costo: cargar una compra con él infla el stock valorizado y el costo
 * promedio de cada producto.
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

describe('ModalImportarCompra · un precio de venta no es un costo (1557-b11)', () => {
  beforeEach(() => {
    hoisted.filas = []
  })

  it('sin columna de costo, «Precio de venta» no se importa como costo', async () => {
    const { onImportar } = await subir([{ Codigo: 'A', Cantidad: 5, 'Precio de venta': 1500 }])

    expect(await screen.findByText(/No se encontró una columna de costo/)).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /Importar \d+ item/ })).not.toBeInTheDocument()
    expect(onImportar).not.toHaveBeenCalled()
  })

  it('con «Costo» y «Precio de venta» toma el costo, esté la columna donde esté', async () => {
    const { onImportar, user } = await subir([{ Codigo: 'A', Cantidad: 5, 'Precio de venta': 1500, Costo: 900 }])

    await user.click(await screen.findByRole('button', { name: /Importar 1 item/ }))
    await waitFor(() => expect(onImportar).toHaveBeenCalledTimes(1))
    expect((onImportar.mock.calls[0][0] as { costoUnitario: number }[])[0].costoUnitario).toBe(900)
  })

  it('«Precio neto» y «Precio» siguen siendo costo (lista del proveedor)', async () => {
    const { onImportar, user } = await subir([{ Codigo: 'A', Cantidad: 5, 'Precio neto': 700 }])

    await user.click(await screen.findByRole('button', { name: /Importar 1 item/ }))
    await waitFor(() => expect(onImportar).toHaveBeenCalledTimes(1))
    expect((onImportar.mock.calls[0][0] as { costoUnitario: number }[])[0].costoUnitario).toBe(700)
  })

  it('«PVP» y «Precio público» tampoco son costo', async () => {
    await subir([{ Codigo: 'A', Cantidad: 5, PVP: 1500, 'Precio público': 1400 }])
    expect(await screen.findByText(/No se encontró una columna de costo/)).toBeInTheDocument()
  })
})
