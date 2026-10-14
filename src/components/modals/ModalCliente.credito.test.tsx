/**
 * Valores iniciales de crédito al editar un cliente (#1172).
 *
 * El formulario cargaba `dias_credito || 30`: un cliente de contado (0) se
 * reabría como 30 y el guardado lo reenviaba. Con `??` sólo null/undefined
 * toman el default.
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

function clienteCon(extra: Record<string, unknown>): ClienteDB {
  return {
    id: 440,
    razon_social: 'Comercial TP',
    nombre_fantasia: 'Comercial TP',
    direccion: 'Berutti 399',
    tipo_factura_default: 'ZZ',
    descuento_porcentaje: 0,
    ...extra,
  } as unknown as ClienteDB
}

async function guardar(cliente: ClienteDB): Promise<Record<string, unknown>> {
  render(
    <ModalCliente
      cliente={cliente}
      onSave={onSave}
      onVerificarDuplicado={onVerificarDuplicado}
      onClose={vi.fn()}
      guardando={false}
      isAdmin
    />
  )
  fireEvent.click(screen.getByRole('button', { name: /^guardar$/i }))
  await waitFor(() => expect(onSave).toHaveBeenCalled(), { timeout: 5000 })
  return onSave.mock.calls[0][0] as Record<string, unknown>
}

beforeEach(() => {
  vi.clearAllMocks()
  onVerificarDuplicado.mockResolvedValue({
    bloquea: false, avisa: false, motivo: null, distancia_m: null, cliente_visible: null,
  })
})

describe('ModalCliente — crédito inicial (#1172)', () => {
  it('un cliente de contado (dias_credito = 0) se reabre y se guarda con 0, no con 30', async () => {
    const datos = await guardar(clienteCon({ dias_credito: 0, limite_credito: 0 }))
    expect(datos.diasCredito).toBe(0)
    expect(datos.limiteCredito).toBe(0)
  })

  it('un crédito explícito viaja tal cual', async () => {
    const datos = await guardar(clienteCon({ dias_credito: 15, limite_credito: 2500 }))
    expect(datos.diasCredito).toBe(15)
    expect(datos.limiteCredito).toBe(2500)
  })

  it('un null de la base sigue tomando el default 30', async () => {
    const datos = await guardar(clienteCon({ dias_credito: null, limite_credito: null }))
    expect(datos.diasCredito).toBe(30)
    expect(datos.limiteCredito).toBe(0)
  })
})
