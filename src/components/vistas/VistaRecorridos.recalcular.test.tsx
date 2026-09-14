/**
 * El botón de recalcular una ruta (mig 234).
 *
 * Hasta la 234 el trigger de entrega era `AFTER UPDATE OF estado, monto_pagado`,
 * así que una salvedad bajaba `pedidos.total` y `recorridos.total_facturado` no
 * se enteraba: 18 de 123 rutas quedaron con "Pendiente" (facturado − cobrado)
 * inflado. El trigger ya no se pierde el cambio, pero las rutas viejas necesitan
 * un recálculo explícito, y `recalcular_recorrido` no tenía ningún caller en el
 * front.
 *
 * Lo que se verifica acá es el contrato del botón, no el RPC: aparece sólo si el
 * container pasó `onRecalcular` (o sea, sólo para admin — el RPC exige encargado
 * o admin y un botón que siempre falla es peor que no tenerlo), y le pasa el id
 * del recorrido en el que se hizo clic, no el de otro.
 */
import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

vi.mock('../../hooks/queries', () => ({
  useDepositoCoords: () => null,
}))

vi.mock('../recorridos/PanelNoEntregados', () => ({
  default: () => null,
}))

import VistaRecorridos from './VistaRecorridos'

const recorridos = [
  {
    id: '7',
    fecha: '2026-09-10',
    estado: 'completado',
    total_pedidos: 2,
    pedidos_entregados: 2,
    total_facturado: 50000,
    total_cobrado: 30000,
    transportista: { nombre: 'Rulo' },
    pedidos: [],
  },
  {
    id: '9',
    fecha: '2026-09-10',
    estado: 'en_curso',
    total_pedidos: 1,
    pedidos_entregados: 0,
    total_facturado: 1000,
    total_cobrado: 0,
    transportista: { nombre: 'Tino' },
    pedidos: [],
  },
] as any

const baseProps = {
  recorridos,
  loading: false,
  fechaSeleccionada: '2026-09-10',
  estadisticas: null,
  onRefresh: vi.fn(),
  onFechaChange: vi.fn(),
}

describe('VistaRecorridos · botón de recalcular', () => {
  it('no dibuja el botón si el container no pasó onRecalcular (no-admin)', () => {
    render(<VistaRecorridos {...baseProps} />)

    expect(screen.queryAllByRole('button', { name: /recalcular totales/i })).toHaveLength(0)
  })

  it('dibuja un botón por recorrido cuando el usuario es admin', () => {
    render(<VistaRecorridos {...baseProps} onRecalcular={vi.fn()} />)

    expect(screen.getAllByRole('button', { name: /recalcular totales/i })).toHaveLength(2)
  })

  it('llama a onRecalcular con el id del recorrido clickeado', async () => {
    const onRecalcular = vi.fn().mockResolvedValue(undefined)
    render(<VistaRecorridos {...baseProps} onRecalcular={onRecalcular} />)

    const botones = screen.getAllByRole('button', { name: /recalcular totales/i })
    await userEvent.click(botones[1])

    expect(onRecalcular).toHaveBeenCalledTimes(1)
    expect(onRecalcular).toHaveBeenCalledWith('9')
  })

  it('no dispara un segundo recálculo mientras el primero está en vuelo', async () => {
    let resolver: (() => void) | undefined
    const onRecalcular = vi.fn().mockImplementation(
      () => new Promise<void>(res => { resolver = res })
    )
    render(<VistaRecorridos {...baseProps} onRecalcular={onRecalcular} />)

    const boton = screen.getAllByRole('button', { name: /recalcular totales/i })[0]
    await userEvent.click(boton)
    expect(boton).toBeDisabled()

    await userEvent.click(boton)
    expect(onRecalcular).toHaveBeenCalledTimes(1)

    resolver?.()
  })
})
