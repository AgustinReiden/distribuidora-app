import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import type { ProductoDB } from '../../types'
import type { AplicarControlStockResult, CargaPreviaPlanilla } from '../../hooks/queries/useControlStockQuery'

/**
 * #1295 · Una planilla de control de stock se aplica una vez. El modal manda el
 * "ID de planilla" con los ajustes, avisa ANTES de aplicar si esa planilla ya
 * se cargó (en vez del aviso de "el stock cambió", que era su propia carga), y
 * ante filas rechazadas pide una planilla nueva: el mismo archivo ya no entra.
 */

const PLANILLA = {
  planillaId: '6f1c2a9e-1d2b-4c3d-9e8f-0a1b2c3d4e5f',
  filas: [{ codigo: 'A1', nombre: 'Agua', stockReal: 10, stockPlanilla: 12 }],
  invalidas: [],
}

const buscarCargaPrevia = vi.fn<(planillaId: string) => Promise<CargaPreviaPlanilla | null>>()

vi.mock('../../utils/excel', () => ({
  exportControlStock: vi.fn(),
  readControlStockPlanilla: vi.fn(() => Promise.resolve(PLANILLA)),
}))

vi.mock('../../hooks/queries/useControlStockQuery', () => ({
  useBuscarCargaPreviaPlanilla: () => buscarCargaPrevia,
}))

import ModalControlStock from './ModalControlStock'

const PRODUCTOS = [
  { id: 1, codigo: 'A1', nombre: 'Agua', categoria: 'Bebidas', stock: 9 },
  { id: 2, codigo: 'B2', nombre: 'Birra', categoria: 'Bebidas', stock: 30 },
] as unknown as ProductoDB[]

const RESULTADO: AplicarControlStockResult = {
  sesion_id: 15,
  total_items: 0,
  total_altas: 0,
  total_bajas: 0,
  movidos_desde_descarga: 0,
  aplicados: [],
  no_encontrados: [],
  rechazados: [{ producto_id: 1, stock_planilla: 12, stock_contado: 10, stock_actual: 1, motivo: 'quedaria_negativo' }],
}

function renderModal() {
  const onAplicar = vi.fn(() => Promise.resolve(RESULTADO))
  render(<ModalControlStock productos={PRODUCTOS} puedeCargar onAplicar={onAplicar} aplicando={false} onClose={vi.fn()} />)
  return { onAplicar, user: userEvent.setup() }
}

// El modal va en un portal: el input se busca en el documento.
async function subirPlanilla(user: ReturnType<typeof userEvent.setup>) {
  const input = document.querySelector('input[type="file"]') as HTMLInputElement
  await user.upload(input, new File(['x'], 'Control_Stock.xlsx'))
}

beforeEach(() => { buscarCargaPrevia.mockReset() })

describe('ModalControlStock · una planilla se aplica una vez (#1295)', () => {
  it('una planilla ya cargada se avisa antes de aplicar y no se puede aplicar', async () => {
    buscarCargaPrevia.mockResolvedValue({ id: 12, fecha: '2026-10-29T18:20:00Z', total_items: 3 })
    const { user, onAplicar } = renderModal()
    await subirPlanilla(user)

    expect(await screen.findByText(/Esta planilla ya se cargó/)).toBeInTheDocument()
    expect(screen.getByText(/control N° 12, 3 producto\(s\) ajustado\(s\)/)).toBeInTheDocument()
    expect(buscarCargaPrevia).toHaveBeenCalledWith(PLANILLA.planillaId)
    // El aviso de "el stock cambió desde la descarga" no aparece: era la propia carga.
    expect(screen.queryByText(/el stock cambió desde que se descargó/)).not.toBeInTheDocument()
    expect(screen.getByRole('button', { name: /Aplicar ajustes/ })).toBeDisabled()
    expect(onAplicar).not.toHaveBeenCalled()
  })

  it('una planilla nueva manda su id con los ajustes', async () => {
    buscarCargaPrevia.mockResolvedValue(null)
    const { user, onAplicar } = renderModal()
    await subirPlanilla(user)

    await user.click(await screen.findByRole('button', { name: /Aplicar ajustes/ }))
    expect(onAplicar).toHaveBeenCalledWith({
      planillaId: PLANILLA.planillaId,
      ajustes: [{ producto_id: '1', stock_real: 10, stock_planilla: 12 }],
    })
  })

  it('sin conexión para mirar, no traba: decide el servidor', async () => {
    buscarCargaPrevia.mockRejectedValue(new Error('Sin conexión'))
    const { user } = renderModal()
    await subirPlanilla(user)

    expect(await screen.findByRole('button', { name: /Aplicar ajustes/ })).toBeEnabled()
  })

  it('las filas rechazadas piden una planilla nueva, con el producto y los números', async () => {
    buscarCargaPrevia.mockResolvedValue(null)
    const { user } = renderModal()
    await subirPlanilla(user)
    await user.click(await screen.findByRole('button', { name: /Aplicar ajustes/ }))

    expect(await screen.findByText(/descargá una planilla nueva y volvé a contarlos/)).toBeInTheDocument()
    expect(screen.getByText(/Esta planilla ya quedó cargada y no se vuelve a aplicar/)).toBeInTheDocument()
    expect(screen.getByText('Agua: se contaron 10, la planilla decía 12 y hoy hay 1.')).toBeInTheDocument()
  })
})
