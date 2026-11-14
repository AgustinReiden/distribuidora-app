/**
 * FRG-1 (#1557) en el import de Excel: la 499 redondea `costo_unitario` al centavo y controla
 * el subtotal de cada renglón con tolerancia de 0,01. El import pasaba el costo de la celda tal
 * cual (=10000/2400 → 4,1666…) y ModalCompra armaba `subtotal = cantidad × costo` con ese costo
 * crudo: 2.400 u. a 4,1666 mandaban 9.999,84 y el server, con 4,17, daba 10.008 y rechazaba la
 * compra entera. Ahora el costo entra al modal ya al centavo, como el del escaneo.
 */
import { describe, it, expect, vi } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import type { ProductoDB } from '../../types'
import { redondearSQL } from '../../utils/calculations'

const filas = vi.hoisted(() => [
  { Codigo: 'A', Cantidad: 2400, Costo: 4.1666666667 },
  { Codigo: 'B', Cantidad: 2400, Costo: '4,1666' },
  { Codigo: 'C', Cantidad: 12, Costo: '833,3333' },
  { Codigo: 'D', Cantidad: 24, Costo: 152.875, 'Bonificacion%': 5 },
  { Codigo: 'E', Cantidad: 10, Costo: '100,00' },
])

vi.mock('../../utils/excel', () => ({
  readExcelFile: () => Promise.resolve(filas),
}))

import ModalImportarCompra from './ModalImportarCompra'

const PRODUCTOS = ['A', 'B', 'C', 'D', 'E'].map((codigo, i) =>
  ({ id: String(i + 1), nombre: `Producto ${codigo}`, codigo, stock: 0, condicion_iva: 'gravado', porcentaje_iva: 21 } as unknown as ProductoDB))

/**
 * El renglón como lo arma ModalCompra al guardar y el control de la 499: costo al centavo y
 * |round(subtotal, 2) − round(cantidad × costo × (1 − bonif), 2)| > 0,01 rechaza.
 */
function cierraEnElServer(cantidad: number, costoUnitario: number, bonificacion: number): boolean {
  const subtotal = cantidad * costoUnitario * (1 - bonificacion / 100)
  const da = redondearSQL(cantidad * redondearSQL(costoUnitario, 2) * (1 - bonificacion / 100), 2)
  return Math.abs(redondearSQL(subtotal, 2) - da) <= 0.01
}

describe('ModalImportarCompra · el costo entra al centavo (FRG-1, #1557)', () => {
  it('redondea el costo de la celda y el renglón cierra contra su subtotal', async () => {
    const onImportar = vi.fn()
    const user = userEvent.setup()
    const { container } = render(<ModalImportarCompra productos={PRODUCTOS} onImportar={onImportar} onClose={vi.fn()} />)

    const archivo = new File(['x'.repeat(200)], 'compra.xlsx', {
      type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    })
    await user.upload(container.querySelector('input[type="file"]') as HTMLInputElement, archivo)
    await user.click(await screen.findByRole('button', { name: /Importar 5 items/ }))

    await waitFor(() => expect(onImportar).toHaveBeenCalledTimes(1))
    const items = onImportar.mock.calls[0][0] as { productoCodigo: string; cantidad: number; bonificacion: number; costoUnitario: number }[]
    expect(items.map(i => [i.productoCodigo, i.costoUnitario])).toEqual([
      ['A', 4.17],
      ['B', 4.17],
      ['C', 833.33],
      ['D', 152.88],
      ['E', 100],
    ])
    expect(items.filter(i => !cierraEnElServer(i.cantidad, i.costoUnitario, i.bonificacion)).map(i => i.productoCodigo)).toEqual([])
  })
})
