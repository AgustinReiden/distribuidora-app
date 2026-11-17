/**
 * «Ver más antiguas» en el historial de ajustes de stock (#1599, 1599-b3): con
 * exactamente una página llena puede haber más; con menos, no hay nada más que ver.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

const mocks = vi.hoisted(() => ({ useSesiones: vi.fn() }))

vi.mock('../../hooks/queries/useControlStockQuery', () => ({
  SESIONES_POR_PAGINA: 100,
  useControlStockSesionesQuery: (enabled: boolean, limite: number) => mocks.useSesiones(enabled, limite),
  useControlStockDetalleQuery: () => ({ data: [], isLoading: false }),
}))

import ModalAjustesStockHistorial from './ModalAjustesStockHistorial'

function sesiones(n: number) {
  return Array.from({ length: n }, (_, i) => ({
    id: i + 1, fecha: '2026-11-01T12:00:00Z', usuario_id: null, total_items: 1,
    total_altas: 1, total_bajas: 0, observaciones: null, usuario: null,
  }))
}

beforeEach(() => mocks.useSesiones.mockReset())

describe('ModalAjustesStockHistorial — más antiguas', () => {
  it('con una página llena ofrece «Ver más antiguas» y pide el doble', async () => {
    mocks.useSesiones.mockImplementation((_e: boolean, limite: number) => ({
      data: sesiones(limite === 100 ? 100 : 130), isLoading: false, isFetching: false,
    }))
    render(<ModalAjustesStockHistorial productos={[]} onClose={() => {}} />)

    await userEvent.setup().click(screen.getByRole('button', { name: 'Ver más antiguas' }))

    expect(mocks.useSesiones).toHaveBeenLastCalledWith(true, 200)
    // 130 < 200: ya no hay más.
    expect(screen.queryByRole('button', { name: 'Ver más antiguas' })).not.toBeInTheDocument()
  })

  it('con menos de una página no ofrece nada', () => {
    mocks.useSesiones.mockReturnValue({ data: sesiones(3), isLoading: false, isFetching: false })
    render(<ModalAjustesStockHistorial productos={[]} onClose={() => {}} />)

    expect(screen.queryByRole('button', { name: 'Ver más antiguas' })).not.toBeInTheDocument()
  })
})
