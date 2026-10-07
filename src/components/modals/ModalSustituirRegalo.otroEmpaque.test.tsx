/**
 * `ModalSustituirRegalo` con otro empaque u otro producto (#950).
 *
 * Con UNA fila, el admin puede elegir cualquier producto operativo. Si es de
 * otra categoría o de otro empaque, la cantidad se sugiere POR VALOR y se puede
 * corregir; si es de otra categoría sin `unidades_por_bulto`, no deja confirmar.
 * El reparto (dos filas o más) sigue restringido a la misma categoría, y quien
 * no es admin tampoco ve los de otra categoría.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent, waitFor } from '@testing-library/react'

// Precios de prod: Manaos 3L $11.100 el fardo x6 (1850 la botella),
// Placer 500 $7.000 el fardo x12 (583,33 la botella).
const PRODUCTOS = [
  { id: '82', nombre: 'Manaos Manzana 3L', precio: 11100, stock: 100, categoria_id: 'manaos', subcategoria_id: '3l', unidades_por_bulto: 6 },
  { id: '80', nombre: 'Manaos Naranja 3L', precio: 11100, stock: 100, categoria_id: 'manaos', subcategoria_id: '3l', unidades_por_bulto: 6 },
  { id: '125', nombre: 'Placer Pomelo 500', precio: 7000, stock: 50, categoria_id: 'placer', subcategoria_id: '500', unidades_por_bulto: 12 },
  { id: '500', nombre: 'Papas Fritas', precio: 900, stock: 50, categoria_id: 'snacks', subcategoria_id: null, unidades_por_bulto: null },
]

const dividir = vi.fn()
const sustituir = vi.fn()

vi.mock('../../hooks/queries', () => ({
  useProductosQuery: () => ({ data: PRODUCTOS }),
  usePromoAcumuladorQuery: () => ({ data: null }),
}))
vi.mock('../../hooks/queries/useSustituirRegaloMutation', () => ({
  useSustituirRegaloMutation: () => ({ mutateAsync: sustituir, isPending: false }),
  useDividirRegaloMutation: () => ({ mutateAsync: dividir, isPending: false }),
}))
vi.mock('../../contexts/NotificationContext', () => ({
  useNotification: () => ({ success: vi.fn(), error: vi.fn() }),
}))

import ModalSustituirRegalo from './ModalSustituirRegalo'
import type { ProductoDB } from '../../types'

const renderModal = (puedeCambiarDeProducto = true) => render(
  <ModalSustituirRegalo
    pedidoItemId="24656"
    productoOriginal={PRODUCTOS[0] as unknown as ProductoDB}
    cantidadOriginal={6}
    regaloMueveStock={false}
    promocionId="13"
    unidadesPorBloque={6}
    factorOriginal={6}
    puedeCambiarDeProducto={puedeCambiarDeProducto}
    onClose={vi.fn()}
  />,
)

const opciones = (n: number) => {
  fireEvent.focus(screen.getByRole('combobox', { name: `Producto ${n}` }))
  return screen.getAllByRole('option').map(o => (o.textContent ?? '').split(' ·')[0])
}
const elegir = (n: number, id: string) => {
  const nombre = PRODUCTOS.find(p => p.id === id)!.nombre
  fireEvent.focus(screen.getByRole('combobox', { name: `Producto ${n}` }))
  const opcion = screen.getAllByRole('option').find(o => (o.textContent ?? '').startsWith(`${nombre} ·`))
  if (!opcion) throw new Error(`no hay opcion para ${nombre}`)
  fireEvent.click(opcion)
}
const cantidad = (n: number) => screen.getByLabelText(`Cantidad ${n}`) as HTMLInputElement
const motivo = (txt: string) =>
  fireEvent.change(screen.getByPlaceholderText(/el cliente prefiere/i), { target: { value: txt } })

describe('ModalSustituirRegalo — otro empaque u otro producto (#950)', () => {
  beforeEach(() => {
    sustituir.mockReset().mockResolvedValue({ sustitucionId: '1', modo: 'B' })
    dividir.mockReset()
  })

  it('el admin ve productos de otra categoría en el cambio simple', () => {
    renderModal()
    expect(opciones(1)).toEqual(['Manaos Naranja 3L', 'Papas Fritas', 'Placer Pomelo 500'])
  })

  it('quien no es admin sigue viendo sólo la misma categoría', () => {
    renderModal(false)
    expect(opciones(1)).toEqual(['Manaos Naranja 3L'])
    expect(screen.getByText(/Sólo productos de la misma categoría/)).toBeInTheDocument()
  })

  it('otra categoría: sugiere la cantidad por valor, la muestra y deja editarla', async () => {
    renderModal()
    elegir(1, '125')
    // 6 botellas × $1.850 = $11.100 → 11.100 / (7.000/12) = 19,03 → 19
    expect(cantidad(1).value).toBe('19')
    expect(screen.getByText(/de regalo → 19 de Placer Pomelo 500/)).toBeInTheDocument()
    // El contador del sustituto cuenta con SU empaque (12), no con el de la promo.
    expect(screen.getByText(/sube/).textContent).toMatch(/0\/12/)

    fireEvent.change(cantidad(1), { target: { value: '18' } })
    // Al salir del campo se confirma lo tipeado (en pantalla, el click en
    // "usar 19" ya saca el foco del campo).
    fireEvent.blur(cantidad(1))
    expect(cantidad(1).value).toBe('18')
    // Se puede volver a la sugerida.
    fireEvent.click(screen.getByRole('button', { name: 'usar 19' }))
    expect(cantidad(1).value).toBe('19')
    fireEvent.change(cantidad(1), { target: { value: '18' } })

    motivo('el cliente prefiere Placer')
    fireEvent.click(screen.getByRole('button', { name: /cambiar regalo/i }))
    await waitFor(() => expect(sustituir).toHaveBeenCalledTimes(1))
    expect(sustituir.mock.calls[0][0]).toMatchObject({ productoNuevoId: '125', cantidadNueva: 18 })
  })

  it('mismo empaque y misma categoría: la cantidad sigue siendo la original, sin cálculo', () => {
    renderModal()
    elegir(1, '80')
    expect(cantidad(1).value).toBe('6')
    expect(screen.queryByText(/de regalo →/)).not.toBeInTheDocument()
  })

  it('otra categoría sin unidades por bulto: pide cargarlo y no deja confirmar', () => {
    renderModal()
    elegir(1, '500')
    expect(screen.getByRole('alert').textContent).toMatch(/Papas Fritas es de otra categoría y no tiene cargadas/)
    motivo('quiere papas')
    const confirmar = screen.getByRole('button', { name: /cambiar regalo/i })
    expect(confirmar).toBeDisabled()
    fireEvent.click(confirmar)
    expect(sustituir).not.toHaveBeenCalled()
  })

  it('el reparto sigue restringido a la misma categoría aunque sea admin', () => {
    renderModal()
    fireEvent.click(screen.getByRole('button', { name: /repartir en otro sabor/i }))
    expect(opciones(1)).toEqual(['Manaos Manzana 3L', 'Manaos Naranja 3L'])
    expect(screen.getByText(/Sólo productos de la misma categoría/)).toBeInTheDocument()
  })
})
