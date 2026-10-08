/**
 * Comprobante por defecto del cliente: la opción "VB — Consumo interno (vale blanco)"
 * (cliente de empresa propia, único que puede recibir vales blancos).
 *
 * Sólo un admin la ve y la puede poner o sacar: todo el bloque "Configuración de
 * Crédito y Descuento" es admin-only, y el servidor lo exige igual con el trigger
 * clientes_vb_solo_admin (42501).
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent, waitFor } from '@testing-library/react'
import ModalCliente from './ModalCliente'
import type { ClienteDB } from '../../types'

vi.mock('../../hooks/queries', () => ({
  usePreventistasQuery: () => ({ data: [] }),
  useZonasEstandarizadasQuery: () => ({ data: [] }),
  useCategoriasQuery: () => ({ data: [] }),
  useProductosQuery: () => ({ data: [] }),
  useClientesQuery: () => ({ data: [] }),
}))

vi.mock('../AddressAutocomplete', () => ({
  AddressAutocomplete: ({ value, onChange }: { value: string; onChange: (v: string) => void }) => (
    <input data-testid="direccion" value={value} onChange={e => onChange(e.target.value)} />
  ),
}))

const onSave = vi.fn()
const onVerificarDuplicado = vi.fn()

function renderModal(props: { isAdmin: boolean; cliente?: ClienteDB | null }) {
  return render(
    <ModalCliente
      cliente={props.cliente ?? null}
      onSave={onSave}
      onVerificarDuplicado={onVerificarDuplicado}
      onClose={vi.fn()}
      guardando={false}
      isAdmin={props.isAdmin}
    />
  )
}

const clienteVB = {
  id: 440,
  razon_social: 'Comercial TP',
  nombre_fantasia: 'Comercial TP',
  direccion: 'Berutti 399',
  tipo_factura_default: 'VB',
  limite_credito: 0,
  dias_credito: 30,
  descuento_porcentaje: 0,
} as unknown as ClienteDB

beforeEach(() => {
  vi.clearAllMocks()
  onVerificarDuplicado.mockResolvedValue({
    bloquea: false, avisa: false, motivo: null, distancia_m: null, cliente_visible: null,
  })
})

describe('ModalCliente — comprobante por defecto VB (consumo interno)', () => {
  it('el admin ve la opción VB junto a ZZ y FC', () => {
    renderModal({ isAdmin: true })
    const select = screen.getByLabelText(/comprobante por defecto/i, { selector: 'select' }) as HTMLSelectElement
    const valores = Array.from(select.options).map(o => o.value)
    expect(valores).toEqual(['ZZ', 'FC', 'VB'])
    expect(screen.getByRole('option', { name: /VB — Consumo interno/i })).toBeInTheDocument()
  })

  it('quien no es admin no ve el selector de comprobante (ni, por lo tanto, la opción VB)', () => {
    renderModal({ isAdmin: false })
    expect(screen.queryByText(/comprobante por defecto/i)).toBeNull()
    expect(screen.queryByRole('option', { name: /VB — Consumo interno/i })).toBeNull()
  })

  it('al elegir VB avisa qué implica', () => {
    renderModal({ isAdmin: true })
    expect(screen.queryByTestId('aviso-cliente-vb')).toBeNull()
    fireEvent.change(screen.getByLabelText(/comprobante por defecto/i, { selector: 'select' }), { target: { value: 'VB' } })
    expect(screen.getByTestId('aviso-cliente-vb')).toHaveTextContent(/empresas propias/i)
  })

  it('un cliente que ya es VB abre con VB seleccionado y lo manda tal cual al guardar', async () => {
    renderModal({ isAdmin: true, cliente: clienteVB })
    const select = screen.getByLabelText(/comprobante por defecto/i, { selector: 'select' }) as HTMLSelectElement
    expect(select.value).toBe('VB')

    fireEvent.click(screen.getByRole('button', { name: /^guardar$/i }))
    await waitFor(() => expect(onSave).toHaveBeenCalled(), { timeout: 5000 })
    expect(onSave.mock.calls[0][0].tipoFacturaDefault).toBe('VB')
  })
})
