/**
 * La baja de un lote que todavía no venció pide el motivo (#1558, 1558-b6;
 * decisión del dueño): `dar_de_baja_lote` la rechaza sin él. El lote vencido
 * sigue sin pedirlo, y llama a `onDarDeBaja` con dos argumentos, como antes.
 *
 * El reloj se fija en el 3/10/2026 (solo `Date`), como en la caracterización.
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

const VENCIDO = '2026-09-20'
const HOY = '2026-10-03'
const CRITICO = '2026-10-10'

function lote(id: number, fecha: string): LoteReporte {
  return {
    lote_id: id,
    producto_id: 100 + id,
    producto_nombre: `Producto ${id}`,
    producto_codigo: null,
    fecha_vencimiento: fecha,
    cantidad: 10,
    cantidad_restante: 8,
    dias_restantes: 0,
    origen: 'manual',
    compra_id: null,
    stock_producto: 40,
    bolsa_producto: 0,
  }
}

function renderVista(lotes: LoteReporte[]) {
  const props: VistaVencimientosProps = {
    lotes,
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
  }
  render(<VistaVencimientos {...props} />)
  return props
}

describe('VistaVencimientos — la baja de un lote que no venció pide el motivo', () => {
  it('sin motivo no llama a la RPC y dice qué falta', async () => {
    const props = renderVista([lote(3, CRITICO)])
    const user = userEvent.setup()
    await user.click(screen.getByRole('button', { name: /Dar de baja/ }))
    expect(screen.getByRole('textbox', { name: 'Motivo de la baja' })).toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'Confirmar la baja' }))
    expect(props.onDarDeBaja).not.toHaveBeenCalled()
    expect(screen.getByRole('alert')).toHaveTextContent('todavía no venció')
  })

  it('con motivo llama a la RPC con el motivo, sin los espacios de los bordes', async () => {
    const props = renderVista([lote(3, CRITICO)])
    const user = userEvent.setup()
    await user.click(screen.getByRole('button', { name: /Dar de baja/ }))
    await user.type(screen.getByRole('textbox', { name: 'Motivo de la baja' }), '  Rotura en el depósito ')
    await user.click(screen.getByRole('button', { name: 'Confirmar la baja' }))
    expect(props.onDarDeBaja).toHaveBeenCalledWith(3, 8, 'Rotura en el depósito')
  })

  it('el lote que vence hoy todavía no venció: también lo pide', async () => {
    const props = renderVista([lote(4, HOY)])
    const user = userEvent.setup()
    await user.click(screen.getByRole('button', { name: /Dar de baja/ }))
    await user.click(screen.getByRole('button', { name: 'Confirmar la baja' }))
    expect(props.onDarDeBaja).not.toHaveBeenCalled()
  })

  it('el lote vencido no pide motivo y llama con dos argumentos', async () => {
    const props = renderVista([lote(1, VENCIDO)])
    const user = userEvent.setup()
    await user.click(screen.getByRole('button', { name: /Dar de baja/ }))
    expect(screen.queryByRole('textbox', { name: 'Motivo de la baja' })).not.toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'Confirmar la baja' }))
    expect(props.onDarDeBaja).toHaveBeenCalledWith(1, 8)
  })

  it('cancelar y volver a abrir borra el motivo y el error', async () => {
    renderVista([lote(3, CRITICO)])
    const user = userEvent.setup()
    await user.click(screen.getByRole('button', { name: /Dar de baja/ }))
    await user.type(screen.getByRole('textbox', { name: 'Motivo de la baja' }), 'algo')
    await user.click(screen.getByRole('button', { name: 'Cancelar la baja' }))
    await user.click(screen.getByRole('button', { name: /Dar de baja/ }))
    expect(screen.getByRole('textbox', { name: 'Motivo de la baja' })).toHaveValue('')
    expect(screen.queryByRole('alert')).not.toBeInTheDocument()
  })
})
