import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

const cambiar = vi.fn()
const cancelar = vi.fn()
const notifySuccess = vi.fn()
const notifyError = vi.fn()

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
        // Una programada lejos en el futuro (mig 282): la vigente quedó cerrada el día antes.
        { id: '1', encuadre_id: '1', tasa_nominal: 0.08, vigente_desde: '2000-01-01', vigente_hasta: '2099-02-28' },
        { id: '7', encuadre_id: '1', tasa_nominal: 0.1, vigente_desde: '2099-03-01', vigente_hasta: null },
        { id: '5', encuadre_id: '5', tasa_nominal: 0, vigente_desde: '2000-01-01', vigente_hasta: null },
      ],
    },
  }),
  useGuardarEncuadreIIMutation: () => ({ mutateAsync: vi.fn(), isPending: false }),
  useCambiarAlicuotaIIMutation: () => ({ mutateAsync: cambiar, isPending: false }),
  useCancelarAlicuotaProgramadaMutation: () => ({ mutateAsync: cancelar, isPending: false }),
}))

vi.mock('../../../contexts/NotificationContext', () => ({
  useNotification: () => ({ success: notifySuccess, error: notifyError }),
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

  it('muestra la tasa vigente y, aparte, la programada a futuro', () => {
    render(<PanelImpuestosInternos esAdmin={false} />)
    expect(screen.getByText('8% nominal')).toBeInTheDocument()
    expect(screen.getByText('Programada: 10% desde 01/03/2099')).toBeInTheDocument()
    // El encuadre sin futuras no muestra ninguna.
    expect(screen.getAllByText(/^Programada:/)).toHaveLength(1)
  })

  it('un admin puede cargar una tasa con fecha futura', async () => {
    const user = userEvent.setup()
    render(<PanelImpuestosInternos esAdmin />)

    await user.click(screen.getAllByRole('button', { name: 'Cambiar tasa' })[0])
    const desde = screen.getByLabelText('Vigente desde')
    expect(desde).not.toHaveAttribute('max')
    await user.type(screen.getByLabelText('Tasa nominal (%)'), '12')
    fireEvent.change(desde, { target: { value: '2099-06-01' } })
    const guardar = screen.getByRole('button', { name: 'Guardar tasa' })
    expect(guardar).toBeEnabled()
    await user.click(guardar)

    expect(cambiar).toHaveBeenCalledTimes(1)
    expect(cambiar.mock.calls[0][0]).toMatchObject({ encuadreId: '1', tasaNominal: 0.12, vigenteDesde: '2099-06-01' })
  })

  describe('cancelar una programada (mig 283)', () => {
    const BOTON = 'Cancelar la programada de 10% desde 01/03/2099'

    it('quien no es admin ve la programada pero no puede cancelarla', () => {
      render(<PanelImpuestosInternos esAdmin={false} />)
      expect(screen.getByText('Programada: 10% desde 01/03/2099')).toBeInTheDocument()
      expect(screen.queryByRole('button', { name: BOTON })).not.toBeInTheDocument()
    })

    it('un admin la cancela recién después de confirmar, dentro del panel', async () => {
      const user = userEvent.setup()
      cancelar.mockResolvedValue(undefined)
      render(<PanelImpuestosInternos esAdmin />)

      // Una sola programada en el catálogo: un solo botón.
      expect(screen.getAllByRole('button', { name: /^Cancelar la programada/ })).toHaveLength(1)
      await user.click(screen.getByRole('button', { name: BOTON }))
      expect(cancelar).not.toHaveBeenCalled()

      const confirmacion = screen.getByRole('group', { name: 'Confirmar cancelación' })
      expect(confirmacion).toHaveTextContent('¿Cancelar la tasa de 10% programada desde 01/03/2099?')
      // Renderizada dentro del panel, no en un portal.
      expect(confirmacion.closest('section')).not.toBeNull()

      await user.click(screen.getByRole('button', { name: 'Sí, cancelar la programada' }))
      expect(cancelar).toHaveBeenCalledTimes(1)
      expect(cancelar).toHaveBeenCalledWith('7')
      expect(notifySuccess).toHaveBeenCalledWith('General: se canceló la tasa de 10% programada desde 01/03/2099')
      // Se cierra DESPUÉS del await de la mutación, fuera del act() del clic:
      // React lo pinta en otra vuelta del event loop (#1006).
      await waitFor(() => expect(screen.queryByRole('group', { name: 'Confirmar cancelación' })).not.toBeInTheDocument())
    })

    it('"No, dejarla" cierra la confirmación sin llamar a la base', async () => {
      const user = userEvent.setup()
      render(<PanelImpuestosInternos esAdmin />)

      await user.click(screen.getByRole('button', { name: BOTON }))
      await user.click(screen.getByRole('button', { name: 'No, dejarla' }))

      expect(cancelar).not.toHaveBeenCalled()
      expect(screen.queryByRole('group', { name: 'Confirmar cancelación' })).not.toBeInTheDocument()
      expect(screen.getByRole('button', { name: BOTON })).toBeInTheDocument()
    })

    it('si la base la rechaza, muestra el error y deja la confirmación abierta', async () => {
      const user = userEvent.setup()
      cancelar.mockRejectedValue(new Error('Esa alícuota ya empezó a regir: no se puede cancelar. Para corregirla, cargá otra tasa.'))
      render(<PanelImpuestosInternos esAdmin />)

      await user.click(screen.getByRole('button', { name: BOTON }))
      await user.click(screen.getByRole('button', { name: 'Sí, cancelar la programada' }))

      expect(notifyError).toHaveBeenCalledWith('Esa alícuota ya empezó a regir: no se puede cancelar. Para corregirla, cargá otra tasa.')
      expect(notifySuccess).not.toHaveBeenCalled()
      expect(screen.getByRole('group', { name: 'Confirmar cancelación' })).toBeInTheDocument()
    })
  })
})
