/**
 * #1560-b5: las medidas (unidades por pallet, por separador) tenían su propio lector, y «1.200»
 * pegado era 1,2. Ahora leen con el de toda la app: lo pegado se lee como se muestra la plata, y la
 * tecla del punto se escribe como coma (D17).
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import '@testing-library/jest-dom/vitest'
import ProductoMedidas from './ProductoMedidas'

const mutateAsync = vi.fn()

vi.mock('../../hooks/queries', () => ({
  useCargoMedidasQuery: () => ({
    data: [{ id: 'pal', nombre: 'Pallet', unidadSingular: 'pallet', activo: true, medidaBaseId: null }],
  }),
  useProductoMedidasQuery: () => ({ data: {} }),
  useGuardarProductoMedidasMutation: () => ({ mutateAsync, isPending: false }),
}))

vi.mock('../../hooks/supabase/useAuth', () => ({
  useAuth: () => ({ isAdminOrEncargado: true, perfil: { rol: 'admin' } }),
}))

describe('ProductoMedidas · lo tipeado', () => {
  beforeEach(() => { mutateAsync.mockReset(); mutateAsync.mockResolvedValue(undefined) })

  it.each([
    ['1.200', 1200],
    ['1200', 1200],
    ['333,3333', 333.3333],
    ['333.33', 333.33],
    ['1.200,5', 1200.5],
  ])('pegado %j se guarda %d', async (texto, esperado) => {
    const user = userEvent.setup()
    render(<ProductoMedidas productoId={7} />)
    await user.click(screen.getByRole('textbox'))
    await user.paste(texto)
    await user.keyboard('{Enter}')
    expect(mutateAsync).toHaveBeenCalledWith([{ productoId: '7', medidaId: 'pal', unidadesPor: esperado }])
  })

  it('tipeado «1200» se ve «1.200» (los miles los pone el campo) y se guarda 1200', async () => {
    const user = userEvent.setup()
    render(<ProductoMedidas productoId={7} />)
    await user.type(screen.getByRole('textbox'), '1200')
    expect(screen.getByRole('textbox')).toHaveValue('1.200')
    await user.keyboard('{Enter}')
    expect(mutateAsync).toHaveBeenCalledWith([{ productoId: '7', medidaId: 'pal', unidadesPor: 1200 }])
  })

  it('tipeado «1.200» se ve «1,200» y se guarda 1,2', async () => {
    const user = userEvent.setup()
    render(<ProductoMedidas productoId={7} />)
    await user.type(screen.getByRole('textbox'), '1.200')
    expect(screen.getByRole('textbox')).toHaveValue('1,200')
    await user.keyboard('{Enter}')
    expect(mutateAsync).toHaveBeenCalledWith([{ productoId: '7', medidaId: 'pal', unidadesPor: 1.2 }])
  })

  it.each(['1,200,5', 'abc', '0', '-5', '1e3', 'Infinity'])('%j no se guarda y lo dice', async texto => {
    const user = userEvent.setup()
    render(<ProductoMedidas productoId={7} />)
    await user.click(screen.getByRole('textbox'))
    await user.paste(texto)
    await user.keyboard('{Enter}')
    expect(mutateAsync).not.toHaveBeenCalled()
    expect(screen.getByText('Tiene que ser un número mayor que 0')).toBeInTheDocument()
  })
})
