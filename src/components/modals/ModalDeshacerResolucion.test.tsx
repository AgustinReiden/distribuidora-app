/**
 * ModalDeshacerResolucion (gastos 6): deshacer una resolución pide un motivo obligatorio y se
 * confirma sólo con el botón.
 */
import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import ModalDeshacerResolucion, { type ModalDeshacerResolucionProps } from './ModalDeshacerResolucion'
import { formatPrecio } from '../../utils/formatters'
import type { FaltanteDeRendicion } from '../../types/gastos'

/** formatPrecio separa con espacios no cortables; el texto del DOM los normaliza. */
const normal = (s: string): string => s.replace(/\s/g, ' ')

const faltante = (extra: Partial<FaltanteDeRendicion> = {}): FaltanteDeRendicion => ({
  id: 1, transportista_id: 'tr-1', fecha: '2026-10-28', causal: 'empleado', monto: 5000, observacion: null,
  empleado: { id: 9, nombre: 'Marcos Delgado' }, gasto_id: null, rubro_nombre: null,
  creado_por_nombre: 'Ana Admin', created_at: '2026-11-03T12:00:00Z', ...extra,
})

function renderModal(props: Partial<ModalDeshacerResolucionProps> = {}) {
  const onDeshacer = vi.fn<ModalDeshacerResolucionProps['onDeshacer']>(() => Promise.resolve())
  const onClose = vi.fn()
  render(
    <ModalDeshacerResolucion
      fecha="2026-10-28"
      transportistaNombre="Tito Transportista"
      faltantes={[]}
      guardando={false}
      onDeshacer={onDeshacer}
      onClose={onClose}
      {...props}
    />,
  )
  return { onDeshacer, onClose, user: userEvent.setup() }
}

const BOTON = { name: 'Deshacer resolución' }

describe('ModalDeshacerResolucion', () => {
  it('dice a qué rendición y qué se deshace', () => {
    renderModal()

    expect(screen.getByText('Tito Transportista')).toBeInTheDocument()
    expect(screen.getByText('28/10/2026')).toBeInTheDocument()
    expect(screen.getByText(
      'Se compensan las deudas, se anulan los gastos de la resolución y la rendición vuelve a disconformidad.',
    )).toBeInTheDocument()
  })

  it('lista las líneas que se deshacen, con empleado o rubro, y suma el total', () => {
    renderModal({
      faltantes: [
        faltante(),
        faltante({ id: 2, causal: 'robo_perdida', monto: 8000, empleado: null, gasto_id: 7, rubro_nombre: 'Faltantes de caja', observacion: 'Se lo robaron' }),
        faltante({ id: 3, causal: 'gasto_no_cargado', monto: 500, empleado: null, gasto_id: 8, rubro_nombre: 'Peajes y estacionamiento' }),
      ],
    })

    expect(screen.getByText(normal(`A cargo de Marcos Delgado · ${formatPrecio(5000)}`))).toBeInTheDocument()
    expect(screen.getByText(normal(`Robo o pérdida · ${formatPrecio(8000)} · Se lo robaron`))).toBeInTheDocument()
    expect(screen.getByText(normal(`Gasto que no se cargó: Peajes y estacionamiento · ${formatPrecio(500)}`))).toBeInTheDocument()
    expect(screen.getByText(normal(`Total: ${formatPrecio(13500)}`))).toBeInTheDocument()
  })

  it('una resolución sin diferencia imputada lo dice', () => {
    renderModal({ faltantes: [] })

    expect(screen.getByText('Esta resolución no imputó ninguna diferencia: sólo vuelve a disconformidad.')).toBeInTheDocument()
    expect(screen.queryByText(/^Total:/)).toBeNull()
  })

  it('sin motivo no deja deshacer', async () => {
    const { user, onDeshacer } = renderModal()

    expect(screen.getByRole('button', BOTON)).toBeDisabled()
    await user.type(screen.getByLabelText(/¿Por qué se deshace\?/), '   ')
    expect(screen.getByRole('button', BOTON)).toBeDisabled()
    expect(onDeshacer).not.toHaveBeenCalled()
  })

  it('manda el motivo sin espacios sobrantes', async () => {
    const { user, onDeshacer } = renderModal()

    await user.type(screen.getByLabelText(/¿Por qué se deshace\?/), '  Me equivoqué de empleado  ')
    await user.click(screen.getByRole('button', BOTON))

    expect(onDeshacer).toHaveBeenCalledWith('Me equivoqué de empleado')
  })

  it('Enter en el campo no confirma', async () => {
    const { user, onDeshacer } = renderModal()

    await user.type(screen.getByLabelText(/¿Por qué se deshace\?/), 'motivo{Enter}')

    expect(onDeshacer).not.toHaveBeenCalled()
  })

  it('mientras guarda no se puede deshacer ni cancelar', () => {
    renderModal({ guardando: true })

    expect(screen.getByRole('button', { name: 'Cancelar' })).toBeDisabled()
  })
})
