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
import { ErrorDeSupabase } from '../../utils/errorDeSupabase'

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
      // Lo que lanza `errorDeSupabase` cuando el server contestó: lleva su `code`.
      if (vars.metrica === 'venta') throw new ErrorDeSupabase('Solo un administrador puede cargar la meta', { code: 'P0001' }, false)
    })
    await guardar()

    expect(notifyError).toHaveBeenCalledTimes(1)
    const [mensaje, opciones] = notifyError.mock.calls[0]
    expect(mensaje).toMatch(/meta de venta/i)
    expect(mensaje).toMatch(/^No se guardó/)
    expect(mensaje).not.toMatch(/confirmar/i)
    expect(mensaje).toMatch(/Solo un administrador puede cargar la meta/)
    expect(opciones).toEqual({ persist: true })
  })

  it('si no hay señal y fallan las dos, avisa de las dos (la segunda no tapa a la primera)', async () => {
    mutateAsync.mockRejectedValue(new ErrorDeSupabase('Sin conexión: no se pudo confirmar que la meta se guardó.', {}, true))
    await guardar()

    const textos = notifyError.mock.calls.map(c => c[0] as string)
    expect(textos.some(t => /meta de venta/i.test(t))).toBe(true)
    expect(textos.some(t => /meta de margen/i.test(t))).toBe(true)
  })

  // H5 de la revisión de C7: sin señal a mitad de la llamada no se sabe si el server la guardó. Decir
  // «No se guardó» era afirmar lo que no se sabe, y quien confía en eso la vuelve a cargar a ciegas.
  it('sin señal NO dice «No se guardó»: dice que no se pudo confirmar y que revise la meta', async () => {
    mutateAsync.mockImplementation(async (vars: { metrica: string }) => {
      if (vars.metrica === 'venta') throw new ErrorDeSupabase('Sin conexión: no se pudo confirmar que la meta se guardó.', {}, true)
    })
    await guardar()

    expect(notifyError).toHaveBeenCalledTimes(1)
    const [mensaje, opciones] = notifyError.mock.calls[0]
    expect(mensaje).toMatch(/^No se pudo confirmar si se guardó la meta de venta/)
    expect(mensaje).toMatch(/revisá la meta/i)
    expect(mensaje).not.toMatch(/^No se guardó/)
    expect(opciones).toEqual({ persist: true })
  })

  it('un 5xx de gateway (la base pudo haber terminado) también es «sin confirmar»', async () => {
    mutateAsync.mockRejectedValue(new ErrorDeSupabase('Error del servidor (HTTP 524): no se pudo confirmar la operación.', { code: 'HTTP_524' }, false))
    await guardar()

    expect(notifyError.mock.calls.every(c => /^No se pudo confirmar si se guardó/.test(String(c[0])))).toBe(true)
  })

  it('si las dos guardan bien, no sale ningún aviso de error', async () => {
    mutateAsync.mockResolvedValue(undefined)
    await guardar()

    expect(mutateAsync).toHaveBeenCalledTimes(2)
    expect(notifyError).not.toHaveBeenCalled()
  })
})
