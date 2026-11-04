/**
 * Tests de `ModalRegistrarPago` — la clave del cobro sobrevive al modal (#1410).
 *
 * El FIFO a cuenta no tiene tope: el sobrante queda a favor. Si el primer
 * intento entró pero la respuesta se perdió, y el reintento viaja con otra
 * clave porque el modal se cerró, el pago se duplica entero. Lo mismo, con
 * tope, el cobro de una parada del chofer.
 */
import { describe, it, expect, vi } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

vi.mock('../../hooks/queries/useUltimaFechaCajaCerradaQuery', () => ({
  useFechaMinimaPago: () => undefined,
}))

import ModalRegistrarPago, { type ModalRegistrarPagoProps } from './ModalRegistrarPago'
import type { ClienteDB, RegistrarPagoFifoResult } from '../../types'

const CLIENTE = { id: '303', nombre_fantasia: 'MARCOS CHOFER' } as unknown as ClienteDB
const SALDO = 111280

const RESULTADO_FIFO: RegistrarPagoFifoResult = {
  pagoIds: [901], sobrante: 0, montoTotal: SALDO, creditoAplicado: 0, aplicaciones: [],
}

type Fifo = NonNullable<ModalRegistrarPagoProps['onConfirmarFIFO']>

/** Abre el modal, carga el total, registra y lo cierra. */
async function registrarYcerrar(props: Partial<ModalRegistrarPagoProps>): Promise<void> {
  const user = userEvent.setup()
  const { unmount } = render(
    <ModalRegistrarPago
      cliente={CLIENTE}
      saldoPendiente={SALDO}
      pedidos={[]}
      onClose={vi.fn()}
      onConfirmar={vi.fn()}
      {...props}
    />,
  )
  await user.click(screen.getByRole('button', { name: 'Total' }))
  await user.click(screen.getByRole('button', { name: 'Registrar' }))
  await waitFor(() => expect(screen.queryByRole('button', { name: 'Registrar' })?.hasAttribute('disabled')).not.toBe(true))
  unmount()
}

describe('ModalRegistrarPago — la clave sobrevive al modal (#1410)', () => {
  it('FIFO sin respuesta, cerrar y reabrir: el reintento lleva la misma clave', async () => {
    const onConfirmarFIFO = vi.fn<Fifo>().mockRejectedValue(new Error('Sin conexión'))

    await registrarYcerrar({ onConfirmarFIFO })
    await registrarYcerrar({ onConfirmarFIFO })

    expect(onConfirmarFIFO).toHaveBeenCalledTimes(2)
    expect(onConfirmarFIFO.mock.calls[1][0].clientRequestId)
      .toBe(onConfirmarFIFO.mock.calls[0][0].clientRequestId)
  })

  it('FIFO que salió bien: el mismo pago otra vez es otro pago, con otra clave', async () => {
    const onConfirmarFIFO = vi.fn<Fifo>().mockResolvedValue(RESULTADO_FIFO)

    await registrarYcerrar({ onConfirmarFIFO })
    await registrarYcerrar({ onConfirmarFIFO })

    expect(onConfirmarFIFO.mock.calls[1][0].clientRequestId)
      .not.toBe(onConfirmarFIFO.mock.calls[0][0].clientRequestId)
  })

  it('cobro de una parada sin respuesta, cerrar y reabrir: la misma clave', async () => {
    const onConfirmar = vi.fn<ModalRegistrarPagoProps['onConfirmar']>().mockRejectedValue(new Error('Sin conexión'))
    const parada = { pedidos: [], pedidoIdFijo: '4625', onConfirmar }

    await registrarYcerrar(parada)
    await registrarYcerrar(parada)

    expect(onConfirmar).toHaveBeenCalledTimes(2)
    expect(onConfirmar.mock.calls[1][0].clientRequestId).toBe(onConfirmar.mock.calls[0][0].clientRequestId)
  })
})
