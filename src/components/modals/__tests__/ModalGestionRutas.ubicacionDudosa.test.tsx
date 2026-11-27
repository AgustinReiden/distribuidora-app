/**
 * «Armar ruta» avisa las paradas cuya ubicación no coincide con su dirección (#1717).
 *
 * Un cliente guardado con el punto de la calle (Google no encontró la altura) queda a
 * 1,5 km de su vecino de dos puertas, y el optimizador, que sólo ve coordenadas, los
 * separa. El aviso sale al tildar los pedidos, antes de optimizar.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import type { PedidoDB, PerfilDB } from '../../../types'

vi.mock('../../../hooks/queries', () => ({
  useDepositoCoords: () => ({ lat: -26.8, lng: -65.2 }),
  useDestinoCoords: () => null,
  useSetDepositoMutation: () => ({ mutateAsync: vi.fn(), isPending: false }),
  useSetDestinoMutation: () => ({ mutateAsync: vi.fn(), isPending: false }),
  useCambiarTransportistaRutaMutation: () => ({ mutateAsync: vi.fn(), isPending: false }),
  useRecorridoExistenteQuery: () => ({ data: null, isError: false, refetch: vi.fn() }),
  useRutasEnCursoQuery: () => ({ data: [], isError: false, refetch: vi.fn() }),
  useRutasEnCursoMultiQuery: () => ({ data: undefined, isError: false, refetch: vi.fn() }),
}))

vi.mock('../../../hooks/useOptimizarRuta', () => ({
  horarioParaRutear: () => null,
}))

import ModalGestionRutas from '../ModalGestionRutas'

const pedido = (id: string, direccion: string, latitud: number, longitud: number): PedidoDB =>
  ({
    id, estado: 'en_preparacion', total: 100, items: [], fecha: '2026-11-27',
    cliente: { id: `c${id}`, nombre_fantasia: `Cliente ${id}`, direccion, latitud, longitud },
  }) as unknown as PedidoDB

function montar(pedidos: PedidoDB[]) {
  render(
    <ModalGestionRutas
      transportistas={[{ id: 't1', nombre: 'Tomás Chofer' } as PerfilDB]}
      pedidos={pedidos}
      onArmarRuta={vi.fn()}
      onArmarRutaMulti={vi.fn()}
      onExportarPDF={vi.fn()}
      onClose={vi.fn()}
      loading={false}
      guardando={false}
      rutaOptimizada={null}
      error={null}
    />,
  )
}

async function tildarTodos(ids: string[]) {
  const user = userEvent.setup()
  await user.selectOptions(screen.getByRole('combobox'), 't1')
  for (const id of ids) {
    const casilla = screen.getByRole('checkbox', { name: new RegExp(`#${id} - Cliente ${id}`) })
    if (!(casilla as HTMLInputElement).checked) await user.click(casilla)
  }
}

describe('ModalGestionRutas — ubicaciones dudosas (#1717)', () => {
  it('avisa los vecinos de la misma cuadra que el mapa pone a 1,5 km', async () => {
    montar([
      pedido('1', 'Pje. Los Ceibos 298, T4000 San Miguel de Tucumán', -26.8275, -65.2402),
      pedido('2', 'Los Ceibos 248, T4000 San Miguel de Tucumán', -26.8405, -65.2437),
    ])
    await tildarTodos(['1', '2'])

    expect(screen.getByText('Una ubicación no coincide con su dirección')).toBeInTheDocument()
    expect(screen.getByText(/están en la misma cuadra, pero en el mapa quedan a 1,5 km/)).toBeInTheDocument()
  })

  it('no avisa cuando los vecinos están bien ubicados', async () => {
    montar([
      pedido('1', 'Pje. Los Ceibos 298, T4000 San Miguel de Tucumán', -26.8275, -65.2402),
      pedido('2', 'Los Ceibos 248, T4000 San Miguel de Tucumán', -26.8269, -65.2400),
    ])
    await tildarTodos(['1', '2'])

    expect(screen.queryByText(/no coincide con su dirección/)).not.toBeInTheDocument()
  })
})
