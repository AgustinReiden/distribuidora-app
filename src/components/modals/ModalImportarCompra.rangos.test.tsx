/**
 * #1471 (STK-F-4): el import de Excel aceptaba cualquier bonificación (una
 * columna "gratis" en unidades se tomaba como porcentaje), redondeaba la
 * cantidad con decimales en silencio y dejaba pasar el costo negativo. Ahora
 * esas filas se rechazan y se dice por qué; las buenas se importan igual.
 */
import { describe, it, expect, vi } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import type { ProductoDB } from '../../types'

const filas = vi.hoisted(() => [
  { Codigo: 'OK', Cantidad: 10, Costo: 100, 'Bonificacion%': 5 },
  { Codigo: 'DEC', Cantidad: 2.5, Costo: 100 },
  { Codigo: 'BON', Cantidad: 1, Costo: 100, 'Bonificacion%': 150 },
  { Codigo: 'NEG', Cantidad: 1, Costo: -1 },
  { Codigo: 'GRA', Cantidad: 12, Costo: 100, Gratis: 2 },
  { Codigo: 'CER', Cantidad: 12, Costo: 100, Gratis: 0 },
  { Codigo: 'CS0', Cantidad: 5, Costo: 0 },
  { Codigo: 'REG', Cantidad: 2, Costo: 0, 'Bonificacion%': 100 },
])

vi.mock('../../utils/excel', () => ({
  readExcelFile: () => Promise.resolve(filas),
}))

import ModalImportarCompra from './ModalImportarCompra'

// Con costo en la ficha: un 0 del Excel ya no se cambia en silencio por él (CMP-5, #1557).
const PRODUCTOS = ['OK', 'DEC', 'BON', 'NEG', 'GRA', 'CER', 'CS0', 'REG'].map((codigo, i) =>
  ({ id: String(i + 1), nombre: `Producto ${codigo}`, codigo, stock: 0, condicion_iva: 'gravado', porcentaje_iva: 21, costo_sin_iva: 80 } as unknown as ProductoDB))

describe('ModalImportarCompra · los rangos de cada fila (#1471)', () => {
  it('rechaza decimales, bonificación fuera de 0 a 100, costo negativo y "gratis" con unidades', async () => {
    const onImportar = vi.fn()
    const user = userEvent.setup()
    const { container } = render(<ModalImportarCompra productos={PRODUCTOS} onImportar={onImportar} onClose={vi.fn()} />)

    const archivo = new File(['x'.repeat(200)], 'compra.xlsx', {
      type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    })
    await user.upload(container.querySelector('input[type="file"]') as HTMLInputElement, archivo)

    expect(await screen.findByText(/Fila 3 \(DEC\): la cantidad tiene que ser entera/)).toBeInTheDocument()
    expect(screen.getByText(/Fila 4 \(BON\): la bonificación es un porcentaje, de 0 a 100/)).toBeInTheDocument()
    expect(screen.getByText(/Fila 5 \(NEG\): el costo no puede ser negativo/)).toBeInTheDocument()
    expect(screen.getByText(/Fila 6 \(GRA\): la columna "gratis" no se importa/)).toBeInTheDocument()
    // CMP-5 (#1557): costo 0 sin bonificación del 100 % no pasa; con ella es un regalo.
    expect(screen.getByText(/Fila 8 \(CS0\): el costo es 0: si viene sin cargo, cargalo con bonificación del 100 %/)).toBeInTheDocument()

    await user.click(await screen.findByRole('button', { name: /Importar 3 items/ }))
    await waitFor(() => expect(onImportar).toHaveBeenCalledTimes(1))
    const items = onImportar.mock.calls[0][0] as { productoCodigo: string; cantidad: number; bonificacion: number; costoUnitario: number }[]
    expect(items.map(i => [i.productoCodigo, i.cantidad, i.bonificacion, i.costoUnitario])).toEqual([
      ['OK', 10, 5, 100],
      ['CER', 12, 0, 100],
      ['REG', 2, 100, 0],
    ])
  })
})
