/**
 * El import de Excel saca los atributos fiscales de la ficha, porque el archivo
 * no los trae. Se sube un archivo de verdad al input y sólo se reemplaza la
 * lectura del .xlsx: lo que se prueba es lo que le llega a la compra.
 */
import { describe, it, expect, vi } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import type { ProductoDB } from '../../types'

const filas = vi.hoisted(() => [
  { Codigo: 'EXE', Cantidad: 1, Costo: 100 },
  { Codigo: 'NOG', Cantidad: 1, Costo: 100 },
  { Codigo: 'MED', Cantidad: 1, Costo: 100 },
  { Codigo: 'SIN', Cantidad: 1, Costo: 100 },
])

vi.mock('../../utils/excel', () => ({
  readExcelFile: () => Promise.resolve(filas),
}))

import ModalImportarCompra from './ModalImportarCompra'

const producto = (id: string, codigo: string, condicion_iva: string, porcentaje_iva: number | null) =>
  ({ id, nombre: `Producto ${codigo}`, codigo, stock: 0, condicion_iva, porcentaje_iva } as unknown as ProductoDB)

const PRODUCTOS = [
  producto('1', 'EXE', 'exento', null),
  producto('2', 'NOG', 'no_gravado', null),
  producto('3', 'MED', 'gravado', 10.5),
  producto('4', 'SIN', 'gravado', null),
]

describe('ModalImportarCompra · la alícuota sale de la ficha (#1274)', () => {
  it('exento y no gravado van en 0, 10,5 se conserva y gravado sin porcentaje es 21', async () => {
    const onImportar = vi.fn()
    const user = userEvent.setup()
    const { container } = render(<ModalImportarCompra productos={PRODUCTOS} onImportar={onImportar} onClose={vi.fn()} />)

    const archivo = new File(['x'.repeat(200)], 'compra.xlsx', {
      type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    })
    await user.upload(container.querySelector('input[type="file"]') as HTMLInputElement, archivo)
    await user.click(await screen.findByRole('button', { name: /Importar 4 items/ }))

    await waitFor(() => expect(onImportar).toHaveBeenCalledTimes(1))
    const items = onImportar.mock.calls[0][0] as { condicionIva: string; porcentajeIva: number }[]
    expect(items.map(i => [i.condicionIva, i.porcentajeIva])).toEqual([
      ['exento', 0],
      ['no_gravado', 0],
      ['gravado', 10.5],
      ['gravado', 21],
    ])
  })
})
