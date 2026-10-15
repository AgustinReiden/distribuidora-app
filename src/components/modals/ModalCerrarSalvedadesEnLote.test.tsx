/**
 * Cierre en lote del atraso de salvedades (#1198).
 *
 * Fija: el número que se confirma es el que cuenta el servidor; la confirmación
 * se renderiza DENTRO del dialog Radix (CLAUDE.md: hermana en el container
 * quedaría detrás del overlay); nada se cierra hasta confirmar; y un rechazo
 * del RPC se muestra sin cerrar el modal.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

const h = vi.hoisted(() => ({
  conteo: { data: 12 as number | undefined, isLoading: false, isError: false, error: null as Error | null },
  conteoArgs: [] as Array<[string, boolean | undefined]>,
  mutateAsync: vi.fn(),
  isPending: false,
}))

vi.mock('../../hooks/queries/useCierreSalvedadesEnLote', () => ({
  useConteoCierreEnLoteQuery: (hasta: string, enabled?: boolean) => {
    h.conteoArgs.push([hasta, enabled])
    return h.conteo
  },
  useCerrarSalvedadesEnLoteMutation: () => ({ mutateAsync: h.mutateAsync, isPending: h.isPending }),
}))

import ModalCerrarSalvedadesEnLote from './ModalCerrarSalvedadesEnLote'
import { fechaHaceDias } from '../../utils/formatters'

beforeEach(() => {
  h.conteo = { data: 12, isLoading: false, isError: false, error: null }
  h.conteoArgs.length = 0
  h.mutateAsync.mockReset()
  h.isPending = false
})

describe('ModalCerrarSalvedadesEnLote', () => {
  it('cuenta en el servidor hasta la fecha por defecto (hace 7 días) y muestra el número', () => {
    render(<ModalCerrarSalvedadesEnLote onClose={vi.fn()} />)
    expect(h.conteoArgs[h.conteoArgs.length - 1]).toEqual([fechaHaceDias(7), true])
    expect(screen.getByTestId('conteo-cierre')).toHaveTextContent('Hay 12 salvedades pendientes')
  })

  it('la confirmación aparece dentro del dialog y no cierra nada hasta confirmar', async () => {
    const user = userEvent.setup()
    render(<ModalCerrarSalvedadesEnLote onClose={vi.fn()} />)
    const dialog = screen.getByRole('dialog')

    await user.click(within(dialog).getByRole('button', { name: /Cerrar 12 salvedades/ }))
    const confirmacion = within(dialog).getByRole('alertdialog')
    expect(confirmacion).toHaveTextContent('¿Cerrar 12 salvedades pendientes')
    expect(h.mutateAsync).not.toHaveBeenCalled()

    await user.click(within(confirmacion).getByRole('button', { name: 'Volver' }))
    expect(within(dialog).queryByRole('alertdialog')).not.toBeInTheDocument()
    expect(h.mutateAsync).not.toHaveBeenCalled()
  })

  it('al confirmar manda la fecha y la nota, y avisa cuántas cerró', async () => {
    h.mutateAsync.mockResolvedValue({ cerradas: 12, nota: 'Cierre en lote…' })
    const user = userEvent.setup()
    render(<ModalCerrarSalvedadesEnLote onClose={vi.fn()} />)
    const dialog = screen.getByRole('dialog')

    await user.type(within(dialog).getByLabelText('Nota (opcional)'), 'Atraso de abril a septiembre')
    await user.click(within(dialog).getByRole('button', { name: /Cerrar 12 salvedades/ }))
    await user.click(within(dialog).getByRole('button', { name: 'Sí, cerrar 12' }))

    expect(h.mutateAsync).toHaveBeenCalledWith({ hasta: fechaHaceDias(7), notas: 'Atraso de abril a septiembre' })
    expect(await within(dialog).findByRole('status')).toHaveTextContent('Se cerraron 12 salvedades')
  })

  it('sin pendientes hasta esa fecha no se puede avanzar', () => {
    h.conteo = { data: 0, isLoading: false, isError: false, error: null }
    render(<ModalCerrarSalvedadesEnLote onClose={vi.fn()} />)
    expect(screen.getByTestId('conteo-cierre')).toHaveTextContent('No hay salvedades pendientes')
    expect(screen.getByRole('button', { name: /Cerrar\s+salvedades/ })).toBeDisabled()
  })

  it('el rechazo del RPC se muestra y el modal sigue abierto', async () => {
    h.mutateAsync.mockRejectedValue(new Error('Solo admin puede cerrar salvedades en lote'))
    const onClose = vi.fn()
    const user = userEvent.setup()
    render(<ModalCerrarSalvedadesEnLote onClose={onClose} />)
    const dialog = screen.getByRole('dialog')

    await user.click(within(dialog).getByRole('button', { name: /Cerrar 12 salvedades/ }))
    await user.click(within(dialog).getByRole('button', { name: 'Sí, cerrar 12' }))

    expect(await within(dialog).findByRole('alert')).toHaveTextContent('Solo admin puede cerrar salvedades en lote')
    expect(onClose).not.toHaveBeenCalled()
  })

  it('una fecha futura no se cuenta ni se puede confirmar', async () => {
    const user = userEvent.setup()
    render(<ModalCerrarSalvedadesEnLote onClose={vi.fn()} />)
    const input = screen.getByLabelText('Cerrar las pendientes cargadas hasta el')
    await user.clear(input)
    await user.type(input, '2999-01-01')
    expect(h.conteoArgs[h.conteoArgs.length - 1]).toEqual(['2999-01-01', false])
    expect(screen.getByText('Elegí una fecha que no sea futura.')).toBeInTheDocument()
  })
})
