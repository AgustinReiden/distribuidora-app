/**
 * `ModalEntregaConSalvedad` — el cargo de envío en el total a cobrar.
 *
 * El total del pedido incluye el cargo (`total = productos + cargo_envio`) pero
 * las líneas no: el "Total efectivo a cobrar" salía de sumar las líneas que
 * quedan y el chofer cobraba de menos por el envío. El cargo se suma mientras
 * quede algo vendido; si el cliente lo rechaza todo, el server lo deja sin
 * cobrar (el pedido queda sin productos) y acá tampoco se suma.
 */
import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import type { PedidoDB, RegistrarSalvedadResult } from '../../types'

vi.mock('../../hooks/queries', () => ({
  useSimularSalvedadesPromoImpactoQuery: () => ({ data: [], isLoading: false }),
  useSimularSalvedadesComboImpactoQuery: () => ({ data: [], isLoading: false }),
}))

import ModalEntregaConSalvedad from './ModalEntregaConSalvedad'

// Productos 4.000 (2 x 1.500 + 1 x 1.000) + envío 500 = 4.500.
const PEDIDO = {
  id: '60',
  cliente_id: '9',
  estado: 'en_preparacion',
  total: 4500,
  cargo_envio: 500,
  cargo_envio_estado: 'cobrado',
  cliente: { id: '9', nombre_fantasia: 'Kiosco Este' },
  items: [
    { id: '301', pedido_id: '60', producto_id: '1', producto: { nombre: 'Yerba' }, cantidad: 2, precio_unitario: 1500 },
    { id: '302', pedido_id: '60', producto_id: '2', producto: { nombre: 'Azúcar' }, cantidad: 1, precio_unitario: 1000 },
  ],
} as unknown as PedidoDB

async function irALaConfirmacion(nombres: string[], pedido: PedidoDB = PEDIDO) {
  const user = userEvent.setup()
  const OK: RegistrarSalvedadResult[] = [{ success: true }]
  render(
    <ModalEntregaConSalvedad
      pedido={pedido}
      onSave={vi.fn().mockResolvedValue(OK)}
      onMarcarEntregado={vi.fn().mockResolvedValue(undefined)}
      onClose={vi.fn()}
    />,
  )
  for (const nombre of nombres) {
    await user.click(screen.getByText(nombre))
    await user.selectOptions(screen.getAllByRole('combobox')[0], 'cliente_rechaza')
  }
  await user.click(screen.getByRole('button', { name: /continuar/i }))
}

describe('ModalEntregaConSalvedad — cargo de envío', () => {
  it('el total efectivo a cobrar suma el cargo', async () => {
    await irALaConfirmacion(['Azúcar'])

    // 3.000 de Yerba que se entrega + 500 de envío.
    expect(screen.getByText('Total efectivo a cobrar:').nextSibling).toHaveTextContent(/\$\s?3\.500/)
    // "Total original" son los productos: el envío va en su renglón.
    expect(screen.getByText('Total original:').nextSibling).toHaveTextContent(/\$\s?4\.000/)
    expect(screen.getByText('Envío:').nextSibling).toHaveTextContent(/\$\s?500/)
  })

  it('si se rechaza todo no lo suma', async () => {
    await irALaConfirmacion(['Yerba', 'Azúcar'])

    expect(screen.getByText('Total efectivo a cobrar:').nextSibling).toHaveTextContent(/^\$\s?0(,00)?$/)
    expect(screen.queryByText('Envío:')).not.toBeInTheDocument()
  })

  // Productos 10.000 (4 x 2.000 + 1 x 2.000) + envío 500 = 10.500.
  const PEDIDO_10K = {
    ...PEDIDO,
    total: 10500,
    items: [
      { id: '311', pedido_id: '60', producto_id: '1', producto: { nombre: 'Yerba' }, cantidad: 4, precio_unitario: 2000 },
      { id: '312', pedido_id: '60', producto_id: '2', producto: { nombre: 'Azúcar' }, cantidad: 1, precio_unitario: 2000 },
    ],
  } as unknown as PedidoDB

  it('la cuenta visible cierra: productos − afectado + envío = total a cobrar', async () => {
    await irALaConfirmacion(['Azúcar'], PEDIDO_10K)

    // 10.000 − 2.000 + 500 = 8.500.
    expect(screen.getByText('Total original:').nextSibling).toHaveTextContent(/^\$\s?10\.000(,00)?$/)
    expect(screen.getByText('Monto afectado por salvedades:').nextSibling).toHaveTextContent(/^-\$\s?2\.000(,00)?$/)
    expect(screen.getByText('Envío:').nextSibling).toHaveTextContent(/^\+\$\s?500(,00)?$/)
    expect(screen.getByText('Total efectivo a cobrar:').nextSibling).toHaveTextContent(/^\$\s?8\.500(,00)?$/)
  })

  it('con el rechazo total no hay renglón de envío y la cuenta da 0', async () => {
    await irALaConfirmacion(['Yerba', 'Azúcar'], PEDIDO_10K)

    expect(screen.getByText('Total original:').nextSibling).toHaveTextContent(/^\$\s?10\.000(,00)?$/)
    expect(screen.getByText('Monto afectado por salvedades:').nextSibling).toHaveTextContent(/^-\$\s?10\.000(,00)?$/)
    expect(screen.queryByText('Envío:')).not.toBeInTheDocument()
    expect(screen.getByText('Total efectivo a cobrar:').nextSibling).toHaveTextContent(/^\$\s?0(,00)?$/)
  })

  it('un pedido sin cargo no muestra la palabra envío', async () => {
    const user = userEvent.setup()
    render(
      <ModalEntregaConSalvedad
        pedido={{ ...PEDIDO, total: 4000, cargo_envio: 0 } as unknown as PedidoDB}
        onSave={vi.fn().mockResolvedValue([{ success: true }])}
        onMarcarEntregado={vi.fn().mockResolvedValue(undefined)}
        onClose={vi.fn()}
      />,
    )
    await user.click(screen.getByText('Azúcar'))
    await user.selectOptions(screen.getAllByRole('combobox')[0], 'cliente_rechaza')
    await user.click(screen.getByRole('button', { name: /continuar/i }))

    expect(screen.getByText('Total efectivo a cobrar:').nextSibling).toHaveTextContent(/\$\s?3\.000/)
    expect(screen.queryByText('Envío:')).not.toBeInTheDocument()
  })
})
