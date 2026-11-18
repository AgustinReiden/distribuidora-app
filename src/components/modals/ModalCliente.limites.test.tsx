/**
 * B23 de #1603 (decisión del dueño, 18/11): los días de crédito y los descuentos del cliente fuera de
 * su límite quedan en rojo, con su motivo, y el cliente no se guarda. Antes el blur del toque en
 * «Guardar» recortaba: un descuento de 150 se guardaba 100 % y 500 días de crédito se guardaban 365.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import ModalCliente from './ModalCliente'
import type { ClienteDB } from '../../types'

vi.mock('../../hooks/queries', () => ({
  usePreventistasQuery: () => ({ data: [] }),
  useZonasEstandarizadasQuery: () => ({ data: [] }),
  useCategoriasQuery: () => ({ data: [] }),
  useProductosQuery: () => ({ data: [] }),
  useClientesQuery: () => ({ data: [] }),
  usePreventistaZonasQuery: () => ({ data: [] }),
  useDueniosZonasQuery: () => ({ data: new Map() }),
}))

vi.mock('../../contexts/AuthDataContext', () => ({
  useAuthData: () => ({ perfil: { rol: 'admin' }, user: { id: 'u-admin' } }),
}))

vi.mock('../AddressAutocomplete', () => ({
  AddressAutocomplete: ({ value, onChange }: { value: string; onChange: (v: string) => void }) => (
    <input data-testid="direccion" value={value} onChange={e => onChange(e.target.value)} />
  ),
}))

const onSave = vi.fn()
const onVerificarDuplicado = vi.fn()

const CLIENTE = {
  id: 440,
  razon_social: 'Comercial de Prueba',
  nombre_fantasia: 'Comercial de Prueba',
  direccion: 'Calle Falsa 123',
  tipo_factura_default: 'ZZ',
  descuento_porcentaje: 10,
  dias_credito: 30,
  limite_credito: 0,
  descuentos_categoria: [{ categoria: 'Bebidas', descuento_porcentaje: 5 }],
} as unknown as ClienteDB

function abrir() {
  render(
    <ModalCliente
      cliente={CLIENTE}
      onSave={onSave}
      onVerificarDuplicado={onVerificarDuplicado}
      onClose={vi.fn()}
      guardando={false}
      isAdmin
    />
  )
  return userEvent.setup()
}

const guardar = (): HTMLElement => screen.getByRole('button', { name: /^guardar$/i })

beforeEach(() => {
  vi.clearAllMocks()
  onVerificarDuplicado.mockResolvedValue({
    bloquea: false, avisa: false, motivo: null, distancia_m: null, cliente_visible: null,
  })
})

describe('ModalCliente — crédito y descuentos fuera de su límite (B23)', () => {
  it.each([
    ['días de crédito 500', 'Días de crédito', '500', 'El plazo es de hasta 365 días'],
    ['descuento 150', 'Descuento general (%)', '150', 'No puede pasar de 100 %'],
    ['descuento de la categoría 150', 'Descuento de la categoría (%)', '150', 'No puede pasar de 100 %'],
  ])('%s: queda en rojo con su motivo y el cliente no se guarda', async (_caso, campo, texto, motivo) => {
    const user = abrir()
    const input = screen.getByLabelText(campo)

    await user.clear(input)
    await user.type(input, texto)
    await user.click(guardar())

    expect(input).toHaveValue(texto)
    expect(input).toHaveAttribute('aria-invalid', 'true')
    expect(screen.getByRole('alert')).toHaveTextContent(motivo)
    expect(screen.getByText('Hay un campo en rojo para corregir')).toBeInTheDocument()
    await new Promise(r => setTimeout(r, 50))
    expect(onSave).not.toHaveBeenCalled()
  })

  it('dentro del límite guarda lo tipeado, sin salir antes del campo', async () => {
    const user = abrir()

    await user.clear(screen.getByLabelText('Días de crédito'))
    await user.type(screen.getByLabelText('Días de crédito'), '365')
    await user.clear(screen.getByLabelText('Descuento general (%)'))
    await user.type(screen.getByLabelText('Descuento general (%)'), '100')
    await user.clear(screen.getByLabelText('Descuento de la categoría (%)'))
    await user.type(screen.getByLabelText('Descuento de la categoría (%)'), '40')
    await user.click(guardar())

    await waitFor(() => expect(onSave).toHaveBeenCalled(), { timeout: 5000 })
    expect(onSave.mock.calls[0][0]).toMatchObject({
      diasCredito: 365,
      descuentoPorcentaje: 100,
      descuentosPorCategoria: [{ categoria: 'Bebidas', porcentaje: 40 }],
    })
  })

  it('los días de crédito vacíos valen 0, y el campo lo muestra en gris', async () => {
    const user = abrir()
    const input = screen.getByLabelText('Días de crédito')
    // Decisión del dueño (18/11): vacío es contado, y la ayuda lo dice.
    expect(screen.getByText(/0 = contado/)).toBeInTheDocument()

    await user.clear(input)
    expect(input).toHaveAttribute('placeholder', '0')
    await user.click(guardar())

    await waitFor(() => expect(onSave).toHaveBeenCalled(), { timeout: 5000 })
    expect(onSave.mock.calls[0][0]).toMatchObject({ diasCredito: 0 })
  })
})
