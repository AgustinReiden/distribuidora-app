/**
 * Caracterización de ModalRegistrarPago (#810): lo que se ve y lo que hace,
 * fijado ANTES de pasar el overlay hecho a mano a `ui/Dialog`.
 *
 * Es un modal de plata: la migración no puede cambiar cómo se cierra ni qué
 * le llega a los handlers. Por eso acá se fija, contra el código viejo:
 *  - el formulario con su título, el cliente y el saldo;
 *  - que se cierra SÓLO con sus botones (la X «Cerrar» y «Cancelar»), y que
 *    Escape y un click en el fondo no lo cierran;
 *  - las dos pantallas de éxito (pago simple y FIFO), con lo que reciben
 *    `onConfirmar` / `onConfirmarFIFO` / `onGenerarRecibo`, y su «Cerrar».
 *
 * La única consulta estructural es `fondoDelModal()`: el overlay oscuro se
 * busca por sus clases (`fixed inset-0 bg-black/50`), que comparten el div
 * hecho a mano y el overlay de `ui/Dialog`. Todo lo demás es por rol y texto.
 *
 * El bloque «es un diálogo accesible» se sumó DESPUÉS de la migración y es lo
 * único que el modal viejo no cumplía: role="dialog" con nombre, aria-modal,
 * foco adentro al montar y Tab que no sale. Los demás bloques pasaban igual
 * contra el modal hecho a mano y no se tocaron.
 */
import '@testing-library/jest-dom/vitest'
import { useState } from 'react'
import { describe, it, expect, vi } from 'vitest'
import { act, render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

vi.mock('../../hooks/queries/useUltimaFechaCajaCerradaQuery', () => ({
  useFechaMinimaPago: () => undefined,
}))

import ModalRegistrarPago, { type ModalRegistrarPagoProps } from './ModalRegistrarPago'
import { formatPrecio } from '../../utils/formatters'
import type { ClienteDB, RegistrarPagoFifoResult } from '../../types'

type PagoRegistrado = Awaited<ReturnType<ModalRegistrarPagoProps['onConfirmar']>>

const CLIENTE = { id: '1', nombre_fantasia: 'Almacén Don Ramón' } as unknown as ClienteDB
const SALDO = 1500

const PAGO: PagoRegistrado = {
  id: 'p-1',
  cliente_id: '1',
  monto: SALDO,
  forma_pago: 'efectivo',
  fecha: '2026-10-04',
} as PagoRegistrado

const RESULTADO_FIFO: RegistrarPagoFifoResult = {
  pagoIds: [901],
  sobrante: 0,
  montoTotal: SALDO,
  creditoAplicado: 0,
  aplicaciones: [{ pago_id: 901, pedido_id: 77, pedido_fecha: '2026-09-30', monto: SALDO }],
}

/** FocusScope y DismissableLayer de Radix se enganchan en un setTimeout(0). */
const dejarCorrerTimers = () => act(() => new Promise<void>(resolve => setTimeout(resolve, 0)))

function montar(props: Partial<ModalRegistrarPagoProps> = {}) {
  const onClose = vi.fn()
  const onConfirmar = vi.fn<ModalRegistrarPagoProps['onConfirmar']>().mockResolvedValue(PAGO)
  const utils = render(
    <ModalRegistrarPago
      cliente={CLIENTE}
      saldoPendiente={SALDO}
      pedidos={[]}
      onClose={onClose}
      onConfirmar={onConfirmar}
      {...props}
    />,
  )
  return { ...utils, onClose, onConfirmar }
}

/** El overlay oscuro: el div hecho a mano o el `DialogOverlay`, según la versión. */
function fondoDelModal(): HTMLElement {
  const fondo = document.querySelector<HTMLElement>('.fixed.inset-0.bg-black\\/50')
  if (!fondo) throw new Error('No se encontró el fondo del modal')
  return fondo
}

/** «Total» carga el saldo pendiente en el monto; después, «Registrar». */
async function registrarPorElTotal(user: ReturnType<typeof userEvent.setup>) {
  await user.click(screen.getByRole('button', { name: 'Total' }))
  await user.click(screen.getByRole('button', { name: 'Registrar' }))
}

describe('ModalRegistrarPago · formulario', () => {
  it('abre con el título «Registrar Pago», el cliente y el saldo pendiente', () => {
    montar()

    expect(screen.getByRole('heading', { name: 'Registrar Pago' })).toBeInTheDocument()
    expect(screen.getByText('Almacén Don Ramón')).toBeInTheDocument()
    const saldo = screen.getByText('Saldo pendiente:').parentElement as HTMLElement
    expect(saldo.textContent).toContain(formatPrecio(SALDO))
    expect(screen.getByRole('button', { name: 'Registrar' })).toBeDisabled()
  })

  it('con saldo negativo muestra «Saldo a favor» y no «Saldo pendiente»', () => {
    montar({ saldoPendiente: -300 })

    expect(screen.queryByText('Saldo pendiente:')).toBeNull()
    const aFavor = screen.getByText('Saldo a favor:').parentElement as HTMLElement
    expect(aFavor.textContent).toContain(formatPrecio(300))
  })

  it('la X «Cerrar» llama a onClose', async () => {
    const user = userEvent.setup()
    const { onClose, onConfirmar } = montar()

    await user.click(screen.getByRole('button', { name: 'Cerrar' }))

    expect(onClose).toHaveBeenCalledTimes(1)
    expect(onConfirmar).not.toHaveBeenCalled()
  })

  it('«Cancelar» llama a onClose', async () => {
    const user = userEvent.setup()
    const { onClose, onConfirmar } = montar()

    await user.click(screen.getByRole('button', { name: 'Cancelar' }))

    expect(onClose).toHaveBeenCalledTimes(1)
    expect(onConfirmar).not.toHaveBeenCalled()
  })

  it('Escape NO lo cierra: no llama a onClose y el formulario sigue', async () => {
    const user = userEvent.setup()
    const { onClose } = montar()
    await dejarCorrerTimers()

    await user.keyboard('{Escape}')
    await dejarCorrerTimers()

    expect(onClose).not.toHaveBeenCalled()
    expect(screen.getByRole('heading', { name: 'Registrar Pago' })).toBeInTheDocument()
  })

  it('Escape con el monto cargado y el foco en un campo tampoco lo cierra', async () => {
    const user = userEvent.setup()
    const { onClose } = montar()
    await dejarCorrerTimers()

    await user.click(screen.getByRole('button', { name: 'Total' }))
    await user.click(screen.getByPlaceholderText('Observaciones del pago...'))
    await user.keyboard('{Escape}')
    await dejarCorrerTimers()

    expect(onClose).not.toHaveBeenCalled()
    expect(screen.getByRole('button', { name: 'Registrar' })).toBeEnabled()
  })

  it('un click en el fondo NO lo cierra: no llama a onClose y el formulario sigue', async () => {
    const user = userEvent.setup()
    const { onClose } = montar()
    // El listener de "click afuera" de Radix se engancha en un setTimeout(0):
    // sin esperarlo, el test pasaría aunque el click sí cerrara.
    await dejarCorrerTimers()

    await user.click(fondoDelModal())
    await dejarCorrerTimers()

    expect(onClose).not.toHaveBeenCalled()
    expect(screen.getByRole('heading', { name: 'Registrar Pago' })).toBeInTheDocument()
  })

  it('si onConfirmar falla, muestra el error y el formulario sigue abierto', async () => {
    const user = userEvent.setup()
    const onConfirmar = vi.fn<ModalRegistrarPagoProps['onConfirmar']>()
      .mockRejectedValue(new Error('La caja de esa fecha ya está cerrada'))
    const { onClose } = montar({ onConfirmar })

    await registrarPorElTotal(user)

    expect(await screen.findByText('La caja de esa fecha ya está cerrada')).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: 'Registrar Pago' })).toBeInTheDocument()
    expect(screen.queryByText('Pago Registrado')).toBeNull()
    expect(onClose).not.toHaveBeenCalled()
  })
})

describe('ModalRegistrarPago · pantalla de éxito (pago simple)', () => {
  it('registra con los datos del formulario y muestra «Pago Registrado»', async () => {
    const user = userEvent.setup()
    const { onConfirmar, onClose } = montar()

    await registrarPorElTotal(user)

    expect(await screen.findByRole('heading', { name: 'Pago Registrado' })).toBeInTheDocument()
    expect(onConfirmar).toHaveBeenCalledTimes(1)
    expect(onConfirmar).toHaveBeenCalledWith({
      clienteId: '1',
      pedidoId: null,
      monto: SALDO,
      formaPago: 'efectivo',
      referencia: '',
      notas: '',
      fecha: expect.stringMatching(/^\d{4}-\d{2}-\d{2}$/),
      clientRequestId: expect.any(String),
    })
    expect(screen.getByText(/Se registro un pago de/)).toHaveTextContent('Almacén Don Ramón')
    expect(screen.queryByRole('heading', { name: 'Registrar Pago' })).toBeNull()
    expect(onClose).not.toHaveBeenCalled()
  })

  it('«Generar Recibo» llama a onGenerarRecibo con el pago registrado y el cliente', async () => {
    const user = userEvent.setup()
    const onGenerarRecibo = vi.fn()
    const { onClose } = montar({ onGenerarRecibo })

    await registrarPorElTotal(user)
    await user.click(await screen.findByRole('button', { name: 'Generar Recibo' }))

    expect(onGenerarRecibo).toHaveBeenCalledTimes(1)
    expect(onGenerarRecibo).toHaveBeenCalledWith(PAGO, CLIENTE)
    expect(onClose).not.toHaveBeenCalled()
  })

  it('sin onGenerarRecibo no ofrece el recibo', async () => {
    const user = userEvent.setup()
    montar()

    await registrarPorElTotal(user)
    await screen.findByRole('heading', { name: 'Pago Registrado' })

    expect(screen.queryByRole('button', { name: 'Generar Recibo' })).toBeNull()
  })

  it('«Cerrar» llama a onClose', async () => {
    const user = userEvent.setup()
    const { onClose } = montar({ onGenerarRecibo: vi.fn() })

    await registrarPorElTotal(user)
    await screen.findByRole('heading', { name: 'Pago Registrado' })
    await user.click(screen.getByRole('button', { name: 'Cerrar' }))

    expect(onClose).toHaveBeenCalledTimes(1)
  })

  it('Escape y el click en el fondo tampoco cierran la pantalla de éxito', async () => {
    const user = userEvent.setup()
    const { onClose } = montar()

    await registrarPorElTotal(user)
    await screen.findByRole('heading', { name: 'Pago Registrado' })
    await dejarCorrerTimers()
    await user.keyboard('{Escape}')
    await user.click(fondoDelModal())
    await dejarCorrerTimers()

    expect(onClose).not.toHaveBeenCalled()
    expect(screen.getByRole('heading', { name: 'Pago Registrado' })).toBeInTheDocument()
  })
})

describe('ModalRegistrarPago · es un diálogo accesible (ui/Dialog, #810)', () => {
  it('el formulario es un dialog modal llamado «Registrar Pago», descripto por el cliente', () => {
    montar()

    const dialogo = screen.getByRole('dialog', { name: 'Registrar Pago' })
    expect(dialogo).toHaveAttribute('aria-modal', 'true')
    expect(dialogo).toHaveAccessibleDescription('Almacén Don Ramón')
  })

  it('la pantalla de éxito (pago simple) es un dialog llamado «Pago Registrado»', async () => {
    const user = userEvent.setup()
    montar()

    await registrarPorElTotal(user)

    const dialogo = await screen.findByRole('dialog', { name: 'Pago Registrado' })
    expect(dialogo).toHaveAttribute('aria-modal', 'true')
    expect(screen.queryByRole('dialog', { name: 'Registrar Pago' })).toBeNull()
  })

  it('la pantalla de éxito FIFO es un dialog llamado «Pago Registrado»', async () => {
    const user = userEvent.setup()
    montar({ onConfirmarFIFO: vi.fn().mockResolvedValue(RESULTADO_FIFO) })

    await registrarPorElTotal(user)

    const dialogo = await screen.findByRole('dialog', { name: 'Pago Registrado' })
    expect(dialogo).toHaveAttribute('aria-modal', 'true')
    expect(within(dialogo).getByText('Desglose:')).toBeInTheDocument()
  })

  it('al abrirse, el foco entra al diálogo y deja el botón de la vista que lo abrió', async () => {
    function Host() {
      const [abierto, setAbierto] = useState(false)
      return (
        <>
          <button type="button" onClick={() => setAbierto(true)}>Cobrar</button>
          {abierto && (
            <ModalRegistrarPago
              cliente={CLIENTE}
              saldoPendiente={SALDO}
              pedidos={[]}
              onClose={() => setAbierto(false)}
              onConfirmar={vi.fn()}
            />
          )}
        </>
      )
    }
    const user = userEvent.setup()
    render(<Host />)
    const cobrar = screen.getByRole('button', { name: 'Cobrar' })

    await user.click(cobrar)
    await dejarCorrerTimers()

    expect(cobrar).not.toHaveFocus()
    expect(screen.getByRole('dialog', { name: 'Registrar Pago' }))
      .toContainElement(document.activeElement as HTMLElement)
  })

  it('Tab desde el último focusable vuelve al primero, y Shift+Tab desde el primero al último', async () => {
    const user = userEvent.setup()
    montar()
    await dejarCorrerTimers()
    // Con monto cargado, «Registrar» se habilita y es el último del footer.
    await user.click(screen.getByRole('button', { name: 'Total' }))
    const registrar = screen.getByRole('button', { name: 'Registrar' })
    const cerrar = screen.getByRole('button', { name: 'Cerrar' })

    registrar.focus()
    await user.tab()
    expect(cerrar).toHaveFocus()

    await user.tab({ shift: true })
    expect(registrar).toHaveFocus()
  })

  it('Tab recorre el formulario sin salir nunca del diálogo hacia la vista de atrás', async () => {
    const user = userEvent.setup()
    render(<button type="button">Botón de la vista</button>)
    montar()
    await dejarCorrerTimers()
    const dialogo = screen.getByRole('dialog', { name: 'Registrar Pago' })
    const deLaVista = screen.getByRole('button', { name: 'Botón de la vista', hidden: true })

    for (let i = 0; i < 30; i++) {
      await user.tab()
      expect(deLaVista).not.toHaveFocus()
      expect(dialogo).toContainElement(document.activeElement as HTMLElement)
    }
  })

  it('al pasar a la pantalla de éxito el foco sigue adentro del diálogo', async () => {
    const user = userEvent.setup()
    montar({ onGenerarRecibo: vi.fn() })

    await registrarPorElTotal(user)
    const dialogo = await screen.findByRole('dialog', { name: 'Pago Registrado' })
    await dejarCorrerTimers()

    expect(dialogo).toContainElement(document.activeElement as HTMLElement)
  })
})

describe('ModalRegistrarPago · pantalla de éxito FIFO', () => {
  it('sin pedido elegido imputa por FIFO, muestra el desglose y «Cerrar» llama a onClose', async () => {
    const user = userEvent.setup()
    const onConfirmarFIFO = vi.fn<NonNullable<ModalRegistrarPagoProps['onConfirmarFIFO']>>()
      .mockResolvedValue(RESULTADO_FIFO)
    const { onClose, onConfirmar } = montar({ onConfirmarFIFO })

    await registrarPorElTotal(user)

    expect(await screen.findByRole('heading', { name: 'Pago Registrado' })).toBeInTheDocument()
    expect(onConfirmar).not.toHaveBeenCalled()
    expect(onConfirmarFIFO).toHaveBeenCalledTimes(1)
    expect(onConfirmarFIFO).toHaveBeenCalledWith({
      clienteId: '1',
      monto: SALDO,
      formaPago: 'efectivo',
      fecha: expect.stringMatching(/^\d{4}-\d{2}-\d{2}$/),
      referencia: undefined,
      notas: undefined,
      clientRequestId: expect.any(String),
    })
    expect(screen.getByText(/Total imputado:/)).toHaveTextContent('Almacén Don Ramón')
    const desglose = screen.getByText('Desglose:').parentElement as HTMLElement
    expect(within(desglose).getByText('Pedido #77')).toBeInTheDocument()
    expect(onClose).not.toHaveBeenCalled()

    await user.click(screen.getByRole('button', { name: 'Cerrar' }))

    expect(onClose).toHaveBeenCalledTimes(1)
  })
})
