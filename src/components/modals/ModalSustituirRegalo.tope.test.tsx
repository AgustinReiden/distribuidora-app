/**
 * `ModalSustituirRegalo` y el tope del sustituto de quien no es admin (#1592, PRM-1;
 * decisión del dueño del 16/11).
 *
 * El server mide el sustituto contra el regalo que da la promo con el corte de la
 * línea: entra si es del mismo rubro con la misma cantidad o menos, o si no vale más
 * a precio de lista. La pantalla sugiere y topea con la misma cuenta
 * (`topeSustitutoRegalo`), así lo que propone entra.
 *
 * Fracción: la promo regala 4 botellas de Manaos 3L (fardo de 6 a $600 = $100 la
 * botella). La línea ya se había cambiado a Pomelo 500 ×6 (bulto de 12 a $720 = $60).
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'

const PRODUCTOS = [
  { id: '1', nombre: 'Manaos 3L', precio: 600, stock: 100, categoria_id: 'gaseosa', subcategoria_id: null, unidades_por_bulto: 6 },
  { id: '2', nombre: 'Pomelo 500', precio: 720, stock: 100, categoria_id: 'gaseosa', subcategoria_id: null, unidades_por_bulto: 12 },
  { id: '3', nombre: 'Cola 1L', precio: 120, stock: 100, categoria_id: 'gaseosa', subcategoria_id: null, unidades_por_bulto: 6 },
  { id: '4', nombre: 'Manaos 3L Uva', precio: 660, stock: 100, categoria_id: 'gaseosa', subcategoria_id: null, unidades_por_bulto: 6 },
]

const sustituir = vi.fn()

vi.mock('../../hooks/queries', () => ({
  useProductosQuery: () => ({ data: PRODUCTOS }),
  usePromoAcumuladorQuery: () => ({ data: null }),
}))
vi.mock('../../hooks/queries/useSustituirRegaloMutation', () => ({
  useSustituirRegaloMutation: () => ({ mutateAsync: sustituir, isPending: false }),
  useDividirRegaloMutation: () => ({ mutateAsync: vi.fn(), isPending: false }),
  // el corte de la línea: lo que da la promo, 4 botellas
  useCorteRegaloQuery: () => ({ data: 4 }),
}))
vi.mock('../../contexts/NotificationContext', () => ({
  useNotification: () => ({ success: vi.fn(), error: vi.fn() }),
}))

import ModalSustituirRegalo from './ModalSustituirRegalo'
import type { ProductoDB } from '../../types'

const renderModal = (esAdmin: boolean, original = PRODUCTOS[1], cantidadOriginal = 6, factorOriginal = 12) => render(
  <ModalSustituirRegalo
    pedidoItemId="77"
    productoOriginal={original as unknown as ProductoDB}
    cantidadOriginal={cantidadOriginal}
    regaloMueveStock={false}
    promocionId="9"
    unidadesPorBloque={6}
    factorOriginal={factorOriginal}
    puedeCambiarDeProducto={esAdmin}
    regaloPromo={PRODUCTOS[0] as unknown as ProductoDB}
    factorRegaloPromo={6}
    onClose={vi.fn()}
  />,
)

const elegir = (id: string) => {
  const nombre = PRODUCTOS.find(p => p.id === id)!.nombre
  fireEvent.focus(screen.getByRole('combobox', { name: 'Producto 1' }))
  const opcion = screen.getAllByRole('option').find(o => (o.textContent ?? '').startsWith(`${nombre} ·`))
  if (!opcion) throw new Error(`no hay opcion para ${nombre}`)
  fireEvent.click(opcion)
}
const cantidad = () => screen.getByLabelText('Cantidad 1') as HTMLInputElement
const confirmar = () => screen.getByRole('button', { name: /cambiar regalo/i })

describe('ModalSustituirRegalo — el tope del sustituto de quien no es admin (#1592)', () => {
  beforeEach(() => {
    sustituir.mockReset().mockResolvedValue({ sustitucionId: '1', modo: 'B' })
  })

  it('el cambio por valor se sugiere contra el regalo de la promo y su corte, no contra la línea', () => {
    renderModal(false)
    elegir('3')
    // 4 botellas de $100 = $400 → Cola 1L a $20 la botella: 20 (contra Pomelo ×6, 18).
    expect(cantidad().value).toBe('20')
    expect(screen.getByText(/Podés poner hasta 20 de Cola 1L: lo que da la promo es 4 de Manaos 3L/)).toBeInTheDocument()
    fireEvent.change(screen.getByPlaceholderText(/el cliente prefiere/i), { target: { value: 'prefiere cola' } })
    expect(confirmar()).toBeEnabled()
  })

  it('por encima del tope no deja confirmar, y lo dice', () => {
    renderModal(false)
    elegir('3')
    fireEvent.change(cantidad(), { target: { value: '21' } })
    fireEvent.blur(cantidad())
    fireEvent.change(screen.getByPlaceholderText(/el cliente prefiere/i), { target: { value: 'prefiere cola' } })
    expect(screen.getByRole('alert').textContent).toMatch(/hasta 20 de Cola 1L/)
    expect(confirmar()).toBeDisabled()
  })

  it('un sabor del mismo rubro, apenas más caro, entra con la misma cantidad', () => {
    // La línea es el regalo de la promo, 4 botellas: Uva ($110 la botella) ×4 entra por el rubro.
    renderModal(false, PRODUCTOS[0], 4, 6)
    elegir('4')
    expect(cantidad().value).toBe('4')
    expect(screen.getByText(/Podés poner hasta 4 de Manaos 3L Uva/)).toBeInTheDocument()
    fireEvent.change(screen.getByPlaceholderText(/el cliente prefiere/i), { target: { value: 'uva' } })
    expect(confirmar()).toBeEnabled()
  })

  it('el admin no tiene tope ni ve el aviso', () => {
    renderModal(true)
    elegir('3')
    expect(screen.queryByText(/Podés poner hasta/)).not.toBeInTheDocument()
    fireEvent.change(cantidad(), { target: { value: '50' } })
    fireEvent.blur(cantidad())
    fireEvent.change(screen.getByPlaceholderText(/el cliente prefiere/i), { target: { value: 'prefiere cola' } })
    expect(confirmar()).toBeEnabled()
  })
})
