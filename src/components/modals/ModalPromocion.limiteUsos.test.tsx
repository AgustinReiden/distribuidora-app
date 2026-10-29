/**
 * #1261: el límite de usos cuenta unidades de regalo y se hace cumplir al
 * vender (decisión del dueño, 2026-10-28). El cartel tiene que decirlo, y en
 * una promo con fracción, aclarar que cuenta subunidades y no unidades del
 * contenedor. Antes prometía "bonificaciones entregadas", que no era lo que
 * contaba ni cuándo.
 */
import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import ModalPromocion from './ModalPromocion'
import type { ProductoDB } from '../../types'

vi.mock('../../hooks/queries/usePromocionesQuery', () => ({
  usePreviewCambioFactorQuery: () => ({ data: [], isLoading: false }),
}))

const PRODUCTOS = [{ id: '1', nombre: 'PRODUCTO A', precio: 100, stock: 10 }] as unknown as ProductoDB[]

function renderModal() {
  render(<ModalPromocion promocion={null} productos={PRODUCTOS} onSave={vi.fn()} onClose={vi.fn()} />)
}

const cartel = () => screen.getByTestId('limite-usos-ayuda').textContent ?? ''

describe('ModalPromocion · cartel del límite de usos (#1261)', () => {
  it('unidad entera: cuenta unidades de regalo y corta al vender, para todos', () => {
    renderModal()
    expect(cartel()).toMatch(/unidades de regalo/)
    expect(cartel()).toMatch(/no se puede guardar/)
    expect(cartel()).toMatch(/cancela/)
    expect(cartel()).not.toMatch(/bonificaciones entregadas/)
  })

  it('fracción: aclara que cuenta subunidades, no unidades del contenedor', async () => {
    renderModal()
    await userEvent.click(screen.getByText('Fracción de unidad'))
    expect(cartel()).toMatch(/subunidades/)
    expect(cartel()).toMatch(/no unidades del producto contenedor/)
  })

  it('fracción: el ejemplo usa las subunidades por unidad cargadas', async () => {
    renderModal()
    await userEvent.click(screen.getByText('Fracción de unidad'))
    await userEvent.type(screen.getByPlaceholderText('Ej: 6'), '12')
    expect(cartel()).toMatch(/con 12 por unidad, un límite de 120 son 10 unidades del contenedor/)
  })
})
