/**
 * #1260: cambiar el cliente resuelve las promos y los combos como la edición.
 *
 * - La fecha es la del pedido topada a hoy (`fechaReferenciaPromo`, #1152): un
 *   pedido con fecha futura no puede ganar ni perder un regalo por una promo
 *   que todavía no empezó o que ya terminó para esa fecha.
 * - `combos_vigentes` recibe el pedido, para no contar sus propios combos
 *   contra el tope, y los combos que el pedido ya tiene se miden contra su foto.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render } from '@testing-library/react'
import type { PedidoDB, ProductoDB, ClienteDB } from '../../types'

const { usePromoMapQueryMock, useCombosVigentesQueryMock, useFotosCombosPedidoQueryMock } = vi.hoisted(() => ({
  usePromoMapQueryMock: vi.fn((..._args: unknown[]) => ({ data: new Map(), isLoading: false })),
  useCombosVigentesQueryMock: vi.fn((..._args: unknown[]) => ({ data: [], isLoading: false })),
  useFotosCombosPedidoQueryMock: vi.fn((..._args: unknown[]) => ({ data: [] })),
}))

vi.mock('../../hooks/queries/useCombosQuery', () => ({
  useCombosVigentesQuery: useCombosVigentesQueryMock,
  useFotosCombosPedidoQuery: useFotosCombosPedidoQueryMock,
  useNombresCombosQuery: () => ({ data: new Map() }),
}))
vi.mock('../../hooks/queries/useGruposPrecioQuery', () => ({
  usePricingMapQuery: () => ({ data: new Map(), isLoading: false }),
}))
vi.mock('../../hooks/queries/usePromocionesQuery', () => ({
  usePromoMapQuery: usePromoMapQueryMock,
}))
vi.mock('../../hooks/queries/useProductosQuery', () => ({
  useMinimosVentaQuery: () => ({ data: new Map(), isLoading: false }),
}))

import ModalCambiarCliente from './ModalCambiarCliente'

const productos = [{ id: 1, nombre: 'Producto 1', precio: 300, stock: 10 }] as unknown as ProductoDB[]
const clientes = [{ id: 10, nombre_fantasia: 'Cliente Actual' }] as unknown as ClienteDB[]

function montar(fecha: string) {
  const pedido = {
    id: 123,
    cliente_id: 10,
    fecha,
    total: 600,
    estado: 'pendiente',
    tipo_factura: 'ZZ',
    items: [{ producto_id: 1, cantidad: 2, precio_unitario: 300 }],
  } as unknown as PedidoDB
  render(
    <ModalCambiarCliente pedido={pedido} productos={productos} clientes={clientes}
      guardando={false} onConfirmar={vi.fn()} onClose={vi.fn()} />,
  )
}

describe('ModalCambiarCliente: fecha de referencia de promos y combos (#1260)', () => {
  beforeEach(() => {
    usePromoMapQueryMock.mockClear()
    useCombosVigentesQueryMock.mockClear()
    useFotosCombosPedidoQueryMock.mockClear()
  })

  it('un pedido con fecha futura resuelve promos y combos con los de hoy', () => {
    montar('2099-01-01')
    expect(usePromoMapQueryMock).toHaveBeenLastCalledWith(undefined)
    expect(useCombosVigentesQueryMock.mock.lastCall?.[0]).toBeUndefined()
  })

  it('un pedido con fecha pasada resuelve con los de su fecha', () => {
    montar('2026-01-15')
    expect(usePromoMapQueryMock).toHaveBeenLastCalledWith('2026-01-15')
    expect(useCombosVigentesQueryMock.mock.lastCall?.[0]).toBe('2026-01-15')
  })

  it('combos_vigentes recibe el pedido y se piden las fotos de sus combos', () => {
    montar('2026-01-15')
    expect(useCombosVigentesQueryMock.mock.lastCall?.[1]).toBe('123')
    expect(useFotosCombosPedidoQueryMock).toHaveBeenLastCalledWith('123')
  })
})
