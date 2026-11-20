/**
 * H6(b) de la revisión de C7 (ya pasaba antes): en la edición de un envío entre sucursales, el efecto que
 * prellena las líneas dependía de `productos`. Cualquier refetch del catálogo (volver la señal, otra
 * pantalla que invalida productos) devolvía las líneas a lo guardado: se perdían las cantidades tipeadas
 * y los productos agregados. Ahora se prellena una vez por envío; un catálogo nuevo sólo actualiza el
 * stock disponible de cada línea, sin tocar lo editado.
 */
import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import '@testing-library/jest-dom/vitest'
import ModalCrearMovimiento from './ModalCrearMovimiento'
import type { ProductoDB, SucursalDB } from '../../types'
import type { MovimientoItemDB, MovimientoSucursalDB } from '../../hooks/queries'

const SUCURSALES = [{ id: 2, nombre: 'Sucursal de prueba' }] as unknown as SucursalDB[]
const catalogo = (stockFideos: number, stockArroz = 20) => ([
  { id: '5', nombre: 'Fideos de prueba', codigo: 'F1', stock: stockFideos },
  { id: '6', nombre: 'Arroz de prueba', codigo: 'A1', stock: stockArroz },
]) as unknown as ProductoDB[]
const MOVIMIENTO = { id: 77, sucursal_destino_id: 2, notas: '' } as unknown as MovimientoSucursalDB
// El envío ya descontó 3 de fideos: el catálogo trae 9, y con lo reservado hay 12 disponibles.
const ITEMS = [{ producto_origen_id: 5, cantidad: 3, origen_nombre: 'Fideos de prueba' }] as unknown as MovimientoItemDB[]

const el = (productos: ProductoDB[], items = ITEMS) => (
  <ModalCrearMovimiento
    sucursales={SUCURSALES} productos={productos} guardando={false} onClose={vi.fn()}
    modo="editar" movimiento={MOVIMIENTO} itemsIniciales={items} onGuardarEdicion={vi.fn()}
  />
)

describe('ModalCrearMovimiento · un refetch del catálogo no borra lo editado (H6b)', () => {
  it('conserva la cantidad tipeada y el producto agregado, y actualiza el stock disponible', async () => {
    const user = userEvent.setup()
    const { rerender } = render(el(catalogo(9)))
    const fideos = screen.getByLabelText('Cantidad de Fideos de prueba')
    expect(fideos).toHaveValue('3')

    await user.clear(fideos)
    await user.type(fideos, '7')
    await user.type(screen.getByPlaceholderText('Buscar por nombre o código...'), 'Arroz')
    await user.click(screen.getByRole('button', { name: /Arroz de prueba/ }))
    expect(screen.getByLabelText('Cantidad de Arroz de prueba')).toBeInTheDocument()

    // Vuelve la señal: el catálogo se pide de nuevo (otra identidad, y el stock de fideos bajó a 6).
    rerender(el(catalogo(6)))

    expect(screen.getByLabelText('Cantidad de Fideos de prueba')).toHaveValue('7')
    expect(screen.getByLabelText('Cantidad de Arroz de prueba')).toBeInTheDocument()
    // 6 en el catálogo + 3 que el envío ya tiene reservados.
    expect(screen.getByText('stock disponible: 9', { selector: 'p' })).toBeInTheDocument()
  })

  it('al recibir otros renglones del envío (otra versión guardada) vuelve a prellenar', async () => {
    const { rerender } = render(el(catalogo(9)))
    expect(screen.getByLabelText('Cantidad de Fideos de prueba')).toHaveValue('3')

    const otros = [{ producto_origen_id: 5, cantidad: 4, origen_nombre: 'Fideos de prueba' }] as unknown as MovimientoItemDB[]
    rerender(el(catalogo(9), otros))
    expect(screen.getByLabelText('Cantidad de Fideos de prueba')).toHaveValue('4')
  })
})
