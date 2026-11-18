/**
 * B20 (D17): una celda de texto del Excel se lee como se muestra la plata («1.250,50» es 1250,5), y
 * una que no es un número («1,234,567») no se carga como costo 0: la fila se rechaza con su motivo,
 * aunque sea un regalo (bonificación del 100 %), que con costo 0 pasaría callado.
 */
import { describe, it, expect, vi } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import type { ProductoDB } from '../../types'

const filas = vi.hoisted(() => [
  { Codigo: 'MIL', Cantidad: 2, Costo: '1.250,50' },
  { Codigo: 'ILE', Cantidad: 2, Costo: '1,234,567', 'Bonificacion%': 100 },
  { Codigo: 'BON', Cantidad: 2, Costo: 100, 'Bonificacion%': 'cinco' },
  { Codigo: 'SIM', Cantidad: 3, Costo: '150000' },
])

vi.mock('../../utils/excel', () => ({
  readExcelFile: () => Promise.resolve(filas),
}))

import ModalImportarCompra from './ModalImportarCompra'

const PRODUCTOS = ['MIL', 'ILE', 'BON', 'SIM'].map((codigo, i) =>
  ({ id: String(i + 1), nombre: `Producto ${codigo}`, codigo, stock: 0, condicion_iva: 'gravado', porcentaje_iva: 21, costo_sin_iva: 80 } as unknown as ProductoDB))

describe('ModalImportarCompra · celdas de texto (B20)', () => {
  it('lee los miles de la celda y rechaza la que no es un número', async () => {
    const onImportar = vi.fn()
    const user = userEvent.setup()
    const { container } = render(<ModalImportarCompra productos={PRODUCTOS} onImportar={onImportar} onClose={vi.fn()} />)

    const archivo = new File(['x'.repeat(200)], 'compra.xlsx', {
      type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    })
    await user.upload(container.querySelector('input[type="file"]') as HTMLInputElement, archivo)

    expect(await screen.findByText(/Fila 3 \(ILE\): el costo «1,234,567» no es un número/)).toBeInTheDocument()
    expect(screen.getByText(/Fila 4 \(BON\): la bonificación «cinco» no es un número/)).toBeInTheDocument()

    await user.click(await screen.findByRole('button', { name: /Importar 2 items/ }))
    await waitFor(() => expect(onImportar).toHaveBeenCalledTimes(1))
    const items = onImportar.mock.calls[0][0] as { productoCodigo: string; costoUnitario: number }[]
    expect(items.map(i => [i.productoCodigo, i.costoUnitario])).toEqual([
      ['MIL', 1250.5],
      ['SIM', 150000],
    ])
  })
})
