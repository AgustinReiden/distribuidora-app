/**
 * N7 de la segunda pasada de #1644: `ProductoLotes` va adentro de la ficha del producto, que tiene
 * su registro de campos en rojo. Una cantidad de lote en rojo frenaba el «Guardar» de la ficha, que
 * no tiene nada que ver (el lote tiene su propio guardar). Ahora el lote tiene su registro.
 */
import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import '@testing-library/jest-dom/vitest'
import { RegistroIlegiblesContext, useRegistroIlegibles } from '../../hooks/useRegistroIlegibles'

vi.mock('../../hooks/queries/useLotesQuery', () => ({
  useLotesProductoQuery: () => ({ data: [], isLoading: false }),
  useCrearLoteManualMutation: () => ({ mutateAsync: vi.fn(), isPending: false }),
  useAjustarLoteMutation: () => ({ mutateAsync: vi.fn(), isPending: false }),
}))
vi.mock('../../hooks/queries/usePoliticasComercialesQuery', () => ({
  usePoliticasComercialesQuery: () => ({ politicas: { diasAlertaVencimiento: 60, diasCriticoVencimiento: 15 } }),
}))
vi.mock('../../hooks/supabase/useAuth', () => ({
  useAuth: () => ({ isAdminOrEncargado: true, perfil: { rol: 'admin' } }),
}))
vi.mock('../../contexts/NotificationContext', () => ({
  useNotification: () => ({ success: vi.fn(), error: vi.fn() }),
}))

import ProductoLotes from './ProductoLotes'

function Ficha() {
  const ilegibles = useRegistroIlegibles()
  return (
    <RegistroIlegiblesContext.Provider value={ilegibles.registro}>
      <ProductoLotes productoId={1} stock={50} />
      <button type="button" disabled={ilegibles.hay}>Guardar ficha</button>
    </RegistroIlegiblesContext.Provider>
  )
}

describe('ProductoLotes · su propio registro', () => {
  it('una cantidad de lote en rojo no frena el Guardar de la ficha', async () => {
    const user = userEvent.setup()
    render(<Ficha />)
    await user.click(screen.getByRole('button', { name: /Cargar vencimiento/ }))
    const cantidad = screen.getByLabelText(/Unidades \(hay 50\)/)
    await user.type(cantidad, '1,5')
    expect(cantidad).toHaveAttribute('aria-invalid', 'true')
    expect(screen.getByRole('button', { name: 'Guardar ficha' })).toBeEnabled()
  })
})
