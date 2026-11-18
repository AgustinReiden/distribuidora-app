/**
 * #1600 (1600-b12): `finDeMes` armaba el último día con `new Date(y, m, 0).toISOString()`: medianoche
 * LOCAL pasada a UTC. En un dispositivo al este de UTC esa medianoche cae en el día anterior en UTC
 * y el «Hasta» de un objetivo mensual salía un día antes (29/11 en vez de 30/11), con lo que el mes
 * ya no era «completo» y el objetivo se guardaba como un rango personalizado. La cuenta es de
 * calendario: no depende de la zona del teléfono.
 */
import process from 'node:process'
import { describe, it, expect, vi, beforeAll, afterAll } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import '@testing-library/jest-dom/vitest'

vi.mock('../../hooks/queries', () => ({
  useGuardarMetaPreventistaMutation: () => ({ mutateAsync: vi.fn(), isPending: false }),
  useMarcasQuery: () => ({ data: [] }),
  useCategoriasQuery: () => ({ data: [] }),
  useProductosQuery: () => ({ data: [] }),
  usePreventistasAsignablesQuery: () => ({ data: [{ id: 'p1', nombre: 'Pablo' }] }),
}))
vi.mock('../../contexts/SucursalContext', () => ({ useSucursal: () => ({ currentSucursalId: 1 }) }))

import ModalMetasPreventista from './ModalMetasPreventista'

const TZ_ORIGINAL = process.env.TZ

// Kiritimati es UTC+14: la medianoche local del 30/11 es el 29/11 a las 10:00 UTC.
beforeAll(() => {
  process.env.TZ = 'Pacific/Kiritimati'
  if (new Date(2026, 10, 30).getTimezoneOffset() !== -840) {
    throw new Error('No se pudo fijar TZ=Pacific/Kiritimati en este runner')
  }
})

afterAll(() => {
  if (TZ_ORIGINAL === undefined) delete process.env.TZ
  else process.env.TZ = TZ_ORIGINAL
})

describe('ModalMetasPreventista · el fin de mes no corre un día en un dispositivo al este de UTC', () => {
  it('al abrir el alta de noviembre, «Hasta» es el 30/11 y el mes cuenta como completo', () => {
    render(<ModalMetasPreventista periodo="2026-11-01" onClose={vi.fn()} />)
    expect(screen.getByDisplayValue('2026-11-30')).toBeInTheDocument()
    expect(screen.getByText('Mes completo (lo habitual)')).toBeInTheDocument()
  })

  it('«Usar el mes completo» vuelve al 30/11 después de tocar la fecha', async () => {
    const user = userEvent.setup()
    render(<ModalMetasPreventista periodo="2026-11-01" onClose={vi.fn()} />)
    const hasta = screen.getByDisplayValue('2026-11-30')
    await user.clear(hasta)
    await user.type(hasta, '2026-11-15')
    expect(screen.getByText('Período personalizado')).toBeInTheDocument()

    await user.click(screen.getByRole('button', { name: 'Usar el mes completo' }))
    expect(screen.getByDisplayValue('2026-11-30')).toBeInTheDocument()
  })

  it('un mes de 31 días y febrero bisiesto también cierran en su último día', () => {
    const { unmount } = render(<ModalMetasPreventista periodo="2028-02-01" onClose={vi.fn()} />)
    expect(screen.getByDisplayValue('2028-02-29')).toBeInTheDocument()
    unmount()
    render(<ModalMetasPreventista periodo="2026-12-01" onClose={vi.fn()} />)
    expect(screen.getByDisplayValue('2026-12-31')).toBeInTheDocument()
  })
})
