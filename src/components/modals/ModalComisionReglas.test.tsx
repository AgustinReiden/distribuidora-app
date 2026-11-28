/**
 * ModalComisionReglas (Fr-B10, Fr-B2 y COM-1 de #1554/#1551, tarjeta T7 de #1677).
 *
 * - Fr-B2: un error al cargar las reglas se veía como «No hay reglas cargadas: se comisiona con el
 *   default por rol (2 % preventistas, 0 % el resto)», con números que nadie había leído.
 * - COM-1 (D2 del dueño del 26/11): nadie se fija su propio porcentaje. Quien carga no aparece como
 *   vendedor de su regla y no ve «dar de baja» en una regla suya.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import type { ComponentProps } from 'react'
import '@testing-library/jest-dom/vitest'
import type { ComisionRegla } from '../../hooks/queries/useComisionesQuery'

const { guardar, desactivar, reglasQuery, notify } = vi.hoisted(() => ({
  guardar: vi.fn(),
  desactivar: vi.fn(),
  reglasQuery: vi.fn(),
  notify: { error: vi.fn(), success: vi.fn() },
}))

vi.mock('../../hooks/queries', () => ({
  useComisionReglasQuery: () => reglasQuery(),
  useGuardarComisionReglaMutation: () => ({ mutateAsync: guardar, isPending: false }),
  useDesactivarComisionReglaMutation: () => ({ mutateAsync: desactivar, isPending: false }),
}))
vi.mock('../../contexts/NotificationContext', () => ({ useNotification: () => notify }))
vi.mock('../../contexts/AuthDataContext', () => ({ useAuthData: () => ({ user: { id: 'u-yo' }, isAdmin: true }) }))

import ModalComisionReglas from './ModalComisionReglas'

const VENDEDORES = [
  { id: 'u-yo', nombre: 'Yo Admin' },
  { id: 'u-ana', nombre: 'Ana' },
]

function regla(p: Partial<ComisionRegla>): ComisionRegla {
  return {
    id: 1, sucursal_id: 1, preventista_id: null, origen_precio: null, producto_id: null, categoria_id: null,
    porcentaje: 3, activo: true, vigente_desde: '2026-11-01', vigente_hasta: null, baja_desde: null,
    created_at: '2026-11-01T12:00:00Z', ...p,
  }
}

function abrir(props: Partial<ComponentProps<typeof ModalComisionReglas>> = {}) {
  return render(
    <ModalComisionReglas preventistas={VENDEDORES} comisionPreventista={3} comisionOtros={0} onClose={vi.fn()} {...props} />,
  )
}

describe('ModalComisionReglas', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    reglasQuery.mockReturnValue({ data: [], isLoading: false, error: null, refetch: vi.fn() })
  })

  it('Fr-B2: si las reglas no cargan lo dice, con reintento, y no dice «No hay reglas»', async () => {
    const refetch = vi.fn()
    reglasQuery.mockReturnValue({ data: undefined, isLoading: false, error: new Error('Sin conexión'), refetch })
    abrir()
    const alerta = screen.getByRole('alert')
    expect(alerta).toHaveTextContent('No se pudieron cargar las reglas: Sin conexión')
    expect(screen.queryByText(/No hay reglas cargadas/)).not.toBeInTheDocument()
    await userEvent.setup().click(within(alerta).getByRole('button', { name: 'Reintentar' }))
    expect(refetch).toHaveBeenCalledTimes(1)
  })

  it('Fr-B2: sin el cálculo no inventa el 2 % y el 0 %', () => {
    abrir({ comisionPreventista: undefined, comisionOtros: undefined })
    expect(screen.getByText(/No hay reglas cargadas/)).toHaveTextContent('(— preventistas, — el resto)')
    expect(screen.queryByText(/2%/)).not.toBeInTheDocument()
  })

  it('muestra los % por defecto que llegan, con coma', () => {
    abrir({ comisionPreventista: 2.5, comisionOtros: 0 })
    expect(screen.getByText(/No hay reglas cargadas/)).toHaveTextContent('(2,5% preventistas, 0% el resto)')
  })

  it('COM-1: quien carga no aparece como vendedor de la regla', () => {
    abrir()
    const select = screen.getByRole('combobox', { name: 'Vendedor' })
    expect(within(select).queryByRole('option', { name: 'Yo Admin' })).not.toBeInTheDocument()
    expect(within(select).getByRole('option', { name: 'Ana' })).toBeInTheDocument()
  })

  it('COM-1: una regla propia no se ofrece dar de baja; la de otro, sí', () => {
    reglasQuery.mockReturnValue({
      data: [regla({ id: 7, preventista_id: 'u-yo' }), regla({ id: 8, preventista_id: 'u-ana' })],
      isLoading: false, error: null, refetch: vi.fn(),
    })
    abrir()
    expect(screen.queryByRole('button', { name: 'Dar de baja la regla 7' })).not.toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Dar de baja la regla 8' })).toBeInTheDocument()
  })

  it('agrega una regla para otro vendedor con lo elegido', async () => {
    guardar.mockResolvedValue(10)
    const user = userEvent.setup()
    abrir()
    await user.selectOptions(screen.getByRole('combobox', { name: 'Vendedor' }), 'u-ana')
    await user.click(screen.getByRole('button', { name: /Agregar regla/ }))
    expect(guardar).toHaveBeenCalledWith(expect.objectContaining({ preventistaId: 'u-ana', origenPrecio: null, porcentaje: 2 }))
    expect(notify.success).toHaveBeenCalledWith('Regla agregada')
  })

  it('muestra el motivo del server si rechaza la regla', async () => {
    guardar.mockRejectedValue(new Error('Ya hay una regla igual que rige desde el 01/11/2026 con 3 %'))
    const user = userEvent.setup()
    abrir()
    await user.click(screen.getByRole('button', { name: /Agregar regla/ }))
    expect(notify.error).toHaveBeenCalledWith('Ya hay una regla igual que rige desde el 01/11/2026 con 3 %')
  })
})
