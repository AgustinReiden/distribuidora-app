/**
 * El mínimo de venta masivo no deja pasar más de 99.999.999 unidades: la base lo frena con un
 * CHECK y el usuario vería el 23514 crudo. Se avisa en el formulario y no se deja aplicar.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import ModalMinimoVentaMasivo from './ModalMinimoVentaMasivo'
import type { ProductoDB } from '../../types'
import type { CategoriaDB } from '../../hooks/queries/useCategoriasQuery'

vi.mock('../../hooks/queries', () => ({
  useActualizarMinimoVentaMasivoMutation: () => ({ mutateAsync: vi.fn(), isPending: false }),
}))
vi.mock('../../contexts/NotificationContext', () => ({
  useNotification: () => ({ success: vi.fn(), error: vi.fn(), warning: vi.fn() }),
}))

const categorias = [{ id: 'c1', nombre: 'Fideos', activa: true }] as unknown as CategoriaDB[]
const productos = [{ id: 'p1', nombre: 'Tallarín', categoria: 'Fideos', categoria_id: 'c1' }] as unknown as ProductoDB[]

function abrir() {
  render(<ModalMinimoVentaMasivo productos={productos} categorias={categorias} onClose={vi.fn()} />)
  fireEvent.change(screen.getByLabelText('Categoría'), { target: { value: 'c1' } })
}

describe('ModalMinimoVentaMasivo — tope de 99.999.999', () => {
  it('con un mínimo razonable deja aplicar', () => {
    abrir()
    expect(screen.getByRole('button', { name: 'Aplicar mínimo' })).toBeEnabled()
    expect(screen.queryByRole('alert')).not.toBeInTheDocument()
  })

  it('con más de 99.999.999 muestra el motivo y no deja aplicar', () => {
    abrir()
    fireEvent.change(screen.getByLabelText('Mínimo de unidades'), { target: { value: '100000000' } })

    expect(screen.getByRole('alert')).toHaveTextContent('no puede superar las 99.999.999 unidades')
    expect(screen.getByRole('button', { name: 'Aplicar mínimo' })).toBeDisabled()
  })

  it('con exactamente 99.999.999 deja aplicar', () => {
    abrir()
    fireEvent.change(screen.getByLabelText('Mínimo de unidades'), { target: { value: '99999999' } })

    expect(screen.queryByRole('alert')).not.toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Aplicar mínimo' })).toBeEnabled()
  })
})
