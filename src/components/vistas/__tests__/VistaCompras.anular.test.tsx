/**
 * "Anular compra" en la lista de `VistaCompras` (#1095).
 *
 * Una compra con notas de crédito no se anula: lo acreditado ya bajó el stock y
 * la reversa lo restaría dos veces. El server lo rechaza (anular_compra_atomica)
 * y la lista no ofrece el botón. jsdom no evalúa media queries, así que la tabla
 * de escritorio y las tarjetas del celular están las dos en el DOM: cada
 * compra ofrece el botón dos veces, o ninguna.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import VistaCompras, { type VistaComprasProps } from '../VistaCompras'
import type { CompraDBExtended, ProveedorDBExtended } from '../../../types'

function compra(id: string, proveedor: string): CompraDBExtended {
  return {
    id,
    proveedor_id: id,
    proveedor: { id, nombre: proveedor },
    proveedor_nombre: proveedor,
    numero_factura: `A-${id}`,
    estado: 'recibida',
    total: 1000,
    fecha_compra: '2026-09-20',
    created_at: '2026-09-20T10:00:00Z',
    items: [],
  } as unknown as CompraDBExtended
}

function renderVista(over: Partial<VistaComprasProps> = {}) {
  const onAnularCompra = vi.fn()
  const props: VistaComprasProps = {
    compras: [compra('1', 'Con nota'), compra('2', 'Sin nota')],
    proveedores: [] as ProveedorDBExtended[],
    loading: false,
    isAdmin: true,
    isEncargado: false,
    onNuevaCompra: vi.fn(),
    onVerDetalle: vi.fn(),
    onAnularCompra,
    ncResumen: [{ compra_id: '1', cantidad: 1, total: 500 }],
    ...over,
  }
  render(<VistaCompras {...props} />)
  return { onAnularCompra }
}

describe('VistaCompras — "Anular compra" con notas de crédito (#1095)', () => {
  it('sólo la compra sin notas ofrece anular, en la tabla y en las tarjetas', async () => {
    const { onAnularCompra } = renderVista()
    const botones = screen.getAllByRole('button', { name: 'Anular compra' })
    // Una compra (la 2) x dos pantallas.
    expect(botones).toHaveLength(2)

    const user = userEvent.setup()
    for (const b of botones) await user.click(b)
    expect(onAnularCompra).toHaveBeenCalledTimes(2)
    expect(onAnularCompra.mock.calls.every(([id]) => id === '2')).toBe(true)
  })

  it('control: sin notas, las dos compras ofrecen anular', () => {
    renderVista({ ncResumen: [] })
    expect(screen.getAllByRole('button', { name: 'Anular compra' })).toHaveLength(4)
  })
})
