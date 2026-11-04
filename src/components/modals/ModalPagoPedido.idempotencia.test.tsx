/**
 * Tests de `ModalPagoPedido` — la clave del cobro sobrevive al modal (#1410).
 *
 * Antes la clave vivía en un `useRef`: si el cobro quedaba sin respuesta y el
 * usuario cerraba el modal, el reintento viajaba con otra, y un cobro parcial
 * que ya había entrado volvía a entrar. Y los dos caminos que cierran el modal
 * solos (la entrega con pago y el cobro del alta) pedían volver a cargarlo a
 * mano, siempre con una clave nueva.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach, type Mock } from 'vitest'
import { render, screen, waitFor, fireEvent } from '@testing-library/react'

vi.mock('../../hooks/queries/useUltimaFechaCajaCerradaQuery', () => ({
  useFechaMinimaPago: () => undefined,
}))

import ModalPagoPedido, { type ModalPagoPedidoProps } from './ModalPagoPedido'
import { guardarCobroSinConfirmar, leerCobroSinConfirmar, fijarUsuarioRequestIds } from '../../utils/requestIdPersistente'
import { fechaLocalISO } from '../../utils/formatters'
import type { PedidoDB, PagoDBWithUsuario } from '../../types'

type Confirmar = ModalPagoPedidoProps['onConfirmar']

const pedido = { id: '4625', cliente_id: '1', total: 21600 } as unknown as PedidoDB

// Las claves son de la sesión (useAuth la fija al loguearse).
beforeEach(() => {
  fijarUsuarioRequestIds('u-ana')
})

const pagoDe = (monto: number): PagoDBWithUsuario =>
  ({ id: String(monto), monto, forma_pago: 'efectivo', fecha: '2026-11-04' }) as unknown as PagoDBWithUsuario

function abrir(
  onConfirmar: ModalPagoPedidoProps['onConfirmar'],
  pagosPrevios: PagoDBWithUsuario[] = [],
  extra: Partial<ModalPagoPedidoProps> = {},
) {
  const props = (mas: Partial<ModalPagoPedidoProps>): ModalPagoPedidoProps => ({
    pedido, pagosPrevios, loadingPagosPrevios: false, onConfirmar, onClose: vi.fn(), guardando: false,
    ...extra, ...mas,
  })
  const utils = render(<ModalPagoPedido {...props({})} />)
  return { ...utils, recargar: (mas: Partial<ModalPagoPedidoProps>) => utils.rerender(<ModalPagoPedido {...props(mas)} />) }
}

/** Carga `monto` en la primera línea, cobra y devuelve la clave con que viajó. */
async function cobrarAhora(monto: string, onConfirmar: Mock<Confirmar>): Promise<string | undefined> {
  fireEvent.change(inputMonto(), { target: { value: monto } })
  const llamadas = onConfirmar.mock.calls.length
  fireEvent.click(screen.getByRole('button', { name: /^registrar pago$/i }))
  await waitFor(() => expect(onConfirmar).toHaveBeenCalledTimes(llamadas + 1))
  return onConfirmar.mock.calls[llamadas][0].clientRequestIds?.[0]
}

const CLAVE_VIEJA = '11111111-1111-4111-8111-111111111111'

const inputMonto = (): HTMLInputElement =>
  screen.getAllByPlaceholderText(/0[.,]00/i)[0] as HTMLInputElement

/** Abre el modal, cobra `monto` y lo cierra. Devuelve las claves con que viajó. */
async function cobrar(monto: string, onConfirmar: Mock<Confirmar>): Promise<string[]> {
  const { unmount } = abrir(onConfirmar)
  await waitFor(() => expect(inputMonto().value).toBe('21600'))
  fireEvent.change(inputMonto(), { target: { value: monto } })
  const llamadas = onConfirmar.mock.calls.length
  fireEvent.click(screen.getByRole('button', { name: /^registrar pago$/i }))
  await waitFor(() => expect(onConfirmar).toHaveBeenCalledTimes(llamadas + 1))
  unmount()
  return onConfirmar.mock.calls[llamadas][0].clientRequestIds ?? []
}

describe('ModalPagoPedido — la clave del cobro sobrevive al modal (#1410)', () => {
  it('cobro sin respuesta, cerrar y reabrir: el mismo cobro viaja con la misma clave', async () => {
    const onConfirmar = vi.fn<Confirmar>().mockRejectedValue(new Error('Sin conexión: no se pudo confirmar el pago.'))

    const primero = await cobrar('10000', onConfirmar)
    const reintento = await cobrar('10000', onConfirmar)

    expect(reintento).toEqual(primero)
  })

  it('otro monto al reabrir es otro cobro: otra clave', async () => {
    const onConfirmar = vi.fn<Confirmar>().mockRejectedValue(new Error('Sin conexión'))

    const primero = await cobrar('10000', onConfirmar)
    const otro = await cobrar('9000', onConfirmar)

    expect(otro[0]).not.toBe(primero[0])
  })

  it('después de un cobro que salió bien, el mismo cobro lleva otra clave', async () => {
    const onConfirmar = vi.fn<Confirmar>().mockResolvedValue(undefined)

    const primero = await cobrar('10000', onConfirmar)
    const segundo = await cobrar('10000', onConfirmar)

    expect(segundo[0]).not.toBe(primero[0])
  })

  it('un cobro que quedó sin confirmar se propone tal cual y viaja con su clave', async () => {
    // Lo que dejan la entrega con pago o el alta cuando el cobro falla y el
    // modal se cierra solo. La clave del alta no sale de la huella del modal.
    const clave = '11111111-1111-4111-8111-111111111111'
    guardarCobroSinConfirmar({
      pedidoId: '4625',
      fechaPago: fechaLocalISO(),
      observaciones: 'Pago parcial al crear el pedido',
      pagos: [{ formaPago: 'transferencia', monto: 7000 }],
      clientRequestId: clave,
      pagadoAntes: 0,
    })
    const onConfirmar = vi.fn<Confirmar>().mockResolvedValue(undefined)
    abrir(onConfirmar)

    expect(screen.getByText(/Este cobro quedó sin confirmar/)).toBeTruthy()
    expect(inputMonto().value).toBe('7000')
    fireEvent.click(screen.getByRole('button', { name: /^registrar pago$/i }))

    await waitFor(() => expect(onConfirmar).toHaveBeenCalledTimes(1))
    expect(onConfirmar.mock.calls[0][0]).toMatchObject({
      pagos: [{ formaPago: 'transferencia', monto: 7000 }],
      observaciones: 'Pago parcial al crear el pedido',
      clientRequestIds: [clave],
      pagadoAntes: 0,
    })
  })

  it('si se cambia el cobro propuesto, ya no es el mismo: otra clave', async () => {
    const clave = '11111111-1111-4111-8111-111111111111'
    guardarCobroSinConfirmar({
      pedidoId: '4625',
      fechaPago: fechaLocalISO(),
      pagos: [{ formaPago: 'efectivo', monto: 7000 }],
      clientRequestId: clave,
      pagadoAntes: 0,
    })
    const onConfirmar = vi.fn<Confirmar>().mockResolvedValue(undefined)
    abrir(onConfirmar)

    fireEvent.change(inputMonto(), { target: { value: '6000' } })
    fireEvent.click(screen.getByRole('button', { name: /^registrar pago$/i }))

    await waitFor(() => expect(onConfirmar).toHaveBeenCalledTimes(1))
    expect(onConfirmar.mock.calls[0][0].clientRequestIds?.[0]).not.toBe(clave)
  })

  it('si la boleta subió justo lo del cobro, ya entró: avisa y no lo vuelve a proponer', async () => {
    guardarCobroSinConfirmar({
      pedidoId: '4625', fechaPago: fechaLocalISO(),
      pagos: [{ formaPago: 'efectivo', monto: 7000 }],
      clientRequestId: '11111111-1111-4111-8111-111111111111',
      pagadoAntes: 0,
    })
    abrir(vi.fn<Confirmar>(), [pagoDe(7000)])

    expect(await screen.findByText(/ya entró: no hace falta volver a cargarlo/)).toBeTruthy()
    expect(screen.queryByText(/Este cobro quedó sin confirmar/)).toBeNull()
    await waitFor(() => expect(inputMonto().value).toBe('14600'))
    expect(leerCobroSinConfirmar('4625')).toBeNull()
  })

  it('si la boleta se cobró por otro camino, no lo propone: invitaría a cobrar dos veces', async () => {
    guardarCobroSinConfirmar({
      pedidoId: '4625', fechaPago: fechaLocalISO(),
      pagos: [{ formaPago: 'efectivo', monto: 500 }],
      clientRequestId: '11111111-1111-4111-8111-111111111111',
      pagadoAntes: 0,
    })
    abrir(vi.fn<Confirmar>(), [pagoDe(3000)])

    await waitFor(() => expect(inputMonto().value).toBe('18600'))
    expect(screen.queryByText(/Este cobro quedó sin confirmar/)).toBeNull()
    expect(screen.queryByText(/ya entró/)).toBeNull()
    expect(leerCobroSinConfirmar('4625')).toBeNull()
  })

  it('el cobro lleva lo pagado de la boleta al intentarlo', async () => {
    const onConfirmar = vi.fn<Confirmar>().mockResolvedValue(undefined)
    const { unmount } = abrir(onConfirmar, [pagoDe(1600)])
    await waitFor(() => expect(inputMonto().value).toBe('20000'))
    fireEvent.click(screen.getByRole('button', { name: /^registrar pago$/i }))
    await waitFor(() => expect(onConfirmar).toHaveBeenCalledTimes(1))
    unmount()
    expect(onConfirmar.mock.calls[0][0].pagadoAntes).toBe(1600)
  })

  it('después de "ya entró", un cobro igual y legítimo lleva otra clave: no se lo traga el server', async () => {
    // Boleta de 21600: el primer cobro de 7000 entró sin respuesta. Al reabrir, el
    // modal dice que ya entró. El cliente paga otros 7000 el mismo día.
    guardarCobroSinConfirmar({
      pedidoId: '4625', fechaPago: fechaLocalISO(),
      pagos: [{ formaPago: 'efectivo', monto: 7000 }],
      clientRequestId: CLAVE_VIEJA, pagadoAntes: 0,
    })
    const onConfirmar = vi.fn<Confirmar>().mockResolvedValue(undefined)
    abrir(onConfirmar, [pagoDe(7000)])
    await screen.findByText(/ya entró: no hace falta volver a cargarlo/)

    expect(await cobrarAhora('7000', onConfirmar)).not.toBe(CLAVE_VIEJA)
  })

  it('si la boleta cambió por otro camino, un cobro igual después lleva otra clave', async () => {
    guardarCobroSinConfirmar({
      pedidoId: '4625', fechaPago: fechaLocalISO(),
      pagos: [{ formaPago: 'efectivo', monto: 500 }],
      clientRequestId: CLAVE_VIEJA, pagadoAntes: 0,
    })
    const onConfirmar = vi.fn<Confirmar>().mockResolvedValue(undefined)
    abrir(onConfirmar, [pagoDe(3000)])
    await waitFor(() => expect(inputMonto().value).toBe('18600'))

    expect(await cobrarAhora('500', onConfirmar)).not.toBe(CLAVE_VIEJA)
  })

  it('si los pagos previos no cargaron, no deja cobrar ni toca el cobro sin confirmar', async () => {
    // La boleta ya tenía 1600. La entrega con pago quedó sin respuesta y, al
    // reabrir, falló la carga de pagos: lo pagado no se sabe.
    guardarCobroSinConfirmar({
      pedidoId: '4625', fechaPago: fechaLocalISO(),
      pagos: [{ formaPago: 'efectivo', monto: 7000 }],
      clientRequestId: CLAVE_VIEJA, pagadoAntes: 1600,
    })
    const onConfirmar = vi.fn<Confirmar>().mockResolvedValue(undefined)
    const onReintentarPagosPrevios = vi.fn()
    const { recargar } = abrir(onConfirmar, [], { pagosPreviosFallaron: true, onReintentarPagosPrevios })

    expect(screen.getByRole('alert').textContent).toMatch(/No se pudieron cargar los pagos de esta boleta/)
    expect(screen.getByRole('button', { name: /^registrar pago$/i })).toBeDisabled()
    expect(screen.queryByText(/Este cobro quedó sin confirmar/)).toBeNull()
    expect(leerCobroSinConfirmar('4625')?.clientRequestId).toBe(CLAVE_VIEJA)
    fireEvent.click(screen.getByRole('button', { name: /volver a cargar los pagos/i }))
    expect(onReintentarPagosPrevios).toHaveBeenCalled()

    // Cargan y la boleta sigue como estaba: el cobro no entró, se propone con su clave.
    recargar({ pagosPrevios: [pagoDe(1600)], pagosPreviosFallaron: false })
    expect(await screen.findByText(/Este cobro quedó sin confirmar/)).toBeTruthy()
    fireEvent.click(screen.getByRole('button', { name: /^registrar pago$/i }))
    await waitFor(() => expect(onConfirmar).toHaveBeenCalledTimes(1))
    expect(onConfirmar.mock.calls[0][0].clientRequestIds?.[0]).toBe(CLAVE_VIEJA)
  })
})
