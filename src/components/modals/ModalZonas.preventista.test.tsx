/**
 * El preventista de cada zona (mig 359): elegirlo primero SIMULA en la base y
 * muestra a quién se le sacan clientes; recién al confirmar escribe. Cancelar
 * no escribe nada.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent, waitFor } from '@testing-library/react'
import '@testing-library/jest-dom/vitest'
import ModalZonas from './ModalZonas'

const simular = vi.fn()
const asignar = vi.fn()
const inerte = { mutateAsync: vi.fn(), isPending: false }

vi.mock('../../hooks/queries', () => ({
  useZonasEstandarizadasQuery: () => ({
    data: [{ id: '10', nombre: 'ZONA 1', activo: true }, { id: '20', nombre: 'ZONA 2', activo: true }],
    isLoading: false,
  }),
  useCrearZonaMutation: () => inerte,
  useRenombrarZonaMutation: () => inerte,
  useEliminarZonaMutation: () => inerte,
  useToggleZonaActivaMutation: () => inerte,
  usePreventistasQuery: () => ({ data: [{ id: 'p-ana', nombre: 'Ana' }, { id: 'p-caro', nombre: 'Caro' }] }),
  useDueniosZonasQuery: () => ({ data: new Map([['20', 'p-ana']]) }),
  useSimularAsignacionZonaMutation: () => ({ mutateAsync: simular, isPending: false }),
  useAsignarPreventistaZonaMutation: () => ({ mutateAsync: asignar, isPending: false }),
}))

const simulacion = {
  duenio_anterior: null,
  clientes_zona: 65,
  cambian: 7,
  reservados: 0,
  quitados: [{ preventista_id: 'p-ana', nombre: 'Ana', clientes: 6 }],
  simulado: true,
}

beforeEach(() => {
  vi.clearAllMocks()
  simular.mockResolvedValue(simulacion)
  asignar.mockResolvedValue({ ...simulacion, simulado: false })
})

describe('ModalZonas · preventista de la zona', () => {
  it('muestra el dueño actual de cada zona', () => {
    render(<ModalZonas onClose={vi.fn()} />)
    expect((screen.getByLabelText('Preventista de ZONA 2') as HTMLSelectElement).value).toBe('p-ana')
    expect((screen.getByLabelText('Preventista de ZONA 1') as HTMLSelectElement).value).toBe('')
  })

  it('elegir simula, muestra a quién se le sacan clientes y escribe sólo al confirmar', async () => {
    render(<ModalZonas onClose={vi.fn()} />)

    fireEvent.change(screen.getByLabelText('Preventista de ZONA 1'), { target: { value: 'p-caro' } })

    expect(simular).toHaveBeenCalledWith({ zonaId: '10', preventistaId: 'p-caro' })
    const confirmacion = await screen.findByRole('alertdialog', { name: 'Confirmar preventista de la zona' })
    expect(confirmacion).toHaveTextContent('Linkear "ZONA 1" con Caro: 7 de los 65 clientes de la zona pasan a ser sólo de Caro.')
    expect(confirmacion).toHaveTextContent('Se le sacan a Ana (6).')
    expect(asignar).not.toHaveBeenCalled()

    fireEvent.click(screen.getByRole('button', { name: 'Confirmar' }))

    await waitFor(() => expect(asignar).toHaveBeenCalledWith({ zonaId: '10', preventistaId: 'p-caro' }))
    await waitFor(() => expect(screen.queryByRole('alertdialog')).toBeNull())
  })

  it('cancelar no escribe nada', async () => {
    render(<ModalZonas onClose={vi.fn()} />)

    fireEvent.change(screen.getByLabelText('Preventista de ZONA 1'), { target: { value: 'p-caro' } })
    await screen.findByRole('alertdialog')
    fireEvent.click(screen.getByRole('button', { name: 'Cancelar' }))

    expect(screen.queryByRole('alertdialog')).toBeNull()
    expect(asignar).not.toHaveBeenCalled()
  })

  it('quitar el preventista avisa que los clientes conservan el suyo', async () => {
    render(<ModalZonas onClose={vi.fn()} />)

    fireEvent.change(screen.getByLabelText('Preventista de ZONA 2'), { target: { value: '' } })

    expect(simular).toHaveBeenCalledWith({ zonaId: '20', preventistaId: null })
    expect(await screen.findByRole('alertdialog')).toHaveTextContent('Quitar el preventista de "ZONA 2".')
  })

  it('si la simulación falla, lo dice y no abre la confirmación', async () => {
    simular.mockRejectedValue(new Error('Sin conexión: no se pudo cargar qué clientes cambian.'))
    render(<ModalZonas onClose={vi.fn()} />)

    fireEvent.change(screen.getByLabelText('Preventista de ZONA 1'), { target: { value: 'p-caro' } })

    expect(await screen.findByRole('alert')).toHaveTextContent('no se pudo cargar qué clientes cambian')
    expect(screen.queryByRole('alertdialog')).toBeNull()
  })
})
