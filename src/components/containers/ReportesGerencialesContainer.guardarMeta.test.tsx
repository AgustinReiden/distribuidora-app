/**
 * #1600 (1600-b5): `guardarMeta.mutate` no tenía `onError`. Si el server rechazaba la meta (o no
 * había señal), la pantalla no decía nada y quien cargaba creía que había quedado guardada.
 * Ahora el aviso de lo que no se guardó queda en pantalla hasta que se cierra, dice cuál de las dos
 * metas fue, y si las dos guardan bien no sale ninguno.
 *
 * La vista se mockea: acá se prueba lo que hace el container con lo que le devuelve la mutación.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'

const mutateAsync = vi.fn()
const notifyError = vi.fn()
const notifySuccess = vi.fn()

vi.mock('../../hooks/queries', () => ({
  useReporteGerencialQuery: () => ({ data: undefined, isLoading: false, error: null }),
  useReporteCombosQuery: () => ({ data: undefined }),
  useReporteCombosRotacionQuery: () => ({ data: undefined }),
  useAnalisisMensualQuery: () => ({ data: undefined }),
  useMetasGerencialQuery: () => ({ data: undefined }),
  useGuardarMetaMutation: () => ({ mutateAsync, mutate: vi.fn(), isPending: false }),
  useCalcularComisionesQuery: () => ({ data: undefined }),
  useSucursalesActivasQuery: () => ({ data: [] }),
}))

vi.mock('../../hooks/useAlertasCombos', () => ({
  useAlertasCombos: () => [],
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({
    sucursales: [{ id: 1, nombre: 'Sucursal Uno' }],
    hasMultipleSucursales: false,
    loading: false,
    currentSucursalId: 1,
  }),
}))

vi.mock('../../contexts/NotificationContext', () => ({
  useNotification: () => ({ error: notifyError, success: notifySuccess, warning: vi.fn(), info: vi.fn() }),
}))

vi.mock('../vistas/VistaReportesGerenciales', () => ({
  default: (props: { onGuardarMeta: (venta: number | null, margen: number | null) => void }) => (
    <button onClick={() => props.onGuardarMeta(500000, 20)}>guardar metas</button>
  ),
}))

import ReportesGerencialesContainer from './ReportesGerencialesContainer'

async function guardar() {
  render(
    <MemoryRouter initialEntries={['/reportes-gerenciales']}>
      <ReportesGerencialesContainer />
    </MemoryRouter>,
  )
  await userEvent.click(await screen.findByText('guardar metas'))
}

describe('ReportesGerencialesContainer › guardar la meta (1600-b5)', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('si el server rechaza la meta de venta, avisa cuál no se guardó y por qué, y el aviso queda', async () => {
    mutateAsync.mockImplementation(async (vars: { metrica: string }) => {
      if (vars.metrica === 'venta') throw new Error('Solo un administrador puede cargar la meta')
    })
    await guardar()

    expect(notifyError).toHaveBeenCalledTimes(1)
    const [mensaje, opciones] = notifyError.mock.calls[0]
    expect(mensaje).toMatch(/meta de venta/i)
    expect(mensaje).toMatch(/no se guard/i)
    expect(mensaje).toMatch(/Solo un administrador puede cargar la meta/)
    expect(opciones).toEqual({ persist: true })
  })

  it('si no hay señal y fallan las dos, avisa de las dos (la segunda no tapa a la primera)', async () => {
    mutateAsync.mockRejectedValue(new Error('Sin conexión: no se pudo confirmar que la meta se guardó.'))
    await guardar()

    const textos = notifyError.mock.calls.map(c => c[0] as string)
    expect(textos.some(t => /meta de venta/i.test(t))).toBe(true)
    expect(textos.some(t => /meta de margen/i.test(t))).toBe(true)
  })

  it('si las dos guardan bien, no sale ningún aviso de error', async () => {
    mutateAsync.mockResolvedValue(undefined)
    await guardar()

    expect(mutateAsync).toHaveBeenCalledTimes(2)
    expect(notifyError).not.toHaveBeenCalled()
  })
})
