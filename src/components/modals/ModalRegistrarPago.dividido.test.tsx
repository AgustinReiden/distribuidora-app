/**
 * COB-F-3 (#1476): el pago dividido sobre una boleta es UNA llamada con todas las
 * formas y una sola clave, no una RPC por línea.
 *
 * Antes: si la segunda línea se rechazaba, la primera ya estaba cobrada; y al
 * corregir los montos cambiaban las claves de todas, así que la primera entraba
 * otra vez.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

vi.mock('../../hooks/queries/useUltimaFechaCajaCerradaQuery', () => ({
  useFechaMinimaPago: () => undefined,
  useFechasMinimasPorCobrador: () => new Map(),
}))

import ModalRegistrarPago, { type ModalRegistrarPagoProps } from './ModalRegistrarPago'
import type { ClienteDB } from '../../types'
import { fijarUsuarioRequestIds } from '../../utils/requestIdPersistente'

beforeEach(() => {
  fijarUsuarioRequestIds('u-ana')
})

const CLIENTE = { id: '303', nombre_fantasia: 'MARCOS CHOFER' } as unknown as ClienteDB
type Dividido = NonNullable<ModalRegistrarPagoProps['onConfirmarDividido']>

function montar(onConfirmarDividido: Dividido, onConfirmar = vi.fn()) {
  return render(
    <ModalRegistrarPago
      cliente={CLIENTE}
      saldoPendiente={1000}
      pedidos={[]}
      pedidoIdFijo="4625"
      onClose={vi.fn()}
      onConfirmar={onConfirmar}
      onConfirmarDividido={onConfirmarDividido}
    />,
  )
}

async function cargarDividido(user: ReturnType<typeof userEvent.setup>, m1: string, m2: string) {
  await user.click(screen.getByLabelText(/Pago dividido/))
  const montos = screen.getAllByPlaceholderText('0.00')
  await user.clear(montos[0]); await user.type(montos[0], m1)
  await user.clear(montos[1]); await user.type(montos[1], m2)
}

describe('ModalRegistrarPago — pago dividido sobre una boleta (COB-F-3)', () => {
  it('manda todas las formas en una sola llamada y no cobra línea por línea', async () => {
    const onConfirmarDividido = vi.fn<Dividido>().mockResolvedValue({ id: 'p-2', monto: 400 } as never)
    const onConfirmar = vi.fn()
    const user = userEvent.setup()
    montar(onConfirmarDividido, onConfirmar)

    await cargarDividido(user, '600', '400')
    await user.click(screen.getByRole('button', { name: 'Registrar' }))

    await waitFor(() => expect(onConfirmarDividido).toHaveBeenCalledTimes(1))
    expect(onConfirmar).not.toHaveBeenCalled()
    const dato = onConfirmarDividido.mock.calls[0][0]
    expect(dato.pedidoId).toBe('4625')
    expect(dato.pagos).toEqual([
      { formaPago: 'efectivo', monto: 600 },
      { formaPago: 'transferencia', monto: 400 },
    ])
    expect(typeof dato.clientRequestId).toBe('string')
    // La pantalla de éxito muestra lo cobrado entero, no sólo la última línea.
    expect(await screen.findByText(/\$\s*1\.000/)).toBeTruthy()
  })

  it('si falla, el reintento con los mismos montos lleva la misma clave', async () => {
    const onConfirmarDividido = vi.fn<Dividido>()
      .mockRejectedValueOnce(new Error('Rechazado'))
      .mockResolvedValue({ id: 'p-2', monto: 400 } as never)
    const user = userEvent.setup()
    montar(onConfirmarDividido)

    await cargarDividido(user, '600', '400')
    await user.click(screen.getByRole('button', { name: 'Registrar' }))
    await screen.findByText(/Rechazado/)
    await user.click(screen.getByRole('button', { name: 'Registrar' }))

    await waitFor(() => expect(onConfirmarDividido).toHaveBeenCalledTimes(2))
    expect(onConfirmarDividido.mock.calls[1][0].clientRequestId)
      .toBe(onConfirmarDividido.mock.calls[0][0].clientRequestId)
  })

  it('sin onConfirmarDividido no cobra nada: no cae al cobro línea por línea', async () => {
    const onConfirmar = vi.fn()
    const user = userEvent.setup()
    render(
      <ModalRegistrarPago cliente={CLIENTE} saldoPendiente={1000} pedidos={[]} pedidoIdFijo="4625"
        onClose={vi.fn()} onConfirmar={onConfirmar} />,
    )

    await cargarDividido(user, '600', '400')
    await user.click(screen.getByRole('button', { name: 'Registrar' }))

    expect(await screen.findByText(/no está disponible/)).toBeTruthy()
    expect(onConfirmar).not.toHaveBeenCalled()
  })
})

// T6 de la tercera pasada: los renglones tienen claves estables. Con `key={index}`, quitar un
// renglón en rojo le pasaba su borrador en rojo al de abajo, y la marca de «en rojo» quedaba en el
// índice del que se fue.
describe('ModalRegistrarPago — pago dividido: quitar un renglón en rojo', () => {
  it('el rojo se va con su renglón y no pasa al que queda', async () => {
    const user = userEvent.setup()
    montar(vi.fn<Dividido>())
    await cargarDividido(user, '300', '300')
    await user.click(screen.getByRole('button', { name: /Agregar forma de pago/ }))
    const montos = screen.getAllByPlaceholderText('0.00')
    await user.clear(montos[2]); await user.type(montos[2], '300')
    await user.click(montos[0])
    await user.keyboard('{Control>}a{/Control}1.500.000')
    expect(montos[0]).toHaveAttribute('aria-invalid', 'true')
    const renglon = montos[0].closest('div.p-3') as HTMLElement
    await user.click(renglon.querySelector('button.text-red-500') as HTMLElement)
    const quedan = screen.getAllByPlaceholderText('0.00')
    expect(quedan).toHaveLength(2)
    for (const m of quedan) expect(m).not.toHaveAttribute('aria-invalid', 'true')
    expect(quedan.map(m => (m as HTMLInputElement).value)).toEqual(['300', '300'])
    expect(screen.getAllByText(/Se registra:/)).toHaveLength(2)
  })
})
