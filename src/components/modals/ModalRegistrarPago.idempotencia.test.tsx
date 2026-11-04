/**
 * Tests de `ModalRegistrarPago` — la clave del cobro sobrevive al modal (#1410).
 *
 * El FIFO a cuenta no tiene tope: el sobrante queda a favor. Si el primer
 * intento entró pero la respuesta se perdió, y el reintento viaja con otra
 * clave porque el modal se cerró, el pago se duplica entero. Lo mismo, con
 * tope, el cobro de una parada del chofer.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor, act } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

vi.mock('../../hooks/queries/useUltimaFechaCajaCerradaQuery', () => ({
  useFechaMinimaPago: () => undefined,
}))

import ModalRegistrarPago, { type ModalRegistrarPagoProps } from './ModalRegistrarPago'
import type { ClienteDB, RegistrarPagoFifoResult } from '../../types'
import { fijarUsuarioRequestIds } from '../../utils/requestIdPersistente'
import { ErrorDeSupabase } from '../../utils/errorDeSupabase'

// Las claves son de la sesión (useAuth la fija al loguearse).
beforeEach(() => {
  fijarUsuarioRequestIds('u-ana')
})

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

  it('el server devolvió un cobro anterior: la pantalla de éxito avisa que no se cobró dos veces', async () => {
    const onConfirmar = vi.fn<ModalRegistrarPagoProps['onConfirmar']>().mockResolvedValue(
      { id: 'p-1', monto: SALDO, idempotentReplay: true } as Awaited<ReturnType<ModalRegistrarPagoProps['onConfirmar']>>,
    )
    const user = userEvent.setup()
    render(
      <ModalRegistrarPago cliente={CLIENTE} saldoPendiente={SALDO} pedidos={[]} pedidoIdFijo="4625"
        onClose={vi.fn()} onConfirmar={onConfirmar} />,
    )
    await user.click(screen.getByRole('button', { name: 'Total' }))
    await user.click(screen.getByRole('button', { name: 'Registrar' }))

    expect(await screen.findByText(/ya había entrado en tu intento anterior/)).toBeTruthy()
  })
})

describe('ModalRegistrarPago — el chofer reintenta un cobro que entró sin respuesta (#1410)', () => {
  // Boleta de 1000: cobra 600, entra, la respuesta no llega. La pantalla relee
  // el recorrido y el saldo pasa a 400 con los 600 todavía en el campo.
  const sinRespuesta = new ErrorDeSupabase('Sin conexión: no se pudo confirmar el pago.', {}, true)

  function montarParada(saldo: number, onConfirmar: ModalRegistrarPagoProps['onConfirmar']) {
    const props = { cliente: CLIENTE, pedidos: [], pedidoIdFijo: '4625', onClose: vi.fn(), onConfirmar }
    const utils = render(<ModalRegistrarPago {...props} saldoPendiente={saldo} />)
    return { ...utils, releer: (nuevo: number) => utils.rerender(<ModalRegistrarPago {...props} saldoPendiente={nuevo} />) }
  }

  it('no dice que el excedente queda a favor: dice que ya figura y que repetirlo no cobra de nuevo', async () => {
    const onConfirmar = vi.fn<ModalRegistrarPagoProps['onConfirmar']>().mockRejectedValue(sinRespuesta)
    const user = userEvent.setup()
    const { releer } = montarParada(1000, onConfirmar)

    await user.type(screen.getByPlaceholderText(/0[.,]00/), '600')
    await user.click(screen.getByRole('button', { name: 'Registrar' }))
    await screen.findByText(/no se pudo confirmar el pago/)
    act(() => releer(400))

    expect(screen.getByText(/que quedó sin\s+confirmar ya figura en la cuenta/)).toBeTruthy()
    expect(screen.queryByText(/quedará como saldo a favor/)).toBeNull()
  })

  it('si el server rechazó el cobro, no hubo intento que pueda haber entrado: no lo anuncia', async () => {
    const rechazo = new ErrorDeSupabase('El monto supera lo que falta cobrar', { code: 'P0001' }, false)
    const onConfirmar = vi.fn<ModalRegistrarPagoProps['onConfirmar']>().mockRejectedValue(rechazo)
    const user = userEvent.setup()
    const { releer } = montarParada(1000, onConfirmar)

    await user.type(screen.getByPlaceholderText(/0[.,]00/), '600')
    await user.click(screen.getByRole('button', { name: 'Registrar' }))
    await screen.findByText(/supera lo que falta/)
    act(() => releer(400))

    expect(screen.queryByText(/ya figura en la cuenta/)).toBeNull()
  })
})
