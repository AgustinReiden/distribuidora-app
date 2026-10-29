import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import ModalRubrosGasto from './ModalRubrosGasto'
import type { RubroGasto } from '../../types/gastos'

const RUBROS: RubroGasto[] = [
  { id: 1, nombre: 'Combustible', grupo: 'vehiculos', palabras_busqueda: 'nafta', pide_litros_km: true, reparto_sugerido_meses: null, sugiere_mes_anterior: false, activo: true },
  { id: 3, nombre: 'Librería', grupo: 'administracion', palabras_busqueda: null, pide_litros_km: false, reparto_sugerido_meses: null, sugiere_mes_anterior: false, activo: false },
]

function renderModal(onGuardar = vi.fn((r: unknown) => Promise.resolve(r as RubroGasto))) {
  const onClose = vi.fn()
  render(<ModalRubrosGasto rubros={RUBROS} onGuardar={onGuardar} onClose={onClose} />)
  return { onGuardar, onClose, user: userEvent.setup() }
}

describe('ModalRubrosGasto', () => {
  it('lista los rubros por grupo y marca los inactivos', () => {
    renderModal()
    expect(screen.getByRole('region', { name: 'Vehículos' })).toHaveTextContent('Combustible')
    expect(screen.getByRole('region', { name: 'Administración' })).toHaveTextContent('Librería')
    expect(screen.getByText('Inactivo')).toBeInTheDocument()
    expect(screen.queryByRole('region', { name: 'Impuestos' })).not.toBeInTheDocument()
  })

  it('desactivar manda el rubro completo con activo en false', async () => {
    const { user, onGuardar } = renderModal()
    await user.click(screen.getByRole('button', { name: 'Desactivar Combustible' }))

    expect(onGuardar).toHaveBeenCalledWith({
      id: 1, nombre: 'Combustible', grupo: 'vehiculos', palabras_busqueda: 'nafta', activo: false,
      pide_litros_km: true, reparto_sugerido_meses: null, sugiere_mes_anterior: false,
    })
  })

  it('renombrar guarda el nombre nuevo', async () => {
    const { user, onGuardar } = renderModal()
    await user.click(screen.getByRole('button', { name: 'Renombrar Librería' }))
    const input = screen.getByLabelText('Nombre del rubro Librería')
    await user.clear(input)
    await user.type(input, 'Papelería')
    await user.click(screen.getByRole('button', { name: 'Guardar nombre' }))

    expect(onGuardar).toHaveBeenCalledWith(expect.objectContaining({ id: 3, nombre: 'Papelería' }))
  })

  it('cambiar el grupo y el rechazo del server se muestra tal cual', async () => {
    const { user, onGuardar } = renderModal(
      vi.fn(() => Promise.reject(new Error('Este rubro ya tiene gastos: no se le puede cambiar el grupo'))),
    )
    await user.selectOptions(screen.getByLabelText('Grupo de Combustible'), 'otros')

    expect(onGuardar).toHaveBeenCalledWith(expect.objectContaining({ id: 1, grupo: 'otros' }))
    expect(await screen.findByText('Este rubro ya tiene gastos: no se le puede cambiar el grupo')).toBeInTheDocument()
  })
})
