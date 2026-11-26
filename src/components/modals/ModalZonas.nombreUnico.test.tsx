/**
 * D13 (ola 3 de #1603, T9): el nombre de una zona es único por sucursal sin mirar mayúsculas ni los
 * espacios de los bordes. La pantalla lo avisa antes de ir al server y nombra la zona que ya está.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import '@testing-library/jest-dom/vitest'
import ModalZonas from './ModalZonas'

const crear = vi.fn()
const renombrar = vi.fn()
const inerte = { mutateAsync: vi.fn(), isPending: false }

vi.mock('../../hooks/queries', () => ({
  useZonasEstandarizadasQuery: () => ({
    // «Centro » quedó guardada con un espacio al final (por REST, de antes).
    data: [{ id: '10', nombre: 'Centro ', activo: true }, { id: '20', nombre: 'Norte', activo: true }],
    isLoading: false,
  }),
  useCrearZonaMutation: () => ({ mutateAsync: crear, isPending: false }),
  useRenombrarZonaMutation: () => ({ mutateAsync: renombrar, isPending: false }),
  useEliminarZonaMutation: () => inerte,
  useToggleZonaActivaMutation: () => inerte,
  usePreventistasQuery: () => ({ data: [] }),
  useDueniosZonasQuery: () => ({ data: new Map() }),
  useSimularAsignacionZonaMutation: () => inerte,
  useAsignarPreventistaZonaMutation: () => inerte,
}))

beforeEach(() => {
  vi.clearAllMocks()
  crear.mockResolvedValue({ id: '30', nombre: 'x' })
  renombrar.mockResolvedValue(undefined)
})

describe('ModalZonas · nombre único (D13)', () => {
  it('el alta de «CENTRO» con «Centro » ya cargada se frena y nombra la que existe', () => {
    render(<ModalZonas onClose={vi.fn()} />)
    fireEvent.change(screen.getByLabelText('Nueva zona'), { target: { value: 'CENTRO' } })
    fireEvent.click(screen.getByRole('button', { name: /Agregar/ }))

    expect(screen.getByRole('alert')).toHaveTextContent('Ya existe la zona «Centro »')
    expect(crear).not.toHaveBeenCalled()
  })

  it('renombrar otra zona a « centro» se frena; renombrar la misma con otras mayúsculas, no', () => {
    render(<ModalZonas onClose={vi.fn()} />)
    fireEvent.click(screen.getByRole('button', { name: 'Renombrar Norte' }))
    const campo = screen.getByDisplayValue('Norte')
    fireEvent.change(campo, { target: { value: ' centro' } })
    fireEvent.keyDown(campo, { key: 'Enter' })

    expect(screen.getByRole('alert')).toHaveTextContent('Ya existe la zona «Centro »')
    expect(renombrar).not.toHaveBeenCalled()
  })

  it('un nombre nuevo va al server', () => {
    render(<ModalZonas onClose={vi.fn()} />)
    fireEvent.change(screen.getByLabelText('Nueva zona'), { target: { value: 'Centro Sur' } })
    fireEvent.click(screen.getByRole('button', { name: /Agregar/ }))
    expect(crear).toHaveBeenCalledWith('Centro Sur')
  })
})
