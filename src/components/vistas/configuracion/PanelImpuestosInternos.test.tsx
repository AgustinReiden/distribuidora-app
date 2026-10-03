import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

const cambiar = vi.fn()

vi.mock('../../../hooks/queries/useImpuestosInternosQuery', () => ({
  useCatalogoIIQuery: () => ({
    isLoading: false,
    error: null,
    data: {
      encuadres: [
        { id: '1', nombre: 'General', criterio: 'Sin jugo', activo: true },
        { id: '5', nombre: 'No alcanzado', criterio: null, activo: true },
      ],
      alicuotas: [
        { id: '1', encuadre_id: '1', tasa_nominal: 0.08, vigente_desde: '2000-01-01', vigente_hasta: null },
        { id: '5', encuadre_id: '5', tasa_nominal: 0, vigente_desde: '2000-01-01', vigente_hasta: null },
      ],
    },
  }),
  useGuardarEncuadreIIMutation: () => ({ mutateAsync: vi.fn(), isPending: false }),
  useCambiarAlicuotaIIMutation: () => ({ mutateAsync: cambiar, isPending: false }),
}))

vi.mock('../../../contexts/NotificationContext', () => ({
  useNotification: () => ({ success: vi.fn(), error: vi.fn() }),
}))

import PanelImpuestosInternos from './PanelImpuestosInternos'

describe('PanelImpuestosInternos (mig 277)', () => {
  beforeEach(() => vi.clearAllMocks())

  it('muestra la tasa nominal y la efectiva sobre el neto', () => {
    render(<PanelImpuestosInternos esAdmin={false} />)
    expect(screen.getByText('8% nominal')).toBeInTheDocument()
    expect(screen.getByText('8,6957% sobre el neto')).toBeInTheDocument()
    expect(screen.getByText('0% nominal')).toBeInTheDocument()
  })

  it('quien no es admin no ve cómo cambiar nada', () => {
    render(<PanelImpuestosInternos esAdmin={false} />)
    expect(screen.queryByRole('button', { name: 'Cambiar tasa' })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /Nuevo encuadre/ })).not.toBeInTheDocument()
  })

  it('un admin cambia la tasa en un solo pedido, con la nominal en fracción', async () => {
    const user = userEvent.setup()
    render(<PanelImpuestosInternos esAdmin />)

    await user.click(screen.getAllByRole('button', { name: 'Cambiar tasa' })[0])
    await user.type(screen.getByLabelText('Tasa nominal (%)'), '10')
    await user.click(screen.getByRole('button', { name: 'Guardar tasa' }))

    expect(cambiar).toHaveBeenCalledTimes(1)
    expect(cambiar.mock.calls[0][0]).toMatchObject({ encuadreId: '1', tasaNominal: 0.1 })
  })
})
