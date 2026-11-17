/**
 * ModalProveedor: el CUIT se valida con su dígito verificador (D37 de #1561, 1561-b11), y el
 * motivo que devuelve el server al guardar (CUIT duplicado) llega a la pantalla (1599-b1).
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent, waitFor } from '@testing-library/react'
import ModalProveedor from './ModalProveedor'
import type { Proveedor } from '../../types'

vi.mock('../../hooks/queries', () => ({
  useZonasEstandarizadasQuery: () => ({ data: [] }),
}))
vi.mock('../AddressAutocomplete', () => ({
  AddressAutocomplete: () => <input aria-label="direccion" />,
}))

const onSave = vi.fn()

function abrir(proveedor: Proveedor | null = null) {
  render(<ModalProveedor proveedor={proveedor} onSave={onSave} onClose={vi.fn()} />)
}
const cuit = () => screen.getByPlaceholderText('XX-XXXXXXXX-X')
const guardar = () => fireEvent.click(screen.getByRole('button', { name: /crear proveedor|actualizar/i }))

beforeEach(() => {
  vi.clearAllMocks()
  onSave.mockResolvedValue(undefined)
})

describe('ModalProveedor — CUIT', () => {
  it('con el dígito verificador equivocado no guarda y lo dice', async () => {
    abrir()
    fireEvent.change(screen.getByPlaceholderText('Nombre del proveedor'), { target: { value: 'Proveedor de prueba' } })
    fireEvent.change(cuit(), { target: { value: '20123456789' } })
    guardar()

    expect(await screen.findByText(/el dígito verificador no coincide/i)).toBeVisible()
    expect(onSave).not.toHaveBeenCalled()
  })

  it('con un CUIT bien armado guarda', async () => {
    abrir()
    fireEvent.change(screen.getByPlaceholderText('Nombre del proveedor'), { target: { value: 'Proveedor de prueba' } })
    fireEvent.change(cuit(), { target: { value: '20123456786' } })
    guardar()

    await waitFor(() => expect(onSave).toHaveBeenCalled())
  })

  it('sin CUIT guarda', async () => {
    abrir()
    fireEvent.change(screen.getByPlaceholderText('Nombre del proveedor'), { target: { value: 'Proveedor de prueba' } })
    guardar()

    await waitFor(() => expect(onSave).toHaveBeenCalled())
  })

  it('el motivo del server (CUIT duplicado) se muestra en el modal', async () => {
    onSave.mockRejectedValue(new Error('Ya existe un proveedor con CUIT "20-12345678-6": Norte 01'))
    abrir()
    fireEvent.change(screen.getByPlaceholderText('Nombre del proveedor'), { target: { value: 'Proveedor de prueba' } })
    fireEvent.change(cuit(), { target: { value: '20123456786' } })
    guardar()

    expect(await screen.findByText(/Ya existe un proveedor con CUIT/)).toBeVisible()
  })
})
