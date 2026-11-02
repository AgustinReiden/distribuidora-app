/**
 * #1324 (decisión del dueño, 2026-10-29): el tipo de regalo de una promo se puede
 * cambiar con pedidos abiertos. La pantalla avisa cuántos son y deja seguir: esos
 * pedidos leen su foto y no cambian.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import ModalPromocion from './ModalPromocion'
import type { ProductoDB } from '../../types'
import type { PromocionConDetalles } from '../../hooks/queries/usePromocionesQuery'

const { abiertos } = vi.hoisted(() => ({ abiertos: vi.fn() }))

vi.mock('../../hooks/queries/usePromocionesQuery', () => ({
  usePreviewCambioFactorQuery: () => ({ data: [], isLoading: false }),
  usePromoPedidosAbiertosQuery: (...args: unknown[]) => abiertos(...args),
}))

const PRODUCTOS = [{ id: '1', nombre: 'PRODUCTO A', precio: 100, stock: 10 }] as unknown as ProductoDB[]

const PROMO = {
  id: '7',
  nombre: 'Promo entera',
  tipo: 'bonificacion',
  activo: true,
  fecha_inicio: '2026-01-01',
  fecha_fin: null,
  producto_regalo_id: '1',
  ajuste_automatico: false,
  regalo_mueve_stock: true,
  descripcion_regalo: null,
  productos: [{ producto_id: '1' }],
  reglas: [
    { clave: 'cantidad_compra', valor: 10 },
    { clave: 'cantidad_bonificacion', valor: 2 },
  ],
} as unknown as PromocionConDetalles

const aviso = () => screen.queryByTestId('aviso-tipo-regalo')

describe('ModalPromocion · aviso de pedidos abiertos al cambiar el tipo de regalo (#1324)', () => {
  beforeEach(() => {
    abiertos.mockReset()
    abiertos.mockReturnValue({ data: 3 })
  })

  it('sin cambiar el tipo no pregunta ni avisa', () => {
    render(<ModalPromocion promocion={PROMO} productos={PRODUCTOS} onSave={vi.fn()} onClose={vi.fn()} />)
    expect(abiertos).toHaveBeenLastCalledWith('7', false)
    expect(aviso()).toBeNull()
  })

  it('al cambiarlo dice cuántos pedidos abiertos hay y que no los afecta', async () => {
    render(<ModalPromocion promocion={PROMO} productos={PRODUCTOS} onSave={vi.fn()} onClose={vi.fn()} />)
    await userEvent.click(screen.getByText('Fracción de unidad'))
    expect(abiertos).toHaveBeenLastCalledWith('7', true)
    expect(aviso()).toHaveTextContent('3 pedidos abiertos')
    expect(aviso()).toHaveTextContent('el cambio vale para los pedidos nuevos')
  })

  it('deja seguir: el botón de guardar no se deshabilita', async () => {
    render(<ModalPromocion promocion={PROMO} productos={PRODUCTOS} onSave={vi.fn()} onClose={vi.fn()} />)
    await userEvent.click(screen.getByText('Fracción de unidad'))
    expect(screen.getByRole('button', { name: 'Actualizar' })).toBeEnabled()
  })

  it('sin pedidos abiertos no avisa', async () => {
    abiertos.mockReturnValue({ data: 0 })
    render(<ModalPromocion promocion={PROMO} productos={PRODUCTOS} onSave={vi.fn()} onClose={vi.fn()} />)
    await userEvent.click(screen.getByText('Fracción de unidad'))
    expect(aviso()).toBeNull()
  })

  it('una promo nueva no tiene pedidos que contar', async () => {
    render(<ModalPromocion promocion={null} productos={PRODUCTOS} onSave={vi.fn()} onClose={vi.fn()} />)
    await userEvent.click(screen.getByText('Fracción de unidad'))
    expect(abiertos).toHaveBeenLastCalledWith(null, false)
    expect(aviso()).toBeNull()
  })
})
