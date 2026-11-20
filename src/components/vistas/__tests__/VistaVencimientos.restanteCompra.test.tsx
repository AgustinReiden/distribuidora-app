/**
 * 1590-c (#1590): «Le quedan $ X» en la devolución por lote.
 *
 * La devolución al proveedor de un lote es una nota de crédito sobre su compra, y
 * si la compra ya tiene un ajuste vigente no puede pasar lo que le queda (su total
 * menos sus notas vigentes; decisión del dueño, #1565). El formulario de la compra
 * lo dice (#1643); el del lote no tenía ni el total ni las notas de la compra y el
 * usuario se enteraba por el rechazo. Ahora, al abrir la devolución, la vista le
 * pide al container la compra del lote y muestra lo que le queda. No bloquea: el
 * server mide la devolución con el importe neto de los descuentos de la factura,
 * un número que la pantalla no tiene.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import VistaVencimientos, { type VistaVencimientosProps } from '../VistaVencimientos'
import type { LoteReporte } from '../../../hooks/queries/useLotesQuery'

beforeEach(() => {
  vi.useFakeTimers({ toFake: ['Date'] })
  vi.setSystemTime(new Date(2026, 9, 3, 12, 0, 0))
})

afterEach(() => {
  vi.useRealTimers()
})

const LOTE: LoteReporte = {
  lote_id: 7,
  producto_id: 107,
  producto_nombre: 'Producto 07',
  producto_codigo: null,
  fecha_vencimiento: '2026-09-20',
  cantidad: 10,
  cantidad_restante: 10,
  dias_restantes: -13,
  origen: 'compra',
  compra_id: 55,
  stock_producto: 40,
  bolsa_producto: 0,
}

function props(overrides: Partial<VistaVencimientosProps> = {}): VistaVencimientosProps {
  return {
    lotes: [LOTE],
    cargando: false,
    refrescando: false,
    diasAlerta: 30,
    diasCritico: 15,
    puedeDarDeBaja: true,
    darDeBajaPendiente: false,
    devolucionPendiente: false,
    onRefrescar: vi.fn(),
    onDarDeBaja: vi.fn().mockResolvedValue(undefined),
    onDevolverAlProveedor: vi.fn().mockResolvedValue(undefined),
    nombreSucursal: 'Tucumán',
    ...overrides,
  }
}

describe('VistaVencimientos — lo que le queda a la compra del lote', () => {
  it('al abrir la devolución pide la compra del lote, y al cerrarla la suelta', async () => {
    const onCompraDevolucion = vi.fn()
    render(<VistaVencimientos {...props({ onCompraDevolucion })} />)
    const user = userEvent.setup()

    await user.click(screen.getByRole('button', { name: /Devolver al proveedor/ }))
    expect(onCompraDevolucion).toHaveBeenLastCalledWith(55)

    await user.click(screen.getByRole('button', { name: 'Cancelar la devolución al proveedor' }))
    expect(onCompraDevolucion).toHaveBeenLastCalledWith(null)
  })

  it('con el tope de la compra, la devolución dice cuánto le queda', async () => {
    render(<VistaVencimientos {...props({ restanteCompra: { compraId: 55, restante: 200 } })} />)
    await userEvent.setup().click(screen.getByRole('button', { name: /Devolver al proveedor/ }))

    expect(screen.getByTestId('devolucion-restante-compra')).toHaveTextContent(
      /Le quedan \$\s?200,00 por acreditar en su compra \(su total menos las notas que ya tiene, contando los ajustes\)/,
    )
  })

  it('sin tope (la compra no tiene un ajuste) no dice nada', async () => {
    render(<VistaVencimientos {...props({ restanteCompra: null })} />)
    await userEvent.setup().click(screen.getByRole('button', { name: /Devolver al proveedor/ }))

    expect(screen.queryByTestId('devolucion-restante-compra')).not.toBeInTheDocument()
  })

  it('el de otra compra no se muestra en este lote', async () => {
    render(<VistaVencimientos {...props({ restanteCompra: { compraId: 99, restante: 200 } })} />)
    await userEvent.setup().click(screen.getByRole('button', { name: /Devolver al proveedor/ }))

    expect(screen.queryByTestId('devolucion-restante-compra')).not.toBeInTheDocument()
  })
})
