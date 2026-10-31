/**
 * El modal cuenta y lista los clientes de cada preventista por
 * `cliente_preventistas` (`preventista_ids`), no por la columna legada
 * `clientes.preventista_id`, que no sigue a la zona (#1314).
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import type { ClienteDB, PerfilDB } from '../../../types'

vi.mock('../../../hooks/useOptimizarRuta', () => ({
  getDepositoCoords: () => ({ lat: -26.8, lng: -65.2 }),
  setDepositoCoords: vi.fn(),
}))

import ModalOptimizarRutaPreventista from '../ModalOptimizarRutaPreventista'

const cliente = (id: string, extra: Partial<ClienteDB>): ClienteDB =>
  ({ id, nombre_fantasia: `Cliente ${id}`, activo: true, latitud: -26.8, longitud: -65.2, ...extra }) as ClienteDB

describe('ModalOptimizarRutaPreventista — asignación (#1314)', () => {
  it('cuenta los clientes por preventista_ids e ignora el preventista_id legado', () => {
    const clientes = [
      // Asignado a Víctor en cliente_preventistas; el legado todavía dice Juan.
      cliente('1', { preventista_ids: ['victor'], preventista_id: 'juan' }),
      cliente('2', { preventista_ids: ['victor'], preventista_id: 'victor' }),
      // Sin asignar: el legado desfasado no lo hace de nadie.
      cliente('3', { preventista_ids: [], preventista_id: 'juan' }),
    ]
    const preventistas = [
      { id: 'victor', nombre: 'Víctor' },
      { id: 'juan', nombre: 'Juan' },
    ] as PerfilDB[]

    render(
      <ModalOptimizarRutaPreventista
        preventistas={preventistas}
        clientes={clientes}
        onOptimizar={vi.fn()}
        onClose={vi.fn()}
        loading={false}
        rutaOptimizada={null}
        error={null}
      />,
    )

    expect(screen.getByRole('option', { name: 'Víctor (2 clientes asignados)' })).toBeInTheDocument()
    expect(screen.getByRole('option', { name: 'Juan (0 clientes asignados)' })).toBeInTheDocument()
  })
})
